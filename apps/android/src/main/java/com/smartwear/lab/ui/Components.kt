package com.smartwear.lab.ui

import androidx.compose.foundation.Canvas
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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.smartwear.core.ConnectionState

enum class ButtonKind { PRIMARY, GLASS, DESTRUCTIVE }

@Composable
fun PillButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    kind: ButtonKind = ButtonKind.GLASS,
    enabled: Boolean = true,
) {
    val shape = RoundedCornerShape(50)
    val base = when (kind) {
        ButtonKind.PRIMARY -> modifier.clip(shape).background(if (enabled) Color.White else Color.White.copy(alpha = 0.25f))
        else -> modifier.glass(shape, strength = if (enabled) 1f else 0.5f)
    }
    val color = when {
        !enabled -> Palette.tertiary
        kind == ButtonKind.PRIMARY -> Color.Black
        kind == ButtonKind.DESTRUCTIVE -> Palette.red
        else -> Palette.label
    }
    Box(
        base
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = 18.dp, vertical = 12.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(text, style = Type.callout.copy(fontWeight = FontWeight.SemiBold), color = color, maxLines = 1)
    }
}

@Composable
fun Chip(text: String, selected: Boolean, onClick: () -> Unit, dot: Color? = null, modifier: Modifier = Modifier) {
    val shape = RoundedCornerShape(50)
    Row(
        modifier
            .then(if (selected) Modifier.clip(shape).background(Color.White.copy(alpha = 0.92f)) else Modifier.glass(shape))
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 9.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (dot != null) {
            Box(Modifier.size(8.dp).clip(CircleShape).background(dot))
            Spacer(Modifier.width(7.dp))
        }
        Text(text, style = Type.callout, color = if (selected) Color.Black else Palette.label, maxLines = 1)
    }
}

@Composable
fun SectionTitle(text: String, trailing: String? = null, modifier: Modifier = Modifier) {
    Row(modifier.fillMaxWidth().padding(top = 22.dp, bottom = 10.dp), verticalAlignment = Alignment.Bottom) {
        Text(text, style = Type.title, color = Palette.label, modifier = Modifier.weight(1f))
        if (trailing != null) Text(trailing, style = Type.footnote, color = Palette.secondary)
    }
}

@Composable
fun StateLabel(state: ConnectionState, modifier: Modifier = Modifier) {
    val (text, color) = when (state) {
        ConnectionState.CONNECTED -> "Đã kết nối" to Palette.green
        ConnectionState.CONNECTING -> "Đang kết nối…" to Palette.orange
        ConnectionState.DISCONNECTING -> "Đang ngắt…" to Palette.secondary
        ConnectionState.DISCONNECTED -> "Chưa kết nối" to Palette.secondary
    }
    Row(modifier, verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(7.dp).clip(CircleShape).background(color))
        Spacer(Modifier.width(6.dp))
        Text(text, style = Type.footnote, color = Palette.secondary)
    }
}

@Composable
fun BatteryBadge(level: Int?, modifier: Modifier = Modifier, charging: Boolean? = null) {
    Row(modifier, verticalAlignment = Alignment.CenterVertically) {
        Canvas(Modifier.size(width = 24.dp, height = 12.dp)) {
            val stroke = 1.2.dp.toPx()
            drawRoundRect(Palette.secondary, size = Size(size.width - 3.dp.toPx(), size.height), cornerRadius = CornerRadius(3.dp.toPx()), style = Stroke(stroke))
            drawRoundRect(Palette.secondary, topLeft = Offset(size.width - 2.dp.toPx(), size.height * 0.3f), size = Size(2.dp.toPx(), size.height * 0.4f), cornerRadius = CornerRadius(1.dp.toPx()))
            if (level != null) {
                val inner = (size.width - 3.dp.toPx() - stroke * 4) * level.coerceIn(0, 100) / 100f
                val color = when { level <= 20 -> Palette.red; level <= 35 -> Palette.orange; else -> Palette.green }
                drawRoundRect(color, topLeft = Offset(stroke * 2, stroke * 2), size = Size(inner, size.height - stroke * 4), cornerRadius = CornerRadius(1.5.dp.toPx()))
            }
        }
        Spacer(Modifier.width(6.dp))
        Text((level?.let { "$it %" } ?: "pin chưa đo") + if (charging == true) " · đang sạc" else "", style = Type.footnote, color = Palette.secondary)
    }
}

/** Biểu đồ cột nhỏ: số gói mỗi giây trong 20 s gần nhất. */
@Composable
fun Sparkline(values: List<Int>, color: Color, modifier: Modifier = Modifier, height: Dp = 28.dp) {
    Canvas(modifier.fillMaxWidth().height(height)) {
        val n = 20
        val max = (values.maxOrNull() ?: 0).coerceAtLeast(2)
        val gap = 3.dp.toPx()
        val barW = (size.width - gap * (n - 1)) / n
        val padded = List(n - values.size.coerceAtMost(n)) { 0 } + values.takeLast(n)
        padded.forEachIndexed { i, v ->
            val h = if (v == 0) 2.dp.toPx() else (size.height * v / max).coerceAtLeast(3.dp.toPx())
            drawRoundRect(
                color = if (v == 0) Color.White.copy(alpha = 0.12f) else color,
                topLeft = Offset(i * (barW + gap), size.height - h),
                size = Size(barW, h),
                cornerRadius = CornerRadius(barW / 2),
            )
        }
    }
}

