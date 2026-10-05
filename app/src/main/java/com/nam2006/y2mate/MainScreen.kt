package com.nam2006.y2mate

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.webkit.MimeTypeMap
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil.compose.AsyncImage
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private val Bg = Color(0xFF07090D)
private val CardBg = Color(0xFF12161E)
private val Fg = Color(0xFFEEF1F7)
private val Muted = Color(0xFF8B94A7)
private val Soft = Color(0x12FFFFFF)
private val Line = Color(0x1AFFFFFF)
private val Ok = Color(0xFF34D399)
private val Err = Color(0xFFF87171)

@Composable
fun Y2mateApp(vm: MainViewModel) {
    val p = vm.opts.platform
    MaterialTheme(
        colorScheme = darkColorScheme(
            primary = Color(p.accent),
            onPrimary = Color(p.onAccent),
            background = Bg,
            surface = CardBg,
            onSurface = Fg,
            onBackground = Fg,
        ),
    ) {
        Surface(Modifier.fillMaxSize(), color = Bg) { MainContent(vm) }
    }
}

@Composable
private fun MainContent(vm: MainViewModel) {
    val ctx = LocalContext.current
    val accent = MaterialTheme.colorScheme.primary
    val onAccent = MaterialTheme.colorScheme.onPrimary
    val dl by Downloader.state.collectAsStateWithLifecycle()
    val clipboard = LocalClipboardManager.current
    var showHistory by remember { mutableStateOf(false) }
    var showSettings by remember { mutableStateOf(false) }
    val o = vm.opts

    val cookiePicker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri: Uri? ->
        if (uri != null) {
            val ok = vm.importCookies(uri)
            toast(ctx, if (ok) "Đã nhập cookies.txt" else "Không đọc được file")
        }
    }

    fun startDownload() {
        if (vm.url.isBlank()) toast(ctx, "Nhập liên kết trước đã nhé") else vm.download()
    }

    Column(
        Modifier
            .fillMaxSize()
            .statusBarsPadding()
            .navigationBarsPadding()
            .imePadding()
            .verticalScroll(rememberScrollState())
            .padding(14.dp),
    ) {
        Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(
                Modifier.size(42.dp).clip(RoundedCornerShape(12.dp))
                    .background(Brush.linearGradient(listOf(Color(0xFFEF4444), Color(0xFFDB2777)))),
                contentAlignment = Alignment.Center,
            ) {
                Icon(painterResource(R.drawable.ic_logo), contentDescription = null, tint = Color.White, modifier = Modifier.size(26.dp))
            }
            Spacer(Modifier.width(12.dp))
            Text(
                buildAnnotatedString {
                    append("Mini-Y2mate ")
                    withStyle(SpanStyle(color = accent)) { append("Pro") }
                },
                fontSize = 20.sp, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f),
            )
            Pill(if (vm.hasCookies) "🍪 OK" else "🍪 —", if (vm.hasCookies) Ok else Color(0xFFFBBF24)) { showSettings = true }
            Spacer(Modifier.width(8.dp))
            Pill("🕘", Fg) { vm.refreshHistory(); showHistory = true }
        }

        Column(
            Modifier.fillMaxWidth().clip(RoundedCornerShape(22.dp)).background(CardBg)
                .border(1.dp, Line, RoundedCornerShape(22.dp)).padding(16.dp),
        ) {
            PlatformTabs(o.platform) { vm.setPlatform(it) }
            Spacer(Modifier.height(14.dp))

            OutlinedTextField(
                value = vm.url,
                onValueChange = { vm.onUrlChange(it) },
                modifier = Modifier.fillMaxWidth(),
                placeholder = { Text("Dán link vào đây…", color = Muted) },
                singleLine = true,
                shape = RoundedCornerShape(12.dp),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Go),
                keyboardActions = KeyboardActions(onGo = { startDownload() }),
                trailingIcon = {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("📋", fontSize = 18.sp, modifier = Modifier.clickable {
                            val t = clipboard.getText()?.text?.trim().orEmpty()
                            if (t.isEmpty()) toast(ctx, "Clipboard đang trống") else vm.onUrlChange(t)
                        }.padding(8.dp))
                        if (vm.url.isNotEmpty()) {
                            Text("✕", fontSize = 16.sp, color = Muted, modifier = Modifier.clickable { vm.onUrlChange("") }.padding(8.dp))
                        }
                    }
                },
            )

            val pv = vm.preview
            if (pv != null || vm.previewLoading) {
                Row(
                    Modifier.fillMaxWidth().padding(top = 12.dp).clip(RoundedCornerShape(14.dp)).background(Soft).padding(10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Box(
                        Modifier.size(width = 96.dp, height = 64.dp).clip(RoundedCornerShape(10.dp)).background(Soft),
                        contentAlignment = Alignment.Center,
                    ) {
                        val thumb = pv?.thumbnail
                        if (thumb != null) {
                            AsyncImage(model = thumb, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
                        } else {
                            Text("🎬", fontSize = 22.sp)
                        }
                    }
                    Spacer(Modifier.width(12.dp))
                    Column(Modifier.weight(1f)) {
                        Text(
                            pv?.title ?: "Đang tải thông tin…",
                            fontWeight = FontWeight.SemiBold, fontSize = 14.sp, maxLines = 2, overflow = TextOverflow.Ellipsis,
                        )
                        if (pv != null) {
                            val meta = listOf(pv.uploader, if (pv.duration > 0) fmtDuration(pv.duration) else "")
                                .filter { it.isNotEmpty() }.joinToString(" · ")
                            Text(meta, fontSize = 12.sp, color = Muted)
                        }
                    }
                }
            }

            Spacer(Modifier.height(14.dp))
            Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(Soft).padding(4.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                TypeButton("🎬 Video", !o.audioOnly, accent, Modifier.weight(1f)) { vm.updateOpts(o.copy(audioOnly = false)) }
                TypeButton("🎵 Audio", o.audioOnly, accent, Modifier.weight(1f)) { vm.updateOpts(o.copy(audioOnly = true)) }
            }

            Spacer(Modifier.height(14.dp))
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                if (!o.audioOnly) {
                    Picker("Chất lượng", o.quality, o.platform.qualities.map { it to qLabel(it) }, Modifier.weight(1f)) { vm.updateOpts(o.copy(quality = it)) }
                    Picker("Định dạng video", o.videoFormat, listOf("mp4", "webm", "mkv", "avi", "mov", "flv").map { it to it.uppercase() }, Modifier.weight(1f)) { vm.updateOpts(o.copy(videoFormat = it)) }
                } else {
                    Picker("Định dạng âm thanh", o.audioFormat, o.platform.audioFormats.map { it to it.uppercase() }, Modifier.weight(1f)) { vm.updateOpts(o.copy(audioFormat = it)) }
                    Picker("Bitrate", o.audioBitrate.toString(), listOf(64, 128, 192, 256, 320).map { it.toString() to "$it kbps" }, Modifier.weight(1f)) { vm.updateOpts(o.copy(audioBitrate = it.toInt())) }
                }
            }

            if (!o.audioOnly) {
                Spacer(Modifier.height(12.dp))
                SwitchRow("📱 iPhone Compatible", "H.264 + AAC, phát được trên iPhone", o.iphone, accent, onAccent) { vm.updateOpts(o.copy(iphone = it)) }
            }
            if (o.platform == Platform.YOUTUBE) {
                Spacer(Modifier.height(8.dp))
                SwitchRow("📀 Tải toàn bộ playlist / kênh", "Lưu vào thư mục riêng trong Download/Mini-Y2mate", o.playlist, accent, onAccent) { vm.updateOpts(o.copy(playlist = it)) }
            }

            Spacer(Modifier.height(18.dp))
            val running = dl is DlState.Running
            Button(
                onClick = { startDownload() },
                enabled = !running,
                modifier = Modifier.fillMaxWidth().height(54.dp),
                shape = RoundedCornerShape(14.dp),
                colors = ButtonDefaults.buttonColors(containerColor = accent, contentColor = onAccent),
            ) {
                Text(
                    when (dl) {
                        is DlState.Running -> "Đang tải…"
                        is DlState.Failed -> "🔄 Thử lại"
                        else -> "⬇️ Tải xuống"
                    },
                    fontSize = 16.sp, fontWeight = FontWeight.Bold,
                )
            }

            when (val s = dl) {
                is DlState.Running -> RunningPanel(s, accent) { vm.cancel() }
                is DlState.Done -> ResultPanel(s.files, ctx)
                is DlState.Failed -> Text("❌ ${s.message}", color = Err, fontSize = 13.sp, modifier = Modifier.padding(top = 12.dp))
                DlState.Idle -> {}
            }

            Text(
                "📁 File được lưu trong Download/Mini-Y2mate",
                fontSize = 12.sp, color = Muted, modifier = Modifier.fillMaxWidth().padding(top = 14.dp),
            )
        }
        Spacer(Modifier.height(24.dp))
    }

    if (showHistory) HistoryDialog(vm, ctx) { showHistory = false }
    if (showSettings) SettingsDialog(vm, ctx, onPick = { cookiePicker.launch(arrayOf("text/plain", "application/octet-stream", "*/*")) }) { showSettings = false }
}

