import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart' show TextEditingController;
import 'package:flutter/foundation.dart';

import '../models/file_item.dart';
import '../services/file_query_service.dart';
import '../services/permission_service.dart';

enum FileViewMode { list, grid }

enum FileSortBy { name, dateModified, size, type }

enum FileFilterType { all, images, videos, audio, documents, apk, archives, other }

/// Estado da aba "Arquivos": navegação real pelo sistema de arquivos,
/// seleção múltipla, busca com escopo e operações em lote.
///
/// A busca é RECURSIVA (subárvore da pasta atual ou o aparelho inteiro),
/// com debounce de 350 ms — diferente das demais abas, que filtram só a
/// página carregada.
class FileProvider extends ChangeNotifier {
  static const String rootPath = '/storage/emulated/0';

  String _currentPath = rootPath;
  final List<String> _pathHistory = <String>[rootPath];
  int _historyIndex = 0;

  List<FileItem> _items = const [];
  List<StorageVolume> _volumes = const [];

  // ---- Busca ----
  Timer? _debounce;
  List<FileItem>? _searchResults;
  bool _isSearching = false;
  bool _globalSearch = false;
  String _searchQuery = '';

  FileFilterType _filterType = FileFilterType.all;
  FileSortBy _sortBy = FileSortBy.name;
  bool _sortAscending = true;
  FileViewMode _viewMode = FileViewMode.list;

  bool _isLoading = true;
  bool _isLoadingMore = false;
  bool _hasMore = false;
  int _offset = 0;
  String? _errorMessage;
  bool _allFilesAccess = false;

  bool _isSelectionMode = false;
  final Set<String> _selectedPaths = <String>{};
  bool _showHiddenFiles = true;
  bool _isDisposed = false;

  // ---- Getters ----
  String get currentPath => _currentPath;
  bool get canGoBack => _historyIndex > 0;
  bool get canGoForward => _historyIndex < _pathHistory.length - 1;
  List<StorageVolume> get volumes => _volumes;
  String get searchQuery => _searchQuery;
  bool get isSearching => _isSearching;
  bool get globalSearch => _globalSearch;
  FileFilterType get filterType => _filterType;
  FileSortBy get sortBy => _sortBy;
  bool get sortAscending => _sortAscending;
  FileViewMode get viewMode => _viewMode;
  bool get isLoading => _isLoading;
  bool get isLoadingMore => _isLoadingMore;
  bool get hasMore => _hasMore;
  String? get errorMessage => _errorMessage;
  bool get allFilesAccess => _allFilesAccess;
  bool get isSelectionMode => _isSelectionMode;
  Set<String> get selectedPaths => _selectedPaths;
  int get selectedCount => _selectedPaths.length;
  bool get showHiddenFiles => _showHiddenFiles;

  /// Itens exibidos: resultados da busca quando ativa; senão a página atual
  /// com filtro client-side por tipo (o tipo também já vem filtrado do
  /// serviço — este filtro cobre páginas acumuladas).
  List<FileItem> get visibleItems {
    final List<FileItem> results = _searchResults ?? _items;
    if (_filterType == FileFilterType.all) return results;
    return results.where((item) {
      if (item.isDirectory) return true;
      switch (_filterType) {
        case FileFilterType.images:
          return item.type == FileType.image;
        case FileFilterType.videos:
          return item.type == FileType.video;
        case FileFilterType.audio:
          return item.type == FileType.audio;
        case FileFilterType.documents:
          return item.type == FileType.document ||
              item.type == FileType.pdf ||
              item.type == FileType.text ||
              item.type == FileType.spreadsheet ||
              item.type == FileType.presentation ||
              item.type == FileType.code;
        case FileFilterType.apk:
          return item.type == FileType.apk;
        case FileFilterType.archives:
          return item.type == FileType.archive;
        case FileFilterType.other:
          return item.type == FileType.other;
        case FileFilterType.all:
          return true;
      }
    }).toList();
  }

