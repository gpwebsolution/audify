import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/song_model.dart';
import '../services/album_artwork_cache.dart';
import '../utils/format.dart';

/// Item da lista de músicas.
///
/// Responsabilidade: apresentação de UMA faixa — capa de álbum (ou ícone
/// fallback), título, artista e duração — com destaque visual para a faixa
/// em reprodução e o coração de favorito (item 4.1). Widget puro: recebe
/// tudo por parâmetros.
class SongListTile extends StatelessWidget {
  final Song song;
  final bool isCurrent;
  final bool isPlaying;
  final VoidCallback onTap;

  /// Long-press marca a faixa para a seleção múltipla.
  final VoidCallback? onLongPress;

  /// Abre as ações da faixa (menu de compartilhamento/exclusão/detalhes).
  ///
  /// Fica num botão explícito porque o long-press pertence à seleção — sem
  /// este botão, as ações por item ficariam inalcançáveis.
  final VoidCallback? onMenuTap;

  final Widget? trailing;

  /// Item 4.1 — coração de favorito. Sem [onFavoriteToggle] o coração não
  /// aparece (call sites antigos seguem intactos); no modo seleção ele
  /// some junto com o menu: o espaço do trailing é da ação em lote.
  final bool isFavorite;
  final VoidCallback? onFavoriteToggle;

  /// Estado de seleção múltipla. [selectionMode] ligado troca a capa pela
  /// checkbox e pinta o item — o mesmo desenho da aba Arquivos.
  final bool selected;
  final bool selectionMode;

  const SongListTile({
    super.key,
    required this.song,
    required this.isCurrent,
    required this.isPlaying,
    required this.onTap,
    this.onLongPress,
    this.onMenuTap,
    this.trailing,
    this.isFavorite = false,
    this.onFavoriteToggle,
    this.selected = false,
    this.selectionMode = false,
  });

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final bool marked = selectionMode && selected;

    // O que vai depois do coração: trailing custom (ex.: alça de
    // reordenar), o ícone da faixa tocando ou o botão de menu.
    final Widget? tail = selectionMode
        ? null
        : trailing ??
              (isCurrent
                  ? Icon(
                      isPlaying
                          ? Icons.graphic_eq
                          : Icons.pause_circle_outline,
                      color: colors.primary,
                    )
                  : onMenuTap == null
                  ? null
                  : IconButton(
                      tooltip: 'Ações da faixa',
                      icon: const Icon(Icons.more_vert),
                      onPressed: onMenuTap,
                    ));
    final bool showHeart = !selectionMode && onFavoriteToggle != null;
    final Widget? trailingWidget = !showHeart
        ? tail
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: isFavorite ? 'Desfavoritar' : 'Favoritar',
                icon: Icon(
                  isFavorite ? Icons.favorite : Icons.favorite_border,
                  color: isFavorite
                      ? colors.error
                      : colors.onSurfaceVariant,
                  size: 22,
                ),
                onPressed: onFavoriteToggle,
              ),
              ?tail,
            ],
          );

    return ListTile(
      onTap: onTap,
      onLongPress: onLongPress,
      leading: selectionMode
          ? Checkbox(
              value: selected,
              onChanged: (_) => onLongPress?.call(),
            )
          : _SongArtwork(song: song, isCurrent: isCurrent, size: 48),
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
      // Sem trailing nenhum (modo seleção, ou tile sem coração/menu)
      // o ListTile vira "só texto" — o espaço é da ação principal.
      trailing: trailingWidget,
      selected: marked || isCurrent,
      selectedTileColor: marked
          ? colors.secondaryContainer.withValues(alpha: 0.5)
          : colors.primaryContainer.withValues(alpha: 0.35),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    );
  }
}

/// Capa de álbum da faixa (MediaStore) com ícone fallback.
///
/// O on_audio_query consulta a arte embutida no arquivo via
/// MediaMetadataRetriever — o cache interno dele evita re-leitura do disco
/// a cada rebuild da lista.
class _SongArtwork extends StatefulWidget {
  final Song song;
  final bool isCurrent;
  final double size;

  const _SongArtwork({
    required this.song,
    required this.isCurrent,
    required this.size,
  });

  @override
  State<_SongArtwork> createState() => _SongArtworkState();
}

class _SongArtworkState extends State<_SongArtwork> {
  /// Carregador da capa, com o Future guardado.
  ///
  /// O `FutureBuilder` precisa receber o MESMO Future entre rebuilds: criado
  /// dentro do `build`, o snapshot anterior seria descartado (a arte pisca a
  /// cada frame) e a consulta nativa seria refeita — e a lista de músicas
  /// reconstrói a cada frame durante a reprodução. Ver [AlbumArtworkCache].
  final AlbumArtworkLoader _art = AlbumArtworkLoader();

  @override
  void didUpdateWidget(covariant _SongArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.song.mediaId != widget.song.mediaId) _art.reset();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final int? mediaId = widget.song.mediaId;

    final Widget placeholder = Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: widget.isCurrent
            ? colors.primary
            : colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(
        Icons.music_note,
        color: widget.isCurrent ? colors.onPrimary : colors.onSurfaceVariant,
      ),
    );

    if (mediaId == null) return placeholder;

    return FutureBuilder<Uint8List?>(
      future: _art.load(mediaId),
      builder: (context, snapshot) {
        final Uint8List? data = snapshot.data;
        if (data == null || data.isEmpty) return placeholder;
        return ClipRRect(
          borderRadius: BorderRadius.circular(10),
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
