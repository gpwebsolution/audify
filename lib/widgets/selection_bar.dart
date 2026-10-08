import 'package:flutter/material.dart';

import '../utils/motion.dart';

/// Seleção múltipla genérica para as telas de mídia.
///
/// Antes cada aba de mídia tratava toque longo como "abrir menu". Aqui o
/// toque longo passa a entrar no modo seleção — o mesmo comportamento que a
/// aba Arquivos já tinha — sem duplicar a máquina de estados em quatro telas.
///
/// Comportamento (idêntico ao que o usuário já conhece em Arquivos):
///  - toque longo no primeiro item entra no modo seleção e marca o item;
///  - toque em item marcado/desmarcado alterna;
///  - desmarcar o último item sai do modo seleção;
///  - a tela é reconstruída a cada mudança ([notifyChanged]), então a UI
///    pode animar a troca de toolbar.
///
/// Uso:
/// ```dart
/// class _MyScreenState extends State<MyScreen> with MediaSelection<String> {
///   @override
///   void notifyChanged() => setState(() {});
/// }
/// ```
///
/// O mixin não herda de `State<W>` de propósito: `State` é genérico no
/// widget, e um mixin preso a `State<StatefulWidget>` conflita com
/// `State<MyScreen>` ("can't implement both"). Notificar via callback é o que
/// o mixin realmente precisa.
mixin MediaSelection<K> {
  final Set<K> _selected = <K>{};
  bool _selectionMode = false;

  /// Reconstrói a tela (chamar `setState(() {})`).
  void notifyChanged();

  /// Itens marcados. Exposto sem cópia: é leitura interna da UI.
  Set<K> get selected => _selected;

  int get selectionCount => _selected.length;

  bool get isSelectionMode => _selectionMode;

  bool isSelected(K key) => _selected.contains(key);

  void clearSelection() {
    if (_selected.isEmpty && !_selectionMode) return;
    _selected.clear();
    _selectionMode = false;
    notifyChanged();
  }

  /// Alterna a marcação de [key]. Marca o item e entra no modo seleção se
  /// ainda não estava nele (toque longo).
  void toggleSelect(K key) {
    if (_selected.add(key)) {
      _selectionMode = true;
    } else {
      _selected.remove(key);
      // Desmarcou o último: sai do modo, como em Arquivos.
      if (_selected.isEmpty) _selectionMode = false;
    }
    notifyChanged();
  }

  /// Marca [items]. Se [replace] for true, troca a marcação atual em vez de
  /// somar.
  void selectAll(Iterable<K> items, {bool replace = true}) {
    if (replace) _selected.clear();
    _selected.addAll(items);
    _selectionMode = _selected.isNotEmpty;
    notifyChanged();
  }

  /// Marca/desmarca tudo visível de uma vez (segundo toque em "selecionar
  /// tudo" desmarca).
  void toggleSelectAll(Iterable<K> items) {
    // Nada visível não pode marcar nada — e principalmente não pode LIGAR o
    // modo seleção, senão uma lista vazia (busca sem resultado) deixa a tela
    // presa numa barra de ações sem nenhum item marcado.
    if (items.isEmpty) return;
    final bool allSelected = items.every(_selected.contains);
    if (allSelected) {
      _selected.removeAll(items);
      if (_selected.isEmpty) _selectionMode = false;
    } else {
      _selected.addAll(items);
      _selectionMode = true;
    }
    notifyChanged();
  }

  /// Só os itens marcados que ainda existem em [universe] — protege contra
  /// item marcado que saiu da lista (excluído por outro caminho) e evita
  /// passar lixo para a ação em lote.
  List<T> selectedFrom<T>(Iterable<T> universe, K Function(T) keyOf) {
    return <T>[
      for (final T item in universe)
        if (_selected.contains(keyOf(item))) item,
    ];
  }
}

/// Barra de ações em lote que substitui a toolbar normal no modo seleção.
///
/// Aplica a mesma cadência visual do resto do app ([Motion.normal]) para a
/// troca entre os dois estados, em vez de a barra "pular" de um lugar para o
/// outro.
class SelectionBar extends StatelessWidget {
  /// Quantidade de itens marcados (já formatada, ex.: "3 selecionados").
  final String label;

  /// Mostra a dica do gesto junto do contador.
  ///
  /// Sem isso o usuário não descobre que o toque longo passou a marcar em vez
  /// de abrir o menu — e era exatamente a confusão que impedia montar uma
  /// seleção de vários itens.
  final bool showGestureHint;

  static const String gestureHint =
      'Toque longo marca • toque para marcar/desmarcar';

  /// Marca/desmarca tudo o que está visível.
  final VoidCallback onSelectAll;

  /// Ações extras do lote (além de selecionar tudo / excluir / limpar). Cada
  /// uma é um ícone. Vazio = barra só com o essencial, como a Galeria.
  final List<Widget> actions;

  /// Ação destrutiva (excluir) — pintada com a cor de erro.
  final VoidCallback? onDelete;

  final VoidCallback onClear;

  const SelectionBar({
    super.key,
    required this.label,
    required this.onSelectAll,
    required this.onClear,
    this.actions = const <Widget>[],
    this.onDelete,
    this.showGestureHint = true,
  });

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(
        color: colors.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.only(left: 10, right: 4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    label,
                    style: TextStyle(
                      color: colors.onSecondaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (showGestureHint)
                    Text(
                      gestureHint,
                      style: TextStyle(
                        fontSize: 10.5,
                        color: colors.onSecondaryContainer.withValues(
                          alpha: 0.75,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Selecionar/desmarcar os itens carregados',
              icon: const Icon(Icons.select_all),
              onPressed: onSelectAll,
            ),
            ...actions,
            if (onDelete != null)
              IconButton(
                tooltip: 'Excluir selecionados',
                icon: Icon(Icons.delete_outline, color: colors.error),
                onPressed: onDelete,
              ),
            IconButton(
              tooltip: 'Limpar seleção',
              icon: const Icon(Icons.close),
              onPressed: onClear,
            ),
          ],
        ),
      ),
    );
  }
}

/// Wrapper animado que troca um widget por outro com fade + leve deslocamento.
///
/// Usado para trocar a toolbar normal pela barra de seleção sem que a
/// interface dê um "soco" (corte seco) na troca.
class AnimatedToolbarSwap extends StatelessWidget {
  /// Identifica qual das duas toolbars está ativa — quando muda, anima.
  final Object value;

  final Widget selectionBar;
  final Widget toolbar;

  const AnimatedToolbarSwap({
    super.key,
    required this.value,
    required this.selectionBar,
    required this.toolbar,
  });

  @override
  Widget build(BuildContext context) {
    // [AnimatedSize] anima a ALTURA (a barra real ocupa espaço; o
    // [SizedBox.shrink] liberta o espaço), e o [AnimatedSwitcher] anima só a
    // opacidade. Um [Stack] com os dois filhos não serve: dentro de uma Column
    // a altura não é limitada e o layout fica frágil.
    return AnimatedSize(
      duration: Motion.normal,
      curve: Motion.settle,
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: Motion.fast,
        switchInCurve: Motion.enter,
        switchOutCurve: Motion.exit,
        transitionBuilder: (Widget current, Animation<double> animation) {
          return FadeTransition(opacity: animation, child: current);
        },
        child: KeyedSubtree(
          key: ValueKey<Object>(value),
          child: value == true ? selectionBar : toolbar,
        ),
      ),
    );
  }
}
