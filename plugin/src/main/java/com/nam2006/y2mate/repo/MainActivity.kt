package com.nam2006.y2mate.repo

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity

class MainActivity : AppCompatActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val pad = (resources.displayMetrics.density * 20).toInt()

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(pad, pad, pad, pad)
        }

        fun title(text: String) = TextView(this).apply {
            this.text = text
            textSize = 20f
            setPadding(0, pad / 2, 0, pad / 4)
        }

        fun body(text: String) = TextView(this).apply {
            this.text = text
            textSize = 14f
            setPadding(0, pad / 4, 0, pad / 4)
        }

        fun button(text: String, onClick: () -> Unit) = Button(this).apply {
            this.text = text
            setOnClickListener { onClick() }
        }

        val pm = packageManager
        val appAInstalled = RepoConfig.appAInstalled(pm)
        val appAVersion = RepoConfig.appAVersion(pm)

        // ===== Tiêu đề =====
        root.addView(title("📦 Mini-Y2mate Repository"))
        root.addView(body(
            "Plugin này giúp Mini-Y2mate tải wheel Python build sẵn cho Android.\n\n" +
            "Đặc điểm:\n" +
            "• Không chứa code thực thi\n" +
            "• Chỉ cung cấp địa chỉ index cho pip\n" +
            "• Tự động được App A phát hiện"
        ))

        // ===== Index URL =====
        root.addView(title("🔗 Index URL"))
        root.addView(body(RepoConfig.INDEX_URL))

        // ===== Trạng thái App A =====
        root.addView(title("📱 Trạng thái"))
        root.addView(body(
            if (appAInstalled)
                "✅ Mini-Y2mate đã cài (v$appAVersion)\n\n" +
                "Khi bạn mở App chính và cài package Python, pip sẽ ưu tiên index trên."
            else
                "⚠️ Chưa cài Mini-Y2mate.\n\n" +
                "Plugin vẫn hoạt động độc lập, nhưng cần cài App chính để dùng."
        ))

        // ===== Nút hành động =====
        root.addView(button(
            if (appAInstalled) "🚀 Mở Mini-Y2mate" else "⬇️ Tải Mini-Y2mate"
        ) {
            if (appAInstalled) {
                val i = pm.getLaunchIntentForPackage(RepoConfig.APP_A_PACKAGE)
                if (i != null) startActivity(i)
            } else {
                startActivity(
                    Intent(Intent.ACTION_VIEW, Uri.parse(RepoConfig.releasesUrl()))
                )
            }
        })

        root.addView(button("📖 Hướng dẫn") {
            startActivity(
                Intent(
                    Intent.ACTION_VIEW,
                    Uri.parse("https://github.com/${RepoConfig.GITHUB_OWNER}/${RepoConfig.GITHUB_REPO}")
                )
            )
        })

        setContentView(ScrollView(this).apply { addView(root) })
    }
}