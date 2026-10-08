import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/file_item.dart';
import '../services/file_query_service.dart';

/// Gerenciador de APKs: todos os .apk do armazenamento interno, com nome de
/// pacote/versão quando o Android consegue parsear o manifest embutido,
/// instalação direta e exclusão em lote.
class ApkManagerScreen extends StatefulWidget {
  const ApkManagerScreen({super.key});

  @override
  State<ApkManagerScreen> createState() => _ApkManagerScreenState();
}

class _ApkManagerScreenState extends State<ApkManagerScreen> {
  List<FileItem> _apks = [];
  final Set<String> _selected = <String>{};
  bool _isLoading = true;
  bool _selectionMode = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      // Busca recursiva em todo o armazenamento interno; Android/data é
      // ignorado pelo serviço — APKs de uso real ficam fora dele.
      _apks = await FileQueryService.searchFiles(
        query: '.apk',
        rootPath: '/storage/emulated/0',
        limit: 500,
        filterType: FileType.apk,
      );
      _apks.sort((a, b) => b.size.compareTo(a.size));
    } catch (e) {
      _error = 'Falha ao procurar APKs: $e';
    }
    if (mounted) setState(() => _isLoading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _selectionMode
              ? '${_selected.length} selecionado(s)'
              : 'Gerenciador de APKs',
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _scan,
            tooltip: 'Reescanear',
          ),
          if (_selectionMode) ...[
            IconButton(
              icon: const Icon(Icons.delete_outline),
              color: Theme.of(context).colorScheme.error,
              tooltip: 'Excluir selecionados',
              onPressed: _deleteSelected,
            ),
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => setState(() {
                _selected.clear();
                _selectionMode = false;
              }),
            ),
          ],
        ],
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_isLoading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!, textAlign: TextAlign.center),
        ),
      );
    }
    if (_apks.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.android_outlined, size: 64, color: Colors.grey),
            SizedBox(height: 12),
            Text('Nenhum APK encontrado no armazenamento.'),
          ],
        ),
      );
    }

    return ListView.separated(
      itemCount: _apks.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) => _buildTile(context, _apks[index]),
    );
  }

  Widget _buildTile(BuildContext context, FileItem apk) {
    final bool isSelected = _selected.contains(apk.path);
    return ListTile(
      leading: _selectionMode
          ? Checkbox(value: isSelected, onChanged: (_) => _toggle(apk.path))
          // Ícone real do app, embutido no APK (lido do manifesto pelo
          // nativo). Cai no ícone genérico quando o APK não tem ícone — o
          // `FutureBuilder` fica durante o carregamento, então o placeholder
          // evita o "salto" de layout.
          : FutureBuilder<ApkInfo?>(
              future: FileQueryService.getApkInfo(apk.path),
              builder: (context, snapshot) {
                final Uint8List? icon = snapshot.data?.icon;
                if (icon == null || icon.isEmpty) {
                  return const Icon(Icons.android, size: 32);
                }
                return ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.memory(
                    icon,
                    width: 32,
                    height: 32,
                    fit: BoxFit.contain,
                    // Ícone de app costuma ter cantos arredondados próprios;
                    // sem isso um PNG quadrado fica solto no tile.
                    filterQuality: FilterQuality.medium,
                    gaplessPlayback: true,
                  ),
                );
              },
            ),
      title: Text(apk.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: FutureBuilder<ApkInfo?>(
        future: FileQueryService.getApkInfo(apk.path),
        builder: (context, snapshot) {
          final info = snapshot.data;
          final String pkg = info == null
              ? ''
              : '${info.appName} • v${info.versionName}';
          return Text(
            [apk.displaySize, if (pkg.isNotEmpty) pkg].join(' • '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          );
        },
      ),
      trailing: _selectionMode ? null : const Icon(Icons.chevron_right),
      onTap: () =>
          _selectionMode ? _toggle(apk.path) : _showActions(context, apk),
      onLongPress: () {
        if (!_selectionMode) setState(() => _selectionMode = true);
        _toggle(apk.path);
      },
    );
  }

  void _toggle(String path) {
    setState(() {
      if (!_selected.add(path)) _selected.remove(path);
      if (_selected.isEmpty) _selectionMode = false;
    });
  }

  void _showActions(BuildContext context, FileItem apk) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.install_mobile),
              title: const Text('Instalar'),
              onTap: () async {
                Navigator.pop(sheetContext);
                final bool ok = await FileQueryService.openFile(apk.path);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        ok
                            ? 'Instalação iniciada'
                            : 'Não foi possível iniciar a instalação',
                      ),
                    ),
                  );
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('Detalhes'),
              onTap: () async {
                Navigator.pop(sheetContext);
                final info = await FileQueryService.getApkInfo(apk.path);
                if (!context.mounted) return;
                showDialog<void>(
                  context: context,
                  builder: (_) => AlertDialog(
                    title: Text(apk.name),
                    content: Text(
                      info == null
                          ? 'Metadados indisponíveis para este APK.'
                          : 'App: ${info.appName}\n'
                                'Pacote: ${info.packageName}\n'
                                'Versão: ${info.versionName} (${info.versionCode})\n'
                                'Tamanho: ${apk.displaySize}\n'
                                'Caminho: ${apk.path}',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('OK'),
                      ),
                    ],
                  ),
                );
              },
            ),
            ListTile(
              leading: Icon(
                Icons.delete_outline,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(
                'Excluir',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              onTap: () async {
                Navigator.pop(sheetContext);
                await FileQueryService.delete(path: apk.path, useTrash: true);
                await _scan();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteSelected() async {
    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Excluir APKs?'),
        content: Text('${_selected.length} arquivo(s) vão para a lixeira.'),
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

    int okCount = 0;
    for (final String path in _selected) {
      if (await FileQueryService.delete(path: path, useTrash: true)) okCount++;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '$okCount de ${_selected.length} excluído(s). Restaurável na Lixeira.',
        ),
      ),
    );
    setState(() {
      _selected.clear();
      _selectionMode = false;
    });
    await _scan();
  }
}
