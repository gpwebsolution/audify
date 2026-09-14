import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/song_model.dart';
import '../providers/player_provider.dart';
import '../providers/playlist_provider.dart';
import '../services/permission_service.dart';
import '../widgets/media_actions.dart';
import '../widgets/song_list_tile.dart';

/// Aba de Música: busca + biblioteca de faixas (aparelho + assets).
///
/// Responsabilidade: apresentação. Permissão, catálogo e reprodução são
/// orquestrados pelo [PlayerProvider]; aqui só há UI e feedback visual.
///
/// Organização: modo plano (Faixas) ou agrupado por Álbum/Artista/Pasta —
/// tocar uma faixa dentro de um grupo usa o grupo como fila.
class MusicScreen extends StatefulWidget {
  const MusicScreen({super.key});

  @override
  State<MusicScreen> createState() => _MusicScreenState();
}

enum _MusicGroupMode { tracks, album, artist, folder }

class _MusicScreenState extends State<MusicScreen> {
  final TextEditingController _searchController = TextEditingController();
  String? _lastShownError;
  _MusicGroupMode _groupMode = _MusicGroupMode.tracks;
  final Set<String> _collapsedGroups = {};

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final PlayerProvider provider = context.watch<PlayerProvider>();

    _handleErrorFeedback(provider);

