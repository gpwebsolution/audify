import 'package:flutter/foundation.dart';

import '../models/song_model.dart';
import '../services/error_log_service.dart';
import '../services/playlist_database.dart';

/// Item 4.1 — favoritos de música (tabela `favorite_songs`).
///
/// Singleton notificável ([FavoritesProvider.instance]) — e não um
/// provider do grafo — porque o coração aparece em QUALQUER lugar:
/// tiles da biblioteca, listas dentro de folhas, detalhe de playlist e
/// player. Com o padrão do grafo, cada rota nova (sheet, tela empurrada)
/// exigiria reanexar o provider e os harnesses de teste legados
/// precisariam dele; aqui nenhum teste existente muda. Mesma razão de
/// existir do [AlbumArtworkCache] e do [PlaylistDatabase] (serviços
/// estáticos do app) — este apenas notifica a UI.
class FavoritesProvider extends ChangeNotifier {
  FavoritesProvider._();

  /// Estado único, vivo junto com o app (nunca é disposed).
  static final FavoritesProvider instance = FavoritesProvider._();

  Set<String> _ids = <String>{};
  List<Song> _songs = <Song>[];
  bool _loaded = false;
  bool _isDisposed = false;

  /// Conjunto de ids favoritados (O(1) nos corações das listas).
  Set<String> get ids => Set<String>.unmodifiable(_ids);

  /// Faixas favoritadas, ordenadas por título (mesma ordem do banco).
  List<Song> get songs => List<Song>.unmodifiable(_songs);

  int get count => _ids.length;
  bool get loaded => _loaded;

  bool isFavorite(String songId) => _ids.contains(songId);

  /// Carrega do banco (idempotente). Falha vira lista vazia + log —
  /// favorito quebrado nunca derruba o app, só fica "vazio".
  Future<void> load() async {
    if (_loaded) return;
    try {
      final List<Song> loaded = await PlaylistDatabase.getFavorites();
      _songs = loaded;
      _ids = loaded.map((Song s) => s.id).toSet();
      _loaded = true;
    } catch (e, s) {
      _ids = <String>{};
      _songs = <Song>[];
      _loaded = true;
      ErrorLogService.logSync('favorites/load', e, s);
    }
    _notify();
  }

  /// Favorita/desfavorita: estado muda na hora (otimista) e persiste em
  /// seguida; se o banco falhar, resincroniza dele e loga — a UI nunca
  /// fica mentindo sobre o que está salvo.
  Future<void> toggle(Song song) async {
    if (_isDisposed) return;
    final bool adding = !_ids.contains(song.id);
    if (adding) {
      _ids.add(song.id);
      // Mesma ordenação do banco (COLLATE NOCASE ≈ toLowerCase aqui)
      // para a lista ao vivo não pular de posição após um reload.
      _songs = [..._songs, song]
        ..sort(
          (Song a, Song b) =>
              a.title.toLowerCase().compareTo(b.title.toLowerCase()),
        );
    } else {
      _ids.remove(song.id);
      _songs = _songs.where((Song s) => s.id != song.id).toList();
    }
    _notify();
    try {
      if (adding) {
        await PlaylistDatabase.addFavorite(song);
      } else {
        await PlaylistDatabase.removeFavorite(song.id);
      }
    } catch (e, s) {
      ErrorLogService.logSync('favorites/toggle', e, s);
      await _resync();
    }
  }

  /// Sai dos favoritos (uso na exclusão de mídia: música que sumiu do
  /// aparelho não pode ficar como coração órfão). Sem efeito se não
  /// estava favoritada; erro de banco vira log (a exclusão principal
  /// segue — o arquivo já era).
  Future<void> remove(String songId) async {
    if (_isDisposed) return;
    final bool had = _ids.remove(songId);
    if (had) {
      _songs = _songs.where((Song s) => s.id != songId).toList();
    }
    try {
      await PlaylistDatabase.removeFavorite(songId);
    } catch (e, s) {
      ErrorLogService.logSync('favorites/remove', e, s);
    }
    if (had) _notify();
  }

  Future<void> _resync() async {
    try {
      final List<Song> loaded = await PlaylistDatabase.getFavorites();
      _songs = loaded;
      _ids = loaded.map((Song s) => s.id).toSet();
      _loaded = true;
    } catch (e, s) {
      ErrorLogService.logSync('favorites/resync', e, s);
    }
    _notify();
  }

  void _notify() {
    if (_isDisposed) return;
    notifyListeners();
  }

  /// Zera o estado em memória (testes — cada teste cuida do próprio
  /// banco, e o singleton compartilharia o conjunto entre testes).
  @visibleForTesting
  void resetForTest() {
    _ids = <String>{};
    _songs = <Song>[];
    _loaded = false;
    _notify();
  }

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
  }
}
