package com.smartwear.veepoo

import com.smartwear.core.Alarm
import com.smartwear.core.Capability
import com.smartwear.core.ControlValue
import com.smartwear.core.ReadingStatus
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneOffset

/** Thành phần máu / cơ thể, hiệu chuẩn, hồ sơ `A3`, báo thức `B9`, lệnh hệ thống. Gói thật GE54 19/10/2026 ghi rõ. */
class VeepooHealthTest {

    private fun hex(s: String) = s.trim().split(Regex("\\s+")).map { it.toInt(16).toByte() }.toByteArray()
    private fun ByteArray.hex() = joinToString(" ") { "%02X".format(it) }
    private fun pad(s: String, n: Int = 20) = hex(s).copyOf(n)

    private val ge54 = VeepooFeatures(listOf(
        "A7 01 00 02 02 02 01 00 06 14 01 02 00 00 00 01 00 06 03 01", "A7 00 03 04 00 03 00 00 03 00 05 01 00 01 02 0B 05 00 01 02",
        "A7 02 00 01 00 00 01 05 01 00 00 00 01 00 00 04 01 02 02 03", "A7 02 01 00 00 00 00 00 00 00 00 00 00 01 00 00 00 00 00 04",
        "A7 00 00 00 01 00 00 01 01 00 00 00 00 00 00 00 00 00 00 05",
    ).map(::hex).associateBy { it[19].toInt() })

    @Test
    fun featuresGe54() {
        val caps = ge54.capabilities()
        assertTrue(caps.containsAll(listOf(Capability.MET, Capability.URIC_ACID, Capability.BLOOD_LIPIDS, Capability.BODY_COMPOSITION, Capability.BLOOD_SUGAR)))
        assertTrue(ge54.glucoseCalibrationMulti)
        assertFalse(ge54.glucoseCalibrationSingle)
        assertTrue(ge54.bloodComponentCalibration)
        assertTrue(ge54.bodyComposition)
        assertTrue(ge54.textAlarm)
        assertFalse(ge54.metLive) // MET type 2: không đo tại chỗ
        assertEquals("Chạy ngoài trời", VeepooData.sportName(1)) // ESportType.OUTDOOR_RUNNING
        assertEquals("Leo núi", VeepooData.sportName(11))
        val met = VeepooMeasure.met()
        assertEquals(ReadingStatus.MEASURING, met(pad("89 08 01 00 32 0B"))!!.first.status)
        assertEquals(1.3, met(pad("89 08 01 00 64 0D"))!!.first.value!!, 1e-9)
        assertNull(met(pad("89 06 01 00 64 15")))
    }

    @Test
    fun bloodCalibrationGe54() {
        // Đọc thật: bật, uric 90,0 μmol/L, TCHO 15,00, TAG 12,00, HDL 10,00, LDL 15,00.
        val c = VeepooHealth.parseBloodCalibration(pad("8A 02 02 01 01 84 03 DC 05 B0 04 E8 03 DC 05"))!!
        assertTrue(c.enabled)
        assertEquals(VeepooHealth.BloodValues(900, 1500, 1200, 1000, 1500), c.values)
        assertEquals("8A 02 01 01 84 03 DC 05 B0 04 E8 03 DC 05 00 00 00 00 00 00", VeepooHealth.bloodCalibrationWrite(c).hex())
        assertEquals("8A 02 01 00 84 03", VeepooHealth.bloodCalibrationWrite(c.copy(enabled = false)).copyOf(6).hex())
        assertNull(VeepooHealth.parseBloodCalibration(pad("8A 02 02 00 01 84 03 DC 05 B0 04 E8 03 DC 05")))
        assertEquals("8A 01 01 01", VeepooHealth.bloodComponentStart(true).copyOf(4).hex())
        assertEquals(20, VeepooHealth.BLOOD_COMPONENT_STOP.size)
    }

