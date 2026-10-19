package com.smartwear.lab.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.smartwear.core.Capability
import com.smartwear.core.ConnectionState
import com.smartwear.core.DeviceManager
import com.smartwear.core.ScanEntry
import com.smartwear.core.WearableDevice
import java.util.Locale

// ---------- Tab "Thiết bị" ----------

@Composable
fun DevicesList(
    devices: List<WearableDevice>,
    manager: DeviceManager,
    colorOf: (WearableDevice) -> Color,
    onOpen: (WearableDevice) -> Unit,
    onAdd: () -> Unit,
) {
    val connectedCount = devices.count { it.state.collectAsState().value == ConnectionState.CONNECTED }
    Text("Thiết bị", style = Type.largeTitle, color = Palette.label)
    Text(
        "$connectedCount đang kết nối · giới hạn ~${manager.maxConnections}",
        style = Type.body,
        color = Palette.secondary,
    )
    Spacer(Modifier.height(16.dp))
    MeasureAllBar(devices, manager)

    SectionTitle("Đang quản lý", trailing = "${devices.size}")
    if (devices.isEmpty()) {
        GlassCard(onClick = onAdd) {
            Column {
                Text("Chưa có thiết bị", style = Type.headline, color = Palette.label)
                Text("Chạm để quét và thêm nhiều thiết bị cùng lúc.", style = Type.body, color = Palette.secondary)
            }
        }
    }
    devices.forEach { device ->
        DeviceRow(device, colorOf(device), manager, onOpen)
        Spacer(Modifier.height(10.dp))
    }
}

@Composable
private fun DeviceRow(device: WearableDevice, color: Color, manager: DeviceManager, onOpen: (WearableDevice) -> Unit) {
    val state by device.state.collectAsState()
    val battery by device.battery.collectAsState()
    val latest by device.latest.collectAsState()
    val measuring by device.measuring.collectAsState()
    val stats by device.stats.collectAsState()
    val info by device.info.collectAsState()
    val headline = (measuring?.let { latest[it] }) ?: latest.values.maxByOrNull { it.timestamp }

    GlassCard(onClick = { onOpen(device) }) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Orb(color, 40.dp, pulseKey = stats.packetsReceived.takeIf { it > 0 }, dimmed = state != ConnectionState.CONNECTED)
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(info?.model ?: device.name, style = Type.headline, color = Palette.label, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(
                    when {
                        measuring != null -> "Đang đo ${measuring!!.style.label.lowercase()}"
                        state == ConnectionState.CONNECTED -> "Đã kết nối · ${device.driver.displayName}"
                        state == ConnectionState.CONNECTING -> "Đang kết nối…"
                        else -> "Chưa kết nối · ${device.driver.displayName}"
                    },
                    style = Type.footnote,
                    color = if (measuring != null) Palette.green else Palette.secondary,
                    maxLines = 1,
                )
                Spacer(Modifier.height(6.dp))
                BatteryBadge(battery)
            }
            Column(horizontalAlignment = Alignment.End) {
                if (headline != null) {
                    val value = headline.display()
                    Row(verticalAlignment = Alignment.Bottom) {
                        Text(
                            value ?: headline.statusText(),
                            style = if (value != null) Type.metric else Type.callout,
                            color = if (value != null) Palette.label else Palette.orange,
                        )
                        if (value != null) Text(" ${headline.capability.style.unit}", style = Type.footnote, color = Palette.secondary, modifier = Modifier.padding(bottom = 4.dp))
                    }
                    Text(headline.capability.style.label, style = Type.caption, color = headline.capability.style.color)
                } else if (state == ConnectionState.DISCONNECTED) {
                    PillButton("Kết nối", { manager.connect(device) })
                }
            }
        }
    }
}

