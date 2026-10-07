package com.nam2006.y2mate

import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject

object PythonRunner {
    private const val TAG = "PythonRunner"
    private const val MODULE = "py_runner"

    data class Result(val success: Boolean, val output: String)

    suspend fun runCode(code: String): Result = withContext(Dispatchers.IO) {
        try {
            val args = JSONObject().apply { put("code", code) }.toString()
            val raw = PythonBridge.callFunction(MODULE, "run_code", args)
            val j = JSONObject(raw)
            Result(
                success = j.optBoolean("success", false),
                output = j.optString("output", "(không có output)"),
            )
        } catch (t: Throwable) {
            Log.e(TAG, "runCode fail", t)
            Result(false, "Lỗi JNI: ${t.message}")
        }
    }

    suspend fun resetNamespace(): Result = withContext(Dispatchers.IO) {
        try {
            val raw = PythonBridge.callFunction(MODULE, "reset_namespace", "{}")
            val j = JSONObject(raw)
            Result(j.optBoolean("success", false), j.optString("output", ""))
        } catch (t: Throwable) {
            Result(false, t.message ?: "reset fail")
        }
    }

    suspend fun checkImport(module: String): Result = withContext(Dispatchers.IO) {
        try {
            val args = JSONObject().apply { put("module", module) }.toString()
            val raw = PythonBridge.callFunction(MODULE, "check_import", args)
            val j = JSONObject(raw)
            Result(j.optBoolean("success", false), j.optString("output", ""))
        } catch (t: Throwable) {
            Result(false, t.message ?: "check fail")
        }
    }

    suspend fun envInfo(): Map<String, String>? = withContext(Dispatchers.IO) {
        try {
            val raw = PythonBridge.callFunction(MODULE, "env_info", "{}")
            val j = JSONObject(raw)
            if (!j.optBoolean("success", false)) return@withContext null
            val info = j.optJSONObject("info") ?: return@withContext null
            val map = HashMap<String, String>()
            val keys = info.keys()
            while (keys.hasNext()) {
                val k = keys.next()
                map[k] = info.get(k).toString()
            }
            map
        } catch (t: Throwable) {
            null
        }
    }
}