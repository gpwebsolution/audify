import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:audify/services/archive_service.dart';
import 'package:audify/services/file_name_validator.dart';
import 'package:audify/services/file_op_result.dart';
import 'package:audify/services/file_query_service.dart';
import 'package:flutter_test/flutter_test.dart';

// ignore_for_file: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);

  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => root;
}

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('audify_security_test');
  });

  tearDown(() async {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  File mkFile(String name, String content) {
    final File f = File('${temp.path}/$name');
    f.parent.createSync(recursive: true);
    return f..writeAsStringSync(content);
  }

  Uint8List zipBytes(List<ArchiveFile> entries) {
    final Archive archive = Archive();
    for (final ArchiveFile entry in entries) {
      archive.add(entry);
    }
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  Future<FileOpResult> extractBytes(
    Uint8List bytes, {
    String name = 'malicioso.zip',
    ExtractionLimits limits = const ExtractionLimits(),
  }) {
    final File zip = File('${temp.path}/$name')..writeAsBytesSync(bytes);
    return FileQueryService.extractArchive(
      archivePath: zip.path,
      destPath: '${temp.path}/destino',
      limits: limits,
    );
  }

  group('zip-slip (A1)', () {
    test('recusa entrada com ../../ e não escreve fora do destino', () async {
      final Uint8List bytes = zipBytes(<ArchiveFile>[
        ArchiveFile('../../evil.txt', 4, <int>[101, 118, 105, 108]),
      ]);

      final FileOpResult result = await extractBytes(bytes);

      expect(result.ok, isFalse);
      expect(result.code, FileOpErrorCode.unsafePath);
      expect(File('${temp.path}/evil.txt').existsSync(), isFalse);
      expect(
        File('${temp.path}/destino/evil.txt').existsSync(),
        isFalse,
        reason: 'nem dentro do destino o arquivo deve ser criado',
      );
    });

    test('recusa caminho absoluto', () async {
      final Uint8List bytes = zipBytes(<ArchiveFile>[
        ArchiveFile('/abs/evil.txt', 3, <int>[97, 98, 99]),
      ]);

      final FileOpResult result = await extractBytes(bytes);

      expect(result.ok, isFalse);
      expect(File('/abs/evil.txt').existsSync(), isFalse);
    });

    test('recusa escape para diretório irmão', () async {
      final Uint8List bytes = zipBytes(<ArchiveFile>[
        ArchiveFile('../destino_evil/x.txt', 1, <int>[120]),
      ]);

      final FileOpResult result = await extractBytes(bytes);

      expect(result.ok, isFalse);
      expect(File('${temp.path}/destino_evil/x.txt').existsSync(), isFalse);
    });

    test('recusa entradas duplicadas', () async {
      // O Archive deduplica nomes idênticos; "a.txt" e "a.txt/" são
      // entradas diferentes que normalizam para o mesmo caminho.
      final Uint8List bytes = zipBytes(<ArchiveFile>[
        ArchiveFile('a.txt', 1, <int>[97]),
        ArchiveFile.directory('a.txt/'),
      ]);

      final FileOpResult result = await extractBytes(bytes);

      expect(result.ok, isFalse);
      expect(result.reason, contains('duplicad'));
    });

    test('recusa zip bomba acima do limite declarado', () async {
      final Uint8List bytes = zipBytes(<ArchiveFile>[
        ArchiveFile(
          'grande.bin',
          1024 * 1024,
          List<int>.filled(1024 * 1024, 0),
        ),
      ]);

      final FileOpResult result = await extractBytes(
        bytes,
        limits: const ExtractionLimits(maxEntryBytes: 1024),
      );

      expect(result.ok, isFalse);
      expect(result.code, FileOpErrorCode.unsafePath);
    });

    test('ZIP normal continua extraindo', () async {
      final Uint8List bytes = zipBytes(<ArchiveFile>[
        ArchiveFile('pasta/ok.txt', 2, <int>[111, 107]),
      ]);

      final FileOpResult result = await extractBytes(bytes);

      expect(result.ok, isTrue);
      expect(File('${result.path}/pasta/ok.txt').readAsStringSync(), 'ok');
    });
  });

  group('validateFileName (A4)', () {
    test('aceita nomes normais', () {
      expect(validateFileName('foto.jpg'), isNull);
      expect(validateFileName('relatório final.pdf'), isNull);
      expect(validateFileName('.oculto'), isNull);
    });

    test('recusa caminhos e nomes perigosos', () {
      expect(validateFileName(''), isNotNull);
      expect(validateFileName('   '), isNotNull);
      expect(validateFileName('.'), isNotNull);
      expect(validateFileName('..'), isNotNull);
      expect(validateFileName('../x'), isNotNull);
      expect(validateFileName('a/b'), isNotNull);
      expect(validateFileName(r'a\b'), isNotNull);
      expect(validateFileName('a\u0000b'), isNotNull);
      expect(validateFileName('a\u0001b'), isNotNull);
      expect(validateFileName('a:b'), isNotNull);
      expect(validateFileName('a*b'), isNotNull);
      expect(validateFileName('fim.'), isNotNull);
      expect(validateFileName('fim '), isNotNull);
      expect(validateFileName('CON.txt'), isNotNull);
      expect(validateFileName('COM1.log'), isNotNull);
      expect(validateFileName('a' * 256), isNotNull);
    });

    test('aceita o teto de 255 bytes', () {
      expect(validateFileName('a' * 255), isNull);
    });
  });

  group('lixeira — restauração segura (E1/E2)', () {
    late Directory support;
    late PathProviderPlatform previous;

    setUp(() {
      previous = PathProviderPlatform.instance;
      support = Directory('${temp.path}/support')..createSync(recursive: true);
      PathProviderPlatform.instance = _FakePathProvider(support.path);
      addTearDown(() => PathProviderPlatform.instance = previous);
    });

    test('não sobrescreve o original: restaura como "nome (1)"', () async {
      final File original = mkFile('volta.txt', 'versao-antiga');
      await FileQueryService.delete(path: original.path, useTrash: true);
      final TrashEntry entry = (await FileQueryService.listTrash()).single;

      // O usuário criou outro arquivo com o mesmo nome no meio do caminho.
      original.writeAsStringSync('versao-nova');

      final FileOpResult result = await FileQueryService.restoreFromTrash(
        entry,
      );

      expect(result.ok, isTrue);
      expect(result.path, isNot(entry.originalPath));
      expect(result.path, contains('volta (1).txt'));
      expect(original.readAsStringSync(), 'versao-nova');
      expect(File(result.path!).readAsStringSync(), 'versao-antiga');
      expect(await FileQueryService.listTrash(), isEmpty);
    });

    test(
      'manifesto com aspas no caminho é removido por JSON, não texto',
      () async {
        final File original = mkFile('a"b.txt', 'com-aspas');
        await FileQueryService.delete(path: original.path, useTrash: true);
        final TrashEntry entry = (await FileQueryService.listTrash()).single;

        final FileOpResult result = await FileQueryService.restoreFromTrash(
          entry,
        );

        expect(result.ok, isTrue);
        expect(await FileQueryService.listTrash(), isEmpty);
        expect(File(entry.originalPath).readAsStringSync(), 'com-aspas');
      },
    );

    test('linha corrompida no manifesto não esconde as demais', () async {
      final File a = mkFile('bom.txt', 'bom');
      await FileQueryService.delete(path: a.path, useTrash: true);

      final File manifest = File('${support.path}/trash/manifest.jsonl');
      manifest.writeAsStringSync(
        '${manifest.readAsStringSync()}{lixo sem json}\n',
      );

      final List<TrashEntry> entries = await FileQueryService.listTrash();
      expect(entries, hasLength(1));
      expect(entries.single.originalPath, a.path);
    });
  });

  group('manifesto atômico (E3)', () {
    test('não deixa .tmp para trás e mantém JSON válido', () async {
      final Directory support = Directory('${temp.path}/support')
        ..createSync(recursive: true);
      final PathProviderPlatform previous = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _FakePathProvider(support.path);
      addTearDown(() => PathProviderPlatform.instance = previous);

      final File original = mkFile('um.txt', '1');
      await FileQueryService.delete(path: original.path, useTrash: true);

      final File manifest = File('${support.path}/trash/manifest.jsonl');
      expect(File('${manifest.path}.tmp').existsSync(), isFalse);
      for (final String line in manifest.readAsLinesSync()) {
        if (line.trim().isEmpty) continue;
        expect(jsonDecode(line), isA<Map<String, dynamic>>());
      }
    });
  });
}
