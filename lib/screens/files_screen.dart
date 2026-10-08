import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/file_item.dart';
import '../models/gallery_image_model.dart';
import '../models/pdf_file_model.dart';
import '../models/video_model.dart';
import '../providers/file_provider.dart';
import '../services/file_query_service.dart';
import '../services/text_file_service.dart';
import '../services/media_share_service.dart';
import 'apk_manager_screen.dart';
import 'duplicate_files_screen.dart';
import 'file_details_screen.dart';
import 'pdf_viewer_screen.dart';
import 'photo_viewer_screen.dart';
import 'storage_analyzer_screen.dart';
import 'text_editor_screen.dart';
import 'trash_screen.dart';
import '../widgets/selection_bar.dart';
import 'video_player_screen.dart';

/// Aba "Arquivos": gerenciador completo do armazenamento real do aparelho.
///
/// Navegação física (breadcrumb clicável), lista/grade com miniaturas,
/// busca recursiva com escopo, seleção múltipla com ações em lote e
/// atalhos para as pastas do sistema.
class FilesScreen extends StatefulWidget {
  const FilesScreen({super.key});

  @override
  State<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends State<FilesScreen> {
  final TextEditingController _searchController = TextEditingController();
  String? _lastShownError;

  /// Quantidade de itens na lixeira, mostrada como badge no menu: é o que
  /// transforma "Lixeira" em algo que o usuário percebe.
  int _trashCount = 0;
  String _trashSizeLabel = '';

  @override
  void initState() {
    super.initState();
    _refreshTrashBadge();
  }

  /// Recalcula o contador da lixeira.
  ///
  /// Roda em background e ignora o resultado se a tela já foi fechada — o
  /// `FileQueryService` é lento (lê o manifesto e stat de cada arquivo) e
  /// não pode travar a abertura da aba.
  Future<void> _refreshTrashBadge() async {
    final List<TrashEntry> entries = await FileQueryService.listTrash();
    if (!mounted) return;
    final int bytes = entries.fold<int>(
      0,
      (int sum, TrashEntry e) => sum + e.sizeBytes,
    );
    setState(() {
      _trashCount = entries.length;
      _trashSizeLabel = bytes > 0 ? formatBytes(bytes) : '';
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final FileProvider provider = context.watch<FileProvider>();
    _handleErrorFeedback(provider);

    return Column(
      children: [
        _buildSearchBar(provider),
        _buildBreadcrumb(provider),
        provider.isSelectionMode
            ? _buildSelectionToolbar(provider)
            : _buildToolbar(provider),
        Expanded(child: _buildBody(context, provider)),
      ],
    );
  }

  void _handleErrorFeedback(FileProvider provider) {
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

  // =========================================================================
  // BARRA DE BUSCA (com alternância de escopo: pasta atual <-> todo aparelho)
  // =========================================================================

  Widget _buildSearchBar(FileProvider provider) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: TextField(
        controller: _searchController,
        onChanged: provider.setSearchQuery,
        decoration: InputDecoration(
          hintText: provider.globalSearch
              ? 'Buscar em todo o aparelho…'
              : 'Buscar nesta pasta e subpastas…',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: provider.globalSearch
                    ? 'Escopo: todo o aparelho (toque p/ restringir)'
                    : 'Escopo: pasta atual (toque p/ ampliar)',
                icon: Icon(
                  provider.globalSearch
                      ? Icons.public
                      : Icons.folder_copy_outlined,
                  color: Theme.of(context).colorScheme.primary,
                ),
                onPressed: provider.toggleSearchScope,
              ),
              if (_searchController.text.isNotEmpty)
                IconButton(
                  tooltip: 'Limpar busca',
                  icon: const Icon(Icons.clear),
                  onPressed: () {
                    _searchController.clear();
                    provider.setSearchQuery('');
                  },
                ),
            ],
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(28),
            borderSide: BorderSide.none,
          ),
          filled: true,
          contentPadding: EdgeInsets.zero,
        ),
      ),
    );
  }

  // =========================================================================
  // BREADCRUMB CLICÁVEL
  // =========================================================================

  Widget _buildBreadcrumb(FileProvider provider) {
    final List<String> segments = provider.currentPath
        .split('/')
        .where((s) => s.isNotEmpty)
        .toList();

    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          if (provider.canGoBack || provider.canGoForward) ...[
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.arrow_back_ios_new, size: 18),
              tooltip: 'Voltar',
              onPressed: provider.canGoBack ? provider.goBack : null,
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.arrow_forward_ios, size: 18),
              tooltip: 'Avançar',
              onPressed: provider.canGoForward ? provider.goForward : null,
            ),
          ],
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              reverse: true,
              children: [
                for (final entry in segments.asMap().entries.toList().reversed)
                  Builder(
                    builder: (context) {
                      final int index = entry.key;
                      final String segment = entry.value;
                      final bool isLast = index == segments.length - 1;
                      final String partialPath =
                          '/${segments.take(index + 1).join('/')}';
                      return InkWell(
                        onTap: () => provider.navigateTo(partialPath),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          child: Center(
                            child: Text(
                              isLast ? segment : '$segment ›',
                              style: TextStyle(
                                fontWeight: isLast
                                    ? FontWeight.w600
                                    : FontWeight.normal,
                                color: isLast
                                    ? Theme.of(context).colorScheme.onSurface
                                    : Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                InkWell(
                  onTap: provider.goHome,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Center(
                      child: Icon(
                        Icons.home_outlined,
                        size: 18,
                        color: segments.isEmpty
                            ? Theme.of(context).colorScheme.onSurface
                            : Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // =========================================================================
  // TOOLBARS
  // =========================================================================

  Widget _buildToolbar(FileProvider provider) {
    return Row(
      children: [
        PopupMenuButton<FileFilterType>(
          tooltip: 'Filtrar por tipo',
          icon: Icon(
            Icons.filter_list,
            color: provider.filterType == FileFilterType.all
                ? null
                : Theme.of(context).colorScheme.primary,
          ),
          onSelected: provider.setFilterType,
          itemBuilder: (_) => [
            _filterItem(FileFilterType.all, 'Todos', Icons.apps),
            _filterItem(FileFilterType.images, 'Imagens', Icons.image),
            _filterItem(FileFilterType.videos, 'Vídeos', Icons.videocam),
            _filterItem(FileFilterType.audio, 'Áudio', Icons.music_note),
            _filterItem(
              FileFilterType.documents,
              'Documentos',
              Icons.description,
            ),
            _filterItem(FileFilterType.apk, 'APKs', Icons.android),
            _filterItem(FileFilterType.archives, 'Compactados', Icons.archive),
            _filterItem(
              FileFilterType.other,
              'Outros',
              Icons.insert_drive_file,
            ),
          ],
        ),
        IconButton(
          tooltip: provider.sortAscending
              ? '${_sortLabel(provider.sortBy)} ▲'
              : '${_sortLabel(provider.sortBy)} ▼',
          icon: const Icon(Icons.sort),
          onPressed: () => _showSortSheet(provider),
        ),
        const Spacer(),
        Text(
          '${provider.visibleItems.length} itens',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const Spacer(),
        IconButton(
          tooltip: 'Lista / Grade',
          icon: Icon(
            provider.viewMode == FileViewMode.list
                ? Icons.grid_view_outlined
                : Icons.view_list_outlined,
          ),
          onPressed: () => provider.setViewMode(
            provider.viewMode == FileViewMode.list
                ? FileViewMode.grid
                : FileViewMode.list,
          ),
        ),
        PopupMenuButton<String>(
          tooltip: 'Mais opções',
          icon: const Icon(Icons.more_vert),
          onSelected: (value) => _handleMenuAction(context, provider, value),
          itemBuilder: (_) => [
            PopupMenuItem(
              value: 'new_folder',
              child: ListTile(
                leading: Icon(Icons.create_new_folder_outlined),
                title: Text('Nova pasta'),
                contentPadding: EdgeInsets.zero,
              ),
            ),
            PopupMenuItem(
              value: 'new_file',
              child: ListTile(
                leading: Icon(Icons.note_add_outlined),
                title: Text('Novo arquivo de texto'),
                subtitle: Text('HTML, CSS, JS, JSON, TXT, MD…'),
                contentPadding: EdgeInsets.zero,
              ),
            ),
            PopupMenuItem(
              value: 'shortcuts',
              child: ListTile(
                leading: Icon(Icons.bookmarks_outlined),
                title: Text('Atalhos do aparelho'),
                // "Pastas do sistema" sugeria CRIAÇÃO de pasta do sistema, que
                // o app não faz (e não pode fazer). É navegação: atalhos para
                // Download, DCIM, Android/data...
                subtitle: Text('Ir para Download, DCIM, Música…'),
                contentPadding: EdgeInsets.zero,
              ),
            ),
            // Lixeira com CONTAGEM: o item era invisível na prática porque
            // "Lixeira" sozinho não diz se há algo ali — e o usuário não
            // descobre o que deletou até ir procurar.
            PopupMenuItem(
              value: 'trash',
              child: ListTile(
                leading: Badge(
                  isLabelVisible: _trashCount > 0,
                  label: Text('$_trashCount'),
                  child: const Icon(Icons.delete_outline),
                ),
                title: const Text('Lixeira'),
                subtitle: Text(
                  _trashCount == 0
                      ? 'vazia'
                      : '$_trashCount ${_trashCount == 1 ? 'item' : 'itens'}'
                            '${_trashSizeLabel.isEmpty ? '' : ' • $_trashSizeLabel'}',
                ),
                contentPadding: EdgeInsets.zero,
              ),
            ),
            PopupMenuItem(
              value: 'analyzer',
              child: ListTile(
                leading: Icon(Icons.donut_large),
                title: Text('Analisador de armazenamento'),
                contentPadding: EdgeInsets.zero,
              ),
            ),
            PopupMenuItem(
              value: 'apks',
              child: ListTile(
                leading: Icon(Icons.android),
                title: Text('Gerenciador de APKs'),
                contentPadding: EdgeInsets.zero,
              ),
            ),
            PopupMenuItem(
              value: 'duplicates',
              child: ListTile(
                leading: Icon(Icons.content_copy),
                title: Text('Arquivos duplicados'),
                contentPadding: EdgeInsets.zero,
              ),
            ),
            PopupMenuItem(
              value: 'hidden',
              child: ListTile(
                leading: Icon(Icons.visibility_outlined),
                title: Text(
                  provider.showHiddenFiles
                      ? 'Ocultar arquivos ocultos'
                      : 'Mostrar arquivos ocultos',
                ),
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ],
        ),
      ],
    );
  }

  PopupMenuItem<FileFilterType> _filterItem(
    FileFilterType value,
    String label,
    IconData icon,
  ) {
    return PopupMenuItem<FileFilterType>(
      value: value,
      child: ListTile(
        leading: Icon(icon),
        title: Text(label),
        contentPadding: EdgeInsets.zero,
      ),
    );
  }

  String _sortLabel(FileSortBy sortBy) {
    switch (sortBy) {
      case FileSortBy.name:
        return 'Nome';
      case FileSortBy.dateModified:
        return 'Data';
      case FileSortBy.size:
        return 'Tamanho';
      case FileSortBy.type:
        return 'Tipo';
    }
  }

  void _showSortSheet(FileProvider provider) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final FileSortBy sort in FileSortBy.values)
              ListTile(
                leading: Icon(
                  provider.sortBy == sort
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                ),
                title: Text(_sortLabel(sort)),
                trailing: provider.sortBy == sort
                    ? Icon(
                        provider.sortAscending
                            ? Icons.arrow_upward
                            : Icons.arrow_downward,
                      )
                    : null,
                onTap: () {
                  Navigator.pop(sheetContext);
                  provider.setSortBy(sort);
                },
              ),
          ],
        ),
      ),
    );
  }

  /// Barra de ações em lote — o MESMO [SelectionBar] das abas de mídia.
  ///
  /// Antes Arquivos tinha uma barra própria: sem a dica do gesto e com
  /// "selecionar tudo" que nunca desmarcava, enquanto as abas de mídia
  /// faziam o contrário. Uma implementação só, mesmo comportamento.
  Widget _buildSelectionToolbar(FileProvider provider) {
    return SelectionBar(
      label: '${provider.selectedCount} selecionado(s)',
      onSelectAll: provider.toggleSelectAllVisible,
      onClear: provider.clearSelection,
      onDelete: () => _confirmDeleteSelection(),
      actions: <SelectionAction>[
        SelectionAction(
          icon: Icons.info_outline,
          label: provider.selectedCount == 1
              ? 'Detalhes do arquivo'
              : 'Detalhes (selecione 1 arquivo)',
          // Desabilitado em vez de sumir: o usuário entende que o recurso
          // existe e precisa marcar exatamente um item.
          onPressed: provider.selectedCount == 1
              ? () => _openDetailsOfSelection(provider)
              : null,
        ),
        SelectionAction(
          icon: Icons.content_copy,
          label: 'Copiar para…',
          onPressed: () => _pickDestination(copy: true),
        ),
        SelectionAction(
          icon: Icons.drive_file_move_outline,
          label: 'Mover para…',
          onPressed: () => _pickDestination(copy: false),
        ),
        SelectionAction(
          icon: Icons.folder_zip_outlined,
          label: 'Compactar em ZIP',
          onPressed: () => _showZipDialog(),
        ),
        SelectionAction(
          icon: Icons.share_outlined,
          label: 'Compartilhar',
          onPressed: () => _shareSelected(),
        ),
        SelectionAction(
          icon: Icons.swap_horiz,
          label: 'Inverter seleção',
          onPressed: () => provider.toggleSelectAllVisible(),
        ),
      ],
    );
  }

  // =========================================================================
  // CORPO (lista/grade com lazy loading)
  // =========================================================================

  Widget _buildBody(BuildContext context, FileProvider provider) {
    if (!Platform.isAndroid) {
      return const _EmptyState(
        icon: Icons.folder_outlined,
        message: 'Gerenciador disponível apenas no Android.',
      );
    }
    if (!provider.allFilesAccess) {
      return _AllFilesAccessState(
        onRequest: () => provider.requestAllFilesAccess(),
      );
    }
    if (provider.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final List<FileItem> visible = provider.visibleItems;
    if (visible.isEmpty && provider.isSearching) {
      return const Center(child: CircularProgressIndicator());
    }
    if (visible.isEmpty) {
      return _EmptyState(
        icon: provider.searchQuery.isNotEmpty
            ? Icons.search_off
            : Icons.folder_open_outlined,
        message: provider.searchQuery.isNotEmpty
            ? 'Nenhum resultado para "${provider.searchQuery}".'
            : 'Pasta vazia.',
      );
    }

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.metrics.extentAfter < 400) provider.loadMore();
        return false;
      },
      child: RefreshIndicator(
        onRefresh: () => provider.load(refresh: true),
        child: provider.viewMode == FileViewMode.grid
            ? GridView.builder(
                key: const ValueKey('grid'),
                padding: const EdgeInsets.all(8),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  childAspectRatio: 0.72,
                ),
                itemCount: visible.length,
                itemBuilder: (context, index) => _FileGridTile(
                  item: visible[index],
                  isSelected: provider.selectedPaths.contains(
                    visible[index].path,
                  ),
                  selectionMode: provider.isSelectionMode,
                  onTap: () => _onTap(provider, visible[index]),
                  onLongPress: () => _onLongPress(provider, visible[index]),
                ),
              )
            : ListView.separated(
                key: const ValueKey('list'),
                itemCount: visible.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) => _FileListTile(
                  item: visible[index],
                  isSelected: provider.selectedPaths.contains(
                    visible[index].path,
                  ),
                  selectionMode: provider.isSelectionMode,
                  onTap: () => _onTap(provider, visible[index]),
                  onLongPress: () => _onLongPress(provider, visible[index]),
                ),
              ),
      ),
    );
  }

  void _onTap(FileProvider provider, FileItem item) {
    if (provider.isSelectionMode) {
      provider.toggleSelect(item.path);
      return;
    }
    if (item.isDirectory) {
      provider.navigateTo(item.path);
      return;
    }
    _openFile(item);
  }

  void _onLongPress(FileProvider provider, FileItem item) {
    if (!provider.isSelectionMode) provider.toggleSelectionMode();
    provider.toggleSelect(item.path);
  }

  /// Roteia a abertura por tipo: visualizadores nativos do Audify quando
  /// existem, app externo caso contrário.
  Future<void> _openFile(FileItem item) async {
    final BuildContext context = this.context;
    switch (item.type) {
      case FileType.pdf:
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => PdfViewerScreen(
              pdf: PdfFile(
                id: 'file-${item.path}',
                name: item.name,
                path: item.path,
                size: item.size,
                dateAdded: item.dateModified,
              ),
            ),
          ),
        );
        return;
      case FileType.image:
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => PhotoViewerScreen(
              images: [
                GalleryImage(
                  id: item.path.hashCode,
                  name: item.name,
                  path: item.path,
                  size: item.size,
                  dateAdded: item.dateModified,
                  width: -1,
                  height: -1,
                ),
              ],
              initialIndex: 0,
            ),
          ),
        );
        return;
      case FileType.video:
        final Video video = Video(
          // Id negativo derivado do caminho: nunca colide com MediaStore;
          // miniatura por id não existe, mas o player usa o caminho.
          id: -(item.path.hashCode.abs()),
          title: item.name,
          displayName: item.name,
          duration: Duration.zero,
          path: item.path,
          size: item.size,
          dateAdded: item.dateModified,
        );
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => VideoPlayerScreen(queue: [video], initialIndex: 0),
          ),
        );
        return;
      default:
        // Arquivo de texto abre no editor EMBUTIDO, antes de qualquer app
        // externo: quem cria um index.html no Audify espera editar no Audify,
        // não ser jogado para um editor de terceiro.
        if (TextFileService.isTextFile(item.path)) {
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => TextEditorScreen(path: item.path),
            ),
          );
          return;
        }
        final bool ok = await FileQueryService.openFile(item.path);
        if (!ok && mounted) {
          ScaffoldMessenger.of(this.context).showSnackBar(
            const SnackBar(
              content: Text('Nenhum app instalado abre este tipo de arquivo.'),
            ),
          );
        }
    }
  }

  /// Cria um arquivo de texto na pasta atual e abre o editor.
  Future<void> _createTextFile(FileProvider provider) async {
    final String? name = await showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => const _NewFileDialog(),
    );
    if (name == null || name.trim().isEmpty || !mounted) return;

    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final Color errorColor = Theme.of(context).colorScheme.error;
    final TextFileResult result = await TextFileService.create(
      directory: provider.currentPath,
      name: name,
      content: TextFileService.starterContent(
        TextFileService.extensionOf(name) ?? '',
      ),
    );
    if (!result.success) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(result.error ?? 'Não foi possível criar o arquivo.'),
          backgroundColor: errorColor,
        ),
      );
      return;
    }

    await provider.load(refresh: true);
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TextEditorScreen(path: result.path),
      ),
    );
  }

  /// Diálogo de "novo arquivo": nome + extensão, com motivo de recusa.

  // =========================================================================
  // AÇÕES
  // =========================================================================

  Future<void> _pickDestination({required bool copy}) async {
    final FileProvider provider = context.read<FileProvider>();
    final String? destPath = await showDialog<String>(
      context: context,
      builder: (_) => _DestinationPicker(initialPath: provider.currentPath),
    );
    if (destPath == null || !mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    final bool ok = copy
        ? await provider.copyTo(destPath)
        : await provider.moveTo(destPath);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? (copy
                    ? 'Copiado(s) para ${destPath.split('/').last}'
                    : 'Movido(s)')
              : 'Falha em parte das operações',
        ),
      ),
    );
  }

  /// Um único share sheet com TODOS os selecionados (qualquer tipo).
  Future<void> _shareSelected() async {
    final FileProvider provider = context.read<FileProvider>();
    final List<String> paths = provider.selectedItems
        .map((f) => f.path)
        .toList();
    if (paths.isEmpty) return;
    try {
      await MediaShareService.shareFiles(paths);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Não foi possível compartilhar: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  Future<void> _confirmDeleteSelection() async {
    final FileProvider provider = context.read<FileProvider>();
    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Excluir selecionados?'),
        content: Text(
          '${provider.selectedCount} item(ns) vão para a lixeira '
          '(restaurável em Mais opções → Lixeira).',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Excluir'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final bool ok = await provider.deleteSelected(useTrash: true);
    // O contador da lixeira no menu precisa acompanhar a exclusão.
    await _refreshTrashBadge();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          ok ? 'Movido(s) para a lixeira' : 'Falha em alguns itens',
        ),
      ),
    );
  }

  void _showZipDialog() {
    final FileProvider provider = context.read<FileProvider>();
    final TextEditingController nameCtrl = TextEditingController(
      text: 'arquivos.zip',
    );
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Compactar seleção'),
        content: TextField(
          controller: nameCtrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Nome do arquivo .zip'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(dialogContext);
              final messenger = ScaffoldMessenger.of(context);
              final bool ok = await provider.zipSelection(nameCtrl.text.trim());
              messenger.showSnackBar(
                SnackBar(
                  content: Text(ok ? 'ZIP criado' : 'Falha ao criar ZIP'),
                ),
              );
            },
            child: const Text('Criar'),
          ),
        ],
      ),
    );
  }

  void _showCreateFolderDialog() {
    final FileProvider provider = context.read<FileProvider>();
    final TextEditingController nameCtrl = TextEditingController();
    showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Nova pasta'),
        content: TextField(
          controller: nameCtrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Nome da pasta'),
          onSubmitted: (value) => Navigator.pop(dialogContext, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, nameCtrl.text.trim()),
            child: const Text('Criar'),
          ),
        ],
      ),
    ).then((name) async {
      if (name is! String || name.isEmpty || !mounted) return;
      final bool ok = await provider.createDirectory(name);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ok ? 'Pasta criada' : 'Falha ao criar pasta')),
        );
      }
    });
  }

  /// Abre a tela de detalhes do único item selecionado.
  void _openDetailsOfSelection(FileProvider provider) {
    final List<FileItem> selected = provider.selectedItems;
    if (selected.length != 1) return;
    provider.clearSelection();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => FileDetailsScreen(item: selected.first),
      ),
    );
  }

  void _handleMenuAction(
    BuildContext context,
    FileProvider provider,
    String action,
  ) {
    switch (action) {
      case 'new_folder':
        _showCreateFolderDialog();
      case 'new_file':
        _createTextFile(provider);
      case 'shortcuts':
        _showSystemFolders(provider);
      case 'trash':
        // `.then` para recarregar o badge: restaurar/apagar dentro da lixeira
        // muda o contador, e voltar sem atualizar mostraria um número velho.
        Navigator.of(context)
            .push(MaterialPageRoute<void>(builder: (_) => const TrashScreen()))
            .then((_) => _refreshTrashBadge());
      case 'analyzer':
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const StorageAnalyzerScreen()),
        );
      case 'apks':
        Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const ApkManagerScreen()));
      case 'duplicates':
        Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const DuplicateFilesScreen()));
      case 'hidden':
        provider.setShowHiddenFiles(!provider.showHiddenFiles);
    }
  }

  void _showSystemFolders(FileProvider provider) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final StorageVolume volume in provider.volumes)
              ListTile(
                leading: Icon(
                  volume.isRemovable ? Icons.sd_card : Icons.storage,
                ),
                title: Text(volume.name),
                subtitle: volume.totalSpace > 0
                    ? Text(
                        '${volume.displayFreeSpace} livres de ${volume.displayTotalSpace}',
                      )
                    : null,
                onTap: () {
                  Navigator.pop(sheetContext);
                  provider.navigateTo(volume.path);
                },
              ),
            const Divider(),
            ...SystemFolders.shortcuts.map(
              (SystemFolder folder) => ListTile(
                leading: Icon(folder.icon),
                title: Text(folder.name),
                onTap: () {
                  Navigator.pop(sheetContext);
                  provider.navigateTo(folder.path);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// TILES
// =============================================================================

class _FileListTile extends StatelessWidget {
  final FileItem item;
  final bool isSelected;
  final bool selectionMode;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _FileListTile({
    required this.item,
    required this.isSelected,
    required this.selectionMode,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;

    return Material(
      color: isSelected && selectionMode
          ? colors.secondaryContainer.withValues(alpha: 0.5)
          : colors.surface,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              if (selectionMode)
                Checkbox(
                  value: isSelected,
                  onChanged: (_) => onLongPress(),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              SizedBox(
                width: 44,
                height: 44,
                child: _FileThumbnail(item: item),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      item.isDirectory
                          ? item.displayDateModified
                          : '${formatBytes(item.size)} • ${item.displayDateModified}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                item.isDirectory ? Icons.chevron_right : Icons.open_in_new,
                size: 20,
                color: colors.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FileGridTile extends StatelessWidget {
  final FileItem item;
  final bool isSelected;
  final bool selectionMode;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _FileGridTile({
    required this.item,
    required this.isSelected,
    required this.selectionMode,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;

    return Material(
      color: colors.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Container(
                    color: colors.surfaceContainerHighest,
                    alignment: Alignment.center,
                    child: SizedBox.expand(child: _FileThumbnail(item: item)),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                      Text(
                        item.isDirectory ? 'Pasta' : formatBytes(item.size),
                        maxLines: 1,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (selectionMode)
              Positioned.fill(
                child: ColoredBox(
                  color: isSelected
                      ? colors.secondaryContainer.withValues(alpha: 0.55)
                      : Colors.transparent,
                  child: Align(
                    alignment: Alignment.topRight,
                    child: Checkbox(
                      value: isSelected,
                      onChanged: (_) => onLongPress(),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Miniatura por tipo: imagem decodifica direto do disco (rápido); vídeo/PDF
/// pedem ao canal nativo (com cache em memória no serviço); demais tipos usam
/// ícone por extensão.
class _FileThumbnail extends StatelessWidget {
  final FileItem item;

  const _FileThumbnail({required this.item});

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;

    if (item.isDirectory) {
      return Center(child: Icon(Icons.folder, color: colors.primary));
    }

    if (item.type == FileType.image) {
      final File file = File(item.path);
      return Image.file(
        file,
        fit: BoxFit.cover,
        cacheWidth: 200,
        errorBuilder: (_, _, _) =>
            Icon(Icons.image_outlined, color: colors.onSurfaceVariant),
      );
    }

    if (item.type == FileType.video || item.type == FileType.pdf) {
      return FutureBuilder<Uint8List?>(
        future: FileQueryService.getThumbnail(item.path),
        builder: (context, snapshot) {
          final bytes = snapshot.data;
          if (bytes != null && bytes.isNotEmpty) {
            return Image.memory(
              bytes,
              fit: BoxFit.cover,
              gaplessPlayback: true,
            );
          }
          return Icon(item.icon, color: colors.onSurfaceVariant);
        },
      );
    }

    return Center(child: Icon(item.icon, color: colors.onSurfaceVariant));
  }
}

// =============================================================================
// SELETOR DE DESTINO (copiar/mover)
// =============================================================================

class _DestinationPicker extends StatefulWidget {
  final String initialPath;

  const _DestinationPicker({required this.initialPath});

  @override
  State<_DestinationPicker> createState() => _DestinationPickerState();
}

class _DestinationPickerState extends State<_DestinationPicker> {
  late String _currentPath;
  List<FileItem> _folders = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _currentPath = widget.initialPath;
    _load();
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);
    final FileListResult result = await FileQueryService.listDirectory(
      path: _currentPath,
      limit: 5000,
    );
    if (!mounted) return;
    setState(() {
      _folders = result.items
          .where((i) => i.isDirectory && !i.name.startsWith('.'))
          .toList();
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Escolher destino'),
      content: SizedBox(
        width: double.maxFinite,
        height: 380,
        child: Column(
          children: [
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_upward, size: 20),
                  tooltip: 'Subir um nível',
                  onPressed: () => setState(() {
                    _currentPath = Directory(_currentPath).parent.path;
                    _load();
                  }),
                ),
                Expanded(
                  child: Text(
                    _currentPath,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
            const Divider(height: 1),
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _folders.isEmpty
                  ? const Center(child: Text('Nenhuma subpasta aqui.'))
                  : ListView.builder(
                      itemCount: _folders.length,
                      itemBuilder: (context, index) => ListTile(
                        dense: true,
                        leading: Icon(
                          _folders[index].icon,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        title: Text(_folders[index].name),
                        onTap: () {
                          _currentPath = _folders[index].path;
                          _load();
                        },
                      ),
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _currentPath),
          child: const Text('Selecionar esta pasta'),
        ),
      ],
    );
  }
}

// =============================================================================
// ESTADOS VAZIOS / PERMISSÃO
// =============================================================================

class _AllFilesAccessState extends StatelessWidget {
  final VoidCallback onRequest;

  const _AllFilesAccessState({required this.onRequest});

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_off_outlined, size: 64, color: colors.outline),
            const SizedBox(height: 12),
            Text(
              'O Audify precisa do acesso especial "Todos os arquivos" '
              'para funcionar como gerenciador de arquivos.\n\n'
              'Na tela do sistema que abrir, ative o acesso para este app.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRequest,
              icon: const Icon(Icons.settings_outlined),
              label: const Text('Conceder acesso'),
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
            Icon(icon, size: 56, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

/// Diálogo "novo arquivo de texto".
///
/// A extensão é escolhida por um seletor em vez de ser digitada: os tipos
/// aceitos são poucos, e digitar ".htlm" e errar numa lista livre seria
/// descobrir o problema só ao abrir o arquivo em outro programa.
class _NewFileDialog extends StatefulWidget {
  const _NewFileDialog();

  @override
  State<_NewFileDialog> createState() => _NewFileDialogState();
}

class _NewFileDialogState extends State<_NewFileDialog> {
  final TextEditingController _name = TextEditingController();
  String _extension = 'html';
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final String fullName = '${_name.text.trim()}.$_extension';
    final String? problem = TextFileService.validateName(fullName);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    Navigator.pop(context, fullName);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Novo arquivo de texto'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _name,
                  autofocus: true,
                  textCapitalization: TextCapitalization.none,
                  decoration: const InputDecoration(
                    labelText: 'Nome',
                    hintText: 'index',
                  ),
                  onChanged: (_) {
                    if (_error != null) setState(() => _error = null);
                  },
                  onSubmitted: (_) => _submit(),
                ),
              ),
              const SizedBox(width: 10),
              DropdownButton<String>(
                value: _extension,
                underline: const SizedBox.shrink(),
                items: <DropdownMenuItem<String>>[
                  for (final String ext in TextFileService.textExtensions)
                    DropdownMenuItem<String>(value: ext, child: Text('.$ext')),
                ],
                onChanged: (String? value) {
                  if (value == null) return;
                  setState(() {
                    _extension = value;
                    _error = null;
                  });
                },
              ),
            ],
          ),
          if (_error != null) ...<Widget>[
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(
                  Icons.error_outline,
                  size: 16,
                  color: Theme.of(context).colorScheme.error,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _error!,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancelar'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Criar e editar')),
      ],
    );
  }
}
