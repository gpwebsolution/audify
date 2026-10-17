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


class GalleryQueryHandler(
    private val activity: Activity,
    private val flutterEngine: FlutterEngine
) {

    fun register() {
        // Canal nativo da GALERIA DE FOTOS (mesmo padrão do de vídeos).
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "audify/gallery_query"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getImages" -> {
                    // Keyset pagination: a página traz as fotos ANTES de
                    // (date_added, _id) da última carregada (null = página 1).
                    val beforeDate = call.argument<Number>("beforeDateAdded")?.toLong()
                    val beforeId = call.argument<Number>("beforeId")?.toLong()
                    val limit = call.argument<Int>("limit") ?: 120
                    val albumId = call.argument<Number>("albumId")?.toLong()
                    result.success(queryImages(beforeDate, beforeId, limit, albumId))
                }
                "getAlbums" -> result.success(queryAlbums())
                "getThumbnail" -> {
                    val id = call.argument<Number>("id")?.toLong() ?: run {
                        result.error("bad_args", "id obrigatório", null)
                        return@setMethodCallHandler
                    }
                    val width = call.argument<Int>("width") ?: 320
                    result.success(queryImageThumbnail(id, width))
                }
                else -> result.notImplemented()
            }
        }
    }

    /// Lista uma página de imagens (mais recentes primeiro) via keyset.
    ///
    /// [beforeDate]/[beforeId]: tupla (date_added, _id) da ÚLTIMA foto da
    /// página anterior — retorna as fotos imediatamente anteriores a ela.
    /// Funciona no API 24+ (sem depender do overload de LIMIT do API 29).
    private fun queryImages(
        beforeDate: Long?,
        beforeId: Long?,
        limit: Int,
        albumId: Long?
    ): List<Map<String, Any?>> {
        val images = mutableListOf<Map<String, Any?>>()
        val projection = arrayOf(
            MediaStore.Images.Media._ID,
            MediaStore.Images.Media.DISPLAY_NAME,
            MediaStore.Images.Media.DATA,
            MediaStore.Images.Media.SIZE,
            MediaStore.Images.Media.DATE_ADDED,
            MediaStore.Images.Media.WIDTH,
            MediaStore.Images.Media.HEIGHT,
            MediaStore.Images.Media.BUCKET_ID,
            MediaStore.Images.Media.BUCKET_DISPLAY_NAME
        )

        // Keyset: (date_added DESC, _id DESC) com desempate por id — evita
        // pular fotos com a MESMA data entre páginas.
        val selection = buildString {
            if (beforeDate != null && beforeId != null) {
                append("(${MediaStore.Images.Media.DATE_ADDED} < ?) OR ")
                append("(${MediaStore.Images.Media.DATE_ADDED} = ? AND ")
                append("${MediaStore.Images.Media._ID} < ?)")
            } else {
                append("1 = 1")
            }
            if (albumId != null) {
                append(" AND ${MediaStore.Images.Media.BUCKET_ID} = ?")
            }
        }
        val selectionArgs = buildList {
            if (beforeDate != null && beforeId != null) {
                add(beforeDate.toString())
                add(beforeDate.toString())
                add(beforeId.toString())
            }
            if (albumId != null) add(albumId.toString())
        }.toTypedArray()
        val sortOrder =
            "${MediaStore.Images.Media.DATE_ADDED} DESC, ${MediaStore.Images.Media._ID} DESC"

        activity.contentResolver.query(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
            projection, selection, selectionArgs, sortOrder
        )?.use { cursor: Cursor ->
            val idCol = cursor.getColumnIndexOrThrow(MediaStore.Images.Media._ID)
            val nameCol = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.DISPLAY_NAME)
            val dataCol = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.DATA)
            val sizeCol = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.SIZE)
            val addedCol = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.DATE_ADDED)
            val widthCol = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.WIDTH)
            val heightCol = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.HEIGHT)
            val bucketIdCol = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.BUCKET_ID)
            val bucketNameCol = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.BUCKET_DISPLAY_NAME)

            while (cursor.moveToNext() && images.size < limit) {
                val data = cursor.getString(dataCol) ?: continue
                images.add(
                    mapOf(
                        "id" to cursor.getLong(idCol),
                        "name" to cursor.getString(nameCol),
                        "path" to data,
                        "size" to cursor.getLong(sizeCol),
                        "dateAdded" to cursor.getLong(addedCol),
                        // WIDTH/HEIGHT existem desde o API 29; antes disso
                        // retornam -1 e a UI exibe sem dimensões.
                        "width" to cursor.getInt(widthCol),
                        "height" to cursor.getInt(heightCol),
                        "bucketId" to cursor.getLong(bucketIdCol),
                        "bucketName" to cursor.getString(bucketNameCol)
                    )
                )
            }
        }
        return images
    }

    /// Álbuns (pastas) de imagens com contagem de fotos, maiores primeiro.
    ///
    /// O MediaStore NÃO aceita funções agregadas (COUNT/MAX) na projeção —
    /// o provider rejeita com "Invalid column". Estratégia: lê os buckets
    /// (id, nome, _id) ordenados por data DESC e agrupa em Kotlin: o
    /// primeiro _id de cada bucket é a capa (a mais recente) e o contador
    /// soma as fotos do bucket.
    private fun queryAlbums(): List<Map<String, Any?>> {
        val albums = mutableListOf<Map<String, Any?>>()
        val projection = arrayOf(
            MediaStore.Images.Media.BUCKET_ID,
            MediaStore.Images.Media.BUCKET_DISPLAY_NAME,
            MediaStore.Images.Media._ID
        )
        val albumByBucket = LinkedHashMap<Long, MutableMap<String, Any?>>()

        activity.contentResolver.query(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
            projection, null, null,
            "${MediaStore.Images.Media.DATE_ADDED} DESC"
        )?.use { cursor: Cursor ->
            val bucketCol = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.BUCKET_ID)
            val nameCol = cursor.getColumnIndexOrThrow(MediaStore.Images.Media.BUCKET_DISPLAY_NAME)
            val idCol = cursor.getColumnIndexOrThrow(MediaStore.Images.Media._ID)

            while (cursor.moveToNext()) {
                val bucketId = cursor.getLong(bucketCol)
                val album = albumByBucket.getOrPut(bucketId) {
                    mutableMapOf(
                        "id" to bucketId,
                        "name" to cursor.getString(nameCol),
                        "count" to 0,
                        // Capa = foto mais recente do bucket (a 1ª lida).
                        "coverId" to cursor.getLong(idCol)
                    )
                }
                album["count"] = (album["count"] as Int) + 1
            }
        }

        // Maiores (mais fotos) primeiro — mesmo ordenamento da versão SQL.
        albums.addAll(albumByBucket.values.sortedByDescending { it["count"] as Int })
        return albums
    }

    /// Miniatura de imagem (mesma estratégia do vídeo: loadThumbnail no
    /// API 29+, Thumbnails.getThumbnail no legado).
    private fun queryImageThumbnail(id: Long, width: Int): ByteArray? {
        return try {
            val bitmap: Bitmap? = if (android.os.Build.VERSION.SDK_INT >= 29) {
                val uri: Uri = ContentUris.withAppendedId(
                    MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id
                )
                activity.contentResolver.loadThumbnail(
                    uri, android.util.Size(width, width), null
                )
            } else {
                @Suppress("DEPRECATION")
                MediaStore.Images.Thumbnails.getThumbnail(
                    activity.contentResolver, id,
                    MediaStore.Images.Thumbnails.MICRO_KIND, null
                )
            }
            bitmap?.let { bmp ->
                val out = java.io.ByteArrayOutputStream()
                bmp.compress(Bitmap.CompressFormat.JPEG, 85, out)
                out.toByteArray()
            }
        } catch (e: Exception) {
            null
        }
    }
}
