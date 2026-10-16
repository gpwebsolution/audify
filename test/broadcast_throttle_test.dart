// Testes do item 1.10: throttle do broadcast de PlaybackState.
//
// O tick de posição (onPositionChanged, ~5x/s) não precisa reenviar o
// estado a cada atualização: o sistema projeta o cursor a partir de
// updatePosition + updateTime. Aqui verificamos que:
//  - com throttled=true, no máximo 1 broadcast por broadcastInterval;
//  - chamadas SEM throttle (play/pause/seek/modos) passam sempre;
//  - o relógio injetável controla o tempo (sem fakeAsync).

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:audio_service/audio_service.dart' as asvc;

import 'package:audify/services/audio_service.dart';

import 'support/playable_audio_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(mockAudioplayersChannels);

  group('broadcastPlaybackState throttled', () {
    late DateTime now;
    late AudioService svc;

    setUp(() {
      now = DateTime(2026, 1, 1, 12);
      svc = AudioService(clock: () => now);
    });

    tearDown(() async {
      await svc.dispose();
    });

    test('ticks dentro de 1s emitem no máximo 1x', () async {
      final List<asvc.PlaybackState> seen = <asvc.PlaybackState>[];
      final StreamSubscription<asvc.PlaybackState> sub =
          svc.playbackState.skip(1).listen(seen.add);
      addTearDown(sub.cancel);

      // 5 ticks de 200ms (padrão do audioplayers) em 1s.
      for (int i = 0; i < 5; i++) {
        svc.position.value = Duration(milliseconds: 200 * i);
        svc.broadcastPlaybackState(throttled: true);
        now = now.add(const Duration(milliseconds: 200));
      }

      await pumpEventQueue();
      expect(seen, hasLength(1));
      expect(seen.first.updatePosition, Duration.zero,
          reason: 'primeiro tick (t=0) é o emitido');
    });

    test('passou do intervalo: emite de novo', () async {
      final List<asvc.PlaybackState> seen = <asvc.PlaybackState>[];
      final StreamSubscription<asvc.PlaybackState> sub =
          svc.playbackState.skip(1).listen(seen.add);
      addTearDown(sub.cancel);

      svc.broadcastPlaybackState(throttled: true);
      await pumpEventQueue();
      expect(seen, hasLength(1));

      // Ainda dentro do intervalo: suprimido.
      now = now.add(const Duration(milliseconds: 900));
      svc.broadcastPlaybackState(throttled: true);
      await pumpEventQueue();
      expect(seen, hasLength(1));

      // Passou de 1s: emitido.
      now = now.add(const Duration(milliseconds: 200));
      svc.broadcastPlaybackState(throttled: true);
      await pumpEventQueue();
      expect(seen, hasLength(2));
    });

    test('sem throttle (controles) passa mesmo dentro do intervalo',
        () async {
      final List<asvc.PlaybackState> seen = <asvc.PlaybackState>[];
      final StreamSubscription<asvc.PlaybackState> sub =
          svc.playbackState.skip(1).listen(seen.add);
      addTearDown(sub.cancel);

      svc.broadcastPlaybackState(throttled: true);
      // Play/pause/seek/modos logo em seguida: não podem ficar velhos.
      svc.broadcastPlaybackState();
      svc.broadcastPlaybackState();
      svc.broadcastPlaybackState();

      await pumpEventQueue();
      expect(seen, hasLength(4));
    });

    test('broadcast imediato atualiza a janela do throttle', () async {
      final List<asvc.PlaybackState> seen = <asvc.PlaybackState>[];
      final StreamSubscription<asvc.PlaybackState> sub =
          svc.playbackState.skip(1).listen(seen.add);
      addTearDown(sub.cancel);

      svc.broadcastPlaybackState(throttled: true); // t=0: emitido
      svc.broadcastPlaybackState(); // imediato: estado já está fresco
      // Tick logo em seguida: suprimido — o imediato acima já cobriu
      // o mesmo instante (não há estado velho para corrigir).
      svc.broadcastPlaybackState(throttled: true);
      await pumpEventQueue();
      expect(seen, hasLength(2));
    });
  });
}
