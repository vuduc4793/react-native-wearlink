package com.smartwear.veepoo

import com.smartwear.core.Contact
import com.smartwear.core.ControlValue
import com.smartwear.core.MusicCommand
import com.smartwear.core.RemoteCameraEvent
import com.smartwear.core.WeatherCondition
import com.smartwear.core.WeatherDay
import com.smartwear.core.WeatherForecast
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDateTime
import java.time.ZoneOffset

class VeepooPhoneTest {

    private fun hex(s: String) = s.trim().split(Regex("\\s+")).map { it.toInt(16).toByte() }.toByteArray()
    private fun ByteArray.hex() = joinToString(" ") { "%02X".format(it) }
    private val ge54Switches = VeepooMessageSwitches(
        hex("AD 02 01 01 01 01 00 01 01 00 01 01 01 01 01 01 01 00 00 01"),
        hex("AD 02 01 01 01 01 00 01 00 00 00 00 00 00 00 00 00 00 00 10"),
    )

    @Test
    fun appTypeFallback() {
        assertEquals(23, VeepooPhone.typeFor("messenger", ge54Switches))
        assertEquals(17, VeepooPhone.typeFor("zalo", ge54Switches)) // GE54: Zalo không có trong AD ⇒ "khác"
        assertEquals(17, VeepooPhone.typeFor("unknown-app", ge54Switches))
        assertNull(VeepooPhone.typeFor("zalo", VeepooMessageSwitches(hex("AD 02 01 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00"), null)))
    }

    @Test
    fun appMessagePackets() {
        val p = VeepooPhone.appMessage(17, "Lan", "Chào bạn, hẹn 7 giờ", maxPackets = 20, contactMsgLength = 0)
        val content = "Lan:Chào bạn, hẹn 7 giờ".toByteArray()
        assertEquals((content.size + 13) / 14, p.size)
        assertEquals("C2 11 0E 03 01 02", p[0].copyOf(6).hex())
        assertEquals(content.size - 28, p[2][2].toInt())
        assertArrayEquals(content, p.flatMap { it.copyOfRange(6, 6 + it[2]).toList() }.toByteArray())
        // Giới hạn số gói.
        assertEquals(2, VeepooPhone.appMessage(9, "", "x".repeat(100), maxPackets = 2, contactMsgLength = 0).size)
        // Tiêu đề cắt 12 byte không vỡ ký tự UTF-8.
        assertEquals("Nguyễn Vă", String(VeepooPhone.utf8Prefix("Nguyễn Văn A", 12)))
        assertEquals("Nguyễn V", String(VeepooPhone.utf8Prefix("Nguyễn Văn A", 11)))
    }

    @Test
    fun smsAndCall() {
        val sms = VeepooPhone.sms("Mẹ", isName = true, text = "Về ăn cơm", maxPackets = 20, contactMsgLength = 4)
        assertEquals("C2 01 04 02 01 01", sms[0].copyOf(6).hex())
        assertEquals(2, sms[1][5].toInt())
        val call = VeepooPhone.incomingCall("0901234567", isName = false, contactMsgLength = 0)
        assertEquals("C2 00 0A 01 01 00 30 39 30 31 32 33 34 35 36 37 00 00 00 00", call.single().hex())
        assertEquals("C1 00 00 00", VeepooPhone.CALL_END.hex())
        assertTrue(VeepooPhone.isRejectCall(hex("C1 02 00 00")))
    }

    @Test
    fun musicAndEvents() {
        assertEquals(MusicCommand.NEXT, VeepooPhone.parseMusicCommand(hex("99 02 04 00")))
        assertEquals(MusicCommand.PLAY_PAUSE, VeepooPhone.parseMusicCommand(hex("99 02 01 00")))
        assertEquals(MusicCommand.VOLUME_DOWN, VeepooPhone.parseMusicCommand(hex("99 03 06 00")))
        assertEquals(MusicCommand.PREVIOUS, VeepooPhone.parseMusicCommand(hex("01 01 01 04")))
        val m = VeepooPhone.musicPackets(true, "Song", "Me", null, 60)
        assertEquals("99 01 01 02 F0 10 A1 04 53 6F 6E 67 A2 02 4D 65 A3 01 01 A4", m[0].hex())
        assertEquals(2, m.size)
        assertEquals("99 01 02 02 01 3C", m[1].copyOf(6).hex())
        assertEquals(RemoteCameraEvent.SHUTTER, VeepooPhone.parseCamera(hex("B6 01 02")))
        assertEquals(RemoteCameraEvent.OPENED, VeepooPhone.parseCamera(hex("B6 01 01 01")))
        assertEquals(RemoteCameraEvent.CLOSED, VeepooPhone.parseCamera(hex("B6 01 00")))
        assertTrue(VeepooPhone.isFindPhone(hex("B5 00 01")))
        assertFalse(VeepooPhone.isFindPhone(hex("B5 0A 01")))
        assertEquals(1, VeepooPhone.findDeviceStatus(hex("B5 0A 01")))
        assertTrue(VeepooPhone.isSos(hex("B7 01 01")))
    }

