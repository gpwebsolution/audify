# Correções do Audify — Auditoria de estabilidade (ago/2026)

Este documento explica, em linguagem simples, **o que estava quebrado**, **por quê**
e **o que foi mudado**. Foi feito para o dono do projeto acompanhar as correções
sem precisar ler código.

---

## Resumo rápido

| # | Problema | Causa raiz | Correção |
|---|----------|-----------|----------|
| 1 | App trava no release e "não abre mais" | Regras de minificação (R8) incompletas + nenhum tratamento de erro global | Regras ProGuard completas para todos os plugins + captura global de erros com log local |
| 2 | Música para / notificação some em segundo plano | Serviço de áudio saía do modo foreground ao pausar; fabricantes matavam o app | Serviço agora permanece em foreground mesmo pausado + pedido de isenção de otimização de bateria |
| 3 | Sem diagnóstico quando o app fecha sozinho | Nenhum erro era registrado | Log local `crash_log.txt` visível em Configurações → Log de erros |
| 4 | App não reagia ao ir/voltar do segundo plano | Nenhum observador de ciclo de vida | MainScreen e player de vídeo agora observam pausa/retorno |
| 5 | Riscos adicionais encontrados na auditoria | Race no banco, cache sem limite, leaks, catches vazios | Detalhados na seção 5 |
| 6 | **Só dava para excluir fotos e PDFs** — música, vídeo e outros arquivos não saíam do aparelho | Um único método de exclusão sem caminho por versão do SO, com retorno booleano não verificado e MediaStore não reindexado | Serviço unificado com a estratégia correta do SO + limpeza de estado (seção 6) |

---

## 1. O crash silencioso no release (suspeita principal confirmada)

### O que estava quebrado
O APK de release é "minificado": o Android remove e renomeia classes que ele
acredita não serem usadas. O arquivo de regras (`proguard-rules.pro`) só protegia
2 bibliotecas (audio_service e on_audio_query). Todas as outras ficavam sujeitas à
remoção/renomeação — incluindo:

- **video_player** (ExoPlayer/Media3 por baixo)
- **syncfusion_flutter_pdfviewer** (módulo nativo do leitor de PDFs)
- **file_picker**, **share_plus**, **open_filex**, **permission_handler**
- **sqflite** (banco de dados), **audioplayers**, **path_provider**, etc.

Quando um desses plugins resolve uma classe/recurso **por nome em tempo de
execução** e o minificador renomeou essa classe, o app explode **sem nenhuma
mensagem** — exatamente o sintoma relatado: funciona no debug, trava no release.
E como alguns desses canais são usados logo na abertura, um estado corrompido
pós-crash deixava o app **crashando em loop** até limpar dados/reinstalar.

### O que foi feito
- `android/app/proguard-rules.pro` foi reescrito com regras explícitas para
  **todos** os plugins do projeto (nomes verificados um a um nos pacotes
  instalados), além de Media3/ExoPlayer, FileProvider e anotações.
- Estratégia deliberada de "proteger demais": como o uso é pessoal via sideload,
  alguns KB a mais no APK valem a estabilidade.
- Observações honestas:
  - `image`, `exif`, `archive` e `crypto` são pacotes **100% Dart** — nunca foram
    afetados pelo minificador nativo (não precisam de regra; ficou documentado
    para não haver falso mistério).
  - A Syncfusion não publica regras oficiais de R8 para o visualizador Flutter
    (o renderizador é Dart); o módulo nativo do plugin foi protegido por nome.

---

## 2. Reprodução em segundo plano

### O que estava quebrado
1. Na configuração do audio_service, `androidStopForegroundOnPause: true`
   derrubava o serviço de primeiro plano **toda vez que a música pausava**. Em
   aparelhos Xiaomi/MIUI, Samsung e Motorola, o Android aproveitava isso para
   matar o processo minutos depois — perdendo notificação, controles da tela de
   bloqueio e posição.
   - Detalhe técnico descoberto: o próprio package **rejeita** a combinação
     `androidNotificationOngoing: true` com `stopForegroundOnPause: false`
     (existe um assert no código dele). A combinação correta escolhida foi
     `ongoing: false` + `stopForegroundOnPause: false`. Efeito colateral bom:
     deslizar a notificação para fora agora **para a música de forma limpa**
     (antes disso não havia caminho de encerramento limpo).
2. O comentário no AndroidManifest dizia que o segundo plano dependia só de
   WAKE_LOCK "sem depender do foreground service" — informação falsa/desatualizada
   que já causou decisões erradas. Reescrito.
3. Interrupções de áudio tratavam tudo igual: qualquer fim de interrupção retomava
   a música — inclusive quando **outro app assumiu o áudio permanentemente**.
   Agora: ligação/notificação → pausa e **retoma sozinha**; outro app assumiu →
   pausa e **fica pausada** (comportamento recomendado pela documentação).
