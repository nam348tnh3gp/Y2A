package com.nam2006.y2mate

import android.app.Application
import android.util.Log
import java.io.File

object PythonBridge {
    private const val TAG = "PythonBridge"
    @Volatile private var initialized = false
    private var initError: String? = null

    // Signature MỚI: 3 params (thêm filesDir)
    private external fun nativeInit(
        nativeLibDir: String,
        sitePackagesDir: String,
        filesDir: String
    ): Boolean
    private external fun nativeCallFunction(module: String, func: String, argJson: String): String
    private external fun nativeFinalize()

    init {
        System.loadLibrary("python_jni")
    }

    fun lastError(): String? = initError

    /** PHẢI gọi từ thread nền (giải nén asset + Py_Initialize rất nặng). */
    @Synchronized
    fun init(app: Application): Boolean {
        if (initialized) return true
        initError = null
        try {
            val nativeLibDir = app.applicationInfo.nativeLibraryDir
            Log.i(TAG, "nativeLibDir: $nativeLibDir")

            // Extract site-packages từ assets ra filesDir
            val sitePackages = File(app.filesDir, "site-packages")
            val marker = File(sitePackages, ".extracted")
            if (!marker.exists()) {
                Log.i(TAG, "⏳ Extract site-packages lần đầu...")
                sitePackages.mkdirs()
                copyAssetDir(app, "python/site-packages", sitePackages)
                marker.writeText("ok")
                Log.i(TAG, "✅ Extract xong")
            } else {
                Log.i(TAG, "✅ Site-packages đã có sẵn")
            }

            // Copy yt_dlp_bridge.py vào filesDir — luôn ghi đè
            val scriptFile = File(app.filesDir, "yt_dlp_bridge.py")
            app.assets.open("yt_dlp_bridge.py").use { input ->
                scriptFile.outputStream().use { input.copyTo(it) }
            }
            Log.i(TAG, "✅ Copy yt_dlp_bridge.py → ${scriptFile.absolutePath}")

            // Init Python — truyền 3 path
            Log.i(TAG, "⏳ nativeInit...")
            initialized = nativeInit(
                nativeLibDir,
                sitePackages.absolutePath,
                app.filesDir.absolutePath
            )
            Log.i(TAG, "✅ nativeInit kết quả: $initialized")

            if (!initialized) {
                initError = "nativeInit thất bại (xem logcat tag PythonJNI)"
            }
            return initialized
        } catch (t: Throwable) {
            initError = t.message
            Log.e(TAG, "❌ Init fail", t)
            return false
        }
    }

    private fun copyAssetDir(app: Application, assetPath: String, dest: File) {
        val children = app.assets.list(assetPath) ?: return
        if (children.isEmpty()) {
            dest.parentFile?.mkdirs()
            app.assets.open(assetPath).use { input ->
                dest.outputStream().use { input.copyTo(it) }
            }
            return
        }
        dest.mkdirs()
        for (child in children) {
            copyAssetDir(app, "$assetPath/$child", File(dest, child))
        }
    }

    fun callFunction(module: String, func: String, argJson: String): String {
        if (!initialized) {
            return """{"success":false,"error":"Python chưa init: ${initError ?: "unknown"}"}"""
        }
        return nativeCallFunction(module, func, argJson)
    }

    fun isInitialized(): Boolean = initialized

    fun finalize() {
        if (initialized) {
            nativeFinalize()
            initialized = false
        }
    }
}