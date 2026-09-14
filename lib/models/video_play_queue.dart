import 'dart:math' as math;

import 'package:flutter/material.dart' show IconData, Icons;

import 'video_model.dart';

/// Modos de repetição (mesma semântica do player de música).
enum VideoRepeatMode {
  off('Repetir desligado', Icons.repeat),
  all('Repetir todos', Icons.repeat),
  one('Repetir este vídeo', Icons.repeat_one);

  final String label;
  final IconData icon;

  const VideoRepeatMode(this.label, this.icon);
}

/// Fila de reprodução de vídeos com a lógica de navegação isolada e
/// testável.
///
/// Responsabilidade: decidir QUAL vídeo toca em seguida conforme o modo
/// atual (repetição/aleatório). O player consome [next]/[previous] e faz
/// o resto (seek, pause no fim, replay no modo "uma").
class VideoPlayQueue {
  /// Ordem original (como veio da aba) — restaurada ao desligar aleatório.
  final List<Video> _original;

  /// Ordem ATUAL (embaralhada quando o aleatório está ligado).
  final List<Video> _order;

  final math.Random _random;

  int index;
  VideoRepeatMode repeatMode;
  bool shuffle;

  VideoPlayQueue(
    List<Video> queue, {
    int initialIndex = 0,
    this.repeatMode = VideoRepeatMode.off,
    this.shuffle = false,
    math.Random? random,
  }) : _original = List.of(queue),
       _order = List.of(queue),
       index = queue.isEmpty ? 0 : initialIndex.clamp(0, queue.length - 1),
       _random = random ?? math.Random();

  Video get current => _order[index];
  int get length => _order.length;
  bool get isEmpty => _order.isEmpty;

  /// Ordem atual (cópia defensiva; útil para testes).
  List<Video> get order => List.unmodifiable(_order);

  /// Liga/desliga o aleatório.
  ///
  /// Ligado: embaralha mantendo o vídeo atual em PRIMEIRO (não muda o que
  /// está tocando). Desligado: restaura a ordem original e volta ao vídeo
  /// que estava tocando.
  void setShuffle(bool value) {
    if (shuffle == value || isEmpty) return;
    shuffle = value;
    final Video playing = _order[index];
    if (value) {
      _order.removeAt(index);
      _order.shuffle(_random);
      _order.insert(0, playing);
      index = 0;
    } else {
      _order
        ..clear()
        ..addAll(_original);
      index = _order.indexWhere((v) => v.id == playing.id);
      if (index < 0) index = 0;
    }
  }

  void toggleShuffle() => setShuffle(!shuffle);

  /// Avança para o próximo modo de repetição (desligado -> todos -> uma).
  void cycleRepeat() {
    repeatMode = VideoRepeatMode
        .values[(repeatMode.index + 1) % VideoRepeatMode.values.length];
  }

  /// Próximo vídeo da fila, ou null quando não há (fim da fila sem
  /// repetição — o player pausa no último frame).
  ///
  /// Aleatório ligado: escolhe um índice aleatório, nunca o mesmo vídeo
  /// em sequência. Repetição "todos": volta ao início no fim da fila.
  /// Repetição "uma" é tratada pelo player (replay do mesmo vídeo).
  Video? next() {
    if (isEmpty) return null;
    if (shuffle && length > 1) {
      int next;
      do {
        next = _random.nextInt(length);
      } while (next == index);
      index = next;
      return _order[index];
    }
    if (index + 1 < length) {
      index++;
      return _order[index];
    }
    if (repeatMode == VideoRepeatMode.all) {
      index = 0;
      return _order[0];
    }
    return null;
  }

  /// Vídeo anterior (a regra dos 3s — voltar ao início vs. trocar de
  /// vídeo — é decisão do player, que chama [previous] só para navegar).
  Video? previous() {
    if (isEmpty) return null;
    if (index > 0) {
      index--;
      return _order[index];
    }
    if (repeatMode == VideoRepeatMode.all) {
      index = length - 1;
      return _order[index];
    }
    return null;
  }
}
