package com.nam2006.y2mate

import android.app.Application
import android.content.ContentValues
import android.content.Intent
import android.provider.MediaStore
import android.webkit.MimeTypeMap
import androidx.core.content.ContextCompat
import android.util.Log
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.concurrent.atomic.AtomicLong
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream

object Downloader {
    private const val TAG = "Downloader"
    private const val PROCESS_ID = "y2m-current"
    private val SAFE = setOf("mp4", "mkv", "webm")
    private val LOSSLESS = setOf("flac", "wav", "alac")

    private lateinit var app: Application
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private const val READY_TIMEOUT_MS = 120_000

    // Mỗi lần start()/cancel() tăng counter → các tác vụ cũ biết mình đã "hết hiệu lực"
    private val runCounter = AtomicLong(0)
    // Chỉ cho 1 lần tải chạy tại 1 thời điểm
    private val runMutex = Mutex()

    val state = MutableStateFlow<DlState>(DlState.Idle)
    val ready = MutableStateFlow(false)
    val initError = MutableStateFlow<String?>(null)

    // FFmpeg JNI
    private external fun nativeChmod(path: String): Boolean
    private external fun nativeExecFfmpeg(binaryPath: String, args: Array<String>): Int
    private external fun nativeCanExecute(path: String): Boolean

    init {
        System.loadLibrary("ffmpeg_jni")
    }

    // ==========================================================
    // INIT — chờ PythonBridge sẵn sàng
    // ==========================================================
    fun init(application: Application) {
        app = application
        scope.launch {
            try {
                // 1. Chuẩn bị FFmpeg (copy .so từ nativeLibDir → filesDir, chmod, extract libs)
                prepareFfmpeg()

                // 2. Khởi tạo Python runtime (giải nén stdlib.zip + sitepackages.zip)
                Log.i(TAG, "⏳ Khởi tạo Python runtime…")
                if (!PythonBridge.init(app)) {
                    initError.value = PythonBridge.lastError() ?: "Python không khởi tạo được"
                    Log.e(TAG, "❌ Python init fail: ${initError.value}")
                    return@launch
                }
                Log.i(TAG, "✅ Python runtime sẵn sàng")

                ready.value = true
            } catch (t: Throwable) {
                val root = t.cause ?: t
                initError.value = root.message ?: root.toString()
                Log.e(TAG, "❌ Init fail", t)
            }
        }
    }

    // ==========================================================
    // FFmpeg
    // ==========================================================
    private fun prepareFfmpeg() {
        val nativeLibDir = app.applicationInfo.nativeLibraryDir
        val ffmpegInLib = File(nativeLibDir, "libffmpeg.so")
        if (!ffmpegInLib.exists()) {
            extractFfmpegFromAssets()
            return
        }
        val destDir = File(app.filesDir, "ffmpeg")
        destDir.mkdirs()
        val destFfmpeg = File(destDir, "ffmpeg")
        if (!destFfmpeg.exists()) {
            ffmpegInLib.copyTo(destFfmpeg, overwrite = true)
        }
        nativeChmod(destFfmpeg.absolutePath)
        extractLibsFromAssets(destDir)
    }

    private fun extractFfmpegFromAssets() {
        val destDir = File(app.filesDir, "ffmpeg")
        destDir.mkdirs()
        val destFfmpeg = File(destDir, "ffmpeg")
        try {
            app.assets.open("ffmpeg/ffmpeg").use { input ->
                FileOutputStream(destFfmpeg).use { output -> input.copyTo(output) }
            }
            nativeChmod(destFfmpeg.absolutePath)
            extractLibsFromAssets(destDir)
        } catch (e: Exception) {
            initError.value = "Không extract được FFmpeg: ${e.message}"
        }
    }

    private fun extractLibsFromAssets(destDir: File) {
        try {
            val libFiles = app.assets.list("ffmpeg/lib") ?: return
            for (libName in libFiles) {
                val destLib = File(destDir, libName)
                if (!destLib.exists()) {
                    app.assets.open("ffmpeg/lib/$libName").use { input ->
                        FileOutputStream(destLib).use { output -> input.copyTo(output) }
                    }
                }
            }
        } catch (_: Exception) {}
    }

