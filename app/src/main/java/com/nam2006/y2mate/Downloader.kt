package com.nam2006.y2mate

import android.app.Application
import android.content.Context
import android.content.ContentValues
import android.content.Intent
import android.provider.MediaStore
import android.webkit.MimeTypeMap
import androidx.core.content.ContextCompat
import com.ffmpegkit.ytdlp.YtDlp
import com.ffmpegkit.ytdlp.YtDlpRequest
import com.ffmpegkit.ytdlp.YtDlpException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import java.io.File

/**
 * Lõi tải: bọc yt-dlp + FFmpeg chạy ngay trên điện thoại (thư viện ffmpegkit-maintained).
 * Sử dụng API mới (YtDlp, YtDlpRequest) thay vì API cũ.
 */
object Downloader {
    private const val PROCESS_ID = "y2m-current"
    private val SAFE = setOf("mp4", "mkv", "webm")
    private val LOSSLESS = setOf("flac", "wav", "alac")
    private val SPEED = Regex("at\\s+(\\S+/s)")
    private val ITEM = Regex("Downloading item (\\d+) of (\\d+)")

    private lateinit var app: Application
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    @Volatile private var cancelled = false

    val state = MutableStateFlow<DlState>(DlState.Idle)
    val ready = MutableStateFlow(false)
    val initError = MutableStateFlow<String?>(null)

    fun init(application: Application) {
        app = application
        scope.launch {
            try {
                YtDlp.init(application)
                ready.value = true
            } catch (t: Throwable) {
                val root = t.cause ?: t
                initError.value = root.message ?: root.toString()
            }
        }
    }

    // ---------------------------------------------------------------- điều khiển

    fun start(url: String, o: Options) {
        if (state.value is DlState.Running) return
        cancelled = false
        state.value = DlState.Running("⏳ Đang chuẩn bị…", 0f, "", -1L)
        ContextCompat.startForegroundService(app, Intent(app, DownloadService::class.java))
        scope.launch {
            try {
                waitReady()
                val saved = runDownload(url, o)
                val now = System.currentTimeMillis()
                HistoryStore.add(app, saved.map { HistoryItem(url, it.name, it.uri, now) })
                state.value = DlState.Done(saved)
            } catch (t: Throwable) {
                state.value = if (cancelled) DlState.Idle else DlState.Failed(cleanError(t))
            }
        }
    }

    fun cancel() {
        cancelled = true
        try {
            YtDlp.destroyProcessById(PROCESS_ID)
        } catch (e: Exception) {
            // bỏ qua
        }
        state.value = DlState.Idle
    }

    fun reset() {
        if (state.value !is DlState.Running) state.value = DlState.Idle
    }

    private suspend fun waitReady() {
        while (!ready.value) {
            val err = initError.value
            if (err != null) throw IllegalStateException("Không khởi tạo được yt-dlp: $err")
            delay(200)
        }
    }

    /** Dùng cho xem trước (chạy trên luồng IO, chặn tối đa ~40 giây chờ khởi tạo). */
    fun fetchInfo(url: String): PreviewInfo {
        var waited = 0
        while (!ready.value) {
            if (initError.value != null || waited > 40_000) throw IllegalStateException("yt-dlp chưa sẵn sàng")
            Thread.sleep(200)
            waited += 200
        }
        val req = YtDlpRequest(url)
        req.addOption("--no-playlist")
        req.addOption("--socket-timeout", "15")
        req.addOption("--extractor-args", "youtube:player_client=web,mweb,android,tv")
        addCookies(req)
        val info = YtDlp.getInfo(req)
        val title = (info.title as? String) ?: "(không có tiêu đề)"
        val uploader = (info.uploader as? String) ?: ""
        val duration = (info.duration as? Number)?.toInt() ?: 0
        val thumb = info.thumbnail as? String
        return PreviewInfo(title, uploader, duration, thumb)
    }

    // ---------------------------------------------------------------- tải

    private fun addCookies(req: YtDlpRequest) {
        if (CookieStore.has(app)) req.addOption("--cookies", CookieStore.file(app).absolutePath)
    }

