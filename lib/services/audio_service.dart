import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import '../models/song_model.dart';
import 'error_log_service.dart';
import 'notification_art_cache.dart';

/// Estados de reprodução expostos para a UI (abstração sobre PlayerState).
enum PlayerStatus { idle, playing, paused, stopped, completed }

/// Camada de serviço de áudio.
///
/// Responsabilidade: isolar TODA a lógica do `AudioPlayer` do pacote
/// audioplayers em um único lugar. A UI e o Provider nunca tocam no plugin
/// diretamente — conversam apenas com esta classe.
///
/// Extende `BaseAudioHandler` (audio_service): além do player, esta classe
/// alimenta o MediaSession do Android — notificação de mídia persistente e
/// controles na tela de bloqueio/heads-up (play, pause, próxima, anterior,
/// seek). Os botões do sistema chamam os overrides ([play], [pause], [stop],
/// [seek], [skipToNext], [skipToPrevious]); a navegação real da fila fica no
/// [PlayerProvider] via callbacks ([onSkipToNext]/[onSkipToPrevious]).
///
/// Pontos críticos da implementação:
///  - Streams expostos via `ValueNotifier` (posição, duração, status, erro)
///    para a UI, mais `playbackState`/`mediaItem` do audio_service;
///  - Toda `StreamSubscription` é registrada e cancelada em [dispose],
///    evitando vazamento de memória e callbacks em widgets destruídos;
///  - Toda chamada ao player (inclusive as vindas de CALLBACKS DE STREAM)
///    é blindada com try/catch + log local: se o canal nativo foi
///    destruído (Activity recriada pelo SO), o erro vira mensagem na UI,
///    nunca crash;
///  - `playSong()` para a reprodução anterior ANTES de carregar a nova faixa
///    (troca rápida de música sem "duplicar" áudio ou travar o player);
///  - Erros de reprodução nunca crasham: viram mensagem em [errorMessage].
class AudioService extends BaseAudioHandler {
  final AudioPlayer _player = AudioPlayer();

  /// Posição atual de reprodução (atualizada ~200ms em tempo real).
  final ValueNotifier<Duration> position = ValueNotifier(Duration.zero);

  /// Duração total da faixa carregada.
  final ValueNotifier<Duration> duration = ValueNotifier(Duration.zero);

  /// Estado do player (playing, paused, stopped, completed...).
  final ValueNotifier<PlayerStatus> status =
      ValueNotifier(PlayerStatus.idle);

  /// Última mensagem de erro (null = sem erro). Usada para feedback visual.
  final ValueNotifier<String?> errorMessage = ValueNotifier(null);

  /// Todas as subscrições ativas, para cancelamento centralizado no dispose.
  final List<StreamSubscription<dynamic>> _subscriptions = [];

  /// Faixa corrente (para o botão play do sistema retomar/repetir).
  Song? _currentSong;

  /// True quando o audio_service falhou no boot e o app roda em modo
  /// degradado (sem notificação/tela de bloqueio, só som).
  final bool degradedMode;

  /// Callbacks de navegação da fila — setados pelo [PlayerProvider], que
  /// conhece a fila/shuffle/repeat. Evita acoplamento do serviço ao estado.
  Future<void> Function()? onSkipToNext;
  Future<void> Function()? onSkipToPrevious;

  /// Chamado quando uma faixa FALHOU ao abrir (arquivo apagado/corrompido,
  /// canal nativo morto...). O [PlayerProvider] decide se pula para a
  /// próxima — com limite de falhas seguidas para não entrar em loop.
  Future<void> Function(Song song)? onPlaybackFailed;

  /// Leitura ao vivo da preferência "pausar ao desconectar fones"
  /// ([SettingsProvider.pauseOnNoisy]). É um getter (não bool) para
  /// refletir mudanças feitas em Configurações sem recriar o serviço.
  /// Nulo = padrão (ligado).
  bool Function()? pauseOnNoisyEnabled;

