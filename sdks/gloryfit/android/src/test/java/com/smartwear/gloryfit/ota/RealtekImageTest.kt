package com.smartwear.gloryfit.ota

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Kiểm với firmware Y25 thật. File không nằm trong git (sdks/gloryfit/research/firmware/, đã gitignore; scripts/android.sh
 * chỉ đồng bộ riêng file này sang máy build): xem [Y25Firmware]. Thiếu file thì bỏ qua.
 */
class RealtekImageTest {

    private fun y25(): RealtekImage = RealtekImage.parse(Y25Firmware.bytes())

    @Test fun headerFields() {
        val img = y25()
        assertEquals(RealtekImage.MP_HEADER_SIZE, img.imageOffset)
        assertEquals(RealtekImage.IMAGE_ID_APP, img.imageId)
        assertEquals(0x11, img.icType)
        assertEquals(0x0019AB74L, img.payloadLength)
        assertEquals(0x0019AF74, img.imageLength)
        assertEquals("RTL8763E", img.partNumber)
        assertEquals(0x96A01040L, img.imageVersion)
        assertFalse(img.encrypted)
        assertEquals("985B8AC4", img.pubKeyHash.joinToString("") { "%02X".format(it) })
    }

    @Test fun integrity() {
        val img = y25()
        assertTrue(img.crcOk())
        assertTrue(img.shaOk())
        assertTrue(img.pubKeyHashOk())
        assertTrue(img.signatureOk())
    }

    @Test fun modifiedByteBreaksChecks() {
        val bytes = y25().bytes.copyOf()
        bytes[bytes.size - 1] = (bytes[bytes.size - 1] + 1).toByte()
        val img = RealtekImage.parse(bytes)
        assertFalse(img.crcOk())
        assertFalse(img.shaOk())
        assertFalse(img.signatureOk())
    }

    @Test fun crc16ArcCheckValue() {
        // Giá trị kiểm chuẩn của CRC-16/ARC cho "123456789".
        val b = "123456789".toByteArray()
        assertEquals(0xBB3D, RealtekImage.crc16Arc(b, 0, b.size))
    }

    @Test fun strictVerifyAcceptsOriginal() {
        val img = RealtekImage.load(Y25Firmware.bytes())
        assertEquals(Y25Firmware.SHA256, img.fileSha256)
        assertEquals(img.imageLength, img.wire.size)
    }
}

/**
 * Tìm `RB370L73AC_V001205.bin`: biến môi trường `REALTEK_IMAGE`, rồi `sdks/gloryfit/research/firmware/` (thư mục làm việc
 * của test Gradle là `sdks/gloryfit/android`), rồi /tmp. Thiếu file ⇒ test bị bỏ qua (assume), không báo lỗi.
 */
object Y25Firmware {
    const val SHA256 = "7d477c2d76f3f4040cf3f0b08f68bb5734efbbc889a2a057eff2b3472eb83e55"
    private val cached: ByteArray? by lazy {
        listOfNotNull(
            System.getenv("REALTEK_IMAGE"),
            "../research/firmware/RB370L73AC_V001205.bin",
            "sdks/gloryfit/research/firmware/RB370L73AC_V001205.bin",
            "/tmp/RB370L73AC_V001205.bin",
        ).map(::File).firstOrNull { it.isFile }?.readBytes()
    }

    fun bytes(): ByteArray {
        org.junit.Assume.assumeTrue("thiếu firmware Y25 (đặt REALTEK_IMAGE)", cached != null)
        return cached!!.copyOf()
    }
}
