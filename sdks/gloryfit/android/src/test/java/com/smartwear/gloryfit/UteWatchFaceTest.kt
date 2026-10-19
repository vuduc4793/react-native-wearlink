package com.smartwear.gloryfit

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test
import java.util.zip.CRC32

/** Ví dụ trong sdks/gloryfit/docs/02-watchface.md §4. */
class UteWatchFaceTest {
    private fun hex(s: String) = s.split(" ").map { it.toInt(16).toByte() }.toByteArray()
    private fun le32(b: ByteArray, i: Int) = (b[i].toInt() and 0xFF) or ((b[i + 1].toInt() and 0xFF) shl 8) or
        ((b[i + 2].toInt() and 0xFF) shl 16) or ((b[i + 3].toInt() and 0xFF) shl 24)

    @Test
    fun crc32CheckValue() {
        assertEquals(0xCBF43926L, CRC32().apply { update("123456789".toByteArray()) }.value)
    }

    @Test
    fun rgb565BigEndianAndNearBlack() {
        assertArrayEquals(hex("F8 00 FF FF 10 42"), UteWatchFace.rgb565(intArrayOf(0xFFFF0000.toInt(), 0xFFFFFFFF.toInt(), 0xFF000000.toInt())))
    }

    @Test
    fun rleTwoRuns() {
        // 100 px "đen" (0x0000) rồi 140 px trắng: 01 64 00 00 01 8C FF FF.
        val px = ByteArray(240 * 2).also { for (i in 100 until 240) { it[2 * i] = 0xFF.toByte(); it[2 * i + 1] = 0xFF.toByte() } }
        val out = UteWatchFace.rle(px, 240, 1)
        assertEquals(4 + 8, le32(out, 0))          // bảng 1 dòng (4 byte) + 8 byte dữ liệu
        assertEquals(4, le32(out, 4))              // dòng 0 bắt đầu sau bảng
        assertArrayEquals(hex("01 64 00 00 01 8C FF FF"), out.copyOfRange(8, 16))
    }

    @Test
    fun rleMergesSinglePixels() {
        val px = hex("11 11 22 22 33 33")
        val out = UteWatchFace.rle(px, 3, 1)
        assertArrayEquals(hex("03 01 11 11 22 22 33 33"), out.copyOfRange(8, out.size))
    }

    @Test
    fun headerAndTable() {
        val bg = UteWatchFace.Element(UteWatchFace.TYPE_BACKGROUND, 0, 0, 2, 1, listOf(intArrayOf(-1, -1)))
        val digit = UteWatchFace.Element(UteWatchFace.TYPE_HOUR_TENS, 5, 6, 1, 1, List(14) { intArrayOf(-1) })
        val bin = UteWatchFace.build(466, 466, level = 0, elements = listOf(digit, bg))
        assertArrayEquals(hex("FE FF FF FF"), bin.copyOfRange(0, 4))
        val payload = bin.copyOfRange(24, bin.size)
        assertEquals(payload.size, le32(bin, 4))
        assertEquals(CRC32().apply { update(payload) }.value.toInt(), le32(bin, 8))
        assertArrayEquals(hex("D2 01 D2 01 00 01 FF 00 FF FF FF FF"), bin.copyOfRange(12, 24))
        // Element sắp theo type: nền (17) trước chữ số (57); dữ liệu bắt đầu ở (2+1)*24+2 = 74.
        assertEquals(17, bin[24].toInt())
        assertEquals(74, le32(bin, 24 + 4))
        assertEquals(57, bin[48].toInt())
        assertEquals(74 + 4, le32(bin, 48 + 4))
        assertEquals(14, bin[48 + 16].toInt())
    }
}
