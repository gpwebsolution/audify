import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import 'file_op_result.dart';

/// Limites de segurança para extração de ZIP.
///
/// Um ZIP pode declarar milhões de entradas, descompactar para centenas de
/// GB (zip bomb) ou tentar escrever fora da pasta de destino (zip-slip).
/// Os valores padrão são generosos para uso pessoal e continuam protegendo
/// o aparelho de um arquivo malicioso/corrompido.
class ExtractionLimits {
  final int maxEntries;
  final int maxTotalBytes;
  final int maxEntryBytes;
  final double maxCompressionRatio;

  const ExtractionLimits({
    this.maxEntries = 10000,
    this.maxTotalBytes = 2 * 1024 * 1024 * 1024,
    this.maxEntryBytes = 1024 * 1024 * 1024,
    this.maxCompressionRatio = 100,
  });
}

/// Argumentos serializáveis do job de isolate.
class ZipExtractArgs {
  final String archivePath;
  final String destPath;
  final ExtractionLimits limits;

  const ZipExtractArgs({
    required this.archivePath,
    required this.destPath,
    required this.limits,
  });
}

/// Wrapper top-level exigido pelo `compute()`.
FileOpResult extractZipJob(ZipExtractArgs args) => extractZipSync(
  archivePath: args.archivePath,
  destPath: args.destPath,
  limits: args.limits,
);