    @Test
    fun bpCalibrationGe54() {
        // Đọc thật sau khi khôi phục: kết quả 1, 120/87, chế độ riêng, thao tác 2 (đọc).
        assertEquals(VeepooHealth.BpCalibration(true, 120, 87), VeepooHealth.parseBpCalibration(pad("91 01 78 57 01 02")))
        // Gói `91` thiếu byte bị vòng tay coi là "đặt thường 0/0" ⇒ phản hồi `91 01 00 00 00 00`.
        assertEquals(VeepooHealth.BpCalibration(false, 0, 0), VeepooHealth.parseBpCalibration(pad("91 01 00 00 00 00")))
        val w = VeepooHealth.bpCalibrationWrite(VeepooHealth.BpCalibration(true, 120, 87))
        assertEquals(20, w.size)
        assertEquals("91 01 78 57 00 00", w.copyOf(6).hex())
        assertEquals("91 02 00 00", VeepooHealth.BP_CALIBRATION_READ.hex())
    }

    @Test
    fun glucoseCalibrationGe54() {
        val p1 = hex("89 03 02 01 01 02 01 0F 00 8A 02 0F 01 EE 02 00 00 00 00 00")
        val p2 = hex("89 03 02 01 02 02 00 00 00 00 00 00 00 00 00 00 00 00 00 00")
        val g = VeepooHealth.parseGlucoseMulti(p1, p2)!!
        assertTrue(g.enabled)
        assertEquals(VeepooHealth.Meal(15 * 60, 650, 15 * 60 + 1, 750), g.meals[0])
        assertEquals(VeepooHealth.Meal(0, 0, 0, 0), g.meals[2])
        val w = VeepooHealth.glucoseMultiWrite(g)
        assertEquals("89 03 01 01 02 01 0F 00 8A 02 0F 01 EE 02 00 00 00 00 00 00", w[0].hex())
        assertEquals("89 03 01 02 02 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00", w[1].hex())
        assertEquals("89 02 01 8A 02 01", VeepooHealth.glucoseCalibrationWrite(650, true).copyOf(6).hex())
        assertEquals(VeepooHealth.GlucoseCalibration(true, value100 = 650), VeepooHealth.parseGlucoseCalibration(pad("89 02 02 01 8A 02 01")))
    }

    @Test
    fun calibrationControls() {
        val e = VeepooControls.Extra(
            bp = VeepooHealth.BpCalibration(true, 120, 87),
            glucose = VeepooHealth.GlucoseCalibration(true, meals = listOf(VeepooHealth.Meal(900, 650, 901, 750), VeepooHealth.Meal(0, 0, 0, 0), VeepooHealth.Meal(0, 0, 0, 0))),
            blood = VeepooHealth.BloodCalibration(true, VeepooHealth.BloodValues(900, 1500, 1200, 1000, 1500)),
        )
        val ids = VeepooControls.calibrationControls(ge54, e).map { it.id }
        assertTrue(listOf("calibrate.bp.enabled", "calibrate.bp.systolic", "calibrate.glucose.breakfastBefore", "calibrate.glucose.dinnerTime",
            "calibrate.bloodComponent.ldl", "calibrate.bloodComponent.uricAcid").all { it in ids })
        assertFalse("calibrate.glucose.value" in ids)
        val bp = VeepooControls.applyCalibration("calibrate.bp.systolic", ControlValue.Number(130), e)!!
        assertEquals("91 01 82 57 00", VeepooControls.calibrationPackets("calibrate.bp.systolic", ge54, bp)[0].copyOf(5).hex())
        val g = VeepooControls.applyCalibration("calibrate.glucose.lunchTime", ControlValue.TimeRange(12 * 60, 14 * 60), e)!!
        assertEquals(VeepooHealth.Meal(720, 0, 840, 0), g.glucose!!.meals[1])
        assertEquals(2, VeepooControls.calibrationPackets("calibrate.glucose.lunchTime", ge54, g).size)
        val b = VeepooControls.applyCalibration("calibrate.bloodComponent.hdl", ControlValue.Number(120), e)!!
        assertEquals(120, b.blood!!.values.hdl100)
        assertNull(VeepooControls.applyCalibration("auto.hr", ControlValue.Bool(true), e))
    }

