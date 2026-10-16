import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../models/repeat_mode.dart';
import '../models/song_model.dart';
import 'error_log_service.dart';
import 'notification_art_cache.dart';

/// Estados de reprodução expostos para a UI (abstração sobre PlayerState).
enum PlayerStatus { idle, playing, paused, stopped, completed }

/// Modos do timer de sono (item 3.1).
///
/// - [off]: desligado.
/// - [duration]: dispara quando o relógio passa do prazo (parede — segue
///   mesmo com a faixa pausada; coerente com os sleep timers do mercado).
/// - [trackEnd]: "ao fim da faixa" — dispara quando a faixa corrente
///   termina, sem avançar a fila (o [PlayerProvider] pergunta ao serviço
///   antes de pular para a próxima).
enum SleepTimerMode { off, duration, trackEnd }

/// Camada de serviço de áudio.
///
/// Responsabilidade: isolar TODA a lógica do `AudioPlayer` do pacote
/// just_audio em um único lugar. A UI e o Provider nunca tocam no plugin
/// diretamente — conversam apenas com esta classe. (Item 3.0: motor trocado
/// de audioplayers para just_audio — gapless/Equalizer — mantendo esta
/// interface pública estável; ver RELATORIO_3.0.md.)
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

  /// Botões vindos do SISTEMA (Bluetooth/Android Auto/relógio):
  /// repeat/shuffle direto no modo específico (não ciclam) e pular para
  /// um índice da fila publicada. O provider aplica e persiste.
  Future<void> Function(RepeatMode mode)? onSetRepeatMode;
  Future<void> Function(bool enabled)? onSetShuffleMode;
  Future<void> Function(int index)? onSkipToQueueIndex;

  /// Modo de repeat/shuffle APLICADOS no provider — publicados no
  /// [PlaybackState] para o sistema exibir/refletir os botões certos.
  RepeatMode _publishedRepeat = RepeatMode.off;
  bool _publishedShuffle = false;

  /// Índice da faixa corrente na fila publicada (null = nada selecionado).
  int? _publishedQueueIndex;

  /// Fila publicada por último (identidade da lista) — evita reenviar a
  /// fila inteira ao MediaSession a cada troca de faixa.
  List<Song>? _publishedQueue;

  /// Velocidade de reprodução publicada no [PlaybackState] (1.0 =
  /// normal). Item 3.2: mutable via [setPlaybackSpeed] (0,5–2,0).
  double _speed = 1.0;

  /// Relógio injetável (testes: sem fakeAsync, controlamos o tempo na mão).
  final DateTime Function() _clock;

  /// Último broadcast efetivo — throttle do tick de posição (1x/s).
  DateTime _lastBroadcast = DateTime.fromMillisecondsSinceEpoch(0);

  // ---------------------------------------------------------------------
  // Item 3.1 — timer de sono (o estado vive AQUI, não em widget: sobrevive
  // ao app em segundo plano, é cancelado por [stop] e exposto para a UI
  // ler o tempo restante quando quiser).
  // ---------------------------------------------------------------------

  /// Janela do fade-out final ([sleepFadeDuration]) antes do disparo.
  static const Duration sleepFadeDuration = Duration(seconds: 10);

  /// Volume corrente (1.0 = normal). Notifier para a UI/teste; o valor é
  /// espelhado no just_audio via [_applyVolume].
  final ValueNotifier<double> volume = ValueNotifier<double>(1.0);

  /// Modo ativo do timer (off = desligado).
  SleepTimerMode _sleepMode = SleepTimerMode.off;

  /// Prazo absoluto (relógio injetado) quando [_sleepMode] é duration.
  DateTime? _sleepDeadline;

  /// Guarda de reentrada: [_expireSleep] chama [stop], que pode gerar
  /// novos eventos de stream que voltam a checar o timer.
  bool _sleepExpiring = false;

  /// Intervalo mínimo entre broadcasts gerados pelo TICK DE POSIÇÃO.
  /// Mudanças de estado (play/pause/seek/troca de faixa) continuam
  /// broadcast imediato — o throttle cobre só o tick de posição
  /// (positionStream do just_audio: até ~5x/s), que enchia o canal
  /// nativo sem necessidade (o sistema projeta a posição a partir de
  /// updatePosition + updateTime).
  static const Duration broadcastInterval = Duration(seconds: 1);

  /// Fila do provider → MediaSession (Android Auto/Bluetooth/browse).
  ///
  /// A fila é enviada APENAS quando a lista muda de identidade (troca de
  /// faixa/index não reenvia — só atualiza o índice via [PlaybackState]).
  /// Entradas ficam sem capa de propósito: gravar a capa de milhares de
  /// faixas em disco a cada publicação é I/O proibido; a capa da faixa
  /// corrente continua na notificação via [mediaItem].
  void publishQueue(List<Song> songs, int currentIndex) {
    try {
      if (!identical(_publishedQueue, songs)) {
        _publishedQueue = songs;
        queue.add(<MediaItem>[
          for (final Song song in songs)
            MediaItem(
              id: song.id,
              title: song.title,
              artist: song.displayArtist,
              album: song.album,
              duration: song.duration,
            ),
        ]);
      }
      _publishedQueueIndex =
          (currentIndex < 0 || currentIndex >= songs.length) ? null : currentIndex;
      broadcastPlaybackState();
    } catch (e, s) {
      ErrorLogService.logSync('audio/publishQueue', e, s);
    }
  }

  /// Publica os modos repeat/shuffle aplicados pelo provider (chamar após
  /// QUALQUER mudança de modo — inclusive a vinda do próprio sistema).
  void syncModes({required RepeatMode repeat, required bool shuffle}) {
    try {
      _publishedRepeat = repeat;
      _publishedShuffle = shuffle;
      broadcastPlaybackState();
    } catch (e, s) {
      ErrorLogService.logSync('audio/syncModes', e, s);
    }
  }

  /// Mapeamento PURO: modo do app → enum do audio_service
  /// (publicado no PlaybackState; é o que o sistema lê).
  static AudioServiceRepeatMode systemRepeatMode(RepeatMode mode) =>
      switch (mode) {
        RepeatMode.off => AudioServiceRepeatMode.none,
        RepeatMode.all => AudioServiceRepeatMode.all,
        RepeatMode.one => AudioServiceRepeatMode.one,
      };

  /// Mapeamento PURO inverso: comando do sistema → modo do app.
  /// `group` (não implementado pelo audio_service) cai em `off`.
  static RepeatMode appRepeatMode(AudioServiceRepeatMode mode) =>
      switch (mode) {
        AudioServiceRepeatMode.one => RepeatMode.one,
        AudioServiceRepeatMode.all => RepeatMode.all,
        _ => RepeatMode.off, // none e group
      };

  /// Mapeamento PURO: shuffle do app → enum do audio_service.
  static AudioServiceShuffleMode systemShuffleMode(bool enabled) =>
      enabled ? AudioServiceShuffleMode.all : AudioServiceShuffleMode.none;

  /// Mapeamento PURO: estado interno → processingState publicado
  /// (o sistema depende de `completed` para mostrar "repetir" na UI).
  static AudioProcessingState systemProcessingState(PlayerStatus status) =>
      switch (status) {
        PlayerStatus.idle => AudioProcessingState.idle,
        PlayerStatus.completed => AudioProcessingState.completed,
        _ => AudioProcessingState.ready,
      };

  /// Chamado quando uma faixa FALHOU ao abrir (arquivo apagado/corrompido,
  /// canal nativo morto...). O [PlayerProvider] decide se pula para a
  /// próxima — com limite de falhas seguidas para não entrar em loop.
  Future<void> Function(Song song)? onPlaybackFailed;

  /// Leitura ao vivo da preferência "pausar ao desconectar fones"
  /// ([SettingsProvider.pauseOnNoisy]). É um getter (não bool) para
  /// refletir mudanças feitas em Configurações sem recriar o serviço.
  /// Nulo = padrão (ligado).
  bool Function()? pauseOnNoisyEnabled;

  /// Item 3.1: notificado quando o timer de sono DISPARA sozinho (o
  /// provider reemite a UI mesmo sem mudança de status — ex.: expiração
  /// com a faixa já parada, em que o chip sumiria sem rebuild).
  VoidCallback? onSleepTimerChanged;

  /// Tipo da interrupção que pausou a reprodução (null = nenhuma).
  ///
  /// Diferencia PERDA TEMPORÁRIA (ligação/notificação -> retoma sozinho)
  /// de PERDA PERMANENTE (outro app assumiu o áudio -> NÃO retoma).
  AudioInterruptionType? _interruptionPause;

  AudioService({
    this.degradedMode = false,
    this.pauseOnNoisyEnabled,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    _configureAudioSession();

    // Subscrições nos streams nativos do plugin. Guardamos cada uma na
    // lista para cancelar em [dispose] — regra de ouro contra leaks.
    // Cada mudança relevante também reemite o playbackState do
    // audio_service para manter a notificação/tela de bloqueio sincronizadas.
    // Os corpos são blindados: uma exceção DENTRO de um callback de stream
    // escapa para a zona e derrubaria o app — agora vira log local.
    // (just_audio: positionStream é timer Dart de 16–200ms só enquanto toca;
    // playerStateStream cobre playing+processingState — completed incluso.)
    _subscriptions.addAll(<StreamSubscription<dynamic>>[
      _player.positionStream.listen((Duration newPosition) {
        try {
          // Item 3.1: o tick do posicionador é o "relógio de eventos" do
          // timer de sono enquanto toca (a checagem é por relógio injetado,
          // não pela posição). No-op barato quando o timer está off.
          unawaited(checkSleepTimer());
          // Só ticks de reprodução: o just_audio re-emite a posição ATUAL
          // no primeiro listen (replay, chega assíncrona) e não emite com
          // o player parado — aceitar fora de `playing` setaria posição e
          // abriria o throttle do broadcast à toa no boot (contrato do
          // teste de throttle).
          if (status.value != PlayerStatus.playing) return;
          if (position.value == newPosition) return;
          position.value = newPosition;
          // Tick de posição: broadcast com throttle (1x/s) — ver
          // [broadcastInterval]. O sistema projeta o avanço real a partir
          // de updatePosition/updateTime, então não precisa de tick.
          broadcastPlaybackState(throttled: true);
        } catch (e, s) {
          ErrorLogService.logSync('audio/onPosition', e, s);
        }
      }),
      _player.durationStream.listen((Duration? newDuration) {
        try {
          duration.value = newDuration ?? Duration.zero;
        } catch (e, s) {
          ErrorLogService.logSync('audio/onDuration', e, s);
        }
      }),
      _player.playerStateStream.listen((PlayerState state) {
        try {
          // Item 3.1: qualquer mudança de estado é evento para checar o
          // timer (cobre retomada/buffering — a expiração é por relógio de
          // parede e precisa de um gatilho para disparar com o player
          // parado).
          unawaited(checkSleepTimer());
          final PlayerStatus before = status.value;
          _mapPlayerState(state);
          // Guarda: o just_audio re-emite o estado ATUAL no primeiro
          // listen (replay) — sem checar mudança, o boot publicaria
          // PlaybackState à toa e o throttle sairia aberto cedo (contrato
          // do teste de throttle: 1 emissão por intervalo).
          if (status.value != before) {
            broadcastPlaybackState();
          }
        } catch (e, s) {
          ErrorLogService.logSync('audio/onState', e, s);
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
  ///
  /// just_audio expõe (playing, processingState) ortogonais: o fim da faixa
  /// é `processingState == completed` (antes era um evento à parte do
  /// audioplayers); idle recém-construído vira [PlayerStatus.idle] para o
  /// systemProcessingState continuar publicando `idle` no boot.
  void _mapPlayerState(PlayerState state) {
    switch (state.processingState) {
      case ProcessingState.completed:
        status.value = PlayerStatus.completed;
      case ProcessingState.idle:
        status.value = PlayerStatus.idle;
      case ProcessingState.loading:
      case ProcessingState.buffering:
      case ProcessingState.ready:
        status.value = state.playing ? PlayerStatus.playing : PlayerStatus.paused;
    }
  }

  /// Reproduz uma faixa do catálogo.
  ///
  /// Estratégia para troca rápida de música: `stop()` primeiro (cancela a
  /// faixa anterior e libera recursos), só então seta a nova fonte. Sem
  /// isso, duas reproduções podem sobrepor-se no mesmo player.
  ///
  /// Fonte conforme a origem: assets usam `AudioSource.asset`; faixas do
  /// aparelho usam `AudioSource.uri` com o caminho absoluto do arquivo.
  /// (just_audio carrega no `setAudioSource` — falha de arquivo lança aqui,
  /// alimentando o mesmo catch de antes: mensagem amigável + skip 1.7.)
  Future<void> playSong(Song song) async {
    try {
      _currentSong = song;
      errorMessage.value = null;
      await _player.stop();

      final AudioSource source = song.isAsset
          ? AudioSource.asset(song.assetKey!)
          : AudioSource.uri(Uri.file(song.filePath!));
      await _player.setAudioSource(source);
      await _player.play();

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
      broadcastPlaybackState();
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
  ///
  /// (just_audio: o método de retomar é `play()`; a fonte continua carregada
  /// após `pause()`, então a posição é preservada.)
  Future<void> resume() async {
    try {
      // Item 3.1: se o prazo do timer de sono já passou (ex.: faixa
      // pausada durante o cronômetro), a retomada dispara o fade/stop em
      // vez de começar a tocar de novo.
      if (await checkSleepTimer()) return;
      await _player.play();
    } catch (e, s) {
      ErrorLogService.logSync('audio/resume', e, s);
      errorMessage.value = userMessage('retomar a reprodução', e);
    }
  }

  /// Para a reprodução e volta o cursor para o início.
  ///
  /// Item 3.1: também CANCELA o timer de sono (stop explícito do usuário/
  /// sistema desliga o cronômetro) e restaura o volume, caso o fade-out
  /// tenha sido interrompido no meio.
  @override
  Future<void> stop() async {
    _interruptionPause = null;
    _sleepMode = SleepTimerMode.off;
    _sleepDeadline = null;
    try {
      await _player.stop();
      // O stop do just_audio NÃO zera o cursor (o do audioplayers zerava):
      // seek explícito para a próxima retomada começar no início, como
      // documentado.
      await _player.seek(Duration.zero);
    } catch (e, s) {
      ErrorLogService.logSync('audio/stop', e, s);
      errorMessage.value = userMessage('parar a reprodução', e);
    } finally {
      status.value = PlayerStatus.idle;
      position.value = Duration.zero;
      // Republica o estado final (tudo parado) — o stream do just_audio
      // pode não emitir aqui (sem mudança percebida) e a notificação não
      // pode ficar mostrando "tocando".
      broadcastPlaybackState();
      // Item 3.1: fade interrompido → próxima escuta começa em volume 1.0.
      await _applyVolume(1.0);
      // Notifica o audio_service: processa o stop (remove controles e,
      // no Android, permite encerrar o foreground service limpo — cobre
      // o caso de o usuário deslizar o app fora dos recentes).
      await super.stop();
    }
  }

  // ---------------------------------------------------------------------
  // Item 3.1 — timer de sono: API do serviço.
  //
  // Design: o prazo é um deadline de RELÓGIO DE PAREDE (relógio injetável,
  // testável sem fakeAsync) e a checagem é EVENT-DRIVEN nos listeners
  // (tick de posição, mudança de estado, retomada). Isso mantém o timer
  // vivo em segundo plano (Dart timers continuam sob o foreground service)
  // sem depender de Timer.periodic de minutos reais em teste.
  // ---------------------------------------------------------------------

  /// Modo atual do timer (para a UI marcar a opção ativa).
  SleepTimerMode get sleepMode => _sleepMode;

  /// True quando há um sono agendado ([duration] ou [trackEnd]).
  bool get sleepTimerActive => _sleepMode != SleepTimerMode.off;

  /// Tempo restante do modo [SleepTimerMode.duration].
  ///
  /// Calculado a cada leitura pelo relógio injetado — a UI mostra o valor
  /// certo mesmo sem tick de posição (ex.: faixa pausada).
  Duration get sleepRemaining {
    final DateTime? deadline = _sleepDeadline;
    if (_sleepMode != SleepTimerMode.duration || deadline == null) {
      return Duration.zero;
    }
    final Duration left = deadline.difference(_clock());
    return left.isNegative ? Duration.zero : left;
  }

  /// Agenda o sono por [duration] a partir de agora (sobrescreve o anterior).
  void startSleepTimer(Duration duration) {
    try {
      _sleepMode = SleepTimerMode.duration;
      _sleepDeadline = _clock().add(duration);
      if (duration <= Duration.zero) {
        // Prazo já vencido: dispara imediatamente (sem esperar evento).
        unawaited(checkSleepTimer());
      }
    } catch (e, s) {
      ErrorLogService.logSync('audio/sleepStart', e, s);
    }
  }

  /// Agenda o sono para o FIM da faixa corrente (sem avançar a fila —
  /// o [PlayerProvider] consome o evento via [consumeSleepAtTrackEnd]).
  void startSleepAtTrackEnd() {
    try {
      _sleepMode = SleepTimerMode.trackEnd;
      _sleepDeadline = null;
    } catch (e, s) {
      ErrorLogService.logSync('audio/sleepTrackEnd', e, s);
    }
  }

  /// Cancela o timer sem parar a reprodução; restaura o volume se o
  /// fade já tivesse começado.
  void cancelSleepTimer() {
    try {
      _sleepMode = SleepTimerMode.off;
      _sleepDeadline = null;
      unawaited(_applyVolume(1.0));
    } catch (e, s) {
      ErrorLogService.logSync('audio/sleepCancel', e, s);
    }
  }

  /// Item 3.1 — "ao fim da faixa": chamado pelo [PlayerProvider] quando a
  /// faixa termina. Retorna `true` se o timer consumiu o evento (para o
  /// provider NÃO avançar a fila) e agenda o stop; `false` caso contrário.
  bool consumeSleepAtTrackEnd() {
    if (_sleepMode != SleepTimerMode.trackEnd) return false;
    unawaited(_expireSleep());
    return true;
  }

  /// Checagem do timer de sono (relógio injetado). Retorna `true` quando
  /// o prazo venceu e o fade/stop já foram disparados.
  ///
  /// Chamada pelos listeners de posição/estado e pela [resume]; em teste é
  /// chamada direto após avançar o relógio.
  Future<bool> checkSleepTimer() async {
    try {
      if (_sleepMode != SleepTimerMode.duration) return false;
      final DateTime? deadline = _sleepDeadline;
      if (deadline == null) return false;
      final DateTime now = _clock();
      if (!now.isBefore(deadline)) {
        await _expireSleep();
        return true;
      }
      // Últimos [sleepFadeDuration]: rampa linear 1.0 → 0.0.
      final Duration left = deadline.difference(now);
      if (left <= sleepFadeDuration) {
        final double target =
            (left.inMilliseconds / sleepFadeDuration.inMilliseconds)
                .clamp(0.0, 1.0)
                .toDouble();
        await _applyVolume(target);
      }
      return false;
    } catch (e, s) {
      ErrorLogService.logSync('audio/sleepCheck', e, s);
      return false;
    }
  }

  /// Dispara o sono: limpa o estado, PARA a reprodução (cancela e restaura
  /// o volume via [stop]) e garante volume 1.0 para a próxima escuta.
  Future<void> _expireSleep() async {
    if (_sleepExpiring) return;
    _sleepExpiring = true;
    try {
      _sleepMode = SleepTimerMode.off;
      _sleepDeadline = null;
      await stop();
      await _applyVolume(1.0);
      onSleepTimerChanged?.call();
    } catch (e, s) {
      ErrorLogService.logSync('audio/sleepExpire', e, s);
    } finally {
      _sleepExpiring = false;
    }
  }

  /// Espelha o volume no notifier da UI e no just_audio (guardado:
  /// fade a cada tick não deve gerar chamada de canal sem mudança).
  Future<void> _applyVolume(double value) async {
    if (volume.value == value) return;
    volume.value = value;
    try {
      await _player.setVolume(value);
    } catch (e, s) {
      ErrorLogService.logSync('audio/setVolume', e, s);
    }
  }

  /// Busca (seek) para uma posição específica.
  @override
  Future<void> seek(Duration target) async {
    try {
      await _player.seek(target);
      position.value = target;
      broadcastPlaybackState();
    } catch (e, s) {
      ErrorLogService.logSync('audio/seek', e, s);
      errorMessage.value = userMessage('mudar a posição da faixa', e);
    }
  }

  /// Velocidade de reprodução corrente (1.0 = normal).
  double get playbackSpeed => _speed;

  /// Item 3.2 — velocidade de reprodução (0,5x–2,0x).
  ///
  /// O clamp vive AQUI (camada de serviço): o valor publicado no
  /// [PlaybackState].speed e o aplicado no just_audio são o mesmo número.
  /// O just_audio reaplica speed/volume ao reativar a plataforma
  /// (setAudioSource), então a velocidade sobrevive a trocas de faixa
  /// sem reenvio explícito.
  Future<void> setPlaybackSpeed(double value) async {
    try {
      _speed = value.clamp(0.5, 2.0).toDouble();
      await _player.setSpeed(_speed);
      // Estado muda → broadcast imediato (não throttle): a notificação e
      // a tela de bloqueio refletem o novo rate na hora.
      broadcastPlaybackState();
    } catch (e, s) {
      ErrorLogService.logSync('audio/setSpeed', e, s);
      errorMessage.value = userMessage('mudar a velocidade', e);
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

  /// Comando direto de repeat do sistema (Bluetooth/Android Auto):
  /// delega ao provider, que aplica NA FILA e persiste a preferência.
  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    try {
      await onSetRepeatMode?.call(appRepeatMode(repeatMode));
    } catch (e, s) {
      ErrorLogService.logSync('audio/setRepeatMode', e, s);
    }
  }

  /// Comando direto de shuffle do sistema: idem [setRepeatMode].
  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    try {
      await onSetShuffleMode
          ?.call(shuffleMode != AudioServiceShuffleMode.none);
    } catch (e, s) {
      ErrorLogService.logSync('audio/setShuffleMode', e, s);
    }
  }

  /// Pular para um índice da fila publicada (Android Auto/browse).
  /// Índice fora do intervalo é ignorado no provider — aqui só
  /// protegemos o canal nativo contra throw.
  @override
  Future<void> skipToQueueItem(int index) async {
    try {
      await onSkipToQueueIndex?.call(index);
    } catch (e, s) {
      ErrorLogService.logSync('audio/skipToQueueItem', e, s);
    }
  }

  /// Reemite o estado para o audio_service (notificação + lock screen).
  ///
  /// A lista de controles muda conforme o estado: pausa quando tocando,
  /// play quando pausado. Os compact indices definem os botões visíveis
  /// na notificação compacta (anterior, play/pause, próxima).
  ///
  /// Publica TAMBÉM o que o sistema/Bluetooth/Android Auto precisam ler:
  /// fila corrente, índice dela, modos repeat/shuffle e velocidade —
  /// sem isso o lock screen mostra o estado errado (ex.: repeat aceso
  /// depois de desligar no app).
  ///
  /// [throttled] = true só nos ticks de posição: no máximo 1 emitido por
  /// [broadcastInterval] (relógio injetável). Demais chamadas (play,
  /// pause, seek, troca de faixa, modos) são sempre imediatas — o
  /// sistema não pode ficar com estado velho em mudança de controle.
  void broadcastPlaybackState({bool throttled = false}) {
    try {
      final DateTime now = _clock();
      if (throttled &&
          now.difference(_lastBroadcast) < broadcastInterval) {
        return; // posição nova já será coberta pelo próximo tick
      }
      _lastBroadcast = now;
      final bool playing = status.value == PlayerStatus.playing;
      playbackState.add(PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          playing ? MediaControl.pause : MediaControl.play,
          MediaControl.skipToNext,
          MediaControl.stop,
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.setShuffleMode,
          MediaAction.setRepeatMode,
          MediaAction.skipToQueueItem,
        },
        androidCompactActionIndices: const [0, 1, 2],
        processingState: systemProcessingState(status.value),
        playing: playing,
        updatePosition: position.value,
        // Posição projetada: `position + (now - updateTime)` — o sistema
        // calcula o avanço em tempo real, então o broadcast NÃO precisa de
        // tick por atualização de cursor (o throttle acima é seguro).
        updateTime: now,
        speed: _speed,
        repeatMode: systemRepeatMode(_publishedRepeat),
        shuffleMode: systemShuffleMode(_publishedShuffle),
        queueIndex: _publishedQueueIndex,
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
    volume.dispose(); // item 3.1

    try {
      await _player.dispose();
    } catch (e, s) {
      ErrorLogService.logSync('audio/dispose-player', e, s);
    }
  }
}
