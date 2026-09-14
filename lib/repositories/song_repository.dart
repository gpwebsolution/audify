import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:on_audio_query/on_audio_query.dart';

import '../models/song_model.dart';

/// Fonte de dados do catálogo de músicas.
///
/// Responsabilidade: descobrir as faixas disponíveis em DUAS fontes:
///  1. MediaStore do aparelho (biblioteca de músicas do usuário);
///  2. Assets empacotados no APK (`assets/songs/`, descobertos via
///     AssetManifest — sem nome de arquivo hardcoded).
///
/// É a ÚNICA camada que toca no plugin on_audio_query e no AssetManifest;
/// providers e UI consomem apenas [SongRepository].
class SongRepository {
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
  Future<List<Song>> loadDeviceSongs() async {
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
      debugPrint('[SongRepository] loadDeviceSongs falhou: $e');
      return const [];
    }
  }

  /// Carrega as músicas empacotadas nos assets.
  Future<List<Song>> loadAssetSongs() async {
    final manifest = await _assetManifestLoader();
    final songs = <Song>[];
    for (final assetKey in manifest) {
      final isInSongsFolder = assetKey.startsWith(songsFolder);
      final isAcceptedFormat =
          assetKey.toLowerCase().endsWith(acceptedExtension);
      if (isInSongsFolder && isAcceptedFormat) {
        songs.add(Song.fromAsset(assetPath: assetKey));
      }
    }
    return songs;
  }

  /// Carrega a lista de assets do bundle (isolado para testes).
  Future<List<String>> _assetManifestLoader() async {
    final AssetManifest manifest =
        await AssetManifest.loadFromAssetBundle(rootBundle);
    return manifest.listAssets();
  }
}