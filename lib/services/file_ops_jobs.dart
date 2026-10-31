import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

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
      _copyRecursive(child.path, '$dest/${p.basename(child.path)}');
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

/// Move = rename no mesmo volume; em volume diferente copia com verificação,
/// publica o destino e só então apaga a origem.
///
/// O fallback antigo capturava QUALQUER `FileSystemException` (inclusive
/// permissão negada) e copiava às cegas, sem conferir o resultado. Agora só
/// EXDEV (cross-device) cai no caminho de cópia.
bool moveJob(TwoPaths args) {
  final FileSystemEntityType type = FileSystemEntity.typeSync(args.source);
  if (type == FileSystemEntityType.notFound) return false;
  // Nunca sobrescreve: o chamador resolve colisão com uniquePathSync, mas
  // uma corrida entre a checagem e o rename não pode apagar dados.
  if (FileSystemEntity.typeSync(args.dest) != FileSystemEntityType.notFound) {
    return false;
  }

  try {
    // O pai do destino pode não existir (mover para subpasta nova). Criar
    // antes evita que o rename falhe e caia no fallback de cópia.
    Directory(p.dirname(args.dest)).createSync(recursive: true);
    if (type == FileSystemEntityType.directory) {
      Directory(args.source).renameSync(args.dest);
    } else {
      File(args.source).renameSync(args.dest);
    }
    return true;
  } on FileSystemException catch (e) {
    if (!_isCrossDevice(e)) return false;
  } catch (_) {
    return false;
  }

  return moveAcrossVolumes(args.source, args.dest);
}

bool _isCrossDevice(FileSystemException e) {
  if (e.osError?.errorCode == 18) return true; // EXDEV (Linux/Android)
  final String message = (e.osError?.message ?? e.message).toLowerCase();
  return message.contains('exdev') ||
      message.contains('cross-device') ||
      message.contains('cross device');
}

/// Caminho de "volume diferente" usado por [moveJob] e testável direto:
/// copia para um temporário, confere tamanho/hash, publica o destino e só
/// então apaga a origem. Em qualquer falha, a origem permanece intacta.
bool moveAcrossVolumes(String source, String dest) {
  final String temp =
      '$dest.audify-tmp-${DateTime.now().microsecondsSinceEpoch}';
  try {
    _copyRecursive(source, temp);
    if (!_sameContent(source, temp)) {
      _deleteRecursiveSync(temp);
      return false;
    }
    if (FileSystemEntity.typeSync(dest) != FileSystemEntityType.notFound) {
      _deleteRecursiveSync(temp);
      return false;
    }
    if (FileSystemEntity.isDirectorySync(temp)) {
      Directory(temp).renameSync(dest);
    } else {
      File(temp).renameSync(dest);
    }
    try {
      _deleteRecursiveSync(source);
    } catch (_) {
      // Se não conseguimos apagar a origem, desfazemos a cópia para não
      // deixar o usuário com dois arquivos achando que moveu.
      try {
        _deleteRecursiveSync(dest);
      } catch (_) {
        // Sem recuperação possível: a origem continua intacta e o destino
        // duplicado é reportado como falha.
      }
      return false;
    }
    return true;
  } catch (_) {
    try {
      if (FileSystemEntity.typeSync(temp) != FileSystemEntityType.notFound) {
        _deleteRecursiveSync(temp);
      }
    } catch (_) {
      // Limpeza best-effort do temporário; a origem não foi tocada.
    }
    return false;
  }
}

/// Confere tamanho (e SHA-256 para arquivos até 64 MB) entre origem e cópia.
bool _sameContent(String source, String copy) {
  final FileSystemEntityType type = FileSystemEntity.typeSync(source);
  if (type == FileSystemEntityType.directory) {
    final Map<String, int> sourceFiles = _fileSizes(source);
    final Map<String, int> copyFiles = _fileSizes(copy);
    if (sourceFiles.length != copyFiles.length) return false;
    for (final MapEntry<String, int> entry in sourceFiles.entries) {
      if (copyFiles[entry.key] != entry.value) return false;
      if (entry.value <= 64 * 1024 * 1024) {
        final File a = File(p.join(source, entry.key));
        final File b = File(p.join(copy, entry.key));
        if (sha256.convert(a.readAsBytesSync()).toString() !=
            sha256.convert(b.readAsBytesSync()).toString()) {
          return false;
        }
      }
    }
    return true;
  }

  final File a = File(source);
  final File b = File(copy);
  if (!b.existsSync() || a.lengthSync() != b.lengthSync()) return false;
  if (a.lengthSync() > 64 * 1024 * 1024) return true;
  return sha256.convert(a.readAsBytesSync()).toString() ==
      sha256.convert(b.readAsBytesSync()).toString();
}

Map<String, int> _fileSizes(String root) {
  final Map<String, int> sizes = <String, int>{};
  void walk(Directory dir) {
    for (final FileSystemEntity entity in dir.listSync(followLinks: false)) {
      if (entity is Directory) {
        walk(entity);
      } else if (entity is File) {
        sizes[p.relative(entity.path, from: root)] = entity.lengthSync();
      }
    }
  }

  walk(Directory(root));
  return sizes;
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

/// Sufixo " (1)", " (2)"… quando o destino já existe — nunca sobrescreve
/// silenciosamente. Versão síncrona compartilhada com a lixeira.
String uniquePathSync(String path) {
  if (FileSystemEntity.typeSync(path) == FileSystemEntityType.notFound) {
    return path;
  }
  final bool isDir = FileSystemEntity.isDirectorySync(path);
  final String parent = p.dirname(path);
  final String name = p.basename(path);
  String stem = name;
  String ext = '';
  if (!isDir) {
    final int dot = name.lastIndexOf('.');
    if (dot > 0) {
      stem = name.substring(0, dot);
      ext = name.substring(dot);
    }
  }
  for (int i = 1; i < 1000; i++) {
    final String candidate = '$parent/$stem ($i)$ext';
    if (FileSystemEntity.typeSync(candidate) == FileSystemEntityType.notFound) {
      return candidate;
    }
  }
  return path;
}