  FileProvider() {
    _initialize();
  }

  Future<void> _initialize() async {
    if (!Platform.isAndroid) {
      _isLoading = false;
      _notify();
      return;
    }
    _allFilesAccess = await PermissionService.hasAllFilesAccess();
    _volumes = await FileQueryService.loadStorageVolumes();
    await load();
  }

  /// Recarrega volumes (ex.: retorno do cartão SD).
  Future<void> refreshVolumes() async {
    _volumes = await FileQueryService.loadStorageVolumes();
    _notify();
  }

  // =========================================================================
  // CARREGAMENTO PAGINADO
  // =========================================================================

  Future<void> load({bool refresh = false}) async {
    if (!Platform.isAndroid) {
      _items = const [];
      _isLoading = false;
      _notify();
      return;
    }

    if (refresh) {
      _offset = 0;
      _items = const [];
      _hasMore = true;
    }

    _isLoading = _offset == 0;
    _notify();

    try {
      final FileListResult result = await FileQueryService.listDirectory(
        path: _currentPath,
        offset: _offset,
        limit: FileQueryService.pageSize,
        sortBy: _sortBy.name,
        sortAscending: _sortAscending,
        includeHidden: _showHiddenFiles,
      );
      // Dedup por caminho absoluto: nunca duplica itens na lista ao
      // recarregar páginas concorrentes.
      final Map<String, FileItem> merged = <String, FileItem>{
        for (final FileItem item in _items) item.path: item,
        for (final FileItem item in result.items) item.path: item,
      };
      _items = merged.values.toList();
      _hasMore = result.hasMore && result.items.isNotEmpty;
      _offset += result.items.length;
      _errorMessage = null;
    } catch (e) {
      _errorMessage = 'Falha ao listar pasta: $e';
    } finally {
      _isLoading = false;
      _isLoadingMore = false;
      _notify();
    }
  }

  Future<void> loadMore() async {
    if (_isLoading || _isLoadingMore || !_hasMore || _searchResults != null) {
      return;
    }
    _isLoadingMore = true;
    _notify();
    await load();
  }

  // =========================================================================
  // BUSCA (debounce + escopo)
  // =========================================================================

