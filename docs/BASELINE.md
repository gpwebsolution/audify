# Baseline do Audify — Fase 0

Medições feitas **antes** das correções P0 (estado do commit `69d1e6a`) e
**depois** delas, no mesmo ambiente. Serve para provar o ponto de partida e
separar o que foi verificado do que continua pendente. Números sem execução
real (aparelho) estão marcados como **não verificado**.

Data da medição: 31/10/2026.

## Ambiente

| Item | Versão |
|---|---|
| Flutter | 3.47.7 (stable) |
| Dart | 3.13.5 |
| Android SDK | 36 |
| JDK | 17 (`/snap/android-studio/247/jbr`) |
| Gradle | 9.1.0 |
| AGP | 9.0.1 |
| Aparelho Android | **nenhum conectado** (só Linux/Chrome) |

## Antes × depois

| Métrica | Antes (`69d1e6a`) | Depois das correções P0 |
|---|---|---|
| `flutter analyze` | 0 issues | 0 issues |
| `dart format .` | falhava (114 arquivos) | limpo (`--set-exit-if-changed` = 0) |
| `flutter test` | 554 passando | 590 passando |
| Cobertura de linhas | 52,1% (5727/10988) | 52,2% (5849/11207) |
| `:app:lintDebug` | 8 erros / 20 avisos | **0 erros** / 16 avisos |
| `:app:testDebugUnitTest` | não rodava junto do lint | passa |
| APK release (universal) | 82.497.080 B | — (agora por ABI) |
| APK release arm64-v8a | — | 30,6 MB |
| APK release armeabi-v7a | — | 29,3 MB |
| APK release x86_64 | — | 32,3 MB |
| APK debug | build ok | build ok |

### Erros de lint corrigidos (não silenciados)

1. `MissingIntentFilterForMediaSearch` — `MEDIA_PLAY_FROM_SEARCH` adicionado ao
   serviço de mídia (Android Auto / busca por voz).
2. `NewApi` em `MediaDeleteHandler` — métodos de exclusão anotados com
   `@RequiresApi`/`@SuppressLint` **justificado**; os chamadores já eram
   guardados por `Build.VERSION`.
3. `NewApi` no retry de `onActivityResult` — só alcançável após diálogo do
   Android 10/11+; supressão documentada.
4. `NewApi` em `VideoQueryHandler` — **bug real**: a sobrecarga
   `ThumbnailUtils.createVideoThumbnail(File, Size, CancellationSignal)` só
   existe no API 29+ e era chamada sem guarda (crash em Android 7–9). Agora há
   fallback para a sobrecarga antiga.
5. `IntentReset` em `FileQueryHandler` — `setData` seguido de `setType` apagava
   a URI; trocado por `setDataAndType`.
6. `SelectedPhotoAccess` — `READ_MEDIA_VISUAL_USER_SELECTED` declarado para o
   acesso parcial do Android 14.

Avisos restantes (16) são de estilo/terceiros e estão triados em
`docs/TROUBLESHOOTING.md`; nenhum é erro. O lint de dependências
(`audio_service`) não é executado por `:app:lintDebug`.

## O que foi verificado de fato

- `flutter analyze` e `dart format` limpos.
- `flutter test --coverage` com 590 testes passando.
- `flutter build apk --release --split-per-abi` e `--debug`.
- `./gradlew :app:lintDebug :app:testDebugUnitTest`.
- Testes unitários cobrem zip-slip, zip bomb, nomes inválidos, colisão na
  lixeira, manifesto corrompido, move/cópia entre volumes (simulado),
  `EXDEV` e restauração.

## O que NÃO foi verificado (sem aparelho)

Estes itens **não podem** ser declarados prontos apenas com testes de unidade:

- abertura a frio e tempo de primeira tela;
- jank/scroll em listas grandes;
- StrictMode (disco/rede na main thread);
- TalkBack e navegação por acessibilidade;
- reprodução real de áudio em background/notificação;
- restauração da lixeira entre volumes reais (EXDEV de verdade);
- permissões por versão (Android 9, 10, 11, 13, 14) na prática;
- assinatura de release com keystore do dono (não há `key.properties`).

Ver `docs/RELATORIO_FINAL.md` para o status honesto de cada item.
