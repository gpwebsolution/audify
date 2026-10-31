import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../models/media_ref.dart';
import '../models/video_model.dart';
import '../models/video_play_queue.dart';
import '../providers/playlist_provider.dart';
import '../providers/video_provider.dart';
import '../services/error_log_service.dart';
import '../utils/motion.dart';
import '../widgets/media_actions.dart';
import '../widgets/media_details_sheet.dart';
import '../widgets/playlist_picker_sheet.dart';
import '../widgets/video_controls.dart';
import 'videos_screen.dart';

/// Player de vídeo em tela cheia, no padrão do player de música.
///
/// Fila completa (próximo/anterior), aleatório, repetição (desligada /
/// todas / uma), rotação da tela, velocidade de reprodução, volume e
/// seek por arraste. O vídeo termina e avança sozinho conforme o modo de
/// repetição.
class VideoPlayerScreen extends StatefulWidget {
  /// Fila de vídeos (lista visível da aba) e ponto de partida.
  final List<Video> queue;
  final int initialIndex;

  const VideoPlayerScreen({
    super.key,
    required this.queue,
    required this.initialIndex,
  });

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen>
    with WidgetsBindingObserver {
  /// Fila + lógica de navegação (repetição/aleatório) — testável.
  late final VideoPlayQueue _playQueue;

  VideoPlayerController? _controller;
  bool _isPlaying = false;
  bool _dragging = false;
  Duration _dragValue = Duration.zero;
  String? _error;

  double _speed = 1.0;

  /// Volume entre 0 e 1. Persiste entre os vídeos da fila — era o
  /// comportamento desejado: trocar de vídeo não deve resetar o volume.
  double _volume = 1.0;

  /// Volume anterior ao mudo, para o toggle voltar ao ponto anterior.
  double _volumeBeforeMute = 1.0;

  /// Os controles aparecem com toque e somem sozinhos. Sem isso o vídeo fica
  /// coberto por SeekBar e botões a maior parte do tempo.
  bool _controlsVisible = true;

  /// Guarda do auto-ocultar dos controles.
  Timer? _controlsTimer;

  /// Texto do OSD (ex.: "70%", "Mudo"). Null = OSD escondido.
  String? _osd;

  /// Guarda do OSD: some sozinho para não cobrir o vídeo indefinidamente.
  Timer? _osdTimer;

  /// Ângulo de rotação do vídeo (0/90/180/270).
  int _rotation = 0;

  /// Guarda do auto-avanço: o listener dispara várias vezes no fim do
  /// vídeo; processa a conclusão uma única vez até o próximo carregamento.
  bool _completionHandled = false;

  Video get _current => _playQueue.current;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _playQueue = VideoPlayQueue(
      widget.queue,
      initialIndex: widget.initialIndex,
    );
    _initController();
  }

