// Item 5.2 — tema escuro AMOLED (preto puro nos fundos "large").

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:audify/theme/app_theme.dart';

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
}
