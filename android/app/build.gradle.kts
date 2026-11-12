import java.util.Base64
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Push notifications (Firebase project "poma-original", same as the web app).
// google-services.json comes from the Firebase console (Android app
// com.influencor.app) and is not committed. Without it the app still builds and
// runs; push is simply disabled.
if (file("google-services.json").exists()) {
    apply(plugin = "com.google.gms.google-services")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

android {
    namespace = "com.influencor.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.influencor.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // Reseller App Links (AndroidManifest `.ResellerLinks`) only in builds
        // that keep the reseller space: the Google Play build passes
        // --dart-define=INFLUENCOR_RESELLER=false (Flutter forwards dart-defines
        // to Gradle, base64-encoded and comma-separated).
        val dartDefines = (project.findProperty("dart-defines") as String?)
            ?.split(",")
            ?.filter { it.isNotBlank() }
            ?.map { String(Base64.getDecoder().decode(it)) }
            .orEmpty()
        manifestPlaceholders["resellerLinks"] =
            dartDefines.none { it.trim() == "INFLUENCOR_RESELLER=false" }.toString()
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = rootProject.file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    // A release signed with the debug key has a different certificate than the
    // one declared in assetlinks.json (App Links would silently stop being
    // verified), so a release build without key.properties fails loudly.
    // ALLOW_DEBUG_SIGNING=1 keeps `flutter run --release` usable locally.
    val releaseRequested = gradle.startParameter.taskNames.any {
        it.contains("release", ignoreCase = true)
    }
    if (releaseRequested &&
        !keystorePropertiesFile.exists() &&
        System.getenv("ALLOW_DEBUG_SIGNING") != "1"
    ) {
        throw GradleException(
            "android/key.properties is missing: refusing to sign a release with the " +
                "debug key (App Links would not verify). Create it, or set " +
                "ALLOW_DEBUG_SIGNING=1 for a local-only build."
        )
    }

    buildTypes {
        release {
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }

    packaging {
        jniLibs {
            // Native plugins are built locally by cargokit. On this Windows SDK
            // setup, app bundle generation can fail while stripping their
            // symbols even though the binaries are otherwise valid. Only
            // those are kept as is: the Flutter engine, the app code and the
            // other libraries must be stripped (otherwise ~140 MB of debug
            // symbols per ABI ship to users, and `flutter build appbundle`
            // refuses the bundle).
            keepDebugSymbols += listOf(
                "**/libsuper_native_extensions.so",
                "**/libirondash_engine_context_native.so",
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
