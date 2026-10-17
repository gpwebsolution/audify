package com.example.music_app

import android.app.Activity
import android.app.RecoverableSecurityException
import android.content.ContentUris
import android.content.Intent
import android.database.Cursor
import android.graphics.Bitmap
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.widget.Toast
import java.util.concurrent.atomic.AtomicBoolean
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel


class VideoQueryHandler(
    private val activity: Activity,
    private val flutterEngine: FlutterEngine
) {

    fun register() {
        // Canal nativo para consulta ao MediaStore de VÍDEOS (o on_audio_query
        // só cobre áudio). Evita depender de plugin abandonado/incompatível.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "audify/video_query"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getVideos" -> result.success(queryVideos())
                "getThumbnail" -> {
                    // ATENÇÃO: o codec padrão do Flutter entrega int do Dart
                    // como java.lang.Integer (32 bits) — o cast para Long
                    // lança ClassCastException. Sempre converter via Number.
                    val id = call.argument<Number>("id")?.toLong() ?: run {
                        result.error("bad_args", "id obrigatório", null)
                        return@setMethodCallHandler
                    }
                    val width = call.argument<Int>("width") ?: 320
                    result.success(queryThumbnail(id, width))
                }
                else -> result.notImplemented()
            }
        }
    }

    /// Lista os vídeos do aparelho (mais recentes primeiro).
    private fun queryVideos(): List<Map<String, Any?>> {
        val videos = mutableListOf<Map<String, Any?>>()
        val projection = arrayOf(
            MediaStore.Video.Media._ID,
            MediaStore.Video.Media.TITLE,
            MediaStore.Video.Media.DISPLAY_NAME,
            MediaStore.Video.Media.DURATION,
            MediaStore.Video.Media.DATA,
            MediaStore.Video.Media.SIZE,
            MediaStore.Video.Media.DATE_ADDED
        )

        activity.contentResolver.query(
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
            projection, null, null,
            "${MediaStore.Video.Media.DATE_ADDED} DESC"
        )?.use { cursor: Cursor ->
            val idCol = cursor.getColumnIndexOrThrow(MediaStore.Video.Media._ID)
            val titleCol = cursor.getColumnIndexOrThrow(MediaStore.Video.Media.TITLE)
            val nameCol = cursor.getColumnIndexOrThrow(MediaStore.Video.Media.DISPLAY_NAME)
            val durCol = cursor.getColumnIndexOrThrow(MediaStore.Video.Media.DURATION)
            val dataCol = cursor.getColumnIndexOrThrow(MediaStore.Video.Media.DATA)
            val sizeCol = cursor.getColumnIndexOrThrow(MediaStore.Video.Media.SIZE)
            val addedCol = cursor.getColumnIndexOrThrow(MediaStore.Video.Media.DATE_ADDED)

            while (cursor.moveToNext()) {
                val data = cursor.getString(dataCol) ?: continue
                videos.add(
                    mapOf(
                        "id" to cursor.getLong(idCol),
                        "title" to cursor.getString(titleCol),
                        "displayName" to cursor.getString(nameCol),
                        "duration" to cursor.getLong(durCol),
                        "path" to data,
                        "size" to cursor.getLong(sizeCol),
                        "dateAdded" to cursor.getLong(addedCol)
                    )
                )
            }
        }
        return videos
    }

    /// Miniatura de vídeo (rápida, para listas). Retorna null quando o
    /// MediaStore não tem miniatura — a UI usa o placeholder.
    ///
    /// Cadeia de fallbacks: loadThumbnail do MediaStore (API 29+) ->
    /// Thumbnails.getThumbnail legado -> ThumbnailUtils (gera do arquivo
    /// em disco). Assim a capa aparece mesmo quando o MediaStore não tem
    /// miniatura indexada.
    private fun queryThumbnail(id: Long, width: Int): ByteArray? {
        var bitmap: Bitmap? = null

        try {
            if (android.os.Build.VERSION.SDK_INT >= 29) {
                val uri: Uri = ContentUris.withAppendedId(
                    MediaStore.Video.Media.EXTERNAL_CONTENT_URI, id
                )
                bitmap = activity.contentResolver.loadThumbnail(
                    uri, android.util.Size(width, width), null
                )
            } else {
                @Suppress("DEPRECATION")
                bitmap = MediaStore.Video.Thumbnails.getThumbnail(
                    activity.contentResolver, id,
                    MediaStore.Video.Thumbnails.MINI_KIND, null
                )
            }
        } catch (e: Exception) {
            android.util.Log.w("AudifyNative", "loadThumbnail video $id falhou: $e")
            bitmap = null
        }

        // Fallback: decodifica um frame do arquivo em disco (funciona sem
        // depender do MediaStore). Requer a permissão de vídeos concedida.
        if (bitmap == null) {
            try {
                val path = queryVideoPath(id)
                if (path != null) {
                    bitmap = android.media.ThumbnailUtils.createVideoThumbnail(
                        java.io.File(path),
                        android.util.Size(width, width),
                        null
                    )
                } else {
                    android.util.Log.w("AudifyNative", "fallback video $id: caminho não encontrado")
                }
            } catch (e: Exception) {
                android.util.Log.w("AudifyNative", "fallback video $id falhou: $e")
                bitmap = null
            }
        }

        return bitmap?.let { bmp ->
            val out = java.io.ByteArrayOutputStream()
            bmp.compress(Bitmap.CompressFormat.JPEG, 85, out)
            out.toByteArray()
        }
    }

    /// Caminho em disco de um vídeo pelo id (para o fallback de miniatura).
    private fun queryVideoPath(id: Long): String? {
        return try {
            val projection = arrayOf(MediaStore.Video.Media.DATA)
            var result: String? = null
            activity.contentResolver.query(
                ContentUris.withAppendedId(
                    MediaStore.Video.Media.EXTERNAL_CONTENT_URI, id
                ),
                projection, null, null, null
            )?.use { cursor: Cursor ->
                if (cursor.moveToFirst()) {
                    result = cursor.getString(0)
                }
            }
            result
        } catch (e: Exception) {
            null
        }
    }
}
