import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/media_ref.dart';
import 'error_log_service.dart';

/// Item que NÃO pôde ser excluído, com o motivo legível.
class DeleteFailure {
  final MediaRef ref;
  final String reason;

  const DeleteFailure(this.ref, this.reason);

  @override
  String toString() => 'DeleteFailure(${ref.key}: $reason)';
}

/// Resultado estruturado de [MediaDeleteService.deleteMedia].
///
/// Regra de ouro: um item só entra em [deleted] se o nativo CONFIRMOU que a
/// linha sumiu do MediaStore / o arquivo sumiu do disco. Nunca há "sucesso"
/// presumido.
class DeleteResult {
  /// Itens confirmados como removidos.
  final List<MediaRef> deleted;

  /// Itens que não estavam mais no aparelho quando a exclusão foi pedida.
  ///
  /// Não contam como falha: o objetivo do usuário (o arquivo não estar mais
  /// lá) já está satisfeito, então o item sai das listas do mesmo jeito.
  final List<MediaRef> notFound;

  /// Itens que permaneceram no aparelho, com o motivo.
  final List<DeleteFailure> failed;

  /// O usuário cancelou o diálogo do sistema.
  final bool cancelledByUser;

  /// O SO informou que falta a permissão de "Todos os arquivos".
  final bool permissionRequired;

  /// Erro de plataforma/canal ( impede qualquer conclusão confiável).
  final String? error;

  DeleteResult({
    required this.deleted,
    required this.failed,
    this.notFound = const <MediaRef>[],
    this.cancelledByUser = false,
    this.permissionRequired = false,
    this.error,
  });

  /// Resultado vazio (nada foi pedido).
  DeleteResult.empty()
    : deleted = const [],
      notFound = const [],
      failed = const [],
      cancelledByUser = false,
      permissionRequired = false,
      error = null;

  /// Total de itens informados pelo nativo (apagados + ausentes + com falha).
  int get total => deleted.length + notFound.length + failed.length;

  /// Itens que a UI pode limpar do seu estado com segurança.
  ///
  /// Inclui [deleted] e [notFound], mas [notFound] só entra depois de
  /// [confirmAbsent]: ver [confirmationSet].
  ///
  /// [cancelled], [failed] e [permissionRequired] NUNCA entram aqui — são os
  /// casos em que o arquivo continua no aparelho e limpar a lista produziria
  /// um item fantasma (aparência de exclusão sem exclusão).
  List<MediaRef> get removed => <MediaRef>[
    ...deleted,
    ...notFound.where((MediaRef r) => _absentConfirmed.contains(r.key)),
  ];

  /// Chaves de [notFound] que foram reconfirmadas como realmente ausentes.
  final Set<String> _absentConfirmed = <String>{};

  /// Autoriza a limpeza de estado para os itens `notFound` informados.
  ///
  /// A checagem autoritativa é do nativo (consultou o MediaStore). Ainda
  /// assim, [notFound] é revalidado contra o disco: se o arquivo estiver
  /// acessível e presente, o item NÃO é limpo e volta a ser falha.
  ///
  /// O teste é unilateral de propósito: `existsSync() == true` é prova de
  /// que o arquivo existe; `false` NÃO prova que sumiu (pode ser só falta de
  /// permissão de leitura), e nesse caso o nativo já Respond e a confiança é
  /// dele.
  void confirmAbsent(List<MediaRef> candidates) {
    for (final MediaRef ref in candidates) {
      final String? path = ref.path;
      if (path != null && path.isNotEmpty) {
        try {
          if (File(path).existsSync()) continue; // existe de verdade: não limpa
        } on FileSystemException {
          // Sem permissão para stat: mantém o veredito do nativo.
        }
      }
      _absentConfirmed.add(ref.key);
    }
  }

  /// True somente quando tudo que foi pedido saiu do aparelho.
  bool get isComplete =>
      error == null && failed.isEmpty && removed.isNotEmpty && !cancelledByUser;

  /// True quando nada saiu do aparelho (cancelamento ou falha total).
  bool get isEmpty => error != null || (removed.isEmpty && !cancelledByUser);

