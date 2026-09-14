import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Utilitários de privacidade para imagens: remover EXIF/GPS gerando uma
/// cópia limpa. O re-encode (decode + encode) descarta todos os blocos
/// APP1/EXIF — é a forma mais robusta e offline-friendly de "limpar" uma
/// foto antes de compartilhar.
class ImageMetadataService {
  ImageMetadataService._();

  /// Gera `<nome>_sem_exif.jpg` (ou .png) na MESMA pasta da original.
  /// Retorna o caminho do arquivo criado ou null em falha.
  static Future<String?> saveCopyWithoutMetadata(String path) =>
      compute(stripImageMetadataJob, path);
}

/// Top-level (requisito do compute()): decodifica + re-encoda sem metadados.
String? stripImageMetadataJob(String path) {
  try {
    final File file = File(path);
    final img.Image? decoded = img.decodeImage(file.readAsBytesSync());
    if (decoded == null) return null;

    final bool isPng = path.toLowerCase().endsWith('.png');
    final List<int> encoded =
        isPng ? img.encodePng(decoded) : img.encodeJpg(decoded, quality: 92);

    final String out = '${path.substring(0, path.lastIndexOf('.'))}_sem_exif'
        '${isPng ? '.png' : '.jpg'}';
    File(out).writeAsBytesSync(encoded, flush: true);
    return out;
  } catch (_) {
    return null;
  }
}
