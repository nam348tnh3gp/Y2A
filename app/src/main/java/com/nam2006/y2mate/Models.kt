package com.nam2006.y2mate

import androidx.annotation.DrawableRes
import androidx.compose.runtime.Immutable

enum class Platform(
    val label: String,
    val accent: Long,
    val onAccent: Long,
    @DrawableRes val icon: Int,
) {
    YOUTUBE("YouTube", 0xFFFF4D4D, 0xFFFFFFFF, R.drawable.ic_yt),
    FACEBOOK("Facebook", 0xFF4C8DFF, 0xFFFFFFFF, R.drawable.ic_fb),
    TIKTOK("TikTok", 0xFF25F4EE, 0xFF04201F, R.drawable.ic_tt);

    val qualities: List<String>
        get() = if (this == YOUTUBE) listOf("360p", "720p", "1080p", "1440p", "2160p")
        else listOf("360p", "720p", "1080p")

    val audioFormats: List<String>
        get() = if (this == YOUTUBE) listOf("mp3", "m4a", "webm", "aac", "flac", "ogg", "wav", "opus")
        else listOf("mp3", "m4a", "aac", "flac", "ogg", "wav", "opus")

    companion object {
        fun detect(url: String): Platform? {
            val u = url.lowercase()
            return when {
                "youtube.com" in u || "youtu.be" in u -> YOUTUBE
                "facebook.com" in u || "fb.watch" in u || "fb.com" in u -> FACEBOOK
                "tiktok.com" in u -> TIKTOK
                else -> null
            }
        }
    }
}

@Immutable
data class Options(
    val platform: Platform = Platform.YOUTUBE,
    val audioOnly: Boolean = false,
    val quality: String = "720p",
    val videoFormat: String = "mp4",
    val audioFormat: String = "mp3",
    val audioBitrate: Int = 128,
    val iphone: Boolean = false,
    val playlist: Boolean = false,
)

@Immutable
data class PreviewInfo(
    val title: String,
    val uploader: String,
    val duration: Int,
    val thumbnail: String?,
)

@Immutable
data class SavedFile(val name: String, val uri: String)

@Immutable
data class HistoryItem(val url: String, val name: String, val uri: String, val ts: Long)

sealed interface DlState {
    @Immutable
    data object Idle : DlState

    @Immutable
    data class Running(
        val label: String,
        val progress: Float,
        val speed: String,
        val eta: Long
    ) : DlState

    @Immutable
    data class Done(val files: List<SavedFile>) : DlState

    @Immutable
    data class Failed(val message: String) : DlState
}