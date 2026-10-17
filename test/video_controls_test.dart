// Item 6.2 — testes diretos dos widgets extraídos de video_player_screen.dart
// (VideoControlsBar, VideoVolumeOsd, VideoErrorState).
//
// A caracterização prévia cobre só o estado de erro (via tela — o player não
// sobe em host sem decoder). Estes testes protegem o contrato dos controles e
// do OSD que antes eram privados da tela: callbacks, tempos formatados,
// tooltips e alternância de estado visível.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:audify/widgets/video_controls.dart';

void main() {
  testWidgets('VideoControlsBar: tempos, transporte, velocidade e volume', (
    WidgetTester t,
  ) async {
    int toggles = 0;
    int previous = 0;
    int next = 0;
    int muteToggles = 0;
    final List<Duration> seekStarts = <Duration>[];
    final List<Duration> seekUpdates = <Duration>[];
    final List<Duration> seekEnds = <Duration>[];
    double? lastVolume;
    double? lastSpeed;

    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VideoControlsBar(
            position: const Duration(seconds: 30),
            duration: const Duration(minutes: 3),
            isPlaying: false,
            speed: 1.0,
            volume: 0.5,
            onTogglePlay: () => toggles++,
            onPrevious: () => previous++,
            onNext: () => next++,
            onSeekStart: seekStarts.add,
            onSeekUpdate: seekUpdates.add,
            onSeekEnd: seekEnds.add,
            onSpeedSelected: (double s) => lastSpeed = s,
            onVolumeChanged: (double v) => lastVolume = v,
            onToggleMute: () => muteToggles++,
          ),
        ),
      ),
    );

    // Tempos formatados nos extremos do seek.
    expect(find.text('00:30'), findsOneWidget);
    expect(find.text('03:00'), findsOneWidget);

    // Transporte — isPlaying false mostra "Tocar".
    await t.tap(find.byTooltip('Tocar'));
    expect(toggles, 1);
    await t.tap(find.byTooltip('Anterior'));
    expect(previous, 1);
    await t.tap(find.byTooltip('Próximo'));
    expect(next, 1);

    // Velocidade: abre o menu e aplica a escolha.
    await t.tap(find.byTooltip('Velocidade 1.0x'));
    await t.pumpAndSettle();
    await t.tap(find.text('1.5x'));
    await t.pumpAndSettle();
    expect(lastSpeed, 1.5);

    // Volume: botão de mudo + slider (2º Slider da árvore — o 1º é o seek).
    await t.tap(find.byTooltip('Silenciar'));
    expect(muteToggles, 1);
    await t.drag(find.byType(Slider).at(1), const Offset(60, 0));
    expect(lastVolume, isNotNull);

    // Seek: arrastar dispara start/update/end com valores dentro da duração.
    await t.drag(find.byType(Slider).at(0), const Offset(120, 0));
    expect(seekStarts, isNotEmpty);
    expect(seekUpdates, isNotEmpty);
    expect(seekEnds, isNotEmpty);
    for (final Duration d in <Duration>[...seekStarts, ...seekUpdates, ...seekEnds]) {
      expect(d.inMilliseconds, inInclusiveRange(0, const Duration(minutes: 3).inMilliseconds));
    }
  });

  testWidgets('VideoVolumeOsd: sem mensagem fica invisível; com valor mostra', (
    WidgetTester t,
  ) async {
    await t.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: VideoVolumeOsd(message: null, volume: 0.5),
        ),
      ),
    );
    AnimatedOpacity opacity = t.widget<AnimatedOpacity>(find.byType(AnimatedOpacity));
    expect(opacity.opacity, 0);
    expect(find.text('70%'), findsNothing);

    await t.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: VideoVolumeOsd(message: '70%', volume: 0.7),
        ),
      ),
    );
    opacity = t.widget<AnimatedOpacity>(find.byType(AnimatedOpacity));
    expect(opacity.opacity, 1);
    expect(find.text('70%'), findsOneWidget);
  });

  testWidgets('VideoErrorState: ícone e mensagem centralizados', (
    WidgetTester t,
  ) async {
    await t.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: VideoErrorState(message: 'Arquivo não encontrado no aparelho.'),
        ),
      ),
    );
    expect(find.byIcon(Icons.videocam_off_outlined), findsOneWidget);
    expect(find.text('Arquivo não encontrado no aparelho.'), findsOneWidget);
  });
}