// ===================================================================== thành phần nhỏ

private fun toast(ctx: Context, msg: String) = Toast.makeText(ctx, msg, Toast.LENGTH_SHORT).show()

private fun qLabel(q: String) = when (q) {
    "2160p" -> "2160p (4K)"
    "1440p" -> "1440p (2K)"
    else -> q
}

private fun fmtDuration(sec: Int): String {
    val h = sec / 3600
    val m = (sec % 3600) / 60
    val s = sec % 60
    val mm = m.toString().padStart(2, '0')
    val ss = s.toString().padStart(2, '0')
    return if (h > 0) "$h:$mm:$ss" else "$mm:$ss"
}

@Composable
private fun Pill(text: String, color: Color, onClick: () -> Unit) {
    Box(
        Modifier.height(40.dp).clip(RoundedCornerShape(99.dp)).background(Soft)
            .border(1.dp, Line, RoundedCornerShape(99.dp)).clickable { onClick() }.padding(horizontal = 14.dp),
        contentAlignment = Alignment.Center,
    ) { Text(text, color = color, fontSize = 13.sp, fontWeight = FontWeight.SemiBold) }
}

@Composable
private fun PlatformTabs(current: Platform, onPick: (Platform) -> Unit) {
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(Soft).border(1.dp, Line, RoundedCornerShape(14.dp)).padding(4.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        for (pl in Platform.values()) {
            val sel = pl == current
            Row(
                Modifier.weight(1f).height(42.dp).clip(RoundedCornerShape(10.dp))
                    .background(if (sel) Color(pl.accent) else Color.Transparent).clickable { onPick(pl) },
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.Center,
            ) {
                Box(Modifier.size(24.dp).clip(CircleShape).background(Color.White), contentAlignment = Alignment.Center) {
                    Icon(painterResource(pl.icon), contentDescription = null, tint = Color.Unspecified, modifier = Modifier.size(16.dp))
                }
                Spacer(Modifier.width(6.dp))
                Text(pl.label, color = if (sel) Color(pl.onAccent) else Muted, fontWeight = FontWeight.SemiBold, fontSize = 13.sp)
            }
        }
    }
}

