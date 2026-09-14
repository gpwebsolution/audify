import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/playlist_provider.dart';
import 'playlist_detail_screen.dart';

/// Aba de Playlists: lista as playlists do usuário com CRUD.
class PlaylistsScreen extends StatelessWidget {
  const PlaylistsScreen({super.key});

  /// Descrição mista: "3 faixas • 2 vídeos" (singular/plural corretos).
  static String _describe(Playlist playlist) {
    final List<String> parts = [];
    if (playlist.songCount > 0) {
      parts.add('${playlist.songCount} '
          '${playlist.songCount == 1 ? 'faixa' : 'faixas'}');
    }
    if (playlist.videoCount > 0) {
      parts.add('${playlist.videoCount} '
          '${playlist.videoCount == 1 ? 'vídeo' : 'vídeos'}');
    }
    if (parts.isEmpty) return 'Playlist vazia';
    return parts.join(' • ');
  }

  @override
  Widget build(BuildContext context) {
    final PlaylistProvider provider = context.watch<PlaylistProvider>();
    final ColorScheme colors = Theme.of(context).colorScheme;

    return Column(
      children: [
        Expanded(
          child: provider.isLoading
              ? const Center(child: CircularProgressIndicator())
              : provider.playlists.isEmpty
                  ? _EmptyPlaylists()
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: provider.playlists.length,
                      itemBuilder: (context, index) {
                        final playlist = provider.playlists[index];
                        return Dismissible(
                          key: ValueKey('playlist-${playlist.id}'),
                          direction: DismissDirection.endToStart,
                          background: Container(
                            alignment: Alignment.centerRight,
                            padding: const EdgeInsets.only(right: 24),
                            margin: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: colors.errorContainer,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(
                              Icons.delete_outline,
                              color: colors.onErrorContainer,
                            ),
                          ),
                          confirmDismiss: (_) async {
                            return await _confirmDelete(
                                  context,
                                  playlist.name,
                                ) ??
                                false;
                          },
                          onDismissed: (_) => provider.delete(playlist.id),
                          child: ListTile(
                            leading: CircleAvatar(
                              backgroundColor: colors.primaryContainer,
                              child: Icon(
                                Icons.queue_music,
                                color: colors.onPrimaryContainer,
                              ),
                            ),
                            title: Text(
                              playlist.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            subtitle: Text(_describe(playlist)),
                            trailing: const Icon(Icons.chevron_right),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => PlaylistDetailScreen(
                                  playlistId: playlist.id,
                                  playlistName: playlist.name,
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
        ),
      ],
    );
  }

  Future<bool?> _confirmDelete(BuildContext context, String name) {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Excluir "$name"?'),
        content: const Text('As faixas continuam no aparelho — '
            'apenas a playlist é removida.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Excluir'),
          ),
        ],
      ),
    );
  }
}

class _EmptyPlaylists extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.playlist_add,
              size: 64,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text(
              'Nenhuma playlist ainda.\n'
              'Toque no + para criar a primeira.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}