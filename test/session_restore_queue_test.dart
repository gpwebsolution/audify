// Testes do item 1.6: a retomada de sessão restaura a FILA ATIVA
// (ids + índice), não o catálogo inteiro.
//
// Usa repositórios falsos + AudioService simulado que "toca" sem
// erro (test/support/playable_audio_service.dart) — mesma receita
// de player_queue_search_test.dart.
//
// OBS: o provider ORDENA o catálogo por título (apple, banana,
// cherry, mango, pear).

import 'package:flutter_test/flutter_test.dart';

import 'package:audify/models/song_model.dart';
import 'package:audify/providers/player_provider.dart';
import 'package:audify/providers/settings_provider.dart';
import 'package:audify/repositories/session_repository.dart';
import 'package:audify/repositories/song_repository.dart';

import 'support/playable_audio_service.dart';

class _FakeSongRepository extends SongRepository {
  final List<Song> assets;
  _FakeSongRepository(this.assets);

  @override
  Future<List<Song>> loadDeviceSongs() async => const [];

  @override
  Future<List<Song>> loadAssetSongs() async => assets;
}

/// SessionRepository controlável: devolve a sessão/fila gravadas em
/// memória (sem SharedPreferences) para simular "o app reabriu".
class _FakeSessionRepository extends SessionRepository {
  _FakeSessionRepository({this.savedSong, this.position = Duration.zero});

  Song? savedSong;
  Duration position;
  List<String> queueIds = const [];
  int queueIndex = -1;

  @override
  Future<void> save(Song song, Duration position) async {
    savedSong = song;
    this.position = position;
  }

  @override
  Future<void> saveQueue(List<String> ids, int index) async {
    queueIds = ids;
    queueIndex = index;
  }

  @override
  Future<void> clear() async {
    savedSong = null;
    queueIds = const [];
    queueIndex = -1;
  }

  @override
  Future<(Song?, Duration)> load() async => (savedSong, position);

  @override
  Future<(List<String>, int)> loadQueue() async => (queueIds, queueIndex);
}

Song _track(String name) => Song.fromAsset(assetPath: 'assets/songs/$name.mp3');

List<Song> _fiveTracks() => [
      _track('apple'),
      _track('banana'),
      _track('cherry'),
      _track('mango'),
      _track('pear'),
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(mockAudioplayersChannels);

  /// Cria o provider já com a sessão "gravada" (como se viesse do disco).
  Future<PlayerProvider> restoredProvider({
    required Song? savedSong,
    Duration position = Duration.zero,
    List<String> queueIds = const [],
    int queueIndex = -1,
    List<Song>? catalog,
  }) async {
    final _FakeSessionRepository session = _FakeSessionRepository(
      savedSong: savedSong,
      position: position,
    )
      ..queueIds = queueIds
      ..queueIndex = queueIndex;
    final SettingsProvider settings = SettingsProvider();
    await settings.load();

    final PlayerProvider provider = PlayerProvider(
      PlayableAudioService(),
      settings: settings,
      songRepository: _FakeSongRepository(catalog ?? _fiveTracks()),
      sessionRepository: session,
    );
    addTearDown(provider.dispose);
    await provider.init();
    return provider;
  }

  test('restaura a fila ativa (ordem salva), não o catálogo', () async {
    // Sessão anterior: fila era cherry -> apple -> mango (ex.: ordem
    // embaralhada ou de uma playlist), parada na apple.
    final PlayerProvider provider = await restoredProvider(
      savedSong: _track('apple'),
      position: const Duration(seconds: 12),
      queueIds: ['assets/songs/cherry.mp3', 'assets/songs/apple.mp3',
          'assets/songs/mango.mp3'],
      queueIndex: 1,
    );

    expect(provider.currentSong!.title, 'Apple');
    expect(provider.position, const Duration(seconds: 12));

    // A fila É a salva (3 faixas), não as 5 do catálogo.
    expect(provider.hasNext, isTrue);
    await provider.next();
    expect(provider.currentSong!.title, 'Mango');

    // Fim da fila salva (repeat off): para em Mango — não segue
    // para Banana/Pear do catálogo.
    await provider.next();
    expect(provider.currentSong!.title, 'Mango');
  });

  test('id que sumiu do catálogo é descartado só ele', () async {
    final PlayerProvider provider = await restoredProvider(
      savedSong: _track('banana'),
      // 'assets/songs/zzz.mp3' não existe mais no catálogo.
      queueIds: [
        'assets/songs/apple.mp3',
        'assets/songs/zzz.mp3',
        'assets/songs/banana.mp3',
        'assets/songs/pear.mp3',
      ],
      queueIndex: 2,
    );

    expect(provider.currentSong!.title, 'Banana');
    await provider.next();
    expect(provider.currentSong!.title, 'Pear');
  });

  test('faixa corrente fora da fila salva volta ao catálogo (fallback)',
      () async {
    final PlayerProvider provider = await restoredProvider(
      savedSong: _track('mango'),
      queueIds: ['assets/songs/apple.mp3'], // mango ficou de fora
      queueIndex: 0,
    );

    expect(provider.currentSong!.title, 'Mango');
    // Fallback: fila = catálogo, então a próxima é Pear (ordem alfabética).
    await provider.next();
    expect(provider.currentSong!.title, 'Pear');
  });

  test('sessão antiga (sem fila salva) mantém fila = catálogo', () async {
    final PlayerProvider provider = await restoredProvider(
      savedSong: _track('cherry'),
      queueIds: const [],
      queueIndex: -1,
    );

    expect(provider.currentSong!.title, 'Cherry');
    await provider.next();
    expect(provider.currentSong!.title, 'Mango');
  });

  test('faixa salva que não existe mais não retoma nada', () async {
    final PlayerProvider provider = await restoredProvider(
      savedSong: _track('banana'),
      queueIds: const [],
      catalog: [_track('apple'), _track('pear')], // banana sumiu
    );

    expect(provider.currentSong, isNull);
    expect(provider.hasNext, isFalse);
  });
}
