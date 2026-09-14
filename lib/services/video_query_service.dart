import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/video_model.dart';
import 'gallery_query_service.dart' show ThumbnailDiskCache;

/// Consulta ao MediaStore de vídeos via canal nativo (MainActivity.kt).
///
/// A consulta é feita 100% no lado Android; aqui fica apenas a ponte Dart
/// + cache de miniaturas em memória (evita re-consultar o disco a cada
/// rebuild da lista — performance em listas longas).
class VideoQueryService {
  static const MethodChannel _channel = MethodChannel('audify/video_query');

  /// Cache em memória de miniaturas (id -> bytes). Pequeno e bounded:
  /// vídeos são tipicamente poucos; limpar em [clearCache] quando a lista
  /// for recarregada.
  static final Map<int, Uint8List> _thumbCache = {};

  /// True se o canal nativo existe (Android). Em outras plataformas o app
  /// degrada para lista vazia com mensagem amigável.
  static bool get isSupported => Platform.isAndroid;

  /// Lista os vídeos do aparelho (mais recentes primeiro).
  static Future<List<Video>> loadVideos() async {
    if (!isSupported) return const [];

    try {
      final List<dynamic>? raw = await _channel
          .invokeMethod<List<dynamic>>('getVideos');
      if (raw == null) return const [];
      return raw
          .map((e) => Video.fromChannel(e as Map<dynamic, dynamic>))
          .toList();
    } catch (e) {
      // Falha de plataforma nunca crasha o app: degrada para lista vazia.
      debugPrint('[VideoQuery] loadVideos falhou: $e');
      return const [];
    }
  }

  /// Miniatura do vídeo (cache em memória + disco).
  static Future<Uint8List?> loadThumbnail(int id, {int width = 320}) async {
    final Uint8List? cached = _thumbCache[id];
    if (cached != null) return cached;

    // Disco primeiro (mesmo padrão da galeria).
    final Uint8List? disk = await ThumbnailDiskCache.get('video_$id');
    if (disk != null) {
      _thumbCache[id] = disk;
      return disk;
    }

    try {
      final Uint8List? bytes = await _channel
          .invokeMethod<Uint8List>('getThumbnail', {'id': id, 'width': width});
      if (bytes != null && bytes.isNotEmpty) {
        _thumbCache[id] = bytes;
        await ThumbnailDiskCache.put('video_$id', bytes);
      }
      return bytes;
    } catch (e) {
      return null;
    }
  }

  static void clearCache() => _thumbCache.clear();
}