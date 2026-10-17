// Testes do item 4.2 — UI do histórico: entradas automáticas na aba
// Playlists, detalhe "Tocadas recentemente"/"Mais tocadas" (ordem,
// play-all) e "Limpar histórico".
//
// Acesso ao banco sob FakeAsync segue a receita do favorites_ui_test:
// assíncrono em tester.runAsync (zona real) e pingue-pongue
// pump/runAsync (_drainDb) para gravações disparadas na zona fake.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:audify/models/song_model.dart';
import 'package:audify/providers/favorites_provider.dart';
import 'package:audify/providers/history_provider.dart';
import 'package:audify/providers/player_provider.dart';
import 'package:audify/providers/playlist_provider.dart';
import 'package:audify/repositories/session_repository.dart';
import 'package:audify/repositories/song_repository.dart';
import 'package:audify/screens/auto_playlist_detail_screen.dart';
import 'package:audify/screens/playlists_screen.dart';
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

PlayerProvider _player(PlayableAudioService svc) => PlayerProvider(
      svc,
      songRepository: _FakeSongRepository(<Song>[
        _track('alpha'),
        _track('beta'),
        _track('gamma'),
      ]),
      sessionRepository: _FakeSessionRepository(),
    );

/// Fecha/apaga o banco na zona real e zera os singletons em memória.
Future<void> _freshDb(WidgetTester tester) async {
  await tester.runAsync(() async {
    await PlaylistDatabase.close();
    await databaseFactory.deleteDatabase(
      p.join(await getDatabasesPath(), 'audify.db'),
    );
  });
  FavoritesProvider.instance.resetForTest();
  HistoryProvider.instance.resetForTest();
}

/// Abre o singleton na zona real (senão os awaits seguintes penduram).
Future<void> _warmDb(WidgetTester tester) =>
    tester.runAsync(() => PlaylistDatabase.getStats());

/// Semeia plays e carrega o singleton, tudo em zona real.
Future<void> _seedHistory(
  WidgetTester tester,
  List<(String, int)> plays,
) =>
    tester.runAsync(() async {
      for (final (String songId, int ms) in plays) {
        await PlaylistDatabase.recordPlay(songId, playedAtMs: ms);
      }
      await HistoryProvider.instance.load();
    });

/// Aterrissa gravações/leituras disparadas na zona fake.
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

