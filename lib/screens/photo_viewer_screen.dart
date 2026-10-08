import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/gallery_image_model.dart';
import '../models/media_ref.dart';
import '../providers/gallery_provider.dart';
import '../services/image_actions_service.dart';
import '../widgets/exif_sheet.dart';
import '../widgets/media_actions.dart';
import '../widgets/media_details_sheet.dart';

/// Visualizador de fotos em tela cheia.
///
/// Swipe horizontal entre as fotos (PageView) + zoom por pinça/double-tap
/// (InteractiveViewer, com reset ao trocar de foto). Fundo preto: foco
/// total na imagem.
class PhotoViewerScreen extends StatefulWidget {
  final List<GalleryImage> images;
  final int initialIndex;

  const PhotoViewerScreen({
    super.key,
    required this.images,
    required this.initialIndex,
  });

  @override
  State<PhotoViewerScreen> createState() => _PhotoViewerScreenState();
}

class _PhotoViewerScreenState extends State<PhotoViewerScreen> {
  late final PageController _pageController;
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  /// Menu de ações da foto exibida.
  ///
  /// As ações que dependem de outro app (papel de parede, editar) vão por
  /// intent nativa com `content://` do FileProvider: desde o Android 7 um
  /// `file://` entregue a outro app lança `FileUriExposedException`.
  Future<void> _showImageActions(
    BuildContext context,
    GalleryImage image,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext sheetContext) {
        void go(Future<void> Function() action) {
          Navigator.pop(sheetContext);
          action();
        }

        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: <Widget>[
              ListTile(
                leading: const Icon(Icons.wallpaper),
                title: const Text('Definir como papel de parede'),
                subtitle: const Text('Você escolhe o recorte e a posição'),
                onTap: () =>
                    go(() => ImageActionsService.setAsWallpaper(image.path)),
              ),
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Editar'),
                subtitle: const Text('Abre um editor de imagem instalado'),
                onTap: () =>
                    go(() => ImageActionsService.editImage(image.path)),
              ),
              ListTile(
                leading: const Icon(Icons.branding_watermark_outlined),
                title: const Text('Marca d’água'),
                subtitle: const Text(
                  'Escreve um texto numa cópia, sem tocar na original',
                ),
                onTap: () => go(() => _promptWatermark(context, image)),
              ),
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: const Text('Detalhes'),
                subtitle: const Text('Dados EXIF, tamanho e caminho'),
                onTap: () => go(() => _showDetails(context, image)),
              ),
              ListTile(
                leading: const Icon(Icons.share_outlined),
                title: const Text('Compartilhar'),
                onTap: () => go(
                  () => MediaActions.share(
                    context,
                    path: image.path,
                    name: image.name,
                    mimeType: mimeTypeForImagePath(image.path),
                  ),
                ),
              ),
              const Divider(),
              // Excluir precisa estar AQUI: com o botão de 3 pontinhos removido
              // da miniatura, este menu é o único caminho para apagar uma foto
              // a partir da grade.
              ListTile(
                leading: Icon(
                  Icons.delete_outline,
                  color: Theme.of(context).colorScheme.error,
                ),
                title: Text(
                  'Excluir do aparelho',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                subtitle: const Text('Some da galeria e dos favoritos'),
                onTap: () => go(() => _deleteImage(context, image)),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Exclui a foto e sai do visualizador.
  ///
  /// Confirma com o diálogo do SO (via [MediaActions.confirmDelete]) e só
  /// remove da lista quando o nativo confirma. Se a foto for a única do
  /// visualizador, volta para a galeria em vez de deixar uma tela vazia.
  Future<void> _deleteImage(BuildContext context, GalleryImage image) async {
    final NavigatorState navigator = Navigator.of(context);
    final GalleryProvider gallery = context.read<GalleryProvider>();

    await MediaActions.confirmDelete(
      context,
      MediaRef.fromImage(image),
      label: image.name,
      onDeleted: (List<MediaRef> removed) async {
        final bool confirmed = removed.any(
          (MediaRef r) => r.key == MediaRef.fromImage(image).key,
        );
        if (!confirmed) return;
        await gallery.handleImagesDeleted(<GalleryImage>[image]);

        // A foto sumiu de uma lista que este visualizador recebeu como cópia:
        // sair da tela é mais honesto do que mostrar uma imagem apagada.
        if (!navigator.mounted) return;
        if (widget.images.length <= 1) {
          navigator.pop();
        } else {
          setState(() {
            // Garante que o índice atual ainda existe depois da remoção.
            if (_currentIndex >= widget.images.length - 1) {
              _currentIndex = widget.images.length - 2;
            }
            if (_currentIndex < 0) _currentIndex = 0;
          });
        }
      },
    );
  }

  /// Detalhes: painel de informações + dados EXIF.
  Future<void> _showDetails(BuildContext context, GalleryImage image) async {
    await MediaDetailsSheet.showImage(
      context,
      image,
      onShowExif: () => showExifSheet(context, image.path),
    );
  }

  /// MIME pela extensão, com JPEG como padrão.
  ///
  /// Função de arquivo (e não método): a Galeria tem a mesma regra, e duplicar
  /// um método privado entre telas é a forma mais rápida dos dois lados
  /// divergirem.
  static String mimeTypeForImagePath(String path) {
    final String lower = path.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.bmp')) return 'image/bmp';
    if (lower.endsWith('.heic') || lower.endsWith('.heif')) {
      return 'image/heic';
    }
    return 'image/jpeg';
  }

  /// Pede o texto da marca d'água e aplica numa CÓPIA.
  Future<void> _promptWatermark(
    BuildContext context,
    GalleryImage image,
  ) async {
    final TextEditingController controller = TextEditingController();
    final String? text = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Marca d’água'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            hintText: 'Ex.: © Meu estúdio',
            helperText:
                'A original não é alterada. A cópia fica na pasta Audify do '
                'seu armazenamento.',
          ),
          onSubmitted: (String value) => Navigator.pop(dialogContext, value),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('Aplicar'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (text == null || text.trim().isEmpty || !context.mounted) return;

    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final Color errorColor = Theme.of(context).colorScheme.error;
    messenger.showSnackBar(
      const SnackBar(content: Text('Gerando a cópia com marca d’água…')),
    );
    try {
      final WatermarkResult result = await WatermarkService.applyText(
        sourcePath: image.path,
        text: text,
      );
      if (!context.mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text('Cópia salva em ${result.path}'),
          action: SnackBarAction(
            label: 'Compartilhar',
            onPressed: () => MediaActions.share(
              context,
              path: result.path,
              name: '${image.name}-marcada.jpg',
              mimeType: 'image/jpeg',
            ),
          ),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text('Não foi possível aplicar a marca d’água: $e'),
          backgroundColor: errorColor,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final GalleryImage image = widget.images[_currentIndex];

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          image.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 16),
        ),
        actions: [
          if (image.displayDimensions.isNotEmpty)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Text(
                  image.displayDimensions,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ),
          // Menu de ações da foto em UM botão: papel de parede, editor, marca
          // d'água, detalhes (com EXIF) e compartilhamento. O AppBar do
          // visualizador é pequeno e cada ícone extra rouba espaço da foto.
          IconButton(
            tooltip: 'Ações da foto',
            icon: const Icon(Icons.more_vert),
            onPressed: () => _showImageActions(context, image),
          ),
        ],
      ),
      body: PageView.builder(
        controller: _pageController,
        itemCount: widget.images.length,
        onPageChanged: (index) => setState(() => _currentIndex = index),
        itemBuilder: (context, index) =>
            _ZoomableImage(key: ValueKey(index), image: widget.images[index]),
      ),
      // ---- Contador (3 de 12) ----
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(
            '${_currentIndex + 1} de ${widget.images.length}',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ),
      ),
    );
  }
}