@Composable
private fun TypeButton(text: String, selected: Boolean, accent: Color, modifier: Modifier, onClick: () -> Unit) {
    Box(
        modifier.height(40.dp).clip(RoundedCornerShape(10.dp))
            .background(if (selected) Color(0x1AFFFFFF) else Color.Transparent)
            .border(1.dp, if (selected) accent else Color.Transparent, RoundedCornerShape(10.dp))
            .clickable { onClick() },
        contentAlignment = Alignment.Center,
    ) { Text(text, color = if (selected) Fg else Muted, fontWeight = FontWeight.SemiBold) }
}

@Composable
private fun Picker(label: String, value: String, options: List<Pair<String, String>>, modifier: Modifier, onPick: (String) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Column(modifier) {
        Text(label, fontSize = 12.sp, color = Muted, modifier = Modifier.padding(start = 2.dp, bottom = 5.dp))
        Box {
            OutlinedButton(
                onClick = { open = true },
                modifier = Modifier.fillMaxWidth().height(46.dp),
                shape = RoundedCornerShape(12.dp),
            ) {
                Text(options.firstOrNull { it.first == value }?.second ?: value, color = Fg, modifier = Modifier.weight(1f))
                Text("▾", color = Muted)
            }
            DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
                for (opt in options) {
                    DropdownMenuItem(text = { Text(opt.second) }, onClick = { onPick(opt.first); open = false })
                }
            }
        }
    }
}