4. Faltava pedir ao usuário a **isenção de otimização de bateria** — principal
   motivo de players morrerem em segundo plano em MIUI/Samsung/Motorola mesmo
   com foreground service correto.

### O que foi feito
- Config corrigida em `lib/main.dart` (serviço permanece vivo pausado).
- Manifest atualizado (comentários corretos + permissão
  `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`).
- Novo item em **Configurações → Segundo plano**: "Ignorar otimização de bateria",
  que abre o diálogo oficial do sistema.
- `lib/services/audio_service.dart` reescrito por partes: interrupções
  diferenciadas, todos os pontos de chamada ao player protegidos (inclusive os
  que rodam dentro de callbacks de stream), erros dos botões da notificação
  capturados (um throw ali atravessa o canal nativo).

---

## 3. Diagnóstico de crashes (log local, 100% offline)

### O que estava quebrado
Qualquer exceção não tratada derrubava o app inteiro **sem deixar rastro**. Se o
app fechasse sozinho, era impossível saber o porquê depois.

### O que foi feito
- Novo `lib/services/error_log_service.dart`: registra erros de três fontes —
  erros do framework Flutter (`FlutterError.onError`), exceções assíncronas do
  sistema (`PlatformDispatcher.instance.onError`) e tudo que escapar da zona
  principal (`runZonedGuarded`).
- Os logs vão para `logs/crash_log.txt` dentro dos documentos do app, com teto
  de ~128 KB (nunca enche o armazenamento). **Nada sai do aparelho** — zero
  telemetria/analytics, como o projeto exige.
- Para consultar: **Configurações → Log de erros** (com botão de limpar).
- Bônus direto contra o sintoma "não abre mais": se a inicialização do
  audio_service falhar (estado ruim pós-crash), o app **agora abre mesmo assim**
  em modo degradado (som sem notificação) em vez de crashar em loop.

---

## 4. Ciclo de vida (ir para segundo plano / voltar)

### O que estava quebrado
Nenhuma tela observava o ciclo de vida: o app não salvava a sessão ao sair, não
ressincronizava a UI ao voltar (a posição mostrada podia estar defasada em relação
ao que você controlou pela notificação/tela de bloqueio) e o **vídeo continuava
tocando som com o app minimizado**.

### O que foi feito
- `MainScreen` agora observa `paused/resumed/detached`: ao ir para segundo plano
  salva "continuar de onde parou" imediatamente; ao voltar, ressincroniza
  posição/status/erros com o serviço real de áudio.
- Player de vídeo pausa sozinho ao sair do app (e não retoma sozinho — padrão dos
  players). Também protegi o caso de troca rápida de vídeo onde o controller
  morre entre o seek e o play.

---

## 5. Outros problemas encontrados na auditoria completa

Estes não estavam na lista original, mas foram encontrados e corrigidos:

1. **Race condition no banco SQLite** (`playlist_database.dart`): duas operações
   simultâneas no boot podiam abrir o banco **duas vezes** (vazando uma conexão
   e arriscando escritas concorrentes em handles diferentes). Agora há um lock
   de abertura (Completer): uma única conexão, todos aguardam a mesma.
2. **Cache de miniaturas era write-only** (`ThumbnailDiskCache`): as miniaturas
   eram gravadas em disco mas **nunca relidas** — puro desperdício de espaço.
   Agora lê do disco antes de regerar. Além disso:
   - Ganhou **limite de tamanho total (~48 MB)** além do limite de arquivos;
     a poda roda em isolate (não trava a UI).
   - **Bug grave relacionado:** PDFs usavam `path.hashCode` como chave — o
     hashCode do Dart muda a cada abertura do app, então as chaves nunca
     batiam e arquivos órfãos **se acumulavam para sempre** no disco. Trocado
     por SHA-1 estável do caminho.
3. **Leak no visualizador de PDF**: o `PdfViewerController` nunca era descartado.
   Agora é. Também tirei I/O síncrona de dentro do `build()`.
4. **Catches vazios/silenciosos**: ~15 pontos que engoliam erros sem registro
   foram atualizados para registrar o erro (logcat/log local) ou dar feedback
   na tela — exemplos: falha ao carregar músicas/vídeos/galeria/PDFs, salvar
   sessão, restaurar da lixeira, compartilhar arquivos, gerar cópia sem EXIF,
   favoritos de PDF. Os guards internos dos jobs em isolate (que pulam arquivos
   individuais ilegíveis de propósito, milhares de vezes por varredura)
   permanecem silenciosos **por design** — registrá-los geraria spam inútil.
5. **Favoritos de PDF** podiam chamar `notifyListeners()` após o dispose (crash
   em debug) — recebeu o mesmo guard `_isDisposed` dos outros providers.
6. **Defesa no boot**: preferências e audio_service agora são inicializados
   dentro de try/catch — nada do boot pode mais impedir o app de abrir.

