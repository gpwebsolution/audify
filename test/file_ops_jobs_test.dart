import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:audify/services/archive_service.dart';
import 'package:audify/services/file_op_result.dart';
import 'package:audify/services/file_ops_jobs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('audify_jobs_test');
  });

  tearDown(() async {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  File mkFile(String path, String content) {
    final File f = File('${temp.path}/$path');
    f.parent.createSync(recursive: true);
    return f..writeAsStringSync(content);
  }

  group('copyJob', () {
    test('copia arquivo e árvore de diretórios', () {
      mkFile('src/a.txt', 'a');
      mkFile('src/sub/b.txt', 'bb');

      expect(
        copyJob(
          TwoPaths(source: '${temp.path}/src', dest: '${temp.path}/copy'),
        ),
        isTrue,
      );

      expect(File('${temp.path}/copy/a.txt').readAsStringSync(), 'a');
      expect(File('${temp.path}/copy/sub/b.txt').readAsStringSync(), 'bb');
    });

    test('origem inexistente devolve false', () {
      expect(
        copyJob(
          TwoPaths(source: '${temp.path}/nao-existe', dest: '${temp.path}/x'),
        ),
        isFalse,
      );
    });
  });

  group('moveJob', () {
    test('move arquivo no mesmo volume', () {
      final File src = mkFile('origem.txt', 'conteudo');

      expect(
        moveJob(TwoPaths(source: src.path, dest: '${temp.path}/novo.txt')),
        isTrue,
      );

      expect(src.existsSync(), isFalse);
      expect(File('${temp.path}/novo.txt').readAsStringSync(), 'conteudo');
    });

    test('cria a pasta de destino quando não existe', () {
      final File src = mkFile('origem.txt', 'x');

      expect(
        moveJob(
          TwoPaths(source: src.path, dest: '${temp.path}/a/b/c/destino.txt'),
        ),
        isTrue,
      );
      expect(File('${temp.path}/a/b/c/destino.txt').existsSync(), isTrue);
    });

    test('move diretório inteiro', () {
      mkFile('pasta/a.txt', 'a');
      mkFile('pasta/sub/b.txt', 'b');

      expect(
        moveJob(
          TwoPaths(source: '${temp.path}/pasta', dest: '${temp.path}/movida'),
        ),
        isTrue,
      );

      expect(File('${temp.path}/movida/a.txt').existsSync(), isTrue);
      expect(File('${temp.path}/movida/sub/b.txt').existsSync(), isTrue);
      expect(Directory('${temp.path}/pasta').existsSync(), isFalse);
    });

    test('nunca sobrescreve destino existente', () {
      final File src = mkFile('origem.txt', 'origem');
      mkFile('destino.txt', 'destino');

      expect(
        moveJob(TwoPaths(source: src.path, dest: '${temp.path}/destino.txt')),
        isFalse,
      );

      expect(src.readAsStringSync(), 'origem');
      expect(File('${temp.path}/destino.txt').readAsStringSync(), 'destino');
    });

    test('origem inexistente devolve false', () {
      expect(
        moveJob(
          TwoPaths(
            source: '${temp.path}/sumiu.txt',
            dest: '${temp.path}/x.txt',
          ),
        ),
        isFalse,
      );
    });
  });

  group('moveAcrossVolumes (fallback EXDEV)', () {
    test('copia, verifica e apaga a origem (arquivo)', () {
      final File src = mkFile('origem.bin', 'conteudo-verificado');

      expect(moveAcrossVolumes(src.path, '${temp.path}/destino.bin'), isTrue);

      expect(src.existsSync(), isFalse);
      expect(
        File('${temp.path}/destino.bin').readAsStringSync(),
        'conteudo-verificado',
      );
    });

    test('copia árvore inteira e remove a origem', () {
      mkFile('pasta/a.txt', 'a');
      mkFile('pasta/sub/b.txt', 'bb');

      expect(
        moveAcrossVolumes('${temp.path}/pasta', '${temp.path}/pasta-destino'),
        isTrue,
      );

      expect(Directory('${temp.path}/pasta').existsSync(), isFalse);
      expect(File('${temp.path}/pasta-destino/a.txt').existsSync(), isTrue);
      expect(File('${temp.path}/pasta-destino/sub/b.txt').existsSync(), isTrue);
    });

    test('destino ocupado não sobrescreve e mantém a origem', () {
      final File src = mkFile('origem.txt', 'origem');
      mkFile('destino.txt', 'destino');

      expect(moveAcrossVolumes(src.path, '${temp.path}/destino.txt'), isFalse);

      expect(src.readAsStringSync(), 'origem');
      expect(File('${temp.path}/destino.txt').readAsStringSync(), 'destino');
    });

    test('origem inexistente devolve false', () {
      expect(
        moveAcrossVolumes('${temp.path}/sumiu', '${temp.path}/destino'),
        isFalse,
      );
    });
  });

  group('delete/create/unique', () {
    test('deletePermanentJob apaga arquivo e diretório', () {
      mkFile('a.txt', 'a');
      mkFile('dir/b.txt', 'b');

      expect(deletePermanentJob('${temp.path}/a.txt'), isTrue);
      expect(deletePermanentJob('${temp.path}/dir'), isTrue);
      expect(File('${temp.path}/a.txt').existsSync(), isFalse);
      expect(Directory('${temp.path}/dir').existsSync(), isFalse);
      expect(deletePermanentJob('${temp.path}/nada'), isTrue);
    });

    test('createDirJob cria aninhado', () {
      expect(createDirJob('${temp.path}/a/b/c'), isTrue);
      expect(Directory('${temp.path}/a/b/c').existsSync(), isTrue);
    });

    test('uniquePathSync gera sufixo para arquivo e pasta', () {
      mkFile('foto.jpg', 'x');
      Directory('${temp.path}/pasta').createSync();

      expect(
        uniquePathSync('${temp.path}/foto.jpg'),
        '${temp.path}/foto (1).jpg',
      );
      expect(uniquePathSync('${temp.path}/pasta'), '${temp.path}/pasta (1)');
      expect(
        uniquePathSync('${temp.path}/livre.txt'),
        '${temp.path}/livre.txt',
      );
    });
  });

  group('extractZipSync (limites)', () {
    Uint8List zipBytes(List<ArchiveFile> entries) {
      final Archive archive = Archive();
      for (final ArchiveFile entry in entries) {
        archive.add(entry);
      }
      return Uint8List.fromList(ZipEncoder().encode(archive));
    }

    test('arquivo inexistente devolve notFound', () {
      final FileOpResult result = extractZipSync(
        archivePath: '${temp.path}/nao.zip',
        destPath: '${temp.path}/dest',
      );
      expect(result.ok, isFalse);
      expect(result.code, FileOpErrorCode.notFound);
    });

    test('limite de entradas', () {
      final File zip = File('${temp.path}/muitas.zip')
        ..writeAsBytesSync(
          zipBytes(<ArchiveFile>[
            ArchiveFile('a.txt', 1, <int>[97]),
            ArchiveFile('b.txt', 1, <int>[98]),
          ]),
        );

      final FileOpResult result = extractZipSync(
        archivePath: zip.path,
        destPath: '${temp.path}/dest',
        limits: const ExtractionLimits(maxEntries: 1),
      );
      expect(result.ok, isFalse);
      expect(result.reason, contains('entradas demais'));
    });

    test('limite de tamanho total', () {
      final File zip = File('${temp.path}/total.zip')
        ..writeAsBytesSync(
          zipBytes(<ArchiveFile>[
            ArchiveFile('a.txt', 10, List<int>.filled(10, 97)),
          ]),
        );

      final FileOpResult result = extractZipSync(
        archivePath: zip.path,
        destPath: '${temp.path}/dest',
        limits: const ExtractionLimits(maxTotalBytes: 5),
      );
      expect(result.ok, isFalse);
      expect(result.reason, contains('limite'));
    });

    test('bytes que não são ZIP devolvem erro de IO', () {
      final File zip = File('${temp.path}/lixo.zip')
        ..writeAsBytesSync(<int>[1, 2, 3, 4, 5, 6, 7, 8]);

      final FileOpResult result = extractZipSync(
        archivePath: zip.path,
        destPath: '${temp.path}/dest',
      );
      expect(result.ok, isFalse);
      expect(result.code, FileOpErrorCode.io);
    });

    test('recusa entrada "." e letra de unidade', () {
      final File dot = File('${temp.path}/dot.zip')
        ..writeAsBytesSync(
          zipBytes(<ArchiveFile>[
            ArchiveFile('./x.txt', 1, <int>[120]),
          ]),
        );
      expect(
        extractZipSync(
          archivePath: dot.path,
          destPath: '${temp.path}/dest1',
        ).ok,
        isFalse,
      );

      final File drive = File('${temp.path}/drive.zip')
        ..writeAsBytesSync(
          zipBytes(<ArchiveFile>[
            ArchiveFile('C:/evil.txt', 1, <int>[120]),
          ]),
        );
      expect(
        extractZipSync(
          archivePath: drive.path,
          destPath: '${temp.path}/dest2',
        ).ok,
        isFalse,
      );
    });

    test('recusa escrita através de link simbólico pré-existente', () {
      if (Platform.isWindows) return;
      final Directory outside = Directory('${temp.path}/fora')..createSync();
      final Directory dest = Directory('${temp.path}/dest-link')..createSync();
      Link('${dest.path}/link').createSync(outside.path);

      final File zip = File('${temp.path}/link.zip')
        ..writeAsBytesSync(
          zipBytes(<ArchiveFile>[
            ArchiveFile('link/evil.txt', 1, <int>[120]),
          ]),
        );

      final FileOpResult result = extractZipSync(
        archivePath: zip.path,
        destPath: dest.path,
      );

      expect(result.ok, isFalse);
      expect(File('${outside.path}/evil.txt').existsSync(), isFalse);
    });

    test('limite de taxa de compressão (zip bomb)', () {
      final File zip = File('${temp.path}/ratio.zip')
        ..writeAsBytesSync(
          zipBytes(<ArchiveFile>[
            ArchiveFile('zeros.bin', 4096, List<int>.filled(4096, 0)),
          ]),
        );

      final FileOpResult result = extractZipSync(
        archivePath: zip.path,
        destPath: '${temp.path}/dest-ratio',
        limits: const ExtractionLimits(maxCompressionRatio: 0.01),
      );
      expect(result.ok, isFalse);
      expect(result.reason, contains('compressão'));
    });

    test('extração válida devolve caminho e conteúdo', () {
      final File zip = File('${temp.path}/ok.zip')
        ..writeAsBytesSync(
          zipBytes(<ArchiveFile>[
            ArchiveFile('dir/ok.txt', 2, <int>[111, 107]),
          ]),
        );

      final FileOpResult result = extractZipSync(
        archivePath: zip.path,
        destPath: '${temp.path}/dest',
      );
      expect(result.ok, isTrue);
      expect(File('${temp.path}/dest/dir/ok.txt').readAsStringSync(), 'ok');
    });
  });

  group('FileOpResult', () {
    test('construtores carregam código, motivo e caminho', () {
      const FileOpResult ok = FileOpResult.ok(path: '/x');
      const FileOpResult partial = FileOpResult.partial(reason: 'quase');
      const FileOpResult failed = FileOpResult.failed(
        reason: 'erro',
        code: FileOpErrorCode.permission,
      );

      expect(ok.ok, isTrue);
      expect(ok.path, '/x');
      expect(partial.ok, isTrue);
      expect(partial.partial, isTrue);
      expect(failed.ok, isFalse);
      expect(failed.code, FileOpErrorCode.permission);
    });
  });
}
