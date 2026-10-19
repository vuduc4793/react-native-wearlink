package com.smartwear.lab.ui

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import kotlin.math.cos
import kotlin.math.sin

/**
 * Bề mặt "kính" kiểu Liquid Glass: nền trong mờ, viền sáng phía trên (specular) mờ dần xuống dưới.
 * Lớp nội dung phía sau đã là các vùng màu mềm nên không cần blur backdrop thật.
 */
fun Modifier.glass(shape: Shape = RoundedCornerShape(22.dp), tint: Color = Color.White, strength: Float = 1f): Modifier = this
    .clip(shape)
    .background(
        Brush.verticalGradient(
            listOf(tint.copy(alpha = 0.13f * strength), tint.copy(alpha = 0.06f * strength)),
        ),
    )
    .border(
        width = 1.dp,
        brush = Brush.verticalGradient(
            listOf(Color.White.copy(alpha = 0.32f * strength), Color.White.copy(alpha = 0.05f), Color.White.copy(alpha = 0.10f * strength)),
        ),
        shape = shape,
    )

/** Lớp nội dung phía sau kính: mỗi thiết bị một vùng màu trôi chậm. */
@Composable
fun ColorFields(colors: List<Color>, modifier: Modifier = Modifier) {
    val transition = rememberInfiniteTransition(label = "fields")
    val t by transition.animateFloat(
        initialValue = 0f,
        targetValue = (2 * Math.PI).toFloat(),
        animationSpec = infiniteRepeatable(tween(26_000, easing = LinearEasing), RepeatMode.Restart),
        label = "t",
    )
    val fields = colors.ifEmpty { listOf(Color(0xFF2C3440)) }
    // Không dùng blur: gradient toả đã mềm sẵn, còn blur 80 dp toàn màn mỗi khung làm GPU yếu (Adreno 612, Redmi
    // Note 7 Pro) mất 2–5 s/khung ⇒ cả app đứng, popup 3D không vẽ được (19/10/2026).
    Canvas(modifier.fillMaxSize()) {
        fields.forEachIndexed { i, color ->
            val phase = i * 2.1f
            val center = Offset(
                x = size.width * (0.5f + 0.32f * cos(t + phase)),
                y = size.height * (0.28f + 0.18f * sin(t * 0.8f + phase)),
            )
            drawCircle(
                brush = Brush.radialGradient(listOf(color.copy(alpha = 0.55f), Color.Transparent), center, size.width * 0.55f),
                radius = size.width * 0.55f,
                center = center,
            )
        }
    }
}

/** Quả cầu đại diện cho một thiết bị; nảy nhẹ mỗi khi có gói tin mới ([pulseKey] đổi). */
@Composable
fun Orb(color: Color, size: Dp, pulseKey: Any? = null, dimmed: Boolean = false, modifier: Modifier = Modifier) {
    val scale = remember { Animatable(1f) }
    LaunchedEffect(pulseKey) {
        if (pulseKey != null) {
            scale.animateTo(1.18f, tween(120))
            scale.animateTo(1f, tween(380))
        }
    }
    val alpha = if (dimmed) 0.35f else 1f
    Canvas(modifier.size(size).scale(scale.value)) {
        val r = this.size.minDimension / 2
        // Quầng sáng mềm quanh quả cầu.
        drawCircle(Brush.radialGradient(listOf(color.copy(alpha = 0.35f * alpha), Color.Transparent), center, r * 1.6f), r * 1.6f)
        // Thân cầu: điểm sáng lệch trái-trên tạo cảm giác khối.
        drawCircle(
            brush = Brush.radialGradient(
                listOf(Color.White.copy(alpha = 0.95f * alpha), color.copy(alpha = alpha), color.copy(alpha = 0.6f * alpha), Color(0xFF0B0C0E)),
                center = Offset(center.x - r * 0.35f, center.y - r * 0.4f),
                radius = r * 1.5f,
            ),
            radius = r * 0.62f,
        )
    }
}
