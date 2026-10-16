# Relatório 3.0 — Motor de áudio: manter audioplayers ou trocar por just_audio

**Contexto.** O app usa `audioplayers: ^6.8.1` isolado em
`lib/services/audio_service.dart`. Cada troca de faixa faz
`stop() → setSource() → resume()` (audio_service.dart:441-448), gerando
intervalo entre faixas (sem gapless). Não há equalizador nem crossfade
nativo. Velocidade existe (`setPlaybackRate`) e o item 3.2 vai usá-la.

## Comparação

| Critério | audioplayers 6.8.1 (hoje) | just_audio 0.10.6 (jun/2026) |
| --- | --- | --- |
| Gapless | Não (stop→setSource→resume) | **Sim** no Android/iOS (ExoPlayer) |
| Equalizador/graves | Não | **Sim** (`AndroidEqualizer` + `AndroidLoudnessEnhancer`) |
| Velocidade | Sim (`setPlaybackRate`) | Sim (`setSpeed`) |
| Crossfade | Não nativo | Não nativo (maintainer, issue #815) — implementação própria nos dois |
| Integração audio_service | Funciona | **Padrão documentado** (BaseAudioHandler + AudioPlayer) |
| Manutenção | Ativa | Ativa; 0.10.6 migrou para media3 ExoPlayer 1.4.1 e AGP 9 |

## Análise

- **minSdk 24:** compatível. media3/ExoPlayer 1.4.1 declara minSdk 19;
  áudio simples suportado oficialmente a partir da API 23; exige
  compileSdk 34 (Flutter já compila com 35+). App em 24 > 23 sem margem
  de dúvida.
- **Tamanho do APK:** baseline medido — **release 80.692.756 B** (build de
  08/10): 73 MB são as 4 ABIs de `libapp.so`/`libflutter.so`, dex 4,5 MB,
  assets 2,6 MB. O dex **já continha ExoPlayer** (o audioplayers 6.8.1 usa
  ExoPlayer + SoundPool). **Após a troca (medido): 81.397.836 B —
  +705.080 B (+0,87%)**, dentro da estimativa de ±2 MB; `xyz.luan` sumiu
  do dex e `com.ryanheise.just_audio` entrou.
- **Risco em aparelhos fracos:** baixo. Não entra stack de decodificação
  nova — é a mesma linhagem ExoPlayer já embarcada. O risco real é
  regressão de comportamento (interrupções/ligações, pausar ao desconectar
  fones, notificação/tela de bloqueio, modo degradado), hoje cobertos pela
  suíte e exigindo validação em aparelho (não feita ainda).
- **Esforço:** contido. Só `audio_service.dart` importa o plugin (verificado
  — as outras 2 menções no código são comentários); a classe já estende
  `BaseAudioHandler`, exatamente o padrão recomendado pelo audio_service
  com just_audio. A interface pública (`playSong`, `play/pause/resume/stop`,
  `seek`, `skipTo*`, `publishQueue`, `syncModes`, notifiers) fica idêntica
  → UI, providers e testes de fila não mudam. Ajustes nos testes: trocar o
  mock de canais do audioplayers pelo do just_audio (3-4 arquivos);
  `PlayableAudioService` mantém os overrides.
- **Custo do crossfade (3.4):** caro em qualquer caminho (não há crossfade
  nativo em nenhum dos dois; exige sobreposição de 2 players ou rampa de
  volume). Gapless, por outro lado, é **grátis** só com just_audio.

## Decisão: APROVADO (custo aceitável)

Seguir 3.1–3.4 **com just_audio**: 3.3 (equalizador) e 3.4 (gapless)
só existem nesse caminho; a troca é contida em um arquivo + mocks de
teste; o risco é gerenciável e o impacto de tamanho é marginal frente a
80,7 MB. 3.1 (timer de sono) e 3.2 (velocidade) serão feitos já sobre o
novo motor, mantendo a interface pública do `AudioService` estável.

**Ressalvas honestas:** o delta de APK foi medido em build release
(+0,87% — ver acima), mas nada foi validado em aparelho — interrupções,
notificação e background precisam de teste manual antes de encerrar a
Fase 3.
