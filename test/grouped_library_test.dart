// Testes do item 2.2: modo agrupado memoizado + renderização lazy.
//
// Antes: music_screen agrupava e ordenava (O(n log n)) A CADA build e
// renderizava com ListView(children: sections) — todos os tiles
// construídos de uma vez (5.000 faixas = milhares de widgets novos por
// rebuild). Agora:
//  - agrupamento memoizado no PlayerProvider.visibleGroups (recalcula
//    só quando muda a identidade da lista visível — catálogo/busca —
//    ou o modo);
//  - tela achata em linhas (cabeçalho + faixas expandidas) e renderiza
//    com ListView.builder: a árvore só materializa a viewport.
//
// "Comportamento igual" coberto aqui: chaves ordenadas, conteúdo na
// ordem do catálogo, colapsar/expandir, "tocar todas" (grupo vira
// fila) e tocar uma faixa do grupo com navegação interna.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:audify/models/song_model.dart';
import 'package:audify/providers/player_provider.dart';
import 'package:audify/repositories/session_repository.dart';
import 'package:audify/repositories/song_repository.dart';
import 'package:audify/screens/music_screen.dart';
import 'package:audify/widgets/song_list_tile.dart';

import 'support/playable_audio_service.dart';

Song _song({
  required String id,
  required String title,
  String? album,
  String? artist,
  String? filePath,
}) =>
    // fromStored devolve null só com song_id vazio — o helper sempre
    // passa id válido.
    Song.fromStored(<String, Object?>{
      'song_id': id,
      'title': title,
      'album': album,
      'artist': artist,
      'file_path': filePath,
      'is_asset': 0,
    })!;

/// 5.000 faixas em 100 álbuns ('Álbum 00'..'Álbum 99'), títulos
/// 'Faixa 0000'..'Faixa 4999' (ordenação lexicográfica = numérica).
List<Song> _manySongs(int total) => <Song>[
  for (int i = 0; i < total; i++)
    _song(
      id: 'm$i',
      title: 'Faixa ${i.toString().padLeft(4, '0')}',
      album: 'Álbum ${(i % 100).toString().padLeft(2, '0')}',
      artist: 'Artista ${(i % 7)}',
    ),
];

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

PlayerProvider _provider(
  PlayableAudioService svc,
  List<Song> catalog, {
  int catalogComputeThreshold = PlayerProvider.defaultCatalogComputeThreshold,
}) => PlayerProvider(
  svc,
  songRepository: _FakeSongRepository(catalog),
  sessionRepository: _FakeSessionRepository(),
  catalogComputeThreshold: catalogComputeThreshold,
);

