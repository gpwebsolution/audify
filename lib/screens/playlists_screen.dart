import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../l10n/l10n.dart';
import '../providers/favorites_provider.dart';
import '../providers/history_provider.dart';
import '../providers/playlist_provider.dart';
import '../widgets/playlist_picker_sheet.dart';
import 'auto_playlist_detail_screen.dart';
import 'favorites_detail_screen.dart';
import 'playlist_detail_screen.dart';

/// Aba de Playlists: lista as playlists do usuário com CRUD.
class PlaylistsScreen extends StatelessWidget {
  const PlaylistsScreen({super.key});

  /// Descrição mista: "3 faixas • 2 vídeos" (singular/plural corretos).
  static String _describe(Playlist playlist) {
    final List<String> parts = [];
    if (playlist.songCount > 0) {
      parts.add(
        '${playlist.songCount} '
        '${playlist.songCount == 1 ? 'faixa' : 'faixas'}',
      );
    }
    if (playlist.videoCount > 0) {
      parts.add(
        '${playlist.videoCount} '
        '${playlist.videoCount == 1 ? 'vídeo' : 'vídeos'}',
      );
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
        // Item 4.1 — playlist automática "Favoritas" PINADA no topo,
        // antes do carregamento e mesmo sem playlist alguma (a fonte é
        // a tabela favorite_songs, não a tabela playlists).
        const _FavoritesTile(),
        // Item 4.2 — playlists automáticas de histórico (somente
        // leitura), logo abaixo de Favoritas e acima das playlists
        // reais.
        const _HistoryTiles(),
        Expanded(
          child: provider.isLoading
              ? const Center(child: CircularProgressIndicator())
              : provider.playlists.isEmpty
              ? _EmptyPlaylists()
              : ListView.builder(
                  // Padding inferior reserva o espaço do FAB: sem isso a
                  // ÚLTIMA playlist fica atrás do botão "Nova playlist"
                  // e some justamente na hora de tocar nela.
                  padding: const EdgeInsets.only(
                    top: 8,
                    // 56 (altura do FAB) + 16 (folga) + 8 (respiro)
                    bottom: 80,
                  ),
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
                        return await _confirmDelete(context, playlist.name) ??
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
                          style: const TextStyle(fontWeight: FontWeight.w600),
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
        content: const Text(
          'As faixas continuam no aparelho — '
          'apenas a playlist é removida.',
        ),
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

/// Item 4.1 — entrada fixa "Favoritas" no topo da aba.
///
/// Playlist automática: sem CRUD de playlist (não renomeia/exclui/
/// reordena) — o detalhe é o [FavoritesDetailScreen] e a fonte é a
/// tabela `favorite_songs`.
class _FavoritesTile extends StatelessWidget {
  const _FavoritesTile();

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: ListenableBuilder(
        listenable: FavoritesProvider.instance,
        builder: (BuildContext context, _) {
          final int count = FavoritesProvider.instance.count;
          return ListTile(
            leading: CircleAvatar(
              backgroundColor: colors.errorContainer,
              child: Icon(Icons.favorite, color: colors.onErrorContainer),
            ),
            title: const Text(
              'Favoritas',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              count == 0
                  ? 'Toque no coração de uma faixa para começar'
                  : '$count ${count == 1 ? 'faixa' : 'faixas'}',
            ),
            trailing: const Icon(Icons.chevron_right),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const FavoritesDetailScreen(),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Item 4.2 — entradas fixas do histórico na aba Playlists.
///
/// Duas playlists automáticas somente leitura (sem CRUD): a fonte é a
/// tabela `song_stats` via [HistoryProvider] — a contagem do subtítulo
/// e os detalhes reagem ao vivo a cada play registrado e ao "Limpar
/// histórico".
class _HistoryTiles extends StatelessWidget {
  const _HistoryTiles();

  Widget _tile(
    BuildContext context,
    ColorScheme colors, {
    required String title,
    required IconData icon,
    required String subtitle,
    required bool recent,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: colors.tertiaryContainer,
          child: Icon(icon, color: colors.onTertiaryContainer),
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) =>
                AutoPlaylistDetailScreen(title: title, recent: recent),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;

    return ListenableBuilder(
      listenable: HistoryProvider.instance,
      builder: (BuildContext context, _) {
        final int count = HistoryProvider.instance.count;
        final String subtitle = count == 0
            ? 'Ainda sem histórico'
            : '$count ${count == 1 ? 'faixa' : 'faixas'}';
        return Column(
          children: [
            _tile(
              context,
              colors,
              title: 'Tocadas recentemente',
              icon: Icons.history,
              subtitle: subtitle,
              recent: true,
            ),
            _tile(
              context,
              colors,
              title: 'Mais tocadas',
              icon: Icons.trending_up,
              subtitle: subtitle,
              recent: false,
            ),
          ],
        );
      },
    );
  }
}

class _EmptyPlaylists extends StatelessWidget {
  const _EmptyPlaylists();

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l10n = l10nOf(context);
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
              l10n.emptyPlaylists,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            // Item 5.3 — ação clara no estado vazio: mesmo diálogo do
            // FAB "Nova playlist" (função compartilhada do seletor).
            FilledButton.icon(
              icon: const Icon(Icons.add),
              label: Text(l10n.newPlaylistBtn),
              onPressed: () =>
                  askPlaylistName(context, context.read<PlaylistProvider>()),
            ),
          ],
        ),
      ),
    );
  }
}
