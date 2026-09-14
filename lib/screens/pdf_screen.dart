import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/pdf_file_model.dart';
import '../providers/pdf_provider.dart';
import '../services/pdf_favorites_service.dart';
import '../services/pdf_progress_service.dart';
import '../services/pdf_query_service.dart';
import '../widgets/media_actions.dart';
import 'pdf_viewer_screen.dart';

/// Aba de PDFs: documentos do aparelho (MediaStore) + seletor do sistema.
///
/// O botão "Selecionar PDF" (SAF) é o caminho confiável no Android 13+,
/// onde o caminho de PDFs de terceiros pode não ser legível sem a
/// permissão de armazenamento (que deixou de existir nessa versão).
///
/// Organização: favoritos primeiro (estrela persistida em SharedPreferences),
/// depois mais recentes; nº de páginas exibido no subtítulo (PdfRenderer
/// nativo, lazy por tile).
class PdfScreen extends StatefulWidget {
  const PdfScreen({super.key});

  @override
  State<PdfScreen> createState() => _PdfScreenState();
}

class _PdfScreenState extends State<PdfScreen> {
  String? _lastShownError;

  @override
  void initState() {
    super.initState();
    context.read<PdfFavoritesService>().load();
  }

  @override
  Widget build(BuildContext context) {
    final PdfProvider provider = context.watch<PdfProvider>();
    final PdfFavoritesService favorites = context.watch<PdfFavoritesService>();

    final String? error = provider.errorMessage;
    if (error != null && error != _lastShownError) {
      _lastShownError = error;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(error),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      });
    }

    // Favoritos primeiro, depois mais recentes.
    final List<PdfFile> sorted = [...provider.pdfs]..sort((a, b) {
        final bool favA = favorites.isFavorite(a.path);
        final bool favB = favorites.isFavorite(b.path);
        if (favA != favB) return favA ? -1 : 1;
        return b.dateAdded.compareTo(a.dateAdded);
      });

    return Column(
      children: [
        // ---- Ações ----
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton.tonalIcon(
              onPressed: () async {
                final PdfFile? picked = await provider.pickPdf();
                if (picked == null) return;
                if (!context.mounted) return;
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => PdfViewerScreen(pdf: picked),
                  ),
                );
              },
              icon: const Icon(Icons.folder_open_outlined),
              label: const Text('Selecionar PDF'),
            ),
          ),
        ),
        Expanded(child: _buildBody(context, provider, favorites, sorted)),
      ],
    );
  }

  Widget _buildBody(
    BuildContext context,
    PdfProvider provider,
    PdfFavoritesService favorites,
    List<PdfFile> sorted,
  ) {
    if (provider.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    // Sem "Todos os arquivos": o Android 13+ não lista PDFs por padrão.
    // Explica e oferece o acesso especial + o seletor manual (SAF).
    if (!provider.allFilesAccess && provider.pdfs.isEmpty) {
      return _AllFilesAccessState(
        onRequest: () => provider.requestAllFilesAccess(),
        onPick: () => provider.pickPdf(),
      );
    }

    if (provider.pdfs.isEmpty) {
      return const _EmptyState(
        icon: Icons.picture_as_pdf_outlined,
        message: 'Nenhum PDF encontrado no aparelho.\n'
            'Use "Selecionar PDF" para abrir um arquivo, '
            'ou salve PDFs para vê-los aqui.',
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: sorted.length,
      itemBuilder: (context, index) {
        final pdf = sorted[index];
        final bool isFav = favorites.isFavorite(pdf.path);
        return ListTile(
          leading: _PdfThumbnail(pdf: pdf),
          title: Text(pdf.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Row(
            children: [
              Flexible(child: _PdfSubtitle(pdf: pdf)),
            ],
          ),
          trailing: IconButton(
            tooltip: isFav ? 'Remover dos favoritos' : 'Adicionar aos favoritos',
            icon: Icon(
              isFav ? Icons.star_rounded : Icons.star_outline_rounded,
              color: isFav ? Theme.of(context).colorScheme.primary : null,
            ),
            onPressed: () => favorites.toggle(pdf.path),
          ),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => PdfViewerScreen(pdf: pdf),
            ),
          ),
          onLongPress: () => _showPdfActions(context, provider, pdf),
        );
      },
    );
  }

  /// Menu de ações do PDF: compartilhar / excluir (long-press).
  Future<void> _showPdfActions(
    BuildContext context,
    PdfProvider provider,
    PdfFile pdf,
  ) async {
    // PDFs do MediaStore têm id numérico (para o diálogo do sistema);
    // os do seletor SAF são excluídos pelo caminho (cache do app).
    final int? mediaId =
        pdf.id.startsWith('pdf-') ? int.tryParse(pdf.id.substring(4)) : null;
    await MediaActions.show(
      context,
      type: 'pdf',
      mediaId: mediaId,
      filePath: pdf.path,
      shareName: pdf.name,
      shareMimeType: 'application/pdf',
      onDeleted: () {
        // Sem progresso salvo para um arquivo que não existe mais.
        PdfProgressService.clear(pdf.path);
        provider.load();
      },
    );
  }
}

