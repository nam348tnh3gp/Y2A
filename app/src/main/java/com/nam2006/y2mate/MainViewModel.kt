package com.nam2006.y2mate

import android.app.Application
import android.content.Context
import android.net.Uri
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class MainViewModel(application: Application) : AndroidViewModel(application) {
    private val ctx: Context = application
    private val prefs = ctx.getSharedPreferences("settings", Context.MODE_PRIVATE)

    var url by mutableStateOf("")
    var opts by mutableStateOf(loadOpts())
    var preview by mutableStateOf<PreviewInfo?>(null)
    var previewLoading by mutableStateOf(false)
    var hasCookies by mutableStateOf(CookieStore.has(application))
    var history by mutableStateOf<List<HistoryItem>>(emptyList())

    private var previewJob: Job? = null

    private fun loadOpts(): Options {
        val p = try {
            Platform.valueOf(prefs.getString("platform", "YOUTUBE") ?: "YOUTUBE")
        } catch (e: Exception) {
            Platform.YOUTUBE
        }
        return Options(
            platform = p,
            audioOnly = prefs.getBoolean("audioOnly", false),
            quality = prefs.getString("quality", "720p") ?: "720p",
            videoFormat = prefs.getString("videoFormat", "mp4") ?: "mp4",
            audioFormat = prefs.getString("audioFormat", "mp3") ?: "mp3",
            audioBitrate = prefs.getInt("bitrate", 128),
            iphone = prefs.getBoolean("iphone", false),
            playlist = false,
        )
    }

    fun updateOpts(o: Options) {
        opts = o
        prefs.edit()
            .putString("platform", o.platform.name)
            .putBoolean("audioOnly", o.audioOnly)
            .putString("quality", o.quality)
            .putString("videoFormat", o.videoFormat)
            .putString("audioFormat", o.audioFormat)
            .putInt("bitrate", o.audioBitrate)
            .putBoolean("iphone", o.iphone)
            .apply()
    }

    fun setPlatform(p: Platform) {
        var o = opts.copy(platform = p)
        if (o.quality !in p.qualities) o = o.copy(quality = "720p")
        if (o.audioFormat !in p.audioFormats) o = o.copy(audioFormat = "mp3")
        if (p != Platform.YOUTUBE) o = o.copy(playlist = false)
        updateOpts(o)
    }

    fun onUrlChange(v: String) {
        url = v
        Downloader.reset()
        val detected = Platform.detect(v)
        if (detected != null && detected != opts.platform) setPlatform(detected)

        previewJob?.cancel()
        val u = v.trim()
        if (!u.startsWith("http")) {
            preview = null
            previewLoading = false
            return
        }
        previewLoading = true
        previewJob = viewModelScope.launch {
            delay(700)
            try {
                val info = withContext(Dispatchers.IO) { Downloader.fetchInfo(u) }
                if (url.trim() == u) preview = info
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (url.trim() == u) preview = null
            } finally {
                if (url.trim() == u) previewLoading = false
            }
        }
    }

    fun handleShared(text: String?) {
        if (text == null) return
        val m = Regex("https?://\\S+").find(text) ?: return
        onUrlChange(m.value)
    }

    fun download() {
        val u = url.trim()
        if (u.isNotEmpty()) Downloader.start(u, opts)
    }

    fun cancel() = Downloader.cancel()

    fun importCookies(uri: Uri): Boolean {
        val ok = CookieStore.import(ctx, uri)
        hasCookies = CookieStore.has(ctx)
        return ok
    }

    fun clearCookies() {
        CookieStore.clear(ctx)
        hasCookies = false
    }

    fun refreshHistory() {
        history = HistoryStore.load(ctx)
    }

    fun clearHistory() {
        HistoryStore.clear(ctx)
        history = emptyList()
    }
}