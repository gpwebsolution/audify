import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Preferências do app persistidas em disco (shared_preferences).
///
/// Responsabilidade: tema (claro/escuro/sistema) e afins. Mudanças
/// notificam a UI imediatamente e persistem para a próxima sessão.
class SettingsProvider extends ChangeNotifier {
  static const String _themeKey = 'theme_mode';
  static const String _resumeKey = 'resume_playback';
  static const String _galleryColumnsKey = 'gallery_columns';
  static const String _videoColumnsKey = 'video_columns';

  /// Limite de colunas escolhido pelo usuário (zoom da grade).
  ///
  /// O número efetivo é calculado por [gridColumns] a partir da largura da
  /// tela: 10 colunas cabem num tablet, mas num celular de 360dp dariam
  /// thumbnails de 36dp — ilegíveis. Ver [GridColumns.of].
  static const int minColumns = 2;
  static const int maxColumns = 10;

  /// Largura mínima de um tile, para a grade nunca ficar ilegível.
  static const double minTileWidth = 56;

  ThemeMode _themeMode = ThemeMode.system;

  /// "Continuar de onde parou": ao abrir o app, restaura a última faixa
  /// e posição (pausada) tocadas na sessão anterior.
  bool _resumePlayback = true;
  int _galleryColumns = 3;
  int _videoColumns = 2;
  bool _isDisposed = false;

  ThemeMode get themeMode => _themeMode;
  bool get resumePlayback => _resumePlayback;

  /// Colunas desejadas na Galeria (zoom do usuário).
  int get galleryColumns => _galleryColumns;

  /// Colunas desejadas em Vídeos (zoom do usuário).
  int get videoColumns => _videoColumns;

  /// Colunas EFETIVAS para uma largura de tela.
  ///
  /// O valor do usuário é o teto, não a GARANTIA: num aparelho estreito,
  /// 10 colunas dariam thumbnails minúsculos, então o cálculo reduz até o tile
  /// ter [minTileWidth]. Nunca fica abaixo de [minColumns], para a grade não
  /// virar uma faixa.
  int effectiveColumns(int desired, double availableWidth) {
    final int clamped = desired.clamp(minColumns, maxColumns);
    final int fits = (availableWidth / minTileWidth).floor();
    return clamped < fits ? clamped : (fits < minColumns ? minColumns : fits);
  }

  Future<void> setGalleryColumns(int value) =>
      _setColumns(value, _galleryColumns, _galleryColumnsKey, (int v) {
        _galleryColumns = v;
      });

  Future<void> setVideoColumns(int value) =>
      _setColumns(value, _videoColumns, _videoColumnsKey, (int v) {
        _videoColumns = v;
      });

  Future<void> _setColumns(
    int value,
    int current,
    String key,
    void Function(int) apply,
  ) async {
    final int clamped = value.clamp(minColumns, maxColumns);
    if (clamped == current) return;
    apply(clamped);
    _notify();
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setInt(key, clamped);
    } catch (e) {
      // Falha de escrita não quebra a sessão atual.
    }
  }

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
      _galleryColumns = (prefs.getInt(_galleryColumnsKey) ?? 3).clamp(
        minColumns,
        maxColumns,
      );
      _videoColumns = (prefs.getInt(_videoColumnsKey) ?? 2).clamp(
        minColumns,
        maxColumns,
      );
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
      await prefs.setString(_themeKey, switch (mode) {
        ThemeMode.light => 'light',
        ThemeMode.dark => 'dark',
        ThemeMode.system => 'system',
      });
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
