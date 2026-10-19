package com.smartwear.gloryfit

import com.smartwear.core.ControlValue
import com.smartwear.core.DeviceEvent
import com.smartwear.core.WatchFaceSlot
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate

/**
 * Lệnh hệ thống mới: `AF AA`, `BE 01/02`, `26 05/08/09`, `D1 01/04/05/06`, `33F3`, `37 BA`, `AD`, khung giờ `34 04`/`F7 0F`/
 * `69 AB`, mốc đồng bộ `[op] FA YYYY MM DD HH mm` (đối chiếu `uterkthis.java`, `uterkint.java`, `uterkclass.java`, `uterkelse.java`).
 */
class UteSystemTest {
    private fun hex(s: String) = s.split(" ").map { it.toInt(16).toByte() }.toByteArray()
    private fun hexOf(b: ByteArray) = b.joinToString(" ") { "%02X".format(it) }

    private val y25 = Ute.Features.parse(
        hex("08 88 6C 2A 01 24 39 43 75 6E DF FE D9 21 00 5D 78 5B A0 DC"),
        hex("00 F4 00 00 00 00 00 00 00 00 00 05 00 00 40 02 00 00 04 20"),
    )
    private val today = LocalDate.of(2026, 10, 19)

    @Test fun y25Bits() {
        with(UteControls) {
            assertTrue(y25.readLanguage())
            assertTrue(y25.shortcuts())
        }
        assertTrue(y25.syncTimestamp)
        assertTrue(UteContacts.clearSupported(y25))
    }

    @Test fun language() {
        assertEquals("AF AA", hexOf(UteControls.LANGUAGE_QUERY))
        val p = hex("AF AA 63 00 00 00 00 00 00 00 00 00 00 00 00 00 12 34 56 01")
        assertEquals(99, UteControls.parseLanguage(p))
        assertArrayEquals(intArrayOf(0x345601, 0x000012, 0, 0, 0), UteControls.parseLanguageMasks(p))
        assertEquals(2, UteControls.parseLanguage(hex("AF AA 02")))
        assertNull(UteControls.parseLanguageMasks(hex("AF AA 02")))
        assertNull(UteControls.parseLanguage(hex("AF AB 02")))
        // Ngôn ngữ đọc được hiện ở dòng mô tả, không đổi lựa chọn đã lưu.
        val c = UteControls.controls(y25, UteSettings(), today, UteReadState(language = 99)).first { it.id == "language" }
        assertEquals("Đồng hồ đang dùng: Tiếng Việt", c.detail)
        assertEquals(ControlValue.Number(0), c.value)
    }

    @Test fun shortcuts() {
        assertEquals("BE 01", hexOf(UteControls.SHORTCUT_SUPPORT))
        assertEquals("BE 02", hexOf(UteControls.SHORTCUT_STATUS))
        val support = UteControls.parseShortcuts(hex("BE 01 0A 20 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00"), 1)
        val status = UteControls.parseShortcuts(hex("BE 02 08 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00"), 2)
        assertEquals(0x0A2000, support)
        assertEquals(0x080000, status)
        assertNull(UteControls.parseShortcuts(hex("BE 01 0A"), 1)) // phải đúng 18 byte dữ liệu
        assertNull(UteControls.parseShortcuts(hex("BE 02 08 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00"), 1))
        val controls = UteControls.controls(y25, UteSettings(), today, UteReadState(shortcutSupport = support, shortcutStatus = status))
            .filter { it.id.startsWith("shortcut.") }
        // 0x002000 đặt giờ, 0x020000 nâng tay, 0x080000 DND; chỉ DND đang bật. Chỉ đọc (enabled = false).
        assertEquals(listOf("shortcut.8192", "shortcut.131072", "shortcut.524288"), controls.map { it.id })
        assertEquals(listOf(false, false, true), controls.map { (it.value as ControlValue.Bool).on })
        assertTrue(controls.none { it.enabled })
        assertTrue(UteControls.commands("shortcut.524288", y25, UteSettings()).isEmpty())
    }

    @Test fun windows() {
        val s = UteSettings()
            .with("spo2Range.enabled", ControlValue.Bool(true))
            .with("spo2Range.range", ControlValue.TimeRange(22 * 60 + 30, 6 * 60))
            .with("hr24Range.enabled", ControlValue.Bool(true))
            .with("raiseRange.enabled", ControlValue.Bool(true))
        assertEquals(listOf("34 04 01 16 1E 06 00"), UteControls.commands("spo2Range.enabled", y25, s).map(::hexOf))
        assertEquals(listOf("F7 0F 01 00 00 17 3B"), UteControls.commands("hr24Range.range", y25, s).map(::hexOf))
        assertEquals(listOf("69 AB 01 05 01 08 00 16 00"), UteControls.commands("raiseRange.enabled", y25, s).map(::hexOf))
        val ids = UteControls.controls(y25, UteSettings(), today).map { it.id }
        assertTrue(listOf("spo2Range.enabled", "spo2Range.range", "hr24Range.enabled", "hr24Range.range", "raiseRange.enabled").all { it in ids })
    }

