// Testes do item 3.2 — velocidade de reprodução (0,5x–2,0x).
//
// Cobre: clamp na camada de serviço, publicação no PlaybackState.speed,
// persistência no SharedPreferences (novo e restaurado no boot), o
// delegador do PlayerProvider e o seletor no PlayerScreen (item 3.7:
// botão visível na tela, não mais no AppBar).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:audify/models/song_model.dart';
import 'package:audify/providers/player_provider.dart';
import 'package:audify/providers/settings_provider.dart';
import 'package:audify/repositories/session_repository.dart';
import 'package:audify/repositories/song_repository.dart';
import 'package:audify/screens/player_screen.dart';
import 'package:audify/services/audio_service.dart';

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

PlayerProvider _provider(
  PlayableAudioService svc,
  SettingsProvider? settings,
) =>
    PlayerProvider(
      svc,
      settings: settings,
      songRepository: _FakeSongRepository(<Song>[_track('apple')]),
      sessionRepository: _FakeSessionRepository(),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('AudioService.setPlaybackSpeed (3.2)', () {
    late AudioService svc;

    setUp(() {
      svc = AudioService();
    });

    tearDown(() async {
      await svc.dispose();
    });

    test('clamp 0,5–2,0 e publica no PlaybackState.speed', () async {
      final List<double> speeds = <double>[];
      final sub = svc.playbackState
          .skip(1)
          .listen((state) => speeds.add(state.speed));
      addTearDown(sub.cancel);

      await svc.setPlaybackSpeed(1.5);
      expect(svc.playbackSpeed, 1.5);

      // Fora da faixa: clamp, não estoura.
      await svc.setPlaybackSpeed(3.0);
      expect(svc.playbackSpeed, 2.0);
      await svc.setPlaybackSpeed(0.1);
      expect(svc.playbackSpeed, 0.5);

      // Entrega do BehaviorSubject é assíncrona: drena os microtasks
      // antes de contar as emissões.
      await pumpEventQueue();
      expect(speeds, <double>[1.5, 2.0, 0.5]);
      expect(svc.errorMessage.value, isNull);
    });

    test('padrão é 1.0 e a mudança de estado é broadcast imediato', () async {
      expect(svc.playbackSpeed, 1.0);

      final List<Object?> seen = <Object?>[];
      final sub = svc.playbackState.skip(1).listen(seen.add);
      addTearDown(sub.cancel);

      await svc.setPlaybackSpeed(1.25);
      await pumpEventQueue();
      expect(seen, hasLength(1)); // sem throttle: estado novo emite na hora
    });
  });

  group('persistência no SettingsProvider (3.2)', () {
    test('padrão 1.0; gravar e restaurar em nova sessão', () async {
      final SettingsProvider settings = SettingsProvider();
      await settings.load();
      expect(settings.playbackSpeed, 1.0);

      await settings.setPlaybackSpeed(1.5);
      final SettingsProvider restored = SettingsProvider();
      await restored.load();
      expect(restored.playbackSpeed, 1.5);
    });

    test('valor fora da faixa salvo volta ao normal (1.0)', () async {
      SharedPreferences.setMockInitialValues({'playback_speed': 42.0});
      final SettingsProvider settings = SettingsProvider();
      await settings.load();
      expect(settings.playbackSpeed, 1.0);

      // set fora de faixa também cai no normal.
      await settings.setPlaybackSpeed(9.0);
      expect(settings.playbackSpeed, 1.0);
    });
  });

  group('PlayerProvider (3.2)', () {
    test('delega ao serviço e persiste', () async {
      final SettingsProvider settings = SettingsProvider();
      await settings.load();
      final PlayableAudioService audio = PlayableAudioService();
      final PlayerProvider provider = _provider(audio, settings);
      addTearDown(provider.dispose);
      await provider.init();
      await pumpEventQueue();

      await provider.setPlaybackSpeed(1.25);

      expect(provider.playbackSpeed, 1.25);
      expect(audio.playbackSpeed, 1.25);
      expect(settings.playbackSpeed, 1.25);
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('playback_speed'), 1.25);
    });

    test('velocidade salva volta no boot (construtor aplica no serviço)',
        () async {
      SharedPreferences.setMockInitialValues({'playback_speed': 1.5});
      final SettingsProvider settings = SettingsProvider();
      await settings.load();
      expect(settings.playbackSpeed, 1.5);

      final PlayableAudioService audio = PlayableAudioService();
      final PlayerProvider provider = _provider(audio, settings);
      addTearDown(provider.dispose);
      await provider.init();
      await pumpEventQueue();

      expect(audio.playbackSpeed, 1.5);
      expect(provider.playbackSpeed, 1.5);
    });
  });

  group('seletor no PlayerScreen (3.2)', () {
    testWidgets('menu aplica 1.5x no serviço', (tester) async {
      final PlayableAudioService audio = PlayableAudioService();
      final PlayerProvider provider = _provider(audio, null);
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

      expect(find.byTooltip('Velocidade 1.0x'), findsOneWidget);

      await tester.tap(find.byTooltip('Velocidade 1.0x'));
      await tester.pumpAndSettle();
      expect(find.text('1.5x'), findsOneWidget);

      await tester.tap(find.text('1.5x'));
      await tester.pumpAndSettle();

      expect(provider.playbackSpeed, 1.5);
      expect(audio.playbackSpeed, 1.5);
      // O rótulo do botão passa a mostrar a nova velocidade.
      expect(find.byTooltip('Velocidade 1.5x'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });
  });
}
