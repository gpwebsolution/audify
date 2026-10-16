// Testes do item 2.1: o tick de posição (~5x/s) NÃO reconstrói a lista
// da biblioteca.
//
// O que mudou:
//  - PlayerProvider.position não participa mais do notifyListeners() do
//    provider — virou um ValueNotifier dedicado (positionListenable),
//    consumido só pelos widgets de progresso (ValueListenableBuilder);
//  - telas de lista assinam o provider com context.select (fatia
//    _MusicView: catálogo, busca, faixa corrente, toque, erros);
//  - a busca passou a notificar de propósito (antes ela só "funcionava"
//    na tela porque o tick reconstruía tudo).
//
// Estratégia dos testes de widget: a identidade dos widgets filhos é um
// contador de builds — quando a tela reconstrói, o itemBuilder cria
// INSTÂNCIAS NOVAS (element.update troca o widget); sem rebuild, as
// instâncias originais permanecem na árvore (same()).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:audify/models/song_model.dart';
import 'package:audify/providers/player_provider.dart';
import 'package:audify/repositories/session_repository.dart';
import 'package:audify/repositories/song_repository.dart';
import 'package:audify/screens/music_screen.dart';
import 'package:audify/screens/player_screen.dart';
import 'package:audify/widgets/player_controls.dart';
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

PlayerProvider _provider(PlayableAudioService svc) => PlayerProvider(
  svc,
  songRepository: _FakeSongRepository(<Song>[
    _track('apple'),
    _track('banana'),
    _track('cherry'),
  ]),
  sessionRepository: _FakeSessionRepository(),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();


  test('tick de posição não emite notifyListeners; busca notifica (2.1)',
      () async {
    final PlayableAudioService svc = PlayableAudioService();
    final PlayerProvider provider = _provider(svc);
    addTearDown(provider.dispose);
    await provider.init();
    // Deixa o init do construtor (disparado junto) terminar antes de
    // contar notificações.
    await pumpEventQueue();

    int notifications = 0;
    provider.addListener(() => notifications++);

    // 5 ticks — o que acontece em ~1s de reprodução.
    for (int i = 1; i <= 5; i++) {
      svc.position.value = Duration(seconds: i);
    }
    expect(
      notifications,
      0,
      reason: 'tick só move o notifier de progresso, não a UI da lista',
    );
    expect(provider.position, const Duration(seconds: 5));
    expect(provider.positionListenable.value, const Duration(seconds: 5));

    // A busca notifica de propósito (sem isso, digitar não atualizava a
    // tela pausada — dependia do rebuild acidental do tick).
    provider.setSearchQuery('a');
    expect(notifications, 1);
    expect(provider.visibleSongs, hasLength(2));
  });

  testWidgets(
    'aba Música: lista não reconstrói quando só a posição muda',
    (tester) async {
      final PlayableAudioService svc = PlayableAudioService();
      final PlayerProvider provider = _provider(svc);
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

      expect(find.byType(SongListTile), findsNWidgets(3));
      final SongListTile tile0 = tester.widget<SongListTile>(
        find.byType(SongListTile).first,
      );
      final TextField field0 = tester.widget<TextField>(
        find.byType(TextField),
      );

      // Ticks de posição — o cenário real de ~1s tocando.
      for (int i = 1; i <= 5; i++) {
        svc.position.value = Duration(seconds: i);
        await tester.pump();
      }

      expect(
        tester.widget<SongListTile>(find.byType(SongListTile).first),
        same(tile0),
        reason: 'tick de posição não pode reconstruir os itens da lista',
      );
      expect(
        tester.widget<TextField>(find.byType(TextField)),
        same(field0),
        reason: 'nem a tela inteira (campo de busca incluso)',
      );

      // Controle: mudança REAL da fatia reconstrói — prova que a técnica
      // de identidade enxergaria um rebuild indevido.
      provider.setSearchQuery('a');
      await tester.pump();
      expect(find.byType(SongListTile), findsNWidgets(2));
      final SongListTile tileSearch = tester.widget<SongListTile>(
        find.byType(SongListTile).first,
      );
      expect(tileSearch, isNot(same(tile0)));

      // Controle 2: tocar uma faixa reconstrói (destaque muda) — o
      // select continua reativo ao que importa para a lista.
      await provider.playVisibleAt(0);
      await tester.pump();
      final SongListTile tilePlaying = tester.widget<SongListTile>(
        find.byType(SongListTile).first,
      );
      expect(tilePlaying, isNot(same(tileSearch)));
      expect(tilePlaying.isCurrent, isTrue);

      // Desmonta antes do dispose do provider (notifier não pode ser
      // dispensado com ouvintes de widget ainda ligados).
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'mini player: a barra segue o tick; o resto não reconstrói',
    (tester) async {
      final PlayableAudioService svc = PlayableAudioService();
      final PlayerProvider provider = _provider(svc);
      addTearDown(provider.dispose);
      await provider.init();
      await provider.playVisibleAt(0);
      svc.duration.value = const Duration(minutes: 3);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            bottomNavigationBar: ChangeNotifierProvider<PlayerProvider>.value(
              value: provider,
              child: const PlayerControls(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester.widget<LinearProgressIndicator>(
          find.byType(LinearProgressIndicator),
        ).value,
        0.0,
      );
      final Text title = tester.widget<Text>(find.text('Apple'));

      // 1 de 3 minutos tocados → barra em ~0.33.
      svc.position.value = const Duration(minutes: 1);
      await tester.pump();

      expect(
        tester.widget<LinearProgressIndicator>(
          find.byType(LinearProgressIndicator),
        ).value,
        closeTo(1 / 3, 0.001),
        reason: 'a barra de progresso deve reagir ao tick',
      );
      expect(
        tester.widget<Text>(find.text('Apple')),
        same(title),
        reason: 'o restante do mini player não reconstrói no tick',
      );

      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'player em tela cheia: slider e tempos seguem o tick',
    (tester) async {
      final PlayableAudioService svc = PlayableAudioService();
      final PlayerProvider provider = _provider(svc);
      addTearDown(provider.dispose);
      await provider.init();
      await provider.playVisibleAt(0);
      svc.duration.value = const Duration(minutes: 3);

      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<PlayerProvider>.value(
            value: provider,
            child: const PlayerScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.widget<Slider>(find.byType(Slider)).value, 0.0);
      expect(find.text('00:00'), findsOneWidget);
      expect(find.text('03:00'), findsOneWidget);

      svc.position.value = const Duration(seconds: 10);
      await tester.pump();

      expect(tester.widget<Slider>(find.byType(Slider)).value, 10000.0);
      expect(
        find.text('00:10'),
        findsOneWidget,
        reason: 'tempo decorrido reage ao tick',
      );

      final Text title = tester.widget<Text>(find.text('Apple'));
      svc.position.value = const Duration(seconds: 20);
      await tester.pump();
      expect(tester.widget<Slider>(find.byType(Slider)).value, 20000.0);
      expect(
        tester.widget<Text>(find.text('Apple')),
        same(title),
        reason: 'capa/título/controles não reconstruem no tick',
      );

      await tester.pumpWidget(const SizedBox());
    },
  );
}
