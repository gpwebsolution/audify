// Testes do PlayerProvider: a busca NÃO altera a fila que está
// tocando (separação entre lista exibida e fila ativa).
//
// Usa repositórios falsos (SongRepository/SessionRepository são
// concretos, mas os métodos são sobrescrevíveis) e o AudioService
// real. Os canais do audioplayers são mockados para que o VM
// não dispare MissingPluginException — a reprodução "falha" por
// dentro (asset inexistente no bundle de teste), mas o estado
// do provider (faixa corrente/fila) é definido ANTES da chamada
// ao plugin, o que é o que estes testes verificam.
//
// OBS: o provider ORDENA o catálogo por título, então a ordem
// das faixas é alfabética (apple, banana, cherry, mango, pear).

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:audify/models/song_model.dart';
import 'package:audify/providers/player_provider.dart';
import 'package:audify/repositories/session_repository.dart';
import 'package:audify/repositories/song_repository.dart';
import 'package:audify/services/audio_service.dart';

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
  Future<void> clear() async {}

  @override
  Future<(Song?, Duration)> load() async => (null, Duration.zero);
}

Song _track(String name) =>
    Song.fromAsset(assetPath: 'assets/songs/$name.mp3');

List<Song> _fiveTracks() => [
      _track('apple'),
      _track('banana'),
      _track('cherry'),
      _track('mango'),
      _track('pear'),
    ];

PlayerProvider _provider() {
  return PlayerProvider(
    AudioService(),
    songRepository: _FakeSongRepository(_fiveTracks()),
    sessionRepository: _FakeSessionRepository(),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // Sem os canais do audioplayers no VM: evita
    // MissingPluginException (o app é tolerante a falhas
    // do plugin, mas o erro assíncrono falharia o teste).
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding
            .instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers.global'),
      (call) async => null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers'),
      (call) async => null,
    );
  });

  test('digitar na busca não altera a fila que está tocando',
      () async {
    final PlayerProvider provider = _provider();
    addTearDown(provider.dispose);

    await provider.init();
    expect(provider.visibleSongs.length, 5);

    // Toca Cherry (índice 2 na ordem alfabética).
    await provider.playVisibleAt(2);
    expect(provider.currentSong!.title, 'Cherry');

    // Filtra por "a": Apple, Banana, Mango e Pear ficam
    // visíveis; a faixa que TOCAVA (Cherry) sai da lista.
    provider.setSearchQuery('a');
    expect(provider.visibleSongs.length, 4);

    // A fila ativa NÃO foi reconstruída com a busca: próxima
    // é Mango (ordem original da fila), e NÃO Apple (primeira
    // da lista filtrada — comportamento antigo, que trocava
    // a fila a cada digitação).
    await provider.next();
    expect(provider.currentSong!.title, 'Mango');

    await provider.next();
    expect(provider.currentSong!.title, 'Pear');

    // Fim da fila (repeat off): não avança nem reinicia.
    await provider.next();
    expect(provider.currentSong!.title, 'Pear');
  });

  test('limpar a busca devolve a lista completa sem mexer '
      'na reprodução', () async {
    final PlayerProvider provider = _provider();
    addTearDown(provider.dispose);

    await provider.init();
    await provider.playVisibleAt(1); // Banana

    // "e": Apple, Cherry e Pear (Banana e Mango não têm "e").
    provider.setSearchQuery('e');
    expect(provider.visibleSongs.length, 3);
    await provider.next(); // Cherry (fila original)
    expect(provider.currentSong!.title, 'Cherry');

    provider.setSearchQuery('');
    expect(provider.visibleSongs.length, 5);
    // A reprodução continua na mesma faixa.
    expect(provider.currentSong!.title, 'Cherry');
  });

  test('busca ativa durante a reprodução: a faixa tocada '
      'não é interrompida', () async {
    final PlayerProvider provider = _provider();
    addTearDown(provider.dispose);

    await provider.init();
    await provider.playVisibleAt(0); // Apple

    // Digitação rápida (vários termos seguidos).
    provider.setSearchQuery('a');
    provider.setSearchQuery('ap');
    provider.setSearchQuery('app');
    provider.setSearchQuery('');

    // Nenhuma das digitações trocou a faixa nem a fila.
    expect(provider.currentSong!.title, 'Apple');
  });
}
