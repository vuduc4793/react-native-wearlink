package com.smartwear.qring.protocol

import com.smartwear.core.SleepStage
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZonedDateTime

/** Ví dụ hex lấy từ sdks/qring/docs/03-history-sync.md, múi giờ Việt Nam (UTC+7). */
class HistoryParserTest {

    private val zone = ZoneId.of("Asia/Ho_Chi_Minh")
    private val parser = HistoryParser(zone)
    private val day = LocalDate.of(2026, 10, 12)

    private fun hex(s: String) = s.split(" ").map { it.toInt(16).toByte() }.toByteArray()
    private fun at(date: LocalDate, h: Int, m: Int) = ZonedDateTime.of(date.atTime(h, m), zone).toInstant().toEpochMilli()

    @Test
    fun stepsRequest() {
        assertArrayEquals(hex("43 00 0F 00 5F 01 00 00 00 00 00 00 00 00 00 B2"), parser.stepsRequest(0).bytes)
        assertArrayEquals(hex("43 01 0F 00 5F 01 00 00 00 00 00 00 00 00 00 B3"), parser.stepsRequest(1).bytes)
    }

    @Test
    fun stepsSlotsAndCompletion() {
        val header = Packet.of(0x43, 0xF0, 0x05, 0x01)
        val slot = Packet.of(0x43, 0x26, 0x10, 0x12, 0x20, 0x00, 0x05, 0x23, 0x00, 0xF4, 0x01, 0x72, 0x01)
        val last = Packet.of(0x43, 0x26, 0x10, 0x12, 0x21, 0x04, 0x05, 0x01, 0x00, 0x0A, 0x00, 0x05, 0x00)
        assertFalse(parser.stepsComplete(listOf(header, slot)))
        assertTrue(parser.stepsComplete(listOf(header, slot, last)))

        val points = parser.parseSteps(listOf(header, slot, last))
        assertEquals(2, points.size)
        assertEquals(at(day, 8, 0), points[0].timestamp)
        assertEquals(500.0, points[0].value, 0.0)
        assertEquals(350.0, points[0].extra["calories"]!!, 0.0) // 0x23 = 35 × 10 (calorieNewProtocol)
        assertEquals(370.0, points[0].extra["distance"]!!, 0.0)
        assertEquals(at(day, 8, 15), points[1].timestamp)
    }

    @Test
    fun stepsNoData() {
        val none = listOf(Packet.of(0x43, 0xFF))
        assertTrue(parser.stepsComplete(none))
        assertTrue(parser.parseSteps(none).isEmpty())
    }

    @Test
    fun todayTotalsBigEndian() {
        val p = Packet.of(0x48, 0x00, 0x0B, 0xB8, 0, 0, 0, 0x01, 0x86, 0xA0, 0x00, 0x07, 0xD0, 0x00, 0x2D)
        val t = parser.parseTodayTotals(p)
        assertEquals(3000, t.steps)
        assertEquals(100000, t.calories)
        assertEquals(2000, t.distanceMeters)
        assertEquals(45, t.activeMinutes)
    }

    @Test
    fun heartRateRequestUsesLocalWallClock() {
        assertArrayEquals(
            hex("15 80 74 CD 6A 00 00 00 00 00 00 00 00 00 00 40"),
            parser.heartRateRequest(LocalDate.of(2026, 10, 13)).bytes,
        )
    }

    @Test
    fun heartRateSeries() {
        val header = Packet.of(0x15, 0x00, 0x03, 0x05)
        val first = Packet.of(0x15, 0x01, 0x80, 0x74, 0xCD, 0x6A, 0, 0, 0, 0, 0, 0x3C, 0x3E, 0x40, 0x3B)
        val second = Packet.of(0x15, 0x02, 0x3A, 0x3A, 0x3A, 0x3A, 0x3A, 0x3A, 0x3A, 0x3A, 0x3A, 0x3A, 0x3A, 0x3A, 0x3A)
        assertFalse(parser.heartRateComplete(listOf(header, first)))
        assertTrue(parser.heartRateComplete(listOf(header, first, second)))

        val points = parser.parseHeartRate(listOf(header, first, second), day)
        assertEquals(at(day, 0, 25), points.first().timestamp)
        assertEquals(60.0, points.first().value, 0.0)
        assertEquals(4 + 13, points.size)
        assertEquals(at(day, 0, 45), points[4].timestamp) // giá trị thứ 9 (gói 2) = 00:45
        assertEquals(58.0, points[4].value, 0.0)
    }

