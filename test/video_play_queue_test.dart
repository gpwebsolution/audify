import 'dart:math' as math;

import 'package:audify/models/video_model.dart';
import 'package:audify/models/video_play_queue.dart';
import 'package:flutter_test/flutter_test.dart';

Video _video(int id) => Video(
  id: id,
  title: 'Video $id',
  displayName: 'Video $id.mp4',
  duration: const Duration(minutes: 2),
  path: '/storage/emulated/0/Movies/v$id.mp4',
  size: 1024,
  dateAdded: id,
);

void main() {
  List<Video> queue(int n) => List.generate(n, _video);

  group('VideoPlayQueue', () {
    test('next() avança na ordem e current acompanha', () {
      final q = VideoPlayQueue(queue(3), initialIndex: 0);
      expect(q.current.id, 0);
      expect(q.next()!.id, 1);
      expect(q.index, 1);
      expect(q.current.id, 1);
      expect(q.next()!.id, 2);
      expect(q.index, 2);
    });

    test('next() retorna null no fim da fila sem repetição', () {
      final q = VideoPlayQueue(queue(2), initialIndex: 1);
      expect(q.next(), isNull);
      expect(q.index, 1);
    });

    test('next() volta ao início com repetição "todos"', () {
      final q = VideoPlayQueue(
        queue(2),
        initialIndex: 1,
        repeatMode: VideoRepeatMode.all,
      );
      expect(q.next()!.id, 0);
      expect(q.index, 0);
      expect(q.next()!.id, 1);
    });

    test('previous() volta um; com repetição "todos" dá a volta', () {
      final q = VideoPlayQueue(queue(3), initialIndex: 2);
      expect(q.previous()!.id, 1);
      expect(q.previous()!.id, 0);
      expect(q.previous(), isNull);

      final all = VideoPlayQueue(
        queue(3),
        initialIndex: 0,
        repeatMode: VideoRepeatMode.all,
      );
      expect(all.previous()!.id, 2);
    });

    test('cycleRepeat() percorre off -> todos -> uma -> off', () {
      final q = VideoPlayQueue(queue(1));
      expect(q.repeatMode, VideoRepeatMode.off);
      q.cycleRepeat();
      expect(q.repeatMode, VideoRepeatMode.all);
      q.cycleRepeat();
      expect(q.repeatMode, VideoRepeatMode.one);
      q.cycleRepeat();
      expect(q.repeatMode, VideoRepeatMode.off);
    });

    test('shuffle mantém o vídeo atual em primeiro', () {
      final q = VideoPlayQueue(queue(5), initialIndex: 2);
      q.setShuffle(true);
      expect(q.shuffle, isTrue);
      expect(q.index, 0);
      expect(q.current.id, 2);
      expect(q.length, 5);
    });

    test('desligar shuffle restaura a ordem original e o vídeo tocando', () {
      final q = VideoPlayQueue(queue(5), initialIndex: 2);
      q.setShuffle(true);
      final Video playing = q.next()!;
      final int playingId = playing.id;
      q.setShuffle(false);
      expect(q.shuffle, isFalse);
      expect(q.current.id, playingId);
      expect([for (final v in q.order) v.id], [0, 1, 2, 3, 4]);
    });

    test('shuffle ligado: next() nunca repete o mesmo vídeo em sequência', () {
      final q = VideoPlayQueue(
        queue(4),
        initialIndex: 0,
        shuffle: true,
        random: math.Random(42),
      );
      int previousId = q.current.id;
      for (var i = 0; i < 20; i++) {
        final next = q.next()!;
        expect(next.id, isNot(previousId));
        previousId = next.id;
      }
    });

    test('setShuffle é idempotente e ignora fila vazia', () {
      final empty = VideoPlayQueue(const []);
      empty.setShuffle(true);
      expect(empty.shuffle, isFalse);
      expect(empty.next(), isNull);

      final q = VideoPlayQueue(queue(3));
      q.setShuffle(true);
      q.setShuffle(true);
      expect(q.shuffle, isTrue);
    });

    // Excluir um vídeo não pode deixá-lo na fila: o player abriria um
    // arquivo morto ao avançar.
    group('removeVideos', () {
      test('remove o vídeo da fila e reencaixa o índice', () {
        final q = VideoPlayQueue(queue(4), initialIndex: 1);
        final removed = q.removeVideos(<int>{2});

        expect(removed.single.id, 2);
        expect(q.length, 3);
        expect(q.order.map((v) => v.id), isNot(contains(2)));
        // O corrente (id 1) sobreviveu e continua na mesma posição.
        expect(q.current.id, 1);
        expect(q.index, 1);
      });

      test('vídeo removido não volta ao desligar o aleatório', () {
        final q = VideoPlayQueue(queue(4), initialIndex: 0);
        q.setShuffle(true);
        q.removeVideos(<int>{3});

        q.setShuffle(false);
        expect(q.order.map((Video v) => v.id), isNot(contains(3)));
        expect(q.length, 3);
      });

      test('remove o que tocava e herda a posição do sucessor', () {
        final q = VideoPlayQueue(queue(4), initialIndex: 2);
        q.removeVideos(<int>{2});

        expect(q.length, 3);
        // Índice 2 agora é o id 3, que ocupa a posição do removido — e sendo
        // o último da fila, não há sucessor seguinte.
        expect(q.current.id, 3);
        expect(q.index, 2);
        expect(q.next(), isNull);
      });
      test('esvaziar a fila deixa o índice em zero e next() nulo', () {
        final q = VideoPlayQueue(queue(2), initialIndex: 0);
        q.removeVideos(<int>{0, 1});

        expect(q.length, 0);
        expect(q.isEmpty, isTrue);
        expect(q.index, 0);
        expect(q.next(), isNull);
      });

      test('ids sem correspondência não alteram a fila', () {
        final q = VideoPlayQueue(queue(3), initialIndex: 1);
        expect(q.removeVideos(<int>{99}), isEmpty);
        expect(q.length, 3);
        expect(q.current.id, 1);

        expect(q.removeVideos(<int>{}), isEmpty);
        expect(q.length, 3);
      });
    });
  });
}
