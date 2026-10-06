package com.nam2006.y2mate

import android.app.Application

class App : Application() {
    override fun onCreate() {
        super.onCreate()
        // KHÔNG chạy việc nặng trên main thread: giải nén site-packages + Py_Initialize
        // + giải nén FFmpeg đều nằm trong Downloader.init (chạy nền, Dispatchers.IO).
        Downloader.init(this)
    }
}