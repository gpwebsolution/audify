// Testes do item 3.3: equalizador + reforço de graves com checagem de
// capacidade em RUNTIME.
//
// Cobertura:
//  - canal nativo ausente/errando -> EqualizerSupport.unsupported, sem
//    crash (o item exige "desligar com segurança");
//  - canal saudável -> probe supported, frequências reais, mestre e
//    ganhos por banda enviados (com o reforço de graves somado);
//  - clamp na faixa real do aparelho (bandas a mais são ignoradas);
//  - persistência + saneamento das preferências (disco corrompido cai
//    no default);
//  - EqualizerProvider delegando para serviço/persistência;
//  - tela própria nos estados suportado/não suportado.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:audify/providers/equalizer_provider.dart';
import 'package:audify/providers/settings_provider.dart';
import 'package:audify/screens/equalizer_screen.dart';
import 'package:audify/services/audio_service.dart';

/// Mock dos canais do just_audio (principal + por jogador + eventos) —
/// simula um aparelho com/sem equalizador sem tocar em hardware.
class _JustAudioMock {
  _JustAudioMock({
    this.minDb = -15,
    this.maxDb = 15,
    this.bandCount = 5,
    this.failGetParameters = false,
    this.missingGetParameters = false,
  });

  final double minDb;
  final double maxDb;
  final int bandCount;
  final bool failGetParameters;

  /// Simula o canal do equalizador SEM implementação nativa (a leitura do
  /// parâmetro responde "no implementation found", como num aparelho que
  /// não expõe o Equalizer do Android).
  final bool missingGetParameters;

  /// Todas as chamadas registradas (qualquer método), para asserts
  /// genéricos (ex.: conteúdo do 'init').
  final List<MethodCall> calls = <MethodCall>[];

  static const List<double> _centers = <double>[60, 230, 910, 3600, 14000];

  String? _playerId;

  List<MethodCall> callsWhere(String method) =>
      calls.where((MethodCall c) => c.method == method).toList();

  /// Ganhos enviados por banda, na ordem das chamadas.
  List<double> get gainCalls => callsWhere('androidEqualizerBandSetGain')
      .map(
        (MethodCall c) => ((c.arguments as Map)['gain'] as num).toDouble(),
      )
      .toList();

  List<int> get gainBands => callsWhere('androidEqualizerBandSetGain')
      .map((MethodCall c) => (c.arguments as Map)['bandIndex'] as int)
      .toList();

  /// Estados enviados em audioEffectSetEnabled.
  List<bool> get enabledCalls => callsWhere('audioEffectSetEnabled')
      .map((MethodCall c) => (c.arguments as Map)['enabled'] as bool)
      .toList();

  /// Instala os mocks; o retorno é o teardown (addTearDown).
  void Function() install() {
    final TestWidgetsFlutterBinding binding =
        TestWidgetsFlutterBinding.ensureInitialized();
    const MethodChannel main =
        MethodChannel('com.ryanheise.just_audio.methods');

    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      main,
      (MethodCall call) async {
        calls.add(call);
        if (call.method == 'init') {
          _installPlayerChannels(binding);
        }
        // void/Map: resposta vazia cobre init (void) e os métodos com
        // Response.fromMap (payload nunca-nulo).
        return <dynamic, dynamic>{};
      },
    );