    private fun formatSelector(o: Options): String {
        if (o.audioOnly) return "bestaudio/best"
        val h = o.quality.removeSuffix("p")
        return when (o.platform) {
            Platform.FACEBOOK -> "best[height<=$h]/best"
            Platform.TIKTOK -> "bestvideo[height<=$h][ext=mp4]+bestaudio/best[height<=$h]/best"
            Platform.YOUTUBE ->
                if (o.iphone) "bestvideo[height<=$h][vcodec^=avc1]+bestaudio[acodec^=mp4a]/best[ext=mp4][vcodec^=avc1]"
                else if (o.playlist && o.quality == "2160p") "bestvideo+bestaudio/best"
                else "bestvideo[height<=$h]+bestaudio/best"
        }
    }

    private fun runDownload(url: String, o: Options): List<SavedFile> {
        val root = app.getExternalFilesDir("tmp") ?: File(app.filesDir, "tmp")
        val dir = File(root, Integer.toHexString((url + o.toString()).hashCode()))
        dir.mkdirs()
        try {
            if (cancelled) throw IllegalStateException("cancelled")

            val selector = formatSelector(o)
            val req = YtDlpRequest(url)

            req.addOption("--no-mtime")
            req.addOption("--concurrent-fragments", "4")
            req.addOption("--retries", "10")
            req.addOption("--fragment-retries", "20")
            req.addOption("--file-access-retries", "5")
            req.addOption("--socket-timeout", "30")
            req.addOption("--no-check-certificates")
            req.addOption("--geo-bypass")
            req.addOption("--user-agent",
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
                "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
            req.addOption("--add-header", "Accept-Language:en-US,en;q=0.9")
            addCookies(req)

            if (o.platform == Platform.YOUTUBE) {
                req.addOption("--extractor-args", "youtube:player_client=web,mweb,android,tv")
            }

            if (o.playlist) {
                req.addOption("--yes-playlist")
                req.addOption("--ignore-errors")
                req.addOption("--no-abort-on-error")
                req.addOption("--sleep-requests", "1")
                req.addOption("--min-sleep-interval", "5")
                req.addOption("--max-sleep-interval", "10")
                req.addOption("-o", dir.absolutePath + "/%(playlist_title).80B/%(playlist_index)03d - %(title).100B.%(ext)s")
            } else {
                req.addOption("--no-playlist")
                req.addOption("-o", dir.absolutePath + "/%(title).100B_%(id)s.%(ext)s")
            }

            req.addOption("-f", selector)
            if (o.audioOnly) {
                req.addOption("-x")
                req.addOption("--audio-format", o.audioFormat)
                req.addOption("--audio-quality", if (o.audioFormat in LOSSLESS) "0" else "${o.audioBitrate}K")
            } else {
                val merge = if (o.iphone) "mp4" else if (o.videoFormat in SAFE) o.videoFormat else "mp4"
                req.addOption("--merge-output-format", merge)
                if (!o.iphone && o.videoFormat !in SAFE) req.addOption("--recode-video", o.videoFormat)
            }

            // ----- tiến trình
            val expectedStreams = if (!o.audioOnly && selector.contains("+")) 2 else 1
            var streamIdx = 0
            var item = 1
            var total = 1
            var lastPct = 0f
            var lastSpeed = ""

            val cb: (Float, Long, String) -> Unit = { p, eta, line ->
                val l = line.trim()
                val m = ITEM.find(l)
                if (m != null) {
                    item = m.groupValues[1].toIntOrNull() ?: item
                    total = m.groupValues[2].toIntOrNull() ?: total
                    streamIdx = 0
                    lastPct = 0f
                }
                if (l.startsWith("[download] Destination:")) streamIdx++
                if (p in 0f..100f) lastPct = p
                SPEED.find(l)?.let { lastSpeed = it.groupValues[1] }

                val finishing = l.startsWith("[Merger]") || l.startsWith("[ExtractAudio]") ||
                    l.startsWith("[VideoConvertor]") || l.startsWith("[VideoRemuxer]")
                val idx = if (streamIdx < 1) 1 else streamIdx
                var label = when {
                    l.startsWith("[Merger]") -> "🔄 Đang ghép video + âm thanh"
                    finishing -> "🔄 Đang chuyển đổi"
                    o.audioOnly -> "🎵 Đang tải âm thanh"
                    expectedStreams == 2 && idx >= 2 -> "🎵 Đang tải âm thanh"
                    else -> "📹 Đang tải video"
                }
                if (total > 1) label += "  ($item/$total)"
                val within = if (finishing) 0.97f
                else (((idx - 1) + lastPct / 100f) / expectedStreams).coerceIn(0f, 0.96f)
                val frac = (((item - 1) + within) / total).coerceIn(0f, 0.99f)
                state.value = DlState.Running(label, frac, lastSpeed, eta)
            }

            // ----- Thực thi với retry tự động
            val maxRetries = 3
            var lastError: Throwable? = null
            for (attempt in 1..maxRetries) {
                if (cancelled) throw IllegalStateException("cancelled")
                try {
                    YtDlp.execute(req, PROCESS_ID, cb)
                    lastError = null
                    break
                } catch (t: Throwable) {
                    lastError = t
                    val msg = t.message.orEmpty()
                    val isReload = msg.contains("page needs to be reloaded", ignoreCase = true)
                    val is403 = msg.contains("403", ignoreCase = true)
                    if ((isReload || is403) && attempt < maxRetries) {
                        state.value = DlState.Running(
                            "🔁 Thử lại lần $attempt/$maxRetries…",
                            lastPct / 100f, lastSpeed, -1L
                        )
                        Thread.sleep(2000L * attempt)
                        continue
                    } else {
                        throw t
                    }
                }
            }
            if (lastError != null) throw lastError
            if (cancelled) throw IllegalStateException("cancelled")

            // ----- lưu vào thư mục Download/Mini-Y2mate
            val files = dir.walkTopDown().filter { it.isFile && !isTemp(it.name) }.toList()
            if (files.isEmpty()) throw IllegalStateException("Không tìm thấy file đã tải")
            val saved = ArrayList<SavedFile>()
            for (f in files) {
                val rel = (f.parentFile ?: dir).relativeTo(dir).path
                val target = if (rel.isEmpty()) "Download/Mini-Y2mate" else "Download/Mini-Y2mate/$rel"
                saved.add(saveToDownloads(f, target))
            }
            dir.deleteRecursively()
            return saved
        } catch (t: Throwable) {
            if (cancelled) dir.deleteRecursively()
            throw t
        }
    }

    private fun isTemp(name: String): Boolean {
        return name.endsWith(".part") || name.endsWith(".ytdl") || name.endsWith(".temp") ||
            name.contains(".part-") || Regex("\\.f\\d+\\.\\w+$").containsMatchIn(name)
    }

    private fun saveToDownloads(file: File, relativePath: String): SavedFile {
        val resolver = app.contentResolver
        val ext = file.extension.lowercase()
        val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "application/octet-stream"
        val values = ContentValues()
        values.put(MediaStore.Downloads.DISPLAY_NAME, file.name)
        values.put(MediaStore.Downloads.MIME_TYPE, mime)
        values.put(MediaStore.Downloads.RELATIVE_PATH, relativePath)
        values.put(MediaStore.Downloads.IS_PENDING, 1)
        val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: throw IllegalStateException("Không tạo được file trong thư mục Download")
        val out = resolver.openOutputStream(uri)
            ?: throw IllegalStateException("Không ghi được file vào thư mục Download")
        out.use { o -> file.inputStream().use { it.copyTo(o) } }
        val done = ContentValues()
        done.put(MediaStore.Downloads.IS_PENDING, 0)
        resolver.update(uri, done, null, null)
        return SavedFile(file.name, uri.toString())
    }

    private fun cleanError(t: Throwable): String {
        val msg = (t.message ?: t.toString()).trim()
        val lines = msg.lines()
        val line = lines.lastOrNull { it.contains("ERROR", ignoreCase = true) } ?: lines.lastOrNull().orEmpty()
        val hint = when {
            msg.contains("Sign in", ignoreCase = true) || msg.contains("not a bot", ignoreCase = true) ->
                " — hãy nhập cookies.txt (nút 🍪)"
            msg.contains("page needs to be reloaded", ignoreCase = true) ->
                " — YouTube đang giới hạn. Chờ vài phút hoặc đổi mạng (WiFi ↔ 4G)."
            msg.contains("403", ignoreCase = true) ->
                " — bị chặn tạm thời. Thử lại sau vài phút hoặc nhập cookies."
            else -> ""
        }
        return line.take(280) + hint
    }
}