package com.smartwear.gloryfit

import com.smartwear.core.ControlValue
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate

/** Cùng dữ liệu mẫu với `UteSettingsTests` iOS. */
class UteSettingsTest {
    private fun hex(s: String) = s.split(" ").map { it.toInt(16).toByte() }.toByteArray()
    private fun hexOf(b: ByteArray) = b.joinToString(" ") { "%02X".format(it) }

    /** Bảng tính năng 33F1 của Y25 (bit theo docs/feature-matrix.md phụ lục A). */
    private val y25 = Ute.Features(
        mapOf(1 to 0x4BA0CC, 2 to 0x00547C, 3 to 0x00D921, 4 to 0x75EEDF, 5 to 0x200962),
        244,
    )
    private val today = LocalDate.of(2026, 10, 15)

    @Test fun defaultsMatchLegacyUserInfo() {
        assertArrayEquals(Ute.userInfo(), UteControls.userInfo(UteSettings()))
        assertEquals("A0 01 01", hexOf(UteControls.units(UteSettings())))
    }

    @Test fun encodeRoundTrip() {
        val s = UteSettings()
            .with("goal.steps", ControlValue.Number(10_000))
            .with("dnd.range", ControlValue.TimeRange(23 * 60, 6 * 60 + 30))
            .with("display.raise", ControlValue.Bool(false))
        val back = UteSettings.decode(s.encode())
        assertEquals(10_000, back["goal.steps"])
        assertEquals(23 * 60, back["dnd.range.from"])
        assertEquals(390, back["dnd.range.to"])
        assertFalse(back.on("display.raise"))
        assertEquals(170, back["profile.height"])
    }

    @Test fun profileAndAlertsGoToA9() {
        val s = UteSettings()
            .with("profile.height", ControlValue.Number(175))
            .with("hrHigh.enabled", ControlValue.Bool(true))
            .with("hrHigh.value", ControlValue.Number(150))
            .with("hrLow.enabled", ControlValue.Bool(true))
            .with("unit.fahrenheit", ControlValue.Bool(true))
            .with("profile.gender", ControlValue.Number(1))
        val cmds = UteControls.commands("profile.height", y25, s)
        assertEquals(1, cmds.size)
        assertEquals("A9 00 AF 00 41 05 00 00 1F 40 01 96 00 1E 02 00 02 02 2D", hexOf(cmds[0]))
    }

    @Test fun reminders() {
        val s = UteSettings()
            .with("sedentary.enabled", ControlValue.Bool(true))
            .with("sedentary.interval", ControlValue.Number(45))
        assertEquals("D3 01 2D 02 03 01 00 09 00 12 00 01", hexOf(UteControls.commands("sedentary.interval", y25, s).single()))
        val noRange = Ute.Features(mapOf(1 to 0x010000), null)
        assertEquals("D3 01 2D 02 03 01 00", hexOf(UteControls.commands("sedentary.enabled", noRange, s).single()))

        val dnd = UteSettings().with("dnd.scheduled", ControlValue.Bool(true)).with("dnd.vibration", ControlValue.Bool(false))
        assertEquals("D7 04 16 00 07 00 01", hexOf(UteControls.commands("dnd.scheduled", y25, dnd).single()))
        // Bit 3 = từ chối cuộc gọi trên đồng hồ (`DoNotDisturbInfo.setEndCallSwitch`, uterkthis.java:4029-4070).
        val endCall = UteSettings().with("dnd.endCall", ControlValue.Bool(true))
        assertEquals("D7 0E 16 00 07 00 00", hexOf(UteControls.commands("dnd.endCall", y25, endCall).single()))
        assertFalse(UteControls.controls(y25, endCall, today).any { it.id == "dnd.endCall" })
    }

    @Test fun goals() {
        val s = UteSettings().with("goal.steps", ControlValue.Number(12_000)).with("goal.distance", ControlValue.Number(5))
        val steps = UteControls.commands("goal.steps", y25, s)
        assertEquals(2, steps.size)
        assertEquals("3F 04 01 00 00 2E E0", hexOf(steps[1]))
        assertEquals("3F 03 01 01 2C", hexOf(UteControls.commands("goal.calories", y25, s).single()))
        assertEquals("3F 05 01 00 00 13 88", hexOf(UteControls.commands("goal.distance", y25, s).single()))
    }

    @Test fun heartRateAndMisc() {
        val off = UteSettings().with("hr24.enabled", ControlValue.Bool(false))
        assertEquals(listOf("F7 02"), UteControls.commands("hr24.enabled", y25, off).map(::hexOf))
        val ten = UteSettings().with("hr24.interval", ControlValue.Number(10))
        assertEquals(listOf("F7 01", "F7 09 01 00 0A"), UteControls.commands("hr24.interval", y25, ten).map(::hexOf))
        assertEquals("D1 0A 00", hexOf(UteControls.commands("findPhone.enabled", y25, UteSettings().with("findPhone.enabled", ControlValue.Bool(false))).single()))
        assertEquals("AF AB 63", hexOf(UteControls.commands("language", y25, UteSettings().with("language", ControlValue.Number(1))).single()))
        assertTrue(UteControls.commands("language", y25, UteSettings()).isEmpty())
        assertEquals("A0 01 02", hexOf(UteControls.commands("unit.hour12", y25, UteSettings().with("unit.hour12", ControlValue.Bool(true))).single()))
    }

    @Test fun periodStoresAbsoluteDate() {
        val s = UteSettings().with("period.enabled", ControlValue.Bool(true)).with("period.daysAgo", ControlValue.Number(3), today)
        assertEquals("29 01 07 EA 0A 0C 05 1C", hexOf(UteControls.commands("period.daysAgo", y25, s, today).single()))
        // Hai ngày sau vẫn là ngày 12/10: giao diện hiện "cách đây 5 ngày".
        val later = UteControls.controls(y25, s, today.plusDays(2)).first { it.id == "period.daysAgo" }
        assertEquals(ControlValue.Number(5), later.value)
    }

    @Test fun controlsFollowFeatureFlags() {
        val ids = UteControls.controls(y25, UteSettings(), today).map { it.id }.toSet()
        assertTrue("find.start" in ids)
        assertTrue("sedentary.range" in ids)
        assertTrue("dnd.scheduled" in ids)
        assertTrue("hrLow.enabled" in ids)
        assertTrue("period.enabled" in ids)
        assertFalse("drink.enabled" in ids) // Y25 không có nhắc uống nước (b5.3 = 0)
        // Y25 có F5 0x40 ⇒ có SpO2 tự động như GloryFitPro (`RkSupportUtils.isSupOxygenSetting`).
        assertTrue("spo2Auto.enabled" in ids)
        val bare = UteControls.controls(Ute.Features(emptyMap(), null), UteSettings(), today).map { it.id }
        assertFalse("dnd.scheduled" in bare)
        assertFalse("hr24.enabled" in bare)
        // Mục con bị khoá khi mục cha tắt
        val interval = UteControls.controls(y25, UteSettings(), today).first { it.id == "sedentary.interval" }
        assertFalse(interval.enabled)
    }

    @Test fun findWatch() {
        assertArrayEquals(hex("AB 00 00 00 01 02 07 01"), UteControls.FIND_WATCH)
    }
}
