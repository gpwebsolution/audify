import 'dart:convert' show utf8;
import 'dart:io' show Platform;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/pdf_file_model.dart';
import 'gallery_query_service.dart' show ThumbnailDiskCache;

/// Chave ESTÁVEL de cache em disco para um caminho.
///
/// NÃO usar String.hashCode: ele é randomizado por execução do processo
/// no Dart — a chave mudaria a cada abertura do app, o cache nunca
/// acertaria e arquivos órfãos se acumulariam no disco para sempre.
/// SHA-1 truncado é estável entre sessões.
String diskKeyForPdfPath(String path) =>
    sha1.convert(utf8.encode(path)).toString().substring(0, 20);

/// Consulta aos PDFs do aparelho via canal nativo (MainActivity.kt).
///
/// Espelha o padrão do [VideoQueryService]: consulta no lado Android,
/// ponte Dart pura. Sem cache — a lista é pequena e simples.
class PdfQueryService {
  static const MethodChannel _channel = MethodChannel('audify/pdf_query');

  /// True se o canal nativo existe (Android). Em outras plataformas o app
  /// degrada para lista vazia (o seletor SAF continua disponível).
  static bool get isSupported => Platform.isAndroid;

  /// Lista os PDFs do aparelho (mais recentes primeiro).
  static Future<List<PdfFile>> loadPdfs() async {
    if (!isSupported) return const [];

    try {
      final List<dynamic>? raw =
          await _channel.invokeMethod<List<dynamic>>('getPdfs');
      if (raw == null) return const [];
      return raw
          .map((e) => PdfFile.fromChannel(e as Map<dynamic, dynamic>))
          .toList();
    } catch (e) {
      // Falha de plataforma nunca crasha o app: degrada para lista vazia.
      debugPrint('[PdfQuery] loadPdfs falhou: $e');
      return const [];
    }
  }

  /// Cache em memória de miniaturas (path -> bytes).
  static final Map<String, Uint8List> _thumbCache = {};

  /// Miniatura da primeira página do PDF (cache em memória + disco).
  static Future<Uint8List?> loadThumbnail(String path, {int width = 240}) async {
    final Uint8List? cached = _thumbCache[path];
    if (cached != null) return cached;

    // Disco primeiro (mesmo padrão da galeria/vídeos). Chave estável
    // derivada do caminho (ver diskKeyForPdfPath).
    final String diskKey = 'pdf_${diskKeyForPdfPath(path)}';
    final Uint8List? disk = await ThumbnailDiskCache.get(diskKey);
    if (disk != null) {
      _thumbCache[path] = disk;
      return disk;
    }

    try {
      final Uint8List? bytes = await _channel
          .invokeMethod<Uint8List>('getThumbnail', {'path': path, 'width': width});
      if (bytes != null && bytes.isNotEmpty) {
        _thumbCache[path] = bytes;
        await ThumbnailDiskCache.put(diskKey, bytes);
      }
      return bytes;
    } catch (e) {
      return null;
    }
  }

  // ---- Número de páginas (PdfRenderer no lado nativo, por caminho) ----

  static final Map<String, int> _pageCountCache = {};

  /// Total de páginas do PDF. Cache em memória; falha -> null (a UI
  /// simplesmente omite o número).
  static Future<int?> getPageCount(String path) async {
    final int? cached = _pageCountCache[path];
    if (cached != null) return cached;
    if (!isSupported) return null;
    try {
      final int? count = await _channel.invokeMethod<int>(
        'getPageCount',
        {'path': path},
      );
      if (count != null && count > 0) _pageCountCache[path] = count;
      return count;
    } catch (_) {
      return null;
    }
  }

  static void clearCache() {
    _thumbCache.clear();
    _pageCountCache.clear();
  }

  /// Limpa tudo que o serviço guardou sobre um PDF (miniatura em memória e
  /// em disco + nº de páginas) — usado quando o arquivo é excluído.
  static Future<void> clearForPath(String path) async {
    _thumbCache.remove(path);
    _pageCountCache.remove(path);
    await ThumbnailDiskCache.remove('pdf_${diskKeyForPdfPath(path)}');
  }
}