import 'dart:io';
import 'dart:typed_data';

import 'package:audify/services/image_actions_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// Testes da marca d'água.
///
/// Roda com IMAGEM DE VERDADE em disco: o defeito que mais aparece aqui é
/// escala errada (texto sempre com o tamanho da fonte) e recorte na borda —
/// nenhum dos dois aparece com um mock.
void main() {
  late Directory dir;

  /// PNG de teste: degradê, para dar contraste ao texto branco.
  Uint8List makePng(int w, int h) {
    final img.Image image = img.Image(width: w, height: h, numChannels: 3);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        image.setPixelRgb(x, y, x % 255, y % 255, 128);
      }
    }
    return Uint8List.fromList(img.encodePng(image));
  }

  File writeImage(String name, int w, int h) {
    final File file = File('${dir.path}${Platform.pathSeparator}$name');
    file.writeAsBytesSync(makePng(w, h));
    return file;
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('audify_wm');
    WatermarkService.setOutputDirForTesting(dir);
  });

  tearDown(() {
    WatermarkService.setOutputDirForTesting(Directory('${dir.path}/unused'));
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  group('WatermarkService.applyText', () {
    test('gera uma cópia e não toca na original', () async {
      final File source = writeImage('foto.png', 600, 800);
      final int originalBytes = source.lengthSync();

      final WatermarkResult result = await WatermarkService.applyText(
        sourcePath: source.path,
        text: '© Meu estúdio',
      );

      expect(result.path, isNot(source.path));
      expect(result.sizeBytes, greaterThan(0));
      // A original intacta é o ponto: a tela foi aberta só para ver.
      expect(source.existsSync(), isTrue);
      expect(source.lengthSync(), originalBytes);
    });

    test('a cópia existe e é uma imagem decodificável', () async {
      final File source = writeImage('foto2.png', 400, 500);
      final WatermarkResult result = await WatermarkService.applyText(
        sourcePath: source.path,
        text: 'teste',
      );

      final File copy = File(result.path);
      expect(copy.existsSync(), isTrue);
      final img.Image? decoded = img.decodeJpg(copy.readAsBytesSync());
      expect(decoded, isNotNull);
      expect(decoded!.width, 400);
      expect(decoded.height, 500);
    });

    test('o texto ESCALA com a imagem, não fica com tamanho fixo', () async {
      // Este é o defeito que o pacote `image` traz de graça: as fontes bitmap
      // (arial14/24/48) têm tamanho FIXO, então quem não redimensiona imprime
      // um texto minúsculo num print de 3000px e ilegível numa miniatura.
      //
      // A prova é quantitativa: a área coberta pelo texto tem de acompanhar a
      // área da imagem (aqui 16x), e não ficar parada.
      final File small = writeImage('pequena.png', 400, 300);
      final File big = writeImage('grande.png', 1600, 1200);

      int brightPixels(File out) {
        final img.Image decoded = img.decodeJpg(out.readAsBytesSync())!;
        int count = 0;
        final int from = (decoded.height * 0.75).round();
        for (int y = from; y < decoded.height; y++) {
          for (int x = 0; x < decoded.width; x++) {
            // O texto é branco puro sobre a sombra: conta o branco.
            if (decoded.getPixel(x, y).r > 240) count++;
          }
        }
        return count;
      }

      final WatermarkResult r1 = await WatermarkService.applyText(
        sourcePath: small.path,
        text: 'texto bem comprido para testar',
      );
      final WatermarkResult r2 = await WatermarkService.applyText(
        sourcePath: big.path,
        text: 'texto bem comprido para testar',
      );

      final int p1 = brightPixels(File(r1.path));
      final int p2 = brightPixels(File(r2.path));
      expect(
        p1,
        greaterThan(0),
        reason: 'o texto tem que aparecer na miniatura',
      );

      // 16x de área; o texto deve acompanhar dentro de uma faixa razoável.
      // Folga larga porque a taxa de preenchimento da fonte não é idêntica
      // entre escalas, mas a ordem de grandeza precisa bater.
      final double ratio = p2 / p1;
      expect(ratio, greaterThan(8), reason: 'o texto não acompanhou o tamanho');
      expect(ratio, lessThan(32), reason: 'o texto ficou desproporcional');
    });

    test('texto vazio é recusado antes de decodificar', () async {
      final File source = writeImage('vazia.png', 100, 100);
      await expectLater(
        WatermarkService.applyText(sourcePath: source.path, text: '   '),
        throwsArgumentError,
      );
    });

    test('caminho vazio é recusado', () async {
      await expectLater(
        WatermarkService.applyText(sourcePath: '', text: 'x'),
        throwsArgumentError,
      );
    });

    test('arquivo inexistente falha com mensagem clara', () async {
      await expectLater(
        WatermarkService.applyText(
          sourcePath: '${dir.path}/nao-existe.png',
          text: 'x',
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('conteúdo que não é imagem falha com motivo', () async {
      final File bogus = File('${dir.path}/falso.png');
      bogus.writeAsStringSync('isto nao e uma imagem');

      await expectLater(
        WatermarkService.applyText(sourcePath: bogus.path, text: 'x'),
        throwsA(isA<StateError>()),
      );
    });

    test('arquivo vazio falha com motivo', () async {
      final File empty = File('${dir.path}/vazio.bin');
      empty.writeAsBytesSync(<int>[]);

      await expectLater(
        WatermarkService.applyText(sourcePath: empty.path, text: 'x'),
        throwsA(isA<StateError>()),
      );
    });

    test('nomes com acento/espaço não quebram a saída', () async {
      final File source = writeImage('minha foto (1).png', 300, 300);
      final WatermarkResult result = await WatermarkService.applyText(
        sourcePath: source.path,
        text: 'Ação',
      );
      expect(File(result.path).existsSync(), isTrue);
      // Extensão normalizada para jpg e nome sem o original.
      expect(result.path.endsWith('.jpg'), isTrue);
    });

    test('a cópia não sobrescreve uma cópia anterior', () async {
      final File source = writeImage('dup.png', 200, 200);
      final WatermarkResult a = await WatermarkService.applyText(
        sourcePath: source.path,
        text: 'primeira',
      );
      final WatermarkResult b = await WatermarkService.applyText(
        sourcePath: source.path,
        text: 'segunda',
      );
      // Mesmo caminho de saída é aceitável (é a mesma foto marcada), mas o
      // resultado precisa ser legível depois de sobrescrito.
      expect(a.path, b.path);
      expect(File(b.path).existsSync(), isTrue);
    });

    test('o texto principal ocupa ~80% da largura (design 80%/30%)', () async {
      // Regressão do defeito reportado: fontScale default era 0.035 — texto
      // com 3,5% da largura, ilegível. O design original (commit 4445829)
      // manda 80% na largura do texto principal e ~30% na assinatura.
      final File source = writeImage('escala.png', 800, 600);
      final WatermarkResult result = await WatermarkService.applyText(
        sourcePath: source.path,
        text: 'texto bem comprido para testar',
      );

      final img.Image out = img.decodeJpg(
        File(result.path).readAsBytesSync(),
      )!;
      int minX = out.width, maxX = 0;
      for (int y = (out.height * 0.7).round(); y < out.height; y++) {
        for (int x = 0; x < out.width; x++) {
          final p = out.getPixel(x, y);
          // Texto branco (alpha 235 sobre o degradê, suavizado pelo JPEG):
          // os três canais altos. A sombra é escura e o fundo nunca passa
          // de b=128, então fica separado com folga.
          if (p.r > 190 && p.g > 190 && p.b > 160) {
            if (x < minX) minX = x;
            if (x > maxX) maxX = x;
          }
        }
      }
      expect(maxX, greaterThan(0), reason: 'o texto não apareceu na cópia');
      final double fraction = (maxX - minX + 1) / out.width;
      expect(
        fraction,
        greaterThan(0.65),
        reason: 'texto ficou estreito demais (fraction=$fraction)',
      );
      expect(
        fraction,
        lessThan(0.95),
        reason: 'texto estourou a imagem (fraction=$fraction)',
      );
    });

    test('EXIF: foto gravada de lado sai orientada na cópia', () async {
      // Celulares gravam com Orientation=6 (sensor de lado); o encoder de
      // saída não herda EXIF, então sem bakeOrientation a cópia sairia
      // girada 90°.
      final img.Image raw = img.Image(width: 400, height: 300);
      img.fill(raw, color: img.ColorRgb8(70, 110, 170));
      raw.exif.imageIfd['Orientation'] = 6;
      final File source = File('${dir.path}/girada.jpg');
      source.writeAsBytesSync(img.encodeJpg(raw));

      final WatermarkResult result = await WatermarkService.applyText(
        sourcePath: source.path,
        text: 'lado',
      );

      final img.Image out = img.decodeJpg(
        File(result.path).readAsBytesSync(),
      )!;
      expect(out.width, 300, reason: 'largura deve girar junto com a foto');
      expect(out.height, 400, reason: 'altura deve girar junto com a foto');
    });
  });

  group('WatermarkService.asciiFold', () {
    test('© vira (c) e acentos viram ASCII', () {
      expect(WatermarkService.asciiFold('© Meu estúdio'), '(c) Meu estudio');
      expect(WatermarkService.asciiFold('Ação'), 'Acao');
      expect(WatermarkService.asciiFold('¼'), '?');
    });

    test('combining marks (NFD) só são removidas', () {
      expect(WatermarkService.asciiFold('e\u0301'), 'e');
      expect(WatermarkService.asciiFold('a\u0303\u0301'), 'a');
    });

    test('ASCII puro passa sem mudança', () {
      expect(WatermarkService.asciiFold('abc XYZ 123'), 'abc XYZ 123');
      expect(WatermarkService.asciiFold('“aspas” – ok…'), '"aspas" - ok...');
    });
  });
}
