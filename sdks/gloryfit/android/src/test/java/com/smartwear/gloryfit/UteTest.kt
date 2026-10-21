package com.smartwear.gloryfit

import com.smartwear.core.Capability
import com.smartwear.core.SleepStage
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.ZonedDateTime

/** Ví dụ hex lấy từ sdks/gloryfit/docs/01-protocol.md §7. */
class UteTest {
    private val zone = ZoneId.of("Asia/Ho_Chi_Minh")
    private fun hex(s: String) = s.split(" ").map { it.toInt(16).toByte() }.toByteArray()
    private fun at(y: Int, mo: Int, d: Int, h: Int, mi: Int) = ZonedDateTime.of(y, mo, d, h, mi, 0, 0, zone).toInstant().toEpochMilli()

    @Test
    fun commands() {
        assertArrayEquals(hex("A3 07 EA 0A 0D 10 1E 05"), Ute.setTime(LocalDateTime.of(2026, 10, 13, 16, 30, 5)))
        assertArrayEquals(hex("D5 01 64 66 76 0C"), Ute.pairingCode("1234"))
        assertArrayEquals(hex("33 02 00 BC 61 4E"), Ute.accountId(12_345_678))
        assertArrayEquals(hex("A9 00 AA 00 41 05 00 00 1F 40 01 FF 00 1E 01 00 02 01 00"), Ute.userInfo())
    }

    @Test
    fun featureGroups() {
        // 33F1: F7 (2 byte), F6, F5, F4, F3, F2, F1 (3 byte mỗi nhóm).
        val main = hex("00 00  00 00 20  00 00 48  00 00 00  00 00 00  00 40 00  18 00 01".replace("  ", " "))
        val ble5 = hex("00 F4  00 00 00  00 00 00  00 00 20  08 00 00  00 00 00  00 00 00".replace("  ", " "))
        val f = Ute.Features.parse(main, ble5)
        assertTrue(f.usesPairingCode)            // F1 0x000001
        assertTrue(f.usesAccountId)              // F10 0x080000
        assertTrue(f.heartRate24h)               // F2 0x004000
        assertEquals(244, f.maxPacketLength)
        assertEquals(
            setOf(Capability.STEPS, Capability.SLEEP, Capability.HEART_RATE, Capability.BLOOD_PRESSURE, Capability.SPO2, Capability.TEMPERATURE, Capability.STRESS, Capability.HRV),
            f.capabilities(),
        )
    }

    @Test
    fun setTimeWithTimeZone() {
        val t = LocalDateTime.of(2026, 10, 13, 16, 30, 5)
        assertArrayEquals(hex("A3 07 EA 0A 0D 10 1E 05 07"), Ute.setTime(t, tzHours = 7))
        assertArrayEquals(hex("A3 07 EA 0A 0D 10 1E 05 F9"), Ute.setTime(t, tzHours = -7))
        assertEquals(7, Ute.tzHours(zone, t))
        assertEquals(-3, Ute.tzHours(ZoneId.of("America/St_Johns"), LocalDateTime.of(2026, 1, 10, 12, 0))) // −3:30
    }

    @Test
    fun heartRate24hCommands() {
        assertArrayEquals(hex("F7 01"), Ute.HR24_ENABLE)
        assertArrayEquals(hex("F7 09 01 00 05"), Ute.heartRate24hInterval(5))
        assertArrayEquals(hex("F7 09 01 00 05"), Ute.heartRate24hInterval(1)) // nhỏ nhất 5 phút
        assertArrayEquals(hex("F7 09 01 00 3C"), Ute.heartRate24hInterval(60))
        assertArrayEquals(hex("E5 AA"), Ute.HR_STATUS)
        assertEquals(true, Ute.parseHeartRateStatus(hex("E5 AA 11")))
        assertEquals(false, Ute.parseHeartRateStatus(hex("E5 AA FF")))
        assertEquals(null, Ute.parseHeartRateStatus(hex("E5 11 00 4C")))
    }

    @Test
    fun heartRateByPushGate() {
        // Bảng thật (doc 01 §10, §11; 34F1 HT43 từ doc 08 §3.2): cả hai có isHas24HourHRM (33F1 byte 15 bit 6),
        // không có isHasHRMTimedMeasurement (34F1 byte 8 bit 7).
        val ble5 = hex("00 F4 00 00 00 00 00 00 00 00 00 05 00 00 40 00 00 00 04 00")
        val y25 = Ute.Features.parse(hex("08 88 6C 2A 01 24 39 43 75 6E DF FE D9 21 00 5D 78 5B A0 DC"), ble5)
        val ht43 = Ute.Features.parse(hex("08 88 6C 2A 01 24 39 43 75 6E DF FE D9 21 00 5D 78 4B A1 DC"), ble5)
        for (f in listOf(y25, ht43)) {
            assertTrue(f.heartRate24h)
            assertFalse(f.heartRateTimedMeasurement)
            assertTrue(f.heartRateByPush)
        }
        // Bỏ bit 6 của byte 15 ⇒ đường cũ D6 01 / E5 11.
        val no24h = Ute.Features.parse(hex("08 88 6C 2A 01 24 39 43 75 6E DF FE D9 21 00 1D 78 5B A0 DC"), ble5)
        assertFalse(no24h.heartRate24h)
        assertFalse(no24h.heartRateByPush)
        // Có isHasHRMTimedMeasurement ⇒ SDK iOS cho đo tay E5 11.
        val timed = Ute.Features.parse(
            hex("08 88 6C 2A 01 24 39 43 75 6E DF FE D9 21 00 5D 78 5B A0 DC"),
            hex("00 F4 00 00 00 00 00 00 80 00 00 05 00 00 40 00 00 00 04 00"),
        )
        assertTrue(timed.heartRateTimedMeasurement)
        assertFalse(timed.heartRateByPush)
        assertFalse(Ute.Features(emptyMap(), null).heartRateByPush)
    }

