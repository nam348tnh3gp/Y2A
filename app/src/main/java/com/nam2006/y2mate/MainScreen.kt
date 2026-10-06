package com.nam2006.y2mate

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.webkit.MimeTypeMap
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AudioFile
import androidx.compose.material.icons.filled.Clear
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ContentPaste
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.OpenInNew
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.VideoFile
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil.compose.AsyncImage
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

// ============================================================
// COLORS
// ============================================================
private val Bg = Color(0xFF07090D)
private val CardBg = Color(0xFF12161E)
private val CardBgAlt = Color(0xFF171C26)
private val Fg = Color(0xFFEEF1F7)
private val Muted = Color(0xFF8B94A7)
private val Soft = Color(0x12FFFFFF)
private val Line = Color(0x1AFFFFFF)
private val Ok = Color(0xFF34D399)
private val Err = Color(0xFFF87171)
private val Warn = Color(0xFFFBBF24)

// ============================================================
// ROOT
// ============================================================
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
            error = Err,
        ),
    ) {
        Surface(Modifier.fillMaxSize(), color = Bg) { RootScreen(vm) }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun RootScreen(vm: MainViewModel) {
    val ctx = LocalContext.current
    val ready by Downloader.ready.collectAsStateWithLifecycle()
    val initError by Downloader.initError.collectAsStateWithLifecycle()

    when {
        initError != null -> InitErrorScreen(initError!!)
        !ready -> LoadingScreen()
        else -> MainContent(vm)
    }
}

// ============================================================
// LOADING / ERROR SCREENS
// ============================================================
@Composable
private fun LoadingScreen() {
    Box(Modifier.fillMaxSize().background(Bg), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            CircularProgressIndicator(
                color = Color(0xFFFF4D4D),
                strokeWidth = 3.dp,
                modifier = Modifier.size(48.dp),
            )
            Spacer(Modifier.height(20.dp))
            Text("Đang khởi tạo…", fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(6.dp))
            Text(
                "Lần đầu mở app có thể mất 10–30 giây",
                fontSize = 12.sp, color = Muted,
            )
        }
    }
}

@Composable
private fun InitErrorScreen(err: String) {
    Box(Modifier.fillMaxSize().background(Bg).padding(24.dp), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(Icons.Default.ErrorOutline, contentDescription = null, tint = Err, modifier = Modifier.size(56.dp))
            Spacer(Modifier.height(16.dp))
            Text("Không khởi tạo được", fontSize = 18.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(8.dp))
            Text(
                err.take(400),
                fontSize = 13.sp, color = Muted, textAlign = TextAlign.Center,
            )
            Spacer(Modifier.height(20.dp))
            Text(
                "Hãy thử xoá dữ liệu app trong Settings → Apps → Mini-Y2mate Pro → Storage → Clear data, sau đó mở lại.",
                fontSize = 12.sp, color = Muted, textAlign = TextAlign.Center,
            )
        }
    }
}

