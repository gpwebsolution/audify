// Item de manutenção — reprodução do erro de ciclo de vida reportado no
// fluxo da marca d'água: o `TextEditingController` era descartado no momento
// do pop, com o diálogo ainda na animação de saída → "controller used after
// being disposed" → cascata até o assert `_dependents.isEmpty`
// (InheritedElement.debugDeactivated) que o dono viu na tela.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:audify/models/gallery_image_model.dart';
import 'package:audify/screens/photo_viewer_screen.dart';
import 'package:audify/services/image_actions_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory workDir;

  setUp(() {
    workDir = Directory.systemTemp.createTempSync('audify_wm_ui');
    WatermarkService.setOutputDirForTesting(workDir);
  });

  tearDown(() {
    workDir.deleteSync(recursive: true);
    WatermarkService.setOutputDirForTesting(Directory.systemTemp);
  });

  GalleryImage makeImage() {
    final img.Image frame = img.Image(width: 320, height: 240);
    img.fill(frame, color: img.ColorRgb8(120, 160, 90));
    final File file = File('${workDir.path}/IMG_TESTE.jpg');
    file.writeAsBytesSync(img.encodeJpg(frame, quality: 90));
    return GalleryImage(
      id: 1,
      name: 'IMG_TESTE.jpg',
      path: file.path,
      size: file.lengthSync(),
      dateAdded: 0,
      width: 320,
      height: 240,
    );
  }

  Future<void> openWatermarkDialog(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PhotoViewerScreen(images: [makeImage()], initialIndex: 0),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Ações da foto'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Marca d’água'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
  }

  testWidgets('cancelar o diálogo não lança erro de ciclo de vida', (
    WidgetTester tester,
  ) async {
    await openWatermarkDialog(tester);

    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('aplicar com texto vazio não lança erro de ciclo de vida', (
    WidgetTester tester,
  ) async {
    await openWatermarkDialog(tester);

    await tester.tap(find.text('Aplicar'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('aplicar com texto gera a cópia sem erro de ciclo de vida', (
    WidgetTester tester,
  ) async {
    await openWatermarkDialog(tester);

    await tester.enterText(find.byType(TextField), '© Meu estúdio');
    await tester.pumpAndSettle();

    await tester.runAsync(() async {
      await tester.tap(find.text('Aplicar'));
      // As continuações do pop do diálogo vivem na zona fake do teste: só
      // descarregam num `pump`. O isolate do `compute` trabalha em tempo
      // real — o laço intercala tempo real (isolate) e `pump` (microtasks
      // fake + frames) até a cópia ser anunciada.
      bool ready = false;
      for (int i = 0; i < 120 && !ready; i++) {
        // Tempo REAL: o isolate do compute trabalha.
        await Future<void>.delayed(const Duration(milliseconds: 100));
        // Tempo FAKE: animação de saída do diálogo e microtasks das
        // continuações do pop só andam com relógio do teste avançado.
        await tester.pump(const Duration(milliseconds: 50));
        ready =
            find.textContaining('Cópia salva').evaluate().isNotEmpty ||
            find.textContaining('Não foi possível').evaluate().isNotEmpty;
      }
      await tester.pumpAndSettle();
    });

    expect(tester.takeException(), isNull);
    expect(
      find.textContaining('Cópia salva'),
      findsOneWidget,
      reason: 'a cópia deveria ser gerada e anunciada no snack',
    );

    final List<FileSystemEntity> out = workDir.listSync(recursive: true);
    expect(
      out.any((FileSystemEntity e) => e.path.endsWith('-marcada.jpg')),
      isTrue,
      reason: 'a cópia com marca d’água deveria existir',
    );
  });
}
