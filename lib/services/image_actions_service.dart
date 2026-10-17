import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';

/// Ações de imagem que o SO precisa fazer por nós.
///
/// Todas passam por `content://` (FileProvider): desde o Android 7 nenhum app
/// pode entregar `file://` para fora — lançaria `FileUriExposedException`.
/// É o que torna possível "definir como papel de parede" e "editar" sem
/// gambiarra.
class ImageActionsService {
  const ImageActionsService._();

  static const MethodChannel _channel = MethodChannel('audify/file_query');

  /// Abre o seletor de papel de parede do sistema com a imagem.
  ///
  /// O SO mostra pré-visualização e deixa o usuário cortar e posicionar —
  /// melhor que esticar a imagem até o SO.
  static Future<bool> setAsWallpaper(String path) async {
    return _invoke('setAsWallpaper', path);
  }

  /// Abre um editor externo (ACTION_EDIT).
  static Future<bool> editImage(String path) async {
    return _invoke('editImage', path);
  }

  /// `content://` do arquivo, ou null se não existir/estiver fora das raízes.
  static Future<String?> getContentUri(String path) async {
    if (path.isEmpty) return null;
    try {
      return await _channel.invokeMethod<String>('getContentUri', {
        'path': path,
      });
    } catch (e) {
      debugPrint('[ImageActions] getContentUri($path): $e');
      return null;
    }
  }

  static Future<bool> _invoke(String method, String path) async {
    if (path.isEmpty) return false;
    try {
      await _channel.invokeMethod<void>(method, {'path': path});
      return true;
    } catch (e) {
      // O nativo já mostra Toast quando é "nenhum app instalado"; aqui não
      // duplicamos a mensagem para não aparecer duas vezes.
      debugPrint('[ImageActions] $method($path): $e');
      return false;
    }
  }
}

/// Resultado de aplicar uma marca d'água.
class WatermarkResult {
  /// Caminho da cópia gerada.
  final String path;

  /// Tamanho em bytes da cópia.
  final int sizeBytes;

  const WatermarkResult({required this.path, required this.sizeBytes});
}

/// Aplica um texto sobre uma imagem, sem tocar no original.
///
/// O arquivo original NUNCA é sobrescrito: a marca d'água vai para uma cópia
/// JPEG no diretório externo do próprio app. Duas razões:
///  - sobrescrever destruiria a foto sem volta, numa tela que o usuário abriu
///    só para ver uma prévia;
///  - o diretório do app não exige `MANAGE_EXTERNAL_STORAGE`, então funciona
///    em qualquer aparelho sem pedir a permissão especial "Todos os arquivos".
///
/// Roda fora da thread de UI: decodificar e re-encodar uma foto de 12 MP leva
/// centenas de milissegundos.
class WatermarkService {
  const WatermarkService._();

  /// Aplica [text] em [sourcePath] e devolve o caminho da cópia.
  static Future<WatermarkResult> applyText({
    required String sourcePath,
    required String text,

    /// Fração da LARGURA da imagem que o texto principal ocupa (0.8 = 80%,
    /// o design "80% / 30%" do commit original — a assinatura usa
    /// `fontScale * 0.36` ≈ 29%). Antes valia 0.035, o que deixava o texto
    /// com 3,5% da largura: ilegível em foto de celular.
    double fontScale = 0.8,

    /// Margem inferior como fração da altura (0.05 = 5%).
    double marginScale = 0.05,
  }) async {
    if (sourcePath.isEmpty) {
      throw ArgumentError('sourcePath vazio');
    }
    final String trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('texto vazio');
    }

    // A fonte bitmap do pacote `image` só tem glifos ASCII: "©", "é", "ç"...
    // seriam pulados em silêncio no desenho ("Meu estdio" com buraco).
    // Dobra para ASCII ANTES de mandar para o isolate.
    final String safe = asciiFold(trimmed);

    // O diretório é resolvido AQUI, na isolate principal, e viaja no job.
    // `compute` roda em isolate nova, onde estado estático (o override dos
    // testes) não existe — e o path_provider precisa de canal nativo, que
    // também não deve ser chamado de dentro do isolate de trabalho.
    final Directory outDir = await _outputDir();

