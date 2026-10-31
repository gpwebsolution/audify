# Segurança — Audify

Documento vivo das decisões de segurança. Não descreve “segurança por
obscuridade”; descreve o que o app faz, o que ele **não** faz e o que ainda
depende do dono.

## Princípios

1. **Offline por padrão.** O app não tem backend, conta, analytics, crash
   reporting remoto ou telemetria. Os logs ficam em disco local e são apagáveis
   pelo usuário.
2. **Sem rede no release.** O `AndroidManifest.xml` de release remove a
   permissão `INTERNET` (`tools:node="remove"`). Se um plugin tentar abrir
   socket, o sistema bloqueia.
3. **Menor privilégio possível.** As permissões amplas
   (`MANAGE_EXTERNAL_STORAGE`, `WRITE_EXTERNAL_STORAGE`) existem porque o app
   gerencia arquivos de áudio/vídeo/documentos fora do sandbox; a alternativa
   “lite” sem essas permissões está pendente de decisão do dono.
4. **Nada de segredo no repositório.** Keystore e `key.properties` são
   ignorados pelo Git. O build de release usa debug **apenas** como fallback
   local; CI não assina release.

## Superfície de ataque e mitigações

### Arquivos e caminhos

- Todo nome criado/renomeado passa por `lib/services/file_name_validator.dart`:
  rejeita vazio, `.`/`..`, separadores `/` e `\`, caracteres de controle,
  `<>:"|?*`, espaço/ponto no fim, nomes reservados do DOS e >255 bytes UTF-8.
- Caminhos de destino são sempre resolvidos e verificados dentro da raiz
  permitida antes de escrever (evita *path traversal* em operações normais).
- `_uniquePath`/`uniquePathSync` nunca sobrescrevem: colisão vira `nome (1)`.

### Extração de ZIP (`lib/services/archive_service.dart`)

Proteções aplicadas a **cada entrada**, antes de escrever:

| Ameaça | Mitigação |
|---|---|
| Zip-slip (`../../`) | rejeita `..`, caminhos absolutos, letra de unidade e destino fora da raiz |
| Symlink no ZIP | entradas de link são rejeitadas |
| Zip bomb | limites de entradas, tamanho por entrada, total descompactado e taxa de compressão |
| Sobrescrita silenciosa | entradas duplicadas são rejeitadas |
| Arquivo não-ZIP | assinatura `PK` validada antes de processar |
| Escrita parcial | saída parcial é apagada em caso de falha; tamanho escrito é conferido |
| Bloqueio da UI | extração roda em `compute` (isolate) |

Limites padrão em `ExtractionLimits`; ajustar exige revisão de segurança e
testes em `test/file_security_test.dart`.

### Lixeira (`lib/services/trash_service.dart`)

- Manifesto em JSON por linha, com escape correto de aspas e caminhos.
- Estado `pending` é gravado **antes** de mover; `moved` depois. Um crash no
  meio não deixa o app “esquecendo” um arquivo.
- Gravação atômica: `manifest.tmp` + `rename`.
- Linhas corrompidas são ignoradas, não derrubam a lixeira.
- Restauração usa `uniquePathSync` e `moveJob` (seguro entre volumes); nunca
  sobrescreve o arquivo existente.

### Exclusão de mídia (Kotlin)

- Estratégia por versão: MediaStore `createDeleteRequest` (11+),
  `RecoverableSecurityException` (10), exclusão direta (≤9).
- URIs são sanitizadas (`content://` + authority do MediaStore); URI inválida
  não derruba o lote inteiro.
- O retorno é **verificado** (linha do MediaStore e arquivo em disco), não um
  booleano otimista.

### FileProvider e backup

- `file_paths.xml` expõe somente `external-path name="shared" path="."`; nada
  de diretórios internos, bancos ou logs.
- `allowBackup="false"` e regras de exclusão para `logs/`, `trash/`, banco,
  shared prefs e armazenamento externo.
- `usesCleartextTraffic="false"` (defesa em profundidade, mesmo sem rede no
  release).

### Conteúdo externo

- `FileQueryHandler.queryContentUri` só devolve `content://` para arquivo
  regular existente com extensão de imagem conhecida
  (`jpg/jpeg/png/webp/gif/bmp/heic/heif`).
- `setDataAndType` é usado no `ACTION_EDIT` (o antigo `setData` + `setType`
  apagava a URI).

## Assinatura de release

`android/app/build.gradle.kts` lê `android/key.properties` (fora do Git). Se o
arquivo não existir, o build usa a chave de debug e emite aviso — **não serve
para publicação**. O dono precisa fornecer keystore, alias e senhas. O CI não
tem esses segredos e não publica release assinado.

## Dependências

- `third_party/on_audio_query_android` é código local e não pode ser removido.
- Dependabot abre PRs semanais; nenhum merge automático.
- `flutter pub outdated` é informativo no CI. Atualizações de plugin nativo
  exigem revalidação em aparelho (ver `docs/RELEASE.md`).

## Pendências de decisão do dono

- `applicationId` definitivo (hoje `com.example.music_app`).
- Sabor “lite” sem `MANAGE_EXTERNAL_STORAGE`/`WRITE_EXTERNAL_STORAGE`.
- Política da lixeira (retenção, tamanho máximo).
- Licença do projeto e licença do Syncfusion.
- Motor de áudio definitivo (hoje `just_audio`/`audio_service`).

## Como reportar

Não abra issue pública com dados pessoais, caminhos de arquivos ou logs. Envie
ao mantenedor por canal privado. O app não coleta nada automaticamente.
