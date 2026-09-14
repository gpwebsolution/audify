import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Preferências do app persistidas em disco (shared_preferences).
///
/// Responsabilidade: tema (claro/escuro/sistema) e afins. Mudanças
/// notificam a UI imediatamente e persistem para a próxima sessão.
class SettingsProvider extends ChangeNotifier {
  static const String _themeKey = 'theme_mode';
  static const String _resumeKey = 'resume_playback';

  ThemeMode _themeMode = ThemeMode.system;

  /// "Continuar de onde parou": ao abrir o app, restaura a última faixa
  /// e posição (pausada) tocadas na sessão anterior.
  bool _resumePlayback = true;
  bool _isDisposed = false;

  ThemeMode get themeMode => _themeMode;
  bool get resumePlayback => _resumePlayback;

  /// Carrega as preferências salvas (chamado uma vez no boot).
  Future<void> load() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? stored = prefs.getString(_themeKey);
      _themeMode = switch (stored) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
      _resumePlayback = prefs.getBool(_resumeKey) ?? true;
      _notify();
    } catch (e) {
      // Sem persistência disponível: mantém o padrão (system).
    }
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    if (_themeMode == mode) return;
    _themeMode = mode;
    _notify();
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _themeKey,
        switch (mode) {
          ThemeMode.light => 'light',
          ThemeMode.dark => 'dark',
          ThemeMode.system => 'system',
        },
      );
    } catch (e) {
      // Falha de escrita não quebra a sessão atual.
    }
  }

  Future<void> setResumePlayback(bool enabled) async {
    if (_resumePlayback == enabled) return;
    _resumePlayback = enabled;
    _notify();
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_resumeKey, enabled);
    } catch (e) {
      // Falha de escrita não quebra a sessão atual.
    }
  }

  void _notify() {
    if (!_isDisposed) notifyListeners();
  }

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
  }
}