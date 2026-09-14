import 'dart:math';

import '../models/repeat_mode.dart';
import '../models/song_model.dart';

/// Fila de reprodução pura (sem plugins): ordem, shuffle, repeat e
/// navegação. Lógica 100% testável em unidade — sem dependência de áudio.
///
/// O [PlayerProvider] delega a navegação da fila a esta classe; a UI e o
/// serviço de áudio nunca a tocam diretamente.
class PlaybackQueue {
  PlaybackQueue({Random? random}) : _random = random ?? Random();

  final Random _random;

  /// Fila atual (ordem visível, respeitando shuffle).
  List<Song> _queue = const [];

  /// Índice da faixa corrente na fila (-1 = nada selecionado).
  int _queueIndex = -1;

  /// Modo de repetição ativo.
  RepeatMode _repeat = RepeatMode.off;

  /// Embaralhamento ativo (a ordem visível fica aleatória).
  bool _shuffle = false;

  /// Ordem original (sem shuffle) capturada ao ativar o embaralhamento —
  /// permite restaurar a ordem ao desativar.
  List<Song> _originalOrder = const [];

  List<Song> get queue => _queue;

  int get queueIndex => _queueIndex;

  RepeatMode get repeat => _repeat;

  bool get shuffle => _shuffle;

  bool get isEmpty => _queue.isEmpty;

  Song? get current =>
      (_queueIndex >= 0 && _queueIndex < _queue.length)
          ? _queue[_queueIndex]
          : null;

  /// Reconstrói a fila a partir da lista visível (respeita shuffle) e
  /// reencaixa a faixa [keepCurrent] na nova posição, se existir.
  void rebuild(List<Song> visibleSongs, {Song? keepCurrent}) {
    if (_shuffle) {
      // Mantém a "ordem original" sincronizada com a lista visível para
      // que desativar o shuffle restaure a ordem certa (ex.: após busca).
      _originalOrder = List.of(visibleSongs);
    }
    final List<Song> ordered = List.of(visibleSongs);
    if (_shuffle) ordered.shuffle(_random);
    _queue = ordered;
    if (keepCurrent != null) {
      final int idx = _queue.indexWhere((s) => s.id == keepCurrent.id);
      _queueIndex = idx >= 0 ? idx : -1;
    }
  }

  /// Substitui a fila inteira (ex.: playlist do usuário) começando em
  /// [startIndex] (clampado ao tamanho válido).
  void setQueue(List<Song> songs, int startIndex) {
    _queue = List.of(songs);
    _queueIndex = (startIndex < 0 || startIndex >= _queue.length)
        ? (songs.isEmpty ? -1 : 0)
        : startIndex;
  }

  void setIndex(int index) {
    if (index >= 0 && index < _queue.length) _queueIndex = index;
  }

  /// Índice da próxima faixa conforme repeat/shuffle, ou null se a fila
  /// termina (repeat off) ou está vazia.
  int? nextIndex() {
    if (_queue.isEmpty) return null;
    if (_repeat == RepeatMode.one) return _queueIndex;
    if (_shuffle) return _random.nextInt(_queue.length);
    if (_queueIndex >= _queue.length - 1) {
      return _repeat == RepeatMode.all ? 0 : null;
    }
    return _queueIndex + 1;
  }

  /// Índice da faixa anterior (com wrap), ou null se a fila tem <= 1.
  int? previousIndex() {
    if (_queue.length <= 1) return null;
    return (_queueIndex - 1 + _queue.length) % _queue.length;
  }

  /// Alterna shuffle: ativar reembaralha mantendo a faixa atual; desativar
  /// restaura a ordem original capturada no momento da ativação.
  void toggleShuffle() {
    if (_shuffle) {
      // Desativando: restaura a ordem original, reencaixando a faixa atual.
      final Song? keep = current;
      _shuffle = false;
      _queue = List.of(_originalOrder);
      _originalOrder = const [];
      if (keep != null) {
        final int idx = _queue.indexWhere((s) => s.id == keep.id);
        _queueIndex = idx >= 0 ? idx : -1;
      }
    } else {
      // Ativando: captura a ordem atual como original e embaralha.
      _originalOrder = List.of(_queue);
      final Song? keep = current;
      _shuffle = true;
      rebuild(_queue, keepCurrent: keep);
    }
  }

  /// Cicla o modo de repetição: off -> all -> one -> off.
  void cycleRepeat() {
    _repeat = switch (_repeat) {
      RepeatMode.off => RepeatMode.all,
      RepeatMode.all => RepeatMode.one,
      RepeatMode.one => RepeatMode.off,
    };
  }
}