import 'package:flutter/material.dart';

import '../utils/motion.dart';

/// Tema centralizado do app.
///
/// Responsabilidade: TODA a configuração visual vive aqui. Nenhum widget
/// define cor/fonte "na unha" — tudo vem do ThemeData.
///
/// Dark Mode: o tema escuro já está implementado ([AppTheme.dark]) e pronto
/// para ser ativado em main.dart trocando `theme:`/`darkTheme:`/`themeMode:`
/// (uma única linha). Paleta consistente derivada de uma única cor-semente
/// via Material 3 (ColorScheme.fromSeed).
class AppTheme {
  /// Cor-semente única do app — todas as outras cores são derivadas dela.
  static const Color _seedColor = Color(0xFF6750A4);

  static ThemeData get light => _build(Brightness.light);

  static ThemeData get dark => _build(Brightness.dark);

  /// Item 5.2 — tema escuro AMOLED: fundos em preto puro (#000), o que
  /// apaga de vez os pixels em telas OLED. Só muda os fundos "large"
  /// (scaffold, app bar, folhas, menus, diálogos); a paleta derivada da
  /// cor-semente continua a mesma do [dark] para o contraste dos
  /// textos/componentes não mudar.
  static ThemeData get amoled => _build(Brightness.dark, pureBlack: true);

  static ThemeData _build(Brightness brightness, {bool pureBlack = false}) {
    final ColorScheme colorScheme = ColorScheme.fromSeed(
      seedColor: _seedColor,
      brightness: brightness,
    );
    const Color black = Color(0xFF000000);

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: pureBlack ? black : colorScheme.surface,
      // Transição de página padronizada (fade + deslocamento curto) para que
      // navegar entre abas e telas não dê um corte seco.
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.android: Motion.pageTransition,
          TargetPlatform.iOS: Motion.pageTransition,
          TargetPlatform.macOS: Motion.pageTransition,
          TargetPlatform.windows: Motion.pageTransition,
          TargetPlatform.linux: Motion.pageTransition,
        },
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: pureBlack ? black : colorScheme.surface,
        foregroundColor: colorScheme.onSurface,
        centerTitle: true,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      dialogTheme: pureBlack
          ? const DialogThemeData(backgroundColor: black)
          : null,
      bottomSheetTheme: pureBlack
          ? const BottomSheetThemeData(backgroundColor: black)
          : null,
      popupMenuTheme: pureBlack ? const PopupMenuThemeData(color: black) : null,
      sliderTheme: SliderThemeData(
        // Polegar levemente maior para facilitar o arrasto do seek.
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
      ),
      // Feedback de toque e seleção com a mesma cadência do resto do app.
      splashFactory: InkSparkle.splashFactory,
    );
  }
}
