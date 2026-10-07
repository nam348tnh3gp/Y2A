package com.nam2006.y2mate

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.widget.Toast
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private val PyCardBg = Color(0xFF12161E)
private val PyFg = Color(0xFFEEF1F7)
private val PyMuted = Color(0xFF8B94A7)
private val PySoft = Color(0x12FFFFFF)
private val PyLine = Color(0x1AFFFFFF)
private val PyOk = Color(0xFF34D399)
private val PyErr = Color(0xFFF87171)
private val PyAccent = Color(0xFF7C3AED)

private const val DEFAULT_CODE = """import sys
print("Python", sys.version.split()[0])
print("Prefix:", sys.prefix)
"""

@Composable
fun PyScriptScreen() {
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()

    var code by remember { mutableStateOf(DEFAULT_CODE) }
    var output by remember { mutableStateOf("") }
    var running by remember { mutableStateOf(false) }
    var lastOk by remember { mutableStateOf<Boolean?>(null) }

    var showInstall by remember { mutableStateOf(false) }
    var showPackages by remember { mutableStateOf(false) }
    var showEnv by remember { mutableStateOf(false) }

    Column(
        Modifier
            .fillMaxWidth()
            .verticalScroll(rememberScrollState()),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("🐍", fontSize = 22.sp)
            Spacer(Modifier.width(8.dp))
            Text("Python Console", fontWeight = FontWeight.Bold, fontSize = 18.sp, color = PyFg)
            Spacer(Modifier.weight(1f))
            PillSmall("ℹ️") { showEnv = true }
        }

        Text("Code", fontSize = 12.sp, color = PyMuted)
        OutlinedTextField(
            value = code,
            onValueChange = { code = it },
            modifier = Modifier
                .fillMaxWidth()
                .heightIn(min = 180.dp, max = 320.dp),
            textStyle = MaterialTheme.typography.bodyMedium.copy(
                fontFamily = FontFamily.Monospace,
                fontSize = 13.sp,
            ),
            shape = RoundedCornerShape(12.dp),
        )

        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(
                onClick = {
                    if (running) return@Button
                    running = true
                    lastOk = null
                    output = "⏳ Đang chạy…"
                    scope.launch {
                        val r = PythonRunner.runCode(code)
                        lastOk = r.success
                        output = r.output
                        running = false
                    }
                },
                enabled = !running,
                modifier = Modifier.weight(1f).height(48.dp),
                shape = RoundedCornerShape(12.dp),
                colors = ButtonDefaults.buttonColors(
                    containerColor = PyAccent,
                    contentColor = Color.White,
                ),
            ) {
                if (running) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(18.dp),
                        strokeWidth = 2.dp,
                        color = Color.White,
                    )
                    Spacer(Modifier.width(8.dp))
                }
                Text("▶ Chạy", fontWeight = FontWeight.SemiBold)
            }

            OutlinedButton(
                onClick = {
                    scope.launch {
                        PythonRunner.resetNamespace()
                        output = "🔄 Đã reset namespace"
                        lastOk = null
                    }
                },
                enabled = !running,
                modifier = Modifier.height(48.dp),
                shape = RoundedCornerShape(12.dp),
            ) { Text("🔄", color = PyFg) }
        }

        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(
                onClick = { showInstall = true },
                enabled = !running,
                modifier = Modifier.weight(1f).height(44.dp),
                shape = RoundedCornerShape(12.dp),
            ) { Text("📦 Cài đặt package", color = PyFg) }

            OutlinedButton(
                onClick = { showPackages = true },
                enabled = !running,
                modifier = Modifier.height(44.dp),
                shape = RoundedCornerShape(12.dp),
            ) { Text("📋", color = PyFg) }
        }

        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Output", fontSize = 12.sp, color = PyMuted)
            Spacer(Modifier.weight(1f))
            if (output.isNotBlank()) {
                Text(
                    "📋 Copy",
                    fontSize = 12.sp,
                    color = PyMuted,
                    modifier = Modifier
                        .clickable {
                            val cm = ctx.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                            cm.setPrimaryClip(ClipData.newPlainText("output", output))
                            Toast.makeText(ctx, "Đã copy", Toast.LENGTH_SHORT).show()
                        }
                        .padding(6.dp),
                )
            }
        }

        Box(
            Modifier
                .fillMaxWidth()
                .heightIn(min = 120.dp, max = 360.dp)
                .clip(RoundedCornerShape(12.dp))
                .background(Color(0xFF0B0F16))
                .border(1.dp, PyLine, RoundedCornerShape(12.dp))
                .padding(12.dp),
        ) {
            if (output.isBlank()) {
                Text("(chưa có output)", fontSize = 13.sp, color = PyMuted)
            } else {
                Column(Modifier.verticalScroll(rememberScrollState())) {
                    SelectionContainer {
                        Text(
                            output,
                            fontSize = 12.5.sp,
                            fontFamily = FontFamily.Monospace,
                            color = when (lastOk) {
                                true -> PyOk
                                false -> PyErr
                                else -> PyFg
                            },
                        )
                    }
                }
            }
        }

        Spacer(Modifier.height(20.dp))
    }

    if (showInstall) InstallDialog(
        onClose = { showInstall = false },
        onResult = { r ->
            output = r.output
            lastOk = r.success
        },
    )
    if (showPackages) PackagesDialog(onClose = { showPackages = false })
    if (showEnv) EnvDialog(onClose = { showEnv = false })
}

