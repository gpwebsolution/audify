import 'dart:async';
import 'dart:io';

import 'package:audify/models/media_ref.dart';
import 'package:audify/services/media_delete_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Testes do canal `audify/media_delete` com um MethodChannel FALSO.
///
/// O que se trava aqui é a tradução da resposta nativa em estado de UI — bem mais
/// perto do defeito real do que testar só `parseResult`: o canal de verdade é
/// chamado, incluindo o timeout de verdade.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('audify/media_delete');
  final MediaRef audio = MediaRef.audio(mediaId: 7, path: '/sd/Music/a.mp3');
  final MediaRef video = MediaRef.video(mediaId: 8, path: '/sd/Movies/v.mp4');
  final List<MediaRef> items = <MediaRef>[audio, video];

  late List<MethodCall> calls;
  late Duration savedTimeout;
  late bool? savedSupported;

  /// Payload bruto do nativo.
  Map<String, Object?> payload({
    List<String> deleted = const <String>[],
    List<String> notFound = const <String>[],
    List<Map<String, String>> failed = const <Map<String, String>>[],
    bool cancelled = false,
    bool permissionRequired = false,
  }) =>
      <String, Object?>{
        'deleted': deleted,
        'notFound': notFound,
        'failed': failed,
        'cancelled': cancelled,
        'permissionRequired': permissionRequired,
      };

  /// Instala um handler que responde o payload depois de [delay].
  void respondWith(
    Map<String, Object?> value, {
    Duration delay = Duration.zero,
  }) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call);
          if (delay > Duration.zero) await Future<void>.delayed(delay);
          return value;
        });
  }

  /// Handler que NUNCA responde — simula o nativo travado.
  void neverRespond() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call);
          await Completer<void>().future;
          return null;
        });
  }

  setUp(() {
    calls = <MethodCall>[];
    savedTimeout = MediaDeleteService.timeout;
    // O app real usa 90s; nos testes um valor curto torna o timeout testável.
    MediaDeleteService.timeout = const Duration(milliseconds: 150);
    // O runner não é Android: sem isto o serviço responderia "não suportado"
    // e o canal nativo nunca seria exercitado.
    savedSupported = MediaDeleteService.isSupportedOverride;
    MediaDeleteService.isSupportedOverride = true;
  });

  tearDown(() {
    MediaDeleteService.timeout = savedTimeout;
    MediaDeleteService.isSupportedOverride = savedSupported;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('MediaDeleteService.deleteMedia — canal', () {
    test('manda deleteBatch com o payload de cada item', () async {
      respondWith(payload(deleted: <String>['audio:7', 'video:8']));

      final DeleteResult result = await MediaDeleteService.deleteMedia(items);

      expect(calls.single.method, 'deleteBatch');
      final Map<Object?, Object?> args =
          calls.single.arguments as Map<Object?, Object?>;
      expect((args['items']! as List<Object?>).length, 2);
      expect(result.deleted.length, 2);
      expect(result.failed, isEmpty);
    });

    test('deleted: limpa o estado dos itens confirmados', () async {
      respondWith(payload(deleted: <String>['audio:7', 'video:8']));

      final DeleteResult result = await MediaDeleteService.deleteMedia(items);
      result.confirmAbsent(result.notFound);

      // Confirmado pelo SO → a UI pode limpar.
      expect(result.removed.length, 2);
      expect(result.removed.map((MediaRef r) => r.key).toSet(),
          <String>{'audio:7', 'video:8'});
      expect(result.message, '2 arquivos excluídos.');
    });

    test('failed: nada é limpo e o motivo chega ao usuário', () async {
      respondWith(
        payload(
          failed: <Map<String, String>>[
            <String, String>{
              'key': 'audio:7',
              'reason': 'O Android recusou a exclusão.',
            },
            <String, String>{'key': 'video:8', 'reason': 'Arquivo protegido.'},
          ],
        ),
      );

      final DeleteResult result = await MediaDeleteService.deleteMedia(items);
      result.confirmAbsent(result.notFound);

      expect(result.deleted, isEmpty);
      expect(result.removed, isEmpty);
      expect(result.failed.length, 2);
      expect(result.message, 'O Android recusou a exclusão.');
    });

    test('cancelled: nada muda e o usuário é avisado', () async {
      respondWith(payload(cancelled: true));

      final DeleteResult result = await MediaDeleteService.deleteMedia(items);
      result.confirmAbsent(result.notFound);

      expect(result.cancelledByUser, isTrue);
      expect(result.removed, isEmpty);
      expect(result.failed, isEmpty);
      expect(result.cancelledWithoutChanges, isTrue);
      expect(result.message, 'Exclusão cancelada.');
    });

    test('permissionRequired: nada é limpo e pede a permissão', () async {
      respondWith(
        payload(
          failed: <Map<String, String>>[
            <String, String>{
              'key': 'audio:7',
              'reason': 'Conceda o acesso a "Todos os arquivos".',
            },
          ],
          permissionRequired: true,
        ),
      );

      final DeleteResult result = await MediaDeleteService.deleteMedia(items);
      result.confirmAbsent(result.notFound);

      expect(result.permissionRequired, isTrue);
      expect(result.removed, isEmpty);
      expect(result.message, contains('Todos os arquivos'));
    });

    test('notFound: só limpa depois de reconfirmado no disco', () async {
      respondWith(payload(notFound: <String>['audio:7', 'video:8']));

      final DeleteResult result = await MediaDeleteService.deleteMedia(items);

      // Antes da reconfirmação, nada é limpo.
      expect(result.notFound.length, 2);
      expect(result.removed, isEmpty);

      // Os caminhos de /sd/Music e /sd/Movies não existem no host de teste,
      // então a ausência é confirmada e o estado pode ser limpo.
      result.confirmAbsent(result.notFound);
      expect(result.removed.length, 2);
    });

    test('notFound com arquivo AINDA existente não limpa o estado', () async {
      // Arquivo temporário de verdade: existe, então é prova de que o
      // item NÃO pode sair da lista.
      final Directory dir = Directory.systemTemp.createTempSync('audify');
      final File file = File('${dir.path}/ainda-aqui.mp3');
      file.writeAsStringSync('x');
      addTearDown(() {
        if (file.existsSync()) file.deleteSync();
        if (dir.existsSync()) dir.deleteSync();
      });

      final MediaRef alive = MediaRef.audio(
        mediaId: 99,
        path: file.path,
      );
      respondWith(payload(notFound: <String>[alive.key]));

      final DeleteResult result = await MediaDeleteService.deleteMedia(
        <MediaRef>[alive],
      );
      result.confirmAbsent(result.notFound);

      // O nativo disse notFound, mas o arquivo está lá: o veto impede a
      // limpeza e o item continua visível (sem item fantasma, e sem
      // esconder algo que o usuário precisa ver).
      expect(result.notFound.length, 1);
      expect(result.removed, isEmpty);
    });

    test('timeout: não trava e devolve failed com motivo claro', () async {
      neverRespond();

      final DeleteResult result = await MediaDeleteService.deleteMedia(items);

      expect(calls.length, 1, reason: 'a chamada foi realmente feita');
      expect(result.deleted, isEmpty);
      expect(result.notFound, isEmpty);
      expect(result.failed.length, 2, reason: 'todos os itens são failed');
      expect(result.removed, isEmpty);
      expect(result.message, contains('não respondeu a tempo'));
      expect(result.message, contains('Nada foi excluído'));
    });

    test('timeout não deixa o Future pendurado', () async {
      neverRespond();
      // Se o timeout não existisse, isto nunca completaria e o teste
      // terminaria por timeout do próprio runner em vez de passar.
      await expectLater(
        MediaDeleteService.deleteMedia(items).timeout(
          const Duration(seconds: 5),
        ),
        completes,
      );
    });

    test('resposta lenta DENTRO do prazo é aceita', () async {
      respondWith(
        payload(deleted: <String>['audio:7']),
        delay: const Duration(milliseconds: 40),
      );

      final DeleteResult result = await MediaDeleteService.deleteMedia(
        <MediaRef>[audio],
      );
      expect(result.deleted.single.key, 'audio:7');
    });

    test('resposta nativa null vira failed, não exceção', () async {
      // O SO pode responder `null` (ou um mapa vazio) sem quebrar o canal:
      // precisa virar falha clara, não um NoSuchMethodError.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            calls.add(call);
            return null;
          });

      final DeleteResult result = await MediaDeleteService.deleteMedia(items);
      expect(result.deleted, isEmpty);
      expect(result.failed.length, 2);
      expect(result.message, contains('não respondeu'));
    });

    test('PlatformException vira failed com a mensagem do SO', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            calls.add(call);
            throw PlatformException(code: 'boom', message: 'sem permissão');
          });

      final DeleteResult result = await MediaDeleteService.deleteMedia(items);
      expect(result.failed.length, 2);
      expect(result.message, 'sem permissão');
    });

    test('lista vazia não chama o canal', () async {
      respondWith(payload());
      final DeleteResult result =
          await MediaDeleteService.deleteMedia(const <MediaRef>[]);
      expect(calls, isEmpty);
      expect(result.total, 0);
    });

    test('item sem id, uri ou caminho é recusado antes do canal', () async {
      respondWith(payload());
      const MediaRef unresolvable = MediaRef(kind: MediaKind.audio);
      final DeleteResult result = await MediaDeleteService.deleteMedia(
        <MediaRef>[unresolvable],
      );
      expect(calls, isEmpty);
      expect(result.message, contains('Não foi possível identificar'));
    });
  });
}
