import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:exif/exif.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import '../models/file_item.dart';

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
      final List<dynamic>? raw =
          await _channel.invokeMethod<List<dynamic>>('getStorageVolumes');
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
      final String target =
          overwrite ? destPath : await _uniquePath(destPath);
      return await compute(
          _copyJob, _TwoPaths(source: sourcePath, dest: target));
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
      final String target =
          overwrite ? destPath : await _uniquePath(destPath);
      return await compute(
          _moveJob, _TwoPaths(source: sourcePath, dest: target));
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
      return await compute(
          _renameJob, _TwoPaths(source: path, dest: target));
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
    try {
      if (!useTrash) {
        return await compute(_deletePermanentJob, path);
      }
      final Directory trashRoot = await _trashDir();
      final String stamp = DateTime.now().microsecondsSinceEpoch.toString();
      final String inside = '${trashRoot.path}/files/${stamp}_'
          '${path.split('/').where((s) => s.isNotEmpty).last}';
      final bool moved = await compute(
          _moveJob, _TwoPaths(source: path, dest: inside));
      if (!moved) return false;
      await _appendToManifest(path, inside, DateTime.now());
      return true;
    } catch (e) {
      debugPrint('[FileQueryService] delete: $e');
      return false;
    }
  }

  static Future<bool> createDirectory(String path) async {
    try {
      return await compute(_createDirJob, path);
    } catch (_) {
      return false;
    }
  }

  // =========================================================================
  // LIXEIRA INTERNA
  // =========================================================================

  static Future<Directory> _trashDir() async {
    final Directory support = await getApplicationSupportDirectory();
    final Directory dir = Directory('${support.path}/trash/files');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return Directory('${support.path}/trash');
  }

  static File _manifestFile(Directory trashRoot) =>
      File('${trashRoot.path}/manifest.jsonl');

  static Future<void> _appendToManifest(
      String originalPath, String trashPath, DateTime at) async {
    final Directory support = await getApplicationSupportDirectory();
    final File manifest = _manifestFile(Directory('${support.path}/trash'));
    final Map<String, Object?> entry = <String, Object?>{
      'original': originalPath,
      'trashPath': trashPath,
      'deletedAtMs': at.millisecondsSinceEpoch,
    };
    await manifest.writeAsString(
      '${jsonEncode(entry)}\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  /// Entradas atuais da lixeira (arquivos que sumiram do disco são omitidos).
  static Future<List<TrashEntry>> listTrash() async {
    try {
      final Directory support = await getApplicationSupportDirectory();
      final File manifest =
          File('${support.path}/trash/manifest.jsonl');
      if (!manifest.existsSync()) return const [];
      final List<TrashEntry> result = <TrashEntry>[];
      for (final String line in manifest.readAsLinesSync()) {
        if (line.trim().isEmpty) continue;
        try {
          final Map<String, dynamic> map =
              jsonDecode(line) as Map<String, dynamic>;
          final String trashPath = map['trashPath'] as String;
          if (!File(trashPath).existsSync() &&
              !Directory(trashPath).existsSync()) {
            continue;
          }
          final FileSystemEntityType kind =
              FileSystemEntity.typeSync(trashPath);
          final int size = kind == FileSystemEntityType.file
              ? File(trashPath).lengthSync()
              : 0;
          result.add(TrashEntry(
            originalPath: map['original'] as String,
            trashPath: trashPath,
            deletedAtMs: (map['deletedAtMs'] as num).toInt(),
            sizeBytes: size,
          ));
        } catch (_) {
          continue;
        }
      }
      return result;
    } catch (_) {
      return const [];
    }
  }

  /// Devolve o item ao local original (recriando pastas se necessário).
  static Future<bool> restoreFromTrash(TrashEntry entry) async {
    try {
      final bool moved = await compute(
          _restoreJob, _RestoreArgs(entry: entry));
      if (moved) await _removeFromManifest(entry.trashPath);
      return moved;
    } catch (e) {
      debugPrint('[FileQueryService] restoreFromTrash: $e');
      return false;
    }
  }

  static Future<bool> deleteForever(String trashPath) async {
    try {
      final bool ok = await compute(_deletePermanentJob, trashPath);
      if (ok) await _removeFromManifest(trashPath);
      return ok;
    } catch (e) {
      debugPrint('[FileQueryService] deleteForever: $e');
      return false;
    }
  }

  static Future<void> emptyTrash() async {
    try {
      final Directory trashRoot = await _trashDir();
      final Directory files = Directory('${trashRoot.path}/files');
      if (files.existsSync()) {
        await compute(_deletePermanentJob, files.path);
        files.createSync(recursive: true);
      }
      await _rewriteManifest(const []);
    } catch (e) {
      debugPrint('[FileQueryService] emptyTrash: $e');
    }
  }

  static Future<void> _removeFromManifest(String trashPath) async {
    try {
      final Directory support = await getApplicationSupportDirectory();
      final File manifest = File('${support.path}/trash/manifest.jsonl');
      if (!manifest.existsSync()) return;
      final List<String> kept = <String>[];
      for (final String line in manifest.readAsLinesSync()) {
        if (!line.contains('"$trashPath"')) kept.add(line);
      }
      await _rewriteManifest(kept);
    } catch (e) {
      debugPrint('[FileQueryService] removeFromManifest: $e');
    }
  }

  static Future<void> _rewriteManifest(List<String> lines) async {
    final Directory support = await getApplicationSupportDirectory();
    final File manifest = File('${support.path}/trash/manifest.jsonl');
    await manifest.writeAsString(
      lines.isEmpty ? '' : '${lines.join('\n')}\n',
      flush: true,
    );
  }

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
          await compute(_deletePermanentJob, p);
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
      final Directory out = Directory('$destPath/.${_baseName(archivePath)}_extracted');
      final bool ok = await compute(
        _extractJob,
        _ExtractArgs(zipPath: archivePath, destPath: out.path),
      );
      if (!ok) return false;
      if (deleteAfter) await compute(_deletePermanentJob, archivePath);
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
  static Future<ApkInfo?> getApkInfo(String path) async {
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
  // ANALISADOR DE ARMAZENAMENTO
  // =========================================================================

  /// Uso por categoria. Varredura completa da árvore (menos subárvores
  /// excluídas + lixeira) rodando em isolate — pode levar segundos em
  /// armazenamentos cheios; a tela mostra loading.
  static Future<StorageUsage> getStorageUsage({String? rootPath}) async {
    final StorageVolume volume = (await loadStorageVolumes()).firstOrNull ??
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
      debugPrint('[FileQueryService] tamanho do cache falhou: $e');
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
        _LargestArgs(
          rootPath: rootPath ?? '/storage/emulated/0',
          limit: limit,
        ),
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
          .map((g) => DuplicateGroup(
                hash: g.hash,
                size: g.size,
                files: g.items,
              ))
          .toList()
        ..sort((a, b) => b.size.compareTo(a.size));
    } catch (e) {
      debugPrint('[FileQueryService] findDuplicates: $e');
      return const [];
    }
  }

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

// =============================================================================
// ENTRADA DA LIXEIRA
// =============================================================================

class TrashEntry {
  final String originalPath;
  final String trashPath;
  final int deletedAtMs;
  final int sizeBytes;

  const TrashEntry({
    required this.originalPath,
    required this.trashPath,
    required this.deletedAtMs,
    required this.sizeBytes,
  });

  String get originalName =>
      originalPath.split('/').where((s) => s.isNotEmpty).last;

  String get displayDeletedAt {
    final DateTime dt = DateTime.fromMillisecondsSinceEpoch(deletedAtMs);
    return '${dt.day.toString().padLeft(2, '0')}/'
        '${dt.month.toString().padLeft(2, '0')}/${dt.year}';
  }
}

// =============================================================================
// RESULTADOS SIMPLES
// =============================================================================

class FileListResult {
  final List<FileItem> items;
  final int totalCount;
  final bool hasMore;

  const FileListResult({
    required this.items,
    required this.totalCount,
    required this.hasMore,
  });

  factory FileListResult.empty() => const FileListResult(
        items: [],
        totalCount: 0,
        hasMore: false,
      );
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
  final String? iconPath;
  final int minSdkVersion;
  final int targetSdkVersion;

  const ApkInfo({
    required this.packageName,
    required this.versionName,
    required this.versionCode,
    required this.appName,
    this.iconPath,
    required this.minSdkVersion,
    required this.targetSdkVersion,
  });

  factory ApkInfo.fromChannel(Map<dynamic, dynamic> map) {
    return ApkInfo(
      packageName: map['packageName'] as String? ?? '?',
      versionName: map['versionName'] as String? ?? '?',
      versionCode: (map['versionCode'] as num?)?.toInt() ?? 0,
      appName: map['appName'] as String? ?? '?',
      iconPath: map['iconPath'] as String?,
      minSdkVersion: (map['minSdkVersion'] as num?)?.toInt() ?? 0,
      targetSdkVersion: (map['targetSdkVersion'] as num?)?.toInt() ?? 0,
    );
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
      final String name =
          path.split('/').where((s) => s.isNotEmpty).last;
      if (!args.includeHidden && name.startsWith('.')) continue;

      final bool isDir = stat.type == FileSystemEntityType.directory;
      final FileType type = isDir
          ? FileType.directory
          : FileTypeMap.fromExtension(_jobExt(name));

      if (args.filterType != null &&
          type.name != args.filterType &&
          type != FileType.directory) {
        continue;
      }

      matched.add(FileItem.fromStat(
        path: path,
        isDirectory: isDir,
        size: stat.size,
        modifiedSeconds: stat.modified.millisecondsSinceEpoch ~/ 1000,
        createdSeconds: stat.changed.millisecondsSinceEpoch ~/ 1000,
      ));
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
    if (_isExcluded(current)) continue;
    final Directory dir = Directory(current);
    List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: false);
    } catch (_) {
      continue;
    }
    for (final FileSystemEntity entity in entries) {
      try {
        final String name =
            entity.path.split('/').where((s) => s.isNotEmpty).last;
        final bool isDir = FileSystemEntity.isDirectorySync(entity.path);
        if (isDir) {
          if (!_isExcluded(entity.path)) stack.add(entity.path);
          continue;
        }
        if (!name.toLowerCase().contains(args.query)) continue;
        if (args.filterType != null &&
            FileTypeMap.fromExtension(_jobExt(name)).name !=
                args.filterType) {
          continue;
        }
        final FileStat stat = entity.statSync();
        if (found.length >= args.limit) break;
        found.add(FileItem.fromStat(
          path: entity.path,
          isDirectory: false,
          size: stat.size,
          modifiedSeconds: stat.modified.millisecondsSinceEpoch ~/ 1000,
          createdSeconds: stat.changed.millisecondsSinceEpoch ~/ 1000,
        ));
      } catch (_) {
        continue;
      }
    }
  }
  found.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return found;
}

