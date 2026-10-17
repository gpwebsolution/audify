import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:exif/exif.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';

import '../models/file_item.dart';



import 'file_ops_jobs.dart';
import 'storage_analysis_service.dart';
import 'trash_service.dart';

export 'storage_analysis_service.dart' show DuplicateGroup, StorageUsage;
export 'trash_service.dart' show TrashEntry;

/// Núcleo do gerenciador de arquivos.
///
/// Implementação 100% Dart sobre `dart:io`: com o acesso especial "Todos os
/// arquivos" (MANAGE_EXTERNAL_STORAGE) concedido, as APIs de arquivo leem e
/// escrevem o armazenamento externo inteiro normalmente. Vantagens sobre um
/// canal nativo gigante: testável com diretórios temporários no host e toda
/// a I/O pesada roda em `compute()` (isolate), nunca na UI thread.
///
/// O canal nativo `audify/file_query` fica restrito ao que Dart não alcança:
/// espaço livre/total dos volumes (StatFs), miniatura de vídeo/PDF por
/// caminho (MediaMetadataRetriever/PdfRenderer) e metadados de APK
/// (PackageManager.getPackageArchiveInfo).
class FileQueryService {
  static const MethodChannel _channel = MethodChannel('audify/file_query');

  /// Itens por página de listagem.
  static const int pageSize = 200;

  static bool get isSupported => Platform.isAndroid;

  /// Subárvores ignoradas nas varreduras recursivas (busca global, analisador,
  /// duplicados): dados privados de outros apps são volumosos e irrelevantes.
  static const List<String> _excludedNames = <String>[
    'Android/data',
    'Android/obb',
    '.Trash-1000',
  ];

  // =========================================================================
  // VOLUMES DE ARMAZENAMENTO (nativo: StatFs não existe em dart:io)
  // =========================================================================

  /// Lista os volumes (interno + SD externo se houver). Em caso de falha do
  /// canal, degrada para o volume primário com tamanhos zerados — a
  /// navegação continua funcionando.
  static Future<List<StorageVolume>> loadStorageVolumes() async {
    if (!isSupported) return const [];
    try {
      final List<dynamic>? raw = await _channel.invokeMethod<List<dynamic>>(
        'getStorageVolumes',
      );
      if (raw == null || raw.isEmpty) return _fallbackVolumes();
      return raw
          .map((e) => StorageVolume.fromChannel(e as Map<dynamic, dynamic>))
          .toList();
    } catch (_) {
      return _fallbackVolumes();
    }
  }

  static List<StorageVolume> _fallbackVolumes() => const [
    StorageVolume(
      path: '/storage/emulated/0',
      name: 'Armazenamento interno',
      isPrimary: true,
      isRemovable: false,
      totalSpace: 0,
      freeSpace: 0,
    ),
  ];

  // =========================================================================
  // LISTAGEM PAGINADA
  // =========================================================================

  /// Lista UMA página de itens de [path]. Ordenação/paginação acontecem no
  /// isolate ([_listDirJob]) — pastas com milhares de entradas não travam a
  /// UI. Pastas vêm sempre antes de arquivos; ocultos (`.nome`) só entram
  /// com [includeHidden].
  static Future<FileListResult> listDirectory({
    required String path,
    int offset = 0,
    int limit = pageSize,
    String sortBy = 'name',
    bool sortAscending = true,
    FileType? filterType,
    bool includeHidden = true,
  }) async {
    try {
      final _ListResult data = await compute(
        _listDirJob,
        _ListArgs(
          path: path,
          offset: offset,
          limit: limit,
          sortBy: sortBy,
          ascending: sortAscending,
          filterType: filterType?.name,
          includeHidden: includeHidden,
        ),
      );
      return FileListResult(
        items: data.items,
        totalCount: data.totalCount,
        hasMore: offset + data.items.length < data.totalCount,
      );
    } catch (e) {
      debugPrint('[FileQueryService] listDirectory($path): $e');
      return FileListResult.empty();
    }
  }

  // =========================================================================
  // BUSCA RECURSIVA
  // =========================================================================

