import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../l10n/l10n.dart';
import '../models/media_ref.dart';
import '../models/song_model.dart';
import '../models/song_sort_key.dart';
import '../providers/player_provider.dart';
import '../providers/favorites_provider.dart';
import '../providers/playlist_provider.dart';
import '../services/permission_service.dart';
import '../widgets/media_actions.dart';
import '../widgets/group_header.dart';
import '../widgets/media_details_sheet.dart';
import '../widgets/playlist_picker_sheet.dart';
import '../widgets/permission_banner.dart';
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
    // Item 5.1: localizações capturadas antes de qualquer await.
    final AppLocalizations l10n = l10nOf(context);
    // O modelo decide: faixa de asset (ou sem id/caminho) não vira MediaRef
    // e nunca chega ao canal nativo.
    final MediaRef? ref = MediaRef.fromSong(song);
    if (ref == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.assetLockedMessage)));
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
}

/// Fatia do [PlayerProvider] exibida pela aba (item 2.1): um ÚNICO select
/// estrutural — a tela reconstrói apenas quando um destes valores muda.
/// Posição de reprodução não compõe a fatia: o progresso pertence ao mini
/// player e ao player em tela cheia (ValueListenableBuilder).
typedef _MusicView = ({
  bool isLoading,
  List<Song> songs,
  List<Song> visibleSongs,
  Song? currentSong,
  bool isPlaying,
  String searchQuery,
  AudioPermissionState permission,
  String? errorMessage,
  SongSortKey sortKey,
  bool sortAscending,
});

