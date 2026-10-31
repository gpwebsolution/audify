# Relatório final — Auditoria e correções P0

Data: 31/10/2026. Base: `69d1e6a`. Este relatório separa **o que foi feito e
verificado** do que **continua pendente**. Onde não houve execução real, está
escrito “não verificado” — sem inferência.

## Resultado em números

| Métrica | Antes | Depois |
|---|---|---|
| `flutter analyze` | 0 | 0 |
| `dart format .` | falhava (114 arquivos) | limpo |
| Testes Flutter | 554 | **590** |
| Cobertura de linhas | 52,1% | 52,2% (5849/11207) |
| `:app:lintDebug` | 8 erros | **0 erros**, 16 avisos triados |
| `:app:testDebugUnitTest` | não rodava no CI | passa |
| APK release | universal ~82,5 MB | por ABI: 29,3 / 30,6 / 32,3 MB |
| `INTERNET` no APK release | presente | **ausente** (verificado com `aapt2`) |
| `allowBackup` / cleartext | padrão | `false` / `false` |

## Correções de segurança e perda de dados (P0)

### Arquivos e ZIP

- **Zip-slip / path traversal**: `archive_service.dart` rejeita `..`, caminho
  absoluto, letra de unidade, symlink, entrada duplicada e destino fora da
  raiz.
- **Zip bomb**: limites de entradas, tamanho por entrada, total descompactado
  e taxa de compressão.
- **Extração parcial**: saída apagada em falha; tamanho escrito conferido;
  assinatura ZIP validada; execução em isolate.
- **Nomes inválidos**: `file_name_validator.dart` centraliza a validação
  (vazio, controle, reservados do DOS, >255 bytes, `<>:"|?*`, ponto/espaço no
  fim).
- **Sobrescrita silenciosa**: `uniquePathSync` gera `nome (1)`; `moveJob` se
  recusa a sobrescrever.
- **Cópia/movimentação entre volumes**: `moveAcrossVolumes` copia para
  temporário, confere tamanho/SHA-256, renomeia, apaga origem e faz rollback
  em falha. `moveJob` só usa o fallback em `EXDEV` real.

### Lixeira

- Manifesto com estado `pending` antes do move e `moved` depois; gravação
  atômica (`manifest.tmp` + rename); JSON por linha com escape correto;
  linhas corrompidas não derrubam a lixeira.
- Restauração retorna `FileOpResult`, nunca sobrescreve e funciona entre
  volumes.

### Exclusão de mídia (Android)

- Estratégia por versão mantida e agora com retorno verificado.
- **Bug real corrigido**: `ThumbnailUtils.createVideoThumbnail(File, Size,
  CancellationSignal)` (API 29+) era chamado sem guarda e crasharia em
  Android 7–9; há fallback para a sobrecarga antiga.
- `ACTION_EDIT` usava `setData` + `setType` (o segundo apagava a URI);
  corrigido para `setDataAndType`.

### Privacidade e superfície

- `INTERNET` removida do manifesto de release; `usesCleartextTraffic=false`.
- `allowBackup=false` + `backup_rules.xml`/`data_extraction_rules.xml`
  excluindo logs, lixeira, banco, prefs e armazenamento externo.
- `file_paths.xml` reduzido a `external-path name="shared" path="."`.
- `queryContentUri` só entrega arquivo regular existente com extensão de
  imagem conhecida.
- `READ_MEDIA_VISUAL_USER_SELECTED` declarado para o acesso parcial do
  Android 14.
- Serviço de mídia declara `MEDIA_PLAY_FROM_SEARCH` (Android Auto/busca por
  voz).

### Banco de dados

- `PRAGMA foreign_keys = ON` em `onConfigure`.
- `onDowngrade` lança erro claro em vez de apagar dados silenciosamente.

### Assinatura

- `build.gradle.kts` lê `android/key.properties` e cria a configuração de
  release; sem o arquivo, usa debug **com aviso**. CI não assina release.

## Testes adicionados

