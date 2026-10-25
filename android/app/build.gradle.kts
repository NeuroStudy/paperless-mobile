import java.util.Properties
import java.io.FileInputStream
import com.android.build.gradle.internal.api.ApkVariantOutputImpl

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystorePropsFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropsFile.exists()) {
        FileInputStream(keystorePropsFile).use { load(it) }
    }
}

// Keep the local testing choice outside version control and preserve real release signing.
val localProperties = Properties().apply {
    rootProject.file("local.properties").takeIf { it.isFile }?.inputStream()?.use { load(it) }
}
val useDebugSigning = providers.gradleProperty("useDebugSigning")
    .orElse(localProperties.getProperty("useDebugSigning", "false"))
    .get().toBooleanStrict()
val requiredSigningProperties = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
val missingSigningProperties = requiredSigningProperties.filter {
    keystoreProperties.getProperty(it).isNullOrBlank()
}
// Match the existing CI convention: relative storeFile paths are relative to android/app.
val releaseStoreFile = keystoreProperties.getProperty("storeFile")
    ?.takeIf { it.isNotBlank() }?.let { file(it) }

val validateReleaseSigningConfiguration = tasks.register("validateReleaseSigningConfiguration") {
    group = "verification"
    description = "Checks release signing before compiling the app."
    doLast {
        if (useDebugSigning) {
            logger.warn("Release build uses the machine's DEBUG key for local testing. Do not publish this artifact.")
        } else {
            val problem = when {
                !keystorePropsFile.isFile -> "android/key.properties is missing."
                missingSigningProperties.isNotEmpty() ->
                    "android/key.properties is missing: ${missingSigningProperties.joinToString()}."
                releaseStoreFile?.isFile != true ->
                    "storeFile does not point to an existing keystore (relative paths start at android/app)."
                else -> null
            }
            if (problem != null) {
                throw GradleException(
                    "$problem Restore the release keystore and complete android/key.properties " +
                        "(see android/key.properties.example). For local testing only, set " +
                        "useDebugSigning=true in android/local.properties. See CONTRIBUTING.md."
                )
            }
        }
    }
}

tasks.configureEach {
    // Flutter compilation can run independently of Android's pre-build task.
    if (name in listOf("preReleaseBuild", "compileFlutterBuildRelease", "validateSigningRelease")) {
        dependsOn(validateReleaseSigningConfiguration)
    }
}

android {
    namespace = "de.astubenbord.paperless_mobile"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // Required for flutter_local_notifications
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    dependenciesInfo {
        includeInApk = false
        includeInBundle = false
    }

    defaultConfig {
        applicationId = "de.astubenbord.paperless_mobile"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // Required for flutter_local_notifications
        multiDexEnabled = true
    }

    signingConfigs {
        create("release") {
            val alias = keystoreProperties.getProperty("keyAlias")
            val keyPass = keystoreProperties.getProperty("keyPassword")
            val storePath = keystoreProperties.getProperty("storeFile")
            val storePass = keystoreProperties.getProperty("storePassword")

            if (alias != null) keyAlias = alias
            if (keyPass != null) keyPassword = keyPass
            if (!storePath.isNullOrBlank()) storeFile = releaseStoreFile
            if (storePass != null) storePassword = storePass
        }
    }

    buildTypes {
        getByName("release") {
            signingConfig = signingConfigs.getByName(if (useDebugSigning) "debug" else "release")
        }
        getByName("debug") {
            applicationIdSuffix = ".debug"
        }
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}

val abiCodes = mapOf("armeabi-v7a" to 1, "arm64-v8a" to 2, "x86_64" to 3)
android.applicationVariants.configureEach {
    val variant = this
    variant.outputs.forEach { output ->
        val abiVersionCode = abiCodes[output.filters.find { it.filterType == "ABI" }?.identifier]
        if (abiVersionCode != null) {
            (output as ApkVariantOutputImpl).versionCodeOverride = variant.versionCode * 10 + abiVersionCode
        }
    }
}