    fun getFfmpegPath(): String? {
        val destFfmpeg = File(app.filesDir, "ffmpeg/ffmpeg")
        return if (destFfmpeg.exists() && nativeCanExecute(destFfmpeg.absolutePath)) {
            destFfmpeg.absolutePath
        } else null
    }

    // ==========================================================
    // START / CANCEL
    // ==========================================================
    fun start(url: String, o: Options) {
        if (state.value is DlState.Running) return
        val myRun = runCounter.incrementAndGet()
        state.value = DlState.Running("⏳ Đang chuẩn bị…", 0f, "", -1L)
        ContextCompat.startForegroundService(app, Intent(app, DownloadService::class.java))
        scope.launch {
            runMutex.withLock {
                if (runCounter.get() != myRun) return@withLock
                var poller: Job? = null
                try {
                    waitReady()
                    if (runCounter.get() != myRun) return@withLock
                    poller = launch { pollProgress(myRun) }
                    val saved = runDownload(url, o, myRun)
                    val now = System.currentTimeMillis()
                    HistoryStore.add(app, saved.map { HistoryItem(url, it.name, it.uri, now) })
                    if (runCounter.get() == myRun) state.value = DlState.Done(saved)
                } catch (t: Throwable) {
                    if (runCounter.get() == myRun) state.value = DlState.Failed(cleanError(t))
                } finally {
                    poller?.cancel()
                }
            }
        }
    }

    fun cancel() {
        runCounter.incrementAndGet()
        state.value = DlState.Idle
        // Báo Python dừng thật sự (nếu không, yt-dlp vẫn tải ngầm)
        scope.launch {
            try {
                PythonBridge.callFunction("yt_dlp_bridge", "cancel_json", "{}")
            } catch (t: Throwable) {
                Log.w(TAG, "cancel_json fail", t)
            }
        }
    }

    // ==========================================================
    // PROGRESS POLLING
    // ==========================================================
    private suspend fun pollProgress(run: Long) {
        while (true) {
            delay(600)
            if (runCounter.get() != run) return
            try {
                val j = JSONObject(PythonBridge.callFunction("yt_dlp_bridge", "get_progress_json", "{}"))
                val st = j.optString("status", "idle")
                val pct = (j.optDouble("percent", 0.0) / 100.0).toFloat().coerceIn(0f, 1f)
                val speed = j.optString("speed", "").replace(Regex("\u001B\\[[0-9;]*m"), "").trim()
                val eta = j.optLong("eta", -1L)
                val label = when (st) {
                    "downloading" -> "⬇️ Đang tải…"
                    "finished" -> "⚙️ Đang xử lý…"
                    else -> "⏳ Đang chuẩn bị…"
                }
                state.update { cur ->
                    if (cur is DlState.Running && runCounter.get() == run)
                        DlState.Running(label, pct, speed, eta)
                    else cur
                }
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
            }
        }
    }

    fun reset() {
        if (state.value !is DlState.Running) state.value = DlState.Idle
    }

    private suspend fun waitReady() {
        var waited = 0
        while (!ready.value) {
            val err = initError.value
            if (err != null) throw IllegalStateException("Không khởi tạo được: $err")
            if (waited > READY_TIMEOUT_MS) throw IllegalStateException("Khởi tạo quá lâu, hãy mở lại app")
            delay(200)
            waited += 200
        }
    }

    // ==========================================================
    // FETCH INFO (preview)
    // ==========================================================
    fun fetchInfo(url: String): PreviewInfo {
        var waited = 0
        while (!ready.value) {
            if (initError.value != null || waited > READY_TIMEOUT_MS) throw IllegalStateException("Chưa sẵn sàng")
            Thread.sleep(200); waited += 200
        }

        val cookiesFile = if (CookieStore.has(app)) CookieStore.file(app).absolutePath else ""

        val argsJson = JSONObject().apply {
            put("url", url)
            put("cookies_file", cookiesFile)
        }.toString()

        val resultJson = PythonBridge.callFunction("yt_dlp_bridge", "get_info_json", argsJson)
        val json = JSONObject(resultJson)

        return PreviewInfo(
            title = json.optString("title", "(không có tiêu đề)"),
            uploader = json.optString("uploader", ""),
            duration = json.optInt("duration", 0),
            thumbnail = json.optString("thumbnail", "").ifEmpty { null },
        )
    }

