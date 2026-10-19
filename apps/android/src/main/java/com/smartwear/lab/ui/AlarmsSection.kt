package com.smartwear.lab.ui

import android.app.TimePickerDialog
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Switch
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.smartwear.core.Alarm
import com.smartwear.core.AlarmClock
import kotlinx.coroutines.launch

/** "T2 T3 …" từ bitmask lặp (bit0 = thứ Hai … bit6 = Chủ nhật); 0 = một lần. */
fun repeatText(days: Int): String = when (days and 0x7F) {
    0 -> "Một lần"
    0x7F -> "Hằng ngày"
    0x1F -> "T2–T6"
    else -> listOf("T2", "T3", "T4", "T5", "T6", "T7", "CN").filterIndexed { i, _ -> days and (1 shl i) != 0 }.joinToString(" ")
}

/** Báo thức trên thiết bị: đọc khi mở, bật/tắt, xoá, thêm (chọn giờ, lặp T2–T6). */
@Composable
fun AlarmsSection(device: AlarmClock, connected: Boolean) {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    var alarms by remember(device) { mutableStateOf<List<Alarm>?>(null) }
    var error by remember(device) { mutableStateOf<String?>(null) }
    var busy by remember(device) { mutableStateOf(false) }

    fun act(block: suspend () -> Unit) {
        if (busy) return
        busy = true
        scope.launch {
            error = runCatching { block(); alarms = device.alarms() }.exceptionOrNull()?.message
            busy = false
        }
    }
    LaunchedEffect(device, connected) { if (connected) act {} }

    SectionTitle("Báo thức", trailing = alarms?.let { "${it.size}/${device.maxAlarms}" })
    GlassCard {
        Column {
            val list = alarms
            when {
                !connected -> Text("Kết nối để đọc báo thức.", style = Type.body, color = Palette.secondary)
                list == null -> Text(if (busy) "Đang đọc…" else "Chưa đọc.", style = Type.body, color = Palette.secondary)
                list.isEmpty() -> Text("Không có báo thức.", style = Type.body, color = Palette.secondary)
            }
            list?.forEachIndexed { i, a ->
                if (i > 0) Hairline(Modifier.padding(vertical = 2.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("%02d:%02d".format(a.hour, a.minute), style = Type.headline, color = Palette.label)
                        Text(repeatText(a.repeatDays) + (a.label?.let { " · $it" } ?: ""), style = Type.footnote, color = Palette.secondary)
                    }
                    TextButton(onClick = { act { device.deleteAlarm(a.id) } }, enabled = connected && !busy) { Text("Xoá", color = Palette.red) }
                    Switch(checked = a.enabled, onCheckedChange = { on -> act { device.setAlarm(a.copy(enabled = on)) } }, enabled = connected && !busy)
                }
            }
            Spacer(Modifier.height(8.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                PillButton("Đọc lại", { act {} }, Modifier.weight(1f), enabled = connected && !busy)
                PillButton("Thêm", {
                    TimePickerDialog(context, { _, h, m -> act { device.setAlarm(Alarm(-1, h, m, 0x1F, true, "SmartWear")) } }, 7, 0, true).show()
                }, Modifier.weight(1f), enabled = connected && !busy && (alarms?.size ?: 0) < device.maxAlarms)
            }
            error?.let { Text(it, style = Type.footnote, color = Palette.orange, modifier = Modifier.padding(top = 6.dp)) }
        }
    }
}
