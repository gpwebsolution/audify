// Testes do item 2.6 — faixas fantasma nas playlists: reconciliação com o
// catálogo ao abrir (song_id, depois file_path), marcação das indisponíveis
// e remoção em lote. Banco REAL com sqflite_common_ffi (SQLite nativo em
// testes — o canal do sqflite não existe na VM).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:audify/models/song_model.dart';
import 'package:audify/providers/player_provider.dart';
import 'package:audify/providers/playlist_provider.dart';
import 'package:audify/repositories/session_repository.dart';
import 'package:audify/repositories/song_repository.dart';
import 'package:audify/services/playlist_database.dart';

import 'support/playable_audio_service.dart';

Song _song({
  required String id,
  required String title,
  String? filePath,
  String? assetPath,
  bool isAsset = false,
}) =>
    Song.fromStored(<String, Object?>{
      'song_id': id,
      'title': title,
      'file_path': filePath,
      'asset_path': assetPath,
      'is_asset': isAsset ? 1 : 0,
    })!;

class _FakeRepo extends SongRepository {
  final List<Song> device;
  _FakeRepo(this.device);

  @override
  Future<List<Song>> loadDeviceSongs() async => device;

  @override
  Future<List<Song>> loadAssetSongs() async => const <Song>[];
}

class _FakeSession extends SessionRepository {
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

List<String> _ids(List<Song> songs) =>
    songs.map((Song s) => s.id).toList(growable: false);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    mockAudioplayersChannels();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('reconcileSongs (2.6) — puro', () {
    test('casa por song_id (instância nova), depois file_path (id mudou); '
        'fantasma é o que não bate e não tem arquivo', () async {
      final List<Song> stored = <Song>[
        _song(id: 'media-1', title: 'Título velho A', filePath: '/music/a.mp3'),
        _song(id: 'media-2', title: 'B', filePath: '/music/b.mp3'),
        _song(id: 'velho-9', title: 'C', filePath: '/music/c.mp3'),
      ];
      final List<Song> catalog = <Song>[
        // Mesmo id, título atualizado no MediaStore → usa a instância nova.
        _song(id: 'media-1', title: 'Título novo A', filePath: '/music/a.mp3'),
        // Mesmo arquivo, id renasceu (arquivo movido/reindexado).
        _song(id: 'novo-7', title: 'C', filePath: '/music/c.mp3'),
      ];

      final PlaylistSongsView view = await PlaylistProvider.reconcileSongs(
        stored,
        catalog: catalog,
      );

      expect(_ids(view.songs), <String>['media-1', 'novo-7'],
          reason: 'a por id, c por path (com o id atual do catálogo); '
              'ordem da playlist preservada');
      expect(view.songs.first.title, 'Título novo A',
          reason: 'metadados frescos do catálogo, não o snapshot morto');
      expect(_ids(view.missing), <String>['media-2'],
          reason: 'b não está no catálogo e /music/b.mp3 não existe');
    });

    test('fora do catálogo mas arquivo no disco (filtro 2.5) NÃO é fantasma',
        () async {
      final Directory dir = await Directory.systemTemp.createTemp('audify_26');
      addTearDown(() => dir.delete(recursive: true));
      final File viva = File(p.join(dir.path, 'viva.mp3'))
        ..writeAsStringSync('x');

      final PlaylistSongsView view = await PlaylistProvider.reconcileSongs(
        <Song>[_song(id: 'escondida', title: 'Filtrada', filePath: viva.path)],
        catalog: <Song>[
          _song(id: 'outra', title: 'Outra', filePath: '/music/outra.mp3'),
        ],
      );

      expect(_ids(view.songs), <String>['escondida'],
          reason: 'o arquivo existe em disco — só o filtro 2.5 escondeu; '
              '"Remover indisponíveis" não pode apagar isso');
      expect(view.missing, isEmpty);
    });

    test('catálogo vazio não marca nada (guarda) e asset nunca é fantasma',
        () async {
      final PlaylistSongsView semCatalogo =
          await PlaylistProvider.reconcileSongs(
        <Song>[
          _song(id: 'a', title: 'A', filePath: '/music/a.mp3'),
          _song(id: 'b', title: 'B', filePath: '/music/b.mp3'),
        ],
        catalog: const <Song>[],
      );
      expect(_ids(semCatalogo.songs), <String>['a', 'b'],
          reason: 'catálogo vazio = ainda carregando/sem permissão; marcar '
              'tudo daria "Remover indisponíveis" o poder de apagar a '
              'playlist inteira à toa');
      expect(semCatalogo.missing, isEmpty);

      final PlaylistSongsView comAsset = await PlaylistProvider.reconcileSongs(
        <Song>[
          _song(
            id: 'assets/songs/anjo.mp3',
            title: 'Anjo',
            isAsset: true,
            assetPath: 'assets/songs/anjo.mp3',
          ),
          _song(id: 'sumiu', title: 'Sumiu', filePath: '/music/sumiu.mp3'),
        ],
        catalog: <Song>[
          _song(id: 'x', title: 'X', filePath: '/music/x.mp3'),
        ],
      );
      expect(_ids(comAsset.songs), <String>['assets/songs/anjo.mp3'],
          reason: 'asset vive no bundle — só some se o app mudar');
      expect(_ids(comAsset.missing), <String>['sumiu']);
    });
  });

