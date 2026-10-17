import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/playlist_provider.dart';

/// Item 4.4 — seletor de playlist ("adicionar à playlist") com o botão
/// "Nova playlist" DENTRO da própria folha.
///
/// Antes o seletor mandava o usuário criar a playlist em outra aba
/// (player, música, vídeo): aqui o nome é pedido no lugar (dialog) e a
/// playlist recém-criada já sai como a ESCOLHIDA — [onPick] recebe ela
/// e o fluxo de adicionar continua normalmente.
///
/// [onPick] roda depois que a folha fecha; [subtitleOf] diferencia o
/// "N faixas" (música) do "N vídeos" (vídeo).
Future<void> showPlaylistPickerSheet(
  BuildContext context, {
  required Future<void> Function(Playlist playlist) onPick,
  required String Function(Playlist playlist) subtitleOf,
}) {
  final PlaylistProvider provider = context.read<PlaylistProvider>();
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (BuildContext sheetContext) {
      Future<void> pick(Playlist playlist) async {
        Navigator.pop(sheetContext);
        await onPick(playlist);
      }

      return SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.playlist_add),
              title: const Text('Nova playlist'),
              subtitle: const Text('Cria e escolhe em seguida'),
              onTap: () async {
                Navigator.pop(sheetContext);
                final Playlist? created = await askPlaylistName(
                  context,
                  provider,
                );
                if (created == null || !context.mounted) return;
                await onPick(created);
              },
            ),
            if (provider.playlists.isNotEmpty) const Divider(),
            for (final Playlist playlist in provider.playlists)
              ListTile(
                leading: const Icon(Icons.queue_music),
                title: Text(playlist.name),
                subtitle: Text(subtitleOf(playlist)),
                onTap: () => pick(playlist),
              ),
          ],
        ),
      );
    },
  );
}

/// Dialog de nome (mesmo formato do FAB "Nova playlist" da aba
/// Playlists). Devolve a playlist criada — ou null se cancelou ou o
/// nome já existia (aí o aviso de duplicata aparece na tela chamadora).
///
/// Item 5.3 — pública para o estado vazio da aba Playlists poder
/// oferecer a MESMA ação de criação do FAB.
Future<Playlist?> askPlaylistName(
  BuildContext context,
  PlaylistProvider provider,
) async {
  final TextEditingController controller = TextEditingController();
  final String? name = await showDialog<String>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      title: const Text('Nova playlist'),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(hintText: 'Nome da playlist'),
        onSubmitted: (String value) => Navigator.pop(dialogContext, value),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, controller.text),
          child: const Text('Criar'),
        ),
      ],
    ),
  );
  if (name == null || name.trim().isEmpty) return null;

  final String trimmed = name.trim();
  final bool created = await provider.create(trimmed);
  if (!created) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Já existe uma playlist com o nome "$trimmed".'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
    return null;
  }
  // A nova já está recarregada no provider — acha pelo nome (UNIQUE).
  for (final Playlist playlist in provider.playlists) {
    if (playlist.name == trimmed) return playlist;
  }
  return null;
}
