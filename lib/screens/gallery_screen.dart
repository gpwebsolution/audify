import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/gallery_image_model.dart';
import '../models/image_album.dart';
import '../providers/gallery_provider.dart';
import '../services/gallery_query_service.dart';
import '../widgets/media_actions.dart';
import 'photo_viewer_screen.dart';

/// Aba de Galeria: fotos do aparelho (MediaStore) em grade.
class GalleryScreen extends StatefulWidget {
  const GalleryScreen({super.key});

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  final TextEditingController _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final GalleryProvider provider = context.watch<GalleryProvider>();

    return Column(
      children: [
        // ---- Busca ----
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: TextField(
            controller: _searchController,
            onChanged: provider.setSearchQuery,
            decoration: InputDecoration(
              hintText: 'Buscar foto',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: provider.searchQuery.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Limpar busca',
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _searchController.clear();
                        provider.setSearchQuery('');
                      },
                    ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(28),
                borderSide: BorderSide.none,
              ),
              filled: true,
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ),
        Expanded(child: _buildBody(context, provider)),
      ],
    );
  }

  Widget _buildBody(BuildContext context, GalleryProvider provider) {
    if (!Platform.isAndroid) {
      return const _EmptyState(
        icon: Icons.photo_library_outlined,
        message: 'Galeria disponível apenas no Android.',
      );
    }

    if (provider.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (provider.images.isEmpty) {
      return const _EmptyState(
        icon: Icons.photo_outlined,
        message: 'Nenhuma foto encontrada no aparelho.\n'
            'Tire ou salve fotos para vê-las aqui.',
      );
    }

    return Column(
      children: [
        if (provider.albums.isNotEmpty)
          _AlbumChips(
            albums: provider.albums,
            selectedId: provider.selectedAlbumId,
            onSelect: provider.selectAlbum,
          ),
        Expanded(child: _buildGrid(context, provider)),
      ],
    );
  }

  Widget _buildGrid(BuildContext context, GalleryProvider provider) {
    final List<GalleryImage> visible = provider.visibleImages;

    if (visible.isEmpty) {
      return _EmptyState(
        icon: Icons.photo_outlined,
        message: 'Nenhum resultado para "${provider.searchQuery}".',
      );
    }

    // Grade 3 colunas: densidade de fotos (padrão de galerias).
    return NotificationListener<ScrollNotification>(
      // Scroll infinito: carrega a próxima página ao chegar perto do fim.
      onNotification: (notification) {
        if (notification.metrics.extentAfter < 400) {
          provider.loadMore();
        }
        return false;
      },
      child: GridView.builder(
        padding: const EdgeInsets.all(4),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisSpacing: 4,
          crossAxisSpacing: 4,
        ),
        itemCount: visible.length + (provider.isLoadingMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (index >= visible.length) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(12),
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
              ),
            );
          }
          return _ImageTile(
            image: visible[index],
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => PhotoViewerScreen(
                  images: visible,
                  initialIndex: index,
                ),
              ),
            ),
            onLongPress: () => _showImageActions(context, provider, index),
          );
        },
      ),
    );
  }

  /// Menu de ações da foto: compartilhar / excluir (long-press).
  Future<void> _showImageActions(
    BuildContext context,
    GalleryProvider provider,
    int index,
  ) async {
    final GalleryImage image = provider.visibleImages[index];
    await MediaActions.show(
      context,
      type: 'image',
      mediaId: image.id,
      filePath: image.path,
      shareName: image.name,
      shareMimeType: _imageMimeType(image.path),
      onDeleted: () => provider.load(),
    );
  }

  /// MIME pela extensão do arquivo (fallback JPEG).
  static String _imageMimeType(String path) {
    final String lower = path.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.bmp')) return 'image/bmp';
    return 'image/jpeg';
  }
}

class _ImageTile extends StatelessWidget {
  final GalleryImage image;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _ImageTile({
    required this.image,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;

    return Material(
      color: colors.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: _ThumbnailImage(image: image),
      ),
    );
  }
}

/// Filtro horizontal de álbuns (pastas) + chip "Todas" para limpar.
class _AlbumChips extends StatelessWidget {
  final List<ImageAlbum> albums;
  final int? selectedId;
  final ValueChanged<int?> onSelect;

  const _AlbumChips({
    required this.albums,
    required this.selectedId,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 56,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        scrollDirection: Axis.horizontal,
        itemCount: albums.length + 1,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          if (index == 0) {
            return ChoiceChip(
              selected: selectedId == null,
              avatar: const Icon(Icons.photo_library_outlined, size: 18),
              label: const Text('Todas'),
              onSelected: (_) => onSelect(null),
            );
          }
          final ImageAlbum album = albums[index - 1];
          return ChoiceChip(
            selected: selectedId == album.id,
            avatar: _AlbumCover(coverId: album.coverId),
            label: Text(album.displayName),
            onSelected: (_) => onSelect(album.id),
          );
        },
      ),
    );
  }
}

/// Capa do álbum: miniatura de uma foto da pasta (com cache do serviço).
class _AlbumCover extends StatelessWidget {
  final int coverId;

  const _AlbumCover({required this.coverId});

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;

    return FutureBuilder<Uint8List?>(
      future: GalleryQueryService.loadThumbnail(coverId, width: 96),
      builder: (context, snapshot) {
        final Uint8List? bytes = snapshot.data;
        if (bytes == null || bytes.isEmpty) {
          return Icon(
            Icons.folder_outlined,
            size: 18,
            color: colors.onSurfaceVariant,
          );
        }
        return ClipOval(
          child: Image.memory(
            bytes,
            width: 24,
            height: 24,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => Icon(
              Icons.folder_outlined,
              size: 18,
              color: colors.onSurfaceVariant,
            ),
          ),
        );
      },
    );
  }
}

/// Miniatura da foto carregada direto do arquivo (mesmo caminho do
/// visualizador) — mais confiável que o canal nativo em todos os aparelhos.
class _ThumbnailImage extends StatelessWidget {
  final GalleryImage image;

  const _ThumbnailImage({required this.image});

  @override
  Widget build(BuildContext context) {
    final File file = File(image.path);
    if (!file.existsSync() || file.lengthSync() == 0) {
      return const _BrokenThumb();
    }
    return Image.file(
      file,
      fit: BoxFit.cover,
      gaplessPlayback: true,
      // Decodifica em resolução menor: grade rápida sem consumir memória.
      cacheWidth: 360,
      errorBuilder: (_, _, _) => const _BrokenThumb(),
    );
  }
}

class _BrokenThumb extends StatelessWidget {
  const _BrokenThumb();

  @override
  Widget build(BuildContext context) {
    return Icon(
      Icons.broken_image_outlined,
      size: 28,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
  }
}

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String message;

  const _EmptyState({required this.icon, required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 64,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}