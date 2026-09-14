import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Resultado da exclusão de uma mídia do aparelho.
enum DeleteResult {
  /// Usuário confirmou a exclusão no diálogo do sistema.
  deleted,

  /// Usuário cancelou o diálogo do sistema.
  cancelled,

  /// Falha ao excluir (arquivo inacessível, erro de plataforma).
  failed,
}

/// Exclusão de mídia do MediaStore via canal nativo (`audify/media_delete`).
///
/// No Android 11+ o sistema mostra o diálogo de confirmação
/// (MediaStore.createDeleteRequest) — o resultado é assíncrono e pode ser
/// cancelado pelo usuário. Em versões legadas a exclusão é direta.
class MediaDeleteRepository {
  static const MethodChannel _channel = MethodChannel('audify/media_delete');

  /// Exclui uma mídia do aparelho.
  ///
  /// [type]: 'audio' | 'video' | 'image' | 'pdf'.
  /// [id]: id no MediaStore (opcional se [path] for informado).
  /// [path]: caminho do arquivo (usado para PDFs do seletor SAF).
  static Future<DeleteResult> delete({
    required String type,
    int? id,
    String? path,
  }) async {
    try {
      final bool? deleted = await _channel.invokeMethod<bool>(
        'delete',
        {'type': type, 'id': id, 'path': path},
      );
      return deleted == true ? DeleteResult.deleted : DeleteResult.cancelled;
    } on PlatformException catch (e) {
      // Erro de plataforma (ex.: mídia já removida do MediaStore).
      debugPrint('MediaDeleteRepository: ${e.message}');
      return DeleteResult.failed;
    } catch (e) {
      debugPrint('MediaDeleteRepository: $e');
      return DeleteResult.failed;
    }
  }
}