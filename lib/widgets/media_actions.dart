import 'package:flutter/material.dart';

import '../repositories/media_delete_repository.dart';
import '../services/media_share_service.dart';

/// Ações de mídia compartilhadas (compartilhar / excluir) via bottom sheet.
///
/// Usado pela Galeria, Vídeos, Músicas e PDFs: mesmo menu, mesmo feedback
/// visual (snackbars), evitando duplicação entre telas.
class MediaActions {
  /// Abre o menu de ações para um arquivo de mídia.
  ///
  /// [type]: tipo da mídia ('image' | 'video' | 'audio' | 'pdf').
  /// [mediaId]: id no MediaStore (para exclusão; pode ser null se [deletePath]
  /// for informado — ex.: PDF do seletor SAF).
  /// [filePath]: caminho do arquivo (compartilhamento e exclusão legada).
  /// [shareName]: nome legível para o share sheet.
  /// [shareMimeType]: MIME para o share sheet (ajuda o WhatsApp etc. a
  /// classificar o arquivo).
  /// [onDeleted]: chamado após exclusão confirmada (para a tela recarregar).
  static Future<void> show(
    BuildContext context, {
    required String type,
    int? mediaId,
    required String filePath,
    String? shareName,
    String? shareMimeType,
    VoidCallback? onDeleted,
  }) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: const Icon(Icons.share_outlined),
              title: const Text('Compartilhar'),
              subtitle: const Text('WhatsApp, Messenger e outros'),
              onTap: () async {
                Navigator.pop(sheetContext);
                await _share(context, filePath, shareName, shareMimeType);
              },
            ),
            ListTile(
              leading: Icon(
                Icons.delete_outline,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(
                'Excluir do aparelho',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
              subtitle: const Text('O Android pedirá confirmação'),
              onTap: () async {
                Navigator.pop(sheetContext);
                await _delete(
                  context,
                  type: type,
                  mediaId: mediaId,
                  filePath: filePath,
                  onDeleted: onDeleted,
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  static Future<void> _share(
    BuildContext context,
    String path,
    String? name,
    String? mimeType,
  ) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final Color errorColor = Theme.of(context).colorScheme.error;
    try {
      await MediaShareService.shareFile(
        path: path,
        fileName: name,
        mimeType: mimeType,
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('Não foi possível compartilhar: $e'),
          backgroundColor: errorColor,
        ),
      );
    }
  }

  static Future<void> _delete(
    BuildContext context, {
    required String type,
    int? mediaId,
    required String filePath,
    VoidCallback? onDeleted,
  }) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final Color errorColor = Theme.of(context).colorScheme.error;
    final DeleteResult result = await MediaDeleteRepository.delete(
      type: type,
      id: mediaId,
      path: filePath,
    );

    switch (result) {
      case DeleteResult.deleted:
        messenger.showSnackBar(
          const SnackBar(content: Text('Arquivo excluído.')),
        );
        onDeleted?.call();
      case DeleteResult.cancelled:
        messenger.showSnackBar(
          const SnackBar(content: Text('Exclusão cancelada.')),
        );
      case DeleteResult.failed:
        messenger.showSnackBar(
          SnackBar(
            content: const Text('Não foi possível excluir o arquivo.'),
            backgroundColor: errorColor,
          ),
        );
    }
  }
}