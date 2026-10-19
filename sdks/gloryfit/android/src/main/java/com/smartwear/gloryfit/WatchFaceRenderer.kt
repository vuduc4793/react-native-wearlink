package com.smartwear.gloryfit

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Typeface
import com.smartwear.core.TimePosition
import com.smartwear.core.WatchFaceSpec
import com.smartwear.core.WatchFaceStyle
import com.smartwear.core.WatchWidget

/**
 * Dựng mặt đồng hồ UTE từ ảnh người dùng và các tuỳ chỉnh. Mỗi khối ([WatchWidget]) gồm một hoặc nhiều element
 * UTE với bộ ảnh riêng, theo đúng thứ tự ảnh của template GloryFit (sdks/gloryfit/docs/03-watchface-elements.md):
 * - bộ chữ số 14 ảnh: `-` `.` `/` `0`…`9` `:` → chữ số d nằm ở ảnh d+3;
 * - thứ 14 ảnh: 0–6 và 7–13 (hai bản ngôn ngữ), CN → T7; ta vẽ tiếng Việt ở cả hai nửa;
 * - AM/PM 4 ảnh, pin 5 mức, Bluetooth 2 trạng thái, tiến độ bước 11 mức (0 → 100 %).
 *
 * Khối nào có trong [WatchFaceStyle.placements] thì đặt theo vị trí người dùng kéo thả, còn lại xếp tự động.
 * Ảnh mỗi element được vẽ sẵn trên đúng phần nền phía sau nó (như app GloryFit); ảnh xem trước ghép từ chính
 * các ảnh sẽ gửi nên giống hệt đồng hồ.
 */
class WatchFaceRenderer(private val typeface: Typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)) {

    /** Một element UTE, toạ độ tương đối trong khối. */
    private class Slot(val type: Int, val x: Int, val y: Int, val w: Int, val h: Int, val frames: List<(Canvas) -> Unit>, val sample: Int)

    /** Một khối đã dựng ở một tỉ lệ: kích thước và các element bên trong. */
    private class Built(val widget: WatchWidget, val w: Int, val h: Int, val slots: List<Slot>)

    private class Placed(val built: Built?, val rect: RectF)

    private val digitChars = listOf("-", ".", "/") + (0..9).map { it.toString() } + ":"
    private fun digitFrame(d: Char) = digitChars.indexOf(d.toString()).coerceAtLeast(0)
    private val weekdays = listOf("CN", "T2", "T3", "T4", "T5", "T6", "T7")

    // ---------- Vẽ từng loại ảnh ----------

