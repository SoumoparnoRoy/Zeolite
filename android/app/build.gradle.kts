import java.util.Properties

// Real signing credentials live outside the repo, so a clone has none. Gradle
// still has to configure, hence the absent case rather than a hard failure.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        keystorePropertiesFile.inputStream().use { load(it) }
    }
}

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    // Reads google-services.json, which is gitignored, so a fresh clone has to
    // supply its own before this configures.
    id("com.google.gms.google-services")
    // Uploads the R8 mapping with a release build, so a Java stack trace in a
    // crash report reads as the code rather than as minified names.
    id("com.google.firebase.crashlytics")
}

android {
    namespace = "com.soumoparno.zeolite"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications schedules alarms using java.time APIs,
        // which must be backported for older Android versions.
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "com.soumoparno.zeolite"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        multiDexEnabled = true
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // Null without key.properties, leaving the artifact unsigned so
            // it fails loudly. Debug keys here looked fine and were not.
            signingConfig = signingConfigs.findByName("release")
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
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

// The lockfile is what lets a dependency scan see the APK's native side;
// rerun `./gradlew :app:dependencies --write-locks` after a plugin upgrade.
// The engine stays out because `flutter run` resolves only one ABI's build.
dependencyLocking {
    lockAllConfigurations()
    ignoredDependencies.add("io.flutter:*")
}

// AGP's test-platform tooling never runs here (no managed-device tests), and
// locking it fills every scan with advisories for code that never ships.
configurations.matching { it.name.startsWith("_internal-unified-test-platform") }
    .configureEach { resolutionStrategy.deactivateDependencyLocking() }

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")

    testImplementation("junit:junit:4.13.2")
    // Android's org.json is a stub on the JVM; the real one lets the prune be
    // tested against a record the plugin actually wrote.
    testImplementation("org.json:json:20250517")
}
