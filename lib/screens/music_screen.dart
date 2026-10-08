import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/media_ref.dart';
import '../models/song_model.dart';
import '../providers/player_provider.dart';
import '../providers/playlist_provider.dart';
import '../services/permission_service.dart';
import '../widgets/media_actions.dart';
import '../widgets/media_details_sheet.dart';
import '../widgets/selection_bar.dart';
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

  /// Exclui uma música do aparelho e limpa catálogo, fila, sessão e
  /// playlists.
  ///
  /// Estático para ser reusado pelo player em tela cheia
  /// ([PlayerScreen] tem o mesmo fluxo) sem duplicar a lógica.
  static Future<void> deleteSong(
    BuildContext context,
    PlayerProvider provider,
    Song song,
  ) async {
    // O modelo decide: faixa de asset (ou sem id/caminho) não vira MediaRef
    // e nunca chega ao canal nativo.
    final MediaRef? ref = MediaRef.fromSong(song);
    if (ref == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text(assetLockedMessage)));
      return;
    }

    // Provider lido antes de qualquer await: nada de segurar BuildContext
    // através de lacuna assíncrona.
    final PlaylistProvider playlists = context.read<PlaylistProvider>();

    // Índice da faixa em reprodução ANTES de qualquer mudança, para poder
    // retomar caso o usuário desista da exclusão.
    final bool wasPlaying = provider.currentSong?.id == song.id;
    int? resumeIndex;
    if (wasPlaying) {
      resumeIndex = provider.visibleSongs.indexWhere(
        (Song s) => s.id == song.id,
      );
    }

    await MediaActions.confirmDelete(
      context,
      ref,
      label: song.title,
      // O handle de áudio é liberado ANTES de pedir a exclusão: arquivo em
      // uso pode sobreviver à remoção sem nenhum erro visível. Se o usuário
      // cancelar, a reprodução é retomada abaixo.
      onBeforeDelete: () async {
        if (wasPlaying) await provider.stop();
      },
      onDeleted: (List<MediaRef> _) async {
        // Excluída do aparelho: sai de todas as playlists.
        await playlists.removeSongsFromAll(<Song>[song]);
        await provider.handleSongsDeleted(<Song>[song]);
      },
    );

    // Nada foi excluído (cancelou no app ou no diálogo do SO) e a faixa que
    // tocava continua no aparelho: volta a reproduzir.
    final bool stillThere = provider.songs.any((Song s) => s.id == song.id);
    if (wasPlaying && stillThere && resumeIndex != null && resumeIndex >= 0) {
      final int target = provider.visibleSongs.indexWhere(
        (Song s) => s.id == song.id,
      );
      if (target >= 0) await provider.playVisibleAt(target);
    }
  }

  /// Motivo exibido quando a faixa não está no aparelho (é do próprio APK).
  static const String assetLockedMessage =
      'Faixa embutida no app, não pode ser excluída.';
}

enum _MusicGroupMode { tracks, album, artist, folder }

class _MusicScreenState extends State<MusicScreen> with MediaSelection<String> {
  final TextEditingController _searchController = TextEditingController();
  String? _lastShownError;
  _MusicGroupMode _groupMode = _MusicGroupMode.tracks;
  final Set<String> _collapsedGroups = {};

  @override
  void notifyChanged() => setState(() {});

  /// Long-press alterna entre "abrir menu" e "marcar para o lote".
  ///
  /// Com o modo seleção já ligado, o long-press continua marcando/desmarcando
  /// Long-press ENTRA no modo seleção e marca a faixa.
  ///
  /// Deliberadamente NÃO abre o menu de ações: o mesmo gesto já marcava só
  /// depois de um segundo toque longo (o primeiro abria o menu), o que
  /// impedia montar uma seleção de várias músicas. As ações por item ficam no
  /// botão de menu do tile ([SongListTile.onMenuTap]).
  void _onSongLongPress(Song song) => toggleSelect(song.id);

  /// Toque no item: no modo seleção marca/desmarca; fora dele, reproduz.
  void _onSongTap(PlayerProvider provider, int index, Song song) {
    if (isSelectionMode) {
      toggleSelect(song.id);
      return;
    }
    provider.playVisibleAt(index);
  }

