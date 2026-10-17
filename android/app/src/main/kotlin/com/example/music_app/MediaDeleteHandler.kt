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


class MediaDeleteHandler(
    private val activity: Activity,
    private val flutterEngine: FlutterEngine
) {

    fun register() {
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
    }

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
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
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
                        if (activity.contentResolver.delete(uri, null, null) > 0) {
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
            MediaStore.createDeleteRequest(activity.contentResolver, uris).intentSender
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

        activity.runOnUiThread {
            try {
                // Marca ANTES de entregar: se `startIntentSenderForResult`
                // lançar depois de o SO ter recebido o pedido, a reserva
                // precisa ser mantida para o `onActivityResult` que virá.
                synchronized(deleteLock) {
                    pendingDelete?.takeIf { it.state === state }?.dialogLaunched = true
                }
                activity.startIntentSenderForResult(sender, DELETE_MEDIA_REQUEST, null, 0, 0, 0)
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
        if (activity.contentResolver.delete(uri, null, null) > 0) {
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

        activity.runOnUiThread {
            try {
                synchronized(deleteLock) {
                    pendingDelete?.takeIf { it.state === state }?.dialogLaunched = true
                }
                activity.startIntentSenderForResult(
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
                if (activity.contentResolver.delete(uri, null, null) > 0) {
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
            MediaScannerConnection.scanFile(activity, paths.toTypedArray(), null, null)
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
                activity.contentResolver.query(
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
        activity.contentResolver.query(
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
            activity.contentResolver.query(
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
                activity,
                "${activity.packageName}.fileprovider",
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
            activity.runOnUiThread {
                Toast.makeText(activity, "Não foi possível abrir esta imagem.", Toast.LENGTH_SHORT).show()
            }
            return
        }
        val intent = Intent(Intent.ACTION_SET_WALLPAPER).apply {
            data = Uri.parse(uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        activity.runOnUiThread {
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
            activity.runOnUiThread {
                Toast.makeText(activity, "Não foi possível abrir esta imagem.", Toast.LENGTH_SHORT).show()
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
        activity.runOnUiThread {
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
            activity.startActivity(intent)
        } catch (e: android.content.ActivityNotFoundException) {
            Toast.makeText(activity, emptyMessage, Toast.LENGTH_LONG).show()
        } catch (e: SecurityException) {
            Toast.makeText(activity, "O Android bloqueou esta ação.", Toast.LENGTH_SHORT).show()
        }
    }
}
