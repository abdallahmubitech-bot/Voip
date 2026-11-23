import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Load the release keystore when it is present; fall back to debug signing
// otherwise so the project still builds out of the box.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        FileInputStream(keystorePropertiesFile).use { load(it) }
    }
}

// `version: 1.2.0+3` in pubspec.yaml -> name "1.2.0", code 3.
val pubspecVersionRaw: String = rootProject.file("../pubspec.yaml")
    .takeIf { it.exists() }
    ?.readLines()
    ?.firstOrNull { it.trimStart().startsWith("version:") }
    ?.substringAfter("version:")
    ?.trim()
    ?.trim('"', '\'')
    ?: ""
val pubspecVersionName: String =
    pubspecVersionRaw.substringBefore("+").ifBlank { "1.2.0" }
val pubspecBuildNumber: Int =
    pubspecVersionRaw.substringAfter("+", "3").trim().toIntOrNull() ?: 3

android {
    namespace = "com.example.esp32_voip"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.esp32_voip"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = maxOf(flutter.minSdkVersion, 23)
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        // Read the version straight from pubspec.yaml (`version: 1.2.0+3`) so the
        // APK is correct even when Gradle is driven directly, without the
        // `flutter build` wrapper that normally writes flutter.versionCode
        // into local.properties.
        versionCode = (project.findProperty("voipVersionCode") as String?)?.toInt()
            ?: pubspecBuildNumber
        versionName = (project.findProperty("voipVersionName") as String?)
            ?: pubspecVersionName

        // The AOT snapshot is generated for arm64-v8a only, so restrict the
        // native libraries to that ABI. Without this, plugin .so files for other
        // ABIs are packaged and ship without a matching libapp.so.
        ndk {
            abiFilters.add("arm64-v8a")
        }
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = rootProject.file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            isMinifyEnabled = false
            isShrinkResources = false
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
