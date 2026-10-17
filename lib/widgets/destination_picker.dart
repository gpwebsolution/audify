// Item 6.2 — seletor de destino (copiar/mover) extraído de
// lib/screens/files_screen.dart.

import 'dart:io';

import 'package:flutter/material.dart';

import '../models/file_item.dart';
import '../services/file_query_service.dart';

// =============================================================================
// SELETOR DE DESTINO (copiar/mover)
// =============================================================================

class DestinationPicker extends StatefulWidget {
  final String initialPath;

  const DestinationPicker({super.key, required this.initialPath});

  @override
  State<DestinationPicker> createState() => DestinationPickerState();
}

class DestinationPickerState extends State<DestinationPicker> {
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
