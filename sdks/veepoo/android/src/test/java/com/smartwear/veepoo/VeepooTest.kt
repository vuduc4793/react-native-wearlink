package com.smartwear.veepoo

import com.smartwear.core.Capability
import com.smartwear.core.ReadingStatus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDateTime
import java.time.ZoneOffset

/** Gói thật của GE54 (19/10/2026, Redmi Note 7 Pro) và gói dựng từ mã G Band. */
class VeepooTest {

    private fun hex(s: String) = s.trim().split(Regex("\\s+")).map { it.toInt(16).toByte() }.toByteArray()

    @Test
    fun advertGe54() {
        val a = Veepoo.parseAdvert(Veepoo.COMPANY_VEEPOO, hex("45 1D E3 8F F4 9C A1 00 95 01 00 5C 17 53 FF 2F 00 30 10"))
        assertEquals("9C:F4:8F:E3:1D:45", a.mac)
        assertEquals(161, a.advertNumber)
        assertEquals(5980, a.deviceNumber)
        assertEquals("95.01", a.firmware)
    }

    @Test
    fun cleanName() {
        assertEquals("GE54", Veepoo.cleanName("GE54��"))
        assertEquals("GE54", Veepoo.cleanName("GE54\u0000\u0001"))
        assertEquals("", Veepoo.cleanName(null))
    }

    @Test
    fun passwordCheckMatchesCapture() {
        // Gói app gửi lúc 18:41:51 GMT+7, 24h.
        val p = Veepoo.passwordCheck("0000", LocalDateTime.of(2026, 10, 19, 18, 41, 51), is24h = true, zone = ZoneOffset.ofHours(7))
        assertEquals("A1 00 00 00 07 EA 0A 13 12 29 33 01 01 1C 00 00 00 00 00 00", p.joinToString(" ") { "%02X".format(it) })
        // Mật khẩu thập phân gửi LE16, múi giờ âm theo 15 phút.
        val q = Veepoo.passwordCheck("1234", LocalDateTime.of(2026, 1, 2, 3, 4, 5), is24h = false, zone = ZoneOffset.ofHoursMinutes(-3, -30))
        assertEquals(0xD2.toByte(), q[1]); assertEquals(0x04.toByte(), q[2])
        assertEquals((-14).toByte(), q[13])
    }

    @Test
    fun passwordReplyGe54() {
        val r = Veepoo.parsePasswordReply(hex("A1 00 00 06 17 5C 00 95 01 00 00 01 45 1D E3 8F F4 9C 00 00"))!!
        assertEquals(Veepoo.PasswordStatus.CHECK_AND_TIME_SUCCESS, r.status)
        assertTrue(Veepoo.passwordAccepted(r))
        assertEquals(5980, r.deviceNumber)
        assertEquals("00.95.01", r.firmware)
        assertEquals("00.95.01.00", r.testVersion)
        assertEquals("9C:F4:8F:E3:1D:45", r.mac)
        assertEquals(1, r.nightWrist)
        assertEquals(0, r.findPhone)
        assertFalse(Veepoo.passwordAccepted(Veepoo.parsePasswordReply(hex("A1 00 00 00 17 5C 00 95 01 00 00 01 45 1D E3 8F F4 9C 00 00"))!!))
        assertNull(Veepoo.parsePasswordReply(hex("A1 00 00 06")))
    }

    @Test
    fun batteryGe54() {
        val charging = Veepoo.parseBattery(hex("A0 01 00 00 55 01 55 01 00 00 00 00 00 00 00 00 00 00 00 00"))!!
        assertEquals(85, charging.percent)
        assertTrue(charging.charging)
        val unplugged = Veepoo.parseBattery(hex("A0 00 00 00 56 01 56 01 00 00 00 00 00 00 00 00 00 00 00 00"))!!
        assertEquals(86, unplugged.percent)
        assertFalse(unplugged.charging)
        // Không có phần trăm: quy vạch × 25.
        assertEquals(75, Veepoo.parseBattery(hex("A0 00 00 00 03 00 00 01"))!!.percent)
        assertNull(Veepoo.parseBattery(hex("A0 00 00 00 00 01 50 01")))
    }

    @Test
    fun setTimeAndCrc() {
        assertEquals("A5 07 EA 0A 13 12 29 33 02", Veepoo.setTime(LocalDateTime.of(2026, 10, 19, 18, 41, 51), true).joinToString(" ") { "%02X".format(it) })
        // CRC-16/MODBUS của "123456789" = 0x4B37.
        assertEquals(0x4B37, Veepoo.crc16("123456789".toByteArray()))
    }

