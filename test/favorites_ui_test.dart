// Testes do item 4.1 — corações de favorito na UI.
//
// Camadas: PlayerScreen (ações rápidas), MusicScreen (coração do tile),
// aba Playlists (entrada fixa "Favoritas") e o detalhe (tocar tudo /
// desfavoritar).
//
// sqflite_common_ffi sob FakeAsync: o elapse do pump é síncrono (a IO
// real do isolate nunca roda durante ele) e as microtarefas da zona fake
// só drenam em pump. Por isso todo acesso assíncrono ao banco roda em
// tester.runAsync (zona real) e a gravação disparada pelo tap — que nasce
// na zona fake — aterrissa com o pingue-pongue pump/runAsync de _drainDb.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:audify/models/song_model.dart';
import 'package:audify/providers/favorites_provider.dart';
import 'package:audify/providers/player_provider.dart';
import 'package:audify/providers/playlist_provider.dart';
import 'package:audify/repositories/session_repository.dart';
import 'package:audify/repositories/song_repository.dart';
import 'package:audify/screens/favorites_detail_screen.dart';
import 'package:audify/screens/music_screen.dart';
import 'package:audify/screens/playlists_screen.dart';
import 'package:audify/screens/player_screen.dart';
import 'package:audify/services/playlist_database.dart';
import 'package:audify/widgets/song_list_tile.dart';

import 'support/playable_audio_service.dart';

Song _track(String name) => Song.fromAsset(assetPath: 'assets/songs/$name.mp3');

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

PlayerProvider _player(PlayableAudioService svc) => PlayerProvider(
  svc,
  songRepository: _FakeSongRepository(<Song>[
    _track('alpha'),
    _track('beta'),
    _track('gamma'),
  ]),
  sessionRepository: _FakeSessionRepository(),
);

/// Coração NÃO cheio na linha da faixa [title].
Finder _heartOf(String title) => find.descendant(
  of: find.ancestor(of: find.text(title), matching: find.byType(SongListTile)),
  matching: find.byTooltip('Favoritar'),
);

/// Fecha/apaga o banco na zona real e zera o singleton em memória.
Future<void> _freshDb(WidgetTester tester) async {
  await tester.runAsync(() async {
    await PlaylistDatabase.close();
    await databaseFactory.deleteDatabase(
      p.join(await getDatabasesPath(), 'audify.db'),
    );
  });
  FavoritesProvider.instance.resetForTest();
}

/// Abre o singleton do PlaylistsDatabase DENTRO da zona real — sem isso,
/// qualquer await posterior (mesmo em runAsync) encadeia num Completer
/// preso na zona fake e o teste trava.
Future<void> _warmDb(WidgetTester tester) =>
    tester.runAsync(() => PlaylistDatabase.getFavorites());

