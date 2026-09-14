import 'package:on_audio_query/on_audio_query.dart';

/// Modelo de dados de uma faixa musical.
///
/// Representa UMA música, seja do MediaStore do aparelho (device) ou
/// empacotada nos assets do app. É um DTO puro: não conhece AudioPlayer
/// nem Provider.
class Song {
  /// Identificador único (id do MediaStore para device, caminho do asset
  /// para assets). Base da igualdade — usado como chave em listas/Queue.
  final String id;

  /// Caminho completo do asset, ex.: `assets/songs/minha_faixa.mp3`
  /// (apenas para faixas do bundle).
  final String? assetPath;

  /// Caminho relativo (sem `assets/`), usado pelo `AssetSource` do
  /// audioplayers, ex.: `songs/minha_faixa.mp3`.
  final String? assetKey;

  /// Título legível da faixa.
  final String title;

  /// Nome do artista (null quando o MediaStore não tem metadado).
  final String? artist;

  /// Nome do álbum.
  final String? album;

  /// Id da faixa no MediaStore (para buscar capa de álbum e igualdade).
  final int? mediaId;

  /// Id do álbum no MediaStore (para a URI correta de album art).
  final int? albumId;

  /// Caminho absoluto do arquivo no aparelho, ex.:
  /// `/storage/emulated/0/Music/faixa.mp3` — fonte do `DeviceFileSource`.
  final String? filePath;

  /// Duração total conhecida (MediaStore reporta; assets preenchem em
  /// runtime quando o player carrega a faixa).
  final Duration? duration;

  /// True quando a faixa vem do bundle de assets do app.
  final bool isAsset;

  Song._({
    required this.id,
    required this.title,
    this.assetPath,
    this.assetKey,
    this.artist,
    this.album,
    this.mediaId,
    this.albumId,
    this.filePath,
    this.duration,
    required this.isAsset,
  });

  /// Faixa empacotada nos assets: título derivado do nome do arquivo.
  factory Song.fromAsset({required String assetPath}) {
    return Song._(
      id: assetPath,
      assetPath: assetPath,
      assetKey: assetPath.startsWith('assets/')
          ? assetPath.substring('assets/'.length)
          : assetPath,
      title: _humanize(assetPath.split('/').last.split('.').first),
      isAsset: true,
    );
  }

  /// Faixa do MediaStore do aparelho (metadados completos do sistema).
  factory Song.fromMediaStore(SongModel model) {
    return Song._(
      id: 'media-${model.id}',
      title: model.title.trim().isEmpty
          ? _humanize(model.displayNameWOExt)
          : model.title,
      artist: model.artist,
      album: model.album,
      mediaId: model.id,
      albumId: model.albumId,
      filePath: model.data,
      duration: model.duration != null && model.duration! > 0
          ? Duration(milliseconds: model.duration!)
          : null,
      isAsset: false,
    );
  }

  /// Artista formatado para exibição (fallback amigável).
  String get displayArtist => (artist == null || artist!.trim().isEmpty)
      ? 'Artista desconhecido'
      : artist!;

  /// Serializa para mapa persistível (banco de playlists). Os nomes das
  /// chaves SEGUEM as colunas do banco (snake_case) — o sqflite usa as
  /// chaves do mapa como nomes de coluna no INSERT. O [Song.id] é estável
  /// entre sessões (id do MediaStore ou caminho do asset), então basta
  /// guardar os campos de exibição para reconstruir offline.
  Map<String, Object?> toStored() => {
        'song_id': id,
        'title': title,
        'artist': artist,
        'album': album,
        'media_id': mediaId,
        'album_id': albumId,
        'file_path': filePath,
        'asset_path': assetPath,
        'asset_key': assetKey,
        'is_asset': isAsset ? 1 : 0,
        'duration_ms': duration?.inMilliseconds,
      };

  /// Reconstrói uma [Song] a partir do mapa do banco (colunas snake_case).
  /// Retorna null se o registro estiver corrompido (defensivo — nunca
  /// crash de leitura).
  static Song? fromStored(Map<String, Object?> map) {
    final int isAsset = (map['is_asset'] as int?) ?? 0;
    final String id = (map['song_id'] as String?) ?? '';
    if (id.isEmpty) return null;
    return Song._(
      id: id,
      title: (map['title'] as String?) ?? '',
      artist: map['artist'] as String?,
      album: map['album'] as String?,
      mediaId: map['media_id'] as int?,
      albumId: map['album_id'] as int?,
      filePath: map['file_path'] as String?,
      assetPath: map['asset_path'] as String?,
      assetKey: map['asset_key'] as String?,
      duration: map['duration_ms'] != null
          ? Duration(milliseconds: map['duration_ms'] as int)
          : null,
      isAsset: isAsset == 1,
    );
  }

  /// Transforma nomes de arquivo em título legível:
  /// `minha_faixa-ao_vivo` -> `Minha Faixa Ao Vivo`.
  static String _humanize(String input) {
    final words = input.split(RegExp(r'[_\-\s]+')).where((w) => w.isNotEmpty);
    return words.map(_capitalize).join(' ');
  }

  static String _capitalize(String word) =>
      word.isEmpty ? word : word[0].toUpperCase() + word.substring(1);

  @override
  bool operator ==(Object other) => other is Song && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'Song(id: $id, title: $title, isAsset: $isAsset)';
}