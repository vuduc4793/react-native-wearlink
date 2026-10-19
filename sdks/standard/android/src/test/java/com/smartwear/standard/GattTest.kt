package com.smartwear.standard

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
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
}
