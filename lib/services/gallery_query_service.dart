import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../models/gallery_image_model.dart';
import '../models/image_album.dart';

/// Consulta ao MediaStore de imagens via canal nativo (MainActivity.kt).
///
/// Consulta 100% no lado Android com PAGINAÇÃO (offset/limit) — nunca
/// carrega a biblioteca inteira de uma vez. Miniaturas vêm com cache em
/// memória e em disco ([ThumbnailDiskCache]).
class GalleryQueryService {
  static const MethodChannel _channel = MethodChannel('audify/gallery_query');

  /// Tamanho padrão de página (fotos por carregamento).
  static const int pageSize = 120;

  /// Cache em memória de miniaturas (id -> bytes).
  static final Map<int, Uint8List> _thumbCache = {};

  /// True se o canal nativo existe (Android).
  static bool get isSupported => Platform.isAndroid;

  /// Lista os álbuns (pastas) de imagens do aparelho, maiores primeiro.
  static Future<List<ImageAlbum>> loadAlbums() async {
    if (!isSupported) return const [];
    try {
      final List<dynamic>? raw =
          await _channel.invokeMethod<List<dynamic>>('getAlbums');
      if (raw == null) return const [];
      return raw
          .map((e) => ImageAlbum.fromChannel(e as Map<dynamic, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('[GalleryQuery] loadAlbums falhou: $e');
      return const [];
    }
  }

  /// Lista uma página de imagens (mais recentes primeiro), por keyset.
  ///
  /// [beforeDateAdded]/[beforeId]: tupla (date_added, _id) da ÚLTIMA imagem
  /// da página anterior (null na primeira página). [albumId] filtra por
  /// pasta (null = todas).
  static Future<List<GalleryImage>> loadImages({
    int? beforeDateAdded,
    int? beforeId,
    int limit = pageSize,
    int? albumId,
  }) async {
    if (!isSupported) return const [];

    try {
      final List<dynamic>? raw = await _channel.invokeMethod<List<dynamic>>(
        'getImages',
        {
          'beforeDateAdded': beforeDateAdded,
          'beforeId': beforeId,
          'limit': limit,
          'albumId': albumId,
        },
      );
      if (raw == null) return const [];
      return raw
          .map((e) => GalleryImage.fromChannel(e as Map<dynamic, dynamic>))
          .toList();
    } catch (e) {
      // Falha de plataforma nunca crasha o app: degrada para lista vazia.
      debugPrint('[GalleryQuery] loadImages falhou: $e');
      return const [];
    }
  }

  /// Miniatura da imagem (cache em memória + disco).
  static Future<Uint8List?> loadThumbnail(int id, {int width = 320}) async {
    final Uint8List? cached = _thumbCache[id];
    if (cached != null) return cached;

    // Disco primeiro (evita re-gerar no lado nativo a cada sessão).
    final Uint8List? disk = await ThumbnailDiskCache.get('gallery_$id');
    if (disk != null) {
      _thumbCache[id] = disk;
      return disk;
    }

    try {
      final Uint8List? bytes = await _channel
          .invokeMethod<Uint8List>('getThumbnail', {'id': id, 'width': width});
      if (bytes != null && bytes.isNotEmpty) {
        _thumbCache[id] = bytes;
        await ThumbnailDiskCache.put('gallery_$id', bytes);
      }
      return bytes;
    } catch (e) {
      return null;
    }
  }

  static void clearCache() => _thumbCache.clear();
}

/// Cache em disco de miniaturas (dir de cache do app, com limite duplo).
///
/// Evita re-gerar miniaturas a cada sessão. Limites: nº de arquivos
/// ([maxFiles]) E tamanho total ([maxTotalBytes]) — sem teto de bytes, um
/// aparelho com muitas fotos enche o armazenamento com JPEGs de ~30 KB
/// cada. A poda (mais antigos primeiro) roda em `compute()` para não
/// travar a UI thread. Falhas de I/O são silenciosas — cache é
/// otimização, nunca requisito.
class ThumbnailDiskCache {
  static const int maxFiles = 600;

  /// Teto total do cache (~48 MB).
  static const int maxTotalBytes = 48 * 1024 * 1024;

  /// Lê uma miniatura do disco (null se não existir/falhar).
  static Future<Uint8List?> get(String key) async {
    try {
      final Directory dir = await _dir();
      final String path = '${dir.path}/$key.jpg';
      // existsSync é barato; a leitura só acontece quando existe.
      final File file = File(path);
      if (!file.existsSync()) return null;
      return await file.readAsBytes();
    } catch (e) {
      return null;
    }
  }

  /// Grava uma miniatura no disco (podando quando necessário). A poda é
  /// agendada em isolate — nunca na UI thread.
  static Future<void> put(String key, Uint8List bytes) async {
    try {
      final Directory dir = await _dir();
      final File file = File('${dir.path}/$key.jpg');
      await file.writeAsBytes(bytes);
      unawaited(_pruneIfNeeded(dir.path));
    } catch (e) {
      // Cache é otimização: falha de escrita é ignorada.
    }
  }

  static Future<Directory> _dir() async {
    final Directory cache = await getTemporaryDirectory();
    final Directory dir = Directory('${cache.path}/thumbnails');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// Remove os arquivos mais antigos quando o cache excede os limites de
  /// contagem OU de bytes totais. Roda em isolate (compute) — varrer e
  /// deletar centenas de arquivos na UI thread causaria jank visível.
  static Future<void> _pruneIfNeeded(String dirPath) async {
    try {
      await compute(_pruneJob, _PruneArgs(dirPath: dirPath));
    } catch (_) {
      // Poda falhou: cache apenas cresce até a próxima tentativa.
    }
  }
}

class _PruneArgs {
  final String dirPath;
  const _PruneArgs({required this.dirPath});
}

/// Top-level (requisito do compute()): poda por contagem e por bytes.
void _pruneJob(_PruneArgs args) {
  final Directory dir = Directory(args.dirPath);
  if (!dir.existsSync()) return;
  final List<(File, DateTime, int)> entries = <(File, DateTime, int)>[];
  int totalBytes = 0;
  for (final FileSystemEntity entity in dir.listSync(followLinks: false)) {
    try {
      if (entity is! File) continue;
      final FileStat stat = entity.statSync();
      entries.add((entity, stat.modified, stat.size));
      totalBytes += stat.size;
    } catch (_) {
      continue;
    }
  }
  if (entries.length <= ThumbnailDiskCache.maxFiles &&
      totalBytes <= ThumbnailDiskCache.maxTotalBytes) {
    return;
  }

  // Mais antigos primeiro; remove até voltar dentro dos dois limites.
  entries.sort((a, b) => a.$2.compareTo(b.$2));
  int files = entries.length;
  int bytes = totalBytes;
  for (final (File file, _, int size) in entries) {
    if (files <= ThumbnailDiskCache.maxFiles &&
        bytes <= ThumbnailDiskCache.maxTotalBytes) {
      break;
    }
    try {
      file.deleteSync();
      files--;
      bytes -= size;
    } catch (_) {
      continue;
    }
  }
}