import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'file_op_result.dart';
import 'file_ops_jobs.dart';
import 'file_query_service.dart'; // formatBytes (ciclo aceito pelo Dart)

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

  /// Registra a INTENÇÃO antes do move e confirma depois.
  ///
  /// Se o processo morrer entre o move e a confirmação, a entrada "pending"
  /// continua no manifesto e o arquivo existe em `trash/files` — listTrash
  /// a recupera. Se o move falhar, a entrada sem arquivo é descartada.
  static Future<void> _appendToManifest(
    String originalPath,
    String trashPath,
    DateTime at, {
    String state = 'pending',
  }) async {
    final Directory support = await getApplicationSupportDirectory();
    final File manifest = _manifestFile(Directory('${support.path}/trash'));
    final Map<String, Object?> entry = <String, Object?>{
      'original': originalPath,
      'trashPath': trashPath,
      'deletedAtMs': at.millisecondsSinceEpoch,
      'state': state,
    };
    await manifest.writeAsString(
      '${jsonEncode(entry)}\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  /// Entradas atuais da lixeira (arquivos que sumiram do disco são omitidos).
  ///
  /// Cada linha é decodificada como JSON — comparar texto (`contains`) quebra
  /// com aspas/barras no caminho e podia esconder itens. Entradas repetidas
  /// (pending + moved) são deduplicadas pela última ocorrência.
  static Future<List<TrashEntry>> listTrash() async {
    try {
      final Directory support = await getApplicationSupportDirectory();
      final File manifest = File('${support.path}/trash/manifest.jsonl');
      if (!manifest.existsSync()) return const [];

      final Map<String, TrashEntry> byPath = <String, TrashEntry>{};
      for (final String line in manifest.readAsLinesSync()) {
        if (line.trim().isEmpty) continue;
        try {
          final Map<String, dynamic> map =
              jsonDecode(line) as Map<String, dynamic>;
          final String trashPath = map['trashPath'] as String;
          final FileSystemEntityType kind = FileSystemEntity.typeSync(
            trashPath,
          );
          if (kind == FileSystemEntityType.notFound) continue;
          final int size = kind == FileSystemEntityType.file
              ? File(trashPath).lengthSync()
              : 0;
          byPath[trashPath] = TrashEntry(
            originalPath: map['original'] as String,
            trashPath: trashPath,
            deletedAtMs: (map['deletedAtMs'] as num).toInt(),
            sizeBytes: size,
          );
        } catch (_) {
          // Linha corrompida (processo morto no meio da escrita antiga):
          // ignora só ela; as demais continuam recuperáveis.
          continue;
        }
      }
      return byPath.values.toList();
    } catch (e) {
      debugPrint('[TrashService] listTrash: $e');
      return const [];
    }
  }

  /// Devolve o item ao local original (recriando pastas se necessário).
  ///
  /// Usa o mesmo `moveJob` da exclusão: rename no mesmo volume e, quando o
  /// original está em outro volume (lixeira interna -> armazenamento
  /// compartilhado, o caso normal), cópia verificada + remoção da origem.
  /// Se o nome original já existe, restaura como "nome (1)" — nunca
  /// sobrescreve em silêncio.
  static Future<FileOpResult> restoreFromTrash(TrashEntry entry) async {
    try {
      final String target = uniquePathSync(entry.originalPath);
      final bool moved = await compute(
        moveJob,
        TwoPaths(source: entry.trashPath, dest: target),
      );
      if (!moved) {
        return const FileOpResult.failed(
          reason:
              'Não foi possível restaurar. O arquivo continua na lixeira; '
              'verifique o espaço livre e a permissão da pasta original.',
          code: FileOpErrorCode.io,
        );
      }
      await _removeFromManifest(entry.trashPath);
      return FileOpResult.ok(path: target);
    } catch (e) {
      debugPrint('[TrashService] restoreFromTrash: $e');
      return FileOpResult.failed(
        reason: 'Não foi possível restaurar: $e',
        code: FileOpErrorCode.io,
      );
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
        if (line.trim().isEmpty) continue;
        try {
          final Map<String, dynamic> map =
              jsonDecode(line) as Map<String, dynamic>;
          if (map['trashPath'] == trashPath) continue;
        } catch (_) {
          // Mantém linhas ilegíveis? Não: o manifesto novo só carrega
          // entradas válidas (listTrash já as ignoraria).
          continue;
        }
        kept.add(line);
      }
      await _rewriteManifest(kept);
    } catch (e) {
      debugPrint('[TrashService] removeFromManifest: $e');
    }
  }

  /// Escrita atômica: grava `manifest.tmp`, força o flush e renomeia sobre o
  /// manifesto. Um processo morto no meio deixa o manifesto anterior intacto
  /// (ou o novo completo), nunca um arquivo truncado.
  static Future<void> _rewriteManifest(List<String> lines) async {
    final Directory support = await getApplicationSupportDirectory();
    final File manifest = File('${support.path}/trash/manifest.jsonl');
    final File temp = File('${manifest.path}.tmp');
    await temp.writeAsString(
      lines.isEmpty ? '' : '${lines.join('\n')}\n',
      flush: true,
    );
    await temp.rename(manifest.path);
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
      final DateTime now = DateTime.now();

      // Intenção ANTES do move: se o app morrer no meio, a entrada pending
      // + o arquivo em trash/files permitem recuperar o item.
      await _appendToManifest(path, inside, now);
      final bool moved = await compute(
        moveJob,
        TwoPaths(source: path, dest: inside),
      );
      if (!moved) {
        await _removeFromManifest(inside);
        return false;
      }
      // Confirmação (a entrada pending já basta para listar; a linha moved
      // mantém o histórico legível).
      await _appendToManifest(path, inside, now, state: 'moved');
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
