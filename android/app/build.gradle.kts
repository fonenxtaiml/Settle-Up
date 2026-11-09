import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing (README "Release signing"). The upload key lives outside
// git: android/key.properties (git-ignored) names the keystore and its
// passwords. Without that file a release build falls back to the debug key
// and says so loudly; pass -PrequireReleaseKey to make that an error.
val keystorePropertiesFile: File = rootProject.file("key.properties")
val hasReleaseKey = keystorePropertiesFile.isFile
val keystoreProperties = Properties().apply {
    if (hasReleaseKey) keystorePropertiesFile.inputStream().use { load(it) }
}

fun releaseKeyProperty(name: String): String =
    keystoreProperties.getProperty(name)?.takeIf { it.isNotBlank() }
        ?: throw GradleException(
            "android/key.properties has no $name. It needs storeFile, " +
                "storePassword, keyAlias and keyPassword (see README.md).",
        )

android {
    namespace = "app.settleup.settle_up"
    // 37 (not 36 as in SPEC 9.1): permission_handler_android 14.1.1 AAR metadata
    // requires consumers to compile against API 37. targetSdk stays 36.
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "app.settleup.settle_up"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 26 // LocalOnlyHotspot (P1); bluetooth_low_energy needs 24
        targetSdk = 36 // NOT 37: Android 17 local-network permission is unverified
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                // A relative storeFile is resolved from the android/ folder.
                storeFile = rootProject.file(releaseKeyProperty("storeFile"))
                storePassword = releaseKeyProperty("storePassword")
                keyAlias = releaseKeyProperty("keyAlias")
                keyPassword = releaseKeyProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKey) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

// Warn (or fail with -PrequireReleaseKey) only when a release variant is
// actually built, so debug builds and tests stay quiet.
gradle.taskGraph.whenReady {
    val buildsRelease = allTasks.any {
        it.project == project && it.name.contains("Release")
    }
    if (buildsRelease && !hasReleaseKey) {
        val message =
            "android/key.properties not found: this RELEASE build is signed " +
                "with the DEBUG key. It cannot be uploaded to Play, and a " +
                "build signed with the real key cannot update it. See " +
                "README.md \"Release signing\"."
        if (project.hasProperty("requireReleaseKey")) {
            throw GradleException(message)
        }
        logger.warn("WARNING: $message")
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