@Composable
private fun SwitchRow(title: String, sub: String, checked: Boolean, accent: Color, onAccent: Color, onChange: (Boolean) -> Unit) {
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(Color(0x08FFFFFF))
            .border(1.dp, Line, RoundedCornerShape(14.dp)).clickable { onChange(!checked) }.padding(horizontal = 14.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
            Text(sub, fontSize = 12.sp, color = Muted)
        }
        Switch(
            checked = checked, onCheckedChange = { onChange(it) },
            colors = SwitchDefaults.colors(checkedTrackColor = accent, checkedThumbColor = onAccent),
        )
    }
}

@Composable
private fun RunningPanel(s: DlState.Running, accent: Color, onCancel: () -> Unit) {
    Column(Modifier.fillMaxWidth().padding(top = 14.dp).clip(RoundedCornerShape(14.dp)).background(Color(0x08FFFFFF)).border(1.dp, Line, RoundedCornerShape(14.dp)).padding(14.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(s.label, fontWeight = FontWeight.SemiBold, fontSize = 13.5.sp, modifier = Modifier.weight(1f))
            TextButton(onClick = onCancel) { Text("✕ Hủy", color = Err) }
        }
        Spacer(Modifier.height(6.dp))
        LinearProgressIndicator(
            progress = { s.progress },
            modifier = Modifier.fillMaxWidth().height(10.dp).clip(RoundedCornerShape(99.dp)),
            color = accent,
            trackColor = Soft,
        )
        Spacer(Modifier.height(8.dp))
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            val extra = if (s.eta >= 0) "  ·  còn ${fmtDuration(s.eta.toInt())}" else ""
            Text(if (s.speed.isNotEmpty()) "⚡ ${s.speed}$extra" else "—", fontSize = 12.sp, color = Muted)
            Text("${(s.progress * 100).toInt()}%", fontSize = 12.sp, color = Muted)
        }
    }
}

@Composable
private fun ResultPanel(files: List<SavedFile>, ctx: Context) {
    Column(Modifier.fillMaxWidth().padding(top = 14.dp).clip(RoundedCornerShape(14.dp)).background(Ok.copy(alpha = 0.08f)).border(1.dp, Ok.copy(alpha = 0.45f), RoundedCornerShape(14.dp)).padding(14.dp)) {
        Text(if (files.size > 1) "✅ Đã tải ${files.size} file" else "✅ Tải thành công!", color = Ok, fontWeight = FontWeight.Bold)
        for (f in files.take(6)) {
            Spacer(Modifier.height(10.dp))
            Text(f.name, fontSize = 13.sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(top = 6.dp)) {
                Button(onClick = { openFile(ctx, f.uri, f.name) }, colors = ButtonDefaults.buttonColors(containerColor = Ok, contentColor = Color(0xFF04130C))) { Text("📂 Mở") }
                OutlinedButton(onClick = { shareFile(ctx, f.uri, f.name) }) { Text("↗ Chia sẻ", color = Fg) }
            }
        }
        if (files.size > 6) Text("… và ${files.size - 6} file khác trong thư mục Download/Mini-Y2mate", fontSize = 12.sp, color = Muted, modifier = Modifier.padding(top = 10.dp))
    }
}

// ===================================================================== hộp thoại

