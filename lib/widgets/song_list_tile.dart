import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:on_audio_query/on_audio_query.dart';

import '../models/song_model.dart';
import '../utils/format.dart';

/// Item da lista de músicas.
///
/// Responsabilidade: apresentação de UMA faixa — capa de álbum (ou ícone
/// fallback), título, artista e duração — com destaque visual para a faixa
/// em reprodução. Widget puro: recebe tudo por parâmetros.
class SongListTile extends StatelessWidget {
  final Song song;
  final bool isCurrent;
  final bool isPlaying;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final Widget? trailing;

  const SongListTile({
    super.key,
    required this.song,
    required this.isCurrent,
    required this.isPlaying,
    required this.onTap,
    this.onLongPress,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;

    return ListTile(
      onTap: onTap,
      onLongPress: onLongPress,
      leading: _SongArtwork(song: song, isCurrent: isCurrent, size: 48),
      title: Text(
        song.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: isCurrent ? colors.primary : colors.onSurface,
          fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
        ),
      ),
      subtitle: Text(
        [
          song.displayArtist,
          if (song.duration != null) formatDuration(song.duration!),
        ].join(' • '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: trailing ??
          (isCurrent
              ? Icon(
                  isPlaying ? Icons.graphic_eq : Icons.pause_circle_outline,
                  color: colors.primary,
                )
              : null),
      selected: isCurrent,
      selectedTileColor: colors.primaryContainer.withValues(alpha: 0.35),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    );
  }
}

/// Capa de álbum da faixa (MediaStore) com ícone fallback.
///
/// O on_audio_query consulta a arte embutida no arquivo via
/// MediaMetadataRetriever — o cache interno dele evita re-leitura do disco
/// a cada rebuild da lista.
class _SongArtwork extends StatelessWidget {
  final Song song;
  final bool isCurrent;
  final double size;

  const _SongArtwork({
    required this.song,
    required this.isCurrent,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final int? mediaId = song.mediaId;

    final Widget placeholder = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: isCurrent ? colors.primary : colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(
        Icons.music_note,
        color: isCurrent ? colors.onPrimary : colors.onSurfaceVariant,
      ),
    );

    if (mediaId == null) return placeholder;

    return FutureBuilder<Uint8List?>(
      future: OnAudioQuery().queryArtwork(mediaId, ArtworkType.AUDIO),
      builder: (context, snapshot) {
        final Uint8List? data = snapshot.data;
        if (data == null || data.isEmpty) return placeholder;
        return ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.memory(
            data,
            width: size,
            height: size,
            fit: BoxFit.cover,
            gaplessPlayback: true,
          ),
        );
      },
    );
  }
}