package com.smartwear.veepoo

import com.smartwear.core.Capability
import com.smartwear.core.SleepStage
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneOffset

/** Lịch sử GE54 thật (đồng bộ 19/10/2026 18:59, `src/test/resources/ge54/`). */
class VeepooHistoryTest {

    private val zone = ZoneOffset.ofHours(7)
    private fun hex(s: String) = s.trim().split(Regex("\\s+")).map { it.toInt(16).toByte() }.toByteArray()
    private fun fixture(name: String): List<ByteArray> =
        javaClass.classLoader!!.getResource("ge54/$name")!!.readText().lines().filter { it.isNotBlank() }.map(::hex)

    @Test
    fun stepsToday() {
        val t = VeepooHistory.parseD8(hex("D8 00 16 00 00 00 12 00 00 00 09 00 00 00 00 00 00 00 00 00"))!!
        assertEquals(22, t.steps)
        assertEquals(18, t.distanceMeters)
        assertEquals(900, t.calories) // 0,9 kcal = 900 cal (quy ước core)
        assertEquals(1234, VeepooHistory.parseA8(hex("A8 00 00 04 D2 00 00"))!!)
        assertEquals(0, VeepooHistory.parseA8(hex("A8 FF FF FF FF 00 00"))!!)
        assertEquals(null, VeepooHistory.parseA8(hex("A8 00 00 04 D2 01 00")))
    }

    @Test
    fun dfRequest() {
        assertEquals("DF 01 00 02 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00", VeepooHistory.dfRequest(2).joinToString(" ") { "%02X".format(it) })
    }

    @Test
    fun dfBlocksGe54() {
        val packets = fixture("df_day0_head.txt")
        val h = VeepooHistory.parseDfHeader(packets[0])!!
        assertEquals(1, h.block)
        assertEquals(33, h.totalBlocks)
        assertEquals(2, h.packets)
        assertEquals(0xEF, h.validBytes)
        assertEquals(0x20B9, h.crc)
        assertEquals(0xCD, h.packetLength)
        val blocks = VeepooHistory.assembleDf(packets)
        assertEquals(2, blocks.size)
        assertTrue(blocks.all { it.crcOk })
        val first = VeepooHistory.parseFiveMinute(blocks[0].payload, LocalDate.of(2026, 10, 19))!!
        assertEquals(LocalDateTime.of(2026, 10, 19, 15, 45), first.time)
        assertEquals(22, first.steps)
        assertEquals(18, first.distanceMeters)
        assertEquals(9, first.calories10)
        val second = VeepooHistory.parseFiveMinute(blocks[1].payload, LocalDate.of(2026, 10, 19))!!
        assertEquals(LocalDateTime.of(2026, 10, 19, 15, 50), second.time)
        assertEquals(listOf(63, 0, 0, 0, 0), second.heartRates)
        assertEquals(117, second.systolic)
        assertEquals(90, second.diastolic)
        assertEquals(0x13, second.stress)
        assertEquals(36.7, second.temperature!!, 0.001) // C3 62 01 6F 01: nền 35,4, cơ thể 36,7
        val series = VeepooHistory.toSeries(listOf(first, second), zone)
        assertEquals(2, series[Capability.STEPS]!!.size)
        assertEquals(900.0, series[Capability.STEPS]!![0].extra["calories"]!!, 0.001)
        assertEquals(6.83, second.glucose!!, 0.001) // BE 02 AB 02
        assertEquals(6.83, series[Capability.BLOOD_SUGAR]!![0].value, 0.001)
        assertEquals(90.0, series[Capability.BLOOD_PRESSURE]!![0].extra["diastolic"]!!, 0.0)
    }

    @Test
    fun dfCorruptBlockRejected() {
        val packets = fixture("df_day0_head.txt").map { it.copyOf() }
        packets[1][20] = 0x7F // hỏng một byte dữ liệu khối 1
        val blocks = VeepooHistory.assembleDf(packets)
        assertEquals(false, blocks[0].crcOk)
        assertEquals(true, blocks[1].crcOk)
    }

