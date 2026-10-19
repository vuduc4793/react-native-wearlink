package com.smartwear.gloryfit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Cùng dữ liệu mẫu với `UteContactsTests` iOS (gói đã gửi thật lên Y25, đồng hồ trả `37 FB 01`). */
class UteContactsTest {
    private fun hexOf(b: ByteArray) = b.joinToString(" ") { "%02X".format(it) }
    private val y25 = Ute.Features(mapOf(5 to 0x002000, 6 to (0x6C2A01 or 0x080000)), 244)

    @Test fun singleContactMatchesWatchVerifiedPacket() {
        val segs = UteContacts.segments(listOf(UteContacts.Contact("Test SmartWear", "090 123 4567")), y25, 244)
        assertEquals(1, segs.size)
        assertEquals(244, segs[0].size)
        assertEquals("37 FB 01 37 FB 0A 1C 30 39 30 31 32 33 34 35 36 37 00 54", hexOf(segs[0].copyOf(19)))
    }

    @Test fun fourRecordsPerPacketAndVietnameseNames() {
        val list = (1..9).map { UteContacts.Contact("Nguyễn Văn Đức số $it dài quá", "+84 912 345 67$it") }
        val segs = UteContacts.segments(list, y25, 244)
        assertEquals(listOf(4, 4, 1), segs.map { it[2].toInt() })
        assertEquals(12, segs[0][5].toInt())
        assertEquals(40, segs[0][6].toInt())
        assertEquals("00 4E 00 67", hexOf(segs[0].copyOfRange(19, 23)))
        assertTrue(UteContacts.supported(y25))
        assertEquals(70, UteContacts.maxContacts(y25))
    }

    @Test fun callBluetoothStateParsing() {
        val p = byteArrayOf(0x38, 0x01) + "Y25(ID-6E1B)".toByteArray() + ByteArray(8) +
            byteArrayOf(0x78, 0x02, 0xB7.toByte(), 0x03, 0x6E, 0x1B, 1, 1, 1, 0, 0)
        assertEquals(
            UteContacts.CallBluetoothState("Y25(ID-6E1B)", "78:02:B7:03:6E:1B", true, true, true),
            UteContacts.parseCallBluetooth(p),
        )
    }
}