    @Test
    fun liveGlucoseAndBlood() {
        val g = VeepooMeasure.bloodGlucose()
        assertEquals(ReadingStatus.MEASURING, g(pad("89 01 01 00 32 00 00"))!!.first.status)
        val (r, done) = g(pad("89 01 01 00 64 1A 03"))!!
        assertTrue(done)
        assertEquals(7.94, r.value!!, 1e-9)
        assertEquals(ReadingStatus.NOT_WORN, g(pad("89 01 01 04"))!!.first.status)
        assertNull(g(pad("89 06 01 00 64 15"))) // stress, không phải đường huyết

        val u = VeepooMeasure.bloodComponent(Capability.URIC_ACID)
        val m = u(pad("8A 01 01 00 20"))!!.first
        assertEquals(ReadingStatus.MEASURING, m.status)
        assertEquals(com.smartwear.core.Reading.NOTE_TOUCH_SENSOR, m.note)
        assertEquals(32.0, m.extra.getValue("progress"), 1e-9)
        val (ur, ud) = u(pad("8A 01 01 00 64 B0 04 F4 01 78 00 A0 00 2C 01"))!!
        assertTrue(ud)
        assertEquals(120.0, ur.value!!, 1e-9)
        assertEquals(mapOf("uricAcid" to 120.0, "totalCholesterol" to 5.0, "triglycerides" to 1.2, "hdl" to 1.6, "ldl" to 3.0), ur.extra)
        val (lr, _) = VeepooMeasure.bloodComponent(Capability.BLOOD_LIPIDS)(pad("8A 01 01 00 64 B0 04 F4 01 78 00 A0 00 2C 01"))!!
        assertEquals(5.0, lr.value!!, 1e-9)
        assertEquals(ReadingStatus.ERROR, u(pad("8A 01 01 03 00"))!!.first.status)
        assertEquals(ReadingStatus.ERROR, u(pad("8A 01 01 01 00"))!!.first.status) // đang đo việc khác = bận
        assertEquals(ReadingStatus.ERROR, u(pad("8A 01 02 00"))!!.first.status)
        // Trạng thái 4 (EBloodComponentDetectState.WEAR_ERROR) ⇒ chưa chạm/đeo: NOT_WORN + nhắc chạm cảm biến.
        u(pad("8A 01 01 04"))!!.let { (r, done) ->
            assertTrue(done); assertEquals(ReadingStatus.NOT_WORN, r.status); assertEquals("TOUCH_SENSOR", r.note)
        }
        // Tiến độ 100 mà toàn 0 ⇒ lỗi, không phải OK.
        u(pad("8A 01 01 00 64"))!!.let { (r, done) -> assertTrue(done); assertEquals(ReadingStatus.ERROR, r.status); assertEquals("TOUCH_SENSOR", r.note) }
        assertNull(u(pad("8A 02 02 01"))) // gói hiệu chuẩn
    }

    /** GE54 thật 19/10/2026 21:26, chế độ thường `8A 01 01 00`: 19 gói, tiến độ 0→100, kết quả ở gói cuối. */
    @Test
    fun bloodComponentGe54Capture() {
        val packets = javaClass.classLoader!!.getResource("ge54/8a_blood_general.txt")!!.readText().lines().filter { it.isNotBlank() }.map(::hex)
        assertEquals(19, packets.size)
        val parse = VeepooMeasure.bloodComponent(Capability.BLOOD_LIPIDS)
        val out = packets.map { parse(it)!! }
        out.dropLast(1).forEach { (r, done) ->
            assertEquals(ReadingStatus.MEASURING, r.status); assertEquals("TOUCH_SENSOR", r.note); assertNull(r.value); assertTrue(!done)
        }
        assertEquals(listOf(0.0, 6.0, 6.0, 12.0), out.take(4).map { it.first.extra.getValue("progress") })
        val (r, done) = out.last()
        assertTrue(done)
        assertEquals(ReadingStatus.OK, r.status)
        assertEquals(4.27, r.value!!, 1e-9)
        assertEquals(mapOf("uricAcid" to 215.3, "totalCholesterol" to 4.27, "triglycerides" to 1.02, "hdl" to 1.04, "ldl" to 2.68), r.extra)
        assertEquals(215.3, VeepooMeasure.bloodComponent(Capability.URIC_ACID)(packets.last())!!.first.value!!, 1e-9)
        // Chế độ riêng (`8A 01 01 01`, hiệu chuẩn 15/12/10/15 đang lưu): kết quả bám hiệu chuẩn — driver không dùng nữa.
        val priv = parse(pad("8A 01 01 00 64 CE 05 16 06 CA 04 EB 03 49 06"))!!.first
        assertEquals(15.58, priv.value!!, 1e-9)
        assertEquals("8A 01 01 00", VeepooHealth.bloodComponentStart(false).copyOf(4).hex())
    }

