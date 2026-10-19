package com.smartwear.lab.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
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
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.unit.dp
import com.smartwear.core.Capability
import com.smartwear.core.ConnectionState
import com.smartwear.core.DeviceManager
import com.smartwear.core.HistoryPoint
import com.smartwear.core.SleepSession
import com.smartwear.core.SleepStage
import com.smartwear.core.WearableDevice
import java.text.SimpleDateFormat
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.TextStyle
import java.util.Date
import java.util.Locale

private val vi = Locale("vi")

/** Mục "Lịch sử" trong màn chi tiết: đồng bộ và xem dữ liệu đã lưu trên thiết bị, theo ngày. */
@Composable
fun HistorySection(device: WearableDevice, manager: DeviceManager) {
    if (!device.supportsHistory) return
    val history by device.history.collectAsState()
    val progress by device.syncProgress.collectAsState()
    val state by device.state.collectAsState()
    val measuring by device.measuring.collectAsState()
    var dayOffset by rememberSaveable(device.id) { mutableIntStateOf(0) }
    val zone = ZoneId.systemDefault()

    SectionTitle(
        "Lịch sử",
        trailing = history?.let { "đồng bộ lúc " + SimpleDateFormat("HH:mm", Locale.US).format(Date(it.syncedAt)) },
    )

    val p = progress
    if (p != null) {
        GlassCard {
            Column {
                Text("Đang đồng bộ · ${p.step}", style = Type.callout, color = Palette.label)
                Spacer(Modifier.height(10.dp))
                LinearProgressIndicator(
                    progress = { (p.done + 1f) / p.total.coerceAtLeast(1) },
                    modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(3.dp)),
                    color = Palette.label,
                    trackColor = Color.White.copy(alpha = 0.12f),
                )
                Text("${p.done + 1}/${p.total} bước", style = Type.footnote, color = Palette.secondary, modifier = Modifier.padding(top = 8.dp))
            }
        }
        return
    }

    PillButton(
        if (history == null) "Đồng bộ 7 ngày" else "Đồng bộ lại",
        { manager.syncHistory(device, 7) },
        Modifier.fillMaxWidth(),
        kind = if (history == null) ButtonKind.PRIMARY else ButtonKind.GLASS,
        enabled = state == ConnectionState.CONNECTED && measuring == null,
    )
    val h = history ?: return

    // Chọn ngày.
    Spacer(Modifier.height(12.dp))
    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        for (d in 0 until h.days.coerceAtLeast(1)) {
            val date = LocalDate.now().minusDays(d.toLong())
            val label = when (d) {
                0 -> "Hôm nay"
                1 -> "Hôm qua"
                else -> date.dayOfWeek.getDisplayName(TextStyle.SHORT, vi).replaceFirstChar { it.uppercase() } + " ${date.dayOfMonth}"
            }
            Chip(label, selected = d == dayOffset, onClick = { dayOffset = d })
        }
    }
    val date = LocalDate.now().minusDays(dayOffset.toLong())
    val dayStart = date.atStartOfDay(zone).toInstant().toEpochMilli()
    val dayEnd = dayStart + 86_400_000L
    fun points(cap: Capability) = h.series[cap].orEmpty().filter { it.timestamp in dayStart until dayEnd }

    Spacer(Modifier.height(12.dp))
    ActivityCard(points(Capability.STEPS), if (dayOffset == 0) h.today else null, dayStart)
    Spacer(Modifier.height(10.dp))
    SleepCard(
        session = h.sleep.lastOrNull { !it.nap && it.end in dayStart until dayEnd },
        naps = h.sleep.filter { it.nap && it.end in dayStart until dayEnd },
    )
    if (device.capabilities.value.contains(Capability.HEART_RATE) || h.workouts.isNotEmpty()) {
        Spacer(Modifier.height(10.dp))
        WorkoutCard(h.workouts.filter { it.start in dayStart until dayEnd })
    }

    listOf(
        Capability.HEART_RATE, Capability.SPO2, Capability.HRV, Capability.STRESS, Capability.TEMPERATURE, Capability.BLOOD_SUGAR,
        Capability.MET, Capability.URIC_ACID, Capability.BLOOD_LIPIDS,
    ).forEach { cap ->
        if (cap in h.series) {
            Spacer(Modifier.height(10.dp))
            SeriesCard(cap, points(cap), dayStart)
        }
    }

    if (h.errors.isNotEmpty()) {
        Spacer(Modifier.height(10.dp))
        GlassCard {
            Column {
                Text("Không đồng bộ được", style = Type.callout, color = Palette.orange)
                h.errors.forEach { Text("· $it", style = Type.footnote, color = Palette.secondary, modifier = Modifier.padding(top = 4.dp)) }
            }
        }
    }
}

