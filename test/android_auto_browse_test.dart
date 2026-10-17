// Item 6.5 — browse do Android Auto / Bluetooth (MediaBrowserService).
//
// O que se testa em host: o contrato de getChildren (raiz → categorias →
// faixas, ids estáveis, raiz "recent" do Auto) e a resolução de
// playFromMediaId. O QUE NÃO SE TESTA AQUI: o toque real a partir do
// head unit e a UI do Android Auto — isso só em veículo/aparelho
// (o plugin de áudio não existe em host e a tela do Auto é do sistema).

import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter_test/flutter_test.dart';

import 'package:audify/models/song_model.dart';
import 'package:audify/providers/player_provider.dart';
import 'package:audify/repositories/session_repository.dart';
import 'package:audify/repositories/song_repository.dart';
import 'package:audify/services/audio_service.dart';

import 'support/playable_audio_service.dart';

Song _song({
  required String id,
  required String title,
  String? album,
  String? artist,
  String? filePath,
}) => Song.fromStored(<String, Object?>{
  'song_id': id,
  'title': title,
  'album': album,
  'artist': artist,
  'file_path': filePath ?? '/data/music/$id.mp3',
  'is_asset': 0,
})!;

class _FakeSongRepository extends SongRepository {
  _FakeSongRepository(this.assets);

  final List<Song> assets;

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AudioService svc;

  setUp(() {
    svc = AudioService();
  });

  tearDown(() async {
    await svc.dispose();
  });

  List<Song> catalog() => <Song>[
    _song(id: 'a1', title: 'Alfa', album: 'Um', artist: 'Zed'),
    _song(id: 'b2', title: 'Beta', album: 'Dois', artist: 'Yara'),
    _song(id: 'c3', title: 'Gama', album: 'Três', artist: 'Xico'),
  ];

  void withSources({
    required List<Song> all,
    List<Song> favorites = const <Song>[],
    List<Song> recent = const <Song>[],
  }) {
    svc.onBrowseAllSongs = () => all;
    svc.onBrowseFavorites = () => favorites;
    svc.onBrowseRecent = () => recent;
  }

  group('getChildren (6.5)', () {
    test('raiz expõe as 3 categorias, não tocáveis', () async {
      final List<MediaItem> root = await svc.getChildren(
        AudioService.browseRootId,
      );
      expect(root, hasLength(3));
      expect(root[0].id, AudioService.browseAllId);
      expect(root[0].title, 'Todas as faixas');
      expect(root[1].id, AudioService.browseFavoritesId);
      expect(root[1].title, 'Favoritas');
      expect(root[2].id, AudioService.browseRecentId);
      expect(root[2].title, 'Tocadas recentemente');
      for (final MediaItem item in root) {
        expect(item.playable, isFalse);
      }
    });

    test('sem fontes injetadas as categorias ficam vazias', () async {
      expect(await svc.getChildren(AudioService.browseAllId), isEmpty);
      expect(await svc.getChildren(AudioService.browseFavoritesId), isEmpty);
      expect(await svc.getChildren('cat:qualquer'), isEmpty);
      expect(await svc.getChildren('id-inexistente'), isEmpty);
    });

    test('categoria lista faixas com id song:<id> e metadados', () async {
      final List<Song> all = catalog();
      withSources(all: all, favorites: <Song>[all[1]], recent: <Song>[all[2]]);

      final List<MediaItem> items = await svc.getChildren(
        AudioService.browseAllId,
      );
      expect(items, hasLength(3));
      expect(items[0].id, 'song:a1');
      expect(items[0].title, 'Alfa');
      expect(items[0].artist, 'Zed');
      expect(items[0].album, 'Um');
      expect(items[0].playable, isTrue);

      expect(
        (await svc.getChildren(AudioService.browseFavoritesId))
            .map((MediaItem m) => m.id),
        <String>['song:b2'],
      );
      expect(
        (await svc.getChildren(AudioService.browseRecentId))
            .map((MediaItem m) => m.id),
        <String>['song:c3'],
      );
      // A raiz "recent" que o Android Auto pede (EXTRA_RECENT) usa a
      // mesma fonte da categoria.
      expect(
        (await svc.getChildren(AudioService.browseRecentRootId))
            .map((MediaItem m) => m.id),
        <String>['song:c3'],
      );
    });
  });

  group('playFromMediaId / resolveBrowseSong (6.5)', () {
    test('resolve song:<id> na fonte e devolve null fora dela', () {
      final List<Song> all = catalog();
      withSources(all: all);

      expect(svc.resolveBrowseSong('song:a1')?.title, 'Alfa');
      expect(svc.resolveBrowseSong('song:nao-existe'), isNull);
      expect(svc.resolveBrowseSong('sem-prefixo'), isNull);
      expect(svc.resolveBrowseSong('song:'), isNull);
    });

    test('sem fonte nenhuma nunca lança', () {
      expect(svc.resolveBrowseSong('song:a1'), isNull);
    });

    test('playFromMediaId com id desconhecido é no-op (não lança)', () async {
      withSources(all: catalog());
      // O toque real (playSong → just_audio) NÃO é exercitado aqui: o
      // plugin não existe em host. O caminho de id inválido — que é o
      // que o Auto dispara quando a fila sobrevive a uma recarga — tem
      // que ser silencioso, sem exceção no canal nativo.
      await svc.playFromMediaId('song:sumiu');
      await svc.playFromMediaId('lixo');
    });
  });

  group('wiring do PlayerProvider (6.5)', () {
    late PlayableAudioService audio;
    late PlayerProvider provider;

    Future<void> bootProvider(List<Song> catalog) async {
      // O provider injeta os callbacks no serviço QUE ELE MESMO usa —
      // por isso as asserções falam com esta instância e não com a
      // `svc` do setUp.
      audio = PlayableAudioService();
      provider = PlayerProvider(
        audio,
        songRepository: _FakeSongRepository(catalog),
        sessionRepository: _FakeSessionRepository(),
      );
      addTearDown(provider.dispose);
      await provider.init();
    }

    test('root e cat:all enxergam o catálogo do provider', () async {
      await bootProvider(catalog());

      final List<MediaItem> root = await audio.getChildren(
        AudioService.browseRootId,
      );
      expect(root, hasLength(3));

      final List<MediaItem> items = await audio.getChildren(
        AudioService.browseAllId,
      );
      expect(items, hasLength(3));
      expect(items.first.title, 'Alfa');
      expect(items.last.id, 'song:c3');
    });

    test(
      'favoritas vazias e recent sem histórico devolvem lista vazia',
      () async {
        await bootProvider(catalog());
        expect(
          await audio.getChildren(AudioService.browseFavoritesId),
          isEmpty,
        );
        expect(await audio.getChildren(AudioService.browseRecentId), isEmpty);
      },
    );
  });
}
