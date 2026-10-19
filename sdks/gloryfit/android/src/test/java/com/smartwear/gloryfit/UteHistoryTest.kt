package com.smartwear.gloryfit

import com.smartwear.core.ActivityTotals
import com.smartwear.core.SleepStage
import com.smartwear.gloryfit.Ute.SyncCommand
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.ZoneId
import java.time.ZonedDateTime

/**
 * Lịch sử UTE: port `UteHistoryTests.swift` (định dạng `EB 02`, `31/32`, `EC`, `C8` và chọn lệnh theo bit,
 * docs/feature-matrix.md việc 9). Gói `31/32`, `EC` dựng theo mã giải; `EB 01`/`EB 02` là gói thật Y25.
 */
class UteHistoryTest {
    private val zone = ZoneId.of("Asia/Ho_Chi_Minh")
    private fun hex(s: String) = s.split(" ").map { it.toInt(16).toByte() }.toByteArray()
    private fun at(y: Int, mo: Int, d: Int, h: Int, mi: Int) = ZonedDateTime.of(y, mo, d, h, mi, 0, 0, zone).toInstant().toEpochMilli()

    // Bảng tính năng thật (01-protocol §10/§11, 08-hardware §3.2): Y25 có CyWee (34F1 b19.5), HT43 không.
    private val y25 = Ute.Features.parse(
        hex("08 88 6C 2A 01 24 39 43 75 6E DF FE D9 21 00 5D 78 5B A0 DC"),
        hex("00 F4 00 00 00 00 00 00 00 00 00 05 00 00 40 02 00 00 04 20"),
    )
    private val ht43 = Ute.Features.parse(
        hex("08 88 6C 2A 01 24 39 43 75 6E DF FE D9 21 00 5D 78 4B A1 DC"),
        hex("00 F4 00 00 00 00 00 00 00 00 00 05 00 00 40 00 00 00 04 00"),
    )

    // ---------- Chọn lệnh ----------

    @Test
    fun featureBits() {
        assertTrue(y25.resolveSleep)
        assertTrue(y25.cywee)
        assertTrue(ht43.resolveSleep)
        assertFalse(ht43.cywee)
        assertFalse(Ute.Features(emptyMap(), null).resolveSleep)
    }

    @Test
    fun planY25UsesCyweeThenOldFallback() {
        val plan = Ute.SyncPlan(y25, y25.capabilities())
        assertEquals(listOf(SyncCommand.STEPS_CYWEE, SyncCommand.STEPS_HOURLY), plan.steps)
        assertEquals(listOf(SyncCommand.SLEEP_CYWEE, SyncCommand.SLEEP_RESOLVE, SyncCommand.SLEEP_ROLL), plan.sleep)
        assertEquals(SyncCommand.HEART_RATE_24H, plan.heartRate)
        assertEquals(SyncCommand.SPO2, plan.spo2)
        assertEquals(SyncCommand.BLOOD_PRESSURE, plan.bloodPressure)
    }

    @Test
    fun planHt43UsesResolveSleep() {
        val plan = Ute.SyncPlan(ht43, ht43.capabilities())
        assertEquals(listOf(SyncCommand.STEPS_HOURLY), plan.steps)
        assertEquals(listOf(SyncCommand.SLEEP_RESOLVE, SyncCommand.SLEEP_ROLL), plan.sleep)
        assertNull(plan.bloodPressure) // HT43 không có huyết áp
    }

    @Test
    fun planOldWatchKeepsB2B3() {
        val f = Ute.Features(mapOf(1 to 0x080000, 2 to 0x004000), null)
        val plan = Ute.SyncPlan(f, f.capabilities())
        assertEquals(listOf(SyncCommand.STEPS_HOURLY), plan.steps)
        assertEquals(listOf(SyncCommand.SLEEP_ROLL), plan.sleep)
        assertEquals(SyncCommand.HEART_RATE_24H, plan.heartRate)
        val noSleep = Ute.Features(mapOf(4 to 0x008000), null)
        assertEquals(emptyList<SyncCommand>(), Ute.SyncPlan(noSleep, noSleep.capabilities()).sleep)
    }

