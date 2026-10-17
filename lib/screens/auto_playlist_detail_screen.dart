import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/song_model.dart';
import '../providers/favorites_provider.dart';
import '../providers/history_provider.dart';
import '../providers/player_provider.dart';
import '../widgets/song_list_tile.dart';

/// Item 4.2 — detalhe das playlists automáticas de histórico:
/// "Tocadas recentemente" e "Mais tocadas".
///
/// Somente leitura: sem CRUD e sem remoção individual (é histórico do
/// app, não uma playlist do usuário) — o coração por linha continua,
/// como em qualquer lista de faixas. A ação "Limpar histórico" apaga a
/// tabela `song_stats` inteira, com confirmação.
class AutoPlaylistDetailScreen extends StatelessWidget {
  const AutoPlaylistDetailScreen({
    super.key,
    required this.title,
    required this.recent,
  });

  /// 'Tocadas recentemente' → true; 'Mais tocadas' → false.
  final bool recent;

  /// Título da entrada na aba Playlists (também o da AppBar).
  final String title;

  /// Resolve os ids ordenados pelo histórico contra o catálogo cheio do
  /// player (ids órfãos — ex.: mídia reindexada — caem fora).
  List<Song> _songsOf(PlayerProvider player) {
    final List<String> ids = recent
        ? HistoryProvider.instance.recentIds
        : HistoryProvider.instance.mostPlayedIds;
    if (ids.isEmpty) return const <Song>[];
    final Map<String, Song> catalog = <String, Song>{
      for (final Song s in player.songs) s.id: s,
    };
    final List<Song> songs = <Song>[];
    for (final String id in ids) {
      final Song? song = catalog[id];
      if (song != null) songs.add(song);
    }
    return songs;
  }

  Future<bool?> _confirmClear(BuildContext context) {
    return showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Limpar histórico?'),
        content: const Text(
          'As contagens e datas de "Tocadas recentemente" e '
          '"Mais tocadas" serão apagadas.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Limpar'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final PlayerProvider player = context.watch<PlayerProvider>();

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          ListenableBuilder(
            listenable: HistoryProvider.instance,
            builder: (BuildContext context, _) {
              if (_songsOf(player).isEmpty) return const SizedBox.shrink();
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'Tocar tudo',
                    icon: const Icon(Icons.playlist_play),
                    onPressed: () => player.playQueue(_songsOf(player), 0),
                  ),
                  IconButton(
                    tooltip: 'Limpar histórico',
                    icon: const Icon(Icons.delete_sweep_outlined),
                    onPressed: () async {
                      final bool confirmed =
                          await _confirmClear(context) ?? false;
                      if (!confirmed) return;
                      await HistoryProvider.instance.clear();
                    },
                  ),
                ],
              );
            },
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: HistoryProvider.instance,
        builder: (BuildContext context, _) {
          final List<Song> songs = _songsOf(player);
          if (songs.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      recent ? Icons.history : Icons.trending_up,
                      size: 64,
                      color: Theme.of(context).colorScheme.outline,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      recent
                          ? 'Nenhuma faixa no histórico ainda.\n'
                                'Toque uma música por pelo menos 30 s '
                                'para ela aparecer aqui.'
                          : 'Sem contagens por aqui ainda.\n'
                                'As faixas mais ouvidas aparecerão nesta lista.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            );
          }
          // O coração muda com o FavoritesProvider (singleton fora do
          // grafo): builder aninhado para as duas fontes.
          return ListenableBuilder(
            listenable: FavoritesProvider.instance,
            builder: (BuildContext context, _) => ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: songs.length,
              itemBuilder: (BuildContext context, int index) {
                final Song song = songs[index];
                final bool isCurrent = player.currentSong?.id == song.id;
                return SongListTile(
                  song: song,
                  isCurrent: isCurrent,
                  isPlaying: isCurrent && player.isPlaying,
                  isFavorite: FavoritesProvider.instance.isFavorite(song.id),
                  onFavoriteToggle: () =>
                      FavoritesProvider.instance.toggle(song),
                  onTap: () => player.playQueue(songs, index),
                );
              },
            ),
          );
        },
      ),
    );
  }
}