// ============================================================
// MAIN CONTENT
// ============================================================
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun MainContent(vm: MainViewModel) {
    val ctx = LocalContext.current
    val accent = MaterialTheme.colorScheme.primary
    val onAccent = MaterialTheme.colorScheme.onPrimary
    val dl by Downloader.state.collectAsStateWithLifecycle()
    val ui by vm.ui.collectAsStateWithLifecycle()
    val clipboard = LocalClipboardManager.current
    val scope = rememberCoroutineScope()
    val snackbar = remember { SnackbarHostState() }

    var showSettings by remember { mutableStateOf(false) }
    var showHistory by remember { mutableStateOf(false) }

    val cookiePicker = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument()
    ) { uri: Uri? ->
        if (uri != null) {
            val ok = vm.importCookies(uri)
            scope.launch {
                snackbar.showSnackbar(if (ok) "Đã nhập cookies.txt" else "Không đọc được file")
            }
        }
    }

    fun toast(msg: String) {
        scope.launch { snackbar.showSnackbar(msg) }
    }

    fun startDownload() {
        if (vm.url.isBlank()) toast("Nhập liên kết trước đã nhé") else vm.download()
    }

    Scaffold(
        containerColor = Bg,
        contentWindowInsets = WindowInsets(0),
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = {
            CenterAlignedTopAppBar(
                title = {
                    Text(
                        buildAnnotatedString {
                            append("Mini-Y2mate ")
                            withStyle(SpanStyle(color = accent)) { append("Pro") }
                        },
                        fontSize = 18.sp, fontWeight = FontWeight.Bold,
                    )
                },
                actions = {
                    IconButton(onClick = {
                        vm.refreshHistory(); showHistory = true
                    }) {
                        Icon(Icons.Default.History, contentDescription = "Lịch sử", tint = Fg)
                    }
                    IconButton(onClick = { showSettings = true }) {
                        Icon(
                            Icons.Default.Settings,
                            contentDescription = "Cài đặt",
                            tint = if (ui.hasCookies) Ok else Warn,
                        )
                    }
                },
            )
        },
    ) { padding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .imePadding(),
            contentPadding = PaddingValues(
                start = 14.dp, end = 14.dp, top = 8.dp,
                bottom = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding() + 16.dp,
            ),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            item(key = "url-card") {
                UrlInputCard(
                    vm = vm,
                    accent = accent,
                    onPaste = {
                        val t = clipboard.getText()?.text?.trim().orEmpty()
                        if (t.isEmpty()) toast("Clipboard đang trống") else vm.onUrlChange(t)
                    },
                    onClear = { vm.onUrlChange("") },
                    onGo = { startDownload() },
                )
            }

            item(key = "preview") {
                AnimatedVisibility(
                    visible = vm.preview != null || vm.previewLoading,
                    enter = fadeIn() + slideInVertically { it / 4 },
                    exit = fadeOut() + slideOutVertically { it / 4 },
                ) {
                    PreviewCard(vm.preview, vm.previewLoading)
                }
            }

            item(key = "platform") {
                PlatformSelector(vm.opts.platform, accent) { vm.setPlatform(it) }
            }

            item(key = "type") {
                TypeSelector(
                    audioOnly = vm.opts.audioOnly,
                    accent = accent,
                    onChange = { vm.updateOpts(vm.opts.copy(audioOnly = it)) },
                )
            }

            item(key = "options") {
                OptionsSection(vm)
            }

            item(key = "download-button") {
                DownloadButton(
                    state = dl,
                    accent = accent,
                    onAccent = onAccent,
                    onClick = { startDownload() },
                )
            }

            item(key = "result") {
                AnimatedVisibility(
                    visible = dl !is DlState.Idle,
                    enter = fadeIn(),
                    exit = fadeOut(),
                ) {
                    when (val s = dl) {
                        is DlState.Running -> RunningPanel(s, accent) { vm.cancel() }
                        is DlState.Done -> ResultPanel(s.files, ctx) { toast(it) }
                        is DlState.Failed -> ErrorPanel(s.message)
                        DlState.Idle -> {}
                    }
                }
            }

            item(key = "footer") {
                Text(
                    "📁 File được lưu trong Download/Mini-Y2mate",
                    fontSize = 12.sp, color = Muted,
                    modifier = Modifier.fillMaxWidth().padding(top = 6.dp),
                    textAlign = TextAlign.Center,
                )
            }
        }
    }

    if (showSettings) {
        SettingsSheet(
            vm = vm,
            onPick = { cookiePicker.launch(arrayOf("text/plain", "application/octet-stream", "*/*")) },
            onSnackbar = { toast(it) },
            onClose = { showSettings = false },
        )
    }

    if (showHistory) {
        HistorySheet(
            vm = vm,
            ctx = ctx,
            onClose = { showHistory = false },
        )
    }
}

// ============================================================
// URL INPUT CARD
// ============================================================
@Composable
private fun UrlInputCard(
    vm: MainViewModel,
    accent: Color,
    onPaste: () -> Unit,
    onClear: () -> Unit,
    onGo: () -> Unit,
) {
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(20.dp))
            .background(CardBg)
            .border(1.dp, Line, RoundedCornerShape(20.dp))
            .padding(14.dp),
    ) {
        OutlinedTextField(
            value = vm.url,
            onValueChange = { vm.onUrlChange(it) },
            modifier = Modifier.fillMaxWidth(),
            placeholder = { Text("Dán link vào đây…", color = Muted) },
            singleLine = true,
            shape = RoundedCornerShape(12.dp),
            keyboardOptions = KeyboardOptions(
                keyboardType = KeyboardType.Uri,
                imeAction = ImeAction.Go,
            ),
            keyboardActions = KeyboardActions(onGo = { onGo() }),
            trailingIcon = {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    IconButton(onClick = onPaste) {
                        Icon(Icons.Default.ContentPaste, contentDescription = "Dán", tint = Muted)
                    }
                    if (vm.url.isNotEmpty()) {
                        IconButton(onClick = onClear) {
                            Icon(Icons.Default.Clear, contentDescription = "Xoá", tint = Muted)
                        }
                    }
                }
            },
        )
    }
}

