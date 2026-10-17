// Testes do item 4.2 — histórico de reprodução (song_stats).
//
// Três camadas:
//  - PlaybackHistoryService: regra de contagem (30 s OU 50%, uma vez
//    por execução da faixa) com relógio e persistência injetáveis;
//  - PlaylistDatabase: repositório song_stats com sqflite_common_ffi +
//    migração 4 → 5;
//  - PlayerProvider: integração — o tick de posição publicado pelo
//    AudioService dispara a gravação (e só uma vez).

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:audify/models/song_model.dart';
import 'package:audify/providers/player_provider.dart';
import 'package:audify/repositories/session_repository.dart';
import 'package:audify/repositories/song_repository.dart';
import 'package:audify/services/playback_history_service.dart';
import 'package:audify/services/playlist_database.dart';

import 'support/playable_audio_service.dart';

Song _track(String name) =>
    Song.fromAsset(assetPath: 'assets/songs/$name.mp3');

class _FakeSongRepository extends SongRepository {
  final List<Song> assets;
  _FakeSongRepository(this.assets);

  @override
  Future<List<Song>> loadDeviceSongs() async => const [];

  @override
  Future<List<Song>> loadAssetSongs() async => assets;
}

class _FakeSessionRepository extends SessionRepository {
  @override
  Future<void> save(Song song, Duration position) async {}

  @override
  Future<void> saveQueue(List<String> ids, int index) async {}

  @override
  Future<void> clear() async {}

  @override
  Future<(Song?, Duration)> load() async => (null, Duration.zero);

  @override
  Future<(List<String>, int)> loadQueue() async => (const <String>[], -1);
}

PlayerProvider _provider(PlayableAudioService svc, PlaybackHistoryService h) =>
    PlayerProvider(
      svc,
      songRepository: _FakeSongRepository(<Song>[
        _track('alpha'),
        _track('beta'),
        _track('gamma'),
      ]),
      sessionRepository: _FakeSessionRepository(),
      history: h,
    );

