# =====================================================================
# Regras R8/ProGuard do Audify (release minificado).
#
# O Flutter já injeta regras padrão do engine e dos plugins (consumer
# rules dos AARs). Aqui ficam os keeps EXPLÍCITOS para tudo que:
#   1. usa REFLEXÃO ou resolve classes/recursos por NOME em runtime
#      (invisível para o shrinker estático); ou
#   2. é citado em relatos oficiais de crash pós-minificação.
#
# Estratégia "over-keep": uso pessoal via sideload — estabilidade vale
# mais do que alguns KB de APK. Renomear/remover uma classe usada por
# MethodChannel nativo -> Dart derruba o app em release SEM log visível
# (exatamente o sintoma relatado: crash silencioso só no release).
# =====================================================================

# ---------------------------------------------------------------------
# audio_service + audio_session (com.ryanheise)
# Notificação de mídia, MediaSession e tela de bloqueio resolvem
# recursos/classes via getIdentifier e reflexão. Sem keep, a notificação
# quebra ou o foreground service crasha ao iniciar.
# ---------------------------------------------------------------------
-keep class com.ryanheise.audioservice.** { *; }
-keep class com.ryanheise.audio_session.** { *; }

# ---------------------------------------------------------------------
# on_audio_query / MediaStore (override local em third_party/)
# Consulta ao MediaStore + PermissionController nativo com callbacks
# registrados dinamicamente pelo Dart.
# ---------------------------------------------------------------------
-keep class com.lucasjosino.on_audio_query.** { *; }

# ---------------------------------------------------------------------
# audioplayers (xyz.luan.audioplayers)
# Canal de plataforma + ExoPlayer subjacente; callbacks nativos -> Dart
# por nome de método.
# ---------------------------------------------------------------------
-keep class xyz.luan.audioplayers.** { *; }

# ---------------------------------------------------------------------
# video_player (io.flutter.plugins.videoplayer) + ExoPlayer/Media3
# O plugin usa androidx.media3 (ExoPlayer). As AARs do Media3 trazem
# consumer rules próprias, mas o keep explícito cobre builds onde a
# versão do R8/agregação as ignora — causa conhecida de
# ClassNotFoundException em release minificado.
# ---------------------------------------------------------------------
-keep class io.flutter.plugins.videoplayer.** { *; }
-keep class androidx.media3.** { *; }
-dontwarn androidx.media3.**

# ---------------------------------------------------------------------
# sqflite (com.tekartik.sqflite)
# Banco SQLite acessado por MethodChannel; classes registradas por nome.
# ---------------------------------------------------------------------
-keep class com.tekartik.sqflite.** { *; }

# ---------------------------------------------------------------------
# file_picker (com.mr.flutter.plugin.filepicker)
# Reescrita recente do plugin; relatos de crash pós-R8 sem keep próprio.
# ---------------------------------------------------------------------
-keep class com.mr.flutter.plugin.filepicker.** { *; }
-dontwarn com.mr.flutter.plugin.filepicker.**

# ---------------------------------------------------------------------
# share_plus / package_info_plus / device_info_plus (dev.fluttercommunity.plus)
# Canais de plataforma com FileProvider e resolução de metadados.
# ---------------------------------------------------------------------
-keep class dev.fluttercommunity.plus.share.** { *; }
-keep class dev.fluttercommunity.plus.packageinfo.** { *; }
-keep class dev.fluttercommunity.plus.device_info.** { *; }
-keep class dev.fluttercommunity.plus.connectivity.** { *; }

# ---------------------------------------------------------------------
# open_filex (com.crazecoder.openfile)
# Usa FileProvider próprio + xml de paths resolvido por nome — o resource
# shrinker pode remover o xml se ninguém referenciar estaticamente.
# ---------------------------------------------------------------------
-keep class com.crazecoder.openfile.** { *; }
-keep class androidx.core.content.FileProvider { *; }
-keep class com.crazecoder.openfile.R$* { *; }

# ---------------------------------------------------------------------
# permission_handler (com.baseflow.permissionhandler)
# Enums de permissão mapeados por string entre Dart e nativo.
# ---------------------------------------------------------------------
-keep class com.baseflow.permissionhandler.** { *; }

# ---------------------------------------------------------------------
# shared_preferences / path_provider / url_launcher (io.flutter.plugins.*)
# Mantidos explicitamente: baratos e eliminam qualquer risco de o
# shrinker tocar nos canais básicos de infraestrutura.
# ---------------------------------------------------------------------
-keep class io.flutter.plugins.sharedpreferences.** { *; }
-keep class io.flutter.plugins.pathprovider.** { *; }
-keep class io.flutter.plugins.urllauncher.** { *; }
-keep class io.flutter.plugins.** { *; }

# ---------------------------------------------------------------------
# syncfusion_flutter_pdfviewer (com.syncfusion.flutter.pdfviewer)
# Módulo Android do visualizador de PDFs (canal nativo). O renderizador
# é Dart puro, mas o plugin Java precisa sobreviver intacto.
# ---------------------------------------------------------------------
-keep class com.syncfusion.flutter.pdfviewer.** { *; }

# ---------------------------------------------------------------------
# jni (com.github.dart_lang.jni) — usado pela pilha on_audio_query
# JNI por definição depende de nomes de classe/símbolo exatos.
# ---------------------------------------------------------------------
-keep class com.github.dart_lang.jni.** { *; }
-dontwarn com.github.dart_lang.jni.**

# ---------------------------------------------------------------------
# MainActivity do app + canais nativos locais
# ---------------------------------------------------------------------
-keep class com.example.music_app.MainActivity { *; }

# ---------------------------------------------------------------------
# Annotations/coroutines referenciadas indiretamente pelos plugins
# ---------------------------------------------------------------------
-dontwarn org.jetbrains.annotations.**
-dontwarn kotlinx.coroutines.**
-dontwarn org.slf4j.**
-dontwarn javax.annotation.**

# Linhas de stack legíveis no log de erros local (custo mínimo).
-keepattributes SourceFile,LineNumberTable,InnerClasses,EnclosingMethod,Signature,*Annotation*
-renamesourcefileattribute SourceFile