// ============================================================
// PREVIEW
// ============================================================
@Composable
private fun PreviewCard(pv: PreviewInfo?, loading: Boolean) {
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(CardBgAlt)
            .padding(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier
                .size(width = 96.dp, height = 64.dp)
                .clip(RoundedCornerShape(10.dp))
                .background(Soft),
            contentAlignment = Alignment.Center,
        ) {
            val thumb = pv?.thumbnail
            if (thumb != null) {
                AsyncImage(
                    model = thumb,
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxSize(),
                )
            } else {
                Icon(
                    Icons.Default.VideoFile,
                    contentDescription = null,
                    tint = Muted,
                    modifier = Modifier.size(28.dp),
                )
            }
        }
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(
                pv?.title?.takeIf { it.isNotBlank() } ?: "Đang tải thông tin…",
                fontWeight = FontWeight.SemiBold,
                fontSize = 14.sp,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.alpha(if (loading && pv == null) 0.6f else 1f),
            )
            if (pv != null) {
                val meta = listOf(
                    pv.uploader,
                    if (pv.duration > 0) fmtDuration(pv.duration) else "",
                ).filter { it.isNotBlank() }.joinToString(" · ")
                if (meta.isNotBlank()) {
                    Spacer(Modifier.height(2.dp))
                    Text(meta, fontSize = 12.sp, color = Muted)
                }
            }
        }
    }
}

// ============================================================
// SELECTORS
// ============================================================
@Composable
private fun PlatformSelector(current: Platform, accent: Color, onPick: (Platform) -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(Soft)
            .border(1.dp, Line, RoundedCornerShape(14.dp))
            .padding(4.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        for (pl in Platform.values()) {
            val sel = pl == current
            Row(
                Modifier
                    .weight(1f)
                    .height(42.dp)
                    .clip(RoundedCornerShape(10.dp))
                    .background(if (sel) Color(pl.accent) else Color.Transparent)
                    .clickable { onPick(pl) },
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.Center,
            ) {
                Box(
                    Modifier.size(22.dp).clip(CircleShape).background(Color.White),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        painterResource(pl.icon),
                        contentDescription = null,
                        tint = Color.Unspecified,
                        modifier = Modifier.size(15.dp),
                    )
                }
                Spacer(Modifier.width(6.dp))
                Text(
                    pl.label,
                    color = if (sel) Color(pl.onAccent) else Muted,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 13.sp,
                )
            }
        }
    }
}

@Composable
private fun TypeSelector(audioOnly: Boolean, accent: Color, onChange: (Boolean) -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(Soft)
            .padding(4.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        TypeTab(
            "Video", Icons.Default.VideoFile,
            selected = !audioOnly, accent = accent,
            modifier = Modifier.weight(1f),
        ) { onChange(false) }
        TypeTab(
            "Audio", Icons.Default.MusicNote,
            selected = audioOnly, accent = accent,
            modifier = Modifier.weight(1f),
        ) { onChange(true) }
    }
}

