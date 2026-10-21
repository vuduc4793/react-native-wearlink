package com.smartwear.gloryfit

import com.smartwear.core.AgpsFile
import com.smartwear.core.AgpsRequestType
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/** Gói `01 E9` dựng theo GloryFitPro `uterkif/uterkcase.java` (doc 09 §4). */
class UteAgpsTest {
    private fun hex(s: String) = s.split(" ").map { it.toInt(16).toByte() }.toByteArray()

    @Test
    fun commands() {
        assertArrayEquals(hex("01 E9 AA 01"), UteAgps.INFO)
        assertArrayEquals(hex("56 FD"), UteAgps.EPHEMERIS_STATE)
        assertArrayEquals(hex("01 E9 AB 03 01 03"), UteAgps.status(UteAgps.STATUS_DONE))
        assertArrayEquals(hex("01 E9 AB 03 01 05"), UteAgps.status(UteAgps.STATUS_NOT_SUPPORT))
        // Hà Nội, toạ độ × 10⁷, giây Unix big-endian.
        assertArrayEquals(
            hex("01 E9 AB 02 0C 12 34 56 78 0C 88 B1 C8 3F 18 11 B0"),
            UteAgps.position(0x12345678, 21.0285, 105.8542),
        )
        assertArrayEquals(hex("01 E9 AB 02 0C 00 00 00 01 EB D0 08 00 3F 18 11 B0"), UteAgps.position(1, -33.8688, 105.8542))
        assertThrows(IllegalArgumentException::class.java) { UteAgps.position(1, 91.0, 0.0) }
        assertArrayEquals(hex("01 E9 AB 04 01 02 AA BB"), UteAgps.dataPacket(0x0102, hex("AA BB")))
        assertArrayEquals(hex("01 E9 AB 04 FD FD 5A"), UteAgps.endPacket(0x5A))
    }

    @Test
    fun requests() {
        assertEquals(AgpsRequestType.STATUS, UteAgps.parseRequest(hex("01 E9 AC 03 01 02")))
        assertEquals(AgpsRequestType.DOWNLOAD, UteAgps.parseRequest(hex("01 E9 AC 03 01 01")))
        assertEquals(AgpsRequestType.POSITION, UteAgps.parseRequest(hex("01 E9 AC 01 00 01")))
        assertNull(UteAgps.parseRequest(hex("01 E9 AC 01 00 00")))
        assertNull(UteAgps.parseRequest(hex("01 E9 AC 04 01 07")))
        assertNull(UteAgps.parseRequest(hex("FD 01 AA 01")))
        assertTrue(UteAgps.isTransferResult(hex("01 E9 AC 04 01 07")))
        assertEquals(0x0123, UteAgps.resendFrom(hex("01 E9 AC 04 01 06 01 23")))
        assertNull(UteAgps.resendFrom(hex("01 E9 AC 04 01 07")))
        assertEquals(true, UteAgps.parseEphemerisState(hex("56 FD 01")))
        assertEquals(false, UteAgps.parseEphemerisState(hex("56 FD 00")))
        assertNull(UteAgps.parseEphemerisState(hex("56 01 00")))
    }

    @Test
    fun info() {
        // TLV: interval 60, version 7, danh sách file "gps_gal;gps_bds", chia hai gói.
        val packets = listOf(
            hex("01 E9 AA 01 00 01 01 3C 02 02 00 07 03 0F 67 70 73 5F"),
            hex("01 E9 AA 01 01 67 61 6C 3B 67 70 73 5F 62 64 73"),
            hex("01 E9 AA 01 FD 00"),
        )
        assertTrue(UteAgps.isInfoEnd(packets[2]))
        val info = UteAgps.parseInfo(packets, ephemerisValid = false)
        assertEquals(60, info.interval)
        assertEquals(7, info.version)
        assertEquals(listOf("gps_gal", "gps_bds"), info.files)
        assertEquals(false, info.ephemerisValid)
        // TLV cụt: không đọc quá cuối, không lỗi.
        assertEquals(emptyList<String>(), UteAgps.parseInfo(listOf(hex("01 E9 AA 01 00 03 09 61"))).files)
    }

    @Test
    fun payloadAndPackets() {
        val files = listOf(AgpsFile("gps_gal.dat", hex("01 02 03")), AgpsFile("bds", hex("04 05")))
        val payload = UteAgps.payload(files)
        assertArrayEquals(
            hex("00 14 07 67 70 73 5F 67 61 6C 00 00 00 03 03 62 64 73 00 00 00 02 00 00 00 05 01 02 03 04 05"),
            payload,
        )
        val packets = UteAgps.packets(payload, 14)
        assertEquals(3, packets.size)
        assertArrayEquals(hex("01 E9 AB 04 00 02 03 04 05"), packets[2])
        var x = 0
        packets.forEach { p -> p.forEach { x = x xor (it.toInt() and 0xFF) } }
        assertEquals(x, UteAgps.xor(packets))
    }

    @Test
    fun limits() {
        assertThrows(IllegalArgumentException::class.java) { UteAgps.payload(emptyList()) }
        assertThrows(IllegalArgumentException::class.java) { UteAgps.payload(listOf(AgpsFile("a", ByteArray(0)))) }
        assertThrows(IllegalArgumentException::class.java) { UteAgps.payload(listOf(AgpsFile("a", ByteArray(UteAgps.MAX_FILE_BYTES + 1)))) }
        assertThrows(IllegalArgumentException::class.java) { UteAgps.payload(listOf(AgpsFile("tên lạ", hex("01")))) }
        assertThrows(IllegalArgumentException::class.java) {
            UteAgps.payload(List(3) { AgpsFile("f$it", ByteArray(UteAgps.MAX_FILE_BYTES)) })
        }
        assertEquals("gps_gal", UteAgps.stem("dir/gps_gal.dat"))
    }
}
