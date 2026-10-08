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

class MainActivity : AudioServiceActivity() {

    companion object {
        private const val TAG = "AudifyDelete"

        /// Código de request do diálogo de exclusão do sistema
        /// (MediaStore.createDeleteRequest / RecoverableSecurityException).
        private const val DELETE_MEDIA_REQUEST = 7001

        /// Esquema e autoridade que o MediaStore aceita em createDeleteRequest.
        private const val SCHEME_CONTENT = "content"
        private const val AUTHORITY_MEDIA = "media"

        /// Texto mostrado quando o SO exige MANAGE_EXTERNAL_STORAGE.
        private const val MISSING_ALL_FILES =
            "Conceda o acesso a \"Todos os arquivos\" para excluir este " +
                "documento do aparelho."

        /// Texto mostrado quando o SO recusa por falta de permissão de mídia.
        private const val MISSING_MEDIA_PERMISSION =
            "O Android não autorizou a exclusão. Verifique as permissões de " +
                "mídia do app e tente de novo."

        /**
         * Exclusão aguardando a resposta do diálogo do sistema.
         *
         * Vive no [companion] (escopo de processo) e NÃO em campo da Activity
         * porque o diálogo do SO sobrevive à recriação da Activity (rotação,
         * pressão de memória), mas um `MethodChannel.Result` guardado em campo
         * seria perdido junto — deixando o Future do Dart pendurado para sempre.
         * O FlutterEngine é retido nessa rotação, então o Result continua válido.
         */
        @Volatile
        private var pendingDelete: PendingDelete? = null

        // Serializa o ciclo "reservar -> executar -> responder" para que dois
        // pedidos simultâneos nunca sobrescrevam o `Result` pendente.
        // Ambos os caminhos (chegada do Dart e conclusão do diálogo) usam o
        // mesmo monitor, e a reserva é feita NA THREAD DA PLATAFORMA antes de
        // qualquer trabalho em background.
        private val deleteLock = Any()
    }

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

