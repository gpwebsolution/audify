import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/repeat_mode.dart';
import '../models/song_model.dart';
import '../repositories/session_repository.dart';
import '../repositories/song_repository.dart';
import '../services/audio_service.dart';
import '../services/catalog_snapshot_service.dart';
import '../services/error_log_service.dart';
import '../services/permission_service.dart';
import '../services/playback_history_service.dart';
import '../utils/playback_queue.dart';
import '../utils/text_normalize.dart';
import 'history_provider.dart';
import 'settings_provider.dart';

export '../models/repeat_mode.dart' show RepeatMode;

/// Estado da permissão de acesso às músicas do aparelho.
enum AudioPermissionState { unknown, granted, denied, permanentlyDenied }

/// Modo de agrupamento da aba Música (item 2.2).
///
/// A lógica de chave e o agrupamento memoizado moram no provider
/// ([PlayerProvider.visibleGroups]) porque o recálculo acontece SÓ na
/// origem dos dados; a tela só desenha as linhas (lazy).
enum MusicGroupMode { tracks, album, artist, folder }

/// Um grupo do modo agrupado: chave do cabeçalho + faixas na ordem do
/// catálogo. Imutável na prática — instância compartilhada entre rebuilds
/// enquanto os entrarem do memo não mudarem (item 2.2).
class SongGroup {
  final String key;
  final List<Song> songs;

  const SongGroup({required this.key, required this.songs});
}

/// Gerenciamento de estado central do player.
///
/// Responsabilidade: orquestrar a camada de áudio, o catálogo (MediaStore +
/// assets) e a fila de reprodução, expondo à UI um único modelo consumível
/// via `context.watch<PlayerProvider>()`.
///
/// Fila: a lista "visível" (após busca) é o que a UI mostra — NÃO é a
/// fila de reprodução. A fila ativa só muda quando o usuário toca uma
/// faixa/grupo ([playVisibleAt]/[playQueue]): digitar na busca não
/// reordena nem encolhe a fila em uso (a reprodução continua na mesma
/// ordem, com as mesmas próximas faixas).
class PlayerProvider extends ChangeNotifier {
  final AudioService _audioService;
  final SettingsProvider? settings;
  final SongRepository _songRepository;
  final SessionRepository _sessionRepository;
  final PlaybackQueue _playbackQueue;

  /// Item 4.2 — regra do histórico (contagem por posição).
  final PlaybackHistoryService _history;

  List<Song> _songs = const [];
  List<Song> _visibleSongs = const [];
  String _searchQuery = '';

  // ---- Memoização do modo agrupado (item 2.2) ----
  // A tela recalculava o agrupamento + ordenação O(n log n) a cada build
  // e montava TODOS os tiles (ListView eager). Agora o resultado fica
  // guardado e só invalida quando muda a identidade da lista visível
  // (catálogo/busca) ou o modo.
  MusicGroupMode? _groupsMode;
  List<Song>? _groupsSource;
  List<SongGroup> _groups = const [];
  AudioPermissionState _permission = AudioPermissionState.unknown;

  /// Último instante em que a sessão foi persistida (throttle de 5s).
  DateTime _lastSessionSave = DateTime.fromMillisecondsSinceEpoch(0);

  /// Falhas SEGUIDAS ao abrir faixas (arquivo apagado/corrompido...).
  /// Zerado quando uma faixa abre com sucesso e quando o usuário escolhe
  /// outra faixa na mão — só assim a fila corrompida não gera loop.
  int _consecutivePlayFailures = 0;

  /// Teto de falhas seguidas antes de PARAR (e não pular mais). Com a
  /// fila toda morta, pular indefinidamente só aquece o aparelho.
  static const int maxConsecutivePlayFailures = 3;

  /// POST_NOTIFICATIONS pedido nesta sessão (item 1.11 — só no primeiro
  /// play, nunca no boot).
  bool _notificationPermissionAsked = false;

  /// Implementação do pedido de notificação (injetável para teste).
  final Future<void> Function() _requestNotificationPermission;

  // ---- Snapshot + reconciliação do catálogo (item 2.4) ----

  /// Snapshot leve do catálogo (JSON) — boot mostra a lista na hora.
  /// `null` = desativado (padrão em testes; o app real injeta no main).
  final CatalogSnapshotService? _snapshotService;

  /// Relógio injetável: o throttle do re-scan ao voltar do segundo
  /// plano precisa ser testável sem esperar 30s de verdade.
  final DateTime Function() _clock;

  /// Varredura do catálogo em andamento — deduplica boot/resume/pull.
  bool _catalogScanInFlight = false;

  /// Instante da última varredura iniciada (throttle do onAppResumed).
  DateTime? _lastCatalogScan;

  /// Janela mínima entre re-scans automáticos ao voltar do segundo
  /// plano — checar o MediaStore a cada retorno custa I/O à toa.
  static const Duration catalogRescanThrottle = Duration(seconds: 30);

  /// A partir de quantas faixas a ordenação do catálogo sai da UI
  /// thread ([compute]). Abaixo disso custa <~2ms e não paga o spawn
  /// do isolate. [defaultCatalogComputeThreshold] para o app real;
  /// testes podem subir o valor (ver construtor).
  static const int defaultCatalogComputeThreshold = 500;

  /// Limite efetivo deste provider ([defaultCatalogComputeThreshold]
  /// no app; injetável para teste).
  final int catalogComputeThreshold;

  Song? _currentSong;

  /// Posição de reprodução — notifier DEDICADO (item 2.1): o tick
  /// (~5x/s) NÃO passa por notifyListeners(), então a lista da
  /// biblioteca não reconstrói enquanto toca. Só os widgets de
  /// progresso consomem, via ValueListenableBuilder ([positionListenable]).
  final ValueNotifier<Duration> _positionNotifier =
      ValueNotifier<Duration>(Duration.zero);

  Duration _duration = Duration.zero;
  PlayerStatus _status = PlayerStatus.idle;
  String? _errorMessage;
  bool _isLoading = true;
  bool _isDisposed = false;

  /// Cadeia de recargas da fila editada (item 3.5) — serializa as
  /// edições rápidas para o player não receber cargas sobrepostas.
  Future<void> _pendingQueueReload = Future<void>.value();

  /// Todas as faixas (MediaStore + assets).
  List<Song> get songs => _songs;

  /// Faixas visíveis na UI (filtro de busca aplicado) — é a fila.
  List<Song> get visibleSongs => _visibleSongs;

  String get searchQuery => _searchQuery;

  AudioPermissionState get permission => _permission;

  Song? get currentSong => _currentSong;

  RepeatMode get repeat => _playbackQueue.repeat;

