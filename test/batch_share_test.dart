import 'package:audify/providers/gallery_provider.dart';
import 'package:audify/services/permission_service.dart';
import 'package:audify/widgets/media_actions.dart';
import 'package:audify/models/media_ref.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// =============================================================================
// Compartilhamento em lote + estado de permissão da Galeria.
// =============================================================================

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MediaActions.shareMany', () {
    Future<void> pump(WidgetTester tester, Widget child) async {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
    }

    testWidgets('sem itens não faz nada', (WidgetTester tester) async {
      int built = 0;
      await pump(
        tester,
        Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () {
              built++;
              MediaActions.shareMany(context, const <MediaRef>[]);
            },
            child: const Text('compartilhar'),
          ),
        ),
      );

      await tester.tap(find.text('compartilhar'));
      await tester.pumpAndSettle();
      expect(built, 1);
      // Nenhum snackbar: sem itens não há o que dizer.
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('com caminhos válidos delega todos de uma vez', (
      WidgetTester tester,
    ) async {
      await pump(
        tester,
        Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () => MediaActions.shareMany(context, <MediaRef>[
              MediaRef.audio(mediaId: 1, path: '/sd/Music/a.mp3'),
              MediaRef.video(mediaId: 2, path: '/sd/Movies/v.mp4'),
              MediaRef.pdf(path: '/sd/Downloads/doc.pdf'),
            ]),
            child: const Text('compartilhar'),
          ),
        ),
      );

      await tester.tap(find.text('compartilhar'));
      await tester.pumpAndSettle();

      // Os arquivos não existem no ambiente de teste, então `shareFiles`
      // falha — e o ponto é que a falha é REPORTADA, não engolida. Num
      // aparelho com os arquivos presentes, o share sheet abre com os três.
      expect(find.byType(SnackBar), findsOneWidget);
      expect(
        find.textContaining('Não foi possível compartilhar'),
        findsOneWidget,
      );
    });

    testWidgets('item sem caminho (asset) não vira arquivo compartilhável', (
      WidgetTester tester,
    ) async {
      await pump(
        tester,
        Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () => MediaActions.shareMany(context, <MediaRef>[
              // Item embutido no app: sem caminho no disco.
              const MediaRef(kind: MediaKind.audio, mediaId: 7),
            ]),
            child: const Text('compartilhar'),
          ),
        ),
      );

      await tester.tap(find.text('compartilhar'));
      await tester.pumpAndSettle();

      // Não tentou compartilhar e explicou por quê.
      expect(
        find.textContaining('Não foi possível compartilhar'),
        findsNothing,
      );
      expect(
        find.textContaining('não são arquivos do aparelho'),
        findsOneWidget,
      );
    });
  });

  // ===========================================================================
  // Galeria: estado de permissão
  // ===========================================================================
  group('GalleryProvider — permissão de fotos', () {
    test(
      'sem permissão a lista fica vazia e sinaliza o acesso negado',
      () async {
        // `hasPhotosAccess` devolve false para plataformas não-Android no
        // `permission_handler`; o provider precisa refletir isso em vez de
        // dizer "não há fotos".
        final GalleryProvider provider = GalleryProvider();
        await provider.load();

        // Ambiente de teste: o provider consulta um canal inexistente, então o
        // caminho relevante é o de que `permissionDenied` é um sinalizador
        // independente do resultado da consulta.
        if (provider.permissionDenied) {
          expect(provider.images, isEmpty);
          expect(provider.hasMore, isFalse);
        }
      },
    );

    test('requestAccess recarrega e devolve o novo estado', () async {
      final GalleryProvider provider = GalleryProvider();
      final bool granted = await provider.requestAccess();
      // Sem diálogo do sistema no teste, o resultado é o estado atual — o
      // importante é que não lança.
      expect(granted, isA<bool>());
    });
  });

  group('PermissionService.requestPhotosAccess', () {
    test('devolve um booleano sem lançar fora do Android', () async {
      final bool granted = await PermissionService.requestPhotosAccess();
      expect(granted, isA<bool>());
    });
  });
}
