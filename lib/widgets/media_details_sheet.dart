import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/gallery_image_model.dart';
import '../models/pdf_file_model.dart';
import '../models/song_model.dart';
import '../models/video_model.dart';
import '../services/file_query_service.dart' show formatBytes;
import '../utils/format.dart';

/// Painel de detalhes de um arquivo do aparelho.
///
/// Ponto único de "informações" do app: música, vídeo, foto e PDF abrem
/// exatamente esta folha. Antes these dados não apareciam em lugar nenhum —
/// havia `ListTile` com ícone de "info" que não faziam nada ao toque.
///
/// [onShowExif] é opcional: só a galeria sabe extrair EXIF (que exige o
/// arquivo em disco); quando ausente, o botão simplesmente não aparece em vez
/// de aparecer quebrado.
class MediaDetailsSheet extends StatelessWidget {
  /// Ícone grande no cabeçalho.
  final IconData icon;

  /// Cor de destaque do ícone (dá o tom do tipo de mídia).
  final Color iconColor;

  final String title;
  final String? subtitle;

  /// Caminho absoluto — habilita o botão "copiar caminho".
  final String? path;

  /// Linhas "rótulo: valor". Rótulo ou valor vazio = linha omitida, então
  /// cada tipo de mídia passa só o que realmente tem.
  final List<(String?, String?)> rows;

  /// Abre os metadados EXIF (só imagens).
  final VoidCallback? onShowExif;

  /// Abre o visualizador em tela cheia (só fotos).
  final VoidCallback? onOpenFullscreen;

  const MediaDetailsSheet({
    super.key,
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.rows,
    this.subtitle,
    this.path,
    this.onShowExif,
    this.onOpenFullscreen,
  });

  /// Abre a folha de detalhes de uma música.
  static Future<void> showSong(BuildContext context, Song song) {
    final bool isAsset = song.isAsset;
    return show(
      context,
      icon: isAsset ? Icons.library_music : Icons.music_note,
      iconColor: isAsset ? Colors.teal : Colors.indigo,
      title: song.title,
      subtitle: song.displayArtist,
      path: song.filePath,
      rows: <(String?, String?)>[
        ('Título', song.title),
        ('Artista', song.displayArtist),
        ('Álbum', song.album),
        (
          'Duração',
          song.duration == null ? null : formatDuration(song.duration!),
        ),
        ('Origem', isAsset ? 'Embutida no app' : 'Armazenamento do aparelho'),
        ('Nome do arquivo', _fileNameOf(song.filePath)),
        ('Extensão', _extensionOf(song.filePath)),
        ('Tamanho', isAsset ? null : _sizeOfPath(song.filePath)),
        ('Modificado', _modifiedOfPath(song.filePath)),
        ('Caminho', song.filePath),
        ('ID no MediaStore', song.mediaId?.toString()),
      ],
    );
  }

  /// Abre a folha de detalhes de um vídeo.
  static Future<void> showVideo(BuildContext context, Video video) {
    return show(
      context,
      icon: Icons.movie,
      iconColor: Colors.deepPurple,
      title: video.displayTitle,
      subtitle: formatDuration(video.duration),
      path: video.path,
      rows: <(String?, String?)>[
        ('Título', video.title),
        ('Nome do arquivo', video.displayName),
        ('Duração', formatDuration(video.duration)),
        ('Tamanho', formatBytes(video.size)),
        ('Adicionado em', _dateOf(video.dateAdded)),
        ('Extensão', _extensionOf(video.displayName)),
        ('Caminho', video.path),
        ('ID no MediaStore', video.id.toString()),
      ],
    );
  }

  /// Abre a folha de detalhes de uma foto.
  static Future<void> showImage(
    BuildContext context,
    GalleryImage image, {
    VoidCallback? onShowExif,
    VoidCallback? onOpenFullscreen,
  }) {
    final bool hasSize = image.width > 0 && image.height > 0;
    return show(
      context,
      icon: Icons.image,
      iconColor: Colors.teal,
      title: image.name,
      path: image.path,
      onShowExif: onShowExif,
      onOpenFullscreen: onOpenFullscreen,
      rows: <(String?, String?)>[
        ('Nome do arquivo', image.name),
        ('Dimensões', hasSize ? '${image.width} x ${image.height} px' : null),
        if (hasSize)
          (
            'Megapixels',
            '${((image.width * image.height) / 1000000).toStringAsFixed(1)} MP',
          ),
        ('Tamanho', formatBytes(image.size)),
        ('Adicionado em', _dateOf(image.dateAdded)),
        ('Extensão', _extensionOf(image.name)),
        ('Caminho', image.path),
        ('ID no MediaStore', image.id.toString()),
      ],
    );
  }

  /// Abre a folha de detalhes de um PDF.
  static Future<void> showPdf(BuildContext context, PdfFile pdf) {
    final bool fromMediaStore = pdf.id.startsWith('pdf-');
    return show(
      context,
      icon: Icons.picture_as_pdf,
      iconColor: Colors.red,
      title: pdf.name,
      path: pdf.path,
      rows: <(String?, String?)>[
        ('Nome do arquivo', pdf.name),
        ('Tamanho', formatBytes(pdf.size)),
        ('Adicionado em', _dateOf(pdf.dateAdded)),
        ('Extensão', 'PDF'),
        ('Caminho', pdf.path),
        (
          'Origem',
          fromMediaStore ? 'Armazenamento do aparelho' : 'Seletor de arquivos',
        ),
        ('ID no MediaStore', fromMediaStore ? pdf.id.substring(4) : null),
      ],
    );
  }

