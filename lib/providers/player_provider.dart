import 'package:flutter/foundation.dart';

import '../models/repeat_mode.dart';
import '../models/song_model.dart';
import '../repositories/session_repository.dart';
import '../repositories/song_repository.dart';
import '../services/audio_service.dart';
import '../services/permission_service.dart';
import '../utils/playback_queue.dart';
import 'settings_provider.dart';

export '../models/repeat_mode.dart' show RepeatMode;

/// Estado da permissão de acesso às músicas do aparelho.
enum AudioPermissionState { unknown, granted, denied, permanentlyDenied }

/// Gerenciamento de estado central do player.
///
/// Responsabilidade: orquestrar a camada de áudio, o catálogo (MediaStore +
/// assets) e a fila de reprodução, expondo à UI um único modelo consumível
/// via `context.watch<PlayerProvider>()`.
///
/// Fila: a lista "visível" (após busca) é a fila de reprodução. Tocar uma
/// faixa monta a ordem — sequencial ou embaralhada (shuffle) — e próximo/
/// anterior navegam nela, com avanço automático no fim da faixa.
class PlayerProvider extends ChangeNotifier {
  final AudioService _audioService;
  final SettingsProvider? settings;
  final SongRepository _songRepository;
  final SessionRepository _sessionRepository;
  final PlaybackQueue _playbackQueue;

  List<Song> _songs = const [];
  List<Song> _visibleSongs = const [];
  String _searchQuery = '';
  AudioPermissionState _permission = AudioPermissionState.unknown;

  /// Último instante em que a sessão foi persistida (throttle de 5s).
  DateTime _lastSessionSave = DateTime.fromMillisecondsSinceEpoch(0);

  Song? _currentSong;

  Duration _position = Duration.zero;
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