  /// Busca por nome (case-insensitive) em toda a subárvore de [rootPath].
  /// Para cedo ao atingir [limit]; ignora subárvores privadas de outros apps.
  static Future<List<FileItem>> searchFiles({
    required String query,
    String rootPath = '/storage/emulated/0',
    int limit = 500,
    FileType? filterType,
  }) async {
    try {
      return await compute(
        _searchJob,
        _SearchArgs(
          query: query.toLowerCase(),
          rootPath: rootPath,
          limit: limit,
          filterType: filterType?.name,
        ),
      );
    } catch (e) {
      debugPrint('[FileQueryService] searchFiles: $e');
      return const [];
    }
  }

  // =========================================================================
  // MINIATURAS (vídeo/PDF via nativo; imagem é tratada pela UI com Image.file)
  // =========================================================================

  /// Cache em memória (path -> bytes). Disco reusa [ThumbnailDiskCache] da
  /// galeria (mesmo padrão, mesma pasta de cache).
  static final Map<String, Uint8List> _thumbCache = {};

  static Future<Uint8List?> getThumbnail(String path, {int width = 320}) async {
    final FileType type = FileTypeMap.fromExtension(_extOf(path));
    // Imagens: a UI decodifica direto (Image.file) — mais barato que ida e
    // volta nativa. Vídeo/PDF precisam de decodificador nativo.
    if (type == FileType.image || type == FileType.directory) return null;

    final Uint8List? cached = _thumbCache[path];
    if (cached != null) return cached;

    try {
      final Uint8List? bytes = await _channel.invokeMethod<Uint8List>(
        'getFilePathThumbnail',
        {'path': path, 'width': width},
      );
      if (bytes != null && bytes.isNotEmpty) {
        _thumbCache[path] = bytes;
      }
      return bytes;
    } catch (_) {
      return null;
    }
  }

  static void clearThumbnailCache() => _thumbCache.clear();

  // =========================================================================
  // HASH SHA-256 (duplicados)
  // =========================================================================

  /// Hash de conteúdo em streaming (chunks de 64 KB) dentro de isolate.
  static Future<String?> computeHash(String path) async {
    try {
      return await compute(_hashJob, path);
    } catch (e) {
      debugPrint('[FileQueryService] computeHash($path): $e');
      return null;
    }
  }

  // =========================================================================
  // OPERAÇÕES DE ARQUIVO (CRUD)
  // =========================================================================

  static Future<bool> copy({
    required String sourcePath,
    required String destPath,
    bool overwrite = false,
  }) async {
    try {
      final String target = overwrite ? destPath : await _uniquePath(destPath);
      return await compute(
        copyJob,
        TwoPaths(source: sourcePath, dest: target),
      );
    } catch (e) {
      debugPrint('[FileQueryService] copy: $e');
      return false;
    }
  }

  /// Move = rename (instantâneo no mesmo volume) com fallback para
  /// copiar+apagar quando atravessa volumes (interno -> SD).
  static Future<bool> move({
    required String sourcePath,
    required String destPath,
    bool overwrite = false,
  }) async {
    try {
      final String target = overwrite ? destPath : await _uniquePath(destPath);
      return await compute(
        moveJob,
        TwoPaths(source: sourcePath, dest: target),
      );
    } catch (e) {
      debugPrint('[FileQueryService] move: $e');
      return false;
    }
  }

  static Future<bool> rename({
    required String path,
    required String newName,
  }) async {
    if (newName.contains('/') || newName.trim().isEmpty) return false;
    try {
      final String parent = path.substring(0, path.lastIndexOf('/'));
      final String target = await _uniquePath('$parent/$newName');
      return await compute(renameJob, TwoPaths(source: path, dest: target));
    } catch (e) {
      debugPrint('[FileQueryService] rename: $e');
      return false;
    }
  }

  /// Exclui para a lixeira interna do app ([useTrash], padrão) ou
  /// permanentemente. A lixeira vive no diretório de suporte do app —
  /// fora do armazenamento compartilhado, invisível a outros apps.

  static Future<bool> delete({
    required String path,
    bool useTrash = true,
  }) async {
    if (!useTrash) {
      try {
        return await compute(deletePermanentJob, path);
      } catch (e) {
        debugPrint('[FileQueryService] delete: $e');
        return false;
      }
    }
    return TrashService.moveToTrash(path);
  }


