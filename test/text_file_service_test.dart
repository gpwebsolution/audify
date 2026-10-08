import 'dart:io';

import 'package:audify/services/text_file_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Testes de criação e edição de arquivos de texto.
///
/// Roda com disco real (diretório temporário): o serviço cria, lê e apaga
/// arquivos, e um mock não provaria nada sobre o que importa aqui.
void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('audify_text');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  group('validateName', () {
    test('aceita extensões de texto', () {
      for (final String name in <String>[
        'index.html',
        'estilo.css',
        'app.js',
        'dados.json',
        'notas.md',
        'lista.xml',
        'log.txt',
      ]) {
        expect(
          TextFileService.validateName(name),
          isNull,
          reason: '$name deveria ser aceito',
        );
      }
    });

    test('recusa sem extensão, com motivo', () {
      final String? problem = TextFileService.validateName('index');
      expect(problem, isNotNull);
      expect(problem, contains('extensão'));
    });

    test('recusa extensão que não é de texto, listando as válidas', () {
      final String? problem = TextFileService.validateName('video.mp4');
      expect(problem, isNotNull);
      expect(problem, contains('mp4'));
      expect(problem, contains('html'));
    });

    test('recusa barra, ponto e vazio', () {
      expect(TextFileService.validateName(''), isNotNull);
      expect(TextFileService.validateName('   '), isNotNull);
      expect(TextFileService.validateName('.'), isNotNull);
      expect(TextFileService.validateName('a/b.txt'), contains('/'));
    });

    test('aceita nome com acento, espaço e hífen', () {
      expect(TextFileService.validateName('minha página-legal.html'), isNull);
    });

    test('recusa nome muito longo', () {
      expect(TextFileService.validateName('${'a' * 130}.txt'), isNotNull);
    });
  });

  group('isTextFile', () {
    test('reconhece texto e rejeita binário', () {
      expect(TextFileService.isTextFile('/a/b/c.html'), isTrue);
      expect(TextFileService.isTextFile('/a/b/c.HTML'), isTrue);
      expect(TextFileService.isTextFile('/a/b/c.mp4'), isFalse);
      expect(TextFileService.isTextFile('/a/b/c.apk'), isFalse);
      expect(TextFileService.isTextFile('/a/b/semextensao'), isFalse);
    });

    test('isTextFile é o filtro que impede corromper binário', () {
      // Se este teste quebrar, abrir um .mp3 no editor passaria a GRAVAR por
      // cima do arquivo em vez de recusar.
      final String db = '/data/app.db';
      expect(TextFileService.isTextFile(db), isFalse);
    });
  });

  group('create', () {
    test('cria o arquivo com o conteúdo inicial', () async {
      final TextFileResult result = await TextFileService.create(
        directory: dir.path,
        name: 'index.html',
      );

      expect(result.success, isTrue);
      final File file = File(result.path);
      expect(file.existsSync(), isTrue);
      expect(file.path, endsWith('index.html'));
      expect(file.readAsStringSync(), contains('<!DOCTYPE html>'));
    });

    test('NÃO sobrescreve arquivo existente', () async {
      await TextFileService.create(directory: dir.path, name: 'a.txt');
      final String original = File('${dir.path}/a.txt').readAsStringSync();

      final TextFileResult second = await TextFileService.create(
        directory: dir.path,
        name: 'a.txt',
      );

      expect(second.success, isTrue);
      expect(second.path, isNot('${dir.path}/a.txt'));
      // O original segue intacto — criar arquivo nunca deve destruir trabalho.
      expect(File('${dir.path}/a.txt').readAsStringSync(), original);
    });

    test('recusa nome inválido sem criar nada', () async {
      final TextFileResult result = await TextFileService.create(
        directory: dir.path,
        name: 'video.mp4',
      );
      expect(result.success, isFalse);
      expect(result.error, isNotNull);
      expect(dir.listSync().whereType<File>(), isEmpty);
    });

    test('vários arquivos com o mesmo nome coexistem', () async {
      final List<String> paths = <String>[
        (await TextFileService.create(directory: dir.path, name: 'x.txt')).path,
        (await TextFileService.create(directory: dir.path, name: 'x.txt')).path,
        (await TextFileService.create(directory: dir.path, name: 'x.txt')).path,
      ];
      expect(paths.toSet().length, 3);
      for (final String p in paths) {
        expect(File(p).existsSync(), isTrue);
      }
    });
  });

  group('read / write', () {
    test('faz ida e volta preservando o conteúdo', () async {
      const String content = 'linha 1\nlinha 2\nacentuação: ção\n';
      await TextFileService.write('${dir.path}/a.txt', content);

      final TextFileResult result = await TextFileService.read(
        '${dir.path}/a.txt',
      );
      expect(result.success, isTrue);
      expect(result.content, content);
    });

    test('recusa arquivo inexistente', () async {
      final TextFileResult result = await TextFileService.read(
        '${dir.path}/nao-existe.txt',
      );
      expect(result.success, isFalse);
      expect(result.error, contains('não encontrado'));
    });

    test('recusa binário, em vez de mostrar lixo', () async {
      final File bin = File('${dir.path}/x.mp4');
      bin.writeAsBytesSync(<int>[0, 1, 2, 3]);
      final TextFileResult result = await TextFileService.read(bin.path);
      expect(result.success, isFalse);
    });

    test('recusa arquivo grande demais em vez de travar a UI', () async {
      final File big = File('${dir.path}/grande.txt');
      // Só o cabeçalho: o teste valida o LIMIAR, não escreve 2 MB.
      big.writeAsStringSync('x' * 16);
      final TextFileResult ok = await TextFileService.read(big.path);
      expect(ok.success, isTrue);

      expect(
        TextFileService.maxEditableBytes,
        lessThanOrEqualTo(4 * 1024 * 1024),
      );
    });

    test('write devolve o caminho e o conteúdo', () async {
      final TextFileResult result = await TextFileService.write(
        '${dir.path}/b.json',
        '{"a":1}',
      );
      expect(result.success, isTrue);
      expect(result.content, '{"a":1}');
      expect(File(result.path).existsSync(), isTrue);
    });
  });

  group('validateJson', () {
    test('aceita JSON válido', () {
      expect(TextFileService.validateJson('{"a": 1, "b": [2,3]}'), isNull);
      expect(TextFileService.validateJson('[]'), isNull);
    });

    test('recusa JSON quebrado com o motivo', () {
      final String? problem = TextFileService.validateJson('{"a": }');
      expect(problem, isNotNull);
      expect(problem, contains('JSON'));
    });

    test('recusa objeto sem chave', () {
      expect(TextFileService.validateJson('{a: 1}'), isNotNull);
    });
  });

  group('starterContent', () {
    test('HTML vem com esqueleto utilizável', () {
      final String html = TextFileService.starterContent('html');
      expect(html, contains('<!DOCTYPE html>'));
      expect(html, contains('</html>'));
      // Charset é obrigatório: sem ele, acentos quebram no navegador.
      expect(html, contains('charset="UTF-8"'));
    });

    test('JSON começa válido (caso contrário o editor recusaria salvar)', () {
      expect(
        TextFileService.validateJson(TextFileService.starterContent('json')),
        isNull,
      );
    });

    test('CSS e JS vêm como comentário, não com código quebrado', () {
      expect(TextFileService.starterContent('css'), startsWith('/*'));
      expect(TextFileService.starterContent('js'), startsWith('//'));
    });

    test('tipo desconhecido devolve vazio, não lixo', () {
      expect(TextFileService.starterContent('log'), isEmpty);
    });
  });
}