/** Đo cùng một chỉ số trên mọi thiết bị đang kết nối có hỗ trợ. */
@Composable
fun MeasureAllBar(devices: List<WearableDevice>, manager: DeviceManager) {
    val available = devices
        .filter { it.state.collectAsState().value == ConnectionState.CONNECTED }
        .flatMap { it.measurable.collectAsState().value }
        .toSet()
    val ordered = Capability.entries.filter { it in available }
    var selected by rememberSaveable { mutableStateOf<Capability?>(null) }
    val target = selected?.takeIf { it in available } ?: ordered.firstOrNull()
    val anyMeasuring = devices.any { it.measuring.collectAsState().value != null }

    GlassCard {
        Column {
            Text("Đo đồng loạt", style = Type.headline, color = Palette.label)
            Text(
                if (ordered.isEmpty()) "Kết nối thiết bị để đo." else "Cùng một chỉ số trên mọi thiết bị hỗ trợ.",
                style = Type.footnote,
                color = Palette.secondary,
            )
            if (ordered.isNotEmpty()) {
                Spacer(Modifier.height(12.dp))
                Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    ordered.forEach { cap ->
                        val count = devices.count { cap in it.measurable.value && it.state.value == ConnectionState.CONNECTED }
                        Chip("${cap.style.label} · $count", selected = cap == target, onClick = { selected = cap }, dot = cap.style.color)
                    }
                }
                Spacer(Modifier.height(12.dp))
                if (anyMeasuring) {
                    PillButton("Dừng tất cả", { manager.stopAllMeasurements() }, Modifier.fillMaxWidth())
                } else {
                    PillButton(
                        "Đo ${target?.style?.label?.lowercase().orEmpty()} trên tất cả",
                        { target?.let(manager::measureAll) },
                        Modifier.fillMaxWidth(),
                        kind = ButtonKind.PRIMARY,
                    )
                }
            }
        }
    }
}

// ---------- Tab "Thêm" ----------

@Composable
fun AddScreen(manager: DeviceManager, devices: List<WearableDevice>, onConnected: () -> Unit) {
    val results by manager.scanResults.collectAsState()
    val scanning by manager.scanning.collectAsState()
    val scanError by manager.scanError.collectAsState()
    val chosen = remember { mutableStateListOf<String>() }
    val managedIds = devices.map { it.id }.toSet()

    Row(verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text("Thêm thiết bị", style = Type.largeTitle, color = Palette.label)
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (scanning) {
                    CircularProgressIndicator(Modifier.size(14.dp), color = Palette.secondary, strokeWidth = 1.5.dp)
                    Spacer(Modifier.width(8.dp))
                }
                Text(
                    when {
                        scanError != null -> "Lỗi quét: $scanError"
                        scanning -> "Đang tìm thiết bị gần đây…"
                        else -> "Chọn nhiều thiết bị để kết nối cùng lúc"
                    },
                    style = Type.body,
                    color = if (scanError != null) Palette.orange else Palette.secondary,
                )
            }
        }
        PillButton(if (scanning) "Dừng" else "Quét lại", { if (scanning) manager.stopScan() else manager.startScan() })
    }

    results.groupBy { it.driver.displayName }.forEach { (driverName, entries) ->
        SectionTitle(driverName, trailing = "${entries.size} thiết bị")
        Column(Modifier.glass()) {
            entries.sortedByDescending { it.scanned.rssi }.forEachIndexed { i, entry ->
                if (i > 0) Hairline(Modifier.padding(start = 56.dp))
                ScanRow(entry, managed = entry.scanned.address in managedIds, selected = entry.scanned.address in chosen) {
                    if (entry.scanned.address in chosen) chosen.remove(entry.scanned.address) else chosen.add(entry.scanned.address)
                }
            }
        }
    }
    if (results.isEmpty() && !scanning) {
        Spacer(Modifier.height(16.dp))
        Text("Chưa thấy thiết bị được hỗ trợ. Đưa thiết bị lại gần rồi quét lại.", style = Type.body, color = Palette.secondary)
    }

    Spacer(Modifier.height(20.dp))
    val selectedEntries = results.filter { it.scanned.address in chosen }
    PillButton(
        if (selectedEntries.isEmpty()) "Chọn thiết bị để kết nối" else "Kết nối ${selectedEntries.size} thiết bị",
        {
            manager.connect(selectedEntries)
            chosen.clear()
            onConnected()
        },
        Modifier.fillMaxWidth(),
        kind = ButtonKind.PRIMARY,
        enabled = selectedEntries.isNotEmpty(),
    )
    Text(
        "Android thường cho tối đa ~${manager.maxConnections} kết nối Bluetooth LE cùng lúc.",
        style = Type.footnote,
        color = Palette.tertiary,
        modifier = Modifier.padding(top = 10.dp),
    )
}