    return Column(
      children: [
        // ---- Busca ----
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: TextField(
            controller: _searchController,
            onChanged: provider.setSearchQuery,
            decoration: InputDecoration(
              hintText: 'Buscar música, artista ou álbum',
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

        // ---- Modo de organização (chips) ----
        SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              for (final mode in _MusicGroupMode.values)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(_modeLabel(mode)),
                    selected: _groupMode == mode,
                    avatar: Icon(_modeIcon(mode), size: 18),
                    onSelected: (_) => setState(() {
                      _groupMode = mode;
                      _collapsedGroups.clear();
                    }),
                  ),
                ),
            ],
          ),
        ),

        // ---- Banner de permissão (quando negada/bloqueada) ----
        if (provider.permission == AudioPermissionState.denied ||
            provider.permission == AudioPermissionState.permanentlyDenied)
          _PermissionBanner(provider: provider),

        // ---- Lista de músicas (expande) ----
        Expanded(child: _buildBody(context, provider)),
      ],
    );
  }

  static String _modeLabel(_MusicGroupMode mode) {
    switch (mode) {
      case _MusicGroupMode.tracks:
        return 'Faixas';
      case _MusicGroupMode.album:
        return 'Álbum';
      case _MusicGroupMode.artist:
        return 'Artista';
      case _MusicGroupMode.folder:
        return 'Pasta';
    }
  }

  static IconData _modeIcon(_MusicGroupMode mode) {
    switch (mode) {
      case _MusicGroupMode.tracks:
        return Icons.music_note_outlined;
      case _MusicGroupMode.album:
        return Icons.album_outlined;
      case _MusicGroupMode.artist:
        return Icons.person_outline;
      case _MusicGroupMode.folder:
        return Icons.folder_outlined;
    }
  }

  /// Chave de agrupamento da faixa no modo atual.
  String _groupKeyOf(Song song) {
    switch (_groupMode) {
      case _MusicGroupMode.tracks:
        return '';
      case _MusicGroupMode.album:
        return song.album?.trim().isNotEmpty == true
            ? song.album!.trim()
            : 'Sem álbum';
      case _MusicGroupMode.artist:
        return song.displayArtist;
      case _MusicGroupMode.folder:
        final String? path = song.filePath;
        if (path == null || path.isEmpty) return 'Assets do app';
        final List<String> parts =
            path.split('/').where((s) => s.isNotEmpty).toList();
        return parts.length >= 2 ? parts[parts.length - 2] : '/';
    }
  }

  /// Exibe o erro do provider uma única vez (feedback visual, sem crash).
  void _handleErrorFeedback(PlayerProvider provider) {
    final String? error = provider.errorMessage;
    if (error != null && error != _lastShownError) {
      _lastShownError = error;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(error),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      });
    }
  }

  Widget _buildBody(BuildContext context, PlayerProvider provider) {
    if (provider.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (provider.visibleSongs.isEmpty) {
      return _buildEmptyState(context, provider);
    }

    if (_groupMode == _MusicGroupMode.tracks) {
      return ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: provider.visibleSongs.length,
        itemBuilder: (context, index) {
          final Song song = provider.visibleSongs[index];
          final bool isCurrent = provider.currentSong?.id == song.id;
          return SongListTile(
            song: song,
            isCurrent: isCurrent,
            isPlaying: isCurrent && provider.isPlaying,
            onTap: () => provider.playVisibleAt(index),
            onLongPress: () => _showSongMenu(context, provider, song),
          );
        },
      );
    }

    // ---- Modo agrupado (Álbum/Artista/Pasta) ----
    final LinkedHashMap<String, List<Song>> groups = LinkedHashMap();
    for (final Song song in provider.visibleSongs) {
      groups.putIfAbsent(_groupKeyOf(song), () => []).add(song);
    }
    final List<MapEntry<String, List<Song>>> sortedEntries = groups.entries
        .toList()
      ..sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase()));

    final List<Widget> sections = <Widget>[];
    for (final entry in sortedEntries) {
      final String key = entry.key;
      final List<Song> songs = entry.value;
      final bool collapsed = _collapsedGroups.contains(key);
      sections.add(_GroupHeader(
        icon: _modeIcon(_groupMode),
        title: key,
        count: songs.length,
        collapsed: collapsed,
        onToggle: () => setState(() {
          if (!collapsed) {
            _collapsedGroups.add(key);
          } else {
            _collapsedGroups.remove(key);
          }
        }),
        onPlayAll: () => provider.playQueue(songs, 0),
      ));
      if (!collapsed) {
        for (int i = 0; i < songs.length; i++) {
          final Song song = songs[i];
          final bool isCurrent = provider.currentSong?.id == song.id;
          sections.add(SongListTile(
            song: song,
            isCurrent: isCurrent,
            isPlaying: isCurrent && provider.isPlaying,
            // O grupo vira a fila: próxima/anterior navega dentro dele.
            onTap: () => provider.playQueue(songs, i),
            onLongPress: () => _showSongMenu(context, provider, song),
          ));
        }
      }
    }

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: sections,
    );
  }

  /// Menu por toque longo: compartilhar / excluir (músicas do aparelho)
  /// e adicionar à playlist.
  void _showSongMenu(
    BuildContext context,
    PlayerProvider provider,
    Song song,
  ) {
    showModalBottomSheet<void>(
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
                _pickPlaylist(context, song);
              },
            ),
            // Músicas do bundle (assets) não podem ser compartilhadas/
            // excluídas — fazem parte do APK.
            if (!song.isAsset && song.filePath != null) ...[
              ListTile(
                leading: const Icon(Icons.share_outlined),
                title: const Text('Compartilhar'),
                subtitle: const Text('WhatsApp, Messenger e outros'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  MediaActions.show(
                    context,
                    type: 'audio',
                    mediaId: song.mediaId,
                    filePath: song.filePath!,
                    shareName: '${song.title}.mp3',
                    shareMimeType: 'audio/mpeg',
                    onDeleted: () {
                      // Excluída do aparelho: sai de todas as playlists.
                      final PlaylistProvider playlists =
                          context.read<PlaylistProvider>();
                      playlists.removeSongFromAll(song);
                      provider.requestPermissionAndReload();
                    },
                  );
                },
              ),
            ],
            ListTile(
              leading: Icon(Icons.info_outline, color: Theme.of(context).colorScheme.onSurfaceVariant),
              title: Text('${song.title} • ${song.displayArtist}'),
              subtitle: song.album != null ? Text(song.album!) : null,
            ),
          ],
        ),
      ),
    );
  }

  /// Escolhe uma playlist para receber a faixa.
  void _pickPlaylist(BuildContext context, Song song) {
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
                subtitle: Text('${playlist.songCount} faixas'),
                onTap: () async {
                  await playlistProvider.addSong(playlist.id, song);
                  if (sheetContext.mounted) Navigator.pop(sheetContext);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Adicionada a "${playlist.name}"'),
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

  Widget _buildEmptyState(BuildContext context, PlayerProvider provider) {
    final bool noPermission =
        provider.permission != AudioPermissionState.granted;

    final String message = noPermission
        ? 'Permissão de acesso às músicas negada.\n'
            'Permita acima para ver as músicas do aparelho.'
        : (provider.songs.isEmpty
            ? 'Nenhuma música encontrada.\n'
                'Adicione arquivos .mp3 em assets/songs/ ou no aparelho.'
            : 'Nenhum resultado para "${provider.searchQuery}".');

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              noPermission
                  ? Icons.library_music_outlined
                  : Icons.search_off,
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

/// Cabeçalho de grupo (Álbum/Artista/Pasta): expande/recolhe e toca o
/// grupo inteiro.
class _GroupHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  final int count;
  final bool collapsed;
  final VoidCallback onToggle;
  final VoidCallback onPlayAll;

  const _GroupHeader({
    required this.icon,
    required this.title,
    required this.count,
    required this.collapsed,
    required this.onToggle,
    required this.onPlayAll,
  });

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;

    return ListTile(
      leading: Icon(icon, color: colors.primary),
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context)
            .textTheme
            .titleSmall
            ?.copyWith(fontWeight: FontWeight.w600),
      ),
      subtitle: Text('$count ${count == 1 ? 'faixa' : 'faixas'}'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Tocar grupo',
            icon: const Icon(Icons.play_circle_outline),
            onPressed: onPlayAll,
          ),
          AnimatedRotation(
            turns: collapsed ? -0.25 : 0,
            duration: const Duration(milliseconds: 150),
            child: IconButton(
              tooltip: collapsed ? 'Expandir' : 'Recolher',
              icon: const Icon(Icons.expand_more),
              onPressed: onToggle,
            ),
          ),
        ],
      ),
      onTap: onToggle,
    );
  }
}

/// Cartão de permissão negada com ação de nova tentativa / ajustes.
class _PermissionBanner extends StatelessWidget {
  final PlayerProvider provider;

  const _PermissionBanner({required this.provider});

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final bool permanent =
        provider.permission == AudioPermissionState.permanentlyDenied;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: colors.errorContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, color: colors.onErrorContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              permanent
                  ? 'Permissão bloqueada. Libere nas Configurações do '
                      'sistema para ver suas músicas.'
                  : 'Permita o acesso às músicas para ver sua biblioteca.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.onErrorContainer,
                  ),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: permanent
                ? PermissionService.openSettings
                : provider.requestPermissionAndReload,
            child: Text(permanent ? 'Abrir ajustes' : 'Permitir'),
          ),
        ],
      ),
    );
  }
}