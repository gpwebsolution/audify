import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/song_model.dart';
import '../providers/favorites_provider.dart';
import '../providers/player_provider.dart';
import '../widgets/song_list_tile.dart';

/// Item 4.1 — detalhe da playlist automática "Favoritas".
///
/// Sem CRUD de playlist (não renomeia, não exclui, não reordena): a
/// fonte é a tabela `favorite_songs`. O coração de cada linha DESFAZ o
/// favorito — a linha sai sozinha (o singleton notifica) e, no último,
/// a tela vira o estado vazio.
class FavoritesDetailScreen extends StatelessWidget {
  const FavoritesDetailScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final PlayerProvider player = context.watch<PlayerProvider>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Favoritas'),
        actions: [
          ListenableBuilder(
            listenable: FavoritesProvider.instance,
            builder: (BuildContext context, _) {
              if (FavoritesProvider.instance.songs.isEmpty) {
                return const SizedBox.shrink();
              }
              return IconButton(
                tooltip: 'Tocar tudo',
                icon: const Icon(Icons.playlist_play),
                onPressed: () =>
                    player.playQueue(FavoritesProvider.instance.songs, 0),
              );
            },
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: FavoritesProvider.instance,
        builder: (BuildContext context, _) {
          final List<Song> songs = FavoritesProvider.instance.songs;
          if (songs.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.favorite_border,
                      size: 64,
                      color: Theme.of(context).colorScheme.outline,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Nenhuma faixa favorita ainda.\n'
                      'Toque no coração de uma música para ela '
                      'aparecer aqui.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: songs.length,
            itemBuilder: (BuildContext context, int index) {
              final Song song = songs[index];
              final bool isCurrent = player.currentSong?.id == song.id;
              return SongListTile(
                song: song,
                isCurrent: isCurrent,
                isPlaying: isCurrent && player.isPlaying,
                // Toda linha desta tela É favorita: coração sempre cheio,
                // e o toque remove (a linha some via ListenableBuilder
                // do build acima).
                isFavorite: true,
                onFavoriteToggle: () => FavoritesProvider.instance.toggle(song),
                onTap: () => player.playQueue(songs, index),
              );
            },
          );
        },
      ),
    );
  }
}
