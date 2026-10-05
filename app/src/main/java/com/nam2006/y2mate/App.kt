package com.nam2006.y2mate

import android.app.Application

class App : Application() {
    override fun onCreate() {
        super.onCreate()
        // Giải nén Python + yt-dlp + FFmpeg ở nền (lần đầu mất vài giây)
        Downloader.init(this)
    }
}