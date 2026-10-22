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

// ABIs the APK carries, each with its own Go bridge (native/yggdrasil_bridge,
// built per ABI by build_android.*): arm64-v8a (phones), armeabi-v7a (older
// 32-bit phones) and x86_64 (ChromeOS, emulators). Flutter passes the
// platforms it builds for as "target-platform" (all three for
// `flutter build apk`, only the device's for `flutter run`), so a debug run
// builds one bridge, not three. 32-bit x86 has no Flutter release engine.
val zenAbiOfPlatform = mapOf(
    "android-arm64" to "arm64-v8a",
    "android-arm" to "armeabi-v7a",
    "android-x64" to "x86_64",
)
val zenAbis: List<String> = (project.findProperty("target-platform") as String?)
    ?.split(",")
    ?.mapNotNull { zenAbiOfPlatform[it.trim()] }
    ?.distinct()
    ?.takeIf { it.isNotEmpty() }
    ?: zenAbiOfPlatform.values.toList()
// `flutter build apk --split-per-abi` (the release APKs, one per ABI:
// Zen-arm64-v8a.apk, Zen-armeabi-v7a.apk, Zen-x86_64.apk) uses ABI
// splits, which AGP does not allow together with abiFilters. Every split
// APK keeps the plain version code (force-version-code-ignoring-abi in
// android/gradle.properties; Flutter would otherwise add 1000, 2000 or
// 4000 per ABI): all of them are the same release, so any one installs
// over any other (a 32-bit copy from a friend, then the 64-bit update).
val zenSplitPerAbi = project.hasProperty("split-per-abi")

// Distribution flavors:
//   full         - the full app (self-update, passing the APK on);
//   appStoreOnly - Google Play / Galaxy Store ONLY, never to be sideloaded:
//                  no REQUEST_INSTALL_PACKAGES (src/appStoreOnly/
//                  AndroidManifest.xml), no icon camouflage, the label "Zen" as
//                  everywhere, and Dart
//                  hides self-update and APK sharing (appFlavor ==
//                  "appStoreOnly", lib/src/features/update/store_build.dart).
//   flutter build appbundle --release --flavor appStoreOnly   (Play)
//   flutter build apk --release --flavor appStoreOnly         (Galaxy Store)
// The flavors exist only when a flavored task is asked for (or with
// -Pzen.flavors=true, e.g. for Android Studio), so plain `flutter build apk`
// and `flutter run` still build the full app as app-release.apk.
val zenFlavors: Boolean =
    (project.findProperty("zen.flavors") as String?)?.toBoolean() == true ||
        Regex("(full|appstoreonly)(debug|profile|release)").containsMatchIn(
            gradle.startParameter.taskNames.joinToString(" ").lowercase(),
        )

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
        if (!zenSplitPerAbi) {
            ndk {
                abiFilters.clear()
                abiFilters += zenAbis
            }
        }
    }

    if (zenSplitPerAbi) {
        splits {
            abi {
                // Only the ABIs with a Go bridge (no armeabi or x86 APK).
                include(*zenAbis.toTypedArray())
            }
        }
    }

    if (zenFlavors) {
        flavorDimensions += "distribution"
        productFlavors {
            create("full") {
                dimension = "distribution"
                isDefault = true
            }
            create("appStoreOnly") {
                dimension = "distribution"
            }
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
            // Native libraries compressed in the APK (extracted on install):
            // the APK travels over Wi-Fi, hotspots and the mesh (passing
            // Zen on, updates from friends), and stored libraries would
            // make it about 2.5 times bigger.
            useLegacyPackaging = true
            // Plugins' libraries for ABIs without a Go bridge (and so
            // without a working app).
            excludes += listOf(
                "lib/armeabi/**",
                "lib/x86/**",
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

// The appStoreOnly files carry their purpose in the name (Flutter looks for
// its own app-appStoreOnly-release.* names, so they are copied, not renamed):
// build/app/outputs/app-store-only/Zen-APP-STORE-ONLY-do-not-install-manually.{aab,apk}
val appStoreOnlyName = "Zen-APP-STORE-ONLY-do-not-install-manually"
if (zenFlavors) {
    for ((task, source, extension) in listOf(
        Triple("bundleAppStoreOnlyRelease", "bundle/appStoreOnlyRelease", "aab"),
        Triple("assembleAppStoreOnlyRelease", "apk/appStoreOnly/release", "apk"),
    )) {
        val copy = tasks.register<Copy>("copy${task.replaceFirstChar { it.uppercase() }}Output") {
            from(layout.buildDirectory.dir("outputs/$source")) {
                include("*.$extension")
                rename { "$appStoreOnlyName.$extension" }
            }
            into(layout.buildDirectory.dir("outputs/app-store-only"))
        }
        tasks.matching { it.name == task }.configureEach { finalizedBy(copy) }
    }
}

// Go bridge (native/yggdrasil_bridge): checked before every build and
// rebuilt only when its Go sources changed (the hash is kept next to the
// .so): build_if_changed.ps1 on Windows, build_if_changed.sh elsewhere.
// ZEN_SKIP_GO_BRIDGE=1 skips the check. See docs/RELEASES.md.
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
    // Only the ABIs this build packages (one for `flutter run`).
    environment("ZEN_ANDROID_ABIS", zenAbis.joinToString(","))
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
    // System biometric prompt with a Keystore key.
    implementation("androidx.biometric:biometric:1.1.0")
}