  Duration get position => _position;

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
  }) : _songRepository = songRepository ?? SongRepository(),
       _sessionRepository = sessionRepository ?? SessionRepository(),
       _playbackQueue = playbackQueue ?? PlaybackQueue() {
    // Botões da notificação/tela de bloqueio (audio_service) delegam a
    // navegação da fila para este provider.
    _audioService.onSkipToNext = next;
    _audioService.onSkipToPrevious = previous;
    _audioService.position.addListener(_onPositionChanged);
    _audioService.duration.addListener(_onDurationChanged);
    _audioService.status.addListener(_onStatusChanged);
    _audioService.errorMessage.addListener(_onErrorMessageChanged);

    init();
  }

  /// Fluxo de inicialização: permissões -> catálogo -> fila.
  Future<void> init() async {
    _isLoading = true;
    _notify();

    _permission = _mapResult(await PermissionService.requestAudioAccess());
    // Permissões de vídeo + galeria (um dialog do sistema, não bloqueante
    // para a biblioteca de música).
    await PermissionService.requestMediaGroup();
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
      ]..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
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

  /// Atualiza o termo de busca e reaplica o filtro na lista/fila.
  void setSearchQuery(String query) {
    _searchQuery = query.trim();
    _applySearchFilter();
  }

  void _applySearchFilter() {
    final String q = _searchQuery.toLowerCase();
    _visibleSongs = q.isEmpty
        ? List.of(_songs)
        : _songs.where((s) {
            final inTitle = s.title.toLowerCase().contains(q);
            final inArtist = (s.artist ?? '').toLowerCase().contains(q);
            final inAlbum = (s.album ?? '').toLowerCase().contains(q);
            return inTitle || inArtist || inAlbum;
          }).toList();
    _rebuildQueue();
  }

  /// Reconstrói a fila de reprodução na ordem atual (respeita shuffle).
  void _rebuildQueue() {
    _playbackQueue.rebuild(_visibleSongs, keepCurrent: _currentSong);
  }

  /// Toca a faixa da lista visível pelo índice da UI.
  Future<void> playVisibleAt(int index) async {
    if (index < 0 || index >= _visibleSongs.length) return;
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
    _playbackQueue.setQueue(queue, startIndex);
    await _playCurrent();
  }

  Future<void> _playCurrent() async {
    final Song? song = _playbackQueue.current;
    if (song == null) return;
    _currentSong = song;
    _position = Duration.zero;
    _duration = Duration.zero;
    _notify(); // destaca a faixa imediatamente
    await _audioService.playSong(song);
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
    if (_position > const Duration(seconds: 3)) {
      return seek(Duration.zero);
    }
    final int? prevIndex = _playbackQueue.previousIndex();
    if (prevIndex == null) return seek(Duration.zero);
    _playbackQueue.setIndex(prevIndex);
    await _playCurrent();
  }

  void toggleShuffle() {
    _playbackQueue.toggleShuffle();
    _notify();
  }

  void cycleRepeat() {
    _playbackQueue.cycleRepeat();
    _notify();
  }

  void _onPositionChanged() {
    _position = _audioService.position.value;
    _maybeSaveSession();
    _notify();
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
      _position = Duration.zero;
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
    _position = svc.position.value;
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
    _position = Duration.zero;
    _notify();
  }

  /// Envia seek ao player (valor vem do Slider arrastado).
  Future<void> seek(Duration target) async {
    await _audioService.seek(target);
  }

  // ------------------------------------------------------------------
  // Sessão: "continuar de onde parou" (preferência em Configurações).
  // ------------------------------------------------------------------

  /// Restaura a última faixa tocada (posição salva, sem autoplay).
  Future<void> _restoreSession() async {
    final SettingsProvider? prefs = settings;
    if (prefs == null || !prefs.resumePlayback) return;
    if (_songs.isEmpty) return;

    final (Song?, Duration) stored = await _sessionRepository.load();
    final Song? saved = stored.$1;
    if (saved == null) return;

    // Só restaura se a faixa ainda existir no catálogo atual.
    final int idx = _songs.indexWhere((s) => s.id == saved.id);
    if (idx < 0) return;

    _currentSong = _songs[idx];
    _position = stored.$2;
    _playbackQueue.setQueue(_songs, idx);
    _notify();
  }

  /// Persiste faixa + posição (throttle de 5s durante a reprodução).
  Future<void> _saveSession() async {
    final Song? song = _currentSong;
    if (song == null) return;
    await _sessionRepository.save(song, _position);
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

    // Sucessor escolhido ANTES de remover, para não depender do índice
    // antigo nem da lista já filtrada.
    final List<Song> survivors = _playbackQueue.queue
        .where((Song s) => !ids.contains(s.id))
        .toList();
    Song? successor;
    if (removedCurrent && survivors.isNotEmpty) {
      final int current = _playbackQueue.queueIndex;
      successor = current < 0 || _playbackQueue.shuffle
          ? survivors.first
          : survivors[current.clamp(0, survivors.length - 1)];
    }

    _songs = _songs.where((Song s) => !ids.contains(s.id)).toList();
    _applySearchFilter(); // refiltra e reconstrói a fila (notify incluso)

    if (removedCurrent) {
      // A sessão salva aponta para um arquivo morto: some com ela. Só quando
      // a excluída era a que tocava — excluir outra faixa não pode derrubar o
      // "continuar de onde parou" de uma música que continua no aparelho.
      await _sessionRepository.clear();

      await _audioService.stop();
      _currentSong = null;
      _position = Duration.zero;
      _duration = Duration.zero;
      _status = PlayerStatus.idle;
      _lastSessionSave = DateTime.fromMillisecondsSinceEpoch(0);
      _notify();

      final int nextIndex = successor == null
          ? -1
          : _visibleSongs.indexWhere((Song s) => s.id == successor!.id);
      if (nextIndex >= 0) await playVisibleAt(nextIndex);
      return;
    }

    // A faixa que tocava sobreviveu: a fila já foi reencaixada, mas o
    // objeto corrente precisa voltar a ser o da lista nova.
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
    super.dispose();
  }
}