@Composable
private fun PillSmall(text: String, onClick: () -> Unit) {
    Box(
        Modifier
            .size(36.dp)
            .clip(RoundedCornerShape(99.dp))
            .background(PySoft)
            .border(1.dp, PyLine, RoundedCornerShape(99.dp))
            .clickable { onClick() },
        contentAlignment = Alignment.Center,
    ) { Text(text, fontSize = 15.sp, color = PyFg) }
}

@Composable
private fun InstallDialog(
    onClose: () -> Unit,
    onResult: (PythonRunner.Result) -> Unit,
) {
    val scope = rememberCoroutineScope()
    var pkg by remember { mutableStateOf("") }
    var upgrade by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }

    AlertDialog(
        onDismissRequest = { if (!busy) onClose() },
        containerColor = PyCardBg,
        title = { Text("📦 Cài đặt package (pip)") },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                Text(
                    "Chỉ hỗ trợ package Python thuần.\n" +
                    "Package cần C extension sẽ báo 'gcc/clang not found'.",
                    fontSize = 12.sp, color = PyMuted,
                )
                Spacer(Modifier.height(10.dp))
                OutlinedTextField(
                    value = pkg,
                    onValueChange = { pkg = it },
                    modifier = Modifier.fillMaxWidth(),
                    placeholder = { Text("requests, bs4, httpx...", color = PyMuted) },
                    singleLine = true,
                    enabled = !busy,
                    shape = RoundedCornerShape(10.dp),
                    textStyle = MaterialTheme.typography.bodyMedium.copy(
                        fontFamily = FontFamily.Monospace,
                    ),
                )
                Spacer(Modifier.height(8.dp))
                Row(
                    Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(10.dp))
                        .background(PySoft)
                        .clickable(enabled = !busy) { upgrade = !upgrade }
                        .padding(10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(if (upgrade) "☑" else "☐", fontSize = 16.sp, color = PyFg)
                    Spacer(Modifier.width(8.dp))
                    Text("Cập nhật lên bản mới nhất (--upgrade)", fontSize = 13.sp, color = PyFg)
                }
                if (busy) {
                    Spacer(Modifier.height(12.dp))
                    LinearProgressIndicator(
                        modifier = Modifier.fillMaxWidth().height(6.dp).clip(RoundedCornerShape(99.dp)),
                        color = PyAccent,
                    )
                    Spacer(Modifier.height(6.dp))
                    Text("Đang cài — có thể mất vài phút…", fontSize = 12.sp, color = PyMuted)
                }
            }
        },
        confirmButton = {
            TextButton(
                enabled = !busy && pkg.isNotBlank(),
                onClick = {
                    busy = true
                    scope.launch {
                        val r = PipManager.install(pkg.trim(), upgrade)
                        busy = false
                        onResult(r)
                        onClose()
                    }
                },
            ) { Text("Cài đặt") }
        },
        dismissButton = {
            TextButton(enabled = !busy, onClick = onClose) { Text("Hủy") }
        },
    )
}

@Composable
private fun PackagesDialog(onClose: () -> Unit) {
    var list by remember { mutableStateOf<List<String>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }
    var query by remember { mutableStateOf("") }

    LaunchedEffect(Unit) {
        list = withContext(Dispatchers.IO) { PipManager.list() }
        loading = false
    }

    val filtered = remember(query, list) {
        if (query.isBlank()) list
        else list.filter { it.contains(query, ignoreCase = true) }
    }

    AlertDialog(
        onDismissRequest = onClose,
        containerColor = PyCardBg,
        title = { Text("📋 Packages (${list.size})") },
        text = {
            Column {
                OutlinedTextField(
                    value = query,
                    onValueChange = { query = it },
                    modifier = Modifier.fillMaxWidth(),
                    placeholder = { Text("Tìm kiếm…", color = PyMuted) },
                    singleLine = true,
                    shape = RoundedCornerShape(10.dp),
                )
                Spacer(Modifier.height(8.dp))
                Box(
                    Modifier
                        .fillMaxWidth()
                        .heightIn(min = 200.dp, max = 380.dp)
                        .clip(RoundedCornerShape(10.dp))
                        .background(Color(0xFF0B0F16))
                        .border(1.dp, PyLine, RoundedCornerShape(10.dp))
                        .padding(8.dp),
                ) {
                    when {
                        loading -> Text("Đang tải…", color = PyMuted, fontSize = 13.sp)
                        filtered.isEmpty() -> Text("(không có)", color = PyMuted, fontSize = 13.sp)
                        else -> Column(Modifier.verticalScroll(rememberScrollState())) {
                            SelectionContainer {
                                Text(
                                    filtered.joinToString("\n"),
                                    fontSize = 12.sp,
                                    fontFamily = FontFamily.Monospace,
                                    color = PyFg,
                                )
                            }
                        }
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = onClose) { Text("Đóng") } },
    )
}

@Composable
private fun EnvDialog(onClose: () -> Unit) {
    var info by remember { mutableStateOf<Map<String, String>?>(null) }
    LaunchedEffect(Unit) {
        info = PythonRunner.envInfo()
    }

    AlertDialog(
        onDismissRequest = onClose,
        containerColor = PyCardBg,
        title = { Text("ℹ️ Môi trường Python") },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                val i = info
                if (i == null) {
                    Text("Không lấy được thông tin", color = PyMuted)
                } else {
                    for ((k, v) in i) {
                        Text("$k:", fontSize = 12.sp, color = PyMuted, fontWeight = FontWeight.SemiBold)
                        Text(
                            v,
                            fontSize = 12.sp,
                            fontFamily = FontFamily.Monospace,
                            color = PyFg,
                        )
                        Spacer(Modifier.height(6.dp))
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = onClose) { Text("Đóng") } },
    )
}