    @Test
    fun bodyComposition() {
        // 14 giá trị ÷10: BMI 22,5; mỡ 18,0 %; … ; BMR 1650.
        val values = intArrayOf(225, 180, 117, 533, 750, 488, 120, 600, 390, 450, 28, 170, 110, 16500)
        val body = byteArrayOf(0xA0.toByte(), 28) + values.flatMap { listOf((it and 0xFF).toByte(), (it shr 8).toByte()) }
        val chunks = body.toList().chunked(14).map { it.toByteArray() }
        val packets = chunks.mapIndexed { i, c -> byteArrayOf(0x93.toByte(), 4, 1, 1, (i + 1).toByte(), chunks.size.toByte()) + c.copyOf(14) }
        val parse = VeepooMeasure.bodyComposition()
        assertEquals(ReadingStatus.MEASURING, parse(pad("93 04 01 00 32 00"))!!.first.status)
        var last: Pair<com.smartwear.core.Reading, Boolean>? = null
        packets.forEach { last = parse(it) }
        val (r, done) = last!!
        assertTrue(done)
        assertEquals(18.0, r.value!!, 1e-9)
        assertEquals(22.5, r.extra.getValue("bmi"), 1e-9)
        assertEquals(1650.0, r.extra.getValue("basalMetabolicRate"), 1e-9)
        assertEquals(14, r.extra.size)
        assertEquals("93 04 01", VeepooHealth.BODY_START.copyOf(3).hex())
        assertEquals(ReadingStatus.ERROR, parse(pad("93 04 01 04"))!!.first.status)
        // Byte 5 = 1: chưa chạm điện cực (GE54 19/10: `93 04 01 00 xx 01`) ⇒ nhắc chạm; 4 gói liền ⇒ NOT_WORN, dừng (như G Band).
        val lead = VeepooMeasure.bodyComposition()
        assertNull(lead(pad("93 04 01 00 0A 00"))!!.first.note)
        repeat(3) {
            val (r, done) = lead(pad("93 04 01 00 10 01"))!!
            assertTrue(!done); assertEquals(ReadingStatus.MEASURING, r.status); assertEquals("TOUCH_SENSOR", r.note)
            assertEquals(16.0, r.extra.getValue("progress"), 1e-9)
        }
        lead(pad("93 04 01 00 16 01"))!!.let { (r, done) -> assertTrue(done); assertEquals(ReadingStatus.NOT_WORN, r.status); assertEquals("TOUCH_SENSOR", r.note) }
        // Chạm lại giữa chừng ⇒ đếm lại từ 0.
        val again = VeepooMeasure.bodyComposition()
        repeat(3) { again(pad("93 04 01 00 10 01")) }
        assertEquals(ReadingStatus.MEASURING, again(pad("93 04 01 00 12 00"))!!.first.status)
        assertTrue(!again(pad("93 04 01 00 14 01"))!!.second)
    }

