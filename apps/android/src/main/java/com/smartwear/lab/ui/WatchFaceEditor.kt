package com.smartwear.lab.ui

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.RectF
import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import com.smartwear.core.Complication
import com.smartwear.core.ConnectionState
import com.smartwear.core.TimePosition
import com.smartwear.core.WatchFaceCustomizable
import com.smartwear.core.WatchFaceSpec
import com.smartwear.core.WatchFaceStyle
import com.smartwear.core.WatchWidget
import com.smartwear.core.WearableDevice
import com.smartwear.core.WidgetPlacement
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.Locale
import kotlin.math.roundToInt

private val textColors = listOf(0xFFFFFFFF, 0xFFF5E6C8, 0xFFFFB04A, 0xFFFF6B4A, 0xFF66D4CF, 0xFF64D2FF, 0xFFB9A3FF, 0xFF16161A)
private val backgroundColors = listOf(0xFF0E0F12, 0xFF1C1C1E, 0xFF2A1A0E, 0xFF0E1A2A, 0xFF12261C, 0xFFF2F2F7)
private val PREVIEW_SIZE = 300.dp

/**
 * Trình chỉnh mặt đồng hồ cho thiết bị hỗ trợ [WatchFaceCustomizable]: kéo thả từng khối trên ảnh xem trước,
 * chỉnh cỡ khối đang chọn, đổi ảnh/màu/thành phần. Ảnh xem trước do chính driver dựng nên giống hệt đồng hồ.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun WatchFaceEditor(device: WearableDevice, onClose: () -> Unit) {
    val face = device as? WatchFaceCustomizable ?: return onClose()
    val context = LocalContext.current
    val store = (context.applicationContext as com.smartwear.lab.SmartWearApp).watchFaces
    val autoStatus by store.status.collectAsState()
    val scope = rememberCoroutineScope()
    val state by device.state.collectAsState()

    var spec by remember { mutableStateOf<WatchFaceSpec?>(null) }
    var specError by remember { mutableStateOf<String?>(null) }
    var image by remember { mutableStateOf<Bitmap?>(null) }
    var style by remember { mutableStateOf(WatchFaceStyle()) }
    var preview by remember { mutableStateOf<Bitmap?>(null) }
    var layout by remember { mutableStateOf<Map<WatchWidget, RectF>>(emptyMap()) }
    var size by remember { mutableStateOf<Int?>(null) }
    var sending by remember { mutableStateOf<Float?>(null) }
    var result by remember { mutableStateOf<String?>(null) }
    var selected by remember { mutableStateOf<WatchWidget?>(WatchWidget.TIME) }
    var autoApply by remember { mutableStateOf(true) }

    // Trạng thái kéo: khối đang kéo, độ dời (pixel đồng hồ), ảnh nền không có khối đó, ảnh riêng của khối.
    var dragging by remember { mutableStateOf<WatchWidget?>(null) }
    var dragDelta by remember { mutableStateOf(Offset.Zero) }
    var dragBase by remember { mutableStateOf<Bitmap?>(null) }
    var dragSprite by remember { mutableStateOf<Bitmap?>(null) }

    BackHandler(enabled = sending == null) { onClose() }

    // Nạp thiết kế đã lưu (nếu có) để chỉnh tiếp; không thì dùng ảnh mặc định.
    LaunchedEffect(Unit) {
        val saved = withContext(Dispatchers.IO) { store.effective(device.id) }
        autoApply = saved.autoApply
        if (saved.image != null && saved.style != null) {
            image = saved.image
            style = saved.style
        } else {
            image = withContext(Dispatchers.IO) { context.assets.open("watchface_default.png").use(BitmapFactory::decodeStream) }
        }
    }
    LaunchedEffect(state) {
        if (spec == null && state == ConnectionState.CONNECTED) {
            runCatching { face.watchFaceSpec() }.onSuccess { spec = it; specError = null }.onFailure { specError = it.message }
        }
    }
    LaunchedEffect(spec, image, style) {
        val s = spec ?: return@LaunchedEffect
        val img = image ?: return@LaunchedEffect
        val (p, l) = withContext(Dispatchers.Default) { face.renderWatchFace(img, s, style) to face.watchFaceLayout(img, s, style) }
        preview = p
        layout = l
        size = null
        delay(800)
        size = withContext(Dispatchers.Default) { face.watchFaceSize(img, s, style) }
    }

    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri: Uri? ->
        if (uri != null) scope.launch {
            image = withContext(Dispatchers.IO) { decodeScaled(context, uri, 1024) }
            result = null
        }
    }

    /** Đặt tâm khối [w] (pixel đồng hồ), giữ hệ số cỡ hiện có. */
    fun placeAt(w: WatchWidget, center: Offset, scale: Float? = null) {
        val s = spec ?: return
        val current = style.placements[w]?.scale ?: 1f
        style = style.copy(placements = style.placements + (w to WidgetPlacement(
            (center.x / s.width).coerceIn(0f, 1f), (center.y / s.height).coerceIn(0f, 1f), scale ?: current,
        )))
    }

    Column {
        Chip("‹  ${device.name.substringBefore('(').substringBefore('_')}", selected = false, onClick = { if (sending == null) onClose() })
        Spacer(Modifier.height(14.dp))
        Text("Mặt đồng hồ", style = Type.largeTitle, color = Palette.label)
        Text(
            spec?.let { "${it.width} × ${it.height} · ${if (it.round) "màn tròn" else "màn vuông"} · tối đa ${it.maxBytes / 1024} KB" }
                ?: specError ?: if (state == ConnectionState.CONNECTED) "Đang đọc thông số màn hình…" else "Kết nối thiết bị để tuỳ chỉnh",
            style = Type.body,
            color = if (specError != null) Palette.orange else Palette.secondary,
        )
        Text("Chạm để chọn, kéo để di chuyển từng khối.", style = Type.footnote, color = Palette.tertiary, modifier = Modifier.padding(top = 4.dp))

        // ---------- Xem trước + kéo thả ----------
        Spacer(Modifier.height(16.dp))
        val density = LocalDensity.current
        val previewPx = with(density) { PREVIEW_SIZE.toPx() }
        val currentLayout by rememberUpdatedState(layout)
        val currentSpec by rememberUpdatedState(spec)
        val currentStyle by rememberUpdatedState(style)
        val currentImage by rememberUpdatedState(image)
        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
            val shape = if (spec?.round != false) CircleShape else RoundedCornerShape(36.dp)
            Box(
                Modifier
                    .size(PREVIEW_SIZE)
                    .clip(shape)
                    .background(Color.Black)
                    .border(1.dp, Color.White.copy(alpha = 0.18f), shape)
                    .pointerInput(Unit) {
                        fun hit(pos: Offset): WatchWidget? {
                            val s = currentSpec ?: return null
                            val k = previewPx / s.width
                            val p = Offset(pos.x / k, pos.y / k)
                            // Ưu tiên khối chữ (nhỏ, nằm trên) rồi mới tới ảnh.
                            return currentLayout.entries.filter { it.key != WatchWidget.IMAGE }.firstOrNull { it.value.contains(p.x, p.y) }?.key
                                ?: currentLayout[WatchWidget.IMAGE]?.takeIf { it.contains(p.x, p.y) }?.let { WatchWidget.IMAGE }
                        }
                        detectTapGestures { pos -> hit(pos)?.let { selected = it } }
                    }
                    .pointerInput(Unit) {
                        detectDragGestures(
                            onDragStart = { pos ->
                                val s = currentSpec ?: return@detectDragGestures
                                val k = previewPx / s.width
                                val p = Offset(pos.x / k, pos.y / k)
                                val w = currentLayout.entries.filter { it.key != WatchWidget.IMAGE }.firstOrNull { it.value.contains(p.x, p.y) }?.key
                                    ?: currentLayout[WatchWidget.IMAGE]?.takeIf { it.contains(p.x, p.y) }?.let { WatchWidget.IMAGE }
                                    ?: return@detectDragGestures
                                selected = w
                                dragging = w
                                dragDelta = Offset.Zero
                                dragBase = null
                                dragSprite = null
                                val img = currentImage ?: return@detectDragGestures
                                val st = currentStyle
                                scope.launch {
                                    val (base, sprite) = withContext(Dispatchers.Default) {
                                        face.renderWatchFace(img, s, st, exclude = w) to face.renderWidget(img, s, st, w)
                                    }
                                    if (dragging == w) { dragBase = base; dragSprite = sprite }
                                }
                            },
                            onDrag = { change, amount ->
                                val s = currentSpec ?: return@detectDragGestures
                                if (dragging == null) return@detectDragGestures
                                change.consume()
                                dragDelta += amount / (previewPx / s.width)
                            },
                            onDragEnd = {
                                val w = dragging
                                val rect = w?.let { currentLayout[it] }
                                if (w != null && rect != null) placeAt(w, Offset(rect.centerX() + dragDelta.x, rect.centerY() + dragDelta.y))
                                dragging = null
                            },
                            onDragCancel = { dragging = null },
                        )
                    },
                contentAlignment = Alignment.Center,
            ) {
                val s = spec
                val p = preview
                val k = if (s != null) previewPx / s.width else 1f
                val dragW = dragging
                val base = dragBase
                val sprite = dragSprite
                when {
                    dragW != null && base != null && sprite != null && s != null -> {
                        Image(base.asImageBitmap(), null, Modifier.fillMaxSize())
                        val rect = layout[dragW]
                        if (rect != null) {
                            val x = ((rect.left + dragDelta.x) * k).roundToInt()
                            val y = ((rect.top + dragDelta.y) * k).roundToInt()
                            Image(
                                sprite.asImageBitmap(), null,
                                Modifier
                                    .align(Alignment.TopStart)
                                    .offset { IntOffset(x, y) }
                                    .size(with(density) { (rect.width() * k).toDp() }, with(density) { (rect.height() * k).toDp() }),
                            )
                        }
                    }
                    p != null -> Image(p.asImageBitmap(), contentDescription = "Xem trước mặt đồng hồ", modifier = Modifier.fillMaxSize())
                    else -> CircularProgressIndicator(color = Palette.secondary, strokeWidth = 2.dp)
                }
                // Viền khối đang chọn.
                val sel = selected
                val selRect = sel?.let { layout[it] }
                if (s != null && selRect != null && (dragW == null || dragW == sel)) {
                    Canvas(Modifier.fillMaxSize()) {
                        val d = if (dragW == sel) dragDelta else Offset.Zero
                        val pad = 4.dp.toPx()
                        drawRoundRect(
                            color = Color.White,
                            topLeft = Offset((selRect.left + d.x) * k - pad, (selRect.top + d.y) * k - pad),
                            size = Size(selRect.width() * k + pad * 2, selRect.height() * k + pad * 2),
                            cornerRadius = CornerRadius(6.dp.toPx()),
                            style = Stroke(1.5.dp.toPx()),
                        )
                    }
                }
            }
        }
        Spacer(Modifier.height(10.dp))
        val limit = spec?.maxBytes ?: 0
        Text(
            when (val sz = size) {
                null -> "Đang tính dung lượng…"
                else -> String.format(Locale("vi"), "%,d KB / %,d KB", sz / 1024, limit / 1024) + if (sz > limit) " · sẽ tự thu nhỏ chữ giờ cho vừa" else ""
            },
            style = Type.footnote,
            color = if ((size ?: 0) > limit) Palette.orange else Palette.secondary,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth(),
        )

        // ---------- Khối đang chọn ----------
        val sel = selected
        if (sel != null && sel in style.widgets) {
            GlassCard(Modifier.padding(top = 14.dp)) {
                Column {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("Đang chọn: ${sel.label}", style = Type.headline, color = Palette.label, modifier = Modifier.weight(1f))
                        Text(if (sel in style.placements) "tự do" else "tự xếp", style = Type.footnote, color = Palette.secondary)
                    }
                    val scale = style.placements[sel]?.scale ?: 1f
                    LabeledSlider("Cỡ", "${(scale * 100).roundToInt()} %", scale, 0.5f..2f) { v ->
                        val rect = layout[sel] ?: return@LabeledSlider
                        val center = style.placements[sel]?.let { Offset(it.cx * (spec?.width ?: 1), it.cy * (spec?.height ?: 1)) }
                            ?: Offset(rect.centerX(), rect.centerY())
                        placeAt(sel, center, v)
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(top = 6.dp)) {
                        PillButton("Về chỗ tự xếp", { style = style.copy(placements = style.placements - sel) }, Modifier.weight(1f), enabled = sel in style.placements)
                        if (sel != WatchWidget.TIME) {
                            PillButton("Ẩn", {
                                style = when (sel) {
                                    WatchWidget.IMAGE -> style.copy(imageScale = 1f)
                                    WatchWidget.AMPM -> style.copy(hour12 = false)
                                    else -> style.copy(complications = style.complications - Complication.valueOf(sel.name))
                                }
                                selected = WatchWidget.TIME
                            }, Modifier.weight(1f), kind = ButtonKind.DESTRUCTIVE)
                        }
                    }
                }
            }
        }
        PillButton("Tự xếp lại tất cả", { style = style.copy(placements = emptyMap()) }, Modifier.fillMaxWidth().padding(top = 10.dp), enabled = style.placements.isNotEmpty())

        // ---------- Thành phần ----------
        SectionTitle("Thành phần", trailing = "${style.complications.size}/${Complication.entries.size}")
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Complication.entries.forEach { c ->
                Chip(c.label, selected = c in style.complications, onClick = {
                    style = style.copy(complications = if (c in style.complications) style.complications - c else style.complications + c)
                    if (c in style.complications) selected = WatchWidget.valueOf(c.name)
                })
            }
            Chip("AM/PM", selected = style.hour12, onClick = { style = style.copy(hour12 = !style.hour12) })
        }

        // ---------- Ảnh nền ----------
        SectionTitle("Ảnh nền")
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            PillButton("Chọn ảnh…", { picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }, Modifier.weight(1f))
            PillButton("Ảnh mặc định", {
                scope.launch { image = withContext(Dispatchers.IO) { context.assets.open("watchface_default.png").use(BitmapFactory::decodeStream) } }
            }, Modifier.weight(1f))
        }
        Spacer(Modifier.height(12.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Chip("Phủ kín màn", selected = style.imageScale >= 0.99f, onClick = { style = style.copy(imageScale = 1f) })
            Chip("Ảnh tự do", selected = style.imageScale < 0.99f, onClick = { style = style.copy(imageScale = 0.55f); selected = WatchWidget.IMAGE })
        }
        ColorRow("Màu nền", backgroundColors, style.backgroundColor) { style = style.copy(backgroundColor = it) }

        // ---------- Chữ ----------
        SectionTitle("Chữ")
        Text("Bố cục tự xếp", style = Type.callout, color = Palette.label)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(top = 8.dp)) {
            listOf(TimePosition.TOP to "Trên", TimePosition.CENTER to "Giữa", TimePosition.BOTTOM to "Dưới").forEach { (pos, label) ->
                Chip(label, selected = style.timePosition == pos, onClick = { style = style.copy(timePosition = pos) })
            }
        }
        LabeledSlider("Cỡ chữ giờ gốc", "${(style.timeSize * 100).roundToInt()} %", style.timeSize, 0.12f..0.24f) { style = style.copy(timeSize = it) }
        ColorRow("Màu chữ", textColors, style.textColor) { style = style.copy(textColor = it) }
        ColorRow("Màu nhấn", textColors, style.accentColor) { style = style.copy(accentColor = it) }
        ToggleRow("Nền tối sau chữ", style.scrim) { style = style.copy(scrim = it) }
        Text("Kim đồng hồ: chưa có trong trình chỉnh. Các mặt có kim nằm trong Thư viện.", style = Type.footnote, color = Palette.tertiary, modifier = Modifier.padding(top = 10.dp))

        // ---------- Gửi ----------
        SectionTitle("Mặc định")
        ToggleRow("Tự cài lại khi kết nối", autoApply) {
            autoApply = it
            store.setAutoApply(device.id, it)
        }
        Text(
            "Mỗi lần kết nối, nếu đồng hồ không hiển thị mặt này (vừa reset, đổi mặt) thì app tự gửi lại.",
            style = Type.footnote,
            color = Palette.tertiary,
            modifier = Modifier.padding(top = 4.dp),
        )
        autoStatus[device.id]?.let { Text(it, style = Type.footnote, color = Palette.secondary, modifier = Modifier.padding(top = 6.dp)) }
        Spacer(Modifier.height(24.dp))
        val progress = sending
        if (progress != null) {
            Text("Đang gửi lên đồng hồ · ${(progress * 100).toInt()} %", style = Type.callout, color = Palette.label)
            Spacer(Modifier.height(8.dp))
            LinearProgressIndicator(
                progress = { progress },
                modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(3.dp)),
                color = Palette.label,
                trackColor = Color.White.copy(alpha = 0.12f),
            )
        } else {
            PillButton(
                "Gửi lên đồng hồ",
                {
                    val img = image ?: return@PillButton
                    result = null
                    sending = 0f
                    scope.launch {
                        runCatching { face.setWatchFace(img, style) { p -> sending = p } }
                            .onSuccess { used ->
                                withContext(Dispatchers.IO) { store.save(device.id, img, used, autoApply, pushed = true) }
                                result = if (used.timeSize < style.timeSize) "Đã cài. Chữ giờ được thu nhỏ còn ${(used.timeSize * 100).toInt()} % để vừa dung lượng."
                                else "Đã cài lên đồng hồ."
                                style = used
                            }
                            .onFailure { result = "Không gửi được: ${it.message}" }
                        sending = null
                    }
                },
                Modifier.fillMaxWidth(),
                kind = ButtonKind.PRIMARY,
                enabled = spec != null && image != null && state == ConnectionState.CONNECTED,
            )
        }
        result?.let {
            Text(it, style = Type.callout, color = if (it.startsWith("Không")) Palette.orange else Palette.green, modifier = Modifier.padding(top = 12.dp))
        }
    }
}