---

## 6. Exclusão de mídia: só funcionava para foto e PDF

### O problema
Na aba Música e na aba Vídeos, "Excluir do aparelho" **não apagava nada**: o
arquivo continuava no aparelho e/ou voltava a aparecer na lista. Foto (Galeria)
e PDF funcionavam normalmente.

### Por que só duas abas funcionavam
A primeira versão da correção trocou o `deleteMedia` antigo (um método único,
com retorno booleano) pelo serviço unificado com estratégia por versão do SO.
Isso resolveu a maior parte dos defeitos, mas deixou **um buraco no Android
11+ que atingia todos os tipos**, então música e vídeo continuaram sem excluir
e foto/PDF só funcionavam por acaso:

- **Foto e PDF** — funcionavam porque o caminho delas acabava por não passar
  pelo diálogo do sistema (PDF sem indexação ia por `File.delete()`), e por
  isso escapavam do buraco.
- **Música e vídeo** — vão sempre por `content://`, então caíam nele.

### O defeito que sobrava (o que realmente travava a exclusão)
No Android 11+, `MainActivity.deleteWithSystemDialog` montava o
`createDeleteRequest`, o SO abria o diálogo, o usuário confirmava, o SO apagava
— e **o app não registrava veredito nenhum para nenhum item**.

O rastreamento era um `LinkedHashMap<String, String?>` onde `null` significava
"confirmado como removido". A checagem final fazia:

```kotlin
when (state.outcomes[item.key]) {
    null -> continue                                  // "já confirmado"
    UNDECIDED -> ...verificar no MediaStore...
}
```

Item **nunca registrado** e item **registrado como removido** são indistinguíveis
num `when` sobre `Map.get`. Todo item caía no primeiro ramo e era descartado, e
o payload devolvia `{deleted: [], failed: []}`.

No Dart, a regra conservadora (item não confirmado = falha) transformava isso em
`"A exclusão não foi confirmada."` para todos os itens, e como `deleted` vinha
vazio o callback de limpeza **nunca era chamado** — a lista não atualizava. O
sintoma final era: o diálogo aparecia, o arquivo sumia do aparelho, o app
dizia que falhou e o item continuava na tela.

Além disso, o mesmo método `deleteMedia` antigo tinha outros defeitos reais:

1. **No Android 10 (API 29) não havia tratamento de `RecoverableSecurityException`.**
   O SO **exige** essa exceção para permitir apagar mídia de outro app: o
   `contentResolver.delete(uri)` cru lançava, o `catch` genérico virava um erro
   genérico e o Dart não conseguia distinguir "falhou" de "usuário cancelou".
   No Android 10 esse é o caminho usado para **todas** as mídias.
2. **`Uri.fromFile()` gerava uma URI `file://`.** Isso acontecia sempre que
   faltava o id do MediaStore (PDF do seletor SAF, "outros arquivos"). O
   `createDeleteRequest` **rejeita** URIs `file://`, e o ramo de contingência
   caía em `File.delete()` — que, sob *Scoped Storage*, **falha silenciosamente**
   para arquivo de outro app. Era o caminho do item "outros arquivos".
3. **O MediaStore não era reindexado.** Sem `MediaScannerConnection` /
   notificação do `ContentResolver`, uma exclusão feita pelo caminho deixava
   uma linha órfã no banco do MediaStore. O arquivo tinha sumido do disco, mas
   **voltava a aparecer na lista** — exatamente o sintoma relatado.
4. **O resultado pendente era um único espaço (`_pendingDeleteResult`) e não
   havia exclusão em lote.** Um segundo pedido sobrescrevia o primeiro e o
   `Future` do Dart ficava esperando para sempre: a tela parecia travada e o
   usuário não recebia retorno nenhum.

Some-se a isso dois problemas de interface: na aba Música o botão de excluir
ficava **escondido dentro da opção "Compartilhar"** (dois bottom sheets
sequenciais para uma ação), e o retorno era **um booleano genérico** — um
item em lote que falhava era reportado como sucesso, e um `false` (falha real)
era reportado como "exclusão cancelada".

### O que foi feito

**Serviço unificado** (`lib/services/media_delete_service.dart` +
`lib/models/media_ref.dart`): uma única API `deleteMedia(List<MediaRef>)`,
usada pelas seis abas. `MediaRef` carrega id do MediaStore, `content://`, caminho
e tipo — e define uma **chave estável** que é o contrato com o lado nativo.

**Estratégia nativa correta por versão do SO** (`MainActivity.kt`):

| Versão do Android | Estratégia |
|---|---|
| 11+ (API 30+) | `MediaStore.createDeleteRequest` com **um único diálogo para o lote inteiro** (funciona para áudio, vídeo e imagem sem "Todos os arquivos") |
| 10 (API 29) | `contentResolver.delete` capturando `RecoverableSecurityException` → confirma com o usuário e **repete** a exclusão |
| 9 e abaixo (API ≤ 28) | `contentResolver.delete` direto (WRITE_EXTERNAL_STORAGE) com `File.delete()` como reserva |