/// Monta a aba Playlists sob providers acima do MaterialApp (as rotas
/// empurradas enxergam tudo — igual ao app em main.dart).
Widget _appTree(PlayerProvider player, PlaylistProvider playlists) =>
    MultiProvider(
      providers: [
        ChangeNotifierProvider<PlayerProvider>.value(value: player),
        ChangeNotifierProvider<PlaylistProvider>.value(value: playlists),
      ],
      child: MaterialApp(home: Scaffold(body: const PlaylistsScreen())),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('histórico na UI (4.2)', () {
    testWidgets('aba Playlists: automáticas entre Favoritas e as reais',
        (WidgetTester tester) async {
      await _freshDb(tester);
      final PlayableAudioService audio = PlayableAudioService();
      final PlayerProvider player = _player(audio);
      addTearDown(player.dispose);
      await player.init();
      await _warmDb(tester);
      await _seedHistory(tester, <(String, int)>[
        (_track('alpha').id, 1000),
        (_track('alpha').id, 2000),
        (_track('beta').id, 1500),
      ]);
      await tester.runAsync(() async {
        await PlaylistDatabase.createPlaylist('Minha Lista');
      });
      final PlaylistProvider playlists = PlaylistProvider(player);
      addTearDown(playlists.dispose);

      await tester.pumpWidget(_appTree(player, playlists));
      await tester.pump();
      // Reloads do construtor (playlists + spinner) precisam da janela
      // real antes de qualquer pumpAndSettle.
      await _drainDb(tester);

      // Ordem fixa: Favoritas → histórico → playlists reais.
      final Offset favoritas = tester.getCenter(find.text('Favoritas'));
      final Offset recentes = tester.getCenter(
        find.text('Tocadas recentemente'),
      );
      final Offset tocadas = tester.getCenter(find.text('Mais tocadas'));
      final Offset minha = tester.getCenter(find.text('Minha Lista'));
      expect(favoritas.dy, lessThan(recentes.dy));
      expect(recentes.dy, lessThan(tocadas.dy));
      expect(tocadas.dy, lessThan(minha.dy));

      // 2 faixas no histórico (as duas entradas compartilham a contagem).
      expect(find.text('2 faixas'), findsNWidgets(2));

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets(
        'detalhes: recentes por último toque, mais tocadas por contagem, '
        'play-all na ordem da tela',
        (WidgetTester tester) async {
      await _freshDb(tester);
      final PlayableAudioService audio = PlayableAudioService();
      final PlayerProvider player = _player(audio);
      addTearDown(player.dispose);
      await player.init();
      await _warmDb(tester);
      // Alpha: 2 plays (último 600) | Beta: 1 play (último 900).
      await _seedHistory(tester, <(String, int)>[
        (_track('alpha').id, 500),
        (_track('alpha').id, 600),
        (_track('beta').id, 900),
      ]);
      final PlaylistProvider playlists = PlaylistProvider(player);
      addTearDown(playlists.dispose);

      await tester.pumpWidget(_appTree(player, playlists));
      await tester.pump();
      await _drainDb(tester);

      // --- Tocadas recentemente: último toque primeiro (Beta > Alpha).
      await tester.tap(find.text('Tocadas recentemente'));
      await tester.pumpAndSettle();
      expect(find.byType(AutoPlaylistDetailScreen), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Beta')).dy,
        lessThan(tester.getTopLeft(find.text('Alpha')).dy),
      );

      await tester.tap(find.byTooltip('Tocar tudo'));
      await tester.pumpAndSettle();
      expect(audio.played.last.title, 'Beta');
      expect(
        player.queue.map((Song s) => s.title).toList(),
        <String>['Beta', 'Alpha'],
      );

      await tester.pageBack();
      await tester.pumpAndSettle();

      // --- Mais tocadas: contagem primeiro (Alpha com 2 > Beta com 1).
      await tester.tap(find.text('Mais tocadas'));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('Alpha')).dy,
        lessThan(tester.getTopLeft(find.text('Beta')).dy),
      );

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Limpar histórico: confirma, esvazia tela, banco e tiles',
        (WidgetTester tester) async {
      await _freshDb(tester);
      final PlayableAudioService audio = PlayableAudioService();
      final PlayerProvider player = _player(audio);
      addTearDown(player.dispose);
      await player.init();
      await _warmDb(tester);
      await _seedHistory(tester, <(String, int)>[
        (_track('alpha').id, 100),
      ]);
      final PlaylistProvider playlists = PlaylistProvider(player);
      addTearDown(playlists.dispose);

      await tester.pumpWidget(_appTree(player, playlists));
      await tester.pump();
      await _drainDb(tester);

      await tester.tap(find.text('Mais tocadas'));
      await tester.pumpAndSettle();
      expect(find.text('Alpha'), findsOneWidget);

      await tester.tap(find.byTooltip('Limpar histórico'));
      await tester.pumpAndSettle();
      expect(find.text('Limpar histórico?'), findsOneWidget);

      await tester.tap(find.text('Limpar'));
      await tester.pumpAndSettle();

      // Detalhe esvaziou (e os botões da AppBar somem junto).
      expect(HistoryProvider.instance.count, 0);
      expect(
        find.textContaining('Sem contagens por aqui ainda'),
        findsOneWidget,
      );
      expect(find.byTooltip('Tocar tudo'), findsNothing);

      // Banco limpo de verdade.
      await _drainDb(tester);
      expect(await tester.runAsync(() => PlaylistDatabase.getStats()), isEmpty);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Ainda sem histórico'), findsNWidgets(2));

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('histórico vazio: estado vazio sem play-all',
        (WidgetTester tester) async {
      await _freshDb(tester);
      final PlayableAudioService audio = PlayableAudioService();
      final PlayerProvider player = _player(audio);
      addTearDown(player.dispose);
      await player.init();
      await _warmDb(tester);
      final PlaylistProvider playlists = PlaylistProvider(player);
      addTearDown(playlists.dispose);

      await tester.pumpWidget(_appTree(player, playlists));
      await tester.pump();
      await _drainDb(tester);

      await tester.tap(find.text('Tocadas recentemente'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Nenhuma faixa no histórico ainda'),
        findsOneWidget,
      );
      expect(find.byTooltip('Tocar tudo'), findsNothing);
      expect(find.byTooltip('Limpar histórico'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });
  });
}