  /// Resumo em português para a SnackBar da UI.
  String get message {
    if (error != null) return error!;
    final int removedCount = removed.length;
    if (removedCount == 0) {
      if (cancelledByUser) return 'Exclusão cancelada.';
      if (permissionRequired) {
        return 'Conceda o acesso a "Todos os arquivos" para excluir '
            'documentos do aparelho.';
      }
      final DeleteFailure? first = failed.firstOrNull;
      return first?.reason ?? 'Não foi possível excluir o arquivo.';
    }
    if (failed.isEmpty) {
      return removedCount == 1
          ? 'Arquivo excluído.'
          : '$removedCount arquivos excluídos.';
    }
    return removedCount == 1
        ? '1 excluído, ${failed.length} não pôde ser excluído.'
        : '$removedCount excluídos, ${failed.length} sem sucesso.';
  }

  /// True quando o usuário cancelou e nada foi removido — a UI não deve
  /// mexer em nenhum estado nesse caso.
  bool get cancelledWithoutChanges => cancelledByUser && removed.isEmpty;
}

/// Exclusão unificada de mídia do aparelho (canal `audify/media_delete`).
///
/// Ponto único de entrada para foto, vídeo, música, PDF e "outros arquivos".
/// A estratégia por versão do Android vive inteiramente no lado nativo
/// (ver `MainActivity.deleteBatch`): esta classe só monta o payload e
/// interpreta a resposta estruturada.
///
/// Regras de leitura do resultado:
///  - [DeleteResult.deleted] só contém o que o nativo verificou;
///  - [DeleteResult.cancelledByUser] significa "não mexa na UI";
///  - nunca assumir sucesso a partir de um booleano genérico.
class MediaDeleteService {
  static const MethodChannel _channel = MethodChannel('audify/media_delete');

  /// Tempo máximo que o app espera o SO concluir a exclusão.
  ///
  /// A exclusão é assíncrona e passa por um diálogo do sistema: se algo
  /// travar do lado nativo (uma exceção depois do diálogo aberto, por
  /// exemplo), o Future ficaria pendurado para sempre e a tela pareceria
  /// travada. Com o timeout, o app sempre volta com uma resposta — e como
  /// volta com `failed`, NENHUMA lista é alterada.
  ///
  /// Generoso de propósito: o usuário pode demorar no diálogo do SO.
  /// Exposto para os testes poderem usar um valor pequeno.
  static Duration timeout = const Duration(seconds: 90);

  /// A exclusão via MediaStore só existe no Android.
  ///
  /// [isSupportedOverride] existe só para os testes: o runner roda em Linux,
  /// então sem a costura o canal nativo nunca seria exercitado e o teste
  /// passaria a testar apenas o caminho "não suportado".
  @visibleForTesting
  static bool? isSupportedOverride;

  static bool get isSupported =>
      isSupportedOverride ?? (!kIsWeb && Platform.isAndroid);

  /// Exclui [items] do aparelho. Suporta lote com UM único diálogo do
  /// sistema (Android 11+).
  static Future<DeleteResult> deleteMedia(List<MediaRef> items) async {
    if (items.isEmpty) return DeleteResult.empty();

    final List<MediaRef> resolvable = items
        .where((MediaRef i) => i.isResolvable)
        .toList();
    if (resolvable.isEmpty) {
      return DeleteResult(
        deleted: <MediaRef>[],
        failed: <DeleteFailure>[],
        error: 'Não foi possível identificar o arquivo no aparelho.',
      );
    }

    if (!isSupported) {
      return DeleteResult(
        deleted: const [],
        failed: resolvable
            .map(
              (MediaRef i) => DeleteFailure(
                i,
                'Exclusão disponível '
                'somente no Android.',
              ),
            )
            .toList(),
      );
    }

    try {
      final Map<dynamic, dynamic>? raw = await _channel
          .invokeMapMethod<dynamic, dynamic>('deleteBatch', <String, Object?>{
            'items': resolvable
                .map((MediaRef i) => i.toPayload())
                .toList(growable: false),
          })
          // Sem `onTimeout`: o padrão de Future.timeout lança TimeoutException,
          // capturada logo abaixo com a mensagem que o usuário entende.
          .timeout(timeout);
      if (raw == null) {
        return DeleteResult(
          deleted: const [],
          failed: resolvable
              .map(
                (MediaRef i) =>
                    DeleteFailure(i, 'O Android não respondeu à exclusão.'),
              )
              .toList(),
        );
      }
      return parseResult(raw, resolvable);
    } on TimeoutException catch (e) {
      // Todo item volta como `failed`: sem confirmação do SO, a UI não pode
      // limpar lista, fila, playlist nem sessão. O usuário recebe o motivo.
      debugPrint('[MediaDelete] timeout: $e');
      ErrorLogService.logSync(
        'media/delete',
        e,
        StackTrace.current,
      );
      return DeleteResult(
        deleted: const [],
        failed: resolvable
            .map(
              (MediaRef i) => DeleteFailure(
                i,
                'O Android não respondeu a tempo. '
                'Nada foi excluído — tente novamente.',
              ),
            )
            .toList(),
      );
    } on PlatformException catch (e, s) {
      debugPrint('[MediaDelete] falha de plataforma: ${e.message}');
      ErrorLogService.logSync('media/delete', e, s);
      return DeleteResult(
        deleted: const [],
        failed: resolvable
            .map(
              (MediaRef i) =>
                  DeleteFailure(i, e.message ?? 'Falha ao excluir.'),
            )
            .toList(),
      );
    } catch (e, s) {
      debugPrint('[MediaDelete] falha inesperada: $e');
      ErrorLogService.logSync('media/delete', e, s);
      return DeleteResult(
        deleted: const [],
        failed: resolvable
            .map((MediaRef i) => DeleteFailure(i, 'Falha inesperada: $e'))
            .toList(),
      );
    }
  }

