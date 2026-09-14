import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/file_item.dart';
import '../providers/file_provider.dart';
import '../services/file_query_service.dart';
import '../services/image_metadata_service.dart';
import '../services/media_share_service.dart';

/// Detalhes completos de um arquivo: tamanho, datas, permissões POSIX e
/// EXIF quando for imagem — com opção de gerar cópia sem metadados
/// sensíveis (privacidade antes de compartilhar).
class FileDetailsScreen extends StatefulWidget {
  final FileItem item;

  const FileDetailsScreen({super.key, required this.item});

  @override
  State<FileDetailsScreen> createState() => _FileDetailsScreenState();
}

class _FileDetailsScreenState extends State<FileDetailsScreen> {
  late Future<FileDetails?> _details;

  @override
  void initState() {
    super.initState();
    _details = FileQueryService.getFileDetails(widget.item.path);
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Abrir',
            icon: const Icon(Icons.open_in_new),
            onPressed: () async {
              final bool ok =
                  await FileQueryService.openFile(widget.item.path);
              if (!ok && mounted) {
                ScaffoldMessenger.of(this.context).showSnackBar(const SnackBar(
                    content: Text('Nenhum app abre este tipo de arquivo.')));
              }
            },
          ),
          IconButton(
            tooltip: 'Compartilhar',
            icon: const Icon(Icons.share_outlined),
            onPressed: () => MediaShareService.shareFiles([widget.item.path]),
          ),
          IconButton(
            tooltip: 'Excluir',
            icon: Icon(Icons.delete_outline, color: colors.error),
            onPressed: _confirmDelete,
          ),
        ],
      ),
      body: FutureBuilder<FileDetails?>(
        future: _details,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final details = snapshot.data;
          if (details == null) {
            return const Center(child: Text('Não foi possível ler os detalhes.'));
          }

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _buildPreview(),
              const SizedBox(height: 16),
              _Section(
                title: 'Informações',
                children: [
                  _InfoRow('Nome', widget.item.name),
                  _InfoRow('Tipo', _typeLabel()),
                  _InfoRow('Extensão', widget.item.extension.isEmpty ? '—' : '.${widget.item.extension}'),
                  _InfoRow('Tamanho', formatBytes(details.size)),
                ],
              ),
              const SizedBox(height: 12),
              _Section(
                title: 'Localização e datas',
                children: [
                  SelectableText(widget.item.path,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(fontFamily: 'monospace')),
                  const SizedBox(height: 8),
                  _InfoRow('Criado', _fmtDate(details.dateCreated)),
                  _InfoRow('Modificado', _fmtDate(details.dateModified)),
                  _InfoRow('Pasta', widget.item.parentPath ?? '—'),
                ],
              ),
              const SizedBox(height: 12),
              _Section(
                title: 'Permissões (POSIX)',
                children: [
                  _InfoRow('Modo', details.permissions.isEmpty ? '—' : details.permissions,
                      mono: true),
                  _InfoRow('Oculto', details.isHidden ? 'Sim' : 'Não'),
                  _InfoRow('Somente leitura', details.isReadOnly ? 'Sim' : 'Não'),
                ],
              ),
              // ---- EXIF (imagens): câmera, GPS, dados técnicos ----
              if (widget.item.type == FileType.image)
                _ExifSection(exif: details.exifData ?? const {}, item: widget.item),
              const SizedBox(height: 32),
            ],
          );
        },
      ),
    );
  }

  Widget _buildPreview() {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Center(
      child: Container(
        width: double.infinity,
        height: 180,
        decoration: BoxDecoration(
          color: colors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(14),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: widget.item.type == FileType.image
              ? Image.file(File(widget.item.path), fit: BoxFit.contain,
                  cacheWidth: 800,
                  errorBuilder: (_, _, _) => Icon(widget.item.icon, size: 56))
              : Icon(widget.item.icon, size: 64, color: colors.onSurfaceVariant),
        ),
      ),
    );
  }

  String _typeLabel() {
    switch (widget.item.type) {
      case FileType.directory:
        return 'Pasta';
      case FileType.audio:
        return 'Áudio';
      case FileType.video:
        return 'Vídeo';
      case FileType.image:
        return 'Imagem';
      case FileType.pdf:
        return 'PDF';
      case FileType.document:
        return 'Documento';
      case FileType.archive:
        return 'Compactado';
      case FileType.apk:
        return 'Aplicativo Android (APK)';
      case FileType.code:
        return 'Código-fonte';
      case FileType.text:
        return 'Texto';
      case FileType.spreadsheet:
        return 'Planilha';
      case FileType.presentation:
        return 'Apresentação';
      case FileType.other:
        return 'Arquivo';
    }
  }

  static String _fmtDate(int seconds) {
    if (seconds <= 0) return '—';
    final DateTime dt = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
    return '${dt.day.toString().padLeft(2, '0')}/'
        '${dt.month.toString().padLeft(2, '0')}/${dt.year} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _confirmDelete() async {
    final provider = context.read<FileProvider>();
    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Excluir arquivo?'),
        content: Text('"${widget.item.name}" vai para a lixeira.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancelar')),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            child: const Text('Excluir'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    await provider.deleteSingle(widget.item.path, useTrash: true);
    if (mounted) Navigator.pop(context);
  }
}