    private val ge54Pages = listOf(
        "A7 01 00 02 02 02 01 00 06 14 01 02 00 00 00 01 00 06 03 01",
        "A7 00 03 04 00 03 00 00 03 00 05 01 00 01 02 0B 05 00 01 02",
        "A7 02 00 01 00 00 01 05 01 00 00 00 01 00 00 04 01 02 02 03",
        "A7 02 01 00 00 00 00 00 00 00 00 00 00 01 00 00 00 00 00 04",
        "A7 00 00 00 01 00 00 01 01 00 00 00 00 00 00 00 00 00 00 05",
    )

    @Test
    fun featuresGe54() {
        val f = VeepooFeatures(ge54Pages.map(::hex).associateBy { it[19].toInt() })
        assertTrue(f.complete)
        assertTrue(f.bloodPressure)
        assertTrue(f.healthRemind)
        assertFalse(f.longSeat)
        assertTrue(f.camera)
        assertEquals(6, f.spo2Type)
        assertTrue(f.spo2)
        assertEquals(20, f.messagePackets)
        assertEquals(2, f.wristTurnType)
        assertFalse(f.brightness)
        assertEquals(6, f.alarmType)
        assertTrue(f.textAlarm)
        assertTrue(f.heartRate)
        assertEquals(3, f.watchDays)
        assertEquals(4, f.contactMsgLength)
        assertEquals(3, f.sportModelSlots)
        assertEquals(0, f.screenStyleCount)
        assertFalse(f.weather)
        assertEquals(5, f.originProtocolVersion)
        assertTrue(f.usesDf)
        assertEquals(1, f.sleepTag)
        assertTrue(f.preciseSleep)
        assertEquals(2, f.bigDataTranType)
        assertEquals(0, f.watchUiServerCount)
        assertFalse(f.contacts)
        assertEquals(1, f.musicType)
        assertEquals(5, f.temperatureType)
        assertTrue(f.findDeviceByPhone)
        assertEquals(1, f.cpuType)
        assertTrue(f.stress)
        assertTrue(f.met)
        assertTrue(f.sportControl)
        assertEquals(1, f.screenShape)
        assertFalse(f.nativeWatchFace)
        assertTrue(Capability.SLEEP in f.capabilities())
        assertFalse(Capability.MENSTRUATION in f.capabilities())
    }

    @Test
    fun messageSwitchesGe54() {
        val m = VeepooMessageSwitches(
            hex("AD 02 01 01 01 01 00 01 01 00 01 01 01 01 01 01 01 00 00 01"),
            hex("AD 02 01 01 01 01 00 01 00 00 00 00 00 00 00 00 00 00 00 10"),
        )
        assertEquals(1, m.status(0)) // điện thoại
        assertEquals(1, m.status(1)) // SMS
        assertEquals(0, m.status(4)) // Sina
        assertEquals(1, m.status(17)) // khác
        assertEquals(1, m.status(23)) // Messenger
        assertEquals(0, m.status(24)) // Zalo: không hỗ trợ ⇒ gửi dạng "khác"
        val w = m.writePackets { it != 9 } // tắt WhatsApp
        assertEquals(2, w.size)
        assertEquals("AD 01 01 01 01 01 00 01 01 00 01 02 01 01 01 01 01 00 00 01", w[0].joinToString(" ") { "%02X".format(it) })
        assertEquals("AD 01 01 01 01 01 00 01 00 00 00 00 00 00 00 00 00 00 00 10", w[1].joinToString(" ") { "%02X".format(it) })
    }

    @Test
    fun customSettingsGe54() {
        val c = VeepooCustomSettings(
            hex("B8 02 01 01 01 01 00 00 00 00 02 02 01 00 00 00 01 00 00 00"),
            hex("B8 02 00 00 01 01 00 01 00 01 01 01 01 01 00 00 00 00 00 01"),
        )
        assertTrue(c.metric)
        assertTrue(c.is24h)
        assertTrue(c.on(0, VeepooCustomSettings.AUTO_HR))
        assertEquals(2, c.get(0, VeepooCustomSettings.SPO2_LOW))
        assertTrue(c.on(1, VeepooCustomSettings.AUTO_TEMPERATURE))
        assertTrue(c.on(1, VeepooCustomSettings.AUTO_STRESS))
        // Ghi 12h: chỉ đổi byte 3 + byte 1 = 01 (ghi).
        assertEquals("B8 01 01 02 01 01 00 00 00 00 02 02 01 00 00 00 01 00 00 00",
            c.write(0, VeepooCustomSettings.HOUR, 2)!!.joinToString(" ") { "%02X".format(it) })
        assertEquals("B8 01 00 00 01 01 00 01 00 01 01 01 01 01 00 00 00 00 00 01",
            c.write(1, VeepooCustomSettings.AUTO_STRESS, 1)!!.joinToString(" ") { "%02X".format(it) })
        assertFalse(c.with(0, VeepooCustomSettings.HOUR, 2).is24h)
    }