/** Dải 50 vạch: mỗi vạch là một gói 0,5 s của phép đo đang chạy (~25 s). */
@Composable
fun PacketLane(count: Int, color: Color, modifier: Modifier = Modifier, total: Int = 50) {
    Canvas(modifier.fillMaxWidth().height(22.dp)) {
        val gap = 2.5.dp.toPx()
        val barW = (size.width - gap * (total - 1)) / total
        for (i in 0 until total) {
            val filled = i < count
            val h = if (filled) size.height * (0.55f + 0.45f * ((i * 37) % 10) / 10f) else 3.dp.toPx()
            drawLine(
                color = if (filled) color else Color.White.copy(alpha = 0.14f),
                start = Offset(i * (barW + gap) + barW / 2, size.height),
                end = Offset(i * (barW + gap) + barW / 2, size.height - h),
                strokeWidth = barW,
                cap = StrokeCap.Round,
            )
        }
    }
}

enum class Tab(val label: String) { DEVICES("Thiết bị"), ADD("Thêm"), LAB("Khả thi") }

@Composable
fun TabBar(selected: Tab, onSelect: (Tab) -> Unit, modifier: Modifier = Modifier) {
    Row(
        modifier.glass(RoundedCornerShape(50), strength = 1.3f).background(Color.Black.copy(alpha = 0.35f)).padding(5.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Tab.entries.forEach { tab ->
            val active = tab == selected
            Column(
                Modifier
                    .clip(RoundedCornerShape(50))
                    .then(if (active) Modifier.background(Color.White.copy(alpha = 0.16f)) else Modifier)
                    .clickable { onSelect(tab) }
                    .padding(horizontal = 22.dp, vertical = 8.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                TabIcon(tab, if (active) Palette.label else Palette.secondary)
                Spacer(Modifier.height(3.dp))
                Text(tab.label, style = Type.caption, color = if (active) Palette.label else Palette.secondary)
            }
        }
    }
}

@Composable
private fun TabIcon(tab: Tab, color: Color) {
    Canvas(Modifier.size(22.dp)) {
        val s = 1.7.dp.toPx()
        when (tab) {
            Tab.DEVICES -> {
                drawCircle(color, size.width * 0.22f, Offset(size.width * 0.36f, size.height * 0.5f), style = Stroke(s))
                drawCircle(color, size.width * 0.22f, Offset(size.width * 0.66f, size.height * 0.5f), style = Stroke(s))
            }
            Tab.ADD -> {
                drawCircle(color, size.width * 0.42f, center, style = Stroke(s))
                drawLine(color, Offset(center.x, size.height * 0.3f), Offset(center.x, size.height * 0.7f), s, StrokeCap.Round)
                drawLine(color, Offset(size.width * 0.3f, center.y), Offset(size.width * 0.7f, center.y), s, StrokeCap.Round)
            }
            Tab.LAB -> listOf(0.55f, 0.85f, 0.4f).forEachIndexed { i, h ->
                val x = size.width * (0.28f + i * 0.22f)
                drawLine(color, Offset(x, size.height * 0.85f), Offset(x, size.height * (0.85f - 0.7f * h)), s * 1.4f, StrokeCap.Round)
            }
        }
    }
}

@Composable
fun GlassCard(modifier: Modifier = Modifier, onClick: (() -> Unit)? = null, content: @Composable () -> Unit) {
    Box(
        modifier
            .fillMaxWidth()
            .glass()
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(16.dp),
    ) { content() }
}

@Composable
fun KeyValue(key: String, value: String, mono: Boolean = false) {
    Row(Modifier.fillMaxWidth().padding(vertical = 6.dp)) {
        Text(key, style = Type.footnote, color = Palette.secondary, modifier = Modifier.weight(0.42f))
        Text(value, style = if (mono) Type.mono.copy(color = Palette.label) else Type.footnote.copy(color = Palette.label), modifier = Modifier.weight(0.58f))
    }
}

@Composable
fun Hairline(modifier: Modifier = Modifier) {
    Box(modifier.fillMaxWidth().height(1.dp).background(Palette.separator))
}

@Composable
fun SelectMark(selected: Boolean, enabled: Boolean = true) {
    Box(
        Modifier
            .size(24.dp)
            .clip(CircleShape)
            .then(
                if (selected) Modifier.background(Palette.accent)
                else Modifier.border(1.5.dp, if (enabled) Palette.secondary else Palette.tertiary.copy(alpha = 0.4f), CircleShape),
            ),
        contentAlignment = Alignment.Center,
    ) {
        if (selected) {
            Canvas(Modifier.size(12.dp)) {
                val s = 2.dp.toPx()
                drawLine(Color.White, Offset(size.width * 0.1f, size.height * 0.55f), Offset(size.width * 0.4f, size.height * 0.85f), s, StrokeCap.Round)
                drawLine(Color.White, Offset(size.width * 0.4f, size.height * 0.85f), Offset(size.width * 0.92f, size.height * 0.15f), s, StrokeCap.Round)
            }
        }
    }
}