class _MusicScreenState extends State<MusicScreen> with MediaSelection<String> {
  final TextEditingController _searchController = TextEditingController();
  String? _lastShownError;
  MusicGroupMode _groupMode = MusicGroupMode.tracks;
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
      final AppLocalizations l10n = l10nOf(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.assetLockedMessage)),
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
          final AppLocalizations l10n = l10nOf(context);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l10n.skippedKept(skipped))),
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
    final AppLocalizations l10n = l10nOf(context);
    // Item 2.1: select explícito (não watch) — a lista reconstrói só
    // quando um destes valores muda. Tick de posição não está aqui e não
    // passa pelo notifyListeners do provider.
    final PlayerProvider provider = context.read<PlayerProvider>();
    final _MusicView view = context.select<PlayerProvider, _MusicView>(
      (PlayerProvider p) => (
        isLoading: p.isLoading,
        songs: p.songs,
        visibleSongs: p.visibleSongs,
        currentSong: p.currentSong,
        isPlaying: p.isPlaying,
        searchQuery: p.searchQuery,
        permission: p.permission,
        errorMessage: p.errorMessage,
        sortKey: p.sortKey,
        sortAscending: p.sortAscending,
      ),
    );

    _handleErrorFeedback(view.errorMessage);

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
              hintText: l10n.musicSearchHint,
              prefixIcon: const Icon(Icons.search),
              suffixIcon: view.searchQuery.isEmpty
                  ? null
                  : IconButton(
                      tooltip: l10n.clearSearchTooltip,
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
            label: l10n.selectedCount(selectionCount),
            onSelectAll: () =>
                toggleSelectAll(provider.visibleSongs.map((Song s) => s.id)),
            onClear: clearSelection,
            onDelete: () => deleteSelectedSongs(context, provider),
            actions: <SelectionAction>[
              // Item 3.5 — fila: lote inteiro entra na fila ativa de
              // uma vez (ordem da seleção); seleção limpa ao concluir.
              SelectionAction(
                icon: Icons.playlist_play,
                label: l10n.queuePlayNext,
                onPressed: () {
                  provider.queuePlayNext(
                    selectedFrom(provider.visibleSongs, (Song s) => s.id),
                  );
                  clearSelection();
                },
              ),
              SelectionAction(
                icon: Icons.queue_music,
                label: l10n.queueAppend,
                onPressed: () {
                  provider.queueAppend(
                    selectedFrom(provider.visibleSongs, (Song s) => s.id),
                  );
                  clearSelection();
                },
              ),
              SelectionAction(
                icon: Icons.share_outlined,
                label: l10n.shareSelected,
                onPressed: () => _shareSelected(context, provider),
              ),
              SelectionAction(
                icon: Icons.playlist_add,
                label: l10n.addToPlaylist,
                onPressed: () => _addSelectedToPlaylist(
                  context,
                  provider,
                  selectedFrom(provider.visibleSongs, (Song s) => s.id),
                ),
              ),
              SelectionAction(
                icon: Icons.swap_horiz,
                label: l10n.invertSelection,
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
                for (final mode in MusicGroupMode.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(_modeLabel(l10n, mode)),
                      selected: _groupMode == mode,
                      avatar: Icon(_modeIcon(mode), size: 18),
                      onSelected: (_) => setState(() {
                        _groupMode = mode;
                        _collapsedGroups.clear();
                      }),
                    ),
                  ),
                // Item 4.3 — ordenação escolhível: critério (item
                // marcado) + sentido, junto com os chips de agrupamento.
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: PopupMenuButton<({SongSortKey? key, bool? toggleDirection})>(
                    tooltip: l10n.sortTooltip,
                    icon: const Icon(Icons.sort),
                    itemBuilder: (BuildContext menuContext) => <PopupMenuEntry<
                        ({SongSortKey? key, bool? toggleDirection})>>[
                      for (final SongSortKey key in SongSortKey.values)
                        CheckedPopupMenuItem(
                          value: (key: key, toggleDirection: null),
                          checked: view.sortKey == key,
                          child: Text(_sortKeyLabel(l10n, key)),
                        ),
                      const PopupMenuDivider(),
                      PopupMenuItem(
                        value: (key: null, toggleDirection: true),
                        child: Text(
                          view.sortAscending
                              ? l10n.sortDescendingOption
                              : l10n.sortAscendingOption,
                        ),
                      ),
                    ],
                    onSelected: (
                      ({SongSortKey? key, bool? toggleDirection}) value,
                    ) {
                      if (value.toggleDirection == true) {
                        provider.setSort(
                          key: view.sortKey,
                          ascending: !view.sortAscending,
                        );
                      } else if (value.key != null) {
                        provider.setSort(
                          key: value.key!,
                          ascending: view.sortAscending,
                        );
                      }
                    },
                  ),
                ),
              ],
            ),
          ),
        ),

        // ---- Banner de permissão (quando negada/bloqueada) ----
        if (view.permission == AudioPermissionState.denied ||
            view.permission == AudioPermissionState.permanentlyDenied)
          PermissionBanner(provider: provider),

        // ---- Lista de músicas (expande) + pull-to-refresh (item 2.4) ----
        Expanded(
          child: RefreshIndicator(
            onRefresh: provider.rescanCatalog,
            child: _buildBody(context, provider, view),
          ),
        ),
      ],
    );
  }

  static String _modeLabel(AppLocalizations l10n, MusicGroupMode mode) {
    switch (mode) {
      case MusicGroupMode.tracks:
        return l10n.groupTracks;
      case MusicGroupMode.album:
        return l10n.groupAlbum;
      case MusicGroupMode.artist:
        return l10n.groupArtist;
      case MusicGroupMode.folder:
        return l10n.groupFolder;
    }
  }

  /// Rótulo do critério de ordenação no menu (item 5.1: as chaves
  /// `sortKey*` substituem o antigo label pronto no enum).
  static String _sortKeyLabel(AppLocalizations l10n, SongSortKey key) {
    switch (key) {
      case SongSortKey.title:
        return l10n.sortKeyTitle;
      case SongSortKey.artist:
        return l10n.sortKeyArtist;
      case SongSortKey.album:
        return l10n.sortKeyAlbum;
      case SongSortKey.dateAdded:
        return l10n.sortKeyDateAdded;
      case SongSortKey.duration:
        return l10n.sortKeyDuration;
      case SongSortKey.mostPlayed:
        return l10n.sortKeyMostPlayed;
    }
  }

  static IconData _modeIcon(MusicGroupMode mode) {
    switch (mode) {
      case MusicGroupMode.tracks:
        return Icons.music_note_outlined;
      case MusicGroupMode.album:
        return Icons.album_outlined;
      case MusicGroupMode.artist:
        return Icons.person_outline;
      case MusicGroupMode.folder:
        return Icons.folder_outlined;
    }
  }

  /// Exibe o erro do provider uma única vez (feedback visual, sem crash).
  ///
  /// Recebe o valor já selecionado ([_MusicView.errorMessage]) — este
  /// widget não assina o provider por conta própria (item 2.1).
  void _handleErrorFeedback(String? error) {
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

  Widget _buildBody(
    BuildContext context,
    PlayerProvider provider,
    _MusicView view,
  ) {
    if (view.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (view.visibleSongs.isEmpty) {
      return _buildEmptyState(context, provider, view);
    }

    if (_groupMode == MusicGroupMode.tracks) {
      return ListView.builder(
        // Sempre rolável (item 2.4): lista curta/esticada ainda
        // deixa puxar para atualizar (RefreshIndicator acima).
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: view.visibleSongs.length,
        itemBuilder: (context, index) {
          final Song song = view.visibleSongs[index];
          final bool isCurrent = view.currentSong?.id == song.id;
          final bool marked = isSelected(song.id);
          // Item 4.1: o coração assiste ao singleton (sem provider no
          // grafo) e só reconstrói o tile alterado, não a lista inteira.
          return ListenableBuilder(
            listenable: FavoritesProvider.instance,
            builder: (context, _) => SongListTile(
              song: song,
              isCurrent: isCurrent,
              isPlaying: isCurrent && view.isPlaying,
              selected: marked,
              selectionMode: isSelectionMode,
              isFavorite: FavoritesProvider.instance.isFavorite(song.id),
              onFavoriteToggle: () =>
                  FavoritesProvider.instance.toggle(song),
              onTap: () => _onSongTap(provider, index, song),
              onLongPress: () => _onSongLongPress(song),
              onMenuTap: () => _showSongMenu(context, provider, song),
            ),
          );
        },
      );
    }

    // ---- Modo agrupado (Álbum/Artista/Pasta) — item 2.2 ----
    // Agrupamento memoizado no provider (recalcula só quando mudam
    // catálogo, busca ou modo); aqui só se ACHATA em linhas (cabeçalho +
    // faixas dos grupos expandidos) e renderiza com ListView.builder —
    // a árvore só materializa a viewport, não os milhares de tiles.
    final List<SongGroup> groups = provider.visibleGroups(_groupMode);
    final List<GroupRow> rows = <GroupRow>[];
    for (final SongGroup group in groups) {
      rows.add(GroupRow.header(group));
      if (_collapsedGroups.contains(group.key)) continue;
      for (int i = 0; i < group.songs.length; i++) {
        rows.add(GroupRow.item(group, i));
      }
    }

    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: rows.length,
      itemBuilder: (context, index) {
        final GroupRow row = rows[index];
        if (row.indexInGroup < 0) {
          // Cabeçalho: expandir/recolher + "tocar grupo".
          final SongGroup group = row.group;
          final bool collapsed = _collapsedGroups.contains(group.key);
          return GroupHeader(
            icon: _modeIcon(_groupMode),
            title: group.key,
            count: group.songs.length,
            collapsed: collapsed,
            onToggle: () => setState(() {
              if (!collapsed) {
                _collapsedGroups.add(group.key);
              } else {
                _collapsedGroups.remove(group.key);
              }
            }),
            onPlayAll: () => provider.playQueue(group.songs, 0),
          );
        }
        final Song song = row.group.songs[row.indexInGroup];
        final bool isCurrent = view.currentSong?.id == song.id;
        return ListenableBuilder(
          listenable: FavoritesProvider.instance,
          builder: (context, _) => SongListTile(
            song: song,
            isCurrent: isCurrent,
            isPlaying: isCurrent && view.isPlaying,
            selected: isSelected(song.id),
            selectionMode: isSelectionMode,
            isFavorite: FavoritesProvider.instance.isFavorite(song.id),
            onFavoriteToggle: () =>
                FavoritesProvider.instance.toggle(song),
            // O grupo vira a fila: próxima/anterior navega dentro dele.
            onTap: () => isSelectionMode
                ? toggleSelect(song.id)
                : provider.playQueue(row.group.songs, row.indexInGroup),
            onLongPress: () => _onSongLongPress(song),
            onMenuTap: () => _showSongMenu(context, provider, song),
          ),
        );
      },
    );
  }

  /// Menu por toque longo: adicionar à playlist, compartilhar, excluir.
  void _showSongMenu(BuildContext context, PlayerProvider provider, Song song) {
    // Mesma regra do modelo: o que não vira MediaRef não é excluível (faixa
    // embutida no APK, ou faixa sem id/caminho para localizar no aparelho).
    final bool isAsset = MediaRef.fromSong(song) == null;
    // Item 4.1 — estado do coração LIDO na abertura do menu (o menu
    // fecha no toggle; o coração do tile já mostra o resultado).
    final FavoritesProvider favorites = FavoritesProvider.instance;
    final bool isFav = favorites.isFavorite(song.id);

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        final AppLocalizations l10n = l10nOf(sheetContext);
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              // Item 3.5 — fila de reprodução: entram na fila ATIVA
              // (ordem que o player segue), não na lista exibida.
              ListTile(
                leading: const Icon(Icons.playlist_play),
                title: Text(l10n.queuePlayNext),
                onTap: () {
                  Navigator.pop(sheetContext);
                  provider.queuePlayNext([song]);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(l10n.addedUpNext(song.title))),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.queue_music),
                title: Text(l10n.queueAppend),
                onTap: () {
                  Navigator.pop(sheetContext);
                  provider.queueAppend([song]);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(l10n.addedInQueue(song.title))),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.playlist_add),
                title: Text(l10n.addToPlaylist),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _pickPlaylist(context, song);
                },
              ),
              // Item 4.1 — favoritar pelo menu (mesmo efeito do coração
              // do tile, para quem chegou por aqui).
              ListTile(
                leading: Icon(
                  isFav ? Icons.favorite : Icons.favorite_border,
                  color: isFav
                      ? Theme.of(context).colorScheme.error
                      : null,
                ),
                title: Text(isFav ? l10n.unfavorite : l10n.favorite),
                subtitle: isFav
                    ? Text(l10n.favoriteOffSub)
                    : Text(l10n.favoriteOnSub),
                onTap: () {
                  Navigator.pop(sheetContext);
                  favorites.toggle(song);
                },
              ),
              if (!isAsset) ...[
                ListTile(
                  leading: const Icon(Icons.share_outlined),
                  title: Text(l10n.share),
                  subtitle: Text(l10n.shareApps),
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
                    l10n.deleteFromDevice,
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                  subtitle: Text(
                    l10n.deleteSubtitle(song.title),
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
                    l10n.deleteFromDevice,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.outline,
                    ),
                  ),
                  subtitle: Text(l10n.assetLockedMessage),
                  onTap: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(l10n.assetLockedMessage),
                      ),
                    );
                  },
                ),
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: Text(l10n.details),
                subtitle: Text('${song.title} • ${song.displayArtist}'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  MediaDetailsSheet.showSong(context, song);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  /// Escolhe uma playlist para receber a faixa.
  /// Item 4.4 — seletor com "Nova playlist" embutida: cria no lugar e
  /// a recém-criada já recebe a faixa.
  void _pickPlaylist(BuildContext context, Song song) {
    final PlaylistProvider playlistProvider = context.read<PlaylistProvider>();
    showPlaylistPickerSheet(
      context,
      onPick: (Playlist playlist) async {
        await playlistProvider.addSong(playlist.id, song);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l10nOf(context).addedToPlaylist(playlist.name)),
            ),
          );
        }
      },
      subtitleOf: (Playlist playlist) =>
          l10nOf(context).tracksCount(playlist.songCount),
    );
  }

  /// Escolhe uma playlist para várias músicas de uma vez (modo seleção).
  ///
  /// Item 4.4: a folha vem com "Nova playlist" — mesmo sem nenhuma
  /// criada o lote não esbarra em aviso de "crie na aba Playlists".
  ///
  /// Um único add por música no banco. Se alguma falhar, o contador de erro
  /// diz quantas entraram de fato em vez de mentir "N adicionadas".
  Future<void> _pickPlaylistForMany(
    BuildContext context,
    PlaylistProvider playlistProvider,
    List<Song> songs,
  ) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    await showPlaylistPickerSheet(
      context,
      onPick: (Playlist playlist) async {
        // Uma transação + um reload (antes: um insert e uma query de
        // posição por faixa, e a contagem da playlist ficava errada).
        final int added = await playlistProvider.addSongsToPlaylist(
          playlist.id,
          songs,
        );
        if (mounted) clearSelection();
        if (!messenger.mounted) return;
        final AppLocalizations l10n = l10nOf(messenger.context);
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              added == songs.length
                  ? l10n.addedManyToPlaylist(songs.length, playlist.name)
                  : l10n.addedPartialToPlaylist(
                      added,
                      songs.length,
                      playlist.name,
                    ),
            ),
          ),
        );
      },
        subtitleOf: (Playlist playlist) =>
            l10nOf(context).tracksCount(playlist.songCount),
      );
  }

  Widget _buildEmptyState(
    BuildContext context,
    PlayerProvider provider,
    _MusicView view,
  ) {
    final AppLocalizations l10n = l10nOf(context);
    final bool noPermission = view.permission != AudioPermissionState.granted;
    final bool permanent =
        view.permission == AudioPermissionState.permanentlyDenied;

    final String message = noPermission
        ? l10n.emptyPermissionDenied
        : (view.songs.isEmpty
              ? l10n.emptyNoMusic
              : l10n.emptyNoResults(view.searchQuery));

    // Item 5.3 — uma ação clara por estado: permissão pedida/levada às
    // ajustes, catálogo vazio atualizado, busca sem resultado limpa.
    final Widget? action = noPermission
        ? TextButton(
            onPressed: permanent
                ? PermissionService.openSettings
                : provider.requestPermissionAndReload,
            child: Text(permanent ? l10n.openSettingsBtn : l10n.allowBtn),
          )
        : view.songs.isEmpty
        ? FilledButton.tonal(
            onPressed: provider.rescanCatalog,
            child: Text(l10n.rescanBtn),
          )
        : view.searchQuery.isNotEmpty
        ? TextButton(
            onPressed: () => provider.setSearchQuery(''),
            child: Text(l10n.clearSearchTooltip),
          )
        : null;

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
            if (action != null) ...<Widget>[
              const SizedBox(height: 16),
              action,
            ],
          ],
        ),
      ),
    );
  }
}