// =============================================================================
// SEÇÃO EXIF
// =============================================================================

/// Mostra Make/Model, data da captura, GPS (com botão de copiar coordenadas
/// e abrir mapa externo), dimensões/técnica. App é offline: reverse geocoding
/// exigiria rede — exibimos as coordenadas puras.
class _ExifSection extends StatelessWidget {
  final Map<String, dynamic> exif;
  final FileItem item;

  const _ExifSection({required this.exif, required this.item});

  /// GPS em DMS (racionais) -> decimal.
  static double? _dmsToDecimal(List<num>? parts, String ref) {
    if (parts == null || parts.length < 3) return null;
    final double value =
        parts[0].toDouble() + parts[1].toDouble() / 60 + parts[2].toDouble() / 3600;
    return (ref == 'S' || ref == 'W') ? -value : value;
  }

  static List<num>? _parseRationals(String raw) {
    try {
      final List<String> pieces =
          raw.replaceAll('[', '').replaceAll(']', '').split(',');
      if (pieces.length < 3) return null;
      num parseOne(String s) {
        s = s.trim();
        if (s.contains('/')) {
          final List<String> f = s.split('/');
          return num.parse(f[0]) / (num.tryParse(f[1]) ?? 1);
        }
        return num.parse(s);
      }
      return [parseOne(pieces[0]), parseOne(pieces[1]), parseOne(pieces[2])];
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (exif.isEmpty) return const SizedBox();

    final String? lat = exif['GPSLatitude']?.toString();
    final String? lon = exif['GPSLongitude']?.toString();
    final double? latitude = _dmsToDecimal(_parseRationals(lat ?? ''), exif['GPSLatitudeRef']?.toString() ?? '');
    final double? longitude = _dmsToDecimal(_parseRationals(lon ?? ''), exif['GPSLongitudeRef']?.toString() ?? '');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        _Section(
          title: 'Metadados EXIF',
          children: [
            for (final entry in exif.entries.take(24))
              _InfoRow(entry.key, '${entry.value}'),
            if (latitude != null && longitude != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('Copiar coordenadas'),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(
                        text: '$latitude, $longitude'));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Coordenadas copiadas.')));
                    }
                  },
                ),
              ),
            const SizedBox(height: 4),
            Text(
              'Compartilhar sem localização: gere uma cópia sem GPS abaixo.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: OutlinedButton.icon(
                icon: const Icon(Icons.privacy_tip_outlined, size: 18),
                label: const Text('Salvar cópia sem metadados'),
                onPressed: () => _stripMetadata(context),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// Cria `<nome>_sem_exif.jpg` na MESMA pasta via ImageMetadataService.
  Future<void> _stripMetadata(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result =
          await ImageMetadataService.saveCopyWithoutMetadata(item.path);
      messenger.showSnackBar(SnackBar(
        content: Text(result == null
            ? 'Falha ao re-encodar imagem.'
            : 'Cópia limpa salva: ${result.split('/').last}'),
      ));
    } catch (e) {
      // Ação do usuário falhou: feedback obrigatório + log local.
      debugPrint('[FileDetails] stripMetadata(${item.path}): $e');
      messenger.showSnackBar(const SnackBar(
        content: Text('Não foi possível gerar a cópia sem metadados.'),
      ));
    }
  }
}

// =============================================================================
// WIDGETS DE APOIO
// =============================================================================

class _Section extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const _Section({required this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 10),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final bool mono;

  const _InfoRow(this.label, this.value, {this.mono = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 118,
            child: Text(label,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    )),
          ),
          Expanded(
            child: SelectableText(value,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontFamily: mono ? 'monospace' : null,
                    )),
          ),
        ],
      ),
    );
  }
}
