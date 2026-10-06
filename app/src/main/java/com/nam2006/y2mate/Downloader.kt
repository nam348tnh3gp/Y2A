package com.nam2006.y2mate

import android.app.Application
import android.content.ContentValues
import android.content.Intent
import android.provider.MediaStore
import android.webkit.MimeTypeMap
import androidx.core.content.ContextCompat
import com.chaquo.python.Python
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import java.io.File
import java.io.FileOutputStream

object Downloader {
    private const val PROCESS_ID = "y2m-current"
    private val SAFE = setOf("mp4", "mkv", "webm")
    private val LOSSLESS = setOf("flac", "wav", "alac")

    private lateinit var app: Application
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    @Volatile private var cancelled = false

    val state = MutableStateFlow<DlState>(DlState.Idle)
    val ready = MutableStateFlow(false)
    val initError = MutableStateFlow<String?>(null)

    private external fun nativeChmod(path: String): Boolean
    private external fun nativeExecFfmpeg(binaryPath: String, args: Array<String>): Int
    private external fun nativeCanExecute(path: String): Boolean

    init {
        System.loadLibrary("ffmpeg_jni")
    }

    fun init(application: Application) {
        app = application
        scope.launch {
            try {
                val py = Python.getInstance()
                py.getModule("yt_dlp_bridge")
                prepareFfmpeg()
                ready.value = true
            } catch (t: Throwable) {
                val root = t.cause ?: t
                initError.value = root.message ?: root.toString()
            }
        }
    }

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
                FileOutputStream(destFfmpeg).use { output ->
                    input.copyTo(output)
                }
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
                        FileOutputStream(destLib).use { output ->
                            input.copyTo(output)
                        }
                    }
                }
            }
        } catch (e: Exception) {
            // Không có thư viện phụ thuộc
        }
    }

    fun getFfmpegPath(): String? {
        val destFfmpeg = File(app.filesDir, "ffmpeg/ffmpeg")
        return if (destFfmpeg.exists() && nativeCanExecute(destFfmpeg.absolutePath)) {
            destFfmpeg.absolutePath
        } else null
    }

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
        state.value = DlState.Idle
    }

    fun reset() {
        if (state.value !is DlState.Running) state.value = DlState.Idle
    }

    private suspend fun waitReady() {
        while (!ready.value) {
            val err = initError.value
            if (err != null) throw IllegalStateException("Không khởi tạo được: $err")
            delay(200)
        }
    }

    fun fetchInfo(url: String): PreviewInfo {
        var waited = 0
        while (!ready.value) {
            if (initError.value != null || waited > 40_000) throw IllegalStateException("Chưa sẵn sàng")
            Thread.sleep(200)
            waited += 200
        }
        val py = Python.getInstance()
        val module = py.getModule("yt_dlp_bridge")
        val cookiesFile = if (CookieStore.has(app)) CookieStore.file(app).absolutePath else ""

        // PyObject.asMap() trả Map<PyObject, PyObject> → convert sang Map<String, Any>
        val resultPy = module.callAttr("get_info", url, cookiesFile).asMap()
        val result: Map<String, Any> = resultPy.entries.associate { entry ->
            entry.key.toString() to (entry.value.toJava(Any::class.java) ?: "")
        }

        val title = result["title"]?.toString() ?: "(không có tiêu đề)"
        val uploader = result["uploader"]?.toString() ?: ""
        val duration = (result["duration"]?.toString()?.toDoubleOrNull() ?: 0.0).toInt()
        val thumb = result["thumbnail"]?.toString()
        return PreviewInfo(title, uploader, duration, thumb)
    }

    fun checkYtDlpUpdate(): String {
        return try {
            val py = Python.getInstance()
            val module = py.getModule("yt_dlp_bridge")
            val installed = module.callAttr("get_installed_version").toString()
            val latest = module.callAttr("get_latest_version").toString()
            if (latest.startsWith("Error")) {
                "Không thể kiểm tra: $latest"
            } else if (installed != latest) {
                "Có bản cập nhật: $installed → $latest"
            } else {
                "yt-dlp đã là bản mới nhất ($installed)"
            }
        } catch (e: Exception) {
            "Lỗi kiểm tra: ${e.message}"
        }
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

            val py = Python.getInstance()
            val module = py.getModule("yt_dlp_bridge")

            // Dùng mutableMapOf<String, Any> — type K, V tường minh
            val pyOptions: MutableMap<String, Any> = mutableMapOf()
            pyOptions.put("format", formatSelector(o))
            pyOptions.put("output_dir", dir.absolutePath)
            pyOptions.put("output_template", if (o.playlist) {
                "%(playlist_title).80B/%(playlist_index)03d - %(title).100B.%(ext)s"
            } else {
                "%(title).100B_%(id)s.%(ext)s"
            })
            pyOptions.put("playlist", o.playlist)
            pyOptions.put("audio_only", o.audioOnly)
            pyOptions.put("audio_format", o.audioFormat)
            pyOptions.put("audio_bitrate", o.audioBitrate.toString())

            getFfmpegPath()?.let { pyOptions.put("ffmpeg_path", it) }

            if (CookieStore.has(app)) {
                pyOptions.put("cookies_file", CookieStore.file(app).absolutePath)
            }

            // Gọi Python — convert kết quả Map<PyObject, PyObject> → Map<String, Any>
            val resultPy = module.callAttr("download", url, pyOptions).asMap()
            val result: Map<String, Any> = resultPy.entries.associate { entry ->
                entry.key.toString() to (entry.value.toJava(Any::class.java) ?: "")
            }

            val success = (result["success"] as? Boolean) ?: false
            val error = result["error"] as? String

            if (!success) throw IllegalStateException(error ?: "Tải thất bại")
            if (cancelled) throw IllegalStateException("cancelled")

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
                " — YouTube đang giới hạn. Chờ vài phút hoặc đổi mạng."
            msg.contains("403", ignoreCase = true) ->
                " — bị chặn tạm thời. Thử lại sau vài phút."
            msg.contains("ffmpeg", ignoreCase = true) ->
                " — cần FFmpeg để ghép/chuyển đổi."
            else -> ""
        }
        return line.take(280) + hint
    }
}