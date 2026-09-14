/// Modelo de um vídeo do MediaStore do aparelho.
///
/// DTO puro com os metadados retornados pelo canal nativo
/// (`audify/video_query`). Não conhece player nem provider.
class Video {
  /// Id no MediaStore (base da igualdade e das miniaturas).
  final int id;

  /// Título do vídeo (metadado do MediaStore).
  final String title;

  /// Nome do arquivo em disco.
  final String displayName;

  /// Duração em milissegundos.
  final Duration duration;

  /// Caminho absoluto do arquivo (fonte do video_player).
  final String path;

  /// Tamanho em bytes.
  final int size;

  /// Época de adição ao MediaStore (epoch seconds).
  final int dateAdded;

  Video({
    required this.id,
    required this.title,
    required this.displayName,
    required this.duration,
    required this.path,
    required this.size,
    required this.dateAdded,
  });

  /// Converte o map vindo do canal nativo (Kotlin -> Dart).
  factory Video.fromChannel(Map<dynamic, dynamic> map) {
    return Video(
      id: (map['id'] as num).toInt(),
      title: (map['title'] as String?)?.trim() ?? '',
      displayName: (map['displayName'] as String?) ?? '',
      duration: Duration(
        milliseconds: ((map['duration'] as num?) ?? 0).toInt(),
      ),
      path: map['path'] as String,
      size: ((map['size'] as num?) ?? 0).toInt(),
      dateAdded: ((map['dateAdded'] as num?) ?? 0).toInt(),
    );
  }

  /// Título legível (fallback para o nome do arquivo sem extensão).
  String get displayTitle {
    if (title.isNotEmpty) return title;
    final name = displayName.split('.').first;
    return name.isEmpty ? 'Vídeo' : name;
  }

  /// Serializa para mapa persistível (banco de playlists). Os nomes das
  /// chaves SEGUEM as colunas do banco (snake_case) — o sqflite usa as
  /// chaves do mapa como nomes de coluna no INSERT. O id do MediaStore é
  /// estável entre sessões — basta guardar os campos de exibição para
  /// reconstruir offline.
  Map<String, Object?> toStored() => {
        'video_id': id,
        'title': title,
        'display_name': displayName,
        'duration_ms': duration.inMilliseconds,
        'file_path': path,
        'size': size,
        'date_added': dateAdded,
      };

  /// Reconstrói um [Video] a partir do mapa do banco (colunas snake_case).
  /// Retorna null se o registro estiver corrompido (defensivo — nunca
  /// crash de leitura).
  static Video? fromStored(Map<String, Object?> map) {
    final int? id = map['video_id'] as int?;
    final String? path = map['file_path'] as String?;
    if (id == null || path == null || path.isEmpty) return null;
    return Video(
      id: id,
      title: (map['title'] as String?) ?? '',
      displayName: (map['display_name'] as String?) ?? '',
      duration:
          Duration(milliseconds: ((map['duration_ms'] as int?) ?? 0)),
      path: path,
      size: ((map['size'] as int?) ?? 0),
      dateAdded: ((map['date_added'] as int?) ?? 0),
    );
  }

  @override
  bool operator ==(Object other) => other is Video && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'Video(id: $id, title: $displayTitle)';
}