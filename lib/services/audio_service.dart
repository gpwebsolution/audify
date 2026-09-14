import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import '../models/song_model.dart';
import 'error_log_service.dart';

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

  /// Tipo da interrupção que pausou a reprodução (null = nenhuma).
  ///
  /// Diferencia PERDA TEMPORÁRIA (ligação/notificação -> retoma sozinho)
  /// de PERDA PERMANENTE (outro app assumiu o áudio -> NÃO retoma).
  AudioInterruptionType? _interruptionPause;

  AudioService({this.degradedMode = false}) {
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
      mediaItem.add(MediaItem(
        id: song.id,
        title: song.title,
        artist: song.displayArtist,
        album: song.album,
        duration: song.duration,
        artUri: song.albumId != null
            ? Uri.parse(
                'content://media/external/audio/albumart/${song.albumId}')
            : null,
      ));
      _broadcastPlaybackState();
    } catch (e, s) {
      // Arquivo inválido/corrompido ou falha de plataforma (inclui canal
      // nativo morto): nunca crash — loga e expõe para a UI.
      ErrorLogService.logSync('audio/playSong', e, s);
      status.value = PlayerStatus.idle;
      errorMessage.value = 'Falha ao reproduzir "${song.title}": $e';
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
      errorMessage.value = 'Falha ao pausar: $e';
    }
  }

  /// Retoma de onde parou.
  Future<void> resume() async {
    try {
      await _player.resume();
    } catch (e, s) {
      ErrorLogService.logSync('audio/resume', e, s);
      errorMessage.value = 'Falha ao retomar: $e';
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
      errorMessage.value = 'Falha ao parar: $e';
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
      errorMessage.value = 'Falha ao buscar posição: $e';
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
