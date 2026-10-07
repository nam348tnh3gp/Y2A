package com.nam2006.y2mate

import android.app.Application
import android.content.pm.PackageManager
import android.util.Log
import java.io.File

/**
 * Đọc metadata từ App B (plugin Repository) và ghi pip.conf cho Python.
 *
 * Nếu plugin không cài → dùng PyPI mặc định.
 * Nếu plugin cài → pip ưu tiên index của plugin trước PyPI.
 */
object RepoPlugin {
    private const val TAG = "RepoPlugin"
    private const val PLUGIN_PKG = "com.nam2006.y2mate.repo"

    data class Config(
        val installed: Boolean,
        val indexUrl: String,
        val extraIndexUrl: String,
        val trustedHost: String,
        val pluginVersion: Int,
    )

    /** Đọc metadata từ plugin nếu đã cài. Không throw. */
    fun detect(ctx: Application): Config {
        return try {
            @Suppress("DEPRECATION")
            val ai = ctx.packageManager.getApplicationInfo(
                PLUGIN_PKG,
                PackageManager.GET_META_DATA
            )
            val md = ai.metaData
            val idx = md?.getString("pip.index_url")
            val extra = md?.getString("pip.extra_index_url") ?: "https://pypi.org/simple/"
            val host = md?.getString("pip.trusted_host") ?: ""
            val ver = md?.getString("pip.plugin_version")?.toIntOrNull() ?: 1

            if (idx.isNullOrBlank()) {
                Log.w(TAG, "Plugin cài nhưng thiếu metadata pip.index_url")
                Config(false, "", extra, host, 0)
            } else {
                Log.i(TAG, "✅ Plugin detected: $idx (v$ver)")
                Config(true, idx, extra, host, ver)
            }
        } catch (_: Exception) {
            Log.i(TAG, "Plugin chưa cài")
            Config(false, "", "", "", 0)
        }
    }

    /**
     * Ghi pip.conf vào $pythonHome/pip.conf.
     * Pip tự đọc file này mỗi lần chạy.
     */
    fun writePipConf(app: Application, config: Config) {
        try {
            val pythonHome = File(app.filesDir, "python")
            if (!pythonHome.exists()) {
                Log.w(TAG, "pythonHome chưa tồn tại, bỏ qua writePipConf")
                return
            }
            val pipConf = File(pythonHome, "pip.conf")

            val content = buildString {
                appendLine("[global]")
                if (config.installed && config.indexUrl.isNotBlank()) {
                    appendLine("index-url = ${config.indexUrl}")
                    appendLine("extra-index-url = ${config.extraIndexUrl}")
                    if (config.trustedHost.isNotBlank()) {
                        appendLine("trusted-host = ${config.trustedHost}")
                    }
                } else {
                    appendLine("index-url = https://pypi.org/simple/")
                }
                appendLine("disable-pip-version-check = true")
                appendLine("no-warn-script-location = true")
                appendLine()
                appendLine("[install]")
                appendLine("no-cache-dir = false")
            }

            pipConf.writeText(content)
            Log.i(TAG, "✅ pip.conf → ${pipConf.absolutePath}")
        } catch (t: Throwable) {
            Log.e(TAG, "writePipConf fail", t)
        }
    }

    /** Xóa pip.conf (khi user gỡ plugin). */
    fun removePipConf(app: Application) {
        try {
            File(app.filesDir, "python/pip.conf").delete()
        } catch (_: Throwable) {}
    }
}