Além disso:

- **PDFs e "outros arquivos"** (que não são mídia indexada) passam a ser
  resolvidos por caminho em `MediaStore.Files` — assim também entram pelo
  diálogo do sistema em vez de bater no `File.delete()` mudo. Sem
  indexação e sem "Todos os arquivos", a resposta é um motivo claro.
- **Reindexação obrigatória** com `MediaScannerConnection.scanFile` ao final de
  toda exclusão — acaba com o item que "volta a aparecer".
- **Desfecho tipado por item** (`sealed class DeleteOutcome`): `Deleted`,
  `NotFound`, `Cancelled`, `Undecided`, `Failed` e `PermissionDenied`.
  Substituiu o `Map` com valor `null` e eliminou a ambiguidade
  "ausente = removido" que era a causa raiz do defeito acima.
- **Verificação real**: cada item entra como `Undecided` antes do diálogo do
  sistema, e `finishDelete` consulta o MediaStore / confere o disco antes de
  promover a `Deleted`. Sem `path`/`uri`/`id` não há como verificar, e aí o
  item **não** vira "excluído" — a verificação que falha não vira sucesso.
- **`NotFound`**: arquivo já apagado por outro app é reportado como ausente,
  não como falha nem como exclusão bem-sucedida — e ainda assim sai das
  listas do app (`DeleteResult.removed` = excluídos + ausentes).
- **Exclusão concorrente resolvida**: a reserva do slot de exclusão é feita na
  thread da plataforma, sob monitor, **antes** de qualquer trabalho em
  background. Antes, a checagem e a reserva ficavam em threads diferentes e
  dois toques rápidos sobrescreviam o `Result` pendente.
- **Sobrevive à recriação da Activity**: o lote pendente vive no `companion`
  (escopo de processo), não em campo da Activity — rotação ou pressão de
  memória já não deixam o `Future` do Dart pendurado para sempre.
- **Manifest**: `WRITE_EXTERNAL_STORAGE` passou para `maxSdkVersion="28"`
  (é a permissão do caminho de exclusão do Android 9 e abaixo). Nenhuma
  permissão existente foi removida.

**Integração em todas as abas** (`MediaActions` reescrito):

- Diálogo de confirmação em português antes de excluir
  ("Excluir X? ... Esta ação não pode ser desfeita").
- SnackBar com o **resultado real**: sucesso, cancelado, ou erro com o motivo.
- **Música**: item "Excluir" direto no menu de toque longo (e no player em tela
  cheia). Faixa de `assets/songs/` mostra "Faixa embutida no app, não pode ser
  excluída" — não é apagável por definição.
- **Vídeos**: item direto na grade e botão no player em tela cheia, que
  **descarta o `VideoPlayerController` antes de apagar** (com o decoder
  segurando o arquivo, o SO não consegue removê-lo). A exclusão do player
  reusa `VideosScreen.deleteVideo` (uma fonte só de lógica). Se o usuário
  recusar ou a exclusão falhar, o controller é **recriado** — antes ele
  ficava descartado e o player aparecia quebrado.
- **Galeria e PDFs**: migrados para o mesmo serviço unificado, sem perder o
  que já funcionava.
- Se o usuário **cancela o diálogo do sistema**, nada na interface muda.
- A limpeza de estado usa `DeleteResult.removed` (excluídos **e** ausentes):
  um arquivo que já não estava no aparelho também sai das listas, senão vira
  item fantasma permanente.

**Consistência de estado** depois da exclusão confirmada:

- Item sai da lista do provider correspondente (`notifyListeners` incluso).
- Música em reprodução: o áudio **para e avança** para a próxima sobrevivente;
  a faixa sai da fila (`PlaybackQueue.removeSongs`, que também sabe que a
  removida **não pode voltar** ao desativar o embaralhamento) e do estado de
  retomada de sessão (`SessionRepository.clear`) — **só quando a excluída era
  a que tocava**: excluir outra faixa não pode derrubar o "continuar de onde
  parou" de uma música que continua no aparelho.
- Vídeo em reprodução: sai da `VideoPlayQueue` (`VideoPlayQueue.removeVideos`,
  que limpa também a ordem original para não voltar ao desligar o aleatório).
- `MediaRef.fromSong` recusa faixa de asset e faixa sem id/caminho: um id
  sintético de asset colidiria com um id real do MediaStore e o nativo poderia
  apagar a música errada.
- A faixa/vídeo sai de **todas** as playlists no SQLite.
- Cache de miniaturas é apagado (memória **e** disco), junto com o progresso de
  leitura do PDF e o favorito dele.

