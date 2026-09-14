// Testes unitários da fila de reprodução (PlaybackQueue) — lógica pura de
// navegação: próxima/anterior, repeat (off/all/one) e shuffle. Sem plugins.

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'package:audify/models/repeat_mode.dart';
import 'package:audify/models/song_model.dart';
import 'package:audify/utils/playback_queue.dart';

Song _song(int n) => Song.fromAsset(assetPath: 'assets/songs/faixa_$n.mp3');

List<Song> _threeSongs() => [_song(1), _song(2), _song(3)];

void main() {
  group('PlaybackQueue — fila básica', () {
    test('fila vazia: next/previous retornam null e current é null', () {
      final PlaybackQueue queue = PlaybackQueue();
      expect(queue.current, isNull);
      expect(queue.nextIndex(), isNull);
      expect(queue.previousIndex(), isNull);
    });

    test('setQueue com startIndex inválido clamp para 0', () {
      final PlaybackQueue queue = PlaybackQueue();
      queue.setQueue(_threeSongs(), 99);
      expect(queue.current, _song(1));

      queue.setQueue(_threeSongs(), -3);
      expect(queue.current, _song(1));
    });

    test('setQueue com lista vazia deixa índice -1', () {
      final PlaybackQueue queue = PlaybackQueue();
      queue.setQueue(const [], 0);
      expect(queue.current, isNull);
      expect(queue.isEmpty, isTrue);
    });

    test('current reflete o índice atual', () {
      final PlaybackQueue queue = PlaybackQueue();
      queue.setQueue(_threeSongs(), 1);
      expect(queue.current, _song(2));
    });
  });

  group('PlaybackQueue — repeat off', () {
    test('avança até o fim e para (next null)', () {
      final PlaybackQueue queue = PlaybackQueue();
      queue.setQueue(_threeSongs(), 0);
      expect(queue.nextIndex(), 1);
      queue.setIndex(1);
      expect(queue.nextIndex(), 2);
      queue.setIndex(2);
      expect(queue.nextIndex(), isNull);
    });

    test('previous wrapa no início', () {
      final PlaybackQueue queue = PlaybackQueue();
      queue.setQueue(_threeSongs(), 0);
      expect(queue.previousIndex(), 2);
    });

    test('fila de 1 faixa: previous null (sem wrap)', () {
      final PlaybackQueue queue = PlaybackQueue();
      queue.setQueue([_song(1)], 0);
      expect(queue.previousIndex(), isNull);
      expect(queue.nextIndex(), isNull);
    });
  });

  group('PlaybackQueue — repeat all/one', () {
    test('repeat all: após o fim volta ao início', () {
      final PlaybackQueue queue = PlaybackQueue();
      queue.setQueue(_threeSongs(), 2);
      queue.cycleRepeat(); // off -> all
      expect(queue.repeat, RepeatMode.all);
      expect(queue.nextIndex(), 0);
    });

    test('repeat one: next sempre retorna a mesma faixa', () {
      final PlaybackQueue queue = PlaybackQueue();
      queue.setQueue(_threeSongs(), 1);
      queue.cycleRepeat(); // off -> all
      queue.cycleRepeat(); // all -> one
      expect(queue.repeat, RepeatMode.one);
      expect(queue.nextIndex(), 1);
    });

    test('cycleRepeat cicla off -> all -> one -> off', () {
      final PlaybackQueue queue = PlaybackQueue();
      expect(queue.repeat, RepeatMode.off);
      queue.cycleRepeat();
      expect(queue.repeat, RepeatMode.all);
      queue.cycleRepeat();
      expect(queue.repeat, RepeatMode.one);
      queue.cycleRepeat();
      expect(queue.repeat, RepeatMode.off);
    });
  });

  group('PlaybackQueue — shuffle', () {
    test('toggleShuffle embaralha mantendo a faixa atual', () {
      final PlaybackQueue queue = PlaybackQueue(random: Random(42));
      queue.setQueue(_threeSongs(), 0);
      queue.toggleShuffle();
      expect(queue.shuffle, isTrue);
      // A faixa atual continua na fila (possivelmente em outra posição).
      expect(queue.current, _song(1));
    });

    test('desativar shuffle restaura a ordem original', () {
      final PlaybackQueue queue = PlaybackQueue(random: Random(7));
      final List<Song> original = _threeSongs();
      queue.setQueue(original, 0);
      queue.toggleShuffle();
      final List<Song> shuffled = List.of(queue.queue);
      expect(shuffled, isNot(equals(original)));

      queue.toggleShuffle();
      expect(queue.shuffle, isFalse);
      expect(queue.queue, original);
      expect(queue.current, _song(1));
    });

    test('rebuild reencaixa keepCurrent na nova fila', () {
      final PlaybackQueue queue = PlaybackQueue();
      queue.setQueue(_threeSongs(), 1);
      queue.rebuild([_song(4), _song(1), _song(2)], keepCurrent: _song(2));
      expect(queue.current, _song(2));
      expect(queue.queueIndex, 2);
    });

    test('rebuild sem keepCurrent mantém índice anterior', () {
      final PlaybackQueue queue = PlaybackQueue();
      queue.setQueue(_threeSongs(), 0);
      queue.rebuild([_song(9)]);
      expect(queue.queueIndex, 0);
      expect(queue.current, _song(9));
    });
  });
}