  void setSearchQuery(String query) {
    _searchQuery = query.trim();
    _debounce?.cancel();
    if (_searchQuery.isEmpty) {
      _searchResults = null;
      _isSearching = false;
      _notify();
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 350), _runSearch);
  }

  Future<void> _runSearch() async {
    _isSearching = true;
    _notify();

    final List<FileItem> results = await FileQueryService.searchFiles(
      query: _searchQuery,
      rootPath: _globalSearch ? rootPath : _currentPath,
      filterType: _filterTypeToFileType(_filterType),
    );

    _searchResults = results;
    _isSearching = false;
    _notify();
  }

  void toggleSearchScope() {
    _globalSearch = !_globalSearch;
    if (_searchQuery.isNotEmpty) {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 350), _runSearch);
    }
    _notify();
  }

  void clearSearch(TextEditingController? controller) {
    controller?.clear();
    setSearchQuery('');
  }

  // =========================================================================
  // NAVEGAÇÃO
  // =========================================================================

  Future<void> navigateTo(String path) async {
    path = path.endsWith('/') && path != '/' ? path.substring(0, path.length - 1) : path;
    if (path == _currentPath) {
      await load(refresh: true);
      return;
    }
    _currentPath = path;
    _resetPageState();
    if (_historyIndex < _pathHistory.length - 1) {
      _pathHistory.removeRange(_historyIndex + 1, _pathHistory.length);
    }
    _pathHistory.add(path);
    _historyIndex = _pathHistory.length - 1;
    await load(refresh: true);
  }

  Future<void> goBack() async {
    if (!canGoBack) return;
    _historyIndex--;
    _currentPath = _pathHistory[_historyIndex];
    _resetPageState();
    await load(refresh: true);
  }

  Future<void> goForward() async {
    if (!canGoForward) return;
    _historyIndex++;
    _currentPath = _pathHistory[_historyIndex];
    _resetPageState();
    await load(refresh: true);
  }

  /// Sobe um nível — limitado à raiz do armazenamento interno.
  Future<void> goUp() async {
    if (_currentPath == rootPath) return;
    final String parent = Directory(_currentPath).parent.path;
    if (parent == _currentPath) return;
    await navigateTo(parent);
  }

  Future<void> goHome() => navigateTo(rootPath);

  void _resetPageState() {
    _offset = 0;
    _hasMore = true;
    _selectedPaths.clear();
    _isSelectionMode = false;
    _searchResults = null;
    _errorMessage = null;
  }

  // =========================================================================
  // FILTROS / ORDENAÇÃO / VISUALIZAÇÃO
  // =========================================================================

  FileType? _filterTypeToFileType(FileFilterType filter) {
    switch (filter) {
      case FileFilterType.images:
        return FileType.image;
      case FileFilterType.videos:
        return FileType.video;
      case FileFilterType.audio:
        return FileType.audio;
      case FileFilterType.documents:
        return FileType.document;
      case FileFilterType.apk:
        return FileType.apk;
      case FileFilterType.archives:
        return FileType.archive;
      case FileFilterType.other:
        return FileType.other;
      case FileFilterType.all:
        return null;
    }
  }

  void setFilterType(FileFilterType type) {
    if (_filterType == type) return;
    _filterType = type;
    if (_searchQuery.isNotEmpty) {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 350), _runSearch);
    } else {
      load(refresh: true);
    }
    _notify();
  }

  void setSortBy(FileSortBy sortBy) {
    if (_sortBy == sortBy) {
      _sortAscending = !_sortAscending;
    } else {
      _sortBy = sortBy;
      _sortAscending = true;
    }
    load(refresh: true);
  }

  void setViewMode(FileViewMode mode) {
    if (_viewMode == mode) return;
    _viewMode = mode;
    _notify();
  }

  void setShowHiddenFiles(bool show) {
    if (_showHiddenFiles == show) return;
    _showHiddenFiles = show;
    load(refresh: true);
  }

  // =========================================================================
  // SELEÇÃO MÚLTIPLA
  // =========================================================================

  void toggleSelectionMode() {
    _isSelectionMode = !_isSelectionMode;
    if (!_isSelectionMode) _selectedPaths.clear();
    _notify();
  }

  void toggleSelect(String path) {
    if (!_selectedPaths.add(path)) {
      _selectedPaths.remove(path);
    }
    if (_selectedPaths.isEmpty) _isSelectionMode = false;
    _notify();
  }

  void selectAllVisible() {
    for (final FileItem item in visibleItems) {
      _selectedPaths.add(item.path);
    }
    _isSelectionMode = true;
    _notify();
  }

  void clearSelection() {
    _selectedPaths.clear();
    _isSelectionMode = false;
    _notify();
  }

  List<FileItem> get selectedItems =>
      visibleItems.where((i) => _selectedPaths.contains(i.path)).toList();

  // =========================================================================
  // OPERAÇÕES DE ARQUIVO
  // =========================================================================

  Future<bool> createDirectory(String name) async {
    if (name.trim().isEmpty) return false;
    final bool ok =
        await FileQueryService.createDirectory('$_currentPath/$name');
    if (ok) await load(refresh: true);
    return ok;
  }

  Future<bool> rename(String path, String newName) async {
    final bool ok = await FileQueryService.rename(path: path, newName: newName);
    if (ok) await load(refresh: true);
    return ok;
  }

  /// Exclui a seleção (para lixeira). Retorna caminhos movidos para undo
  /// futuro; a UI oferece "restaurar" via tela da Lixeira.
  Future<bool> deleteSelected({bool useTrash = true}) async {
    if (_selectedPaths.isEmpty) return false;
    final List<String> targets = _selectedPaths.toList();

    bool allOk = true;
    for (final String path in targets) {
      final bool ok = await FileQueryService.delete(path: path, useTrash: useTrash);
      if (!ok) allOk = false;
    }
    _selectedPaths.clear();
    _isSelectionMode = false;
    await load(refresh: true);
    return allOk;
  }

  Future<bool> deleteSingle(String path, {bool useTrash = true}) async {
    final bool ok = await FileQueryService.delete(path: path, useTrash: useTrash);
    await load(refresh: true);
    return ok;
  }

  Future<bool> copyTo(String destPath) async {
    if (_selectedPaths.isEmpty) return false;
    bool allOk = true;
    for (final String source in _selectedPaths) {
      final String name = source.split('/').last;
      final bool ok = await FileQueryService.copy(
        sourcePath: source,
        destPath: '$destPath/$name',
      );
      if (!ok) allOk = false;
    }
    _selectedPaths.clear();
    _isSelectionMode = false;
    _notify();
    if (destPath == _currentPath) await load(refresh: true);
    return allOk;
  }

  Future<bool> moveTo(String destPath) async {
    if (_selectedPaths.isEmpty) return false;
    bool allOk = true;
    for (final String source in _selectedPaths) {
      final String name = source.split('/').last;
      final bool ok = await FileQueryService.move(
        sourcePath: source,
        destPath: '$destPath/$name',
      );
      if (!ok) allOk = false;
    }
    _selectedPaths.clear();
    _isSelectionMode = false;
    _notify();
    await load(refresh: true);
    return allOk;
  }

  Future<bool> zipSelection(String zipName) async {
    if (_selectedPaths.isEmpty) return false;
    final bool ok = await FileQueryService.createZip(
      sourcePaths: _selectedPaths.toList(),
      zipPath: '$_currentPath/'
          '${zipName.endsWith('.zip') ? zipName : '$zipName.zip'}',
    );
    if (ok) {
      _selectedPaths.clear();
      _isSelectionMode = false;
      await load(refresh: true);
    }
    return ok;
  }

  Future<bool> extractArchive(String archivePath) async {
    final bool ok = await FileQueryService.extractArchive(
      archivePath: archivePath,
      destPath: _currentPath,
    );
    if (ok) await load(refresh: true);
    return ok;
  }

  // =========================================================================
  // PASSES-THROUGH PARA TELAS SECUNDÁRIAS
  // =========================================================================

  Future<bool> openFile(String path) => FileQueryService.openFile(path);

  Future<List<TrashEntry>> listTrash() => FileQueryService.listTrash();

  Future<bool> restoreFromTrash(TrashEntry entry) async {
    final bool ok = await FileQueryService.restoreFromTrash(entry);
    if (ok && _currentPath == Directory(entry.originalPath).parent.path) {
      await load(refresh: true);
    }
    return ok;
  }

  Future<bool> deleteForever(String trashPath) =>
      FileQueryService.deleteForever(trashPath);

  Future<void> emptyTrash() => FileQueryService.emptyTrash();

  Future<StorageUsage> getStorageUsage() => FileQueryService.getStorageUsage();

  Future<List<FileItem>> getLargestFiles({int limit = 20}) =>
      FileQueryService.getLargestFiles(limit: limit);

  Future<List<DuplicateGroup>> findDuplicates({
    String? rootPath,
    int minSize = 1024,
  }) =>
      FileQueryService.findDuplicates(
        rootPath: rootPath ?? FileProvider.rootPath,
        minSize: minSize,
      );

  Future<bool> requestAllFilesAccess() async {
    final bool granted = await PermissionService.requestAllFilesAccess();
    _allFilesAccess = granted;
    if (granted) {
      _volumes = await FileQueryService.loadStorageVolumes();
      await load(refresh: true);
    }
    _notify();
    return granted;
  }

  void _notify() {
    if (!_isDisposed) notifyListeners();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _isDisposed = true;
    super.dispose();
  }
}