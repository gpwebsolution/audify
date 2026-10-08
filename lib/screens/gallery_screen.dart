import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/gallery_image_model.dart';
import '../models/image_album.dart';
import '../models/media_ref.dart';
import '../providers/gallery_provider.dart';
import '../services/gallery_query_service.dart';
import '../utils/motion.dart';
import '../widgets/exif_sheet.dart';
import '../widgets/media_actions.dart';
import '../widgets/media_details_sheet.dart';
import '../widgets/selection_bar.dart';
import 'photo_viewer_screen.dart';

/// Aba de Galeria: fotos do aparelho (MediaStore) em grade.
class GalleryScreen extends StatefulWidget {
  const GalleryScreen({super.key});

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen>
    with MediaSelection<int> {
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
            onChanged: (String value) {
              provider.setSearchQuery(value);
              if (isSelectionMode) clearSelection();
            },
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
        // ---- Barra de ações em lote (modo seleção) ----
        AnimatedToolbarSwap(
          value: isSelectionMode,
          selectionBar: SelectionBar(
            label: '$selectionCount selecionada(s)',
            onSelectAll: () => toggleSelectAll(
              provider.visibleImages.map((GalleryImage i) => i.id),
            ),
            onClear: clearSelection,
            onDelete: () => deleteSelectedImages(context, provider),
            actions: <Widget>[
              IconButton(
                tooltip: 'Compartilhar selecionadas',
                icon: const Icon(Icons.share_outlined),
                onPressed: () => _shareSelected(context, provider),
              ),
            ],
          ),
          toolbar: const SizedBox.shrink(),
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

    // Sem permissão a lista volta vazia. Distinguir os dois casos evita
    // dizer "nenhuma foto encontrada" quando o problema é o acesso negado.
    if (provider.permissionDenied) {
      return _PhotosPermissionState(onRequest: () => provider.requestAccess());
    }

    if (provider.images.isEmpty) {
      return const _EmptyState(
        icon: Icons.photo_outlined,
        message:
            'Nenhuma foto encontrada no aparelho.\n'
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
            selected: isSelected(visible[index].id),
            selectionMode: isSelectionMode,
            onTap: () {
              if (isSelectionMode) {
                toggleSelect(visible[index].id);
                return;
              }
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) =>
                      PhotoViewerScreen(images: visible, initialIndex: index),
                ),
              );
            },
            // Long-press marca; as ações ficam no botão do tile.
            onLongPress: () => toggleSelect(visible[index].id),
            onMenuTap: () => _showImageActions(context, provider, index),
          );
        },
      ),
    );
  }

  @override
  void notifyChanged() => setState(() {});

  /// Compartilha as fotos marcadas num único diálogo do sistema.
  void _shareSelected(BuildContext context, GalleryProvider provider) {
    final List<GalleryImage> images = selectedFrom(
      provider.visibleImages,
      (GalleryImage i) => i.id,
    );
    if (images.isEmpty) return;
    MediaActions.shareMany(context, <MediaRef>[
      for (final GalleryImage i in images) MediaRef.fromImage(i),
    ]);
  }

  /// Exclui as fotos marcadas do aparelho com UM único diálogo do sistema.
  ///
  /// Cuidado com a galeria: ela tem scroll infinito, então [visibleImages]
  /// muda conforme a rolagem. Só o que está marcado E visível vai para o
  /// lote — item marcado que saiu da tela não seria confirmado pelo nativo e
  /// viraria falha fantasma.
  Future<void> deleteSelectedImages(
    BuildContext context,
    GalleryProvider provider,
  ) async {
    final List<GalleryImage> images = selectedFrom(
      provider.visibleImages,
      (GalleryImage i) => i.id,
    );
    if (images.isEmpty) {
      clearSelection();
      return;
    }
    if (!context.mounted) return;

    // Usa as chaves confirmadas pelo SO (excluídas + já ausentes) em vez de
    // `images`: se o SO negar permissão para 1 de 10, tirar os 10 da grade
    // deixaria um arquivo vivo sem nenhum registro — item fantasma eterno.
    await MediaActions.confirmDeleteMany(
      context,
      <MediaRef>[for (final GalleryImage i in images) MediaRef.fromImage(i)],
      onDeleted: (List<MediaRef> removed) async {
        // Só depois de confirmar: cancelar preserva a seleção.
        clearSelection();
        final Set<String> goneKeys = removed.map((MediaRef r) => r.key).toSet();
        provider.handleImagesDeleted(<GalleryImage>[
          for (final GalleryImage i in images)
            if (goneKeys.contains(MediaRef.fromImage(i).key)) i,
        ]);
      },
    );
  }

  /// Menu de ações da foto: compartilhar / detalhes / excluir (long-press).
  Future<void> _showImageActions(
    BuildContext context,
    GalleryProvider provider,
    int index,
  ) async {
    final GalleryImage image = provider.visibleImages[index];
    await MediaActions.show(
      context,
      ref: MediaRef.fromImage(image),
      label: image.name,
      sharePath: image.path,
      shareName: image.name,
      shareMimeType: _imageMimeType(image.path),
      extraTiles: <Widget>[
        ListTile(
          leading: const Icon(Icons.info_outline),
          title: const Text('Detalhes'),
          subtitle: const Text('Tamanho, dimensões e caminho'),
          onTap: () {
            Navigator.of(context).pop();
            MediaDetailsSheet.showImage(
              context,
              image,
              onShowExif: () => showExifSheet(context, image.path),
              onOpenFullscreen: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => PhotoViewerScreen(
                    images: provider.visibleImages,
                    initialIndex: index,
                  ),
                ),
              ),
            );
          },
        ),
      ],
      onDeleted: (List<MediaRef> removed) async {
        // Só some da grade se o nativo confirmar a remoção.
        if (removed.any(
          (MediaRef r) => r.key == MediaRef.fromImage(image).key,
        )) {
          provider.handleImagesDeleted(<GalleryImage>[image]);
        }
      },
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

  /// Abre as ações da foto (menu compartilhamento/detalhes/exclusão).
  final VoidCallback onMenuTap;
  final bool selected;
  final bool selectionMode;

  const _ImageTile({
    required this.image,
    required this.onTap,
    required this.onLongPress,
    required this.onMenuTap,
    this.selected = false,
    this.selectionMode = false,
  });

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final bool marked = selectionMode && selected;

    return AnimatedContainer(
      duration: Motion.fast,
      curve: Motion.settle,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: marked ? Border.all(color: colors.primary, width: 2.5) : null,
      ),
      child: Material(
        color: Colors.transparent,
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            InkWell(
              onTap: onTap,
              onLongPress: onLongPress,
              child: _ThumbnailImage(image: image),
            ),
            if (marked)
              IgnorePointer(
                child: Container(color: colors.primary.withValues(alpha: 0.3)),
              ),
            if (selectionMode)
              Align(
                alignment: Alignment.topRight,
                child: Padding(
                  padding: const EdgeInsets.all(3),
                  child: IgnorePointer(
                    child: Icon(
                      marked
                          ? Icons.check_circle
                          : Icons.radio_button_unchecked,
                      color: marked ? colors.primary : colors.outline,
                      size: 20,
                      shadows: const <Shadow>[
                        Shadow(color: Colors.black26, blurRadius: 4),
                      ],
                    ),
                  ),
                ),
              )
            else
              // Botão de ações sobre a miniatura: o long-press pertence à
              // seleção, então o menu precisa de um alvo visível.
              Align(
                alignment: Alignment.topRight,
                child: IconButton(
                  tooltip: 'Ações da foto',
                  padding: EdgeInsets.zero,
                  // Alvo mínimo de 48dp: com padding de 4dp o botão ficava
                  // com 24dp, metade do recomendado — difícil de acertar.
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.black.withValues(alpha: 0.45),
                    foregroundColor: Colors.white,
                  ),
                  icon: const Icon(Icons.more_vert, size: 20),
                  onPressed: onMenuTap,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Tela de permissão de fotos.
///
/// Antes a Galeria mostrava "Nenhuma foto encontrada" quando o acesso era
/// negado — uma afirmação que o app não podia verificar, e sem nenhuma ação
/// para resolver.
class _PhotosPermissionState extends StatelessWidget {
  final VoidCallback onRequest;

  const _PhotosPermissionState({required this.onRequest});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.photo_library_outlined,
              size: 64,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text(
              'Para ver suas fotos, o Audify precisa de acesso '
              'aos arquivos de imagem do aparelho.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRequest,
              icon: const Icon(Icons.lock_open_outlined),
              label: const Text('Permitir acesso às fotos'),
            ),
          ],
        ),
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

    // coverId 0 = álbum ficou sem capa após uma exclusão: pedir a miniatura
    // ao MediaStore só gastaria uma ida ao canal nativo para dar null.
    if (coverId <= 0) {
      return Icon(
        Icons.folder_outlined,
        size: 18,
        color: colors.onSurfaceVariant,
      );
    }

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
            Icon(icon, size: 64, color: Theme.of(context).colorScheme.outline),
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
