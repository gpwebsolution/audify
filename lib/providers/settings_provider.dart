// `hide RepeatMode`: o Flutter também exporta um RepeatMode
// (RepeatingAnimationBuilder) — escondemos o dele para usar
// o enum do app sem prefixo.
import 'package:flutter/material.dart' hide RepeatMode;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/repeat_mode.dart';

/// Preferências do app persistidas em disco (shared_preferences).
///
/// Responsabilidade: tema (claro/escuro/sistema) e afins. Mudanças
/// notificam a UI imediatamente e persistem para a próxima sessão.
class SettingsProvider extends ChangeNotifier {
  static const String _themeKey = 'theme_mode';
  static const String _resumeKey = 'resume_playback';
  static const String _galleryColumnsKey = 'gallery_columns';
  static const String _videoColumnsKey = 'video_columns';
  static const String _trashDaysKey = 'trash_retention_days';
  static const String _pauseOnNoisyKey = 'pause_on_noisy';
  static const String _shuffleKey = 'shuffle_enabled';
  static const String _repeatModeKey = 'repeat_mode';
  static const String _minDurationKey = 'library_min_duration_seconds';
  static const String _ignoredFoldersKey = 'library_ignored_folders';

  /// Opções de prazo da lixeira, em dias. `0` = manter para sempre.
  static const List<int> trashRetentionOptions = <int>[
    0, // para sempre
    1,
    7,
    15,
    30,
    90,
  ];

  /// Opções de duração MÍNIMA da biblioteca (segundos). `0` =
  /// desligado (padrão) — mostra tudo, inclusive toques curtíssimos.
  static const List<int> minDurationOptions = <int>[
    0, // desligado
    10,
    30,
    60,
    120,
  ];

  /// Prazo padrão: 30 dias é o padrão de mercado (Google Fotos, Drive).
  static const int defaultTrashRetentionDays = 30;

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

  /// Pausar a reprodução ao desconectar os fones (evento
  /// "becoming noisy" do AudioSession). Padrão ligado: música
  /// tocando alto de repente no alto-falante do aparelho é
  /// constrangedor e gasta bateria. Sem auto-retomada — o
  /// usuário decide quando plugar de novo e retomar.
  bool _pauseOnNoisy = true;

  /// Embaralhamento ativo — persistido para a próxima
  /// sessão (o usuário mantém a preferência).
  bool _shuffleEnabled = false;

  /// Modo de repetição persistido (off/all/one).
  RepeatMode _repeatMode = RepeatMode.off;
  int _galleryColumns = 3;
  int _videoColumns = 2;
  int _trashRetentionDays = defaultTrashRetentionDays;

  // ---- Filtros da biblioteca (item 2.5) ----

  /// Duração mínima em segundos — `0` = desligado (padrão).
  int _libraryMinDurationSeconds = 0;

  /// Pastas ignoradas (caminhos normalizados, sem barra final).
  List<String> _ignoredFolders = const <String>[];

  bool _isDisposed = false;

  ThemeMode get themeMode => _themeMode;
  bool get resumePlayback => _resumePlayback;

  /// Pausar ao desconectar fones (becoming noisy).
  bool get pauseOnNoisy => _pauseOnNoisy;

  /// Embaralhamento ativo (persistido).
  bool get shuffleEnabled => _shuffleEnabled;

  /// Modo de repetição (persistido).
  RepeatMode get repeatMode => _repeatMode;

  /// Colunas desejadas na Galeria (zoom do usuário).
  int get galleryColumns => _galleryColumns;

  /// Colunas desejadas em Vídeos (zoom do usuário).
  int get videoColumns => _videoColumns;

  /// Quantos dias um item fica na lixeira antes de ser apagado.
  ///
  /// `0` significa "até o usuário apagar" — sem expurgo automático.
  int get trashRetentionDays => _trashRetentionDays;

  /// Rótulo curto do prazo, para a UI.
  String get trashRetentionLabel =>
      _trashRetentionDays == 0 ? 'Para sempre' : '$_trashRetentionDays dias';

  /// Duração mínima da biblioteca em segundos (`0` = desligado) —
  /// item 2.5.
  int get libraryMinDurationSeconds => _libraryMinDurationSeconds;

  /// Rótulo da duração mínima, para a UI.
  String get libraryMinDurationLabel {
    final int seconds = _libraryMinDurationSeconds;
    if (seconds == 0) return 'Desligado';
    if (seconds >= 60 && seconds % 60 == 0) return '${seconds ~/ 60} min';
    return '$seconds s';
  }

