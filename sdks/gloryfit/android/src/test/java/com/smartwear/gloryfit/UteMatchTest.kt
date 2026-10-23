package com.smartwear.gloryfit

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID

/** Nhận diện khi quét (như GloryFitMatchTests iOS): UUID quảng bá hoặc tiền tố tên. */
class UteMatchTest {
    private fun u16(v: Int) = UUID.fromString("0000%04x-0000-1000-8000-00805f9b34fb".format(v))

    @Test
    fun byName() {
        assertTrue(Ute.matches("Y25_6E1B", emptyList()))
        assertTrue(Ute.matches("HT43(ID-2750)", emptyList()))
    }

    @Test
    fun byAdvertisedService() {
        assertTrue(Ute.matches(null, listOf(u16(0x5533))))
        for (v in listOf(0x5554, 0x4544, 0x4231, 0x424C, 0x4F4F, 0x3455)) assertTrue(Ute.matches(null, listOf(u16(v))))
    }

    @Test
    fun otherDevices() {
        assertFalse(Ute.matches("COROS PACE 3 8E1086", listOf(u16(0x180F), u16(0x180A), u16(0xFEE7))))
        assertFalse(Ute.matches("R09_8404", listOf(u16(0xFEE7))))
        assertFalse(Ute.matches(null, emptyList()))
    }
}
