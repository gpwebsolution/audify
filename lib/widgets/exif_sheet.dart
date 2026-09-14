import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/file_query_service.dart';
import '../services/image_metadata_service.dart';

/// Bottom sheet com os metadados EXIF de uma imagem — câmera, data da
/// captura, dados técnicos e GPS. App 100% offline: mostramos as
/// coordenadas puras (com botão de copiar), sem reverse geocoding.
///
/// Também oferece "Salvar cópia sem metadados": re-encode via image package
/// descarta todos os blocos EXIF/GPS antes de compartilhar.
Future<void> showExifSheet(BuildContext context, String imagePath) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => SafeArea(
      child: FutureBuilder<FileDetails?>(
        future: FileQueryService.getFileDetails(imagePath),
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          final details = snapshot.data;
          if (details == null) {
            return const Padding(
              padding: EdgeInsets.all(24),
              child: Text('Não foi possível ler os metadados.'),
            );
          }
          return _ExifContent(details: details);
        },
      ),
    ),
  );
}

class _ExifContent extends StatelessWidget {
  final FileDetails details;

  const _ExifContent({required this.details});

  static double? _dmsToDecimal(List<num>? parts, String ref) {
    if (parts == null || parts.length < 3) return null;
    final double value = parts[0].toDouble() +
        parts[1].toDouble() / 60 +
        parts[2].toDouble() / 3600;
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

  /// Rótulos amigáveis para as tags EXIF mais úteis (ordem de exibição).
  static const Map<String, String> _labels = {
    'Image Make': 'Fabricante',
    'Image Model': 'Modelo',
    'Image DateTime': 'Data da captura',
    'EXIF DateTimeOriginal': 'Original',
    'EXIF ExposureTime': 'Tempo de exposição',
    'EXIF FNumber': 'Abertura',
    'EXIF ISOSpeedRatings': 'ISO',
    'EXIF FocalLength': 'Distância focal',
    'EXIF Flash': 'Flash',
    'EXIF LensModel': 'Lente',
  };

  @override
  Widget build(BuildContext context) {
    final Map<String, dynamic> exif =
        details.exifData ?? const <String, dynamic>{};
    final ColorScheme colors = Theme.of(context).colorScheme;

    final String? latRaw = exif['GPSLatitude']?.toString();
    final String? lonRaw = exif['GPSLongitude']?.toString();
    final double? latitude =
        _dmsToDecimal(_parseRationals(latRaw ?? ''), exif['GPSLatitudeRef']?.toString() ?? '');
    final double? longitude =
        _dmsToDecimal(_parseRationals(lonRaw ?? ''), exif['GPSLongitudeRef']?.toString() ?? '');

    final List<Widget> rows = <Widget>[
      _Row('Tamanho', formatBytes(details.size)),
      for (final entry in exif.entries)
        if (_labels.containsKey(entry.key)) _Row(_labels[entry.key]!, '${entry.value}'),
      if (latitude != null && longitude != null)
        _Row(
            'Localização',
            '${latitude.toStringAsFixed(6)}, ${longitude.toStringAsFixed(6)}'),
    ];

    final bool hasAnyMetadata = exif.isNotEmpty;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.55,
      minChildSize: 0.35,
      maxChildSize: 0.9,
      builder: (context, scrollController) => ListView(
        controller: scrollController,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        children: [
          Text(
            details.name,
            style: Theme.of(context).textTheme.titleMedium,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          SelectableText(
            details.path,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(fontFamily: 'monospace'),
          ),
          const Divider(height: 24),
          ...rows,
          if (!hasAnyMetadata)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'Esta imagem não possui metadados EXIF.',
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: colors.onSurfaceVariant),
              ),
            ),
          if (latitude != null && longitude != null) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.copy, size: 18),
              label: const Text('Copiar coordenadas GPS'),
              onPressed: () async {
                await Clipboard.setData(
                    ClipboardData(text: '$latitude, $longitude'));
                if (context.mounted) {
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Coordenadas copiadas.')));
                }
              },
            ),
          ],
          if (hasAnyMetadata) ...[
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              icon: const Icon(Icons.privacy_tip_outlined, size: 18),
              label: const Text('Salvar cópia sem metadados'),
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                final navigator = Navigator.of(context);
                final String? result =
                    await ImageMetadataService.saveCopyWithoutMetadata(
                        details.path);
                messenger.showSnackBar(SnackBar(
                  content: Text(result == null
                      ? 'Falha ao re-encodar imagem.'
                      : 'Cópia limpa salva: ${result.split('/').last}'),
                ));
                navigator.pop();
              },
            ),
            const SizedBox(height: 4),
            Text(
              'Cria "<nome>_sem_exif.jpg" na mesma pasta — compartilhe sem '
              'expor localização ou aparelho.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  final String label;
  final String value;

  const _Row(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 132,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
          Expanded(
            child: SelectableText(value,
                style: Theme.of(context).textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }
}
