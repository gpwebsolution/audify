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
    if (_shuffle) {
      // Sem isto, "desligar o shuffle" restauraria a ordem original
      // de UMA SESSÃO ANTERIOR (ou a vazia, numa fila restaurada do
      // disco) — a nova fila passa a ser a referência.
      _originalOrder = List.of(songs);
    }
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

  // ------------------------------------------------------------------
  // Item 3.5 — edição da fila (folha "Fila", "Tocar a seguir" e
  // "Adicionar à fila").
  //
  // Sem DUPLICATAS por contrato: ids são usados por todo o app
  // (sessão, gapless, `indexWhere` do índice corrente), então um id
  // já presente é MOVIDO (insertNext) ou ignorado (append) — nunca
  // entra em dobro. Com shuffle ativo a edição vale na ordem
  // embaralhada; a ordem original só acompanha a COMPOSIÇÃO (membros
  // novos entram no fim, remoções saem) — mover não muda composição,
  // então ao desligar o embaralhamento o usuário vê a ordem original
  // com a mesma lista de faixas.
  // ------------------------------------------------------------------

  /// Insere [songs] logo APÓS a faixa corrente ("Tocar a seguir"), na
  /// ordem dada (lote da seleção em lote chega inteiro aqui). Faixas já
  /// presentes são MOVIDAS para o bloco; a faixa corrente nunca sai do
  /// lugar (é ignorada no lote). Sem faixa corrente, entra no início.
  /// Retorna false quando nada muda (fila já nessa ordem).
  bool insertNext(List<Song> songs) {
    final Song? keep = current;
    final List<Song> incoming = <Song>[];
    for (final Song song in songs) {
      if (keep != null && song.id == keep.id) continue;
      if (!incoming.any((Song s) => s.id == song.id)) incoming.add(song);
    }
    if (incoming.isEmpty) return false;
    final List<String> before = <String>[for (final Song s in _queue) s.id];

    _queue = _queue
        .where((Song s) => !incoming.any((Song x) => x.id == s.id))
        .toList();
    if (keep != null) {
      // Sem duplicatas a rebusca é exata; o índice acompanha a remoção
      // de itens que estavam ANTES da corrente.
      _queueIndex = _queue.indexWhere((Song s) => s.id == keep.id);
    }
    final int insertAt = keep == null ? 0 : _queueIndex + 1;
    _queue.insertAll(insertAt, incoming);
    if (_shuffle) {
      for (final Song song in incoming) {
        if (!_originalOrder.any((Song s) => s.id == song.id)) {
          _originalOrder = <Song>[..._originalOrder, song];
        }
      }
    }
    final List<String> after = <String>[for (final Song s in _queue) s.id];
    return !_sameIds(before, after);
  }

  /// Acrescenta [songs] ao FIM da fila ("Adicionar à fila"). Faixas já
  /// presentes são ignoradas (sem duplicatas). Retorna true se algo entrou.
  bool append(List<Song> songs) {
    final List<Song> fresh = <Song>[];
    for (final Song song in songs) {
      if (fresh.any((Song s) => s.id == song.id)) continue;
      if (_queue.any((Song s) => s.id == song.id)) continue;
      fresh.add(song);
    }
    if (fresh.isEmpty) return false;
    _queue = <Song>[..._queue, ...fresh];
    if (_shuffle) _originalOrder = <Song>[..._originalOrder, ...fresh];
    return true;
  }

  /// Move o item de [from] para [to], onde [to] é a posição FINAL do
  /// item na lista resultante (sem o +1 do ReorderableListView — quem
  /// chama converte). A faixa corrente acompanha o movimento (o player
  /// não pode trocar de faixa só por arrastar). Retorna false se os
  /// índices forem inválidos ou iguais.
  bool move(int from, int to) {
    if (from < 0 || from >= _queue.length) return false;
    if (to < 0 || to >= _queue.length) return false;
    if (from == to) return false;
    final Song? keep = current;
    final Song song = _queue.removeAt(from);
    _queue.insert(to, song);
    if (keep != null) {
      _queueIndex = _queue.indexWhere((Song s) => s.id == keep.id);
    }
    return true;
  }

  /// Remove e devolve o item em [index] (null se fora de faixa). Se era
  /// a faixa corrente, a próxima sobrevivente na MESMA posição assume
  /// (mesma regra de [removeSongs] — no fim, o anterior); se nada
  /// sobrar, a fila esvazia (-1). No shuffle a faixa também sai da
  /// ordem original (desligar o embaralhamento não ressuscita).
  Song? removeAt(int index) {
    if (index < 0 || index >= _queue.length) return null;
    final Song? keep = current;
    final Song removed = _queue.removeAt(index);
    if (keep == null) {
      // Sem corrente selecionada o índice -1 continua -1.
    } else if (removed.id == keep.id) {
      _queueIndex = _queue.isEmpty
          ? -1
          : index.clamp(0, _queue.length - 1);
    } else {
      _queueIndex = _queue.indexWhere((Song s) => s.id == keep.id);
    }
    if (_shuffle) {
      final int pos =
          _originalOrder.indexWhere((Song s) => s.id == removed.id);
      if (pos >= 0) {
        final List<Song> order = List<Song>.of(_originalOrder);
        order.removeAt(pos);
        _originalOrder = order;
      }
    }
    return removed;
  }

  /// Compara ids na ORDEM (fila ordenada — igualdade simples seria
  /// insuficiente para detectar um move que só trocou posições).
  static bool _sameIds(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
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