    // ==========================================================
    // CHECK YT-DLP UPDATE
    // ==========================================================
    fun checkYtDlpUpdate(): String {
        return try {
            val resultJson = PythonBridge.callFunction("yt_dlp_bridge", "check_versions_json", "{}")
            val json = JSONObject(resultJson)
            val installed = json.optString("installed", "?")
            val latest = json.optString("latest", "?")
            if (latest.startsWith("Error")) "Không kiểm tra được: $latest"
            else if (installed != latest) "Có bản cập nhật: $installed → $latest"
            else "yt-dlp đã là bản mới nhất ($installed)"
        } catch (e: Exception) {
            "Lỗi kiểm tra: ${e.message}"
        }
    }

    // ==========================================================
    // FORMAT SELECTOR
    // ==========================================================
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

    // ==========================================================
    // RUN DOWNLOAD
    // ==========================================================
    private fun runDownload(url: String, o: Options, run: Long): List<SavedFile> {
        val root = app.getExternalFilesDir("tmp") ?: File(app.filesDir, "tmp")
        val dir = File(root, Integer.toHexString((url + o.toString()).hashCode()))
        dir.mkdirs()
        try {
            if (runCounter.get() != run) throw IllegalStateException("cancelled")

            val optionsJson = JSONObject().apply {
                put("url", url)
                put("format", formatSelector(o))
                put("output_dir", dir.absolutePath)
                put("output_template", if (o.playlist) {
                    "%(playlist_title).80B/%(playlist_index)03d - %(title).100B.%(ext)s"
                } else {
                    "%(title).100B_%(id)s.%(ext)s"
                })
                put("playlist", o.playlist)
                put("audio_only", o.audioOnly)
                put("audio_format", o.audioFormat)
                put("audio_bitrate", o.audioBitrate.toString())
                put("video_format", o.videoFormat)
                put("iphone", o.iphone)
                getFfmpegPath()?.let { put("ffmpeg_path", it) }
                if (CookieStore.has(app)) {
                    put("cookies_file", CookieStore.file(app).absolutePath)
                }
            }.toString()

            // Gọi Python qua JNI
            val resultJson = PythonBridge.callFunction("yt_dlp_bridge", "download_json", optionsJson)
            val result = JSONObject(resultJson)

            val success = result.optBoolean("success", false)
            val error = result.optString("error", "")

            if (runCounter.get() != run) throw IllegalStateException("cancelled")
            if (!success) throw IllegalStateException(error.ifEmpty { "Tải thất bại" })

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
            if (runCounter.get() != run) dir.deleteRecursively()
            throw t
        }
    }

    private fun isTemp(name: String): Boolean =
        name.endsWith(".part") || name.endsWith(".ytdl") || name.endsWith(".temp") ||
            name.contains(".part-") || Regex("\\.f\\d+\\.\\w+$").containsMatchIn(name)

    // ==========================================================
    // SAVE TO DOWNLOADS (MediaStore)
    // ==========================================================
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
            ?: throw IllegalStateException("Không tạo được file trong Download")
        val out = resolver.openOutputStream(uri)
            ?: throw IllegalStateException("Không ghi được file")
        out.use { o -> file.inputStream().use { it.copyTo(o) } }
        val done = ContentValues()
        done.put(MediaStore.Downloads.IS_PENDING, 0)
        resolver.update(uri, done, null, null)
        return SavedFile(file.name, uri.toString())
    }

    // ==========================================================
    // ERROR CLEANUP
    // ==========================================================
    private fun cleanError(t: Throwable): String {
        val msg = (t.message ?: t.toString()).trim()
        val lines = msg.lines()
        val line = lines.lastOrNull { it.contains("ERROR", ignoreCase = true) } ?: lines.lastOrNull().orEmpty()
        val hint = when {
            msg.contains("Sign in", true) || msg.contains("not a bot", true) -> " — nhập cookies.txt (🍪)"
            msg.contains("page needs to be reloaded", true) -> " — YouTube giới hạn. Chờ hoặc đổi mạng."
            msg.contains("403", true) -> " — bị chặn tạm thời."
            msg.contains("ffmpeg", true) -> " — cần FFmpeg."
            msg.contains("CANNOT LINK", true) -> " — thiếu thư viện phụ thuộc."
            else -> ""
        }
        return line.take(280) + hint
    }
}