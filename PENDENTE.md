# PENDENTE — Melhorias Audify

Itens que não couberam na implementação (ou dependem de decisão do dono).
Cada linha: ID do item, o que falta e o motivo.

---

## 3.4 — Gapless e crossfade

- **Crossfade é rampa de volume, sem sobreposição de áudio.** O fade-out
  da faixa atual + fade-in da próxima funcionam porque o gapless troca a
  faixa dentro do MESMO player; com um único player não é possível tocar
  as duas faixas ao mesmo tempo (blend de verdade exigiria 2 players
  alternados — escopo novo e bem maior). Efeito auditivo: a troca tem um
  "vácuo" curto no ponto de transição, não um blend. [Decisão do dono:
  se quiser sobreposição real, é um item novo]
- **Não validado em aparelho.** Gapless (ouvir troca de faixa sem
  intervalo) e crossfade (rampa perceptível nas pontas) foram cobertos
  só por testes de unidade/serviço (fila carregada, seek sem recarga,
  transição por evento, fatores de volume). Checklist manual no relatório
  final.

---

## 3.6 — Letras (offline)

- **ID3 parcial: só v2.3 e v2.4.** V2.2 (frames de 3 letras) não é
  lido; tags com unsync, extended header/footer ignorados (frame
  "unsincronizado" é picotado e não é recuperado); frame SYLT (letra
  sincronizada de fato) não é interpretado — só USLT. Format flags do
  frame ≠ 0 fazem o frame ser pulado.
- **Tag grande não alcançada:** a leitura embutida varre no máximo
  256KB do arquivo (o USLT costuma estar no começo, mas uma playlist
  gigante antes dele não é coberta).
- **USLT com descritor sem byte terminador é descartado** (retorna
  null em vez de arriscar texto torto).
- **`.lrc` só via arquivo ao lado do MP3 ou asset empacotado** — o app
  não busca letras na rede (offline por regra) e nenhum `.lrc` de
  demonstração foi adicionado aos assets (só existem os dois MP3).
- **Sem highlight em texto corrido:** letra embutida que não tem
  marcações LRC vira "texto corrido" (lista inteira, sem linha corrente
  destacada) — é o esperado, mas não há transformação automática.
- **Offset `[offset]`** segue a convenção da Wikipédia (+ adianta a
  letra); players que interpretam ao contrário terão letra 2×off.
- **Não validado em aparelho:** folha com letra real, rolagem automática
  e legibilidade em telas pequenas — checklist no relatório final.

---

## 3.7 — Mini player e PlayerScreen

- ~~**Botão de favorito (coração) NÃO entrou na tela.**~~ **Resolvido no
  4.1:** `_quickActions` ganhou o coração (e o menu de ações da faixa,
  também).
- **Cor derivada da capa só para faixa de aparelho.** Faixas asset (os
  dois MP3 do bundle) não têm MediaStore/capa → o player usa o tema da
  casa; se a extração de cor falhar, também (log 'player/capaColors'),
  nunca derrubando a tela.
- **Não validado em aparelho:** rotação real retrato↔paisagem, capa
  com cor dominante de álbum de verdade e legibilidade da coluna
  direita em telas baixas — checklist no relatório final.

---

## 4.1 — Favoritos de música

- **`song_id` órfão após reindex do MediaStore.** A tabela guarda
  `file_path` como reserva (o id do MediaStore muda quando o sistema
  reindexa), mas NÃO existe rotina de reconciliação: um favorito com id
  antigo some da busca e fica invisível (a linha não é reaproveitada).
  Seria um passo futuro: achar por `file_path` e regravar o id novo.
- **Coração oculto no modo de seleção em lote.** Na seleção multipla o
  trailing vira checkbox + ações do lote; favoritar uma a uma ali não
  faz sentido com o lote aberto (deliberado, não uma lacuna técnica).
- **"Favoritas" é automática, sem CRUD.** Não renomeia, não exclui,
  não reordena — é a entrada fixa da aba Playlists que abre o
  FavoritesDetailScreen (é o que a spec pede).
- **Ordem fixa por título (NOCASE).** Sem critério escolhível — a
  ordenação por data/duração/ano é o item 4.3.
