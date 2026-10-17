// `hide RepeatMode`: o Flutter também exporta um RepeatMode
// (RepeatingAnimationBuilder) — escondemos o dele para usar
// o enum do app sem prefixo.
import 'package:flutter/material.dart' hide RepeatMode;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_locale_choice.dart';
import '../models/repeat_mode.dart';
import '../models/song_sort_key.dart';

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
  static const String _playbackSpeedKey = 'playback_speed';
  static const String _crossfadeKey = 'crossfade_seconds';
  static const String _eqEnabledKey = 'equalizer_enabled';
  static const String _eqBandsKey = 'equalizer_bands';
  static const String _eqPresetKey = 'equalizer_preset';
  static const String _eqBassEnabledKey = 'equalizer_bass_enabled';
  static const String _eqBassStrengthKey = 'equalizer_bass_strength';

  // Item 4.3 — ordenação escolhível da biblioteca.
  static const String _librarySortKeyKey = 'library_sort_key';
  static const String _librarySortAscendingKey = 'library_sort_ascending';

  // Item 5.1 — idioma escolhido (null/sistema = seguir o aparelho).
  static const String _localeChoiceKey = 'locale_choice';
  // Item 5.2 — Configurações organizadas.
  static const String _amoledKey = 'theme_amoled';
  static const String _sleepDefaultKey = 'sleep_default_minutes';
  static const String _stopPausedKey = 'stop_service_paused_minutes';

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

  /// Velocidades de reprodução do seletor (item 3.2) — mesma grade do
  /// player de vídeo (video_player_screen). O clamp 0,5–2,0 é garantido
  /// pela camada de serviço.
  static const List<double> playbackSpeedOptions = <double>[
    0.5,
    0.75,
    1.0,
    1.25,
    1.5,
    2.0,
  ];

  /// Crossfade (item 3.4): duração máxima da transição entre faixas, em
  /// segundos. `0` = desligado (padrão); teto em 12 s (faixa do pedido).
  static const int maxCrossfadeSeconds = 12;

  /// Opções do seletor: desligado + 1..12 s.
  static final List<int> crossfadeOptions =
      List<int>.generate(maxCrossfadeSeconds + 1, (int i) => i);

  // ---- Equalizador (item 3.3) ----

  /// Nº de bandas do layout CANÔNICO usado pela UI antes de a capacidade
  /// real do aparelho ser conhecida (aparelhos com outra contagem se
  /// ajustam no probe — ver `AudioService.probeEqualizer`).
  static const int equalizerBandCount = 5;

  /// Nome do preset "sem curva" (bandas zeradas).
  static const String equalizerDefaultPreset = 'Plano';

  /// Nome exibido quando o usuário mexe nas bandas na mão.
  static const String equalizerCustomPreset = 'Personalizado';

  /// Ganho padrão do reforço de graves (0–100; vira dB na camada de
  /// serviço: `12 * forca / 100`).
  static const int defaultEqualizerBassStrength = 60;

  /// Presets do equalizador (item 3.3) — curvas de 5 bandas (dB) no
  /// layout canônico. O aparelho recebe o que couber na faixa real
  /// (clamp na camada de serviço).
  static const Map<String, List<double>> equalizerPresets =
      <String, List<double>>{
    equalizerDefaultPreset: <double>[0, 0, 0, 0, 0],
    'Graves': <double>[9, 6, 1, -1, -2],
    'Graves & agudos': <double>[8, 3, 0, 3, 8],
    'Vocal': <double>[-2, -1, 4, 3, 1],
    'Rock': <double>[5, 3, 0, 2, 5],
    'Pop': <double>[1, 3, 4, 3, 1],
    'Jazz': <double>[4, 2, 0, 2, 4],
    'Clássico': <double>[4, 3, 0, 3, 4],
    'Eletrônico': <double>[7, 3, 0, 3, 7],
  };

  /// Faixa de ganho CANÔNICA (dB) para validação/persistência — a faixa
  /// real do aparelho (±15 dB na maioria) é lida no probe e o clamp
  /// final acontece ao aplicar.
  static const double equalizerMinDb = -15;
  static const double equalizerMaxDb = 15;

  /// Bandas zeradas do layout canônico.
  static List<double> defaultEqualizerBands() =>
      List<double>.filled(equalizerBandCount, 0);

  /// Valida uma lista de bandas vinda da UI ou do disco: cada valor é
  /// tornado finito e limitado a [-15, 15]; entradas inválidas viram 0.
  /// Tamanho fora de [1, 10] cai no default (5 bandas planas).
  static List<double> sanitizeEqualizerBands(List<double> bands) {
    if (bands.isEmpty || bands.length > 10) return defaultEqualizerBands();
    return bands
        .map((double b) {
          if (!b.isFinite) return 0.0;
          return b.clamp(equalizerMinDb, equalizerMaxDb).toDouble();
        })
        .toList(growable: false);
  }

  /// Prazo padrão: 30 dias é o padrão de mercado (Google Fotos, Drive).
  static const int defaultTrashRetentionDays = 30;

  /// Item 5.2 — durações oferecidas para o timer de sono padrão.
  /// `0` = desativado (padrão: o menu de sono continua manual).
  static const List<int> sleepDefaultOptions = <int>[0, 15, 30, 45, 60];

  /// Item 5.2 — durações oferecidas para "parar o serviço após N minutos
  /// pausado". `0` = desativado; o padrão é 30 min (spec 5.2).
  static const List<int> stopPausedOptions = <int>[0, 5, 15, 30, 60];
  static const int defaultStopPausedMinutes = 30;

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

  /// Velocidade de reprodução persistida (item 3.2). `1.0` = normal.
  double _playbackSpeed = 1.0;

  /// Crossfade persistido (item 3.4): segundos da transição entre
  /// faixas — `0` = desligado.
  int _crossfadeSeconds = 0;

  // ---- Equalizador (item 3.3) — ver [setEqualizer] ----
  bool _equalizerEnabled = false;
  List<double> _equalizerBands = defaultEqualizerBands();
  String _equalizerPreset = equalizerDefaultPreset;
  bool _equalizerBassEnabled = false;
  int _equalizerBassStrength = defaultEqualizerBassStrength;

  int _galleryColumns = 3;
  int _videoColumns = 2;
  int _trashRetentionDays = defaultTrashRetentionDays;

  // ---- Filtros da biblioteca (item 2.5) ----

  /// Duração mínima em segundos — `0` = desligado (padrão).
  int _libraryMinDurationSeconds = 0;

  /// Pastas ignoradas (caminhos normalizados, sem barra final).
  List<String> _ignoredFolders = const <String>[];

  // ---- Ordenação da biblioteca (item 4.3) ----

  /// Critério de ordenação — padrão: título (a ordem natural de
  /// sempre, para nenhum usuário acordar com a lista "mexida").
  SongSortKey _sortKey = SongSortKey.title;

  /// Sentido crescente (padrão). False = decrescente.
  bool _sortAscending = true;

  /// Idioma escolhido (item 5.1) — padrão: seguir o sistema.
  AppLocaleChoice _localeChoice = AppLocaleChoice.system;

  // Item 5.2 — preferências novas.
  bool _themeAmoled = false;
  int _sleepDefaultMinutes = 0;
  int _stopServicePausedMinutes = defaultStopPausedMinutes;

  bool _isDisposed = false;

  ThemeMode get themeMode => _themeMode;
  bool get resumePlayback => _resumePlayback;

  /// Pausar ao desconectar fones (becoming noisy).
  bool get pauseOnNoisy => _pauseOnNoisy;

  /// Embaralhamento ativo (persistido).
  bool get shuffleEnabled => _shuffleEnabled;

  /// Modo de repetição (persistido).
  RepeatMode get repeatMode => _repeatMode;

  /// Velocidade de reprodução persistida (0,5–2,0; 1.0 = normal).
  double get playbackSpeed => _playbackSpeed;

  /// Crossfade em segundos (0 = desligado; ver [maxCrossfadeSeconds]).
  int get crossfadeSeconds => _crossfadeSeconds;

  /// Idioma escolhido (item 5.1) — padrão: seguir o sistema.
  AppLocaleChoice get localeChoice => _localeChoice;

  /// Locale concreto para o MaterialApp; `null` = seguir o sistema
  /// (o fallback pt-BR acontece na resolução do main.dart).
  Locale? get localeOverride => switch (_localeChoice) {
        AppLocaleChoice.system => null,
        AppLocaleChoice.portuguese => const Locale('pt', 'BR'),
        AppLocaleChoice.english => const Locale('en'),
      };

  /// Equalizador ligado (item 3.3).
  bool get equalizerEnabled => _equalizerEnabled;

  /// Bandas do equalizador em dB (cópia imutável).
  List<double> get equalizerBands => List<double>.unmodifiable(
        _equalizerBands,
      );

  /// Nome do preset ativo ('Plano', 'Rock'... ou [equalizerCustomPreset]).
  String get equalizerPreset => _equalizerPreset;

  /// Reforço de graves ligado (item 3.3).
  bool get equalizerBassEnabled => _equalizerBassEnabled;

  /// Força do reforço de graves (0–100).
  int get equalizerBassStrength => _equalizerBassStrength;

  /// Colunas desejadas na Galeria (zoom do usuário).
  int get galleryColumns => _galleryColumns;

  /// Colunas desejadas em Vídeos (zoom do usuário).
  int get videoColumns => _videoColumns;

  /// Quantos dias um item fica na lixeira antes de ser apagado.
  ///
  /// `0` significa "até o usuário apagar" — sem expurgo automático.
  int get trashRetentionDays => _trashRetentionDays;

  /// Duração mínima da biblioteca em segundos (`0` = desligado) —
  /// item 2.5.
  int get libraryMinDurationSeconds => _libraryMinDurationSeconds;

  /// Pastas cujas faixas não aparecem na biblioteca (item 2.5).
  List<String> get ignoredFolders => List<String>.unmodifiable(
        _ignoredFolders,
      );

  /// Ordenação escolhida da biblioteca (item 4.3).
  SongSortKey get sortKey => _sortKey;

  /// Sentido da ordenação (true = crescente).
  bool get sortAscending => _sortAscending;

  /// Item 5.2 — tema escuro AMOLED (preto puro), só age no modo escuro.
  bool get themeAmoled => _themeAmoled;

  /// Item 5.2 — duração padrão do timer de sono (0 = desativado).
  int get sleepDefaultMinutes => _sleepDefaultMinutes;

  /// Item 5.2 — parar o serviço depois de N minutos pausado
  /// (0 = desativado; padrão 30).
  int get stopServicePausedMinutes => _stopServicePausedMinutes;

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
      // Item 3.2: só aceita valor finito dentro da faixa; corrompido
      // volta ao normal (1.0).
      final double storedSpeed = prefs.getDouble(_playbackSpeedKey) ?? 1.0;
      _playbackSpeed = storedSpeed.isFinite &&
              storedSpeed >= 0.5 &&
              storedSpeed <= 2.0
          ? storedSpeed
          : 1.0;
      // Item 3.4: fora de 0–12 (corrompido) volta ao padrão desligado.
      _crossfadeSeconds = (prefs.getInt(_crossfadeKey) ?? 0).clamp(
        0,
        maxCrossfadeSeconds,
      );
      // Item 3.3: bandas corrompidas (tamanho/NaN/fora da faixa) caem no
      // default plano; preset desconhecido volta para 'Plano'.
      _equalizerEnabled = prefs.getBool(_eqEnabledKey) ?? false;
      _equalizerBands = sanitizeEqualizerBands(
        (prefs.getStringList(_eqBandsKey) ?? const <String>[])
            .map(double.tryParse)
            .whereType<double>()
            .toList(growable: false),
      );
      final String storedPreset = prefs.getString(_eqPresetKey) ??
          equalizerDefaultPreset;
      _equalizerPreset =
          equalizerPresets.containsKey(storedPreset) ||
                  storedPreset == equalizerCustomPreset
              ? storedPreset
              : equalizerDefaultPreset;
      _equalizerBassEnabled = prefs.getBool(_eqBassEnabledKey) ?? false;
      _equalizerBassStrength =
          (prefs.getInt(_eqBassStrengthKey) ?? defaultEqualizerBassStrength)
              .clamp(0, 100);
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
      // Item 4.3: chave desconhecida (valor gravado por versão futura/
      // corrompido) volta para título; sentido cai em crescente.
      _sortKey = SongSortKey.fromName(prefs.getString(_librarySortKeyKey));
      _sortAscending = prefs.getBool(_librarySortAscendingKey) ?? true;
      // Item 5.1: chave desconhecida volta para "seguir o sistema".
      _localeChoice = AppLocaleChoice.fromName(prefs.getString(_localeChoiceKey));
      // Item 5.2: fora da lista de opções volta para o padrão da spec.
      _themeAmoled = prefs.getBool(_amoledKey) ?? false;
      _sleepDefaultMinutes = sleepDefaultOptions
              .contains(prefs.getInt(_sleepDefaultKey))
          ? prefs.getInt(_sleepDefaultKey)!
          : 0;
      _stopServicePausedMinutes = stopPausedOptions
              .contains(prefs.getInt(_stopPausedKey))
          ? prefs.getInt(_stopPausedKey)!
          : defaultStopPausedMinutes;
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

  /// Persiste a velocidade de reprodução (item 3.2). Valores fora de
  /// 0,5–2,0 ou não finitos caem no normal (1.0) — a mesma faixa que o
  /// seletor oferece e que o serviço garante por clamp.
  Future<void> setPlaybackSpeed(double speed) async {
    final double valid =
        speed.isFinite && speed >= 0.5 && speed <= 2.0 ? speed : 1.0;
    if (_playbackSpeed == valid) return;
    _playbackSpeed = valid;
    _notify();
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_playbackSpeedKey, valid);
    } catch (e) {
      // Falha de escrita não quebra a sessão atual.
    }
  }

  /// Persiste o crossfade (item 3.4). Fora de 0–12 cai no teto/piso —
  /// a mesma faixa que o slider oferece.
  Future<void> setCrossfadeSeconds(int seconds) async {
    final int safe = seconds.clamp(0, maxCrossfadeSeconds);
    if (_crossfadeSeconds == safe) return;
    _crossfadeSeconds = safe;
    _notify();
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_crossfadeKey, safe);
    } catch (e) {
      // Falha de escrita não quebra a sessão atual.
    }
  }

  /// Persiste o estado COMPLETO do equalizador (item 3.3) de uma vez:
  /// a tela de bandas mexe em vários campos por gesto e um notify/persist
  /// conjunto evita rebuilds e escritas duplicadas. Validação igual ao
  /// load (bandas saneadas, preset conhecido, força 0–100).
  Future<void> setEqualizer({
    required bool enabled,
    required List<double> bands,
    required String preset,
    required bool bassEnabled,
    required int bassStrength,
  }) async {
    final List<double> safeBands = sanitizeEqualizerBands(bands);
    final String safePreset = equalizerPresets.containsKey(preset) ||
            preset == equalizerCustomPreset
        ? preset
        : equalizerDefaultPreset;
    final int safeStrength = bassStrength.clamp(0, 100);
    _equalizerEnabled = enabled;
    _equalizerBands = safeBands;
    _equalizerPreset = safePreset;
    _equalizerBassEnabled = bassEnabled;
    _equalizerBassStrength = safeStrength;
    _notify();
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_eqEnabledKey, enabled);
      await prefs.setStringList(
        _eqBandsKey,
        safeBands.map((double b) => b.toString()).toList(growable: false),
      );
      await prefs.setString(_eqPresetKey, safePreset);
      await prefs.setBool(_eqBassEnabledKey, bassEnabled);
      await prefs.setInt(_eqBassStrengthKey, safeStrength);
    } catch (e) {
      // Falha de escrita não quebra a sessão atual.
    }
  }

  /// Persiste a ordenação escolhida da biblioteca (item 4.3).
  /// O PlayerProvider é quem chama, junto com a reordenação da lista.
  Future<void> setSort({
    required SongSortKey key,
    required bool ascending,
  }) async {
    if (_sortKey == key && _sortAscending == ascending) return;
    _sortKey = key;
    _sortAscending = ascending;
    _notify();
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(_librarySortKeyKey, key.name);
      await prefs.setBool(_librarySortAscendingKey, ascending);
    } catch (e) {
      // Falha de escrita não quebra a sessão atual.
    }
  }

  /// Persiste o idioma escolhido (item 5.1). `system` segue o aparelho.
  Future<void> setLocaleChoice(AppLocaleChoice choice) async {
    if (_localeChoice == choice) return;
    _localeChoice = choice;
    _notify();
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(_localeChoiceKey, choice.name);
    } catch (e) {
      // Falha de escrita não quebra a sessão atual.
    }
  }

  /// Item 5.2 — tema escuro AMOLED (preto puro). Efeito só no modo
  /// escuro (main.dart escolhe o darkTheme conforme esta flag).
  Future<void> setThemeAmoled(bool enabled) async {
    if (_themeAmoled == enabled) return;
    _themeAmoled = enabled;
    _notify();
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_amoledKey, enabled);
    } catch (e) {
      // Falha de escrita não quebra a sessão atual.
    }
  }

  /// Item 5.2 — duração padrão do timer de sono (0 = desativado);
  /// valor fora da lista é ignorado.
  Future<void> setSleepDefaultMinutes(int minutes) async {
    if (!sleepDefaultOptions.contains(minutes)) return;
    if (_sleepDefaultMinutes == minutes) return;
    _sleepDefaultMinutes = minutes;
    _notify();
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_sleepDefaultKey, minutes);
    } catch (e) {
      // Falha de escrita não quebra a sessão atual.
    }
  }

  /// Item 5.2 — minutos pausados antes de o serviço parar (0 =
  /// desativado); valor fora da lista é ignorado.
  Future<void> setStopServicePausedMinutes(int minutes) async {
    if (!stopPausedOptions.contains(minutes)) return;
    if (_stopServicePausedMinutes == minutes) return;
    _stopServicePausedMinutes = minutes;
    _notify();
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_stopPausedKey, minutes);
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