    @Test
    fun hrvSeries() {
        val header = Packet.of(0x39, 0x00, 0x02, 0x1E)
        val first = Packet.of(0x39, 0x01, 0x01, 0x2A, 0x30, 0x2D)
        val points = parser.parseDaily(listOf(header, first), day)
        assertTrue(parser.dailyComplete(listOf(header, first)))
        assertEquals(listOf(42.0, 48.0, 45.0), points.map { it.value })
        assertEquals(at(day, 0, 30), points[1].timestamp)
    }

    @Test
    fun sleepNewProtocolCrossesMidnight() {
        val payload = hex("01 00 16 64 05 A4 01 02 3C 03 5A 02 3C 04 1E 02 5A 03 3C 04 28 05 0A 02 28")
        assertEquals(0xFF91, BigDataFrame.crc16Modbus(payload))

        val today = LocalDate.of(2026, 10, 13)
        val sessions = parser.parseSleep(payload, today)
        assertEquals(1, sessions.size)
        val s = sessions[0]
        assertEquals(at(today, 7, 0), s.end)
        assertEquals(at(today.minusDays(1), 23, 0), s.start)
        assertEquals(9, s.segments.size)
        assertEquals(SleepStage.LIGHT, s.segments[0].stage)
        assertEquals(60 + 60 + 90 + 40, s.minutes(SleepStage.LIGHT))
        assertEquals(150, s.minutes(SleepStage.DEEP))
        assertEquals(70, s.minutes(SleepStage.REM))
        assertEquals(10, s.minutes(SleepStage.AWAKE))
        assertEquals(470, s.asleepMinutes)
    }

    @Test
    fun temperaturePage() {
        val page = parser.parseIntervalPage(hex("00 1E 01 00 3C 0E 4E 0E 00 00"), twoByteValues = true)!!
        assertEquals(30, page.interval)
        assertEquals(listOf(36.44, 36.62, 0.0), page.values)
        val points = parser.intervalPoints(listOf(page), day.plusDays(0).let { LocalDate.of(2026, 10, 12) })
        assertEquals(2, points.size)
        assertEquals(at(day, 0, 30), points[1].timestamp)
    }

    @Test
    fun spo2HourlyPairs() {
        val record = ByteArray(49)
        record[0] = 1 // hôm qua
        record[1] = 98.toByte(); record[2] = 95.toByte() // 00h
        record[3] = 97.toByte(); record[4] = 94.toByte() // 01h
        val points = parser.parseSpo2(record, LocalDate.of(2026, 10, 13))
        assertEquals(2, points.size)
        assertEquals(at(day, 1, 0), points[1].timestamp)
        assertEquals(97.0, points[1].value, 0.0)
        assertEquals(94.0, points[1].extra["min"]!!, 0.0)
    }
}

class NapParserTest {
    private val zone = ZoneId.of("Asia/Ho_Chi_Minh")

    /** Khung 0x3E thật đọc từ DS500 ngày 2026-10-13. */
    @Test
    fun napFrameFromDs500() {
        val payload = "02 06 08 FE 02 27 03 02 1F 02 0A 05 08 F5 02 26 03 02 17 02 1A"
            .split(" ").map { it.toInt(16).toByte() }.toByteArray()
        val today = LocalDate.of(2026, 10, 13)
        val naps = HistoryParser(zone).parseSleep(payload, today, nap = true)
        assertEquals(2, naps.size)
        val first = naps[0]
        assertTrue(first.nap)
        assertEquals(ZonedDateTime.of(today.minusDays(6).atTime(13, 27), zone).toInstant().toEpochMilli(), first.end)
        assertEquals(ZonedDateTime.of(today.minusDays(6).atTime(12, 46), zone).toInstant().toEpochMilli(), first.start)
        assertEquals(41, first.minutes(SleepStage.LIGHT))
        assertEquals(49, naps[1].asleepMinutes)
    }
}
