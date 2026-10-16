// Mock dos canais do just_audio (principal + por jogador + eventos) —
// simula um aparelho com/sem equalizador e captura as chamadas feitas
// pelo AudioService (load/seek/setLoopMode/setVolume/...), sem tocar em
// hardware. Compartilhado entre test_equalizer e testes do 3.4.
//
// O retorno de [mockJustAudio] é registrado via addTearDown — os canais
// são removidos ao fim de cada teste.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class JustAudioMock {
  JustAudioMock({
    this.minDb = -15,
    this.maxDb = 15,
    this.bandCount = 5,
    this.failGetParameters = false,
    this.missingGetParameters = false,
    this.autoReadyOnLoad = true,
    this.autoReadyDurationMs = 2000,
  });

  final double minDb;
  final double maxDb;
  final int bandCount;
  final bool failGetParameters;

  /// Simula o canal do equalizador SEM implementação nativa (a leitura do
  /// parâmetro responde "no implementation found", como num aparelho que
  /// não expõe o Equalizer do Android).
  final bool missingGetParameters;

  /// Emite um PlaybackEventMessage `ready` (processingState 3) logo após
  /// cada `load` — o nativo faz isso e o just_audio ESPERA esse evento
  /// (processingStateStream.firstWhere(!loading)) senão o load trava.
  final bool autoReadyOnLoad;

  /// Duração simulada emitida nesse evento (duração da fila carregada).
  final int autoReadyDurationMs;

  /// Todas as chamadas registradas (qualquer método), para asserts
  /// genéricos (ex.: conteúdo do 'init'/'load').
  final List<MethodCall> calls = <MethodCall>[];

  static const List<double> _centers = <double>[60, 230, 910, 3600, 14000];

  String? _playerId;

  /// Sink do EventChannel de eventos do jogador — permite EMITIR
  /// PlaybackEventMessage (transição de índice, erro, completed) nos
  /// testes.
  MockStreamHandlerEventSink? eventSink;

  /// Sink do EventChannel de dados (playing/volume/loopMode...).
  MockStreamHandlerEventSink? dataSink;

  String? get playerId => _playerId;

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

  /// Índices enviados em seek (na ordem das chamadas).
  List<int> get seekIndices => callsWhere('seek')
      .map((MethodCall c) => (c.arguments as Map)['index'] as int?)
      .whereType<int>()
      .toList();

  /// Monta um PlaybackEventMessage (formato do canal: processingState é
  /// o ÍNDICE do enum ProcessingStateMessage, updateTime em MILESSEGUNDOS
  /// e posições em microssegundos) para emitir pelo [eventSink].
  Map<dynamic, dynamic> playbackEvent({
    required int currentIndex,
    int processingState = 3, // ProcessingStateMessage.ready
    int positionMs = 0,
    int? durationMs,
    int? errorCode,
    String? errorMessage,
  }) {
    final int nowMs = DateTime.now().millisecondsSinceEpoch;
    return <dynamic, dynamic>{
      'processingState': processingState,
      'updateTime': nowMs,
      'updatePosition': positionMs * 1000,
      'bufferedPosition': positionMs * 1000,
      'icyMetadata': null,
      'duration': durationMs == null ? null : durationMs * 1000,
      'currentIndex': currentIndex,
      'androidAudioSessionId': null,
      'errorCode': errorCode,
      'errorMessage': errorMessage,
    };
  }

  /// Monta um PlayerDataMessage (canal data) para emitir pelo [dataSink].
  Map<dynamic, dynamic> playerData({bool? playing, double? volume}) =>
      <dynamic, dynamic>{
        'playing': ?playing,
        'volume': ?volume,
      };

  /// Agenda o evento `ready` de um load (o nativo emite após o player
  /// terminar de carregar). Enfileirado no EVENT loop (não microtask)
  /// para chegar depois de o cliente assinar o processingStateStream.
  void _scheduleAutoReady(MethodCall call) {
    if (!autoReadyOnLoad) return;
    final Map<Object?, Object?> args =
        call.arguments as Map<Object?, Object?>;
    final int index = (args['initialIndex'] as int?) ?? 0;
    final int positionMs = ((args['initialPosition'] as int?) ?? 0) ~/ 1000;
    Future<void>.delayed(Duration.zero, () {
      eventSink?.success(
        playbackEvent(
          currentIndex: index,
          processingState: 3, // ready
          positionMs: positionMs,
          durationMs: autoReadyDurationMs,
        ),
      );
    });
  }

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
      eventSink = null;
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
        if (call.method == 'load') _scheduleAutoReady(call);
        // Demais métodos (load, seek, setGain, setEnabled, dispose...):
        // payload vazio é válido para todos os Response do plugin.
        return <dynamic, dynamic>{};
      },
    );
    // Eventos: stream respondida — sem eventos por padrão; testes que
    // precisam de transição de índice/erro EMITEM via [eventSink].
    binding.defaultBinaryMessenger.setMockStreamHandler(
      EventChannel('com.ryanheise.just_audio.events.$id'),
      MockStreamHandler.inline(
        onListen: (Object? arguments, MockStreamHandlerEventSink events) {
          eventSink = events;
        },
      ),
    );
    binding.defaultBinaryMessenger.setMockStreamHandler(
      EventChannel('com.ryanheise.just_audio.data.$id'),
      MockStreamHandler.inline(
        onListen: (Object? arguments, MockStreamHandlerEventSink events) {
          dataSink = events;
        },
      ),
    );
  }
}

/// Instala o mock e registra o teardown automaticamente.
JustAudioMock mockJustAudio({
  double minDb = -15,
  double maxDb = 15,
  int bandCount = 5,
  bool failGetParameters = false,
  bool missingGetParameters = false,
  bool autoReadyOnLoad = true,
  int autoReadyDurationMs = 2000,
}) {
  final JustAudioMock mock = JustAudioMock(
    minDb: minDb,
    maxDb: maxDb,
    bandCount: bandCount,
    failGetParameters: failGetParameters,
    missingGetParameters: missingGetParameters,
    autoReadyOnLoad: autoReadyOnLoad,
    autoReadyDurationMs: autoReadyDurationMs,
  );
  addTearDown(mock.install());
  return mock;
}
