# 🎵 Audify

**Tocador de mídia local para Android/iOS** — música, vídeos, galeria de fotos e PDFs, tudo no seu aparelho, com playlists e player em segundo plano (MediaSession).

O Audify lê a biblioteca de mídia do aparelho (MediaStore), toca MP3s empacotados nos assets do app e guarda playlists em banco local (SQLite). Sem contas, sem nuvem, sem credenciais — 100% offline e privado.

---

## ✨ Funcionalidades

| Aba | O que faz |
|-----|-----------|
| 🎵 **Música** | Lista músicas do MediaStore do aparelho **+** MP3s dos assets (`assets/songs/`), capa de álbum, busca, fila de reprodução |
| 🎬 **Vídeos** | Lista vídeos do aparelho com miniaturas e player em tela cheia |
| 🖼️ **Galeria** | Fotos do aparelho por álbum, com visualizador e cache de miniaturas em disco |
| 📄 **PDFs** | Lista PDFs do aparelho, visualizador com progresso de leitura salvo por arquivo |
| 📃 **Playlists** | Crie/renomeie/exclua playlists e associe músicas e vídeos a elas (SQLite) |
| ⚙️ **Configurações** | Tema claro/escuro/sistema, retomada automática de reprodução, permissões e licenças |

### Player
- Reprodução em **segundo plano** com notificação de mídia e controles na tela de bloqueio (MediaSession via `audio_service`)
- Mini player fixo no rodapé + tela do player com controles completos
- **Retomada de reprodução**: abre o app e continua de onde parou na sessão anterior
- Modos de repetição e fila de reprodução

### Permissões (Android)
Solicitadas sob demanda, de acordo com a versão do Android:
- `READ_MEDIA_AUDIO / READ_MEDIA_IMAGES / READ_MEDIA_VIDEO` (Android 13+)
- `READ_EXTERNAL_STORAGE` (≤ 12) e `MANAGE_EXTERNAL_STORAGE` para PDFs no 13+
- `POST_NOTIFICATIONS` (13+) para a notificação de música

---

## 🧱 Arquitetura

```
lib/
├── main.dart                  # Bootstrap: providers + AudioService + tema
├── theme/                     # AppTheme (claro/escuro, Material 3)
├── models/                    # Song, Video, GalleryImage, PdfFile, RepeatMode...
├── providers/                 # Camada de estado (ChangeNotifier + provider)
│   ├── player_provider.dart   #    player (áudio via audio_service)
│   ├── playlist_provider.dart #    playlists (SQLite)
│   ├── video_provider.dart    #    biblioteca de vídeos
│   ├── gallery_provider.dart  #    galeria de fotos
│   ├── pdf_provider.dart      #    PDFs
│   └── settings_provider.dart #    tema + retomada (shared_preferences)
├── services/
│   ├── audio_service.dart     # MediaSession / notificação / background
│   ├── song_catalog_service.dart  # MediaStore + assets (AssetManifest)
│   ├── gallery_query_service.dart # consulta de fotos/álbuns
│   ├── video_query_service.dart   # consulta de vídeos
│   ├── pdf_query_service.dart     # consulta de PDFs
│   ├── permission_service.dart    # permissões por versão do SO
│   ├── playlist_database.dart     # schema SQLite
│   ├── media_share_service.dart   # compartilhar arquivos
│   └── pdf_progress_service.dart  # página salva por PDF
├── screens/                   # 6 abas + player + visualizadores
├── widgets/                   # ListTile de música, artwork, controles...
├── repositories/              # session/playlist/media-delete/song
└── utils/                     # format, playback_queue
```

- **Estado**: `provider` (ChangeNotifier + InheritedWidget), sem overengineering
- **Áudio**: `audioplayers` (mesma API para `AssetSource` hoje e `UrlSource` no futuro)
- **Persistência**: `sqflite` (playlists) + `shared_preferences` (preferências)
- **Mídia nativa**: `on_audio_query` (MediaStore) — com **cópia local corrigida** em `third_party/on_audio_query_android` (ver nota no `pubspec.yaml`)
- **PDF**: `syncfusion_flutter_pdfviewer`; **Vídeo**: `video_player`

> **Nota:** `dependency_overrides` aponta `on_audio_query_android` para a cópia local em `third_party/` (correção de AGP 8+/namespace). Não remova essa pasta.

---

## 🚀 Como rodar o projeto

### Requisitos

