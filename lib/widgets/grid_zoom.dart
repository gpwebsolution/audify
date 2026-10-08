import 'package:flutter/material.dart';

import '../utils/motion.dart';

/// Controle de "zoom" da grade: quantos itens cabem por linha.
///
/// Aparece como um botão que abre um painel compacto. A opção vai de
/// [minColumns] a [maxColumns] — o usuário escolhe quantas colunas quer, e a
/// tela reduz esse número quando a largura não comporta (ver
/// `SettingsProvider.effectiveColumns`).
///
/// É um popover em vez de um slider porque o valor é discreto e few: um
/// controle contínuo sugeriria precisão que não existe (e o número exato de
/// colunas muda com a largura da tela).
class GridZoomButton extends StatelessWidget {
  /// Colunas desejadas (persistido).
  final int columns;

  /// Colunas que EFFETIVAMENTE estão na grade agora — mostrar este número
  /// evita a surpresa de pedir 10 e ver 6.
  final int effectiveColumns;

  /// Aplica a nova escolha.
  final ValueChanged<int> onChanged;

  /// Texto do botão ("Fotos" / "Vídeos").
  final String label;

  const GridZoomButton({
    super.key,
    required this.columns,
    required this.effectiveColumns,
    required this.onChanged,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final bool limited = effectiveColumns < columns;

    return PopupMenuButton<int>(
      tooltip: 'Itens por linha',
      // Cor de destaque quando o layout efetivo difere do pedido: sinaliza
      // que a tela estreita limitou a escolha.
      icon: Icon(
        limited ? Icons.zoom_out_map : Icons.grid_view,
        color: limited ? colors.primary : null,
      ),
      onSelected: onChanged,
      itemBuilder: (BuildContext context) => <PopupMenuEntry<int>>[
        PopupMenuItem<int>(enabled: false, child: _Header(label: label)),
        for (int n = 2; n <= 10; n++)
          PopupMenuItem<int>(
            value: n,
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: 28,
                  child: Text(
                    '$n',
                    style: TextStyle(
                      fontWeight: n == columns
                          ? FontWeight.bold
                          : FontWeight.normal,
                      color: n == columns ? colors.primary : null,
                    ),
                  ),
                ),
                // Amostra da densidade: quantos quadradinhos por linha.
                Expanded(
                  child: Row(
                    children: <Widget>[
                      for (int i = 0; i < n; i++)
                        Container(
                          width: 4,
                          height: 12,
                          margin: const EdgeInsets.only(right: 2),
                          decoration: BoxDecoration(
                            color: n == columns
                                ? colors.primary
                                : colors.onSurfaceVariant.withValues(
                                    alpha: 0.5,
                                  ),
                            borderRadius: BorderRadius.circular(1),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  final String label;

  const _Header({required this.label});

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return SizedBox(
      width: 200,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            '$label por linha',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            'Menos colunas = itens maiores',
            style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
          ),
          const Divider(height: 12),
        ],
      ),
    );
  }
}

/// Grade com densidade variável, animada ao trocar o número de colunas.
///
/// O [AnimatedSwitcher] só anima a opacidade; para a TRANSIÇÃO entre
/// densidades é preciso o [GridView] reconstruir com a contagem nova. Como
///a reconstrução é imediata, a animação fica por conta do `key` do grid.
class ResponsiveMediaGrid<T> extends StatelessWidget {
  /// Itens já filtrados (ordem de exibição).
  final List<T> items;

  /// Número efetivo de colunas.
  final int columns;

  /// Constroi o tile de um item.
  final Widget Function(BuildContext context, T item, int index) itemBuilder;

  /// Proporção largura/altura do tile.
  final double childAspectRatio;

  final EdgeInsetsGeometry padding;
  final double spacing;

  /// dispara rolagem infinita quando chega perto do fim.
  final VoidCallback? onLoadMore;

  const ResponsiveMediaGrid({
    super.key,
    required this.items,
    required this.columns,
    required this.itemBuilder,
    required this.childAspectRatio,
    this.padding = const EdgeInsets.all(4),
    this.spacing = 4,
    this.onLoadMore,
  });

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: (ScrollNotification notification) {
        if (onLoadMore != null && notification.metrics.extentAfter < 400) {
          onLoadMore!();
        }
        return false;
      },
      child: AnimatedSize(
        duration: Motion.normal,
        curve: Motion.settle,
        child: GridView.builder(
          padding: padding,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: spacing,
            crossAxisSpacing: spacing,
            childAspectRatio: childAspectRatio,
          ),
          itemCount: items.length,
          itemBuilder: (BuildContext context, int index) =>
              itemBuilder(context, items[index], index),
        ),
      ),
    );
  }
}
