// Testes do item 2.3: normalização de texto para comparação — busca,
// ordenação e agrupamento da biblioteca sem depender de acento/caixa,
// com ordem natural ("Faixa 2" antes de "Faixa 10").
//
// Metade é unitário puro (lib/utils/text_normalize.dart); a outra
// metade roda no PlayerProvider com repositórios falsos e um
// AudioService simulado (test/support/playable_audio_service.dart).

import 'package:flutter_test/flutter_test.dart';

import 'package:audify/models/song_model.dart';
import 'package:audify/providers/player_provider.dart';
import 'package:audify/repositories/session_repository.dart';
import 'package:audify/repositories/song_repository.dart';
import 'package:audify/utils/text_normalize.dart';

import 'support/playable_audio_service.dart';

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

Song _song({
  required String id,
  required String title,
  String? album,
  String? artist,
}) =>
    // fromStored devolve null só com song_id vazio — id sempre válido.
    Song.fromStored(<String, Object?>{
      'song_id': id,
      'title': title,
      'album': album,
      'artist': artist,
      'file_path': '/fake/$id.mp3',
      'is_asset': 0,
    })!;

/// Catálogo bagunçado de propósito: acentos, caixa mista e números com
/// dígitos de tamanhos diferentes.
List<Song> _catalog() => [
      _song(id: 'a1', title: 'Zebra Blues', album: 'Outro', artist: 'Zeca'),
      _song(id: 'a2', title: 'Faixa 10', album: 'Álbum 10', artist: 'Yara'),
      _song(id: 'a3', title: 'Faixa 2', album: 'Álbum 2', artist: 'Xena'),
      _song(
        id: 'a4',
        title: 'Ação ao Vivo',
        album: 'Ao Vivo',
        artist: 'Ângela',
      ),
      _song(
        id: 'a5',
        title: 'Árvore de Natal',
        album: 'Álbum 10',
        artist: 'Bruno',
      ),
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(mockAudioplayersChannels);

  group('stripDiacritics', () {
    test('remove diacríticos comuns de pt-BR/ES/FR preservando caixa', () {
      expect(stripDiacritics('Ação'), 'Acao');
      expect(stripDiacritics('ação'), 'acao');
      expect(stripDiacritics('Señor'), 'Senor');
      expect(stripDiacritics('cœur'), 'coeur');
      expect(stripDiacritics('Papier-mâché'), 'Papier-mache');
      expect(stripDiacritics('ÀÉÎÕÜ'), 'AEIOU');
      expect(stripDiacritics(''), '');
    });

    test('o que não é diacrítico passa intacto', () {
      expect(stripDiacritics('Faixa 2 — #1! (ok)'), 'Faixa 2 — #1! (ok)');
      expect(stripDiacritics('Árvore 🌳'), 'Arvore 🌳');
      expect(stripDiacritics('banana'), 'banana');
    });
  });

  group('normalizeKey', () {
    test('minúsculas sem acento: as três grafias viram a mesma chave', () {
      expect(normalizeKey('AÇÃO'), 'acao');
      expect(normalizeKey('Ação'), 'acao');
      expect(normalizeKey('acao'), 'acao');
    });
  });

  group('naturalCompare', () {
    test('ordem natural: Faixa 2 antes de Faixa 10 antes de Faixa 100', () {
      expect(naturalCompare('Faixa 2', 'Faixa 10'), lessThan(0));
      expect(naturalCompare('Faixa 10', 'Faixa 2'), greaterThan(0));
      expect(naturalCompare('Faixa 10', 'Faixa 100'), lessThan(0));
      expect(naturalCompare('Faixa 2', 'Faixa 2'), 0);
    });

    test('acento e caixa não decidem ordem nem igualdade', () {
      expect(naturalCompare('Árvore', 'Zebra'), lessThan(0));
      expect(naturalCompare('Ação', 'acao'), 0);
      expect(naturalCompare('AÇÃO', 'acao'), 0);
      expect(naturalCompare('acao', 'bananas'), lessThan(0));
    });

    test('zeros à esquerda empatam; prefixo curto vem antes', () {
      expect(naturalCompare('Faixa 02', 'Faixa 2'), 0);
      expect(naturalCompare('Faixa 0007', 'Faixa 7'), 0);
      expect(naturalCompare('Faixa', 'Faixa 1'), lessThan(0));
    });

    test('símbolos no meio continuam valendo', () {
      expect(naturalCompare('Faixa (2)', 'Faixa (10)'), lessThan(0));
      expect(naturalCompare('01 - Faixa', '1 - Faixa'), 0);
    });

    test('número gigante não estoura int (sem parse)', () {
      expect(
        naturalCompare('Faixa 999999999999999999999999', 'Faixa 1'),
        greaterThan(0),
      );
      expect(
        naturalCompare(
          'Faixa 1000000000000000000000000',
          'Faixa 999999999999999999999999',
        ),
        greaterThan(0),
      );
    });
  });

  group('PlayerProvider: ordenação/busca/agrupamento normalizados (2.3)', () {
    late PlayerProvider provider;

    setUp(() async {
      provider = PlayerProvider(
        PlayableAudioService(),
        songRepository: _FakeSongRepository(_catalog()),
        sessionRepository: _FakeSessionRepository(),
      );
      await provider.init();
    });

    tearDown(() => provider.dispose());

    test('catálogo ordena natural e sem acento', () {
      expect(provider.songs.map((s) => s.title).toList(), <String>[
        'Ação ao Vivo', // 'acao...' antes de 'arvore...' e de 'zebra...'
        'Árvore de Natal',
        'Faixa 2', // natural: 2 < 10 (lexicográfico faria 10 < 2)
        'Faixa 10',
        'Zebra Blues', // 'zebra' > 'arvore' — antes vinha primeiro
      ]);
    });

    test('buscar sem acento acha título e álbum acentuados', () {
      provider.setSearchQuery('acao');
      expect(provider.visibleSongs.map((s) => s.title).toList(), <String>[
        'Ação ao Vivo',
      ]);

      provider.setSearchQuery('arvore');
      expect(provider.visibleSongs.map((s) => s.title).toList(), <String>[
        'Árvore de Natal',
      ]);

      // acentado também encontra (normalização nos dois lados)
      provider.setSearchQuery('Ação');
      expect(provider.visibleSongs.map((s) => s.title).toList(), <String>[
        'Ação ao Vivo',
      ]);

      // busca no ARTISTA acentuado: 'angela' acha 'Ângela'
      provider.setSearchQuery('angela');
      expect(provider.visibleSongs.map((s) => s.id).toList(), <String>['a4']);
    });

    test('chaves de grupo ordenadas natural e sem acento', () {
      final List<String> keys =
          provider.visibleGroups(MusicGroupMode.album).map((g) => g.key).toList();
      expect(keys, <String>[
        'Álbum 2', // 'album 2' antes de 'album 10' (ordem natural)
        'Álbum 10',
        'Ao Vivo',
        'Outro',
      ]);
    });
  });
}
