import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:share_plus/share_plus.dart';

/// Compartilhamento de arquivos de mídia (share sheet do Android — WhatsApp,
/// Messenger, etc.) via share_plus.
///
/// Responsabilidade: receber um arquivo local (foto, vídeo, música, PDF) e
/// abrir o compartilhamento do sistema. O share_plus usa FileProvider
/// interno — funciona com caminhos locais sem permissões extras.
class MediaShareService {
  /// Abre o share sheet com o arquivo indicado.
  ///
  /// [fileName] é usado quando o caminho não tem nome legível (ex.: PDFs do
  /// seletor SAF); [mimeType] ajuda o sistema a escolher os apps corretos.
  static Future<void> shareFile({
    required String path,
    String? fileName,
    String? mimeType,
  }) async {
    final File file = File(path);
    if (!file.existsSync() || file.lengthSync() == 0) {
      throw StateError('Arquivo não encontrado ou vazio: $path');
    }

    final String name = fileName ?? file.uri.pathSegments.last;
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(path, mimeType: mimeType, name: name)],
      ),
    );
  }

  /// VERSÃO MULTIARQUIVO: usada pelo gerenciador de arquivos na seleção em
  /// lote — um único share sheet com todos os arquivos escolhidos.
  ///
  /// Aceita QUALQUER tipo de arquivo (apk, zip, docx…): sem filtro de mídia.
  /// Arquivos inexistentes são silenciosamente omitidos (nunca crash).
  static Future<void> shareFiles(List<String> paths) async {
    if (paths.isEmpty) return;

    final List<XFile> files = <XFile>[];
    for (final String path in paths) {
      try {
        final File file = File(path);
        if (!file.existsSync() || file.lengthSync() == 0) continue;
        files.add(XFile(path));
      } catch (e) {
        // Arquivo individual ilegível: omitido do share (nunca crash),
        // mas registrado para diagnóstico.
        debugPrint('[MediaShare] arquivo ignorado ($path): $e');
        continue;
      }
    }
    if (files.isEmpty) {
      throw StateError('Nenhum arquivo válido para compartilhar.');
    }

    await SharePlus.instance.share(ShareParams(files: files));
  }
}