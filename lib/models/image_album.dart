/// Modelo de um álbum (pasta) de imagens do aparelho.
///
/// DTO puro: espelha o mapa retornado pelo canal nativo `audify/gallery_query`
/// (método `getAlbums`). BUCKET_ID é o id da pasta no MediaStore.
class ImageAlbum {
  /// Id da pasta no MediaStore (BUCKET_ID).
  final int id;

  /// Nome da pasta (ex.: `DCIM/Camera`).
  final String name;

  /// Quantidade de imagens na pasta.
  final int count;

  /// Id de uma imagem da pasta (para a capa do álbum na UI).
  final int coverId;

  const ImageAlbum({
    required this.id,
    required this.name,
    required this.count,
    required this.coverId,
  });

  /// Reconstrói a partir do mapa do canal nativo.
  factory ImageAlbum.fromChannel(Map<dynamic, dynamic> map) {
    return ImageAlbum(
      id: (map['id'] as num).toInt(),
      name: (map['name'] as String?) ?? 'Álbum',
      count: ((map['count'] as num?) ?? 0).toInt(),
      coverId: ((map['coverId'] as num?) ?? 0).toInt(),
    );
  }

  /// Nome exibível: última parte do caminho (ex.: `Camera`).
  String get displayName {
    if (name.isEmpty) return 'Álbum';
    return name.split('/').last;
  }
}