List<Song> _smallCatalog() => <Song>[
  _song(id: 's1', title: 'Faixa Um', album: 'Zeta', artist: 'Boa'),
  _song(id: 's2', title: 'Faixa Dois', album: 'Alfa', artist: 'Avela'),
  _song(id: 's3', title: 'Faixa Três', album: 'Zeta', artist: 'Boa'),
  _song(id: 's4', title: 'Faixa Quatro', album: 'Alfa', artist: 'Avela'),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('visibleGroups: agrupamento correto (2.2)', () {
    late PlayerProvider provider;

    setUp(() async {
      provider = _provider(PlayableAudioService(), _smallCatalog());
      await provider.init();
    });

    tearDown(() => provider.dispose());

    test('chaves ordenadas e conteúdo na ordem do catálogo (álbum)', () {
      final List<SongGroup> byAlbum = provider.visibleGroups(
        MusicGroupMode.album,
      );
      expect(byAlbum.map((SongGroup g) => g.key).toList(), <String>[
        'Alfa',
        'Zeta',
      ]);
      // Dentro do grupo, a ordem é a do catálogo (ordenado por título:
      // Faixa Dois, Quatro, Três, Um).
      expect(byAlbum[0].songs.map((Song s) => s.id), <String>['s2', 's4']);
      expect(byAlbum[1].songs.map((Song s) => s.id), <String>['s3', 's1']);
    });

    test('modo artista e pasta têm as mesmas chaves do código antigo', () {
      final List<SongGroup> byArtist = provider.visibleGroups(
        MusicGroupMode.artist,
      );
      expect(byArtist.map((SongGroup g) => g.key).toList(), <String>[
        'Avela',
        'Boa',
      ]);

      final List<SongGroup> byFolder = provider.visibleGroups(
        MusicGroupMode.folder,
      );
      expect(byFolder.single.key, 'Assets do app');
      expect(byFolder.single.songs, hasLength(4));
    });

    test('memo: mesma instância; invalida só em modo, busca ou catálogo', () {
      final List<SongGroup> first = provider.visibleGroups(
        MusicGroupMode.album,
      );
      expect(
        provider.visibleGroups(MusicGroupMode.album),
        same(first),
        reason: 'mesmo modo + mesmos dados = memo hit (sem recálculo)',
      );
      expect(
        provider.visibleGroups(MusicGroupMode.artist),
        isNot(same(first)),
        reason: 'modo diferente invalida',
      );

      provider.setSearchQuery('Zeta');
      final List<SongGroup> filtered = provider.visibleGroups(
        MusicGroupMode.album,
      );
      expect(filtered, isNot(same(first)), reason: 'busca invalida');
      expect(filtered.map((SongGroup g) => g.key).toList(), <String>['Zeta']);
      expect(filtered.single.songs.map((Song s) => s.id), <String>['s3', 's1']);

      provider.setSearchQuery('');
      expect(
        provider
            .visibleGroups(MusicGroupMode.album)
            .map((SongGroup g) => g.key),
        <String>['Alfa', 'Zeta'],
      );
    });
  });

  testWidgets(
    'modo agrupado com 5.000 faixas: lazy, colapsar e grupo como fila',
    (tester) async {
      final PlayableAudioService svc = PlayableAudioService();
      // Limite do compute elevado (item 2.4): sob FakeAsync o isolate
      // não responde e o init travaria — aqui o que importa é o
      // agrupamento/lazy, não o caminho do isolate (ele é coberto no
      // teste de abertura do snapshot, em zona real).
      final PlayerProvider provider = _provider(
        svc,
        _manySongs(5000),
        catalogComputeThreshold: 100000,
      );
      addTearDown(provider.dispose);
      await provider.init();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChangeNotifierProvider<PlayerProvider>.value(
              value: provider,
              child: const MusicScreen(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Muda para o modo agrupado (chip 'Álbum').
      final Stopwatch sw = Stopwatch()..start();
      await tester.tap(find.widgetWithText(ChoiceChip, 'Álbum'));
      await tester.pumpAndSettle();
      sw.stop();

      expect(find.text('Álbum 00'), findsOneWidget);
      final int builtInitially = find.byType(SongListTile).evaluate().length;
      expect(builtInitially, greaterThan(0));
      expect(
        builtInitially,
        lessThan(100),
        reason:
            'ListView.builder só constrói a viewport — o '
            'ListView(children:) antigo materializava ~5.000+ tiles',
      );
      expect(sw.elapsedMilliseconds, lessThan(5000));
      debugPrint(
        '[2.2] agrupar 5.000 faixas: ${sw.elapsedMilliseconds}ms, '
        '$builtInitially tiles na árvore',
      );

      // Colapsar esconde as faixas do grupo; expandir traz de volta.
      await tester.tap(find.byTooltip('Recolher').first);
      await tester.pumpAndSettle();
      final int collapsedTiles = find.byType(SongListTile).evaluate().length;
      expect(collapsedTiles, lessThan(builtInitially));
      expect(find.byTooltip('Expandir'), findsWidgets);
      await tester.tap(find.byTooltip('Expandir').first);
      await tester.pumpAndSettle();
      expect(
        find.byType(SongListTile).evaluate().length,
        greaterThan(collapsedTiles),
      );

      // 'Tocar grupo' (cabeçalho) toca a primeira do grupo como fila.
      await tester.tap(find.byTooltip('Tocar grupo').first);
      await tester.pumpAndSettle();
      expect(provider.currentSong?.id, 'm0', reason: 'Álbum 00 / Faixa 0000');

      // Tocar a 2ª faixa do grupo: o GRUPO vira a fila — a próxima é a
      // vizinha do grupo (m100 -> m200), não a do catálogo geral.
      await tester.tap(find.byType(SongListTile).at(1));
      await tester.pumpAndSettle();
      expect(provider.currentSong?.id, 'm100');
      await provider.next();
      expect(
        provider.currentSong?.id,
        'm200',
        reason: 'navegação interna: o grupo é a fila',
      );

      // Rolar constrói outras linhas — e segue lazy.
      await tester.drag(find.byType(ListView).last, const Offset(0, -2000));
      await tester.pumpAndSettle();
      expect(
        find.byType(SongListTile).evaluate().length,
        lessThan(200),
        reason: 'mesmo após rolar, só viewport + cache estão na árvore',
      );

      await tester.pumpWidget(const SizedBox());
    },
  );
}