    return () {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(main, null);
      final String? id = _playerId;
      if (id != null) {
        binding.defaultBinaryMessenger.setMockMethodCallHandler(
          MethodChannel('com.ryanheise.just_audio.methods.$id'),
          null,
        );
        binding.defaultBinaryMessenger.setMockStreamHandler(
          EventChannel('com.ryanheise.just_audio.events.$id'),
          null,
        );
        binding.defaultBinaryMessenger.setMockStreamHandler(
          EventChannel('com.ryanheise.just_audio.data.$id'),
          null,
        );
      }
    };
  }

  void _installPlayerChannels(TestWidgetsFlutterBinding binding) {
    // O id vem do pedido de init (a UI Dart o gerou antes de chamar).
    // Como o handler não expõe o retorno, re-registramos no canal
    // derivado — o id está em algum init já registrado em `calls`.
    final MethodCall init = callsWhere('init').last;
    _playerId = ((init.arguments as Map)['id'] as String?) ?? 'player';
    final String id = _playerId!;

    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      MethodChannel('com.ryanheise.just_audio.methods.$id'),
      (MethodCall call) async {
        calls.add(call);
        if (call.method == 'androidEqualizerGetParameters') {
          if (missingGetParameters) {
            throw MissingPluginException(
              'No implementation found for method '
              'androidEqualizerGetParameters',
            );
          }
          if (failGetParameters) {
            throw PlatformException(
              code: 'error',
              message: 'Equalizador não suportado',
            );
          }
          return <dynamic, dynamic>{
            'parameters': <dynamic, dynamic>{
              'minDecibels': minDb,
              'maxDecibels': maxDb,
              'bands': <dynamic>[
                for (int i = 0; i < bandCount; i++)
                  <dynamic, dynamic>{
                    'index': i,
                    'lowerFrequency': _centers[i] * 0.8,
                    'upperFrequency': _centers[i] * 1.2,
                    'centerFrequency': _centers[i],
                    'gain': 0.0,
                  },
              ],
            },
          };
        }
        // Demais métodos (load, setGain, setEnabled, dispose...):
        // payload vazio é válido para todos os Response do plugin.
        return <dynamic, dynamic>{};
      },
    );
    // Eventos: stream respondida, porém sem nenhum evento — o estado
    // inicial do player (idle) já satisfaz o carregamento do probe.
    binding.defaultBinaryMessenger.setMockStreamHandler(
      EventChannel('com.ryanheise.just_audio.events.$id'),
      MockStreamHandler.inline(
        onListen: (Object? arguments, MockStreamHandlerEventSink events) {
          // sem eventos de propósito
        },
      ),
    );
    binding.defaultBinaryMessenger.setMockStreamHandler(
      EventChannel('com.ryanheise.just_audio.data.$id'),
      MockStreamHandler.inline(
        onListen: (Object? arguments, MockStreamHandlerEventSink events) {
          // sem eventos de propósito
        },
      ),
    );
  }
}

/// Instala o mock e registra o teardown automaticamente.
_JustAudioMock _mockJustAudio({
  double minDb = -15,
  double maxDb = 15,
  int bandCount = 5,
  bool failGetParameters = false,
  bool missingGetParameters = false,
}) {
  final _JustAudioMock mock = _JustAudioMock(
    minDb: minDb,
    maxDb: maxDb,
    bandCount: bandCount,
    failGetParameters: failGetParameters,
    missingGetParameters: missingGetParameters,
  );
  addTearDown(mock.install());
  return mock;
}

