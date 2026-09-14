import 'package:flutter/foundation.dart';

import '../models/gallery_image_model.dart';
import '../models/image_album.dart';
import '../services/gallery_query_service.dart';

/// Estado da galeria de fotos do aparelho.
///
/// Responsabilidade: carregar e expor as imagens do MediaStore (canal
/// nativo) para a aba de Galeria — com PAGINAÇÃO (lazy loading), filtro
/// por álbum (pasta) e busca por nome de arquivo.
class GalleryProvider extends ChangeNotifier {
  /// Álbum selecionado (null = todas as fotos).
  int? _selectedAlbumId;

  List<GalleryImage> _images = const [];
  List<ImageAlbum> _albums = const [];
  String _searchQuery = '';
  bool _isLoading = true;
  bool _isLoadingMore = false;
  bool _hasMore = true;
  bool _isDisposed = false;

  List<GalleryImage> get images => _images;
  List<ImageAlbum> get albums => _albums;
  int? get selectedAlbumId => _selectedAlbumId;
  String get searchQuery => _searchQuery;
  bool get isLoading => _isLoading;
  bool get isLoadingMore => _isLoadingMore;
  bool get hasMore => _hasMore;

  /// Nome do álbum selecionado (para o cabeçalho da tela).
  String get selectedAlbumName {
    final ImageAlbum? album =
        _albums.where((a) => a.id == _selectedAlbumId).firstOrNull;
    return album?.displayName ?? 'Galeria';
  }

  /// Imagens filtradas pela busca (nome do arquivo).
  List<GalleryImage> get visibleImages {
    final String q = _searchQuery.toLowerCase();
    if (q.isEmpty) return _images;
    return _images
        .where((img) => img.name.toLowerCase().contains(q))
        .toList();
  }

  GalleryProvider() {
    load();
  }

  /// Carrega os álbuns e a primeira página de fotos (reset total).
  Future<void> load() async {
    _isLoading = true;
    _hasMore = true;
    _notify();

    final List<ImageAlbum> albums =
        await GalleryQueryService.loadAlbums();
    final List<GalleryImage> page =
        await GalleryQueryService.loadImages(albumId: _selectedAlbumId);

    _albums = albums;
    _images = page;
    _hasMore = page.length >= GalleryQueryService.pageSize;
    _isLoading = false;
    _notify();
  }

  /// Carrega a próxima página (chamado pelo scroll infinito).
  Future<void> loadMore() async {
    if (_isLoading || _isLoadingMore || !_hasMore || _images.isEmpty) return;
    _isLoadingMore = true;
    _notify();

    // Keyset: a partir da última foto carregada (tupla data+id).
    final GalleryImage last = _images.last;
    final List<GalleryImage> page = await GalleryQueryService.loadImages(
      beforeDateAdded: last.dateAdded,
      beforeId: last.id,
      albumId: _selectedAlbumId,
    );

    if (page.isEmpty) {
      _hasMore = false;
    } else {
      _images = [..._images, ...page];
      _hasMore = page.length >= GalleryQueryService.pageSize;
    }
    _isLoadingMore = false;
    _notify();
  }

  /// Seleciona um álbum (null = todas as fotos) e recarrega a partir dele.
  Future<void> selectAlbum(int? albumId) async {
    if (_selectedAlbumId == albumId) return;
    _selectedAlbumId = albumId;
    await load();
  }

  void setSearchQuery(String query) {
    _searchQuery = query.trim();
    _notify();
  }

  void _notify() {
    if (!_isDisposed) notifyListeners();
  }

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
  }
}