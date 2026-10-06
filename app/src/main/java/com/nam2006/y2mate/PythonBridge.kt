package com.nam2006.y2mate

import android.app.Application
import android.content.res.AssetManager
import android.util.Log
import java.io.File

object PythonBridge {
    private const val TAG = "PythonBridge"
    @Volatile private var initialized = false
    @Volatile private var libLoaded = false
    private var initError: String? = null

    private external fun nativeInit(
        nativeLibDir: String,
        sitePackagesDir: String,
        filesDir: String,
        assetManager: AssetManager
    ): Boolean
    private external fun nativeCallFunction(module: String, func: String, argJson: String): String
    private external fun nativeFinalize()

    @Synchronized
    private fun ensureLib(): Boolean {
        if (libLoaded) return true
        return try {
            System.loadLibrary("python_jni")
            libLoaded = true
            Log.i(TAG, "✅ python_jni loaded")
            true
        } catch (t: Throwable) {
            initError = "Không load được python_jni: ${t.message}"
            Log.e(TAG, "loadLibrary fail", t)
            false
        }
    }

    fun lastError(): String? = initError
    fun isInitialized(): Boolean = initialized

    @Synchronized
    fun init(app: Application): Boolean {
        if (initialized) return true
        initError = null
        if (!ensureLib()) return false

        try {
            val nativeLibDir = app.applicationInfo.nativeLibraryDir
            Log.i(TAG, "nativeLibDir: $nativeLibDir")

            // Extract site-packages folder (không phải zip)
            val sitePackages = File(app.filesDir, "site-packages")
            val marker = File(sitePackages, ".extracted")
            if (!marker.exists()) {
                Log.i(TAG, "⏳ Extract site-packages...")
                sitePackages.mkdirs()
                copyAssetDir(app, "python/site-packages", sitePackages)
                marker.writeText("ok")
                Log.i(TAG, "✅ site-packages extracted")
            } else {
                Log.i(TAG, "✅ site-packages cached")
            }

            // Copy yt_dlp_bridge.py
            val scriptFile = File(app.filesDir, "yt_dlp_bridge.py")
            try {
                app.assets.open("yt_dlp_bridge.py").use { input ->
                    scriptFile.outputStream().use { input.copyTo(it) }
                }
                Log.i(TAG, "✅ yt_dlp_bridge.py copied")
            } catch (e: Exception) {
                Log.w(TAG, "Copy bridge failed", e)
            }

            Log.i(TAG, "⏳ nativeInit...")
            initialized = nativeInit(
                nativeLibDir,
                sitePackages.absolutePath,
                app.filesDir.absolutePath,
                app.assets
            )
            Log.i(TAG, "✅ nativeInit: $initialized")
            if (!initialized) initError = "nativeInit failed"
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
        if (!initialized || !libLoaded) {
            return """{"success":false,"error":"Python chưa init: ${initError ?: "unknown"}"}"""
        }
        return try {
            nativeCallFunction(module, func, argJson)
        } catch (t: Throwable) {
            Log.e(TAG, "callFunction fail", t)
            """{"success":false,"error":"${t.message?.replace("\"", "'") ?: "unknown"}"}"""
        }
    }

    fun finalize() {
        if (initialized && libLoaded) {
            try { nativeFinalize() } catch (_: Throwable) {}
            initialized = false
        }
    }
}