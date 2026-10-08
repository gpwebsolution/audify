import 'gallery_image_model.dart';
import 'pdf_file_model.dart';
import 'song_model.dart';
import 'video_model.dart';

/// Tipo do arquivo a excluir. Determina a coleção do MediaStore usada
/// nativamente e o texto de feedback ao usuário.
enum MediaKind {
  audio('audio'),
  video('video'),
  image('image'),
  pdf('pdf'),

  /// Qualquer outro arquivo (zip, apk, docx...). Não é mídia indexada:
  /// precisa de "Todos os arquivos" ou de um id do MediaStore.Files.
  other('other');

  const MediaKind(this.wireName);

  /// Nome enviado ao canal nativo (e o mesmo usado para montar a chave).
  final String wireName;

  static MediaKind fromWire(String? value) => switch (value) {
    'audio' => MediaKind.audio,
    'video' => MediaKind.video,
    'image' => MediaKind.image,
    'pdf' => MediaKind.pdf,
    _ => MediaKind.other,
  };
}

/// Referência a um arquivo do aparelho, pronta para ser excluída.
///
/// DTO puro: carrega apenas o que o lado nativo precisa para localizar o
/// arquivo no MediaStore (ou no disco) e o que a UI precisa para
/// reconstruir o resultado depois do diálogo do sistema.
///
/// Estabilidade da chave ([key]): é o contrato com o Kotlin — o nativo
/// devolve as chaves dos itens que realmente sumiram, e o Dart casa o
/// resultado com a lista original usando exatamente a mesma regra.
class MediaRef {
  final MediaKind kind;

  /// Id da linha no MediaStore (null para arquivos fora dele).
  final int? mediaId;

  /// URI `content://` pronta, quando o chamador já a tem.
  final String? uri;

  /// Caminho absoluto no disco (usado para varredura do MediaStore,
  /// compartilhamento e fallback de exclusão direta).
  final String? path;

  const MediaRef({required this.kind, this.mediaId, this.uri, this.path});

  factory MediaRef.audio({int? mediaId, String? path, String? uri}) =>
      MediaRef(kind: MediaKind.audio, mediaId: mediaId, uri: uri, path: path);

  factory MediaRef.video({int? mediaId, String? path, String? uri}) =>
      MediaRef(kind: MediaKind.video, mediaId: mediaId, uri: uri, path: path);

  factory MediaRef.image({int? mediaId, String? path, String? uri}) =>
      MediaRef(kind: MediaKind.image, mediaId: mediaId, uri: uri, path: path);

  factory MediaRef.pdf({int? mediaId, String? path, String? uri}) =>
      MediaRef(kind: MediaKind.pdf, mediaId: mediaId, uri: uri, path: path);

  factory MediaRef.other({String? path, int? mediaId, String? uri}) =>
      MediaRef(kind: MediaKind.other, mediaId: mediaId, uri: uri, path: path);

  /// Faixa do MediaStore. Retorna **null** para faixa de asset (empacotada
  /// no APK): ela não é arquivo do aparelho e nunca deve virar [MediaRef],
  /// porque o id sintético do asset colidiria com um id real do MediaStore e
  /// o nativo poderia apagar a música errada.
  static MediaRef? fromSong(Song song) {
    if (song.isAsset) return null;
    // Sem id do MediaStore e sem caminho absoluto não há como localizar o
    // arquivo (faixa reconstruída do banco sem metadado de disco).
    if (song.mediaId == null && (song.filePath?.isEmpty ?? true)) return null;
    return MediaRef(
      kind: MediaKind.audio,
      mediaId: song.mediaId,
      path: song.filePath,
    );
  }

  factory MediaRef.fromVideo(Video video) =>
      MediaRef(kind: MediaKind.video, mediaId: video.id, path: video.path);

  factory MediaRef.fromImage(GalleryImage image) =>
      MediaRef(kind: MediaKind.image, mediaId: image.id, path: image.path);

  /// PDFs do MediaStore têm id numérico; os do seletor SAF não (o
  /// [PdfFile.id] é `picked-<caminho>`) e são resolvidos pelo caminho.
  factory MediaRef.fromPdf(PdfFile pdf) => MediaRef(
    kind: MediaKind.pdf,
    mediaId: pdf.id.startsWith('pdf-')
        ? int.tryParse(pdf.id.substring('pdf-'.length))
        : null,
    path: pdf.path,
  );

  /// Identificador estável do item — casa com o que o nativo devolve.
  ///
  /// Prioridade idêntica à implementação Kotlin: uri explícita, depois
  /// `tipo:id`, depois o caminho.
  String get key {
    if (uri != null && uri!.isNotEmpty) return uri!;
    if (mediaId != null) return '${kind.wireName}:$mediaId';
    return path ?? '';
  }

  /// True quando o item tem alguma forma de ser localizado pelo nativo.
  bool get isResolvable =>
      (uri?.isNotEmpty ?? false) ||
      mediaId != null ||
      (path?.isNotEmpty ?? false);

  /// Payload enviado ao canal nativo (`audify/media_delete`).
  Map<String, Object?> toPayload() => <String, Object?>{
    'type': kind.wireName,
    'id': mediaId,
    'uri': uri,
    'path': path,
    'key': key,
  };

  @override
  bool operator ==(Object other) => other is MediaRef && other.key == key;

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() => 'MediaRef($key, ${kind.wireName})';
}
