import 'dart:async';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/song_model.dart';
import '../models/video_model.dart';

/// Banco de dados local do app (sqflite).
///
/// Responsabilidade: persistir as playlists do usuário. A mídia em si
/// nunca é copiada — guardamos apenas os metadados + identificadores
/// (id do MediaStore / caminho do asset), que são estáveis entre sessões.
///
/// Esquema:
///  - playlists(id INTEGER PK AUTOINCREMENT, name TEXT NOT NULL UNIQUE)
///  - playlist_songs(playlist_id FK, song_id TEXT, position INTEGER,
///    + colunas de exibição para reconstruir a Song offline)
///  - playlist_videos(playlist_id FK, video_id INTEGER, position INTEGER,
///    + colunas de exibição para reconstruir o Video offline)
class PlaylistDatabase {
  static const String _dbName = 'audify.db';
  static const int _dbVersion = 3;

  static Database? _db;

  /// Lock de abertura: sem ele, duas chamadas concorrentes a
  /// [_database()] (ex.: reload de playlists + playPlaylist no boot)
  /// ambas veem `_db == null`, abrem o banco DUAS vezes e a segunda
  /// conexão vaza — além de escritas em handles diferentes. O Completer
  /// garante uma única abertura; todos aguardam o mesmo Future.
  static Completer<Database>? _opening;

