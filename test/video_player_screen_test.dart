// Item 6.2 — teste de caracterização da VideoPlayerScreen ANTES da extração
// de _ErrorState/_ControlsBar/_VolumeOsd.
//
// Em host não há decoder de vídeo: os dois caminhos de erro da tela são
// alcançáveis de verdade — arquivo inexistente (cheque de disco) e arquivo
// existente (controller sem plataforma nativa). Ambos devolvem o _ErrorState
// com a mensagem própria.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:audify/models/video_model.dart';
import 'package:audify/screens/video_player_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Video makeVideo(String path) => Video(
    id: 1,
    title: 'Vídeo de teste',
    displayName: 'video_teste.mp4',
    duration: const Duration(seconds: 12),
    path: path,
    size: 1024,
    dateAdded: 0,
  );

  Future<void> pumpScreen(WidgetTester tester, Video video) async {
    await tester.pumpWidget(
      MaterialApp(
        home: VideoPlayerScreen(queue: <Video>[video], initialIndex: 0),
      ),
    );
    // initState dispara _initController() async: File.exists() é I/O real e
    // o initialize() do controller fala com a plataforma — fora da zona
    // fake. runAsync dá o event loop real; os pumps seguintes consomem os
    // microtasks/frames.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('arquivo inexistente mostra o estado de erro da tela', (
    WidgetTester tester,
  ) async {
    await pumpScreen(tester, makeVideo('/nao/existe/audify_video.mp4'));

    expect(find.text('Arquivo não encontrado no aparelho.'), findsOneWidget);
    expect(find.byIcon(Icons.videocam_off_outlined), findsOneWidget);
    // Sem controller não há barra de controles nem OSD.
    expect(find.byIcon(Icons.play_arrow), findsNothing);
  });

  testWidgets('arquivo sem decoder nativo cai no erro de reprodução', (
    WidgetTester tester,
  ) async {
    final File file =
        File('${Directory.systemTemp.path}/audify_caract_video.mp4')
          ..writeAsBytesSync(<int>[0, 0, 0, 0]);
    addTearDown(() {
      if (file.existsSync()) file.deleteSync();
    });

    await pumpScreen(tester, makeVideo(file.path));

    expect(find.text('Não foi possível reproduzir este vídeo.'), findsOneWidget);
    expect(find.byIcon(Icons.videocam_off_outlined), findsOneWidget);
  });
}
