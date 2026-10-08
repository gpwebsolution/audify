import 'dart:typed_data';

import 'package:flutter/material.dart';
import '../models/song_model.dart';
import '../services/album_artwork_cache.dart';

/// Capa de álbum da faixa (MediaStore) com ícone fallback.
///
/// Reutilizada na lista e no player em tela cheia. A arte vem por
/// [AlbumArtworkCache]: o `on_audio_query` não cacheia nada, e o player
/// reconstrói a cada frame durante a reprodução — sem cache, eram centenas de
/// leituras nativas de JPEG por segundo.
class AlbumArtwork extends StatefulWidget {
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
  State<AlbumArtwork> createState() => _AlbumArtworkState();
}

class _AlbumArtworkState extends State<AlbumArtwork> {
  /// Future da capa guardado entre rebuilds (ver [AlbumArtworkCache]).
  final AlbumArtworkLoader _art = AlbumArtworkLoader();

  @override
  void didUpdateWidget(covariant AlbumArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.song.mediaId != widget.song.mediaId) _art.reset();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final int? mediaId = widget.song.mediaId;
    final Radius radius = Radius.circular(widget.size * 0.12);

    final Widget placeholder = Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: widget.fallbackColor ?? colors.surfaceContainerHighest,
        borderRadius: widget.borderRadius ?? BorderRadius.all(radius),
      ),
      child: Icon(
        widget.fallbackIcon,
        size: widget.size * 0.4,
        color: colors.onSurfaceVariant,
      ),
    );

    if (mediaId == null) return placeholder;

    return FutureBuilder<Uint8List?>(
      future: _art.load(mediaId),
      builder: (context, snapshot) {
        final Uint8List? data = snapshot.data;
        if (data == null || data.isEmpty) return placeholder;
        return ClipRRect(
          borderRadius: widget.borderRadius ?? BorderRadius.all(radius),
          child: Image.memory(
            data,
            width: widget.size,
            height: widget.size,
            fit: BoxFit.cover,
            gaplessPlayback: true,
          ),
        );
      },
    );
  }
}