    @Test
    fun commandBytesAndChannels() {
        assertArrayEquals(hex("B2 FA"), SyncCommand.STEPS_HOURLY.bytes)
        assertArrayEquals(hex("EB 02 FA"), SyncCommand.STEPS_CYWEE.bytes)
        assertArrayEquals(hex("31 01"), SyncCommand.SLEEP_RESOLVE.bytes)
        assertArrayEquals(hex("EC 01"), SyncCommand.SLEEP_CYWEE.bytes)
        assertArrayEquals(hex("C8 FA"), SyncCommand.BLOOD_PRESSURE.bytes)
        assertTrue(SyncCommand.STEPS_CYWEE.usesBle5)
        assertFalse(SyncCommand.SLEEP_CYWEE.usesBle5) // `EC 01` ghi 33F1 (`writeChara`)
        assertEquals("EB 02 FA", SyncCommand.STEPS_CYWEE.hex)
    }

    @Test
    fun streamMatchAndEnd() {
        val eb = SyncCommand.STEPS_CYWEE
        assertTrue(eb.matches(hex("EB 02 07 EA 0A 0D 08 03 E8")))
        assertFalse(eb.matches(hex("EB 01 07 EA 0A 0D 08 03 E8"))) // bước realtime
        assertTrue(eb.isEnd(hex("EB 02 FD 00")))
        assertTrue(eb.isEnd(hex("EB 02 FD 26"))) // gói thật Y25
        assertFalse(eb.isEnd(hex("EB 02 07 EA")))

        val r = SyncCommand.SLEEP_RESOLVE
        assertTrue(r.matches(hex("31 01 07 EA 0A 0E 03")))
        assertTrue(r.matches(hex("32 17 00 02 00 00 3C")))
        assertFalse(r.matches(hex("31 AB 01"))) // báo thức ngủ, không phải luồng
        assertTrue(r.isEnd(hex("31 02")))
        assertFalse(r.dedupe)

        val ec = SyncCommand.SLEEP_CYWEE
        assertTrue(ec.matches(hex("EC 02 16 1E")))
        assertTrue(ec.isEnd(hex("EC 03")))
        assertFalse(ec.isEnd(hex("EC 02 16 1E")))

        assertTrue(SyncCommand.SPO2.isEnd(hex("34 FA FD E7")))
        assertTrue(SyncCommand.BLOOD_PRESSURE.isEnd(hex("C8 FD")))
        assertTrue(SyncCommand.BLOOD_PRESSURE.isEnd(hex("C8 FD 05"))) // gói thật Y25
        assertTrue(SyncCommand.HEART_RATE_24H.matches(hex("F7 07 EA 0A 0D 12")))
        assertTrue(SyncCommand.STEPS_HOURLY.dedupe)
    }

    // ---------- Bản ghi ----------

    @Test
    fun cyweeSteps() {
        // `EB 02 YYYY MM DD HH sH sL dH dL c c c`: 1000 bước, 750 m, 40000 cal (40 kcal).
        val points = Ute.parseCyweeSteps(
            listOf(hex("EB 02 07 EA 0A 0D 08 03 E8 02 EE 00 9C 40"), hex("EB 02 00 00 00 00 00 00 05"), hex("EB 02 FD 00")), zone,
        )
        assertEquals(1, points.size) // năm 0 bị bỏ như app
        assertEquals(at(2026, 10, 13, 8, 0), points[0].timestamp)
        assertEquals(1000.0, points[0].value, 0.0)
        assertEquals(750.0, points[0].extra["distance"])
        assertEquals(40000.0, points[0].extra["calories"])
    }

    @Test
    fun bloodPressure() {
        val points = Ute.parseBloodPressure(listOf(hex("C8 07 EA 0A 0D 08 1E 78 4E"), hex("C8 07 EA 0A 0D 09 00 00 00"), hex("C8 FD")), zone)
        assertEquals(1, points.size) // 0/0 bị bỏ
        assertEquals(at(2026, 10, 13, 8, 30), points[0].timestamp)
        assertEquals(120.0, points[0].value, 0.0)
        assertEquals(78.0, points[0].extra["diastolic"])
    }

    @Test
    fun bloodPressureFromY25() {
        // Gói thật Y25 16/10/2026 (`C8 FA`): 15:19 122/72, 15:20 121/73.
        val points = Ute.parseBloodPressure(listOf(hex("C8 07 EA 0A 10 0F 13 7A 48"), hex("C8 07 EA 0A 10 0F 14 79 49")), zone)
        assertEquals(listOf(122.0, 121.0), points.map { it.value })
        assertEquals(at(2026, 10, 16, 15, 19), points[0].timestamp)
        assertEquals(73.0, points[1].extra["diastolic"])
    }