  static Future<bool> createDirectory(String path) async {
    try {
      return await compute(createDirJob, path);
    } catch (_) {
      return false;
    }
  }

  // =========================================================================
  // LIXEIRA INTERNA — implementação em TrashService; a API pública fica aqui
  // para que chamadores e testes continuem os mesmos.
  // =========================================================================

  static Future<List<TrashEntry>> listTrash() => TrashService.listTrash();

  static Future<bool> restoreFromTrash(TrashEntry entry) =>
      TrashService.restoreFromTrash(entry);

  static Future<bool> deleteForever(String trashPath) =>
      TrashService.deleteForever(trashPath);

  static Future<int> purgeExpired(int retentionDays) =>
      TrashService.purgeExpired(retentionDays);

  static Future<int> trashSize() => TrashService.trashSize();

  static Future<void> emptyTrash() => TrashService.emptyTrash();


  // =========================================================================
  // ZIP
  // =========================================================================

  /// Compacta os caminhos selecionados em [zipPath]. Pastas são percorridas
  /// recursivamente (arcname relativo à própria raiz incluída).
  static Future<bool> createZip({
    required List<String> sourcePaths,
    required String zipPath,
    bool deleteAfter = false,
  }) async {
    try {
      final String target = await _uniquePath(zipPath);
      final bool ok = await compute(
        _zipJob,
        _ZipArgs(sources: sourcePaths, zipPath: target),
      );
      if (!ok) return false;
      if (deleteAfter) {
        for (final String p in sourcePaths) {
          await compute(deletePermanentJob, p);
        }
      }
      return true;
    } catch (e) {
      debugPrint('[FileQueryService] createZip: $e');
      return false;
    }
  }

  /// Extrai ZIPs para [destPath]. RAR/7z não têm decodificador em Dart puro
  /// nem no Android SDK — retornamos false com clareza para a UI avisar.
  static Future<bool> extractArchive({
    required String archivePath,
    required String destPath,
    bool deleteAfter = false,
  }) async {
    final String ext = _extOf(archivePath);
    if (ext != 'zip') return false;
    try {
      final Directory out = Directory(
        '$destPath/.${_baseName(archivePath)}_extracted',
      );
      final bool ok = await compute(
        _extractJob,
        _ExtractArgs(zipPath: archivePath, destPath: out.path),
      );
      if (!ok) return false;
      if (deleteAfter) await compute(deletePermanentJob, archivePath);
      return true;
    } catch (e) {
      debugPrint('[FileQueryService] extractArchive: $e');
      return false;
    }
  }

  // =========================================================================
  // DETALHES DO ARQUIVO (+ EXIF de imagens)
  // =========================================================================

  static Future<FileDetails?> getFileDetails(String path) async {
    try {
      final _DetailsData data = await compute(_detailsJob, path);
      return FileDetails(
        path: data.path,
        name: data.name,
        size: data.size,
        dateCreated: data.createdSeconds,
        dateModified: data.modifiedSeconds,
        dateAccessed: 0,
        permissions: data.permissions,
        owner: '',
        group: '',
        isHidden: data.name.startsWith('.'),
        isReadOnly: !data.writable,
        exifData: data.exif,
      );
    } catch (e) {
      debugPrint('[FileQueryService] getFileDetails($path): $e');
      return null;
    }
  }

  // =========================================================================
  // ABRIR / INSTALAR / METADADOS DE APK
  // =========================================================================

  /// Abre com app externo via open_filex (ACTION_VIEW + FileProvider interno
  /// do plugin). Retorna true quando o sistema despachou o Intent.
  static Future<bool> openFile(String path) async {
    try {
      final OpenResult result = await OpenFilex.open(path);
      return result.type == ResultType.done;
    } catch (e) {
      debugPrint('[FileQueryService] openFile($path): $e');
      return false;
    }
  }

  static Future<bool> installApk(String path) => openFile(path);

