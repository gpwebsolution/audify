import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/file_provider.dart';
import '../providers/settings_provider.dart';
import '../services/file_query_service.dart';
import '../widgets/selection_bar.dart';

/// Lixeira interna do app: itens excluídos ficam aqui (fora do armazenamento
/// compartilhado, invisível ao gerenciador de arquivos do sistema) até a
/// restauração, a exclusão definitiva ou o fim do prazo.
///
/// Seleção múltipla: long-press marca, e a barra de lote restaura ou apaga
/// vários de uma vez — item por item era inviável numa lixeira com dezenas de
/// entradas.
class TrashScreen extends StatefulWidget {
  const TrashScreen({super.key});

  @override
  State<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends State<TrashScreen> with MediaSelection<String> {
  List<TrashEntry> _entries = [];
  bool _isLoading = true;

  /// Resumo do expurgo da última abertura ("3 itens expirados foram
  /// apagados"), mostrado uma única vez.
  String? _purgeNotice;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void notifyChanged() => setState(() {});

  Future<void> _load() async {
    final SettingsProvider settings = context.read<SettingsProvider>();
    final entries = await FileQueryService.listTrash();
    if (!mounted) return;

    // Expurgo ANTES de exibir: o usuário não deve precisar abrir a lixeira
    // para ver o que o prazo já recolheu.
    final int purged = await FileQueryService.purgeExpired(
      settings.trashRetentionDays,
    );
    final List<TrashEntry> after = purged == 0
        ? entries
        : await FileQueryService.listTrash();
    if (!mounted) return;

    setState(() {
      _entries = after;
      _isLoading = false;
      _purgeNotice = purged == 0
          ? null
          : purged == 1
          ? '1 item expirado foi apagado.'
          : '$purged itens expirados foram apagados.';
    });
  }

  List<TrashEntry> get _selectedEntries =>
      selectedFrom(_entries, (TrashEntry e) => e.trashPath);

  Future<void> _restore(TrashEntry entry) async {
    final bool ok = await context.read<FileProvider>().restoreFromTrash(entry);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Restaurado para ${entry.originalPath}'
              : 'Falha ao restaurar — o local original pode já existir.',
        ),
      ),
    );
    await _load();
  }

  Future<void> _deleteForever(TrashEntry entry) async {
    final bool ok = await FileQueryService.deleteForever(entry.trashPath);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? 'Excluído definitivamente.' : 'Falha ao excluir.'),
      ),
    );
    await _load();
  }

  /// Restaura os marcados, um a um, e informa quantos voltaram.
  ///
  /// Um por item porque o destino pode ter sido ocupado por outro arquivo —
  /// aí só aquele item falha, e o erro precisa ser visível em vez de engolido.
  Future<void> _restoreSelected() async {
    final List<TrashEntry> entries = _selectedEntries;
    if (entries.isEmpty) return;
    clearSelection();
    if (!mounted) return;

    final FileProvider files = context.read<FileProvider>();
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    int restored = 0;
    int failed = 0;
    for (final TrashEntry entry in entries) {
      if (await files.restoreFromTrash(entry)) {
        restored++;
      } else {
        failed++;
      }
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          failed == 0
              ? restored == 1
                    ? '1 item restaurado.'
                    : '$restored itens restaurados.'
              : '$restored restaurados, $failed falharam '
                    '(o local original pode já existir).',
        ),
      ),
    );
    await _load();
  }

  /// Apaga definitivamente os marcados, com confirmação.
  Future<void> _deleteSelectedForever() async {
    final List<TrashEntry> entries = _selectedEntries;
    if (entries.isEmpty) return;

    final int bytes = entries.fold<int>(
      0,
      (int sum, TrashEntry e) => sum + e.sizeBytes,
    );
    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text(
          entries.length == 1
              ? 'Excluir definitivamente?'
              : 'Excluir ${entries.length} itens definitivamente?',
        ),
        content: Text(
          'Esta ação não pode ser desfeita.'
          '${bytes > 0 ? '\n\n${formatBytes(bytes)} serão liberados.' : ''}',
        ),
        actions: <Widget>[
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
    if (confirm != true) return;
    clearSelection();
    if (!mounted) return;

    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    int deleted = 0;
    for (final TrashEntry entry in entries) {
      if (await FileQueryService.deleteForever(entry.trashPath)) deleted++;
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          deleted == entries.length
              ? deleted == 1
                    ? '1 item excluído definitivamente.'
                    : '$deleted itens excluídos definitivamente.'
              : '$deleted de ${entries.length} foram excluídos.',
        ),
      ),
    );
    await _load();
  }

  Future<void> _emptyAll() async {
    if (_entries.isEmpty) return;
    clearSelection();
    final int bytes = _entries.fold<int>(
      0,
      (int sum, TrashEntry e) => sum + e.sizeBytes,
    );
    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Esvaziar lixeira?'),
        content: Text(
          '${_entries.length} item(ns) serão excluídos DEFINITIVAMENTE.'
          '${bytes > 0 ? '\n\n${formatBytes(bytes)} serão liberados.' : ''}',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
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
    final int retention = context.watch<SettingsProvider>().trashRetentionDays;
    final ColorScheme colors = Theme.of(context).colorScheme;
    final int totalBytes = _entries.fold<int>(
      0,
      (int sum, TrashEntry e) => sum + e.sizeBytes,
    );

    return PopScope<void>(
      // Sair do modo seleção ao voltar, em vez de fechar a tela inteira.
      canPop: !isSelectionMode,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (!didPop && isSelectionMode) clearSelection();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            isSelectionMode ? '$selectionCount selecionado(s)' : 'Lixeira',
          ),
          actions: <Widget>[
            if (!isSelectionMode && _entries.isNotEmpty)
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
            ? _EmptyTrash(notice: _purgeNotice)
            : Column(
                children: <Widget>[
                  if (_purgeNotice != null)
                    _Notice(
                      text: _purgeNotice!,
                      onDismiss: () => setState(() => _purgeNotice = null),
                    ),
                  AnimatedToolbarSwap(
                    value: isSelectionMode,
                    selectionBar: SelectionBar(
                      label: '$selectionCount selecionado(s)',
                      onSelectAll: () => toggleSelectAll(
                        _entries.map((TrashEntry e) => e.trashPath),
                      ),
                      onClear: clearSelection,
                      onDelete: _deleteSelectedForever,
                      actions: <SelectionAction>[
                        SelectionAction(
                          icon: Icons.restore,
                          label: 'Restaurar selecionados',
                          onPressed: _restoreSelected,
                        ),
                        SelectionAction(
                          icon: Icons.swap_horiz,
                          label: 'Inverter seleção',
                          onPressed: () => invertSelection(
                            _entries.map((TrashEntry e) => e.trashPath),
                          ),
                        ),
                      ],
                    ),
                    toolbar: _InfoHeader(
                      count: _entries.length,
                      totalBytes: totalBytes,
                      retentionLabel: retention == 0
                          ? 'sem prazo de expiração'
                          : 'expiram em $retention dias',
                    ),
                  ),
                  Expanded(
                    child: ListView.separated(
                      itemCount: _entries.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (BuildContext context, int index) {
                        final TrashEntry entry = _entries[index];
                        final bool marked =
                            isSelectionMode && isSelected(entry.trashPath);
                        return ListTile(
                          selected: marked,
                          selectedTileColor: colors.secondaryContainer
                              .withValues(alpha: 0.5),
                          leading: isSelectionMode
                              ? Checkbox(
                                  value: isSelected(entry.trashPath),
                                  onChanged: (_) =>
                                      toggleSelect(entry.trashPath),
                                  materialTapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                )
                              : const Icon(Icons.delete_outline),
                          title: Text(
                            entry.originalName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '${entry.originalPath}\n'
                            'Excluído ${entry.ageLabel}'
                            '${entry.sizeBytes > 0 ? ' • ${entry.displaySize}' : ''}'
                            ' • ${entry.expiryLabel(retention)}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          isThreeLine: true,
                          trailing: isSelectionMode
                              ? null
                              : PopupMenuButton<String>(
                                  tooltip: 'Ações do item',
                                  onSelected: (String value) {
                                    if (value == 'restore') _restore(entry);
                                    if (value == 'delete') {
                                      _deleteForever(entry);
                                    }
                                  },
                                  itemBuilder: (_) =>
                                      const <PopupMenuEntry<String>>[
                                        PopupMenuItem<String>(
                                          value: 'restore',
                                          child: Text('Restaurar'),
                                        ),
                                        PopupMenuItem<String>(
                                          value: 'delete',
                                          child: Text(
                                            'Excluir definitivamente',
                                          ),
                                        ),
                                      ],
                                ),
                          onTap: isSelectionMode
                              ? () => toggleSelect(entry.trashPath)
                              : null,
                          onLongPress: () => toggleSelect(entry.trashPath),
                        );
                      },
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

/// Cabeçalho com o resumo da lixeira e o prazo vigente.
class _InfoHeader extends StatelessWidget {
  final int count;
  final int totalBytes;
  final String retentionLabel;

  const _InfoHeader({
    required this.count,
    required this.totalBytes,
    required this.retentionLabel,
  });

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        '$count ${count == 1 ? 'item' : 'itens'}'
        '${totalBytes > 0 ? ' • ${formatBytes(totalBytes)}' : ''}'
        '\nItens $retentionLabel. Ajuste em Configurações.',
        style: TextStyle(fontSize: 12.5, color: colors.onSurfaceVariant),
      ),
    );
  }
}

/// Aviso de expurgo automático, dispensável.
class _Notice extends StatelessWidget {
  final String text;
  final VoidCallback onDismiss;

  const _Notice({required this.text, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: colors.secondaryContainer,
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Row(
        children: <Widget>[
          Icon(Icons.auto_delete_outlined, size: 18, color: colors.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12.5,
                color: colors.onSecondaryContainer,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            tooltip: 'Dispensar',
            visualDensity: VisualDensity.compact,
            onPressed: onDismiss,
          ),
        ],
      ),
    );
  }
}

class _EmptyTrash extends StatelessWidget {
  final String? notice;

  const _EmptyTrash({this.notice});

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.delete_outline, size: 64, color: colors.outline),
            const SizedBox(height: 12),
            const Text('A lixeira está vazia.'),
            if (notice != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                notice!,
                textAlign: TextAlign.center,
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