    @Test fun dataActionsNeedConfirmation() {
        val controls = UteControls.controls(y25, UteSettings(), today).associateBy { it.id }
        assertNotNull(controls.getValue("data.reset").confirm)
        assertNotNull(controls.getValue("contacts.clear").confirm)
        assertNull(controls.getValue("find.start").confirm)
        val bare = UteControls.controls(Ute.Features(emptyMap(), null), UteSettings(), today).map { it.id }
        assertFalse("contacts.clear" in bare)
        assertEquals("AD", hexOf(Ute.FACTORY_RESET))
        assertEquals("37 BA", hexOf(UteContacts.CLEAR))
    }

    @Test fun watchFaceSlots() {
        assertEquals("26 09", hexOf(Ute.DIAL_SLOTS_ALL))
        assertEquals("26 05 00", hexOf(Ute.dialSlotsQuery()))
        assertEquals("26 08 02", hexOf(Ute.dialSlotDelete(2)))
        val slots = Ute.parseDialSlotPackets(
            listOf(hex("26 09 00 00 00 01 E2 40 01 FF FF FF FE"), hex("26 09 01 02 00 00 00 07"), hex("26 09 FD")),
        )
        assertEquals(listOf(WatchFaceSlot(0, 123456), WatchFaceSlot(1, 0xFFFFFFFEL), WatchFaceSlot(2, 7)), slots)
        // Gói seq 0 mới thì bắt đầu lại.
        assertEquals(listOf(WatchFaceSlot(5, 1)), Ute.parseDialSlotPackets(listOf(hex("26 09 00 00 00 00 00 09"), hex("26 09 00 05 00 00 00 01"))))
        // `26 05` một gói, phần lẻ < 5 byte bỏ.
        assertEquals(listOf(WatchFaceSlot(0, 9)), Ute.parseDialSlots(hex("26 05 00 00 00 00 09 01 02").copyOfRange(2, 9)))
        assertEquals(1, Ute.parseDialDelete(hex("26 08 02 05 01")))
        assertEquals(0, Ute.parseDialDelete(hex("26 08 02 05 00")))
        assertNull(Ute.parseDialDelete(hex("26 08 02")))
    }

    @Test fun deviceEvents() {
        assertEquals(DeviceEvent.SWITCH_SCREEN_BUTTON, Ute.parseDeviceEvent(hex("D1 01")))
        assertEquals(DeviceEvent.LONG_PRESS_BUTTON_2, Ute.parseDeviceEvent(hex("D1 04")))
        assertEquals(DeviceEvent.SOS_BUTTON, Ute.parseDeviceEvent(hex("D1 05")))
        assertEquals(DeviceEvent.LONG_PRESS_BUTTON_3, Ute.parseDeviceEvent(hex("D1 06")))
        // Nút nhạc / từ chối cuộc gọi / chụp ảnh không phải sự kiện lẻ.
        assertNull(Ute.parseDeviceEvent(hex("D1 02")))
        assertNull(Ute.parseDeviceEvent(hex("D1 07")))
        assertNull(Ute.parseDeviceEvent(hex("D1 03")))
    }

    @Test fun dataStatusInferredBits() {
        val st = Ute.DataStatus(hex("00 06 42"))
        assertEquals(setOf("steps", "heartRate", "sportHeartRate", "heartRate24h"), st.pending)
        assertTrue(Ute.DataStatus(ByteArray(0)).pending.isEmpty())
    }

    @Test fun timestampSync() {
        val since = LocalDate.of(2026, 10, 17)
        // F7 FA / 34 FA / C8 FA: 00:00 của ngày đầu; B2 FA: 00:00; B3 FA: 18:00 hôm trước.
        assertEquals("F7 FA 07 EA 0A 11 00 00", hexOf(Ute.SyncCommand.HEART_RATE_24H.request(since, y25)))
        assertEquals("34 FA 07 EA 0A 11 00 00", hexOf(Ute.SyncCommand.SPO2.request(since, y25)))
        assertEquals("C8 FA 07 EA 0A 11 00 00", hexOf(Ute.SyncCommand.BLOOD_PRESSURE.request(since, y25)))
        assertEquals("B3 FA 07 EA 0A 10 12 00", hexOf(Ute.SyncCommand.SLEEP_ROLL.request(since, y25)))
        // CyWee và `31 01` không có mốc; không có F4 0x2000 hoặc không mốc ⇒ lệnh cũ.
        assertEquals("EB 02 FA", hexOf(Ute.SyncCommand.STEPS_CYWEE.request(since, y25)))
        assertEquals("EC 01", hexOf(Ute.SyncCommand.SLEEP_CYWEE.request(since, y25)))
        assertEquals("F7 FA", hexOf(Ute.SyncCommand.HEART_RATE_24H.request(since, Ute.Features(emptyMap(), null))))
        assertEquals("F7 FA", hexOf(Ute.SyncCommand.HEART_RATE_24H.request(null, y25)))
        assertEquals("FD FA 07 EA 0A 11 00 00", hexOf(Ute.workoutSync(since, y25)))
        assertEquals("FD FA 00 00 00 00 00 00", hexOf(Ute.workoutSync(null, y25)))
    }
}
