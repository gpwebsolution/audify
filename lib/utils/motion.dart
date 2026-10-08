import 'package:flutter/material.dart';

/// Vocabulário de animação do app: durações, curvas e pequenas transições
/// prontas.
///
/// O objetivo é que qualquer elemento que "aparece" ou "some" no Audify se
/// comporte da mesma forma — nada de corte seco, nada de atraso que faça o
/// app parecer lento. Os valores aqui são curtos de propósito: uma interface
/// que responde em ~150ms parece rápida mesmo que a operação demore.
class Motion {
  const Motion._();

  /// Mudança de estado de um controle (play/pause, seleção, mute).
  static const Duration fast = Duration(milliseconds: 150);

  /// Entrada/saída de um painel ou overlay.
  static const Duration normal = Duration(milliseconds: 220);

  /// Transição que o usuário percebe e acompanha (OSD, snackbar, sheet).
  static const Duration slow = Duration(milliseconds: 320);

  /// Quanto os controles do player ficam na tela depois do último toque.
  static const Duration controlsLinger = Duration(seconds: 3);

  /// Quanto o OSD fica visível antes de sumir sozinho.
  static const Duration osdLinger = Duration(milliseconds: 1200);

  /// Curva padrão de entrada: rápida no começo, suave no final.
  static const Curve enter = Curves.easeOutCubic;

  /// Curva padrão de saída: o inverso da entrada.
  static const Curve exit = Curves.easeInCubic;

  /// Curva para quando o elemento fica no lugar (ex.: volume).
  static const Curve settle = Curves.easeOut;

  /// Curva padrão deemphasis — usada em tudo que é padrão do Material.
  static const Curve standard = Curves.easeInOutCubic;

  /// Transição de página do app: entra de baixo com fade, levemente suavizada
  /// em relação ao Material para não competir com a animação do sistema.
  static const PageTransitionsBuilder pageTransition =
      FadeUpwardsPageTransitionsBuilder();
}

/// Fade + deslocamento vertical usado nas transições de página.
///
/// É o mesmo desenho do Material (`FadeUpwardsPageTransitionsBuilder`) com a
/// curva trocada por [Motion.standard], que deixa o movimento mais uniforme.
class FadeUpwardsPageTransitionsBuilder extends PageTransitionsBuilder {
  const FadeUpwardsPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Motion.standard),
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.06),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: animation, curve: Motion.standard)),
        child: child,
      ),
    );
  }
}

/// Aparece/desaparece com fade em vez de corte seco.
///
/// Envolve o conteúdo em [AnimatedOpacity] com [Motion.normal] e preserva o
/// espaço no layout ([Offstage] só desliga o *pintura*, não o *tamanho*), o
/// que evita o "salto" quando um painel some.
class FadeInOut extends StatelessWidget {
  final bool visible;
  final Widget child;

  /// Curva usada quando [visible] é true (entrada).
  final Curve enterCurve;

  /// Curva usada quando [visible] é false (saída).
  final Curve exitCurve;

  const FadeInOut({
    super.key,
    required this.visible,
    required this.child,
    this.enterCurve = Motion.enter,
    this.exitCurve = Motion.exit,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: visible ? 1 : 0,
      duration: visible ? Motion.normal : Motion.fast,
      curve: visible ? enterCurve : exitCurve,
      child: child,
    );
  }
}

/// Troca o filho com um fade, sem o "flash" do widget novo aparecendo antes
/// do antigo sumir.
class AnimatedContentSwitcher extends StatelessWidget {
  final Widget child;

  /// Identifica o conteúdo atual — quando muda, o switcher anima.
  final Object value;

  const AnimatedContentSwitcher({
    super.key,
    required this.value,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: Motion.fast,
      switchInCurve: Motion.enter,
      switchOutCurve: Motion.exit,
      transitionBuilder: (Widget current, Animation<double> animation) {
        return FadeTransition(opacity: animation, child: current);
      },
      child: KeyedSubtree(key: ValueKey<Object>(value), child: child),
    );
  }
}

/// Pulso curto de escala — usado para confirmar uma ação pontual (toque em
/// "selecionar tudo", salvar, etc.) sem precisar de StatefulWidget.
///
/// Um pulso por execução: reiniciar a animação exige uma nova instância, então
/// o [key] deve mudar junto com quem dispara.
class PressPulse extends StatefulWidget {
  final Widget child;
  final double scale;

  const PressPulse({super.key, required this.child, this.scale = 0.92});

  @override
  State<PressPulse> createState() => _PressPulseState();
}

class _PressPulseState extends State<PressPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 90),
    reverseDuration: Motion.fast,
  );

  late final Animation<double> _scale = Tween<double>(
    begin: 1,
    end: widget.scale,
  ).animate(CurvedAnimation(parent: _controller, curve: Motion.exit));

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _controller.forward(),
      onTapUp: (_) => _controller.reverse(),
      onTapCancel: () => _controller.reverse(),
      child: ScaleTransition(scale: _scale, child: widget.child),
    );
  }
}