/// Imagem com zoom por pinça e double-tap (alterna 1x <-> 3x).
class _ZoomableImage extends StatefulWidget {
  final GalleryImage image;

  const _ZoomableImage({super.key, required this.image});

  @override
  State<_ZoomableImage> createState() => _ZoomableImageState();
}

class _ZoomableImageState extends State<_ZoomableImage> {
  final TransformationController _transform = TransformationController();
  bool _zoomed = false;

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  void _toggleZoom() {
    final Matrix4 target = _zoomed
        ? Matrix4.identity()
        : Matrix4.diagonal3Values(3.0, 3.0, 3.0);
    _transform.value = target;
    _zoomed = !_zoomed;
  }

  @override
  Widget build(BuildContext context) {
    // Arquivo inacessível/corrompido: nunca crash — estado de erro visual.
    final File file = File(widget.image.path);
    if (!file.existsSync() || file.lengthSync() == 0) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.broken_image_outlined, size: 64, color: Colors.white38),
            SizedBox(height: 12),
            Text(
              'Imagem inacessível ou corrompida.',
              style: TextStyle(color: Colors.white70),
            ),
          ],
        ),
      );
    }

    return InteractiveViewer(
      transformationController: _transform,
      maxScale: 5.0,
      // Swipe horizontal desabilita enquanto há zoom (pinça ativa) — evita
      // conflito entre gestos do PageView e do zoom.
      panEnabled: true,
      scaleEnabled: true,
      child: Center(
        child: GestureDetector(
          onDoubleTap: _toggleZoom,
          child: Image.file(
            file,
            fit: BoxFit.contain,
            errorBuilder: (context, error, stackTrace) => const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.broken_image_outlined,
                    size: 64,
                    color: Colors.white38,
                  ),
                  SizedBox(height: 12),
                  Text(
                    'Não foi possível decodificar a imagem.',
                    style: TextStyle(color: Colors.white70),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
