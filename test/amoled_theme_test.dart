// Item 5.2 — tema escuro AMOLED (preto puro nos fundos "large").
// Item 5.3 — contraste WCAG 4.5:1 do texto principal sobre esses
// fundos e dos pares intrínsecos de componentes.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:audify/theme/app_theme.dart';

/// Luminância relativa (WCAG 2.1) — canais da API nova de [Color]
/// já vêm no intervalo 0.0 a 1.0.
double _luminance(Color c) {
  double channel(double s) {
    return s <= 0.04045
        ? s / 12.92
        : math.pow((s + 0.055) / 1.055, 2.4).toDouble();
  }

  return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
}

/// Razão de contraste entre duas cores (1.0 = igual, 21 = branco/preto).
double _contrast(Color a, Color b) {
  final double la = _luminance(a);
  final double lb = _luminance(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

void main() {
  test('AMOLED pinta de preto puro os fundos principais', () {
    const Color black = Color(0xFF000000);
    final ThemeData amoled = AppTheme.amoled;
    expect(amoled.scaffoldBackgroundColor, black);
    expect(amoled.appBarTheme.backgroundColor, black);
    expect(amoled.bottomSheetTheme.backgroundColor, black);
    expect(amoled.popupMenuTheme.color, black);
    expect(amoled.dialogTheme.backgroundColor, black);
  });

  test('dark normal NÃO vira preto puro (só a flag AMOLED muda)', () {
    const Color black = Color(0xFF000000);
    final ThemeData dark = AppTheme.dark;
    expect(dark.scaffoldBackgroundColor, isNot(black));
    expect(dark.appBarTheme.backgroundColor, isNot(black));
    expect(dark.bottomSheetTheme.backgroundColor, isNull);
    expect(dark.popupMenuTheme.color, isNull);
    expect(dark.dialogTheme.backgroundColor, isNull);
  });

  test('AMOLED mantém a mesma paleta do dark (contraste não muda)', () {
    expect(
      AppTheme.amoled.colorScheme.brightness,
      AppTheme.dark.colorScheme.brightness,
    );
    expect(
      AppTheme.amoled.colorScheme.primary,
      AppTheme.dark.colorScheme.primary,
    );
  });

  test('contraste WCAG >= 4.5:1 no fundo preto puro (5.3)', () {
    final ThemeData t = AppTheme.amoled;
    final ColorScheme c = t.colorScheme;
    final Color bg = t.scaffoldBackgroundColor;

    // Texto comum sobre o fundo AMOLED (títulos, corpo, legendas).
    expect(_contrast(c.onSurface, bg), greaterThanOrEqualTo(4.5),
        reason: 'onSurface sobre preto');
    expect(_contrast(c.onSurfaceVariant, bg), greaterThanOrEqualTo(4.5),
        reason: 'onSurfaceVariant (subtítulos) sobre preto');
    expect(_contrast(c.primary, bg), greaterThanOrEqualTo(4.5),
        reason: 'primary (links/chips ativos) sobre preto');

    // Pares intrínsecos dos componentes (não dependem do fundo).
    expect(_contrast(c.onPrimary, c.primary), greaterThanOrEqualTo(4.5),
        reason: 'texto do botão preenchido');
    expect(
      _contrast(c.onErrorContainer, c.errorContainer),
      greaterThanOrEqualTo(4.5),
      reason: 'banner de permissão (errorContainer)',
    );
    expect(
      _contrast(c.onPrimaryContainer, c.primaryContainer),
      greaterThanOrEqualTo(4.5),
      reason: 'primaryContainer (avatars/chips)',
    );
  });
}