    @Test
    fun controlsGe54() {
        val r = VeepooControls.parseRemind(hex("E7 02 01 01 08 00 12 00 3C 01 01 01 00 00 00 00 00 00 00 00"))!!
        assertEquals(VeepooControls.Remind(1, 8 * 60, 18 * 60, 60, true), r)
        val d = VeepooControls.parseRemind(hex("E7 02 01 02 08 00 16 00 1E 01 01 01 00 00 00 00 00 00 00 00"))!!
        assertEquals(30, d.interval)
        assertEquals("E7 01 02 08 00 16 00 2D 00", VeepooControls.remindWrite(d.copy(interval = 45, on = false)).copyOf(9).hex())
        assertEquals(VeepooControls.HeartAlarm(100, 55, true), VeepooControls.parseHeartAlarm(hex("AC 64 37 01 02 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00")))
        assertEquals("AC 96 32 01", VeepooControls.heartAlarmWrite(VeepooControls.HeartAlarm(150, 50, true)).hex())
        assertEquals(Triple(0, 3, 2), VeepooControls.b8Change("unit.hour24", ControlValue.Bool(false)))
        assertEquals(Triple(1, 9, 1), VeepooControls.b8Change("auto.stress", ControlValue.Bool(true)))
        assertEquals("F4 0A 0A 00 01", VeepooControls.language(10).hex())
        val f = VeepooFeatures(listOf(
            "A7 01 00 02 02 02 01 00 06 14 01 02 00 00 00 01 00 06 03 01", "A7 00 03 04 00 03 00 00 03 00 05 01 00 01 02 0B 05 00 01 02",
            "A7 02 00 01 00 00 01 05 01 00 00 00 01 00 00 04 01 02 02 03", "A7 02 01 00 00 00 00 00 00 00 00 00 00 01 00 00 00 00 00 04",
            "A7 00 00 00 01 00 00 01 01 00 00 00 00 00 00 00 00 00 00 05",
        ).map(::hex).associateBy { it[19].toInt() })
        val b8 = VeepooCustomSettings(hex("B8 02 01 01 01 01 00 00 00 00 02 02 01 00 00 00 01 00 00 00"), hex("B8 02 00 00 01 01 00 01 00 01 01 01 01 01 00 00 00 00 00 01"))
        val ids = VeepooControls.controls(f, b8, mapOf(1 to r, 2 to d), VeepooControls.HeartAlarm(100, 55, true), null).map { it.id }
        assertTrue("auto.hr" in ids && "remind.drink.range" in ids && "hrAlarm.high" in ids && "unit.hour24" in ids)
        assertFalse("language" in ids) // vòng tay không màn
        assertFalse("auto.met" in ids) // B8 gói 1 byte 8 = 0
    }

    @Test
    fun workoutGe54() {
        val crc = VeepooData.parseWorkoutCrc(hex("D3 01 01 7B C3 F4 C0 2D AC 00 00 00 00 00 00 00 00 00 00 00"), 3)!!
        assertEquals(listOf(0xC37B, 0xC0F4, 0xAC2D), crc)
        val packets = javaClass.classLoader!!.getResource("ge54/d4_slot1.txt")!!.readText().lines().filter { it.isNotBlank() }.map(::hex)
        assertTrue(VeepooData.isWorkoutLast(packets.last()))
        val w = VeepooData.parseWorkout(packets, sportType = 5, zone = ZoneOffset.ofHours(7))!!
        assertEquals(0x6AD366B4L * 1000, w.start)
        assertEquals(0x6AD36C0BL * 1000, w.end)
        assertEquals(0x548, w.activeSeconds)
        assertEquals(0x0A98, w.steps)
        assertEquals(0x0909, w.distanceMeters)
        assertEquals(0x231A1 / 1000, w.calories)
        assertEquals(0x96, w.maxHeartRate)
        assertEquals(0x7A, w.avgHeartRate)
        assertEquals(0x53, w.minHeartRate)
        assertEquals("DA 01 03 00 01", VeepooData.workoutControl(3, 1).copyOf(5).hex())
    }

    @Test
    fun weatherAndContacts() {
        val f = WeatherForecast("Hà Nội", 30, 70, 5, listOf(WeatherDay(WeatherCondition.SUNNY, 33, 25), WeatherDay(WeatherCondition.LIGHT_RAIN, 30, -2)))
        val p = VeepooData.weatherPackets(f, LocalDateTime.of(2026, 10, 19, 19, 0), crc = 0x1234)
        val total = p.size
        assertEquals("C8 04 %02X 01 F0".format(total), p[0].copyOf(5).hex())
        val all = p.flatMap { it.copyOfRange(4, 20).toList() }.toByteArray()
        val len = (all[1].toInt() and 0xFF) or ((all[2].toInt() and 0xFF) shl 8)
        assertEquals("A1 02 34 12 A2", all.copyOfRange(3, 8).hex())
        assertTrue(len + 3 <= all.size)
        // Ngày 2: tối thiểu -2 °C ⇒ dấu 0, 2.
        assertTrue(all.hex().contains("C3 04 01 1E 00 02"))
        val c = VeepooData.contactPackets(1, Contact("Mẹ", "0901 234 567"))
        assertEquals("72 01 01 02 A0 18 00 A1 01 01 A2 04", c[0].copyOf(12).hex())
        assertEquals("72 04 05", VeepooData.contactDelete(5).copyOf(3).hex())
    }

    @Test
    fun watchFaceBuilders() {
        val info = VeepooWatchFace.parseInfo(hex("50 02 01 01 00 10 00 00 00 00 08 00 03 00 01 00 34 12 00 01"))!!
        assertEquals(0x1000L, info.address)
        assertEquals(0x080000L, info.maxBytes)
        assertEquals(0x1234, info.crc)
        assertEquals("50 01 01 00 10 00 00 08 00 00 00 03 00 CD AB 01", VeepooWatchFace.startUpdate(info, 8, 0xABCD).copyOf(16).hex())
        assertEquals("44 4F 4F 47 01 00 10 00 00 08 00 00 00", VeepooWatchFace.doogErase(0x1000, 8).hex())
        assertEquals(8, VeepooWatchFace.pad4(ByteArray(5)).size)
        assertEquals(0xFF.toByte(), VeepooWatchFace.pad4(ByteArray(5))[7])
    }
}
