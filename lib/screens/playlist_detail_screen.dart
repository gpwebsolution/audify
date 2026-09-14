import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/song_model.dart';
import '../models/video_model.dart';
import '../providers/player_provider.dart';
import '../providers/playlist_provider.dart';
import '../services/video_query_service.dart';
import '../utils/format.dart';
import '../widgets/song_list_tile.dart';
import 'video_player_screen.dart';

/// Detalhe de uma playlist: músicas E vídeos salvos, com reprodução,
/// remoção e reordenação (drag & drop).
class PlaylistDetailScreen extends StatefulWidget {
  final int playlistId;
  final String playlistName;

  const PlaylistDetailScreen({
    super.key,
    required this.playlistId,
    required this.playlistName,
  });

  @override
  State<PlaylistDetailScreen> createState() => _PlaylistDetailScreenState();
}

class _PlaylistDetailScreenState extends State<PlaylistDetailScreen> {
  List<Song>? _songs;
  List<Video>? _videos;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final PlaylistProvider provider = context.read<PlaylistProvider>();
    final List<Song> songs = await provider.songsOf(widget.playlistId);
    final List<Video> videos = await provider.videosOf(widget.playlistId);
    if (mounted) {
      setState(() {
        _songs = songs;
        _videos = videos;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final PlayerProvider player = context.watch<PlayerProvider>();
    final PlaylistProvider provider = context.watch<PlaylistProvider>();
    final ColorScheme colors = Theme.of(context).colorScheme;
    final List<Song> songs = _songs ?? const [];
    final List<Video> videos = _videos ?? const [];

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.playlistName),
        actions: [
          // ---- Renomear ----
          IconButton(
            tooltip: 'Renomear',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => _rename(context, provider),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : songs.isEmpty && videos.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'Playlist vazia.\nToque e segure uma música na aba '
                      'Música (ou um vídeo na aba Vídeos) e escolha '
                      '"Adicionar à playlist".',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  children: [
                    if (songs.isNotEmpty) ...[
                      _SectionHeader(
                        icon: Icons.music_note_outlined,
                        title: 'Músicas (${songs.length})',
                        onPlay: () => provider.playPlaylist(
                          widget.playlistId,
                          songs.first,
                        ),
                      ),
                      _ReorderableSongs(
                        songs: songs,
                        player: player,
                        onTap: (song) =>
                            provider.playPlaylist(widget.playlistId, song),
                        onRemove: (song) => _confirmRemoveSong(
                          context,
                          provider,
                          song,
                        ),
                        onReorder: (reordered) {
                          setState(() => _songs = reordered);
                          provider.reorder(widget.playlistId, reordered);
                        },
                      ),
                    ],
                    if (videos.isNotEmpty) ...[
                      _SectionHeader(
                        icon: Icons.movie_outlined,
                        title: 'Vídeos (${videos.length})',
                        onPlay: () => _openVideoPlayer(context, videos, 0),
                      ),
                      _ReorderableVideos(
                        videos: videos,
                        colors: colors,
                        onTap: (index) =>
                            _openVideoPlayer(context, videos, index),
                        onRemove: (video) => _confirmRemoveVideo(
                          context,
                          provider,
                          video,
                        ),
                        onReorder: (reordered) {
                          setState(() => _videos = reordered);
                          provider.reorderVideos(widget.playlistId, reordered);
                        },
                      ),
                    ],
                  ],
                ),
    );
  }

  void _openVideoPlayer(BuildContext context, List<Video> videos, int index) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => VideoPlayerScreen(queue: videos, initialIndex: index),
      ),
    );
  }

  Future<void> _rename(
    BuildContext context,
    PlaylistProvider provider,
  ) async {
    final TextEditingController controller =
        TextEditingController(text: widget.playlistName);
    final String? newName = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Renomear playlist'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Nome da playlist'),
          onSubmitted: (value) => Navigator.pop(dialogContext, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('Salvar'),
          ),
        ],
      ),
    );
    if (newName == null || newName.trim().isEmpty) return;
    await provider.rename(widget.playlistId, newName);
  }

  Future<void> _confirmRemoveSong(
    BuildContext context,
    PlaylistProvider provider,
    Song song,
  ) async {
    final bool? confirmed = await _confirmRemove(
      context,
      song.title,
      'A música continua na biblioteca — apenas sai desta playlist.',
    );
    if (confirmed == true) {
      await provider.removeSong(widget.playlistId, song);
      await _load();
    }
  }

  Future<void> _confirmRemoveVideo(
    BuildContext context,
    PlaylistProvider provider,
    Video video,
  ) async {
    final bool? confirmed = await _confirmRemove(
      context,
      video.displayTitle,
      'O vídeo continua na biblioteca — apenas sai desta playlist.',
    );
    if (confirmed == true) {
      await provider.removeVideo(widget.playlistId, video);
      await _load();
    }
  }

  Future<bool?> _confirmRemove(
    BuildContext context,
    String title,
    String content,
  ) {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Remover "$title"?'),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Remover'),
          ),
        ],
      ),
    );
  }
}

