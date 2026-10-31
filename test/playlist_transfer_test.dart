// Testes do item 4.5 — exportar/importar playlists e duplicar.
//
// Duas camadas:
//  - PlaylistTransferService (puro): ida-e-volta JSON e .m3u8 +
//    casamento por filePath e, na falta, por título+artista
//    normalizados (caixa e acento não atrapalham);
//  - PlaylistProvider: importa com nome LIVRE e devolve o relatório
//    "X importadas, Y não encontradas"; duplicar copia faixas e
//    vídeos com "(cópia)" sem colidir.
//
// Os dois usam duplo de PlaylistRepository — nenhum teste toca sqflite.

import 'package:flutter_test/flutter_test.dart';

import 'package:audify/models/song_model.dart';
import 'package:audify/models/video_model.dart';
import 'package:audify/providers/player_provider.dart';
import 'package:audify/providers/playlist_provider.dart';
import 'package:audify/repositories/playlist_repository.dart';
import 'package:audify/services/playlist_transfer_service.dart';

import 'support/playable_audio_service.dart';

Song _song(
  String id,
  String title, {
  String? artist,
  String? album,
  String? filePath,
  int? durationMs,
}) => Song.fromStored(<String, Object?>{
  'song_id': id,
  'title': title,
  'artist': artist,
  'album': album,
  'file_path': filePath,
  'duration_ms': durationMs,
  'is_asset': 0,
})!;

PlaylistTransferEntry _entry(
  String title, {
  String? artist,
  String? filePath,
  int? durationMs,
}) => PlaylistTransferEntry(
  title: title,
  artist: artist,
  filePath: filePath,
  durationMs: durationMs,
);

class _FakePlaylistRepository extends PlaylistRepository {
  final Map<int, String> names = <int, String>{};
  final Map<int, List<Song>> songsById = <int, List<Song>>{};
  final Map<int, List<Video>> videosById = <int, List<Video>>{};
  int _nextId = 1;

  int seed(
    String name, {
    List<Song> songs = const [],
    List<Video> videos = const [],
  }) {
    final int id = _nextId++;
    names[id] = name;
    songsById[id] = List<Song>.of(songs);
    videosById[id] = List<Video>.of(videos);
    return id;
  }

  List<Song> songsOf(int playlistId) => songsById[playlistId] ?? const [];
  List<Video> videosOf(int playlistId) => videosById[playlistId] ?? const [];

  @override
  Future<List<Map<String, Object?>>> getPlaylists() async =>
      <Map<String, Object?>>[
        for (final MapEntry<int, String> entry in names.entries)
          <String, Object?>{
            'id': entry.key,
            'name': entry.value,
            'song_count': songsById[entry.key]?.length ?? 0,
            'video_count': videosById[entry.key]?.length ?? 0,
          },
      ];

  @override
  Future<void> createPlaylist(String name) async {
    if (names.containsValue(name)) {
      throw Exception('UNIQUE constraint failed: playlists.name');
    }
    final int id = _nextId++;
    names[id] = name;
    songsById[id] = <Song>[];
    videosById[id] = <Video>[];
  }

  @override
  Future<List<Song>> getSongs(int playlistId) async =>
      List<Song>.of(songsOf(playlistId));

  @override
  Future<List<Video>> getVideos(int playlistId) async =>
      List<Video>.of(videosOf(playlistId));

  @override
  Future<int> addSongs(int playlistId, List<Song> songs) async {
    songsById.putIfAbsent(playlistId, () => <Song>[]).addAll(songs);
    return songs.length;
  }

  @override
  Future<int> addVideos(int playlistId, List<Video> videos) async {
    videosById.putIfAbsent(playlistId, () => <Video>[]).addAll(videos);
    return videos.length;
  }
}