  /// Tipo da interrupção que pausou a reprodução (null = nenhuma).
  ///
  /// Diferencia PERDA TEMPORÁRIA (ligação/notificação -> retoma sozinho)
  /// de PERDA PERMANENTE (outro app assumiu o áudio -> NÃO retoma).
  AudioInterruptionType? _interruptionPause;

  AudioService({this.degradedMode = false, this.pauseOnNoisyEnabled}) {
    _configureAudioSession();

    // Subscrições nos streams nativos do plugin. Guardamos cada uma na
    // lista para cancelar em [dispose] — regra de ouro contra leaks.
    // Cada mudança relevante também reemite o playbackState do
    // audio_service para manter a notificação/tela de bloqueio sincronizadas.
    // Os corpos são blindados: uma exceção DENTRO de um callback de stream
    // escapa para a zona e derrubaria o app — agora vira log local.
    _subscriptions.addAll(<StreamSubscription<dynamic>>[
      _player.onPositionChanged.listen((Duration newPosition) {
        try {
          position.value = newPosition;
          _broadcastPlaybackState();
        } catch (e, s) {
          ErrorLogService.logSync('audio/onPosition', e, s);
        }
      }),
      _player.onDurationChanged.listen((Duration newDuration) {
        try {
          duration.value = newDuration;
        } catch (e, s) {
          ErrorLogService.logSync('audio/onDuration', e, s);
        }
      }),
      _player.onPlayerStateChanged.listen((state) {
        try {
          _mapPlayerState(state);
          _broadcastPlaybackState();
        } catch (e, s) {
          ErrorLogService.logSync('audio/onState', e, s);
        }
      }),
      _player.onPlayerComplete.listen((_) {
        try {
          // Faixa chegou ao fim naturalmente.
          status.value = PlayerStatus.completed;
          _broadcastPlaybackState();
        } catch (e, s) {
          ErrorLogService.logSync('audio/onComplete', e, s);
        }
      }),
    ]);
  }

  /// Fallback do boot: quando `AudioService.init` falha (canal nativo
  /// indisponível pós-crash do processo), o app abre mesmo assim —
  /// apenas sem notificação de mídia/tela de bloqueio.
  factory AudioService.noop() {
    debugPrint('[AudioService] Modo degradado: sem MediaSession/segundo plano.');
    return AudioService(degradedMode: true);
  }

  /// Configura a sessão de áudio (AudioSession) e reage a interrupções:
  /// pausa em ligações/outro app de áudio e retoma quando apropriado.
  ///
  /// Chamada no construtor; falhas de plataforma (Linux/Web sem canal
  /// nativo) viram log — o app continua funcional sem esse recurso.
  Future<void> _configureAudioSession() async {
    try {
      final AudioSession session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
      _subscriptions.add(
        session.interruptionEventStream.listen(
          (event) => _handleInterruption(event),
          onError: (Object e, StackTrace s) =>
              ErrorLogService.logSync('audio/interruption', e, s),
        ),
      );
      // "Becoming noisy" = fone desconectado (ou Bluetooth de áudio
      // desligado): pausa, sem auto-retomada. A decisão (se deve
      // pausar) é função pura testável — ver [shouldPauseOnNoisy].
      _subscriptions.add(
        session.becomingNoisyEventStream.listen(
          (_) => _handleBecomingNoisy(),
          onError: (Object e, StackTrace s) =>
              ErrorLogService.logSync('audio/becomingNoisy', e, s),
        ),
      );
    } catch (e, s) {
      // Plataforma sem suporte (desktop/web/testes): segue sem pausa
      // automática — comportamento esperado, log discreto.
      ErrorLogService.logSync('audio/session', e, s);
    }
  }

