plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

val youtubedlAndroid = "0.18.1"

android {
    namespace = "com.nam2006.y2mate"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.nam2006.y2mate"
        minSdk = 29
        targetSdk = 34
        versionCode = 1
        versionName = "1.0"
        // Thư viện yt-dlp + Python + FFmpeg có sẵn mã native cho từng kiến trúc CPU.
        // Chỉ cần arm64-v8a nếu điện thoại của bạn là máy đời mới (từ ~2017) để APK nhẹ hơn.
        ndk { abiFilters += listOf("arm64-v8a", "armeabi-v7a") }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            // Ký bằng khóa debug để cài trực tiếp (sideload). Không dùng để đưa lên Google Play.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures { compose = true }

    // Bắt buộc với youtubedl-android: giải nén thư viện .so khi cài
    packaging { jniLibs { useLegacyPackaging = true } }

    lint {
        abortOnError = false
        checkReleaseBuilds = false
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

    implementation("io.github.junkfood02.youtubedl-android:library:$youtubedlAndroid")
    implementation("io.github.junkfood02.youtubedl-android:ffmpeg:$youtubedlAndroid")
}