- **Migração 3 → 4 coberta só por sqflite_common_ffi em desktop.**
  Teste cria um banco v3 na mão e reabre; não foi verificada a
  migração com dados reais de aparelho.
- **Não validado em aparelho:** coração persistindo entre reinícios,
  contagem no tile da lista, entrada "Favoritas" e play-all do detalhe
  — checklist no relatório final.

---

## 4.2 — Histórico e mais tocadas

- **Contagem por posição, não por tempo de ouvida.** A regra olha a
  posição nos ticks em que o player está TOCANDO (30 s ou 50%); um
  seek adiantado durante a reprodução passa do limiar e conta, mesmo
  que ninguém ouvisse os 30 s. O "não a cada seek/retorno" está coberto
  pelo flag por execução — mas segundos tocados de fato não são medidos.
- **Repetição em loop da mesma faixa conta uma vez.** O reset do flag
  depende da faixa corrente MUDAR; repeat-one que volta ao início sem
  trocar de id (mesma execução contínua na tela) não reconta. Trocar de
  faixa e voltar conta de novo (testado).
- **Retomada de sessão acima do limiar conta.** O flag vive em memória:
  abrir o app e retomar uma faixa em 45 s registra o play (o anterior
  já pode ter sido contado na sessão anterior).
- **song_stats guarda só `song_id`** (sem `file_path`, ao contrário dos
  favoritos): mídia reindexada vira linha órfã — os detalhes mostram
  só o que casa com o catálogo atual, mas as stats velhas continuam na
  tabela e na contagem dos tiles.
- **Listas completas, sem limite** de "N mais tocadas"/"N recentes".
- **Migração 4 → 5 coberta só por sqflite_common_ffi em desktop.**
- **Não validado em aparelho:** contagem durante ouvida real, tiles na
  aba Playlists, play-all e "Limpar histórico" — checklist no relatório
  final.

---

## 4.3 — Ordenação escolhível

- **Ano (`year`) não exposto pela versão usada do plugin.** O
  on_audio_query 2.9.0 (e o side Android dele) não tem `year` — só
  `dateAdded` (epoch s) e `track` (número da faixa), que entraram na
  [CONFIRMAR resolvido]: ordenar por ANO DE LANÇAMENTO fica sem
  fonte de dados; a data usada é a de ADIÇÃO à biblioteca.
- **"Mais tocadas" não reordena ao vivo.** Os pesos são lidos
  (`HistoryProvider.stats`) só quando algo reaplica o filtro (mudar
  busca/ordenar); plays da sessão corrente entram na próxima dessas
  mudanças, não no próximo notify do tick.
- **Vale só para a aba Música** (lista visível e grupos). Favoritas,
  detalhe de playlist, histórico e "Recentes" seguem as ordens próprias
  deles; a fila de reprodução ativa nunca acompanha a troca.
- **Nulos sempre por último** em ambos os sentidos (data/duração/track
  ausentes), e o desempate por título é INVERTIDO junto com o sentido —
  decisão explícita, coberta por teste.
- **Faixa (`track`) ausente em muito conteúdo** (streams/m4a): dentro
  do álbum essas faixas caem no fim, em ordem natural de título.
- **Migração 5 → 6 coberta só por sqflite_common_ffi em desktop.** As
  suítes novas deste item (`song_sort_test`, `music_sort_test`) usam
  diretório de banco temporário exclusivo para não correr com as
  demais suítes em paralelo (a corrida no `audify.db` compartilhado do
  cwd é pré-existente entre os testes de banco antigos).
- **Não validado em aparelho:** menu "Ordenar" (abrir/itens/tap),
  persistência entre reinícios, agrupamento por álbum com faixas reais
  (track do MediaStore) — checklist no relatório final.

---

## 4.4 — Criar playlist sem sair do fluxo

- **Vídeo em reprodução: um toque virou dois.** O item "Adicionar à
  playlist" do video_player ANTES ia direto para a PRIMEIRA playlist
  (ou ficava desabilitado quando não havia nenhuma); agora abre o
  seletor como nas demais telas — é o comportamento pedido pelo item,
  mas muda o atalho de quem já tinha playlist.
