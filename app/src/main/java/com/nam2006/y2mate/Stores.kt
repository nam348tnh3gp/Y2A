package com.nam2006.y2mate

import android.content.Context
import android.net.Uri
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

object HistoryStore {
    private fun prefs(ctx: Context) = ctx.getSharedPreferences("history", Context.MODE_PRIVATE)

    fun load(ctx: Context): List<HistoryItem> {
        val raw = prefs(ctx).getString("items", "[]") ?: "[]"
        val arr = try { JSONArray(raw) } catch (e: Exception) { JSONArray() }
        val out = ArrayList<HistoryItem>()
        for (i in 0 until arr.length()) {
            val o = arr.optJSONObject(i) ?: continue
            out.add(HistoryItem(o.optString("url"), o.optString("name"), o.optString("uri"), o.optLong("ts")))
        }
        return out
    }

    private fun save(ctx: Context, items: List<HistoryItem>) {
        val arr = JSONArray()
        for (h in items) {
            val o = JSONObject()
            o.put("url", h.url)
            o.put("name", h.name)
            o.put("uri", h.uri)
            o.put("ts", h.ts)
            arr.put(o)
        }
        prefs(ctx).edit().putString("items", arr.toString()).apply()
    }

    fun add(ctx: Context, items: List<HistoryItem>) {
        save(ctx, (items + load(ctx)).take(40))
    }

    fun clear(ctx: Context) {
        prefs(ctx).edit().remove("items").apply()
    }
}

object CookieStore {
    fun file(ctx: Context): File = File(ctx.filesDir, "cookies.txt")

    fun has(ctx: Context): Boolean {
        val f = file(ctx)
        return f.exists() && f.length() > 0
    }

    /**
     * Import cookies — hỗ trợ cả 2 định dạng:
     * - Netscape cookies.txt (giữ nguyên)
     * - JSON từ Cookie-Editor / EditThisCookie (tự convert sang Netscape)
     */
    fun import(ctx: Context, uri: Uri): Boolean {
        return try {
            val raw = ctx.contentResolver.openInputStream(uri)?.use { ins ->
                ins.bufferedReader().readText()
            } ?: return false

            val trimmed = raw.trim()
            val netscape = if (trimmed.startsWith("{")) {
                convertJsonToNetscape(trimmed)
            } else {
                trimmed
            }

            if (netscape.isNullOrBlank()) return false

            file(ctx).writeText(netscape)
            true
        } catch (e: Exception) {
            false
        }
    }

    /**
     * Convert JSON (Cookie-Editor format) → Netscape cookies.txt.
     *
     * JSON format:
     *   {"cookies":[{"name":"X","value":"Y","domain":".youtube.com",
     *                "path":"/","secure":true,"expirationDate":1793456789},...]}
     *
     * Netscape format (7 cột, phân cách bằng TAB):
     *   domain  flag  path  secure  expiry  name  value
     */
    private fun convertJsonToNetscape(jsonStr: String): String? {
        return try {
            val root = JSONObject(jsonStr)
            val cookies = root.optJSONArray("cookies") ?: return null
            val sb = StringBuilder()
            sb.append("# Netscape HTTP Cookie File\n")
            sb.append("# Converted from JSON by Mini-Y2mate\n\n")

            for (i in 0 until cookies.length()) {
                val c = cookies.optJSONObject(i) ?: continue

                val domain = c.optString("domain", "")
                if (domain.isEmpty()) continue

                val name = c.optString("name", "")
                val value = c.optString("value", "")
                if (name.isEmpty()) continue

                // flag = TRUE nếu domain bắt đầu bằng "." (subdomain match)
                val flag = if (domain.startsWith(".")) "TRUE" else "FALSE"

                val path = c.optString("path", "/").ifEmpty { "/" }

                // secure: JSON có thể là boolean hoặc string
                val secureBool = when {
                    c.has("secure") -> c.optBoolean("secure", false)
                    c.has("isSecure") -> c.optBoolean("isSecure", false)
                    else -> false
                }
                val secure = if (secureBool) "TRUE" else "FALSE"

                // expiry: JSON có thể là "expirationDate" (double), "expiry" (long), hoặc không có
                val expiry = when {
                    c.has("expirationDate") -> c.optDouble("expirationDate", 0.0).toLong()
                    c.has("expiry") -> c.optLong("expiry", 0L)
                    else -> 0L  // session cookie
                }

                // 7 cột Netscape, phân cách bằng TAB
                sb.append(domain).append('\t')
                    .append(flag).append('\t')
                    .append(path).append('\t')
                    .append(secure).append('\t')
                    .append(expiry).append('\t')
                    .append(name).append('\t')
                    .append(value).append('\n')
            }

            val result = sb.toString()
            // Kiểm tra có ít nhất 1 cookie được convert không
            if (result.lines().count { it.contains('\t') } == 0) null else result
        } catch (e: Exception) {
            null
        }
    }

    fun clear(ctx: Context) {
        file(ctx).delete()
    }
}