  bool get shuffle => _playbackQueue.shuffle;

  Duration get position => _positionNotifier.value;

  /// Progresso como ValueListenable (item 2.1): consumir com
  /// ValueListenableBuilder nos widgets que mostram a barra/tempos —
  /// mudanças aqui não acionam os watchers da lista.
  ValueListenable<Duration> get positionListenable => _positionNotifier;

  Duration get duration => _duration;

  PlayerStatus get status => _status;

  String? get errorMessage => _errorMessage;

  bool get isLoading => _isLoading;

  bool get isPlaying => _status == PlayerStatus.playing;

  bool get hasCurrentSong => _currentSong != null;

  // ---- Item 3.1 — timer de sono (estado mora no AudioService) ----

  /// Modo do timer (para a UI marcar a opção ativa no seletor).
  SleepTimerMode get sleepMode => _audioService.sleepMode;

  /// True quando há um sono agendado.
  bool get sleepTimerActive => _audioService.sleepTimerActive;

  /// Tempo restante (relógio de parede, recalculado a cada leitura).
  Duration get sleepRemaining => _audioService.sleepRemaining;

  /// Velocidade de reprodução corrente (item 3.2; 1.0 = normal).
  double get playbackSpeed => _audioService.playbackSpeed;

  /// Se há uma próxima faixa na fila (respecta repeat/shuffle).
  bool get hasNext => _playbackQueue.nextIndex() != null;

  /// Fila ATIVA de reprodução (ordem que o player segue, item 3.5) —
  /// o que a folha "Fila" do PlayerScreen lista. NÃO é a lista visível
  /// da biblioteca (que pode estar filtrada/busca).
  List<Song> get queue => _playbackQueue.queue;

  /// Índice da faixa corrente na fila (-1 = nada selecionado).
  int get queueIndex => _playbackQueue.queueIndex;

  PlayerProvider(
    this._audioService, {
    this.settings,
    SongRepository? songRepository,
    SessionRepository? sessionRepository,
    PlaybackQueue? playbackQueue,
    Future<void> Function()? requestNotificationPermission,
    // Item 2.4: null = snapshot DESATIVADO (padrão). Só o main.dart —
    // raiz de composição — injeta o serviço real. Testes ficam sem
    // snapshot de propósito: o channel do path_provider não responde
    // sob FakeAsync e travaria o await de init() em testWidgets.
    this._snapshotService,
    DateTime Function()? clock,
    // Item 2.4: a partir de quantas faixas a ordenação vai para
    // [compute]. Testes com milhares de faixas sob FakeAsync elevam o
    // limite (isolate não responde fora de zona real — runAsync exporia
    // exceções latentes de canal de plataforma do motor de áudio).
    this.catalogComputeThreshold = defaultCatalogComputeThreshold,
    // Item 4.2: regra do histórico (30 s / 50%). Testes injetam o
    // serviço com spy de gravação; o padrão grava em song_stats e
    // refresca o HistoryProvider da UI ao contar.
    PlaybackHistoryService? history,
  }) : _songRepository = songRepository ?? SongRepository(),
       _sessionRepository = sessionRepository ?? SessionRepository(),
       _playbackQueue = playbackQueue ?? PlaybackQueue(),
       _requestNotificationPermission = requestNotificationPermission ??
           PermissionService.requestNotificationAccess,
       _history = history ??
           PlaybackHistoryService(onRecorded: HistoryProvider.instance.refresh),
       _clock = clock ?? DateTime.now {
    // Botões da notificação/tela de bloqueio (audio_service) delegam a
    // navegação da fila para este provider.
    _audioService.onSkipToNext = next;
    _audioService.onSkipToPrevious = previous;
    // Comandos de repeat/shuffle/índice vindos do SISTEMA
    // (Bluetooth, Android Auto, relógio) — o app é a fonte de verdade:
    // aplica na fila e persiste a preferência.
    _audioService.onSetRepeatMode = _onSystemSetRepeatMode;
    _audioService.onSetShuffleMode = _onSystemSetShuffleMode;
    _audioService.onSkipToQueueIndex = _onSystemSkipToQueueIndex;
    // Faixa que FALHOU ao abrir: decide aqui (quem conhece a fila)
    // se pula para a próxima — com teto de falhas seguidas.
    _audioService.onPlaybackFailed = _onPlaybackFailed;
    // Item 3.4: o player avança SOZINHO na fila carregada (gapless) —
    // o serviço notifica a nova faixa e este provider sincroniza
    // fila/UI/sessão sem recarregar nada.
    _audioService.onQueueIndexChanged = _onQueueIndexChanged;
    // Item 3.1: o timer de sono pode disparar sozinho (relógio) com o
    // player já parado — sem mudança de status, quem reemite a UI é este
    // callback. `_notify` é guardado contra dispose.
    _audioService.onSleepTimerChanged = _notify;
    _audioService.position.addListener(_onPositionChanged);
    _audioService.duration.addListener(_onDurationChanged);
    _audioService.status.addListener(_onStatusChanged);
    _audioService.errorMessage.addListener(_onErrorMessageChanged);

    // Restaura shuffle/repeat persistidos (as preferências
    // já foram carregadas no boot — ver main.dart).
    // A fila ainda está vazia: ativar shuffle aqui só
    // marca o modo; a ordem é embaralhada na primeira
    // montagem de fila (playVisibleAt).
    final SettingsProvider? prefs = settings;
    if (prefs != null) {
      _playbackQueue.setRepeat(prefs.repeatMode);
      if (prefs.shuffleEnabled) {
        _playbackQueue.toggleShuffle();
      }
      // Item 3.2: velocidade salva na sessão anterior → serviço (e daí
      // para o just_audio/broadcast). 1.0 já é o padrão: pula a chamada.
      if (prefs.playbackSpeed != 1.0) {
        _audioService.setPlaybackSpeed(prefs.playbackSpeed);
      }
    }

    init();
  }

  /// Fluxo de inicialização: permissões -> catálogo -> fila.
  /// Boot ÚNICO e idempotente (item 2.4): o construtor já dispara o
  /// init(); chamadas seguintes (testes) aguardam o MESMO futuro em vez
  /// de rodar um segundo boot — dois boots paralelos disputavam
  /// snapshot/reconciliação e o segundo resetava a lista que o primeiro
  /// já tinha reconciliado.
  Future<void>? _initFuture;

  Future<void> init() => _initFuture ??= _init();