    private fun text(t: String, w: Int, h: Int, color: Int, weight: Float = 0.98f): (Canvas) -> Unit = { c ->
        val p = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            this.color = color; typeface = this@WatchFaceRenderer.typeface; textAlign = Paint.Align.CENTER; textSize = h * weight
        }
        val width = p.measureText(t)
        if (width > w * 0.96f) p.textSize *= w * 0.96f / width
        val bounds = Rect().also { p.getTextBounds("0", 0, 1, it) }
        c.drawText(t, w / 2f, h / 2f + bounds.height() / 2f, p)
    }

    private fun digitFrames(w: Int, h: Int, color: Int) = digitChars.map { text(it, w, h, color) }

    private fun battery(level: Int, w: Int, h: Int, color: Int): (Canvas) -> Unit = { c ->
        val stroke = h * 0.12f
        val p = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color; style = Paint.Style.STROKE; strokeWidth = stroke }
        val body = RectF(stroke, stroke, w - h * 0.25f - stroke, h - stroke)
        c.drawRoundRect(body, h * 0.2f, h * 0.2f, p)
        p.style = Paint.Style.FILL
        c.drawRoundRect(RectF(body.right + stroke * 0.6f, h * 0.32f, w - stroke * 0.4f, h * 0.68f), stroke, stroke, p)
        if (level > 0) {
            val inner = RectF(body.left + stroke * 1.6f, body.top + stroke * 1.6f, body.right - stroke * 1.6f, body.bottom - stroke * 1.6f)
            inner.right = inner.left + inner.width() * level / 4f
            c.drawRoundRect(inner, stroke * 0.6f, stroke * 0.6f, p)
        }
    }

    private fun bluetooth(connected: Boolean, w: Int, h: Int, color: Int): (Canvas) -> Unit = { c ->
        val p = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            this.color = if (connected) color else color.withAlpha(0x70)
            style = Paint.Style.STROKE; strokeWidth = h * 0.1f; strokeJoin = Paint.Join.ROUND; strokeCap = Paint.Cap.ROUND
        }
        val cx = w / 2f
        c.drawPath(Path().apply {
            moveTo(cx - h * 0.22f, h * 0.3f); lineTo(cx + h * 0.22f, h * 0.68f); lineTo(cx, h * 0.88f); lineTo(cx, h * 0.12f)
            lineTo(cx + h * 0.22f, h * 0.32f); lineTo(cx - h * 0.22f, h * 0.7f)
        }, p)
        if (!connected) {
            p.color = color
            c.drawLine(w * 0.15f, h * 0.15f, w * 0.85f, h * 0.85f, p)
        }
    }

    private fun stepIcon(w: Int, h: Int, color: Int): (Canvas) -> Unit = { c ->
        val p = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color }
        c.drawOval(RectF(w * 0.12f, h * 0.05f, w * 0.48f, h * 0.62f), p)
        c.drawOval(RectF(w * 0.18f, h * 0.68f, w * 0.44f, h * 0.92f), p)
        c.drawOval(RectF(w * 0.54f, h * 0.2f, w * 0.88f, h * 0.75f), p)
        c.drawOval(RectF(w * 0.58f, h * 0.78f, w * 0.84f, h * 0.98f), p)
    }

    private fun heartIcon(w: Int, h: Int, color: Int): (Canvas) -> Unit = { c ->
        val p = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color }
        val s = minOf(w, h).toFloat()
        val ox = (w - s) / 2f
        val oy = (h - s) / 2f
        c.drawPath(Path().apply {
            moveTo(ox + s / 2, oy + s * 0.92f)
            cubicTo(ox - s * 0.15f, oy + s * 0.45f, ox + s * 0.2f, oy - s * 0.05f, ox + s / 2, oy + s * 0.28f)
            cubicTo(ox + s * 0.8f, oy - s * 0.05f, ox + s * 1.15f, oy + s * 0.45f, ox + s / 2, oy + s * 0.92f)
        }, p)
    }

    private fun flameIcon(w: Int, h: Int, color: Int): (Canvas) -> Unit = { c ->
        val p = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color }
        c.drawPath(Path().apply {
            moveTo(w * 0.5f, h * 0.04f)
            cubicTo(w * 0.95f, h * 0.4f, w * 0.9f, h * 0.95f, w * 0.5f, h * 0.96f)
            cubicTo(w * 0.1f, h * 0.95f, w * 0.05f, h * 0.55f, w * 0.32f, h * 0.35f)
            cubicTo(w * 0.35f, h * 0.55f, w * 0.45f, h * 0.6f, w * 0.5f, h * 0.04f)
        }, p)
    }

    private fun pinIcon(w: Int, h: Int, color: Int): (Canvas) -> Unit = { c ->
        val p = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color }
        val r = minOf(w, h) * 0.32f
        c.drawCircle(w / 2f, h * 0.38f, r, p)
        c.drawPath(Path().apply { moveTo(w / 2f - r * 0.8f, h * 0.5f); lineTo(w / 2f, h * 0.96f); lineTo(w / 2f + r * 0.8f, h * 0.5f); close() }, p)
        c.drawCircle(w / 2f, h * 0.38f, r * 0.4f, Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = 0xFF111111.toInt() })
    }

    private fun progress(step: Int, w: Int, h: Int, color: Int): (Canvas) -> Unit = { c ->
        val p = Paint(Paint.ANTI_ALIAS_FLAG)
        p.color = color.withAlpha(0x45)
        c.drawRoundRect(RectF(0f, 0f, w.toFloat(), h.toFloat()), h / 2f, h / 2f, p)
        if (step > 0) {
            p.color = color
            c.drawRoundRect(RectF(0f, 0f, w * step / 10f, h.toFloat()), h / 2f, h / 2f, p)
        }
    }

    private fun Int.withAlpha(a: Int) = (this and 0x00FFFFFF) or (a shl 24)
    private fun px(v: Float) = maxOf(1, v.toInt())

    // ---------- Dựng từng khối ----------

    private fun build(widget: WatchWidget, s: Int, style: WatchFaceStyle, k: Float): Built? {
        val main = style.textColor
        val accent = style.accentColor
        val soft = main.withAlpha(0xC8)
        return when (widget) {
            WatchWidget.IMAGE -> null
            WatchWidget.TIME -> {
                val dh = px(s * style.timeSize.coerceIn(0.12f, 0.24f) * k)
                val dw = px(dh * 0.62f)
                val colon = px(dh * 0.28f)
                val digits = digitFrames(dw, dh, main)
                Built(widget, dw * 4 + colon, dh, listOf(
                    Slot(UteWatchFace.TYPE_HOUR_TENS, 0, 0, dw, dh, digits, digitFrame('1')),
                    Slot(UteWatchFace.TYPE_HOUR_UNITS, dw, 0, dw, dh, digits, digitFrame('0')),
                    Slot(UteWatchFace.TYPE_COLON, dw * 2, 0, colon, dh, listOf(text(":", colon, dh, main)), 0),
                    Slot(UteWatchFace.TYPE_MINUTE_TENS, dw * 2 + colon, 0, dw, dh, digits, digitFrame('0')),
                    Slot(UteWatchFace.TYPE_MINUTE_UNITS, dw * 3 + colon, 0, dw, dh, digits, digitFrame('8')),
                ))
            }
            WatchWidget.SECONDS -> {
                val h = px(s * 0.07f * k)
                val w = px(h * 0.62f)
                val digits = digitFrames(w, h, accent)
                Built(widget, w * 2 + 2, h, listOf(
                    Slot(UteWatchFace.TYPE_SECOND_TENS, 0, 0, w, h, digits, digitFrame('3')),
                    Slot(UteWatchFace.TYPE_SECOND_UNITS, w + 2, 0, w, h, digits, digitFrame('0')),
                ))
            }
            WatchWidget.AMPM -> {
                val h = px(s * 0.048f * k)
                val w = px(h * 1.9f)
                Built(widget, w, h, listOf(Slot(UteWatchFace.TYPE_AMPM, 0, 0, w, h, listOf("SA", "CH", "AM", "PM").map { text(it, w, h, accent) }, 2)))
            }
            WatchWidget.WEEKDAY -> {
                val h = px(s * 0.06f * k)
                val w = px(h * 1.5f)
                Built(widget, w, h, listOf(Slot(UteWatchFace.TYPE_WEEK, 0, 0, w, h, (weekdays + weekdays).map { text(it, w, h, accent) }, 1)))
            }
            WatchWidget.DATE -> {
                val h = px(s * 0.06f * k)
                val cw = px(h * 0.6f)
                val digits = digitFrames(cw, h, soft)
                val parts = listOf(UteWatchFace.TYPE_MONTH_TENS to '1', UteWatchFace.TYPE_MONTH_UNITS to '0', UteWatchFace.TYPE_DATE_SEPARATOR to '/', UteWatchFace.TYPE_DAY_TENS to '1', UteWatchFace.TYPE_DAY_UNITS to '3')
                Built(widget, cw * 5, h, parts.mapIndexed { i, (type, sample) ->
                    if (type == UteWatchFace.TYPE_DATE_SEPARATOR) Slot(type, i * cw, 0, cw, h, listOf(text("/", cw, h, soft)), 0)
                    else Slot(type, i * cw, 0, cw, h, digits, digitFrame(sample))
                })
            }
            WatchWidget.BATTERY -> {
                val h = px(s * 0.04f * k)
                val w = px(h * 2.1f)
                Built(widget, w, h, listOf(Slot(UteWatchFace.TYPE_BATTERY, 0, 0, w, h, (0..4).map { battery(it, w, h, main) }, 3)))
            }
            WatchWidget.BLUETOOTH -> {
                val h = px(s * 0.04f * k)
                Built(widget, h, h, listOf(Slot(UteWatchFace.TYPE_BLUETOOTH, 0, 0, h, h, listOf(bluetooth(true, h, h, main), bluetooth(false, h, h, main)), 0)))
            }
            WatchWidget.STEPS, WatchWidget.HEART_RATE, WatchWidget.CALORIES, WatchWidget.DISTANCE -> {
                val h = px(s * 0.05f * k)
                val cw = px(h * 0.6f)
                val (iconType, icon, digitTypes, sample) = when (widget) {
                    WatchWidget.STEPS -> Quad(UteWatchFace.TYPE_STEP_ICON, stepIcon(h, h, accent), UteWatchFace.TYPE_STEP_DIGITS, "03246")
                    WatchWidget.HEART_RATE -> Quad(UteWatchFace.TYPE_HEART_ICON, heartIcon(h, h, 0xFFFF453A.toInt()), UteWatchFace.TYPE_HEART_DIGITS, "076")
                    WatchWidget.CALORIES -> Quad(UteWatchFace.TYPE_KCAL_ICON, flameIcon(h, h, accent), UteWatchFace.TYPE_KCAL_DIGITS, "0124")
                    else -> Quad(UteWatchFace.TYPE_DISTANCE_ICON, pinIcon(h, h, accent), UteWatchFace.TYPE_DISTANCE_DIGITS, "02.06")
                }
                val digits = digitFrames(cw, h, soft)
                val gap = maxOf(2, h / 10)
                Built(widget, h + gap + cw * digitTypes.size, h,
                    listOf(Slot(iconType, 0, 0, h, h, listOf(icon), 0)) +
                        digitTypes.mapIndexed { i, type -> Slot(type, h + gap + i * cw, 0, cw, h, digits, digitFrame(sample[i])) })
            }
            WatchWidget.STEP_PROGRESS -> {
                val w = px(s * 0.32f * k)
                val h = maxOf(4, px(s * 0.012f * k))
                Built(widget, w, h, listOf(Slot(UteWatchFace.TYPE_STEP_PROGRESS, 0, 0, w, h, (0..10).map { progress(it, w, h, accent) }, 4)))
            }
        }
    }

    private data class Quad(val iconType: Int, val icon: (Canvas) -> Unit, val digitTypes: List<Int>, val sample: String)

    // ---------- Đặt khối ----------

    /** Vị trí (pixel) của mọi khối đang bật: theo [WatchFaceStyle.placements] nếu có, không thì xếp tự động. */
    private fun place(image: Bitmap?, spec: WatchFaceSpec, style: WatchFaceStyle): Map<WatchWidget, Placed> {
        val s = minOf(spec.width, spec.height)
        val enabled = style.widgets
        val out = LinkedHashMap<WatchWidget, Placed>()
        val auto = autoLayout(image, spec, style)
        for (w in enabled) {
            val p = style.placements[w]
            if (p == null) {
                auto[w]?.let { out[w] = it }
                continue
            }
            if (w == WatchWidget.IMAGE) {
                val side = s * style.imageScale.coerceIn(0.3f, 1f) * p.scale.coerceIn(0.3f, 3f)
                val (iw, ih) = artSize(image, side)
                out[w] = Placed(null, RectF(p.cx * spec.width - iw / 2, p.cy * spec.height - ih / 2, p.cx * spec.width + iw / 2, p.cy * spec.height + ih / 2))
                continue
            }
            val b = build(w, s, style, p.scale.coerceIn(0.4f, 3f)) ?: continue
            val left = (p.cx * spec.width - b.w / 2f).coerceIn(0f, (spec.width - b.w).toFloat())
            val top = (p.cy * spec.height - b.h / 2f).coerceIn(0f, (spec.height - b.h).toFloat())
            out[w] = Placed(b, RectF(left, top, left + b.w, top + b.h))
        }
        return out
    }

    private fun artSize(image: Bitmap?, side: Float): Pair<Float, Float> {
        if (image == null) return side to side
        val k = minOf(side / image.width, side / image.height)
        return image.width * k to image.height * k
    }

    /** Bố cục tự động: hàng thứ/ngày, hàng giờ (+ AM/PM, giây bên phải), hàng chỉ số, thanh tiến độ, pin/Bluetooth. */
    private fun autoLayout(image: Bitmap?, spec: WatchFaceSpec, style: WatchFaceStyle): Map<WatchWidget, Placed> {
        val s = minOf(spec.width, spec.height)
        val en = style.widgets
        val cx = spec.width / 2f
        val gap = s * 0.02f
        fun b(w: WatchWidget) = if (w in en) build(w, s, style, 1f) else null
        val out = LinkedHashMap<WatchWidget, Placed>()

        val info = listOfNotNull(b(WatchWidget.WEEKDAY), b(WatchWidget.DATE))
        val time = b(WatchWidget.TIME)!!
        val ampm = b(WatchWidget.AMPM)
        val seconds = b(WatchWidget.SECONDS)
        val metrics = listOf(WatchWidget.STEPS, WatchWidget.HEART_RATE, WatchWidget.CALORIES, WatchWidget.DISTANCE).mapNotNull { b(it) }
        val bar = b(WatchWidget.STEP_PROGRESS)
        val status = listOfNotNull(b(WatchWidget.BLUETOOTH), b(WatchWidget.BATTERY))

        val infoH = info.maxOfOrNull { it.h } ?: 0
        val metricH = metrics.maxOfOrNull { it.h } ?: 0
        val blockH = (if (info.isNotEmpty()) infoH + gap else 0f) + time.h + (if (metrics.isNotEmpty()) gap + metricH else 0f) + (if (bar != null) gap + bar.h else 0f)
        val top = when (style.timePosition) {
            TimePosition.TOP -> spec.height * 0.17f
            TimePosition.CENTER -> (spec.height - blockH) / 2f
            TimePosition.BOTTOM -> spec.height * 0.86f - blockH
        }
        fun row(items: List<Built>, y: Float, spacing: Float) {
            val total = items.sumOf { it.w } + spacing * (items.size - 1).coerceAtLeast(0)
            var x = cx - total / 2f
            for (it in items) { out[it.widget] = Placed(it, RectF(x, y, x + it.w, y + it.h)); x += it.w + spacing }
        }
        var y = top
        if (info.isNotEmpty()) { row(info, y, infoH * 0.5f); y += infoH + gap }
        val sideW = maxOf(ampm?.w ?: 0, seconds?.w ?: 0)
        val sideGap = if (sideW > 0) s * 0.015f else 0f
        val timeLeft = cx - (time.w + sideGap + sideW) / 2f
        out[WatchWidget.TIME] = Placed(time, RectF(timeLeft, y, timeLeft + time.w, y + time.h))
        val sx = timeLeft + time.w + sideGap
        ampm?.let { out[WatchWidget.AMPM] = Placed(it, RectF(sx, y + time.h * 0.08f, sx + it.w, y + time.h * 0.08f + it.h)) }
        seconds?.let { val sy = y + time.h * 0.96f - it.h; out[WatchWidget.SECONDS] = Placed(it, RectF(sx, sy, sx + it.w, sy + it.h)) }
        y += time.h
        if (metrics.isNotEmpty()) { y += gap; row(metrics, y, s * 0.035f); y += metricH }
        if (bar != null) { y += gap; row(listOf(bar), y, 0f); y += bar.h }
        if (status.isNotEmpty()) {
            val sy = if (style.timePosition == TimePosition.TOP) spec.height * 0.88f else spec.height * 0.08f
            row(status, sy, status.first().h.toFloat())
        }
        if (WatchWidget.IMAGE in en) {
            val margin = spec.height * 0.07f
            val (rt, rb) = when (style.timePosition) {
                TimePosition.BOTTOM -> margin to top - spec.height * 0.03f
                TimePosition.TOP -> y + spec.height * 0.03f to spec.height - margin
                TimePosition.CENTER -> 0f to spec.height.toFloat()
            }
            val side = minOf(s * style.imageScale.coerceIn(0.3f, 1f), rb - rt)
            val (iw, ih) = artSize(image, side)
            val cy = (rt + rb) / 2f
            out[WatchWidget.IMAGE] = Placed(null, RectF(cx - iw / 2, cy - ih / 2, cx + iw / 2, cy + ih / 2))
        }
        return out
    }

    // ---------- Nền ----------

    private var cachedSource: Bitmap? = null
    private var cachedArt: Bitmap? = null
    private var cachedCover: Bitmap? = null

    /** Ảnh đã xoá nền đồng màu (cache theo ảnh nguồn, vì bước này tốn thời gian). */
    private fun art(image: Bitmap): Pair<Bitmap, Bitmap> {
        if (cachedSource !== image) {
            val cleaned = removeFlatBackground(image)
            cachedSource = image
            cachedArt = cleaned
            cachedCover = cropToContent(cleaned, image)
        }
        return cachedArt!! to cachedCover!!
    }

    private fun background(image: Bitmap, spec: WatchFaceSpec, style: WatchFaceStyle, placed: Map<WatchWidget, Placed>): Bitmap {
        val bmp = Bitmap.createBitmap(spec.width, spec.height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)
        canvas.drawColor(style.backgroundColor)
        val (art, cover) = art(image)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
        val cx = spec.width / 2f
        val imageRect = placed[WatchWidget.IMAGE]?.rect
        if (imageRect == null) {
            val k = maxOf(spec.width.toFloat() / cover.width, spec.height.toFloat() / cover.height)
            canvas.drawBitmap(cover, null, RectF(cx - cover.width * k / 2, spec.height / 2f - cover.height * k / 2, cx + cover.width * k / 2, spec.height / 2f + cover.height * k / 2), paint)
        } else {
            canvas.drawBitmap(art, null, imageRect, paint)
        }
        // Nền tối mờ sau từng khối chữ nằm đè lên ảnh.
        if (style.scrim) {
            val s = minOf(spec.width, spec.height)
            val pad = s * 0.018f
            val scrim = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0x70000000 }
            for ((w, p) in placed) {
                if (w == WatchWidget.IMAGE) continue
                if (imageRect != null && !RectF.intersects(imageRect, p.rect)) continue
                val r = RectF(p.rect.left - pad, p.rect.top - pad, p.rect.right + pad, p.rect.bottom + pad)
                canvas.drawRoundRect(r, minOf(r.height() / 2, s * 0.06f), minOf(r.height() / 2, s * 0.06f), scrim)
            }
        }
        if (spec.round) {
            val mask = Path().apply {
                addRect(0f, 0f, spec.width.toFloat(), spec.height.toFloat(), Path.Direction.CW)
                addCircle(cx, spec.height / 2f, minOf(spec.width, spec.height) / 2f, Path.Direction.CCW)
            }
            canvas.drawPath(mask, Paint().apply { color = 0xFF000000.toInt() })
        }
        return bmp
    }

    // ---------- Xuất ----------

    private fun cell(bg: Bitmap, x: Int, y: Int, w: Int, h: Int, frame: (Canvas) -> Unit): Bitmap {
        val cx = x.coerceIn(0, bg.width - w)
        val cy = y.coerceIn(0, bg.height - h)
        val c = Bitmap.createBitmap(bg, cx, cy, w, h).copy(Bitmap.Config.ARGB_8888, true)
        frame(Canvas(c))
        return c
    }

    private fun pixels(b: Bitmap) = IntArray(b.width * b.height).also { b.getPixels(it, 0, b.width, 0, 0, b.width, b.height) }

    /** Khung (pixel) của từng khối đang bật. */
    fun layout(image: Bitmap, spec: WatchFaceSpec, style: WatchFaceStyle): Map<WatchWidget, RectF> =
        place(image, spec, style).mapValues { RectF(it.value.rect) }

    /** Ảnh xem trước: nền + ảnh mẫu của từng khối (giờ 10:08, ngày 10/13…), bỏ qua [exclude]. */
    fun preview(image: Bitmap, spec: WatchFaceSpec, style: WatchFaceStyle, exclude: WatchWidget? = null): Bitmap {
        val placed = place(image, spec, style)
        val bg = background(image, spec, style, if (exclude == null) placed else placed - exclude)
        val out = bg.copy(Bitmap.Config.ARGB_8888, true)
        val canvas = Canvas(out)
        for ((w, p) in placed) {
            if (w == exclude) continue
            val b = p.built ?: continue
            for (slot in b.slots) {
                val x = (p.rect.left + slot.x).toInt()
                val y = (p.rect.top + slot.y).toInt()
                canvas.drawBitmap(cell(bg, x, y, slot.w, slot.h, slot.frames[slot.sample]), x.coerceIn(0, bg.width - slot.w).toFloat(), y.coerceIn(0, bg.height - slot.h).toFloat(), null)
            }
        }
        return out
    }

    /** Ảnh riêng của một khối trên nền trong suốt (để kéo thả). */
    fun sprite(image: Bitmap, spec: WatchFaceSpec, style: WatchFaceStyle, widget: WatchWidget): Bitmap {
        val p = place(image, spec, style)[widget] ?: return Bitmap.createBitmap(1, 1, Bitmap.Config.ARGB_8888)
        val w = maxOf(1, p.rect.width().toInt())
        val h = maxOf(1, p.rect.height().toInt())
        val out = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(out)
        val b = p.built
        if (b == null) {
            canvas.drawBitmap(art(image).first, null, RectF(0f, 0f, w.toFloat(), h.toFloat()), Paint(Paint.FILTER_BITMAP_FLAG))
        } else {
            for (slot in b.slots) {
                canvas.save()
                canvas.translate(slot.x.toFloat(), slot.y.toFloat())
                slot.frames[slot.sample](canvas)
                canvas.restore()
            }
        }
        return out
    }

    fun elements(image: Bitmap, spec: WatchFaceSpec, style: WatchFaceStyle): List<UteWatchFace.Element> {
        val placed = place(image, spec, style)
        val bg = background(image, spec, style, placed)
        val list = mutableListOf(UteWatchFace.Element(UteWatchFace.TYPE_BACKGROUND, 0, 0, spec.width, spec.height, listOf(pixels(bg))))
        for ((_, p) in placed) {
            val b = p.built ?: continue
            for (slot in b.slots) {
                val x = (p.rect.left + slot.x).toInt().coerceIn(0, bg.width - slot.w)
                val y = (p.rect.top + slot.y).toInt().coerceIn(0, bg.height - slot.h)
                list += UteWatchFace.Element(slot.type, x, y, slot.w, slot.h, slot.frames.map { pixels(cell(bg, x, y, slot.w, slot.h, it)) })
            }
        }
        list += UteWatchFace.Element(UteWatchFace.TYPE_PREVIEW, 0, 0, spec.width, spec.height, listOf(pixels(preview(image, spec, style))))
        return list
    }

    // ---------- Xử lý ảnh ----------

    /**
     * Xoá nền đồng màu quanh ảnh (ví dụ logo trên nền trắng): nếu 4 góc cùng màu, làm trong suốt các pixel
     * gần màu đó nằm ngoài bao lồi của hình. Ảnh không có nền đồng màu thì giữ nguyên.
     */
    fun removeFlatBackground(image: Bitmap, tolerance: Int = 40): Bitmap {
        val w = image.width
        val h = image.height
        val px = IntArray(w * h).also { image.copy(Bitmap.Config.ARGB_8888, false).getPixels(it, 0, w, 0, 0, w, h) }
        fun opaque(c: Int) = (c ushr 24) > 0x80
        fun near(a: Int, b: Int) = maxOf(
            Math.abs((a shr 16 and 0xFF) - (b shr 16 and 0xFF)),
            Math.abs((a shr 8 and 0xFF) - (b shr 8 and 0xFF)),
            Math.abs((a and 0xFF) - (b and 0xFF)),
        ) <= tolerance
        val corners = listOf(px[0], px[w - 1], px[(h - 1) * w], px[h * w - 1])
        val key = corners[0]
        if (!corners.all { opaque(it) && near(it, key) }) return image
        val points = mutableListOf<Pair<Int, Int>>()
        for (y in 0 until h) {
            var minX = -1
            var maxX = -1
            for (x in 0 until w) {
                val c = px[y * w + x]
                if (opaque(c) && !near(c, key)) { if (minX < 0) minX = x; maxX = x }
            }
            if (minX >= 0) { points += minX to y; points += maxX to y }
        }
        if (points.size < 3) return image
        val hull = convexHull(points)
        for (y in 0 until h) for (x in 0 until w) {
            val i = y * w + x
            if (near(px[i], key) && !inside(hull, x, y)) px[i] = 0
        }
        return Bitmap.createBitmap(px, w, h, Bitmap.Config.ARGB_8888)
    }

    /** Cắt [source] theo khung có nội dung của [mask] (bỏ viền trong suốt). */
    private fun cropToContent(mask: Bitmap, source: Bitmap = mask): Bitmap {
        val w = mask.width
        val h = mask.height
        val px = IntArray(w * h).also { mask.getPixels(it, 0, w, 0, 0, w, h) }
        var l = w; var t = h; var r = -1; var b = -1
        for (y in 0 until h) for (x in 0 until w) if ((px[y * w + x] ushr 24) > 0x20) {
            if (x < l) l = x; if (x > r) r = x; if (y < t) t = y; if (y > b) b = y
        }
        return if (r < l || b < t) source else Bitmap.createBitmap(source, l, t, r - l + 1, b - t + 1)
    }

    private fun cross(o: Pair<Int, Int>, a: Pair<Int, Int>, b: Pair<Int, Int>): Long =
        (a.first - o.first).toLong() * (b.second - o.second) - (a.second - o.second).toLong() * (b.first - o.first)

    private fun convexHull(points: List<Pair<Int, Int>>): List<Pair<Int, Int>> {
        val p = points.distinct().sortedWith(compareBy({ it.first }, { it.second }))
        val lower = mutableListOf<Pair<Int, Int>>()
        for (pt in p) { while (lower.size >= 2 && cross(lower[lower.size - 2], lower.last(), pt) <= 0) lower.removeAt(lower.lastIndex); lower += pt }
        val upper = mutableListOf<Pair<Int, Int>>()
        for (pt in p.asReversed()) { while (upper.size >= 2 && cross(upper[upper.size - 2], upper.last(), pt) <= 0) upper.removeAt(upper.lastIndex); upper += pt }
        return lower.dropLast(1) + upper.dropLast(1)
    }

    private fun inside(hull: List<Pair<Int, Int>>, x: Int, y: Int): Boolean {
        val pt = x to y
        for (i in hull.indices) if (cross(hull[i], hull[(i + 1) % hull.size], pt) < 0) return false
        return true
    }
}