  static Future<Database> _database() async {
    final Database? existing = _db;
    if (existing != null && existing.isOpen) return existing;
    final Completer<Database>? inFlight = _opening;
    if (inFlight != null) return inFlight.future;

    final Completer<Database> completer = Completer<Database>();
    _opening = completer;
    try {
      final String path = p.join(await getDatabasesPath(), _dbName);
      final Database opened = await openDatabase(
        path,
        version: _dbVersion,
        onCreate: (db, version) async {
          await _createSchema(db);
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 2) {
            // Playlists agora aceitam vídeos também.
            await db.execute('''
              CREATE TABLE playlist_videos(
                playlist_id INTEGER NOT NULL,
                video_id INTEGER NOT NULL,
                position INTEGER NOT NULL,
                title TEXT,
                display_name TEXT,
                duration_ms INTEGER,
                file_path TEXT,
                size INTEGER,
                date_added INTEGER,
                PRIMARY KEY (playlist_id, video_id),
                FOREIGN KEY (playlist_id) REFERENCES playlists(id) ON DELETE CASCADE
              )
            ''');
          }
          if (oldVersion < 3) {
            await db.execute(
              "ALTER TABLE playlist_songs ADD COLUMN album_id INTEGER",
            );
          }
        },
      );
      _db = opened;
      completer.complete(opened);
      return opened;
    } catch (e) {
      // Propaga para todos que aguardavam e libera nova tentativa depois.
      completer.completeError(e);
      rethrow;
    } finally {
      _opening = null;
    }
  }

  static Future<void> _createSchema(Database db) async {
    await db.execute('''
      CREATE TABLE playlists(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE
      )
    ''');
    await db.execute('''
      CREATE TABLE playlist_songs(
        playlist_id INTEGER NOT NULL,
        song_id TEXT NOT NULL,
        position INTEGER NOT NULL,
        title TEXT,
        artist TEXT,
        album TEXT,
        media_id INTEGER,
        album_id INTEGER,
        file_path TEXT,
        asset_path TEXT,
        asset_key TEXT,
        is_asset INTEGER NOT NULL DEFAULT 0,
        duration_ms INTEGER,
        PRIMARY KEY (playlist_id, song_id),
        FOREIGN KEY (playlist_id) REFERENCES playlists(id) ON DELETE CASCADE
      )
    ''');
    await db.execute('''
      CREATE TABLE playlist_videos(
        playlist_id INTEGER NOT NULL,
        video_id INTEGER NOT NULL,
        position INTEGER NOT NULL,
        title TEXT,
        display_name TEXT,
        duration_ms INTEGER,
        file_path TEXT,
        size INTEGER,
        date_added INTEGER,
        PRIMARY KEY (playlist_id, video_id),
        FOREIGN KEY (playlist_id) REFERENCES playlists(id) ON DELETE CASCADE
      )
    ''');
  }

  /// Playlist com seu conjunto de faixas.
  static Future<Map<String, Object?>> createPlaylist(String name) async {
    final Database db = await _database();
    final int id = await db.insert('playlists', {'name': name});
    return {'id': id, 'name': name};
  }

  /// Todas as playlists com contagem de faixas e vídeos (para a lista da UI).
  static Future<List<Map<String, Object?>>> getPlaylists() async {
    final Database db = await _database();
    return db.rawQuery('''
      SELECT p.id, p.name,
        COUNT(DISTINCT ps.song_id) AS song_count,
        COUNT(DISTINCT pv.video_id) AS video_count
      FROM playlists p
      LEFT JOIN playlist_songs ps ON ps.playlist_id = p.id
      LEFT JOIN playlist_videos pv ON pv.playlist_id = p.id
      GROUP BY p.id
      ORDER BY p.name COLLATE NOCASE
    ''');
  }

  /// Faixas de uma playlist, na ordem salva.
  static Future<List<Song>> getSongs(int playlistId) async {
    final Database db = await _database();
    final List<Map<String, Object?>> rows = await db.query(
      'playlist_songs',
      where: 'playlist_id = ?',
      whereArgs: [playlistId],
      orderBy: 'position ASC',
    );
    return rows
        .map(Song.fromStored)
        .whereType<Song>()
        .toList();
  }

  /// Adiciona uma faixa ao fim da playlist (idempotente).
  static Future<void> addSong(int playlistId, Song song) async {
    final Database db = await _database();
    final List<Map<String, Object?>> rows = await db.query(
      'playlist_songs',
      columns: ['MAX(position) AS max_pos'],
      where: 'playlist_id = ?',
      whereArgs: [playlistId],
    );
    final int nextPosition =
        ((rows.firstOrNull?['max_pos'] as int?) ?? -1) + 1;

    final Map<String, Object?> values = song.toStored()
      ..['playlist_id'] = playlistId
      ..['position'] = nextPosition;

    await db.insert(
      'playlist_songs',
      values,
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  /// Remove uma faixa da playlist.
  static Future<void> removeSong(int playlistId, String songId) async {
    final Database db = await _database();
    await db.delete(
      'playlist_songs',
      where: 'playlist_id = ? AND song_id = ?',
      whereArgs: [playlistId, songId],
    );
  }

  /// Reordena as faixas da playlist conforme a ordem dos ids informados.
  ///
  /// Transação única: ou a nova ordem persiste inteira, ou nada muda —
  /// nunca fica "meio reordenada" se uma escrita falhar.
  static Future<void> reorderSongs(
    int playlistId,
    List<String> orderedSongIds,
  ) async {
    final Database db = await _database();
    await db.transaction((txn) async {
      for (int i = 0; i < orderedSongIds.length; i++) {
        await txn.update(
          'playlist_songs',
          {'position': i},
          where: 'playlist_id = ? AND song_id = ?',
          whereArgs: [playlistId, orderedSongIds[i]],
        );
      }
    });
  }

  /// Remove uma música de TODAS as playlists (quando é excluída do
  /// aparelho — nenhuma playlist pode apontar para um arquivo inexistente).
  static Future<void> removeSongFromAll(String songId) async {
    final Database db = await _database();
    await db.delete(
      'playlist_songs',
      where: 'song_id = ?',
      whereArgs: [songId],
    );
  }

  /// Vídeos de uma playlist, na ordem salva.
  static Future<List<Video>> getVideos(int playlistId) async {
    final Database db = await _database();
    final List<Map<String, Object?>> rows = await db.query(
      'playlist_videos',
      where: 'playlist_id = ?',
      whereArgs: [playlistId],
      orderBy: 'position ASC',
    );
    return rows.map(Video.fromStored).whereType<Video>().toList();
  }

  /// Adiciona um vídeo ao fim da playlist (idempotente).
  static Future<void> addVideo(int playlistId, Video video) async {
    final Database db = await _database();
    final List<Map<String, Object?>> rows = await db.query(
      'playlist_videos',
      columns: ['MAX(position) AS max_pos'],
      where: 'playlist_id = ?',
      whereArgs: [playlistId],
    );
    final int nextPosition =
        ((rows.firstOrNull?['max_pos'] as int?) ?? -1) + 1;

    final Map<String, Object?> values = video.toStored()
      ..['playlist_id'] = playlistId
      ..['position'] = nextPosition;

    await db.insert(
      'playlist_videos',
      values,
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  /// Remove um vídeo da playlist.
  static Future<void> removeVideo(int playlistId, int videoId) async {
    final Database db = await _database();
    await db.delete(
      'playlist_videos',
      where: 'playlist_id = ? AND video_id = ?',
      whereArgs: [playlistId, videoId],
    );
  }

  /// Reordena os vídeos da playlist (transação única).
  static Future<void> reorderVideos(
    int playlistId,
    List<int> orderedVideoIds,
  ) async {
    final Database db = await _database();
    await db.transaction((txn) async {
      for (int i = 0; i < orderedVideoIds.length; i++) {
        await txn.update(
          'playlist_videos',
          {'position': i},
          where: 'playlist_id = ? AND video_id = ?',
          whereArgs: [playlistId, orderedVideoIds[i]],
        );
      }
    });
  }

  /// Remove um vídeo de TODAS as playlists (quando é excluído do aparelho).
  static Future<void> removeVideoFromAll(int videoId) async {
    final Database db = await _database();
    await db.delete(
      'playlist_videos',
      where: 'video_id = ?',
      whereArgs: [videoId],
    );
  }

  /// Renomeia uma playlist.
  static Future<void> renamePlaylist(int id, String name) async {
    final Database db = await _database();
    await db.update(
      'playlists',
      {'name': name},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Exclui a playlist (as faixas somem em cascata).
  static Future<void> deletePlaylist(int id) async {
    final Database db = await _database();
    await db.delete('playlists', where: 'id = ?', whereArgs: [id]);
  }

  /// Fecha o banco (uso em testes).
  static Future<void> close() async {
    final Database? db = _db;
    _db = null;
    await db?.close();
  }
}