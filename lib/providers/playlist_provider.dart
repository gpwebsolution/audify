import 'package:flutter/foundation.dart';

import '../models/song_model.dart';
import '../models/video_model.dart';
import '../repositories/playlist_repository.dart';
import 'player_provider.dart';

/// Uma playlist com suas faixas (DTO de exibição).
class Playlist {
  final int id;
  final String name;
  final int songCount;
  final int videoCount;

  const Playlist({
    required this.id,
    required this.name,
    required this.songCount,
    required this.videoCount,
  });

  /// Total de itens (músicas + vídeos).
  int get itemCount => songCount + videoCount;
}

/// Estado das playlists do usuário.
///
/// Responsabilidade: CRUD de playlists (banco sqflite) e integração com a
/// reprodução — tocar uma playlist de música monta a fila no
/// [PlayerProvider]; a de vídeos abre o [VideoPlayerScreen] (via tela).
class PlaylistProvider extends ChangeNotifier {
  final PlayerProvider _player;
  final PlaylistRepository _repository;

  List<Playlist> _playlists = const [];
  bool _isLoading = true;
  String? _errorMessage;
  bool _isDisposed = false;

  List<Playlist> get playlists => _playlists;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

  PlaylistProvider(this._player, {PlaylistRepository? repository})
    : _repository = repository ?? PlaylistRepository() {
    reload();
  }

  Future<void> reload() async {
    _isLoading = true;
    _notify();
    try {
      final List<Map<String, Object?>> rows = await _repository.getPlaylists();
      _playlists = rows
          .map(
            (row) => Playlist(
              id: row['id'] as int,
              name: row['name'] as String,
              songCount: ((row['song_count'] as num?) ?? 0).toInt(),
              videoCount: ((row['video_count'] as num?) ?? 0).toInt(),
            ),
          )
          .toList();
    } catch (e) {
      _errorMessage = 'Falha ao carregar playlists: $e';
    } finally {
      _isLoading = false;
      _notify();
    }
  }

  /// Cria uma playlist; retorna false se o nome já existir.
  Future<bool> create(String name) async {
    try {
      await _repository.createPlaylist(name.trim());
      await reload();
      return true;
    } catch (e) {
      _errorMessage = 'Não foi possível criar a playlist: $e';
      _notify();
      return false;
    }
  }

  Future<void> rename(int id, String name) async {
    try {
      await _repository.renamePlaylist(id, name.trim());
      await reload();
    } catch (e) {
      _errorMessage = 'Não foi possível renomear: $e';
      _notify();
    }
  }

  Future<void> delete(int id) async {
    try {
      await _repository.deletePlaylist(id);
      await reload();
    } catch (e) {
      _errorMessage = 'Não foi possível excluir: $e';
      _notify();
    }
  }

  /// Faixas salvas de uma playlist (para a tela de detalhe).
  Future<List<Song>> songsOf(int playlistId) =>
      _repository.getSongs(playlistId);

  /// Adiciona a faixa atual ou uma específica a uma playlist.
  Future<void> addSong(int playlistId, Song song) async {
    try {
      await _repository.addSong(playlistId, song);
    } catch (e) {
      _errorMessage = 'Não foi possível adicionar a faixa: $e';
      _notify();
    }
  }

  Future<void> removeSong(int playlistId, Song song) async {
    try {
      await _repository.removeSong(playlistId, song.id);
    } catch (e) {
      _errorMessage = 'Não foi possível remover a faixa: $e';
      _notify();
    }
  }

  /// Adiciona várias faixas a uma playlist de uma vez (modo seleção).
  ///
  /// Uma transação no banco e **um** [reload] no fim — o laço sobre [addSong]
  /// fazia uma query por faixa e deixava a contagem das playlists desatualizada
  /// na tela.
  ///
  /// Devolve quantas faixas entraram de fato. Faixa que já estava na playlist
  /// não conta, e a UI usa isso para dizer "8 de 10 adicionadas" em vez de
  /// mentir.
  Future<int> addSongsToPlaylist(int playlistId, List<Song> songs) async {
    if (songs.isEmpty) return 0;
    try {
      final int added = await _repository.addSongs(playlistId, songs);
      await reload();
      return added;
    } catch (e) {
      _errorMessage = 'Não foi possível adicionar as faixas: $e';
      _notify();
      return 0;
    }
  }

