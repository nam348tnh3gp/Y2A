plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("com.chaquo.python")
}

// Đọc version code từ versioncode.txt ở root repo.
// CI workflow sẽ tự động bump file này mỗi lần build.
// Nếu file chưa tồn tại (build local lần đầu), dùng mặc định là 1.
val versionCodeFromFile: Int = run {
    val f = rootProject.file("versioncode.txt")
    if (f.exists()) {
        f.readText().trim().toIntOrNull()?.coerceAtLeast(1) ?: 1
    } else {
        1
    }
}

android {
    namespace = "com.nam2006.y2mate"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.nam2006.y2mate"
        minSdk = 29
        targetSdk = 34

        // Version code đọc từ file, được CI bump tự động
        versionCode = versionCodeFromFile
        // versionName theo versionCode để dễ nhìn trong Settings → About
        versionName = "1.0.$versionCodeFromFile"

        ndk {
            abiFilters += listOf("arm64-v8a")
        }

        externalNativeBuild {
            cmake {
                cppFlags += "-std=c++17"
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures { compose = true }

    // Build JNI từ CMake
    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    // Đảm bảo Gradle pick up jniLibs và assets
    sourceSets {
        getByName("main") {
            jniLibs.srcDirs("src/main/jniLibs")
            assets.srcDirs("src/main/assets")
        }
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
            // Tránh conflict nếu có nhiều lib cùng tên
            pickFirsts += listOf(
                "**/libffmpeg.so",
                "**/libffprobe.so"
            )
        }
    }

    androidResources {
        // Không nén các file binary trong assets (cần cho extract runtime)
        noCompress += listOf("zip", "so", "ffmpeg", "ffprobe")
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
            }
        }
    }
}

dependencies {
    implementation(platform("androidx.compose:compose-bom:2024.10.01"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    implementation("io.coil-kt:coil-compose:2.7.0")
}