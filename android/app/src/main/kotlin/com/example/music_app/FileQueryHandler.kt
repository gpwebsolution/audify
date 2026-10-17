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


class FileQueryHandler(
    private val activity: Activity,
    private val flutterEngine: FlutterEngine
) {

    fun register() {
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
                        activity.runOnUiThread { result.success(bytes) }
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

    // =====================================================================
    // GERENCIADOR DE ARQUIVOS (canal audify/file_query)
    // =====================================================================

    /// Volumes de armazenamento com espaço real via StatFs. O volume primário
    /// é /storage/emulated/0; secundários removíveis vêm do StorageManager.
    private fun queryStorageVolumes(): List<Map<String, Any?>> {
        val volumes = mutableListOf<Map<String, Any?>>()
        try {
            val storageManager = activity.getSystemService(android.content.Context.STORAGE_SERVICE)
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
                            volume.getDescription(activity)
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
    /// Converte o ícone do APK (um Drawable do manifesto) em bytes PNG.
    ///
    /// O caminho feliz é um `BitmapDrawable`; para ícone vetorial/adaptativo o
    /// SO entrega um `Drawable` que precisa ser desenhado num Canvas — daí os
    /// dois ramos. Falha de carga devolve null: ícone faltando é cosmético e
    /// não pode derrubar a leitura dos outros metadados.
    private fun apkIconPng(
        applicationInfo: android.content.pm.ApplicationInfo?,
        pm: android.content.pm.PackageManager
    ): ByteArray? {
        if (applicationInfo == null) return null
        return try {
            val drawable = applicationInfo.loadIcon(pm) ?: return null
            val size = 144
            val bitmap = (drawable as? android.graphics.drawable.BitmapDrawable)
                ?.bitmap
                ?.let { Bitmap.createScaledBitmap(it, size, size, true) }
                ?: run {
                    val created = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
                    val canvas = android.graphics.Canvas(created)
                    drawable.setBounds(0, 0, size, size)
                    drawable.draw(canvas)
                    created
                }
            val out = java.io.ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
            out.toByteArray()
        } catch (e: Exception) {
            null
        }
    }

    private fun queryApkInfo(path: String): Map<String, Any?>? {
        return try {
            val pm = activity.packageManager
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
                "targetSdkVersion" to (info.applicationInfo?.targetSdkVersion ?: 0),
                // Ícone do app embutido no APK, em PNG. Vem null quando o
                // manifesto não declara ícone ou a carga falha — a UI cai no
                // ícone genérico em vez de quebrar.
                "icon" to apkIconPng(info.applicationInfo, pm)
            )
        } catch (e: Exception) {
            null
        }
    }
}