@Composable
private fun ActivityCard(slots: List<HistoryPoint>, today: com.smartwear.core.ActivityTotals?, dayStart: Long) {
    val color = Capability.STEPS.style.color
    val steps = today?.steps ?: slots.sumOf { it.value }.toInt()
    val calories = today?.calories ?: slots.sumOf { it.extra["calories"] ?: 0.0 }.toInt()
    val distance = today?.distanceMeters ?: slots.sumOf { it.extra["distance"] ?: 0.0 }.toInt()
    GlassCard {
        Column {
            Text("Hoạt động", style = Type.headline, color = color)
            Row(verticalAlignment = Alignment.Bottom) {
                Text(String.format(vi, "%,d", steps), style = Type.hero.copy(fontSize = Type.metric.fontSize * 1.6f), color = Palette.label)
                Text(" bước", style = Type.title, color = Palette.secondary, modifier = Modifier.padding(bottom = 6.dp))
            }
            Text(
                String.format(vi, "%.0f kcal · %.2f km", calories / 1000.0, distance / 1000.0),
                style = Type.callout,
                color = Palette.secondary,
            )
            Spacer(Modifier.height(12.dp))
            if (slots.isEmpty()) {
                Text("Không có dữ liệu bước theo giờ.", style = Type.footnote, color = Palette.tertiary)
            } else {
                // Gộp khung 15 phút thành 24 cột theo giờ.
                val hourly = DoubleArray(24)
                slots.forEach { hourly[((it.timestamp - dayStart) / 3_600_000L).toInt().coerceIn(0, 23)] += it.value }
                BarChart(hourly.toList(), color)
                HourAxis()
            }
        }
    }
}

@Composable
private fun WorkoutCard(workouts: List<com.smartwear.core.Workout>) {
    val time = SimpleDateFormat("HH:mm", Locale.US)
    GlassCard {
        Column {
            Text("Bài tập", style = Type.headline, color = Palette.orange)
            if (workouts.isEmpty()) {
                Text("Không có bài tập trong ngày này. Bắt đầu một bài trên đồng hồ rồi đồng bộ lại.", style = Type.body,
                    color = Palette.secondary, modifier = Modifier.padding(top = 6.dp))
                return@Column
            }
            workouts.forEach { w ->
                val mins = w.activeSeconds / 60
                val parts = listOfNotNull(
                    "${time.format(Date(w.start))} · ${mins} phút ${w.activeSeconds % 60} giây",
                    w.distanceMeters?.let { "%.2f km".format(it / 1000.0) },
                    w.calories?.let { "$it kcal" },
                    w.steps?.let { "$it bước" },
                    w.avgHeartRate?.let { "nhịp tim tb $it" + (w.maxHeartRate?.let { m -> " · max $m" } ?: "") },
                    w.paceSecondsPerKm?.let { "pace ${it / 60}'${"%02d".format(it % 60)}\"/km" },
                )
                Text(w.name, style = Type.callout, color = Palette.label, modifier = Modifier.padding(top = 8.dp))
                Text(parts.joinToString(" · "), style = Type.footnote, color = Palette.secondary)
            }
        }
    }
}

