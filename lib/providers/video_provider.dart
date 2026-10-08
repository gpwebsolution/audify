import 'package:flutter/foundation.dart';

import '../models/video_model.dart';
import '../services/permission_service.dart';
import '../services/video_query_service.dart';

/// Estado da biblioteca de vídeos do aparelho.
///
/// Responsabilidade: carregar e expor os vídeos do MediaStore (canal
/// nativo) para a aba de Vídeos. Leitura simples — sem lógica de player
/// aqui (a reprodução é pontual na [VideoPlayerScreen]).
class VideoProvider extends ChangeNotifier {
  List<Video> _videos = const [];
  String _searchQuery = '';
  bool _isLoading = true;
  bool _permissionDenied = false;
  bool _isDisposed = false;

  List<Video> get videos => _videos;
  String get searchQuery => _searchQuery;
  bool get isLoading => _isLoading;

  /// True quando o aparelho NEGOU a permissão de vídeos (Android 13+
  /// separa READ_MEDIA_VIDEO das demais) — a tela oferece "Permitir".
  bool get permissionDenied => _permissionDenied;

  /// Vídeos filtrados pela busca (título/nome do arquivo).
  List<Video> get visibleVideos {
    final String q = _searchQuery.toLowerCase();
    if (q.isEmpty) return _videos;
    return _videos
        .where((v) =>
            v.displayTitle.toLowerCase().contains(q) ||
            v.displayName.toLowerCase().contains(q))
        .toList();
  }

  VideoProvider() {
    load();
  }

  Future<void> load() async {
    _isLoading = true;
    _notify();
    _permissionDenied = !await PermissionService.hasVideosAccess();
    VideoQueryService.clearCache();
    _videos = _permissionDenied
        ? const []
        : await VideoQueryService.loadVideos();
    _isLoading = false;
    _notify();
  }

  /// Remove vídeos confirmados como APAGADOS do aparelho.
  ///
  /// Filtra a lista, joga fora as miniaturas (memória + disco) e notifica
  /// a UI. Não recarrega do MediaStore de propósito: o usuário acabou de
  /// ver o sistema apagar, e a fila do provider sai do caminho da exclusão.
  Future<void> handleVideosDeleted(List<Video> deleted) async {
    if (deleted.isEmpty) return;
    final Set<int> ids = deleted.map((Video v) => v.id).toSet();
    _videos = _videos.where((Video v) => !ids.contains(v.id)).toList();
    for (final Video video in deleted) {
      await VideoQueryService.clearThumbnail(video.id);
    }
    _notify();
  }

  /// Pede a permissão de vídeos (dialog do sistema) e recarrega a lista.
  Future<bool> requestAccess() async {
    final bool granted = await PermissionService.requestVideosAccess();
    await load();
    return granted;
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