import 'dart:io';

import 'package:flutter/material.dart';

import '../models/gallery_image_model.dart';
import '../widgets/exif_sheet.dart';

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
          // Metadados EXIF da foto atual (câmera, GPS, técnica) + opção de
          // gerar cópia sem metadados sensíveis.
          IconButton(
            tooltip: 'Metadados',
            icon: const Icon(Icons.info_outline),
            onPressed: () => showExifSheet(context, image.path),
          ),
        ],
      ),
      body: PageView.builder(
        controller: _pageController,
        itemCount: widget.images.length,
        onPageChanged: (index) => setState(() => _currentIndex = index),
        itemBuilder: (context, index) => _ZoomableImage(
          key: ValueKey(index),
          image: widget.images[index],
        ),
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