  /// Nome do pacote/versão/label de um APK solto no disco — só o Android
  /// consegue parsear o binário AndroidManifest.xml embutido.
  /// Cache de metadados (e ícone) por caminho de APK.
  ///
  /// Sem isso, o `FutureBuilder` da tela criava um Future NOVO a cada rebuild
  /// (marcar/desmarc um APK bastava) e o nativo reparseava o AndroidManifest
  /// binário do APK — trabalho pesado repetido sem necessidade.
  static final Map<String, ApkInfo> _apkInfoCache = <String, ApkInfo>{};

  /// Consultas em voo, para dois widgets do mesmo APK compartilharem uma ida.
  static final Map<String, Future<ApkInfo?>> _apkInfoPending =
      <String, Future<ApkInfo?>>{};

  static Future<ApkInfo?> getApkInfo(String path) {
    final ApkInfo? cached = _apkInfoCache[path];
    if (cached != null) return Future<ApkInfo?>.value(cached);

    final Future<ApkInfo?>? inflight = _apkInfoPending[path];
    if (inflight != null) return inflight;

    final Future<ApkInfo?> future = _loadApkInfo(path)
        .then((ApkInfo? info) {
          if (info != null) _apkInfoCache[path] = info;
          return info;
        })
        .whenComplete(() => _apkInfoPending.remove(path));
    _apkInfoPending[path] = future;
    return future;
  }

  /// Descarta o cache de um APK (usado quando o arquivo é excluído).
  static void clearApkInfo(String path) => _apkInfoCache.remove(path);

  static Future<ApkInfo?> _loadApkInfo(String path) async {
    if (!isSupported) return null;
    try {
      final Map<dynamic, dynamic>? raw = await _channel
          .invokeMethod<Map<dynamic, dynamic>>('getApkInfo', {'path': path});
      if (raw == null) return null;
      return ApkInfo.fromChannel(raw);
    } catch (e) {
      debugPrint('[FileQueryService] getApkInfo($path): $e');
      return null;
    }
  }

  // =========================================================================
  // ANALISADOR DE ARMAZENAMENTO — implementação em StorageAnalysisService
  // =========================================================================

  static Future<StorageUsage> getStorageUsage({String? rootPath}) =>
      StorageAnalysisService.getStorageUsage(rootPath: rootPath);

  static Future<List<FileItem>> getLargestFiles({
    int limit = 20,
    String? rootPath,
  }) =>
      StorageAnalysisService.getLargestFiles(limit: limit, rootPath: rootPath);

  static Future<List<DuplicateGroup>> findDuplicates({
    String rootPath = '/storage/emulated/0',
    int minSize = 1024,
  }) =>
      StorageAnalysisService.findDuplicates(
        rootPath: rootPath,
        minSize: minSize,
      );

  // =========================================================================
  // HELPERS ESTÁTICOS
  // =========================================================================

  static String _extOf(String path) {
    final String name = path.split('/').last;
    final int dot = name.lastIndexOf('.');
    return dot <= 0 ? '' : name.substring(dot + 1).toLowerCase();
  }

  static String _baseName(String path) =>
      path.split('/').where((s) => s.isNotEmpty).last;

  /// Sufixo " (1)", " (2)"… quando o destino já existe — nunca sobrescreve
  /// silenciosamente.
  static Future<String> _uniquePath(String path) async {
    if (FileSystemEntity.typeSync(path) == FileSystemEntityType.notFound) {
      return path;
    }
    final bool isDir = FileSystemEntity.isDirectorySync(path);
    final String parent = path.substring(0, path.lastIndexOf('/'));
    final String name = _baseName(path);
    String stem = name, ext = '';
    if (!isDir) {
      final int dot = name.lastIndexOf('.');
      if (dot > 0) {
        stem = name.substring(0, dot);
        ext = name.substring(dot);
      }
    }
    for (int i = 1; i < 1000; i++) {
      final String candidate = '$parent/$stem ($i)$ext';
      if (FileSystemEntity.typeSync(candidate) ==
          FileSystemEntityType.notFound) {
        return candidate;
      }
    }
    return path;
  }
}

class FileListResult {
  final List<FileItem> items;
  final int totalCount;
  final bool hasMore;

  const FileListResult({
    required this.items,
    required this.totalCount,
    required this.hasMore,
  });

