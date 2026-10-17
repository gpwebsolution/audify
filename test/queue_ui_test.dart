// Testes do item 3.5 — fila de reprodução com UI.
//
// Três camadas:
//  - PlayerProvider: queuePlayNext/queueAppend/queueMove/queueRemoveAt
//    publicam a fila e, com player ATIVO, recarregam o gapless (3.4)
//    preservando posição e estado; com player PARADO a edição só muda
//    a fila (o próximo play recarrega pelo caminho normal);
//  - PlayerScreen: folha "Fila" (abrir, tocar um item, remover sem
//    fechar);
//  - MusicScreen: "Tocar a seguir" e "Adicionar à fila" no menu da
//    faixa e na seleção em lote.
//
// O duplo PlayableAudioService publica mediaItem e registra o startAt
// como o serviço real — é o que permite asserir a posição preservada
// na recarga. O provider ORDENA o catálogo por título: Alpha, Beta,
// Gamma.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:audify/models/song_model.dart';
import 'package:audify/providers/player_provider.dart';
import 'package:audify/repositories/session_repository.dart';
import 'package:audify/repositories/song_repository.dart';
import 'package:audify/screens/music_screen.dart';
import 'package:audify/screens/player_screen.dart';
import 'package:audify/services/audio_service.dart';
import 'package:audify/widgets/song_list_tile.dart';

import 'support/playable_audio_service.dart';

Song _track(String name) => Song.fromAsset(assetPath: 'assets/songs/$name.mp3');

