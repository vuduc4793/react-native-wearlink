package com.smartwear.lab.ui

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import com.smartwear.core.ConnectionState
import com.smartwear.core.WearableDevice
import kotlin.math.cos
import kotlin.math.roundToInt
import kotlin.math.sin

/**
 * Nửa trên màn hình, thay cho bản đồ của Find My: tâm là điện thoại, mỗi thiết bị là một quả cầu,
 * càng gần tâm tín hiệu càng mạnh (RSSI), nảy theo gói tin.
 */
@Composable
fun SignalField(
    devices: List<WearableDevice>,
    colorOf: (WearableDevice) -> Color,
    selectedId: String?,
    onSelect: (WearableDevice) -> Unit,
    modifier: Modifier = Modifier,
) {
    BoxWithConstraints(modifier.fillMaxSize()) {
        val density = LocalDensity.current
        val w = with(density) { maxWidth.toPx() }
        val h = with(density) { maxHeight.toPx() }
        val center = Offset(w / 2, h * 0.52f)
        val maxR = minOf(w * 0.46f, h * 0.46f)

        Canvas(Modifier.fillMaxSize()) {
            // Vòng đồng tâm hơi nghiêng (elip) gợi mặt phẳng không gian.
            for (i in 1..4) {
                val r = maxR * i / 4f
                drawOval(
                    color = Color.White.copy(alpha = 0.10f - i * 0.015f),
                    topLeft = Offset(center.x - r * 1.25f, center.y - r * 0.55f),
                    size = Size(r * 2.5f, r * 1.1f),
                    style = Stroke(1.dp.toPx()),
                )
            }
            drawCircle(Color.White.copy(alpha = 0.15f), 14.dp.toPx(), center)
            drawCircle(Color.White, 5.dp.toPx(), center)
        }

        devices.forEachIndexed { index, device ->
            val stats by device.stats.collectAsState()
            val state by device.state.collectAsState()
            val latest by device.latest.collectAsState()
            val connected = state == ConnectionState.CONNECTED
            // RSSI -40 (rất gần) … -100 (xa) → bán kính 0.3 … 1.0.
            val rssi = stats.rssi ?: -90
            val norm = ((-rssi - 40) / 60f).coerceIn(0f, 1f)
            val radius by animateFloatAsState(maxR * (0.3f + 0.7f * norm), tween(900), label = "r")
            val angle = remember(index) { (-150 + index * 137.5) * Math.PI / 180 }
            val x = center.x + radius * 1.25f * cos(angle).toFloat()
            val y = center.y + radius * 0.55f * sin(angle).toFloat()
            val orbSize = 40.dp
            val orbPx = with(density) { orbSize.toPx() }
            val headline = latest.values.maxByOrNull { it.timestamp }

            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                modifier = Modifier
                    .offset { IntOffset((x - orbPx).roundToInt(), (y - orbPx / 2).roundToInt()) }
                    .width(orbSize * 2)
                    .clickable(remember { MutableInteractionSource() }, indication = null) { onSelect(device) },
            ) {
                Orb(
                    color = colorOf(device),
                    size = if (device.id == selectedId) 48.dp else orbSize,
                    pulseKey = stats.packetsReceived.takeIf { it > 0 },
                    dimmed = !connected,
                )
                Text(
                    device.name.substringBefore('_').take(12),
                    style = Type.caption,
                    color = if (connected) Palette.label else Palette.tertiary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    textAlign = TextAlign.Center,
                )
                val sub = when {
                    state == ConnectionState.CONNECTING -> "đang nối…"
                    !connected -> "chưa nối"
                    headline != null -> headline.statusText() + headline.display()?.let { " ${headline.capability.style.unit}" }.orEmpty()
                    else -> stats.rssi?.let { "$it dBm" } ?: ""
                }
                Text(sub, style = Type.caption, color = if (headline != null && connected) headline.capability.style.color else Palette.secondary, maxLines = 1)
            }
        }

        if (devices.isEmpty()) {
            Text(
                "Chưa có thiết bị",
                style = Type.footnote,
                color = Palette.secondary,
                modifier = Modifier.align(Alignment.Center).padding(top = 64.dp),
            )
        }
    }
}
