package com.nam2006.y2mate.repo

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
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

        fun small(text: String) = TextView(this).apply {
            this.text = text
            textSize = 12f
            setPadding(0, pad / 6, 0, pad / 4)
            setTextColor(0xFF8B94A7.toInt())
        }

        fun button(text: String, onClick: () -> Unit) = Button(this).apply {
            this.text = text
            setOnClickListener { onClick() }
        }

        fun copyButton(label: String, value: String) = Button(this).apply {
            this.text = label
            setOnClickListener {
                val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                cm.setPrimaryClip(ClipData.newPlainText("index", value))
                Toast.makeText(this@MainActivity, "Đã copy: $value", Toast.LENGTH_SHORT).show()
            }
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
            "• Tự động được App A phát hiện\n" +
            "• Cấu hình 3 index: tự build, Flet, PyPI"
        ))

        // ===== Index URLs =====
        root.addView(title("🔗 Index URLs"))
        root.addView(small("1. Tự build (wheel do bạn build từ CI):"))
        root.addView(body(RepoConfig.INDEX_URL))
        root.addView(copyButton("📋 Copy index 1", RepoConfig.INDEX_URL))

        root.addView(small("2. Flet (numpy, pandas, scipy, cryptography…):"))
        root.addView(body(RepoConfig.EXTRA_INDEX_URL))
        root.addView(copyButton("📋 Copy index 2", RepoConfig.EXTRA_INDEX_URL))

        root.addView(small("3. PyPI (pure Python packages):"))
        root.addView(body(RepoConfig.EXTRA_INDEX_URL_2))
        root.addView(copyButton("📋 Copy index 3", RepoConfig.EXTRA_INDEX_URL_2))

        // ===== Trusted host =====
        root.addView(title("🔒 Trusted host"))
        root.addView(body(RepoConfig.TRUSTED_HOST))

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