package com.nam2006.y2mate

import android.app.Application
import android.util.Log
import java.io.File

object PythonBridge {
    private const val TAG = "PythonBridge"
    @Volatile private var initialized = false
    private var initError: String? = null

    // JNI — signature mới: (nativeLibDir, sitePackagesDir)
    private external fun nativeInit(nativeLibDir: String, sitePackagesDir: String): Boolean
    private external fun nativeCallFunction(module: String, func: String, argJson: String): String
    private external fun nativeFinalize()

    init {
        System.loadLibrary("python_jni")
    }

    fun init(app: Application): Boolean {
        if (initialized) return true
        try {
            // nativeLibDir chứa libpython3.14.so (Android tự extract)
            val nativeLibDir = app.applicationInfo.nativeLibraryDir
            Log.i(TAG, "nativeLibDir: $nativeLibDir")

            // Extract site-packages từ assets ra filesDir
            val sitePackages = File(app.filesDir, "site-packages")
            val marker = File(sitePackages, ".extracted")
            if (!marker.exists()) {
                Log.i(TAG, "Extract site-packages...")
                sitePackages.mkdirs()
                copyAssetDir(app, "python/site-packages", sitePackages)
                marker.writeText("ok")
            }

            // Copy yt_dlp_bridge.py vào filesDir
            val scriptFile = File(app.filesDir, "yt_dlp_bridge.py")
            if (!scriptFile.exists()) {
                app.assets.open("yt_dlp_bridge.py").use { input ->
                    scriptFile.outputStream().use { input.copyTo(it) }
                }
            }

            // Init Python
            initialized = nativeInit(nativeLibDir, sitePackages.absolutePath)

            if (initialized) {
                // Thêm filesDir vào sys.path để import yt_dlp_bridge
                // (Python code tự thêm thông qua sys.path.insert trong nativeInit,
                //  nhưng ta cần thêm filesDir nữa)
                // Đã làm trong nativeInit, ở đây không cần
                Log.i(TAG, "✅ Python initialized")
            }
            return initialized
        } catch (t: Throwable) {
            initError = t.message
            Log.e(TAG, "Init fail", t)
            return false
        }
    }

    private fun copyAssetDir(app: Application, assetPath: String, dest: File) {
        val children = app.assets.list(assetPath) ?: return
        if (children.isEmpty()) {
            // Là file
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