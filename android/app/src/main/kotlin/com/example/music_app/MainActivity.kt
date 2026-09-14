package com.example.music_app

import android.app.Activity
import android.content.ContentUris
import android.content.Intent
import android.database.Cursor
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : AudioServiceActivity() {

    companion object {
        /// Código de request para o diálogo de exclusão do sistema
        /// (MediaStore.createDeleteRequest).
        private const val DELETE_MEDIA_REQUEST = 7001
    }

    /// Result pendente do canal nativo enquanto o diálogo do sistema de
    /// exclusão está aberto (resposta assíncrona).
    private var _pendingDeleteResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

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

        // Canal nativo de ARQUIVOS PDF (mesmo padrão dos demais).
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "audify/pdf_query"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getPdfs" -> result.success(queryPdfs())
                "getPageCount" -> {
                    val path = call.argument<String>("path") ?: run {
                        result.error("bad_args", "path obrigatório", null)
                        return@setMethodCallHandler
                    }
                    Thread { runOnUiThread { result.success(queryPdfPageCount(path)) } }.start()
                }
                "getThumbnail" -> {
                    val path = call.argument<String>("path") ?: run {
                        result.error("bad_args", "path obrigatório", null)
                        return@setMethodCallHandler
                    }
                    val width = call.argument<Int>("width") ?: 320
                    result.success(queryPdfThumbnail(path, width))
                }
                else -> result.notImplemented()
            }
        }

        // Canal nativo de EXCLUSÃO de mídia (MediaStore com confirmação do
        // sistema no Android 11+; exclusão direta nas versões legadas).
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "audify/media_delete"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "delete" -> {
                    val mediaType = call.argument<String>("type") ?: run {
                        result.error("bad_args", "type obrigatório", null)
                        return@setMethodCallHandler
                    }
                    val id = call.argument<Number>("id")?.toLong()
                    val path = call.argument<String>("path")
                    deleteMedia(mediaType, id, path, result)
                }
                else -> result.notImplemented()
            }
        }

        // Canal do GERENCIADOR DE ARQUIVOS: apenas o que dart:io não alcança
        // (espaço dos volumes via StatFs, miniatura de vídeo/PDF por CAMINHO
        // — não por id de MediaStore — e parse do binário AndroidManifest de
        // APKs soltos no disco). Toda a I/O comum é Dart puro.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "audify/file_query"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getStorageVolumes" -> result.success(queryStorageVolumes())
                "getFilePathThumbnail" -> {
                    val path = call.argument<String>("path") ?: run {
                        result.error("bad_args", "path obrigatório", null)
                        return@setMethodCallHandler
                    }
                    val width = call.argument<Int>("width") ?: 320
                    Thread {
                        val bytes = queryFilePathThumbnail(path, width)
                        runOnUiThread { result.success(bytes) }
                    }.start()
                }
                "getApkInfo" -> {
                    val path = call.argument<String>("path") ?: run {
                        result.error("bad_args", "path obrigatório", null)
                        return@setMethodCallHandler
                    }
                    result.success(queryApkInfo(path))
                }
                else -> result.notImplemented()
            }
        }
    }

    /// Resultado do diálogo do sistema após exclusão (Android 11+).
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == DELETE_MEDIA_REQUEST) {
            val callback = _pendingDeleteResult
            _pendingDeleteResult = null
            callback?.success(resultCode == Activity.RESULT_OK)
        }
    }

    /// Exclui uma mídia do MediaStore.
    ///
    /// Android 11+ (API 30): usa MediaStore.createDeleteRequest — o SISTEMA
    /// mostra o diálogo de confirmação ao usuário (o app não pode apagar
    /// mídia de terceiros silenciosamente). Retorno assíncrono.
    /// Android <= 10: exclusão direta via ContentResolver (permissão de
    /// storage concedida cobre o acesso).
    private fun deleteMedia(
        mediaType: String,
        id: Long?,
        path: String?,
        result: MethodChannel.Result
    ) {
        try {
            val collection: Uri? = when (mediaType) {
                "audio" -> MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
                "video" -> MediaStore.Video.Media.EXTERNAL_CONTENT_URI
                "image" -> MediaStore.Images.Media.EXTERNAL_CONTENT_URI
                // PDFs são arquivos genéricos: coleção Files.
                "pdf" -> MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL)
                else -> null
            }
            val uri: Uri? = when {
                id != null && collection != null ->
                    ContentUris.withAppendedId(collection, id)
                // Sem id (ex.: PDF do seletor SAF): apaga pelo caminho.
                !path.isNullOrEmpty() -> Uri.fromFile(java.io.File(path))
                else -> null
            }
            if (uri == null) {
                result.error("bad_args", "id/path obrigatório para $mediaType", null)
                return
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                // Arquivo do PRÓPRIO app (ex.: PDF do seletor SAF copiado
                // para o cache pelo file_picker): exclusão direta — o
                // diálogo do sistema (createDeleteRequest) só aceita URIs
                // content:// e não alcança o cache privado do app.
                if (uri.scheme == "file") {
                    val file = java.io.File(uri.path ?: "")
                    // Arquivo que já não existe também conta como excluído.
                    val deleted = !file.exists() || file.delete()
                    result.success(deleted)
                    return
                }
                // Diálogo do sistema: o usuário confirma a exclusão.
                val pendingIntent = MediaStore.createDeleteRequest(
                    contentResolver, listOf(uri)
                )
                _pendingDeleteResult = result
                startIntentSenderForResult(
                    pendingIntent.intentSender,
                    DELETE_MEDIA_REQUEST, null, 0, 0, 0
                )
            } else {
                // Legado: exclusão direta (o usuário já tem permissão).
                val deleted = contentResolver.delete(uri, null, null)
                result.success(deleted > 0)
            }
        } catch (e: Exception) {
            result.error("delete_failed", "Falha ao excluir: ${e.message}", null)
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

        contentResolver.query(
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
                bitmap = contentResolver.loadThumbnail(
                    uri, android.util.Size(width, width), null
                )
            } else {
                @Suppress("DEPRECATION")
                bitmap = MediaStore.Video.Thumbnails.getThumbnail(
                    contentResolver, id,
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
            contentResolver.query(
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

        contentResolver.query(
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

        contentResolver.query(
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
                contentResolver.loadThumbnail(
                    uri, android.util.Size(width, width), null
                )
            } else {
                @Suppress("DEPRECATION")
                MediaStore.Images.Thumbnails.getThumbnail(
                    contentResolver, id,
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

    /// Lista os arquivos PDF do aparelho via MediaStore.Files.
    ///
    /// Observação: no Android 13+ o caminho (DATA) de PDFs de terceiros
    /// pode não ser legível sem permissão de armazenamento (que não existe
    /// mais nessa versão). O app cobre esse caso com o seletor de arquivos
    /// (SAF) na aba de PDFs — [PdfProvider] expõe os dois caminhos.
    private fun queryPdfs(): List<Map<String, Any?>> {
        val pdfs = mutableListOf<Map<String, Any?>>()
        val collection: Uri =
            MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL)
        val projection = arrayOf(
            MediaStore.Files.FileColumns._ID,
            MediaStore.Files.FileColumns.DISPLAY_NAME,
            MediaStore.Files.FileColumns.DATA,
            MediaStore.Files.FileColumns.SIZE,
            MediaStore.Files.FileColumns.DATE_ADDED
        )
        val selection = "${MediaStore.Files.FileColumns.MIME_TYPE} = ?"
        val selectionArgs = arrayOf("application/pdf")

        contentResolver.query(
            collection, projection, selection, selectionArgs,
            "${MediaStore.Files.FileColumns.DATE_ADDED} DESC"
        )?.use { cursor: Cursor ->
            val idCol = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns._ID)
            val nameCol = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.DISPLAY_NAME)
            val dataCol = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.DATA)
            val sizeCol = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.SIZE)
            val addedCol = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.DATE_ADDED)

            while (cursor.moveToNext()) {
                val data = cursor.getString(dataCol) ?: continue
                pdfs.add(
                    mapOf(
                        "id" to cursor.getLong(idCol),
                        "name" to cursor.getString(nameCol),
                        "path" to data,
                        "size" to cursor.getLong(sizeCol),
                        "dateAdded" to cursor.getLong(addedCol)
                    )
                )
            }
        }
        return pdfs
    }

    /// Miniatura da primeira página de um PDF (PdfRenderer nativo do
    /// Android). Retorna null quando o arquivo é inacessível/corrompido —
    /// a UI usa o ícone de placeholder.
    private fun queryPdfThumbnail(path: String, width: Int): ByteArray? {
        return try {
            val file = java.io.File(path)
            if (!file.exists() || !file.canRead() || file.length() == 0L) {
                return null
            }
            val pfd = android.os.ParcelFileDescriptor.open(
                file, android.os.ParcelFileDescriptor.MODE_READ_ONLY
            )
            val renderer = android.graphics.pdf.PdfRenderer(pfd)
            if (renderer.pageCount == 0) {
                renderer.close()
                pfd.close()
                return null
            }
            val page = renderer.openPage(0)
            val scale = width.toFloat() / page.width
            val bitmap = Bitmap.createBitmap(
                (page.width * scale).toInt().coerceAtLeast(1),
                (page.height * scale).toInt().coerceAtLeast(1),
                Bitmap.Config.ARGB_8888
            )
            // Fundo branco: o PDF é renderizado com transparência.
            bitmap.eraseColor(android.graphics.Color.WHITE)
            page.render(
                bitmap, null, null,
                android.graphics.pdf.PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY
            )
            page.close()
            renderer.close()
            pfd.close()
            val out = java.io.ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.JPEG, 80, out)
            out.toByteArray()
        } catch (e: Exception) {
            null
        }
    }

    /// Número de páginas de um PDF (para a listagem da aba de PDFs).
    private fun queryPdfPageCount(path: String): Int {
        return try {
            val file = java.io.File(path)
            if (!file.exists() || !file.canRead()) return 0
            val pfd = android.os.ParcelFileDescriptor.open(
                file, android.os.ParcelFileDescriptor.MODE_READ_ONLY
            )
            val renderer = android.graphics.pdf.PdfRenderer(pfd)
            val count = renderer.pageCount
            renderer.close()
            pfd.close()
            count
        } catch (e: Exception) {
            0
        }
    }

    // =====================================================================
    // GERENCIADOR DE ARQUIVOS (canal audify/file_query)
    // =====================================================================

    /// Volumes de armazenamento com espaço real via StatFs. O volume primário
    /// é /storage/emulated/0; secundários removíveis vêm do StorageManager.
    private fun queryStorageVolumes(): List<Map<String, Any?>> {
        val volumes = mutableListOf<Map<String, Any?>>()
        try {
            val storageManager = getSystemService(android.content.Context.STORAGE_SERVICE)
                as android.os.storage.StorageManager
            for (volume in storageManager.storageVolumes) {
                val dir: java.io.File? =
                    if (Build.VERSION.SDK_INT >= 30) volume.directory else {
                        @Suppress("DEPRECATION")
                        volume.javaClass.getMethod("getDirectory").invoke(volume) as? java.io.File
                    }
                val path = dir?.absolutePath?.trimEnd('/') ?: continue
                var total = 0L
                var free = 0L
                try {
                    val statFs = android.os.StatFs(path)
                    total = statFs.totalBytes
                    free = statFs.availableBytes
                } catch (_: Exception) {
                }
                volumes.add(
                    mapOf(
                        "path" to path,
                        "name" to (try {
                            volume.getDescription(this@MainActivity)
                        } catch (_: Exception) {
                            null
                        } ?: if (volume.isRemovable) "Cartão SD" else "Armazenamento interno"),
                        "isPrimary" to volume.isPrimary,
                        "isRemovable" to volume.isRemovable,
                        "totalSpace" to total,
                        "freeSpace" to free
                    )
                )
            }
        } catch (_: Exception) {
        }
        if (volumes.isEmpty()) {
            volumes.add(
                mapOf(
                    "path" to "/storage/emulated/0",
                    "name" to "Armazenamento interno",
                    "isPrimary" to true,
                    "isRemovable" to false,
                    "totalSpace" to 0L,
                    "freeSpace" to 0L
                )
            )
        }
        return volumes
    }

    /// Miniatura por CAMINHO arbitrário (fora do MediaStore):
    ///  - vídeo: ThumbnailUtils.createVideoThumbnail (API 29+);
    ///  - PDF: mesmo PdfRenderer da aba de PDFs;
    ///  - imagem: BitmapFactory com inSampleSize (usada raramente — a UI
    ///    normalmente decodifica direto).
    private fun queryFilePathThumbnail(path: String, width: Int): ByteArray? {
        return try {
            val file = java.io.File(path)
            if (!file.exists() || !file.canRead() || file.length() == 0L) return null

            val bitmap: Bitmap? = when {
                path.lowercase().endsWith(".pdf") -> renderPdfFile(file, width)
                isVideoPath(path) -> {
                    if (Build.VERSION.SDK_INT >= 29) {
                        android.media.ThumbnailUtils.createVideoThumbnail(
                            file, android.util.Size(width, width), null
                        )
                    } else {
                        @Suppress("DEPRECATION")
                        val retriever = android.media.MediaMetadataRetriever()
                        try {
                            retriever.setDataSource(path)
                            val frame = retriever.getFrameAtTime(
                                0, android.media.MediaMetadataRetriever.OPTION_CLOSEST_SYNC
                            )
                            frame?.let { scaleBitmap(it, width) }
                        } finally {
                            retriever.release()
                        }
                    }
                }
                isImagePath(path) -> decodeSampledBitmap(file, width)
                else -> null
            }

            bitmap?.let { bmp ->
                val out = java.io.ByteArrayOutputStream()
                bmp.compress(Bitmap.CompressFormat.JPEG, 85, out)
                out.toByteArray()
            }
        } catch (e: Exception) {
            android.util.Log.w("AudifyNative", "fileThumb $path falhou: $e")
            null
        }
    }

    private fun renderPdfFile(file: java.io.File, width: Int): Bitmap? {
        val pfd = android.os.ParcelFileDescriptor.open(
            file, android.os.ParcelFileDescriptor.MODE_READ_ONLY
        )
        val renderer = android.graphics.pdf.PdfRenderer(pfd)
        return try {
            if (renderer.pageCount == 0) return null
            val page = renderer.openPage(0)
            val scale = width.toFloat() / page.width
            val bitmap = Bitmap.createBitmap(
                (page.width * scale).toInt().coerceAtLeast(1),
                (page.height * scale).toInt().coerceAtLeast(1),
                Bitmap.Config.ARGB_8888
            )
            bitmap.eraseColor(android.graphics.Color.WHITE)
            page.render(
                bitmap, null, null,
                android.graphics.pdf.PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY
            )
            page.close()
            bitmap
        } finally {
            renderer.close()
            pfd.close()
        }
    }

    private fun isVideoPath(path: String): Boolean {
        val ext = path.substringAfterLast('.', "").lowercase()
        return ext in setOf("mp4", "mkv", "avi", "mov", "webm", "3gp", "flv", "wmv", "ts")
    }

    private fun isImagePath(path: String): Boolean {
        val ext = path.substringAfterLast('.', "").lowercase()
        return ext in setOf("jpg", "jpeg", "png", "gif", "webp", "bmp", "heic", "heif")
    }

    private fun scaleBitmap(source: Bitmap, width: Int): Bitmap {
        val ratio = width.toFloat() / source.width.coerceAtLeast(1)
        return Bitmap.createScaledBitmap(
            source,
            (source.width * ratio).toInt().coerceAtLeast(1),
            (source.height * ratio).toInt().coerceAtLeast(1),
            true
        )
    }

    /// Decodificação amostrada: inSampleSize calculado contra o tamanho alvo
    /// evita carregar bitmaps enormes na memória para uma miniatura.
    private fun decodeSampledBitmap(file: java.io.File, target: Int): Bitmap? {
        val options = android.graphics.BitmapFactory.Options().apply {
            inJustDecodeBounds = true
        }
        android.graphics.BitmapFactory.decodeFile(file.absolutePath, options)
        var sample = 1
        while (options.outWidth / (sample * 2) >= target &&
            options.outHeight / (sample * 2) >= target
        ) {
            sample *= 2
        }
        val opts = android.graphics.BitmapFactory.Options().apply {
            inSampleSize = sample
        }
        return android.graphics.BitmapFactory.decodeFile(file.absolutePath, opts)
    }

    /// Metadados de APK solto no disco (nome do pacote, versão, label).
    /// getPackageArchiveInfo parseia o binário AndroidManifest embutido.
    private fun queryApkInfo(path: String): Map<String, Any?>? {
        return try {
            val pm = packageManager
            val info = pm.getPackageArchiveInfo(path, 0) ?: return null
            info.applicationInfo?.sourceDir = path
            info.applicationInfo?.publicSourceDir = path
            val label = try {
                info.applicationInfo?.loadLabel(pm)?.toString() ?: path.substringAfterLast('/')
            } catch (_: Exception) {
                path.substringAfterLast('/')
            }
            mapOf(
                "packageName" to info.packageName,
                "versionName" to (info.versionName ?: "?"),
                "versionCode" to
                    (if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else @Suppress("DEPRECATION") info.versionCode.toLong()),
                "appName" to label,
                "minSdkVersion" to (info.applicationInfo?.minSdkVersion ?: 0),
                "targetSdkVersion" to (info.applicationInfo?.targetSdkVersion ?: 0)
            )
        } catch (e: Exception) {
            null
        }
    }
}