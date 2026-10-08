import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/file_item.dart';
import '../services/file_query_service.dart';

/// Detecção de duplicados por hash SHA-256 do CONTEÚDO.
///
/// Nunca exclui nada sozinho: agrupa, o usuário revisa cada grupo escolhe
/// quais cópias manter (checkboxes). A primeira cópia de cada grupo vem
/// pré-marcada para exclusão — regra comum de FMs — mas sempre editável.
class DuplicateFilesScreen extends StatefulWidget {
  const DuplicateFilesScreen({super.key});

  @override
  State<DuplicateFilesScreen> createState() => _DuplicateFilesScreenState();
}

class _DuplicateFilesScreenState extends State<DuplicateFilesScreen> {
  List<DuplicateGroup> _groups = [];

  /// Caminhos marcados para exclusão (default: todas menos a 1ª de cada grupo).
  final Set<String> _marked = <String>{};
  bool _scanning = true;
  bool _deleting = false;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    setState(() => _scanning = true);
    final List<DuplicateGroup> groups = await FileQueryService.findDuplicates(
      rootPath: '/storage/emulated/0',
      minSize: 100 * 1024,
    );
    final Set<String> marked = <String>{};
    for (final DuplicateGroup group in groups) {
      // Mantém a PRIMEIRA cópia (ordem do serviço), marca as demais.
      for (final FileItem file in group.files.skip(1)) {
        marked.add(file.path);
      }
    }
    if (!mounted) return;
    setState(() {
      _groups = groups;
      _marked
        ..clear()
        ..addAll(marked);
      _scanning = false;
    });
  }

  int get _freedBytes {
    int total = 0;
    for (final DuplicateGroup group in _groups) {
      for (final FileItem file in group.files) {
        if (_marked.contains(file.path)) total += file.size;
      }
    }
    return total;
  }

  Future<void> _deleteMarked() async {
    if (_marked.isEmpty || _deleting) return;
    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Excluir duplicatas?'),
        content: Text(
          '${_marked.length} arquivo(s) serão movidos para a lixeira '
          '(${formatBytes(_freedBytes)} liberados). '
          'Nada é apagado permanentemente agora.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Mover p/ lixeira'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    setState(() => _deleting = true);
    final List<String> targets = _marked.toList();
    for (final String path in targets) {
      await FileQueryService.delete(path: path, useTrash: true);
      _marked.remove(path);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${targets.length} duplicata(s) movida(s) para a lixeira.',
        ),
      ),
    );
    await _scan();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Arquivos duplicados')),
      body: _buildBody(context),
      bottomNavigationBar: (!_scanning && _groups.isNotEmpty)
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${_marked.length} marcado(s) • ${formatBytes(_freedBytes)}',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _marked.isEmpty || _deleting
                            ? null
                            : _deleteMarked,
                        icon: _deleting
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.cleaning_services_outlined),
                        label: const Text('Excluir selecionadas'),
                      ),
                    ),
                  ],
                ),
              ),
            )
          : null,
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_scanning) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(
              'Varrendo armazenamento e calculando hashes…\n'
              'Pode levar um minuto em bibliotecas grandes.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      );
    }

    if (_groups.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.verified_outlined,
              size: 64,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 12),
            const Text(
              'Nenhuma duplicata encontrada.\nSeu armazenamento está limpo!',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      itemCount: _groups.length,
      itemBuilder: (context, index) {
        final DuplicateGroup group = _groups[index];
        return Card(
          margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
          child: ExpansionTile(
            // Capa do que está duplicado: o usuário reconhece o arquivo pela
            // imagem antes de ler o nome.
            leading: _DuplicatePreview(
              file: group.files.first,
              size: 44,
              fallbackIcon: Icons.content_copy,
              fallbackColor: Theme.of(context).colorScheme.primary,
            ),
            title: Text(
              group.files.first.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '${group.count} cópias idênticas • ${group.displaySize}',
            ),
            childrenPadding: const EdgeInsets.only(bottom: 8),
            children: group.files
                .map(
                  (file) => CheckboxListTile(
                    key: ValueKey(file.path),
                    value: _marked.contains(file.path),
                    onChanged: (checked) => setState(() {
                      if (checked == true) {
                        _marked.add(file.path);
                      } else {
                        _marked.remove(file.path);
                      }
                    }),
                    secondary: _DuplicatePreview(
                      file: file,
                      size: 40,
                      fallbackIcon: Icons.insert_drive_file_outlined,
                    ),
                    title: Text(
                      file.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${file.parentPath ?? ''} • ${file.displayDateModified}',
                    ),
                  ),
                )
                .toList(),
          ),
        );
      },
    );
  }
}

/// Miniatura de um arquivo duplicado.
///
/// Imagem decodifica direto do disco (mais barato que ir ao nativo); vídeo e
/// PDF usam o decodificador do SO via [FileQueryService.getThumbnail], que já
/// tem cache em memória e em disco. Qualquer outro tipo cai no ícone.
class _DuplicatePreview extends StatelessWidget {
  final FileItem file;
  final double size;
  final IconData fallbackIcon;
  final Color? fallbackColor;

  const _DuplicatePreview({
    required this.file,
    required this.size,
    required this.fallbackIcon,
    this.fallbackColor,
  });

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;

    Widget placeholder() => Icon(
      fallbackIcon,
      size: size * 0.6,
      color: fallbackColor ?? colors.onSurfaceVariant,
    );

    if (file.type == FileType.image) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image.file(
          File(file.path),
          width: size,
          height: size,
          fit: BoxFit.cover,
          // `errorBuilder` é obrigatório: arquivo apagado, corrompido ou sem
          // permissão não pode estourar exceção na lista de duplicados.
          errorBuilder: (_, _, _) => placeholder(),
          gaplessPlayback: true,
        ),
      );
    }

    if (file.type == FileType.video || file.type == FileType.pdf) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: FutureBuilder<Uint8List?>(
          future: FileQueryService.getThumbnail(file.path, width: 160),
          builder: (context, snapshot) {
            final Uint8List? data = snapshot.data;
            if (data == null || data.isEmpty) return placeholder();
            return Image.memory(
              data,
              width: size,
              height: size,
              fit: BoxFit.cover,
              gaplessPlayback: true,
            );
          },
        ),
      );
    }

    return placeholder();
  }
}
