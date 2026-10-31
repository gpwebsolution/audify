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

/// Suporte do APARELHO ao equalizador, checado em runtime (item 3.3).
///
/// - [unknown]: ainda não checado (nunca houve probe nem reprodução);
/// - [supported]: parâmetros lidos com sucesso e há bandas;
/// - [unsupported]: canal falhou/timeout/sem bandas → UI do equalizador
///   desligada com mensagem amigável. Nunca crasha.
enum EqualizerSupport { unknown, supported, unsupported }

/// Estado do equalizador do app (item 3.3): ligado, ganhos por banda (dB),
/// reforço de graves e sua força. Persistido no [SettingsProvider] e
/// replicado no aparelho via [AudioService.applyEqualizerSettings].
class EqualizerSettings {
  const EqualizerSettings({
    this.enabled = false,
    this.bands = const <double>[0, 0, 0, 0, 0],
    this.bassEnabled = false,
    this.bassStrength = 60,
  });

  final bool enabled;
  final List<double> bands;
  final bool bassEnabled;

  /// 0–100; a camada de serviço converte para dB (12 * força / 100).
  final int bassStrength;
}

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
  /// Player just_audio com o equalizador no pipeline (item 3.3). Criado no
  /// construtor ([late]) porque o efeito precisa existir NA CONSTRUÇÃO.
  late final AudioPlayer _player;

  /// Equalizador Android do pipeline (sempre presente; habilitado só
  /// quando o usuário liga na UI — ver [applyEqualizerSettings]).
  final AndroidEqualizer _equalizer = AndroidEqualizer();

  /// Posição atual de reprodução (atualizada ~200ms em tempo real).
  final ValueNotifier<Duration> position = ValueNotifier(Duration.zero);

  /// Duração total da faixa carregada.
  final ValueNotifier<Duration> duration = ValueNotifier(Duration.zero);

  /// Estado do player (playing, paused, stopped, completed...).
  final ValueNotifier<PlayerStatus> status = ValueNotifier(PlayerStatus.idle);

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

  // ---------------------------------------------------------------------
  // Item 6.5 — browse do Android Auto / Bluetooth (MediaBrowser).
  // ---------------------------------------------------------------------

  /// Fontes da biblioteca para o browse — injetadas pelo [PlayerProvider]
  /// (catálogo completo, favoritas e histórico). Null = categorias vazias.
  List<Song> Function()? onBrowseAllSongs;
  List<Song> Function()? onBrowseFavorites;
  List<Song> Function()? onBrowseRecent;

  // ---------------------------------------------------------------------
  // Item 3.4 — gapless e crossfade.
  // ---------------------------------------------------------------------

  /// Notificado quando o PLAYER avança sozinho (gapless) para outro
  /// índice da fila carregada. O [PlayerProvider] sincroniza a
  /// PlaybackQueue/UI sem recarregar — este é o único sinal de
  /// "a faixa X começou" (completed só chega no FIM da fila).
  /// `(index, song)` — o provider valida o id no índice e ignora
  /// eventos espúrios (divergência entre fila publicada e carregada).
  void Function(int index, Song song)? onQueueIndexChanged;

  /// Leitura ao vivo da preferência de crossfade
  /// ([SettingsProvider.crossfadeSeconds]); null ou 0 = desligado.
  /// Getter (não int) para refletir mudanças em Configurações sem
  /// recriar o serviço — mesmo padrão de [pauseOnNoisyEnabled].
  int Function()? crossfadeSeconds;

  /// Leitura ao vivo da preferência "parar o serviço após N minutos
  /// pausado" ([SettingsProvider.stopServicePausedMinutes]); null ou 0
  /// = desativado (padrão da spec: 30 min). Mesmo padrão de
  /// [crossfadeSeconds]: callback para refletir Configurações sem
  /// recriar o serviço.
  int Function()? stopAfterPausedMinutes;

  /// Fila enviada por último em [publishQueue]. Quando contém a faixa
  /// pedida, [playSong] carrega a FILA INTEIRA no player (gapless) em
  /// vez de uma fonte única. A lista nunca é mutada in-place pelo
  /// provider (rebuild/setQueue sempre trocam a identidade).
  List<Song> _queueSnapshot = const <Song>[];

  /// Ids da fila que está CARREGADA no player — comparados com o
  /// snapshot para decidir entre seek (skip sem recarga) e
  /// [AudioPlayer.setAudioSources] (fila nova).
  List<String> _loadedQueueIds = const <String>[];

  /// Índice conhecido do player — dedupe do replay do
  /// `currentIndexStream` e das recargas feitas pelo próprio serviço.
  int? _lastPlayerIndex;

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

  // ---------------------------------------------------------------------
  // Item 3.3 — equalizador + reforço de graves.
  //
  // O efeito mora no pipeline do just_audio e a checagem de capacidade é
  // em RUNTIME: sem plataforma ativa, `parameters` não existe; o probe
  // ativa a plataforma com uma fonte vazia (nada toca) e, se qualquer
  // chamada falhar (canal morto, aparelho sem efeito, timeout), o estado
  // vira [EqualizerSupport.unsupported] + log — UI desligada, sem crash.
  // ---------------------------------------------------------------------

  /// Frequência central das bandas — layout canônico até o probe ler a
  /// real contagem/frequências do aparelho.
  static const List<double> _canonicalBandFrequencies = <double>[
    60,
    230,
    910,
    3600,
    14000,
  ];

  /// Timeout do probe (ativação + leitura de parâmetros). Canal nativo
  /// morto/silencioso vira "não suportado" em vez de pendurar a tela.
  /// Público (configuração): os testes encurtam para não esperar 5s.
  final Duration eqProbeTimeout;

  /// Asset usado APENAS para ativar a plataforma no probe (nunca toca:
  /// o player não chama `play()`); a fonte é limpa ao fim — ver
  /// [_probeParameters].
  static const String _eqProbeAsset = 'assets/songs/relaxing_tone.mp3';

  EqualizerSupport _eqSupport = EqualizerSupport.unknown;

  /// Último estado aplicado/registrado — fonte para (re)aplicar quando a
  /// plataforma fica ativa (a UI é dona do valor; aqui só espelhamos).
  EqualizerSettings _eqSettings = const EqualizerSettings();

  /// Probe em andamento (ou já resolvido) — dedupe de concorrência e
  /// cache do resultado.
  Future<EqualizerSupport>? _eqProbe;

  List<double> _eqBandFrequencies = _canonicalBandFrequencies;

  /// Notifica quando a checagem de suporte termina (a UI lê
  /// [equalizerSupport]). Só o EqualizerProvider registra este callback.
  VoidCallback? onEqualizerSupportChanged;

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

  /// Teto da busca de capa da notificação (item 3.4): além dele o
  /// mediaItem sai SEM capa — arte nunca atrasa a reprodução.
  static const Duration _mediaArtTimeout = Duration(seconds: 2);

  /// Fila do provider → MediaSession (Android Auto/Bluetooth/browse).
  ///
  /// A fila é enviada APENAS quando a lista muda de identidade (troca de
  /// faixa/index não reenvia — só atualiza o índice via [PlaybackState]).
  /// Entradas ficam sem capa de propósito: gravar a capa de milhares de
  /// faixas em disco a cada publicação é I/O proibido; a capa da faixa
  /// corrente continua na notificação via [mediaItem].
  void publishQueue(List<Song> songs, int currentIndex) {
    try {
      // Item 3.4: o snapshot alimenta o gapless do [playSong] — guardado
      // SEMPRE (mesmo com a lista idêntica, o índice abaixo muda).
      _queueSnapshot = songs;
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
      _publishedQueueIndex = (currentIndex < 0 || currentIndex >= songs.length)
          ? null
          : currentIndex;
      broadcastPlaybackState();
    } catch (e, s) {
      ErrorLogService.logSync('audio/publishQueue', e, s);
    }
  }

  /// Publica os modos repeat/shuffle aplicados pelo provider (chamar após
  /// QUALQUER mudança de modo — inclusive a vinda do próprio sistema).
  ///
  /// Item 3.4: o repeat também é aplicado no player como modos NATIVOS
  /// (gapless: a fila carregada avança/repete sem intervalo). A
  /// [PlaybackQueue] continua sendo a fonte da verdade — aqui só
  /// espelhamos o que ela decidiu.
  void syncModes({required RepeatMode repeat, required bool shuffle}) {
    try {
      _publishedRepeat = repeat;
      _publishedShuffle = shuffle;
      unawaited(
        _player
            .setLoopMode(switch (repeat) {
              RepeatMode.off => LoopMode.off,
              RepeatMode.all => LoopMode.all,
              RepeatMode.one => LoopMode.one,
            })
            .catchError((Object e, StackTrace s) {
              ErrorLogService.logSync('audio/setLoopMode', e, s);
            }),
      );
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
    this.crossfadeSeconds,
    this.stopAfterPausedMinutes,
    this.eqProbeTimeout = const Duration(seconds: 5),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    // Item 3.3: pipeline com o equalizador — precisa ser o PRIMEIRO passo
    // do corpo (os listeners abaixo já usam o player).
    _player = AudioPlayer(
      audioPipeline: AudioPipeline(
        androidAudioEffects: <AndroidAudioEffect>[_equalizer],
      ),
    );
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
          // Item 3.4: o crossfade é regulado por posição (fade-in nos
          // primeiros X s / fade-out nos últimos X s) — ver
          // [tickCrossfade].
          unawaited(tickCrossfade());
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
            // Item 5.2: virou pausado agenda o encerramento automático;
            // saiu da pausa (tocou/parou) cancela.
            _syncPausedStop(before);
            broadcastPlaybackState();
          }
        } catch (e, s) {
          ErrorLogService.logSync('audio/onState', e, s);
        }
      }),
      // Item 3.4 — gapless: com a fila inteira carregada, o player
      // avança SOZINHO para a próxima faixa e o índice muda sem passar
      // por `completed` (este só chega no fim da fila). Guarda contra o
      // replay do stream e contra eventos sem fila carregada.
      _player.currentIndexStream.listen((int? index) {
        try {
          if (index == null) return;
          if (index == _lastPlayerIndex) return;
          if (_loadedQueueIds.isEmpty) return;
          _lastPlayerIndex = index;
          unawaited(_onPlayerIndexChanged(index));
        } catch (e, s) {
          ErrorLogService.logSync('audio/onQueueIndex', e, s);
        }
      }),
      // Item 3.4 — falha de arquivo DURANTE a reprodução da playlist:
      // o plugin emite PlayerException com o índice da faixa morta; o
      // provider decide o skip (mesmo callback/critério do playSong).
      _player.errorStream.listen(
        (PlayerException error) {
          try {
            final int? idx = error.index;
            final Song? failed =
                (idx != null && idx >= 0 && idx < _queueSnapshot.length)
                ? _queueSnapshot[idx]
                : _currentSong;
            if (failed == null) return;
            status.value = PlayerStatus.idle;
            errorMessage.value = userMessage('tocar "${failed.title}"', error);
            unawaited(_notifyPlaybackFailed(failed));
          } catch (e, s) {
            ErrorLogService.logSync('audio/onPlayerError', e, s);
          }
        },
        onError: (Object e, StackTrace s) =>
            ErrorLogService.logSync('audio/errorStream', e, s),
      ),
    ]);
  }

  /// Fallback do boot: quando `AudioService.init` falha (canal nativo
  /// indisponível pós-crash do processo), o app abre mesmo assim —
  /// apenas sem notificação de mídia/tela de bloqueio.
  factory AudioService.noop() {
    debugPrint(
      '[AudioService] Modo degradado: sem MediaSession/segundo plano.',
    );
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
            _interruptionPause = wasPlaying
                ? AudioInterruptionType.pause
                : null;
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
  }) => isPlaying && settingEnabled;

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
        status.value = state.playing
            ? PlayerStatus.playing
            : PlayerStatus.paused;
    }
  }

  // ---------------------------------------------------------------------
  // Item 3.4 — gapless: helpers de fila/carregamento.
  // ---------------------------------------------------------------------

  /// Fonte de áudio de uma faixa (asset x arquivo do aparelho).
  static AudioSource _sourceFor(Song song) => song.isAsset
      ? AudioSource.asset(song.assetKey!)
      : AudioSource.uri(Uri.file(song.filePath!));

  static List<String> _idsOf(List<Song> songs) => <String>[
    for (final Song s in songs) s.id,
  ];

  /// True quando os ids carregados são EXATAMENTE os da fila atual —
  /// mesma ordem/tamanho (aí um novo playSong vira seek, sem recarga).
  static bool _sameQueue(List<String> loaded, List<Song> snapshot) {
    if (loaded.length != snapshot.length) return false;
    for (int i = 0; i < loaded.length; i++) {
      if (loaded[i] != snapshot[i].id) return false;
    }
    return true;
  }

  /// Item 3.4: o player mudou de índice SOZINHO (transição gapless).
  /// Atualiza o estado do serviço (faixa/notificação) e notifica o
  /// provider — sem recarregar nada.
  Future<void> _onPlayerIndexChanged(int index) async {
    final List<Song> snap = _queueSnapshot;
    if (index < 0 || index >= snap.length) return;
    final Song song = snap[index];
    _currentSong = song;
    _publishedQueueIndex = index;
    await _updateMediaItem(song);
    broadcastPlaybackState();
    onQueueIndexChanged?.call(index, song);
  }

  /// Notificação/tela de bloqueio acompanham a faixa (capa via cache em
  /// disco — assíncrono com guarda de erro). O [_mediaArtTimeout] limita
  /// a capa: notificação/capa NUNCA podem atrasar a reprodução (disco
  /// cheio, canal nativo lento); sem arte a UI usa o fallback.
  Future<void> _updateMediaItem(Song song) async {
    try {
      final Uri? artUri = await NotificationArtCache.uriFor(
        song,
      ).timeout(_mediaArtTimeout);
      mediaItem.add(
        MediaItem(
          id: song.id,
          title: song.title,
          artist: song.displayArtist,
          album: song.album,
          duration: song.duration,
          artUri: artUri,
        ),
      );
    } catch (e, s) {
      // Timeout/falha: notifica SEM capa em vez de travar o playSong.
      ErrorLogService.logSync('audio/mediaItem', e, s);
      mediaItem.add(
        MediaItem(
          id: song.id,
          title: song.title,
          artist: song.displayArtist,
          album: song.album,
          duration: song.duration,
        ),
      );
    }
  }

  /// Encaminha a falha para o provider (que decide o skip, com teto de
  /// falhas seguidas). Guardado: um throw aqui escaparia para a zona.
  Future<void> _notifyPlaybackFailed(Song failed) async {
    try {
      await onPlaybackFailed?.call(failed);
    } catch (e, s) {
      ErrorLogService.logSync('audio/onPlaybackFailed', e, s);
    }
  }

  // ---------------------------------------------------------------------
  // Item 3.4 — crossfade (fade de volume por posição, 0–12 s).
  //
  // Sem sobreposição de áudio (1 player): fade-out nos últimos X s da
  // faixa + fade-in nos primeiros X s da próxima — a troca é a própria
  // transição gapless. O sono (item 3.1) tem PRIORIDADE: com timer
  // ativo o crossfade não atua para os dois fades brigarem pelo volume.
  // ---------------------------------------------------------------------

  /// Fator de volume do crossfade no instante [position] (1.0 = sem
  /// efeito, 0.0 = mudo). Função pura — testável sem player: fade-in
  /// nos primeiros [crossfadeSeconds] s e fade-out nos últimos; o menor
  /// dos dois manda (o meio da faixa toca em volume normal e faixas
  /// mais curtas que o crossfade fazem um "triângulo" suave).
  static double crossfadeVolumeFactor(
    Duration position,
    Duration duration,
    int crossfadeSeconds,
  ) {
    if (crossfadeSeconds <= 0) return 1.0;
    if (duration <= Duration.zero) return 1.0;
    final int cfMs = crossfadeSeconds * 1000;
    final int posMs = position.inMilliseconds;
    final int remainingMs = duration.inMilliseconds - posMs;
    final double fadeIn = (posMs / cfMs).clamp(0.0, 1.0).toDouble();
    final double fadeOut = (remainingMs / cfMs).clamp(0.0, 1.0).toDouble();
    return fadeIn < fadeOut ? fadeIn : fadeOut;
  }

  /// Aplica o fator do crossfade no tick de posição (o [_applyVolume]
  /// tem guarda de mudança — ticks em volume normal não tocam canal).
  /// `@visibleForTesting`: os testes disparam o fade de forma
  /// determinística (sem depender do timer de posição do just_audio).
  @visibleForTesting
  Future<void> tickCrossfade() async {
    try {
      // Sono ativo: o fade do timer manda (regra de prioridade).
      if (_sleepMode != SleepTimerMode.off) return;
      final int cf = crossfadeSeconds?.call() ?? 0;
      if (cf <= 0) {
        // Desligado/depois de uma janela: retorna à base.
        await _applyVolume(1.0);
        return;
      }
      if (status.value != PlayerStatus.playing) {
        // Pausado/fim: sai da janela (retomada corrige no próximo tick).
        await _applyVolume(1.0);
        return;
      }
      final double factor = crossfadeVolumeFactor(
        position.value,
        duration.value,
        cf,
      );
      await _applyVolume(factor);
    } catch (e, s) {
      ErrorLogService.logSync('audio/crossfade', e, s);
    }
  }

  /// Reproduz uma faixa do catálogo.
  ///
  /// Toca uma faixa do catálogo posicionando-a na fila publicada.
  ///
  /// Item 3.4 — três caminhos:
  ///  - MESMA fila já carregada: só `seek` (gapless, sem recarga);
  ///  - fila publicada nova/diferente: carrega a FILA INTEIRA
  ///    (`setAudioSources`) — o player avança sozinho entre faixas;
  ///  - sem fila publicada: fonte única (serviço isolado).
  ///
  /// [startAt] — posição inicial (item 3.5: a recarga pós-EDIÇÃO da
  /// fila preserva onde a faixa estava; o toque normal do usuário vem
  /// com o padrão zero, ou seja, do início).
  ///
  /// Falha de arquivo/alvo continua no mesmo catch de antes: mensagem
  /// amigável + skip 1.7 (via `onPlaybackFailed`).
  Future<void> playSong(Song song, {Duration startAt = Duration.zero}) async {
    try {
      _currentSong = song;
      errorMessage.value = null;

      final List<Song> snap = _queueSnapshot;
      final int snapIdx = snap.indexWhere((Song s) => s.id == song.id);

      if (snapIdx >= 0 && _sameQueue(_loadedQueueIds, snap)) {
        // Mesma fila já carregada (skip manual, replay, troca de faixa
        // dentro da mesma fila): só REPOSICIONA — gapless, sem recarga
        // e sem o corte de stop → setAudioSource antigo.
        _lastPlayerIndex = snapIdx;
        await _player.seek(startAt, index: snapIdx);
        if (!_player.playing) await _player.play();
      } else if (snapIdx >= 0) {
        // Fila nova (primeira carga, shuffle/rebuild, repeat mudou,
        // edição da fila do item 3.5): carrega a FILA INTEIRA — o
        // player avança sozinho entre faixas (item 3.4).
        await _player.stop();
        await _player.setAudioSources(
          <AudioSource>[for (final Song s in snap) _sourceFor(s)],
          initialIndex: snapIdx,
          initialPosition: startAt,
        );
        _loadedQueueIds = _idsOf(snap);
        _lastPlayerIndex = snapIdx;
        await _player.play();
      } else {
        // Sem fila publicada (serviço usado isolado): fonte única —
        // comportamento antigo.
        await _player.stop();
        await _player.setAudioSources(<AudioSource>[_sourceFor(song)]);
        _loadedQueueIds = <String>[song.id];
        _lastPlayerIndex = 0;
        if (startAt > Duration.zero) await _player.seek(startAt);
        await _player.play();
      }

      // Atualiza a notificação de mídia (título, artista, duração).
      // A capa vem de um ARQUIVO no cache do app (Uri.file) — o
      // content:// legado do albumart falha no Android 10+ e faixa de
      // asset não tinha capa nenhuma. Ver [NotificationArtCache].
      await _updateMediaItem(song);
      broadcastPlaybackState();
      // Item 3.3: com a plataforma ativa agora, o equalizador dá probe
      // (se ainda desconhecido) e o estado persistido vai para o aparelho.
      unawaited(_postPlayEqualizer());
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
        await _notifyPlaybackFailed(song);
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

  // ---------------------------------------------------------------------
  // Item 5.2 — parar o serviço depois de N minutos pausado.
  //
  // Mesmo desenho do timer de sono: deadline de RELÓGIO DE PAREDE com
  // relógio injetável + checagem por tick (Timer.periodic de 1 min,
  // criado só enquanto há prazo agendado). A preferência é lida AO VIVO
  // pelo callback — trocar para 0 (desativado) cancela na próxima
  // checagem. O listener de estado do player chama
  // [schedulePausedStop]/[cancelPausedStop]; em teste eles são chamados
  // direto, como [checkSleepTimer] (contrato documentado do sono).
  // ---------------------------------------------------------------------

  DateTime? _pausedStopDeadline;
  Timer? _pausedStopTicker;

  /// Gatilho do listener de estado: agenda quando a reprodução entra em
  /// pausa e cancela quando sai dela.
  void _syncPausedStop(PlayerStatus before) {
    if (status.value == PlayerStatus.paused && before != PlayerStatus.paused) {
      schedulePausedStop();
    } else if (status.value != PlayerStatus.paused) {
      cancelPausedStop();
    }
  }

  /// Agenda o [stop] para [stopServicePausedMinutes] a partir de agora
  /// (no-op quando a preferência está desativada). Sobrescreve o prazo
  /// anterior.
  void schedulePausedStop() {
    try {
      final int minutes = stopAfterPausedMinutes?.call() ?? 0;
      if (minutes <= 0) return;
      _pausedStopDeadline = _clock().add(Duration(minutes: minutes));
      _pausedStopTicker ??= Timer.periodic(const Duration(minutes: 1), (_) {
        unawaited(checkPausedStop());
      });
    } catch (e, s) {
      ErrorLogService.logSync('audio/pausedStopSchedule', e, s);
    }
  }

  /// Cancela o encerramento agendado (retomada, stop ou dispose).
  void cancelPausedStop() {
    _pausedStopDeadline = null;
    _pausedStopTicker?.cancel();
    _pausedStopTicker = null;
  }

  /// Checagem por relógio injetado. Retorna `true` quando o prazo
  /// venceu e o stop já disparou. Re-lê a preferência a cada chamada:
  /// desativada (0) ou fora da pausa, cancela sem parar o serviço.
  Future<bool> checkPausedStop() async {
    try {
      final DateTime? deadline = _pausedStopDeadline;
      if (deadline == null) return false;
      final int minutes = stopAfterPausedMinutes?.call() ?? 0;
      if (minutes <= 0 || status.value != PlayerStatus.paused) {
        cancelPausedStop();
        return false;
      }
      if (_clock().isBefore(deadline)) return false;
      await stop();
      return true;
    } catch (e, s) {
      ErrorLogService.logSync('audio/pausedStopCheck', e, s);
      return false;
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
      // Item 5.2: stop explícito encerra qualquer encerramento
      // automático que estiver agendado.
      cancelPausedStop();
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
      // Item 3.4 — "ao fim da faixa" com repeat ONE: o player repete a
      // faixa NO NATIVO (LoopMode.one, gapless) e nenhum evento
      // `completed`/transição chega para o provider consumir. Aqui o
      // fim é detectado pela posição (~400 ms do fim, só enquanto
      // toca). Com repeat off/all os eventos normais (fim da fila /
      // transição gapless) continuam consumindo antes, via provider —
      // o consume é one-shot, então um duplo disparo não existe.
      if (_sleepMode == SleepTimerMode.trackEnd &&
          _publishedRepeat == RepeatMode.one &&
          status.value == PlayerStatus.playing &&
          duration.value > Duration.zero &&
          duration.value - position.value <=
              const Duration(milliseconds: 400)) {
        consumeSleepAtTrackEnd(); // agenda fade/stop (one-shot)
        return true;
      }
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

  // ---------------------------------------------------------------------
  // Item 3.3 — equalizador + reforço de graves (runtime-safe)
  // ---------------------------------------------------------------------

  /// Estado da checagem de suporte do aparelho (ver [EqualizerSupport]).
  EqualizerSupport get equalizerSupport => _eqSupport;

  /// Último estado registrado (fonte para reaplicar na ativação).
  EqualizerSettings get equalizerSettings => _eqSettings;

  /// Frequência central das bandas (canônica até o probe; real depois).
  List<double> get equalizerBandFrequencies =>
      List<double>.unmodifiable(_eqBandFrequencies);

  /// Habilitação ATUAL do efeito no player (teste: sem canal nativo).
  @visibleForTesting
  bool get equalizerEffectEnabled => _equalizer.enabled;

  /// Item 3.3 — checa em runtime se o aparelho suporta o equalizador.
  ///
  /// Ativa a plataforma com uma fonte VAZIA (não toca nada) quando nada
  /// foi carregado ainda, lê os parâmetros e aplica o estado registrado.
  /// Falha de qualquer tipo → [EqualizerSupport.unsupported] + log;
  /// resultado é deduplicado/congelado em um único futuro.
  Future<EqualizerSupport> probeEqualizer() => _eqProbe ??= _probeEqualizer();

  Future<EqualizerSupport> _probeEqualizer() async {
    final bool wasIdle = _player.processingState == ProcessingState.idle;
    AudioSource? probeSource;
    try {
      final AndroidEqualizerParameters params = await _probeParameters(
        wasIdle: wasIdle,
        onProbeSource: (AudioSource source) => probeSource = source,
      ).timeout(eqProbeTimeout);
      if (params.bands.isEmpty) {
        _eqSupport = EqualizerSupport.unsupported;
      } else {
        _eqSupport = EqualizerSupport.supported;
        _eqBandFrequencies = List<double>.unmodifiable(
          params.bands.map((AndroidEqualizerBand b) => b.centerFrequency),
        );
        await _applyEqualizerToDevice();
      }
    } catch (e, s) {
      // Canal morto, aparelho sem efeito, timeout — tudo vira
      // "não suportado": a tela só desliga os controles, nunca crasha.
      ErrorLogService.logSync('audio/eqProbe', e, s);
      _eqSupport = EqualizerSupport.unsupported;
    } finally {
      // Só limpa a fonte de probe se ela AINDA é a carregada (identidade
      // checada sem await entre checagem e clear — uma fila iniciada
      // durante o probe já substituiu a fonte e é preservada).
      // Fire-and-forget: o resultado/notify do probe nunca pode ficar
      // preso atrás do clear (playlist pode aguardar sequência própria).
      final AudioSource? source = probeSource;
      if (wasIdle &&
          source != null &&
          _player.audioSources.length == 1 &&
          identical(_player.audioSources.first, source)) {
        unawaited(_clearProbeSource());
      }
    }
    onEqualizerSupportChanged?.call();
    return _eqSupport;
  }

  Future<void> _clearProbeSource() async {
    try {
      await _player.clearAudioSources();
    } catch (e, s) {
      ErrorLogService.logSync('audio/eqProbeClear', e, s);
    }
  }

  /// Lê os parâmetros do equalizador, ativando a plataforma antes (o
  /// just_audio só cria o efeito/ler `parameters` com o player ativo).
  ///
  /// Com o player vazio, `load()` não ativa nada — então carrega um asset
  /// de probe minúsculo SEM tocar. A ativação (init + parâmetros) roda
  /// ANTES do load do arquivo: se o arquivo falhar, os parâmetros podem
  /// já estar válidos (o timeout na chamada ainda decide o suporte).
  Future<AndroidEqualizerParameters> _probeParameters({
    required bool wasIdle,
    required void Function(AudioSource source) onProbeSource,
  }) async {
    if (wasIdle && _player.processingState == ProcessingState.idle) {
      final AudioSource source = AudioSource.asset(_eqProbeAsset);
      onProbeSource(source);
      try {
        await _player.setAudioSources(<AudioSource>[source]);
      } catch (e, s) {
        ErrorLogService.logSync('audio/eqProbeLoad', e, s);
      }
    }
    return _equalizer.parameters;
  }

  /// Item 3.3 — registra/aplica o estado do equalizador.
  ///
  /// Com a plataforma inativa (nada tocado), o `setEnabled` é local (o
  /// just_audio guarda sem chamar o canal) e os ganhos ficam em
  /// [_eqSettings] até o probe/primeira faixa empurrá-los ao aparelho.
  /// Nunca propaga exceção.
  Future<void> applyEqualizerSettings(EqualizerSettings settings) async {
    _eqSettings = _sanitizeEqualizerSettings(settings);
    try {
      await _equalizer.setEnabled(_eqSettings.enabled);
    } catch (e, s) {
      ErrorLogService.logSync('audio/eqEnabled', e, s);
      _markEqualizerUnsupported();
      return;
    }
    if (_eqSupport == EqualizerSupport.supported) {
      await _applyEqualizerToDevice();
    }
  }

  /// Pós-primeira faixa: a plataforma acaba de ativar, então resolve o
  /// probe (se pendente) e sincroniza o estado persistido no aparelho.
  Future<void> _postPlayEqualizer() async {
    try {
      final bool freshProbe = _eqProbe == null;
      final EqualizerSupport support = await probeEqualizer();
      if (support == EqualizerSupport.supported && !freshProbe) {
        await _applyEqualizerToDevice();
      }
    } catch (e, s) {
      ErrorLogService.logSync('audio/eqSync', e, s);
    }
  }

  /// Envia ligar/desligar + ganhos por banda (com o reforço de graves
  /// somado às duas bandas mais graves) para o efeito nativo, com clamp
  /// na faixa real do aparelho. Falha → [EqualizerSupport.unsupported].
  Future<void> _applyEqualizerToDevice() async {
    if (_eqSupport != EqualizerSupport.supported) return;
    final EqualizerSettings s = _eqSettings;
    try {
      // Reenvia o mestre também: entre o apply pré-ativação (local) e o
      // probe pode haver corrida — aqui o canal ESTÁ ativo, então o
      // estado nativo fica determinístico.
      await _equalizer.setEnabled(s.enabled);
      final AndroidEqualizerParameters params = await _equalizer.parameters;
      // Graves: o just_audio não expõe BassBoost — o reforço é um ganho
      // extra (12 dB × força%) somado às bandas 0 e 1 (grave/corpo).
      final double bassDb = s.bassEnabled ? 12.0 * s.bassStrength / 100.0 : 0.0;
      for (int i = 0; i < params.bands.length; i++) {
        final double base = i < s.bands.length ? s.bands[i] : 0.0;
        final double lowShelf = i <= 1 ? bassDb : 0.0;
        final double target = (base + lowShelf)
            .clamp(params.minDecibels, params.maxDecibels)
            .toDouble();
        await params.bands[i].setGain(target);
      }
    } catch (e, s2) {
      ErrorLogService.logSync('audio/eqApply', e, s2);
      _markEqualizerUnsupported();
    }
  }

  /// Congela o resultado do probe como "não suportado" (sem reprobe
  /// infinito) e avisa a UI.
  void _markEqualizerUnsupported() {
    _eqSupport = EqualizerSupport.unsupported;
    _eqProbe ??= Future<EqualizerSupport>.value(EqualizerSupport.unsupported);
    onEqualizerSupportChanged?.call();
  }

  /// Sanitiza o estado vindo da UI/persistência: bandas finitas em
  /// [-15, 15] (tamanho 1–10, senão 5 planas) e força 0–100.
  static EqualizerSettings _sanitizeEqualizerSettings(EqualizerSettings s) {
    final List<double> bands = s.bands.isEmpty || s.bands.length > 10
        ? List<double>.filled(5, 0)
        : s.bands
              .map(
                (double b) =>
                    b.isFinite ? b.clamp(-15.0, 15.0).toDouble() : 0.0,
              )
              .toList(growable: false);
    return EqualizerSettings(
      enabled: s.enabled,
      bands: bands,
      bassEnabled: s.bassEnabled,
      bassStrength: s.bassStrength.clamp(0, 100),
    );
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
      await onSetShuffleMode?.call(shuffleMode != AudioServiceShuffleMode.none);
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

  // ---- Item 6.5 — navegação do MediaBrowser (Auto / Bluetooth) ----

  /// Raiz navegável devolvida pelo nativo (`BROWSABLE_ROOT_ID`) e a raiz
  /// de "recentes" do Android Auto (`RECENT_ROOT_ID`).
  static const String browseRootId = 'root';
  static const String browseRecentRootId = 'recent';

  /// Categorias expostas na raiz (itens browsable, não tocáveis).
  static const String browseAllId = 'cat:all';
  static const String browseFavoritesId = 'cat:favorites';
  static const String browseRecentId = 'cat:recent';

  /// Prefixo dos ids de faixa: `song:<song.id>`.
  static const String browseSongPrefix = 'song:';

  /// Filhos de [parentMediaId]: as 3 categorias na raiz, faixas dentro de
  /// cada categoria. Id desconhecido devolve vazio (o cliente encerra a
  /// navegação) e NUNCA lança — quem chama é o canal nativo.
  @override
  Future<List<MediaItem>> getChildren(
    String parentMediaId, [
    Map<String, dynamic>? options,
  ]) async {
    try {
      switch (parentMediaId) {
        case browseRootId:
          return const <MediaItem>[
            MediaItem(
              id: browseAllId,
              title: 'Todas as faixas',
              playable: false,
            ),
            MediaItem(
              id: browseFavoritesId,
              title: 'Favoritas',
              playable: false,
            ),
            MediaItem(
              id: browseRecentId,
              title: 'Tocadas recentemente',
              playable: false,
            ),
          ];
        case browseRecentRootId:
        case browseRecentId:
          return _browseItems(onBrowseRecent?.call());
        case browseFavoritesId:
          return _browseItems(onBrowseFavorites?.call());
        case browseAllId:
          return _browseItems(onBrowseAllSongs?.call());
        default:
          return const <MediaItem>[];
      }
    } catch (e, s) {
      ErrorLogService.logSync('audio/getChildren', e, s);
      return const <MediaItem>[];
    }
  }

  /// Toca a faixa apontada por [mediaId] (`song:<id>`). Id fora do
  /// catálogo é ignorado (a fila do Auto pode sobreviver a uma recarga
  /// de biblioteca); falha de toque vira log, nunca exceção no canal.
  @override
  Future<void> playFromMediaId(
    String mediaId, [
    Map<String, dynamic>? extras,
  ]) async {
    final Song? song = resolveBrowseSong(mediaId);
    if (song == null) return;
    try {
      await playSong(song);
    } catch (e, s) {
      ErrorLogService.logSync('audio/playFromMediaId', e, s);
    }
  }

  /// Resolve `song:<id>` na fonte de todas as faixas (sem fonte = null).
  /// Público para teste unitário — o toque em si é [playSong].
  Song? resolveBrowseSong(String mediaId) {
    if (!mediaId.startsWith(browseSongPrefix)) return null;
    final String id = mediaId.substring(browseSongPrefix.length);
    for (final Song song in onBrowseAllSongs?.call() ?? const <Song>[]) {
      if (song.id == id) return song;
    }
    return null;
  }

  List<MediaItem> _browseItems(List<Song>? songs) => <MediaItem>[
    for (final Song song in songs ?? const <Song>[])
      MediaItem(
        id: '$browseSongPrefix${song.id}',
        title: song.title,
        artist: song.displayArtist,
        album: song.album,
        duration: song.duration,
      ),
  ];

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
      if (throttled && now.difference(_lastBroadcast) < broadcastInterval) {
        return; // posição nova já será coberta pelo próximo tick
      }
      _lastBroadcast = now;
      final bool playing = status.value == PlayerStatus.playing;
      playbackState.add(
        PlaybackState(
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
        ),
      );
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
    // Item 5.2: nenhum Timer sobrevive ao serviço.
    cancelPausedStop();
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