/// Serviço com spy de gravação e relógio fixo (a regra não toca banco).
PlaybackHistoryService _service(
  List<(String, int)> records, {
  DateTime? now,
}) =>
    PlaybackHistoryService(
      onRecord: (String songId, int playedAtMs) async {
        records.add((songId, playedAtMs));
      },
      clock: () => now ?? DateTime(2026, 10, 16, 12),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('regra de contagem (4.2)', () {
    test('não conta antes de 30 s nem antes de 50% da faixa', () {
      final List<(String, int)> records = <(String, int)>[];
      final PlaybackHistoryService svc = _service(records);
      final Song alpha = _track('alpha');

      svc.onProgress(
        alpha,
        const Duration(seconds: 29),
        const Duration(minutes: 2),
        isPlaying: true,
      );
      svc.onProgress(
        alpha,
        const Duration(seconds: 10),
        const Duration(minutes: 5),
        isPlaying: true,
      );
      expect(records, isEmpty);
    });

    test('conta em 30 s exatos com o relógio injetado', () {
      final List<(String, int)> records = <(String, int)>[];
      final DateTime now = DateTime(2026, 10, 16, 12, 30);
      final PlaybackHistoryService svc = _service(records, now: now);
      final Song alpha = _track('alpha');

      svc.onProgress(
        alpha,
        const Duration(seconds: 30),
        const Duration(minutes: 2),
        isPlaying: true,
      );

      expect(records, hasLength(1));
      expect(records.single.$1, alpha.id);
      expect(records.single.$2, now.millisecondsSinceEpoch);
    });

    test('50% da faixa conta mesmo antes dos 30 s', () {
      final List<(String, int)> records = <(String, int)>[];
      final PlaybackHistoryService svc = _service(records);

      svc.onProgress(
        _track('alpha'),
        const Duration(seconds: 10), // 10 s de 20 s = 50%
        const Duration(seconds: 20),
        isPlaying: true,
      );
      expect(records, hasLength(1));
    });

    test('duração desconhecida só conta aos 30 s', () {
      final List<(String, int)> records = <(String, int)>[];
      final PlaybackHistoryService svc = _service(records);
      final Song alpha = _track('alpha');

      svc.onProgress(
        alpha,
        const Duration(seconds: 15),
        Duration.zero,
        isPlaying: true,
      );
      expect(records, isEmpty);

      svc.onProgress(
        alpha,
        const Duration(seconds: 30),
        Duration.zero,
        isPlaying: true,
      );
      expect(records, hasLength(1));
    });

    test('seek para trás não reconta na mesma execução', () {
      final List<(String, int)> records = <(String, int)>[];
      final PlaybackHistoryService svc = _service(records);
      final Song alpha = _track('alpha');
      const Duration twoMin = Duration(minutes: 2);

      svc.onProgress(
        alpha,
        const Duration(seconds: 30),
        twoMin,
        isPlaying: true,
      );
      svc.onProgress(alpha, Duration.zero, twoMin, isPlaying: true);
      svc.onProgress(
        alpha,
        const Duration(seconds: 45),
        twoMin,
        isPlaying: true,
      );
      expect(records, hasLength(1));
    });

    test('trocar de faixa e voltar conta de novo', () {
      final List<(String, int)> records = <(String, int)>[];
      final PlaybackHistoryService svc = _service(records);
      final Song alpha = _track('alpha');
      final Song beta = _track('beta');
      const Duration twoMin = Duration(minutes: 2);

      svc.onProgress(alpha, const Duration(seconds: 30), twoMin,
          isPlaying: true);
      svc.onProgress(beta, const Duration(seconds: 30), twoMin,
          isPlaying: true);
      expect(records, hasLength(2));

      // Volta para a faixa já tocada: nova execução → conta de novo.
      svc.onProgress(alpha, const Duration(seconds: 30), twoMin,
          isPlaying: true);
      expect(records, hasLength(3));
      expect(records.last.$1, alpha.id);
    });

    test('parada da faixa zera a execução (tocar de novo conta)', () {
      final List<(String, int)> records = <(String, int)>[];
      final PlaybackHistoryService svc = _service(records);
      final Song alpha = _track('alpha');
      const Duration twoMin = Duration(minutes: 2);

      svc.onProgress(alpha, const Duration(seconds: 30), twoMin,
          isPlaying: true);
      svc.onProgress(null, Duration.zero, twoMin, isPlaying: false);
      svc.onProgress(alpha, const Duration(seconds: 30), twoMin,
          isPlaying: true);
      expect(records, hasLength(2));
    });

    test('posição nova com o player pausado não conta', () {
      final List<(String, int)> records = <(String, int)>[];
      final PlaybackHistoryService svc = _service(records);

      // Seek até 40 s com a faixa pausada: não é ouvida.
      svc.onProgress(
        _track('alpha'),
        const Duration(seconds: 40),
        const Duration(minutes: 2),
        isPlaying: false,
      );
      expect(records, isEmpty);
    });

    test('falha de gravação não propaga para o tick de posição', () async {
      final PlaybackHistoryService svc = PlaybackHistoryService(
        onRecord: (String songId, int playedAtMs) async {
          throw StateError('banco indisponível');
        },
        clock: () => DateTime(2026, 10, 16),
      );

      expect(
        () => svc.onProgress(
          _track('alpha'),
          const Duration(seconds: 31),
          const Duration(minutes: 2),
          isPlaying: true,
        ),
        returnsNormally,
      );
      await pumpEventQueue();
    });
  });

  group('song_stats — repositório (4.2)', () {
    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
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

    test('recordPlay cria a linha e soma nas repetições', () async {
      await PlaylistDatabase.recordPlay('s1', playedAtMs: 100);
      List<Map<String, Object?>> rows =
          await PlaylistDatabase.getStats();
      expect(rows, hasLength(1));
      expect(rows.single['song_id'], 's1');
      expect(rows.single['play_count'], 1);
      expect(rows.single['last_played'], 100);

      await PlaylistDatabase.recordPlay('s1', playedAtMs: 200);
      rows = await PlaylistDatabase.getStats();
      expect(rows, hasLength(1));
      expect(rows.single['play_count'], 2);
      expect(rows.single['last_played'], 200);
    });

    test('getStats ordena por contagem e depois pelo último toque',
        () async {
      // A: 2 plays (último 10) | B: 3 plays | C: 2 plays (último 30).
      await PlaylistDatabase.recordPlay('a', playedAtMs: 9);
      await PlaylistDatabase.recordPlay('a', playedAtMs: 10);
      for (final int ms in <int>[11, 12, 13]) {
        await PlaylistDatabase.recordPlay('b', playedAtMs: ms);
      }
      await PlaylistDatabase.recordPlay('c', playedAtMs: 29);
      await PlaylistDatabase.recordPlay('c', playedAtMs: 30);

      final List<Map<String, Object?>> rows =
          await PlaylistDatabase.getStats();
      expect(
        rows.map((Map<String, Object?> r) => r['song_id']).toList(),
        <String>['b', 'c', 'a'],
      );
    });

    test('clearHistory apaga o histórico inteiro', () async {
      await PlaylistDatabase.recordPlay('s1', playedAtMs: 1);
      await PlaylistDatabase.recordPlay('s2', playedAtMs: 2);
      await PlaylistDatabase.clearHistory();
      expect(await PlaylistDatabase.getStats(), isEmpty);
    });

    test('migração 4 → 5 cria song_stats sem perder dados', () async {
      // Banco na mão no esquema v4 (sem song_stats) com dados.
      final String path = p.join(await getDatabasesPath(), 'audify.db');
      final Database dbV4 = await databaseFactory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 4,
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
          },
        ),
      );
      await dbV4.insert('playlists', <String, Object?>{'name': 'Antiga'});
      await dbV4.insert(
        'favorite_songs',
        <String, Object?>{
          'song_id': 'fav1',
          'title': 'Favorita',
          'is_asset': 0,
          'added_at': 42,
        },
      );
      await dbV4.close();

      // Reabre pelo caminho do app (version 5 dispara o onUpgrade).
      expect(await PlaylistDatabase.getStats(), isEmpty);
      final List<Map<String, Object?>> playlists =
          await PlaylistDatabase.getPlaylists();
      expect(playlists.single['name'], 'Antiga');
      expect(await PlaylistDatabase.getFavorites(), hasLength(1));
      // E o caminho novo já funciona logo na abertura.
      await PlaylistDatabase.recordPlay('n1', playedAtMs: 7);
      expect(await PlaylistDatabase.getStats(), hasLength(1));
    });
  });

  group('PlayerProvider registra reprodução (4.2)', () {
    test('posição acima do limiar grava uma única vez por execução',
        () async {
      final PlayableAudioService audio = PlayableAudioService();
      final List<(String, int)> records = <(String, int)>[];
      final PlayerProvider provider =
          _provider(audio, _service(records));
      addTearDown(provider.dispose);
      await provider.init();

      await provider.playVisibleAt(0); // Alpha tocando
      // Duração do provider vem do notifier do serviço.
      audio.duration.value = const Duration(minutes: 2);

      audio.position.value = const Duration(seconds: 31);
      await pumpEventQueue();
      expect(records, hasLength(1));
      expect(records.single.$1, provider.currentSong!.id);

      // Mesma execução: ticks seguintes e seek para trás não recontam.
      audio.position.value = const Duration(seconds: 32);
      audio.position.value = Duration.zero;
      audio.position.value = const Duration(seconds: 45);
      await pumpEventQueue();
      expect(records, hasLength(1));

      // Pausado: posição nova não é ouvida.
      await provider.togglePlayPause(); // pausa
      audio.position.value = const Duration(seconds: 50);
      await pumpEventQueue();
      expect(records, hasLength(1));

      // Próxima faixa: nova execução, conta de novo.
      await provider.togglePlayPause(); // retoma da pausa
      await provider.playVisibleAt(1); // Beta
      audio.position.value = const Duration(seconds: 31);
      await pumpEventQueue();
      expect(records, hasLength(2));
      expect(records.last.$1, provider.currentSong!.id);
    });

    test('50% da faixa conta sem chegar aos 30 s', () async {
      final PlayableAudioService audio = PlayableAudioService();
      final List<(String, int)> records = <(String, int)>[];
      final PlayerProvider provider =
          _provider(audio, _service(records));
      addTearDown(provider.dispose);
      await provider.init();

      await provider.playVisibleAt(0);
      audio.duration.value = const Duration(seconds: 20);
      audio.position.value = const Duration(seconds: 10);
      await pumpEventQueue();
      expect(records, hasLength(1));
    });
  });
}
