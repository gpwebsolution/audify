// Testes do item 4.1 — favoritos de música (tabela favorite_songs):
// repositório (add/remove/lista) e MIGRAÇÃO REAL de esquema 3 → 4.
//
// Usa sqflite_common_ffi (SQLite nativo em vez do canal do sqflite, que
// não existe em testes de unidade) — mesmo arranjo de
// playlist_videos_test.dart / playlist_ghost_songs_test.dart.

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:audify/models/song_model.dart';
import 'package:audify/services/playlist_database.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    await PlaylistDatabase.close();
    // Arquivo do banco persiste entre testes — remove para começar limpo.
    await databaseFactory.deleteDatabase(
      p.join(await getDatabasesPath(), 'audify.db'),
    );
  });

  tearDownAll(() async {
    await PlaylistDatabase.close();
  });

  Song song(String id, String title, {String? filePath}) =>
      Song.fromStored(<String, Object?>{
        'song_id': id,
        'title': title,
        'artist': 'Artista $id',
        'album': 'Álbum',
        'is_asset': 0,
        'file_path': filePath,
        'duration_ms': 180000,
      })!;

  Song assetSong(String id, String title) => Song.fromStored(<String, Object?>{
    'song_id': id,
    'title': title,
    'is_asset': 1,
    'asset_path': 'assets/songs/$id.mp3',
  })!;

  group('favorite_songs — repositório (4.1)', () {
    test('addFavorite + getFavorites + removeFavorite', () async {
      await PlaylistDatabase.addFavorite(song('media-1', 'Beta'));
      await PlaylistDatabase.addFavorite(song('media-2', 'Alfa'));

      List<Song> favorites = await PlaylistDatabase.getFavorites();
      // Ordem de leitura: título sem distinção de maiúsculas.
      expect(
        favorites.map((Song s) => s.id).toList(),
        <String>['media-2', 'media-1'],
      );

      await PlaylistDatabase.removeFavorite('media-1');
      favorites = await PlaylistDatabase.getFavorites();
      expect(favorites.map((Song s) => s.id).toList(), <String>['media-2']);
    });

    test('addFavorite é idempotente (repetir não duplica)', () async {
      await PlaylistDatabase.addFavorite(song('media-9', 'Nove'));
      await PlaylistDatabase.addFavorite(song('media-9', 'Nove'));
      expect(await PlaylistDatabase.getFavorites(), hasLength(1));
    });

    test(
      'getFavorites reconstrói a Song com file_path (reserva) e '
      'campos de exibição',
      () async {
        await PlaylistDatabase.addFavorite(
          song('media-3', 'Guardada', filePath: '/music/guardada.mp3'),
        );
        final Song loaded = (await PlaylistDatabase.getFavorites()).single;

        expect(loaded.id, 'media-3');
        expect(loaded.title, 'Guardada');
        expect(loaded.artist, 'Artista media-3');
        expect(loaded.filePath, '/music/guardada.mp3');
        expect(loaded.duration, const Duration(minutes: 3));
        expect(loaded.isAsset, isFalse);
      },
    );

    test('faixa asset também favorita (asset_path preservado)', () async {
      await PlaylistDatabase.addFavorite(assetSong('alpha', 'Alpha'));
      final Song loaded = (await PlaylistDatabase.getFavorites()).single;
      expect(loaded.isAsset, isTrue);
      expect(loaded.assetPath, 'assets/songs/alpha.mp3');
    });

    test('removeFavorite de id inexistente não lança', () async {
      await PlaylistDatabase.removeFavorite('nada-consta');
      expect(await PlaylistDatabase.getFavorites(), isEmpty);
    });
  });

  group('migração 3 → 4 (4.1)', () {
    test('banco v3 ganha favorite_songs sem perder playlists', () async {
      // Esquema v3 NA MÃO (o mesmo DDL que o onCreate antigo criava) +
      // dados de usuário — simula um aparelho que já usava o app.
      final String path = p.join(await getDatabasesPath(), 'audify.db');
      final Database db = await databaseFactory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 3,
          onCreate: (Database db, int version) async {
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
                FOREIGN KEY (playlist_id) REFERENCES playlists(id)
                  ON DELETE CASCADE
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
                FOREIGN KEY (playlist_id) REFERENCES playlists(id)
                  ON DELETE CASCADE
              )
            ''');
          },
        ),
      );
      await db.insert('playlists', <String, Object?>{'name': 'Legada'});
      await db.insert('playlist_songs', <String, Object?>{
        'playlist_id': 1,
        'song_id': 'media-1',
        'position': 0,
        'title': 'Faixa Legada',
        'is_asset': 0,
      });
      await db.close();

      // Reabre pelo singleton (versão 4) → onUpgrade 3→4 roda.
      // O SELECT na tabela nova SÓ funciona se a migração a criou.
      expect(await PlaylistDatabase.getFavorites(), isEmpty);

      // Dados antigos intactos (a migração não tocou nas playlists).
      final List<Map<String, Object?>> rows =
          await PlaylistDatabase.getPlaylists();
      expect(rows.single['name'], 'Legada');
      expect(rows.single['song_count'], 1);
      final List<Song> songs = await PlaylistDatabase.getSongs(1);
      expect(songs.single.title, 'Faixa Legada');

      // E a tabela nova aceita escrita+leitura no banco migrado.
      await PlaylistDatabase.addFavorite(song('media-7', 'Nova'));
      expect(
        (await PlaylistDatabase.getFavorites()).map((Song s) => s.id),
        <String>['media-7'],
      );
    });
  });
}
