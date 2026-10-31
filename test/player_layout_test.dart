// Testes do item 3.7 — layout do PlayerScreen (retrato/paisagem), capa
// com lado min(320, espaço), ações rápidas na tela e botão anterior do
// mini player.
//
// Overflow de RenderFlex derruba o teste sozinho (FlutterError relatado);
// aqui asserimos também takeException() nulo e a geometria da capa
// (quadrada e encolhendo) — que é o que o 320 fixo antigo quebrava.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:audify/models/song_model.dart';
import 'package:audify/providers/player_provider.dart';
import 'package:audify/repositories/session_repository.dart';
import 'package:audify/repositories/song_repository.dart';
import 'package:audify/screens/player_screen.dart';
import 'package:audify/widgets/album_artwork.dart';
import 'package:audify/widgets/player_controls.dart';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PlayerScreen — layout 3.7', () {
    late PlayableAudioService audio;
    late PlayerProvider provider;

    setUp(() async {
      audio = PlayableAudioService();
      provider = PlayerProvider(
        audio,
        songRepository: _FakeSongRepository(<Song>[
          _track('alpha'),
          _track('beta'),
          _track('gamma'),
        ]),
        sessionRepository: _FakeSessionRepository(),
      );
      await provider.init();
      await provider.playVisibleAt(0);
    });

    tearDown(() => provider.dispose());

    /// View lógica de teste (dpr 1) + reset no fim do teste.
    void view(WidgetTester tester, double width, double height) {
      tester.view.physicalSize = Size(width, height);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
    }

    Future<void> pumpPlayer(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<PlayerProvider>.value(
            value: provider,
            child: const PlayerScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('retrato 400×900: capa 320×320 e ações fora do AppBar', (
      WidgetTester tester,
    ) async {
      view(tester, 400, 900);
      await pumpPlayer(tester);
      expect(tester.takeException(), isNull);

      expect(tester.getSize(find.byType(AlbumArtwork)), const Size(320, 320));

      // Fila/timer/velocidade visíveis na tela…
      expect(find.byTooltip('Fila de reprodução'), findsOneWidget);
      expect(find.byTooltip('Timer de sono'), findsOneWidget);
      expect(find.byTooltip('Velocidade 1.0x'), findsOneWidget);
      // …e NÃO duplicados no AppBar (que só guarda letras + ações).
      for (final String tooltip in <String>[
        'Fila de reprodução',
        'Timer de sono',
        'Velocidade 1.0x',
      ]) {
        expect(
          find.descendant(
            of: find.byType(AppBar),
            matching: find.byTooltip(tooltip),
          ),
          findsNothing,
          reason: '$tooltip deve estar na tela, não no AppBar',
        );
      }

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('retrato pequeno 320×480: capa encolhe quadrada '
        '(não esmaga como o 320 fixo)', (WidgetTester tester) async {
      view(tester, 320, 480);
      await pumpPlayer(tester);
      expect(tester.takeException(), isNull);

      final Size art = tester.getSize(find.byType(AlbumArtwork));
      expect(art.width, art.height, reason: 'capa quadrada, sem deformar');
      expect(art.width, lessThan(320));
      expect(art.width, greaterThan(0));

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('paisagem 960×420: duas colunas, capa à esquerda '
        'e ações na tela', (WidgetTester tester) async {
      view(tester, 960, 420);
      await pumpPlayer(tester);
      expect(tester.takeException(), isNull);

      final Size art = tester.getSize(find.byType(AlbumArtwork));
      expect(art, const Size(320, 320));
      // Duas colunas: capa à esquerda, seek/controles à direita.
      expect(
        tester.getCenter(find.byType(AlbumArtwork)).dx,
        lessThan(tester.getCenter(find.byType(Slider)).dx),
        reason: 'capa e controles em colunas diferentes',
      );
      expect(find.byTooltip('Fila de reprodução'), findsOneWidget);
      expect(find.byTooltip('Timer de sono'), findsOneWidget);
      expect(find.byTooltip('Velocidade 1.0x'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });
  });

  group('mini player — anterior (3.7)', () {
    late PlayableAudioService audio;
    late PlayerProvider provider;

    setUp(() async {
      audio = PlayableAudioService();
      provider = PlayerProvider(
        audio,
        songRepository: _FakeSongRepository(<Song>[
          _track('alpha'),
          _track('beta'),
          _track('gamma'),
        ]),
        sessionRepository: _FakeSessionRepository(),
      );
      await provider.init();
      // Terceira faixa: "anterior" tem para onde ir (beta).
      await provider.playVisibleAt(2);
    });

    tearDown(() => provider.dispose());

    testWidgets('botão Anterior volta para a faixa anterior', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider<PlayerProvider>.value(
            value: provider,
            child: const PlayerControls(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byTooltip('Anterior'), findsOneWidget);
      expect(find.byTooltip('Próxima'), findsOneWidget);
      expect(audio.played.last.title, 'Gamma');

      await tester.tap(find.byTooltip('Anterior'));
      await tester.pumpAndSettle();

      expect(audio.played.last.title, 'Beta');
      expect(provider.queueIndex, 1);

      await tester.pumpWidget(const SizedBox());
    });
  });
}
