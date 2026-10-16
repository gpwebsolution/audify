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