List<Song> _threeTracks() => <Song>[
      _track('alpha'),
      _track('beta'),
      _track('gamma'),
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

PlayerProvider _provider(PlayableAudioService svc) => PlayerProvider(
      svc,
      songRepository: _FakeSongRepository(_threeTracks()),
      sessionRepository: _FakeSessionRepository(),
    );

List<String> _titles(Iterable<Song> songs) =>
    <String>[for (final Song s in songs) s.title];

/// Botão ⋮ da faixa [title] — o tile corrente troca o ⋮ pelo ícone de
/// tocando (song_list_tile), então achar por índice fica frágil.
Finder _menuOf(String title) => find.descendant(
      of: find.ancestor(
        of: find.text(title),
        matching: find.byType(SongListTile),
      ),
      matching: find.byTooltip('Ações da faixa'),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PlayerProvider — edição da fila (3.5)', () {
    test('com player tocando, inserir recarrega a fila no player', () async {
      final PlayableAudioService audio = PlayableAudioService();
      final PlayerProvider provider = _provider(audio);
      addTearDown(provider.dispose);

      await provider.init();
      await provider.playVisibleAt(0); // Alpha
      expect(audio.played.length, 1);

      // Delta não está na fila: entra logo após a corrente.
      provider.queuePlayNext(<Song>[_track('delta')]);
      await pumpEventQueue();

      expect(_titles(provider.queue), <String>[
        'Alpha',
        'Delta',
        'Beta',
        'Gamma',
      ]);
      expect(provider.currentSong?.title, 'Alpha'); // não pulou
      // Recarga do gapless: playSong foi chamado de novo (fila nova).
      expect(audio.played.length, 2);
      expect(audio.played.last.title, 'Alpha');
      // Fila republicada no MediaSession (identidade mudou).
      expect(audio.queue.value, hasLength(4));
    });

    test('append de faixa já presente não faz nada (sem recarga)',
        () async {
      final PlayableAudioService audio = PlayableAudioService();
      final PlayerProvider provider = _provider(audio);
      addTearDown(provider.dispose);

      await provider.init();
      await provider.playVisibleAt(0);

      provider.queueAppend(<Song>[_track('beta')]); // já está na fila
      await pumpEventQueue();

      expect(provider.queue.length, 3);
      expect(audio.played.length, 1); // nada recarregou
    });

    test('nunca tocou: adicionar à fila começa a primeira reprodução',
        () async {
      final PlayableAudioService audio = PlayableAudioService();
      final PlayerProvider provider = _provider(audio);
      addTearDown(provider.dispose);

      await provider.init();
      expect(provider.currentSong, isNull);

      provider.queueAppend(<Song>[_track('beta')]);
      await pumpEventQueue();

      expect(_titles(provider.queue), <String>['Beta']);
      expect(provider.currentSong?.title, 'Beta');
      expect(_titles(audio.played), <String>['Beta']);
      expect(audio.status.value, PlayerStatus.playing);
    });

    test('remover a corrente: a sobrevivente toca do início', () async {
      final PlayableAudioService audio = PlayableAudioService();
      final PlayerProvider provider = _provider(audio);
      addTearDown(provider.dispose);

      await provider.init();
      await provider.playVisibleAt(0); // Alpha soa; mediaItem = Alpha

      provider.queueRemoveAt(0);
      await pumpEventQueue();

      expect(_titles(provider.queue), <String>['Beta', 'Gamma']);
      expect(provider.currentSong?.title, 'Beta');
      expect(audio.played.last.title, 'Beta');
      // A faixa que SOA mudou: começa do zero, não da posição antiga.
      expect(audio.lastStartAt, Duration.zero);
      expect(audio.mediaItem.value?.id, provider.currentSong?.id);
    });

    test('recarga preserva a posição quando a corrente continua a mesma',
        () async {
      final PlayableAudioService audio = PlayableAudioService();
      final PlayerProvider provider = _provider(audio);
      addTearDown(provider.dispose);

      await provider.init();
      await provider.playVisibleAt(0); // Alpha
      audio.position.value = const Duration(seconds: 42);

      provider.queueAppend(<Song>[_track('delta')]); // Alpha segue
      await pumpEventQueue();

      expect(provider.currentSong?.title, 'Alpha');
      // Alpha é a faixa que soa: a recarga reabre na MESMA posição.
      expect(audio.lastStartAt, const Duration(seconds: 42));
      expect(audio.played.length, 2);
      expect(audio.status.value, PlayerStatus.playing);
    });

    test('com player pausado, a edição volta a pausar (não vira play)',
        () async {
      final PlayableAudioService audio = PlayableAudioService();
      final PlayerProvider provider = _provider(audio);
      addTearDown(provider.dispose);

      await provider.init();
      await provider.playVisibleAt(0);
      await audio.pause();
      expect(audio.status.value, PlayerStatus.paused);

      provider.queueAppend(<Song>[_track('delta')]);
      await pumpEventQueue();

      // A recarga abre a fila nova e re-aplica o estado pausado.
      expect(audio.status.value, PlayerStatus.paused);
      expect(audio.played.length, 2);
      expect(provider.queue.length, 4);
    });

    test('reordenar com player tocando: muda a ordem, não a faixa',
        () async {
      final PlayableAudioService audio = PlayableAudioService();
      final PlayerProvider provider = _provider(audio);
      addTearDown(provider.dispose);

      await provider.init();
      await provider.playVisibleAt(0); // Alpha

      provider.queueMove(2, 0); // Gamma vai para o topo
      await pumpEventQueue();

      expect(_titles(provider.queue), <String>[
        'Gamma',
        'Alpha',
        'Beta',
      ]);
      expect(provider.currentSong?.title, 'Alpha');
      // Recarga reabre a MESMA faixa (posição preservada via mediaItem).
      expect(audio.played.last.title, 'Alpha');
      expect(audio.lastStartAt, Duration.zero); // posição era zero
    });

    test('com player parado, a edição só muda a fila (sem recarga)',
        () async {
      final PlayableAudioService audio = PlayableAudioService();
      final PlayerProvider provider = _provider(audio);
      addTearDown(provider.dispose);

      await provider.init();
      await provider.playVisibleAt(0);
      await audio.stop();
      expect(audio.status.value, PlayerStatus.idle);

      provider.queueRemoveAt(2); // Gamma, fora da corrente
      await pumpEventQueue();

      expect(_titles(provider.queue), <String>['Alpha', 'Beta']);
      // Parado: nenhuma chamada extra de playSong (o próximo play
      // recarrega pelo caminho normal do serviço).
      expect(audio.played.length, 1);
    });
  });

  group('PlayerScreen — folha "Fila" (3.5)', () {
    testWidgets('abre a folha, lista a fila e tocar um item troca a faixa',
        (WidgetTester tester) async {
      final PlayableAudioService audio = PlayableAudioService();
      final PlayerProvider provider = _provider(audio);
      addTearDown(provider.dispose);
      await provider.init();
      await provider.playVisibleAt(0);

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<PlayerProvider>.value(
            value: provider,
            child: const PlayerScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Fila de reprodução'));
      await tester.pumpAndSettle();

      expect(find.textContaining('faixas'), findsOneWidget);
      expect(find.text('Tocando agora'), findsOneWidget);
      expect(find.text('Beta'), findsOneWidget);
      expect(find.text('Gamma'), findsOneWidget);

      // Tocar um item da folha fecha o sheet e assume a faixa.
      await tester.tap(find.text('Beta'));
      await tester.pumpAndSettle();

      expect(find.textContaining('faixas'), findsNothing);
      expect(provider.currentSong?.title, 'Beta');
      expect(audio.played.last.title, 'Beta');

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('remover da folha atualiza a lista ao vivo sem fechar',
        (WidgetTester tester) async {
      final PlayableAudioService audio = PlayableAudioService();
      final PlayerProvider provider = _provider(audio);
      addTearDown(provider.dispose);
      await provider.init();
      await provider.playVisibleAt(0); // Alpha corrente

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<PlayerProvider>.value(
            value: provider,
            child: const PlayerScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Fila de reprodução'));
      await tester.pumpAndSettle();

      // Primeiro "Remover da fila" = índice 0 (a corrente Alpha).
      await tester.tap(find.byTooltip('Remover da fila').first);
      await tester.pumpAndSettle();

      expect(find.textContaining('2 faixas'), findsOneWidget);
      expect(find.text('Alpha'), findsNothing); // saiu da folha e do player
      expect(_titles(provider.queue), <String>['Beta', 'Gamma']);
      // A sobrevivente assumiu e recarregou.
      expect(provider.currentSong?.title, 'Beta');
      expect(audio.played.last.title, 'Beta');

      await tester.pumpWidget(const SizedBox());
    });
  });

  group('MusicScreen — menu da faixa e seleção em lote (3.5)', () {
    testWidgets(
      'menu da faixa: Adicionar à fila e Tocar a seguir com confirmação',
      (WidgetTester tester) async {
        final PlayableAudioService audio = PlayableAudioService();
        final PlayerProvider provider = _provider(audio);
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

        await tester.tap(_menuOf('Alpha'));
        await tester.pumpAndSettle();
        expect(find.text('Tocar a seguir'), findsOneWidget);
        expect(find.text('Adicionar à fila'), findsOneWidget);

        // Nunca tocou: a adição vira a primeira reprodução.
        await tester.tap(find.text('Adicionar à fila'));
        await tester.pumpAndSettle();
        expect(_titles(audio.played), <String>['Alpha']);
        expect(_titles(provider.queue), <String>['Alpha']);
        expect(find.text('Na fila: Alpha'), findsOneWidget);

        // "Tocar a seguir" com a fila tocando: entra depois da corrente
        // e NÃO pula para a faixa nova (reload reabre a Alpha).
        await tester.tap(_menuOf('Beta'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Tocar a seguir'));
        await tester.pumpAndSettle();
        expect(_titles(provider.queue), <String>['Alpha', 'Beta']);
        expect(provider.currentSong?.title, 'Alpha');
        expect(audio.played.last.title, 'Alpha');
        // O aviso novo entra ENFILEIRADO atrás do primeiro (4s): o
        // relógio do teste precisa passar por cima dele.
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle();
        expect(find.text('A seguir: Beta'), findsOneWidget);

        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets('seleção em lote: Adicionar à fila leva o lote e limpa',
        (WidgetTester tester) async {
      final PlayableAudioService audio = PlayableAudioService();
      final PlayerProvider provider = _provider(audio);
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

      // Seleciona as duas primeiras faixas (long-press entra no modo).
      await tester.longPress(find.byType(SongListTile).first);
      await tester.pumpAndSettle();
      await tester.tap(find.byType(SongListTile).at(1));
      await tester.pumpAndSettle();
      expect(find.textContaining('2 selecionadas'), findsOneWidget);

      await tester.tap(find.byTooltip('Ações da seleção'));
      await tester.pumpAndSettle();
      expect(find.text('Tocar a seguir'), findsOneWidget);
      expect(find.text('Adicionar à fila'), findsOneWidget);

      await tester.tap(find.text('Adicionar à fila'));
      await tester.pumpAndSettle();

      // Nunca tocou: começa pela primeira selecionada; a seleção limpa.
      expect(_titles(provider.queue), <String>['Alpha', 'Beta']);
      expect(_titles(audio.played), <String>['Alpha']);
      expect(provider.currentSong?.title, 'Alpha');
      expect(find.textContaining('selecionadas'), findsNothing);
      expect(find.byTooltip('Ações da seleção'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });
  });
}
