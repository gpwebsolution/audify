# Release — Audify

Checklist para gerar e publicar um APK. Nada aqui depende de serviço externo
além do SDK/Flutter instalado.

## Pré-requisitos

- Flutter 3.47.7 / Dart 3.13.5 (mesma versão do CI).
- JDK 17 (AGP/Gradle do projeto).
- Android SDK 36.
- Keystore de release **do dono** (não versionada) e `android/key.properties`.

## Versionamento

A versão fica em `pubspec.yaml` (`version: 1.1.0+2` = `versionName+versionCode`).
`android/app/build.gradle.kts` lê `flutter.versionName/versionCode`; não editar
os dois lugares. Mudou a versão? Atualize `CHANGELOG.md` no mesmo commit.

## Assinatura

`android/app/build.gradle.kts` procura `android/key.properties`:

```properties
storeFile=/caminho/absoluto/audify-release.jks
storePassword=...
keyAlias=...
keyPassword=...
```

Sem o arquivo, o build de release cai na chave de debug e avisa. Isso **não**
é publicável. A keystore e o `key.properties` são ignorados pelo Git; nunca
commitar. O CI não tem segredos e não assina release.

## Comandos

```bash
flutter pub get
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test --coverage
./gradlew :app:lintDebug :app:testDebugUnitTest   # rodar em android/
flutter build apk --release --split-per-abi
```

Saída em `build/app/outputs/flutter-apk/`:

| Arquivo | Uso |
|---|---|
| `app-armeabi-v7a-release.apk` | Android 32 bits (aparelhos antigos) |
| `app-arm64-v8a-release.apk` | Android 64 bits (padrão atual) |
| `app-x86_64-release.apk` | emulador/ChromeOS x86_64 |
| `app-debug.apk` | desenvolvimento (não distribuir) |

Tamanho de referência (31/10/2026): 29,3 / 30,6 / 32,3 MB. O antigo APK
universal tinha ~82,5 MB; por isso o release usa `--split-per-abi`.

`mapping.txt` do R8 (se gerado) fica em
`build/app/outputs/mapping/release/mapping.txt` — guardar para desofuscar
crashes.

## R8 / ProGuard

As regras ficam em `android/app/proguard-rules.pro` e protegem os plugins que
resolvem classes por nome em runtime (audio_service, on_audio_query,
video_player/Media3, Syncfusion, sqflite, file_picker, share_plus,
open_filex, permission_handler). **Não** remover regras para “diminuir o APK”:
o sintoma clássico é funcionar no debug e crashar no release.

## Checklist antes de publicar

- [ ] `flutter analyze` = 0 issues.
- [ ] `dart format` limpo.
- [ ] `flutter test --coverage` verde; cobertura não caiu.
- [ ] `:app:lintDebug` = 0 erros.
- [ ] APK release assinado com a keystore do dono (conferir com
      `apksigner verify --print-certs`).
- [ ] `versionCode` maior que o da versão publicada anterior.
- [ ] `CHANGELOG.md` atualizado.
- [ ] Teste manual em pelo menos Android 9, 10, 11/12, 13 e 14 (ver
      `docs/TROUBLESHOOTING.md` e `PENDENTE.md`). Sem aparelho, registrar
      “não verificado” — não declarar pronto.
- [ ] Confirmar que o app não pede rede: `aapt dump permissions` não deve
      listar `INTERNET` no APK de release.
- [ ] Conferir que `allowBackup=false` e as regras de exclusão estão no APK.

## Publicação

O projeto não define loja/assinatura de distribuição. Quando o dono definir
(Play Store, F-Droid, APK direto), documentar aqui: canal, certificado,
política de privacidade e processo de rollback.

## Rollback

1. Reverter para a tag/commit da versão anterior.
2. Rebuild com o **mesmo** `versionCode` da versão quebrada +1.
3. Publicar o APK anterior assinado com a mesma chave.
4. Registrar o incidente no `CHANGELOG.md` e, se houve perda de dados,
   explicar a migração/recuperação.