        // Canal nativo de EXCLUSÃO de mídia (MediaStore, com a estratégia
        // correta por versão do SO). Substitui o antigo delete por item
        // único que só funcionava para foto/PDF — ver deleteBatch().
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "audify/media_delete"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "deleteBatch" -> {
                    val rawItems = call.argument<List<*>>("items")
                    if (rawItems == null) {
                        result.error("bad_args", "items obrigatório", null)
                        return@setMethodCallHandler
                    }
                    deleteBatch(rawItems, result)
                }
                "getContentUri" -> {
                    // Converte um caminho em content:// via FileProvider —
                    // o único tipo de URI aceito por apps de fora desde o
                    // Android 7 (FileUriExposedException).
                    val path = call.argument<String>("path")
                    if (path.isNullOrEmpty()) {
                        result.error("bad_args", "path obrigatório", null)
                        return@setMethodCallHandler
                    }
                    result.success(queryContentUri(path))
                }
                "setAsWallpaper" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrEmpty()) {
                        result.error("bad_args", "path obrigatório", null)
                        return@setMethodCallHandler
                    }
                    setAsWallpaper(path)
                    result.success(null)
                }
                "editImage" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrEmpty()) {
                        result.error("bad_args", "path obrigatório", null)
                        return@setMethodCallHandler
                    }
                    editImage(path)
                    result.success(null)
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

    // =====================================================================
    // EXCLUSÃO DE MÍDIA (canal audify/media_delete) — por versão do SO
    //
    // Android 11+ (API 30+): MediaStore.createDeleteRequest + um ÚNICO
    //   diálogo do sistema para o lote inteiro. Vale para áudio, vídeo e
    //   imagem sem precisar de MANAGE_EXTERNAL_STORAGE.
    // Android 10 (API 29): contentResolver.delete capturando
    //   RecoverableSecurityException -> confirma com o usuário e repete.
    // Android 9 e abaixo (API <= 28): contentResolver.delete direto
    //   (WRITE_EXTERNAL_STORAGE) com File.delete() como reserva.
    // Documentos/arquivos fora do MediaStore de mídia: resolvidos pelo
    //   caminho em MediaStore.Files; sem indexação, exige "Todos os
    //   arquivos" e usa File.delete().
    //
    // O retorno é SEMPRE estruturado e verificado (a linha sumiu do
    // MediaStore / o arquivo sumiu do disco) — nunca um booleano genérico.
    // =====================================================================

    /// Desfecho do diálogo do sistema (RESULT_OK = apagado,
    /// RESULT_CANCELED = usuário recusou). O lote pendente vive no
    /// [companion] porque o IntentSender do SO responde de forma assíncrona e
    /// sobrevive à recriação da Activity.
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != DELETE_MEDIA_REQUEST) return
        val pending = synchronized(deleteLock) {
            val current = pendingDelete ?: return
            current.dialogAnswered = true
            pendingDelete = null
            current
        }

        if (resultCode != Activity.RESULT_OK) {
            // Cancelamento do usuário: o SO não apagou nada. Todos os itens
            // voltam para [DeleteOutcome.Cancelled] e o Dart não mexe na UI.
            pending.state.cancelAll()
            finishDelete(pending.state)
            return
        }

        // Retry de RecoverableSecurityException (Android 10): o SO só libera a
        // exclusão DEPOIS da confirmação, então é preciso repeti-la.
        val retry = pending.retry
        if (retry != null) {
            Thread {
                for ((item, uri) in retry) {
                    val outcome = try {
                        if (contentResolver.delete(uri, null, null) > 0) {
                            DeleteOutcome.Deleted
                        } else {
                            DeleteOutcome.Undecided
                        }
                    } catch (e: RecoverableSecurityException) {
                        DeleteOutcome.Failed("O Android recusou a exclusão.")
                    } catch (e: Exception) {
                        DeleteOutcome.Failed(e.message ?: "Falha ao excluir.")
                    }
                    pending.state.set(item, outcome)
                }
                finishDelete(pending.state)
            }.start()
            return
        }

        // createDeleteRequest (Android 11+): os itens já estão Undecided desde
        // a montagem do lote; finishDelete consulta o MediaStore e o disco para
        // CONFIRMAR o que o SO apagou (e o que ele não apagou).
        Thread { finishDelete(pending.state) }.start()
    }

    /**
     * Recebe o lote do Dart e dispara a exclusão.
     *
     * A reserva do slot de exclusão acontece aqui, na thread da plataforma,
     * sob [deleteLock] — antes de qualquer trabalho em background. Fazer a
     * checagem numa thread e a reserva em outra permitia que dois pedidos
     * quase simultâneos passassem os dois e o segundo sobrescrevesse o
     * `Result` pendente (Future do Dart pendurado para sempre).
     */
    private fun deleteBatch(rawItems: List<*>, result: MethodChannel.Result) {
        val items = mutableListOf<DeleteItem>()
        for (raw in rawItems) {
            val map = raw as? Map<*, *> ?: continue
            val type = map["type"] as? String ?: "other"
            val id = (map["id"] as? Number)?.toLong()
            val uri = map["uri"] as? String
            val path = map["path"] as? String
            val key = (map["key"] as? String) ?: computeKey(type, id, uri, path)
            items.add(DeleteItem(type, id, uri, path, key))
        }
        if (items.isEmpty()) {
            result.success(emptyPayload())
            return
        }

        val state = DeleteState(items, result)
        val reserved = synchronized(deleteLock) {
            if (pendingDelete == null) {
                pendingDelete = PendingDelete(state, retry = null)
                true
            } else {
                false
            }
        }
        if (!reserved) {
            // Outro diálogo do sistema ainda está em tela. Recusa explícita em
            // vez de deixar este Future esperando por um Result que nunca viria.
            state.failAll("Já há uma exclusão em andamento. Tente de novo.")
            finishDelete(state)
            return
        }


        // Todo o trabalho em background fica sob try/catch/finally: sem isso,
        // uma exceção em qualquer etapa (resolução de alvo, consulta ao
        // MediaStore, montagem do pedido) deixava o `Result` sem resposta e o
        // Future do Dart pendurado para sempre — a tela parecia travada.
        Thread {
            try {
                runDelete(state, items)
            } catch (t: Throwable) {
                // Só os itens SEM desfecho viram failed: quem já foi confirmado
                // como removido continua `deleted` (mentir seria pior).
                state.failPending("Falha inesperada ao excluir: ${describe(t)}")
                finishDelete(state)
            } finally {
                // Idempotente e condicional (ver releaseReservation): não
                // derruba a reserva enquanto um diálogo do SO estiver em tela.
                releaseReservation(state)
            }
        }.start()
    }

    /// Mensagem legível de uma falha inesperada, sem vazar ruído interno.
    private fun describe(t: Throwable): String {
        val message = t.message?.trim().orEmpty()
        return when {
            t is SecurityException && message.isEmpty() -> "sem permissão do sistema"
            message.isEmpty() -> t.javaClass.simpleName
            message.length > 120 -> "erro do sistema"
            else -> message
        }
    }

    /**
     * Libera a reserva do slot de exclusão — mas apenas para o lote que a
     * detém. Um lote rejeitado (porque já havia um diálogo em tela) também
     * passa por [finishDelete], e sem esta checagem ele derrubaria a reserva
     * do lote alheio, permitindo dois diálogos do sistema ao mesmo tempo.
     */
    private fun releaseReservation(state: DeleteState) {
        synchronized(deleteLock) {
            val pending = pendingDelete
            if (pending?.state !== state) return
            // Diálogo em tela: a reserva TEM de continuar, senão um segundo
            // pedido passaria pela guarda e abriria outro diálogo por cima.
            if (pending.dialogLaunched && !pending.dialogAnswered) return
            pendingDelete = null
        }
    }

    /// Resolve cada item e escolhe a estratégia correta para o SO atual.
    private fun runDelete(state: DeleteState, targets: List<DeleteItem>) {
        val contentTargets = mutableListOf<Pair<DeleteItem, Uri>>()
        val fileTargets = mutableListOf<Pair<DeleteItem, java.io.File>>()

        for (item in targets) {
            when (val resolved = resolveTarget(item)) {
                is ResolvedTarget.Content ->
                    // Já apagado por outro app? A linha não existe mais, então
                    // não há o que excluir — reporta notFound em vez de gastar
                    // um diálogo do sistema com um item inexistente.
                    if (contentExists(resolved.uri)) {
                        contentTargets.add(item to resolved.uri)
                    } else {
                        state.set(item, DeleteOutcome.NotFound)
                    }
                is ResolvedTarget.OnDisk ->
                    if (resolved.file.exists()) {
                        fileTargets.add(item to resolved.file)
                    } else {
                        state.set(item, DeleteOutcome.NotFound)
                    }
                // Sem id, sem URI e sem caminho utilizável: nada a tentar.
                null -> state.set(item, DeleteOutcome.NotFound)
            }
        }

        // Fora do MediaStore (arquivo do próprio app, "Todos os arquivos"):
        // exclusão direta pelo disco, sem diálogo.
        for ((item, file) in fileTargets) deleteFileDirect(state, item, file)

        if (contentTargets.isEmpty()) {
            finishDelete(state)
            return
        }

        when {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.R ->
                deleteWithSystemDialog(state, contentTargets)
            Build.VERSION.SDK_INT == Build.VERSION_CODES.Q ->
                deleteRecoverable(state, contentTargets)
            else -> deleteLegacy(state, contentTargets)
        }
    }

    /**
     * Android 11+: um único createDeleteRequest para o lote inteiro.
     *
     * Os itens entram como [DeleteOutcome.Undecided] ANTES de abrir o
     * diálogo. Isso é obrigatório: sem um veredito registrado, a checagem
     * final em [finishDelete] não teria o que confirmar e o lote inteiro
     * voltaria para o Dart como "não confirmado" — mesmo com o arquivo já
     * apagado pelo sistema.
     */
    private fun deleteWithSystemDialog(
        state: DeleteState,
        targets: List<Pair<DeleteItem, Uri>>
    ) {
        // Só entram no pedido as URIs que o MediaStore aceita. Uma URI
        // inválida (file://, authority errada, esquema diferente) faz o SO
        // recusar o pedido INTEIRO — o que derrubaria a exclusão dos itens
        // válidos que estavam no mesmo lote.
        val eligible = mutableListOf<Pair<DeleteItem, Uri>>()
        for ((item, uri) in targets) {
            val safe = sanitizeMediaUri(item, uri)
            if (safe == null) {
                // Sem URI reconstruível: tenta o disco antes de desistir, em
                // vez de reprovar o item junto com o lote.
                state.set(item, deleteOnDisk(item))
            } else {
                eligible.add(item to safe)
            }
        }
        if (eligible.isEmpty()) {
            finishDelete(state)
            return
        }

        val uris = eligible.map { it.second }
        for ((item, _) in eligible) state.set(item, DeleteOutcome.Undecided)

        val sender = try {
            MediaStore.createDeleteRequest(contentResolver, uris).intentSender
        } catch (e: Exception) {
            // O SO recusou montar o pedido. Resgate item a item por
            // conteúdo — arquivo do próprio app segue deletável e um item
            // problemático não derruba os demais.
            for ((item, uri) in eligible) {
                state.set(item, deleteViaResolver(item, uri))
            }
            finishDelete(state)
            return
        }

        runOnUiThread {
            try {
                // Marca ANTES de entregar: se `startIntentSenderForResult`
                // lançar depois de o SO ter recebido o pedido, a reserva
                // precisa ser mantida para o `onActivityResult` que virá.
                synchronized(deleteLock) {
                    pendingDelete?.takeIf { it.state === state }?.dialogLaunched = true
                }
                startIntentSenderForResult(sender, DELETE_MEDIA_REQUEST, null, 0, 0, 0)
            } catch (e: Exception) {
                for ((item, _) in eligible) {
                    state.set(
                        item,
                        DeleteOutcome.Failed(
                            "O Android não abriu a confirmação de exclusão."
                        )
                    )
                }
                finishDelete(state)
            }
        }
    }

    /**
     * Exclusão direta via ContentResolver, traduzindo a exceção em desfecho.
     *
     * [propagateRecoverable] existe para o Android 10: lá a
     * `RecoverableSecurityException` NÃO é um erro, é o mecanismo que abre o
     * diálogo de confirmação. Quem chama com `true` precisa recebê-la de volta
     * em vez de engoli-la num desfecho genérico.
     */
    private fun deleteViaResolver(
        item: DeleteItem,
        uri: Uri,
        propagateRecoverable: Boolean = false
    ): DeleteOutcome = try {
        if (contentResolver.delete(uri, null, null) > 0) {
            DeleteOutcome.Deleted
        } else {
            DeleteOutcome.Undecided
        }
    } catch (rse: RecoverableSecurityException) {
        if (propagateRecoverable) throw rse
        DeleteOutcome.Failed("O Android recusou a exclusão.")
    } catch (se: SecurityException) {
        if (!hasAllFilesAccess()) {
            DeleteOutcome.PermissionDenied(MISSING_ALL_FILES)
        } else {
            DeleteOutcome.PermissionDenied(MISSING_MEDIA_PERMISSION)
        }
    } catch (se: Exception) {
        DeleteOutcome.Failed(se.message ?: "Falha ao excluir.")
    }

    /// Android 10: apaga o que puder e pede confirmação do SO para o resto.
    private fun deleteRecoverable(
        state: DeleteState,
        targets: List<Pair<DeleteItem, Uri>>
    ) {
        val retry = mutableListOf<Pair<DeleteItem, Uri>>()
        var recoverable: RecoverableSecurityException? = null

        for ((item, uri) in targets) {
            try {
                state.set(item, deleteViaResolver(item, uri, propagateRecoverable = true))
            } catch (e: RecoverableSecurityException) {
                retry.add(item to uri)
                if (recoverable == null) recoverable = e
            }
        }

        val pendingRetry = retry
        val thrown = recoverable
        if (thrown == null) {
            finishDelete(state)
            return
        }

        // Os itens que dependem da confirmação entram como Undecided para que a
        // verificação final realmente decida depois do RESULT_OK.
        for ((item, _) in pendingRetry) state.set(item, DeleteOutcome.Undecided)
        synchronized(deleteLock) {
            pendingDelete = PendingDelete(state, retry = pendingRetry)
        }

        runOnUiThread {
            try {
                synchronized(deleteLock) {
                    pendingDelete?.takeIf { it.state === state }?.dialogLaunched = true
                }
                startIntentSenderForResult(
                    thrown.userAction.actionIntent.intentSender,
                    DELETE_MEDIA_REQUEST, null, 0, 0, 0
                )
            } catch (e: Exception) {
                for ((item, _) in pendingRetry) {
                    state.set(
                        item,
                        DeleteOutcome.Failed("O Android não pediu a confirmação.")
                    )
                }
                finishDelete(state)
            }
        }
    }

    /// Android 9 e abaixo: exclusão direta com File.delete() de reserva.
    private fun deleteLegacy(
        state: DeleteState,
        targets: List<Pair<DeleteItem, Uri>>
    ) {
        for ((item, uri) in targets) {
            val outcome = try {
                if (contentResolver.delete(uri, null, null) > 0) {
                    DeleteOutcome.Deleted
                } else {
                    // O provider respondeu 0: tenta o disco antes de desistir.
                    val path = item.path
                    if (!path.isNullOrEmpty()) {
                        deleteFile(java.io.File(path))
                    } else {
                        DeleteOutcome.Undecided
                    }
                }
            } catch (e: Exception) {
                val path = item.path
                if (path.isNullOrEmpty()) {
                    DeleteOutcome.Failed(e.message ?: "Falha ao excluir.")
                } else {
                    deleteFile(java.io.File(path))
                }
            }
            state.set(item, outcome)
        }
        finishDelete(state)
    }

    /// Exclusão direta no disco (sem MediaStore): registra o desfecho.
    private fun deleteFileDirect(
        state: DeleteState,
        item: DeleteItem,
        file: java.io.File
    ) {
        state.set(item, deleteFile(file))
    }

    /**
     * Exclusão direta no disco, devolvendo o desfecho.
     *
     * Arquivo ausente vira [DeleteOutcome.NotFound] e NÃO [Deleted]: o app
     * precisa distinguir "saiu do aparelho agora" de "já não estava lá" para
     * não limpar estado de um item que talvez nem fosse esse arquivo.
     */
    private fun deleteFile(file: java.io.File): DeleteOutcome {
        if (!file.exists()) return DeleteOutcome.NotFound
        try {
            if (file.delete() || !file.exists()) return DeleteOutcome.Deleted
        } catch (e: SecurityException) {
            // Segue para o diagnóstico de permissão abaixo.
        } catch (e: Exception) {
            return DeleteOutcome.Failed(e.message ?: "Não foi possível apagar o arquivo.")
        }
        // delete() devolveu false e o arquivo continua lá.
        return if (!hasAllFilesAccess()) {
            DeleteOutcome.PermissionDenied(MISSING_ALL_FILES)
        } else {
            DeleteOutcome.Failed("Não foi possível apagar o arquivo.")
        }
    }

    /**
     * Verifica de verdade o que saiu do aparelho, reindexa o MediaStore e
     * responde ao Dart. É o ÚNICO ponto que chama `result.success()`.
     *
     * Todo item do lote chega aqui COM desfecho registrado (inclusive o
     * [DeleteOutcome.Undecided] deixado pelo diálogo do sistema). A checagem
     * converte cada [DeleteOutcome.Undecided] em [DeleteOutcome.Deleted] ou em
     * falha, consultando o MediaStore e o disco — nunca há sucesso presumido.
     */
    private fun finishDelete(state: DeleteState) {
        // Responde UMA vez. Uma segunda chamada (exceção depois do diálogo já
        // estar em tela, ou conclusão duplicada) faria o Flutter lançar
        // "reply already submitted" e derrubar o isolate do canal — por isso o
        // FIRST-CALL-WINS acontece ANTES de qualquer outro efeito.
        if (!state.claimAnswer()) return

        // [finishDelete] é o ÚNICO ponto terminal do lote: liberar a reserva
        // aqui garante que nenhum caminho (sem diálogo, diálogo recusado,
        // createDeleteRequest que lançou) deixe o slot ocupado e faça o
        // próximo pedido ser recusado para sempre.
        releaseReservation(state)

        for (item in state.items) {
            val outcome = state.outcomeOf(item) ?: continue
            if (outcome !is DeleteOutcome.Undecided) continue
            state.set(
                item,
                if (isGone(item)) {
                    DeleteOutcome.Deleted
                } else {
                    DeleteOutcome.Failed("O arquivo ainda existe no aparelho.")
                }
            )
        }

        // Sem reindexar, uma exclusão feita pelo caminho deixa linha órfã
        // no MediaStore e o item "volta a aparecer" na próxima consulta.
        val paths = state.items.mapNotNull { it.path }
            .filter { it.isNotEmpty() }
            .distinct()
        if (paths.isNotEmpty()) {
            MediaScannerConnection.scanFile(this, paths.toTypedArray(), null, null)
        }

        // Um desfecho por item, montado a partir do lote — nunca a partir do
        // mapa de resultados, para que um item sem registro apareça como falha
        // explícita em vez de sumir em silêncio.
        val deleted = mutableListOf<String>()
        val notFound = mutableListOf<String>()
        val failed = mutableListOf<Map<String, String>>()
        var cancelled = false
        var needsPermission = false

        for (item in state.items) {
            when (val outcome = state.outcomeOf(item)) {
                null -> failed.add(
                    mapOf("key" to item.key, "reason" to "A exclusão não foi confirmada.")
                )
                is DeleteOutcome.Deleted -> deleted.add(item.key)
                is DeleteOutcome.NotFound -> notFound.add(item.key)
                is DeleteOutcome.Cancelled -> cancelled = true
                is DeleteOutcome.PermissionDenied -> {
                    needsPermission = true
                    failed.add(mapOf("key" to item.key, "reason" to outcome.reason))
                }
                is DeleteOutcome.Failed ->
                    failed.add(mapOf("key" to item.key, "reason" to outcome.reason))
                is DeleteOutcome.Undecided -> failed.add(
                    mapOf("key" to item.key, "reason" to "A exclusão não foi confirmada.")
                )
            }
        }

        state.result.success(
            mapOf(
                "deleted" to deleted,
                "notFound" to notFound,
                "failed" to failed,
                "cancelled" to cancelled,
                "permissionRequired" to needsPermission
            )
        )
    }

    /**
     * O item realmente sumiu do aparelho?
     *
     * Para mídia indexada, consulta o MediaStore; para o resto, o disco.
     *
     * Quando não há como saber (sem id, sem URI e sem caminho), devolve
     * `false`: sem evidência de remoção o item NÃO pode virar "excluído".
     * O mesmo vale quando a consulta lança — o anterior devolvia `true`
     * (cursor nulo), o que transformava falha de verificação em sucesso.
     */
    private fun isGone(item: DeleteItem): Boolean {
        val uri = resolveContentUri(item)
        if (uri != null) {
            return try {
                contentResolver.query(
                    uri, arrayOf(MediaStore.MediaColumns._ID), null, null, null
                )?.use { cursor -> cursor.count == 0 } ?: false
            } catch (e: Exception) {
                false
            }
        }
        val path = item.path ?: return false
        return path.isNotEmpty() && !java.io.File(path).exists()
    }

    /**
     * Deixa a URI pronta para o `MediaStore.createDeleteRequest`.
     *
     * O SO só aceita `content://media/...`: qualquer outro esquema
     * (`file://`, `content://downloads/...`, authority do app) faz o pedido
     * INTEIRO ser recusado. Em vez de reprovar o lote, reconstroi a URI:
     *  1. se a URI já é do MediaStore, usa como está;
     *  2. senão, tenta pelo id do item na coleção do tipo (áudio/vídeo/imagem/
     *     arquivos) — é o `_id` do MediaStore, não um id do app;
     *  3. senão, procura o id por caminho em `MediaStore.Files`.
     *
     * Devolve null quando nenhuma das três funciona; o chamador então tenta
     * o disco antes de desistir do item.
     */
    private fun sanitizeMediaUri(item: DeleteItem, uri: Uri): Uri? {
        if (uri.scheme == SCHEME_CONTENT && uri.authority == AUTHORITY_MEDIA) {
            return uri
        }
        item.mediaId?.let { id ->
            return ContentUris.withAppendedId(collectionFor(item.type), id)
        }
        val path = item.path?.takeIf { it.isNotEmpty() } ?: return null
        val foundId = lookupMediaStoreIdByPath(path) ?: return null
        return ContentUris.withAppendedId(filesCollection(), foundId)
    }

    /**
     * Última tentativa para um item sem URI elegível: exclusão direta no disco.
     *
     * Só funciona de fato com "Todos os arquivos" (MANAGE_EXTERNAL_STORAGE)
     * ou para arquivo do próprio app. Sem permissão, devolve PermissionDenied
     * com o motivo certo em vez de um "não foi possível" genérico.
     */
    private fun deleteOnDisk(item: DeleteItem): DeleteOutcome {
        val path = item.path?.takeIf { it.isNotEmpty() } ?: return DeleteOutcome.NotFound
        return deleteFile(java.io.File(path))
    }

    /// A linha do MediaStore ainda existe? Usado para detectar notFound.
    private fun contentExists(uri: Uri): Boolean = try {
        contentResolver.query(
            uri, arrayOf(MediaStore.MediaColumns._ID), null, null, null
        )?.use { cursor -> cursor.count > 0 } ?: false
    } catch (e: Exception) {
        // Sem conseguir verificar, assume que existe: o fluxo de exclusão
        // normal vai tentar de qualquer forma e reportar o desfecho real.
        true
    }

    // ---- Resolução do alvo: MediaStore ou disco ----

    private sealed class ResolvedTarget {
        data class Content(val uri: Uri) : ResolvedTarget()
        data class OnDisk(val file: java.io.File) : ResolvedTarget()
    }

    private fun resolveTarget(item: DeleteItem): ResolvedTarget? {
        resolveContentUri(item)?.let { return ResolvedTarget.Content(it) }
        val path = item.path?.takeIf { it.isNotEmpty() } ?: return null
        return ResolvedTarget.OnDisk(java.io.File(path))
    }

    /// URI `content://` do item, ou null se não houver (aí é exclusão por
    /// disco). Prefere: uri explícita -> id do MediaStore -> busca do
    /// caminho em MediaStore.Files (é o que permite excluir PDFs e
    /// documentos em Documents/Downloads pelo diálogo do sistema).
    private fun resolveContentUri(item: DeleteItem): Uri? {
        val explicit = item.uri?.takeIf { it.isNotEmpty() }
        if (explicit != null) return Uri.parse(explicit)

        val id = item.mediaId
        if (id != null) return ContentUris.withAppendedId(collectionFor(item.type), id)

        val path = item.path?.takeIf { it.isNotEmpty() } ?: return null
        val foundId = lookupMediaStoreIdByPath(path)
        return if (foundId != null) {
            ContentUris.withAppendedId(filesCollection(), foundId)
        } else {
            null
        }
    }

    private fun collectionFor(type: String): Uri = when (type) {
        "audio" -> MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        "video" -> MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        "image" -> MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        // PDFs e "outros arquivos" vivem na coleção genérica Files.
        else -> filesCollection()
    }

    private fun filesCollection(): Uri =
        MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL)

    /// Id do MediaStore.Files para um caminho absoluto (null = não indexado).
    private fun lookupMediaStoreIdByPath(path: String): Long? {
        return try {
            contentResolver.query(
                filesCollection(),
                arrayOf(MediaStore.Files.FileColumns._ID),
                "${MediaStore.Files.FileColumns.DATA} = ?",
                arrayOf(path),
                null
            )?.use { cursor ->
                if (cursor.moveToFirst()) cursor.getLong(0) else null
            }
        } catch (e: Exception) {
            android.util.Log.w(TAG, "busca de id por caminho falhou: $e")
            null
        }
    }

    private fun hasAllFilesAccess(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.R ||
            Environment.isExternalStorageManager()

    private fun emptyPayload(): Map<String, Any?> = mapOf(
        "deleted" to emptyList<String>(),
        "notFound" to emptyList<String>(),
        "failed" to emptyList<Map<String, String>>(),
        "cancelled" to false,
        "permissionRequired" to false
    )

    /// Mesma regra de `MediaRef.key` no Dart — é o contrato do resultado.
    private fun computeKey(
        type: String,
        id: Long?,
        uri: String?,
        path: String?
    ): String {
        if (!uri.isNullOrEmpty()) return uri
        if (id != null) return "$type:$id"
        return path ?: ""
    }

    /** Um item do lote, como veio do Dart. */
    private class DeleteItem(
        val type: String,
        val mediaId: Long?,
        val uri: String?,
        val path: String?,
        val key: String
    )

    /**
     * Desfecho de um item, no vocabulário que vai para o Dart.
     *
     * Ser um tipo fechado (e não um valor nulo dentro de um Map) é o que
     * impede a confusão entre "chave ausente" e "confirmado como removido" —
     * uma ambiguidade que antes fazia o arquivo já apagado pelo sistema voltar
     * para a UI como exclusão não confirmada.
     */
    private sealed class DeleteOutcome {
        /** Confirmado: a linha sumiu do MediaStore / o arquivo sumiu do disco. */
        object Deleted : DeleteOutcome()

        /** Não estava mais lá (já apagado por outro app, por exemplo). */
        object NotFound : DeleteOutcome()

        /** O usuário recusou no diálogo do sistema. Nada foi alterado. */
        object Cancelled : DeleteOutcome()

        /** Ainda sem veredito — a verificação final em `finishDelete` decide. */
        object Undecided : DeleteOutcome()

        /** Falhou, com motivo legível para o usuário. */
        data class Failed(val reason: String) : DeleteOutcome()

        /** Falhou porque falta permissão; o motivo diz qual conceder. */
        data class PermissionDenied(val reason: String) : DeleteOutcome()
    }

    /**
     * Estado acumulado do lote: um desfecho por chave de item.
     *
     * Thread-safe porque o lote é montado numa thread de background, completado
     * na thread da UI (diálogo do SO) e por fim finalizado em outra thread.
     */
    private class DeleteState(
        val items: List<DeleteItem>,
        val result: MethodChannel.Result
    ) {
        private val outcomes = LinkedHashMap<String, DeleteOutcome>()

        /**
         * Garante que o `MethodChannel.Result` seja respondido UMA única vez.
         *
         * Existem dois motivos plausíveis para `finishDelete` ser chamado duas
         * vezes: uma exceção depois do diálogo já estar em tela, ou uma
         * conclusão duplicada. Responder duas vezes faz o Flutter lançar
         * ("reply already submitted") e derruba o isolate do canal.
         */
        private val answered = AtomicBoolean(false)

        /// Reserva o direito de responder. Devolve false para quem perdeu a
        /// corrida — esse chamador não responde nada.
        fun claimAnswer(): Boolean = answered.compareAndSet(false, true)

        fun set(item: DeleteItem, outcome: DeleteOutcome) {
            synchronized(outcomes) { outcomes[item.key] = outcome }
        }

        fun outcomeOf(item: DeleteItem): DeleteOutcome? =
            synchronized(outcomes) { outcomes[item.key] }

        /**
         * O usuário recusou no diálogo: os itens que dependiam da confirmação
         * viram [DeleteOutcome.Cancelled]. Itens já decididos antes do diálogo
         * (ex.: notFound) mantêm o próprio desfecho.
         */
        fun cancelAll() {
            synchronized(outcomes) {
                for (item in items) {
                    if (outcomes[item.key] is DeleteOutcome.Undecided) {
                        outcomes[item.key] = DeleteOutcome.Cancelled
                    }
                }
            }
        }

        /// Lote rejeitado antes de começar (ex.: já há um diálogo em tela).
        fun failAll(reason: String) {
            synchronized(outcomes) {
                for (item in items) outcomes[item.key] = DeleteOutcome.Failed(reason)
            }
        }

        /**
         * Falha apenas o que ainda NÃO tem desfecho.
         *
         * Usado no `catch` do trabalho em background: um item já confirmado
         * como removido precisa continuar `deleted` — sobrescrevê-lo por
         * `failed` seria mentir sobre um arquivo que saiu do aparelho.
         */
        fun failPending(reason: String) {
            synchronized(outcomes) {
                for (item in items) {
                    if (!outcomes.containsKey(item.key)) {
                        outcomes[item.key] = DeleteOutcome.Failed(reason)
                    }
                }
            }
        }
    }

    /** Exclusão aguardando a resposta do diálogo do SO. */
    private class PendingDelete(
        val state: DeleteState,
        /** Preenchido no Android 10: URIs a repetir após o RESULT_OK. */
        val retry: List<Pair<DeleteItem, Uri>>?
    ) {
        /**
         * O `IntentSender` já foi entregue ao SO e o diálogo está em tela.
         *
         * Enquanto for true e [dialogAnswered] for false, a reserva do slot
         * NÃO pode ser liberada: um segundo pedido abriria um segundo diálogo
         * por cima do primeiro.
         */
        @Volatile
        var dialogLaunched = false

        /// O SO já devolveu RESULT_OK/RESULT_CANCELED.
        @Volatile
        var dialogAnswered = false
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

    /**
     * `content://` de um arquivo, via FileProvider.
     *
     * Desde o Android 7 nenhum app pode passar `file://` para fora
     * (FileUriExposedException). Devolve null quando o caminho não existe ou
     * está fora das raízes declaradas em `res/xml/file_paths.xml`.
     */
    private fun queryContentUri(path: String): String? {
        return try {
            val file = java.io.File(path)
            if (!file.exists()) return null
            androidx.core.content.FileProvider.getUriForFile(
                this,
                "$packageName.fileprovider",
                file
            ).toString()
        } catch (e: Exception) {
            android.util.Log.w(TAG, "contentUri($path): $e")
            null
        }
    }

    /**
     * Abre o seletor de papel de parede do sistema com a imagem.
     *
     * Usa ACTION_SET_WALLPAPER (e não `WallpaperManager.setStream`) de
     * propósito: o SO mostra a pré-visualização e deixa o usuário cortar e
     * posicionar, em vez de esticar a imagem e estragá-la.
     */
    private fun setAsWallpaper(path: String) {
        val uri = queryContentUri(path)
        if (uri == null) {
            runOnUiThread {
                Toast.makeText(this, "Não foi possível abrir esta imagem.", Toast.LENGTH_SHORT).show()
            }
            return
        }
        val intent = Intent(Intent.ACTION_SET_WALLPAPER).apply {
            data = Uri.parse(uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        runOnUiThread {
            startActivitySafely(intent, "Nenhum app de papel de parede encontrado")
        }
    }

    /**
     * Abre a imagem em um EDITOR externo (ACTION_EDIT).
     *
     * ACTION_EDIT e não ACTION_VIEW: ACTION_VIEW abriria o visualizador, só de
     * leitura, que não resolve "editar".
     */
    private fun editImage(path: String) {
        val uri = queryContentUri(path)
        if (uri == null) {
            runOnUiThread {
                Toast.makeText(this, "Não foi possível abrir esta imagem.", Toast.LENGTH_SHORT).show()
            }
            return
        }
        val intent = Intent(Intent.ACTION_EDIT).apply {
            data = Uri.parse(uri)
            type = "image/*"
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION
            )
        }
        runOnUiThread {
            startActivitySafely(intent, "Nenhum editor de imagem instalado")
        }
    }

    /**
     * Inicia uma intent informando quando NENHUM app pode atender.
     *
     * `ActivityNotFoundException` é o sintoma de "não há app instalado" e sem
     * este tratamento a tela ficaria em silêncio — o usuário tocaria em
     * "Editar" e nada aconteceria, igual ao bug das ListTile inertes.
     */
    private fun startActivitySafely(intent: Intent, emptyMessage: String) {
        try {
            startActivity(intent)
        } catch (e: android.content.ActivityNotFoundException) {
            Toast.makeText(this, emptyMessage, Toast.LENGTH_LONG).show()
        } catch (e: SecurityException) {
            Toast.makeText(this, "O Android bloqueou esta ação.", Toast.LENGTH_SHORT).show()
        }
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