// Testes de persistência das preferências de reprodução:
// shuffle e repeat (SharedPreferences mockado — sem plugins).

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:audify/models/repeat_mode.dart';
import 'package:audify/providers/settings_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('padrões: shuffle desligado e repeat off', () async {
    final SettingsProvider settings = SettingsProvider();
    await settings.load();
    expect(settings.shuffleEnabled, isFalse);
    expect(settings.repeatMode, RepeatMode.off);
  });

  test('shuffle e repeat são persistidos e restaurados',
      () async {
    final SettingsProvider settings = SettingsProvider();
    await settings.load();

    await settings.setShuffleEnabled(true);
    await settings.setRepeatMode(RepeatMode.all);

    // Nova instância = próxima sessão: lê o que foi
    // salvo no SharedPreferences.
    final SettingsProvider restored = SettingsProvider();
    await restored.load();
    expect(restored.shuffleEnabled, isTrue);
    expect(restored.repeatMode, RepeatMode.all);
  });

  test('todos os modos de repeat voltam do storage',
      () async {
    final SettingsProvider settings = SettingsProvider();
    await settings.load();
    await settings.setRepeatMode(RepeatMode.one);

    final SettingsProvider restored = SettingsProvider();
    await restored.load();
    expect(restored.repeatMode, RepeatMode.one);
  });

  test('desligar shuffle persiste o desligado', () async {
    SharedPreferences.setMockInitialValues({'shuffle_enabled': true});
    final SettingsProvider settings = SettingsProvider();
    await settings.load();
    expect(settings.shuffleEnabled, isTrue);

    await settings.setShuffleEnabled(false);

    final SettingsProvider restored = SettingsProvider();
    await restored.load();
    expect(restored.shuffleEnabled, isFalse);
  });

  test('storage vazio/inválido não quebra o load', () async {
    SharedPreferences.setMockInitialValues({
      'repeat_mode': 99, // valor fora do enum
    });
    final SettingsProvider settings = SettingsProvider();
    await settings.load();
    expect(settings.repeatMode, RepeatMode.off);
    expect(settings.shuffleEnabled, isFalse);
  });

  // ---- Item 5.2 — preferências novas das Configurações ----

  test('padrões 5.2: AMOLED off, sono padrão off, parar pausado 30 min',
      () async {
    final SettingsProvider settings = SettingsProvider();
    await settings.load();
    expect(settings.themeAmoled, isFalse);
    expect(settings.sleepDefaultMinutes, 0);
    expect(settings.stopServicePausedMinutes, 30);
  });

  test('preferências 5.2 são persistidas e restauradas', () async {
    final SettingsProvider settings = SettingsProvider();
    await settings.load();

    await settings.setThemeAmoled(true);
    await settings.setSleepDefaultMinutes(45);
    await settings.setStopServicePausedMinutes(15);

    final SettingsProvider restored = SettingsProvider();
    await restored.load();
    expect(restored.themeAmoled, isTrue);
    expect(restored.sleepDefaultMinutes, 45);
    expect(restored.stopServicePausedMinutes, 15);
  });

  test('5.2: valor fora da lista é ignorado na escrita', () async {
    final SettingsProvider settings = SettingsProvider();
    await settings.load();

    await settings.setSleepDefaultMinutes(7); // fora de [0,15,30,45,60]
    await settings.setStopServicePausedMinutes(7); // fora de [0,5,15,30,60]
    expect(settings.sleepDefaultMinutes, 0);
    expect(settings.stopServicePausedMinutes, 30);
  });

  test('5.2: storage corrompido volta para o padrão da spec', () async {
    SharedPreferences.setMockInitialValues({
      'theme_amoled': true, // este é bool — ok
      'sleep_default_minutes': 7, // fora da lista → 0
      'stop_service_paused_minutes': 7, // fora da lista → 30
    });
    final SettingsProvider settings = SettingsProvider();
    await settings.load();
    expect(settings.themeAmoled, isTrue);
    expect(settings.sleepDefaultMinutes, 0);
    expect(settings.stopServicePausedMinutes, 30);
  });
}
