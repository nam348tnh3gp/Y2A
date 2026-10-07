package com.nam2006.y2mate

import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject

object PipManager {
    private const val TAG = "PipManager"
    private const val MODULE = "py_runner"

    data class Result(val success: Boolean, val output: String)

    suspend fun install(pkg: String, upgrade: Boolean = false): Result =
        withContext(Dispatchers.IO) {
            try {
                val args = JSONObject().apply {
                    put("package", pkg.trim())
                    put("upgrade", upgrade)
                }.toString()
                val raw = PythonBridge.callFunction(MODULE, "install_package", args)
                val j = JSONObject(raw)
                Result(
                    success = j.optBoolean("success", false),
                    output = j.optString("output", "(không có output)"),
                )
            } catch (t: Throwable) {
                Log.e(TAG, "install fail", t)
                Result(false, "Lỗi JNI: ${t.message}")
            }
        }

    suspend fun uninstall(pkg: String): Result = withContext(Dispatchers.IO) {
        try {
            val args = JSONObject().apply { put("package", pkg.trim()) }.toString()
            val raw = PythonBridge.callFunction(MODULE, "uninstall_package", args)
            val j = JSONObject(raw)
            Result(j.optBoolean("success", false), j.optString("output", ""))
        } catch (t: Throwable) {
            Result(false, t.message ?: "uninstall fail")
        }
    }

    suspend fun list(): List<String> = withContext(Dispatchers.IO) {
        try {
            val raw = PythonBridge.callFunction(MODULE, "list_packages", "{}")
            val j = JSONObject(raw)
            if (!j.optBoolean("success", false)) return@withContext emptyList()
            val arr = j.optJSONArray("packages") ?: return@withContext emptyList()
            (0 until arr.length()).map { arr.optString(it) }.filter { it.isNotBlank() }
        } catch (t: Throwable) {
            Log.e(TAG, "list fail", t)
            emptyList()
        }
    }
}