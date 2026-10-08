import '../models/song_model.dart';
import '../models/video_model.dart';
import '../services/playlist_database.dart';

/// Repositório de playlists — camada única de acesso ao banco sqflite.
///
/// Os providers conversam apenas com este repositório; o acesso SQL direto
/// fica isolado em [PlaylistDatabase] (troca futura de persistência é
/// transparente). Erros de banco são propagados ao chamador (que decide o
/// feedback) — nunca crash silencioso.
class PlaylistRepository {
  /// Todas as playlists com contagem de faixas e vídeos.
  Future<List<Map<String, Object?>>> getPlaylists() =>
      PlaylistDatabase.getPlaylists();

  /// Cria uma playlist; lança se o nome já existir (constraint UNIQUE).
  Future<void> createPlaylist(String name) =>
      PlaylistDatabase.createPlaylist(name);

  /// Renomeia uma playlist.
  Future<void> renamePlaylist(int id, String name) =>
      PlaylistDatabase.renamePlaylist(id, name);

  /// Exclui a playlist (faixas/vídeos somem em cascata).
  Future<void> deletePlaylist(int id) => PlaylistDatabase.deletePlaylist(id);

  /// Faixas de uma playlist, na ordem salva.
  Future<List<Song>> getSongs(int playlistId) =>
      PlaylistDatabase.getSongs(playlistId);

  /// Adiciona uma faixa ao fim da playlist (idempotente).
  Future<void> addSong(int playlistId, Song song) =>
      PlaylistDatabase.addSong(playlistId, song);

  /// Adiciona várias faixas numa transação única. Devolve quantas entraram.
  Future<int> addSongs(int playlistId, List<Song> songs) =>
      PlaylistDatabase.addSongs(playlistId, songs);

  /// Remove uma faixa da playlist.
  Future<void> removeSong(int playlistId, String songId) =>
      PlaylistDatabase.removeSong(playlistId, songId);

  /// Remove uma faixa de TODAS as playlists (arquivo excluído do aparelho).
  Future<void> removeSongFromAll(String songId) =>
      PlaylistDatabase.removeSongFromAll(songId);

  /// Aplica a nova ordem das faixas (transação única).
  Future<void> reorderSongs(int playlistId, List<String> orderedSongIds) =>
      PlaylistDatabase.reorderSongs(playlistId, orderedSongIds);

  /// Vídeos de uma playlist, na ordem salva.
  Future<List<Video>> getVideos(int playlistId) =>
      PlaylistDatabase.getVideos(playlistId);

  /// Adiciona um vídeo ao fim da playlist (idempotente).
  Future<void> addVideo(int playlistId, Video video) =>
      PlaylistDatabase.addVideo(playlistId, video);

  /// Adiciona vários vídeos numa transação única. Devolve quantos entraram.
  Future<int> addVideos(int playlistId, List<Video> videos) =>
      PlaylistDatabase.addVideos(playlistId, videos);

  /// Remove um vídeo da playlist.
  Future<void> removeVideo(int playlistId, int videoId) =>
      PlaylistDatabase.removeVideo(playlistId, videoId);

  /// Remove um vídeo de TODAS as playlists (arquivo excluído do aparelho).
  Future<void> removeVideoFromAll(int videoId) =>
      PlaylistDatabase.removeVideoFromAll(videoId);

  /// Aplica a nova ordem dos vídeos (transação única).
  Future<void> reorderVideos(int playlistId, List<int> orderedVideoIds) =>
      PlaylistDatabase.reorderVideos(playlistId, orderedVideoIds);
}