  Future<void> _init() async {
    _isLoading = true;
    _notify();

    _permission = _mapResult(await PermissionService.requestAudioAccess());
    // Item 1.11: o boot NÃO pede mais vídeo/galeria/notificação (rajada
    // antes de o usuário abrir essas abas). Vídeo e galeria são pedidos
    // na própria aba (VideoProvider/GalleryProvider.requestAccessOnTabOpen,
    // com tela explicativa antes) e POST_NOTIFICATIONS no primeiro play
    // (_maybeAskNotificationPermission).
    if (_permission != AudioPermissionState.granted) {
      // Sem permissão o app ainda funciona com os assets do bundle.
      await _loadSongs(includeDevice: false);
      return;
    }

    // Item 2.4: SNAPSHOT primeiro — a biblioteca aparece na hora (sem
    // esperar o MediaStore) e a varredura real roda em segundo plano,
    // reconciliando. Só cai no caminho frio quem não tem snapshot.
    final List<Song>? snapshot =
        _isDisposed ? null : await _snapshotService?.load();
    if (snapshot != null && !_isDisposed) {
      _songs = await _buildCatalog(List<Song>.of(snapshot));
      if (_isDisposed) return;
      _applySearchFilter();
      _isLoading = false;
      _notify();
      // Em segundo plano: varre de verdade e só mexe na UI se algo
      // tiver mudado (um boot sem novidade não reconstrói a lista).
      unawaited(_reconcileCatalog(includeDevice: true));
      await _restoreSession();
      return;
    }

    await _loadSongs(includeDevice: true);
    await _restoreSession();
  }

  /// (Re)carrega o catálogo (caminho frio — sem snapshot). Ao final
  /// grava o snapshot para o próximo boot já abrir com a lista pronta.
  Future<void> _loadSongs({required bool includeDevice}) async {
    _markCatalogScanStarted();
    try {
      final List<Song> device = includeDevice
          ? await _loadFilteredDeviceSongs()
          : const [];
      final List<Song> assets = await _songRepository.loadAssetSongs();
      // Item 2.3: ordem natural + sem acento — 'Faixa 2' antes de
      // 'Faixa 10' e 'Ação' no lugar de 'Zebra' (o sort roda em
      // isolate quando o catálogo é grande — item 2.4).
      _songs = await _buildCatalog(<Song>[...device, ...assets]);
      _applySearchFilter();
      unawaited(_snapshotService?.save(_songs));
    } catch (e, s) {
      _errorMessage = 'Falha ao carregar a lista de músicas: $e';
      ErrorLogService.logSync('PlayerProvider._loadSongs', e, s);
    } finally {
      _isLoading = false;
      _notify();
    }
  }

  /// Junta as fontes e ordena o catálogo ([naturalCompare], item 2.3).
  /// Com muitas faixas a ordenação sai da UI thread via [compute] —
  /// 5 mil faixas aqui atrasam o primeiro frame (item 2.4).
  Future<List<Song>> _buildCatalog(List<Song> merged) async {
    if (merged.length < catalogComputeThreshold) {
      return merged..sort((a, b) => naturalCompare(a.title, b.title));
    }
    return compute(sortCatalogJob, merged);
  }

  /// Varre as fontes de novo e reconcilia o catálogo (item 2.4).
  /// Usado pelo boot com snapshot (em segundo plano), pelo onAppResumed
  /// (com throttle) e pelo pull-to-refresh. Só notifica a UI se algo
  /// TIVER mudado — resume sem novidade não reconstrói a lista.
  Future<void> _reconcileCatalog({required bool includeDevice}) async {
    if (_isDisposed || _catalogScanInFlight) return;
    _catalogScanInFlight = true;
    _markCatalogScanStarted();
    try {
      final List<Song> device = includeDevice
          ? await _loadFilteredDeviceSongs()
          : const <Song>[];
      final List<Song> assets = await _songRepository.loadAssetSongs();
      final List<Song> merged =
          await _buildCatalog(<Song>[...device, ...assets]);
      if (_isDisposed) return;
      if (_catalogEquals(_songs, merged)) return; // sem mudança: silêncio

      _songs = merged;
      _applySearchFilter();
      // Reancora a faixa atual na instância nova (mesmo id, metadados
      // podem ter mudado). Se ela sumiu do catálogo (apagada fora do
      // app), a reprodução segue — o play falha e o handler do item 1.7
      // decide; derrubar o player no meio de um resume seria pior.
      final Song? current = _currentSong;
      if (current != null) {
        final int idx = merged.indexWhere((Song s) => s.id == current.id);
        if (idx >= 0) _currentSong = merged[idx];
      }
      _notify();
      await _snapshotService?.save(merged);
    } catch (e, s) {
      ErrorLogService.logSync('PlayerProvider._reconcileCatalog', e, s);
    } finally {
      _catalogScanInFlight = false;
    }
  }

  /// Pull-to-refresh da aba Música (item 2.4): ação EXPLÍCITA do
  /// usuário — varre sempre, sem o throttle do onAppResumed.
  Future<void> rescanCatalog() => _reconcileCatalog(
        includeDevice: _permission == AudioPermissionState.granted,
      );

  void _markCatalogScanStarted() => _lastCatalogScan = _clock();

  /// Faixas do aparelho já com os FILTROS da Configurações >
  /// Biblioteca (item 2.5) — usada pelo caminho frio e pela
  /// reconciliação para as duas aplicarem as MESMAS regras.
  Future<List<Song>> _loadFilteredDeviceSongs() async {
    final List<Song> raw = await _songRepository.loadDeviceSongs();
    return filterDeviceSongs(
      raw,
      minDurationSeconds: settings?.libraryMinDurationSeconds ?? 0,
      ignoredFolders: settings?.ignoredFolders ?? const <String>[],
    );
  }

  /// Regras da Configurações > Biblioteca (item 2.5): duração mínima e
  /// pastas ignoradas (WhatsApp, toques, notificações...). Só faixas do
  /// aparelho passam por aqui (o chamador garante); assets do bundle
  /// passam sempre, por segurança. Duração DESCONHECIDA passa — filtrar
  /// no escuro esconderia música real. A comparação de pasta usa
  /// `pasta/` como prefixo com limite de diretório: `/Music` não pega
  /// `/MusicAntiga/x.mp3`.
  static List<Song> filterDeviceSongs(
    List<Song> device, {
    required int minDurationSeconds,
    required List<String> ignoredFolders,
  }) {
    if (minDurationSeconds <= 0 && ignoredFolders.isEmpty) return device;
    final int minMs = minDurationSeconds * 1000;
    return device.where((Song song) {
      if (song.isAsset) return true;
      if (minMs > 0) {
        final Duration? duration = song.duration;
        if (duration != null && duration.inMilliseconds < minMs) {
          return false;
        }
      }
      if (ignoredFolders.isNotEmpty) {
        final String? path = song.filePath;
        if (path != null) {
          for (final String folder in ignoredFolders) {
            if (path.startsWith('$folder/')) return false;
          }
        }
      }
      return true;
    }).toList(growable: false);
  }