- **Seletor único lista todas as playlists**, inclusive mistas ou de
  outro tipo (comportamento do código antigo mantido): quem adiciona
  música vê playlists só de vídeo e vice-versa; o subtítulo mostra a
  contagem do tipo pedido ('N faixas' / 'N vídeos').
- **Nome da playlist só passa por trim** (igual ao FAB da aba
  Playlists): vazio cancela, duplicado mostra o aviso vermelho — sem
  outra validação (emoji/espaços internos passam, como no FAB).
- **Não validado em aparelho:** criação em cada uma das 5 telas
  (player, música single, música em lote, vídeo, vídeos em lote) —
  checklist no relatório final.

---

## 4.5 — Exportar e importar playlists

- **Import usa o catálogo EM MEMÓRIA** do PlayerProvider (a lista que a
  tela já carregou): faixa que existe no aparelho mas ainda não entrou
  na varredura não casa — o relatório conta como "não encontrada" até
  um re-scan colocá-la no catálogo.
- **.m3u8 é o formato pobre**: só título/artista/caminho/duração em
  segundos (álbum sai fora) e faixa SEM caminho nenhum é pulada no
  export — o JSON, com todos os cinco campos do item, é o formato
  completo. No casamento do m3u8, artista que contiver " - " perde a
  parte depois do primeiro separador (convenção "Artista - Título").
- **Caminho de asset exporta como `assets/songs/...`**: em outro
  aparelho esse path não existe e o casamento cai no título+artista
  normalizados (testado), mas playlists 100% de assets importadas fora
  do aparelho original casam só quando os nomes baterem.
- **Duplicar preserva o snapshot fiel, inclusive fantasmas** (faixas
  cujo arquivo sumiu do aparelho); duplica faixas E vídeos. Não há
  duplicação a partir da lista de Playlists — só pelo menu do detalhe.
- **Export/import/duplicar não têm teste de widget**: a lógica de
  ida-e-volta, casamento, relatório e duplicação tem 13 testes puros,
  mas os canais nativos (file_picker, share sheet) ficam de fora —
  ficam no checklist "não validado em aparelho" do relatório final.

---

## 4.6 — Editar tags/capa (OPCIONAL) — PROPSTIVA E DECISÃO

**Não codado: custo alto, conforme a própria spec autoriza.**

### Proposta curta (antes de codar, como pedido)

- **Biblioteca candidata:** `phonic` (pure Dart, ID3v2 + capa/APIC,
  formato unificado MP3/FLAC/OGG/MP4 — cobre o que o MediaStore traz;
  alternativa mais enxuta e só-MP3: `id3_codec`; evitado
  `haudiotagger` por puxar binário Rust por plataforma e
  `audiotagger`/`flutter_audio_tagger` por gravação nativa por path,
  negada no Android 11+). Dependência NOVA — a regra-padrão do
  prompt é "sem dependências novas"; só este item a permitiria.
- **Tamanho estimado:** ~700–1000 linhas no total — serviço Dart de
  edição com backup/escrita (~200–300), MÉTODO/SERVICE NATIVO NOVO
  (canal próprio, ex.: `audify/media_edit`, com
  `MediaStore.createWriteRequest` na API 29+ e fallback com
  `WRITE_EXTERNAL_STORAGE` na API 24–28, ~100–150 linhas Kotlin),
  folha de edição de campos + capa por file_picker (~250–350) e
  testes (~150–250). Os 5 MethodChannels existentes não mudam, mas
  nasce um sexto.
- **Fluxo inevitável:** diálogo de escrita do SO (análogo ao
  `createDeleteRequest` da exclusão) → ContentResolver abre o URI →
  lê os bytes inteiros → tag aplicada em Dart → reescreve o URI.
- **Riscos:** (1) reescrita integral do arquivo — falha no meio
  corrompe ou mata a música (mitigação: gravar tmp e só depois
  substituir, mesmo assim sem atomicidade real via ContentResolver);
  (2) reindexação do MediaStore muda o id/caminho → faixas viram
  FANTASMAS nas playlists/favoritos (que casam por song_id/file_path);
  (3) ID3v2.4 com capa não abre em players antigos; (4) capa grande
  em memória em aparelho fraco; (5) três caminhos de permissão por
  faixa de API; (6) formatos além de .mp3 (m4a/flac) exigem a
  biblioteca cobrindo todos ou regra por extensão.
