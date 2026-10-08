import 'package:flutter/material.dart';

import '../models/media_ref.dart';
import '../services/media_delete_service.dart';
import '../services/media_share_service.dart';

/// Ações de mídia compartilhadas (compartilhar / excluir) via bottom sheet.
///
/// Ponto único de UI para as seis abas: mesma confirmação em português,
/// mesma chamada ao [MediaDeleteService] e mesmo feedback real (sucesso,
/// cancelamento ou erro com motivo) — nada de "apagou?" presumido.
class MediaActions {
  /// Abre o menu de ações de UM arquivo.
  ///
  /// [ref] nulo significa "excluir não se aplica" (faixa embutida no APK,
  /// por exemplo). Nesse caso a opção aparece desabilitada e explica o
  /// motivo em [lockedMessage] — esconder a opção deixaria o usuário
  /// sem nenhuma pista do porquê.
  ///
  /// [extraTiles] entra entre "Compartilhar" e "Excluir": é como a Galeria e
  /// a aba de PDFs acrescentam "Detalhes" sem duplicar esta folha.
  static Future<void> show(
    BuildContext context, {
    MediaRef? ref,
    String? lockedMessage,
    required String label,
    String? sharePath,
    String? shareName,
    String? shareMimeType,
    List<Widget> extraTiles = const <Widget>[],
    Future<void> Function(List<MediaRef> deleted)? onDeleted,
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
                final String? path = sharePath ?? ref?.path;
                if (path == null || path.isEmpty) {
                  _snack(context, 'Este item não pode ser compartilhado.');
                  return;
                }
                await _share(
                  context,
                  path: path,
                  name: shareName,
                  mimeType: shareMimeType,
                );
              },
            ),
            ...extraTiles,
            if (ref != null)
              _deleteTile(
                context,
                label: label,
                onTap: () async {
                  Navigator.pop(sheetContext);
                  await confirmDelete(context, ref, onDeleted: onDeleted);
                },
              )
            else
              ListTile(
                enabled: false,
                leading: Icon(
                  Icons.lock_outline,
                  color: Theme.of(context).colorScheme.outline,
                ),
                title: Text(
                  'Excluir do aparelho',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.outline,
                  ),
                ),
                subtitle: Text(lockedMessage ?? 'Não é possível excluir.'),
                onTap: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        lockedMessage ?? 'Este item não pode ser excluído.',
                      ),
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  /// Confirma e executa a exclusão de UM item.
  ///
  /// Cancelo no diálogo do sistema ⇒ [onDeleted] NÃO é chamado e a UI fica
  /// intacta (é a única forma de o usuário desistir sem consequência).
  static Future<void> confirmDelete(
    BuildContext context,
    MediaRef ref, {
    String? label,
    Future<void> Function(List<MediaRef> deleted)? onDeleted,
  }) => confirmDeleteMany(
    context,
    <MediaRef>[ref],
    label: label,
    onDeleted: onDeleted,
  );

  /// Confirma e executa a exclusão de um LOTE com UM único diálogo.
  static Future<void> confirmDeleteMany(
    BuildContext context,
    List<MediaRef> items, {
    String? label,
    Future<void> Function(List<MediaRef> deleted)? onDeleted,
  }) async {
    if (items.isEmpty) return;

    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          items.length == 1
              ? 'Excluir "$label"?'
              : 'Excluir ${items.length} itens?',
        ),
        content: Text(
          items.length == 1
              ? 'O arquivo será apagado do aparelho. '
                    'Esta ação não pode ser desfeita.'
              : 'Os ${items.length} arquivos serão apagados do aparelho. '
                    'Esta ação não pode ser desfeita.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Excluir'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    final DeleteResult result = await MediaDeleteService.deleteMedia(items);
    if (!context.mounted) return;

    // Cancelou no diálogo do SO: nada foi removido, nada muda na UI.
    if (result.cancelledWithoutChanges) {
      _snack(context, 'Exclusão cancelada.');
      return;
    }

    final bool ok = result.removed.isNotEmpty;
    _snack(context, result.message, isError: !ok);

    // A limpeza de estado usa `removed` (excluídos + já ausentes), não
    // `deleted`: um arquivo que já não estava no aparelho também precisa
    // sumir das listas, senão vira item fantasma permanente.
    if (result.removed.isNotEmpty) {
      await onDeleted?.call(result.removed);
    }
  }

  static Widget _deleteTile(
    BuildContext context, {
    required String label,
    required VoidCallback onTap,
  }) {
    final Color error = Theme.of(context).colorScheme.error;
    return ListTile(
      leading: Icon(Icons.delete_outline, color: error),
      title: Text('Excluir do aparelho', style: TextStyle(color: error)),
      subtitle: Text(
        label.isEmpty
            ? 'O Android pedirá confirmação'
            : '$label • o Android pedirá confirmação',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: onTap,
    );
  }

  /// Compartilha um LOTE de arquivos num único diálogo do sistema.
  ///
  /// Usado pelas abas de mídia no modo seleção: um share só, com todos os
  /// arquivos, em vez de um diálogo por item.
  ///
  /// [items] sem caminho (faixa embutida no app) é ignorado com aviso — não é
  /// possível compartilhar algo que está dentro do APK.
  static Future<void> shareMany(
    BuildContext context,
    List<MediaRef> items, {
    List<String> names = const <String>[],
  }) async {
    if (items.isEmpty) return;

    final List<String> paths = <String>[];
    int skipped = 0;
    for (int i = 0; i < items.length; i++) {
      final String? path = items[i].path;
      if (path == null || path.isEmpty) {
        skipped++;
      } else {
        paths.add(path);
      }
    }

    if (paths.isEmpty) {
      _snack(
        context,
        'Nada a compartilhar: os itens marcados não são arquivos '
        'do aparelho.',
        isError: true,
      );
      return;
    }

    // Mensageiro capturado ANTES da espera: compartilhar abre o diálogo do
    // sistema, e o `context` pode não estar montado quando ele volta.
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final Color errorColor = Theme.of(context).colorScheme.error;

    try {
      await MediaShareService.shareFiles(paths);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('Não foi possível compartilhar: $e'),
          backgroundColor: errorColor,
        ),
      );
      return;
    }

    // Compartilhar não mexe no conteúdo, então a seleção é preservada.
    if (skipped > 0) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            skipped == 1
                ? '1 item não foi compartilhado (não é arquivo do aparelho).'
                : '$skipped itens não foram compartilhados '
                      '(não são arquivos do aparelho).',
          ),
        ),
      );
    }
  }

  /// Compartilha UM arquivo já existente, com tratamento de erro.
  ///
  /// Usado direto pelas abas (Música/Vídeos) que já têm item próprio de
  /// exclusão no seu menu — evita aninhar um segundo bottom sheet só para
  /// compartilhar.
  static Future<void> share(
    BuildContext context, {
    required String path,
    String? name,
    String? mimeType,
  }) async {
    if (path.isEmpty) {
      _snack(context, 'Este item não pode ser compartilhado.');
      return;
    }
    await _share(context, path: path, name: name, mimeType: mimeType);
  }

  static Future<void> _share(
    BuildContext context, {
    required String path,
    String? name,
    String? mimeType,
  }) async {
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

  static void _snack(
    BuildContext context,
    String message, {
    bool isError = false,
  }) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: isError ? Theme.of(context).colorScheme.error : null,
        ),
      );
  }
}