@Composable
private fun TypeTab(
    text: String,
    icon: ImageVector,
    selected: Boolean,
    accent: Color,
    modifier: Modifier,
    onClick: () -> Unit,
) {
    Row(
        modifier
            .height(44.dp)
            .clip(RoundedCornerShape(10.dp))
            .background(if (selected) Color(0x1AFFFFFF) else Color.Transparent)
            .border(
                1.dp,
                if (selected) accent else Color.Transparent,
                RoundedCornerShape(10.dp),
            )
            .clickable { onClick() },
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Center,
    ) {
        Icon(icon, contentDescription = null, tint = if (selected) accent else Muted, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(6.dp))
        Text(text, color = if (selected) Fg else Muted, fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
    }
}

// ============================================================
// OPTIONS SECTION
// ============================================================
@Composable
private fun OptionsSection(vm: MainViewModel) {
    val o = vm.opts
    val accent = MaterialTheme.colorScheme.primary
    val onAccent = MaterialTheme.colorScheme.onPrimary

    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(CardBg)
            .border(1.dp, Line, RoundedCornerShape(16.dp))
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        if (!o.audioOnly) {
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                ExposedPicker(
                    label = "Chất lượng",
                    value = o.quality,
                    options = o.platform.qualities.map { it to qLabel(it) },
                    modifier = Modifier.weight(1f),
                ) { vm.updateOpts(o.copy(quality = it)) }

                ExposedPicker(
                    label = "Định dạng video",
                    value = o.videoFormat,
                    options = listOf("mp4", "webm", "mkv", "avi", "mov", "flv")
                        .map { it to it.uppercase() },
                    modifier = Modifier.weight(1f),
                ) { vm.updateOpts(o.copy(videoFormat = it)) }
            }
        } else {
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                ExposedPicker(
                    label = "Định dạng âm thanh",
                    value = o.audioFormat,
                    options = o.platform.audioFormats.map { it to it.uppercase() },
                    modifier = Modifier.weight(1f),
                ) { vm.updateOpts(o.copy(audioFormat = it)) }

                ExposedPicker(
                    label = "Bitrate",
                    value = o.audioBitrate.toString(),
                    options = listOf(64, 128, 192, 256, 320)
                        .map { it.toString() to "$it kbps" },
                    modifier = Modifier.weight(1f),
                ) { vm.updateOpts(o.copy(audioBitrate = it.toInt())) }
            }
        }

        if (!o.audioOnly) {
            SwitchRow(
                title = "iPhone Compatible",
                sub = "H.264 + AAC, phát được trên iPhone",
                checked = o.iphone, accent = accent, onAccent = onAccent,
            ) { vm.updateOpts(o.copy(iphone = it)) }
        }

        if (o.platform == Platform.YOUTUBE) {
            SwitchRow(
                title = "Tải toàn bộ playlist / kênh",
                sub = "Lưu vào thư mục riêng trong Download/Mini-Y2mate",
                checked = o.playlist, accent = accent, onAccent = onAccent,
            ) { vm.updateOpts(o.copy(playlist = it)) }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ExposedPicker(
    label: String,
    value: String,
    options: List<Pair<String, String>>,
    modifier: Modifier,
    onPick: (String) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    val selectedLabel = options.firstOrNull { it.first == value }?.second ?: value

    Column(modifier) {
        Text(
            label,
            fontSize = 12.sp,
            color = Muted,
            modifier = Modifier.padding(start = 2.dp, bottom = 5.dp),
        )
        ExposedDropdownMenuBox(
            expanded = expanded,
            onExpandedChange = { expanded = it },
        ) {
            OutlinedTextField(
                value = selectedLabel,
                onValueChange = {},
                readOnly = true,
                trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = expanded) },
                modifier = Modifier
                    .menuAnchor(androidx.compose.material3.MenuAnchorType.PrimaryNotEditable)
                    .fillMaxWidth(),
                shape = RoundedCornerShape(12.dp),
                singleLine = true,
            )
            ExposedDropdownMenu(
                expanded = expanded,
                onDismissRequest = { expanded = false },
            ) {
                for (opt in options) {
                    DropdownMenuItem(
                        text = { Text(opt.second) },
                        onClick = { onPick(opt.first); expanded = false },
                    )
                }
            }
        }
    }
}

// ============================================================
// SWITCH ROW
// ============================================================
@Composable
private fun SwitchRow(
    title: String,
    sub: String,
    checked: Boolean,
    accent: Color,
    onAccent: Color,
    onChange: (Boolean) -> Unit,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(Color(0x08FFFFFF))
            .clickable { onChange(!checked) }
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
            Text(sub, fontSize = 12.sp, color = Muted)
        }
        Switch(
            checked = checked,
            onCheckedChange = { onChange(it) },
            colors = SwitchDefaults.colors(
                checkedTrackColor = accent,
                checkedThumbColor = onAccent,
            ),
        )
    }
}

