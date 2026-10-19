package com.smartwear.gloryfit

import java.io.ByteArrayOutputStream
import java.util.zip.CRC32

/**
 * Đóng gói file mặt đồng hồ UTE (`.bin`), xem sdks/gloryfit/docs/02-watchface.md §4.
 * `[header 24 B][bảng element N × 24 B][00 00][ảnh element 1][element 2]…`, số nhiều byte little-endian,
 * pixel RGB565 big-endian, nén RLE khi `level ≥ 2` (trừ các type kim / chữ số).
 */
object UteWatchFace {

    // Type element (onlinedial/ConfigType.java).
    const val TYPE_PREVIEW = 10
    const val TYPE_BACKGROUND = 17
    const val TYPE_HOUR_TENS = 57
    const val TYPE_HOUR_UNITS = 58
    const val TYPE_MINUTE_TENS = 59
    const val TYPE_MINUTE_UNITS = 60
    const val TYPE_COLON = 7
    const val TYPE_BATTERY = 8
    const val TYPE_MONTH_TENS = 63
    const val TYPE_MONTH_UNITS = 64
    const val TYPE_DAY_TENS = 65
    const val TYPE_DAY_UNITS = 66
    const val TYPE_DATE_SEPARATOR = 14
    const val TYPE_WEEK = 15
    const val TYPE_AMPM = 16
    const val TYPE_BLUETOOTH = 9
    const val TYPE_STEP_ICON = 24
    val TYPE_STEP_DIGITS = listOf(38, 39, 40, 41, 42)
    const val TYPE_STEP_PROGRESS = 32
    // Firmware có định nghĩa (ConfigType.java) nhưng template của hãng không dùng: thử nghiệm.
    const val TYPE_SECOND_TENS = 61
    const val TYPE_SECOND_UNITS = 62
    const val TYPE_HEART_ICON = 18
    val TYPE_HEART_DIGITS = listOf(35, 36, 37)
    const val TYPE_KCAL_ICON = 29
    val TYPE_KCAL_DIGITS = listOf(43, 44, 45, 46)
    const val TYPE_DISTANCE_ICON = 51
    val TYPE_DISTANCE_DIGITS = listOf(52, 53, 54, 55, 56)

    /** Một element: [frames] là các ảnh ARGB cùng kích thước [w]×[h] (ví dụ 14 ảnh chữ số). */
    class Element(val type: Int, val x: Int, val y: Int, val w: Int, val h: Int, val frames: List<IntArray>) {
        init {
            require(frames.isNotEmpty() && frames.all { it.size == w * h }) { "Element $type: kích thước ảnh không khớp ${w}x$h" }
        }
    }

    private val NO_COMPRESS = (1..3) + (35..46) + (52..70)

    /**
     * ARGB → RGB565 big-endian. Pixel gần đen được đẩy thành (17,9,17) như app GloryFit, vì firmware
     * (suy luận) coi 0x0000 là màu trong suốt.
     */
    fun rgb565(argb: IntArray): ByteArray {
        val out = ByteArray(argb.size * 2)
        for (i in argb.indices) {
            var r = argb[i] shr 16 and 0xFF
            var g = argb[i] shr 8 and 0xFF
            var b = argb[i] and 0xFF
            if (r <= 16 && g <= 8 && b <= 16) { r = 17; g = 9; b = 17 }
            val v = ((r shr 3) shl 11) or ((g shr 2) shl 5) or (b shr 3)
            out[2 * i] = (v shr 8).toByte()
            out[2 * i + 1] = v.toByte()
        }
        return out
    }

    /** RLE của UTE (Rgb.picDataCompress): `u32 len + bảng offset H dòng + các dòng [n][count][màu…]`. */
    fun rle(px: ByteArray, w: Int, h: Int): ByteArray {
        val table = ByteArrayOutputStream()
        val rows = ByteArrayOutputStream()
        var offset = h * 4
        for (r in 0 until h) {
            val base = r * w * 2
            fun same(a: Int, c: Int) = px[base + 2 * a] == px[base + 2 * c] && px[base + 2 * a + 1] == px[base + 2 * c + 1]
            var pending = ByteArray(0)
            var prev = 0
            var rowBytes = 0
            var start = 0
            var i = 0
            var count = 0
            while (i < w) {
                if (same(start, i) && count != 255) {
                    count++
                    i++
                    if (i != w) continue
                }
                val hi = px[base + 2 * start]
                val lo = px[base + 2 * start + 1]
                val block = when {
                    prev == 0 -> byteArrayOf(1, count.toByte(), hi, lo)
                    prev == count && (pending[0].toInt() and 0xFF) < 255 ->
                        (pending + byteArrayOf(hi, lo)).also { it[0] = (it[0] + 1).toByte() }
                    else -> {
                        rows.write(pending)
                        rowBytes += pending.size
                        byteArrayOf(1, count.toByte(), hi, lo)
                    }
                }
                if (i == w) {
                    rows.write(block)
                    rowBytes += block.size
                    table.write(le32(offset))
                    offset += rowBytes
                }
                prev = count
                pending = block
                count = 0
                start = i
            }
        }
        val body = table.toByteArray() + rows.toByteArray()
        return le32(body.size) + body
    }

    fun build(width: Int, height: Int, level: Int, elements: List<Element>): ByteArray {
        val sorted = elements.sortedBy { it.type }
        val blobs = sorted.map { e ->
            val out = ByteArrayOutputStream()
            for (frame in e.frames) {
                val px = rgb565(frame)
                out.write(if (level >= 2 && e.type !in NO_COMPRESS) rle(px, e.w, e.h) else px)
            }
            out.toByteArray()
        }
        // Element có dữ liệu giống hệt element trước thì trỏ chung địa chỉ, không chép lại (PicUtils.java:854-881).
        val addresses = IntArray(sorted.size)
        val unique = mutableListOf<ByteArray>()
        var address = (sorted.size + 1) * 24 + 2
        sorted.indices.forEach { k ->
            val previous = (0 until k).firstOrNull { blobs[it].contentEquals(blobs[k]) }
            if (previous != null) {
                addresses[k] = addresses[previous]
            } else {
                addresses[k] = address
                address += blobs[k].size
                unique += blobs[k]
            }
        }
        val body = ByteArrayOutputStream()
        sorted.forEachIndexed { k, e ->
            body.write(le16(e.type)); body.write(le16(e.w)); body.write(le32(addresses[k])); body.write(le16(e.h))
            body.write(le16(e.x)); body.write(le16(e.y)); body.write(le16(0))
            body.write(e.frames.size)
            body.write(ByteArray(7))
        }
        body.write(ByteArray(2))
        unique.forEach(body::write)
        val payload = body.toByteArray()
        val crc = CRC32().apply { update(payload) }.value.toInt()
        val header = ByteArray(24) { 0xFF.toByte() }
        header[0] = 0xFE.toByte()
        le32(payload.size).copyInto(header, 4)
        le32(crc).copyInto(header, 8)
        le16(width).copyInto(header, 12)
        le16(height).copyInto(header, 14)
        header[16] = 0
        header[17] = 1
        header[19] = level.toByte()
        return header + payload
    }

    private fun le16(v: Int) = byteArrayOf(v.toByte(), (v shr 8).toByte())
    private fun le32(v: Int) = byteArrayOf(v.toByte(), (v shr 8).toByte(), (v shr 16).toByte(), (v shr 24).toByte())
}