    @Test
    fun sleepHourlyFormat() {
        // 14 byte `B3 YYYY MM DD hh (m, r)×4`, FF FF = ô trống.
        val p = hex("B3 07 EA 0A 0E 01 00 02 1E 05 FF FF FF FF")
        val sessions = Ute.parseSleep(listOf(p), zone, hourlyFormat = true)
        assertEquals(1, sessions.size)
        assertEquals(at(2026, 10, 14, 1, 0), sessions[0].start)
        assertEquals(30, sessions[0].minutes(SleepStage.DEEP))
    }

    // ---------- Ngủ do đồng hồ tính (`31 01` / `EC 01`) ----------

    @Test
    fun resolveSleepAcrossMidnightAndSplitPackets() {
        // Ngày 2026-10-14: 23:00 nông 60 phút, 00:00 sâu 90, 01:30 thức 10, 01:40 REM 50. Đoạn thứ 3 bị cắt qua 2 gói `32`.
        val packets = listOf(
            hex("31 01 07 EA 0A 0E 04"),
            hex("32 17 00 02 00 00 3C 00 00 01 00 00 5A 01 1E"),
            hex("32 03 00 00 0A 01 28 04 00 00 32"),
        )
        val days = Ute.sleepDays(packets, cywee = false)
        assertEquals(1, days.size)
        assertEquals(4, days[0].sectionCount)
        assertEquals(4, days[0].declaredCount)
        val sessions = Ute.parseSleepDays(days, zone)
        assertEquals(1, sessions.size)
        val s = sessions[0]
        assertEquals(at(2026, 10, 13, 23, 0), s.start) // từ 20:00 trở đi ⇒ tối hôm trước
        assertEquals(at(2026, 10, 14, 2, 30), s.end)
        assertEquals(60, s.minutes(SleepStage.LIGHT))
        assertEquals(90, s.minutes(SleepStage.DEEP))
        assertEquals(10, s.minutes(SleepStage.AWAKE))
        assertEquals(50, s.minutes(SleepStage.REM))
        assertEquals(200, s.asleepMinutes)
        assertFalse(s.nap)
    }

    @Test
    fun resolveSleepStartingAfterMidnightStaysOnDay() {
        val days = Ute.sleepDays(listOf(hex("31 01 07 EA 0A 0E 01"), hex("32 01 0F 01 00 01 2C")), cywee = false)
        val s = Ute.parseSleepDays(days, zone)
        assertEquals(at(2026, 10, 14, 1, 15), s[0].start)
        assertEquals(300, s[0].minutes(SleepStage.DEEP))
    }

    @Test
    fun cyweeSleepSectionsAndNap() {
        // `EC 02` bỏ 2 byte đầu. 22:30 nông 120; đoạn FF = hết phiên; 13:00 REM 30 (ngủ trưa hôm sau).
        val packets = listOf(
            hex("EC 01 07 EA 0A 0E 03"),
            hex("EC 02 16 1E 02 00 00 78 06 1E FF 00 00 00"),
            hex("EC 02 0D 00 04 00 00 1E"),
        )
        val days = Ute.sleepDays(packets, cywee = true)
        assertEquals(3, days[0].sectionCount)
        val sessions = Ute.parseSleepDays(days, zone)
        assertEquals(2, sessions.size)
        assertEquals(at(2026, 10, 13, 22, 30), sessions[0].start)
        assertEquals(at(2026, 10, 14, 0, 30), sessions[0].end)
        assertEquals(120, sessions[0].minutes(SleepStage.LIGHT))
        assertFalse(sessions[0].nap)
        assertEquals(at(2026, 10, 14, 13, 0), sessions[1].start)
        assertEquals(30, sessions[1].minutes(SleepStage.REM))
        assertTrue(sessions[1].nap)
    }

    @Test
    fun cyweeSleepEmptyFromY25() {
        // Y25 chưa có giấc ngủ: `EC 01` → chỉ `EC 03` (gói kết thúc, không vào danh sách gói).
        assertTrue(SyncCommand.SLEEP_CYWEE.isEnd(hex("EC 03")))
        assertEquals(emptyList<Any>(), Ute.parseSleepDays(Ute.sleepDays(emptyList(), cywee = true), zone))
        // `31 01` → `31 01 07 EA 0A 10 00` (0 đoạn) rồi `31 02`.
        val days = Ute.sleepDays(listOf(hex("31 01 07 EA 0A 10 00")), cywee = false)
        assertEquals(1, days.size)
        assertEquals(0, days[0].sectionCount)
        assertEquals(emptyList<Any>(), Ute.parseSleepDays(days, zone))
    }

