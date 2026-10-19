package com.smartwear.qring

import com.smartwear.core.Capability
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Dữ liệu thật đọc từ thiết bị ngày 2026-10-13 (sdks/qring/docs/devices.md). */
class QRingCapabilitiesTest {

    private fun hex(s: String) = s.split(" ").map { it.toInt(16).toByte() }.toByteArray()

    @Test
    fun r09() {
        val caps = QRingCapabilities(
            hex("01 00 00 02 00 00 00 00 01 00 20 00 00 30"),
            hex("00 AC 27 00 00 00 00 00 00 00 00 00 00 00"),
        )
        assertEquals(
            setOf(
                Capability.HEART_RATE, Capability.STEPS, Capability.SLEEP, Capability.SPO2,
                Capability.TEMPERATURE, Capability.STRESS, Capability.HRV, Capability.GESTURE,
            ),
            caps.toCapabilities(),
        )
        assertTrue(caps.newSleepProtocol)
        assertTrue(caps.blePair)
        assertFalse(caps.noScreen)
    }

    @Test
    fun hs500a() {
        val caps = QRingCapabilities(
            hex("00 00 01 16 00 00 00 00 01 00 20 00 00 30"),
            hex("00 40 00 A0 00 00 08 30 00 00 00 00 00 00"),
        )
        assertEquals(
            setOf(
                Capability.HEART_RATE, Capability.STEPS, Capability.SLEEP, Capability.SPO2,
                Capability.BLOOD_PRESSURE, Capability.STRESS, Capability.HRV, Capability.MENSTRUATION,
            ),
            caps.toCapabilities(),
        )
        assertTrue(caps.noScreen)
        assertFalse(caps.temperature)
    }
}
