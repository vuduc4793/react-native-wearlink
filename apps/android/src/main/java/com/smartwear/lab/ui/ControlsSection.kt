package com.smartwear.lab.ui

import android.app.TimePickerDialog
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.background
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.smartwear.core.ConfigurableDevice
import com.smartwear.core.ConnectionState
import com.smartwear.core.ControlValue
import com.smartwear.core.DeviceControl
import com.smartwear.core.WearableDevice
import com.smartwear.core.formatMinuteOfDay
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Cài đặt & điều khiển của thiết bị, vẽ theo [DeviceControl.kind]. Mục số dùng nút −/+ và chỉ gửi xuống thiết bị
 * sau 0,7 s không bấm thêm (tránh gửi một lệnh mỗi lần bấm).
 */
@Composable
fun ControlsSection(device: WearableDevice) {
    val configurable = device as? ConfigurableDevice ?: return
    val controls by configurable.controls.collectAsState()
    val state by device.state.collectAsState()
    if (controls.isEmpty()) return
    val connected = state == ConnectionState.CONNECTED
    val scope = rememberCoroutineScope()
    var error by remember(device.id) { mutableStateOf<String?>(null) }
    var notice by remember(device.id) { mutableStateOf<String?>(null) }
    // Giá trị số đang chỉnh (chưa gửi)
    val pending = remember(device.id) { mutableStateMapOf<String, Int>() }
    // Hành động nguy hiểm (`DeviceControl.confirm`) đang chờ người dùng xác nhận.
    var confirming by remember(device.id) { mutableStateOf<DeviceControl?>(null) }

    fun run(c: DeviceControl) {
        scope.launch {
            error = null
            runCatching { configurable.runAction(c.id) }
                .onSuccess { notice = "Đã gửi: ${c.title}" }
                .onFailure { error = it.message }
        }
    }

    fun send(id: String, value: ControlValue) {
        scope.launch {
            error = null
            runCatching { configurable.setControl(id, value) }.onFailure { error = it.message }
        }
    }

    for ((id, v) in pending.toMap()) {
        key(id) {
            LaunchedEffect(v) {
                delay(700)
                if (pending[id] == v) {
                    pending.remove(id)
                    send(id, ControlValue.Number(v))
                }
            }
        }
    }

    controls.groupBy { it.group }.forEach { (group, items) ->
        SectionTitle(group)
        GlassCard {
            Column {
                items.forEachIndexed { i, c ->
                    if (i > 0) Hairline(Modifier.padding(vertical = 2.dp))
                    ControlRow(
                        c, connected, pending[c.id],
                        onBool = { send(c.id, ControlValue.Bool(it)) },
                        onNumber = { pending[c.id] = it },
                        onChoice = { send(c.id, ControlValue.Number(it)) },
                        onRange = { from, to -> send(c.id, ControlValue.TimeRange(from, to)) },
                        onAction = { if (c.confirm != null) confirming = c else run(c) },
                    )
                }
            }
        }
    }
    if (device is com.smartwear.core.WeatherDisplay && device.supportsWeather) WeatherCard(device, connected)
    CallContactsCard(device)
    PhoneLinkCard(device)
    confirming?.let { c ->
        AlertDialog(
            onDismissRequest = { confirming = null },
            title = { Text(c.title) },
            text = { Text(c.confirm.orEmpty()) },
            confirmButton = { TextButton(onClick = { confirming = null; run(c) }) { Text("Xác nhận", color = Palette.red) } },
            dismissButton = { TextButton(onClick = { confirming = null }) { Text("Huỷ") } },
        )
    }
    if (!connected) Text("Thay đổi được lưu và gửi xuống khi thiết bị kết nối.", style = Type.footnote, color = Palette.secondary, modifier = Modifier.padding(top = 8.dp))
    notice?.let { Text(it, style = Type.footnote, color = Palette.green, modifier = Modifier.padding(top = 8.dp)) }
    error?.let { Text(it, style = Type.footnote, color = Palette.orange, modifier = Modifier.padding(top = 8.dp)) }
}

