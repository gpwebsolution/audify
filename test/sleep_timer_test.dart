// Testes do item 3.1 — timer de sono.
//
// O prazo é um deadline de RELÓGIO DE PAREDE com relógio injetável (sem
// fakeAsync): os testes avançam `now` na mão e chamam checkSleepTimer()
// direto — o mesmo caminho que os listeners de posição/estado percorrem
// em produção. Cobre: dispara com fade + stop, cancela, "ao fim da faixa"
// (sem avançar a fila), stop() cancelando e a retomada com prazo vencido.
// Ao final, um teste de UI monta o PlayerScreen: abre o seletor, agenda
// 15 min, o chip aparece e o cancelamento pelo chip some com ele.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:audify/models/song_model.dart';
import 'package:audify/providers/player_provider.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DateTime now;
  late AudioService svc;

  setUp(() {
    now = DateTime(2026, 1, 1, 22);
    svc = AudioService(clock: () => now);
  });

  tearDown(() async {
    await svc.dispose();
  });

  group('timer de sono por duração (3.1)', () {
    test(
      'dispara quando o relógio passa do prazo (stop + volume 1.0)',
      () async {
        svc.status.value = PlayerStatus.playing;
        svc.startSleepTimer(const Duration(minutes: 15));
        expect(svc.sleepTimerActive, isTrue);
        expect(svc.sleepMode, SleepTimerMode.duration);
        expect(svc.sleepRemaining, const Duration(minutes: 15));

        // 1 minuto antes: nada muda.
        now = now.add(const Duration(minutes: 14));
        expect(await svc.checkSleepTimer(), isFalse);
        expect(svc.sleepTimerActive, isTrue);
        expect(svc.sleepRemaining, const Duration(minutes: 1));

        // Passou do prazo: dispara (fired), limpa e para.
        now = now.add(const Duration(seconds: 61));
        expect(await svc.checkSleepTimer(), isTrue);
        expect(svc.sleepTimerActive, isFalse);
        expect(svc.sleepRemaining, Duration.zero);
        expect(svc.status.value, PlayerStatus.idle);
        expect(svc.volume.value, 1.0);
      },
    );

    test('fade-out linear nos últimos 10s antes do disparo', () async {
      svc.status.value = PlayerStatus.playing;
      svc.startSleepTimer(const Duration(minutes: 15));

      // 5s antes do fim: volume ~0.5 (metade da janela de fade).
      now = now
          .add(const Duration(minutes: 15))
          .subtract(const Duration(seconds: 5));
      expect(await svc.checkSleepTimer(), isFalse);
      expect(svc.sleepTimerActive, isTrue);
      expect(svc.volume.value, closeTo(0.5, 0.02));

      // Venceu: para e restaura o volume para a próxima escuta.
      now = now.add(const Duration(seconds: 5));
      expect(await svc.checkSleepTimer(), isTrue);
      expect(svc.status.value, PlayerStatus.idle);
      expect(svc.volume.value, 1.0);
    });

    test('cancelar desliga o timer sem parar a reprodução', () async {
      svc.status.value = PlayerStatus.playing;
      svc.startSleepTimer(const Duration(minutes: 15));
      svc.cancelSleepTimer();

      expect(svc.sleepTimerActive, isFalse);
      expect(svc.sleepRemaining, Duration.zero);

      // Prazo original já vencido, mas cancelado: nada dispara.
      now = now.add(const Duration(minutes: 30));
      expect(await svc.checkSleepTimer(), isFalse);
      expect(svc.status.value, PlayerStatus.playing);
      expect(svc.volume.value, 1.0);
    });

    test('stop() cancela o timer (regra: stop desliga o sono)', () async {
      svc.status.value = PlayerStatus.playing;
      svc.startSleepTimer(const Duration(minutes: 15));
      await svc.stop();

      expect(svc.sleepTimerActive, isFalse);

      now = now.add(const Duration(minutes: 30));
      expect(await svc.checkSleepTimer(), isFalse);
      expect(svc.status.value, PlayerStatus.idle);
    });

    test('restante segue o relógio de parede mesmo parado', () {
      svc.startSleepTimer(const Duration(minutes: 15));
      expect(svc.sleepRemaining, const Duration(minutes: 15));

      now = now.add(const Duration(minutes: 5));
      expect(svc.sleepRemaining, const Duration(minutes: 10));
    });

    test('retomada com prazo vencido para em vez de voltar a tocar', () async {
      svc.status.value = PlayerStatus.paused;
      svc.startSleepTimer(const Duration(minutes: 10));
      now = now.add(const Duration(minutes: 11));

      await svc.resume();

      expect(svc.status.value, PlayerStatus.idle);
      expect(svc.errorMessage.value, isNull);
      expect(svc.sleepTimerActive, isFalse);
    });
  });

  group('"ao fim da faixa" (3.1)', () {
    test('consome o evento, para e desliga o timer', () async {
      svc.status.value = PlayerStatus.playing;
      svc.startSleepAtTrackEnd();
      expect(svc.sleepTimerActive, isTrue);
      expect(svc.sleepMode, SleepTimerMode.trackEnd);

      // O provider pergunta antes de avançar a fila — `true` = não pule.
      expect(svc.consumeSleepAtTrackEnd(), isTrue);
      await pumpEventQueue();

      expect(svc.status.value, PlayerStatus.idle);
      expect(svc.sleepTimerActive, isFalse);
      // Segunda pergunta (ou timer desligado): não consome nada.
      expect(svc.consumeSleepAtTrackEnd(), isFalse);
    });

    test(
      'com o timer desligado, o fim de faixa segue normal (false)',
      () async {
        svc.status.value = PlayerStatus.playing;
        expect(svc.consumeSleepAtTrackEnd(), isFalse);
        expect(svc.status.value, PlayerStatus.playing);
      },
    );
  });

  group('UI do PlayerScreen (3.1)', () {
    testWidgets('seletor agenda 15 min, chip aparece e cancela', (tester) async {
      final PlayableAudioService audio = PlayableAudioService();
      final PlayerProvider provider = PlayerProvider(
        audio,
        songRepository: _FakeSongRepository(<Song>[_track('apple')]),
        sessionRepository: _FakeSessionRepository(),
      );
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

      // Sem sono agendado: ícone no AppBar, sem chip.
      expect(find.byTooltip('Timer de sono'), findsOneWidget);
      expect(find.textContaining('Dormir'), findsNothing);

      // Abre o seletor: opções de tempo + "ao fim da faixa" (a lista do
      // sheet é lazy — rola para o último item ficar no viewport).
      await tester.tap(find.byTooltip('Timer de sono'));
      await tester.pumpAndSettle();
      expect(find.text('15 minutos'), findsOneWidget);

      await tester.drag(find.byType(ListView).last, const Offset(0, -200));
      await tester.pumpAndSettle();
      expect(find.text('Ao fim da faixa'), findsOneWidget);

      await tester.drag(find.byType(ListView).last, const Offset(0, 200));
      await tester.pumpAndSettle();
      await tester.tap(find.text('15 minutos'));
      await tester.pumpAndSettle();

      expect(provider.sleepTimerActive, isTrue);
      expect(find.textContaining('Dormir em'), findsOneWidget);

      // Cancela pelo chip (X) — o tempo some junto.
      await tester.tap(find.byTooltip('Desligar timer'));
      await tester.pumpAndSettle();
      expect(provider.sleepTimerActive, isFalse);
      expect(find.textContaining('Dormir'), findsNothing);

      await tester.pumpWidget(const SizedBox());
    });
  });
}
