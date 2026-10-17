import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'file_ops_jobs.dart';
import 'file_query_service.dart';  // formatBytes (ciclo aceito pelo Dart)

/// Lixeira interna do app: arquivos movidos para o diretório de suporte com
/// manifesto JSONL (original, destino, data) e retenção com expurgo.
///
/// Extraída de file_query_service.dart no item 6.2 — a API pública segue
/// disponível em `FileQueryService` (delegação).
class TrashService {
  static Future<Directory> _trashDir() async {
    final Directory support = await getApplicationSupportDirectory();
    final Directory dir = Directory('${support.path}/trash/files');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return Directory('${support.path}/trash');
  }

  static File _manifestFile(Directory trashRoot) =>
      File('${trashRoot.path}/manifest.jsonl');

  static Future<void> _appendToManifest(
    String originalPath,
    String trashPath,
    DateTime at,
  ) async {
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
      final File manifest = File('${support.path}/trash/manifest.jsonl');
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
          final FileSystemEntityType kind = FileSystemEntity.typeSync(
            trashPath,
          );
          final int size = kind == FileSystemEntityType.file
              ? File(trashPath).lengthSync()
              : 0;
          result.add(
            TrashEntry(
              originalPath: map['original'] as String,
              trashPath: trashPath,
              deletedAtMs: (map['deletedAtMs'] as num).toInt(),
              sizeBytes: size,
            ),
          );
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
      final bool moved = await compute(_restoreJob, _RestoreArgs(entry: entry));
      if (moved) await _removeFromManifest(entry.trashPath);
      return moved;
    } catch (e) {
      debugPrint('[FileQueryService] restoreFromTrash: $e');
      return false;
    }
  }

  static Future<bool> deleteForever(String trashPath) async {
    try {
      final bool ok = await compute(deletePermanentJob, trashPath);
      if (ok) await _removeFromManifest(trashPath);
      return ok;
    } catch (e) {
      debugPrint('[FileQueryService] deleteForever: $e');
      return false;
    }
  }

  /// Apaga da lixeira o que já passou do prazo.
  ///
  /// A lixeira vivia sem política nenhuma: `deletedAtMs` era gravado no
  /// manifesto e nunca lido, então os arquivos ficavam lá para sempre e o
  /// espaço nunca era devolvido. É o pior dos dois mundos — o usuário não
  /// sabe que a lixeira está ocupando GB, e não consegue liberar sem ir item
  /// por item.
  ///
  /// Devolve quantos itens foram expurgados (para a UI avisar).
  static Future<int> purgeExpired(int retentionDays) async {
    if (retentionDays <= 0) return 0; // 0 = manter para sempre
    final List<TrashEntry> all = await listTrash();
    final DateTime cutoff = DateTime.now().subtract(
      Duration(days: retentionDays),
    );
    int purged = 0;
    for (final TrashEntry entry in all) {
      if (DateTime.fromMillisecondsSinceEpoch(
        entry.deletedAtMs,
      ).isAfter(cutoff)) {
        continue;
      }
      if (await deleteForever(entry.trashPath)) purged++;
    }
    return purged;
  }

  /// Espaço ocupado pela lixeira agora, em bytes.
  ///
  /// A lixeira é invisível no gerenciador de arquivos do sistema (fica no
  /// diretório de suporte do app), então sem isto o usuário não tem como
  /// saber que ela está ocupando espaço.
  static Future<int> trashSize() async {
    final List<TrashEntry> entries = await listTrash();
    return entries.fold<int>(0, (int sum, TrashEntry e) => sum + e.sizeBytes);
  }

  static Future<void> emptyTrash() async {
    try {
      final Directory trashRoot = await _trashDir();
      final Directory files = Directory('${trashRoot.path}/files');
      if (files.existsSync()) {
        await compute(deletePermanentJob, files.path);
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

  /// Move [path] para a lixeira interna e registra no manifesto — o caminho
  /// usado por `FileQueryService.delete(useTrash: true)`.
  static Future<bool> moveToTrash(String path) async {
    try {
      final Directory trashRoot = await _trashDir();
      final String stamp = DateTime.now().microsecondsSinceEpoch.toString();
      final String inside =
          '${trashRoot.path}/files/${stamp}_'
          '${path.split('/').where((s) => s.isNotEmpty).last}';
      final bool moved = await compute(
        moveJob,
        TwoPaths(source: path, dest: inside),
      );
      if (!moved) return false;
      await _appendToManifest(path, inside, DateTime.now());
      return true;
    } catch (e) {
      debugPrint('[TrashService] moveToTrash: $e');
      return false;
    }
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

  /// "3 dias" / "hoje" — usado na lista e na confirmação.
  String get ageLabel {
    final Duration age = DateTime.now().difference(
      DateTime.fromMillisecondsSinceEpoch(deletedAtMs),
    );
    if (age.inMinutes < 1) return 'agora';
    if (age.inHours < 1) return 'há ${age.inMinutes} min';
    if (age.inDays < 1) return 'há ${age.inHours} h';
    if (age.inDays == 1) return 'há 1 dia';
    return 'há ${age.inDays} dias';
  }

  /// Quando este item será expurgado, dado o prazo em dias.
  ///
  /// `retentionDays <= 0` significa "manter para sempre" e devolve null — a UI
  /// então mostra "pra sempre", que é informação útil por si só.
  DateTime? expiryWith(int retentionDays) {
    if (retentionDays <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(
      deletedAtMs,
    ).add(Duration(days: retentionDays));
  }

  /// "expira em 5 dias" / "expira hoje" / "pra sempre".
  String expiryLabel(int retentionDays) {
    final DateTime? expiry = expiryWith(retentionDays);
    if (expiry == null) return 'fica na lixeira até você apagar';
    final int days = expiry.difference(DateTime.now()).inDays;
    if (days <= 0) return 'expira hoje';
    if (days == 1) return 'expira amanhã';
    return 'expira em $days dias';
  }

  /// Verdadeiro quando o prazo já passou — o expurgo remove.
  bool isExpired(int retentionDays) {
    if (retentionDays <= 0) return false;
    return DateTime.fromMillisecondsSinceEpoch(
      deletedAtMs,
    ).isBefore(DateTime.now().subtract(Duration(days: retentionDays)));
  }

  String get displaySize => formatBytes(sizeBytes);
}

// =============================================================================
// RESULTADOS SIMPLES
// =============================================================================

class _RestoreArgs {
  final TrashEntry entry;
  const _RestoreArgs({required this.entry});
}

bool _restoreJob(_RestoreArgs args) {
  try {
    final TrashEntry entry = args.entry;
    final String parent = entry.originalPath.substring(
      0,
      entry.originalPath.lastIndexOf('/'),
    );
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
