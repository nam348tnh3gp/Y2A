package com.nam2006.y2mate

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import androidx.core.app.NotificationCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/** Giữ tiến trình tải sống khi bạn thoát app, đồng thời hiện thông báo tiến độ. */
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
        startForeground(
            NOTIF_ONGOING,
            buildOngoing("⏳ Đang chuẩn bị…", 0, true),
            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
        )
        if (job == null) {
            job = scope.launch {
                Downloader.state.collect { s ->
                    when (s) {
                        is DlState.Running -> notifyOngoing(s)
                        is DlState.Done -> {
                            notifyFinished("✅ Tải xong", s.files.firstOrNull()?.name ?: "")
                            stopSelf()
                        }
                        is DlState.Failed -> {
                            notifyFinished("❌ Tải thất bại", s.message)
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
        val ch = NotificationChannel(CHANNEL, "Tải xuống", NotificationManager.IMPORTANCE_LOW)
        nm().createNotificationChannel(ch)
    }

    private fun openAppIntent(): PendingIntent {
        val i = Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
        return PendingIntent.getActivity(this, 0, i, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    }

    private fun notifyOngoing(s: DlState.Running) {
        nm().notify(NOTIF_ONGOING, buildOngoing(s.label, (s.progress * 100).toInt(), false))
    }

    private fun buildOngoing(text: String, pct: Int, indeterminate: Boolean): Notification {
        val cancel = PendingIntent.getService(
            this, 1,
            Intent(this, DownloadService::class.java).setAction(ACTION_CANCEL),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle("Mini-Y2mate Pro")
            .setContentText(text)
            .setProgress(100, pct, indeterminate)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(openAppIntent())
            .addAction(0, "Hủy", cancel)
            .build()
    }

    private fun notifyFinished(title: String, text: String) {
        val n = NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setContentTitle(title)
            .setContentText(text)
            .setAutoCancel(true)
            .setContentIntent(openAppIntent())
            .build()
        nm().notify(NOTIF_DONE, n)
    }

    companion object {
        private const val CHANNEL = "downloads"
        private const val NOTIF_ONGOING = 1001
        private const val NOTIF_DONE = 1002
        private const val ACTION_CANCEL = "com.nam2006.y2mate.CANCEL"
    }
}