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

    fun import(ctx: Context, uri: Uri): Boolean {
        return try {
            val input = ctx.contentResolver.openInputStream(uri) ?: return false
            input.use { ins -> file(ctx).outputStream().use { out -> ins.copyTo(out) } }
            true
        } catch (e: Exception) {
            false
        }
    }

    fun clear(ctx: Context) {
        file(ctx).delete()
    }
}
