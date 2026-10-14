import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing: android/key.properties (never committed) with
//   storeFile=<path to the .jks, relative to android/app or absolute>
//   storePassword=...
//   keyAlias=...
//   keyPassword=...
// Without it a release build is signed with the debug key, which anyone can
// use: such an APK must never be handed out (updates are only accepted from
// the same key).
val releaseSigningFile = rootProject.file("key.properties")
val releaseSigning = Properties()
if (releaseSigningFile.isFile) {
    releaseSigningFile.inputStream().use { releaseSigning.load(it) }
}

fun releaseSigningValue(name: String): String =
    releaseSigning.getProperty(name)?.trim()?.takeIf { it.isNotEmpty() }
        ?: throw GradleException("android/key.properties: \"$name\" is missing")

android {
    namespace = "com.roj.zen"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    sourceSets {
        getByName("main") {
            jniLibs.srcDirs("src/main/jniLibs")
        }
    }

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.roj.zen"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            abiFilters.clear()
            abiFilters += "arm64-v8a"
        }
    }

    signingConfigs {
        if (releaseSigningFile.isFile) {
            create("release") {
                storeFile = file(releaseSigningValue("storeFile"))
                storePassword = releaseSigningValue("storePassword")
                keyAlias = releaseSigningValue("keyAlias")
                keyPassword = releaseSigningValue("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (releaseSigningFile.isFile) {
                signingConfigs.getByName("release")
            } else {
                project.logger.warn(
                    "WARNING: android/key.properties not found - the release build " +
                        "is signed with the DEBUG key. Do not distribute it.",
                )
                signingConfigs.getByName("debug")
            }
            isMinifyEnabled = true
            isShrinkResources = true
            ndk {
                debugSymbolLevel = "NONE"
            }
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    packaging {
        jniLibs {
            excludes += listOf(
                "lib/armeabi-v7a/**",
                "lib/armeabi/**",
                "lib/x86/**",
                "lib/x86_64/**",
            )
        }
        resources {
            excludes += listOf("org/apache/tika/**")
        }
    }
}

flutter {
    source = "../.."
}

// Go bridge (native/yggdrasil_bridge): checked before every build and
// rebuilt only when its Go sources changed (the hash is kept next to the
// .so): build_if_changed.ps1 on Windows, build_if_changed.sh elsewhere.
// ZEN_SKIP_GO_BRIDGE=1 skips the check. See docs/WYDANIA.md.
val goBridgeDir = rootProject.file("../native/yggdrasil_bridge")
val isWindowsHost = System.getProperty("os.name").lowercase().contains("windows")
val buildGoBridge = tasks.register<Exec>("buildGoBridge") {
    group = "build"
    description = "Rebuilds libyggdrasil_bridge.so when the Go sources changed."
    workingDir = goBridgeDir
    if (isWindowsHost) {
        commandLine(
            "powershell",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            File(goBridgeDir, "build_if_changed.ps1").absolutePath,
            "-Target",
            "android",
        )
    } else {
        commandLine("sh", File(goBridgeDir, "build_if_changed.sh").absolutePath)
    }
    // The SDK from local.properties, so the script finds its NDK.
    val localProperties = Properties()
    val localPropertiesFile = rootProject.file("local.properties")
    if (localPropertiesFile.isFile) {
        localPropertiesFile.inputStream().use { localProperties.load(it) }
    }
    localProperties.getProperty("sdk.dir")?.let { environment("ANDROID_HOME", it) }
}
tasks.configureEach {
    if (name == "preBuild") {
        dependsOn(buildGoBridge)
    }
}
android {
    packaging {
        jniLibs {
            // The source hash next to the .so is not part of the app.
            excludes += "**/*.sha256"
        }
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    // System biometric prompt with a Keystore key (§14.1).
    implementation("androidx.biometric:biometric:1.1.0")
}
