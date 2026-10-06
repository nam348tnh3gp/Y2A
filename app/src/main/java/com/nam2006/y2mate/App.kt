package com.nam2006.y2mate

import android.app.Application

class App : Application() {
    override fun onCreate() {
        super.onCreate()
        // Khởi tạo Python runtime (thay Chaquopy)
        PythonBridge.init(this)
        // Khởi tạo Downloader (FFmpeg + các thứ khác)
        Downloader.init(this)
    }
}