- **Veredito:** opcional pelo prompt + dependência nova + canal novo
  + risco de perder a mídia do usuário ⇒ **custo alto, não implementar
  agora.** Se a fase visual/idiomas fechar sem pendência melhor,
  retomar com a bancada de testes de arquivo (mp3 de exemplo +
  roundtrip de capa) antes de qualquer UI.

---

## 5.1 — Internacionalização de verdade

- **Escopo migrado: só 3 telas** (Música, Player, Configurações).
  O resto do app — widgets compartilhados (`song_list_tile`,
  `media_actions`, `selection_bar`, diálogos de confirmação), outras
  telas (detalhe de playlist, buscas, histórico, favoritos,
  equalizador, sobre, permissões) e sheets de contexto — continua com
  strings PT hardcoded. A infraestrutura já está pronta: para migrar
  mais tela é só mover a chave para os `.arb` e trocar por
  `l10nOf(context).chave`.
- **Provider/serviço mandam códigos, UI traduz** (regra da spec), mas
  só foi aplicado nas 3 telas: mensagens que nascem fora delas
  (erros de permissão vindos do `PermissionService`, contagens do
  `PlayerProvider`, mensagens do `AudioService`) continuam nascendo em
  PT no código-fonte e só chegam traduzidas onde a tela da vez as
  exibe.
- **Fallback do `l10nOf` é `AppLocalizationsPt`**: contexto sem
  delegate montado (harness de teste, builder solto) cai em PT por
  conveniência — é o que mantém os 491 testes legados verdes sem
  mexer em nenhum harness.
- **"Sistema" é resolução, não tradução completa**: o
  `localeListResolutionCallback` manda `en*` para inglês e QUALQUER
  outro locale (fr, zh, ar, de…) para pt-BR — não há 3ª tradução, o
  pt-BR é o fallback único. `resolveAppLocale` está exportada de
  `lib/main.dart` e é testada unitariamente.
- **No teste de widget, "Sistema" é coberto sem depender do
  ambiente**: o binding de teste (`flutter test`) não propaga
  `platformDispatcher.localeTestValue` para o `Localizations` do
  harness — por isso o teste asserção a alternância real com escolhas
  EXPLÍCITAS (Português ⇄ English, com a tela inteira reconstruindo) e
  trata "Sistema" com um expect flexível (pt ou en), deixando a
  regra de fallback pt-BR para o teste unitário de
  `resolveAppLocale`.
- **`lib/l10n/app_localizations*.dart` são versionados** (não estão no
  `.gitignore`): `git clone && flutter test` passa sem etapa extra.
  Ao editar os `.arb`, rodar `flutter gen-l10n` (ou qualquer comando
  Flutter, que dispara o gen) antes do commit.
- **Rótulos do provider fora da UI viraram valor bruto**:
  `crossfadeLabel`, `trashRetentionLabel` e `libraryMinDurationLabel`
  foram REMOVIDOS do `SettingsProvider` — a tela formata via l10n
  (`_crossfadeLabel` etc.); dois testes que asseguravam o label passam
  a assegurar o valor. Se outro teste que usar esses getters aparecer,
  o analyzer acusa (campo inexistente).
- **`SongSortKey.label` foi removido** do enum: os rótulos vivem em
  `_sortKeyLabel(l10n, key)` na tela de Configurações/Música.
- **Fora de escopo de propósito:** presets do equalizador
  (identidade persistida pelo usuário — traduzir quebraria presets
  salvos), path técnico
  `'/storage/.../WhatsApp/Audio'` e o nome próprio `Audify`
  (localização de nome próprio não é string de UI), e os nomes
  "Português"/"English" do seletor (nome de idioma não se traduz).

---

## 5.2 — Configurações organizadas e completas

