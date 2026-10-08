import 'package:audify/models/media_ref.dart';
import 'package:audify/models/pdf_file_model.dart';
import 'package:audify/models/song_model.dart';
import 'package:audify/services/media_delete_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:on_audio_query/on_audio_query.dart';

/// Testes da lógica pura do serviço unificado de exclusão.
///
/// O foco é a LEITURA do resultado nativo: a regra que garante que o app
/// nunca reporte "excluído" sem confirmação. Não há canal nativo aqui —
/// por isso [MediaDeleteService.parseResult] é testável em isolamento.
void main() {
  final MediaRef audio = MediaRef.audio(mediaId: 7, path: '/sd/Music/a.mp3');
  final MediaRef video = MediaRef.video(mediaId: 8, path: '/sd/DCIM/v.mp4');
  final MediaRef image = MediaRef.image(mediaId: 9, path: '/sd/DCIM/i.jpg');
  final List<MediaRef> all = <MediaRef>[audio, video, image];

  group('MediaRef', () {
    test('chave usa uri explícita quando existe', () {
      const MediaRef ref = MediaRef(
        kind: MediaKind.audio,
        uri: 'content://media/external/audio/media/42',
        mediaId: 42,
      );
      expect(ref.key, 'content://media/external/audio/media/42');
    });

    test('chave cai para tipo:id e depois para o caminho', () {
      expect(audio.key, 'audio:7');
      expect(
        MediaRef.pdf(path: '/sd/Downloads/doc.pdf').key,
        '/sd/Downloads/doc.pdf',
      );
    });

    test('item sem id, uri ou caminho não é resolvível', () {
      expect(const MediaRef(kind: MediaKind.other).isResolvable, isFalse);
      expect(audio.isResolvable, isTrue);
    });

    test('payload enviado ao canal carrega tipo, id, uri e caminho', () {
      expect(audio.toPayload(), <String, Object?>{
        'type': 'audio',
        'id': 7,
        'uri': null,
        'path': '/sd/Music/a.mp3',
        'key': 'audio:7',
      });
    });

    test('PdfFile do SAF vira MediaRef sem id do MediaStore', () {
      final MediaRef picked = MediaRef.fromPdf(_pickedPdf());
      expect(picked.kind, MediaKind.pdf);
      expect(picked.mediaId, isNull);
      expect(picked.path, isNotEmpty);
    });

    test('PdfFile do MediaStore preserva o id numérico', () {
      expect(MediaRef.fromPdf(_mediaStorePdf()).mediaId, 555);
    });
  });

  group('parseResult — confirmações', () {
    test('lote inteiro confirmado vira sucesso completo', () {
      final DeleteResult result = MediaDeleteService.parseResult(
        <dynamic, dynamic>{
          'deleted': <String>['audio:7', 'video:8', 'image:9'],
          'failed': <Object>[],
          'cancelled': false,
          'permissionRequired': false,
        },
        all,
      );

      expect(result.deleted.length, 3);
      expect(result.failed, isEmpty);
      expect(result.isComplete, isTrue);
      expect(result.message, '3 arquivos excluídos.');
    });

    test('item único confirmado tem mensagem no singular', () {
      final DeleteResult result = MediaDeleteService.parseResult(
        <dynamic, dynamic>{
          'deleted': <String>['audio:7'],
          'failed': <Object>[],
        },
        <MediaRef>[audio],
      );
      expect(result.message, 'Arquivo excluído.');
    });
  });

  group('parseResult — falhas', () {
    test('item que o nativo não mencionou vira FALHA, nunca sucesso', () {
      // Este é o teste que trava a regressão que fazia o app dizer
      // "Arquivo excluído" sem o arquivo ter saído.
      final DeleteResult result = MediaDeleteService.parseResult(
        <dynamic, dynamic>{
          'deleted': <String>[],
          'failed': <Object>[],
          'cancelled': false,
        },
        <MediaRef>[audio],
      );

      expect(result.deleted, isEmpty);
      expect(result.failed.length, 1);
      expect(result.failed.single.ref, audio);
      expect(result.failed.single.reason, 'A exclusão não foi confirmada.');
      expect(result.isComplete, isFalse);
    });

    test('falha parcial preserva o apagado e reporta as duas situações', () {
      final DeleteResult result = MediaDeleteService.parseResult(
        <dynamic, dynamic>{
          'deleted': <String>['audio:7'],
          'failed': <Object>[
            <String, Object?>{
              'key': 'video:8',
              'reason': 'Conceda o acesso a "Todos os arquivos".',
            },
          ],
          'permissionRequired': true,
        },
        <MediaRef>[audio, video],
      );

      expect(result.deleted.single, audio);
      expect(result.failed.single.ref, video);
      expect(result.message, '1 excluído, 1 não pôde ser excluído.');
      expect(result.permissionRequired, isTrue);
      expect(result.isComplete, isFalse);
    });

    test('motivo vazio do nativo vira mensagem genérica', () {
      final DeleteResult result = MediaDeleteService.parseResult(
        <dynamic, dynamic>{
          'deleted': <String>[],
          'failed': <Object>[
            <String, Object?>{'key': 'video:8', 'reason': ''},
          ],
        },
        <MediaRef>[video],
      );
      expect(result.failed.single.reason, 'A exclusão não foi confirmada.');
    });

    test(
      'chave que o app não reconhece ainda vira falha com o motivo nativo',
      () {
        // O nativo pode reportar uma chave que o Dart não reconhece (ex.:
        // arquivo-indexado com id). O motivo não pode ser engolido.
        final DeleteResult result = MediaDeleteService.parseResult(
          <dynamic, dynamic>{
            'deleted': <String>[],
            'failed': <Object>[
              <String, Object?>{
                'key': 'other:42',
                'reason': 'Arquivo travado.',
              },
            ],
          },
          <MediaRef>[video],
        );

        final DeleteFailure unknown = result.failed.firstWhere(
          (DeleteFailure f) => f.ref.key == 'other:42',
        );
        expect(unknown.reason, 'Arquivo travado.');
      },
    );

    test('item pedido e não confirmado pelo nativo também vira falha', () {
      // O Dart pediu o vídeo, mas o nativo só reportou outro item: o vídeo
      // NÃO pode ser dado como excluído.
      final DeleteResult result = MediaDeleteService.parseResult(
        <dynamic, dynamic>{
          'deleted': <String>[],
          'failed': <Object>[
            <String, Object?>{'key': 'other:42', 'reason': 'Travado.'},
          ],
        },
        <MediaRef>[video],
      );

      expect(result.deleted, isEmpty);
      expect(
        result.failed.where((DeleteFailure f) => f.ref.key == 'video:8'),
        hasLength(1),
      );
    });
  });

  group('parseResult — cancelamento', () {
    test('cancelar não gera falha nem exclusão (UI fica intacta)', () {
      final DeleteResult result = MediaDeleteService.parseResult(
        <dynamic, dynamic>{
          'deleted': <String>[],
          'failed': <Object>[],
          'cancelled': true,
        },
        all,
      );

      expect(result.cancelledByUser, isTrue);
      expect(result.deleted, isEmpty);
      expect(result.failed, isEmpty);
      expect(result.cancelledWithoutChanges, isTrue);
      expect(result.message, 'Exclusão cancelada.');
    });
  });

  group('DeleteResult.message', () {
    test('erro de plataforma tem prioridade sobre tudo', () {
      const DeleteResult result = DeleteResult(
        deleted: <MediaRef>[],
        failed: <DeleteFailure>[],
        error: 'Falha inesperada',
      );
      expect(result.message, 'Falha inesperada');
      expect(result.isComplete, isFalse);
    });

    test('permissão faltando pede "Todos os arquivos"', () {
      final DeleteResult result = MediaDeleteService.parseResult(
        <dynamic, dynamic>{
          'deleted': <String>[],
          'failed': <Object>[
            <String, Object?>{'key': 'pdf:/sd/Doc.pdf', 'reason': 'x'},
          ],
          'permissionRequired': true,
        },
        <MediaRef>[const MediaRef(kind: MediaKind.pdf, path: '/sd/Doc.pdf')],
      );
      expect(result.message, contains('Todos os arquivos'));
    });
  });

  // ===================================================================
  // Regressão do defeito que fazia música e vídeo não excluírem no
  // Android 11+: o nativo devolvia `deleted: []` e `failed: []` depois do
  // diálogo do sistema, e o Dart reportava "não foi confirmada" para tudo.
  // ===================================================================
  group('regressão: diálogo do sistema sem veredito registrado', () {
    test('lote confirmado pelo SO volta como deleted, não como falha', () {
      // Payload que o Android 11+ produz depois de RESULT_OK.
      final DeleteResult result = MediaDeleteService.parseResult(
        <dynamic, dynamic>{
          'deleted': <String>['audio:7', 'video:8'],
          'notFound': <String>[],
          'failed': <Object>[],
          'cancelled': false,
          'permissionRequired': false,
        },
        <MediaRef>[audio, video],
      );

      expect(result.failed, isEmpty);
      expect(result.deleted.map((MediaRef r) => r.key), <String>[
        'audio:7',
        'video:8',
      ]);
      expect(result.removed.length, 2);
      expect(result.isComplete, isTrue);
      expect(result.message, '2 arquivos excluídos.');
    });

    test('item confirmado some da lista (removed) e habilita a limpeza', () {
      final DeleteResult result = MediaDeleteService.parseResult(
        <dynamic, dynamic>{
          'deleted': <String>['audio:7'],
          'notFound': <String>[],
          'failed': <Object>[],
          'cancelled': false,
        },
        <MediaRef>[audio],
      );
      expect(result.removed.single.key, 'audio:7');
      expect(result.message, 'Arquivo excluído.');
    });
  });

  group('notFound', () {
    test('já apagado por outro app sai em removed e limpa a UI', () {
      final DeleteResult result = MediaDeleteService.parseResult(
        <dynamic, dynamic>{
          'deleted': <String>[],
          'notFound': <String>['audio:7'],
          'failed': <Object>[],
          'cancelled': false,
        },
        <MediaRef>[audio],
      );

      expect(result.failed, isEmpty);
      expect(result.notFound.single.key, 'audio:7');
      // Não conta como "excluído", mas some do aparelho.
      expect(result.deleted, isEmpty);
      expect(result.removed.single.key, 'audio:7');
      expect(result.message, 'Arquivo excluído.');
    });

    test('payload antigo sem o campo notFound continua sendo lido', () {
      final DeleteResult result = MediaDeleteService.parseResult(
        <dynamic, dynamic>{
          'deleted': <String>['audio:7'],
          'failed': <Object>[],
          'cancelled': false,
        },
        <MediaRef>[audio],
      );
      expect(result.notFound, isEmpty);
      expect(result.deleted.single.key, 'audio:7');
    });

    test('mistura: 1 excluído + 1 ausente + 1 falha', () {
      final DeleteResult result = MediaDeleteService.parseResult(
        <dynamic, dynamic>{
          'deleted': <String>['audio:7'],
          'notFound': <String>['video:8'],
          'failed': <Object>[
            <String, Object?>{'key': 'image:9', 'reason': 'Arquivo protegido.'},
          ],
          'cancelled': false,
        },
        all,
      );

      expect(result.deleted.length, 1);
      expect(result.notFound.length, 1);
      expect(result.failed.length, 1);
      expect(result.failed.single.reason, 'Arquivo protegido.');
      expect(result.message, '2 excluídos, 1 sem sucesso.');
      // Cancelou nada, mas houve falha: não é completo.
      expect(result.isComplete, isFalse);
    });

    test('cancelamento não transforma notFound em falha', () {
      final DeleteResult result =
          MediaDeleteService.parseResult(<dynamic, dynamic>{
            'deleted': <String>[],
            'notFound': <String>[],
            'failed': <Object>[],
            'cancelled': true,
          }, all);
      expect(result.failed, isEmpty);
      expect(result.notFound, isEmpty);
      expect(result.cancelledWithoutChanges, isTrue);
    });
  });

  group('MediaRef.fromSong recusa faixa que não está no aparelho', () {
    test('faixa de asset nunca vira MediaRef (evita colisão de id)', () {
      expect(
        MediaRef.fromSong(Song.fromAsset(assetPath: 'assets/songs/demo.mp3')),
        isNull,
      );
    });

    test('faixa do MediaStore vira MediaRef com o id do sistema', () {
      final Song song = Song.fromMediaStore(_songModel(11, '/sd/Music/x.mp3'));
      final MediaRef? ref = MediaRef.fromSong(song);
      expect(ref, isNotNull);
      expect(ref!.mediaId, 11);
      expect(ref.key, 'audio:11');
    });

    test('faixa sem id e sem caminho é rejeitada', () {
      final Song? song = Song.fromStored(<String, Object?>{
        'song_id': 'media-0',
        'title': 'Sem metadado',
        'is_asset': 0,
      });
      expect(song, isNotNull);
      expect(MediaRef.fromSong(song!), isNull);
    });
  });
}

/// PdfFile do seletor SAF (sem id do MediaStore).
PdfFile _pickedPdf() =>
    PdfFile.fromPicked(path: '/sd/Downloads/Doc.pdf', name: 'Doc.pdf');

/// PdfFile vindo do MediaStore (id numérico).
PdfFile _mediaStorePdf() => PdfFile.fromChannel(<dynamic, dynamic>{
  'id': 555,
  'name': 'Doc.pdf',
  'path': '/sd/Downloads/Doc.pdf',
  'size': 1024,
  'dateAdded': 1700000000,
});

/// SongModel do on_audio_query (id do MediaStore + caminho em disco).
SongModel _songModel(int id, String data) => SongModel(<dynamic, dynamic>{
  '_id': id,
  '_data': data,
  '_display_name': 'Faixa$id.mp3',
  '_display_name_wo_ext': 'Faixa$id',
  '_size': 4096,
  'title': 'Faixa$id',
  'album': 'Álbum',
  'album_id': 3,
  'artist': 'Artista',
  'duration': 1000,
});
