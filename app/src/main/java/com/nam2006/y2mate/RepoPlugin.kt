package com.nam2006.y2mate

import android.app.Application
import android.content.pm.PackageManager
import android.util.Log
import java.io.File

object RepoPlugin {
    private const val TAG = "RepoPlugin"
    private const val PLUGIN_PKG = "com.nam2006.y2mate.repo"

    // Fallback khi chưa cài plugin
    private const val DEFAULT_INDEX = "https://nam348tnh3gp.github.io/Y2A/simple/"
    private const val DEFAULT_EXTRA_1 = "https://pypi.flet.dev/simple/"
    private const val DEFAULT_EXTRA_2 = "https://pypi.org/simple/"
    private const val DEFAULT_HOST = "nam348tnh3gp.github.io"

    data class Config(
        val installed: Boolean,
        val indexUrl: String,
        val extraIndexUrl: String,
        val extraIndexUrl2: String,
        val trustedHost: String,
        val pluginVersion: Int,
    )

    fun detect(ctx: Application): Config {
        return try {
            @Suppress("DEPRECATION")
            val ai = ctx.packageManager.getApplicationInfo(
                PLUGIN_PKG,
                PackageManager.GET_META_DATA
            )
            val md = ai.metaData
            val idx = md?.getString("pip.index_url")
            val extra1 = md?.getString("pip.extra_index_url") ?: DEFAULT_EXTRA_1
            val extra2 = md?.getString("pip.extra_index_url_2") ?: DEFAULT_EXTRA_2
            val host = md?.getString("pip.trusted_host") ?: DEFAULT_HOST
            val ver = md?.getString("pip.plugin_version")?.toIntOrNull() ?: 2

            if (idx.isNullOrBlank()) {
                Log.w(TAG, "Plugin cài nhưng thiếu metadata pip.index_url")
                Config(false, DEFAULT_INDEX, extra1, extra2, host, 0)
            } else {
                Log.i(TAG, "✅ Plugin detected: $idx (v$ver)")
                Config(true, idx, extra1, extra2, host, ver)
            }
        } catch (_: Exception) {
            Log.i(TAG, "Plugin chưa cài — dùng default index")
            Config(false, DEFAULT_INDEX, DEFAULT_EXTRA_1, DEFAULT_EXTRA_2, DEFAULT_HOST, 0)
        }
    }

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
                appendLine("index-url = ${config.indexUrl}")
                appendLine("extra-index-url = ${config.extraIndexUrl}")
                if (config.extraIndexUrl2.isNotBlank()) {
                    // Pip hỗ trợ nhiều extra-index-url cách nhau newline + indent
                    appendLine("                  ${config.extraIndexUrl2}")
                }
                if (config.trustedHost.isNotBlank()) {
                    appendLine("trusted-host = ${config.trustedHost}")
                }
                appendLine("disable-pip-version-check = true")
                appendLine("no-warn-script-location = true")
                appendLine("prefer-binary = true")
                appendLine()
                appendLine("[install]")
                appendLine("no-cache-dir = false")
            }

            pipConf.writeText(content)
            Log.i(TAG, "✅ pip.conf → ${pipConf.absolutePath}")
            Log.i(TAG, "  index-url: ${config.indexUrl}")
            Log.i(TAG, "  extra-1  : ${config.extraIndexUrl}")
            Log.i(TAG, "  extra-2  : ${config.extraIndexUrl2}")
        } catch (t: Throwable) {
            Log.e(TAG, "writePipConf fail", t)
        }
    }

    fun removePipConf(app: Application) {
        try {
            File(app.filesDir, "python/pip.conf").delete()
        } catch (_: Throwable) {}
    }
}