- **Preferências NOVAS (3) com teste do provider cada**: tema AMOLED
  (`theme_amoled`), timer de sono padrão (`sleep_default_minutes`,
  opções 0/15/30/45/60, padrão desligado) e parar o serviço após N
  minutos pausado (`stop_service_paused_minutes`, opções 0/5/15/30/60,
  **padrão 30 min** — fora da lista volta para 30). Velocidade padrão e
  ordenação padrão NÃO são chaves novas: são as preferências da 3.2 e
  da 4.3, agora EXPOSTAS em Configurações.
- **O padrão de 30 min do "parar após pausa" muda o comportamento
  anterior** (o serviço vivia indefinidamente pausado). Quem quiser o
  antigo escolhe "Desligado". A parada usa o `stop()` normal do
  serviço (cursor volta ao início; fila não é salva no ponto) — e a
  preferência é lida AO VIVO (trocar para 0 cancela o prazo na
  checagem seguinte, coberto por teste).
- **O agendamento depende do stream de estado do just_audio**: um
  `pause()` normal (tela, notificação, fone) passa por ele e agenda;
  um estado pausado setado sem evento do player não agenda (nunca
  agenda errado às custas de uma parada indevida). Só é validado em
  teste unitário (relógio injetado), não em aparelho.
- **AMOLED escurece só os fundos "large"** (scaffold, app bar, folhas,
  menus, diálogos): as superfícies da paleta M3 (cards/tiles) seguem o
  dark normal, de propósito, para o contraste do texto não mudar.
  Contraste fino do tema AMOLED é do item 5.3.
- **Velocidade em Configurações lê a preferência persistida** (o
  PlayerProvider grava a cada troca) — não há watch do player na aba;
  a leitura acompanha porque persistir notifica o provider. O SHEET de
  velocidade é o único lugar da tela que usa o PlayerProvider (só em
  `onTap`).
- **Timer sono padrão é um ATALHO**: aparece no topo do menu do sono e
  pré-preenche o campo do "personalizado" — nunca dispara sozinho.
- **Ordenação padrão reusa a persistência da 4.3** (chave
  `library_sort_key`/`..._ascending`, sem chave nova) e a folha NÃO
  fecha ao escolher, para combinar critério + sentido antes de sair.
- **Testes novos**: 5 do serviço (`test/paused_stop_test.dart`:
  dispara no prazo, cancela na retomada, desativar no meio, no-op com
  0, guarda fora da pausa — com drenagem do replay do just_audio no
  `setUp`, senão o listener sobrescreve o status manual), 4 do
  provider (padrões, persistência/restauração, escrita fora da lista,
  storage corrompido) e 3 do tema (`test/amoled_theme_test.dart`).
  Sheets/toast da nova UI NÃO têm teste de widget (só a aba em
  Configurações via teste do 5.1).

---

## 5.3 — Acessibilidade e estados vazios

- **Semantics entregue onde o framework não dá de graça**: o Slider do
  do player ganhou `Semantics(label: …)` (sozinho ele só anuncia o
  valor numérico); tiles de música herdam a semântica nativa do
  ListTile (título+subtítulo leem como botão) e todos os 66
  IconButtons do app têm `tooltip` (só o de fechar seleção do APK
  era novo — os outros 65 já tinham). **Não há teste automatizado de
  leitor de tela** (TalkBack real só em aparelho).
- **Alvos ≥ 48 dp**: `materialTapTargetSize: shrinkWrap` foi removido
  dos Checkboxes de seleção (música, lixeira, PDFs, Arquivos ×2) —
  voltaram ao padrão Material de 48; IconButtons já são 48 por padrão.
  **InkWell/GestureDetector com hit próprio** (grids, tiles
  customizados) não foram auditados sistematicamente nem cobertos por
  teste de hit-test.
- **Estados vazios com ação clara**: música (3 estados — permissão →
  "Permitir"/"Abrir ajustes", catálogo vazio → "Atualizar", busca sem
  resultado → "Limpar busca") e Playlists vazio → botão "Nova
  playlist" com o MESMO diálogo do FAB (`askPlaylistName` virou
  pública). **Fora do escopo**: fila vazia (só texto — sem ação
  natural), e os empty states próprios de vídeos/fotos/PDFs/Arquivos/
  Lixeira/Histórico/Favoritas/detalhes de playlist. A aba Playlists
  continua com vários textos hardcoded PT fora do estado vazio
  (descrição de contagem, confirmação de exclusão, tiles de Favoritas/
  Histórico) — migração 5.1 restante.
