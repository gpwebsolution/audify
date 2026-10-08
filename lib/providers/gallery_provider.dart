import 'package:flutter/foundation.dart';

import '../models/gallery_image_model.dart';
import '../models/image_album.dart';
import '../services/gallery_query_service.dart';
import '../services/permission_service.dart';

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
  bool _permissionDenied = false;
  bool _isDisposed = false;

  List<GalleryImage> get images => _images;
  List<ImageAlbum> get albums => _albums;
  int? get selectedAlbumId => _selectedAlbumId;
  String get searchQuery => _searchQuery;
  bool get isLoading => _isLoading;
  bool get isLoadingMore => _isLoadingMore;
  bool get hasMore => _hasMore;

  /// True quando o aparelho NEGOU o acesso às fotos.
  ///
  /// Sem isso, negar a permissão produzia uma tela vazia com a mensagem
  /// "Nenhuma foto encontrada no aparelho" — que atribui o vazio a não ter
  /// fotos, quando na verdade o app não pode nem olhá-las. A tela oferece
  /// "Permitir acesso às fotos" quando esta flag está ligada.
  bool get permissionDenied => _permissionDenied;

  /// Nome do álbum selecionado (para o cabeçalho da tela).
  String get selectedAlbumName {
    final ImageAlbum? album = _albums
        .where((a) => a.id == _selectedAlbumId)
        .firstOrNull;
    return album?.displayName ?? 'Galeria';
  }

  /// Imagens filtradas pela busca (nome do arquivo).
  List<GalleryImage> get visibleImages {
    final String q = _searchQuery.toLowerCase();
    if (q.isEmpty) return _images;
    return _images.where((img) => img.name.toLowerCase().contains(q)).toList();
  }

  GalleryProvider() {
    load();
  }

  /// Carrega os álbuns e a primeira página de fotos (reset total).
  Future<void> load() async {
    _isLoading = true;
    _hasMore = true;
    _notify();

    // Antes de listar: sem permissão a consulta volta vazia, e sem esta
    // checagem a UI não distingue "não tenho fotos" de "não posso ver".
    _permissionDenied = !await PermissionService.hasPhotosAccess();
    if (_permissionDenied) {
      _albums = const [];
      _images = const [];
      _hasMore = false;
      _isLoading = false;
      _notify();
      return;
    }

    final List<ImageAlbum> albums = await GalleryQueryService.loadAlbums();
    final List<GalleryImage> page = await GalleryQueryService.loadImages(
      albumId: _selectedAlbumId,
    );

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

  /// Pede o acesso às fotos e recarrega (chamado pelo botão da tela de
  /// permissão). Devolve true quando o acesso passou a existir.
  Future<bool> requestAccess() async {
    final bool granted = await PermissionService.requestPhotosAccess();
    await load();
    return granted;
  }

  /// Remove fotos confirmadas como APAGADAS do aparelho.
  ///
  /// Filtra a página carregada, descarta as miniaturas (memória + disco) e
  /// notifica. Também descarta a página inteira quando a foto removida era
  /// a capa do álbum selecionado, para não deixar capa órfã.
  Future<void> handleImagesDeleted(List<GalleryImage> deleted) async {
    if (deleted.isEmpty) return;
    final Set<int> ids = deleted.map((GalleryImage i) => i.id).toSet();
    _images = _images.where((GalleryImage i) => !ids.contains(i.id)).toList();
    for (final GalleryImage image in deleted) {
      await GalleryQueryService.clearThumbnail(image.id);
    }
    _albums = _albums
        .map(
          (ImageAlbum a) => ids.contains(a.coverId)
              ? ImageAlbum(
                  id: a.id,
                  name: a.name,
                  count: a.count > 0 ? a.count - 1 : 0,
                  coverId: 0,
                )
              : a,
        )
        .toList();
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