// ============================================================
// DOWNLOAD BUTTON
// ============================================================
@Composable
private fun DownloadButton(
    state: DlState,
    accent: Color,
    onAccent: Color,
    onClick: () -> Unit,
) {
    val running = state is DlState.Running
    val progress = (state as? DlState.Running)?.progress ?: 0f
    val animated by animateFloatAsState(progress, tween(400), label = "btnProgress")

    Button(
        onClick = onClick,
        enabled = !running,
        modifier = Modifier
            .fillMaxWidth()
            .height(56.dp),
        shape = RoundedCornerShape(14.dp),
        colors = ButtonDefaults.buttonColors(
            containerColor = accent,
            contentColor = onAccent,
            disabledContainerColor = accent.copy(alpha = 0.7f),
            disabledContentColor = onAccent,
        ),
    ) {
        when (state) {
            is DlState.Running -> {
                CircularProgressIndicator(
                    progress = { animated },
                    modifier = Modifier.size(22.dp),
                    color = onAccent,
                    strokeWidth = 2.5.dp,
                    trackColor = onAccent.copy(alpha = 0.25f),
                )
                Spacer(Modifier.width(10.dp))
                Text("Đang tải…", fontSize = 16.sp, fontWeight = FontWeight.Bold)
            }
            is DlState.Failed -> {
                Icon(Icons.Default.Refresh, contentDescription = null)
                Spacer(Modifier.width(8.dp))
                Text("Thử lại", fontSize = 16.sp, fontWeight = FontWeight.Bold)
            }
            else -> {
                Icon(Icons.Default.Download, contentDescription = null)
                Spacer(Modifier.width(8.dp))
                Text("Tải xuống", fontSize = 16.sp, fontWeight = FontWeight.Bold)
            }
        }
    }
}

// ============================================================
// RUNNING / RESULT / ERROR PANELS
// ============================================================
@Composable
private fun RunningPanel(s: DlState.Running, accent: Color, onCancel: () -> Unit) {
    val animated by animateFloatAsState(s.progress, tween(400), label = "panelProgress")

    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(Color(0x08FFFFFF))
            .border(1.dp, Line, RoundedCornerShape(14.dp))
            .padding(14.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                s.label,
                fontWeight = FontWeight.SemiBold,
                fontSize = 13.5.sp,
                modifier = Modifier.weight(1f),
            )
            TextButton(onClick = onCancel) {
                Icon(Icons.Default.Close, contentDescription = null, tint = Err, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(4.dp))
                Text("Hủy", color = Err)
            }
        }
        Spacer(Modifier.height(6.dp))
        LinearProgressIndicator(
            progress = { animated },
            modifier = Modifier
                .fillMaxWidth()
                .height(8.dp)
                .clip(RoundedCornerShape(99.dp)),
            color = accent,
            trackColor = Soft,
        )
        Spacer(Modifier.height(8.dp))
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            val extra = if (s.eta >= 0) "  ·  còn ${fmtDuration(s.eta.toInt())}" else ""
            Text(
                if (s.speed.isNotEmpty()) "⚡ ${s.speed}$extra" else "—",
                fontSize = 12.sp, color = Muted,
            )
            Text("${(s.progress * 100).toInt()}%", fontSize = 12.sp, color = Muted)
        }
    }
}

@Composable
private fun ResultPanel(
    files: List<SavedFile>,
    ctx: Context,
    onToast: (String) -> Unit,
) {
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(Ok.copy(alpha = 0.08f))
            .border(1.dp, Ok.copy(alpha = 0.45f), RoundedCornerShape(14.dp))
            .padding(14.dp),
    ) {
        Text(
            if (files.size > 1) "✅ Đã tải ${files.size} file" else "✅ Tải thành công!",
            color = Ok, fontWeight = FontWeight.Bold,
        )
        for (f in files.take(6)) {
            Spacer(Modifier.height(10.dp))
            Text(f.name, fontSize = 13.sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier.padding(top = 6.dp),
            ) {
                Button(
                    onClick = { openFile(ctx, f.uri, f.name, onToast) },
                    colors = ButtonDefaults.buttonColors(
                        containerColor = Ok,
                        contentColor = Color(0xFF04130C),
                    ),
                ) {
                    Icon(Icons.Default.OpenInNew, contentDescription = null, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("Mở")
                }
                OutlinedButton(onClick = { shareFile(ctx, f.uri, f.name, onToast) }) {
                    Icon(Icons.Default.Share, contentDescription = null, modifier = Modifier.size(16.dp), tint = Fg)
                    Spacer(Modifier.width(6.dp))
                    Text("Chia sẻ", color = Fg)
                }
            }
        }
        if (files.size > 6) {
            Text(
                "… và ${files.size - 6} file khác trong thư mục Download/Mini-Y2mate",
                fontSize = 12.sp, color = Muted,
                modifier = Modifier.padding(top = 10.dp),
            )
        }
    }
}