  /// Abre a folha.
  static Future<void> show(
    BuildContext context, {
    required IconData icon,
    required Color iconColor,
    required String title,
    required List<(String?, String?)> rows,
    String? subtitle,
    String? path,
    VoidCallback? onShowExif,
    VoidCallback? onOpenFullscreen,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (BuildContext sheetContext) => MediaDetailsSheet(
        icon: icon,
        iconColor: iconColor,
        title: title,
        subtitle: subtitle,
        path: path,
        rows: rows,
        onShowExif: onShowExif,
        onOpenFullscreen: onOpenFullscreen,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final List<(String, String)> visible = <(String, String)>[
      for (final (String? label, String? value) in rows)
        if (label != null &&
            label.isNotEmpty &&
            value != null &&
            value.isNotEmpty)
          (label, value),
    ];

    return SafeArea(
      child: ConstrainedBox(
        // Nunca mais alto que 80% da tela: caminho + datas ocupam espaço e a
        // folha precisa rolar em telas baixas.
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.8,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _Header(
              icon: icon,
              iconColor: iconColor,
              title: title,
              subtitle: subtitle,
              path: path,
            ),
            const Divider(height: 1),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 4),
                children: <Widget>[
                  for (final (String label, String value) in visible)
                    _DetailRow(label: label, value: value),
                  if (onShowExif != null)
                    ListTile(
                      leading: Icon(
                        Icons.photo_camera_outlined,
                        color: colors.primary,
                      ),
                      title: const Text('Ver dados EXIF'),
                      subtitle: const Text('Câmera, data e GPS da foto'),
                      onTap: () {
                        Navigator.pop(context);
                        onShowExif!();
                      },
                    ),
                  if (onOpenFullscreen != null)
                    ListTile(
                      leading: Icon(Icons.fullscreen, color: colors.primary),
                      title: const Text('Abrir em tela cheia'),
                      onTap: () {
                        Navigator.pop(context);
                        onOpenFullscreen!();
                      },
                    ),
                  if (visible.isEmpty &&
                      onShowExif == null &&
                      onOpenFullscreen == null)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'Nenhuma informação disponível para este arquivo.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String? subtitle;
  final String? path;

  const _Header({
    required this.icon,
    required this.iconColor,
    required this.title,
    this.subtitle,
    this.path,
  });

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      child: Row(
        children: <Widget>[
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: iconColor, size: 28),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (subtitle != null && subtitle!.isNotEmpty)
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          if (path != null && path!.isNotEmpty)
            IconButton(
              tooltip: 'Copiar caminho',
              icon: const Icon(Icons.copy_all_outlined),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: path!));
                Navigator.pop(context);
                messenger.showSnackBar(
                  const SnackBar(content: Text('Caminho copiado.')),
                );
              },
            ),
        ],
      ),
    );
  }
}

/// Uma linha "rótulo / valor". O valor quebra linha porque caminho é longo.
class _DetailRow extends StatelessWidget {
  final String label;
  final String value;

  const _DetailRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 118,
            child: Text(
              label,
              style: TextStyle(color: colors.onSurfaceVariant, fontSize: 13),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: SelectableText(
              value,
              style: const TextStyle(fontSize: 13.5),
            ),
          ),
        ],
      ),
    );
  }
}

/// Nome do arquivo a partir do caminho.
String? _fileNameOf(String? path) {
  if (path == null || path.isEmpty) return null;
  return path.split('/').last;
}

/// Extensão em maiúsculas, ou null quando não há extensão.
String? _extensionOf(String? name) {
  final String? base = _fileNameOf(name);
  if (base == null) return null;
  final int dot = base.lastIndexOf('.');
  if (dot <= 0 || dot == base.length - 1) return null;
  return base.substring(dot + 1).toUpperCase();
}

/// Data legível a partir de epoch SEGUNDOS (é o que o MediaStore usa).
String _dateOf(int epochSeconds) {
  if (epochSeconds <= 0) return 'desconhecida';
  final DateTime date = DateTime.fromMillisecondsSinceEpoch(
    epochSeconds * 1000,
  );
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(date.day)}/${two(date.month)}/${date.year} '
      '${two(date.hour)}:${two(date.minute)}';
}

/// Tamanho do arquivo em disco, já formatado (null se ilegível).
///
/// Música e PDF não trazem tamanho do MediaStore, então ele é lido do disco.
/// Falha silenciosa de propósito: um campo ausente é melhor que uma tela de
/// detalhes que falha ao abrir.
String? _sizeOfPath(String? path) {
  final int? bytes = _statOf(path)?.size;
  return bytes == null ? null : formatBytes(bytes);
}

/// "modificado em ..." a partir da data do arquivo (null se ilegível).
String? _modifiedOfPath(String? path) {
  final FileStat? stat = _statOf(path);
  if (stat == null) return null;
  final DateTime when = stat.modified;
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(when.day)}/${two(when.month)}/${when.year} '
      '${two(when.hour)}:${two(when.minute)}';
}

FileStat? _statOf(String? path) {
  if (path == null || path.isEmpty) return null;
  try {
    final File file = File(path);
    if (!file.existsSync()) return null;
    return file.statSync();
  } on FileSystemException {
    return null;
  }
}