  /// Igualdade REAL do catálogo — [Song.==] compara só o id, então
  /// título/artista/álbum/caminho/duração mudados também contam como
  /// mudança (e aí sim vale reconstruir a lista).
  static bool _catalogEquals(List<Song> a, List<Song> b) {
    if (identical(a, b) || a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      final Song x = a[i];
      final Song y = b[i];
      if (x.id != y.id ||
          x.title != y.title ||
          x.artist != y.artist ||
          x.album != y.album ||
          x.filePath != y.filePath ||
          x.assetPath != y.assetPath ||
          x.mediaId != y.mediaId ||
          x.albumId != y.albumId ||
          x.duration != y.duration) {
        return false;
      }
    }
    return true;
  }

  /// Solicita a permissão de novo (banner da UI) e recarrega o catálogo.
  Future<void> requestPermissionAndReload() async {
    _isLoading = true;
    _notify();

    _permission = _mapResult(await PermissionService.requestAudioAccess());
    await _loadSongs(
      includeDevice: _permission == AudioPermissionState.granted,
    );
  }

  AudioPermissionState _mapResult(AudioAccessResult result) {
    switch (result) {
      case AudioAccessResult.granted:
        return AudioPermissionState.granted;
      case AudioAccessResult.denied:
        return AudioPermissionState.denied;
      case AudioAccessResult.permanentlyDenied:
        return AudioPermissionState.permanentlyDenied;
    }
  }

  /// Atualiza o termo de busca e reaplica o filtro na lista exibida.
  ///
  /// Apenas a LISTA VISÍVEL é filtrada — a fila de reprodução
  /// ativa não é tocada aqui (ver [playVisibleAt]): digitar na
  /// busca não pode reordenar nem encolher a fila que está
  /// tocando.
  void setSearchQuery(String query) {
    _searchQuery = query.trim();
    _applySearchFilter();
    // Item 2.1: a busca não notificava antes — a tela só se atualizava
    // porque o tick de posição reconstruía tudo ~5x/s (pausado, ficava
    // defasada). Com o tick fora do notifyListeners, digitar notifica de
    // verdade: lista e ícone de limpar atualizam na hora.
    _notify();
  }

  void _applySearchFilter() {
    // Item 2.3: busca sem acento — 'acao' acha 'Ação' (a chave
    // normalizada também reduz comparações por faixa a uma passada).
    final String q = normalizeKey(_searchQuery);
    _visibleSongs = q.isEmpty
        ? List.of(_songs)
        : _songs.where((s) {
            final inTitle = normalizeKey(s.title).contains(q);
            final inArtist = normalizeKey(s.artist ?? '').contains(q);
            final inAlbum = normalizeKey(s.album ?? '').contains(q);
            return inTitle || inArtist || inAlbum;
          }).toList();
  }

  /// Grupos do modo agrupado — MEMOIZADO (item 2.2): recalcula apenas
  /// quando mudam o catálogo/busca (identidade da lista visível) ou o
  /// modo. A tela chamava isso a cada build; agora rebuilds que não
  /// mexem nesses entradas reutilizam as mesmas instâncias.
  List<SongGroup> visibleGroups(MusicGroupMode mode) {
    final List<Song> source = _visibleSongs;
    if (!identical(source, _groupsSource) || mode != _groupsMode) {
      _groups = _groupSongs(source, mode);
      _groupsSource = source;
      _groupsMode = mode;
    }
    return _groups;
  }

  /// Agrupa por chave e ordena as chaves com [naturalCompare] (item 2.3:
  /// sem acento e com ordem natural — 'Álbum 2' antes de 'Álbum 10').
  /// As chaves de EXIBIÇÃO continuam com o texto original do MediaStore.
  static List<SongGroup> _groupSongs(List<Song> songs, MusicGroupMode mode) {
    final Map<String, List<Song>> byKey = <String, List<Song>>{};
    for (final Song song in songs) {
      byKey.putIfAbsent(_groupKeyOf(song, mode), () => <Song>[]).add(song);
    }
    final List<String> sortedKeys = byKey.keys.toList()
      ..sort(naturalCompare);
    return <SongGroup>[
      for (final String key in sortedKeys)
        SongGroup(key: key, songs: byKey[key]!),
    ];
  }

  /// Chave de agrupamento da faixa (lógica movida da tela, idêntica:
  /// álbum/artista com fallback amigável; pasta = diretório pai do
  /// arquivo, assets agrupados em "Assets do app").
  static String _groupKeyOf(Song song, MusicGroupMode mode) {
    switch (mode) {
      case MusicGroupMode.tracks:
        return '';
      case MusicGroupMode.album:
        return song.album?.trim().isNotEmpty == true
            ? song.album!.trim()
            : 'Sem álbum';
      case MusicGroupMode.artist:
        return song.displayArtist;
      case MusicGroupMode.folder:
        final String? path = song.filePath;
        if (path == null || path.isEmpty) return 'Assets do app';
        final List<String> parts = path
            .split('/')
            .where((s) => s.isNotEmpty)
            .toList();
        return parts.length >= 2 ? parts[parts.length - 2] : '/';
    }
  }

  /// Reconstrói a fila de reprodução na ordem atual (respeita shuffle).
  void _rebuildQueue() {
    _playbackQueue.rebuild(_visibleSongs, keepCurrent: _currentSong);
  }

  /// Toca a faixa da lista visível pelo índice da UI.
  ///
  /// AQUI a fila muda (ação do usuário): reconstrói a fila a
  /// partir da lista visível atual (respeita shuffle) e
  /// seleciona a faixa tocada. Buscar NÃO faz isso — só
  /// tocar uma faixa monta/atualiza a fila.
  Future<void> playVisibleAt(int index) async {
    if (index < 0 || index >= _visibleSongs.length) return;
    // Escolha manual = nova chance: zera o teto de falhas seguidas.
    _consecutivePlayFailures = 0;
    _rebuildQueue();
    _playbackQueue.setIndex(
      _playbackQueue.queue.indexWhere((s) => s.id == _visibleSongs[index].id),
    );
    await _playCurrent();
  }

  /// Toca uma fila arbitrária (ex.: playlist do usuário) a partir de uma
  /// faixa específica. Substitui a fila corrente sem alterar a biblioteca.
  Future<void> playQueue(List<Song> queue, int startIndex) async {
    if (queue.isEmpty) return;
    // Escolha manual = nova chance: zera o teto de falhas seguidas.
    _consecutivePlayFailures = 0;
    _playbackQueue.setQueue(queue, startIndex);
    await _playCurrent();
  }

