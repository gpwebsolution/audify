plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.music_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
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
            // Uso pessoal (sideload): assinado com a chave debug — não há
            // publicação na Play Store, então uma keystore dedicada só
            // adicionaria atrito sem benefício.
            signingConfig = signingConfigs.getByName("debug")
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
