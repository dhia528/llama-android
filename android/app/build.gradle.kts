plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.llama.android.llama_android"
    compileSdk = 36
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.llama.android.llama_android"
        minSdk = 28
        // shortcut: targetSdk 28 is required to exec binaries from app storage on Android 10+ (W^X).
        // Raises when Play Store distribution is needed; port to packaged jniLibs then.
        targetSdk = 28
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    lint {
        // shortcut: targetSdk 28 is deliberate (exec from app data); Play Store distribution is not a goal.
        disable += "ExpiredTargetSdkVersion"
    }

    buildTypes {
        release {
            // shortcut: debug keystore keeps the release APK sideload-simple.
            // Generate a private keystore before distributing updates to others.
            signingConfig = signingConfigs.getByName("debug")
            // R8 renames kotlin.coroutines.Continuation, which breaks shared_preferences' JNI
            // lookups at runtime; keep minification off until that plugin drops JNI.
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

dependencies {
    testImplementation("junit:junit:4.13.2")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
