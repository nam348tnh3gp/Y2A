package com.nam2006.y2mate

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

class DownloadService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var job: Job? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_CANCEL) {
            Downloader.cancel()
            stopSelf()
            return START_NOT_STICKY
        }

        ensureChannel()

        val initialNotif = buildOngoing("⏳ Đang chuẩn bị…", 0, true)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIF_ONGOING,
                initialNotif,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            )
        } else {
            startForeground(NOTIF_ONGOING, initialNotif)
        }

        if (job == null) {
            job = scope.launch {
                Downloader.state.collect { s ->
                    when (s) {
                        is DlState.Running -> notifyOngoing(s)
                        is DlState.Done -> {
                            notifyFinished(
                                "✅ Tải xong",
                                s.files.firstOrNull()?.name ?: "",
                                showOpen = true,
                                firstFileUri = s.files.firstOrNull()?.uri
                            )
                            stopSelf()
                        }
                        is DlState.Failed -> {
                            notifyFinished("❌ Tải thất bại", s.message, showOpen = false, firstFileUri = null)
                            stopSelf()
                        }
                        DlState.Idle -> stopSelf()
                    }
                }
            }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    private fun nm(): NotificationManager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager

    private fun ensureChannel() {
        val ch = NotificationChannel(
            CHANNEL,
            "Tải xuống",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Thông báo tiến độ tải video"
            setShowBadge(false)
        }
        nm().createNotificationChannel(ch)
    }

    private fun openAppIntent(): PendingIntent {
        val i = Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
        return PendingIntent.getActivity(
            this, 0, i,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
    }

    private fun notifyOngoing(s: DlState.Running) {
        val pct = (s.progress * 100).toInt().coerceIn(0, 100)
        // Chỉ update nếu đã đổi ít nhất 1% so với lần trước
        NotificationManagerCompat.from(this).notify(
            NOTIF_ONGOING,
            buildOngoing(s.label, pct, s.progress <= 0f)
        )
    }

    private fun buildOngoing(text: String, pct: Int, indeterminate: Boolean): Notification {
        val cancel = PendingIntent.getService(
            this, 1,
            Intent(this, DownloadService::class.java).setAction(ACTION_CANCEL),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        val content = "Tiến độ: $pct%" + if (text.contains("tải", true) && !text.contains("xong")) "" else ""

        return NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle("Mini-Y2mate Pro")
            .setContentText(text)
            .setSubText(content)
            .setProgress(100, pct, indeterminate)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(openAppIntent())
            .addAction(0, "Hủy", cancel)
            .build()
    }

    private fun notifyFinished(
        title: String,
        text: String,
        showOpen: Boolean,
        firstFileUri: String?
    ) {
        val builder = NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setContentTitle(title)
            .setContentText(text)
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setContentIntent(openAppIntent())

        if (showOpen && firstFileUri != null) {
            val view = PendingIntent.getActivity(
                this, 2,
                Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(android.net.Uri.parse(firstFileUri), "*/*")
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
                },
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            builder.addAction(0, "Mở", view)
        }

        nm().notify(NOTIF_DONE, builder.build())
    }

    companion object {
        private const val CHANNEL = "downloads"
        private const val NOTIF_ONGOING = 1001
        private const val NOTIF_DONE = 1002
        private const val ACTION_CANCEL = "com.nam2006.y2mate.CANCEL"
    }
}