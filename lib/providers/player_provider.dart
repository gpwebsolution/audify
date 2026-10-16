import 'package:flutter/foundation.dart';

import '../models/repeat_mode.dart';
import '../models/song_model.dart';
import '../repositories/session_repository.dart';
import '../repositories/song_repository.dart';
import '../services/audio_service.dart';
import '../services/error_log_service.dart';
import '../services/permission_service.dart';
import '../utils/playback_queue.dart';
import '../utils/text_normalize.dart';
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

  /// Se há uma próxima faixa na fila (respecta repeat/shuffle).
  bool get hasNext => _playbackQueue.nextIndex() != null;

  PlayerProvider(
    this._audioService, {
    this.settings,
    SongRepository? songRepository,
    SessionRepository? sessionRepository,
    PlaybackQueue? playbackQueue,
    Future<void> Function()? requestNotificationPermission,
  }) : _songRepository = songRepository ?? SongRepository(),
       _sessionRepository = sessionRepository ?? SessionRepository(),
       _playbackQueue = playbackQueue ?? PlaybackQueue(),
       _requestNotificationPermission = requestNotificationPermission ??
           PermissionService.requestNotificationAccess {
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
    }

    init();
  }

  /// Fluxo de inicialização: permissões -> catálogo -> fila.
  Future<void> init() async {
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
    await _loadSongs(includeDevice: true);
    await _restoreSession();
  }

  /// (Re)carrega o catálogo e reconstrói a fila.
  Future<void> _loadSongs({required bool includeDevice}) async {
    try {
      final List<Song> device = includeDevice
          ? await _songRepository.loadDeviceSongs()
          : const [];
      final List<Song> assets = await _songRepository.loadAssetSongs();
      _songs = [
        ...device,
        ...assets,
      // Item 2.3: ordem natural + sem acento — 'Faixa 2' antes de
      // 'Faixa 10' e 'Ação' no lugar de 'Zebra' (antes: 'Zebra' vinha
      // primeiro porque 'á' > 'z' em código de ponto).
      ]..sort((a, b) => naturalCompare(a.title, b.title));
      _applySearchFilter();
    } catch (e) {
      _errorMessage = 'Falha ao carregar a lista de músicas: $e';
    } finally {
      _isLoading = false;
      _notify();
    }
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
    await _audioService.playSong(song);
    // playSong limpa errorMessage no início e só o repreenche em falha:
    // abrir com sucesso zera o contador de falhas seguidas.
    if (_audioService.errorMessage.value == null) {
      _consecutivePlayFailures = 0;
    }
    // Mantém a fila/índice/modos do MediaSession sincronizados com o
    // que está tocando (Bluetooth/Android Auto leem daqui).
    _publishQueueToService();
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
  Future<void> _onTrackCompleted() async {
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
    _audioService.dispose();
    _positionNotifier.dispose();
    super.dispose();
  }
}
