import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/media_ref.dart';
import '../models/video_model.dart';
import '../providers/playlist_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/video_provider.dart';
import '../services/video_query_service.dart';
import '../utils/format.dart';
import '../utils/motion.dart';
import '../widgets/media_actions.dart';
import '../widgets/grid_zoom.dart';
import '../widgets/selection_bar.dart';
import 'video_player_screen.dart';

/// Aba de Vídeos: biblioteca de vídeos do aparelho (MediaStore).
class VideosScreen extends StatefulWidget {
  const VideosScreen({super.key});

  @override
  State<VideosScreen> createState() => _VideosScreenState();

  /// Exclui um vídeo do aparelho e limpa TODOS os estados que o referenciam:
  /// lista, playlists, miniaturas e a fila do player de vídeo.
  ///
  /// Estático para ser reusado pelo player em tela cheia
  /// ([VideoPlayerScreen] tem o mesmo fluxo) sem duplicar a lógica.
  ///
  /// [onBeforeDelete] existe para o player liberar o VideoPlayerController
  /// ANTES da exclusão — com o decoder aberto o arquivo fica travado e a
  /// remoção falha.
  ///
  /// [onDeleted] só é chamado quando o arquivo saiu de fato do aparelho, o
  /// que permite ao caller reagir (sair da tela, tirar da fila) sem tratar
  /// cancelamento como exclusão.
  static Future<void> deleteVideo(
    BuildContext context,
    VideoProvider provider,
    Video video, {
    Future<void> Function()? onBeforeDelete,
    Future<void> Function(List<MediaRef> removed)? onDeleted,
  }) async {
    // O provider de playlists é lido ANTES de qualquer await: evita
    // segurar BuildContext através de uma lacuna assíncrona.
    final PlaylistProvider playlists = context.read<PlaylistProvider>();
    await MediaActions.confirmDelete(
      context,
      MediaRef.fromVideo(video),
      label: video.displayTitle,
      // O decoder é liberado depois do "Excluir" e ANTES da chamada nativa:
      // com o arquivo aberto pelo video_player o SO não consegue removê-lo.
      // Antes do diálogo, o vídeo congelava na tela enquanto o usuário
      // decidia — desnecessário, já que ele podia desistir.
      onBeforeDelete: onBeforeDelete,
      onDeleted: (List<MediaRef> removed) async {
        await playlists.removeVideosFromAll(<Video>[video]);
        await provider.handleVideosDeleted(<Video>[video]);
        await onDeleted?.call(removed);
      },
    );
  }
}

class _VideosScreenState extends State<VideosScreen> with MediaSelection<int> {
  final TextEditingController _searchController = TextEditingController();

  /// Padding da grade. Usado tanto no GridView quanto no cálculo das colunas
  /// efetivas — se divergirem, o usuário pede 6 e a tela mostra 6 colunas
  /// apertadas contra a borda.
  static const EdgeInsets _gridPadding = EdgeInsets.all(12);

  @override
  void notifyChanged() => setState(() {});

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Campo de busca da aba de Vídeos.
  Widget _searchField(VideoProvider provider) {
    return TextField(
      controller: _searchController,
      onChanged: (String value) {
        provider.setSearchQuery(value);
        // O universo mudou: manter a marcação faria a barra prometer N e o
        // SO agir sobre menos.
        if (isSelectionMode) clearSelection();
      },
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
    );
  }

