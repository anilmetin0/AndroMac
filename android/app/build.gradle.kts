plugins {
    id("com.android.application")
}

// Version, build number and commit come from CI (.github/workflows/build.yml).
// Local builds are "<VERSION>" (the VERSION file) / build 1 / commit "local".
val andromacVersion = (project.findProperty("andromacVersion") as String?) ?: rootDir.resolveSibling("VERSION").readText().trim()
val andromacBuild = (project.findProperty("andromacBuild") as String?)?.toIntOrNull() ?: 1
val andromacCommit = (project.findProperty("andromacCommit") as String?) ?: "local"

android {
    namespace = "dev.andromac"
    compileSdk = 37

    defaultConfig {
        applicationId = "dev.andromac"
        minSdk = 29          // Android 10. NsdManager + FGS types + modern crypto.
        targetSdk = 37
        versionCode = andromacBuild
        versionName = andromacVersion
        resValue("string", "build_commit", andromacCommit)
    }

    // Permanent signing key from environment variables (CI secrets or the output of
    // scripts/setup-android-signing.sh). Without it the release build is signed with the
    // debug key: still installable, but updates across versions need a permanent key.
    signingConfigs {
        System.getenv("ANDROID_KEYSTORE_PATH")?.takeIf { it.isNotBlank() }?.let { path ->
            create("release") {
                storeFile = file(path)
                storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("ANDROID_KEY_ALIAS")
                keyPassword = System.getenv("ANDROID_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
        }
        debug { applicationIdSuffix = ".debug" }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
    }

    buildFeatures { resValues = true }
}

// No dependencies: org.json, javax.crypto and NsdManager all ship with the platform.
dependencies { }
