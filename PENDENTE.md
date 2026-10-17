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
