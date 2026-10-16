import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/song_model.dart';
import '../providers/player_provider.dart';
import '../screens/player_screen.dart';
import 'album_artwork.dart';

/// Mini player fixo no rodapé da Home.
///
/// Responsabilidade: resumo da faixa atual (capa, título/artista, barra de
/// progresso), botões play/pause e próxima — e tocar no cartão abre o
/// player em tela cheia ([PlayerScreen]). Sem lógica de áudio própria.
class PlayerControls extends StatelessWidget {
  const PlayerControls({super.key});

  @override
  Widget build(BuildContext context) {
    final PlayerProvider provider = context.watch<PlayerProvider>();
    final ColorScheme colors = Theme.of(context).colorScheme;
    final Song? song = provider.currentSong;

    return Material(
      elevation: 8,
      color: colors.surfaceContainerLow,
      child: InkWell(
        onTap: song == null
            ? null
            : () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const PlayerScreen()),
                ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // ---- Barra fina de progresso ----
              // Item 2.1: só a barra consome o tick de posição (via
              // ValueListenableBuilder); o resto do mini player reconstrói
              // apenas em mudança de faixa/toque/fila.
              ValueListenableBuilder<Duration>(
                valueListenable: provider.positionListenable,
                builder: (context, position, _) {
                  final double progress = provider.duration > Duration.zero
                      ? (position.inMilliseconds /
                              provider.duration.inMilliseconds)
                          .clamp(0.0, 1.0)
                      : 0.0;
                  return LinearProgressIndicator(
                    value: progress,
                    minHeight: 3,
                    backgroundColor: colors.surfaceContainerHighest,
                  );
                },
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                child: Row(
                  children: [
                    // ---- Capa miniatura ----
                    if (song != null)
                      AlbumArtwork(song: song, size: 44)
                    else
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: colors.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(
                          Icons.music_note,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    const SizedBox(width: 12),

                    // ---- Título / artista ----
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            song?.title ?? 'Nenhuma faixa selecionada',
                            style: Theme.of(context)
                                .textTheme
                                .titleSmall
                                ?.copyWith(fontWeight: FontWeight.w600),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (song != null)
                            Text(
                              song.displayArtist,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(color: colors.onSurfaceVariant),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),

                    // ---- Play/Pause + Próxima ----
                    IconButton(
                      tooltip: provider.isPlaying ? 'Pausar' : 'Tocar',
                      icon: Icon(
                        provider.isPlaying
                            ? Icons.pause_circle_filled
                            : Icons.play_circle_filled,
                        size: 40,
                        color: colors.primary,
                      ),
                      onPressed: provider.hasCurrentSong
                          ? provider.togglePlayPause
                          : null,
                    ),
                    IconButton(
                      tooltip: 'Próxima',
                      icon: const Icon(Icons.skip_next),
                      onPressed: provider.hasNext ? provider.next : null,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}