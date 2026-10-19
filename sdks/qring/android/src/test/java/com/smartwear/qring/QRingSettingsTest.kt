package com.smartwear.qring

import com.smartwear.core.ControlValue
import com.smartwear.qring.protocol.Packet
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Cùng dữ liệu mẫu với `QRingSettingsTests` iOS. */
class QRingSettingsTest {
    private fun payload(vararg v: Int) = IntArray(14) { v.getOrElse(it) { 0 } }
    private fun ring() = QRingCapabilities(ByteArray(14).also { it[3] = 0x02 }, ByteArray(14).also { it[1] = 0x40 })
    private fun band() = QRingCapabilities(ByteArray(14).also { it[3] = 0x02 }, ByteArray(14))

    @Test fun parsesReads() {
        val hr = QRingSettings.parse(0x16, payload(1, 1, 10, 0, 40, 150, 1, 60))
        assertEquals(1, hr["hrAuto.enabled"])
        assertEquals(10, hr["hrAuto.interval"])
        assertEquals(5, hr["hrAuto.start"])
        assertEquals(150, hr["hrAuto.high"])
        // 21 01: bước 8000 (40 1F 00), 300 000 cal, 5000 m, 30 phút, 480 phút (LE)
        val goals = QRingSettings.parse(0x21, payload(1, 0x40, 0x1F, 0, 0xE0, 0x93, 0x04, 0x88, 0x13, 0, 30, 0, 0xE0, 0x01))
        assertEquals(mapOf("goal.steps" to 8000, "goal.calories" to 300, "goal.distance" to 5, "goal.exercise" to 30, "goal.sleep" to 480), goals)
        val sit = QRingSettings.parse(0x26, payload(0x09, 0x30, 0x18, 0x00, 0x7F, 90))
        assertEquals(9 * 60 + 30, sit["sedentary.range.from"])
        assertEquals(18 * 60, sit["sedentary.range.to"])
        assertEquals(90, sit["sedentary.interval"])
    }

    @Test fun writesPreserveReadBytes() {
        var v = QRingSettings.parse(0x16, payload(1, 1, 10, 5, 40, 150, 1))
        v = QRingSettings.apply(v, "hrAuto.enabled", ControlValue.Bool(false))
        assertEquals(Packet.of(0x16, 2, 2, 10, 5, 40, 150, 1).toString(), QRingSettings.write("hrAuto.enabled", v).toString())
        v = QRingSettings.apply(v, "goal.steps", ControlValue.Number(10_000))
        assertEquals(
            Packet.of(0x21, 2, 0x10, 0x27, 0, 0xE0, 0x93, 0x04, 0x88, 0x13, 0, 30, 0, 0xE0, 0x01).toString(),
            QRingSettings.write("goal.steps", v).toString(),
        )
        v = QRingSettings.apply(v, "sedentary.interval", ControlValue.Number(0)) // lựa chọn 0 = 30 phút
        v = QRingSettings.apply(v, "sedentary.enabled", ControlValue.Bool(true))
        assertEquals(Packet.of(0x25, 0x09, 0x00, 0x18, 0x00, 0x7F, 30).toString(), QRingSettings.write("sedentary.enabled", v).toString())
        assertEquals("50 55 AA 00 00 00 00 00 00 00 00 00 00 00 00 4F", QRingSettings.write("find.start", v).toString())
    }

    @Test fun ringHasNoScreenSettings() {
        val ring = QRingSettings.controls(ring(), emptyMap(), ring = true).map { it.id }
        assertTrue("find.start" in ring)
        assertTrue("spo2Auto.enabled" in ring)
        assertFalse("dnd.enabled" in ring)
        assertFalse("display.raise" in ring)
        val band = QRingSettings.controls(band(), emptyMap(), ring = false).map { it.id }
        assertTrue("dnd.enabled" in band)
        assertTrue("sedentary.range" in band)
        assertEquals(listOf(0x16, 0x2C, 0x21, 0x0A), QRingSettings.reads(band(), ring = true).map { it.command })
    }
}
