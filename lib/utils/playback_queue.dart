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
  ///
  /// Com shuffle ATIVO, a ordem é embaralhada UMA vez
  /// (Fisher-Yates) com a faixa atual no início. A navegação
  /// (próxima/anterior) é sempre LINEAR na ordem da fila —
  /// assim o shuffle percorre toda a lista sem repetir faixa
  /// antes do ciclo acabar, termina com repeat off e "anterior"
  /// volta na mesma ordem embaralhada.
  void rebuild(List<Song> visibleSongs, {Song? keepCurrent}) {
    if (_shuffle) {
      // Mantém a "ordem original" sincronizada com a lista visível
      // para que desativar o shuffle restaure a ordem certa
      // (ex.: após busca).
      _originalOrder = List.of(visibleSongs);
      final List<Song> rest = keepCurrent == null
          ? List.of(visibleSongs)
          : visibleSongs
              .where((Song s) => s.id != keepCurrent.id)
              .toList();
      _fisherYates(rest);
      _queue = <Song>[
        ?keepCurrent,
        ...rest,
      ];
      // A faixa atual lidera a fila embaralhada; se ela não
      // existir mais na lista visível, a fila fica sem seleção
      // (-1) — mesma semântica de antes.
      _queueIndex = keepCurrent == null
          ? (_queue.isEmpty ? -1 : 0)
          : _queue.indexWhere((Song s) => s.id == keepCurrent.id);
      return;
    }
    _queue = List.of(visibleSongs);
    if (keepCurrent != null) {
      final int idx = _queue.indexWhere((Song s) => s.id == keepCurrent.id);
      _queueIndex = idx >= 0 ? idx : -1;
    }
  }

  /// Embaralha [list] no lugar (Fisher-Yates) com o [Random]
  /// injetável — determinístico nos testes.
  void _fisherYates(List<Song> list) {
    for (int i = list.length - 1; i > 0; i--) {
      final int j = _random.nextInt(i + 1);
      if (i == j) continue;
      final Song tmp = list[i];
      list[i] = list[j];
      list[j] = tmp;
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

  /// Índice da próxima faixa conforme repeat, ou null se a fila
  /// termina (repeat off) ou está vazia.
  ///
  /// A navegação é sempre linear na ordem da fila — com shuffle
  /// ativo, a própria fila JÁ está embaralhada (ver [rebuild]),
  /// então "próxima" segue a ordem aleatória sem sortear um novo
  /// índice a cada chamada (o que podia repetir a mesma faixa e
  /// nunca terminar com repeat off).
  int? nextIndex() {
    if (_queue.isEmpty) return null;
    if (_repeat == RepeatMode.one) return _queueIndex;
    if (_queueIndex < _queue.length - 1) return _queueIndex + 1;
    return _repeat == RepeatMode.all ? 0 : null;
  }

  /// Índice da faixa anterior (ou wrap no início), ou null se a
  /// fila tem <= 1.
  ///
  /// Volta na MESMA ordem da fila (embaralhada ou não) — coerente
  /// com [nextIndex], que também é linear.
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

  /// Define o modo de repetição DIRETO (restauração de
  /// preferência persistida — sem ciclar).
  void setRepeat(RepeatMode mode) {
    _repeat = mode;
  }

  /// Remove da fila as faixas com os ids informados (arquivos excluídos do
  /// aparelho) e reencaixa o índice corrente.
  ///
  /// Se a faixa que TOCAVA foi removida, o índice passa a apontar para a
  /// próxima faixa sobrevivente na mesma posição — é o índice que o
  /// PlayerProvider usa para "pular para a próxima". Se nada sobrar, a
  /// fila esvazia (-1).
  ///
  /// Devolve as faixas efetivamente removidas para o caller decidir como
  /// seguir a reprodução.
  List<Song> removeSongs(Set<String> removedIds) {
    if (removedIds.isEmpty || _queue.isEmpty) return const [];

    final List<Song> removed =
        _queue.where((s) => removedIds.contains(s.id)).toList();
    if (removed.isEmpty) return const [];

    final List<Song> before = _queue;
    final int currentIndex = _queueIndex;
    _queue = before.where((s) => !removedIds.contains(s.id)).toList();

    if (_shuffle) {
      // A ordem original também é a fila "de verdade" do shuffle: sem isto
      // a faixa removida voltaria ao desativar o embaralhamento.
      _originalOrder =
          _originalOrder.where((s) => !removedIds.contains(s.id)).toList();
    }

    final Song? current = currentIndex >= 0 && currentIndex < before.length
        ? before[currentIndex]
        : null;

    if (current == null || removedIds.contains(current.id)) {
      // A corrente saiu: herda a posição da antiga, ajustada para a fila
      // encurtada (o sucessor agora ocupa o mesmo índice, salvo no fim).
      _queueIndex = _queue.isEmpty
          ? -1
          : currentIndex < 0
              ? 0
              : currentIndex.clamp(0, _queue.length - 1);
    } else {
      final int idx = _queue.indexWhere((s) => s.id == current.id);
      _queueIndex = idx;
    }
    return removed;
  }
}