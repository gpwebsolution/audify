import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import '../models/pdf_file_model.dart';
import '../services/pdf_query_service.dart';
import '../services/permission_service.dart';

/// Estado da biblioteca de PDFs do aparelho.
///
/// Responsabilidade: listar os PDFs do MediaStore (canal nativo) e os
/// arquivos escolhidos pelo seletor do sistema (SAF). O SAF é o caminho
/// confiável no Android 13+, onde o caminho de PDFs de terceiros pode não
/// ser legível sem permissão de armazenamento.
class PdfProvider extends ChangeNotifier {
  List<PdfFile> _pdfs = const [];
  bool _isLoading = true;
  bool _allFilesAccess = false;
  String? _errorMessage;
  bool _isDisposed = false;

  List<PdfFile> get pdfs => _pdfs;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

  /// True quando o acesso especial "Todos os arquivos" está concedido —
  /// sem ele, no Android 13+ o MediaStore NÃO lista PDFs de outros apps.
  bool get allFilesAccess => _allFilesAccess;

  PdfProvider() {
    load();
  }

  Future<void> load() async {
    _isLoading = true;
    _notify();
    _allFilesAccess = await PermissionService.hasAllFilesAccess();
    try {
      _pdfs = await PdfQueryService.loadPdfs();
    } catch (e) {
      _errorMessage = 'Falha ao carregar PDFs: $e';
    } finally {
      _isLoading = false;
      _notify();
    }
  }

  /// Abre a tela especial do sistema ("Todos os arquivos") e recarrega.
  /// Retorna true se o acesso foi concedido.
  Future<bool> requestAllFilesAccess() async {
    final bool granted = await PermissionService.requestAllFilesAccess();
    await load();
    return granted;
  }

  /// Abre o seletor de arquivos do sistema (SAF) filtrando PDFs.
  ///
  /// O arquivo escolhido é copiado pelo file_picker para o cache do app
  /// (caminho sempre legível). Retorna o arquivo ou null se cancelado.
  Future<PdfFile?> pickPdf() async {
    try {
      final List<PlatformFile> files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['pdf'],
      );
      final PlatformFile? file = files.firstOrNull;
      if (file?.path == null) return null;

      final PdfFile picked = PdfFile.fromPicked(
        path: file!.path!,
        name: file.name,
      );
      // Mantém na lista da sessão (não persiste entre reinícios — o cache
      // do SAF é temporário por design).
      _pdfs = [picked, ..._pdfs];
      _notify();
      return picked;
    } catch (e) {
      _errorMessage = 'Não foi possível abrir o seletor: $e';
      _notify();
      return null;
    }
  }

  void _notify() {
    if (!_isDisposed) notifyListeners();
  }

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
  }
}