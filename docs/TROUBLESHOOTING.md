# Troubleshooting — Audify

Problemas comuns no desenvolvimento/build e como diagnosticar sem “apagar o
que incomoda”.

## Ambiente

### `flutter` usa a versão errada

O projeto e o CI fixam **Flutter 3.47.7 / Dart 3.13.5**. Versões diferentes
mudam o formatador (`dart format`) e o analyzer. Confira:

```bash
flutter --version
dart --version
```

### Gradle falha por JDK

Use JDK 17. Neste ambiente:

```bash
JAVA_HOME=/snap/android-studio/247/jbr ./gradlew :app:lintDebug
```

### `dart format` acusa arquivos

O formatador do Dart 3.13 usa o estilo novo. Rode `dart format .` e commite a
formatação junto da mudança funcional (ou em commit separado). **Não** use
`--set-exit-if-changed` para “esconder” diferenças sem formatar.

## Build

### APK release “abre e fecha” ou crasha só no release

Quase sempre é R8 removendo/renomeando classe de plugin. Verifique
`android/app/proguard-rules.pro` e `docs/RELEASE.md`. Não desative a
minificação para contornar.

### `INSTALL_FAILED_UPDATE_INCOMPATIBLE`

A assinatura mudou (debug × release ou keystore diferente). Desinstale a
versão anterior ou use a mesma chave. Nunca troque a chave de uma versão já
publicada.

### `key.properties` ausente

Esperado em máquina sem a keystore do dono: o release usa debug e avisa.
Não é erro de código; não commitar keystore.

### `:app:lintDebug` falha por `audio_service`

Rode apenas `:app:lintDebug` (o lint do app). O comando `lint` do projeto
inteiro analisa dependências e acusa erros do plugin `audio_service`, que não
são nossos. Se precisar do lint global, atualize o plugin ou configure
`checkDependencies` — **não** silencie sem registrar o motivo.

## Testes

### Teste falha só no CI

- Confira a versão do Flutter (o CI fixa 3.47.7).
- Rode `flutter test --coverage` localmente.
- Não use `--no-verify`, não delete teste e não adicione `skip` para passar.

### Cobertura caiu

O CI tem piso (`MIN_COVERAGE` em `.github/workflows/ci.yml`). Adicione teste
para o código novo; não baixe o piso.

## Lint do Android — avisos triados

`./gradlew :app:lintDebug` termina com **0 erros** e 16 avisos. Triagem:

| Aviso | Onde | Decisão |
|---|---|---|
| `ScopedStorage` | `MANAGE_EXTERNAL_STORAGE` | intencional: o app gerencia arquivos fora do MediaStore. Play Store exige justificativa; sabor “lite” é decisão do dono. |
| `InlinedApi` (`MediaStore.VOLUME_EXTERNAL`) | `MediaDeleteHandler`, `PdfQueryHandler` | constante inlinada em tempo de compilação; segura em minSdk 24. |
| `ExportedService` | `AudioService` | exigido pelo `audio_service`/Android Auto para MediaBrowser; protegido pelo contrato do MediaSession. |
| `UseKtx` (9) | `FileQueryHandler`, `MediaDeleteHandler`, `PdfQueryHandler` | estilo; trocar por KTX é melhoria incremental, sem impacto funcional. |
| `AndroidGradlePluginVersion` | Gradle wrapper | atualização de Gradle/AGP exige revalidação; não fazer às cegas. |
| `ObsoleteSdkInt` | `drawable-v21` | pasta legada; inofensiva. |
| `UnusedResources` | `mipmap-hdpi/ic_launcher.png` | ícone de launcher gerado; não remover sem conferir todas as densidades. |

Nenhum aviso foi convertido em erro nem escondido com `lintOptions { abortOnError false }`.

## Problemas de dispositivo (quando houver aparelho)

### Áudio para em segundo plano

- Confirme `FOREGROUND_SERVICE_MEDIA_PLAYBACK` e o serviço em foreground.
- Em fabricantes agressivos (Xiaomi/Huawei/Samsung), peça isenção de bateria
  pelas Configurações do app; o pedido é opcional e explicado ao usuário.

### Excluir mídia não funciona em uma versão específica

O caminho nativo muda por API (30+/29/≤28). Reproduza com log:

```bash
adb logcat -s AudifyNative flutter
```

Verifique se o retorno é `PermissionDenied`, `Undecided` ou `Failed` — o app
mostra o motivo na SnackBar.

### Lixeira não restaura entre pastas/volumes

Restaurar usa cópia + verificação + rename quando o volume muda (`EXDEV`).
Em caso de falha, o arquivo permanece na lixeira e o erro é exibido; nada é
apagado silenciosamente.

## Logs

O app grava `crash_log.txt` local (teto de 128 KB), visível em
**Configurações → Log de erros**. É local: não sai do aparelho. Para
diagnóstico, peça ao usuário para exportar/copiar o texto manualmente.

## Onde olhar primeiro

1. `docs/BASELINE.md` — o que já foi medido.
2. `CHANGELOG.md` — o que mudou e por quê.
3. `PENDENTE.md` — decisões do dono e itens não verificados.
4. `docs/RELATORIO_FINAL.md` — status honesto por área.