/// Aterrissa a gravação disparada na zona fake: p/ pump drena a
/// microtarefa que envia, janela real traz a resposta do isolate, pump
/// drena a conclusão. Repetido para as etapas encadeadas.
Future<void> _drainDb(WidgetTester tester, {int rounds = 4}) async {
  for (int i = 0; i < rounds; i++) {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

/// Leitura do banco sempre na zona real (runAsync); nulo → vazio.
Future<List<Song>> _favorites(WidgetTester tester) async {
  final List<Song>? rows = await tester.runAsync(
    () => PlaylistDatabase.getFavorites(),
  );
  return rows ?? const <Song>[];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('coração na UI (4.1)', () {
    testWidgets('player: ações rápidas favoritam e desfavoritam', (
      WidgetTester tester,
    ) async {
      await _freshDb(tester);
      final PlayableAudioService audio = PlayableAudioService();
      final PlayerProvider provider = _player(audio);
      addTearDown(provider.dispose);
      await provider.init();
      await provider.playVisibleAt(0);
      await _warmDb(tester);
      await tester.runAsync(() => FavoritesProvider.instance.load());

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<PlayerProvider>.value(
            value: provider,
            child: const PlayerScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byTooltip('Favoritar'), findsOneWidget);
      await tester.tap(find.byTooltip('Favoritar'));
      await tester.pumpAndSettle();

      final String alphaId = provider.currentSong!.id;
      expect(FavoritesProvider.instance.isFavorite(alphaId), isTrue);
      expect(find.byTooltip('Desfavoritar'), findsOneWidget);

      // Persistência: a linha aterrissou no favorite_songs.
      await _drainDb(tester);
      final List<Song> persisted = await _favorites(tester);
      expect(persisted.map((Song s) => s.title), <String>['Alpha']);

      // Desfavorita pelo mesmo botão.
      await tester.tap(find.byTooltip('Desfavoritar'));
      await tester.pumpAndSettle();
      expect(FavoritesProvider.instance.isFavorite(alphaId), isFalse);
      expect(find.byTooltip('Favoritar'), findsOneWidget);
      await _drainDb(tester);
      expect(await _favorites(tester), isEmpty);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('tile da biblioteca: coração marca só a faixa escolhida', (
      WidgetTester tester,
    ) async {
      await _freshDb(tester);
      final PlayableAudioService audio = PlayableAudioService();
      final PlayerProvider provider = _player(audio);
      addTearDown(provider.dispose);
      await provider.init();
      await _warmDb(tester);
      await tester.runAsync(() => FavoritesProvider.instance.load());

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

      // Três corações (uma por faixa), todos vazios.
      expect(find.byTooltip('Favoritar'), findsNWidgets(3));

      await tester.tap(_heartOf('Beta'));
      await tester.pumpAndSettle();

      expect(
        FavoritesProvider.instance.songs.map((Song s) => s.title).toList(),
        <String>['Beta'],
      );
      expect(find.byTooltip('Desfavoritar'), findsNWidgets(1));
      expect(find.byTooltip('Favoritar'), findsNWidgets(2));
      await _drainDb(tester);
      expect(await _favorites(tester), hasLength(1));

      // Desmarca do mesmo jeito.
      await tester.tap(find.byTooltip('Desfavoritar'));
      await tester.pumpAndSettle();
      expect(FavoritesProvider.instance.count, 0);
      expect(find.byTooltip('Favoritar'), findsNWidgets(3));
      await _drainDb(tester);
      expect(await _favorites(tester), isEmpty);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('aba Playlists: Favoritas fixa no topo e abre o detalhe', (
      WidgetTester tester,
    ) async {
      await _freshDb(tester);
      final PlayableAudioService audio = PlayableAudioService();
      final PlayerProvider provider = _player(audio);
      addTearDown(provider.dispose);
      await provider.init();

      // Semeia na zona real ANTES do PlaylistProvider (senão o
      // auto-reload do construtor nasce com o banco frio na zona fake).
      await _warmDb(tester);
      await tester.runAsync(() async {
        await PlaylistDatabase.createPlaylist('Minha Lista');
        await PlaylistDatabase.addFavorite(_track('beta'));
        await FavoritesProvider.instance.load();
      });

      final PlaylistProvider playlists = PlaylistProvider(provider);
      addTearDown(playlists.dispose);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<PlayerProvider>.value(value: provider),
            ChangeNotifierProvider<PlaylistProvider>.value(value: playlists),
          ],
          // Providers ACIMA do MaterialApp: as rotas empurradas (detalhe
          // de Favoritas) também enxergam — igual ao app em main.dart.
          // A tela é uma aba: no app ela vive sob o Scaffold do
          // HomeScreen (daí o Scaffold aqui também — o ListTile da
          // entrada fixa exige Material ancestor).
          child: MaterialApp(home: Scaffold(body: const PlaylistsScreen())),
        ),
      );
      await tester.pump();
      // O reload do construtor precisa da janela real para aterrissar —
      // e enquanto isLoading=true o spinner giraria para sempre, travando
      // um pumpAndSettle antes do drain.
      await _drainDb(tester);

      // Fixa no topo, ANTES da playlist real (mesmo sem rolagem).
      final Offset favoritas = tester.getCenter(find.text('Favoritas'));
      final Offset minha = tester.getCenter(find.text('Minha Lista'));
      expect(favoritas.dy, lessThan(minha.dy));
      expect(find.textContaining('1 faixa'), findsOneWidget);

      await tester.tap(find.text('Favoritas'));
      await tester.pumpAndSettle();
      expect(find.byType(FavoritesDetailScreen), findsOneWidget);
      expect(find.text('Beta'), findsOneWidget);

      // O coração da linha desfavorita e some sozinho.
      await tester.tap(find.byTooltip('Desfavoritar'));
      await tester.pumpAndSettle();
      expect(FavoritesProvider.instance.count, 0);
      expect(find.textContaining('Nenhuma faixa favorita'), findsOneWidget);
      await _drainDb(tester);
      expect(await _favorites(tester), isEmpty);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('detalhe: "Tocar tudo" monta a fila na ordem alfabética', (
      WidgetTester tester,
    ) async {
      await _freshDb(tester);
      final PlayableAudioService audio = PlayableAudioService();
      final PlayerProvider provider = _player(audio);
      addTearDown(provider.dispose);
      await provider.init();

      await _warmDb(tester);
      await tester.runAsync(() async {
        await PlaylistDatabase.addFavorite(_track('gamma'));
        await PlaylistDatabase.addFavorite(_track('alpha'));
        await FavoritesProvider.instance.load();
      });

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<PlayerProvider>.value(
            value: provider,
            child: const FavoritesDetailScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Tocar tudo'));
      await tester.pumpAndSettle();

      expect(audio.played.last.title, 'Alpha');
      expect(provider.queue.map((Song s) => s.title).toList(), <String>[
        'Alpha',
        'Gamma',
      ]);

      await tester.pumpWidget(const SizedBox());
    });
  });
}