  Future<void> _playCurrent() async {
    final Song? song = _playbackQueue.current;
    if (song == null) return;
    _currentSong = song;
    _positionNotifier.value = Duration.zero;
    _duration = Duration.zero;
    _notify(); // destaca a faixa imediatamente
    // Item 1.11: POST_NOTIFICATIONS no primeiro play — fire-and-forget
    // antes de tocar, para o sistema já ter a permissão quando a
    // notificação de mídia for postada. Nunca atrasa a faixa.
    _maybeAskNotificationPermission();
    // Item 3.4: publica a fila ANTES de tocar — o playSong lê o
    // snapshot publicado para carregar a fila inteira (gapless) ou só
    // reposicionar (skip sem recarga).
    _publishQueueToService();
    await _audioService.playSong(song);
    // playSong limpa errorMessage no início e só o repreenche em falha:
    // abrir com sucesso zera o contador de falhas seguidas.
    if (_audioService.errorMessage.value == null) {
      _consecutivePlayFailures = 0;
    }
  }

  /// Item 1.11 — POST_NOTIFICATIONS no primeiro play (nunca no boot).
  /// Uma única tentativa por sessão; o pedido em si é fire-and-forget
  /// com try/catch — permissão não pode travar nem derrubar a faixa.
  void _maybeAskNotificationPermission() {
    if (_notificationPermissionAsked) return;
    _notificationPermissionAsked = true;
    _askNotificationPermission();
  }

  Future<void> _askNotificationPermission() async {
    try {
      await _requestNotificationPermission();
      // Concedida no MEIO da faixa: o sistema descarta notificações
      // postadas sem permissão e não as recria sozinho — republica o
      // estado para a notificação de mídia aparecer já com o grant.
      if (!_isDisposed && await PermissionService.hasNotificationAccess()) {
        _audioService.broadcastPlaybackState();
      }
    } catch (e, s) {
      ErrorLogService.logSync('player/notification', e, s);
    }
  }

  /// Chamado pelo [AudioService] quando uma faixa FALHOU ao abrir.
  ///
  /// Estratégia: pula para a próxima automaticamente (arquivo apagado/
  /// corrompido não deve travar a escuta), mas com TETO de falhas
  /// seguidas ([maxConsecutivePlayFailures]) — com a fila toda morta,
  /// pular indefinidamente só repete o erro e esquenta o aparelho.
  /// A mensagem amigável (com o motivo) já foi publicada pelo serviço.
  Future<void> _onPlaybackFailed(Song failed) async {
    if (_isDisposed) return;
    _consecutivePlayFailures++;

    if (_consecutivePlayFailures >= maxConsecutivePlayFailures) {
      // Teto batido: para de tentar e deixa uma mensagem que explica o
      // PORQUÊ de ter parado (a do serviço cita a última faixa; esta
      // diz o total). Nada de pular em loop com a fila toda morta.
      _audioService.errorMessage.value =
          'Reprodução parada: $maxConsecutivePlayFailures faixas seguidas '
          'falharam ao abrir. Verifique se os arquivos ainda existem '
          'no aparelho.';
      _status = PlayerStatus.idle;
      _notify();
      return;
    }

    final int? nextIndex = _playbackQueue.nextIndex();
    // Mesma faixa (repeat one apontando para a morta) = loop garantido;
    // null = fim da fila (repeat off). Nos dois casos, sem pular: a
    // mensagem amigável da última falha (serviço) já está na UI.
    final bool sameTrack =
        nextIndex != null && nextIndex == _playbackQueue.queueIndex;
    if (nextIndex == null || sameTrack) return;

    _playbackQueue.setIndex(nextIndex);
    await _playCurrent();
  }

  /// Próxima faixa da fila (respecta repeat all/one e shuffle).
  Future<void> next() async {
    final int? nextIndex = _playbackQueue.nextIndex();
    if (nextIndex == null) return;
    _playbackQueue.setIndex(nextIndex);
    await _playCurrent();
  }

  /// Faixa anterior (ou reinicia a atual se passou mais de 3s tocando).
  Future<void> previous() async {
    if (_currentSong == null) return;
    if (position > const Duration(seconds: 3)) {
      return seek(Duration.zero);
    }
    final int? prevIndex = _playbackQueue.previousIndex();
    if (prevIndex == null) return seek(Duration.zero);
    _playbackQueue.setIndex(prevIndex);
    await _playCurrent();
  }

  void toggleShuffle() {
    _playbackQueue.toggleShuffle();
    // Persiste a preferência (próxima sessão abre
    // no mesmo modo).
    settings?.setShuffleEnabled(_playbackQueue.shuffle);
    _publishQueueToService();
    _notify();
  }

  void cycleRepeat() {
    _playbackQueue.cycleRepeat();
    // Persiste a preferência.
    settings?.setRepeatMode(_playbackQueue.repeat);
    _syncModesToService();
    _notify();
  }

  // ------------------------------------------------------------------
  // Item 3.5 — edição da fila (folha "Fila", "Tocar a seguir" e
  // "Adicionar à fila"). A fila MUTADA com o player ativo precisa ser
  // recarregada: o gapless (3.4) só avança dentro das fontes que o
  // player carregou — sem a recarga, a transição viria da fila ANTIGA.
  // ------------------------------------------------------------------

  /// "Tocar a seguir": [songs] entram logo após a corrente, na ordem
  /// dada (seleção em lote chega como lote). Já presentes são MOVIDAS
  /// (sem duplicatas). Se nunca tocou nada, começa a tocar — senão o
  /// botão play ficaria morto sem faixa corrente.
  void queuePlayNext(List<Song> songs) {
    if (_isDisposed || songs.isEmpty) return;
    if (!_playbackQueue.insertNext(songs)) return;
    _afterQueueEdit(startIfIdle: true);
  }

  /// "Adicionar à fila": [songs] entram no FIM (as já presentes são
  /// ignoradas). Mesma regra de auto-play da fila vazia do
  /// [queuePlayNext].
  void queueAppend(List<Song> songs) {
    if (_isDisposed || songs.isEmpty) return;
    if (!_playbackQueue.append(songs)) return;
    _afterQueueEdit(startIfIdle: true);
  }

  /// Reordena a folha da fila: [to] é a posição FINAL do item (quem
  /// chama converte o +1 do ReorderableListView). O player não troca
  /// de faixa por arrastar — só a ordem muda.
  void queueMove(int from, int to) {
    if (_isDisposed) return;
    if (!_playbackQueue.move(from, to)) return;
    _afterQueueEdit();
  }