  /// Exclui as músicas marcadas do aparelho com UM único diálogo do sistema.
  ///
  /// Faixa embutida no app não é arquivo do aparelho e é filtrada antes de
  /// qualquer chamada nativa, com o motivo informado na SnackBar.
  Future<void> deleteSelectedSongs(
    BuildContext context,
    PlayerProvider provider,
  ) async {
    final List<Song> songs = selectedFrom(
      provider.visibleSongs,
      (Song s) => s.id,
    );
    if (songs.isEmpty) {
      clearSelection();
      return;
    }

    final List<Song> deletable = <Song>[
      for (final Song s in songs)
        if (MediaRef.fromSong(s) != null) s,
    ];
    final int skipped = songs.length - deletable.length;

    if (deletable.isEmpty) {
      clearSelection();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(MusicScreen.assetLockedMessage)),
      );
      return;
    }

    if (!context.mounted) return;

    final PlaylistProvider playlists = context.read<PlaylistProvider>();
    await MediaActions.confirmDeleteMany(
      context,
      <MediaRef>[for (final Song s in deletable) MediaRef.fromSong(s)!],
      onDeleted: (List<MediaRef> removed) async {
        // Limpa SÓ depois da confirmação: cancelar não pode custar ao
        // usuário a seleção inteira de uma vez.
        clearSelection();
        // Usa as chaves devolvidas pelo nativo (excluídas + ausentes) para
        // não limpar estado de uma faixa que na verdade ficou no aparelho.
        final Set<String> goneKeys = removed.map((MediaRef r) => r.key).toSet();
        final List<Song> gone = <Song>[
          for (final Song s in deletable)
            if (goneKeys.contains(MediaRef.fromSong(s)!.key)) s,
        ];
        if (gone.isEmpty) return;
        await playlists.removeSongsFromAll(gone);
        await provider.handleSongsDeleted(gone);
        if (!context.mounted) return;
        if (skipped > 0) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '$skipped ${skipped == 1 ? 'faixa embutida' : 'faixas embutidas'} '
                'no app ${skipped == 1 ? 'foi mantida' : 'foram mantidas'}.',
              ),
            ),
          );
        }
      },
    );
  }

  /// Compartilha as músicas marcadas num único diálogo do sistema.
  void _shareSelected(BuildContext context, PlayerProvider provider) {
    final List<Song> songs = selectedFrom(
      provider.visibleSongs,
      (Song s) => s.id,
    );
    if (songs.isEmpty) return;
    MediaActions.shareMany(context, <MediaRef>[
      for (final Song song in songs)
        if (MediaRef.fromSong(song) case final MediaRef ref) ref,
    ]);
  }

  /// Adiciona as músicas marcadas a uma playlist escolhida pelo usuário.
  ///
  /// Uma única folha de escolha para o lote inteiro (em vez de uma por música)
  /// e o item permanece marcado para permitir adicionar a outra playlist em
  /// seguida.
  Future<void> _addSelectedToPlaylist(
    BuildContext context,
    PlayerProvider provider,
    List<Song> songs,
  ) async {
    if (songs.isEmpty) {
      clearSelection();
      return;
    }
    final PlaylistProvider playlists = context.read<PlaylistProvider>();
    await _pickPlaylistForMany(context, playlists, songs);
  }

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
            onChanged: (String value) {
              provider.setSearchQuery(value);
              // O universo de itens mudou: manter a marcação deixaria a barra
              // anunciando N com o lote agindo sobre menos itens (a busca
              // filtra a lista). Mesmo padrão de "limpar ao mudar o universo".
              if (isSelectionMode) clearSelection();
            },
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

        // ---- Chips de organização / barra de seleção em lote ----
        // No modo seleção os chips somem e entram as ações de lote, com
        // animação de troca em vez de corte seco.
        AnimatedToolbarSwap(
          value: isSelectionMode,
          selectionBar: SelectionBar(
            label: '$selectionCount selecionada(s)',
            onSelectAll: () =>
                toggleSelectAll(provider.visibleSongs.map((Song s) => s.id)),
            onClear: clearSelection,
            onDelete: () => deleteSelectedSongs(context, provider),
            actions: <SelectionAction>[
              SelectionAction(
                icon: Icons.share_outlined,
                label: 'Compartilhar selecionadas',
                onPressed: () => _shareSelected(context, provider),
              ),
              SelectionAction(
                icon: Icons.playlist_add,
                label: 'Adicionar à playlist',
                onPressed: () => _addSelectedToPlaylist(
                  context,
                  provider,
                  selectedFrom(provider.visibleSongs, (Song s) => s.id),
                ),
              ),
              SelectionAction(
                icon: Icons.swap_horiz,
                label: 'Inverter seleção',
                onPressed: () => invertSelection(
                  provider.visibleSongs.map((Song s) => s.id),
                ),
              ),
            ],
          ),
          toolbar: SizedBox(
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
        final List<String> parts = path
            .split('/')
            .where((s) => s.isNotEmpty)
            .toList();
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
          final bool marked = isSelected(song.id);
          return SongListTile(
            song: song,
            isCurrent: isCurrent,
            isPlaying: isCurrent && provider.isPlaying,
            selected: marked,
            selectionMode: isSelectionMode,
            onTap: () => _onSongTap(provider, index, song),
            onLongPress: () => _onSongLongPress(song),
            onMenuTap: () => _showSongMenu(context, provider, song),
          );
        },
      );
    }

    // ---- Modo agrupado (Álbum/Artista/Pasta) ----
    final LinkedHashMap<String, List<Song>> groups = LinkedHashMap();
    for (final Song song in provider.visibleSongs) {
      groups.putIfAbsent(_groupKeyOf(song), () => []).add(song);
    }
    final List<MapEntry<String, List<Song>>> sortedEntries =
        groups.entries.toList()
          ..sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase()));

    final List<Widget> sections = <Widget>[];
    for (final entry in sortedEntries) {
      final String key = entry.key;
      final List<Song> songs = entry.value;
      final bool collapsed = _collapsedGroups.contains(key);
      sections.add(
        _GroupHeader(
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
        ),
      );
      if (!collapsed) {
        for (int i = 0; i < songs.length; i++) {
          final Song song = songs[i];
          final bool isCurrent = provider.currentSong?.id == song.id;
          sections.add(
            SongListTile(
              song: song,
              isCurrent: isCurrent,
              isPlaying: isCurrent && provider.isPlaying,
              selected: isSelected(song.id),
              selectionMode: isSelectionMode,
              // O grupo vira a fila: próxima/anterior navega dentro dele.
              onTap: () => isSelectionMode
                  ? toggleSelect(song.id)
                  : provider.playQueue(songs, i),
              onLongPress: () => _onSongLongPress(song),
              onMenuTap: () => _showSongMenu(context, provider, song),
            ),
          );
        }
      }
    }

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: sections,
    );
  }

  /// Menu por toque longo: adicionar à playlist, compartilhar, excluir.
  void _showSongMenu(BuildContext context, PlayerProvider provider, Song song) {
    // Mesma regra do modelo: o que não vira MediaRef não é excluível (faixa
    // embutida no APK, ou faixa sem id/caminho para localizar no aparelho).
    final bool isAsset = MediaRef.fromSong(song) == null;

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
            if (!isAsset) ...[
              ListTile(
                leading: const Icon(Icons.share_outlined),
                title: const Text('Compartilhar'),
                subtitle: const Text('WhatsApp, Messenger e outros'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  // Compartilhamento direto: a exclusão já tem item
                  // próprio neste menu, não precisa aninhar outro sheet.
                  // `filePath` pode ser nulo mesmo para faixa do aparelho
                  // (metadado ausente ao vir do banco), então o serviço
                  // decide — não um `!` que estoura null-check em silêncio.
                  MediaActions.share(
                    context,
                    path: song.filePath ?? '',
                    name: '${song.title}.mp3',
                    mimeType: 'audio/mpeg',
                  );
                },
              ),
              ListTile(
                leading: Icon(
                  Icons.delete_outline,
                  color: Theme.of(context).colorScheme.error,
                ),
                title: Text(
                  'Excluir do aparelho',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                subtitle: Text(
                  '${song.title} • o Android pedirá confirmação',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () async {
                  Navigator.pop(sheetContext);
                  await MusicScreen.deleteSong(context, provider, song);
                },
              ),
            ] else
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
                subtitle: const Text(MusicScreen.assetLockedMessage),
                onTap: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(MusicScreen.assetLockedMessage),
                    ),
                  );
                },
              ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('Detalhes'),
              subtitle: Text('${song.title} • ${song.displayArtist}'),
              onTap: () {
                Navigator.pop(sheetContext);
                MediaDetailsSheet.showSong(context, song);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// Escolhe uma playlist para receber a faixa.
  void _pickPlaylist(BuildContext context, Song song) {
    final PlaylistProvider playlistProvider = context.read<PlaylistProvider>();
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

  /// Escolhe uma playlist para várias músicas de uma vez (modo seleção).
  ///
  /// Um único add por música no banco. Se alguma falhar, o contador de erro
  /// diz quantas entraram de fato em vez de mentir "N adicionadas".
  Future<void> _pickPlaylistForMany(
    BuildContext context,
    PlaylistProvider playlistProvider,
    List<Song> songs,
  ) async {
    if (playlistProvider.playlists.isEmpty) {
      clearSelection();
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Nenhuma playlist ainda. Crie uma na aba Playlists.'),
        ),
      );
      return;
    }

    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: playlistProvider.playlists.length,
          itemBuilder: (BuildContext _, int index) {
            final playlist = playlistProvider.playlists[index];
            return ListTile(
              leading: const Icon(Icons.queue_music),
              title: Text(playlist.name),
              subtitle: Text('${playlist.songCount} faixas'),
              onTap: () async {
                // Uma transação + um reload (antes: um insert e uma query de
                // posição por faixa, e a contagem da playlist ficava errada).
                final int added = await playlistProvider.addSongsToPlaylist(
                  playlist.id,
                  songs,
                );
                if (sheetContext.mounted) Navigator.pop(sheetContext);
                clearSelection();
                messenger.showSnackBar(
                  SnackBar(
                    content: Text(
                      added == songs.length
                          ? '${songs.length} adicionadas a "${playlist.name}"'
                          : '$added de ${songs.length} adicionadas a '
                                '"${playlist.name}"',
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
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
              noPermission ? Icons.library_music_outlined : Icons.search_off,
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
        style: Theme.of(
          context,
        ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
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
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.onErrorContainer),
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