bool _isExcluded(String path) {
  for (final String ex in FileQueryService._excludedNames) {
    if (path.contains('/$ex')) return true;
  }
  return path.contains('/audify/trash/');
}

String _jobExt(String name) {
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

class _TwoPaths {
  final String source;
  final String dest;
  const _TwoPaths({required this.source, required this.dest});
}

/// Cópia recursiva síncrona em streaming (buffers de 256 KB) — roda inteira
/// no isolate.
bool _copyJob(_TwoPaths args) {
  try {
    _copyRecursive(args.source, args.dest);
    return true;
  } catch (_) {
    return false;
  }
}

void _copyRecursive(String source, String dest) {
  final FileSystemEntityType type = FileSystemEntity.typeSync(source);
  if (type == FileSystemEntityType.directory) {
    Directory(dest).createSync(recursive: true);
    for (final FileSystemEntity child
        in Directory(source).listSync(followLinks: false)) {
      _copyRecursive(child.path, '$dest/${child.path.split('/').last}');
    }
    return;
  }
  if (type == FileSystemEntityType.notFound) {
    throw StateError('Origem não encontrada: $source');
  }
  Directory(File(dest).parent.path).createSync(recursive: true);
  final RandomAccessFile input = File(source).openSync();
  try {
    final RandomAccessFile output = File(dest).openSync(mode: FileMode.write);
    try {
      final Uint8List buffer = Uint8List(256 * 1024);
      int read = input.readIntoSync(buffer, 0, buffer.length);
      while (read > 0) {
        output.writeFromSync(buffer, 0, read);
        read = input.readIntoSync(buffer, 0, buffer.length);
      }
    } finally {
      output.closeSync();
    }
  } finally {
    input.closeSync();
  }
}

bool _moveJob(_TwoPaths args) {
  try {
    // Mesmo volume: rename é instantâneo.
    try {
      FileSystemEntity.typeSync(args.source);
      if (FileSystemEntity.isDirectorySync(args.source)) {
        Directory(args.source).renameSync(args.dest);
      } else {
        File(args.source).renameSync(args.dest);
      }
      return true;
    } on FileSystemException {
      // Volume diferente: copia + apaga.
      _copyRecursive(args.source, args.dest);
      _deleteRecursiveSync(args.source);
      return true;
    }
  } catch (_) {
    return false;
  }
}

/// Renomear = mover para o mesmo pai com outro nome.
bool _renameJob(_TwoPaths args) => _moveJob(args);

class _RestoreArgs {
  final TrashEntry entry;
  const _RestoreArgs({required this.entry});
}

bool _restoreJob(_RestoreArgs args) {
  try {
    final TrashEntry entry = args.entry;
    final String parent =
        entry.originalPath.substring(0, entry.originalPath.lastIndexOf('/'));
    Directory(parent).createSync(recursive: true);
    final bool isDir = FileSystemEntity.isDirectorySync(entry.trashPath);
    if (isDir) {
      Directory(entry.trashPath).renameSync(entry.originalPath);
    } else {
      File(entry.trashPath).renameSync(entry.originalPath);
    }
    return true;
  } catch (_) {
    return false;
  }
}

bool _deletePermanentJob(String path) {
  try {
    _deleteRecursiveSync(path);
    return true;
  } catch (_) {
    return false;
  }
}

void _deleteRecursiveSync(String path) {
  final FileSystemEntityType type = FileSystemEntity.typeSync(path);
  if (type == FileSystemEntityType.notFound) return;
  if (type == FileSystemEntityType.directory) {
    for (final FileSystemEntity child
        in Directory(path).listSync(followLinks: false)) {
      _deleteRecursiveSync(child.path);
    }
    Directory(path).deleteSync(recursive: false);
  } else {
    File(path).deleteSync();
  }
}

bool _createDirJob(String path) {
  try {
    Directory(path).createSync(recursive: true);
    return true;
  } catch (_) {
    return false;
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
      final FileSystemEntityType type =
          FileSystemEntity.typeSync(fsPath, followLinks: true);
      if (type == FileSystemEntityType.directory) {
        for (final FileSystemEntity child
            in Directory(fsPath).listSync(followLinks: true)) {
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
    final String normalizedDest =
        Directory(args.destPath).absolute.path.replaceAll(r'\', '/');

    for (final ArchiveFile entry in archive) {
      final String outPath =
          '$normalizedDest/${entry.name}'.replaceAll(r'\', '/');
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
  final FileType type = FileTypeMap.fromExtension(_jobExt(name));
  if (type == FileType.image && stat.size > 0 && stat.size < 60 * 1024 * 1024) {
    try {
      final Map<String, IfdTag> tags =
          await readExifFromFile(File(path));
      exif = <String, dynamic>{
        for (final MapEntry<String, IfdTag> e in tags.entries)
          e.key.replaceFirst('EXIF ', '').replaceFirst('Image ', ''): e.value
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

int _dirSizeJob(String path) {
  int total = 0;
  final List<String> stack = <String>[path];
  while (stack.isNotEmpty) {
    final String current = stack.removeLast();
    try {
      for (final FileSystemEntity entity
          in Directory(current).listSync(followLinks: false)) {
        final FileSystemEntityType type =
            FileSystemEntity.typeSync(entity.path, followLinks: false);
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

FileType _categoryOf(String name) =>
    FileTypeMap.fromExtension(_jobExt(name));

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
    if (_isExcluded(current)) continue;
    List<FileSystemEntity> entries;
    try {
      entries = Directory(current).listSync(followLinks: false);
    } catch (_) {
      continue;
    }
    for (final FileSystemEntity entity in entries) {
      try {
        final FileSystemEntityType type =
            FileSystemEntity.typeSync(entity.path, followLinks: false);
        if (type == FileSystemEntityType.directory) {
          if (!_isExcluded(entity.path)) stack.add(entity.path);
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
    if (_isExcluded(current)) continue;
    List<FileSystemEntity> entries;
    try {
      entries = Directory(current).listSync(followLinks: false);
    } catch (_) {
      continue;
    }
    for (final FileSystemEntity entity in entries) {
      try {
        final FileSystemEntityType type =
            FileSystemEntity.typeSync(entity.path, followLinks: false);
        if (type == FileSystemEntityType.directory) {
          if (!_isExcluded(entity.path)) stack.add(entity.path);
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
    if (_isExcluded(current)) continue;
    List<FileSystemEntity> entries;
    try {
      entries = Directory(current).listSync(followLinks: false);
    } catch (_) {
      continue;
    }
    for (final FileSystemEntity entity in entries) {
      try {
        final FileSystemEntityType type =
            FileSystemEntity.typeSync(entity.path, followLinks: false);
        if (type == FileSystemEntityType.directory) {
          if (!_isExcluded(entity.path)) stack.add(entity.path);
          continue;
        }
        if (type != FileSystemEntityType.file) continue;
        final FileStat stat = entity.statSync();
        if (stat.size < args.minSize) continue;
        (bySize[stat.size] ??= <FileItem>[]).add(FileItem.fromStat(
          path: entity.path,
          isDirectory: false,
          size: stat.size,
          modifiedSeconds: stat.modified.millisecondsSinceEpoch ~/ 1000,
          createdSeconds: stat.changed.millisecondsSinceEpoch ~/ 1000,
        ));
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
        final Digest digest =
            await sha256.bind(File(item.path).openRead()).first;
        (byHash[digest.toString()] ??= <FileItem>[]).add(item);
      } catch (_) {
        continue;
      }
    }
    for (final MapEntry<String, List<FileItem>> hashed in byHash.entries) {
      if (hashed.value.length >= 2) {
        groups.add(
            _DupRaw(hashed.key, entry.key, hashed.value));
      }
    }
  }
  return groups;
}
