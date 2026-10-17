// Item 6.2 — widgets do player de vídeo extraídos de
// lib/screens/video_player_screen.dart (OSD de volume, barra de controles e
// estado de erro). Contrato visual idêntico ao pré-extração.

import 'package:flutter/material.dart';

import '../utils/format.dart';
import '../utils/motion.dart';

/// Aviso visual de volume no centro do vídeo (o "OSD" dos players).
///
/// Aparece com fade+escala a cada mexida no volume e some sozinho. Mostra o
/// ícone correspondente ao nível (mudo/baixo/médio/alto) e o percentual, para
/// que o usuário saiba exatamente onde parou.
class VideoVolumeOsd extends StatelessWidget {
  /// Texto a exibir (ex.: "70%"). Null = escondido.
  final String? message;

  /// Volume atual, usado para escolher o ícone.
  final double volume;

  const VideoVolumeOsd({super.key, required this.message, required this.volume});

  static IconData _iconFor(double value) {
    if (value <= 0.001) return Icons.volume_off;
    if (value < 0.34) return Icons.volume_mute;
    if (value < 0.67) return Icons.volume_down;
    return Icons.volume_up;
  }

  @override
  Widget build(BuildContext context) {
    final String? text = message;
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: text == null ? 0 : 1,
        duration: Motion.scale(
          context,
          text == null ? Motion.fast : Motion.normal,
        ),
        curve: text == null ? Motion.exit : Motion.enter,
        child: AnimatedScale(
          scale: text == null ? 0.85 : 1,
          duration: Motion.scale(context, Motion.normal),
          curve: Motion.enter,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedContentSwitcher(
                  value: _iconFor(volume),
                  child: Icon(_iconFor(volume), color: Colors.white, size: 34),
                ),
                const SizedBox(height: 6),
                // Altura reservada para o texto: sem isso o OSD "pula" quando
                // o texto some (volume muda de 2 dígitos para 1).
                SizedBox(
                  height: 22,
                  child: AnimatedContentSwitcher(
                    value: text ?? '',
                    child: Text(
                      text ?? '',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Barra de controles do rodapé: seek + tempos + transporte + extras.
class VideoControlsBar extends StatelessWidget {
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
  final VoidCallback onToggleMute;

  const VideoControlsBar({super.key, 
    required this.position,
    required this.duration,
    required this.isPlaying,
    required this.speed,
    required this.volume,
    required this.onToggleMute,
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
                // Slider fixo + botão de mudo. Antes era um Slider dentro de
                // um PopupMenuItem (menu que não fecha, área de toque ruim e
                // nenhum retorno visual) — o usuário arrastava sem ver nada
                // acontecer.
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: volume == 0 ? 'Reativar som' : 'Silenciar',
                      onPressed: onToggleMute,
                      color: Colors.white,
                      icon: Icon(
                        volume <= 0.001
                            ? Icons.volume_off
                            : volume < 0.34
                            ? Icons.volume_mute
                            : volume < 0.67
                            ? Icons.volume_down
                            : Icons.volume_up,
                      ),
                    ),
                    // Largura fixa para o slider não respirar junto com o
                    // resto da barra durante o arraste.
                    SizedBox(
                      width: 110,
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          activeTrackColor: Colors.white,
                          inactiveTrackColor: Colors.white24,
                          thumbColor: Colors.white,
                          overlayColor: Colors.white24,
                        ),
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

class VideoErrorState extends StatelessWidget {
  final String message;

  const VideoErrorState({super.key, required this.message});

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