/// Cabeçalho de seção com botão de reproduzir tudo.
class _SectionHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  final VoidCallback onPlay;

  const _SectionHeader({
    required this.icon,
    required this.title,
    required this.onPlay,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
      child: Row(
        children: [
          Icon(icon, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          TextButton.icon(
            onPressed: onPlay,
            icon: const Icon(Icons.play_arrow, size: 20),
            label: const Text('Reproduzir'),
          ),
        ],
      ),
    );
  }
}

/// Lista reordenável de músicas (arrasta pela alça).
class _ReorderableSongs extends StatelessWidget {
  final List<Song> songs;
  final PlayerProvider player;
  final ValueChanged<Song> onTap;
  final ValueChanged<Song> onRemove;
  final ValueChanged<List<Song>> onReorder;

  const _ReorderableSongs({
    required this.songs,
    required this.player,
    required this.onTap,
    required this.onRemove,
    required this.onReorder,
  });

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;

    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      itemCount: songs.length,
      onReorderItem: (oldIndex, newIndex) {
        final List<Song> reordered = List.of(songs);
        final Song moved = reordered.removeAt(oldIndex);
        reordered.insert(newIndex, moved);
        onReorder(reordered);
      },
      itemBuilder: (context, index) {
        final Song song = songs[index];
        final bool isCurrent = player.currentSong?.id == song.id;
        return ReorderableDragStartListener(
          key: ValueKey('song-${song.id}'),
          index: index,
          child: SongListTile(
            song: song,
            isCurrent: isCurrent,
            isPlaying: isCurrent && player.isPlaying,
            onTap: () => onTap(song),
            onLongPress: () => onRemove(song),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.drag_indicator, color: colors.onSurfaceVariant),
                IconButton(
                  tooltip: 'Remover da playlist',
                  icon: Icon(
                    Icons.remove_circle_outline,
                    color: colors.onSurfaceVariant,
                  ),
                  onPressed: () => onRemove(song),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Lista reordenável de vídeos (arrasta pela alça).
class _ReorderableVideos extends StatelessWidget {
  final List<Video> videos;
  final ColorScheme colors;
  final ValueChanged<int> onTap;
  final ValueChanged<Video> onRemove;
  final ValueChanged<List<Video>> onReorder;

  const _ReorderableVideos({
    required this.videos,
    required this.colors,
    required this.onTap,
    required this.onRemove,
    required this.onReorder,
  });

  @override
  Widget build(BuildContext context) {
    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      itemCount: videos.length,
      onReorderItem: (oldIndex, newIndex) {
        final List<Video> reordered = List.of(videos);
        final Video moved = reordered.removeAt(oldIndex);
        reordered.insert(newIndex, moved);
        onReorder(reordered);
      },
      itemBuilder: (context, index) {
        final Video video = videos[index];
        return ReorderableDragStartListener(
          key: ValueKey('video-${video.id}'),
          index: index,
          child: ListTile(
            leading: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 56,
                height: 40,
                child: _VideoThumb(videoId: video.id),
              ),
            ),
            title: Text(
              video.displayTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(formatDuration(video.duration)),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.drag_indicator, color: colors.onSurfaceVariant),
                IconButton(
                  tooltip: 'Remover da playlist',
                  icon: Icon(
                    Icons.remove_circle_outline,
                    color: colors.onSurfaceVariant,
                  ),
                  onPressed: () => onRemove(video),
                ),
              ],
            ),
            onTap: () => onTap(index),
          ),
        );
      },
    );
  }
}

/// Miniatura do vídeo (mesmo serviço da aba Vídeos).
class _VideoThumb extends StatelessWidget {
  final int videoId;

  const _VideoThumb({required this.videoId});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: VideoQueryService.loadThumbnail(videoId, width: 120),
      builder: (context, snapshot) {
        final Uint8List? data = snapshot.data;
        if (data == null || data.isEmpty) {
          return Container(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Icon(
              Icons.movie_outlined,
              size: 20,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          );
        }
        return Image.memory(data, fit: BoxFit.cover, gaplessPlayback: true);
      },
    );
  }
}