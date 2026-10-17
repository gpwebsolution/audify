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