@Composable
private fun SleepCard(session: SleepSession?, naps: List<SleepSession>) {
    val color = Capability.SLEEP.style.color
    val time = SimpleDateFormat("HH:mm", Locale.US)
    GlassCard {
        Column {
            Text("Giấc ngủ", style = Type.headline, color = color)
            naps.forEach { nap ->
                Text(
                    "Ngủ trưa ${time.format(Date(nap.start))}–${time.format(Date(nap.end))} · ${nap.asleepMinutes} phút",
                    style = Type.callout,
                    color = Palette.label,
                    modifier = Modifier.padding(top = 6.dp),
                )
            }
            if (session == null) {
                Text(
                    if (naps.isEmpty()) "Không có dữ liệu giấc ngủ cho ngày này." else "Không có giấc ngủ đêm.",
                    style = Type.body,
                    color = Palette.secondary,
                    modifier = Modifier.padding(top = 6.dp),
                )
                return@Column
            }
            val asleep = session.asleepMinutes
            Row(verticalAlignment = Alignment.Bottom) {
                Text("${asleep / 60}", style = Type.hero.copy(fontSize = Type.metric.fontSize * 1.6f), color = Palette.label)
                Text(" giờ ", style = Type.title, color = Palette.secondary, modifier = Modifier.padding(bottom = 6.dp))
                Text("${asleep % 60}", style = Type.hero.copy(fontSize = Type.metric.fontSize * 1.6f), color = Palette.label)
                Text(" phút", style = Type.title, color = Palette.secondary, modifier = Modifier.padding(bottom = 6.dp))
            }
            Text("${time.format(Date(session.start))} – ${time.format(Date(session.end))}", style = Type.callout, color = Palette.secondary)
            Spacer(Modifier.height(12.dp))
            // Thanh giai đoạn theo thời gian thật.
            Canvas(Modifier.fillMaxWidth().height(36.dp)) {
                val total = (session.end - session.start).coerceAtLeast(1)
                session.segments.forEach { seg ->
                    val x = size.width * (seg.start - session.start) / total
                    val w = size.width * seg.minutes * 60_000f / total
                    val (row, c) = when (seg.stage) {
                        SleepStage.AWAKE -> 0 to Color(0xFFFF9F0A)
                        SleepStage.REM -> 1 to Color(0xFF64D2FF)
                        SleepStage.LIGHT -> 2 to Color(0xFF7D7AFF)
                        SleepStage.DEEP -> 3 to Color(0xFF4B3FD8)
                        SleepStage.UNKNOWN -> 2 to Palette.tertiary
                    }
                    val rowH = size.height / 4
                    drawRoundRect(c, Offset(x, row * rowH + 1), Size(w.coerceAtLeast(2f), rowH - 2), CornerRadius(3.dp.toPx()))
                }
            }
            Spacer(Modifier.height(10.dp))
            Row {
                StageLegend("Thức", session.minutes(SleepStage.AWAKE), Color(0xFFFF9F0A), Modifier.weight(1f))
                StageLegend("REM", session.minutes(SleepStage.REM), Color(0xFF64D2FF), Modifier.weight(1f))
                StageLegend("Nông", session.minutes(SleepStage.LIGHT), Color(0xFF7D7AFF), Modifier.weight(1f))
                StageLegend("Sâu", session.minutes(SleepStage.DEEP), Color(0xFF4B3FD8), Modifier.weight(1f))
            }
        }
    }
}

@Composable
private fun StageLegend(label: String, minutes: Int, color: Color, modifier: Modifier) {
    Column(modifier) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(8.dp).clip(CircleShape).background(color))
            Spacer(Modifier.width(6.dp))
            Text(label, style = Type.caption, color = Palette.secondary)
        }
        Text("${minutes / 60}g ${minutes % 60}p", style = Type.callout, color = Palette.label)
    }
}

