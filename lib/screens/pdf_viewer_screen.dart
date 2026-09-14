import 'dart:io';

import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';

import '../models/pdf_file_model.dart';
import '../services/pdf_progress_service.dart';

/// Visualizador de PDF (Syncfusion).
///
/// Navegação de páginas embutida do SfPdfViewer: scroll/rotação de página
/// por gesto, barra de páginas (índice/total + setas) no rodapé, zoom por
/// pinça e double-tap. Arquivos inacessíveis/corrompidos caem no estado de
/// erro ([onDocumentLoadFailed]) — nunca crash.
///
/// Retoma da última página lida (por arquivo) e oferece "Voltar ao início".
class PdfViewerScreen extends StatefulWidget {
  final PdfFile pdf;

  const PdfViewerScreen({super.key, required this.pdf});

  @override
  State<PdfViewerScreen> createState() => _PdfViewerScreenState();
}

class _PdfViewerScreenState extends State<PdfViewerScreen> {
  final PdfViewerController _controller = PdfViewerController();

  bool _loadFailed = false;
  bool _documentLoaded = false;

  /// Última página salva; null enquanto não é lida do disco.
  int? _initialPage;

  /// Acessibilidade do arquivo verificada UMA vez no init (I/O síncrona
  /// dentro do build dispararia leituras de disco a cada rebuild).
  bool _fileAccessible = true;

  @override
  void initState() {
    super.initState();
    try {
      final File file = File(widget.pdf.path);
      _fileAccessible = file.existsSync() && file.lengthSync() > 0;
    } catch (e) {
      debugPrint('[PdfViewer] verificação de arquivo falhou: $e');
      _fileAccessible = false;
    }
    PdfProgressService.loadLastPage(widget.pdf.path).then((page) {
      if (!mounted) return;
      setState(() => _initialPage = page);
    });
  }

  @override
  void dispose() {
    // Sem dispose o controller vaza (mantém listeners do viewer morto).
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final File file = File(widget.pdf.path);

    // Caminho inacessível (ex.: PDF de terceiros no Android 13+ sem SAF):
    // orienta o usuário a abrir pelo seletor, que copia para o cache.
    if (!_fileAccessible) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.pdf.name)),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.picture_as_pdf_outlined,
                  size: 64,
                  color: Theme.of(context).colorScheme.outline,
                ),
                const SizedBox(height: 12),
                Text(
                  'Arquivo inacessível.\n'
                  'Abra este PDF por "Selecionar PDF" na aba de PDFs.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.pdf.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          // Aparece só quando retomou de uma página além do início.
          if (_documentLoaded && (_initialPage ?? 1) > 1)
            IconButton(
              tooltip: 'Voltar ao início',
              icon: const Icon(Icons.first_page),
              onPressed: () {
                _controller.jumpToPage(1);
                PdfProgressService.saveLastPage(widget.pdf.path, 1);
              },
            ),
        ],
      ),
      body: _loadFailed
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Não foi possível carregar este PDF.\n'
                  'O arquivo pode estar corrompido.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            )
          // Aguarda a última página salva antes de montar o viewer, para
          // abrir direto nela (sem piscar da página 1).
          : _initialPage == null
              ? const Center(child: CircularProgressIndicator())
              : SfPdfViewer.file(
                  file,
                  controller: _controller,
                  initialPageNumber: _initialPage!,
                  // Falha de decodificação = estado de erro visual (sem crash).
                  onDocumentLoadFailed: (details) =>
                      setState(() => _loadFailed = true),
                  onDocumentLoaded: (_) =>
                      setState(() => _documentLoaded = true),
                  // Salva o progresso a cada troca de página.
                  onPageChanged: (details) => PdfProgressService.saveLastPage(
                    widget.pdf.path,
                    details.newPageNumber,
                  ),
                ),
    );
  }
}