    @Test
    fun advertisedServices() {
        // doc 09 §1.2: 8 nhóm UUID app GloryFit iOS lọc trong quảng bá.
        for (v in listOf(0x55FF, 0x5533, 0x55F0, 0x5536, 0x5534, 0x553C, 0x5555, 0x5554, 0x4544, 0x4231, 0x424C, 0x4F4F, 0x3455)) {
            assertTrue("%04X".format(v), java.util.UUID.fromString("0000%04x-0000-1000-8000-00805f9b34fb".format(v)) in Ute.ADVERTISED)
        }
        assertEquals(13, Ute.ADVERTISED.size)
        assertFalse(java.util.UUID.fromString("0000fee7-0000-1000-8000-00805f9b34fb") in Ute.ADVERTISED)
    }

    @Test
    fun endOfStream() {
        assertTrue(Ute.isEnd(0xB2, hex("B2 FD")))
        assertFalse(Ute.isEnd(0xB2, hex("B2 07 EA 0A 0D 08 03 E8")))
        assertTrue(Ute.isEnd(0x34, hex("34 FA FD E7")))
        assertFalse(Ute.isEnd(0x34, hex("34 FA 07 EA 0A 0D 0F 00 62")))
    }

    @Test
    fun pushedHeartRateFromY25() {
        val r = Ute.parsePushedHeartRate(hex("F7 03 07 EA 0A 0D 11 05 57"), zone)!!
        assertEquals(87.0, r.value!!, 0.0)
        assertEquals(at(2026, 10, 13, 17, 5), r.timestamp)
    }

    @Test
    fun manualHeartRateF70B() {
        // `F7 0B YYYY MM DD hh mm bpm`: người dùng đo trên đồng hồ (doc 09 §2.2).
        val r = Ute.parsePushedHeartRate(hex("F7 0B 07 EA 0A 0F 09 2A 48"), zone)!!
        assertEquals(72.0, r.value!!, 0.0)
        assertEquals(at(2026, 10, 15, 9, 42), r.timestamp)
        assertEquals(null, Ute.parsePushedHeartRate(hex("F7 0B 07 EA 0A 0F 09 2A 00"), zone)) // 0 = không hợp lệ
        assertEquals(null, Ute.parsePushedHeartRate(hex("F7 04 07 EA 0A 0D 11 2A 53 53 53"), zone)) // max/min/avg
        assertEquals(null, Ute.parsePushedHeartRate(hex("F7 0B 07 EA"), zone))
    }

    @Test
    fun liveHeartRateFromWatch() {
        assertEquals(76.0, Ute.parseLiveHeartRate(hex("E5 11 00 4C"))!!.value!!, 0.0) // gói thật từ Y25
        assertEquals(null, Ute.parseLiveHeartRate(hex("E5 11 00 00")))
        assertEquals(null, Ute.parseLiveHeartRate(hex("E5 11")))
    }

    @Test
    fun stepsHourly() {
        val points = Ute.parseSteps(listOf(hex("B2 07 EA 0A 0D 08 03 E8"), hex("B2 FD")), zone)
        assertEquals(1, points.size)
        assertEquals(at(2026, 10, 13, 8, 0), points[0].timestamp)
        assertEquals(1000.0, points[0].value, 0.0)
    }

    @Test
    fun heartRateSingle() {
        val points = Ute.parseHeartRate(listOf(hex("E6 07 EA 0A 0D 0E 1E 48")), zone)
        assertEquals(at(2026, 10, 13, 14, 30), points[0].timestamp)
        assertEquals(72.0, points[0].value, 0.0)
    }

    @Test
    fun heartRate24hCells() {
        // HH = 15: ô byte 6 ở 15:00 − 110 phút = 13:10, ô byte 17 ở 15:00.
        val p = hex("F7 07 EA 0A 0D 0F 46 48 4A 00 00 00 00 00 00 00 00 50")
        val points = Ute.parseHeartRate24h(listOf(p), zone)
        assertEquals(listOf(70.0, 72.0, 74.0, 80.0), points.map { it.value })
        assertEquals(at(2026, 10, 13, 13, 10), points[0].timestamp)
        assertEquals(at(2026, 10, 13, 15, 0), points[3].timestamp)
    }

