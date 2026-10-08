import 'package:flutter/material.dart' hide RepeatMode;
import 'package:provider/provider.dart';

import '../models/media_ref.dart';
import '../models/song_model.dart';
import '../providers/player_provider.dart';
import '../services/audio_service.dart';
import '../utils/format.dart';
import '../widgets/album_artwork.dart';
import 'music_screen.dart';

/// Player em tela cheia ("Agora tocando").
///
/// Responsabilidade: experiência imersiva de reprodução — capa grande,
/// título/artista, seek arrastável, tempos, shuffle/repeat e navegação de
/// fila (anterior/próximo). A leitura de estado é feita via Provider;
/// nenhuma lógica de áudio mora aqui.
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  /// Posição em ms mantida localmente durante o arrasto do slider.
  double? _dragValueMs;

  /// Exclui a faixa em reprodução (ou explica por que ela não é excluível).
  ///
  /// A decisão de "isto é uma faixa do aparelho?" fica no modelo
  /// ([MediaRef.fromSong]); aqui só há o atalho de UI para o botão.
  Future<void> _deleteCurrent(
    BuildContext context,
    PlayerProvider provider,
    Song song,
  ) async {
    if (MediaRef.fromSong(song) == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(MusicScreen.assetLockedMessage)),
      );
      return;
    }
    await MusicScreen.deleteSong(context, provider, song);
  }

  @override
  Widget build(BuildContext context) {
    final PlayerProvider provider = context.watch<PlayerProvider>();
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Song? song = provider.currentSong;

    final bool canControl = provider.hasCurrentSong;
    final bool sliderEnabled = canControl && provider.duration > Duration.zero;
    final double maxMs = provider.duration.inMilliseconds
        .clamp(1, 1 << 62)
        .toDouble();
    final double sliderValue =
        (_dragValueMs ?? provider.position.inMilliseconds.toDouble()).clamp(
          0,
          maxMs,
        );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Agora tocando'),
        actions: [
          if (song != null)
            IconButton(
              tooltip: MediaRef.fromSong(song) == null
                  ? MusicScreen.assetLockedMessage
                  : 'Excluir do aparelho',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _deleteCurrent(context, provider, song),
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // ---- Capa grande (expande no espaço restante) ----
            Expanded(
              child: Center(
                child: song == null
                    ? Icon(
                        Icons.music_note,
                        size: 120,
                        color: colors.outlineVariant,
                      )
                    : AlbumArtwork(
                        song: song,
                        size: 320,
                        fallbackColor: colors.surfaceContainerHighest,
                      ),
              ),
            ),

            // ---- Título / artista ----
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                children: [
                  Text(
                    song?.title ?? 'Nenhuma faixa selecionada',
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    song?.displayArtist ?? '',
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // ---- Slider de progresso (seek arrastável) ----
            Slider(
              value: sliderValue,
              max: maxMs,
              onChanged: sliderEnabled
                  ? (double value) {
                      setState(() => _dragValueMs = value);
                    }
                  : null,
              onChangeStart: sliderEnabled
                  ? (_) => setState(() => _dragValueMs = sliderValue)
                  : null,
              onChangeEnd: sliderEnabled
                  ? (double value) {
                      provider.seek(Duration(milliseconds: value.round()));
                      setState(() => _dragValueMs = null);
                    }
                  : null,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    formatDuration(Duration(milliseconds: sliderValue.round())),
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                  Text(
                    formatDuration(provider.duration),
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),

            // ---- Controles: shuffle / prev / play / next / repeat ----
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  IconButton(
                    tooltip: 'Embaralhar',
                    iconSize: 26,
                    color: provider.shuffle ? colors.primary : null,
                    icon: const Icon(Icons.shuffle),
                    onPressed: provider.toggleShuffle,
                  ),
                  IconButton(
                    tooltip: 'Anterior',
                    iconSize: 40,
                    icon: const Icon(Icons.skip_previous),
                    onPressed: canControl ? provider.previous : null,
                  ),
                  IconButton.filled(
                    tooltip: provider.isPlaying ? 'Pausar' : 'Tocar',
                    iconSize: 52,
                    icon: Icon(
                      provider.isPlaying
                          ? Icons.pause
                          : (provider.status == PlayerStatus.completed
                                ? Icons.replay
                                : Icons.play_arrow),
                    ),
                    onPressed: canControl ? provider.togglePlayPause : null,
                  ),
                  IconButton(
                    tooltip: 'Próxima',
                    iconSize: 40,
                    icon: const Icon(Icons.skip_next),
                    onPressed: canControl ? provider.next : null,
                  ),
                  IconButton(
                    tooltip: 'Repetir',
                    iconSize: 26,
                    color: provider.repeat != RepeatMode.off
                        ? colors.primary
                        : null,
                    icon: Icon(
                      provider.repeat == RepeatMode.one
                          ? Icons.repeat_one
                          : Icons.repeat,
                    ),
                    onPressed: provider.cycleRepeat,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