  /// Reage a eventos de interrupção do AudioSession distinguindo os tipos:
  ///
  ///  - begin + [AudioInterruptionType.pause]: pausa AGORA e marcará para
  ///    retomar quando a interrupção terminar (ligação curta, alarme).
  ///  - begin + [AudioInterruptionType.unknown]: outro app tomou o foco
  ///    permanentemente — pausa e NÃO retoma sozinho (comportamento
  ///    recomendado pela doc do audio_session; antes qualquer fim de
  ///    interrupção retomava, inclusive perda permanente).
  ///  - begin + duck: só reduz volume em configs que pedem duck — a config
  ///    music() não usa, então ignorado.
  void _handleInterruption(AudioInterruptionEvent event) {
    try {
      if (event.begin) {
        final bool wasPlaying = status.value == PlayerStatus.playing;
        switch (event.type) {
          case AudioInterruptionType.duck:
            break;
          case AudioInterruptionType.pause:
            _interruptionPause =
                wasPlaying ? AudioInterruptionType.pause : null;
            if (wasPlaying) pause();
          case AudioInterruptionType.unknown:
            _interruptionPause = null; // perda permanente: não retoma.
            if (wasPlaying) pause();
        }
      } else if (_interruptionPause != null &&
          event.type == AudioInterruptionType.pause) {
        // Interrupção temporária terminou: retoma.
        _interruptionPause = null;
        resume();
      }
    } catch (e, s) {
      ErrorLogService.logSync('audio/interruption', e, s);
    }
  }

  /// Decisão PURA: pausar ao receber "becoming noisy"?
  ///
  /// Extraída assim (sem tocar em plugins/estado) para ser
  /// testável em unidade: só pausa se a música estiver
  /// tocando E o usuário não desligou a preferência.
  /// Nunca retoma sozinho — quem retoma é o usuário.
  static bool shouldPauseOnNoisy({
    required bool isPlaying,
    required bool settingEnabled,
  }) =>
      isPlaying && settingEnabled;

  /// Mensagem AMIGÁVEL (pt-BR) para o usuário a partir de uma falha.
  ///
  /// Função PURA — sem plugin/estado, testável em unidade. O detalhe
  /// técnico da exceção NÃO aparece aqui: quem registra é o
  /// [ErrorLogService] (chamado pelo catch de origem).
  static String friendlyError(Object error) {
    final String text = error.toString().toLowerCase();
    if (text.contains('unable to load asset') ||
        text.contains('no such file') ||
        text.contains('not found') ||
        text.contains('does not exist') ||
        text.contains('enoent')) {
      return 'Arquivo não encontrado — pode ter sido movido ou apagado.';
    }
    if (text.contains('permission') ||
        text.contains('eacces') ||
        text.contains('denied')) {
      return 'Sem permissão para ler este arquivo.';
    }
    if (text.contains('corrupt') ||
        text.contains('format') ||
        text.contains('invalid') ||
        text.contains('source error')) {
      return 'O arquivo parece estar corrompido ou em formato incompatível.';
    }
    return 'Tente novamente ou toque em outra faixa.';
  }

  /// Monta a mensagem final: ação + motivo amigável (nunca o objeto
  /// da exceção cru, que confunde o usuário).
  static String userMessage(String action, Object error) =>
      'Não foi possível $action. ${friendlyError(error)}';

  /// Decisão PURA: vale a pena PULAR para a próxima faixa após esta
  /// falha de abertura?
  ///
  /// Só sim para falha de ARQUIVO (apagado/corrompido/inacessível) —
  /// aí a próxima faixa tem chance de tocar. Para falha de PLATAFORMA
  /// (canal nativo morto, plugin indisponível), pular não resolve:
  /// TODAS as faixas falhariam da mesma forma e só se aquece o
  /// aparelho tentando. Assim também não dispara skip em testes/
  /// ambientes sem canal nativo.
  static bool shouldSkipOnOpenFailure(Object error) {
    final String text = error.toString().toLowerCase();
    if (text.contains('missingpluginexception')) return false;
    return text.contains('unable to load asset') ||
        text.contains('no such file') ||
        text.contains('not found') ||
        text.contains('does not exist') ||
        text.contains('enoent') ||
        text.contains('permission') ||
        text.contains('eacces') ||
        text.contains('denied') ||
        text.contains('corrupt') ||
        text.contains('failed to open') ||
        text.contains('cannot open');
  }

