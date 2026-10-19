package com.smartwear.lab.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.smartwear.core.Capability
import com.smartwear.core.ConnectionState
import com.smartwear.core.DeviceManager
import com.smartwear.core.Reading
import com.smartwear.core.ReadingStatus
import com.smartwear.core.WearableDevice
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/** Màn riêng của một thiết bị, sinh từ capability của chính thiết bị đó. */
@Composable
fun DeviceDetail(
    device: WearableDevice,
    devices: List<WearableDevice>,
    manager: DeviceManager,
    colorOf: (WearableDevice) -> Color,
    onSwitch: (WearableDevice) -> Unit,
    onBack: () -> Unit,
    onOpenWatchFace: () -> Unit = {},
) {
    val state by device.state.collectAsState()
    val info by device.info.collectAsState()
    val battery by device.battery.collectAsState()
    val charging by device.charging.collectAsState()
    val capabilities by device.capabilities.collectAsState()
    val measurable by device.measurable.collectAsState()
    val latest by device.latest.collectAsState()
    val measuring by device.measuring.collectAsState()
    val stats by device.stats.collectAsState()
    val lastError by device.lastError.collectAsState()
    val scope = rememberCoroutineScope()
    val connected = state == ConnectionState.CONNECTED
    val color = colorOf(device)

    var focus by rememberSaveable(device.id) { mutableStateOf<Capability?>(null) }
    val hero = measuring ?: focus ?: measurable.firstOrNull { it in latest } ?: measurable.firstOrNull()
    var packetsAtStart by remember(device.id) { mutableLongStateOf(0L) }

    Column {
        // Chuyển nhanh giữa các thiết bị mà vẫn thấy trạng thái của chúng.
        Row(
            Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Chip("‹  Tất cả", selected = false, onClick = onBack)
            devices.forEach { d ->
                Chip(d.name.substringBefore('_'), selected = d.id == device.id, onClick = { onSwitch(d) }, dot = colorOf(d))
            }
        }

        Row(Modifier.padding(top = 20.dp), verticalAlignment = Alignment.CenterVertically) {
            Orb(color, 52.dp, pulseKey = stats.packetsReceived.takeIf { it > 0 }, dimmed = !connected)
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(info?.model ?: device.name, style = Type.largeTitle.copy(fontSize = 28.sp), color = Palette.label, maxLines = 1)
                Text("${device.name} · ${device.driver.displayName}", style = Type.footnote, color = Palette.secondary, maxLines = 1)
            }
        }
        Row(Modifier.padding(top = 10.dp), verticalAlignment = Alignment.CenterVertically) {
            StateLabel(state)
            Spacer(Modifier.width(16.dp))
            BatteryBadge(battery, charging = charging)
        }

        // Điểm nhấn: phép đo đang chạy hoặc giá trị gần nhất.
        Spacer(Modifier.height(18.dp))
        if (hero != null) {
            val reading = latest[hero]
            val style = hero.style
            val running = measuring == hero
            GlassCard {
                Column {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(style.label, style = Type.headline, color = style.color, modifier = Modifier.weight(1f))
                        Text(
                            when {
                                running && reading?.status == ReadingStatus.OK -> "đang đo · có kết quả"
                                running -> "đang đo · ${stats.packetsReceived - packetsAtStart} gói"
                                reading != null -> "lúc " + SimpleDateFormat("HH:mm", Locale.US).format(Date(reading.timestamp))
                                else -> ""
                            },
                            style = Type.footnote,
                            color = Palette.secondary,
                        )
                    }
                    Row(verticalAlignment = Alignment.Bottom) {
                        val shown = reading?.display()
                        Text(
                            shown ?: if (reading?.status == ReadingStatus.NOT_WORN) "Chưa đeo" else "—",
                            style = if (shown != null) Type.hero else Type.hero.copy(fontSize = 44.sp),
                            color = if (reading?.status == ReadingStatus.NOT_WORN) Palette.orange else Palette.label,
                        )
                        if (shown != null) Text(" ${style.unit}", style = Type.title, color = Palette.secondary, modifier = Modifier.padding(bottom = 14.dp))
                    }
                    if (running) PacketLane((stats.packetsReceived - packetsAtStart).toInt(), style.color, Modifier.padding(vertical = 8.dp))
                    // Phép đo cần chạm cảm biến (thành phần máu / cơ thể): nhắc đặt ngón tay, kèm tiến độ khi đang đo.
                    if (reading?.needsTouch == true && (running || reading.status != ReadingStatus.OK)) {
                        val progress = reading.extra[Reading.EXTRA_PROGRESS]?.takeIf { running }?.let { " · ${it.toInt()} %" }.orEmpty()
                        Text("Đặt ngón tay lên cảm biến của vòng tay$progress", style = Type.callout, color = Palette.orange)
                    }
                    // Ghi chú của driver khi đang đo (ví dụ GloryFit HR 24h: đo trên đồng hồ để có kết quả ngay).
                    if (running) reading?.note?.takeIf { it != Reading.NOTE_TOUCH_SENSOR }?.let { Text(it, style = Type.footnote, color = Palette.secondary) }
                    Spacer(Modifier.height(8.dp))
                    if (running) {
                        PillButton("Dừng đo", { manager.stopMeasure(device) }, Modifier.fillMaxWidth())
                    } else {
                        PillButton(
                            "Đo ${style.label.lowercase()}",
                            {
                                packetsAtStart = stats.packetsReceived
                                manager.measure(device, hero)
                            },
                            Modifier.fillMaxWidth(),
                            kind = ButtonKind.PRIMARY,
                            enabled = connected && measuring == null,
                        )
                    }
                }
            }
        } else if (connected) {
            GlassCard { Text("Thiết bị này không có phép đo trực tiếp.", style = Type.body, color = Palette.secondary) }
        }

        // Toàn bộ chức năng của thiết bị này, sinh từ capability.
        SectionTitle("Chức năng", trailing = if (capabilities.isEmpty()) "chưa đọc" else "${capabilities.size} khả năng")
        if (capabilities.isEmpty()) {
            Text(
                if (connected) "Thiết bị không báo khả năng nào." else "Kết nối để đọc bảng khả năng.",
                style = Type.body,
                color = Palette.secondary,
            )
        }
        capabilities.sortedBy { it.style.historyOnly }.chunked(2).forEach { row ->
            Row(Modifier.padding(bottom = 10.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                row.forEach { cap ->
                    val style = cap.style
                    val reading = latest[cap]
                    val canMeasure = cap in measurable
                    Column(
                        Modifier
                            .weight(1f)
                            .glass(strength = if (cap == hero) 1.6f else 1f)
                            .clickable(enabled = canMeasure) { focus = cap }
                            .padding(14.dp),
                    ) {
                        Text(style.label, style = Type.callout, color = style.color)
                        Spacer(Modifier.height(6.dp))
                        when {
                            !canMeasure -> Text(
                                if (device.supportsHistory && cap in setOf(Capability.STEPS, Capability.SLEEP)) "Xem ở mục Lịch sử" else "Chưa hỗ trợ trong app",
                                style = Type.footnote,
                                color = Palette.secondary,
                            )
                            reading?.display() != null -> Column {
                                Row(verticalAlignment = Alignment.Bottom) {
                                    Text(reading.display()!!, style = Type.metric, color = Palette.label)
                                    Text(" ${style.unit}", style = Type.footnote, color = Palette.secondary, modifier = Modifier.padding(bottom = 4.dp))
                                }
                                reading.extraText()?.let { Text(it, style = Type.footnote, color = Palette.secondary) }
                            }
                            else -> Text(
                                reading.statusText(),
                                style = Type.callout,
                                color = if (reading?.status == ReadingStatus.NOT_WORN) Palette.orange else Palette.secondary,
                            )
                        }
                    }
                }
                if (row.size == 1) Spacer(Modifier.weight(1f))
            }
        }

        SectionTitle("Thiết bị")
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            if (connected) {
                PillButton("Cập nhật pin", { scope.launch { device.refreshBattery() } }, Modifier.weight(1f))
                PillButton("Ngắt kết nối", { manager.disconnect(device) }, Modifier.weight(1f), kind = ButtonKind.DESTRUCTIVE)
            } else {
                PillButton(
                    if (state == ConnectionState.CONNECTING) "Đang kết nối…" else "Kết nối",
                    { manager.connect(device) },
                    Modifier.weight(1f),
                    kind = ButtonKind.PRIMARY,
                    enabled = state == ConnectionState.DISCONNECTED,
                )
                PillButton("Quên", { manager.remove(device); onBack() }, Modifier.weight(1f), kind = ButtonKind.DESTRUCTIVE)
            }
        }
        if (lastError != null) {
            Text(lastError!!, style = Type.footnote, color = Palette.orange, modifier = Modifier.padding(top = 10.dp))
        }

        if (device is com.smartwear.core.WatchFaceCustomizable) {
            SectionTitle("Mặt đồng hồ")
            GlassCard(onClick = onOpenWatchFace) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("Tuỳ chỉnh mặt đồng hồ", style = Type.headline, color = Palette.label)
                        Text("Ảnh nền, màu, vị trí giờ và 10 thành phần", style = Type.footnote, color = Palette.secondary)
                    }
                    Text("›", style = Type.title, color = Palette.secondary)
                }
            }
            if (device.supportsWatchFace) WatchFaceLibrarySection(device)
        }

        ControlsSection(device)

        if (device is com.smartwear.core.AlarmClock && device.supportsAlarms) AlarmsSection(device, connected)

        HistorySection(device, manager)

        TechnicalDetails(device)
    }
}