/// Subtítulo do tile: tamanho • data • nº de páginas (lazy via canal).
class _PdfSubtitle extends StatelessWidget {
  final PdfFile pdf;

  const _PdfSubtitle({required this.pdf});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<int?>(
      future: PdfQueryService.getPageCount(pdf.path),
      builder: (context, snapshot) {
        final int? pages = snapshot.data;
        final String text = [
          if (pdf.displaySize.isNotEmpty) pdf.displaySize,
          if (pdf.dateAdded > 0)
            'Adicionado em ${_formatDate(pdf.dateAdded)}',
          if (pages != null && pages > 0)
            '$pages ${pages == 1 ? 'página' : 'páginas'}',
        ].join(' • ');
        return Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        );
      },
    );
  }

  static String _formatDate(int seconds) {
    final DateTime date =
        DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
    return '${date.day.toString().padLeft(2, '0')}/'
        '${date.month.toString().padLeft(2, '0')}/${date.year}';
  }
}

/// Miniatura da primeira página do PDF (via PdfRenderer nativo). Caminho
/// inacessível/corrompido cai no ícone padrão — nunca quebra a lista.
class _PdfThumbnail extends StatelessWidget {
  final PdfFile pdf;

  const _PdfThumbnail({required this.pdf});

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 40,
        height: 52,
        child: FutureBuilder<Uint8List?>(
          future: PdfQueryService.loadThumbnail(pdf.path),
          builder: (context, snapshot) {
            final Uint8List? data = snapshot.data;
            if (data == null || data.isEmpty) {
              return Container(
                color: colors.surfaceContainerHighest,
                child: Icon(
                  Icons.picture_as_pdf,
                  color: colors.error,
                  size: 28,
                ),
              );
            }
            return Image.memory(
              data,
              fit: BoxFit.cover,
              gaplessPlayback: true,
            );
          },
        ),
      ),
    );
  }
}

/// Estado "sem acesso a arquivos": explica por que os PDFs não aparecem e
/// oferece o acesso especial do sistema ("Todos os arquivos") + o seletor.
class _AllFilesAccessState extends StatelessWidget {
  final VoidCallback onRequest;
  final VoidCallback onPick;

  const _AllFilesAccessState({required this.onRequest, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.folder_off_outlined,
              size: 64,
              color: colors.outline,
            ),
            const SizedBox(height: 12),
            Text(
              'Seus PDFs não aparecem porque o Android 13+ só deixa '
              'apps listarem documentos com o acesso especial '
              '"Todos os arquivos".',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRequest,
              icon: const Icon(Icons.folder_open_outlined),
              label: const Text('Conceder acesso a todos os arquivos'),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: onPick,
              icon: const Icon(Icons.search),
              label: const Text('Ou escolher um PDF manualmente'),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String message;

  const _EmptyState({required this.icon, required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 64,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}