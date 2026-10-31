// Testes da decisão de pausa ao desconectar fones (becoming noisy).
// A lógica é uma função pura em AudioService.shouldPauseOnNoisy:
// sem plugins, sem estado — testável diretamente no VM.

import 'package:flutter_test/flutter_test.dart';

import 'package:audify/services/audio_service.dart';

void main() {
  group('shouldPauseOnNoisy (decisão pura)', () {
    test('pausa quando está tocando e a preferência está ligada', () {
      expect(
        AudioService.shouldPauseOnNoisy(isPlaying: true, settingEnabled: true),
        isTrue,
      );
    });

    test('não pausa quando está pausado (nada tocando)', () {
      expect(
        AudioService.shouldPauseOnNoisy(isPlaying: false, settingEnabled: true),
        isFalse,
      );
    });

    test('não pausa quando o usuário desligou a preferência', () {
      expect(
        AudioService.shouldPauseOnNoisy(isPlaying: true, settingEnabled: false),
        isFalse,
      );
    });

    test('não pausa quando nem toca nem a preferência está ligada', () {
      expect(
        AudioService.shouldPauseOnNoisy(
          isPlaying: false,
          settingEnabled: false,
        ),
        isFalse,
      );
    });
  });
}