@Composable
private fun ControlRow(
    c: DeviceControl,
    connected: Boolean,
    pendingNumber: Int?,
    onBool: (Boolean) -> Unit,
    onNumber: (Int) -> Unit,
    onChoice: (Int) -> Unit,
    onRange: (Int, Int) -> Unit,
    onAction: () -> Unit,
) {
    val context = LocalContext.current
    val dim = Modifier.alpha(if (c.enabled) 1f else 0.4f)
    Row(Modifier.fillMaxWidth().padding(vertical = 8.dp).then(dim), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(c.title, style = Type.callout, color = Palette.label)
            c.detail?.let { Text(it, style = Type.footnote, color = Palette.secondary) }
        }
        when (c.kind) {
            DeviceControl.Kind.ACTION -> PillButton("Bắt đầu", onAction, enabled = connected, kind = ButtonKind.PRIMARY)
            DeviceControl.Kind.TOGGLE -> Switch(
                checked = (c.value as? ControlValue.Bool)?.on == true,
                onCheckedChange = onBool,
                enabled = c.enabled,
                colors = SwitchDefaults.colors(checkedTrackColor = Palette.green, checkedThumbColor = Color.White),
            )
            DeviceControl.Kind.NUMBER -> {
                val current = pendingNumber ?: (c.value as? ControlValue.Number)?.value ?: c.min
                Row(verticalAlignment = Alignment.CenterVertically) {
                    StepButton("−", c.enabled && current > c.min) { onNumber((current - c.step).coerceAtLeast(c.min)) }
                    Text(
                        "$current ${c.unit}".trim(),
                        style = Type.callout,
                        color = if (pendingNumber != null) Palette.accent else Palette.label,
                        modifier = Modifier.padding(horizontal = 10.dp),
                    )
                    StepButton("+", c.enabled && current < c.max) { onNumber((current + c.step).coerceAtMost(c.max)) }
                }
            }
            DeviceControl.Kind.CHOICE -> {
                var open by remember { mutableStateOf(false) }
                val index = (c.value as? ControlValue.Number)?.value ?: 0
                Box {
                    Text(
                        "${c.options.getOrElse(index) { "—" }} ▾",
                        style = Type.callout,
                        color = Palette.accent,
                        modifier = Modifier.clickable(enabled = c.enabled) { open = true }.padding(6.dp),
                    )
                    DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
                        c.options.forEachIndexed { i, label ->
                            DropdownMenuItem(text = { Text(label) }, onClick = { open = false; onChoice(i) })
                        }
                    }
                }
            }
            DeviceControl.Kind.TIME_RANGE -> {
                val r = c.value as? ControlValue.TimeRange ?: return@Row
                fun pick(initial: Int, done: (Int) -> Unit) {
                    TimePickerDialog(context, { _, h, m -> done(h * 60 + m) }, initial / 60, initial % 60, true).show()
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(formatMinuteOfDay(r.fromMinute), style = Type.callout, color = Palette.accent,
                        modifier = Modifier.clickable(enabled = c.enabled) { pick(r.fromMinute) { onRange(it, r.toMinute) } }.padding(6.dp))
                    Text("–", style = Type.callout, color = Palette.secondary)
                    Text(formatMinuteOfDay(r.toMinute), style = Type.callout, color = Palette.accent,
                        modifier = Modifier.clickable(enabled = c.enabled) { pick(r.toMinute) { onRange(r.fromMinute, it) } }.padding(6.dp))
                }
            }
        }
    }
}

@Composable
private fun StepButton(label: String, enabled: Boolean, onClick: () -> Unit) {
    Box(
        Modifier.size(32.dp).clip(CircleShape).background(Palette.separator).clickable(enabled = enabled, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) { Text(label, style = Type.headline, color = if (enabled) Palette.label else Palette.tertiary) }
}

/** Dự báo 7 ngày (Open-Meteo) theo vị trí gần đúng; tự gửi khi kết nối, nút để cập nhật ngay. */
@Composable
private fun WeatherCard(device: WearableDevice, connected: Boolean) {
    val app = LocalContext.current.applicationContext as com.smartwear.lab.SmartWearApp
    val status by app.weather.status.collectAsState()
    val scope = rememberCoroutineScope()
    var busy by remember { mutableStateOf(false) }
    fun push() {
        busy = true
        scope.launch {
            app.weather.push(device, refresh = true)
            busy = false
        }
    }
    val permission = androidx.activity.compose.rememberLauncherForActivityResult(
        androidx.activity.result.contract.ActivityResultContracts.RequestPermission(),
    ) { granted -> if (granted) push() }
    SectionTitle("Thời tiết")
    GlassCard {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text("Dự báo 7 ngày trên đồng hồ", style = Type.callout, color = Palette.label)
                Text(status[device.id] ?: "Tự gửi khi kết nối, theo vị trí gần đúng của điện thoại", style = Type.footnote, color = Palette.secondary)
            }
            PillButton(
                if (busy) "Đang gửi…" else "Cập nhật",
                {
                    if (app.weather.hasPermission()) push()
                    else permission.launch(android.Manifest.permission.ACCESS_COARSE_LOCATION)
                },
                enabled = connected && !busy,
                kind = ButtonKind.PRIMARY,
            )
        }
    }
}