  /// Converte a resposta nativa em [DeleteResult].
  ///
  /// Separado de [deleteMedia] e sem tocar no canal para poder ser testado
  /// em unidade. Regra conservadora: qualquer item que o nativo não
  /// confirmou como removido vira FALHA — nunca sucesso presumido.
  static DeleteResult parseResult(
    Map<dynamic, dynamic> raw,
    List<MediaRef> requested,
  ) {
    final Map<String, MediaRef> byKey = <String, MediaRef>{
      for (final MediaRef item in requested) item.key: item,
    };

    Set<String> keysOf(String field) => <String>{
      for (final Object? k in (raw[field] as List?) ?? const <Object?>[])
        if (k != null) '$k',
    };

    final Set<String> deletedKeys = keysOf('deleted');
    final Set<String> notFoundKeys = keysOf('notFound');
    final bool cancelled = raw['cancelled'] == true;
    final bool permissionRequired = raw['permissionRequired'] == true;

    final List<DeleteFailure> failed = <DeleteFailure>[];

    for (final Map<dynamic, dynamic> entry
        in (raw['failed'] as List?)?.cast<Map<dynamic, dynamic>>() ??
            const <Map<dynamic, dynamic>>[]) {
      final String key = '${entry['key'] ?? ''}';
      final String? reason = (entry['reason'] as String?)?.trim();
      final MediaRef? ref = byKey[key];
      // Item que o nativo nem mencionou = exclusão não confirmada.
      failed.add(
        DeleteFailure(
          ref ?? MediaRef.other(path: key),
          (reason == null || reason.isEmpty)
              ? 'A exclusão não foi confirmada.'
              : reason,
        ),
      );
    }

    final List<MediaRef> deleted = <MediaRef>[];
    final List<MediaRef> notFound = <MediaRef>[];
    for (final MediaRef item in requested) {
      if (deletedKeys.contains(item.key)) {
        deleted.add(item);
      } else if (notFoundKeys.contains(item.key)) {
        // Já não estava no aparelho: o objetivo do usuário já está atendido,
        // então entra em `removed` (limpa a UI) sem virar "excluído com sucesso".
        notFound.add(item);
      }
    }

    // Itens que o nativo não mencionou: ou o usuário cancelou (não é
    // falha) ou a exclusão simplesmente não foi confirmada (é falha).
    final Set<String> reported = <String>{
      ...deletedKeys,
      ...notFoundKeys,
      ...failed.map((DeleteFailure f) => f.ref.key),
    };
    for (final MediaRef item in requested) {
      if (reported.contains(item.key)) continue;
      if (cancelled) continue;
      failed.add(DeleteFailure(item, 'A exclusão não foi confirmada.'));
    }

    return DeleteResult(
      deleted: deleted,
      notFound: notFound,
      failed: failed,
      cancelledByUser: cancelled,
      permissionRequired: permissionRequired,
    );
  }
}