  /// Pastas cujas faixas não aparecem na biblioteca (item 2.5).
  List<String> get ignoredFolders => List<String>.unmodifiable(
        _ignoredFolders,
      );

  /// Define a duração mínima (apenas valores de [minDurationOptions]).
  Future<void> setLibraryMinDuration(int seconds) async {
    if (!minDurationOptions.contains(seconds)) return;
    if (_libraryMinDurationSeconds == seconds) return;
    _libraryMinDurationSeconds = seconds;
    _notify();
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_minDurationKey, seconds);
    } catch (e) {
      // Falha de escrita não quebra a sessão atual.
    }
  }

  /// Adiciona uma pasta ignorada (caminho normalizado; duplicata ou
  /// vazio é ignorado). Retorna true se a lista mudou.
  Future<bool> addIgnoredFolder(String path) async {
    final String? normalized = _normalizeFolderPath(path);
    if (normalized == null) return false;
    if (_ignoredFolders.contains(normalized)) return false;
    _ignoredFolders = <String>[..._ignoredFolders, normalized]..sort();
    _notify();
    await _persistIgnoredFolders();
    return true;
  }

  /// Remove uma pasta ignorada. Retorna true se a lista mudou.
  Future<bool> removeIgnoredFolder(String path) async {
    if (!_ignoredFolders.contains(path)) return false;
    _ignoredFolders =
        _ignoredFolders.where((String f) => f != path).toList(growable: false);
    _notify();
    await _persistIgnoredFolders();
    return true;
  }

  Future<void> _persistIgnoredFolders() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_ignoredFoldersKey, _ignoredFolders);
    } catch (e) {
      // Falha de escrita não quebra a sessão atual.
    }
  }

  /// Normaliza o caminho digitado: trim, sem barra final (a comparação
  /// do filtro usa `caminho/` como prefixo) e sem raiz inútil.
  static String? _normalizeFolderPath(String raw) {
    String path = raw.trim();
    while (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    if (path.isEmpty || path == '/') return null;
    return path;
  }

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

  /// Define o prazo da lixeira. Usa a MESMA tela de expurgo automático para
  /// qualquer valor, então trocar o prazo nunca deixa lixo antigo paradoxicalo.
  Future<void> setTrashRetentionDays(int days) async {
    if (!trashRetentionOptions.contains(days)) return;
    if (_trashRetentionDays == days) return;
    _trashRetentionDays = days;
    _notify();
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_trashDaysKey, days);
    } catch (e) {
      // Falha de escrita não quebra a sessão atual.
    }
  }

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
      _pauseOnNoisy = prefs.getBool(_pauseOnNoisyKey) ?? true;
      _shuffleEnabled = prefs.getBool(_shuffleKey) ?? false;
      _repeatMode = switch (prefs.getInt(_repeatModeKey)) {
        1 => RepeatMode.all,
        2 => RepeatMode.one,
        _ => RepeatMode.off,
      };
      _galleryColumns = (prefs.getInt(_galleryColumnsKey) ?? 3).clamp(
        minColumns,
        maxColumns,
      );
      _videoColumns = (prefs.getInt(_videoColumnsKey) ?? 2).clamp(
        minColumns,
        maxColumns,
      );
      _libraryMinDurationSeconds = minDurationOptions
              .contains(prefs.getInt(_minDurationKey))
          ? prefs.getInt(_minDurationKey)!
          : 0;
      _ignoredFolders =
          (prefs.getStringList(_ignoredFoldersKey) ?? const <String>[])
              .where((String f) => _normalizeFolderPath(f) != null)
              .map((String f) => _normalizeFolderPath(f)!)
              .toList(growable: false);
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

  /// Ativa/desativa a pausa ao desconectar os fones.
  Future<void> setPauseOnNoisy(bool enabled) async {
    if (_pauseOnNoisy == enabled) return;
    _pauseOnNoisy = enabled;
    _notify();
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_pauseOnNoisyKey, enabled);
    } catch (e) {
      // Falha de escrita não quebra a sessão atual.
    }
  }

  /// Persiste o estado do embaralhamento (o PlayerProvider
  /// aplica na fila; aqui só guardamos a preferência).
  Future<void> setShuffleEnabled(bool enabled) async {
    if (_shuffleEnabled == enabled) return;
    _shuffleEnabled = enabled;
    _notify();
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_shuffleKey, enabled);
    } catch (e) {
      // Falha de escrita não quebra a sessão atual.
    }
  }

  /// Persiste o modo de repetição.
  Future<void> setRepeatMode(RepeatMode mode) async {
    if (_repeatMode == mode) return;
    _repeatMode = mode;
    _notify();
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_repeatModeKey, mode.index);
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