  /// Reage ao evento "becoming noisy" (fone desconectado):
  /// pausa a reprodução se [shouldPauseOnNoisy] disser sim.
  /// Falhas viram log local — o evento do sistema nunca
  /// pode derrubar o app.
  void _handleBecomingNoisy() {
    try {
      final bool shouldPause = shouldPauseOnNoisy(
        isPlaying: status.value == PlayerStatus.playing,
        settingEnabled: pauseOnNoisyEnabled?.call() ?? true,
      );
      if (shouldPause) pause();
    } catch (e, s) {
      ErrorLogService.logSync('audio/becomingNoisy', e, s);
    }
  }

  /// Traduz o estado interno do plugin para o enum da nossa camada.
  void _mapPlayerState(PlayerState state) {
    switch (state) {
      case PlayerState.playing:
        status.value = PlayerStatus.playing;
      case PlayerState.paused:
        status.value = PlayerStatus.paused;
      case PlayerState.stopped:
        status.value = PlayerStatus.stopped;
      case PlayerState.completed:
        status.value = PlayerStatus.completed;
      case PlayerState.disposed:
        status.value = PlayerStatus.stopped;
    }
  }

  /// Reproduz uma faixa do catálogo.
  ///
  /// Estratégia para troca rápida de música: `stop()` primeiro (cancela a
  /// faixa anterior e libera recursos), só então seta a nova fonte. Sem
  /// isso, duas reproduções podem sobrepor-se no mesmo player.
  ///
  /// Fonte conforme a origem: assets usam `AssetSource`; faixas do
  /// aparelho usam `DeviceFileSource` com o caminho absoluto do arquivo.
  Future<void> playSong(Song song) async {
    try {
      _currentSong = song;
      errorMessage.value = null;
      await _player.stop();
      await _player.setReleaseMode(ReleaseMode.stop);

      final Source source = song.isAsset
          ? AssetSource(song.assetKey!)
          : DeviceFileSource(song.filePath!);
      await _player.setSource(source);
      await _player.resume();

      // Atualiza a notificação de mídia (título, artista, duração).
      // A capa vem de um ARQUIVO no cache do app (Uri.file) — o
      // content:// legado do albumart falha no Android 10+ e faixa de
      // asset não tinha capa nenhuma. Ver [NotificationArtCache].
      final Uri? artUri = await NotificationArtCache.uriFor(song);
      mediaItem.add(MediaItem(
        id: song.id,
        title: song.title,
        artist: song.displayArtist,
        album: song.album,
        duration: song.duration,
        artUri: artUri,
      ));
      _broadcastPlaybackState();
    } catch (e, s) {
      // Arquivo inválido/corrompido ou falha de plataforma (inclui canal
      // nativo morto): nunca crash — loga TÉCNICO no serviço de log e
      // expõe mensagem amigável para a UI.
      ErrorLogService.logSync('audio/playSong', e, s);
      status.value = PlayerStatus.idle;
      errorMessage.value = userMessage('tocar "${song.title}"', e);
      // Notifica o provider (só em falha de ARQUIVO — ver
      // [shouldSkipOnOpenFailure]): ele decide se pula para a próxima
      // faixa, com limite de falhas seguidas (PlayerProvider).
      if (shouldSkipOnOpenFailure(e)) {
        try {
          await onPlaybackFailed?.call(song);
        } catch (e2, s2) {
          ErrorLogService.logSync('audio/onPlaybackFailed', e2, s2);
        }
      }
    }
  }

  /// Override do audio_service: botão play da notificação/tela de bloqueio.
  @override
  Future<void> play() async {
    final Song? current = _currentSong;
    if (current == null) return;
    if (status.value == PlayerStatus.completed ||
        status.value == PlayerStatus.stopped) {
      // Faixa já terminou ou foi parada: recomeça do início.
      await playSong(current);
    } else {
      await resume();
    }
  }

