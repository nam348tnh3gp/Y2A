package com.nam2006.y2mate

import android.app.Application
import android.content.res.AssetManager
import android.util.Log
import java.io.File

object PythonBridge {
    private const val TAG = "PythonBridge"
    @Volatile private var initialized = false
    private var initError: String? = null

    // Signature JNI mới: thêm AssetManager
    private external fun nativeInit(
        nativeLibDir: String,
        sitePackagesDir: String,
        filesDir: String,
        assetManager: AssetManager
    ): Boolean
    private external fun nativeCallFunction(module: String, func: String, argJson: String): String
    private external fun nativeFinalize()

    init {
        System.loadLibrary("python_jni")
    }

    fun lastError(): String? = initError

    @Synchronized
    fun init(app: Application): Boolean {
        if (initialized) return true
        initError = null
        try {
            val nativeLibDir = app.applicationInfo.nativeLibraryDir
            val sitePackages = File(app.filesDir, "site-packages")
            sitePackages.mkdirs()

            initialized = nativeInit(
                nativeLibDir,
                sitePackages.absolutePath,
                app.filesDir.absolutePath,
                app.assets
            )
            if (!initialized) {
                initError = "nativeInit thất bại (xem logcat tag PythonJNI)"
            }
            return initialized
        } catch (t: Throwable) {
            initError = t.message
            Log.e(TAG, "Init fail", t)
            return false
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