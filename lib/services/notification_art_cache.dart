import 'package:flutter/services.dart';

import '../models/song_model.dart';
import 'album_artwork_cache.dart';
import 'error_log_service.dart';
import 'gallery_query_service.dart' show ThumbnailDiskCache;

/// Capa da faixa em formato de ARQUIVO para a notificação/tela de bloqueio.
///
/// Por quê: `MediaItem.artUri` vinha de
/// `content://media/external/audio/albumart/<id>` — esquema legado que
/// costuma falhar no Android 10+ (e nem toda faixa tem albumId). E faixa
/// de asset ficava SEM capa (asset não é caminho de arquivo).
///
/// A solução é gravar os bytes num arquivo do diretório de cache do app
/// e usar `Uri.file(...)`: o processo do serviço lê o próprio cache, sem
/// depender do MediaStore. Os arquivos entram no MESMO cache das
/// miniaturas ([ThumbnailDiskCache]), herdando a poda por contagem e
/// bytes — sem crescimento infinito.
///
/// Nunca lança: capa é enfeite, não requisito — falha vira `null` e a
/// notificação mostra o ícone padrão.
class NotificationArtCache {
  NotificationArtCache._();

  /// Logo do app usada como capa das faixas de asset (não têm capa de
  /// álbum — o arquivo está no bundle, não no armazenamento).
  static const String logoAsset = 'assets/images/audify.png';

  /// Chave de cache da logo (gravada uma vez, reutilizada na sessão).
  static const String _logoKey = 'art_logo';

  /// Nome puro da entrada de cache da capa de [song] — FUNÇÃO testável
  /// sem tocar em disco/plugin.
  ///
  /// Prefere o id do ÁLBUM (faixas do mesmo álbum compartilham a capa =
  /// menos arquivos) e cai para o id da faixa quando não há álbum.
  /// Retorna null quando não há NEM um nem outro (nada a gravar).
  static String? artKeyFor(Song song) {
    if (song.isAsset) return _logoKey;
    final int? key = song.albumId ?? song.mediaId;
    if (key == null) return null;
    return 'art_album_$key';
  }

  /// Monta o Uri de arquivo a partir de um caminho absoluto — função
  /// pura para o teste cobrir o formato (`file:///...`).
  static Uri uriFromPath(String path) => Uri.file(path);

  /// Devolve o `Uri.file` da capa de [song] (gravando no cache se
  /// necessário), ou null quando não há capa.
  ///
  /// O caminho comum é o cache já existente: leitura barata, sem I/O.
  static Future<Uri?> uriFor(Song song) async {
    try {
      final String? key = artKeyFor(song);
      if (key == null) return null;

      // Já gravada? (pathOf devolve null se não existir/falhar.)
      final String? cachedPath = await ThumbnailDiskCache.pathOf(key);
      if (cachedPath != null) return uriFromPath(cachedPath);

      final Uint8List? bytes =
          song.isAsset ? await _logoBytes() : await _albumBytes(song);
      if (bytes == null || bytes.isEmpty) return null;

      await ThumbnailDiskCache.put(key, bytes);
      final String? path = await ThumbnailDiskCache.pathOf(key);
      return path == null ? null : uriFromPath(path);
    } catch (e, s) {
      // Capa é enfeite: qualquer falha vira "sem capa", nunca crash.
      ErrorLogService.logSync('art/uriFor', e, s);
      return null;
    }
  }

  /// Bytes da capa do álbum via cache em memória do [AlbumArtworkCache]
  /// (mesma fonte usada pelos tiles da lista — uma ida ao nativo para o
  /// app inteiro).
  static Future<Uint8List?> _albumBytes(Song song) async {
    final int? mediaId = song.mediaId;
    if (mediaId == null) return null;
    return AlbumArtworkCache.instance.load(mediaId);
  }

  /// Bytes da logo do app (lida do bundle UMA vez por sessão).
  static Future<Uint8List?> _logoBytes() async {
    try {
      final ByteData data = await rootBundle.load(logoAsset);
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } catch (e, s) {
      ErrorLogService.logSync('art/logo', e, s);
      return null;
    }
  }
}
