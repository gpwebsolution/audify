import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/file_query_service.dart';
import '../providers/file_provider.dart';

/// Lixeira interna do app: itens excluídos ficam aqui (fora do armazenamento
/// compartilhado) até restauração ou exclusão definitiva.
class TrashScreen extends StatefulWidget {
  const TrashScreen({super.key});

  @override
  State<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends State<TrashScreen> {
  List<TrashEntry> _entries = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final entries = await FileQueryService.listTrash();
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _isLoading = false;
    });
  }

  Future<void> _restore(TrashEntry entry) async {
    final ok = await context.read<FileProvider>().restoreFromTrash(entry);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok
          ? 'Restaurado para ${entry.originalPath}'
          : 'Falha ao restaurar (o local original ainda existe?)')),
    );
    await _load();
  }

  Future<void> _deleteForever(TrashEntry entry) async {
    final ok = await FileQueryService.deleteForever(entry.trashPath);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? 'Excluído definitivamente.' : 'Falha ao excluir.')),
    );
    await _load();
  }

  Future<void> _emptyAll() async {
    if (_entries.isEmpty) return;
    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Esvaziar lixeira?'),
        content: Text('${_entries.length} item(ns) serão excluídos DEFINITIVAMENTE.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancelar')),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            child: const Text('Esvaziar'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    await context.read<FileProvider>().emptyTrash();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Lixeira'),
        actions: [
          if (_entries.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_forever),
              tooltip: 'Esvaziar lixeira',
              onPressed: _emptyAll,
            ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _entries.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.delete_outline, size: 64, color: Theme.of(context).colorScheme.outline),
                      const SizedBox(height: 12),
                      const Text('A lixeira está vazia.'),
                    ],
                  ),
                )
              : ListView.separated(
                  itemCount: _entries.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final entry = _entries[index];
                    return ListTile(
                      leading: const Icon(Icons.delete_outline),
                      title: Text(entry.originalName, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        '${entry.originalPath}\nExcluído em ${entry.displayDeletedAt}'
                        '${entry.sizeBytes > 0 ? ' • ${formatBytes(entry.sizeBytes)}' : ''}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      isThreeLine: true,
                      trailing: PopupMenuButton<String>(
                        onSelected: (value) {
                          if (value == 'restore') _restore(entry);
                          if (value == 'delete') _deleteForever(entry);
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'restore', child: Text('Restaurar')),
                          PopupMenuItem(value: 'delete', child: Text('Excluir definitivamente')),
                        ],
                      ),
                    );
                  },
                ),
    );
  }
}
