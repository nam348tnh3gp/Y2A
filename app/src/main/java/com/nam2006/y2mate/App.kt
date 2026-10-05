package com.nam2006.y2mate

import android.app.Application
import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform

class App : Application() {
    override fun onCreate() {
        super.onCreate()
        // Khởi tạo Python runtime
        if (!Python.isStarted()) {
            Python.start(AndroidPlatform(this))
        }
        // Khởi tạo Downloader
        Downloader.init(this)
    }
}