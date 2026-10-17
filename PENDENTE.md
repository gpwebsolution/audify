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