    @Test
    fun spo2Cells() {
        val p = hex("34 FA 07 EA 0A 0D 0F 00 62 63 61 62 FF FF FF FF FF FF FF FF")
        val points = Ute.parseSpo2(listOf(p, hex("34 FA FD E7")), zone)
        assertEquals(listOf(98.0, 99.0, 97.0, 98.0), points.map { it.value })
        assertEquals(at(2026, 10, 13, 13, 10), points[0].timestamp) // 15:00 − 11×10 phút
    }

    @Test
    fun sleepRollCounts() {
        val packets = listOf(
            hex("B3 07 EA 0A 0D 17 1E 00 05"), // 23:30 roll 5 → nông
            hex("B3 07 EA 0A 0E 01 00 00 02"), // 01:00 roll 2 → sâu
            hex("B3 07 EA 0A 0E 03 00 00 2A"), // 03:00 kết thúc (mốc cách nhau ≤ 2 giờ)
            hex("B3 FD 2F"),
        )
        val sessions = Ute.parseSleep(packets, zone)
        assertEquals(1, sessions.size)
        assertEquals(at(2026, 10, 13, 23, 30), sessions[0].start)
        assertEquals(at(2026, 10, 14, 3, 0), sessions[0].end)
        assertEquals(90, sessions[0].minutes(SleepStage.LIGHT))
        assertEquals(120, sessions[0].minutes(SleepStage.DEEP))
    }

    private fun wbytes(h: String) = h.split(" ").map { it.toInt(16).toByte() }.toByteArray()

    @Test fun parsesWorkout() {
        val zone = java.time.ZoneId.of("Asia/Ho_Chi_Minh")
        val packets = listOf(
            wbytes("FD FA 00 00 00 00 00 00 00 01"),
            // gói 0: chạy bộ, 15/10/2026 08:30:00, (epoch kết thúc), tập hiệu quả 1800 s
            wbytes("FD 00 00 01 00 05 07 EA 0A 0F 08 1E 00 00 00 00 00 00 07 08"),
            // gói 1: 3000 bước, 150 kcal, 2,50 km, HR 140/165/90, pace 6'30"
            wbytes("FD 00 01 00 0B B8 00 00 00 96 02 32 8C A5 5A 06 1E 00 00 00"),
            wbytes("FD 00 05 50 51 52 53 54 55 56 57 58 59 5A 5B 5C 5D 5E 5F 60"),
            wbytes("FD FD"),
        )
        val w = Ute.parseWorkouts(packets, zone, endIsTimestamp = true).single()
        assertEquals(1, w.type)
        assertEquals("Chạy bộ", w.name)
        assertEquals(java.time.LocalDateTime.of(2026, 10, 15, 8, 30).atZone(zone).toInstant().toEpochMilli(), w.start)
        assertEquals(1800, w.activeSeconds)
        assertEquals(w.start + 1_800_000, w.end)
        assertEquals(3000, w.steps)
        assertEquals(150, w.calories)
        assertEquals(2500, w.distanceMeters)
        assertEquals(140, w.avgHeartRate)
        assertEquals(165, w.maxHeartRate)
        assertEquals(390, w.paceSecondsPerKm)
        assertEquals(1, Ute.workoutCount(packets[0]))
    }

    @Test fun noWorkoutsWhenCountZero() {
        assertEquals(0, Ute.workoutCount(wbytes("FD FA 00 00 00 00 00 00 00 00")))
        assertEquals(emptyList<Any>(), Ute.parseWorkouts(listOf(wbytes("FD FA 00 00 00 00 00 00 00 00")), java.time.ZoneId.of("UTC"), true))
    }

    @Test
    fun heartRateStreamPackets() {
        // E5 11 00 rr giữa chừng / E5 00 00 rr kết quả ⇒ mẫu; rr = 0 (khởi động) ⇒ bỏ qua; st ≠ 0 ⇒ chưa đeo.
        assertEquals(72, Ute.parseHeartRateStream(hex("E5 11 00 48"))!!.bpm)
        val done = Ute.parseHeartRateStream(hex("E5 00 00 52"), timestamp = 9)!!
        assertEquals(82, done.bpm)
        assertEquals(true, done.contact)
        assertEquals(9L, done.timestamp)
        assertNull(Ute.parseHeartRateStream(hex("E5 11 00 00")))
        val off = Ute.parseHeartRateStream(hex("E5 00 01 00"))!!
        assertNull(off.bpm)
        assertEquals(false, off.contact)
        // F7 03 (đo định kỳ) / F7 0B (đo trên đồng hồ): byte 8 là nhịp tim.
        assertEquals(87, Ute.parseHeartRateStream(hex("F7 03 07 EA 0A 10 11 05 57"))!!.bpm)
        assertEquals(80, Ute.parseHeartRateStream(hex("F7 0B 07 EA 0A 10 11 05 50"))!!.bpm)
        assertNull(Ute.parseHeartRateStream(hex("E5 11")))
        assertNull(Ute.parseHeartRateStream(hex("A2 50")))
    }
}