  /// Remove o item [index] da folha da fila. Se era a corrente, a
  /// próxima sobrevivente assume a posição e Toca do início.
  void queueRemoveAt(int index) {
    if (_isDisposed) return;
    if (_playbackQueue.removeAt(index) == null) return;
    _afterQueueEdit();
  }

  /// Pós-mutação comum: publica na notificação, aciona a UI e, com
  /// player ativo, recarrega a fila nova preservando posição/estado.
  void _afterQueueEdit({bool startIfIdle = false}) {
    if (_isDisposed) return;
    // Nunca tocou: a edição vira a primeira reprodução (só ações
    // ADITIVAS fazem isso — reordenar/remover nada tocado não inicia
    // áudio).
    if (startIfIdle &&
        _currentSong == null &&
        _playbackQueue.queue.isNotEmpty) {
      _playbackQueue.setIndex(
        _playbackQueue.queueIndex >= 0 ? _playbackQueue.queueIndex : 0,
      );
      unawaited(_playCurrent());
      return;
    }
    final Song? cur = _playbackQueue.current;
    _currentSong = cur;
    if (cur == null) {
      // Fila esvaziou: publica o estado vazio e corta um player que
      // estivesse ativo (não pode sobrar áudio de faixa removida).
      _publishQueueToService();
      final PlayerStatus st = _audioService.status.value;
      if (st == PlayerStatus.playing || st == PlayerStatus.paused) {
        unawaited(_audioService.stop());
      }
      _positionNotifier.value = Duration.zero;
      _notify();
      return;
    }
    _publishQueueToService();
    _notify();
    _reloadQueueForEdit();
  }

  /// Recarrega a fila editada no player (item 3.5 + 3.4). Enfileirada:
  /// edições rápidas em sequência viram cargas SERIAIS (o player não
  /// recebe duas cargas sobrepostas); o estado é relido DENTRO da
  /// cadeia para a última edição valer. Só roda com player ativo —
  /// parado, o próximo play já recarrega pelo caminho normal do
  /// [AudioService.playSong]. Falha vira log, sem crash.
  void _reloadQueueForEdit() {
    try {
      if (_isDisposed) return;
      final PlayerStatus st = _audioService.status.value;
      if (st != PlayerStatus.playing && st != PlayerStatus.paused) return;
      _pendingQueueReload = _pendingQueueReload.then((_) async {
        if (_isDisposed) return;
        try {
          final PlayerStatus now = _audioService.status.value;
          if (now != PlayerStatus.playing && now != PlayerStatus.paused) {
            return; // usuário parou enquanto a edição esperava
          }
          final Song? next = _playbackQueue.current;
          if (next == null) return;
          // A posição só vale se a faixa que SOA é a que continua
          // corrente; remoção da atual faz a sobrevivente recomeçar.
          final String? sounding = _audioService.mediaItem.value?.id;
          final Duration startAt = next.id == sounding
              ? _audioService.position.value
              : Duration.zero;
          await _audioService.playSong(next, startAt: startAt);
          if (_isDisposed) return;
          if (now == PlayerStatus.paused) await _audioService.pause();
        } catch (e, s) {
          ErrorLogService.logSync('player/queueReload', e, s);
        }
      });
      unawaited(_pendingQueueReload);
    } catch (e, s) {
      ErrorLogService.logSync('player/queueReload', e, s);
    }
  }

  // ---- Item 3.1 — timer de sono (delegação + notificação da UI) ----

  /// Agenda o sono por [duration] a partir de agora.
  void startSleepTimer(Duration duration) {
    _audioService.startSleepTimer(duration);
    _notify();
  }

  /// Agenda o sono para o fim da faixa corrente (sem avançar a fila).
  void startSleepAtTrackEnd() {
    _audioService.startSleepAtTrackEnd();
    _notify();
  }

  /// Cancela o timer sem parar a música.
  void cancelSleepTimer() {
    _audioService.cancelSleepTimer();
    _notify();
  }

  /// Item 3.2 — velocidade 0,5x–2,0x: aplica no serviço (just_audio +
  /// broadcast do PlaybackState) e persiste para a próxima sessão.
  Future<void> setPlaybackSpeed(double speed) async {
    await _audioService.setPlaybackSpeed(speed);
    _notify();
    await settings?.setPlaybackSpeed(_audioService.playbackSpeed);
  }

  // ------------------------------------------------------------------
  // Comandos vindos do SISTEMA (Bluetooth/Android Auto/relógio)
  // ------------------------------------------------------------------

  /// Repeat escolhido DIRETO pelo sistema (o botão escolhe o modo,
  /// não cicla). Aplica na fila, persiste e reemite o estado para o
  /// sistema refletir o resultado.
  Future<void> _onSystemSetRepeatMode(RepeatMode mode) async {
    if (_isDisposed) return;
    _playbackQueue.setRepeat(mode);
    await settings?.setRepeatMode(mode);
    _syncModesToService();
    _notify();
  }

  /// Shuffle ligado/desligado pelo sistema — idem [_onSystemSetRepeatMode].
  Future<void> _onSystemSetShuffleMode(bool enabled) async {
    if (_isDisposed) return;
    if (_playbackQueue.shuffle != enabled) {
      _playbackQueue.toggleShuffle();
      await settings?.setShuffleEnabled(enabled);
    }
    _syncModesToService();
    _notify();
  }

  /// Faixa escolhida por índice na fila publicada (Android Auto/browse).
  /// Índice fora do intervalo é ignorado — o canal nativo não pode
  /// receber erro por uma lista que encurtou.
  Future<void> _onSystemSkipToQueueIndex(int index) async {
    if (_isDisposed) return;
    if (index < 0 || index >= _playbackQueue.queue.length) return;
    // Escolha manual = nova chance no teto de falhas seguidas.
    _consecutivePlayFailures = 0;
    _playbackQueue.setIndex(index);
    await _playCurrent();
    _publishQueueToService();
  }

  /// Publica fila + índice da fila + modos no MediaSession. Chamado após
  /// QUALQUER mudança de fila/modo/índice (é barato: a lista só vai ao
  /// canal quando a identidade muda — ver [AudioService.publishQueue]).
  void _publishQueueToService() {
    if (_isDisposed) return;
    _audioService.publishQueue(
      _playbackQueue.queue,
      _playbackQueue.queueIndex,
    );
    _syncModesToService();
  }

  /// Publica apenas os modos (shuffle/repeat) no MediaSession.
  void _syncModesToService() {
    if (_isDisposed) return;
    _audioService.syncModes(
      repeat: _playbackQueue.repeat,
      shuffle: _playbackQueue.shuffle,
    );
  }