- **disableAnimations**: `Motion.scale(context, d)` zera a duração
  quando o sistema pede animações reduzidas; aplicado na barra de
  seleção (AnimatedSize+Switcher — vale para música/vídeos/fotos/
  PDFs/Lixeira), grid zoom, rotação do cabeçalho de grupo, destaques
  de seleção de vídeos/fotos e OSD do player de vídeo. **Não cobre**:
  transições de página custom (o `pageTransitionsTheme` do tema não
  recebe context), timers de linger (OSD/controles de vídeo),
  `AnimatedContentSwitcher` do player de vídeo e as animações
  internas do Navigator (sheets/diálogos).
- **Contraste AMOLED**: teste WCAG 2.1 ≥ 4.5:1 para os pares
  principais (onSurface/onSurfaceVariant/primary sobre o preto puro;
  onPrimary×primary; onErrorContainer×errorContainer;
  onPrimaryContainer×primaryContainer) — todos passam com a paleta M3
  dark. **O banner de permissão usa `errorContainer` com alpha 0.5**
  (mistura com o fundo) e esse par misturado NÃO é coberto pelo
  teste.
- **textScaler**: o app nunca desliga a escala (não existe
  `TextScaler.noScaling` no código); o teste novo monta Música, Player
  e Configurações com **2.0x** (override pelo `builder` do
  MaterialApp) e não há overflow. **Não testados a 2.0x**: as outras
  telas, e sheets/dialogs abertos a partir das principais (o conteúdo
  deles não é renderizado no pump inicial).

---

## 6.1 — Dividir MainActivity.kt

- **Divisão por canal, um arquivo por handler**: `MainActivity.kt` foi de
  1.734 para **28 linhas** — só `configureFlutterEngine` registrando os
  handlers e `onActivityResult` repassando para `MediaDeleteHandler`.
  Novos arquivos: `VideoQueryHandler` (172), `GalleryQueryHandler` (213),
  `PdfQueryHandler` (159), `MediaDeleteHandler` (1.005),
  `FileQueryHandler` (293). Nomes de canal, métodos e payloads
  **idênticos** — nenhum arquivo `.dart` foi tocado.
- **Estado pendente da exclusão** continua em `companion object`
  (escopo de processo) — agora no companion de `MediaDeleteHandler`,
  junto do doc que explica por que sobrevive à rotação da Activity;
  `MainActivity` só chama `super.onActivityResult` e delega.
- **Referências implícitas à Activity** reparadas nos handlers
  (`contentResolver`, `runOnUiThread`, `startIntentSenderForResult`,
  `Toast`, `startActivity`, `packageManager`, `this@MainActivity` →
  `activity.…`).
- **Aceite cumprido**: `media_delete_channel_test.dart` e
  `media_delete_service_test.dart` passaram **sem nenhuma alteração**;
  `flutter build apk --debug` compila; suíte completa 512/512 e
  `flutter analyze` limpo. Nenhum teste novo foi adicionado neste item
  (a proteção é a suíte Dart intacta + build).
- **Por que `MediaDeleteHandler` continua com ~1.000 linhas**: o bloco
  de exclusão é coeso (companion + ciclo reservar→dialogo→finishDelete);
  partir mais exigiria dividir o estado compartilhado entre arquivos,
  ganhando acoplamento sem ganho de clareza — decisão deliberada.
- **Não reescrevemos o histórico**: `CHANGELOG.md §6` (ex-`CORRECOES.md`) ainda cita
  `MainActivity.deleteWithSystemDialog` — é documentação do que foi
  feito na época; o método hoje vive em `MediaDeleteHandler`.

---

## 6.2 — Dividir arquivos Dart gigantes

