package com.nam2006.y2mate

import android.util.Log
import java.io.File

/**
 * Bridge giữa Kotlin và Python runtime (flet-dev/python-build).
 * Thay thế Chaquopy.
 */
object PythonBridge {
    private const val TAG = "PythonBridge"
    private const val PY_VERSION = "3.14"

    @Volatile private var initialized = false
    private var initError: String? = null

    // JNI methods
    private external fun nativeInit(pythonHome: String): Boolean
    private external fun nativeRun(codeOrPath: String): String
    private external fun nativeCallFunction(module: String, func: String, argJson: String): String
    private external fun nativeFinalize()

    init {
        System.loadLibrary("python_jni")
        System.loadLibrary("python3.14")
    }

    /**
     * Khởi tạo Python. Extract stdlib từ assets ra filesDir nếu chưa có.
     */
    fun init(app: android.app.Application): Boolean {
        if (initialized) return true

        try {
            val pythonHome = extractRuntime(app)
            Log.i(TAG, "Python home: $pythonHome")

            // Thêm thư mục chứa yt_dlp_bridge.py vào PYTHONPATH
            val scriptDir = File(pythonHome, "scripts")
            scriptDir.mkdirs()
            // Copy yt_dlp_bridge.py từ assets
            copyAssetFile(app, "yt_dlp_bridge.py", File(scriptDir, "yt_dlp_bridge.py"))

            initialized = nativeInit(pythonHome)

            if (initialized) {
                // Thêm script dir vào sys.path
                nativeRun(
                    "import sys\n" +
                    "sys.path.insert(0, r'${scriptDir.absolutePath}')\n"
                )
            }

            return initialized
        } catch (t: Throwable) {
            initError = t.message
            Log.e(TAG, "Init failed", t)
            return false
        }
    }

    /**
     * Extract Python runtime từ assets vào filesDir (1 lần duy nhất).
     */
    private fun extractRuntime(app: android.app.Application): String {
        val destDir = File(app.filesDir, "python$PY_VERSION")
        val marker = File(destDir, ".extracted")

        if (marker.exists()) {
            return destDir.absolutePath
        }

        Log.i(TAG, "Đang extract Python runtime lần đầu...")
        destDir.mkdirs()

        // Extract toàn bộ assets/python/python3.14/ → filesDir/python3.14/
        copyAssetDir(app, "python/python$PY_VERSION", destDir)

        marker.writeText("ok")
        Log.i(TAG, "✅ Đã extract Python runtime")

        return destDir.absolutePath
    }

    private fun copyAssetDir(app: android.app.Application, assetPath: String, dest: File) {
        val children = app.assets.list(assetPath) ?: return
        if (children.isEmpty()) {
            // Là file, không phải dir
            copyAssetFile(app, assetPath, dest)
            return
        }
        dest.mkdirs()
        for (child in children) {
            copyAssetDir(app, "$assetPath/$child", File(dest, child))
        }
    }

    private fun copyAssetFile(app: android.app.Application, assetPath: String, dest: File) {
        dest.parentFile?.mkdirs()
        app.assets.open(assetPath).use { input ->
            dest.outputStream().use { output -> input.copyTo(output) }
        }
    }

    /**
     * Gọi hàm Python với JSON argument, trả về JSON string.
     */
    fun callFunction(module: String, func: String, argJson: String): String {
        if (!initialized) {
            return """{"success":false,"error":"Python chưa khởi tạo: ${initError ?: "unknown"}"}"""
        }
        return nativeCallFunction(module, func, argJson)
    }

    /**
     * Chạy code Python trực tiếp.
     */
    fun run(code: String): String {
        if (!initialized) return "ERROR: Python chưa khởi tạo"
        return nativeRun(code)
    }

    fun isInitialized(): Boolean = initialized

    fun finalize() {
        if (initialized) {
            nativeFinalize()
            initialized = false
        }
    }
}