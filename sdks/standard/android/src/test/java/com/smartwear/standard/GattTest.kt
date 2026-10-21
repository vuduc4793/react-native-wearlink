package com.smartwear.standard

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class GattTest {
    private fun bytes(vararg v: Int) = ByteArray(v.size) { v[it].toByte() }

    @Test
    fun heartRateUInt8() {
        assertEquals(72, Gatt.parseHeartRate(bytes(0x00, 72)))
        // Bit cảm biến tiếp xúc (bit 1-2) không ảnh hưởng định dạng.
        assertEquals(150, Gatt.parseHeartRate(bytes(0x06, 150)))
    }

    @Test
    fun heartRateUInt16() {
        assertEquals(300, Gatt.parseHeartRate(bytes(0x01, 0x2C, 0x01)))
    }

    @Test
    fun heartRateTooShort() {
        assertNull(Gatt.parseHeartRate(bytes()))
        assertNull(Gatt.parseHeartRate(bytes(0x01, 0x2C)))
    }

    @Test
    fun measurementContactAndRr() {
        // flags 0x16: UInt8, có báo tiếp xúc (bit 2) + đang chạm (bit 1), có RR (bit 4). RR 0x0400 = 1024/1024 s = 1000 ms, 0x0333 = 819 → 800 ms.
        val s = Gatt.parseHeartRateMeasurement(bytes(0x16, 60, 0x00, 0x04, 0x33, 0x03), timestamp = 5)!!
        assertEquals(60, s.bpm)
        assertEquals(true, s.contact)
        assertEquals(listOf(1000, 800), s.rrMs)
        assertEquals(5L, s.timestamp)
    }

    @Test
    fun measurementEnergySkippedBeforeRr() {
        // flags 0x19: UInt16, Energy Expended (2 byte bỏ qua), RR 0x0200 = 500 ms; không báo tiếp xúc ⇒ contact null.
        val s = Gatt.parseHeartRateMeasurement(bytes(0x19, 0x8C, 0x00, 0x10, 0x00, 0x00, 0x02))!!
        assertEquals(140, s.bpm)
        assertNull(s.contact)
        assertEquals(listOf(500), s.rrMs)
    }

    @Test
    fun measurementNoContactZeroBpm() {
        // Có báo tiếp xúc nhưng không chạm (bit 2, không bit 1), nhịp tim 0 ⇒ bpm null; gói RR lẻ byte thì bỏ byte thừa.
        val s = Gatt.parseHeartRateMeasurement(bytes(0x14, 0, 0x00, 0x04, 0x01))!!
        assertNull(s.bpm)
        assertEquals(false, s.contact)
        assertEquals(listOf(1000), s.rrMs)
        assertNull(Gatt.parseHeartRate(bytes(0x00, 0)))
        assertTrue(Gatt.parseHeartRateMeasurement(bytes(0x00, 72))!!.rrMs.isEmpty())
    }
}
