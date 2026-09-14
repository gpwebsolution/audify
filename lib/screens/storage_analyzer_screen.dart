import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/file_item.dart';
import '../providers/file_provider.dart';
import '../services/file_query_service.dart';
import 'file_details_screen.dart';

class StorageAnalyzerScreen extends StatefulWidget {
  const StorageAnalyzerScreen({super.key});

  @override
  State<StorageAnalyzerScreen> createState() => _StorageAnalyzerScreenState();
}

class _StorageAnalyzerScreenState extends State<StorageAnalyzerScreen> {
  StorageUsage? _usage;
  List<FileItem> _largestFiles = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final provider = context.read<FileProvider>();
    final usage = await provider.getStorageUsage();
    final largest = await provider.getLargestFiles(limit: 20);
    if (mounted) {
      setState(() {
        _usage = usage;
        _largestFiles = largest;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Analisador de Armazenamento'), actions: [
        IconButton(icon: const Icon(Icons.refresh), onPressed: _loadData, tooltip: 'Atualizar'),
      ]),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadData,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildOverview(),
                    const SizedBox(height: 24),
                    _buildCategoryBreakdown(),
                    const SizedBox(height: 24),
                    _buildLargestFiles(),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildOverview() {
    if (_usage == null) return const SizedBox();

    final ColorScheme colors = Theme.of(context).colorScheme;
    final double usagePercent = _usage!.totalSpace > 0
        ? _usage!.usedSpace / _usage!.totalSpace
        : 0.0;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Visão geral', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Espaço total', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant)),
                      Text(_usage!.displayTotalSpace, style: Theme.of(context).textTheme.headlineMedium),
                    ],
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Espaço livre', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant)),
                      Text(_usage!.displayFreeSpace, style: Theme.of(context).textTheme.headlineMedium?.copyWith(color: colors.primary)),
                    ],
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Espaço usado', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant)),
                      Text(_usage!.displayUsedSpace, style: Theme.of(context).textTheme.headlineMedium?.copyWith(color: colors.error)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                height: 12,
                child: LinearProgressIndicator(
                  value: usagePercent.clamp(0.0, 1.0),
                  backgroundColor: colors.surfaceContainerHighest,
                  valueColor: AlwaysStoppedAnimation<Color>(usagePercent > 0.9 ? colors.error : colors.primary),
                  minHeight: 12,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text('${(usagePercent * 100).toStringAsFixed(1)}% usado', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }

  Widget _buildCategoryBreakdown() {
    if (_usage == null || _usage!.byCategory.isEmpty) return const SizedBox();

    final ColorScheme colors = Theme.of(context).colorScheme;
    final categories = _usage!.byCategory.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Uso por categoria', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            ...categories.map((entry) {
              final double percent = _usage!.usedSpace > 0 ? entry.value / _usage!.usedSpace : 0;
              final Color color = _categoryColor(entry.key);
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(width: 12, height: 12, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                        const SizedBox(width: 8),
                        Expanded(child: Text(_categoryLabel(entry.key), style: Theme.of(context).textTheme.bodyMedium)),
                        Text(_formatBytes(entry.value), style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                      ],
                    ),
                    const SizedBox(height: 4),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: SizedBox(
                        height: 8,
                        child: LinearProgressIndicator(
                          value: percent.clamp(0.0, 1.0),
                          backgroundColor: colors.surfaceContainerHighest,
                          valueColor: AlwaysStoppedAnimation<Color>(color),
                          minHeight: 8,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildLargestFiles() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Top 20 maiores arquivos', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            if (_largestFiles.isEmpty)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text('Nenhum arquivo encontrado', style: Theme.of(context).textTheme.bodyMedium),
                ),
              )
            else
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _largestFiles.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final item = _largestFiles[index];
                  return ListTile(
                    leading: Icon(item.icon, color: Theme.of(context).colorScheme.primary),
                    title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(item.path, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
                    trailing: Text(item.displaySize, style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => FileDetailsScreen(item: item)),
                      );
                    },
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  String _categoryLabel(String key) {
    switch (key) {
      case 'images':
        return 'Imagens';
      case 'videos':
        return 'Vídeos';
      case 'audio':
        return 'Áudio';
      case 'documents':
        return 'Documentos';
      case 'apk':
        return 'APKs';
      case 'archives':
        return 'Compactados';
      case 'cache':
        return 'Cache do app';
      default:
        return 'Outros';
    }
  }

  Color _categoryColor(String key) {
    switch (key) {
      case 'images':
        return Colors.green;
      case 'videos':
        return Colors.blue;
      case 'audio':
        return Colors.orange;
      case 'documents':
        return Colors.purple;
      case 'apk':
        return Colors.teal;
      case 'archives':
        return Colors.amber;
      case 'cache':
        return Colors.grey;
      default:
        return Colors.grey;
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}