  factory FileListResult.empty() =>
      const FileListResult(items: [], totalCount: 0, hasMore: false);
}

class StorageVolume {
  final String path;
  final String name;
  final bool isPrimary;
  final bool isRemovable;
  final int totalSpace;
  final int freeSpace;

  const StorageVolume({
    required this.path,
    required this.name,
    required this.isPrimary,
    required this.isRemovable,
    required this.totalSpace,
    required this.freeSpace,
  });

  factory StorageVolume.fromChannel(Map<dynamic, dynamic> map) {
    return StorageVolume(
      path: map['path'] as String,
      name: map['name'] as String? ?? 'Volume',
      isPrimary: map['isPrimary'] as bool? ?? false,
      isRemovable: map['isRemovable'] as bool? ?? false,
      totalSpace: (map['totalSpace'] as num?)?.toInt() ?? 0,
      freeSpace: (map['freeSpace'] as num?)?.toInt() ?? 0,
    );
  }

  String get displayTotalSpace => formatBytes(totalSpace);
  String get displayFreeSpace => formatBytes(freeSpace);
  double get usagePercent =>
      totalSpace > 0 ? (1 - freeSpace / totalSpace) * 100 : 0;
}

class FileDetails {
  final String path;
  final String name;
  final int size;
  final int dateCreated;
  final int dateModified;
  final int dateAccessed;
  final String permissions;
  final String owner;
  final String group;
  final bool isHidden;
  final bool isReadOnly;
  final Map<String, dynamic>? exifData;

  const FileDetails({
    required this.path,
    required this.name,
    required this.size,
    required this.dateCreated,
    required this.dateModified,
    required this.dateAccessed,
    required this.permissions,
    required this.owner,
    required this.group,
    required this.isHidden,
    required this.isReadOnly,
    this.exifData,
  });
}

class ApkInfo {
  final String packageName;
  final String versionName;
  final int versionCode;
  final String appName;
  final int minSdkVersion;
  final int targetSdkVersion;

  /// Ícone embutido no APK, já em PNG (vem do lado nativo).
  ///
  /// Null quando o manifesto não declara ícone ou a carga falhou — a UI usa
  /// o ícone genérico nesse caso.
  final Uint8List? icon;

  const ApkInfo({
    required this.packageName,
    required this.versionName,
    required this.versionCode,
    required this.appName,
    required this.minSdkVersion,
    required this.targetSdkVersion,
    this.icon,
  });

  factory ApkInfo.fromChannel(Map<dynamic, dynamic> map) {
    final Object? rawIcon = map['icon'];
    return ApkInfo(
      packageName: map['packageName'] as String? ?? '?',
      versionName: map['versionName'] as String? ?? '?',
      versionCode: (map['versionCode'] as num?)?.toInt() ?? 0,
      appName: map['appName'] as String? ?? '?',
      minSdkVersion: (map['minSdkVersion'] as num?)?.toInt() ?? 0,
      targetSdkVersion: (map['targetSdkVersion'] as num?)?.toInt() ?? 0,
      icon: rawIcon is Uint8List ? rawIcon : null,
    );
  }
}

// Formata bytes legível (KB/MB/GB) — itens, volumes e lixeira.
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

// =============================================================================
// JOBS DE ISOLATE (top-level: exigência do compute())
// =============================================================================

class _ListArgs {
  final String path;
  final int offset;
  final int limit;
  final String sortBy;
  final bool ascending;
  final String? filterType;
  final bool includeHidden;

  const _ListArgs({
    required this.path,
    required this.offset,
    required this.limit,
    required this.sortBy,
    required this.ascending,
    this.filterType,
    required this.includeHidden,
  });
}

class _ListResult {
  final List<FileItem> items;
  final int totalCount;
  const _ListResult(this.items, this.totalCount);
}