    @Test
    fun dfBloodMetHrv() {
        // Tag C2: TCHO, TAG, HDL, LDL, uric (LE16).
        val v = VeepooHealth.BloodValues.parseDf(hex("F4 01 78 00 A0 00 2C 01 B0 04"))!!
        assertEquals(VeepooHealth.BloodValues(1200, 500, 120, 160, 300), v)
        assertNull(VeepooHealth.BloodValues.parseDf(ByteArray(10)))
        val rr = List(50) { if (it < 10) 80 + it else 0 }
        val rec = VeepooHistory.FiveMinute(LocalDateTime.of(2026, 10, 19, 8, 0), met = 1.3, hrv = listOf(59, 0, 0, 0, 0), rr = rr, blood = v)
        val s = VeepooHistory.toSeries(listOf(rec), ZoneOffset.UTC)
        assertEquals(1.3, s.getValue(Capability.MET).single().value, 1e-9)
        assertEquals(120.0, s.getValue(Capability.URIC_ACID).single().value, 1e-9)
        val lip = s.getValue(Capability.BLOOD_LIPIDS).single()
        assertEquals(5.0, lip.value, 1e-9)
        assertEquals(setOf("totalCholesterol", "triglycerides", "hdl", "ldl"), lip.extra.keys)
        val hrv = s.getValue(Capability.HRV).single()
        assertEquals(10, hrv.extra.size)
        assertEquals(800.0, hrv.extra.getValue("rr0"), 1e-9)
    }

    @Test
    fun reminders() {
        assertEquals(8, VeepooControls.remindTypeOf("remind.handWash.enabled"))
        assertEquals(3, VeepooControls.remindTypeOf("remind.longView.range"))
        assertEquals(1, VeepooControls.remindTypeOf("sedentary.range"))
        assertEquals(2, VeepooControls.remindTypeOf("drink.interval"))
        assertNull(VeepooControls.remindTypeOf("hrAlarm.high"))
        // Đọc thật GE54: nhìn xa 09:00–18:00 / 30 phút / bật; tập thể dục 120 phút.
        val r3 = VeepooControls.parseRemind(pad("E7 02 01 03 09 00 12 00 1E 01 01 01"))!!
        assertEquals(VeepooControls.Remind(3, 9 * 60, 18 * 60, 30, true), r3)
        assertEquals(120, VeepooControls.parseRemind(pad("E7 02 01 04 09 00 12 00 78 01 01 01"))!!.interval)
        assertEquals("E7 01 08 09 00 12 00 3C 00", VeepooControls.remindWrite(VeepooControls.Remind(8, 540, 1080, 60, false)).copyOf(9).hex())
        val b8 = VeepooCustomSettings(hex("B8 02 01 01 01 01 00 00 00 00 02 02 01 00 00 00 01 00 00 00"), hex("B8 02 00 00 01 01 00 01 00 01 01 01 01 01 00 00 00 00 00 01"))
        val ids = VeepooControls.controls(ge54, b8, (1..8).associateWith { VeepooControls.Remind(it, 540, 1080, 60, true) }, null, null,
            VeepooControls.Extra(profile = VeepooHealth.Profile())).map { it.id }
        for (k in listOf("sedentary", "drink", "longView", "exercise", "medication", "book", "travel", "handWash")) {
            assertTrue("remind.$k.enabled" in ids && "remind.$k.interval" in ids && "remind.$k.range" in ids)
        }
        assertTrue(listOf("profile.height", "profile.gender", "goal.steps", "goal.sleep", "device.powerOff", "data.reset").all { it in ids })
    }

    @Test
    fun profileAndSystem() {
        assertEquals("A3 AA 41 1E 01 1F 40 01 E0 00", VeepooHealth.profile(VeepooHealth.Profile()).copyOf(10).hex())
        assertEquals("A3 9B 32 28 00 27 10 01 A4", VeepooHealth.profile(VeepooHealth.Profile(155, 50, 40, true, 10000, 420)).copyOf(9).hex())
        assertEquals(VeepooHealth.Profile(stepGoal = 12000), VeepooControls.applyProfile("goal.steps", ControlValue.Number(12000), VeepooHealth.Profile()))
        assertEquals(VeepooHealth.Profile(sleepMinutes = 420), VeepooControls.applyProfile("goal.sleep", ControlValue.Number(7), VeepooHealth.Profile()))
        assertEquals("F2 04 " + List(18) { "00" }.joinToString(" "), VeepooHealth.POWER_OFF.hex())
        assertEquals("FF 55 01 73 40 " + List(15) { "00" }.joinToString(" "), VeepooHealth.FACTORY_RESET.hex())
        val confirm = VeepooControls.controls(ge54, VeepooCustomSettings(null, null), emptyMap(), null, null).filter { it.group == VeepooControls.SYSTEM }
        assertTrue(confirm.all { it.confirm != null })
    }

