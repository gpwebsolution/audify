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
///  - favorite_songs(song_id TEXT PK, file_path TEXT como reserva se o
///    id do MediaStore mudar ao reindexar, + colunas de exibição,
///    added_at INTEGER) — item 4.1 (favoritos de música)
///  - song_stats(song_id TEXT PK, play_count INTEGER, last_played
///    INTEGER) — item 4.2 (histórico e mais tocadas)
class PlaylistDatabase {
  static const String _dbName = 'audify.db';
  static const int _dbVersion = 5;

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
          if (oldVersion < 4) {
            // Item 4.1 — favoritos de música. Chave song_id; file_path
            // como reserva (o id do MediaStore muda se o arquivo for
            // reindexado — o caminho permite re-associar depois).
            await _createFavoriteSongs(db);
          }
          if (oldVersion < 5) {
            // Item 4.2 — histórico de reprodução (contagem por faixa).
            await _createSongStats(db);
          }
        },
      );
      _db = opened;
      completer.complete(opened);
      return opened;
    } catch (e) {
      // Propaga para todos que aguardavam e libera nova tentativa depois.
      // `ignore()` ANTES: se esta é a primeira chamada e o chamador é
      // fire-and-forget (ex.: gravação de histórico), o completer não
      // tem awaiter — sem ouvinte, o completeError viraria um erro
      // async não tratado na zona do chamador.
      completer.future.ignore();
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
    await _createFavoriteSongs(db);
    await _createSongStats(db);
  }

  /// Item 4.1 — tabela de favoritos (usada no onCreate E no onUpgrade
  /// 3→4; mesma DDL nos dois caminhos para o esquema nunca divergir).
  static Future<void> _createFavoriteSongs(Database db) async {
    await db.execute('''
      CREATE TABLE favorite_songs(
        song_id TEXT PRIMARY KEY,
        file_path TEXT,
        title TEXT,
        artist TEXT,
        album TEXT,
        media_id INTEGER,
        album_id INTEGER,
        asset_path TEXT,
        asset_key TEXT,
        is_asset INTEGER NOT NULL DEFAULT 0,
        duration_ms INTEGER,
        added_at INTEGER NOT NULL
      )
    ''');
  }

  /// Item 4.2 — histórico de reprodução (usada no onCreate E no
  /// onUpgrade 4→5; mesma DDL nos dois caminhos).
  static Future<void> _createSongStats(Database db) async {
    await db.execute('''
      CREATE TABLE song_stats(
        song_id TEXT PRIMARY KEY,
        play_count INTEGER NOT NULL DEFAULT 0,
        last_played INTEGER NOT NULL
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
    return rows.map(Song.fromStored).whereType<Song>().toList();
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
    final int nextPosition = ((rows.firstOrNull?['max_pos'] as int?) ?? -1) + 1;

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

  // ------------------------------------------------------------------
  // Item 4.1 — favoritos de música (favorite_songs)
  // ------------------------------------------------------------------

  /// Favorita uma faixa (idempotente: repetir não duplica nem mexe no
  /// `added_at` original — o INSERT é ignorado em conflito de chave).
  static Future<void> addFavorite(Song song) async {
    final Database db = await _database();
    await db.insert(
      'favorite_songs',
      song.toStored()
        ..['added_at'] = DateTime.now().millisecondsSinceEpoch,
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  /// Desfavorita (no-op silencioso se a faixa não estava favoritada).
  static Future<void> removeFavorite(String songId) async {
    final Database db = await _database();
    await db.delete(
      'favorite_songs',
      where: 'song_id = ?',
      whereArgs: [songId],
    );
  }

  /// Favoritas na mesma ordem de leitura das playlists (título sem
  /// distinção de maiúsculas) — [Song.fromStored] reconstrói offline.
  static Future<List<Song>> getFavorites() async {
    final Database db = await _database();
    final List<Map<String, Object?>> rows = await db.query(
      'favorite_songs',
      orderBy: 'title COLLATE NOCASE',
    );
    return rows.map(Song.fromStored).whereType<Song>().toList();
  }

  // ------------------------------------------------------------------
  // Item 4.2 — histórico de reprodução (song_stats)
  // ------------------------------------------------------------------

  /// Registra UMA reprodução da faixa em [playedAtMs] (epoch): soma 1
  /// na contagem e atualiza o último toque. UPDATE + INSERT em
  /// transação em vez do "upsert" ON CONFLICT (SQLite < 3.24, que é o
  /// que roda em Android antigo, não o entende).
  static Future<void> recordPlay(String songId, {required int playedAtMs}) async {
    final Database db = await _database();
    await db.transaction((Transaction txn) async {
      final int updated = await txn.rawUpdate(
        'UPDATE song_stats SET play_count = play_count + 1, '
        'last_played = ? WHERE song_id = ?',
        <Object>[playedAtMs, songId],
      );
      if (updated == 0) {
        await txn.insert('song_stats', <String, Object?>{
          'song_id': songId,
          'play_count': 1,
          'last_played': playedAtMs,
        });
      }
    });
  }

  /// Stats de todas as faixas com histórico: mais tocadas primeiro
  /// (empate: último toque mais recente). A ordem "recentemente" é só
  /// uma inversão por `last_played`, feita em memória pelo provider.
  static Future<List<Map<String, Object?>>> getStats() async {
    final Database db = await _database();
    return db.query(
      'song_stats',
      orderBy: 'play_count DESC, last_played DESC',
    );
  }

  /// Apaga todo o histórico (opção "limpar histórico").
  static Future<void> clearHistory() async {
    final Database db = await _database();
    await db.delete('song_stats');
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
    final int nextPosition = ((rows.firstOrNull?['max_pos'] as int?) ?? -1) + 1;

    final Map<String, Object?> values = video.toStored()
      ..['playlist_id'] = playlistId
      ..['position'] = nextPosition;

    await db.insert(
      'playlist_videos',
      values,
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  /// Separador usado no `GROUP_CONCAT` dos ids: o caractere de controle
  /// ASCII 31 (unit separator). Escolhido porque nunca aparece num id do
  /// MediaStore nem num caminho de asset, então o split é seguro.
  static const String kGroupSeparator = '\u001f';

  /// Adiciona VÁRIAS faixas ao fim da playlist numa transação única.
  ///
  /// Existe para o modo de seleção múltipla: chamar [addSong] em laço fazia
  /// uma query de `MAX(position)` + um insert por faixa (10 faixas = 20
  /// operações, sem atomicidade). Aqui a posição inicial e a lista de ids já
  /// presentes são lidas UMA vez e os inserts correm numa transação — ou entra
  /// tudo, ou nada.
  ///
  /// Devolve quantas faixas entraram **de fato**. Faixa repetida na mesma
  /// playlist é contada como ignorada: o `ConflictAlgorithm.ignore` a
  /// descartaria, mas o laço interno já a elimina para o contador não mentir.
  static Future<int> addSongs(int playlistId, List<Song> songs) async {
    if (songs.isEmpty) return 0;
    final Database db = await _database();

    return db.transaction<int>((Transaction txn) async {
      // Query única com as duas informações que o lote precisa.
      final List<Map<String, Object?>> rows = await txn.rawQuery(
        'SELECT MAX(position) AS max_pos, '
        'GROUP_CONCAT(song_id, char(31)) AS ids '
        'FROM playlist_songs WHERE playlist_id = ?',
        <Object?>[playlistId],
      );
      final Map<String, Object?> row = rows.first;
      int position = ((row['max_pos'] as int?) ?? -1) + 1;
      final Set<String> existing = <String>{
        if (row['ids'] is String)
          ...(row['ids']! as String)
              .split(kGroupSeparator)
              .where((String id) => id.isNotEmpty),
      };

      // Ignora repetidas do próprio lote e as que já estão na playlist.
      final Set<String> batch = <String>{};
      final List<Song> toInsert = <Song>[
        for (final Song song in songs)
          if (batch.add(song.id) && !existing.contains(song.id)) song,
      ];
      if (toInsert.isEmpty) return 0;

      final Batch insertBatch = txn.batch();
      for (final Song song in toInsert) {
        insertBatch.insert(
          'playlist_songs',
          song.toStored()
            ..['playlist_id'] = playlistId
            ..['position'] = position,
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        position++;
      }
      await insertBatch.commit(noResult: true);
      return toInsert.length;
    });
  }

  /// Adiciona VÁRIOS vídeos numa transação única (mesmo motivo de [addSongs]).
  static Future<int> addVideos(int playlistId, List<Video> videos) async {
    if (videos.isEmpty) return 0;
    final Database db = await _database();

    return db.transaction<int>((Transaction txn) async {
      final List<Map<String, Object?>> rows = await txn.rawQuery(
        'SELECT MAX(position) AS max_pos, '
        'GROUP_CONCAT(video_id) AS ids '
        'FROM playlist_videos WHERE playlist_id = ?',
        <Object?>[playlistId],
      );
      final Map<String, Object?> row = rows.first;
      int position = ((row['max_pos'] as int?) ?? -1) + 1;
      final Set<String> existing = <String>{
        if (row['ids'] is String)
          ...(row['ids']! as String)
              .split(',')
              .where((String id) => id.isNotEmpty),
      };

      final Set<int> batch = <int>{};
      final List<Video> toInsert = <Video>[
        for (final Video video in videos)
          if (batch.add(video.id) && !existing.contains('${video.id}')) video,
      ];
      if (toInsert.isEmpty) return 0;

      final Batch insertBatch = txn.batch();
      for (final Video video in toInsert) {
        insertBatch.insert(
          'playlist_videos',
          video.toStored()
            ..['playlist_id'] = playlistId
            ..['position'] = position,
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        position++;
      }
      await insertBatch.commit(noResult: true);
      return toInsert.length;
    });
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