  void _onPositionChanged() {
    // Item 2.1: o tick atualiza SÓ o notifier de progresso — sem
    // notifyListeners. A lista da biblioteca não reconstrói ~5x/s;
    // os widgets de progresso reagem via ValueListenableBuilder.
    _positionNotifier.value = _audioService.position.value;
    // Item 4.2: mesma fonte de verdade do progresso alimenta a regra
    // do histórico (30 s / 50%, uma vez por execução da faixa).
    _history.onProgress(
      _currentSong,
      _positionNotifier.value,
      _duration,
      isPlaying: _status == PlayerStatus.playing,
    );
    _maybeSaveSession();
  }

  /// Salva a sessão periodicamente (5s) e em pausas — barato e tolerante
  /// a falhas: o pior caso é retomar de uma posição ligeiramente antiga.
  void _maybeSaveSession() {
    if (_status != PlayerStatus.playing) return;
    final DateTime now = DateTime.now();
    if (now.difference(_lastSessionSave) < const Duration(seconds: 5)) return;
    _lastSessionSave = now;
    _saveSession();
  }

  void _onDurationChanged() {
    _duration = _audioService.duration.value;
    _notify();
  }

  void _onStatusChanged() {
    _status = _audioService.status.value;
    if (_status == PlayerStatus.completed) {
      _onTrackCompleted();
    }
    if (_status != PlayerStatus.playing) {
      // Pausa/fim: grava a posição atual para "continuar de onde parou".
      _saveSession();
    }
    _notify();
  }

  /// Fim natural da faixa: avança na fila (repeat one = toca de novo).
  ///
  /// Com repeat off/all o player carrega a fila inteira (item 3.4): o
  /// `completed` chega só no FIM da fila — as transições intermediárias
  /// vêm por [_onQueueIndexChanged] (gapless, sem recarga).
  Future<void> _onTrackCompleted() async {
    // Item 3.1 — sono "ao fim da faixa": o serviço consome o evento, para a
    // reprodução e o provider NÃO avança a fila (senão a próxima faixa
    // começaria a tocar junto com o disparo do timer).
    if (_audioService.consumeSleepAtTrackEnd()) return;
    if (_playbackQueue.repeat == RepeatMode.one) {
      await _playCurrent();
      return;
    }
    final int? nextIndex = _playbackQueue.nextIndex();
    if (nextIndex == null) {
      _positionNotifier.value = Duration.zero;
      return;
    }
    _playbackQueue.setIndex(nextIndex);
    await _playCurrent();
  }

  /// Item 3.4: o player avançou SOZINHO (gapless) para a próxima faixa
  /// da fila carregada — sincroniza fila/UI/sessão sem recarregar nada
  /// (chamar [_playCurrent] aqui mataria o gapless com um reload).
  void _onQueueIndexChanged(int index, Song song) {
    if (_isDisposed) return;
    // Evento espúrio (divergência entre fila publicada e a carregada no
    // player): o próximo playSong recarrega a fila — aqui só ignora.
    if (index < 0 || index >= _playbackQueue.queue.length) return;
    if (_playbackQueue.queue[index].id != song.id) return;

    _playbackQueue.setIndex(index);
    _currentSong = song;
    _positionNotifier.value = Duration.zero;
    _duration = _audioService.duration.value;
    _publishQueueToService();
    _notify();
    // Item 3.1 — sono "ao fim da faixa": a faixa terminou (a próxima já
    // começou junto, gapless). Consome AQUI; o serviço agenda o stop
    // (one-shot — o segundo consume, em eventos seguintes, é um no-op).
    if (_audioService.consumeSleepAtTrackEnd()) return;
    _maybeSaveSession();
  }

  void _onErrorMessageChanged() {
    _errorMessage = _audioService.errorMessage.value;
    _notify();
  }

  /// Notifica a UI apenas se o provider ainda estiver ativo — previne
  /// notifyListeners() após dispose (crash em modo debug).
  void _notify() {
    if (!_isDisposed) notifyListeners();
  }

  // ------------------------------------------------------------------
  // Ciclo de vida (chamado pelo MainScreen via WidgetsBindingObserver)
  // ------------------------------------------------------------------

  /// App foi para segundo plano (ou está sendo fechado): persiste a
  /// sessão imediatamente — "continuar de onde parou" não pode depender
  /// do throttle de 5s quando o processo pode morrer em seguida.
  void onAppPaused() {
    if (_isDisposed) return;
    if (_currentSong == null) return;
    _saveSession();
  }

  /// Voltou ao primeiro plano: re-sincroniza a UI com o estado REAL do
  /// serviço de áudio. Cobre o caso de o usuário ter controlado a
  /// reprodução pela notificação/tela de bloqueio (posição/status
  /// mudaram por caminhos que não passaram por esta tela).
  ///
  /// Se o processo foi morto e recriado, este provider é novo e init()
  /// já restaurou tudo — aqui apenas garantimos consistência.
  void onAppResumed() {
    if (_isDisposed) return;
    final AudioService svc = _audioService;
    _positionNotifier.value = svc.position.value;
    _duration = svc.duration.value;
    _status = svc.status.value;
    _errorMessage = svc.errorMessage.value;
    _notify();
    _maybeRescanCatalogOnResume();
  }

  /// Re-escaneia ao voltar do segundo plano com THROTTLE (item 2.4):
  /// música adicionada/apagada em outro app aparece sozinha, sem varrer
  /// o MediaStore a cada retorno (ex.: trocar de aba 5x em 10s = 1 scan).
  void _maybeRescanCatalogOnResume() {
    if (_isDisposed) return;
    if (_permission != AudioPermissionState.granted) return;
    final DateTime now = _clock();
    final DateTime? last = _lastCatalogScan;
    if (last != null && now.difference(last) < catalogRescanThrottle) {
      return;
    }
    unawaited(_reconcileCatalog(includeDevice: true));
  }

  /// Alterna entre tocar/pausar com base no estado atual.
  Future<void> togglePlayPause() async {
    if (_currentSong == null) return;
    switch (_status) {
      case PlayerStatus.playing:
        await _audioService.pause();
      case PlayerStatus.paused:
        await _audioService.resume();
      case PlayerStatus.stopped:
        await _audioService.resume();
      case PlayerStatus.completed:
        await _audioService.playSong(_currentSong!);
      case PlayerStatus.idle:
        break;
    }
  }

  /// Para a reprodução e zera a posição na UI.
  Future<void> stop() async {
    await _audioService.stop();
    _positionNotifier.value = Duration.zero;
    _notify();
  }

  /// Envia seek ao player (valor vem do Slider arrastado).
  Future<void> seek(Duration target) async {
    await _audioService.seek(target);
  }

