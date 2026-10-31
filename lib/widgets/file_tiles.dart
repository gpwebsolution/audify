// Item 6.2 — tiles da lista/grade com miniatura, extraídos de
// lib/screens/files_screen.dart.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/file_item.dart';
import '../services/file_query_service.dart';

// =============================================================================
// TILES
// =============================================================================

class FileListTile extends StatelessWidget {
  final FileItem item;
  final bool isSelected;
  final bool selectionMode;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const FileListTile({
    super.key,
    required this.item,
    required this.isSelected,
    required this.selectionMode,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;

    return Material(
      color: isSelected && selectionMode
          ? colors.secondaryContainer.withValues(alpha: 0.5)
          : colors.surface,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              if (selectionMode)
                Checkbox(value: isSelected, onChanged: (_) => onLongPress()),
              SizedBox(width: 44, height: 44, child: FileThumbnail(item: item)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      item.isDirectory
                          ? item.displayDateModified
                          : '${formatBytes(item.size)} • ${item.displayDateModified}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                item.isDirectory ? Icons.chevron_right : Icons.open_in_new,
                size: 20,
                color: colors.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class FileGridTile extends StatelessWidget {
  final FileItem item;
  final bool isSelected;
  final bool selectionMode;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const FileGridTile({
    super.key,
    required this.item,
    required this.isSelected,
    required this.selectionMode,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;

    return Material(
      color: colors.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Container(
                    color: colors.surfaceContainerHighest,
                    alignment: Alignment.center,
                    child: SizedBox.expand(child: FileThumbnail(item: item)),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                      Text(
                        item.isDirectory ? 'Pasta' : formatBytes(item.size),
                        maxLines: 1,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (selectionMode)
              Positioned.fill(
                child: ColoredBox(
                  color: isSelected
                      ? colors.secondaryContainer.withValues(alpha: 0.55)
                      : Colors.transparent,
                  child: Align(
                    alignment: Alignment.topRight,
                    child: Checkbox(
                      value: isSelected,
                      onChanged: (_) => onLongPress(),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Miniatura por tipo: imagem decodifica direto do disco (rápido); vídeo/PDF
/// pedem ao canal nativo (com cache em memória no serviço); demais tipos usam
/// ícone por extensão.
class FileThumbnail extends StatelessWidget {
  final FileItem item;

  const FileThumbnail({super.key, required this.item});

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;

    if (item.isDirectory) {
      return Center(child: Icon(Icons.folder, color: colors.primary));
    }

    if (item.type == FileType.image) {
      final File file = File(item.path);
      return Image.file(
        file,
        fit: BoxFit.cover,
        cacheWidth: 200,
        errorBuilder: (_, _, _) =>
            Icon(Icons.image_outlined, color: colors.onSurfaceVariant),
      );
    }

    if (item.type == FileType.video || item.type == FileType.pdf) {
      return FutureBuilder<Uint8List?>(
        future: FileQueryService.getThumbnail(item.path),
        builder: (context, snapshot) {
          final bytes = snapshot.data;
          if (bytes != null && bytes.isNotEmpty) {
            return Image.memory(
              bytes,
              fit: BoxFit.cover,
              gaplessPlayback: true,
            );
          }
          return Icon(item.icon, color: colors.onSurfaceVariant);
        },
      );
    }

    return Center(child: Icon(item.icon, color: colors.onSurfaceVariant));
  }
}
