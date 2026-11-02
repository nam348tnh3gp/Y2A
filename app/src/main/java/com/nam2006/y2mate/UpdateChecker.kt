package com.nam2006.y2mate

import android.app.DownloadManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import androidx.core.content.FileProvider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

object UpdateChecker {
    private const val UPDATE_JSON = "https://nam348tnh3gp.github.io/Y2A/update.json"
    private const val API = "https://api.github.com/repos/nam348tnh3gp/Y2A/releases/latest"
    private const val VERSION_URL = "https://raw.githubusercontent.com/nam348tnh3gp/Y2A/main/versioncode.txt"

    data class UpdateInfo(
        val versionCode: Int,
        val tag: String,
        val apkUrl: String?,
        val body: String
    )

    suspend fun check(context: Context): UpdateInfo? = withContext(Dispatchers.IO) {
        val current = try {
            context.packageManager.getPackageInfo(context.packageName, 0).longVersionCode.toInt()
        } catch (_: Exception) { 0 }

        // 1. Ưu tiên file update.json trên GitHub Pages
        try {
            val conn = URL(UPDATE_JSON).openConnection() as HttpURLConnection
            conn.connectTimeout = 10000
            conn.readTimeout = 10000
            conn.setRequestProperty("User-Agent", "Y2A-UpdateChecker")
            if (conn.responseCode == 200) {
                val json = JSONObject(conn.inputStream.bufferedReader().use { it.readText() })
                val ver = json.optInt("versionCode", 0)
                val tag = json.optString("tag", "v$ver")
                val apk = json.optString("apkUrl", "").ifBlank { null }
                val notes = json.optString("notes", "")
                if (ver > current && apk != null) {
                    return@withContext UpdateInfo(ver, tag, apk, notes)
                }
            }
        } catch (_: Exception) { }

        // 2. Fallback GitHub Release
        try {
            val conn = URL(API).openConnection() as HttpURLConnection
            conn.setRequestProperty("Accept", "application/vnd.github+json")
            conn.setRequestProperty("User-Agent", "Y2A-UpdateChecker")
            conn.connectTimeout = 12000
            conn.readTimeout = 12000
            if (conn.responseCode == 200) {
                val json = JSONObject(conn.inputStream.bufferedReader().use { it.readText() })
                val tag = json.optString("tag_name", "")
                val ver = tag.removePrefix("v").toIntOrNull() ?: 0
                val assets = json.optJSONArray("assets")
                var apk: String? = null
                if (assets != null) {
                    for (i in 0 until assets.length()) {
                        val a = assets.getJSONObject(i)
                        val name = a.optString("name", "")
                        if (name.endsWith(".apk", true)) {
                            apk = a.optString("browser_download_url")
                            break
                        }
                    }
                }
                val body = json.optString("body", "")
                if (ver > current && apk != null) {
                    return@withContext UpdateInfo(ver, tag, apk, body)
                }
            }
        } catch (_: Exception) { }

        // Fallback: versioncode.txt trên main
        try {
            val conn = URL(VERSION_URL).openConnection() as HttpURLConnection
            conn.connectTimeout = 10000
            conn.readTimeout = 10000
            if (conn.responseCode == 200) {
                val ver = conn.inputStream.bufferedReader().use { it.readText() }.trim().toIntOrNull() ?: 0
                if (ver > current) {
                    return@withContext UpdateInfo(ver, "v$ver", null, "Có bản mới trên main (chưa có Release APK)")
                }
            }
        } catch (_: Exception) { }

        null
    }

    fun downloadAndInstall(context: Context, apkUrl: String, versionCode: Int) {
        val dm = context.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
        val req = DownloadManager.Request(Uri.parse(apkUrl))
            .setTitle("Mini-Y2mate Pro v$versionCode")
            .setDescription("Đang tải bản cập nhật...")
            .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
            .setDestinationInExternalPublicDir(Environment.DIRECTORY_DOWNLOADS, "Y2A-v$versionCode.apk")
            .setMimeType("application/vnd.android.package-archive")
        val id = dm.enqueue(req)

        // Lắng nghe hoàn tất để mở installer
        Thread {
            var done = false
            while (!done) {
                Thread.sleep(1500)
                val q = DownloadManager.Query().setFilterById(id)
                dm.query(q)?.use { c ->
                    if (c.moveToFirst()) {
                        val status = c.getInt(c.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS))
                        if (status == DownloadManager.STATUS_SUCCESSFUL) {
                            val local = c.getString(c.getColumnIndexOrThrow(DownloadManager.COLUMN_LOCAL_URI))
                            done = true
                            openInstaller(context, local)
                        } else if (status == DownloadManager.STATUS_FAILED) {
                            done = true
                        }
                    }
                }
            }
        }.start()
    }

    private fun openInstaller(context: Context, localUri: String?) {
        try {
            val uri = Uri.parse(localUri ?: return)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            context.startActivity(intent)
        } catch (_: Exception) { }
    }
}