**Testes** — `test/media_delete_service_test.dart` (novo) trava a regra mais
importante: **um item que o nativo não confirmou vira falha, nunca sucesso**;
`test/playback_queue_test.dart` ganhou 10 casos de remoção de faixa da fila;
`test/session_repository_test.dart` ganhou o caso de limpeza da sessão.

### Endurecimento (2ª rodada)

Sete ajustes de robustez sobre o mesmo caminho de exclusão:

1. **Resposta exatamente uma vez.** `finishDelete` agora reserva o direito de
   responder (`AtomicBoolean.compareAndSet`) antes de qualquer outro efeito.
   Responder duas vezes fazia o Flutter lançar `reply already submitted` e
   derrubar o isolate do canal.
2. **O `Result` nunca fica sem resposta.** Todo o trabalho em background de
   `deleteBatch` passou a `try/catch/finally`: uma exceção em qualquer etapa
   deixava o Future do Dart pendurado para sempre (a tela parecia travada). No
   `catch`, só os itens **sem** desfecho viram `failed` — quem já foi
   confirmado como removido continua `deleted`, porque sobrescrever seria
   mentir sobre um arquivo que saiu do aparelho. O `finally` libera a reserva,
   de forma condicional: com um diálogo do SO em tela a reserva **precisa**
   continuar, senão um segundo pedido abriria outro diálogo por cima.
3. **URI validada antes do `createDeleteRequest`.** O SO só aceita
   `content://media/...`; uma URI `file://` ou de outra authority fazia o SO
   recusar o pedido **inteiro**, derrubando os itens válidos do mesmo lote.
   Agora cada URI é conferida e, se inválida, reconstruída pelo `id`+tipo ou
   pelo caminho em `MediaStore.Files`; só sem nenhuma das três o item cai para
   exclusão direta no disco — nunca reprovado junto com o lote.
4. **Timeout de 90 s no Dart** (`MediaDeleteService.timeout`). A exclusão passa
   por um diálogo do sistema e é assíncrona; se o nativo travar, o Future
   ficava pendurado. No timeout volta `failed` com motivo claro, e como nada
   foi confirmado **nenhuma lista é alterada**.
5. **Só `deleted` limpa estado.** `cancelled`, `failed` e `permissionRequired`
   nunca limpam lista, fila, playlist, sessão nem cache — nesses casos o
   arquivo continua no aparelho e limpar viraria item fantasma. `notFound`
   também não limpa sozinho: precisa passar por `DeleteResult.confirmAbsent`,
   que revalida contra o disco. O teste é unilateral de propósito —
   `existsSync() == true` é prova de que o arquivo existe, enquanto `false`
   pode ser só falta de permissão de leitura, e aí a confiança é do nativo (que
   consultou o MediaStore).
6. **Player liberado antes de excluir.** Com o handle de áudio ou o decoder de
   vídeo abertos, a remoção falha **sem erro visível** — o diálogo aparece, o
   arquivo sobrevive. Música agora para antes de pedir a exclusão e retoma se o
   usuário desistir; vídeo descarta o `VideoPlayerController` depois do
   "Excluir" e antes da chamada nativa (antes rodava antes do diálogo e
   congelava a imagem enquanto o usuário decidia).
7. **`MediaActions.onBeforeDelete`** — gancho único para o item 6, para a tela
   não precisar orchestrar a liberação do player por fora.

**Testes desta rodada** — `test/media_delete_channel_test.dart` (novo, 14 casos)
exercita o canal com um MethodChannel falso, o que é bem mais perto do defeito
real do que testar só `parseResult`: `deleted`, `failed`, `cancelled`,
`permissionRequired`, `notFound` (inclusive com um arquivo **real** em disco que
continua existindo, provando o veto), timeout com um handler que nunca responde,
resposta `null` do SO e `PlatformException`.

---

## 7. Ações de imagem e grade com densidade ajustável

### Menu de ações do visualizador de fotos

O visualizador em tela cheia só tinha "Metadados" no AppBar. Agora um botão de
menu concentra as ações que fazem falta num player local:

| Ação | Como funciona |
|---|---|
| **Definir como papel de parede** | `ACTION_SET_WALLPAPER` — o SO mostra pré-visualização e deixa o usuário cortar e posicionar (melhor que esticar a imagem com `WallpaperManager`) |
| **Editar** | `ACTION_EDIT`, que abre um editor instalado; `ACTION_VIEW` serviria só para ver |
| **Marca d'água** | texto escrito numa **cópia**, no app |
| **Detalhes** | painel de informações + EXIF |
| **Compartilhar** | o mesmo caminho das demais abas |

**FileProvider (novo).** Desde o Android 7 nenhum app pode entregar `file://`
para fora — lança `FileUriExposedException`. Papel de parede e edição dependem
disso, então o manifest agora declara o `androidx.core.content.FileProvider` com
`res/xml/file_paths.xml`. A permissão é **temporária e por arquivo**: o app de
destino não ganha acesso ao resto do armazenamento.

