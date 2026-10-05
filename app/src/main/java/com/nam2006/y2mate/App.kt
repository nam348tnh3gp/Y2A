package com.nam2006.y2mate

import android.app.Application
import android.util.Log
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLException

class App : Application() {
    override fun onCreate() {
        super.onCreate()
        try {
            // Khởi tạo yt-dlp (thư viện mới) — tương thích ngược qua gói compat
            YoutubeDL.getInstance().init(this)
            // Khởi tạo FFmpeg và các thành phần khác của app
            Downloader.init(this)
        } catch (e: YoutubeDLException) {
            Log.e("App", "Không khởi tạo được yt-dlp", e)
        }
    }
}