_ListResult _listDirJob(_ListArgs args) {
  final Directory dir = Directory(args.path);
  if (!dir.existsSync()) return const _ListResult([], 0);

  final List<FileItem> matched = <FileItem>[];
  final List<FileSystemEntity> entries;
  try {
    entries = dir.listSync(followLinks: false);
  } catch (_) {
    return const _ListResult([], 0);
  }

  for (final FileSystemEntity entity in entries) {
    try {
      final FileStat stat = entity.statSync();
      if (stat.type == FileSystemEntityType.notFound) continue;
      final String path = entity.path;
      final String name = path.split('/').where((s) => s.isNotEmpty).last;
      if (!args.includeHidden && name.startsWith('.')) continue;

      final bool isDir = stat.type == FileSystemEntityType.directory;
      final FileType type = isDir
          ? FileType.directory
          : FileTypeMap.fromExtension(jobExt(name));

      if (args.filterType != null &&
          type.name != args.filterType &&
          type != FileType.directory) {
        continue;
      }

      matched.add(
        FileItem.fromStat(
          path: path,
          isDirectory: isDir,
          size: stat.size,
          modifiedSeconds: stat.modified.millisecondsSinceEpoch ~/ 1000,
          createdSeconds: stat.changed.millisecondsSinceEpoch ~/ 1000,
        ),
      );
    } catch (_) {
      continue;
    }
  }

  _sortItems(matched, args.sortBy, args.ascending);
  final int total = matched.length;
  final int start = args.offset.clamp(0, total);
  final int end = (start + args.limit).clamp(0, total);
  return _ListResult(matched.sublist(start, end), total);
}

void _sortItems(List<FileItem> items, String sortBy, bool ascending) {
  int compare(FileItem a, FileItem b) {
    // Pastas primeiro, sempre.
    if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
    int r;
    switch (sortBy) {
      case 'dateModified':
        r = a.dateModified.compareTo(b.dateModified);
        break;
      case 'size':
        r = a.size.compareTo(b.size);
        break;
      case 'type':
        r = a.type.index.compareTo(b.type.index);
        if (r == 0) {
          r = a.name.toLowerCase().compareTo(b.name.toLowerCase());
        }
        break;
      default:
        r = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    }
    return ascending ? r : -r;
  }

  items.sort(compare);
}

class _SearchArgs {
  final String query;
  final String rootPath;
  final int limit;
  final String? filterType;

  const _SearchArgs({
    required this.query,
    required this.rootPath,
    required this.limit,
    this.filterType,
  });
}