  /// Adiciona vários vídeos a uma playlist de uma vez (modo seleção).
  Future<int> addVideosToPlaylist(int playlistId, List<Video> videos) async {
    if (videos.isEmpty) return 0;
    try {
      final int added = await _repository.addVideos(playlistId, videos);
      await reload();
      return added;
    } catch (e) {
      _errorMessage = 'Não foi possível adicionar os vídeos: $e';
      _notify();
      return 0;
    }
  }

  /// Aplica a nova ordem de faixas de uma playlist (drag & drop).
  Future<void> reorder(int playlistId, List<Song> orderedSongs) async {
    try {
      await _repository.reorderSongs(
        playlistId,
        orderedSongs.map((s) => s.id).toList(),
      );
    } catch (e) {
      _errorMessage = 'Não foi possível reordenar: $e';
      _notify();
    }
  }

  /// Toca uma playlist inteira a partir de uma faixa.
  Future<void> playPlaylist(int playlistId, Song startAt) async {
    final List<Song> songs = await songsOf(playlistId);
    if (songs.isEmpty) return;
    final int startIndex = songs
        .indexWhere((s) => s.id == startAt.id)
        .clamp(0, songs.length - 1);
    await _player.playQueue(songs, startIndex);
  }

  /// Vídeos salvas de uma playlist (para a tela de detalhe).
  Future<List<Video>> videosOf(int playlistId) =>
      _repository.getVideos(playlistId);

  /// Adiciona um vídeo a uma playlist.
  Future<void> addVideo(int playlistId, Video video) async {
    try {
      await _repository.addVideo(playlistId, video);
    } catch (e) {
      _errorMessage = 'Não foi possível adicionar o vídeo: $e';
      _notify();
    }
  }

  Future<void> removeVideo(int playlistId, Video video) async {
    try {
      await _repository.removeVideo(playlistId, video.id);
    } catch (e) {
      _errorMessage = 'Não foi possível remover o vídeo: $e';
      _notify();
    }
  }

  /// Remove músicas de TODAS as playlists (arquivos excluídos do aparelho).
  ///
  /// Lote: apaga os registros de uma vez e recarrega as contagens — sem o
  /// [reload] a lista de playlists continuaria mostrando o item fantasma.
  Future<void> removeSongsFromAll(List<Song> songs) async {
    if (songs.isEmpty) return;
    try {
      for (final Song song in songs) {
        await _repository.removeSongFromAll(song.id);
      }
      await reload();
    } catch (e) {
      _errorMessage = 'Não foi possível atualizar as playlists: $e';
      _notify();
    }
  }

  /// Remove vídeos de TODAS as playlists (arquivos excluídos do aparelho).
  Future<void> removeVideosFromAll(List<Video> videos) async {
    if (videos.isEmpty) return;
    try {
      for (final Video video in videos) {
        await _repository.removeVideoFromAll(video.id);
      }
      await reload();
    } catch (e) {
      _errorMessage = 'Não foi possível atualizar as playlists: $e';
      _notify();
    }
  }

  /// Aplica a nova ordem de vídeos de uma playlist (drag & drop).
  Future<void> reorderVideos(int playlistId, List<Video> orderedVideos) async {
    try {
      await _repository.reorderVideos(
        playlistId,
        orderedVideos.map((v) => v.id).toList(),
      );
    } catch (e) {
      _errorMessage = 'Não foi possível reordenar: $e';
      _notify();
    }
  }

  void _notify() {
    if (!_isDisposed) notifyListeners();
  }

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
  }
}
