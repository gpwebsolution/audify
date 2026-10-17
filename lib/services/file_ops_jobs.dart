import 'dart:io';
import 'dart:typed_data';

/// Jobs de isolate (top-level: exigência do compute()) do gerenciador de
/// arquivos. Extraídos de file_query_service.dart no item 6.2 — funções
/// puras de dart:io, sem estado de serviço.

class TwoPaths {
  final String source;
  final String dest;
  const TwoPaths({required this.source, required this.dest});
}

/// Cópia recursiva síncrona em streaming (buffers de 256 KB) — roda inteira
/// no isolate.
bool copyJob(TwoPaths args) {
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
    for (final FileSystemEntity child in Directory(
      source,
    ).listSync(followLinks: false)) {
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

bool moveJob(TwoPaths args) {
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
bool renameJob(TwoPaths args) => moveJob(args);

bool deletePermanentJob(String path) {
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
    for (final FileSystemEntity child in Directory(
      path,
    ).listSync(followLinks: false)) {
      _deleteRecursiveSync(child.path);
    }
    Directory(path).deleteSync(recursive: false);
  } else {
    File(path).deleteSync();
  }
}

bool createDirJob(String path) {
  try {
    Directory(path).createSync(recursive: true);
    return true;
  } catch (_) {
    return false;
  }
}
