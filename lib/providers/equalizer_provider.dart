import 'dart:async';

import 'package:flutter/foundation.dart';

import '../services/audio_service.dart';
import 'settings_provider.dart';

/// Item 3.3 — estado da tela do Equalizador.
///
/// Dono do estado EXPOSTO na UI (ligado, bandas, preset, graves); o
/// espelho de aplicação/persistência é delegado para [AudioService]
/// (roda no player, runtime-safe) e [SettingsProvider] (disco).
///
/// Padrão igual ao do PlayerProvider com velocidade/sono: a mutação
/// notifica a UI, aplica no serviço (nunca propaga exceção) e persiste.
class EqualizerProvider extends ChangeNotifier {
  EqualizerProvider({required this._audio, required this._settings}) {
    _audio.onEqualizerSupportChanged = _onSupportChanged;
    final SettingsProvider? prefs = _settings;
    _enabled = prefs?.equalizerEnabled ?? false;
    _bands = List<double>.of(prefs?.equalizerBands ?? _defaults());
    _preset = prefs?.equalizerPreset ?? SettingsProvider.equalizerDefaultPreset;
    _bassEnabled = prefs?.equalizerBassEnabled ?? false;
    _bassStrength =
        prefs?.equalizerBassStrength ??
        SettingsProvider.defaultEqualizerBassStrength;
    // Restaura o estado da sessão anterior (só quando ligado: com o
    // equalizador desligado o efeito já nasce bypassado no serviço).
    // Pré-ativação isso é local no just_audio; a primeira faixa/probe
    // empurra os ganhos ao aparelho.
    if (prefs != null && prefs.equalizerEnabled) {
      unawaited(_audio.applyEqualizerSettings(_fromPreferences(prefs)));
    }
  }

  final AudioService _audio;
  final SettingsProvider? _settings;

  bool _enabled = false;
  List<double> _bands = _defaults();
  String _preset = SettingsProvider.equalizerDefaultPreset;
  bool _bassEnabled = false;
  int _bassStrength = SettingsProvider.defaultEqualizerBassStrength;

  bool _isDisposed = false;

  /// Override de suporte só para TESTES: evita o probe real (canal de
  /// plataforma pendura sob FakeAsync em testWidgets).
  EqualizerSupport? _supportOverride;

  /// Presets canônicos (nome → 5 bandas em dB) — mesma fonte da
  /// persistência.
  static const Map<String, List<double>> presets =
      SettingsProvider.equalizerPresets;

  static List<double> _defaults() => SettingsProvider.defaultEqualizerBands();

  static EqualizerSettings _fromPreferences(SettingsProvider prefs) =>
      EqualizerSettings(
        enabled: prefs.equalizerEnabled,
        bands: prefs.equalizerBands,
        bassEnabled: prefs.equalizerBassEnabled,
        bassStrength: prefs.equalizerBassStrength,
      );

  // ---- Estado lido pela UI ----

  /// Suporte do aparelho (checado em runtime pelo serviço).
  EqualizerSupport get support => _supportOverride ?? _audio.equalizerSupport;

  bool get enabled => _enabled;

  /// Bandas em dB (cópia; comprimento cobre o layout canônico e o real).
  List<double> get bands => List<double>.unmodifiable(_bands);

  String get preset => _preset;
  bool get bassEnabled => _bassEnabled;
  int get bassStrength => _bassStrength;

  /// Nº de bandas da UI: a real (probe) ou a canônica (enquanto desconhece).
  int get bandCount {
    final int device = _audio.equalizerBandFrequencies.length;
    return device > _bands.length ? device : _bands.length;
  }

  /// Ganho da banda `index` (0 quando o índice ainda não foi editado).
  double bandValue(int index) => index < _bands.length ? _bands[index] : 0;

  /// Frequência central da banda `index` (null quando desconhecida).
  double? bandFrequency(int index) {
    final List<double> freqs = _audio.equalizerBandFrequencies;
    return index < freqs.length ? freqs[index] : null;
  }

  /// Item 3.3 — checagem de suporte no aparelho (complementa o probe do
  /// serviço; curto-circuita no override de teste).
  Future<EqualizerSupport> probe() {
    final EqualizerSupport? override = _supportOverride;
    if (override != null) {
      return Future<EqualizerSupport>.value(override);
    }
    return _audio.probeEqualizer();
  }

  // ---- Mutações (UI → serviço + persistência) ----

  /// Liga/desliga o equalizador (mestre).
  Future<void> setEqualizerEnabled(bool value) => _update(enabled: value);

  /// Ganho manual de uma banda — marca o preset como Personalizado.
  Future<void> setBand(int index, double gain) {
    if (index < 0 || index > 9) return Future<void>.value();
    final List<double> next = List<double>.of(_bands, growable: true);
    while (next.length <= index) {
      next.add(0);
    }
    return _update(
      bands: next..[index] = gain,
      preset: SettingsProvider.equalizerCustomPreset,
    );
  }

  /// Aplica um preset conhecido (curva de 5 bandas).
  Future<void> applyPreset(String name) {
    final List<double>? curve = SettingsProvider.equalizerPresets[name];
    if (curve == null) return Future<void>.value();
    return _update(bands: List<double>.of(curve), preset: name);
  }

  /// Reforço de graves (soma dB às duas bandas mais graves — ver
  /// [AudioService]).
  Future<void> setBassEnabled(bool value) => _update(bassEnabled: value);

  Future<void> setBassStrength(int value) => _update(bassStrength: value);

  /// Zera bandas/preset/graves (o mestre permanece como está).
  Future<void> reset() => _update(
    bands: _defaults(),
    preset: SettingsProvider.equalizerDefaultPreset,
    bassEnabled: false,
    bassStrength: SettingsProvider.defaultEqualizerBassStrength,
  );

  Future<void> _update({
    bool? enabled,
    List<double>? bands,
    String? preset,
    bool? bassEnabled,
    int? bassStrength,
  }) async {
    _enabled = enabled ?? _enabled;
    if (bands != null) {
      _bands = SettingsProvider.sanitizeEqualizerBands(bands);
    }
    _preset = preset ?? _preset;
    _bassEnabled = bassEnabled ?? _bassEnabled;
    _bassStrength = (bassStrength ?? _bassStrength).clamp(0, 100);
    _notify();
    // Serviço primeiro (feedback imediato na reprodução), depois disco.
    await _audio.applyEqualizerSettings(
      EqualizerSettings(
        enabled: _enabled,
        bands: _bands,
        bassEnabled: _bassEnabled,
        bassStrength: _bassStrength,
      ),
    );
    await _settings?.setEqualizer(
      enabled: _enabled,
      bands: _bands,
      preset: _preset,
      bassEnabled: _bassEnabled,
      bassStrength: _bassStrength,
    );
  }

  // ---- Teste ----

  /// Sobrescreve o suporte sem tocar em canal de plataforma.
  @visibleForTesting
  void debugOverrideSupport(EqualizerSupport? value) {
    _supportOverride = value;
    _notify();
  }

  void _onSupportChanged() {
    _notify();
  }

  void _notify() {
    if (!_isDisposed) notifyListeners();
  }

  @override
  void dispose() {
    _isDisposed = true;
    // Só este provider escreve no callback; limpa para não vazar após a
    // tela/provider morrer.
    _audio.onEqualizerSupportChanged = null;
    super.dispose();
  }
}