  /// App saiu de primeiro plano: pausa o vídeo (sem retomar sozinho).
  ///
  /// Sem isso o áudio do vídeo continua tocando com o app minimizado,
  /// competindo com a música do audio_service e desperdiçando bateria
  /// (o decodificador segue ativo).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final VideoPlayerController? controller = _controller;
    if (controller == null) return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      if (controller.value.isPlaying) {
        controller.pause();
        if (mounted) setState(() => _isPlaying = false);
      }
    }
    // resumed: NÃO retoma automaticamente — o usuário decide (padrão dos
    // players de vídeo).
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controlsTimer?.cancel();
    _osdTimer?.cancel();
    final VideoPlayerController? controller = _controller;
    controller?.removeListener(_onControllerUpdate);
    controller?.dispose();
    super.dispose();
  }

  /// Marca erro no controller atual (desanexada no dispose).
  void _onControllerError() {
    final VideoPlayerController? controller = _controller;
    if (controller != null && controller.value.hasError && mounted) {
      setState(() => _error = 'Não foi possível reproduzir este vídeo.');
    }
  }

  /// Listener de progresso: detecta o FIM do vídeo e avança conforme o
  /// modo de repetição (uma -> replay; todos/off -> próxima; sem próxima
  /// -> pausa no último frame).
  void _onControllerUpdate() {
    final VideoPlayerController? controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (controller.value.hasError) {
      _onControllerError();
      return;
    }
    if (!controller.value.isCompleted || _completionHandled) return;
    _completionHandled = true;

    if (_playQueue.repeatMode == VideoRepeatMode.one) {
      // catchError: o controller pode ter sido descartado entre o seek e
      // o play (troca rápida de vídeo) — erro assíncrono não tratado
      // aqui escaparia para a zona.
      controller
          .seekTo(Duration.zero)
          .then((_) => controller.play())
          .catchError(
            (Object e, StackTrace s) =>
                ErrorLogService.logSync('video/replay', e, s),
          );
    } else {
      _next();
    }
  }

  /// Exclui o vídeo em reprodução e sai da tela.
  ///
  /// A lógica de exclusão é a de [VideosScreen.deleteVideo] (uma fonte só);
  /// aqui o que é específico é o [onBeforeDelete], que descarta o
  /// [VideoPlayerController] ANTES do diálogo do sistema. Com o decoder
  /// segurando o arquivo aberto, a remoção falha silenciosamente no Android.
  Future<void> _deleteCurrent(BuildContext context) async {
    final NavigatorState navigator = Navigator.of(context);
    final Video video = _current;
    bool removed = false;

    await VideosScreen.deleteVideo(
      context,
      context.read<VideoProvider>(),
      video,
      onBeforeDelete: _releaseController,
      onDeleted: (List<MediaRef> _) async => removed = true,
    );
    if (!mounted) return;

    if (removed) {
      _playQueue.removeVideos(<int>{video.id});
      if (navigator.mounted && navigator.canPop()) navigator.pop();
      return;
    }

    // Cancelou no diálogo do SO ou a exclusão falhou: o controller já foi
    // descartado, então recria para o player voltar a funcionar.
    await _initController();
  }

  /// Pausa e descarta o controller atual (libera o arquivo no SO).
  Future<void> _releaseController() async {
    final VideoPlayerController? controller = _controller;
    if (controller == null) return;
    _controller = null;
    controller.removeListener(_onControllerUpdate);
    try {
      if (controller.value.isInitialized) await controller.pause();
      await controller.dispose();
    } catch (e, s) {
      ErrorLogService.logSync('video/release', e, s);
    }
    if (mounted) {
      setState(() {
        _isPlaying = false;
        _error = null;
      });
    }
  }

  Future<void> _initController() async {
    _error = null;
    final File file = File(_current.path);
    if (!await file.exists()) {
      if (mounted) {
        setState(() => _error = 'Arquivo não encontrado no aparelho.');
      }
      return;
    }

    final VideoPlayerController controller = VideoPlayerController.file(file);
    _controller = controller;
    controller.addListener(_onControllerUpdate);

    try {
      await controller.initialize();
      await controller.setPlaybackSpeed(_speed);
      await controller.setVolume(_volume);
      await controller.play();
      if (mounted) setState(() => _isPlaying = true);
    } catch (e, s) {
      ErrorLogService.logSync('video/init', e, s);
      if (mounted) {
        setState(() => _error = 'Não foi possível reproduzir este vídeo.');
      }
    }
  }

  Future<void> _loadVideo(int newIndex) async {
    if (newIndex < 0 || newIndex >= _playQueue.length) return;
    _playQueue.index = newIndex;
    _rotation = 0;
    _completionHandled = false;
    final VideoPlayerController? old = _controller;
    old?.removeListener(_onControllerUpdate);
    await old?.dispose();
    _controller = null;
    if (!mounted) return;
    setState(() {});
    await _initController();
  }

  Future<void> _togglePlay() async {
    final VideoPlayerController? controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (controller.value.isPlaying) {
      await controller.pause();
      if (mounted) setState(() => _isPlaying = false);
    } else {
      // Terminou com repetição desligada: recomeça do início.
      if (controller.value.position >= controller.value.duration) {
        await controller.seekTo(Duration.zero);
      }
      await controller.play();
      if (mounted) setState(() => _isPlaying = true);
    }
    // Voltar a reproduzir (ou pausar) sempre traz a UI de volta.
    _showControls();
  }

  Future<void> _next() async {
    final Video? next = _playQueue.next();
    if (next != null) {
      await _loadVideo(_playQueue.index);
      return;
    }
    // Fim da fila sem repetir: pausa no último frame.
    final VideoPlayerController? controller = _controller;
    if (controller != null && controller.value.isInitialized) {
      await controller.pause();
      if (mounted) setState(() => _isPlaying = false);
    }
  }

  Future<void> _previous() async {
    final VideoPlayerController? controller = _controller;
    // Se passou de ~3s, volta ao início do vídeo atual (padrão de players).
    if (controller != null &&
        controller.value.isInitialized &&
        controller.value.position.inSeconds > 3) {
      await controller.seekTo(Duration.zero);
      return;
    }
    final Video? previous = _playQueue.previous();
    if (previous != null) {
      await _loadVideo(_playQueue.index);
    }
  }

  void _toggleShuffle() {
    setState(() => _playQueue.toggleShuffle());
  }

  void _cycleRepeat() {
    setState(() => _playQueue.cycleRepeat());
  }

  Future<void> _setSpeed(double speed) async {
    setState(() => _speed = speed);
    await _controller?.setPlaybackSpeed(speed);
  }

  /// Aplica o volume e mostra o OSD — é o feedback que faltava: sem ele o
  /// usuário arrasta o controle e não recebe nenhuma confirmação.
  Future<void> _setVolume(double volume) async {
    final double clamped = volume.clamp(0.0, 1.0);
    if (clamped > 0) _volumeBeforeMute = clamped;
    setState(() => _volume = clamped);
    await _controller?.setVolume(clamped);
    _showOsd(clamped == 0 ? 'Mudo' : '${(clamped * 100).round()}%');
    _showControls();
  }

  /// Alterna mudo ↔ o volume anterior.
  Future<void> _toggleMute() async {
    await _setVolume(_volume == 0 ? _volumeBeforeMute : 0);
  }

  /// Mostra uma mensagem no centro do vídeo por [Motion.osdLinger].
  void _showOsd(String message) {
    _osdTimer?.cancel();
    setState(() => _osd = message);
    _osdTimer = Timer(Motion.osdLinger, () {
      if (mounted) setState(() => _osd = null);
    });
  }

  /// Revela os controles e reagenda o auto-ocultar.
  ///
  /// Reproduzindo, eles somem sozinhos; pausado, ficam na tela (não faz
  /// sentido escondê-los quando não há vídeo correndo).
  void _showControls() {
    _controlsTimer?.cancel();
    if (mounted && !_controlsVisible) setState(() => _controlsVisible = true);
    if (!_isPlaying || _dragging) return;
    _controlsTimer = Timer(Motion.controlsLinger, () {
      if (mounted && _isPlaying && !_dragging) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  /// Item 4.4 — escolhe a playlist no seletor (com "Nova playlist"
  /// embutida) e adiciona o vídeo em reprodução.
  Future<void> _addToPlaylist(
    BuildContext context,
    PlaylistProvider playlists,
    Video video,
  ) async {
    await showPlaylistPickerSheet(
      context,
      onPick: (Playlist playlist) async {
        await playlists.addVideo(playlist.id, video);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Adicionado a "${playlist.name}"')),
          );
        }
      },
      subtitleOf: (Playlist playlist) => '${playlist.videoCount} vídeos',
    );
  }

  /// Menu de ações do vídeo em reprodução.
  ///
  /// Reúne compartilhar, detalhes, adicionar à playlist e excluir num só
  /// lugar. Ação impossível vem desabilitada COM o motivo, em vez de sumir —
  /// o mesmo cuidado do player de música.
  Future<void> _showVideoActions(BuildContext context) async {
    final Video video = _current;
    final PlaylistProvider playlists = context.read<PlaylistProvider>();
    final NavigatorState navigator = Navigator.of(context);

    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext sheetContext) {
        void go(Future<void> Function() action) {
          Navigator.pop(sheetContext);
          action();
        }

        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: <Widget>[
              ListTile(
                leading: const Icon(Icons.playlist_add),
                title: const Text('Adicionar à playlist'),
                onTap: () =>
                    go(() => _addToPlaylist(context, playlists, video)),
              ),
              ListTile(
                leading: const Icon(Icons.share_outlined),
                title: const Text('Compartilhar'),
                subtitle: const Text('WhatsApp, Messenger e outros'),
                onTap: () => go(
                  () => MediaActions.share(
                    context,
                    path: video.path,
                    name: video.displayName,
                    mimeType: 'video/mp4',
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: const Text('Detalhes'),
                subtitle: const Text('Duração, tamanho, resolução e caminho'),
                onTap: () =>
                    go(() => MediaDetailsSheet.showVideo(context, video)),
              ),
              const Divider(),
              ListTile(
                leading: Icon(
                  Icons.delete_outline,
                  color: Theme.of(context).colorScheme.error,
                ),
                title: Text(
                  'Excluir do aparelho',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                subtitle: const Text('Some da lista e das playlists'),
                onTap: () => go(() async {
                  await _deleteCurrent(context);
                  if (navigator.mounted && navigator.canPop()) {
                    navigator.pop();
                  }
                }),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Um toque no vídeo: mostra os controles ou os esconde. Toque em play/pause
  /// além de alternar a reprodução também reacende a UI.
  void _toggleControlsVisibility() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) {
      _showControls();
    } else {
      _controlsTimer?.cancel();
    }
  }

  void _rotate() {
    setState(() => _rotation = (_rotation + 90) % 360);
  }

  /// Ajusta o rotacionado do vídeo (largura/altura trocam a 90/270°).
  Size _rotatedSize(Size original) {
    if (_rotation == 90 || _rotation == 270) {
      return Size(original.height, original.width);
    }
    return original;
  }

  @override
  Widget build(BuildContext context) {
    final VideoPlayerController? controller = _controller;
    final bool ready = controller != null && controller.value.isInitialized;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          _current.displayTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          // ---- Menu de ações do vídeo ----
          // Substitui a lixeira isolada: as ações do vídeo ficam aqui, que é
          // onde o usuário já está. Mesmo padrão do player de música e do
          // visualizador de fotos.
          IconButton(
            tooltip: 'Ações do vídeo',
            icon: const Icon(Icons.more_vert),
            onPressed: () => _showVideoActions(context),
          ),
          // ---- Girar vídeo ----
          IconButton(
            tooltip: 'Girar ($_rotation°)',
            icon: const Icon(Icons.screen_rotation_outlined),
            onPressed: _rotate,
          ),
          // ---- Repetição ----
          IconButton(
            tooltip: _playQueue.repeatMode.label,
            icon: Icon(
              _playQueue.repeatMode.icon,
              color: _playQueue.repeatMode == VideoRepeatMode.off
                  ? Colors.white70
                  : Colors.amberAccent,
            ),
            onPressed: _cycleRepeat,
          ),
          // ---- Aleatório ----
          IconButton(
            tooltip: _playQueue.shuffle
                ? 'Aleatório ligado'
                : 'Aleatório desligado',
            icon: Icon(
              Icons.shuffle,
              color: _playQueue.shuffle ? Colors.amberAccent : Colors.white70,
            ),
            onPressed: _toggleShuffle,
          ),
        ],
      ),
      body: _error != null
          ? VideoErrorState(message: _error!)
          : Center(
              child: ready
                  ? GestureDetector(
                      // Um toque no vídeo alterna a UI (padrão de todo
                      // player); o play/pause do toque duplo continua
                      // acessível pelo botão grande e pela barra inferior.
                      onTap: _toggleControlsVisibility,
                      onDoubleTap: _togglePlay,
                      child: AspectRatio(
                        aspectRatio: _rotatedSize(
                          controller.value.size,
                        ).aspectRatio,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            // Rotação visual (0/90/180/270).
                            Transform.rotate(
                              angle: _rotation * math.pi / 180,
                              child: VideoPlayer(controller),
                            ),

                            // ---- OSD (volume, etc.) ----
                            VideoVolumeOsd(message: _osd, volume: _volume),

                            // ---- Botão de play/pause central ----
                            FadeInOut(
                              visible: !_isPlaying,
                              child: PressPulse(
                                child: IconButton(
                                  onPressed: _togglePlay,
                                  iconSize: 72,
                                  icon: const Icon(Icons.play_circle_fill),
                                  color: Colors.white.withValues(alpha: 0.85),
                                  tooltip: 'Reproduzir',
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  : const CircularProgressIndicator(color: Colors.white70),
            ),
      // A barra some sozinha durante a reprodução e volta em qualquer toque.
      bottomNavigationBar: ready
          ? FadeInOut(
              visible: _controlsVisible,
              child: ValueListenableBuilder<VideoPlayerValue>(
                valueListenable: controller,
                builder: (context, value, _) {
                  final Duration position = _dragging
                      ? _dragValue
                      : value.position;
                  return VideoControlsBar(
                    position: position,
                    duration: value.duration,
                    isPlaying: value.isPlaying,
                    speed: _speed,
                    volume: _volume,
                    onTogglePlay: _togglePlay,
                    onPrevious: _previous,
                    onNext: _next,
                    onSeekStart: (v) {
                      setState(() {
                        _dragging = true;
                        _dragValue = v;
                      });
                    },
                    onSeekUpdate: (v) => setState(() => _dragValue = v),
                    onSeekEnd: (v) async {
                      await controller.seekTo(v);
                      setState(() {
                        _dragging = false;
                        _dragValue = v;
                      });
                      _showControls();
                    },
                    onSpeedSelected: _setSpeed,
                    onVolumeChanged: _setVolume,
                    onToggleMute: _toggleMute,
                  );
                },
              ),
            )
          : null,
    );
  }
}
