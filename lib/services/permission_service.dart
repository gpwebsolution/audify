import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:permission_handler/permission_handler.dart';

/// Resultado da solicitação de permissão de acesso a áudio.
enum AudioAccessResult {
  /// Usuário concedeu a permissão.
  granted,

  /// Usuário negou (pode ser pedida novamente).
  denied,

  /// Usuário negou com "não perguntar de novo" — só resolve indo em
  /// Configurações do sistema (ver [PermissionService.openSettings]).
  permanentlyDenied,
}

/// Solicita a permissão de leitura de músicas externas.
///
/// O fluxo usa o PermissionController NATIVO do on_audio_query, que escolhe
/// as permissões corretas pelo `Build.VERSION.SDK_INT` em Kotlin:
///  - Android 13+ (API 33): READ_MEDIA_AUDIO + READ_MEDIA_IMAGES
///  - Android <= 12 (API 32): READ/WRITE_EXTERNAL_STORAGE
///
/// Sem parse de versão do SO no Dart — o plugin decide no lado nativo.
/// O permission_handler é usado APENAS para classificar o desfecho
/// (negada simples vs. permanente) sem abrir dialog.
class PermissionService {
  static final OnAudioQuery _query = OnAudioQuery();

  /// Cache de concessão da sessão: evita re-solicitar/re-verificar toda
  /// vez que a tela reabre. O status real do sistema é a única verdade,
  /// mas este cache cobre o caso em que o status check do plugin é
  /// estrito demais para o SO (ex.: WRITE_EXTERNAL_STORAGE no API 30-32).
  static bool? _grantedThisSession;

  /// Solicita a permissão e retorna o desfecho para a UI decidir o feedback.
  static Future<AudioAccessResult> requestAudioAccess() async {
    debugPrint('[PermissionService] OS: ${Platform.operatingSystemVersion}');
    if (!Platform.isAndroid) return AudioAccessResult.granted;
    if (_grantedThisSession == true) return AudioAccessResult.granted;

    // Status real do sistema (não abre dialog).
    if (await _query.permissionsStatus()) {
      _grantedThisSession = true;
      return AudioAccessResult.granted;
    }

    // Solicita de verdade (dialog do sistema, se necessário).
    final bool granted = await _query.checkAndRequest(retryRequest: true);
    if (granted) {
      _grantedThisSession = true;
      return AudioAccessResult.granted;
    }

    // Classifica a negação sem abrir dialog (permission_handler).
    final PermissionStatus status = await _classifyPermission().status;
    if (status.isPermanentlyDenied) return AudioAccessResult.permanentlyDenied;
    return AudioAccessResult.denied;
  }

  /// Permissão usada para classificar a negação de áudio. O plugin mapeia
  /// [Permission.audio] para READ_MEDIA_AUDIO (API 33+) ou
  /// READ_EXTERNAL_STORAGE (antes) internamente — sem parsing de SO.
  static Permission _classifyPermission() => Permission.audio;

  /// Abre as Configurações do sistema (para casos de negação permanente).
  static Future<bool> openSettings() => openAppSettings();

  /// Solicita as permissões de mídia complementares (vídeo + galeria) via
/// permission_handler:
///  - [Permission.videos] + [Permission.photos] + [Permission.notification]:
///    UM dialog do sistema com fotos e vídeos (READ_MEDIA_VIDEO +
///    READ_MEDIA_IMAGES) + a notificação de mídia do audio_service
///    (tela de bloqueio);
///  - Em Android <= 12 o permission_handler mapeia videos/photos para
///    READ_EXTERNAL_STORAGE automaticamente (mesma permissão única).
///
/// NÃO usamos a string do SO para decidir a versão: no MIUI/HyperOS o
/// `Platform.operatingSystemVersion` não contém "Android" (ex.:
/// "TKQ1.221114.001 test-keys") e a detecção por parsing falhava, pedindo
/// a permissão errada. O mapeamento correto por API level é interno do
/// permission_handler.
///
/// A permissão de ÁUDIO já é resolvida pelo fluxo do on_audio_query
/// ([requestAudioAccess]); este grupo cobre o resto da biblioteca de mídia.
  static Future<void> requestMediaGroup() async {
    if (!Platform.isAndroid || kIsWeb) return;

    try {
      await [Permission.videos, Permission.photos, Permission.notification]
          .request();
    } catch (e) {
      debugPrint('[PermissionService] Falha ao pedir grupo de mídia: $e');
    }
  }

