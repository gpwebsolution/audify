// Testes de UI do item 3.6 — folha de letras do PlayerScreen.
//
// O loader real lê disco/bundle — sob FakeAsync (testWidgets) isso não
// resolve; o teste injeta [LyricsService.debugLoader] (mesma lógica do
// PlayableAudioService para playSong). O caminho real do serviço —
// .lrc na mesma pasta, ID3 embutido, fallbacks — é coberto em
// lyrics_service_test.dart, que roda em zona normal.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:audify/models/song_model.dart';
import 'package:audify/providers/player_provider.dart';
import 'package:audify/repositories/session_repository.dart';
import 'package:audify/repositories/song_repository.dart';
import 'package:audify/screens/player_screen.dart';
import 'package:audify/services/lyrics_service.dart';
import 'package:audify/utils/lrc_parser.dart';
import 'package:audify/widgets/lyrics_sheet.dart';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('folha de letras do PlayerScreen (3.6)', () {
    late PlayableAudioService audio;
    late PlayerProvider provider;

    setUp(() async {
      audio = PlayableAudioService();
      provider = PlayerProvider(
        audio,
        songRepository: _FakeSongRepository(_threeTracks()),
        sessionRepository: _FakeSessionRepository(),
      );
      await provider.init();
      // Tocando = faixa corrente = botão "Letras" visível.
      await provider.playVisibleAt(0);
    });

    tearDown(() {
      LyricsService.debugLoader = null;
      provider.dispose();
    });

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

    testWidgets('abre a folha e destaca a linha da posição atual', (
      WidgetTester tester,
    ) async {
      LyricsService.debugLoader = (Song _) async => LrcLyrics.parse(
        '[00:01.00]primeira\n'
        '[00:02.00]segunda\n'
        '[00:03.00]terceira',
      )!;

      await pumpPlayer(tester);
      await tester.tap(find.byTooltip('Letras'));
      await tester.pumpAndSettle();

      expect(find.byType(LyricsSheet), findsOneWidget);
      expect(find.text('primeira'), findsOneWidget);
      expect(find.text('terceira'), findsOneWidget);

      final ColorScheme colors = Theme.of(
        tester.element(find.byType(LyricsSheet)),
      ).colorScheme;

      // Posição 0: antes da primeira marcação — nada destacado.
      expect(
        tester.widget<Text>(find.text('primeira')).style?.fontWeight,
        isNot(FontWeight.bold),
      );

      // 1,5s → linha 0 acesa (posição propaga do serviço via listener).
      audio.position.value = const Duration(milliseconds: 1500);
      await tester.pumpAndSettle();
      final Text first = tester.widget<Text>(find.text('primeira'));
      expect(first.style?.fontWeight, FontWeight.bold);
      expect(first.style?.color, colors.primary);
      expect(
        tester.widget<Text>(find.text('segunda')).style?.fontWeight,
        isNot(FontWeight.bold),
      );

      // 2,5s → o destaque anda para a linha seguinte.
      audio.position.value = const Duration(milliseconds: 2500);
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.text('segunda')).style?.fontWeight,
        FontWeight.bold,
      );
      expect(
        tester.widget<Text>(find.text('primeira')).style?.fontWeight,
        isNot(FontWeight.bold),
      );

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('sem letra: orienta a colocar um .lrc ao lado do áudio', (
      WidgetTester tester,
    ) async {
      LyricsService.debugLoader = (Song _) async => null;

      await pumpPlayer(tester);
      await tester.tap(find.byTooltip('Letras'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Nenhuma letra encontrada'), findsOneWidget);
      expect(find.textContaining('.lrc'), findsOneWidget);
      expect(find.byType(LyricsSheet), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('texto corrido (sem timestamps) aparece sem destaque', (
      WidgetTester tester,
    ) async {
      LyricsService.debugLoader = (Song _) async =>
          LrcLyrics.unsynced('linha um\nlinha dois');

      await pumpPlayer(tester);
      await tester.tap(find.byTooltip('Letras'));
      await tester.pumpAndSettle();

      expect(find.text('linha um'), findsOneWidget);
      expect(find.text('linha dois'), findsOneWidget);
      expect(
        tester.widget<Text>(find.text('linha um')).style?.fontWeight,
        isNot(FontWeight.bold),
        reason: 'texto corrido não tem linha corrente para destacar',
      );

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('lista longa: rola até a linha corrente (sincronia)', (
      WidgetTester tester,
    ) async {
      LyricsService.debugLoader = (Song _) async => LrcLyrics.parse(
        <String>[
          for (int i = 1; i <= 40; i++)
            '[00:${i.toString().padLeft(2, '0')}.00]linha $i',
        ].join('\n'),
      )!;

      await pumpPlayer(tester);
      await tester.tap(find.byTooltip('Letras'));
      await tester.pumpAndSettle();

      // 25,5s → a linha corrente é "linha 25" (marcada em 25s).
      audio.position.value = const Duration(milliseconds: 25500);
      await tester.pumpAndSettle();

      final Offset topLeft = tester.getTopLeft(find.text('linha 25'));
      expect(topLeft.dy, greaterThanOrEqualTo(0));
      expect(topLeft.dy, lessThan(600), reason: 'dentro do viewport');
      expect(
        tester.widget<Text>(find.text('linha 25')).style?.fontWeight,
        FontWeight.bold,
      );

      await tester.pumpWidget(const SizedBox());
    });
  });
}