    @Test
    fun d1Records() {
        val today = LocalDate.of(2026, 10, 19)
        // Layout thường: hôm qua 18/10 13:25, 300 bước, HR 72, HA 120/80.
        val n = VeepooHistory.parseD1(hex("D1 05 00 20 00 01 00 12 0D 19 01 2C 00 10 48 78 50 00 00 00"), today, sportLayout = false)!!
        assertEquals(LocalDateTime.of(2026, 10, 18, 13, 25), n.time)
        assertEquals(300, n.steps)
        assertEquals(listOf(72), n.heartRates)
        assertEquals(120, n.systolic)
        // Sai ngày trong tháng ⇒ bỏ (như app gốc).
        assertEquals(null, VeepooHistory.parseD1(hex("D1 05 00 20 00 01 00 11 0D 19 01 2C 00 10 48 78 50 00 00 00"), today, false))
        // Layout sport model: [5] = 1×32 + 13, phút ở [19].
        val s = VeepooHistory.parseD1(hex("D1 05 00 20 00 2D 00 0A 00 C8 01 2C 00 10 48 00 00 01 00 19"), today, sportLayout = true)!!
        assertEquals(LocalDateTime.of(2026, 10, 18, 13, 25), s.time)
        assertEquals(200, s.distanceMeters)
        assertEquals(10, s.calories10)
        assertTrue(VeepooHistory.isD1End(hex("D1 20 00 20 00")))
        assertEquals("D1 01 00 02", VeepooHistory.d1Request(2).joinToString(" ") { "%02X".format(it) })
    }

    @Test
    fun hrv5() {
        val b7 = ByteArray(51).also { it[0] = 0; for (i in 1..50) it[i] = (if (i % 2 == 0) 80 else 90).toByte() }
        assertEquals(listOf(100, 100, 100, 100, 100), VeepooHistory.hrv5(b7))
    }

    @Test
    fun preciseSleepGe54() {
        val packets = fixture("e0_day2.txt")
        assertTrue(VeepooHistory.isSleepLast(packets.last()))
        val nights = VeepooHistory.parsePrecise(VeepooHistory.sleepPayload(packets), LocalDate.of(2026, 10, 17))
        assertEquals(1, nights.size)
        val n = nights[0]
        assertEquals(LocalDateTime.of(2026, 10, 17, 0, 36), n.start)
        assertEquals(LocalDateTime.of(2026, 10, 17, 6, 24), n.end)
        assertEquals(348, n.totalMinutes)
        assertEquals(52, n.deepMinutes)
        assertEquals(224, n.lightMinutes)
        assertEquals(2, n.quality)
        assertEquals(1, n.accurateType)
        assertEquals(60, n.pointSeconds)
        assertEquals(348, n.line.size)
        assertEquals(52, n.line.count { it == 0 })
        assertEquals(224, n.line.count { it == 1 })
        val session = VeepooHistory.preciseToSession(n, zone)
        assertEquals(52, session.minutes(SleepStage.DEEP))
        assertEquals(224, session.minutes(SleepStage.LIGHT))
        assertTrue(session.minutes(SleepStage.REM) > 0)
        assertEquals(348, session.segments.sumOf { it.minutes })
    }

    @Test
    fun preciseSleepGe54Day1() {
        val nights = VeepooHistory.parsePrecise(VeepooHistory.sleepPayload(fixture("e0_day1.txt")), LocalDate.of(2026, 10, 18))
        assertEquals(1, nights.size)
        assertEquals(LocalDateTime.of(2026, 10, 18, 0, 55), nights[0].start)
        assertEquals(LocalDateTime.of(2026, 10, 18, 5, 49), nights[0].end)
        assertEquals(nights[0].totalMinutes, nights[0].line.size)
    }

    @Test
    fun emptySleepDay() {
        val p = hex("E0 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00")
        assertTrue(VeepooHistory.isSleepLast(p))
        assertEquals(0, VeepooHistory.parsePrecise(VeepooHistory.sleepPayload(listOf(p)), LocalDate.of(2026, 10, 19)).size)
    }

    @Test
    fun yearRollover() {
        assertEquals(LocalDateTime.of(2025, 12, 31, 23, 10), VeepooHistory.dateNear(LocalDate.of(2026, 1, 1), 12, 31, 23, 10))
    }
}
