// Item 3.6 — leitor MINIMAL de letra embutida em MP3 (ID3v2.3/2.4,
// frame USLT) em Dart puro — sem nova dependência.
//
// Conservador de propósito: tudo que exigiria mais contexto é IGNORADO
// (devolve null) em vez de interpretado pela metade —
//  * tag com unsynchronisation, extended header ou footer;
//  * versões ≠ 2.3/2.4 (o v2.2 usa ids de 3 letras e layout próprio);
//  * frames com qualquer flag de formato (compressão, criptografia,
//    agrupamento, unsync por frame, data-length-indicator);
//  * descritor sem terminador ou payload truncado.
// O chamador lê só os primeiros bytes do arquivo (limite do serviço) —
// tag maior que o limite simplesmente não é alcançada (null).

import 'dart:convert';
import 'dart:typed_data';

/// Devolve o primeiro USLT não-vazio de [bytes] (limitado ao início do
/// arquivo) ou null quando não há letra legível.
String? readId3v2Usult(Uint8List bytes) {
  if (bytes.length < 10) return null;
  // 'ID3'
  if (bytes[0] != 0x49 || bytes[1] != 0x44 || bytes[2] != 0x33) return null;
  final int major = bytes[3];
  if (major != 3 && major != 4) return null;
  final int tagFlags = bytes[5];
  const int footerFlag = 0x10;
  const int extendedHeaderFlag = 0x40;
  const int unsyncFlag = 0x20;
  if (tagFlags & footerFlag != 0 ||
      tagFlags & extendedHeaderFlag != 0 ||
      tagFlags & unsyncFlag != 0) {
    return null;
  }
  final int tagSize = _synchsafe(bytes, 6);
  // Leitura parcial (limite do serviço): o frame pode estar cortado —
  // o loop abaixo trava no bounds.
  final int tagEnd = 10 + tagSize;
  final int end = tagEnd < bytes.length ? tagEnd : bytes.length;

  int pos = 10;
  while (pos + 10 <= end) {
    final int first = bytes[pos];
    if (first == 0) break; // padding: fim dos frames
    // Id deve ser ASCII imprimível; byte estranho = tag corrompida.
    bool validId = true;
    for (int i = 0; i < 4; i++) {
      final int b = bytes[pos + i];
      if (b < 0x20 || b > 0x7e) {
        validId = false;
        break;
      }
    }
    if (!validId) break;
    final String id = latin1.decode(bytes.sublist(pos, pos + 4));
    final int size = major == 4
        ? _synchsafe(bytes, pos + 4)
        : _be32(bytes, pos + 4);
    final int formatFlags = bytes[pos + 9];
    final int dataStart = pos + 10;
    if (dataStart + size > end) break; // frame truncado pela leitura
    if (formatFlags == 0 && id == 'USLT') {
      final String? lyrics = _parseUsult(bytes, dataStart, dataStart + size);
      if (lyrics != null && lyrics.trim().isNotEmpty) return lyrics;
    }
    pos = dataStart + size;
  }
  return null;
}

/// USLT: encoding(1) + idioma(3) + descritor (terminado) + texto.
String? _parseUsult(Uint8List bytes, int start, int end) {
  if (end - start < 5) return null;
  final int encoding = bytes[start];
  if (encoding > 3) return null;
  final int descStart = start + 4; // pula encoding + idioma (3 bytes)
  int? textStart;
  if (encoding == 1 || encoding == 2) {
    // UTF-16: terminador '\0\0' em paridade par em relação ao início
    // da string (o BOM, quando presente, ocupa o primeiro par).
    for (int i = descStart; i + 1 < end; i += 2) {
      if (bytes[i] == 0 && bytes[i + 1] == 0) {
        textStart = i + 2;
        break;
      }
    }
  } else {
    for (int i = descStart; i < end; i++) {
      if (bytes[i] == 0) {
        textStart = i + 1;
        break;
      }
    }
  }
  // Sem terminador = payload fora do padrão: não arrisca leitura torta.
  if (textStart == null) return null;
  final String decoded = _decodeText(
    encoding,
    bytes.sublist(textStart, end),
  );
  // Terminadores sobrescrevendo texto vazio; remove só o NUL final.
  return decoded.replaceAll('\x00', '').trim();
}

String _decodeText(int encoding, Uint8List text) {
  switch (encoding) {
    case 0:
      return latin1.decode(text);
    case 3:
      return utf8.decode(text, allowMalformed: true);
    case 1: // UTF-16 com BOM (ausência de BOM = assume little-endian)
      if (text.length >= 2 && text[0] == 0xff && text[1] == 0xfe) {
        return _utf16(text.sublist(2), Endian.little);
      }
      if (text.length >= 2 && text[0] == 0xfe && text[1] == 0xff) {
        return _utf16(text.sublist(2), Endian.big);
      }
      return _utf16(text, Endian.little);
    case 2: // UTF-16BE sem BOM
      return _utf16(text, Endian.big);
    default:
      return '';
  }
}

String _utf16(Uint8List bytes, Endian endian) {
  final List<int> units = <int>[];
  for (int i = 0; i + 1 < bytes.length; i += 2) {
    units.add(
      endian == Endian.little
          ? bytes[i] | (bytes[i + 1] << 8)
          : (bytes[i] << 8) | bytes[i + 1],
    );
  }
  // fromCharCodes reconstrói os pares de substituição (emoji, etc.).
  return String.fromCharCodes(units);
}

/// Tamanho do header ID3v2 é "synchsafe": cada byte guarda 7 bits.
int _synchsafe(Uint8List bytes, int at) =>
    ((bytes[at] & 0x7f) << 21) |
    ((bytes[at + 1] & 0x7f) << 14) |
    ((bytes[at + 2] & 0x7f) << 7) |
    (bytes[at + 3] & 0x7f);

int _be32(Uint8List bytes, int at) =>
    (bytes[at] << 24) | (bytes[at + 1] << 16) | (bytes[at + 2] << 8) | bytes[at + 3];
