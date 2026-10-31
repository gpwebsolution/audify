import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:permission_handler/permission_handler.dart';

import 'error_log_service.dart';

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

  // =====================================================================
  // PEDIDOS POR CONTEXTO (item 1.11) — sem rajada no boot
  // =====================================================================
  //
  // O boot pede APENAS áudio (on_audio_query, [requestAudioAccess]).
  // Cada permissão sensível é pedida quando o usuário entra no contexto
  // que a usa:
  //  - fotos/vídeos: na própria aba, depois da tela explicativa da aba
  //    ([requestPhotosAccess]/[requestVideosAccess]);
  //  - POST_NOTIFICATIONS: no primeiro play ([requestNotificationAccess]).
  //
  // NÃO usamos a string do SO para decidir a versão: no MIUI/HyperOS o
  // `Platform.operatingSystemVersion` não contém "Android" (ex.:
  // "TKQ1.221114.001 test-keys") e a detecção por parsing falhava, pedindo
  // a permissão errada. O mapeamento correto por API level é interno do
  // permission_handler.

  /// Lote pedido ao abrir a aba Galeria: SÓ fotos. A notificação de mídia
  /// não entra (era pedida junto aqui e no boot — rajada); ela é pedida
  /// no primeiro play, em [requestNotificationAccess].
  static const List<Permission> photosTabPermissions = <Permission>[
    Permission.photos,
  ];

  /// Lote pedido ao abrir a aba Vídeos: só vídeos (Android 13+ separa
  /// READ_MEDIA_VIDEO; antes, o permission_handler mapeia para
  /// READ_EXTERNAL_STORAGE — mesma permissão única).
  static const List<Permission> videosTabPermissions = <Permission>[
    Permission.videos,
  ];

  /// Lote do POST_NOTIFICATIONS: pedido UMA vez, no primeiro play.
  static const List<Permission> firstPlayNotificationPermissions = <Permission>[
    Permission.notification,
  ];

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

  /// Solicita APENAS o acesso às fotos ([photosTabPermissions]).
  ///
  /// Espelha [requestVideosAccess]: o diálogo do sistema aparece na aba
  /// Galeria (item 1.11), depois que a tela explicativa já foi montada —
  /// nunca no boot. A notificação de mídia não acompanha mais este lote.
  static Future<bool> requestPhotosAccess() async {
    if (!Platform.isAndroid) return true;
    if (await hasPhotosAccess()) return true;

    try {
      await photosTabPermissions.request();
    } catch (e) {
      debugPrint('[PermissionService] Falha ao pedir fotos: $e');
    }
    return hasPhotosAccess();
  }

  /// True se o app pode postar notificações (necessário para a notificação
  /// de mídia do audio_service na tela de bloqueio, Android 13+).
  static Future<bool> hasNotificationAccess() async {
    if (!Platform.isAndroid) return false;
    return Permission.notification.isGranted;
  }

  /// Cache de "já perguntou nesta sessão" (item 1.11): o POST_NOTIFICATIONS
  /// é pedido uma única vez — no primeiro play — e nunca no boot.
  static bool _notificationAsked = false;

  /// Decide (função pura — testável) se o POST_NOTIFICATIONS deve ser
  /// pedido AGORA: só no Android, só na primeira chance da sessão e só
  /// se a permissão ainda não foi concedida.
  static bool shouldRequestNotification({
    required bool isAndroid,
    required bool askedThisSession,
    required bool granted,
  }) => isAndroid && !askedThisSession && !granted;

  /// Pede POST_NOTIFICATIONS — item 1.11: o PlayerProvider dispara no
  /// primeiro play; o boot nunca pede (a notificação de mídia só faz
  /// sentido quando o player está em uso). Idempotente por sessão e
  /// tolerante a falha: permissão é conforto, não requisito.
  static Future<void> requestNotificationAccess() async {
    try {
      final bool isAndroid = Platform.isAndroid && !kIsWeb;
      // Fora do Android não há canal a tocar (e nada a pedir).
      final bool granted = isAndroid
          ? await Permission.notification.isGranted
          : true;
      if (!shouldRequestNotification(
        isAndroid: isAndroid,
        askedThisSession: _notificationAsked,
        granted: granted,
      )) {
        return;
      }
      _notificationAsked = true;
      await firstPlayNotificationPermissions.request();
    } catch (e, s) {
      debugPrint('[PermissionService] Falha ao pedir notificação: $e');
      ErrorLogService.logSync('perm/notification', e, s);
    }
  }

  /// True se o app pode LER os vídeos do aparelho (READ_MEDIA_VIDEO no
  /// Android 13+, READ_EXTERNAL_STORAGE antes — mapeado pelo plugin).
  static Future<bool> hasVideosAccess() async {
    if (!Platform.isAndroid) return false;
    return Permission.videos.isGranted;
  }

  /// Solicita APENAS os vídeos ([videosTabPermissions]). Usado quando o
  /// usuário abre a aba Vídeos sem permissão — o dialog do sistema aparece
  /// na aba (item 1.11), depois da tela explicativa, nunca no boot. A
  /// notificação de mídia não acompanha este lote (vai no primeiro play).
  static Future<bool> requestVideosAccess() async {
    if (!Platform.isAndroid) return true;
    if (await hasVideosAccess()) return true;

    try {
      await videosTabPermissions.request();
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

    final PermissionStatus status = await Permission.manageExternalStorage
        .request();
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
      final PermissionStatus status = await Permission
          .ignoreBatteryOptimizations
          .request();
      return status.isGranted;
    } catch (e) {
      debugPrint('[PermissionService] battery request falhou: $e');
      return false;
    }
  }
}
