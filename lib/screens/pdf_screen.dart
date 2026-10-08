import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/pdf_file_model.dart';
import '../models/media_ref.dart';
import '../providers/pdf_provider.dart';
import '../services/pdf_favorites_service.dart';
import '../services/pdf_progress_service.dart';
import '../services/pdf_query_service.dart';
import '../widgets/media_actions.dart';
import '../widgets/media_details_sheet.dart';
import '../widgets/selection_bar.dart';
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

class _PdfScreenState extends State<PdfScreen> with MediaSelection<String> {
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
    final List<PdfFile> sorted = [...provider.pdfs]
      ..sort((a, b) {
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
        // ---- Barra de ações em lote (modo seleção) ----
        AnimatedToolbarSwap(
          value: isSelectionMode,
          selectionBar: SelectionBar(
            label: '$selectionCount selecionado(s)',
            onSelectAll: () =>
                toggleSelectAll(sorted.map((PdfFile p) => p.path)),
            onClear: clearSelection,
            onDelete: () =>
                deleteSelectedPdfs(context, provider, favorites, sorted),
            actions: <SelectionAction>[
              SelectionAction(
                icon: Icons.share_outlined,
                label: 'Compartilhar selecionados',
                onPressed: () => _shareSelected(sorted),
              ),
              SelectionAction(
                icon: Icons.swap_horiz,
                label: 'Inverter seleção',
                onPressed: () => invertSelection(sorted.map((PdfFile p) => p.path)),
              ),
            ],
          ),
          toolbar: const SizedBox.shrink(),
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
        message:
            'Nenhum PDF encontrado no aparelho.\n'
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
        final bool marked = isSelectionMode && isSelected(pdf.path);
        return ListTile(
          selected: marked,
          selectedTileColor: Theme.of(
            context,
          ).colorScheme.secondaryContainer.withValues(alpha: 0.5),
          leading: isSelectionMode
              ? Checkbox(
                  value: isSelected(pdf.path),
                  onChanged: (_) => toggleSelect(pdf.path),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                )
              : _PdfThumbnail(pdf: pdf),
          title: Text(pdf.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Row(
            children: [Flexible(child: _PdfSubtitle(pdf: pdf))],
          ),
          // No modo seleção a estrela e o menu saem: o polegar precisa ir
          // para a ação em lote, e favoritar N itens um a um não faz sentido.
          // Fora dele, o botão ⋮ assume as ações (o long-press pertence à
          // seleção) e a estrela continua ao lado.
          trailing: isSelectionMode
              ? null
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    IconButton(
                      tooltip: isFav
                          ? 'Remover dos favoritos'
                          : 'Adicionar aos favoritos',
                      icon: Icon(
                        isFav ? Icons.star_rounded : Icons.star_outline_rounded,
                        color: isFav
                            ? Theme.of(context).colorScheme.primary
                            : null,
                      ),
                      onPressed: () => favorites.toggle(pdf.path),
                    ),
                    IconButton(
                      tooltip: 'Ações do PDF',
                      icon: const Icon(Icons.more_vert),
                      onPressed: () => _showPdfActions(context, provider, pdf),
                    ),
                  ],
                ),
          onTap: () {
            if (isSelectionMode) {
              toggleSelect(pdf.path);
              return;
            }
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => PdfViewerScreen(pdf: pdf)),
            );
          },
          // Long-press marca; as ações ficam no botão ⋮.
          onLongPress: () => toggleSelect(pdf.path),
        );
      },
    );
  }

  @override
  void notifyChanged() => setState(() {});

  /// Compartilha os PDFs marcados num único diálogo do sistema.
  void _shareSelected(List<PdfFile> visible) {
    final List<PdfFile> pdfs = selectedFrom(visible, (PdfFile p) => p.path);
    if (pdfs.isEmpty) return;
    MediaActions.shareMany(context, <MediaRef>[
      for (final PdfFile p in pdfs) MediaRef.fromPdf(p),
    ]);
  }

  /// Exclui os PDFs marcados com UM único diálogo do sistema e limpa o que
  /// apontava para eles (progresso de leitura e favorito).
  Future<void> deleteSelectedPdfs(
    BuildContext context,
    PdfProvider provider,
    PdfFavoritesService favorites,
    List<PdfFile> visible,
  ) async {
    final List<PdfFile> pdfs = selectedFrom(visible, (PdfFile p) => p.path);
    if (pdfs.isEmpty) {
      clearSelection();
      return;
    }
    if (!context.mounted) return;

    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    await MediaActions.confirmDeleteMany(
      context,
      <MediaRef>[for (final PdfFile p in pdfs) MediaRef.fromPdf(p)],
      onDeleted: (List<MediaRef> removed) async {
        // Só depois de confirmar: cancelar preserva a seleção.
        clearSelection();
        final Set<String> goneKeys = removed.map((MediaRef r) => r.key).toSet();
        final List<PdfFile> gone = <PdfFile>[
          for (final PdfFile p in pdfs)
            if (goneKeys.contains(MediaRef.fromPdf(p).key)) p,
        ];
        if (gone.isEmpty) return;
        for (final PdfFile p in gone) {
          await PdfProgressService.clear(p.path);
          await favorites.remove(p.path);
          await PdfQueryService.clearForPath(p.path);
        }
        await provider.handlePdfsDeleted(gone);
        if (!context.mounted) return;
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              gone.length == 1
                  ? 'PDF excluído.'
                  : '${gone.length} PDFs excluídos.',
            ),
          ),
        );
      },
    );
  }

  /// Menu de ações do PDF: compartilhar / detalhes / excluir (long-press).
  Future<void> _showPdfActions(
    BuildContext context,
    PdfProvider provider,
    PdfFile pdf,
  ) async {
    await MediaActions.show(
      context,
      ref: MediaRef.fromPdf(pdf),
      label: pdf.name,
      sharePath: pdf.path,
      shareName: pdf.name,
      shareMimeType: 'application/pdf',
      extraTiles: <Widget>[
        ListTile(
          leading: const Icon(Icons.info_outline),
          title: const Text('Detalhes'),
          subtitle: const Text('Tamanho, origem e caminho'),
          onTap: () {
            Navigator.of(context).pop();
            MediaDetailsSheet.showPdf(context, pdf);
          },
        ),
      ],
      onDeleted: (List<MediaRef> _) => _afterPdfDeleted(context, provider, pdf),
    );
  }

  /// PDF confirmado como apagado: some da lista, do progresso salvo e dos
  /// favoritos (nada pode apontar para um arquivo inexistente).
  Future<void> _afterPdfDeleted(
    BuildContext context,
    PdfProvider provider,
    PdfFile pdf,
  ) async {
    await PdfProgressService.clear(pdf.path);
    if (!context.mounted) return;
    final PdfFavoritesService favorites = context.read<PdfFavoritesService>();
    await favorites.remove(pdf.path);
    await PdfQueryService.clearForPath(pdf.path);
    await provider.handlePdfsDeleted(<PdfFile>[pdf]);
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
          if (pdf.dateAdded > 0) 'Adicionado em ${_formatDate(pdf.dateAdded)}',
          if (pages != null && pages > 0)
            '$pages ${pages == 1 ? 'página' : 'páginas'}',
        ].join(' • ');
        return Text(text, maxLines: 1, overflow: TextOverflow.ellipsis);
      },
    );
  }

  static String _formatDate(int seconds) {
    final DateTime date = DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
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
            return Image.memory(data, fit: BoxFit.cover, gaplessPlayback: true);
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
            Icon(Icons.folder_off_outlined, size: 64, color: colors.outline),
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
            Icon(icon, size: 64, color: Theme.of(context).colorScheme.outline),
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
