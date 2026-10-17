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


class PdfQueryHandler(
    private val activity: Activity,
    private val flutterEngine: FlutterEngine
) {

    fun register() {
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
                    Thread { activity.runOnUiThread { result.success(queryPdfPageCount(path)) } }.start()
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

        activity.contentResolver.query(
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
}