@Composable
private fun HistoryDialog(vm: MainViewModel, ctx: Context, onClose: () -> Unit) {
    AlertDialog(
        onDismissRequest = onClose,
        containerColor = CardBg,
        title = { Text("📜 Lịch sử tải") },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                if (vm.history.isEmpty()) Text("Chưa có lịch sử", color = Muted)
                for (h in vm.history) {
                    Column(Modifier.fillMaxWidth().clickable { openFile(ctx, h.uri, h.name) }.padding(vertical = 8.dp)) {
                        Text(h.name, fontWeight = FontWeight.SemiBold, fontSize = 14.sp, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(h.url, fontSize = 12.sp, color = Muted, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(java.text.DateFormat.getDateTimeInstance().format(java.util.Date(h.ts)), fontSize = 11.sp, color = Muted)
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = onClose) { Text("Đóng") } },
        dismissButton = { if (vm.history.isNotEmpty()) TextButton(onClick = { vm.clearHistory() }) { Text("Xóa lịch sử", color = Err) } },
    )
}

@Composable
private fun SettingsDialog(vm: MainViewModel, ctx: Context, onPick: () -> Unit, onClose: () -> Unit) {
    val scope = rememberCoroutineScope()
    var updating by remember { mutableStateOf(false) }
    AlertDialog(
        onDismissRequest = onClose,
        containerColor = CardBg,
        title = { Text("🍪 Cookies & yt-dlp") },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                Text(
                    if (vm.hasCookies) "✅ Đang dùng cookies.txt" else "⚠️ Chưa có cookies — YouTube có thể yêu cầu đăng nhập (lỗi \"Sign in to confirm you're not a bot\").",
                    color = if (vm.hasCookies) Ok else Color(0xFFFBBF24), fontSize = 13.sp,
                )
                Spacer(Modifier.height(10.dp))
                Text(
                    "Cách lấy: cài tiện ích \"Get cookies.txt LOCALLY\" trên Chrome/Firefox máy tính, mở youtube.com đã đăng nhập, Export rồi chép file sang điện thoại và chọn bên dưới.",
                    fontSize = 12.sp, color = Muted,
                )
                Spacer(Modifier.height(12.dp))
                Button(onClick = onPick, modifier = Modifier.fillMaxWidth()) { Text("📁 Nhập cookies.txt") }
                if (vm.hasCookies) {
                    OutlinedButton(onClick = { vm.clearCookies() }, modifier = Modifier.fillMaxWidth().padding(top = 6.dp)) { Text("🗑️ Xóa cookies", color = Err) }
                }
                Spacer(Modifier.height(14.dp))
                OutlinedButton(
                    onClick = {
                        updating = true
                        scope.launch {
                            val r = withContext(Dispatchers.IO) {
                                "Thư viện mới không hỗ trợ cập nhật in-app. Hãy nâng version trong build.gradle.kts"
                            }
                            updating = false
                            toast(ctx, r)
                        }
                    },
                    enabled = !updating,
                    modifier = Modifier.fillMaxWidth(),
                ) { Text(if (updating) "Đang cập nhật…" else "🔄 Cập nhật yt-dlp", color = Fg) }
            }
        },
        confirmButton = { TextButton(onClick = onClose) { Text("Đóng") } },
    )
}

// ===================================================================== mở / chia sẻ file

private fun mimeOf(name: String): String =
    MimeTypeMap.getSingleton().getMimeTypeFromExtension(name.substringAfterLast('.', "").lowercase()) ?: "*/*"

private fun openFile(ctx: Context, uri: String, name: String) {
    val i = Intent(Intent.ACTION_VIEW)
        .setDataAndType(Uri.parse(uri), mimeOf(name))
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
    try {
        ctx.startActivity(i)
    } catch (e: Exception) {
        toast(ctx, "Không mở được file (đã bị xóa hoặc chưa có ứng dụng phù hợp)")
    }
}

private fun shareFile(ctx: Context, uri: String, name: String) {
    val send = Intent(Intent.ACTION_SEND)
        .setType(mimeOf(name))
        .putExtra(Intent.EXTRA_STREAM, Uri.parse(uri))
        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    try {
        ctx.startActivity(Intent.createChooser(send, "Chia sẻ").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    } catch (e: Exception) {
        toast(ctx, "Không chia sẻ được file")
    }
}