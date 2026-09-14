import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../models/video_model.dart';
import '../models/video_play_queue.dart';
import '../services/error_log_service.dart';
import '../utils/format.dart';

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
  double _volume = 1.0;

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
          .catchError((Object e, StackTrace s) =>
              ErrorLogService.logSync('video/replay', e, s));
    } else {
      _next();
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

  Future<void> _setVolume(double volume) async {
    setState(() => _volume = volume);
    await _controller?.setVolume(volume);
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
          ? _ErrorState(message: _error!)
          : Center(
              child: ready
                  ? GestureDetector(
                      onTap: _togglePlay,
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
                            if (!_isPlaying)
                              Icon(
                                Icons.play_circle_fill,
                                size: 72,
                                color: Colors.white.withValues(alpha: 0.85),
                              ),
                          ],
                        ),
                      ),
                    )
                  : const CircularProgressIndicator(color: Colors.white70),
            ),
      bottomNavigationBar: ready
          ? ValueListenableBuilder<VideoPlayerValue>(
              valueListenable: controller,
              builder: (context, value, _) {
                final Duration position = _dragging
                    ? _dragValue
                    : value.position;
                return _ControlsBar(
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
                  },
                  onSpeedSelected: _setSpeed,
                  onVolumeChanged: _setVolume,
                );
              },
            )
          : null,
    );
  }
}

/// Barra de controles do rodapé: seek + tempos + transporte + extras.
class _ControlsBar extends StatelessWidget {
  final Duration position;
  final Duration duration;
  final bool isPlaying;
  final double speed;
  final double volume;
  final VoidCallback onTogglePlay;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final ValueChanged<Duration> onSeekStart;
  final ValueChanged<Duration> onSeekUpdate;
  final ValueChanged<Duration> onSeekEnd;
  final ValueChanged<double> onSpeedSelected;
  final ValueChanged<double> onVolumeChanged;

  const _ControlsBar({
    required this.position,
    required this.duration,
    required this.isPlaying,
    required this.speed,
    required this.volume,
    required this.onTogglePlay,
    required this.onPrevious,
    required this.onNext,
    required this.onSeekStart,
    required this.onSeekUpdate,
    required this.onSeekEnd,
    required this.onSpeedSelected,
    required this.onVolumeChanged,
  });

  @override
  Widget build(BuildContext context) {
    final double totalMs = duration.inMilliseconds.toDouble();
    final double posMs = position.inMilliseconds.clamp(0, totalMs).toDouble();

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ---- Seek + tempos ----
            Row(
              children: [
                Text(
                  formatDuration(position),
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
                Expanded(
                  child: SliderTheme(
                    data: SliderThemeData(
                      trackHeight: 2,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 6,
                      ),
                      overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 12,
                      ),
                    ),
                    child: Slider(
                      value: posMs,
                      max: totalMs > 0 ? totalMs : 1,
                      onChanged: (v) {
                        onSeekStart(Duration(milliseconds: v.round()));
                        onSeekUpdate(Duration(milliseconds: v.round()));
                      },
                      onChangeEnd: (v) =>
                          onSeekEnd(Duration(milliseconds: v.round())),
                    ),
                  ),
                ),
                Text(
                  formatDuration(duration),
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ],
            ),
            // ---- Transporte ----
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                IconButton(
                  tooltip: 'Anterior',
                  iconSize: 34,
                  color: Colors.white,
                  icon: const Icon(Icons.skip_previous),
                  onPressed: onPrevious,
                ),
                IconButton(
                  tooltip: isPlaying ? 'Pausar' : 'Tocar',
                  iconSize: 52,
                  color: Colors.white,
                  icon: Icon(
                    isPlaying
                        ? Icons.pause_circle_filled
                        : Icons.play_circle_fill,
                  ),
                  onPressed: onTogglePlay,
                ),
                IconButton(
                  tooltip: 'Próximo',
                  iconSize: 34,
                  color: Colors.white,
                  icon: const Icon(Icons.skip_next),
                  onPressed: onNext,
                ),
                // ---- Velocidade ----
                PopupMenuButton<double>(
                  tooltip: 'Velocidade ${speed}x',
                  color: Colors.grey[900],
                  icon: Text(
                    '${speed}x',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  onSelected: onSpeedSelected,
                  itemBuilder: (_) => [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
                      .map(
                        (s) => PopupMenuItem<double>(
                          value: s,
                          child: Text(
                            '${s}x',
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                      )
                      .toList(),
                ),
                // ---- Volume ----
                PopupMenuButton<void>(
                  tooltip: 'Volume',
                  color: Colors.grey[900],
                  icon: const Icon(Icons.volume_up, color: Colors.white),
                  onSelected: (_) {},
                  itemBuilder: (context) => [
                    PopupMenuItem<void>(
                      enabled: false,
                      child: SizedBox(
                        width: 160,
                        child: Slider(
                          value: volume.clamp(0.0, 1.0),
                          onChanged: onVolumeChanged,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;

  const _ErrorState({required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.videocam_off_outlined,
            size: 64,
            color: Colors.white54,
          ),
          const SizedBox(height: 12),
          Text(
            message,
            style: const TextStyle(color: Colors.white70),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