PlaylistProvider _provider(_FakePlaylistRepository repo) {
  final PlayerProvider player = PlayerProvider(PlayableAudioService());
  addTearDown(player.dispose);
  final PlaylistProvider provider = PlaylistProvider(player, repository: repo);
  addTearDown(provider.dispose);
  return provider;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('transferência — ida-e-volta (4.5)', () {
    test('JSON preserva todos os campos, inclusive nulos', () {
      final List<PlaylistTransferEntry> entries = <PlaylistTransferEntry>[
        _entry(
          'Ação',
          artist: 'João',
          filePath: '/music/acao.mp3',
          durationMs: 12345,
        ),
        _entry('Sem Metadados'),
      ];
      final PlaylistTransferFile back = decodePlaylistJson(
        encodePlaylistJson('Trilha', entries),
      );

      expect(back.name, 'Trilha');
      expect(back.entries, hasLength(2));
      expect(back.entries[0].title, 'Ação');
      expect(back.entries[0].artist, 'João');
      expect(back.entries[0].filePath, '/music/acao.mp3');
      expect(back.entries[0].durationMs, 12345);
      expect(back.entries[1].title, 'Sem Metadados');
      expect(back.entries[1].artist, isNull);
      expect(back.entries[1].filePath, isNull);
      expect(back.entries[1].durationMs, isNull);
    });

    test('JSON inválido (sem name, sem título) é FormatException', () {
      expect(() => decodePlaylistJson('{"songs": []}'), throwsFormatException);
      expect(
        () => decodePlaylistJson('{"name": "X", "songs": [{"artist": "A"}]}'),
        throwsFormatException,
      );
      expect(() => decodePlaylistJson('não é json'), throwsFormatException);
    });

    test('m3u8 preserva artista, título e caminho; pula faixa sem path', () {
      final List<PlaylistTransferEntry> entries = <PlaylistTransferEntry>[
        _entry(
          'Tema',
          artist: 'Banda',
          filePath: '/m/tema.mp3',
          durationMs: 90_000,
        ),
        _entry('Sem Caminho', artist: 'X', durationMs: 1000),
      ];
      final String m3u8 = encodePlaylistM3u8(entries);
      expect(m3u8, contains('#EXTINF:90,Banda - Tema'));
      expect(m3u8, contains('/m/tema.mp3'));
      expect(m3u8, isNot(contains('Sem Caminho')));

      final PlaylistTransferFile back = decodePlaylistM3u8(
        m3u8,
        name: 'Trilha',
      );
      expect(back.name, 'Trilha');
      expect(back.entries, hasLength(1));
      expect(back.entries.single.title, 'Tema');
      expect(back.entries.single.artist, 'Banda');
      expect(back.entries.single.filePath, '/m/tema.mp3');
      expect(back.entries.single.durationMs, 90_000);
    });

    test(
      'm3u8: título com " - " não vira artista (parte na 1ª ocorrência)',
      () {
        final PlaylistTransferFile back = decodePlaylistM3u8(
          '#EXTM3U\n'
          '#EXTINF:10,AC DC - Highway - Ao Vivo\n'
          '/m/acdc.mp3\n',
        );
        expect(back.entries.single.artist, 'AC DC');
        expect(back.entries.single.title, 'Highway - Ao Vivo');
      },
    );

    test('m3u8 sem artista: o título sai inteiro', () {
      final PlaylistTransferFile back = decodePlaylistM3u8(
        '#EXTM3U\n#EXTINF:5,Intro\n/m/intro.mp3\n',
      );
      expect(back.entries.single.artist, isNull);
      expect(back.entries.single.title, 'Intro');
    });
  });

  group('transferência — casamento com o catálogo (4.5)', () {
    test('filePath vence: casa mesmo com título/artista inventados', () {
      final List<Song> catalog = <Song>[
        _song('1', 'Real', artist: 'Verdadeiro', filePath: '/a/real.mp3'),
      ];
      final ({List<Song> songs, int notFound}) result = matchPlaylistEntries(
        <PlaylistTransferEntry>[
          _entry('Inventado', artist: 'Outro', filePath: '/a/real.mp3'),
        ],
        catalog,
      );
      expect(result.songs.single.id, '1');
      expect(result.notFound, 0);
    });

    test('fallback título+artista: caixa e acento não atrapalham', () {
      final List<Song> catalog = <Song>[
        _song('1', 'Ação', artist: 'João Silva', filePath: '/novo/a.mp3'),
      ];
      // Caminho diferente (outro aparelho) — casa pelo texto normalizado.
      final ({List<Song> songs, int notFound}) result = matchPlaylistEntries(
        <PlaylistTransferEntry>[
          _entry('ACAO', artist: 'JOAO SILVA', filePath: '/antigo/a.mp3'),
        ],
        catalog,
      );
      expect(result.songs.single.id, '1');
      expect(result.notFound, 0);
    });

    test('artista divergente não casa nem pelo título igual', () {
      final List<Song> catalog = <Song>[_song('1', 'Tema', artist: 'Banda A')];
      final ({List<Song> songs, int notFound}) result = matchPlaylistEntries(
        <PlaylistTransferEntry>[_entry('Tema', artist: 'Banda B')],
        catalog,
      );
      expect(result.songs, isEmpty);
      expect(result.notFound, 1);
    });

    test('uma faixa atende uma entrada só (sem duplicar apontamento)', () {
      final List<Song> catalog = <Song>[_song('1', 'Tema', artist: 'Banda')];
      final ({List<Song> songs, int notFound}) result = matchPlaylistEntries(
        <PlaylistTransferEntry>[
          _entry('Tema', artist: 'Banda'),
          _entry('Tema', artist: 'Banda'),
        ],
        catalog,
      );
      expect(result.songs, hasLength(1));
      expect(result.notFound, 1);
    });
  });

  group('PlaylistProvider — importar/duplicar (4.5)', () {
    test('import: nome colidido vira " (2)" e o relatório é honesto', () async {
      final _FakePlaylistRepository repo = _FakePlaylistRepository()
        ..seed('Viagens');
      final PlaylistProvider provider = _provider(repo);
      await pumpEventQueue();

      final List<Song> catalog = <Song>[
        _song('1', 'Estrada', artist: 'Banda', filePath: '/m/estrada.mp3'),
        _song('2', 'Praia', artist: 'Sol', filePath: '/outro/praia.mp3'),
        _song('3', 'Só Aqui', artist: 'Ninguém', filePath: '/m/aqui.mp3'),
      ];
      final PlaylistTransferFile file = decodePlaylistJson(
        encodePlaylistJson('Viagens', <PlaylistTransferEntry>[
          _entry('Qualquer', artist: 'X', filePath: '/m/estrada.mp3'),
          _entry('PRAIA', artist: 'sol', filePath: '/m/nao_existe.mp3'),
          _entry('Fantasma', artist: 'Nada', filePath: '/m/404.mp3'),
        ]),
      );

      final PlaylistImportReport report = await provider.importPlaylist(
        file,
        catalog,
      );

      // 1 por filePath, 1 por título+artista; a terceira não achou nada.
      expect(report.imported, 2);
      expect(report.notFound, 1);
      expect(
        provider.playlists.map((Playlist p) => p.name),
        containsAll(<String>['Viagens', 'Viagens (2)']),
      );
      final int newId = provider.playlists
          .firstWhere((Playlist p) => p.name == 'Viagens (2)')
          .id;
      expect(repo.songsOf(newId).map((Song s) => s.id), <String>['1', '2']);
    });

    test('import sem nenhuma faixa encontrada não cria playlist', () async {
      final _FakePlaylistRepository repo = _FakePlaylistRepository()
        ..seed('Original');
      final PlaylistProvider provider = _provider(repo);
      await pumpEventQueue();

      final PlaylistImportReport report = await provider.importPlaylist(
        const PlaylistTransferFile(
          name: 'De Outro Mundo',
          entries: <PlaylistTransferEntry>[
            PlaylistTransferEntry(
              title: 'Nada',
              artist: 'Ninguém',
              filePath: '/fora/nada.mp3',
            ),
          ],
        ),
        <Song>[_song('1', 'Diferente', filePath: '/aqui.mp3')],
      );

      expect(report.imported, 0);
      expect(report.notFound, 1);
      expect(provider.playlists, hasLength(1)); // só a Original
    });

    test('duplicar copia faixas e vídeos com "(cópia)"', () async {
      final _FakePlaylistRepository repo = _FakePlaylistRepository();
      final int source = repo.seed(
        'Trilha',
        songs: <Song>[_song('1', 'A', filePath: '/a.mp3')],
        videos: <Video>[
          Video(
            id: 7,
            title: 'Clipe',
            displayName: 'clipe.mp4',
            duration: const Duration(minutes: 3),
            path: '/v/clipe.mp4',
            size: 10,
            dateAdded: 1,
          ),
        ],
      );
      final PlaylistProvider provider = _provider(repo);
      await pumpEventQueue();

      final String? name = await provider.duplicate(source);

      expect(name, 'Trilha (cópia)');
      final int copyId = provider.playlists
          .firstWhere((Playlist p) => p.name == 'Trilha (cópia)')
          .id;
      expect(repo.songsOf(copyId).map((Song s) => s.id), <String>['1']);
      expect(repo.videosOf(copyId).map((Video v) => v.id), <int>[7]);
      // A original não mudou.
      expect(repo.songsOf(source), hasLength(1));
      expect(repo.videosOf(source), hasLength(1));
    });

    test('duplicar de novo não colide o "(cópia)"', () async {
      final _FakePlaylistRepository repo = _FakePlaylistRepository()
        ..seed('Trilha');
      final PlaylistProvider provider = _provider(repo);
      await pumpEventQueue();

      final int source = provider.playlists.single.id;
      expect(await provider.duplicate(source), 'Trilha (cópia)');
      expect(await provider.duplicate(source), 'Trilha (cópia) (2)');
      expect(
        provider.playlists.map((Playlist p) => p.name),
        containsAll(<String>['Trilha', 'Trilha (cópia)', 'Trilha (cópia) (2)']),
      );
    });
  });
}