  group('songsOf + remoção em lote no banco ffi (2.6)', () {
    setUp(() async {
      await PlaylistDatabase.close();
      // Arquivo do banco persiste entre testes — começa limpo.
      await databaseFactory.deleteDatabase(
        p.join(await getDatabasesPath(), 'audify.db'),
      );
    });

    tearDownAll(() => PlaylistDatabase.close());

    test('abrir reconcilia; "Remover indisponíveis" some com o snapshot '
        'fantasma da playlist', () async {
      // Catálogo: a atualizado, c reindexado (id novo, mesmo arquivo);
      // b saiu do aparelho.
      final PlayerProvider player = PlayerProvider(
        PlayableAudioService(),
        songRepository: _FakeRepo(<Song>[
          _song(id: 'media-1', title: 'A novo', filePath: '/music/a.mp3'),
          _song(id: 'novo-7', title: 'C novo', filePath: '/music/c.mp3'),
        ]),
        sessionRepository: _FakeSession(),
        settings: null,
      );
      addTearDown(player.dispose);
      await player.init();

      final int playlistId =
          (await PlaylistDatabase.createPlaylist('Graves'))['id'] as int;
      // Snapshot antigo no banco (id b, id antigo de c).
      await PlaylistDatabase.addSong(
        playlistId,
        _song(id: 'media-1', title: 'A velho', filePath: '/music/a.mp3'),
      );
      await PlaylistDatabase.addSong(
        playlistId,
        _song(id: 'media-2', title: 'B', filePath: '/music/b.mp3'),
      );
      await PlaylistDatabase.addSong(
        playlistId,
        _song(id: 'velho-9', title: 'C velho', filePath: '/music/c.mp3'),
      );

      final PlaylistProvider provider = PlaylistProvider(player);
      addTearDown(provider.dispose);

      final PlaylistSongsView view = await provider.songsOf(playlistId);
      expect(_ids(view.songs), <String>['media-1', 'novo-7'],
          reason: 'a casa por id, c por file_path — nada de fantasma na fila');
      expect(view.songs.first.title, 'A novo');
      expect(_ids(view.missing), <String>['media-2']);

      await provider.removeUnavailableSongs(playlistId, view.missing);

      final List<Song> remaining =
          await PlaylistDatabase.getSongs(playlistId);
      expect(_ids(remaining), <String>['media-1', 'velho-9'],
          reason: 'só a fantasma sai; as outras linhas seguem');

      final PlaylistSongsView again = await provider.songsOf(playlistId);
      expect(again.missing, isEmpty, reason: 'reabriu: nada fantasma');
      expect(_ids(again.songs), <String>['media-1', 'novo-7']);
    });
  });
}