  @override
  Widget build(BuildContext context) {
    final VideoProvider provider = context.watch<VideoProvider>();
    final SettingsProvider settings = context.watch<SettingsProvider>();
    // Mostrado no botão de zoom: o número efetivo, para o usuário ver que
    // pediu 10 e a tela comportou 6.
    final double available =
        MediaQuery.sizeOf(context).width - _gridPadding.horizontal;
    final int effective = settings.effectiveColumns(
      settings.videoColumns,
      available,
    );

    return Column(
      children: [
        // ---- Busca + zoom da grade ----
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
          child: Row(
            children: <Widget>[
              Expanded(child: _searchField(provider)),
              GridZoomButton(
                label: 'Vídeos',
                columns: settings.videoColumns,
                effectiveColumns: effective,
                onChanged: settings.setVideoColumns,
              ),
            ],
          ),
        ),
        // ---- Barra de ações em lote (modo seleção) ----
        AnimatedToolbarSwap(
          value: isSelectionMode,
          selectionBar: SelectionBar(
            label: '$selectionCount selecionado(s)',
            onSelectAll: () =>
                toggleSelectAll(provider.visibleVideos.map((Video v) => v.id)),
            onClear: clearSelection,
            onDelete: () => deleteSelectedVideos(context, provider),
            actions: <SelectionAction>[
              SelectionAction(
                icon: Icons.share_outlined,
                label: 'Compartilhar selecionados',
                onPressed: () => _shareSelected(context, provider),
              ),
              SelectionAction(
                icon: Icons.playlist_add,
                label: 'Adicionar à playlist',
                onPressed: () => _addSelectedToPlaylist(
                  context,
                  provider,
                  selectedFrom(provider.visibleVideos, (Video v) => v.id),
                ),
              ),
              SelectionAction(
                icon: Icons.swap_horiz,
                label: 'Inverter seleção',
                onPressed: () => invertSelection(
                  provider.visibleVideos.map((Video v) => v.id),
                ),
              ),
            ],
          ),
          toolbar: const SizedBox.shrink(),
        ),

        Expanded(child: _buildBody(context, provider)),
      ],
    );
  }

  Widget _buildBody(BuildContext context, VideoProvider provider) {
    // Recalculado aqui porque _buildBody é chamado do build, mas é um método
    // separado: ler direto da SettingsProvider evita depender de o campo
    // mutável estar sincronizado.
    final SettingsProvider settings = context.watch<SettingsProvider>();
    final double available =
        MediaQuery.sizeOf(context).width - _gridPadding.horizontal;
    final int columns = settings.effectiveColumns(
      settings.videoColumns,
      available,
    );
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
      return _PermissionState(onRequest: () => provider.requestAccess());
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
      padding: _gridPadding,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        // Com mais colunas o tile fica mais baixo proporcionalmente: a
        // miniatura 16:9 encolhe, mas o texto continua cabendo em 2 linhas.
        childAspectRatio: columns >= 5 ? 0.66 : 0.78,
      ),
      itemCount: provider.visibleVideos.length,
      itemBuilder: (context, index) {
        final Video video = provider.visibleVideos[index];
        return _VideoCard(
          video: video,
          selected: isSelected(video.id),
          selectionMode: isSelectionMode,
          onTap: () {
            if (isSelectionMode) {
              toggleSelect(video.id);
              return;
            }
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => VideoPlayerScreen(
                  queue: provider.visibleVideos,
                  initialIndex: index,
                ),
              ),
            );
          },
          // Long-press marca para o lote. As ações ficam no player em tela
          // cheia (toque normal abre), pelo mesmo motivo da Galeria: com 10
          // colunas o card tem ~36dp e um botão de 48dp sobre a miniatura
          // cobria metade da imagem.
          onLongPress: () => toggleSelect(video.id),
        );
      },
    );
  }

  /// Menu de ações do vídeo: adicionar à playlist / compartilhar / excluir.
  /// Exclui os vídeos marcados do aparelho com UM único diálogo do sistema.
  Future<void> deleteSelectedVideos(
    BuildContext context,
    VideoProvider provider,
  ) async {
    final List<Video> videos = selectedFrom(
      provider.visibleVideos,
      (Video v) => v.id,
    );
    if (videos.isEmpty) {
      clearSelection();
      return;
    }
    if (!context.mounted) return;

    final PlaylistProvider playlists = context.read<PlaylistProvider>();
    await MediaActions.confirmDeleteMany(
      context,
      <MediaRef>[for (final Video v in videos) MediaRef.fromVideo(v)],
      onDeleted: (List<MediaRef> removed) async {
        // Só depois de confirmar: cancelar preserva a seleção.
        clearSelection();
        final Set<String> goneKeys = removed.map((MediaRef r) => r.key).toSet();
        final List<Video> gone = <Video>[
          for (final Video v in videos)
            if (goneKeys.contains(MediaRef.fromVideo(v).key)) v,
        ];
        if (gone.isEmpty) return;
        await playlists.removeVideosFromAll(gone);
        await provider.handleVideosDeleted(gone);
      },
    );
  }

  /// Compartilha os vídeos marcados num único diálogo do sistema.
  void _shareSelected(BuildContext context, VideoProvider provider) {
    final List<Video> videos = selectedFrom(
      provider.visibleVideos,
      (Video v) => v.id,
    );
    if (videos.isEmpty) return;
    MediaActions.shareMany(context, <MediaRef>[
      for (final Video v in videos) MediaRef.fromVideo(v),
    ]);
  }

  /// Adiciona os vídeos marcados a uma playlist escolhida pelo usuário.
  Future<void> _addSelectedToPlaylist(
    BuildContext context,
    VideoProvider provider,
    List<Video> videos,
  ) async {
    if (videos.isEmpty) {
      clearSelection();
      return;
    }
    final PlaylistProvider playlists = context.read<PlaylistProvider>();
    if (playlists.playlists.isEmpty) {
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
          itemCount: playlists.playlists.length,
          itemBuilder: (BuildContext _, int index) {
            final playlist = playlists.playlists[index];
            return ListTile(
              leading: const Icon(Icons.playlist_play),
              title: Text(playlist.name),
              subtitle: Text('${playlist.videoCount} vídeos'),
              onTap: () async {
                // Uma transação + um reload (antes: um insert e uma query de
                // posição por vídeo, e a contagem ficava errada).
                final int added = await playlists.addVideosToPlaylist(
                  playlist.id,
                  videos,
                );
                if (sheetContext.mounted) Navigator.pop(sheetContext);
                clearSelection();
                messenger.showSnackBar(
                  SnackBar(
                    content: Text(
                      added == videos.length
                          ? '${videos.length} adicionados a "${playlist.name}"'
                          : '$added de ${videos.length} adicionados a '
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
}

class _VideoCard extends StatelessWidget {
  final Video video;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final bool selected;
  final bool selectionMode;

  const _VideoCard({
    required this.video,
    required this.onTap,
    required this.onLongPress,
    this.selected = false,
    this.selectionMode = false,
  });

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final bool marked = selectionMode && selected;

    return AnimatedContainer(
      duration: Motion.fast,
      curve: Motion.settle,
      decoration: BoxDecoration(
        color: marked
            ? colors.secondaryContainer.withValues(alpha: 0.5)
            : colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: marked ? Border.all(color: colors.primary, width: 2) : null,
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (selectionMode)
                Align(
                  alignment: Alignment.topRight,
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: IgnorePointer(
                      child: Icon(
                        marked
                            ? Icons.check_circle
                            : Icons.radio_button_unchecked,
                        color: marked ? colors.primary : colors.outline,
                        size: 22,
                      ),
                    ),
                  ),
                ),
              Column(
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
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          formatDuration(video.duration),
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: colors.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
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
            Icon(icon, size: 64, color: Theme.of(context).colorScheme.outline),
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
