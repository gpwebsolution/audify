// Testes do item 5.2 — parar o serviço depois de N minutos pausado.
//
// Mesmo contrato do timer de sono (3.1): deadline de RELÓGIO DE PAREDE
// com relógio injetado; os gatilhos que em produção vêm do listener de
// estado do player ([schedulePausedStop]/[cancelPausedStop]) são
// chamados direto nos testes, e [checkPausedStop] é chamado após
// avançar o relógio na mão.

import 'package:flutter_test/flutter_test.dart';

import 'package:audify/services/audio_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DateTime now;
  late AudioService svc;
  late int minutes;

  setUp(() async {
    now = DateTime(2026, 1, 1, 22);
    minutes = 30;
    svc = AudioService(
      clock: () => now,
      stopAfterPausedMinutes: () => minutes,
    );
    // Drena o replay assíncrono inicial do just_audio (estado idle) —
    // sem isso o evento chega depois do set manual de status e o
    // listener sobrescreve o cenário do teste.
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });

  tearDown(() async {
    await svc.dispose();
  });

  test('pausado agenda e o stop dispara exatamente no prazo', () async {
    svc.status.value = PlayerStatus.paused;
    svc.schedulePausedStop();

    // 29 min: ainda não.
    now = now.add(const Duration(minutes: 29));
    expect(await svc.checkPausedStop(), isFalse);
    expect(svc.status.value, PlayerStatus.paused);

    // Passou do prazo: para o serviço (status volta a idle).
    now = now.add(const Duration(minutes: 1));
    expect(await svc.checkPausedStop(), isTrue);
    expect(svc.status.value, PlayerStatus.idle);
  });

  test('cancelar (retomada) limpa o prazo: nada dispara', () async {
    svc.status.value = PlayerStatus.paused;
    svc.schedulePausedStop();
    svc.cancelPausedStop();

    now = now.add(const Duration(hours: 1));
    expect(await svc.checkPausedStop(), isFalse);
    expect(svc.status.value, PlayerStatus.paused);
  });

  test('desativar a preferência (0) no meio do prazo cancela sem parar', () async {
    svc.status.value = PlayerStatus.paused;
    svc.schedulePausedStop();

    minutes = 0; // usuário escolheu "Desligado" em Configurações
    now = now.add(const Duration(minutes: 45));
    expect(await svc.checkPausedStop(), isFalse);
    expect(svc.status.value, PlayerStatus.paused);

    // O prazo foi limpo: voltar para 30 e checar não dispara sozinho.
    minutes = 30;
    expect(await svc.checkPausedStop(), isFalse);
  });

  test('preferência 0 na origem: agendar é no-op', () async {
    minutes = 0;
    svc.status.value = PlayerStatus.paused;
    svc.schedulePausedStop();

    now = now.add(const Duration(hours: 2));
    expect(await svc.checkPausedStop(), isFalse);
    expect(svc.status.value, PlayerStatus.paused);
  });

  test('checagem fora da pausa cancela sem parar', () async {
    svc.status.value = PlayerStatus.paused;
    svc.schedulePausedStop();

    // Retomou sem passar pelo listener (caso-limite): a guarda do
    // próprio check impede o stop.
    svc.status.value = PlayerStatus.playing;
    now = now.add(const Duration(minutes: 40));
    expect(await svc.checkPausedStop(), isFalse);
    expect(svc.status.value, PlayerStatus.playing);
  });
}