@Composable
private fun ErrorPanel(message: String) {
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(Err.copy(alpha = 0.08f))
            .border(1.dp, Err.copy(alpha = 0.35f), RoundedCornerShape(14.dp))
            .padding(14.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(Icons.Default.ErrorOutline, contentDescription = null, tint = Err, modifier = Modifier.size(20.dp))
        Spacer(Modifier.width(10.dp))
        Text(message, color = Err, fontSize = 13.sp, modifier = Modifier.weight(1f))
    }
}

// ============================================================
// SETTINGS SHEET (BottomSheet)
// ============================================================
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SettingsSheet(
    vm: MainViewModel,
    onPick: () -> Unit,
    onSnackbar: (String) -> Unit,
    onClose: () -> Unit,
) {
    val ui by vm.ui.collectAsStateWithLifecycle()
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()
    var updating by remember { mutableStateOf(false) }

    ModalBottomSheet(
        onDismissRequest = onClose,
        sheetState = sheetState,
        containerColor = CardBg,
        dragHandle = null,
    ) {
        Column(
            Modifier
                .fillMaxWidth()
                .navigationBarsPadding()
                .padding(horizontal = 20.dp, vertical = 16.dp),
        ) {
            Text("🍪 Cookies & yt-dlp", fontSize = 18.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(16.dp))

            Row(
                Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(12.dp))
                    .background(if (ui.hasCookies) Ok.copy(alpha = 0.10f) else Warn.copy(alpha = 0.10f))
                    .padding(12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(
                    if (ui.hasCookies) Icons.Default.Folder else Icons.Default.ErrorOutline,
                    contentDescription = null,
                    tint = if (ui.hasCookies) Ok else Warn,
                )
                Spacer(Modifier.width(10.dp))
                Text(
                    if (ui.hasCookies) "Đang dùng cookies.txt"
                    else "Chưa có cookies — YouTube có thể yêu cầu đăng nhập",
                    color = if (ui.hasCookies) Ok else Warn,
                    fontSize = 13.sp,
                )
            }

            Spacer(Modifier.height(12.dp))
            Text(
                "Cách lấy: cài tiện ích \"Get cookies.txt LOCALLY\" trên Chrome/Firefox máy tính, " +
                    "mở youtube.com đã đăng nhập, Export rồi chép file sang điện thoại.",
                fontSize = 12.sp, color = Muted,
            )

            Spacer(Modifier.height(14.dp))
            Button(onClick = onPick, modifier = Modifier.fillMaxWidth()) {
                Text("📁 Nhập cookies.txt")
            }
            if (ui.hasCookies) {
                Spacer(Modifier.height(8.dp))
                OutlinedButton(
                    onClick = { vm.clearCookies() },
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text("🗑️ Xoá cookies", color = Err)
                }
            }

            Spacer(Modifier.height(20.dp))
            HorizontalDivider(color = Line)
            Spacer(Modifier.height(16.dp))

            OutlinedButton(
                onClick = {
                    updating = true
                    scope.launch {
                        val r = withContext(Dispatchers.IO) { Downloader.checkYtDlpUpdate() }
                        updating = false
                        onSnackbar(r)
                    }
                },
                enabled = !updating,
                modifier = Modifier.fillMaxWidth(),
            ) {
                if (updating) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(16.dp),
                        strokeWidth = 2.dp,
                    )
                    Spacer(Modifier.width(8.dp))
                    Text("Đang kiểm tra…", color = Fg)
                } else {
                    Icon(Icons.Default.Refresh, contentDescription = null, modifier = Modifier.size(16.dp), tint = Fg)
                    Spacer(Modifier.width(8.dp))
                    Text("Kiểm tra cập nhật yt-dlp", color = Fg)
                }
            }

            Spacer(Modifier.height(6.dp))
            Text(
                "ℹ️ yt-dlp được quản lý bởi Python/pip. Muốn lên bản mới, sửa `install(\"yt-dlp\")` " +
                    "trong build.gradle.kts rồi build lại.",
                fontSize = 11.sp, color = Muted,
            )

            Spacer(Modifier.height(24.dp))
        }
    }
}

