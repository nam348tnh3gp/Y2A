package com.nam2006.y2mate

import android.content.Context
import android.net.Uri
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

// ============================================================
// HISTORY STORE — không đổi
// ============================================================
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

// ============================================================
// COOKIE STORE — parser mạnh, hỗ trợ nhiều định dạng
// ============================================================
object CookieStore {
    private const val TAG = "CookieStore"

    // Session cookie mặc định sống 1 năm nếu JSON không cung cấp expiry
    private const val DEFAULT_EXPIRY_SECONDS = 365L * 24 * 60 * 60

    // Các prefix bắt buộc secure theo RFC 6265bis
    private val SECURE_PREFIXES = listOf("__Secure-", "__Host-")

    fun file(ctx: Context): File = File(ctx.filesDir, "cookies.txt")

    fun has(ctx: Context): Boolean {
        val f = file(ctx)
        return f.exists() && f.length() > 0
    }

    /**
     * Import cookies. Tự phát hiện định dạng:
     * - JSON: bắt đầu bằng `{` (Cookie-Editor v1/v2, EditThisCookie)
     * - Netscape: còn lại (cookies.txt từ extension)
     *
     * Trả về true nếu import thành công.
     */
    fun import(ctx: Context, uri: Uri): Boolean {
        return try {
            val raw = ctx.contentResolver.openInputStream(uri)?.use { ins ->
                ins.bufferedReader().readText()
            } ?: return false

            val trimmed = raw.trim()
            val netscape = if (trimmed.startsWith("{")) {
                Log.i(TAG, "Phát hiện định dạng JSON — đang convert sang Netscape")
                convertJsonToNetscape(trimmed)
            } else if (trimmed.startsWith("#") || trimmed.contains("\t")) {
                Log.i(TAG, "Phát hiện định dạng Netscape — giữ nguyên")
                normalizeNetscape(trimmed)
            } else {
                Log.w(TAG, "Định dạng không nhận diện được")
                null
            }

            if (netscape.isNullOrBlank()) return false

            file(ctx).writeText(netscape)
            Log.i(TAG, "✅ Đã lưu cookies.txt (${netscape.length} bytes)")
            true
        } catch (e: Exception) {
            Log.e(TAG, "Import fail", e)
            false
        }
    }

    // ============================================================
    // JSON → Netscape
    // ============================================================
    private fun convertJsonToNetscape(jsonStr: String): String? {
        return try {
            val root = JSONObject(jsonStr)

            // Hỗ trợ cả 2 layout:
            // - { "cookies": [...] }              (Cookie-Editor, EditThisCookie)
            // - [ { "name": "...", ... }, ... ]   (một số export khác)
            val cookies: JSONArray = when {
                root.has("cookies") -> root.optJSONArray("cookies") ?: return null
                else -> {
                    // Nếu là array thuần, JSONObject wrap lại thì không tới đây.
                    // Trường hợp này chỉ xảy ra nếu file là "{ ... }" nhưng không có field cookies.
                    return null
                }
            }

            val sb = StringBuilder()
            sb.append("# Netscape HTTP Cookie File\n")
            sb.append("# Converted from JSON by Mini-Y2mate\n\n")

            var validCount = 0

            for (i in 0 until cookies.length()) {
                val c = cookies.optJSONObject(i) ?: continue

                val name = c.optString("name", "").trim()
                val value = c.optString("value", "")
                val domain = c.optString("domain", "").trim()

                if (name.isEmpty() || domain.isEmpty()) continue

                // flag: TRUE nếu domain bắt đầu bằng "." (match subdomain)
                // hostOnly = true → không match subdomain → FALSE
                val hostOnly = c.optBoolean("hostOnly", false)
                val flag = when {
                    hostOnly -> "FALSE"
                    domain.startsWith(".") -> "TRUE"
                    else -> "FALSE"
                }

                // path: dùng giá trị từ JSON, default "/"
                val path = c.optString("path", "/").ifEmpty { "/" }

                // secure: tự detect prefix bắt buộc
                val secureFromPrefix = SECURE_PREFIXES.any { name.startsWith(it) }
                val secureFromJson = when {
                    c.has("secure") -> c.optBoolean("secure", false)
                    c.has("isSecure") -> c.optBoolean("isSecure", false)
                    else -> false
                }
                val secure = secureFromJson || secureFromPrefix

                // httpOnly → prefix "#HttpOnly_" theo chuẩn Netscape
                val httpOnly = c.optBoolean("httpOnly", false) || c.optBoolean("isHttpOnly", false)

                // expiry: nhiều format khác nhau
                val session = c.optBoolean("session", false)
                val expiry: Long = when {
                    session -> 0L
                    c.has("expirationDate") -> c.optDouble("expirationDate", 0.0).toLong()
                    c.has("expiry") -> {
                        // EditThisCookie đôi khi dùng millis
                        val v = c.optLong("expiry", 0L)
                        if (v > 10_000_000_000L) v / 1000 else v
                    }
                    c.has("expires") -> {
                        val v = c.optLong("expires", 0L)
                        if (v > 10_000_000_000L) v / 1000 else v
                    }
                    else -> System.currentTimeMillis() / 1000 + DEFAULT_EXPIRY_SECONDS
                }

                // Format domain cho httpOnly cookie
                val domainField = if (httpOnly) "#HttpOnly_$domain" else domain

                sb.append(domainField).append('\t')
                    .append(flag).append('\t')
                    .append(path).append('\t')
                    .append(if (secure) "TRUE" else "FALSE").append('\t')
                    .append(expiry).append('\t')
                    .append(name).append('\t')
                    .append(value).append('\n')

                validCount++
            }

            if (validCount == 0) {
                Log.w(TAG, "Không convert được cookie nào")
                return null
            }
            Log.i(TAG, "✅ Đã convert $validCount cookies từ JSON")
            sb.toString()
        } catch (e: Exception) {
            Log.e(TAG, "convertJsonToNetscape fail", e)
            null
        }
    }

    // ============================================================
    // Chuẩn hoá Netscape (thêm header nếu thiếu, fix CRLF)
    // ============================================================
    private fun normalizeNetscape(raw: String): String {
        val normalized = raw.replace("\r\n", "\n").replace('\r', '\n')
        return if (normalized.startsWith("#")) {
            normalized
        } else {
            "# Netscape HTTP Cookie File\n\n$normalized"
        }
    }

    // ============================================================
    // Xoá
    // ============================================================
    fun clear(ctx: Context) {
        file(ctx).delete()
    }
}