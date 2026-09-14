/// Modelo de dados de uma imagem do aparelho (MediaStore).
///
/// DTO puro: espelha o mapa retornado pelo canal nativo `audify/gallery_query`.
class GalleryImage {
  /// Id no MediaStore.Images.
  final int id;

  /// Nome de arquivo exibível (ex.: `IMG_20240101.jpg`).
  final String name;

  /// Caminho absoluto do arquivo — usado no visualizador em tela cheia.
  final String path;

  /// Tamanho em bytes.
  final int size;

  /// Timestamp de adição ao MediaStore (segundos desde a época).
  final int dateAdded;

  /// Dimensões conhecidas (se o SO reportar; senão -1).
  final int width;
  final int height;

  const GalleryImage({
    required this.id,
    required this.name,
    required this.path,
    required this.size,
    required this.dateAdded,
    required this.width,
    required this.height,
  });

  /// Reconstrói a partir do mapa do canal nativo.
  factory GalleryImage.fromChannel(Map<dynamic, dynamic> map) {
    return GalleryImage(
      id: (map['id'] as num).toInt(),
      name: (map['name'] as String?) ?? 'Imagem',
      path: (map['path'] as String?) ?? '',
      size: ((map['size'] as num?) ?? 0).toInt(),
      dateAdded: ((map['dateAdded'] as num?) ?? 0).toInt(),
      width: ((map['width'] as num?) ?? -1).toInt(),
      height: ((map['height'] as num?) ?? -1).toInt(),
    );
  }

  /// Dimensões formatadas para exibição (fallback quando o SO não reporta).
  String get displayDimensions =>
      width > 0 && height > 0 ? '$width x $height' : '';
}