// ============================================================
// HISTORY SHEET
// ============================================================
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun HistorySheet(
    vm: MainViewModel,
    ctx: Context,
    onClose: () -> Unit,
) {
    val ui by vm.ui.collectAsStateWithLifecycle()
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()

    ModalBottomSheet(
        onDismissRequest = onClose,
        sheetState = sheetState,
        containerColor = CardBg,
        dragHandle = null,
    ) {
        Column(
            Modifier
                .fillMaxWidth()
                .navigationBarsPadding()
                .padding(horizontal = 20.dp, vertical = 16.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("📜 Lịch sử tải", fontSize = 18.sp, fontWeight = FontWeight.Bold, modifier = Modifier.weight(1f))
                if (ui.history.isNotEmpty()) {
                    TextButton(onClick = { vm.clearHistory() }) {
                        Text("Xoá hết", color = Err, fontSize = 13.sp)
                    }
                }
            }
            Spacer(Modifier.height(12.dp))

            if (!ui.historyLoaded) {
                Box(Modifier.fillMaxWidth().padding(32.dp), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = MaterialTheme.colorScheme.primary)
                }
            } else if (ui.history.isEmpty()) {
                Column(
                    Modifier.fillMaxWidth().padding(vertical = 40.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Icon(Icons.Default.History, contentDescription = null, tint = Muted, modifier = Modifier.size(48.dp))
                    Spacer(Modifier.height(12.dp))
                    Text("Chưa có lịch sử", color = Muted, fontSize = 14.sp)
                }
            } else {
                LazyColumn(
                    Modifier.fillMaxWidth().height(400.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    items(ui.history, key = { it.uri + it.ts }) { h ->
                        Column(
                            Modifier
                                .fillMaxWidth()
                                .clip(RoundedCornerShape(10.dp))
                                .clickable {
                                    openFile(ctx, h.uri, h.name) {}
                                }
                                .padding(horizontal = 10.dp, vertical = 10.dp),
                        ) {
                            Text(
                                h.name,
                                fontWeight = FontWeight.SemiBold,
                                fontSize = 14.sp,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                            Spacer(Modifier.height(2.dp))
                            Text(
                                h.url,
                                fontSize = 12.sp,
                                color = Muted,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                            Spacer(Modifier.height(2.dp))
                            Text(
                                java.text.DateFormat.getDateTimeInstance()
                                    .format(java.util.Date(h.ts)),
                                fontSize = 11.sp,
                                color = Muted,
                            )
                        }
                    }
                }
            }
            Spacer(Modifier.height(16.dp))
        }
    }
}

// ============================================================
// HELPERS
// ============================================================
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

private fun mimeOf(name: String): String =
    MimeTypeMap.getSingleton().getMimeTypeFromExtension(
        name.substringAfterLast('.', "").lowercase()
    ) ?: "*/*"

private fun openFile(ctx: Context, uri: String, name: String, onErr: (String) -> Unit) {
    val i = Intent(Intent.ACTION_VIEW)
        .setDataAndType(Uri.parse(uri), mimeOf(name))
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
    try {
        ctx.startActivity(i)
    } catch (e: Exception) {
        onErr("Không mở được file (đã bị xóa hoặc chưa có ứng dụng phù hợp)")
    }
}

private fun shareFile(ctx: Context, uri: String, name: String, onErr: (String) -> Unit) {
    val send = Intent(Intent.ACTION_SEND)
        .setType(mimeOf(name))
        .putExtra(Intent.EXTRA_STREAM, Uri.parse(uri))
        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    try {
        ctx.startActivity(
            Intent.createChooser(send, "Chia sẻ")
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        )
    } catch (e: Exception) {
        onErr("Không chia sẻ được file")
    }
}