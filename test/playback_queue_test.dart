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

  group('PlaybackQueue — remoção de faixa excluída', () {
    test('removeSongs tira a faixa da fila e devolve o que saiu', () {
      final PlaybackQueue queue = PlaybackQueue();
      queue.setQueue(_threeSongs(), 0);

      final List<Song> removed = queue.removeSongs(<String>{_song(2).id});

      expect(removed.single, _song(2));
      expect(queue.queue.length, 2);
      expect(queue.queue.contains(_song(2)), isFalse);
    });

    test('nada é removido para id desconhecido', () {
      final PlaybackQueue queue = PlaybackQueue();
      queue.setQueue(_threeSongs(), 0);

      final List<Song> removed = queue.removeSongs(<String>{'inexistente'});

      expect(removed, isEmpty);
      expect(queue.queue.length, 3);
      expect(queue.queueIndex, 0);
    });

    test('ids vazios não alteram a fila', () {
      final PlaybackQueue queue = PlaybackQueue();
      queue.setQueue(_threeSongs(), 2);

      expect(queue.removeSongs(<String>{}), isEmpty);
      expect(queue.queue.length, 3);
      expect(queue.queueIndex, 2);
    });

    test('remoção de faixa QUE NÃO TOCAVA mantém a corrente', () {
      final PlaybackQueue queue = PlaybackQueue();
      queue.setQueue(_threeSongs(), 1);
      expect(queue.current, _song(2));

      queue.removeSongs(<String>{_song(3).id});

      expect(queue.current, _song(2));
      expect(queue.queueIndex, 1);
    });

    test('remoção da faixa corrente avança para a próxima sobrevivente', () {
      final PlaybackQueue queue = PlaybackQueue();
      queue.setQueue(_threeSongs(), 0);

      queue.removeSongs(<String>{_song(1).id});

      // A posição 0 agora é a faixa 2 — é dela que a reprodução segue.
      expect(queue.queueIndex, 0);
      expect(queue.current, _song(2));
    });

    test('remoção da ÚLTIMA faixa com corrente no fim fica no índice válido',
        () {
      final PlaybackQueue queue = PlaybackQueue();
      queue.setQueue(_threeSongs(), 2);
      expect(queue.current, _song(3));

      queue.removeSongs(<String>{_song(3).id});

      expect(queue.queueIndex, 1);
      expect(queue.current, _song(2));
    });

    test('remover todas as faixas esvazia a fila', () {
      final PlaybackQueue queue = PlaybackQueue();
      queue.setQueue(_threeSongs(), 1);

      queue.removeSongs(<String>{_song(1).id, _song(2).id, _song(3).id});

      expect(queue.isEmpty, isTrue);
      expect(queue.queueIndex, -1);
      expect(queue.current, isNull);
      expect(queue.nextIndex(), isNull);
    });

    test('remoção em lote tira todas de uma vez', () {
      final PlaybackQueue queue = PlaybackQueue();
      queue.setQueue(_threeSongs(), 0);

      final List<Song> removed = queue.removeSongs(<String>{
        _song(1).id,
        _song(3).id,
      });

      expect(removed.length, 2);
      expect(queue.queue.single, _song(2));
      expect(queue.current, _song(2));
    });

    test('com shuffle a faixa removida não volta ao desativar', () {
      final PlaybackQueue queue = PlaybackQueue(random: Random(7));
      queue.setQueue(_threeSongs(), 0);
      queue.toggleShuffle(); // ativa

      queue.removeSongs(<String>{_song(1).id});
      queue.toggleShuffle(); // desativa -> restaura a ordem original

      expect(queue.queue.contains(_song(1)), isFalse);
      expect(queue.queue.length, 2);
    });
  });
}
