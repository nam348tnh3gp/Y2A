package com.nam2006.y2mate

import android.app.Application
import android.util.Log
import com.ffmpegkit.ytdlp.YtDlp
import com.ffmpegkit.ytdlp.YtDlpException

class App : Application() {
    override fun onCreate() {
        super.onCreate()
        try {
            YtDlp.init(this)
            Downloader.init(this)
        } catch (e: YtDlpException) {
            Log.e("App", "Không khởi tạo được yt-dlp", e)
        }
    }
}