    @Test
    fun sleepDaysIgnoresDataBeforeStartAndBadSections() {
        // Gói `32` trước `31 01` bị bỏ; đoạn giờ 25 bị bỏ; hai ngày tách riêng.
        val packets = listOf(
            hex("32 17 00 02 00 00 3C"),
            hex("31 01 07 EA 0A 0D 01"),
            hex("32 19 00 02 00 00 3C 02 00 01 00 00 3C"),
            hex("31 01 07 EA 0A 0E 01"),
            hex("32 03 00 02 00 00 1E"),
        )
        val days = Ute.sleepDays(packets, cywee = false)
        assertEquals(2, days.size)
        val sessions = Ute.parseSleepDays(days, zone)
        assertEquals(2, sessions.size)
        assertEquals(at(2026, 10, 13, 2, 0), sessions[0].start)
        assertEquals(at(2026, 10, 14, 3, 0), sessions[1].start)
        assertEquals(SleepStage.UNKNOWN, Ute.sleepStage(0))
    }

    @Test
    fun todayTotalsFromRealY25Packets() {
        // Gói thật Y25 16/10/2026: giờ 15 xong (`EB 02`), giờ 16 đang chạy (`EB 01`).
        val hourly = Ute.parseCyweeSteps(listOf(hex("EB 02 07 EA 0A 10 0F 00 1C 00 13 00 07 D6"), hex("EB 02 FD 26")), zone)
        val now = at(2026, 10, 16, 16, 30)
        val t = Ute.todayTotals(hourly, hex("EB 01 07 EA 0A 10 10 00 0A 00 07 00 03 E8"), zone, now)
        assertEquals(ActivityTotals(steps = 38, calories = 3000, distanceMeters = 26), t) // 2006 → 2000 cal (0,1 kcal/giờ như app)
        // Giờ đang chạy đã có trong EB 02 thì không cộng lại; hôm qua thì bỏ.
        val same = Ute.todayTotals(hourly, hex("EB 01 07 EA 0A 10 0F 00 1C 00 13 00 07 D6"), zone, now)
        assertEquals(28, same?.steps)
        assertNull(Ute.todayTotals(hourly, null, zone, at(2026, 10, 17, 8, 0)))
        // Chỉ có `EB 01` (gói thật Y25, giờ 16 chưa có bước) ⇒ tổng 0 chứ không null.
        val empty = Ute.todayTotals(emptyList(), hex("EB 01 07 EA 0A 10 10 00 00 00 00 00 00 00"), zone, now)
        assertEquals(ActivityTotals(steps = 0, calories = 0, distanceMeters = 0), empty)
    }

    @Test
    fun caloriesFollowOfficialAppFormula() {
        // Gói thật Y25 19/10/2026: giờ 19 xong 132 bước / 86 m / 0x00253D = 9533 (kcal×1000); giờ 21 đang chạy chưa có bước.
        // GloryFit/Pro không tính lại từ bước + hồ sơ: kcal = round1(raw / 1000) mỗi giờ (`SWAlgorithmUtil.java:47-49`) ⇒ 9,5 kcal.
        val hourly = Ute.parseCyweeSteps(listOf(hex("EB 02 07 EA 0A 13 13 00 84 00 56 00 25 3D"), hex("EB 02 FD 26")), zone)
        assertEquals(1, hourly.size)
        assertEquals(at(2026, 10, 19, 19, 0), hourly[0].timestamp)
        assertEquals(132.0, hourly[0].value, 0.0)
        assertEquals(86.0, hourly[0].extra["distance"])
        assertEquals(9500.0, hourly[0].extra["calories"])
        val t = Ute.todayTotals(hourly, hex("EB 01 07 EA 0A 13 15 00 00 00 00 00 00 00"), zone, at(2026, 10, 19, 21, 10))
        assertEquals(ActivityTotals(steps = 132, calories = 9500, distanceMeters = 86), t)
        // Làm tròn nửa lên như `TempratureUtils.roundingToFloat(1, …)`.
        assertEquals(listOf(0, 0, 100, 3400, 3500, 9500), listOf(0, 49, 50, 3449, 3450, 9533).map(Ute::cyweeCalories))
    }
}