`startActivitySafely` trata `ActivityNotFoundException` com um aviso — sem isso,
"Editar" em aparelho sem editor seria um botão que não faz nada, exatamente o
defeito das ListTile inertes apontado na auditoria.

### Marca d'água

`WatermarkService` escreve um texto numa **cópia JPEG** — o original nunca é
sobrescrito (a tela foi aberta para ver, não para destruir) e a cópia vai para
`Android/data/com.example.music_app/files/Audify`, que não exige
`MANAGE_EXTERNAL_STORAGE`.

Dois detalhes que o pacote `image` não resolve sozinho:

- As fontes bitmap dele (arial14/24/48) têm tamanho **fixo**. Sem redimensionar,
  o texto sairia minúsculo num print de 4000px e ilegível numa miniatura. O
  serviço desenha no tamanho da fonte e estica com `copyResize`, com o texto
  ocupando 80% da largura (assinatura da app, 30%).
- `compute` roda em **isolate nova**, onde estado estático não existe. O
  diretório de saída é resolvido na isolate principal e viaja no job — o que
  também evita chamar o `path_provider` de dentro do isolate de trabalho.

### Onde ficam as ações (3 pontinhos)

O botão de 3 pontinhos sobre a miniatura foi **removido** da Galeria e dos
Vídeos: com o zoom em 10 colunas o tile tem cerca de 36dp, e um botão de 48dp
cobria a foto inteira. As ações foram para dentro de quem já mostra o conteúdo
em tela cheia, que é onde o usuário está de fato:

| Tela | Menu de ações |
|---|---|
| Visualizador de fotos | papel de parede, editar, marca d'água, detalhes, compartilhar, **excluir** |
| Player de vídeo | adicionar à playlist, compartilhar, detalhes, **excluir** |
| Player de música | adicionar à playlist, compartilhar, detalhes, **excluir** |
| Seleção múltipla | compartilhar, adicionar à playlist, inverter seleção, … |

O "excluir" entrou nos três menus: com o ⋮ fora da grade, era o **único**
caminho para apagar um item a partir de uma miniatura.

Ação que não se aplica vem **desabilitada com o motivo**, nunca oculta — é o
que impede o "botão que não faz nada" apontado na auditoria.

### Seleção múltipla com menu de 3 pontinhos

A barra de lote listava as ações lado a lado. Com 5+ ações (Arquivos tem seis)
ela estourava a largura da tela, e as ações ficavam escondidas atrás de
rolagem horizontal — o usuário nunca as encontrava.

Agora a barra tem **três controles** — selecionar tudo, menu de 3 pontinhos e
cancelar — mais o contador. Tudo o mais, **inclusive excluir**, fica dentro do
menu, com **rótulo em texto** (ícone sozinho seria adivinhação) e esmaecido
quando não se aplica.

Excluir é a ÚLTIMA entrada do menu, depois de um separador: é a ação
irreversível e não deve ficar ao lado das reversíveis. A barra ter cinco
controles era o que forçava rolagem horizontal em tela estreita.

Ganho em todas as abas: **inverter seleção** — a forma rápida de "marcar tudo
menos este", que antes exigia desmarcar item por item.

### Grade com densidade ajustável (Galeria e Vídeos)

As duas abas tinham contagem fixa de colunas (3 fotos, 2 vídeos). Agora há um
botão de **zoom** que escolhe de **2 a 10 itens por linha**, persistido em
`SharedPreferences` (`SettingsProvider`).

O número escolhido é um **teto, não uma garantia**: `effectiveColumns` reduz
pela largura da tela para o tile nunca ficar abaixo de 56dp. Sem isso, 10
colunas num celular de 360dp dariam thumbnails de 36dp — ilegíveis. Quando o
limite reduz a escolha, o botão muda de cor e mostra o número efetivo, para o
usuário não pedir 10 e ver 6 sem explicação.

Vídeos também ajustam a proporção do tile acima de 5 colunas (0.78 → 0.66),
porque a miniatura 16:9 encolhe e o texto precisava de mais altura.

---

## 8. Lixeira com prazo, seleção múltipla e criação de arquivos de texto

### Lixeira: onde ela estava escondida

A lixeira vivia num item de menu escrito só "Lixeira", sem nenhuma pista de
que havia algo ali. O usuário excluía um arquivo e não tinha como descobrir
onde ele tinha ido sem procurar no menu.

- **Badge com a contagem** no item do menu, mais o tamanho ocupado. A lixeira
  fica no diretório de suporte do app — **invisível ao gerenciador de arquivos
  do sistema** — então sem esse número o usuário não tem como saber que ela
  está ocupando espaço.
- **Entrada direta em Configurações** ("Ver lixeira"), ao lado do ajuste de
  prazo.