void main() {
  // ------------------------------------------------------------------
  // Checagem de capacidade em runtime
  // ------------------------------------------------------------------

  test('probe SEM canal nativo vira unsupported, sem crash', () async {
    // Canais do just_audio respondem (evita o hack assíncrono de
    // disposeAllPlayers do _pluginPlatform), mas o Equalizer não tem
    // implementação: getParameters responde "no implementation found".
    final _JustAudioMock mock = _mockJustAudio(missingGetParameters: true);
    final AudioService audio = AudioService(
      eqProbeTimeout: const Duration(milliseconds: 250),
    );
    final List<EqualizerSupport> events = <EqualizerSupport>[];
    audio.onEqualizerSupportChanged = () => events.add(audio.equalizerSupport);

    final EqualizerSupport support = await audio.probeEqualizer();

    expect(support, EqualizerSupport.unsupported);
    expect(audio.equalizerSupport, EqualizerSupport.unsupported);
    expect(events, <EqualizerSupport>[EqualizerSupport.unsupported]);
    // Resultado congelado: reprobe devolve o mesmo sem nova tentativa.
    expect(await audio.probeEqualizer(), EqualizerSupport.unsupported);
    expect(events, hasLength(1));
    // A tentativa tocou o canal (init carregou o efeito simulado).
    expect(mock.callsWhere('init'), hasLength(1));
    await audio.dispose();
  });

  test('probe com getParameters ERRANDO vira unsupported, sem crash', () async {
    final _JustAudioMock mock = _mockJustAudio(failGetParameters: true);
    final AudioService audio = AudioService(
      eqProbeTimeout: const Duration(milliseconds: 400),
    );
    final List<EqualizerSupport> events = <EqualizerSupport>[];
    audio.onEqualizerSupportChanged = () => events.add(audio.equalizerSupport);

    final EqualizerSupport support = await audio.probeEqualizer();

    expect(support, EqualizerSupport.unsupported);
    expect(events, <EqualizerSupport>[EqualizerSupport.unsupported]);
    // O init chegou a tentar carregar o efeito no aparelho simulado.
    expect(mock.callsWhere('init'), hasLength(1));
    await audio.dispose();
  });

  test('probe COM canal saudável: supported, frequências e ganhos', () async {
    final _JustAudioMock mock = _mockJustAudio();
    final AudioService audio = AudioService();

    // Estado ANTES da ativação: local, sem canal tocado.
    await audio.applyEqualizerSettings(
      const EqualizerSettings(
        enabled: true,
        bands: <double>[6, -3, 0, 0, 0],
        bassEnabled: true,
        bassStrength: 50,
      ),
    );
    expect(audio.equalizerSupport, EqualizerSupport.unknown);
    expect(audio.equalizerEffectEnabled, isTrue);

    final EqualizerSupport support = await audio.probeEqualizer();

    expect(support, EqualizerSupport.supported);
    expect(audio.equalizerBandFrequencies, hasLength(5));
    expect(audio.equalizerBandFrequencies.first, 60);

    // O init enviou o efeito com o estado correto.
    final MethodCall init = mock.callsWhere('init').single;
    final List<dynamic> effects =
        ((init.arguments as Map)['androidAudioEffects'] as List<dynamic>);
    expect(effects, hasLength(1));
    expect(effects.first['type'], 'AndroidEqualizer');
    expect(effects.first['enabled'], isTrue);

    // Mestre reenviado ativo (canal ATIVO no apply) + ganhos por banda
    // com o reforço de graves (+6 dB = 12 × 50%) nas bandas 0 e 1.
    expect(mock.enabledCalls, contains(true));
    expect(mock.gainBands, <int>[0, 1, 2, 3, 4]);
    expect(mock.gainCalls, <double>[12, 3, 0, 0, 0]);
    await audio.dispose();
  });

  test('ganho é clampado na faixa real e bandas extras são ignoradas',
      () async {
    final _JustAudioMock mock = _mockJustAudio(
      minDb: -10,
      maxDb: 10,
      bandCount: 3,
    );
    final AudioService audio = AudioService();

    await audio.applyEqualizerSettings(
      const EqualizerSettings(
        enabled: true,
        bands: <double>[99, -99, 5, 9, 9],
        bassEnabled: false,
      ),
    );
    final EqualizerSupport support = await audio.probeEqualizer();

    expect(support, EqualizerSupport.supported);
    expect(audio.equalizerBandFrequencies, hasLength(3));
    expect(mock.gainBands, <int>[0, 1, 2]);
    expect(mock.gainCalls, <double>[10, -10, 5]);
    await audio.dispose();
  });

  test('apply pré-ativação é local e saneia valores', () async {
    final AudioService audio = AudioService();
    expect(
      audio.equalizerBandFrequencies,
      <double>[60, 230, 910, 3600, 14000],
    );

    await audio.applyEqualizerSettings(
      const EqualizerSettings(
        enabled: true,
        bands: <double>[99, -99, 42.5],
        bassStrength: 500,
      ),
    );

    expect(audio.equalizerEffectEnabled, isTrue);
    expect(audio.equalizerSettings.enabled, isTrue);
    expect(audio.equalizerSettings.bands, <double>[15, -15, 15]);
    expect(audio.equalizerSettings.bassStrength, 100);
    expect(audio.equalizerSupport, EqualizerSupport.unknown);
    await audio.dispose();
  });

  // ------------------------------------------------------------------
  // Persistência (SettingsProvider)
  // ------------------------------------------------------------------

  test('equalizador persiste e recarrega via SharedPreferences', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'equalizer_enabled': true,
      'equalizer_bands': <String>['6.0', '-3.0', '0.0', '0.0', '0.0'],
      'equalizer_preset': 'Rock',
      'equalizer_bass_enabled': true,
      'equalizer_bass_strength': 80,
    });
    final SettingsProvider settings = SettingsProvider();
    await settings.load();
    expect(settings.equalizerEnabled, isTrue);
    expect(settings.equalizerBands, <double>[6, -3, 0, 0, 0]);
    expect(settings.equalizerPreset, 'Rock');
    expect(settings.equalizerBassEnabled, isTrue);
    expect(settings.equalizerBassStrength, 80);

    await settings.setEqualizer(
      enabled: false,
      bands: const <double>[1, 2, 3],
      preset: SettingsProvider.equalizerCustomPreset,
      bassEnabled: false,
      bassStrength: 45,
    );
    final SettingsProvider reloaded = SettingsProvider();
    await reloaded.load();
    expect(reloaded.equalizerEnabled, isFalse);
    expect(reloaded.equalizerBands, <double>[1, 2, 3]);
    expect(
      reloaded.equalizerPreset,
      SettingsProvider.equalizerCustomPreset,
    );
    expect(reloaded.equalizerBassStrength, 45);
  });

  test('disco corrompido do equalizador cai nos defaults', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'equalizer_bands': <String>['NaN', '99', '1', 'abc', 'x'],
      'equalizer_preset': 'PresetQueNaoExiste',
      'equalizer_bass_strength': 999,
    });
    final SettingsProvider corrupted = SettingsProvider();
    await corrupted.load();
    expect(corrupted.equalizerBands, <double>[0, 15, 1]);
    expect(corrupted.equalizerPreset, SettingsProvider.equalizerDefaultPreset);
    expect(corrupted.equalizerBassStrength, 100);
    expect(corrupted.equalizerEnabled, isFalse);

    // Lista grande demais → 5 bandas planas.
    SharedPreferences.setMockInitialValues(<String, Object>{
      'equalizer_bands': List<String>.filled(12, '1.0'),
    });
    final SettingsProvider oversized = SettingsProvider();
    await oversized.load();
    expect(
      oversized.equalizerBands,
      <double>[0, 0, 0, 0, 0],
    );
  });

  // ------------------------------------------------------------------
  // EqualizerProvider (delegação serviço + persistência)
  // ------------------------------------------------------------------

  test('EqualizerProvider aplica no serviço e persiste', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SettingsProvider settings = SettingsProvider();
    await settings.load();
    final AudioService audio = AudioService();
    final EqualizerProvider provider = EqualizerProvider(
      audio: audio,
      settings: settings,
    );

    await provider.setEqualizerEnabled(true);
    await provider.setBand(2, 5);
    expect(provider.preset, SettingsProvider.equalizerCustomPreset);
    expect(audio.equalizerSettings.enabled, isTrue);
    expect(audio.equalizerSettings.bands[2], 5);
    expect(settings.equalizerPreset, SettingsProvider.equalizerCustomPreset);

    await provider.applyPreset('Rock');
    expect(provider.preset, 'Rock');
    expect(
      audio.equalizerSettings.bands,
      SettingsProvider.equalizerPresets['Rock'],
    );
    expect(settings.equalizerBands, SettingsProvider.equalizerPresets['Rock']);

    await provider.setBassEnabled(true);
    await provider.setBassStrength(80);
    expect(audio.equalizerSettings.bassEnabled, isTrue);
    expect(audio.equalizerSettings.bassStrength, 80);
    expect(settings.equalizerBassStrength, 80);

    // Override de suporte: probe curto-circuita sem tocar canal.
    provider.debugOverrideSupport(EqualizerSupport.supported);
    expect(provider.support, EqualizerSupport.supported);
    expect(await provider.probe(), EqualizerSupport.supported);

    provider.dispose();
    expect(audio.onEqualizerSupportChanged, isNull);
    await audio.dispose();
  });

  test('EqualizerProvider restaura estado ligado no boot', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'equalizer_enabled': true,
      'equalizer_bands': <String>['7.0', '0.0', '0.0', '0.0', '0.0'],
      'equalizer_preset': 'Graves',
      'equalizer_bass_enabled': true,
      'equalizer_bass_strength': 30,
    });
    final SettingsProvider settings = SettingsProvider();
    await settings.load();
    final AudioService audio = AudioService();
    final EqualizerProvider provider = EqualizerProvider(
      audio: audio,
      settings: settings,
    );
    await pumpEventQueue();

    expect(provider.enabled, isTrue);
    expect(provider.bands.first, 7);
    expect(provider.preset, 'Graves');
    expect(provider.bassStrength, 30);
    // Serviço espelha o estado (pré-ativação: local).
    expect(audio.equalizerSettings.enabled, isTrue);
    expect(audio.equalizerSettings.bands.first, 7);

    provider.dispose();
    await audio.dispose();
  });

  // ------------------------------------------------------------------
  // Tela própria (widget)
  // ------------------------------------------------------------------

  testWidgets('tela: suporte conhecido — mestre, presets, bandas e graves',
      (WidgetTester tester) async {
    // Viewport alto: a lista da tela inteira cabe sem scroll (ListView é
    // lazy e itens fora da tela não existem na árvore).
    tester.view.physicalSize = const Size(1080, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SettingsProvider settings = SettingsProvider();
    await settings.load();
    final AudioService audio = AudioService();
    final EqualizerProvider provider = EqualizerProvider(
      audio: audio,
      settings: settings,
    );
    provider.debugOverrideSupport(EqualizerSupport.supported);
    addTearDown(provider.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<EqualizerProvider>.value(
        value: provider,
        child: const MaterialApp(home: EqualizerScreen()),
      ),
    );
    await tester.pump();

    // Mestre desligado: só o aviso, sem controles.
    expect(find.text('Bandas'), findsNothing);
    expect(find.textContaining('Ligue para ajustar'), findsOneWidget);

    // Liga o mestre → presets/bandas/graves aparecem.
    await tester.tap(find.byType(Switch).first);
    await tester.pump();
    expect(find.text('Bandas'), findsOneWidget);
    expect(find.text('Rock'), findsOneWidget);
    expect(find.byType(Slider), findsNWidgets(5));

    // Preset muda provider + serviço + disco de uma vez.
    await tester.tap(find.text('Rock'));
    await tester.pump();
    expect(provider.preset, 'Rock');
    expect(
      audio.equalizerSettings.bands,
      SettingsProvider.equalizerPresets['Rock'],
    );
    expect(settings.equalizerPreset, 'Rock');

    // Mexer numa banda manualmente vira "Personalizado" (sem arrastar o
    // slider — a lógica de estado é do provider).
    await provider.setBand(0, 8);
    await tester.pump();
    expect(provider.preset, SettingsProvider.equalizerCustomPreset);
    expect(find.text(SettingsProvider.equalizerCustomPreset), findsOneWidget);

    // Reforço de graves: liga o mestre do grave → ganha slider de força.
    await tester.tap(find.text('Reforço de graves'));
    await tester.pump();
    expect(provider.bassEnabled, isTrue);
    expect(settings.equalizerBassEnabled, isTrue);
    expect(find.byType(Slider), findsNWidgets(6));
  });

  testWidgets('tela: aparelho sem suporte mostra estado desligado',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final SettingsProvider settings = SettingsProvider();
    await settings.load();
    final AudioService audio = AudioService();
    final EqualizerProvider provider = EqualizerProvider(
      audio: audio,
      settings: settings,
    );
    provider.debugOverrideSupport(EqualizerSupport.unsupported);
    addTearDown(provider.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<EqualizerProvider>.value(
        value: provider,
        child: const MaterialApp(home: EqualizerScreen()),
      ),
    );
    await tester.pump();

    expect(find.text('Equalizador indisponível'), findsOneWidget);
    expect(find.textContaining('checado em runtime'), findsOneWidget);
    expect(find.byType(Switch), findsNothing);
    expect(find.byType(Slider), findsNothing);
  });
}