List<FileItem> _searchJob(_SearchArgs args) {
  final List<FileItem> found = <FileItem>[];
  final List<String> stack = <String>[args.rootPath];

  while (stack.isNotEmpty && found.length < args.limit) {
    final String current = stack.removeLast();
    if (isExcludedPath(current)) continue;
    final Directory dir = Directory(current);
    List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: false);
    } catch (_) {
      continue;
    }
    for (final FileSystemEntity entity in entries) {
      try {
        final String name = entity.path
            .split('/')
            .where((s) => s.isNotEmpty)
            .last;
        final bool isDir = FileSystemEntity.isDirectorySync(entity.path);
        if (isDir) {
          if (!isExcludedPath(entity.path)) stack.add(entity.path);
          continue;
        }
        if (!name.toLowerCase().contains(args.query)) continue;
        if (args.filterType != null &&
            FileTypeMap.fromExtension(jobExt(name)).name != args.filterType) {
          continue;
        }
        final FileStat stat = entity.statSync();
        if (found.length >= args.limit) break;
        found.add(
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
  found.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return found;
}

bool isExcludedPath(String path) {
  for (final String ex in FileQueryService._excludedNames) {
    if (path.contains('/$ex')) return true;
  }
  return path.contains('/audify/trash/');
}

String jobExt(String name) {
  final int dot = name.lastIndexOf('.');
  return dot <= 0 ? '' : name.substring(dot + 1).toLowerCase();
}

Future<String?> _hashJob(String path) async {
  try {
    final File file = File(path);
    if (!file.existsSync()) return null;
    final Digest digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  } catch (_) {
    return null;
  }
}


class _ZipArgs {
  final List<String> sources;
  final String zipPath;
  const _ZipArgs({required this.sources, required this.zipPath});
}

bool _zipJob(_ZipArgs args) {
  try {
    final Archive archive = Archive();
    void addPath(String fsPath, String arcName) {
      final FileSystemEntityType type = FileSystemEntity.typeSync(
        fsPath,
        followLinks: true,
      );
      if (type == FileSystemEntityType.directory) {
        for (final FileSystemEntity child in Directory(
          fsPath,
        ).listSync(followLinks: true)) {
          addPath(child.path, '$arcName/${child.path.split('/').last}');
        }
        return;
      }
      if (type == FileSystemEntityType.notFound) return;
      final List<int> bytes = File(fsPath).readAsBytesSync();
      final ArchiveFile file = ArchiveFile(arcName, bytes.length, bytes);
      file.lastModTime =
          File(fsPath).lastModifiedSync().millisecondsSinceEpoch ~/ 1000;
      archive.add(file);
    }

    for (final String source in args.sources) {
      addPath(source, source.split('/').where((s) => s.isNotEmpty).last);
    }
    final List<int> encoded = ZipEncoder().encode(archive);
    File(args.zipPath)
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(encoded, flush: true);
    return true;
  } catch (_) {
    return false;
  }
}

class _ExtractArgs {
  final String zipPath;
  final String destPath;
  const _ExtractArgs({required this.zipPath, required this.destPath});
}

bool _extractJob(_ExtractArgs args) {
  try {
    final List<int> bytes = File(args.zipPath).readAsBytesSync();
    final Archive archive = ZipDecoder().decodeBytes(bytes);
    final String normalizedDest = Directory(
      args.destPath,
    ).absolute.path.replaceAll(r'\', '/');

    for (final ArchiveFile entry in archive) {
      final String outPath = '$normalizedDest/${entry.name}'.replaceAll(
        r'\',
        '/',
      );
      // Defesa contra zip-slip: nenhuma entrada pode escapar do destino.
      if (!outPath.startsWith(normalizedDest)) continue;
      if (entry.isFile) {
        final File outFile = File(outPath);
        outFile.parent.createSync(recursive: true);
        outFile.writeAsBytesSync(entry.content as List<int>, flush: true);
      } else {
        Directory(outPath).createSync(recursive: true);
      }
    }
    return true;
  } catch (_) {
    return false;
  }
}

class _DetailsData {
  final String path;
  final String name;
  final int size;
  final int modifiedSeconds;
  final int createdSeconds;
  final String permissions;
  final bool writable;
  final Map<String, dynamic>? exif;

  const _DetailsData({
    required this.path,
    required this.name,
    required this.size,
    required this.modifiedSeconds,
    required this.createdSeconds,
    required this.permissions,
    required this.writable,
    this.exif,
  });
}

Future<_DetailsData> _detailsJob(String path) async {
  final FileStat stat = FileStat.statSync(path);
  final String name = path.split('/').where((s) => s.isNotEmpty).last;

  String permissions = '';
  final int mode = stat.mode;
  String triad(int bits) =>
      '${bits & 4 != 0 ? 'r' : '-'}${bits & 2 != 0 ? 'w' : '-'}'
      '${bits & 1 != 0 ? 'x' : '-'}';
  try {
    final int shifted = mode & 0x1FF;
    permissions =
        '${triad(shifted >> 6)}${triad((shifted >> 3) & 7)}${triad(shifted & 7)}';
  } catch (_) {}

  // EXIF apenas para imagens (leitura rápida, sem decodificar pixels).
  Map<String, dynamic>? exif;
  final FileType type = FileTypeMap.fromExtension(jobExt(name));
  if (type == FileType.image && stat.size > 0 && stat.size < 60 * 1024 * 1024) {
    try {
      final Map<String, IfdTag> tags = await readExifFromFile(File(path));
      exif = <String, dynamic>{
        for (final MapEntry<String, IfdTag> e in tags.entries)
          e.key.replaceFirst('EXIF ', '').replaceFirst('Image ', ''): e
              .value
              .printable
              .trim(),
      };
    } catch (_) {
      exif = null;
    }
  }

  return _DetailsData(
    path: path,
    name: name,
    size: stat.size,
    modifiedSeconds: stat.modified.millisecondsSinceEpoch ~/ 1000,
    createdSeconds: stat.changed.millisecondsSinceEpoch ~/ 1000,
    permissions: permissions,
    writable: stat.modeString()[1] == 'w',
    exif: (exif != null && exif.isNotEmpty) ? exif : null,
  );
}