- O badge é recalculado ao excluir em lote e ao voltar da lixeira (restaurar ou
  apagar lá dentro muda o número).

### Lixeira: prazo de exclusão

A lixeira **não tinha política nenhuma**. `deletedAtMs` era gravado no manifesto
e nunca lido: os arquivos ficavam lá para sempre e o espaço nunca era
devolvido. Pior dos dois mundos — o usuário não sabe que a lixeira ocupa GB e
não consegue liberar sem ir item por item.

Agora há um prazo ajustável em **Configurações → Lixeira → Prazo de
exclusão**: para sempre, 1, 7, 15, 30 ou 90 dias (padrão: 30). O expurgo roda
**ao abrir a lixeira**, antes da lista ser desenhada, e o app avisa quantos
itens foram recolhidos.

Cada item mostra **quando expira** ("expira em 5 dias", "expira amanhã",
"fica na lixeira até você apagar"), e o cabeçalho resume o total e o prazo.

### Lixeira: seleção múltipla

Só havia um `PopupMenuButton` por item — restaurar ou apagar uma lixeira com 50
entradas significava 50 operações, com risco de esquecer alguma.

Long-press marca, e a barra de lote restaura ou apaga **vários de uma vez**:
selecionar tudo, inverter seleção, restaurar selecionados, excluir
definitivamente. Restaurar é feito **um a um** de propósito: o destino pode ter
sido ocupado por outro arquivo, e só aquele item falha — a SnackBar informa
quantos voltaram e quantos falharam, em vez de engolir.

Sair do modo de seleção pelo botão voltar não fecha a tela.

### "Pastas do sistema" → "Atalhos do aparelho"

O menu dizia "Pastas do sistema", que sugere **criar** pasta de sistema — que o
app não faz e não pode fazer. O que existia era uma lista de **atalhos de
navegação** (Download, DCIM, Android/data, Música...). Renomeado para "Atalhos
do aparelho" com a descrição "Ir para Download, DCIM, Música…".

### Criar e editar arquivos de texto (a lacuna real)

Falta era esse: o app só tinha "Nova pasta". Para criar um `index.html` era
preciso sair do app, abrir o Bloco de Notas do sistema e voltar — e o arquivo
só aparecia na lista depois de um "Atualizar" manual.

- **Novo arquivo de texto** no menu: escolhe a extensão (HTML, CSS, JS, JSON,
  MD, XML, TXT, LOG, CSV, YAML, INI, CONF) e o nome. O arquivo nasce com um
  **esqueleto utilizável** — um `index.html` em branco não serve para nada.
- **Editor embutido** para arquivo de texto: fonte monoespaçada, salvar pelo
  botão ou Ctrl+S, contador de linhas/caracteres, e aviso antes de sair com
  alteração não salva.
- **JSON é validado ao salvar**: com erro de sintaxe o app avisa e **não
  grava** — evita o arquivo quebrado que só falharia em outro programa.
- Tocar num `.html`/`.css`/`.json` abre o editor do Audify, em vez de chutar
  para um app de terceiros.

O editor tem **limite de 2 MB**: acima disso a tela viraria uma parede de
texto, e o usuário quase sempre quis outra coisa.

Dois detalhes que evitam desastre:
- lista **fechada** de extensões de texto — abrir um `.mp4`/`.apk`/banco no
  editor mostraria lixo e, ao salvar, **corruptiria o arquivo**;
- criar arquivo **nunca sobrescreve**: nome repetido vira "nome (1).ext".

---

## Como validar (APK de release)