/// Extrai [archivePath] para [destPath], recusando qualquer entrada que
/// tente escapar do destino.
///
/// Roda dentro de um isolate (`compute`) na chamada pública. A leitura do
/// ZIP é em streaming: o conteúdo de cada entrada é decodificado direto para
/// o arquivo de saída, sem carregar o arquivo inteiro na memória.
FileOpResult extractZipSync({
  required String archivePath,
  required String destPath,
  ExtractionLimits limits = const ExtractionLimits(),
}) {
  final File zipFile = File(archivePath);
  if (!zipFile.existsSync()) {
    return const FileOpResult.failed(
      reason: 'Arquivo ZIP não encontrado.',
      code: FileOpErrorCode.notFound,
    );
  }

  // O decodificador aceita bytes arbitrários como "ZIP vazio"; exigir a
  // assinatura evita que um arquivo renomeado para .zip passe como sucesso.
  final RandomAccessFile raf = zipFile.openSync();
  final List<int> header;
  try {
    header = raf.readSync(4);
  } finally {
    raf.closeSync();
  }
  final bool looksLikeZip =
      header.length == 4 &&
      header[0] == 0x50 &&
      header[1] == 0x4B &&
      (header[2] == 0x03 || header[2] == 0x05 || header[2] == 0x07);
  if (!looksLikeZip) {
    return const FileOpResult.failed(
      reason: 'O arquivo não é um ZIP válido.',
      code: FileOpErrorCode.io,
    );
  }

  final int archiveBytes = zipFile.lengthSync();
  final String destRoot = p.normalize(Directory(destPath).absolute.path);
  Directory(destRoot).createSync(recursive: true);

  InputFileStream? input;
  try {
    input = InputFileStream(archivePath);
    final Archive archive = ZipDecoder().decodeStream(input);

    final Set<String> seen = <String>{};
    int entryCount = 0;
    int declaredTotal = 0;
    int writtenTotal = 0;

    for (final ArchiveFile entry in archive) {
      entryCount++;
      if (entryCount > limits.maxEntries) {
        return _fail('O ZIP tem entradas demais (máx. ${limits.maxEntries}).');
      }

      // Links simbólicos podem apontar para fora do destino mesmo com o
      // nome "inocente". Não são necessários para nenhum fluxo do app.
      if (entry.isSymbolicLink) {
        return _fail(
          'O ZIP contém um link simbólico e foi recusado por segurança.',
        );
      }

      final String rawName = entry.name.replaceAll(r'\', '/');
      if (rawName.trim().isEmpty) continue;

      final String? unsafe = _unsafeEntryReason(rawName);
      if (unsafe != null) return _fail(unsafe);

      final String outPath = p.normalize(p.join(destRoot, rawName));
      if (outPath != destRoot && !p.isWithin(destRoot, outPath)) {
        return _fail('O ZIP tentou escrever fora da pasta de destino.');
      }

      if (!seen.add(outPath)) {
        return _fail('O ZIP tem entradas duplicadas e foi recusado.');
      }

      if (entry.isDirectory) {
        Directory(outPath).createSync(recursive: true);
        continue;
      }

      if (entry.size < 0 || entry.size > limits.maxEntryBytes) {
        return _fail(
          'Um arquivo do ZIP é grande demais '
          '(máx. ${_mb(limits.maxEntryBytes)}).',
        );
      }
      declaredTotal += entry.size;
      if (declaredTotal > limits.maxTotalBytes) {
        return _fail(
          'O conteúdo do ZIP passa do limite de ${_mb(limits.maxTotalBytes)}.',
        );
      }
      if (archiveBytes > 0 &&
          declaredTotal > archiveBytes * limits.maxCompressionRatio) {
        return _fail(
          'O ZIP tem taxa de compressão suspeita (possível zip bomb).',
        );
      }

      final Directory parent = Directory(p.dirname(outPath));
      parent.createSync(recursive: true);

      if (_hasSymlinkAncestor(destRoot, outPath)) {
        return _fail('O destino contém um link simbólico; extração recusada.');
      }

      final OutputFileStream output = OutputFileStream(outPath);
      try {
        entry.writeContent(output);
      } finally {
        output.closeSync();
      }

      final int written = File(outPath).lengthSync();
      if (written != entry.size) {
        return _fail('Um arquivo do ZIP saiu incompleto (corrompido).');
      }
      writtenTotal += written;
      if (writtenTotal > limits.maxTotalBytes) {
        return _fail(
          'O conteúdo do ZIP passa do limite de ${_mb(limits.maxTotalBytes)}.',
        );
      }
      if (archiveBytes > 0 &&
          writtenTotal > archiveBytes * limits.maxCompressionRatio) {
        return _fail(
          'O ZIP tem taxa de compressão suspeita (possível zip bomb).',
        );
      }
    }

    return const FileOpResult.ok();
  } on ArchiveException catch (e) {
    return FileOpResult.failed(
      reason: 'ZIP inválido ou corrompido: ${e.message}',
      code: FileOpErrorCode.io,
    );
  } catch (e) {
    return FileOpResult.failed(
      reason: 'Não foi possível extrair o ZIP: $e',
      code: FileOpErrorCode.io,
    );
  } finally {
    input?.closeSync();
  }
}

FileOpResult _fail(String reason) =>
    FileOpResult.failed(reason: reason, code: FileOpErrorCode.unsafePath);

String? _unsafeEntryReason(String name) {
  if (p.isAbsolute(name) || name.startsWith('/')) {
    return 'O ZIP contém um caminho absoluto e foi recusado.';
  }
  // Drive letter (C:\...) mesmo depois de trocar as barras.
  if (RegExp(r'^[A-Za-z]:').hasMatch(name)) {
    return 'O ZIP contém um caminho absoluto e foi recusado.';
  }
  final List<String> parts = name.split('/');
  if (parts.contains('..')) {
    return 'O ZIP contém ".." e tentaria escapar da pasta de destino.';
  }
  if (parts.any((String part) => part == '.')) {
    return 'O ZIP contém um caminho com "." e foi recusado.';
  }
  return null;
}

/// Verifica se algum diretório entre [root] e o pai de [target] é um link
/// simbólico pré-existente (o ZIP não cria links, mas o destino pode ter).
bool _hasSymlinkAncestor(String root, String target) {
  String current = p.dirname(target);
  while (true) {
    if (FileSystemEntity.isLinkSync(current)) return true;
    if (current == root) return false;
    final String parent = p.dirname(current);
    if (parent == current || !p.isWithin(root, parent)) return false;
    current = parent;
  }
}

String _mb(int bytes) => bytes >= 1024 * 1024 * 1024
    ? '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(0)} GB'
    : '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';
