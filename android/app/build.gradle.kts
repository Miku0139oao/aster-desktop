plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// CI supplies a fixed release key through these variables. Local builds fall
// back to the debug key so `flutter run --release` keeps working.
val releaseKeystore = System.getenv("ASTER_ANDROID_KEYSTORE")

android {
    namespace = "app.aster.desktop"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "app.aster.desktop"
        ndk {
            abiFilters += listOf("arm64-v8a", "x86_64")
        }
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
    }

    signingConfigs {
        if (releaseKeystore != null) {
            create("release") {
                storeFile = file(releaseKeystore)
                storePassword = System.getenv("ASTER_ANDROID_STORE_PASSWORD")
                keyAlias = System.getenv("ASTER_ANDROID_KEY_ALIAS")
                keyPassword = System.getenv("ASTER_ANDROID_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            // A fixed key lets users update an installed APK in place.
            signingConfig = if (releaseKeystore != null) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
            // Flutter still ships engine libraries for 32-bit ARM in a
            // universal APK, but gomobile only builds libgojni.so for 64-bit
            // ABIs. Excluding the directory keeps 32-bit devices from
            // installing a build whose engine cannot start.
            excludes += listOf("lib/armeabi-v7a/**", "lib/x86/**")
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

dependencies {
    implementation(files("libs/mobileapi.aar"))
}