```bash
flutter analyze        # 0 issues
flutter test           # 208 testes passando
flutter build apk --release
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

> Importante: instale sempre o **--release** no aparelho. O bug original só
> existia no release — validar no debug não prova nada.

---

## Checklist de teste manual (aparelho físico)

Marque cada item. Se algo falhar, abra **Configurações → Log de erros** antes de
reportar — a causa provavelmente estará lá.

### A. Segundo plano (o problema principal)
- [ ] A1. Tocar música → botão Home → esperar **10 min** com tela apagada →
      a música continua? A notificação responde a play/pause/próxima?
- [ ] A2. Com a tela bloqueada, controlar a reprodução pela **tela de bloqueio**
      (play/pause/next/prev/arrastar a barra).
- [ ] A3. Pausar a música → Home → esperar 5 min com tela apagada → voltar →
      tocar play na notificação: retoma da posição certa?
- [ ] A4. Receber uma **ligação** (ou simular) durante a reprodução: pausa sozinha
      e **retoma** após desligar?
- [ ] A5. Abrir **YouTube/outro player**, dar play: a música do Audify para e
      **não volta sozinha** (perda permanente de foco)?
- [ ] A6. Ir em **Configurações → Segundo plano** e conceder "Ignorar otimização
      de bateria" (deve aparecer ✓ verde). Refazer A1 num Xiaomi/Samsung/Moto,
      se possível.

### B. Fechamento e reabertura (o sintoma "não abre mais")
- [ ] B1. Com música tocando, **deslizar o app fora dos recentes**: deve parar de
      tocar de forma limpa (ou continuar tocando com notificação — ambos ok),
      **sem crash**.
- [ ] B2. Deslizar a **notificação** para fora durante a reprodução: música para
      de forma limpa, sem crash.
- [ ] B3. Reabrir o app imediatamente depois de B1/B2: abre normal, lista carrega,
      dá para tocar de novo.
- [ ] B4. Forçar parada (Configurações do sistema → Aplicativos → Audify → Forçar
      parada) e reabrir: abre normal.

### C. Estresse do player
- [ ] C1. Trocar de música **rapidamente 20x seguidas** (tocar outra faixa a cada
      ~1s): sem travar, sem áudio duplo/sobreposto, sem crash.
- [ ] C2. Deixar uma playlist tocar até o fim natural: avança sozinha conforme o
      modo repeat; repeat-one repete a mesma.
- [ ] C3. Arrastar a barra de progresso várias vezes seguidas durante a
      reprodução.

### D. Estabilidade geral (15–20 min alternando abas)
- [ ] D1. Alternar entre **Música, Vídeos, Galeria, Arquivos, PDFs, Playlists e
      Configurações** várias vezes,abrindo itens de cada tipo (vídeo, foto, PDF,
      pasta, APK).
- [ ] D2. Abrir um vídeo → apertar Home durante a reprodução → voltar: o vídeo
      **pausou** ao sair e não retomou sozinho.
- [ ] D3. Galeria com muitas fotos: rolar bastante (paginação), entrar num álbum e
      voltar. Sem travamentos crescentes (cache de miniaturas limitado).
- [ ] D4. Abrir o **mesmo PDF** duas vezes: segunda abertura é instantânea
      (miniatura/capa vinda do disco) e retoma da última página lida.
- [ ] D5. Criar playlist, adicionar/remover músicas, reordenar arrastando, excluir
      a playlist — sem erros e sobrevive a fechar/abrir o app.
- [ ] D6. Excluir um arquivo/música que está numa playlist → a playlist não pode
      ficar com item morto.

### E. Crash forçado (testa diretamente o "não abre mais")
- [ ] E1. Se conseguir reproduzir QUALQUER crash: reabra o app. Ele **deve abrir
      normalmente** (boot blindado) e o erro deve aparecer em
      **Configurações → Log de erros**.
- [ ] E2. Verificar que o log de erros tem botão "Limpar" funcionando e que o
      arquivo fica pequeno (teto de 128 KB).

### F. Privacidade
- [ ] F1. Confirmar em Configurações do Android → Dados móveis/Wi-Fi que o Audify
      não usa rede (modo avião: todas as funções continuam funcionando).

### G. Exclusão de mídia (a correção da seção 6)
> Faça em **Android 13+**, **Android 11/12** e **Android 10** — o caminho nativo
> é diferente em cada um e o bug antigo só se manifestava em parte deles.
> Tenha um MP3, um vídeo, uma foto, um PDF e um arquivo qualquer
> (ex.: .zip em Downloads) prontos no aparelho.

- [ ] G1. **Uma música**: toque longo → "Excluir do aparelho" → confirmar.
      Deve aparecer o diálogo do sistema; ao confirmar, o arquivo some do
      aparelho **e** da lista, e a SnackBar diz "Arquivo excluído."
- [ ] G2. **Um vídeo**: mesmo fluxo na aba Vídeos. Depois **reabra o app** e
      confirme que o vídeo **não voltou** para a lista.
- [ ] G3. **Uma foto** (aba Galeria) e **um PDF** (aba PDFs): devem continuar
      funcionando como antes (sem regressão).
- [ ] G4. **Cancelar no diálogo do sistema**: a lista, a fila e o player devem
      ficar **exatamente como estavam** — nada sumir da tela.
- [ ] G5. **Faixa embutida no app**: toque longo em uma faixa de
      `assets/songs/` → a opção de excluir aparece **desabilitada** com o texto
      "Faixa embutida no app, não pode ser excluída."
- [ ] G6. **Música tocando + excluí-la**: o áudio deve **parar e pular** para a
      próxima faixa; fechar e reabrir o app **não pode** retomar a música
      excluída ("continuar de onde parou").
- [ ] G7. **Playlist**: ponha a música/vídeo numa playlist, exclua o arquivo e
      abra a playlist — o item **não pode** continuar lá (item morto).
- [ ] G8. **"Outros arquivos"**: um .zip em Downloads, via aba Arquivos
      (lixeira do app) — deve funcionar; e um PDF em Documents pela aba PDFs.
- [ ] G9. **Arquivo protegido** (ex.: em `Android/data` de outro app): a
      SnackBar deve explicar o motivo da falha em vez de mentir "excluído".