@Composable
private fun LabeledSlider(label: String, value: String, current: Float, range: ClosedFloatingPointRange<Float>, onChange: (Float) -> Unit) {
    Column(Modifier.padding(top = 12.dp)) {
        Row {
            Text(label, style = Type.callout, color = Palette.label, modifier = Modifier.weight(1f))
            Text(value, style = Type.callout, color = Palette.secondary)
        }
        Slider(
            value = current,
            onValueChange = onChange,
            valueRange = range,
            colors = SliderDefaults.colors(thumbColor = Color.White, activeTrackColor = Color.White, inactiveTrackColor = Color.White.copy(alpha = 0.18f)),
        )
    }
}

@Composable
private fun ColorRow(label: String, colors: List<Long>, selected: Int, onPick: (Int) -> Unit) {
    Column(Modifier.padding(top = 14.dp)) {
        Text(label, style = Type.callout, color = Palette.label)
        Spacer(Modifier.height(8.dp))
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            colors.forEach { c ->
                val argb = c.toInt()
                Box(
                    Modifier
                        .size(32.dp)
                        .clip(CircleShape)
                        .background(Color(argb))
                        .border(if (argb == selected) 3.dp else 1.dp, if (argb == selected) Color.White else Color.White.copy(alpha = 0.25f), CircleShape)
                        .clickable { onPick(argb) },
                )
            }
        }
    }
}

@Composable
private fun ToggleRow(label: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(top = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(label, style = Type.callout, color = Palette.label, modifier = Modifier.weight(1f))
        Switch(
            checked = checked,
            onCheckedChange = onChange,
            colors = SwitchDefaults.colors(checkedTrackColor = Palette.green, checkedThumbColor = Color.White),
        )
    }
}

/** Đọc ảnh từ thư viện, thu nhỏ để cạnh dài không quá [maxSide]. */
private fun decodeScaled(context: android.content.Context, uri: Uri, maxSide: Int): Bitmap? {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    context.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
    var sample = 1
    while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= maxSide) sample *= 2
    return context.contentResolver.openInputStream(uri)?.use {
        BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inSampleSize = sample })
    }
}