- `test/file_security_test.dart`: zip-slip, absoluto, irmão, duplicata, zip
  bomb, ZIP válido; validação de nomes (incluindo limite de 255 bytes);
  colisão na lixeira; manifesto com aspas, linha corrompida e atomicidade.
- `test/file_ops_jobs_test.dart`: copy/move (arquivo, pasta, criação de pai,
  não sobrescrever, ausente), `moveAcrossVolumes` (arquivo, pasta, ocupado,
  ausente), delete/create/unique, limites de `extractZipSync`, não-ZIP,
  symlink, taxa de compressão, `FileOpResult`.
- `test/file_query_service_test.dart` atualizado para os resultados tipados.

## CI e documentação

- `.github/workflows/ci.yml`: format, analyze, test com cobertura e piso,
  `:app:lintDebug` + `:app:testDebugUnitTest`, APK release por ABI + debug,
  artefatos e mapping R8. Flutter fixo em 3.47.7.
- `.github/dependabot.yml`: pub, Gradle e GitHub Actions, sem merge
  automático.
- `docs/BASELINE.md`, `docs/SECURITY.md`, `docs/ARCHITECTURE.md`,
  `docs/RELEASE.md`, `docs/PRIVACY.md`, `docs/TROUBLESHOOTING.md` e este
  relatório.

## Evidências de execução (31/10/2026)

```text
dart format --output=none --set-exit-if-changed lib test   -> 0
flutter analyze                                            -> 0 issues
flutter test --coverage                                    -> 590 passando
cobertura                                                  -> 5849/11207 (52,19%)
./gradlew :app:lintDebug :app:testDebugUnitTest            -> BUILD SUCCESSFUL
flutter build apk --release --split-per-abi                -> 3 APKs
aapt2 dump permissions (arm64 release)                     -> sem INTERNET
aapt2 dump xmltree (arm64 release)                         -> allowBackup=false,
                                                              cleartext=false
```

## O que NÃO foi verificado (honestidade)

Sem aparelho Android conectado (só Linux/Chrome), **não** foi possível validar:

- abertura a frio, tempo de primeira tela e jank;
- StrictMode (I/O de disco/rede na main thread);
- TalkBack e navegação por acessibilidade;
- reprodução real em background/notificação e controles de fone;
- exclusão de mídia nas versões 9, 10, 11/12, 13 e 14;
- restauração da lixeira com `EXDEV` real entre volumes;
- comportamento do MediaStore e do acesso parcial do Android 14;
- assinatura de release com a keystore do dono (não há `key.properties`).

Também não foram feitos: atualização de plugins (75 desatualizados), lint do
projeto inteiro (`audio_service` acusa erros de terceiros), remoção de
permissões amplas (decisão de produto) e migração de `applicationId`.

## Riscos residuais

1. **Permissões amplas**: `MANAGE_EXTERNAL_STORAGE` é sensível na Play Store;
   a política/sabor lite depende do dono.
2. **Dependências antigas**: 75 pacotes desatualizados; `permission_handler`,
   `file_picker`, `archive`, `image` e Syncfusion merecem atualização
   planejada com teste em aparelho.
3. **Sem teste em hardware**: os caminhos nativos por versão do Android são a
   maior incerteza restante.
4. **Licenças**: projeto e Syncfusion sem decisão formal.
5. **`applicationId` provisório** (`com.example.music_app`): trocar depois de
   publicar quebra atualização; decidir antes da primeira publicação.

## Próximos passos recomendados

1. Dono define `applicationId`, escopo Android-only, sabor lite, política da
   lixeira, motor de áudio e licenças.
2. Rodar o checklist manual de `PENDENTE.md` em aparelhos Android 9/10/11/13/14.
3. Atualizar dependências em lotes pequenos, com CI + aparelho.
4. Fornecer keystore e `key.properties` para o primeiro release assinado.
5. Subir a cobertura de forma incremental (serviços nativos e telas menos
   cobertas), sem reduzir o piso do CI.
