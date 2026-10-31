import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Assinatura de release: key.properties fica fora do versionamento (já está
// no .gitignore). Sem ele o build de release continua usando a chave de debug
// APENAS para sideload local — nunca publique um APK assim.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    FileInputStream(keystorePropertiesFile).use { keystoreProperties.load(it) }
}

android {
    namespace = "com.example.music_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.music_app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // SDK mínimo 24 (Android 7.0 Nougat). NOTA: o requisito original era
        // minSdk 21, mas o Flutter 3.44 abandonou suporte a < 24 — o próprio
        // tool reescreve `minSdk = 21..23` para `flutter.minSdkVersion` em
        // cada build (ver gradle_utils.dart no SDK). Manter 24 é o caminho
        // oficial e cobre ~98% dos aparelhos ativos em 2026.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // Com key.properties presente, usa a keystore própria (obrigatório
            // para atualizar por cima e para publicar). Sem o arquivo, cai na
            // chave de debug só para sideload local — a CI avisa no log.
            if (hasReleaseKeystore) {
                signingConfig = signingConfigs.getByName("release")
            } else {
                logger.warn(
                    "AVISO: key.properties ausente; release assinado com a " +
                    "chave de DEBUG. NÃO publique este APK."
                )
                signingConfig = signingConfigs.getByName("debug")
            }
            // Release minificado: R8 + resource shrink. O proguard-rules.pro
            // mantém o que resolve recursos/classes por reflexão
            // (audio_service/notificação de mídia).
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