- **Serviços extraídos de `file_query_service.dart` (1.669 → 979 linhas)**:
  `file_ops_jobs.dart` (114 — jobs puros de dart:io: copiar/mover/renomear/
  apagar/permanente/criar pasta), `trash_service.dart` (304 — lixeira com
  manifesto JSONL + `moveToTrash` + `TrashEntry` + restore em isolate) e
  `storage_analysis_service.dart` (370 — uso por categoria, maiores
  arquivos, duplicados SHA-256 e seus jobs). A **API pública não mudou**:
  `FileQueryService` continua expondo `listTrash`/`restoreFromTrash`/
  `deleteForever`/`purgeExpired`/`trashSize`/`emptyTrash` e os métodos de
  análise por **delegação**, e re-exporta `TrashEntry`/`StorageUsage`/
  `DuplicateGroup` (`export … show`) — nenhum consumidor ou teste precisou
  de import novo. `delete(useTrash: true)` agora chama
  `TrashService.moveToTrash` (mesmo código, antes inline no serviço);
  `useTrash: false` segue com `deletePermanentJob` no try/catch com a mesma
  mensagem de log. `_isExcluded`/`_jobExt` viraram `isExcludedPath`/`jobExt`
  (top-level públicos, porque a análise de storage importa o núcleo).
- **Ciclo de import aceito (Dart)**: `file_query_service` ⇄ `trash_service`
  (o `formatBytes` continua no núcleo e a lixeira o usa) e
  `file_query_service` ⇄ `storage_analysis_service` (modelo `StorageVolume`
  e jobs compartilhados). Ciclos são legais em Dart; a alternativa seria
  um quarto arquivo utilitário — decisão consciente para não criar mais um
  ponto de fragmentação.
- **Telas divididas (widgets públicos novos em `lib/widgets/`)**:
  `file_tiles.dart` (FileListTile/FileGridTile/FileThumbnail),
  `destination_picker.dart`, `file_screen_states.dart`
  (AllFilesAccessState/EmptyState), `new_file_dialog.dart`,
  `video_controls.dart` (VideoVolumeOsd/VideoControlsBar/VideoErrorState),
  `group_header.dart` (GroupRow/GroupHeader) e `permission_banner.dart`.
  Tamanhos: `files_screen` 1.486 → **992**, `video_player_screen` 906 →
  **619**, `music_screen` 1.010 → **895**. Todos ganharam `super.key`
  (lint `use_key_in_widget_constructors`); as telas só trocaram os nomes
  nos pontos de uso e os imports — nenhum outro arquivo de tela mudou.
- **Caracterização prévia (antes de extrair)**: diálogo "novo arquivo de
  texto" (teste novo no `files_screen_test` — casca, extensões do
  dropdown e validação de nome com "/"); `GroupHeader` já era coberto por
  `grouped_library_test` (tooltip "Recolher", colapsar/expandir), e
  `EmptyState` + `VideoErrorState` já apareciam nos testes de casca do
  host (5.3 / estado de erro do player).
- **Testes diretos escritos na extração** (widgets **inalcançáveis via
  tela em host** — honestidade: a spec pedia cobertura *antes*, mas sem
  Android/decoder estes widgets não montam na árvore de teste prévia):
  FileListTile/FileGridTile (nome, seleção, toque/long-press), FileThumbnail
  (diretório, genérico e vídeo→fallback pelo canal ausente),
  DestinationPicker (subpasta listada via `runAsync`+compute e fecho em
  "Selecionar esta pasta"), AllFilesAccessState (ação do botão),
  VideoControlsBar (tempos `formatDuration`, transporte, menu de
  velocidade → 1.5x, mudo, seek start/update/end), VideoVolumeOsd
  (opacidade 0 sem mensagem / "70%" visível) e PermissionBanner (dois
  ramos de texto/botão com `permission` forçado por override — em host a
  permissão volta concedida e o banner nunca aparece na tela).
- **Suíte 538/538 e `flutter analyze` limpo** (512 + 26 testes: +7 do
  grupo lixeira no `file_query_service_test` com fake de path_provider,
  12 no `files_screen_test`, 2 no `video_player_screen_test`, 3 no
  `video_controls_test`, 2 no `permission_banner_test`). `flutter build
  apk --debug` **não foi refeito neste item** (nenhum código Kotlin/manifest
  mudou — a proteção é a suíte Dart, que cobre os serviços extraídos).
