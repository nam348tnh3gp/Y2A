plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("com.chaquo.python")
}

val versionCodeFromFile: Int = run {
    val f = rootProject.file("versioncode.txt")
    if (f.exists()) f.readText().trim().toIntOrNull()?.coerceAtLeast(1) ?: 1 else 1
}

android {
    namespace = "com.nam2006.y2mate"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.nam2006.y2mate"
        minSdk = 29
        targetSdk = 34
        versionCode = versionCodeFromFile
        versionName = "1.0.$versionCodeFromFile"

        ndk { abiFilters += listOf("arm64-v8a") }

        externalNativeBuild {
            cmake { cppFlags += "-std=c++17" }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures {
        compose = true
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    sourceSets {
        getByName("main") {
            jniLibs.srcDirs("src/main/jniLibs")
            assets.srcDirs("src/main/assets")
        }
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
            pickFirsts += listOf(
                "**/libffmpeg.so",
                "**/libffprobe.so",
                "**/libc++_shared.so"
            )
        }
    }

    androidResources {
        noCompress += listOf("py", "pyc", "so", "zip", "dat")
    }

    lint {
        abortOnError = false
        checkReleaseBuilds = false
    }

    chaquopy {
        defaultConfig {
            version = "3.11"
            pip {
                install("yt-dlp")
                install("certifi")
            }
        }
    }
}

dependencies {
    // BOM
    implementation(platform("androidx.compose:compose-bom:2024.10.01"))

    // Compose core
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material3:material3-window-size-class")
    implementation("androidx.compose.material:material-icons-extended")

    // Animations
    implementation("androidx.compose.animation:animation")
    implementation("androidx.compose.animation:animation-graphics")

    // Activity + Lifecycle
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")

    // Core
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.core:core-splashscreen:1.0.1")

    // Coroutines
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")

    // Image
    implementation("io.coil-kt:coil-compose:2.7.0")

    // Debug
    debugImplementation("androidx.compose.ui:ui-tooling")
}