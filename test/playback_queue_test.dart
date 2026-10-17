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
      // A faixa atual continua na fila (no início da embaralhada).
      expect(queue.current, _song(1));
      expect(queue.queueIndex, 0);
    });

    test('desativar shuffle restaura a ordem original', () {
      final PlaybackQueue queue = PlaybackQueue(random: Random(7));
      final List<Song> original = _threeSongs();
      queue.setQueue(original, 0);
      queue.toggleShuffle();
      final List<Song> shuffled = List.of(queue.queue);
      // É uma permutação da original (mesmas faixas).
      expect(shuffled.length, original.length);
      for (final Song s in original) {
        expect(shuffled.contains(s), isTrue);
      }

      queue.toggleShuffle();
      expect(queue.shuffle, isFalse);
      expect(queue.queue, original);
      expect(queue.current, _song(1));
    });

    test('shuffle: percorre TODAS as faixas antes de repetir '
        '(repeat off)', () {
      final PlaybackQueue queue = PlaybackQueue(random: Random(42));
      final List<Song> songs = List.generate(10, _song);
      queue.setQueue(songs, 0);
      queue.toggleShuffle();

      final List<Song> visited = <Song>[queue.current!];
      int? next = queue.nextIndex();
      while (next != null) {
        queue.setIndex(next);
        visited.add(queue.current!);
        next = queue.nextIndex();
      }

      // Termina com repeat off...
      expect(next, isNull);
      // ...após tocar cada faixa EXATAMENTE uma vez:
      // sem repetição consecutiva nem faixa pulada.
      expect(visited.length, songs.length);
      expect(visited.toSet().length, songs.length);
      // A faixa que tocava permanece no início da ordem.
      expect(visited.first, songs.first);
    });

    test('shuffle: próxima nunca repete a faixa consecutiva '
        '(repeat all)', () {
      final PlaybackQueue queue = PlaybackQueue(random: Random(123));
      final List<Song> songs = List.generate(8, _song);
      queue.setQueue(songs, 0);
      queue.toggleShuffle();
      queue.cycleRepeat(); // off -> all (wrap no fim)

      Song? previous;
      final Set<String> seenInCycle = <String>{};
      // Um ciclo completo = uma passada por todas as faixas.
      for (int step = 0; step < songs.length; step++) {
        final int? next = queue.nextIndex();
        expect(next, isNotNull);
        queue.setIndex(next!);
        final Song current = queue.current!;
        expect(current.id, isNot(equals(previous?.id)));
        seenInCycle.add(current.id);
        previous = current;
      }
      // O ciclo cobriu a fila inteira sem pular ninguém.
      expect(seenInCycle.length, songs.length);
    });

    test('shuffle: anterior volta na mesma ordem embaralhada', () {
      final PlaybackQueue queue = PlaybackQueue(random: Random(42));
      final List<Song> songs = List.generate(6, _song);
      queue.setQueue(songs, 0);
      queue.toggleShuffle();

      final List<Song> order = List.of(queue.queue);
      // Do fim até o início: "anterior" desfaz exatamente
      // a ordem que "próxima" faria.
      queue.setIndex(order.length - 1);
      for (int i = order.length - 2; i >= 0; i--) {
        expect(queue.previousIndex(), i);
        queue.setIndex(i);
      }
      expect(queue.current, order.first);
    });

    test('rebuild reencaixa keepCurrent na nova fila', () {
      final PlaybackQueue queue = PlaybackQueue();
      queue.setQueue(_threeSongs(), 1);
      queue.rebuild([_song(4), _song(1), _song(2)], keepCurrent: _song(2));
      expect(queue.current, _song(2));
      expect(queue.queueIndex, 2);
    });

    test('rebuild com shuffle coloca a faixa atual no início', () {
      final PlaybackQueue queue = PlaybackQueue(random: Random(5));
      queue.setQueue(_threeSongs(), 1);
      queue.toggleShuffle(); // atual = faixa 2 no início

      queue.rebuild([_song(4), _song(1), _song(2)], keepCurrent: _song(2));

      expect(queue.queueIndex, 0);
      expect(queue.current, _song(2));
      // As demais vêm atrás, todas presentes.
      expect(queue.queue.length, 3);
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

  group('PlaybackQueue — edição da fila (3.5)', () {
    test('insertNext entra logo após a corrente e ela não sai do lugar', () {
      final PlaybackQueue queue = PlaybackQueue();
      queue.setQueue(_threeSongs(), 1);
      final bool changed = queue.insertNext(<Song>[_song(4)]);

      expect(changed, isTrue);
      expect(
        queue.queue,
        <Song>[_song(1), _song(2), _song(4), _song(3)],
      );
      expect(queue.queueIndex, 1);
      expect(queue.current, _song(2));
    });

    test('insertNext sem faixa corrente entra no início (índice -1 segue)', () {
      final PlaybackQueue queue = PlaybackQueue();
      final bool changed = queue.insertNext(<Song>[_song(1), _song(2)]);

      expect(changed, isTrue);
      expect(queue.queue, <Song>[_song(1), _song(2)]);
      expect(queue.queueIndex, -1);
      expect(queue.current, isNull);
    });

    test('insertNext de faixa já presente a MOVE (nunca duplica)', () {
      final PlaybackQueue queue = PlaybackQueue();
      queue.setQueue(_threeSongs(), 0);

      final bool changed = queue.insertNext(<Song>[_song(3)]);

      expect(changed, isTrue);
      expect(queue.queue, <Song>[_song(1), _song(3), _song(2)]);
      expect(queue.queue.map((Song s) => s.id).toSet().length, 3);
    });

    test('insertNext de lote preserva a ordem dada e ignora a corrente', () {
      final PlaybackQueue queue = PlaybackQueue();
      queue.setQueue(_threeSongs(), 0);

      // A corrente (_song(1)) no lote é ignorada; _song(2) já estava
      // logo após e entra no BLOCO na ordem do lote (4, 2, 5), nunca
      // em dobro.
      final bool changed =
          queue.insertNext(<Song>[_song(4), _song(1), _song(2), _song(5)]);

      // _song(2) já estava logo após a corrente: entra no BLOCO na
      // ordem do lote (4, 2, 5), nunca em dobro; a corrente não sai.
      expect(changed, isTrue);
      expect(
        queue.queue,
        <Song>[_song(1), _song(4), _song(2), _song(5), _song(3)],
      );
      expect(queue.queueIndex, 0);
    });

    test('insertNext sem mudança real devolve false', () {
      final PlaybackQueue queue = PlaybackQueue();
      queue.setQueue(_threeSongs(), 0);

      // A faixa 2 já é exatamente a próxima.
      expect(queue.insertNext(<Song>[_song(2)]), isFalse);
      // A própria corrente no lote também não muda nada.
      expect(queue.insertNext(<Song>[_song(1)]), isFalse);
      expect(queue.queue, _threeSongs());
      expect(queue.queueIndex, 0);
    });

    test('append põe no fim e ignora o que já está na fila', () {
      final PlaybackQueue queue = PlaybackQueue();
      queue.setQueue(_threeSongs(), 1);

      expect(queue.append(<Song>[_song(4)]), isTrue);
      expect(queue.queue.last, _song(4));
      expect(queue.append(<Song>[_song(2)]), isFalse); // já presente
      expect(queue.append(<Song>[_song(4)]), isFalse); // já entrou
      expect(queue.queue.length, 4);
      expect(queue.current, _song(2)); // append não desloca a corrente
      expect(queue.queueIndex, 1);
    });

    test('append com shuffle: desligar o embaralhamento mantém a nova', () {
      final PlaybackQueue queue = PlaybackQueue(random: Random(11));
      queue.setQueue(_threeSongs(), 0);
      queue.toggleShuffle();

      expect(queue.append(<Song>[_song(4)]), isTrue);
      queue.toggleShuffle(); // desativa -> restaura a ordem original

      expect(queue.queue.length, 4);
      expect(queue.queue.contains(_song(4)), isTrue);
      expect(queue.queue.contains(_song(1)), isTrue);
    });

    test('move de outro item desloca o índice da corrente junto', () {
      final PlaybackQueue queue = PlaybackQueue();
      queue.setQueue(_threeSongs(), 1); // corrente = faixa 2

      expect(queue.move(0, 2), isTrue);
      expect(queue.queue, <Song>[_song(2), _song(3), _song(1)]);
      expect(queue.queueIndex, 0);
      expect(queue.current, _song(2));
    });

    test('move da própria corrente a leva para a posição final', () {
      final PlaybackQueue queue = PlaybackQueue();
      queue.setQueue(_threeSongs(), 0); // corrente = faixa 1

      expect(queue.move(0, 2), isTrue);
      expect(queue.queue, <Song>[_song(2), _song(3), _song(1)]);
      expect(queue.queueIndex, 2);
      expect(queue.current, _song(1));
    });

    test('move com índices inválidos ou iguais devolve false', () {
      final PlaybackQueue queue = PlaybackQueue();
      queue.setQueue(_threeSongs(), 0);

      expect(queue.move(-1, 0), isFalse);
      expect(queue.move(0, 3), isFalse);
      expect(queue.move(2, 2), isFalse);
      expect(queue.queue, _threeSongs());
      expect(queue.queueIndex, 0);
    });

    test('removeAt devolve a faixa e o sucessor assume a posição', () {
      final PlaybackQueue queue = PlaybackQueue();
      queue.setQueue(_threeSongs(), 0);

      final Song? removed = queue.removeAt(0);

      expect(removed, _song(1));
      expect(queue.queue, <Song>[_song(2), _song(3)]);
      expect(queue.queueIndex, 0);
      expect(queue.current, _song(2));
    });

    test('removeAt da corrente no fim aponta o anterior', () {
      final PlaybackQueue queue = PlaybackQueue();
      queue.setQueue(_threeSongs(), 2);

      final Song? removed = queue.removeAt(2);

      expect(removed, _song(3));
      expect(queue.queueIndex, 1);
      expect(queue.current, _song(2));
    });

    test('removeAt fora de faixa devolve null e não muda nada', () {
      final PlaybackQueue queue = PlaybackQueue();
      queue.setQueue(_threeSongs(), 1);

      expect(queue.removeAt(-1), isNull);
      expect(queue.removeAt(3), isNull);
      expect(queue.queue, _threeSongs());
      expect(queue.queueIndex, 1);
    });

    test('removeAt com shuffle não ressuscita a faixa ao desativar', () {
      final PlaybackQueue queue = PlaybackQueue(random: Random(7));
      queue.setQueue(_threeSongs(), 0);
      queue.toggleShuffle();

      final Song removed = queue.removeAt(0)!;
      queue.toggleShuffle(); // desativa -> restaura a ordem original

      expect(queue.queue.contains(removed), isFalse);
      expect(queue.queue.length, 2);
    });

    test('edições convivem com repeat (nextIndex coerente)', () {
      final PlaybackQueue queue = PlaybackQueue();
      queue.setQueue(_threeSongs(), 2);
      queue.cycleRepeat(); // all: próxima do fim volta ao início

      queue.insertNext(<Song>[_song(4)]);
      expect(queue.nextIndex(), 3); // a nova é a próxima da corrente

      // removeAt da própria corrente: o sucessor ocupa o lugar e o
      // repeat all continua embrulhando a partir dele.
      queue.removeAt(2);
      expect(queue.current, _song(4));
      expect(queue.nextIndex(), 0);

      queue.cycleRepeat(); // one: repete a corrente
      expect(queue.nextIndex(), 2);
    });
  });
}