    @Test
    fun alarmsGe54() {
        // Đọc thật: một báo thức id 1, 13:44, tắt, không lặp, ngày thô 30 00 00, nhãn rỗng, CRC 3C31.
        val read = hex("B9 03 01 01 A0 03 01 31 3C A1 0C B1 08 01 00 00 0D 2C 30 00 00 B2 00")
        assertTrue(VeepooAlarms.isLast(read))
        assertEquals(1 to 0x3C31, VeepooAlarms.parseStatus(read))
        val list = VeepooAlarms.parseList(listOf(read))
        assertEquals(listOf(VeepooAlarms.TextAlarm(1, false, 0, 13, 44, 0x30, 0, 0, "")), list)
        assertEquals(0x3C31, VeepooAlarms.crc(list))
        assertEquals(Alarm(1, 13, 44, 0, false, null), list[0].toAlarm())
        assertEquals("A1 0C B1 08 01 00 00 0D 2C 30 00 00 B2 00", VeepooAlarms.entry(list[0]).hex())
        assertEquals(0, VeepooAlarms.crc(emptyList()))
        assertEquals("B9 03 00 00 A0 02 00 00", VeepooAlarms.readRequest().copyOf(8).hex())

        // Thêm báo thức 07:30 T2–T6 "Test": id 2, một gói (MTU 244), CRC của cả danh sách mới.
        val now = LocalDateTime.of(2026, 10, 19, 20, 0)
        val add = VeepooAlarms.fromAlarm(Alarm(-1, 7, 30, 0b0011111, true, "Test"), VeepooAlarms.freeId(list)!!, now)
        assertEquals(VeepooAlarms.TextAlarm(2, true, 0x1F, 7, 30, label = "Test"), add)
        val after = list + add
        val crc = VeepooAlarms.crc(after)
        val p = VeepooAlarms.writePackets(2, add, crc, 244)
        assertEquals(1, p.size)
        assertEquals("B9 02 01 01 A0 02 %02X %02X A1 10 B1 08 02 01 1F 07 1E 00 00 00 B2 04 54 65 73 74".format(crc and 0xFF, crc shr 8), p[0].hex())
        // MTU 20: cắt thành gói 20 byte `B9 op total idx` + 16 byte.
        val small = VeepooAlarms.writePackets(2, add, crc, 20)
        assertEquals(2, small.size)
        assertEquals("B9 02 02 01 A0 02", small[0].copyOf(6).hex())
        assertEquals("B9 02 02 02", small[1].copyOf(4).hex())
        // Xoá: op 1 + TLV báo thức bị xoá, CRC danh sách còn lại (= CRC ban đầu).
        assertEquals("B9 01 01 01 A0 02 31 3C A1 10", VeepooAlarms.writePackets(1, add, VeepooAlarms.crc(list), 244)[0].copyOf(10).hex())
        // Một lần: ngày báo hôm nay nếu giờ chưa qua, không thì ngày mai.
        val once = VeepooAlarms.fromAlarm(Alarm(-1, 6, 0, 0, true), 3, now)
        assertEquals(Triple(26, 10, 20), Triple(once.year, once.month, once.day))
        assertEquals(LocalDate.of(2026, 10, 19).dayOfMonth, VeepooAlarms.fromAlarm(Alarm(-1, 21, 0, 0, true), 3, now).day)
        // Nhãn tiếng Việt cắt theo byte UTF-8 (≤ 30).
        assertTrue(VeepooAlarms.labelBytes("Uống thuốc huyết áp buổi sáng nhé").size <= 30)
        assertNull(VeepooAlarms.freeId((1..10).map { VeepooAlarms.TextAlarm(it, true, 0, 0, 0) }))
    }
}
