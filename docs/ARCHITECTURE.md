# Arquitetura — Audify

App Flutter **Android** para tocar áudio, ver vídeos/fotos/PDFs e gerenciar
arquivos locais. Sem backend, sem conta, sem rede no release. Este documento
mostra as camadas e onde mexer sem quebrar as garantias de segurança.

## Visão geral

```
┌──────────────────────────────────────────────────────────────┐
│ UI (lib/screens, lib/widgets)                                │
│  MainScreen · Music · Videos · Gallery · PDFs · Files · Trash │
└───────────────┬──────────────────────────────────────────────┘
                │ watch/read
┌───────────────▼──────────────────────────────────────────────┐
│ Estado (lib/providers — ChangeNotifier)                       │
│  Player · File · Gallery · Pdf · Video · Playlist · Settings │
└───────────────┬──────────────────────────────────────────────┘
                │ chamadas tipadas
┌───────────────▼──────────────────────────────────────────────┐
│ Serviços (lib/services)                                       │
│  consulta, arquivos, ZIP, lixeira, áudio, permissões, cache  │
└───────────────┬──────────────────────────────────────────────┘
                │ MethodChannel / plugins
┌───────────────▼──────────────────────────────────────────────┐
│ Android nativo (Kotlin) + plugins (audio_service, just_audio,│
│ video_player, sqflite, file_picker, permission_handler...)    │
└──────────────────────────────────────────────────────────────┘
```

## Camadas

### UI (`lib/screens`, `lib/widgets`, `lib/theme`, `lib/l10n`)

- `MainScreen` mantém as abas e o player persistente.
- Telas não fazem I/O direto: pedem ao provider/serviço e reagem ao resultado
  tipado (`FileOpResult`).
- Textos em `lib/l10n` (pt/en); não concatenar strings de UI fora do l10n.

### Estado (`lib/providers`)

- `ChangeNotifier` + `Provider`. O `PlayerProvider` orquestra fila, histórico,
  repetição, timer de sono e restauração de sessão.
- Providers traduzem `FileOpResult` em SnackBar/estado de UI. Nunca engolem
  erro: `failed`/`partial` têm motivo visível.

### Serviços (`lib/services`)

| Área | Arquivos principais |
|---|---|
| Consulta de mídia | `song_catalog_service`, `gallery_query_service`, `pdf_query_service`, `video_query_service` |
| Arquivos e ZIP | `file_query_service`, `file_ops_jobs`, `archive_service`, `file_name_validator`, `file_op_result` |
| Lixeira | `trash_service` |
| Áudio/playback | `audio_service`, `playback_history_service`, `notification_art_cache` |
| Banco de playlists | `playlist_database`, `playlist_transfer_service` |
| Infra | `permission_service`, `error_log_service`, `catalog_snapshot_service` |

Regras:

- Operação de arquivo **retorna** `FileOpResult` (`ok`/`partial`/`failed`),
  não `bool`.
- Nome novo passa por `validateFileName`.
- Trabalho pesado (ZIP, cópia grande) roda em isolate (`compute`).
- Caminho de destino é único (`uniquePathSync`), nunca sobrescreve.

### Android nativo (`android/app/src/main/kotlin/com/example/music_app`)

`MainActivity` é fina e registra handlers separados:

| Handler | Canal | Responsabilidade |
|---|---|---|
| `FileQueryHandler` | `audify/file_query` | content URI, editar, papel de parede |
| `GalleryQueryHandler` | `audify/gallery_query` | MediaStore de imagens/álbuns |
| `VideoQueryHandler` | `audify/video_query` | MediaStore de vídeos + miniaturas |
| `PdfQueryHandler` | `audify/pdf_query` | PDFs/Downloads |
| `MediaDeleteHandler` | `audify/media_delete` | exclusão por versão do SO |

Handlers só aceitam `content://` do MediaStore quando aplicável e verificam o
resultado no SO antes de responder ao Dart.

## Fluxos críticos

### Exclusão de mídia

1. Dart chama `media_delete` com os itens.
2. Handler escolhe a estratégia: `createDeleteRequest` (API 30+),
   `RecoverableSecurityException` (API 29) ou exclusão direta (≤28).
3. Android mostra **um** diálogo para o lote (quando aplicável).
4. Handler confirma no MediaStore **e** no disco; devolve desfecho por item.
5. Provider remove da UI apenas o que foi confirmado; cancela fila/player se
   o item atual sumiu.

### Extração de ZIP

1. `file_query_service.extractArchive` valida o destino e chama
   `archive_service.extractZipJob` em `compute`.
2. O job valida assinatura, limites e cada entrada (sem `..`, symlink,
   absoluto, duplicata).
3. Em falha, a pasta parcial é apagada e o Dart recebe `FileOpResult.failed`.

### Lixeira

1. `moveJob` move para `trash/` (com fallback entre volumes).
2. Manifesto grava `pending` → move → `moved`, com `manifest.tmp` + rename.
3. Restaurar usa `uniquePathSync` + `moveJob`; colisão vira `nome (1)`.

### Áudio em segundo plano

`AudioService` (audio_service) mantém a notificação e a MediaSession; o
`PlayerProvider` restaura a última sessão e limpa itens que não existem mais.
O serviço permanece em foreground mesmo pausado (decisão histórica para
fabricantes agressivos).

## Banco de dados

`playlist_database.dart` (sqflite): `PRAGMA foreign_keys = ON` em
`onConfigure`; `onDowngrade` lança erro claro em vez de apagar dados. Migrações
são versionadas — mudar schema exige confirmação do dono.

## Testes

- `test/` cobre serviços, providers, telas e segurança de arquivos.
- `test/file_security_test.dart` e `test/file_ops_jobs_test.dart` são
  obrigatórios para qualquer mudança em ZIP/arquivos/lixeira.
- `android/app/src/test` cobre o Kotlin quando aplicável.
- Não desabilitar teste para “passar o CI”; corrigir o código.

## Decisões pendentes do dono

`applicationId` (`com.example.music_app`), Android-only × multiplataforma,
sabor lite sem permissões amplas, política da lixeira, motor de áudio, licença
do projeto e do Syncfusion. Ver `PENDENTE.md`.