    @Test
    fun measureHeartRate() {
        val parse = VeepooMeasure.heartRate(samples = 2)
        assertEquals(ReadingStatus.MEASURING, parse(hex("D0 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00"))!!.first.status)
        val first = parse(hex("D0 4D 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00"))!!
        assertEquals(ReadingStatus.MEASURING, first.first.status)
        assertFalse(first.second)
        val done = parse(hex("D0 4C 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00"))!!
        assertEquals(ReadingStatus.OK, done.first.status)
        assertEquals(76.0, done.first.value!!, 0.0)
        assertTrue(done.second)
        assertEquals(ReadingStatus.NOT_WORN, VeepooMeasure.heartRate()(hex("D0 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00"))!!.first.status)
        // Đang sạc (GE54): D0 01 00 00 FD.
        val charging = VeepooMeasure.heartRate()(hex("D0 01 00 00 FD 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00"))!!
        assertEquals(ReadingStatus.ERROR, charging.first.status)
        assertEquals(0xFD, charging.first.errorCode)
    }

    @Test
    fun measureSpo2() {
        val parse = VeepooMeasure.spo2(samples = 3)
        assertEquals(ReadingStatus.MEASURING, parse(hex("80 01 00 00 00 64 00 00 00 00 00 00 00 00 00 00 00 00 00 00"))!!.first.status)
        repeat(2) { assertFalse(parse(hex("80 01 00 63 00 64 00 00 00 00 00 00 00 00 00 00 00 00 00 00"))!!.second) }
        val r = parse(hex("80 01 00 63 00 64 00 00 00 00 00 00 00 00 00 00 00 00 00 00"))!!
        assertEquals(ReadingStatus.OK, r.first.status)
        assertEquals(99.0, r.first.value!!, 0.0)
        assertEquals(ReadingStatus.NOT_WORN, VeepooMeasure.spo2()(hex("80 01 0C 00 00 00"))!!.first.status)
    }

    @Test
    fun measureBloodPressure() {
        val parse = VeepooMeasure.bloodPressure()
        assertEquals(ReadingStatus.MEASURING, parse(hex("90 00 00 28 00 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00"))!!.first.status)
        val r = parse(hex("90 77 56 64 00 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00"))!!
        assertEquals(ReadingStatus.OK, r.first.status)
        assertEquals(119, r.first.systolic)
        assertEquals(86, r.first.diastolic)
        assertTrue(r.second)
        val charging = parse(hex("90 00 00 00 FD 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00"))!!
        assertEquals(253, charging.first.errorCode)
    }

    @Test
    fun measureTemperatureGe54() {
        val parse = VeepooMeasure.temperature()
        assertEquals(ReadingStatus.MEASURING, parse(hex("87 01 01 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00"))!!.first.status)
        // Trạng thái máy 7 = vẫn đang đo (không phải lỗi); 0x0172 = 37,0 °C, nền 0x0169 = 36,1 °C.
        val p = hex("87 01 01 07 00 72 01 69 01 00 00 00 00 00 00 00 00 00 00 00")
        val mid = parse(p)!!
        assertEquals(ReadingStatus.MEASURING, mid.first.status)
        assertFalse(mid.second)
        assertEquals(37.0, mid.first.value!!, 0.001)
        assertEquals(36.1, VeepooMeasure.temperatureBase(p)!!, 0.001)
        val done = parse(hex("87 01 01 07 64 72 01 69 01 00 00 00 00 00 00 00 00 00 00 00"))!!
        assertEquals(ReadingStatus.OK, done.first.status)
        assertTrue(done.second)
        assertEquals(ReadingStatus.ERROR, parse(hex("87 01 01 08 00 00 00 00 00"))!!.first.status)
        assertTrue(parse(hex("87 01 02 00 00 00 00 00 00"))!!.second)
    }

    @Test
    fun measureStressGe54() {
        val parse = VeepooMeasure.stress()
        assertEquals(ReadingStatus.MEASURING, parse(hex("89 06 01 00 30 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00"))!!.first.status)
        val r = parse(hex("89 06 01 00 64 15 00 00 00 00 00 00 00 00 00 00 00 00 00 00"))!!
        assertEquals(ReadingStatus.OK, r.first.status)
        assertEquals(21.0, r.first.value!!, 0.0)
        assertEquals(ReadingStatus.NOT_WORN, parse(hex("89 06 01 04 00 00"))!!.first.status)
        assertNotNull(parse(hex("89 06 02 00 00 00")))
    }
}
