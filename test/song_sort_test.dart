// Testes do item 4.3 — comparação de ordenação e compatibilidade do
// Song com bancos antigos (song_sort + migração 5 → 6).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:audify/models/song_model.dart';
import 'package:audify/models/song_sort_key.dart';
import 'package:audify/services/playlist_database.dart';
import 'package:audify/utils/song_sort.dart';

Song _song(
  String id,
  String title, {
  String? artist,
  String? album,
  int? durationMs,
  int? dateAdded,
  int? track,
}) => Song.fromStored(<String, Object?>{
  'song_id': id,
  'title': title,
  'artist': artist,
  'album': album,
  'duration_ms': durationMs,
  'date_added': dateAdded,
  'track_number': track,
  'is_asset': 1,
})!;

List<String> _titles(List<Song> songs) => [for (final Song s in songs) s.title];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('comparadores (4.3)', () {
    test('título: ordem natural (Faixa 2 antes de Faixa 10)', () {
      final List<Song> songs = <Song>[
        _song('3', 'Faixa 10'),
        _song('1', 'Faixa 2'),
      ];
      songs.sort(
        (Song a, Song b) =>
            compareSongs(a, b, key: SongSortKey.title, ascending: true),
      );
      expect(_titles(songs), <String>['Faixa 2', 'Faixa 10']);
    });

    test('artista: com desempate por título; descendente inverte os dois', () {
      final List<Song> songs = <Song>[
        _song('1', 'Zebra', artist: 'Beta'),
        _song('2', 'Alfa', artist: 'Alfa'),
        _song('3', 'Yoga', artist: 'Alfa'),
      ];
      songs.sort(
        (Song a, Song b) =>
            compareSongs(a, b, key: SongSortKey.artist, ascending: true),
      );
      expect(_titles(songs), <String>['Alfa', 'Yoga', 'Zebra']);

      songs.sort(
        (Song a, Song b) =>
            compareSongs(a, b, key: SongSortKey.artist, ascending: false),
      );
      expect(_titles(songs), <String>['Zebra', 'Yoga', 'Alfa']);
    });

    test('duração: nulo nunca disputa (último em QUALQUER sentido)', () {
      final List<Song> songs = <Song>[
        _song('1', 'Curta', durationMs: 1000),
        _song('2', 'Sem', durationMs: null),
        _song('3', 'Longa', durationMs: 60000),
      ];

      songs.sort(
        (Song a, Song b) =>
            compareSongs(a, b, key: SongSortKey.duration, ascending: true),
      );
      expect(_titles(songs), <String>['Curta', 'Longa', 'Sem']);

      songs.sort(
        (Song a, Song b) =>
            compareSongs(a, b, key: SongSortKey.duration, ascending: false),
      );
      expect(_titles(songs), <String>['Longa', 'Curta', 'Sem']);
    });

    test('data de adição: crescente por epoch, nulo no fim', () {
      final List<Song> songs = <Song>[
        _song('1', 'Nova', dateAdded: 200),
        _song('2', 'Sem data', dateAdded: null),
        _song('3', 'Velha', dateAdded: 100),
      ];
      songs.sort(
        (Song a, Song b) =>
            compareSongs(a, b, key: SongSortKey.dateAdded, ascending: true),
      );
      expect(_titles(songs), <String>['Velha', 'Nova', 'Sem data']);
    });

    test('mais tocadas: contagens do histórico, sem play vale 0', () {
      final List<Song> songs = <Song>[
        _song('1', 'Uma'),
        _song('2', 'Duas'),
        _song('3', 'Zero'),
      ];
      const Map<String, int> counts = <String, int>{'1': 5, '2': 9};
      songs.sort(
        (Song a, Song b) => compareSongs(
          a,
          b,
          key: SongSortKey.mostPlayed,
          ascending: false,
          playCounts: counts,
        ),
      );
      expect(_titles(songs), <String>['Duas', 'Uma', 'Zero']);
    });

    test('desempate natural do álbum é por número da faixa', () {
      final List<Song> songs = <Song>[
        _song('1', 'Intro', track: null),
        _song('2', 'B', track: 3),
        _song('3', 'A', track: 2),
        _song('4', 'Começo', track: 1),
      ];
      songs.sort(compareByTrack);
      expect(_titles(songs), <String>['Começo', 'A', 'B', 'Intro']);
    });
  });

  group('Song — dateAdded/trackNumber (4.3)', () {
    test('roundtrip toStored/fromStored preserva os campos', () {
      final Song original = _song(
        'm1',
        'Faixa',
        dateAdded: 1712345678,
        track: 7,
        durationMs: 12345,
      );
      final Song restored = Song.fromStored(original.toStored())!;
      expect(restored.dateAdded, 1712345678);
      expect(restored.trackNumber, 7);
      expect(restored.duration, const Duration(milliseconds: 12345));
    });

    test('mapa ANTIGO (sem as colunas) vira null, nunca crash', () {
      final Song? song = Song.fromStored(<String, Object?>{
        'song_id': 'antiga',
        'title': 'Antiga',
        'is_asset': 0,
        'duration_ms': 500,
      });
      expect(song, isNotNull);
      expect(song!.dateAdded, isNull);
      expect(song.trackNumber, isNull);
    });
  });

  group('banco — migração 5 → 6 (4.3)', () {
    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      // Diretório exclusivo desta suíte: outras suítes rodam em paralelo
      // e apagam o audify.db compartilhado do cwd (corrida de arquivo).
      await databaseFactory.setDatabasesPath(
        Directory.systemTemp.createTempSync('audify_song_sort_').path,
      );
    });

    setUp(() async {
      await PlaylistDatabase.close();
      await databaseFactory.deleteDatabase(
        p.join(await getDatabasesPath(), 'audify.db'),
      );
    });

    tearDownAll(() async {
      await PlaylistDatabase.close();
    });

    test('banco v5 ganha as colunas e aceita as faixas novas', () async {
      final String path = p.join(await getDatabasesPath(), 'audify.db');
      final Database dbV5 = await databaseFactory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 5,
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
            await db.execute('''
              CREATE TABLE song_stats(
                song_id TEXT PRIMARY KEY,
                play_count INTEGER NOT NULL DEFAULT 0,
                last_played INTEGER NOT NULL
              )
            ''');
          },
        ),
      );
      // Linha antiga: SEM date_added/track_number (não existiam).
      await dbV5.insert('favorite_songs', <String, Object?>{
        'song_id': 'velha',
        'title': 'Velha',
        'is_asset': 0,
        'added_at': 1,
      });
      await dbV5.close();

      // Reabre pelo caminho do app (5 → 6 roda o ALTER).
      // Faixa nova completa: INSERT não pode estourar coluna inexistente.
      await PlaylistDatabase.addFavorite(
        Song.fromStored(<String, Object?>{
          'song_id': 'nova',
          'title': 'Nova',
          'is_asset': 0,
          'date_added': 1712345678,
          'track_number': 3,
        })!,
      );

      final List<Song> favorites = await PlaylistDatabase.getFavorites();
      expect(favorites.map((Song s) => s.id).toSet(), <String>{
        'velha',
        'nova',
      });
      final Song velha = favorites.firstWhere((Song s) => s.id == 'velha');
      final Song nova = favorites.firstWhere((Song s) => s.id == 'nova');
      expect(velha.dateAdded, isNull); // linha pré-migração lida com null
      expect(velha.trackNumber, isNull);
      expect(nova.dateAdded, 1712345678);
      expect(nova.trackNumber, 3);
    });
  });
}