  /// True se o app pode LER as músicas do aparelho. Usa o mapeamento do
  /// permission_handler (READ_MEDIA_AUDIO no 13+, READ_EXTERNAL_STORAGE
  /// antes) — sem parsing de versão do SO.
  static Future<bool> hasAudioAccess() async {
    if (!Platform.isAndroid) return false;
    return Permission.audio.isGranted;
  }

  /// True se o app pode LER as fotos do aparelho.
  static Future<bool> hasPhotosAccess() async {
    if (!Platform.isAndroid) return false;
    return Permission.photos.isGranted;
  }

  /// True se o app pode postar notificações (necessário para a notificação
  /// de mídia do audio_service na tela de bloqueio, Android 13+).
  static Future<bool> hasNotificationAccess() async {
    if (!Platform.isAndroid) return false;
    return Permission.notification.isGranted;
  }

  /// True se o app pode LER os vídeos do aparelho (READ_MEDIA_VIDEO no
  /// Android 13+, READ_EXTERNAL_STORAGE antes — mapeado pelo plugin).
  static Future<bool> hasVideosAccess() async {
    if (!Platform.isAndroid) return false;
    return Permission.videos.isGranted;
  }

  /// Solicita APENAS os vídeos (e a notificação de mídia). Usado quando o
  /// usuário abre a aba Vídeos sem permissão — o dialog do sistema aparece
  /// na hora, sem depender da aba de Música ter sido aberta antes.
  static Future<bool> requestVideosAccess() async {
    if (!Platform.isAndroid) return true;
    if (await hasVideosAccess()) return true;

    try {
      await [Permission.videos, Permission.notification].request();
    } catch (e) {
      debugPrint('[PermissionService] Falha ao pedir vídeos: $e');
    }
    return hasVideosAccess();
  }

  /// True se o acesso especial "Todos os arquivos" está concedido.
  ///
  /// No Android 11+ é a ÚNICA forma de listar PDFs/documentos de outros
  /// apps via MediaStore (não existe permissão de documentos no Android).
  static Future<bool> hasAllFilesAccess() async {
    if (!Platform.isAndroid) return false;
    return Permission.manageExternalStorage.isGranted;
  }

  /// Abre a tela especial do sistema ("Todos os arquivos") e retorna o
  /// novo estado. O usuário sai do app momentaneamente — o caller deve
  /// recarregar a lista ao voltar.
  static Future<bool> requestAllFilesAccess() async {
    if (!Platform.isAndroid) return false;
    if (await hasAllFilesAccess()) return true;

    final PermissionStatus status =
        await Permission.manageExternalStorage.request();
    return status.isGranted;
  }

  // =====================================================================
  // OTIMIZAÇÃO DE BATERIA (segundo plano confiável)
  // =====================================================================

  /// True se o app já está isento da otimização de bateria do Android.
  ///
  /// Sem isenção, fabricantes (Xiaomi/MIUI, Samsung, Motorola...) matam
  /// o processo em segundos-minutos com o app em segundo plano — a música
  /// para sozinha e a notificação some, mesmo com foreground service.
  static Future<bool> isIgnoringBatteryOptimizations() async {
    if (!Platform.isAndroid || kIsWeb) return true;
    try {
      return await Permission.ignoreBatteryOptimizations.isGranted;
    } catch (e) {
      debugPrint('[PermissionService] battery check falhou: $e');
      return false;
    }
  }

  /// Abre o dialog nativo "Permitir que o Audify ignore a otimização de
  /// bateria?". Idempotente: se já concedido, não abre nada. Retorna o
  /// estado final.
  static Future<bool> requestIgnoreBatteryOptimizations() async {
    if (!Platform.isAndroid || kIsWeb) return true;
    try {
      if (await Permission.ignoreBatteryOptimizations.isGranted) return true;
      final PermissionStatus status =
          await Permission.ignoreBatteryOptimizations.request();
      return status.isGranted;
    } catch (e) {
      debugPrint('[PermissionService] battery request falhou: $e');
      return false;
    }
  }
}