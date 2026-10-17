import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/file_item.dart';
import 'file_query_service.dart';

/// Análise de armazenamento: uso por categoria, maiores arquivos e
/// duplicados (SHA-256, nunca exclusão automática).
///
/// Extraído de file_query_service.dart no item 6.2; os jobs de isolate
/// continuam top-level neste arquivo.
class StorageAnalysisService {
  // =========================================================================
  // ANALISADOR DE ARMAZENAMENTO
  // =========================================================================

  /// Uso por categoria. Varredura completa da árvore (menos subárvores
  /// excluídas + lixeira) rodando em isolate — pode levar segundos em
  /// armazenamentos cheios; a tela mostra loading.
  static Future<StorageUsage> getStorageUsage({String? rootPath}) async {
    final StorageVolume volume =
        (await FileQueryService.loadStorageVolumes()).firstOrNull ??
        const StorageVolume(
          path: '/storage/emulated/0',
          name: '',
          isPrimary: true,
          isRemovable: false,
          totalSpace: 0,
          freeSpace: 0,
        );

    int cacheSize = 0;
    try {
      final Directory tmp = await getTemporaryDirectory();
      cacheSize = await compute(_dirSizeJob, tmp.path);
    } catch (e) {
      debugPrint('[StorageAnalysisService] tamanho do cache falhou: $e');
    }

    final Map<String, int> byCategory = await compute(
      _usageJob,
      _WalkArgs(rootPath: rootPath ?? volume.path),
    );
    if (cacheSize > 0) byCategory['cache'] = cacheSize;

    final int used = volume.totalSpace - volume.freeSpace;
    return StorageUsage(
      totalSpace: volume.totalSpace,
      freeSpace: volume.freeSpace,
      usedSpace: used > 0 ? used : byCategory.values.fold(0, (a, b) => a + b),
      byCategory: byCategory,
    );
  }

  /// Top [limit] maiores arquivos do armazenamento.
  static Future<List<FileItem>> getLargestFiles({
    int limit = 20,
    String? rootPath,
  }) async {
    try {
      return await compute(
        _largestJob,
        _LargestArgs(rootPath: rootPath ?? '/storage/emulated/0', limit: limit),
      );
    } catch (_) {
      return const [];
    }
  }

  // =========================================================================
  // DUPLICADOS (SHA-256, nunca exclusão automática)
  // =========================================================================

  /// Agrupa arquivos com conteúdo idêntico. Estratégia de duas fases para
  /// não hashear o aparelho inteiro desnecessariamente: agrupa por tamanho
  /// primeiro e só calcula hash dos grupos com mais de um candidato.
  static Future<List<DuplicateGroup>> findDuplicates({
    String rootPath = '/storage/emulated/0',
    int minSize = 1024,
  }) async {
    try {
      final List<_DupRaw> raw = await compute(
        _duplicatesJob,
        _DupArgs(rootPath: rootPath, minSize: minSize),
      );
      return raw
          .map(
            (g) => DuplicateGroup(hash: g.hash, size: g.size, files: g.items),
          )
          .toList()
        ..sort((a, b) => b.size.compareTo(a.size));
    } catch (e) {
      debugPrint('[StorageAnalysisService] findDuplicates: $e');
      return const [];
    }
  }
}

class StorageUsage {
  final int totalSpace;
  final int freeSpace;
  final int usedSpace;
  final Map<String, int> byCategory;

  const StorageUsage({
    required this.totalSpace,
    required this.freeSpace,
    required this.usedSpace,
    required this.byCategory,
  });

  String get displayTotalSpace => formatBytes(totalSpace);
  String get displayFreeSpace => formatBytes(freeSpace);
  String get displayUsedSpace => formatBytes(usedSpace);
}

class DuplicateGroup {
  final String hash;
  final int size;
  final List<FileItem> files;

  const DuplicateGroup({
    required this.hash,
    required this.size,
    required this.files,
  });

  factory DuplicateGroup.fromChannel(Map<dynamic, dynamic> map) {
    final List<dynamic> filesRaw = map['files'] as List<dynamic>? ?? [];
    return DuplicateGroup(
      hash: map['hash'] as String,
      size: (map['size'] as num?)?.toInt() ?? 0,
      files: filesRaw
          .map((e) => FileItem.fromChannel(e as Map<dynamic, dynamic>))
          .toList(),
    );
  }

  int get count => files.length;
  String get displaySize => formatBytes(size);
}


int _dirSizeJob(String path) {
  int total = 0;
  final List<String> stack = <String>[path];
  while (stack.isNotEmpty) {
    final String current = stack.removeLast();
    try {
      for (final FileSystemEntity entity in Directory(
        current,
      ).listSync(followLinks: false)) {
        final FileSystemEntityType type = FileSystemEntity.typeSync(
          entity.path,
          followLinks: false,
        );
        if (type == FileSystemEntityType.directory) {
          stack.add(entity.path);
        } else if (type == FileSystemEntityType.file) {
          total += File(entity.path).lengthSync();
        }
      }
    } catch (_) {
      continue;
    }
  }
  return total;
}

FileType _categoryOf(String name) => FileTypeMap.fromExtension(jobExt(name));

class _WalkArgs {
  final String rootPath;
  const _WalkArgs({required this.rootPath});
}

