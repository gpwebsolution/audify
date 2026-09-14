import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:on_audio_query/on_audio_query.dart';

import '../models/song_model.dart';

/// Capa de álbum da faixa (MediaStore) com ícone fallback.
///
/// Reutilizada na lista e no player em tela cheia. O on_audio_query lê a
/// arte embutida no arquivo via MediaMetadataRetriever; o cache interno
/// dele evita re-leitura a cada rebuild.
class AlbumArtwork extends StatelessWidget {
  final Song song;
  final double size;
  final BorderRadius? borderRadius;
  final Color? fallbackColor;
  final IconData fallbackIcon;

  const AlbumArtwork({
    super.key,
    required this.song,
    required this.size,
    this.borderRadius,
    this.fallbackColor,
    this.fallbackIcon = Icons.music_note,
  });

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final int? mediaId = song.mediaId;
    final Radius radius = Radius.circular(size * 0.12);

    final Widget placeholder = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: fallbackColor ?? colors.surfaceContainerHighest,
        borderRadius: borderRadius ?? BorderRadius.all(radius),
      ),
      child: Icon(
        fallbackIcon,
        size: size * 0.4,
        color: colors.onSurfaceVariant,
      ),
    );

    if (mediaId == null) return placeholder;

    return FutureBuilder<Uint8List?>(
      future: OnAudioQuery().queryArtwork(mediaId, ArtworkType.AUDIO),
      builder: (context, snapshot) {
        final Uint8List? data = snapshot.data;
        if (data == null || data.isEmpty) return placeholder;
        return ClipRRect(
          borderRadius: borderRadius ?? BorderRadius.all(radius),
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