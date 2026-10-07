package com.nam2006.y2mate

import android.app.Application
import android.util.Log
import org.apache.commons.compress.archivers.tar.TarArchiveInputStream
import java.io.File
import java.io.FileOutputStream

object PythonBridge {
    private const val TAG = "PythonBridge"
    private const val RUNTIME_TAR = "python-runtime.tar"
    private const val BRIDGE_FILE = "yt_dlp_bridge.py"
    private const val RUNNER_FILE = "py_runner.py"

    @Volatile private var initialized = false
    @Volatile private var libLoaded = false
    private var initError: String? = null

    private external fun nativeInit(
        nativeLibDir: String,
        pythonHome: String,
        filesDir: String
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
            initError = "Không load python_jni: ${t.message}"
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
            val pythonHome = File(app.filesDir, "python")
            val marker = File(pythonHome, ".extracted")

            // 1. Extract runtime tar lần đầu
            if (!marker.exists()) {
                Log.i(TAG, "⏳ Extract Python runtime (~30-60s lần đầu)...")
                extractRuntimeTar(app, pythonHome)
                marker.writeText(System.currentTimeMillis().toString())
                Log.i(TAG, "✅ Python runtime extracted")
            } else {
                Log.i(TAG, "✅ Python runtime đã có sẵn")
            }

            // 2. Copy yt_dlp_bridge.py
            val bridgeFile = File(app.filesDir, BRIDGE_FILE)
            try {
                app.assets.open(BRIDGE_FILE).use { input ->
                    FileOutputStream(bridgeFile).use { output -> input.copyTo(output) }
                }
                Log.i(TAG, "✅ ${BRIDGE_FILE} → ${bridgeFile.absolutePath}")
            } catch (e: Exception) {
                Log.w(TAG, "Không copy được $BRIDGE_FILE", e)
            }

            // 2b. Copy py_runner.py
            val runnerFile = File(app.filesDir, RUNNER_FILE)
            try {
                app.assets.open(RUNNER_FILE).use { input ->
                    FileOutputStream(runnerFile).use { output -> input.copyTo(output) }
                }
                Log.i(TAG, "✅ ${RUNNER_FILE} → ${runnerFile.absolutePath}")
            } catch (e: Exception) {
                Log.w(TAG, "Không copy được $RUNNER_FILE", e)
            }

            // 3. Call nativeInit
            Log.i(TAG, "⏳ nativeInit...")
            Log.i(TAG, "  nativeLibDir = $nativeLibDir")
            Log.i(TAG, "  pythonHome   = ${pythonHome.absolutePath}")
            Log.i(TAG, "  filesDir     = ${app.filesDir.absolutePath}")

            initialized = nativeInit(
                nativeLibDir,
                pythonHome.absolutePath,
                app.filesDir.absolutePath
            )
            Log.i(TAG, "✅ nativeInit kết quả: $initialized")

            if (!initialized) {
                initError = "nativeInit trả false (xem logcat tag PythonJNI)"
            }
            return initialized
        } catch (t: Throwable) {
            initError = t.message
            Log.e(TAG, "❌ Init fail", t)
            return false
        }
    }

    /**
     * Extract python-runtime.tar (uncompressed tar) từ assets vào filesDir/python.
     *
     * Cấu trúc tar (top-level là thư mục "lib"):
     *   lib/python3.13/os.py
     *   lib/python3.13/lib-dynload/_ssl.*.so
     *   lib/python3.13/site-packages/yt_dlp/...
     *   lib/python3.13/site-packages/pip/...
     */
    private fun extractRuntimeTar(app: Application, destDir: File) {
        destDir.mkdirs()

        app.assets.open(RUNTIME_TAR).use { input ->
            TarArchiveInputStream(input).use { tar ->
                var entry = tar.nextEntry
                var fileCount = 0

                while (entry != null) {
                    val name = entry.name.removePrefix("./")
                    if (name.isNotEmpty()) {
                        val outFile = File(destDir, name)

                        if (entry.isDirectory) {
                            outFile.mkdirs()
                        } else {
                            outFile.parentFile?.mkdirs()
                            FileOutputStream(outFile).use { output ->
                                tar.copyTo(output)
                            }
                            // Preserve executable bit
                            if (entry.mode and 0b001_000_000 != 0) {
                                outFile.setExecutable(true)
                            }
                            fileCount++
                        }
                    }
                    entry = tar.nextEntry
                }

                Log.i(TAG, "Extracted $fileCount files")
            }
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