  // ------------------------------------------------------------------
  // Sessão: "continuar de onde parou" (preferência em Configurações).
  // ------------------------------------------------------------------

  /// Restaura a última faixa tocada (posição salva, sem autoplay) e a
  /// FILA ativa da sessão anterior (ids + índice).
  ///
  /// A fila salva é reconciliada com o catálogo atual: ids de arquivos
  /// que saíram do aparelho são descartados UM A UM (a faixa que sumiu
  /// não derruba o resto da fila). Sem fila salva (sessão antiga) ou com
  /// fila válida vazia, cai no catálogo inteiro — comportamento antigo.
  Future<void> _restoreSession() async {
    final SettingsProvider? prefs = settings;
    if (prefs == null || !prefs.resumePlayback) return;
    if (_songs.isEmpty) return;

    final (Song?, Duration) stored = await _sessionRepository.load();
    final Song? saved = stored.$1;
    if (saved == null) return;

    // Fila ativa salva (ids na ordem real de reprodução).
    final (List<String> queueIds, _) = await _sessionRepository.loadQueue();

    // Índice do catálogo para a faixa salva (referência de "onde parou").
    final int catalogIdx = _songs.indexWhere((s) => s.id == saved.id);
    if (catalogIdx < 0) {
      // Faixa salva não existe mais: nada a retomar.
      return;
    }

    List<Song> queue;
    int idx;
    if (queueIds.isEmpty) {
      // Sessão antiga (gravada antes do 1.6): fila = catálogo inteiro.
      queue = _songs;
      idx = catalogIdx;
    } else {
      final Map<String, Song> byId = <String, Song>{
        for (final Song s in _songs) s.id: s,
      };
      queue = <Song>[
        for (final String id in queueIds)
          if (byId[id] != null) byId[id]!, // some só o id morto
      ];
      idx = queue.indexWhere((s) => s.id == saved.id);
      if (queue.isEmpty || idx < 0) {
        // Fila salva inteiramente obsoleta (ou a faixa corrente ficou
        // fora dela): volta ao catálogo para não perder a retomada.
        queue = _songs;
        idx = catalogIdx;
      }
      // A posição do índice salvo é ignorada de propósito: o encaixe
      // é sempre pelo id da faixa — ids que sumiram da fila não podem
      // deslocar o "onde parou".
    }

    _currentSong = queue[idx];
    _positionNotifier.value = stored.$2;
    _playbackQueue.setQueue(queue, idx);
    _publishQueueToService();
    _notify();
  }

  /// Persiste faixa + posição + fila ativa (throttle de 5s durante a
  /// reprodução).
  Future<void> _saveSession() async {
    final Song? song = _currentSong;
    if (song == null) return;
    await _sessionRepository.save(song, position);
    // Fila ativa (ids + índice): permite retomar a MESMA fila
    // (inclusive a ordem embaralhada), não só a faixa.
    final List<Song> queue = _playbackQueue.queue;
    final int qIndex = _playbackQueue.queueIndex;
    if (queue.isNotEmpty && qIndex >= 0) {
      await _sessionRepository.saveQueue(
        queue.map((Song s) => s.id).toList(),
        qIndex,
      );
    }
  }

  /// Arquivos de música foram EXCLUÍDOS do aparelho.
  ///
  /// Faz a limpeza completa para que nenhum estado aponte para um arquivo
  /// que não existe mais: sai do catálogo, sai da fila, sai do estado de
  /// retomada e, se era a faixa que tocava, para o áudio e avança para a
  /// próxima sobrevivente.
  ///
  /// Chamar com lista vazia é no-op (nada a atualizar).
  Future<void> handleSongsDeleted(List<Song> deleted) async {
    if (deleted.isEmpty) return;

    final Set<String> ids = deleted.map((Song s) => s.id).toSet();
    final Song? playing = _currentSong;
    final bool removedCurrent = playing != null && ids.contains(playing.id);

    _songs = _songs.where((Song s) => !ids.contains(s.id)).toList();
    // Só refiltra a lista visível — a fila ativa é ajustada
    // abaixo via removeSongs (preserva filas vindas de
    // playlist, não só da lista visível).
    _applySearchFilter();
    // Item 2.4: a exclusão foi explícita — o snapshot não pode voltar
    // com a faixa morta no próximo boot.
    unawaited(_snapshotService?.save(_songs));

    // Remove da fila ativa (ordem preservada; reencaixa o
    // índice corrente na próxima sobrevivente).
    _playbackQueue.removeSongs(ids);
    // Fila encurtou: republica no MediaSession (índices do sistema
    // apontariam para faixas que não existem mais).
    _publishQueueToService();

    if (removedCurrent) {
      // A sessão salva aponta para um arquivo morto: some com ela. Só quando
      // a excluída era a que tocava — excluir outra faixa não pode derrubar o
      // "continuar de onde parou" de uma música que continua no aparelho.
      await _sessionRepository.clear();

      await _audioService.stop();
      _currentSong = null;
      _positionNotifier.value = Duration.zero;
      _duration = Duration.zero;
      _status = PlayerStatus.idle;
      _lastSessionSave = DateTime.fromMillisecondsSinceEpoch(0);
      _notify();

      // Segue para a próxima sobrevivente na fila (já reencaixada
      // pelo removeSongs), se ainda houver o que tocar.
      if (_playbackQueue.current != null) {
        await _playCurrent();
      }
      return;
    }

    // A faixa que tocava sobreviveu: o objeto corrente precisa
    // voltar a ser o do catálogo novo.
    if (playing != null) {
      final int idx = _songs.indexWhere((Song s) => s.id == playing.id);
      if (idx >= 0) _currentSong = _songs[idx];
    }
    _notify();
  }

  @override
  void dispose() {
    _isDisposed = true;
    _audioService.position.removeListener(_onPositionChanged);
    _audioService.duration.removeListener(_onDurationChanged);
    _audioService.status.removeListener(_onStatusChanged);
    _audioService.errorMessage.removeListener(_onErrorMessageChanged);
    // Item 3.4: sem provider não há para quem notificar a transição.
    _audioService.onQueueIndexChanged = null;
    _audioService.dispose();
    _positionNotifier.dispose();
    super.dispose();
  }
}

/// Job de [compute] (precisa de função de topo, item 2.4): ordena o
/// catálogo com a MESMA regra do caminho síncrono — naturalCompare
/// (ordem natural + sem acento, item 2.3) — fora da UI thread.
@pragma('vm:entry-point')
List<Song> sortCatalogJob(List<Song> songs) =>
    songs..sort((a, b) => naturalCompare(a.title, b.title));