@Composable
private fun SeriesCard(cap: Capability, points: List<HistoryPoint>, dayStart: Long) {
    val style = cap.style
    GlassCard {
        Column {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(style.label, style = Type.headline, color = style.color, modifier = Modifier.weight(1f))
                Text("${points.size} điểm", style = Type.footnote, color = Palette.secondary)
            }
            if (points.isEmpty()) {
                Text("Không có dữ liệu cho ngày này.", style = Type.body, color = Palette.secondary, modifier = Modifier.padding(top = 6.dp))
                return@Column
            }
            val values = points.map { it.value }
            val fmt = { v: Double -> cap.format(v) }
            Row(Modifier.padding(top = 6.dp), verticalAlignment = Alignment.Bottom) {
                Text(fmt(values.average()), style = Type.metric, color = Palette.label)
                Text(" ${style.unit} trung bình", style = Type.footnote, color = Palette.secondary, modifier = Modifier.padding(bottom = 4.dp))
            }
            val low = if (cap == Capability.SPO2) points.minOf { it.extra["min"] ?: it.value } else values.min()
            Text("thấp ${fmt(low)} · cao ${fmt(values.max())}", style = Type.footnote, color = Palette.secondary)
            Spacer(Modifier.height(12.dp))
            DotChart(points, dayStart, style.color)
            HourAxis()
        }
    }
}

@Composable
private fun BarChart(values: List<Double>, color: Color) {
    Canvas(Modifier.fillMaxWidth().height(72.dp)) {
        val max = (values.maxOrNull() ?: 0.0).coerceAtLeast(1.0)
        val gap = 3.dp.toPx()
        val w = (size.width - gap * (values.size - 1)) / values.size
        values.forEachIndexed { i, v ->
            val h = if (v <= 0) 2.dp.toPx() else (size.height * v / max).toFloat().coerceAtLeast(3.dp.toPx())
            drawRoundRect(
                if (v <= 0) Color.White.copy(alpha = 0.10f) else color,
                Offset(i * (w + gap), size.height - h),
                Size(w, h),
                CornerRadius(w / 2),
            )
        }
    }
}

/** Biểu đồ điểm theo 24 giờ, trục dọc co giãn theo khoảng giá trị. */
@Composable
private fun DotChart(points: List<HistoryPoint>, dayStart: Long, color: Color) {
    Canvas(Modifier.fillMaxWidth().height(80.dp)) {
        val lo = points.minOf { it.extra["min"] ?: it.value }
        val hi = points.maxOf { it.value }
        val span = (hi - lo).coerceAtLeast(1.0)
        fun y(v: Double) = (size.height - 6.dp.toPx()) * (1 - ((v - lo) / span)).toFloat() + 3.dp.toPx()
        for (i in 1..3) {
            val gy = size.height * i / 4
            drawLine(Color.White.copy(alpha = 0.06f), Offset(0f, gy), Offset(size.width, gy), 1f)
        }
        points.forEach { p ->
            val x = size.width * ((p.timestamp - dayStart) / 86_400_000f)
            val min = p.extra["min"]
            if (min != null && min < p.value) {
                drawLine(color.copy(alpha = 0.5f), Offset(x, y(min)), Offset(x, y(p.value)), 4.dp.toPx(), StrokeCap.Round)
            }
            drawCircle(color, 2.6.dp.toPx(), Offset(x, y(p.value)))
        }
    }
}

/** Nhãn 0h/6h/12h/18h đặt đúng 0/25/50/75 % chiều ngang, 24h canh phải. */
@Composable
private fun HourAxis() {
    Box(Modifier.fillMaxWidth().padding(top = 4.dp)) {
        Row(Modifier.fillMaxWidth()) {
            listOf("0h", "6h", "12h", "18h").forEach { label ->
                Text(label, style = Type.caption, color = Palette.tertiary, modifier = Modifier.weight(1f))
            }
        }
        Text("24h", style = Type.caption, color = Palette.tertiary, modifier = Modifier.align(Alignment.CenterEnd))
    }
}