    return compute(_applyTextJob, <String, Object?>{
      'source': sourcePath,
      'text': safe,
      'fontScale': fontScale,
      'marginScale': marginScale,
      'outputDir': outDir.path,
    });
  }

  /// Glifos ausentes na fonte bitmap viram ASCII legível (PT/EN/símbolos).
  ///
  /// A fonte `arial48` do pacote `image` só desenha 32–126; qualquer code
  /// point fora é ignorado pelo `drawString` SEM erro — o texto sairia com
  /// buracos ("© Meu estúdio" → " Meu estdio"). Combining marks (acentos
  /// em decomposição) caem fora também e são descartados; o que não tiver
  /// mapa vira `?` (visível, em vez de sumir).
  @visibleForTesting
  static String asciiFold(String text) {
    const Map<int, String> fold = <int, String>{
      0x00A9: '(c)', // ©
      0x00AE: '(r)', // ®
      0x2122: 'tm', // ™
      0x20AC: 'EUR', // €
      0x00B0: 'o', // °
      0x00C0: 'A', 0x00C1: 'A', 0x00C2: 'A', 0x00C3: 'A', 0x00C4: 'A',
      0x00C5: 'A', 0x00C7: 'C',
      0x00C8: 'E', 0x00C9: 'E', 0x00CA: 'E', 0x00CB: 'E',
      0x00CC: 'I', 0x00CD: 'I', 0x00CE: 'I', 0x00CF: 'I',
      0x00D1: 'N',
      0x00D2: 'O', 0x00D3: 'O', 0x00D4: 'O', 0x00D5: 'O', 0x00D6: 'O',
      0x00D8: 'O',
      0x00D9: 'U', 0x00DA: 'U', 0x00DB: 'U', 0x00DC: 'U',
      0x00DD: 'Y', 0x00DF: 'ss',
      0x00E0: 'a', 0x00E1: 'a', 0x00E2: 'a', 0x00E3: 'a', 0x00E4: 'a',
      0x00E5: 'a', 0x00E7: 'c',
      0x00E8: 'e', 0x00E9: 'e', 0x00EA: 'e', 0x00EB: 'e',
      0x00EC: 'i', 0x00ED: 'i', 0x00EE: 'i', 0x00EF: 'i',
      0x00F1: 'n',
      0x00F2: 'o', 0x00F3: 'o', 0x00F4: 'o', 0x00F5: 'o', 0x00F6: 'o',
      0x00F8: 'o',
      0x00F9: 'u', 0x00FA: 'u', 0x00FB: 'u', 0x00FC: 'u',
      0x00FD: 'y', 0x00FF: 'y',
      0x0152: 'OE', 0x0153: 'oe', // Œ œ
      0x2018: "'", 0x2019: "'", // ‘ ’
      0x201C: '"', 0x201D: '"', // “ ”
      0x2013: '-', 0x2014: '-', // – —
      0x2026: '...', // …
      0x2022: '*', // •
    };
    final StringBuffer out = StringBuffer();
    for (final int rune in text.runes) {
      if (rune < 0x80) {
        out.writeCharCode(rune);
        continue;
      }
      final String? mapped = fold[rune];
      if (mapped != null) {
        out.write(mapped);
        continue;
      }
      // Marca combinante (acentos em decomposição NFD): só remove.
      if (rune >= 0x0300 && rune <= 0x036F) continue;
      out.write('?');
    }
    return out.toString();
  }

  /// Job do isolate: precisa ser top-level para o `compute`.
  static Future<WatermarkResult> _applyTextJob(
    Map<String, Object?> args,
  ) async {
    final String source = args['source']! as String;
    final String text = args['text']! as String;
    final double fontScale = args['fontScale']! as double;
    final double marginScale = args['marginScale']! as double;
    final String outputDir = args['outputDir']! as String;

    final File sourceFile = File(source);
    if (!sourceFile.existsSync()) {
      throw StateError('Arquivo de origem não encontrado: $source');
    }

    final Uint8List originalBytes = await sourceFile.readAsBytes();
    if (originalBytes.isEmpty) throw StateError('Arquivo vazio.');

    final img.Image? decodedRaw = img.decodeImage(originalBytes);
    if (decodedRaw == null) {
      throw StateError('Formato de imagem não reconhecido.');
    }
    // EXIF: foto de celular é gravada "de lado" com Orientation; o encoder
    // de saída não herda EXIF, então sem assar a orientação a cópia sairia
    // girada em relação ao original. `bakeOrientation` gira o buffer de
    // verdade e limpa a tag.
    final img.Image decoded = img.bakeOrientation(decodedRaw);

    final DateTime now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final String footer =
        'audify • ${two(now.day)}/${two(now.month)}/${now.year}';

    // Texto principal primeiro (maior), crédito da app por baixo (menor).
    _stampText(
      decoded,
      text,
      // O texto ocupa 80% da largura e a assinatura 30%: proporções que
      // continuam legíveis de miniatura a print.
      widthFraction: fontScale,
      baselineFromBottom: (decoded.height * marginScale * 2.1).round().clamp(
        0,
        decoded.height ~/ 2,
      ),
    );
    _stampText(
      decoded,
      footer,
      widthFraction: (fontScale * 0.36).clamp(0.08, 0.9),
      baselineFromBottom: (decoded.height * marginScale).round(),
    );

    final Uint8List encoded = Uint8List.fromList(
      img.encodeJpg(decoded, quality: 92),
    );

    final Directory outDir = Directory(outputDir);
    final String raw = sourceFile.uri.pathSegments.isEmpty
        ? 'imagem'
        : sourceFile.uri.pathSegments.last.replaceAll(RegExp(r'\.[^.]+$'), '');
    final File out = File(
      '${outDir.path}${Platform.pathSeparator}$raw-marcada.jpg',
    );
    await out.writeAsBytes(encoded, flush: true);

    return WatermarkResult(path: out.path, sizeBytes: encoded.length);
  }

  /// Escreve [text] em [canvas], centralizado e com tamanho PROPORCIONAL.
  ///
  /// O `image` só traz fontes bitmap de tamanho FIXO (arial14/24/48), então a
  /// escala real sai desenhando no tamanho da fonte e esticando com
  /// [img.copyResize]. Sem isso o texto ficaria sempre com 48px — minúsculo
  /// num print de 4000px e ilegível numa miniatura de 200px.
  ///
  /// [widthFraction] é a fração da LARGURA da imagem que o texto ocupa, o que
  /// torna o resultado previsível em qualquer resolução.
  static void _stampText(
    img.Image canvas,
    String text, {
    required double widthFraction,
    required int baselineFromBottom,
  }) {
    if (text.isEmpty) return;

    final img.BitmapFont font = img.arial48;
    final int rawWidth = _measureWidth(font, text);
    final int rawHeight = _measureHeight(font, text);
    if (rawWidth <= 0 || rawHeight <= 0) return;

    final int targetWidth = (canvas.width * widthFraction).round().clamp(
      24,
      canvas.width,
    );
    final double factor = targetWidth / rawWidth;
    final int targetHeight = (rawHeight * factor).round().clamp(
      8,
      canvas.height,
    );
    // Folga proporcional para a sombra não ser cortada na borda.
    final int pad = (targetHeight * 0.08).round().clamp(2, 40);

    // Camada 1: no tamanho natural da fonte (para o resize suavizar).
    final img.Image raw = img.Image(
      width: rawWidth + 8,
      height: rawHeight + 8,
      numChannels: 4,
    );
    raw.clear(img.ColorRgba8(0, 0, 0, 0));
    // Sombra primeiro: em foto clara, branco puro sumiria.
    img.drawString(
      raw,
      text,
      font: font,
      x: 4,
      y: 4,
      color: img.ColorRgba8(0, 0, 0, 150),
    );
    img.drawString(
      raw,
      text,
      font: font,
      x: 2,
      y: 2,
      color: img.ColorRgba8(255, 255, 255, 235),
    );

    final img.Image scaled = img.copyResize(
      raw,
      width: targetWidth + pad * 2,
      height: targetHeight + pad * 2,
      interpolation: img.Interpolation.linear,
    );

    final int x = ((canvas.width - scaled.width) ~/ 2).clamp(
      0,
      canvas.width > scaled.width ? canvas.width - scaled.width : 0,
    );
    final int y = (canvas.height - baselineFromBottom - scaled.height).clamp(
      0,
      canvas.height > scaled.height ? canvas.height - scaled.height : 0,
    );
    img.compositeImage(canvas, scaled, dstX: x, dstY: y);
  }

  /// Largura em pixels que [text] ocupa com [font].
  static int _measureWidth(img.BitmapFont font, String text) {
    int width = 0;
    for (final int code in text.codeUnits) {
      final img.BitmapFontCharacter? ch = font.characters[code];
      width += ch?.xAdvance ?? (font.base ~/ 2);
    }
    return width;
  }

  /// Altura em pixels que [text] ocupa com [font].
  static int _measureHeight(img.BitmapFont font, String text) {
    int height = 0;
    for (final int code in text.codeUnits) {
      final img.BitmapFontCharacter? ch = font.characters[code];
      if (ch == null) continue;
      final int h = ch.height + ch.yOffset;
      if (h > height) height = h;
    }
    return height;
  }

  /// Diretório de saída: armazenamento EXTERNO do próprio app.
  ///
  /// Fica visível pelo gerenciador de arquivos e, por ser do app, não exige
  /// `MANAGE_EXTERNAL_STORAGE`. O original nunca é sobrescrito.
  static Future<Directory> _outputDir() async {
    final Directory base = await _externalBase();
    final Directory dir = Directory(
      '${base.path}${Platform.pathSeparator}Audify',
    );
    if (!dir.existsSync()) await dir.create(recursive: true);
    return dir;
  }

  static Future<Directory> _externalBase() async {
    final Directory? injected = _externalDirOverride;
    if (injected != null) return injected;
    final Directory? real = await getExternalStorageDirectory();
    return real ?? Directory.systemTemp;
  }

  /// Sobrescreve o diretório de saída (usado nos testes).
  static Directory? _externalDirOverride;

  /// Diretório de saída a forçar — usado nos testes.
  @visibleForTesting
  // ignore: unnecessary_underscores
  static void setOutputDirForTesting(Directory dir) =>
      _externalDirOverride = dir;
}