Map<String, int> _usageJob(_WalkArgs args) {
  final Map<String, int> buckets = <String, int>{
    'images': 0,
    'videos': 0,
    'audio': 0,
    'documents': 0,
    'apk': 0,
    'archives': 0,
    'others': 0,
  };
  final List<String> stack = <String>[args.rootPath];
  while (stack.isNotEmpty) {
    final String current = stack.removeLast();
    if (isExcludedPath(current)) continue;
    List<FileSystemEntity> entries;
    try {
      entries = Directory(current).listSync(followLinks: false);
    } catch (_) {
      continue;
    }
    for (final FileSystemEntity entity in entries) {
      try {
        final FileSystemEntityType type = FileSystemEntity.typeSync(
          entity.path,
          followLinks: false,
        );
        if (type == FileSystemEntityType.directory) {
          if (!isExcludedPath(entity.path)) stack.add(entity.path);
          continue;
        }
        if (type != FileSystemEntityType.file) continue;
        final int size = File(entity.path).lengthSync();
        switch (_categoryOf(entity.path.split('/').last)) {
          case FileType.image:
            buckets['images'] = buckets['images']! + size;
          case FileType.video:
            buckets['videos'] = buckets['videos']! + size;
          case FileType.audio:
            buckets['audio'] = buckets['audio']! + size;
          case FileType.pdf:
          case FileType.document:
          case FileType.text:
          case FileType.spreadsheet:
          case FileType.presentation:
          case FileType.code:
            buckets['documents'] = buckets['documents']! + size;
          case FileType.apk:
            buckets['apk'] = buckets['apk']! + size;
          case FileType.archive:
            buckets['archives'] = buckets['archives']! + size;
          default:
            buckets['others'] = buckets['others']! + size;
        }
      } catch (_) {
        continue;
      }
    }
  }
  buckets.removeWhere((_, v) => v == 0);
  return buckets;
}

class _LargestArgs {
  final String rootPath;
  final int limit;
  const _LargestArgs({required this.rootPath, required this.limit});
}

List<FileItem> _largestJob(_LargestArgs args) {
  final List<FileItem> top = <FileItem>[];
  final List<String> stack = <String>[args.rootPath];
  while (stack.isNotEmpty) {
    final String current = stack.removeLast();
    if (isExcludedPath(current)) continue;
    List<FileSystemEntity> entries;
    try {
      entries = Directory(current).listSync(followLinks: false);
    } catch (_) {
      continue;
    }
    for (final FileSystemEntity entity in entries) {
      try {
        final FileSystemEntityType type = FileSystemEntity.typeSync(
          entity.path,
          followLinks: false,
        );
        if (type == FileSystemEntityType.directory) {
          if (!isExcludedPath(entity.path)) stack.add(entity.path);
          continue;
        }
        if (type != FileSystemEntityType.file) continue;
        final FileStat stat = entity.statSync();
        final FileItem item = FileItem.fromStat(
          path: entity.path,
          isDirectory: false,
          size: stat.size,
          modifiedSeconds: stat.modified.millisecondsSinceEpoch ~/ 1000,
          createdSeconds: stat.changed.millisecondsSinceEpoch ~/ 1000,
        );
        if (top.length < args.limit) {
          top.add(item);
          top.sort((a, b) => b.size.compareTo(a.size));
        } else if (item.size > top.last.size) {
          top[args.limit - 1] = item;
          top.sort((a, b) => b.size.compareTo(a.size));
        }
      } catch (_) {
        continue;
      }
    }
  }
  return top;
}

class _DupArgs {
  final String rootPath;
  final int minSize;
  const _DupArgs({required this.rootPath, required this.minSize});
}

class _DupRaw {
  final String hash;
  final int size;
  final List<FileItem> items;
  const _DupRaw(this.hash, this.size, this.items);
}

Future<List<_DupRaw>> _duplicatesJob(_DupArgs args) async {
  // Fase 1: agrupa candidatos por tamanho (> minSize).
  final Map<int, List<FileItem>> bySize = <int, List<FileItem>>{};
  final List<String> stack = <String>[args.rootPath];
  while (stack.isNotEmpty) {
    final String current = stack.removeLast();
    if (isExcludedPath(current)) continue;
    List<FileSystemEntity> entries;
    try {
      entries = Directory(current).listSync(followLinks: false);
    } catch (_) {
      continue;
    }
    for (final FileSystemEntity entity in entries) {
      try {
        final FileSystemEntityType type = FileSystemEntity.typeSync(
          entity.path,
          followLinks: false,
        );
        if (type == FileSystemEntityType.directory) {
          if (!isExcludedPath(entity.path)) stack.add(entity.path);
          continue;
        }
        if (type != FileSystemEntityType.file) continue;
        final FileStat stat = entity.statSync();
        if (stat.size < args.minSize) continue;
        (bySize[stat.size] ??= <FileItem>[]).add(
          FileItem.fromStat(
            path: entity.path,
            isDirectory: false,
            size: stat.size,
            modifiedSeconds: stat.modified.millisecondsSinceEpoch ~/ 1000,
            createdSeconds: stat.changed.millisecondsSinceEpoch ~/ 1000,
          ),
        );
      } catch (_) {
        continue;
      }
    }
  }

  // Fase 2: hash apenas onde há mais de um candidato.
  final List<_DupRaw> groups = <_DupRaw>[];
  for (final MapEntry<int, List<FileItem>> entry in bySize.entries) {
    if (entry.value.length < 2) continue;
    final Map<String, List<FileItem>> byHash = <String, List<FileItem>>{};
    for (final FileItem item in entry.value) {
      try {
        final Digest digest = await sha256
            .bind(File(item.path).openRead())
            .first;
        (byHash[digest.toString()] ??= <FileItem>[]).add(item);
      } catch (_) {
        continue;
      }
    }
    for (final MapEntry<String, List<FileItem>> hashed in byHash.entries) {
      if (hashed.value.length >= 2) {
        groups.add(_DupRaw(hashed.key, entry.key, hashed.value));
      }
    }
  }
  return groups;
}