- **Limitações conhecidas**: (1) o ramo de imagem do `FileThumbnail`
  (`Image.file`) não tem teste — o decode/I/O real foge do FakeAsync;
  (2) as ações do PermissionBanner (`openSettings`/
  `requestPermissionAndReload`) só são verificadas por renderização, não
  por tap — o plugin de permissão não responde em host; (3) o diálogo de
  `DestinationPicker` usa `pump` datado porque o `CircularProgressIndicator`
  faria `pumpAndSettle` estourar o timeout; (4) caminho de APK
  (`Platform.isAndroid`) segue sem cobertura host, como antes.

---

## 6.3 — CI (GitHub Actions)

- **`.github/workflows/ci.yml`**: em **todo push e pull_request** roda
  `flutter pub get` → `flutter analyze` → `flutter test` →
  `flutter build apk --debug`, publicando
  `build/app/outputs/flutter-apk/app-debug.apk` como artefato
  (`audify-debug-apk`, `if-no-files-found: error`).
- **Versões fixas, sem "stable" flutuante**: Flutter **3.47.2** (a mesma
  do desenvolvimento; satisfaz o README — 3.44+ / Dart 3.12+) via
  `subosito/flutter-action@v2` com cache; **JDK 17 (temurin)** porque o
  projeto usa **AGP 9.0.1 + Gradle 9.1**, cujo mínimo documentado é 17
  (Build Tools 36 exigido pelo AGP vem do SDK do runner/loja).
- **Sem segredos, sem assinatura de release**: só `build apk --debug`
  (assinatura debug automática); nenhum keystore, token ou variável de
  ambiente é lido pelo workflow.
- **Verificado localmente, não no GitHub**: o YAML foi validado por parser
  e os mesmos 4 comandos rodam verdes aqui (`analyze` limpo, `test`
  538/538, `build apk --debug` → `✓ Built …/app-debug.apk`). O workflow
  em si **não foi executado num runner real** — regra do prompt de não
  dar push; a primeira execução de fato acontece quando o dono der push.
  Se o runner não trouxer o Build Tools 36/SDK esperados, o passo de
  build é o candidato natural a ajuste (analyze/test não dependem do SDK).

---

## 6.4 — Documentação e versão

- **README**: a tabela de funcionalidades foi de 6 para **7 abas**
  (entrou **Arquivos**) com descrições atualizadas (módulo agrupado,
  favoritas/histórico/melhores, idioma, equalizador, log de erros), e duas
  seções novas: **Telas dentro de Arquivos** (Lixeira com expurgo,
  Duplicados por SHA-256, Analisador de armazenamento, Gerenciador de
  APKs) e **Ferramentas** (editor de texto, equalizador — EXIF descrito
  na Galeria). Corrigida também a mentira de **`audioplayers` →
  `just_audio`** (troca real do item 3.0) e a árvore de código (`# 7
  abas`, serviço `file_query_service`). Seção de testes atualizada
  ("mais de 500") com o passo de CI local equivalente ao workflow do 6.3.
- **`pubspec.yaml`**: `description` nova cobrindo o app real (mídia
  local + gerenciador/lixeira/editor/equalizador) no lugar da antiga que
  falava só em MP3 nos assets; **versão `1.0.0+1` → `1.1.0+2`** —
  `versionCode`/`versionName` do Android vêm de `flutter.versionCode`/
  `flutter.versionName`, então nada foi hardcodado em gradle.
- **`CORRECOES.md` → `CHANGELOG.md`** (rename via `git mv`): o conteúdo
  histórico foi **preservado sem reescrita** (mesma resolução do item 6.1
  — o documento registra o que foi feito na época); só ganhou um
  preâmbulo curto explicando o rename e o formato para novas entradas.
  A única referência no repositório (PENDENTE §6.1) aponta agora para o
  nome novo.
- **Verificado**: `flutter analyze` limpo e suíte **538/538** após as
  mudanças; nenhum teste depende da versão/packageInfo (o app lê
  `PackageInfo.fromPlatform()` só para exibir em Configurações).
