import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/video_model.dart';
import '../providers/playlist_provider.dart';
import '../providers/video_provider.dart';
import '../services/video_query_service.dart';
import '../utils/format.dart';
import '../widgets/media_actions.dart';
import 'video_player_screen.dart';

/// Aba de Vídeos: biblioteca de vídeos do aparelho (MediaStore).
class VideosScreen extends StatefulWidget {
  const VideosScreen({super.key});

  @override
  State<VideosScreen> createState() => _VideosScreenState();
}

class _VideosScreenState extends State<VideosScreen> {
  final TextEditingController _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final VideoProvider provider = context.watch<VideoProvider>();

    return Column(
      children: [
        // ---- Busca ----
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: TextField(
            controller: _searchController,
            onChanged: provider.setSearchQuery,
            decoration: InputDecoration(
              hintText: 'Buscar vídeo',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: provider.searchQuery.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Limpar busca',
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _searchController.clear();
                        provider.setSearchQuery('');
                      },
                    ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(28),
                borderSide: BorderSide.none,
              ),
              filled: true,
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ),
        Expanded(child: _buildBody(context, provider)),
      ],
    );
  }

  Widget _buildBody(BuildContext context, VideoProvider provider) {
    if (!VideoQueryService.isSupported) {
      return const _EmptyState(
        icon: Icons.videocam_off_outlined,
        message: 'Vídeos estão disponíveis apenas no Android.',
      );
    }

    if (provider.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    // Sem permissão de vídeos: explica e oferece o botão de permitir
    // (no Android 13+ a permissão é separada das fotos/músicas).
    if (provider.permissionDenied) {
      return _PermissionState(
        onRequest: () => provider.requestAccess(),
      );
    }

    if (provider.visibleVideos.isEmpty) {
      return _EmptyState(
        icon: Icons.videocam_outlined,
        message: provider.searchQuery.isNotEmpty
            ? 'Nenhum resultado para "${provider.searchQuery}".'
            : 'Nenhum vídeo encontrado no aparelho.\n'
                'Grave ou baixe vídeos para vê-los aqui.',
      );
    }

    // Grade 2 colunas: miniatura grande + metadados (uso de tela eficiente).
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.78,
      ),
      itemCount: provider.visibleVideos.length,
      itemBuilder: (context, index) {
        final Video video = provider.visibleVideos[index];
        return _VideoCard(
          video: video,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => VideoPlayerScreen(
                queue: provider.visibleVideos,
                initialIndex: index,
              ),
            ),
          ),
          onLongPress: () => _showVideoActions(context, provider, video),
        );
      },
    );
  }

  /// Menu de ações do vídeo: adicionar à playlist / compartilhar / excluir.
  Future<void> _showVideoActions(
    BuildContext context,
    VideoProvider provider,
    Video video,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: const Icon(Icons.playlist_add),
              title: const Text('Adicionar à playlist'),
              onTap: () {
                Navigator.pop(sheetContext);
                _pickPlaylist(context, video);
              },
            ),
            ListTile(
              leading: const Icon(Icons.share_outlined),
              title: const Text('Compartilhar'),
              subtitle: const Text('WhatsApp, Messenger e outros'),
              onTap: () {
                Navigator.pop(sheetContext);
                MediaActions.show(
                  context,
                  type: 'video',
                  mediaId: video.id,
                  filePath: video.path,
                  shareName: video.displayName,
                  shareMimeType: 'video/mp4',
                  onDeleted: () {
                    // Excluído do aparelho: sai de todas as playlists.
                    final PlaylistProvider playlists =
                        context.read<PlaylistProvider>();
                    playlists.removeVideoFromAll(video);
                    provider.load();
                  },
                );
              },
            ),
            ListTile(
              leading: Icon(
                Icons.info_outline,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              title: Text(video.displayTitle),
              subtitle: Text(formatDuration(video.duration)),
            ),
          ],
        ),
      ),
    );
  }

  /// Escolhe uma playlist para receber o vídeo.
  void _pickPlaylist(BuildContext context, Video video) {
    final PlaylistProvider playlistProvider =
        context.read<PlaylistProvider>();
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        if (playlistProvider.playlists.isEmpty) {
          return const SafeArea(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Nenhuma playlist ainda.\n'
                'Crie uma na aba Playlists.',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        return SafeArea(
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: playlistProvider.playlists.length,
            itemBuilder: (context, index) {
              final playlist = playlistProvider.playlists[index];
              return ListTile(
                leading: const Icon(Icons.queue_music),
                title: Text(playlist.name),
                subtitle: Text('${playlist.itemCount} itens'),
                onTap: () async {
                  await playlistProvider.addVideo(playlist.id, video);
                  if (sheetContext.mounted) Navigator.pop(sheetContext);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Adicionado a "${playlist.name}"'),
                      ),
                    );
                  }
                },
              );
            },
          ),
        );
      },
    );
  }
}

class _VideoCard extends StatelessWidget {
  final Video video;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _VideoCard({
    required this.video,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;

    return Material(
      color: colors.surfaceContainerLow,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ---- Miniatura (16:9) ----
            Expanded(
              child: SizedBox(
                width: double.infinity,
                child: _VideoThumbnail(videoId: video.id),
              ),
            ),
            // ---- Metadados ----
            Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    video.displayTitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context)
                        .textTheme
                        .bodyMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    formatDuration(video.duration),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Miniatura do vídeo (canal nativo, cache em memória).
class _VideoThumbnail extends StatelessWidget {
  final int videoId;

  const _VideoThumbnail({required this.videoId});

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;

    return FutureBuilder<Uint8List?>(
      future: VideoQueryService.loadThumbnail(videoId),
      builder: (context, snapshot) {
        final Uint8List? data = snapshot.data;
        if (data == null || data.isEmpty) {
          return Container(
            color: colors.surfaceContainerHighest,
            child: Icon(
              Icons.movie_outlined,
              size: 40,
              color: colors.onSurfaceVariant,
            ),
          );
        }
        return Image.memory(
          data,
          fit: BoxFit.cover,
          width: double.infinity,
          gaplessPlayback: true,
        );
      },
    );
  }
}

/// Estado "sem permissão": explica o motivo e oferece o botão de permitir.
class _PermissionState extends StatelessWidget {
  final VoidCallback onRequest;

  const _PermissionState({required this.onRequest});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.video_library_outlined,
              size: 64,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text(
              'Para ver seus vídeos, o Audify precisa de acesso '
              'aos vídeos do aparelho.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRequest,
              icon: const Icon(Icons.lock_open_outlined),
              label: const Text('Permitir acesso aos vídeos'),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String message;

  const _EmptyState({required this.icon, required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 64,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}