@Composable
private fun ScanRow(entry: ScanEntry, managed: Boolean, selected: Boolean, onToggle: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(enabled = !managed, onClick = onToggle).padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        SelectMark(selected || managed, enabled = !managed)
        Spacer(Modifier.width(16.dp))
        Column(Modifier.weight(1f)) {
            Text(entry.match.model, style = Type.headline, color = Palette.label, maxLines = 1)
            Text(
                if (managed) "Đã thêm · ${entry.scanned.name.orEmpty()}" else "${entry.scanned.name.orEmpty()} · ${entry.scanned.address}",
                style = Type.footnote,
                color = Palette.secondary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        SignalBars(entry.scanned.rssi)
    }
}

@Composable
private fun SignalBars(rssi: Int) {
    val level = when { rssi >= -60 -> 4; rssi >= -70 -> 3; rssi >= -80 -> 2; else -> 1 }
    Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(2.dp)) {
        for (i in 1..4) {
            Box(
                Modifier
                    .width(4.dp)
                    .height((4 + i * 3).dp)
                    .clip(RoundedCornerShape(2.dp))
                    .background(if (i <= level) Palette.label else Palette.tertiary.copy(alpha = 0.4f)),
            )
        }
    }
}

// ---------- Tab "Khả thi" ----------

@Composable
fun LabScreen(devices: List<WearableDevice>, manager: DeviceManager, colorOf: (WearableDevice) -> Color) {
    val connected = devices.filter { it.state.collectAsState().value == ConnectionState.CONNECTED }
    Text("Khả thi", style = Type.largeTitle, color = Palette.label)
    Text("Kết nối song song có ổn không — số đo thật trên máy này.", style = Type.body, color = Palette.secondary)
    Spacer(Modifier.height(16.dp))

    GlassCard {
        Column {
            Row(verticalAlignment = Alignment.Bottom) {
                Text("${connected.size}", style = Type.hero, color = Palette.label)
                Text(" / ${manager.maxConnections}", style = Type.title, color = Palette.secondary, modifier = Modifier.padding(bottom = 16.dp))
                Spacer(Modifier.weight(1f))
                Text("kết nối\nđồng thời", style = Type.footnote, color = Palette.secondary, modifier = Modifier.padding(bottom = 16.dp))
            }
            Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                for (i in 0 until manager.maxConnections) {
                    Box(
                        Modifier
                            .weight(1f)
                            .height(6.dp)
                            .clip(RoundedCornerShape(3.dp))
                            .background(connected.getOrNull(i)?.let(colorOf) ?: Color.White.copy(alpha = 0.12f)),
                    )
                }
            }
        }
    }

    Spacer(Modifier.height(12.dp))
    MeasureAllBar(devices, manager)

    SectionTitle("Kênh", trailing = "gói/giây · 20 s")
    if (devices.isEmpty()) Text("Chưa có thiết bị.", style = Type.body, color = Palette.secondary)
    devices.forEach { device ->
        val stats by device.stats.collectAsState()
        val state by device.state.collectAsState()
        val info by device.info.collectAsState()
        GlassCard {
            Column {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Orb(colorOf(device), 22.dp, pulseKey = stats.packetsReceived.takeIf { it > 0 }, dimmed = state != ConnectionState.CONNECTED)
                    Spacer(Modifier.width(8.dp))
                    Text(info?.model ?: device.name, style = Type.headline, color = Palette.label, modifier = Modifier.weight(1f), maxLines = 1)
                    Text(String.format(Locale("vi"), "%.1f gói/s", stats.packetsPerSecond), style = Type.callout, color = Palette.label)
                }
                Spacer(Modifier.height(10.dp))
                Sparkline(stats.history, colorOf(device))
                Spacer(Modifier.height(10.dp))
                Row {
                    Metric("RSSI", stats.rssi?.let { "$it dBm" } ?: "chưa đo", Modifier.weight(1f))
                    Metric("Độ trễ", stats.lastLatencyMs?.let { "$it ms" } ?: "chưa đo", Modifier.weight(1f))
                    Metric("Lỗi", stats.errors.toString(), Modifier.weight(1f))
                    Metric("Tổng gói", stats.packetsReceived.toString(), Modifier.weight(1f))
                }
            }
        }
        Spacer(Modifier.height(10.dp))
    }
}

@Composable
private fun Metric(label: String, value: String, modifier: Modifier = Modifier) {
    Column(modifier) {
        Text(label, style = Type.caption, color = Palette.secondary)
        Text(value, style = Type.callout, color = Palette.label, maxLines = 1)
    }
}
