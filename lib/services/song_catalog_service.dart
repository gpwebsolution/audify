import 'package:flutter/services.dart';
import 'package:on_audio_query/on_audio_query.dart';

import '../models/song_model.dart';

/// Catálogo de músicas do app.
///
/// Responsabilidade: descobrir as faixas disponíveis em DUAS fontes:
///  1. MediaStore do aparelho (biblioteca de músicas do usuário);
///  2. Assets empacotados no APK (`assets/songs/`, descobertos via
///     AssetManifest — sem nome de arquivo hardcoded).
///
/// Resultado prático: o app toca as músicas reais do Android + os MP3s
/// do bundle, numa lista única e ordenada.
class SongCatalogService {
  static final OnAudioQuery _query = OnAudioQuery();

  /// Pasta onde ficam as músicas dos assets (casa com o pubspec.yaml).
  static const String songsFolder = 'assets/songs/';

  /// Extensão aceita nos assets (case-insensitive).
  static const String acceptedExtension = '.mp3';

  /// Carrega as músicas do MediaStore do aparelho.
  ///
  /// Requer permissão de áudio concedida (Android 13+) ou de storage
  /// (<= 12). Ordenadas por título (A-Z), ignorando maiúsculas.
  /// Retorna lista vazia se a consulta falhar ou o SO não tiver faixas.
  static Future<List<Song>> loadDeviceSongs() async {
    try {
      final List<SongModel> models = await _query.querySongs(
        sortType: SongSortType.TITLE,
        orderType: OrderType.ASC_OR_SMALLER,
        ignoreCase: true,
      );
      return models
          .where((model) => model.isMusic ?? true)
          .map(Song.fromMediaStore)
          .toList();
    } catch (e) {
      // Sem permissão/MediaStore indisponível: degrada para lista vazia;
      // o chamador decide o feedback (nunca crash silencioso).
      return const [];
    }
  }

  /// Carrega as músicas empacotadas nos assets.
  static Future<List<Song>> loadAssetSongs() async {
    final AssetManifest manifest =
        await AssetManifest.loadFromAssetBundle(rootBundle);

    final songs = <Song>[];
    for (final assetKey in manifest.listAssets()) {
      final isInSongsFolder = assetKey.startsWith(songsFolder);
      final isAcceptedFormat =
          assetKey.toLowerCase().endsWith(acceptedExtension);
      if (isInSongsFolder && isAcceptedFormat) {
        songs.add(Song.fromAsset(assetPath: assetKey));
      }
    }
    return songs;
  }
}