/** Tầng dưới: mọi chi tiết kỹ thuật, ẩn mặc định. */
@Composable
private fun TechnicalDetails(device: WearableDevice) {
    var open by rememberSaveable(device.id) { mutableStateOf(false) }
    val info by device.info.collectAsState()
    val stats by device.stats.collectAsState()
    val log by device.log.collectAsState()
    val time = remember { SimpleDateFormat("HH:mm:ss", Locale.US) }

    Row(
        Modifier.fillMaxWidth().padding(top = 24.dp).clickable { open = !open }.padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text("Chi tiết kỹ thuật", style = Type.headline, color = Palette.label, modifier = Modifier.weight(1f))
        Text(if (open) "Ẩn" else "Hiện", style = Type.callout, color = Palette.accent)
    }
    AnimatedVisibility(open) {
        Column {
            GlassCard {
                Column {
                    KeyValue("Model", info?.model ?: "—")
                    KeyValue("Phần cứng", info?.hardware ?: "—", mono = true)
                    KeyValue("Firmware", info?.firmware ?: "—", mono = true)
                    info?.extra?.forEach { (k, v) -> KeyValue(k, v, mono = v.contains(':') || v.count { it == ' ' } > 3) }
                }
            }
            Spacer(Modifier.height(10.dp))
            GlassCard {
                Column {
                    KeyValue("RSSI", stats.rssi?.let { "$it dBm" } ?: "chưa đo")
                    KeyValue("Gói đã nhận", stats.packetsReceived.toString())
                    KeyValue("Gói/giây (5 s)", String.format(Locale("vi"), "%.1f", stats.packetsPerSecond))
                    KeyValue("Lỗi / timeout", stats.errors.toString())
                    KeyValue("Độ trễ gần nhất", stats.lastLatencyMs?.let { "$it ms" } ?: "chưa đo")
                }
            }
            Spacer(Modifier.height(10.dp))
            GlassCard {
                Column {
                    Text("Gói tin gần nhất", style = Type.callout, color = Palette.label)
                    Spacer(Modifier.height(6.dp))
                    if (log.isEmpty()) Text("Chưa có gói tin.", style = Type.footnote, color = Palette.secondary)
                    log.takeLast(40).asReversed().forEach { e ->
                        Text(
                            "${time.format(Date(e.timestamp))} ${if (e.outgoing) "→" else "←"} ${e.hex}",
                            style = Type.mono,
                            color = if (e.outgoing) Palette.secondary else Palette.label,
                        )
                        if (e.note != null) Text("            ${e.note}", style = Type.mono.copy(fontWeight = FontWeight.Medium), color = Palette.accent)
                    }
                }
            }
        }
    }
}
