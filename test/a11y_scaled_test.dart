// Item 5.3 — acessibilidade: textScaler 2.0 sem overflow nas telas
// principais e o helper de animações reduzidas do Motion.
//
// O override de escala entra pelo `builder` do MaterialApp — o caminho
// canônico para afetar o app inteiro num teste (o MediaQuery do
// ambiente não escala os Texts do harness direto). Overflow estoura
// como exceção do próprio framework e falha o teste.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:audify/l10n/app_localizations.dart';
import 'package:audify/models/song_model.dart';
import 'package:audify/providers/player_provider.dart';
import 'package:audify/providers/settings_provider.dart';
import 'package:audify/repositories/session_repository.dart';
import 'package:audify/repositories/song_repository.dart';
import 'package:audify/screens/music_screen.dart';
import 'package:audify/screens/player_screen.dart';
import 'package:audify/screens/settings_screen.dart';
import 'package:audify/utils/motion.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/playable_audio_service.dart';

class _FakeSongRepository extends SongRepository {
  @override
  Future<List<Song>> loadDeviceSongs() async => const [];

  @override
  Future<List<Song>> loadAssetSongs() async => const [];
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

/// MaterialApp com textScaler 2.0 em TODO o app (via builder).
Widget _scaledApp(Widget home) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: const [Locale('pt', 'BR'), Locale('en')],
    builder: (BuildContext context, Widget? child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: const TextScaler.linear(2.0)),
      child: child!,
    ),
    home: home,
  );
}

/// Confirma que o override do builder realmente pegou: o context é o
/// da TELA montada (abaixo do builder), não o do MaterialApp.
void _expectScaled(WidgetTester tester, Type screen) {
  final BuildContext ctx = tester.element(find.byType(screen));
  expect(MediaQuery.textScalerOf(ctx), const TextScaler.linear(2.0));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('textScaler 2.0 sem overflow (5.3)', () {
    testWidgets('Configurações', (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final SettingsProvider settings = SettingsProvider();
      await settings.load();
      addTearDown(settings.dispose);

      await tester.pumpWidget(
        ChangeNotifierProvider<SettingsProvider>.value(
          value: settings,
          child: Builder(
            builder: (BuildContext context) => _scaledApp(
              const Scaffold(body: SettingsScreen()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      _expectScaled(tester, SettingsScreen);

      // O topo da tela renderizou (cabeçalho "Aparência" — pt ou en
      // conforme o ambiente) — sem overflow: a exceção do framework já
      // teria falhado o pumpAndSettle. A 2.0x as seções seguintes caem
      // abaixo do viewport da ListView, que é rolagem, não defeito.
      expect(
        find.text('APARÊNCIA').evaluate().isNotEmpty ||
            find.text('APPEARANCE').evaluate().isNotEmpty,
        isTrue,
      );

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Música', (WidgetTester tester) async {
      final PlayableAudioService audio = PlayableAudioService();
      final PlayerProvider provider = PlayerProvider(
        audio,
        songRepository: _FakeSongRepository(),
        sessionRepository: _FakeSessionRepository(),
      );
      addTearDown(provider.dispose);
      await provider.init();

      await tester.pumpWidget(
        _scaledApp(
          Scaffold(
            body: ChangeNotifierProvider<PlayerProvider>.value(
              value: provider,
              child: const MusicScreen(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      _expectScaled(tester, MusicScreen);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Player', (WidgetTester tester) async {
      final PlayableAudioService audio = PlayableAudioService();
      final PlayerProvider provider = PlayerProvider(
        audio,
        songRepository: _FakeSongRepository(),
        sessionRepository: _FakeSessionRepository(),
      );
      addTearDown(provider.dispose);
      await provider.init();

      await tester.pumpWidget(
        _scaledApp(
          ChangeNotifierProvider<PlayerProvider>.value(
            value: provider,
            child: const PlayerScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      _expectScaled(tester, PlayerScreen);

      await tester.pumpWidget(const SizedBox());
    });
  });

  group('Motion.scale — animações reduzidas (5.3)', () {
    testWidgets('zera a duração quando o sistema reduz animações',
        (WidgetTester tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Builder(
            builder: (BuildContext c) {
              ctx = c;
              return const SizedBox();
            },
          ),
        ),
      );
      expect(Motion.scale(ctx, Motion.normal), Duration.zero);
      expect(Motion.scale(ctx, Motion.fast), Duration.zero);
    });

    testWidgets('mantém a duração normal quando animações estão ligadas',
        (WidgetTester tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(
        Builder(
          builder: (BuildContext c) {
            ctx = c;
            return const SizedBox();
          },
        ),
      );
      expect(Motion.scale(ctx, Motion.normal), Motion.normal);
      expect(Motion.scale(ctx, Motion.fast), Motion.fast);
    });
  });
}