  /// Pausa a reprodução, mantendo a posição.
  @override
  Future<void> pause() async {
    try {
      await _player.pause();
    } catch (e, s) {
      ErrorLogService.logSync('audio/pause', e, s);
      errorMessage.value = userMessage('pausar a reprodução', e);
    }
  }

  /// Retoma de onde parou.
  Future<void> resume() async {
    try {
      await _player.resume();
    } catch (e, s) {
      ErrorLogService.logSync('audio/resume', e, s);
      errorMessage.value = userMessage('retomar a reprodução', e);
    }
  }

  /// Para a reprodução e volta o cursor para o início.
  @override
  Future<void> stop() async {
    _interruptionPause = null;
    try {
      await _player.stop();
    } catch (e, s) {
      ErrorLogService.logSync('audio/stop', e, s);
      errorMessage.value = userMessage('parar a reprodução', e);
    } finally {
      status.value = PlayerStatus.idle;
      // Notifica o audio_service: processa o stop (remove controles e,
      // no Android, permite encerrar o foreground service limpo — cobre
      // o caso de o usuário deslizar o app fora dos recentes).
      await super.stop();
    }
  }

  /// Busca (seek) para uma posição específica.
  @override
  Future<void> seek(Duration target) async {
    try {
      await _player.seek(target);
      position.value = target;
      _broadcastPlaybackState();
    } catch (e, s) {
      ErrorLogService.logSync('audio/seek', e, s);
      errorMessage.value = userMessage('mudar a posição da faixa', e);
    }
  }

  /// Botão "próxima" do sistema: delega à lógica de fila do provider.
  /// Falhas do provider são capturadas aqui — o botão vem do PROCESSO
  /// NATIVO e um throw atravessaria o canal de plataforma.
  @override
  Future<void> skipToNext() async {
    try {
      await onSkipToNext?.call();
    } catch (e, s) {
      ErrorLogService.logSync('audio/skipNext', e, s);
    }
  }

  /// Botão "anterior" do sistema: idem [skipToNext].
  @override
  Future<void> skipToPrevious() async {
    try {
      await onSkipToPrevious?.call();
    } catch (e, s) {
      ErrorLogService.logSync('audio/skipPrevious', e, s);
    }
  }

  /// Reemite o estado para o audio_service (notificação + lock screen).
  ///
  /// A lista de controles muda conforme o estado: pausa quando tocando,
  /// play quando pausado. Os compact indices definem os botões visíveis
  /// na notificação compacta (anterior, play/pause, próxima).
  void _broadcastPlaybackState() {
    try {
      final bool playing = status.value == PlayerStatus.playing;
      playbackState.add(PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          playing ? MediaControl.pause : MediaControl.play,
          MediaControl.skipToNext,
          MediaControl.stop,
        ],
        systemActions: const {MediaAction.seek},
        androidCompactActionIndices: const [0, 1, 2],
        processingState: status.value == PlayerStatus.idle
            ? AudioProcessingState.idle
            : AudioProcessingState.ready,
        playing: playing,
        updatePosition: position.value,
      ));
    } catch (e, s) {
      ErrorLogService.logSync('audio/broadcast', e, s);
    }
  }

  /// Cancela todas as subscrições e descarta o player.
  ///
  /// Chamado pelo Provider no seu próprio dispose. IMPORTANTE: cancela os
  /// streams ANTES de descartar o player, garantindo que nenhum callback
  /// seja disparado depois que a UI já foi destruída.
  Future<void> dispose() async {
    for (final subscription in List.of(_subscriptions)) {
      try {
        await subscription.cancel();
      } catch (e, s) {
        ErrorLogService.logSync('audio/dispose-sub', e, s);
      }
    }
    _subscriptions.clear();

    position.dispose();
    duration.dispose();
    status.dispose();
    errorMessage.dispose();

    try {
      await _player.dispose();
    } catch (e, s) {
      ErrorLogService.logSync('audio/dispose-player', e, s);
    }
  }
}
