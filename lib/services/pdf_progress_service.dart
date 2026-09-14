import 'package:shared_preferences/shared_preferences.dart';

/// Persistência da última página lida de cada PDF.
///
/// Chave por caminho do arquivo (hash): reabrir o mesmo PDF retoma de onde
/// parou. O progresso é salvo a cada troca de página ([PdfViewerScreen]).
class PdfProgressService {
  /// Chave da última página do arquivo com [path].
  static String _key(String path) => 'pdf_last_page_${path.hashCode}';

  /// Salva a última página lida (1-based).
  static Future<void> saveLastPage(String path, int page) async {
    if (page <= 1) return;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_key(path), page);
    } catch (e) {
      // Persistência é otimização: falha não quebra a leitura.
    }
  }

  /// Última página salva (1-based; 1 = início, quando nunca foi lido).
  static Future<int> loadLastPage(String path) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      return prefs.getInt(_key(path)) ?? 1;
    } catch (e) {
      return 1;
    }
  }

  /// Remove o progresso (usado quando o PDF é excluído).
  static Future<void> clear(String path) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key(path));
    } catch (e) {
      // Silencioso por design.
    }
  }
}