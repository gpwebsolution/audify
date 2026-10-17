// Item 5.1 — internacionalização: alternância de locale na tela de
// Configurações + resolução "seguir o sistema com fallback pt-BR".
import 'package:audify/main.dart';
import 'package:audify/l10n/app_localizations.dart';
import 'package:audify/models/app_locale_choice.dart';
import 'package:audify/providers/settings_provider.dart';
import 'package:audify/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('resolveAppLocale (5.1)', () {
    test('inglês vira en; qualquer outro idioma e lista vazia caem no pt-BR', () {
      expect(
        resolveAppLocale(const <Locale>[Locale('en', 'US')]),
        const Locale('en'),
      );
      expect(
        resolveAppLocale(const <Locale>[Locale('pt', 'BR')]),
        const Locale('pt', 'BR'),
      );
      expect(
        resolveAppLocale(const <Locale>[Locale('fr', 'FR')]),
        const Locale('pt', 'BR'),
      );
      expect(resolveAppLocale(const <Locale>[]), const Locale('pt', 'BR'));
      expect(resolveAppLocale(null), const Locale('pt', 'BR'));
    });
  });

  group('Configurações > Aparência — idioma (5.1)', () {
    testWidgets('alterna Sistema / Português / English na hora', (
      WidgetTester tester,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final SettingsProvider settings = SettingsProvider();
      await settings.load();

      // Mesma costura do MaterialApp do MusicApp (locale vindo da
      // preferência, resolução e delegates do gen-l10n).
      await tester.pumpWidget(
        ChangeNotifierProvider<SettingsProvider>.value(
          value: settings,
          child: Builder(
            builder: (BuildContext context) {
              final SettingsProvider current =
                  context.watch<SettingsProvider>();
              return MaterialApp(
                locale: current.localeOverride,
                supportedLocales: const [Locale('pt', 'BR'), Locale('en')],
                localeListResolutionCallback: (List<Locale>? locales, _) =>
                    resolveAppLocale(locales),
                localizationsDelegates:
                    AppLocalizations.localizationsDelegates,
                home: const Scaffold(body: SettingsScreen()),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Sistema: o app segue o locale do ambiente (a resolução com
      // fallback pt-BR é coberta pelo teste unitário acima) — o que não
      // pode é quebrar a tela.
      expect(
        find.text('Language').evaluate().isNotEmpty ||
            find.text('Idioma').evaluate().isNotEmpty,
        isTrue,
        reason: 'seção de idioma visível em pt ou en',
      );

      // Português explícito: a tela inteira em português.
      await settings.setLocaleChoice(AppLocaleChoice.portuguese);
      await tester.pumpAndSettle();
      expect(find.text('APARÊNCIA'), findsOneWidget);
      expect(find.text('Idioma'), findsOneWidget);
      expect(find.text('APPEARANCE'), findsNothing);

      // English: reconstrói tudo em inglês.
      await settings.setLocaleChoice(AppLocaleChoice.english);
      await tester.pumpAndSettle();
      expect(find.text('APPEARANCE'), findsOneWidget);
      expect(find.text('Language'), findsOneWidget);
      expect(find.text('APARÊNCIA'), findsNothing);
      // Nomes de idioma não se traduzem no seletor.
      expect(find.text('Português'), findsOneWidget);
      expect(find.text('English'), findsOneWidget);

      // De volta ao sistema: preferência some (locale null) e a tela
      // segue o ambiente sem quebrar.
      await settings.setLocaleChoice(AppLocaleChoice.system);
      await tester.pumpAndSettle();
      expect(settings.localeOverride, isNull);
      expect(find.text('Idioma').evaluate().isNotEmpty || find.text('Language').evaluate().isNotEmpty, isTrue);

      settings.dispose();
    });

    testWidgets('preferência de idioma persiste entre instâncias', (
      WidgetTester tester,
    ) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final SettingsProvider first = SettingsProvider();
      await first.load();
      await first.setLocaleChoice(AppLocaleChoice.english);

      final SettingsProvider reloaded = SettingsProvider();
      await reloaded.load();
      expect(reloaded.localeChoice, AppLocaleChoice.english);
      expect(reloaded.localeOverride, const Locale('en'));

      final SettingsProvider corrupted = SettingsProvider();
      SharedPreferences.setMockInitialValues(<String, Object>{
        'locale_choice': 'klingon',
      });
      await corrupted.load();
      expect(corrupted.localeChoice, AppLocaleChoice.system);
      expect(corrupted.localeOverride, isNull);

      first.dispose();
      reloaded.dispose();
      corrupted.dispose();
      await tester.pump();
    });
  });
}