| Ferramenta | Versão |
|------------|--------|
| [Flutter SDK](https://docs.flutter.dev/get-started/install) | 3.44+ (Dart 3.12+) — verificado em Dart 3.13 |
| Android Studio / Android SDK | API 35+ (compile/target), min SDK 24 |
| Xcode (macOS, opcional) | 15+ para build iOS |
| Linux (opcional) | `libsecret-1-dev`, `libjsoncpp-dev`, `ninja-build`, `gtk3` etc. para build desktop |

Verifique sua instalação:

```bash
flutter doctor
flutter --version
```

### Passo a passo

```bash
# 1. Clone o repositório
git clone <URL_DO_SEU_REPOSITORIO> audify
cd audify

# 2. Instale as dependências
flutter pub get

# 3. (Opcional) Análise estática — deve terminar sem erros
flutter analyze

# 4. Rode os testes
flutter test

# 5. Execute o app
flutter run                        # escolhe o dispositivo conectado
flutter run -d <device-id>         # ex.: flutter run -d emulator-5554

# Alternativas de execução:
flutter emulators --launch <emulador>   # lista: flutter emulators
flutter devices                        # lista dispositivos conectados
```

### Gerar APK de produção

```bash
# APK debug (instalável direto):
flutter build apk --debug

# APK release:
flutter build apk --release
# Saída: build/app/outputs/flutter-apk/app-release.apk

# App Bundle (Play Store):
flutter build appbundle --release

# Bundle por plataforma (opcional):
flutter build ios --release     # macOS + Xcode
flutter build linux --release   # desktop Linux
```

> ⚠️ **Assinatura:** o build release atual assina com a **chave debug** (config padrão do template). Para publicar na Play Store, crie uma keystore própria e configure `key.properties` — **nunca** commite a keystore nem o `key.properties` (ambos estão no `.gitignore`).

### Adicionar músicas nos assets

1. Coloque arquivos `.mp3` em `assets/songs/` (descobertos dinamicamente via `AssetManifest`, sem nome hardcoded)
2. Rebuild o app:
   ```bash
   flutter clean && flutter pub get && flutter run
   ```

> As músicas dos assets aparecem junto com as do MediaStore na aba **Música**, em uma única lista ordenada.

### Rodar testes isolados

```bash
flutter test                       # todos
flutter test test/playback_queue_test.dart   # um específico
```

---

## 🧪 Testes

Os testes unitários cobrem filas de reprodução, persistência de sessão e progresso de PDF, álbuns de imagem e agrupamento de vídeos em playlists:

```bash
flutter test
```

---

## 🛡️ Segurança — antes de dar `git push`

Este repositório é **100% local e offline**: não há chaves de API, contas ou backend. Mesmo assim, o `.gitignore` está reforçado para impedir o vazimento de dados da sua máquina:

**Nunca serão versionados:**
- 🔑 Chaves de assinatura: `*.jks`, `*.keystore`, `*.p12`, `key.properties`
- 🗺️ Caminhos do seu PC: `android/local.properties` (contém `sdk.dir` e `flutter.sdk`)
- 🧹 Artefatos de build: `/build/`, `/android/build/`, `.dart_tool/`
- 📱 Arquivos gerados pelo Flutter com caminhos locais: `Generated.xcconfig`, `flutter_export_environment.sh`, pastas `ephemeral/`
- 🪵 Logs e caches: `*.log`, `.idea/`, `*.iml`
- 🌐 Arquivos de ambiente: `.env`, `google-services.json`

**Checklist antes de subir:**
```bash
git status                          # revise TUDO que vai subir
git ls-files | grep -iE "jks|keystore|local.properties|\.env|key.properties"
# ↑ o comando acima deve retornar NADA
```

> 💡 **Regra de ouro:** nunca adicione `local.properties`, `key.properties`, keystores, `.env` ou logs ao commit. Se precisar de configuração local, crie um `.env.example` versionado com placeholders.

---

## 📁 Estrutura do projeto

```
audify/
├── lib/                 # Código Dart (ver Arquitetura)
├── android/             # Projeto Android (Gradle Kotlin DSL)
├── ios/                 # Projeto iOS
├── linux/ macos/ windows/ web/   # Suporte desktop/web (gerado pelo Flutter)
├── assets/
│   ├── songs/           # MP3s empacotados no app
│   └── images/          # Logo do app
├── third_party/         # Cópia local corrigida do on_audio_query_android
├── test/                # Testes unitários
├── pubspec.yaml         # Dependências e assets
└── .gitignore           # Blindado — não altere sem necessidade
```

---

## 📄 Licenças

Todas as bibliotecas usadas são de código aberto — a lista completa aparece no app (Configurações → Licenças de código aberto).

---

Feito com Flutter. 🚀