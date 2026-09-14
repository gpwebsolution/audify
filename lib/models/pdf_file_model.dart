/// Modelo de dados de um arquivo PDF do aparelho.
///
/// DTO puro: espelha o mapa retornado pelo canal nativo `audify/pdf_query`
/// (ou pelo seletor de arquivos SAF, via [PdfProvider.pickPdf]).
class PdfFile {
  /// Identificador (id do MediaStore ou marcador do SAF).
  final String id;

  /// Nome de arquivo exibível (ex.: `manual.pdf`).
  final String name;

  /// Caminho absoluto acessível ao app — fonte do visualizador.
  final String path;

  /// Tamanho em bytes.
  final int size;

  /// Timestamp de adição (segundos desde a época; 0 para arquivos do SAF).
  final int dateAdded;

  const PdfFile({
    required this.id,
    required this.name,
    required this.path,
    required this.size,
    required this.dateAdded,
  });

  /// Reconstrói a partir do mapa do canal nativo.
  factory PdfFile.fromChannel(Map<dynamic, dynamic> map) {
    return PdfFile(
      id: 'pdf-${map['id']}',
      name: (map['name'] as String?) ?? 'Documento',
      path: (map['path'] as String?) ?? '',
      size: ((map['size'] as num?) ?? 0).toInt(),
      dateAdded: ((map['dateAdded'] as num?) ?? 0).toInt(),
    );
  }

  /// Reconstrói a partir de um arquivo selecionado pelo SAF (file_picker).
  factory PdfFile.fromPicked({required String path, required String name}) {
    return PdfFile(
      id: 'picked-$path',
      name: name,
      path: path,
      size: 0,
      dateAdded: 0,
    );
  }

  /// Tamanho formatado para exibição (ex.: `2,4 MB`).
  String get displaySize {
    if (size <= 0) return '';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}