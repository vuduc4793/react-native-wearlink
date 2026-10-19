package com.smartwear.qring.protocol

import com.smartwear.core.ActivityTotals
import com.smartwear.core.HistoryPoint
import com.smartwear.core.SleepSegment
import com.smartwear.core.SleepSession
import com.smartwear.core.SleepStage
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZoneOffset

/**
 * Giải mã dữ liệu lịch sử QRing (sdks/qring/docs/03-history-sync.md). Hàm thuần, không I/O.
 *
 * Ring chỉ biết giờ tường địa phương, không biết múi giờ: mọi mốc thời gian quy đổi theo [zone]
 * của điện thoại. `p.u8(i)` là byte `i+1` của gói 16 byte (byte 0 là mã lệnh).
 */
class HistoryParser(private val zone: ZoneId = ZoneId.systemDefault()) {

    private fun midnight(date: LocalDate): Long = date.atStartOfDay(zone).toInstant().toEpochMilli()
    private fun bcd(v: Int) = (v shr 4) * 10 + (v and 0x0F)
    private fun le16(lo: Int, hi: Int) = lo or (hi shl 8)

    // ---------- Bước chân: lệnh 0x43, khung 15 phút ----------

    /** Request bước chân của ngày [dayOffset] (0 = hôm nay), đủ 96 khung. */
    fun stepsRequest(dayOffset: Int) = Packet.of(CMD_STEPS, dayOffset, 0x0F, 0, 95, 0x01)

    fun stepsComplete(packets: List<Packet>): Boolean {
        val first = packets.firstOrNull() ?: return false
        if (first.u8(0) == 0xFF) return true
        val last = packets.last()
        return last.u8(0) != 0xF0 && last.u8(4) == last.u8(5) - 1
    }

    /** Mỗi khung có dữ liệu thành một điểm: value = số bước, extra calories (cal) và distance (m). */
    fun parseSteps(packets: List<Packet>): List<HistoryPoint> {
        if (packets.isEmpty() || packets[0].u8(0) == 0xFF) return emptyList()
        var newCalorieProtocol = false
        val points = mutableListOf<HistoryPoint>()
        for (p in packets) {
            if (p.u8(0) == 0xF0) {
                newCalorieProtocol = p.u8(2) == 1
                continue
            }
            val date = LocalDate.of(2000 + bcd(p.u8(0)), bcd(p.u8(1)), bcd(p.u8(2)))
            val slot = p.u8(3)
            val calories = le16(p.u8(6), p.u8(7)) * if (newCalorieProtocol) 10 else 1
            val steps = le16(p.u8(8), p.u8(9))
            val distance = le16(p.u8(10), p.u8(11))
            points += HistoryPoint(
                timestamp = midnight(date) + slot * SLOT_MS,
                value = steps.toDouble(),
                extra = mapOf("calories" to calories.toDouble(), "distance" to distance.toDouble()),
            )
        }
        return points
    }

    /** Lệnh 0x48: tổng hôm nay, các trường 24 bit big-endian. */
    fun parseTodayTotals(p: Packet): ActivityTotals {
        fun be24(i: Int) = (p.u8(i) shl 16) or (p.u8(i + 1) shl 8) or p.u8(i + 2)
        return ActivityTotals(
            steps = be24(0),
            calories = be24(6),
            distanceMeters = be24(9),
            activeMinutes = (p.u8(12) shl 8) or p.u8(13),
        )
    }

    // ---------- Nhịp tim theo ngày: lệnh 0x15 ----------

    /** Request nhịp tim cho [date]: 4 byte "giờ tường" của 00:00 ngày đó, little-endian. */
    fun heartRateRequest(date: LocalDate): Packet {
        val localEpoch = date.atStartOfDay().toEpochSecond(ZoneOffset.UTC)
        return Packet.of(CMD_HEART_RATE, (localEpoch and 0xFF).toInt(), (localEpoch shr 8 and 0xFF).toInt(), (localEpoch shr 16 and 0xFF).toInt(), (localEpoch shr 24 and 0xFF).toInt())
    }

    fun heartRateComplete(packets: List<Packet>) = indexedComplete(packets)

    fun parseHeartRate(packets: List<Packet>, date: LocalDate): List<HistoryPoint> =
        indexedSeries(packets, firstOffset = 5, date = date)

    // ---------- HRV (0x39) và stress (0x37): theo ngày lệch ----------

    fun hrvRequest(dayOffset: Int) = Packet.of(CMD_HRV, dayOffset)
    fun stressRequest(dayOffset: Int) = Packet.of(CMD_STRESS, dayOffset)
    fun dailyComplete(packets: List<Packet>) = indexedComplete(packets)

    fun parseDaily(packets: List<Packet>, date: LocalDate): List<HistoryPoint> =
        indexedSeries(packets, firstOffset = 2, date = date)

    /**
     * Khuôn chung của 0x15 / 0x39 / 0x37: gói 0 = (size, range); gói 1 có phần đầu riêng rồi giá trị;
     * gói k ≥ 2 có 13 giá trị. `0xFF` ở gói đầu = không có dữ liệu.
     */
    private fun indexedComplete(packets: List<Packet>): Boolean {
        val first = packets.firstOrNull() ?: return false
        if (first.u8(0) == 0xFF) return true
        val header = packets.firstOrNull { it.u8(0) == 0 } ?: return false
        val size = header.u8(1)
        return size <= 1 || packets.any { it.u8(0) == size - 1 }
    }

    private fun indexedSeries(packets: List<Packet>, firstOffset: Int, date: LocalDate): List<HistoryPoint> {
        val header = packets.firstOrNull { it.u8(0) == 0 } ?: return emptyList()
        val range = header.u8(2).takeIf { it > 0 } ?: return emptyList()
        val values = mutableListOf<Int>()
        packets.filter { it.u8(0) in 1..0xFE }.sortedBy { it.u8(0) }.forEach { p ->
            val from = if (p.u8(0) == 1) firstOffset else 1
            for (i in from..13) values += p.u8(i)
        }
        val base = midnight(date)
        val now = System.currentTimeMillis()
        return values.mapIndexedNotNull { i, v ->
            val minute = i * range
            val ts = base + minute * 60_000L
            if (v == 0 || minute >= 1440 || ts > now) null else HistoryPoint(ts, v.toDouble())
        }
    }

    // ---------- Giấc ngủ, giao thức mới: big-data 0x27 ----------

    /** `sel = 0xFF`: mọi ngày ring còn lưu (suy luận từ app: 0x00 = hôm nay, 0xFF = lịch sử). */
    fun sleepRequest(allDays: Boolean = true) = BigDataFrame(CMD_SLEEP, byteArrayOf(if (allDays) 0xFF.toByte() else 0, 0x01))

    /**
     * Khung 0x27 (giấc chính) và 0x3E (ngủ trưa) cùng định dạng: kiểm chứng trên DS500, khung 0x3E
     * `02 | 06 08 FE 02 27 03 02 1F 02 0A | 05 08 …` là 2 giấc trưa 12:46–13:27 (41 phút) và 12:37–13:26.
     */
    fun parseSleep(payload: ByteArray, today: LocalDate, nap: Boolean = false): List<SleepSession> {
        if (payload.isEmpty()) return emptyList()
        val u = { i: Int -> payload[i].toInt() and 0xFF }
        val dayCount = u(0)
        val sessions = mutableListOf<SleepSession>()
        var offset = 1
        repeat(dayCount) {
            if (offset + 6 > payload.size) return sessions
            val daysAgo = u(offset)
            val length = u(offset + 1) + 2
            val endMinute = le16(u(offset + 4), u(offset + 5))
            val pairsEnd = minOf(offset + length, payload.size)
            val stages = mutableListOf<Pair<SleepStage, Int>>()
            var i = offset + 6
            while (i + 1 < pairsEnd) {
                stages += stageOf(u(i)) to u(i + 1)
                i += 2
            }
            offset += length
            if (stages.isEmpty()) return@repeat
            // Neo theo giờ kết thúc rồi lùi theo tổng thời lượng: đêm qua nửa đêm không cần xử lý riêng.
            val end = midnight(today.minusDays(daysAgo.toLong())) + endMinute * 60_000L
            val start = end - stages.sumOf { it.second } * 60_000L
            var cursor = start
            val segments = stages.map { (stage, minutes) ->
                SleepSegment(cursor, minutes, stage).also { cursor += minutes * 60_000L }
            }
            sessions += SleepSession(start, end, segments, nap)
        }
        return sessions
    }

    private fun stageOf(code: Int) = when (code) {
        2 -> SleepStage.LIGHT
        3 -> SleepStage.DEEP
        4 -> SleepStage.REM
        5 -> SleepStage.AWAKE
        else -> SleepStage.UNKNOWN
    }

    // ---------- SpO2 theo giờ: big-data 0x2A ----------

    fun spo2Request() = BigDataFrame(CMD_SPO2_DAILY, byteArrayOf(0xFF.toByte()))

    /** Bản ghi 49 byte: daysAgo + 24 cặp (cao nhất, thấp nhất) theo giờ. value = cao nhất, extra "min". */
    fun parseSpo2(payload: ByteArray, today: LocalDate): List<HistoryPoint> {
        val points = mutableListOf<HistoryPoint>()
        val now = System.currentTimeMillis()
        for (r in 0 until payload.size / 49) {
            val base = r * 49
            val daysAgo = payload[base].toInt() and 0xFF
            val midnight = midnight(today.minusDays(daysAgo.toLong()))
            for (h in 0 until 24) {
                val max = payload[base + 1 + h * 2].toInt() and 0xFF
                val min = payload[base + 2 + h * 2].toInt() and 0xFF
                val ts = midnight + h * 3_600_000L
                if (max == 0 || ts > now) continue
                points += HistoryPoint(ts, max.toDouble(), mapOf("min" to min.toDouble()))
            }
        }
        return points.sortedBy { it.timestamp }
    }

    // ---------- Chuỗi theo interval có phân trang: nhiệt độ 0x77 (HR 0x75, SpO2 0x5F cùng khuôn) ----------

    data class IntervalPage(val dayIndex: Int, val interval: Int, val count: Int, val index: Int, val values: List<Double>)

    fun intervalRequest(command: Int, dayIndex: Int, page: Int) = BigDataFrame(command, byteArrayOf(dayIndex.toByte(), page.toByte()))

    fun parseIntervalPage(payload: ByteArray, twoByteValues: Boolean): IntervalPage? {
        if (payload.size < 4) return null
        val u = { i: Int -> payload[i].toInt() and 0xFF }
        val values = if (twoByteValues) {
            (4 until payload.size - 1 step 2).map { le16(u(it), u(it + 1)) / 100.0 }
        } else {
            (4 until payload.size).map { u(it).toDouble() }
        }
        return IntervalPage(u(0), u(1), u(2), u(3), values)
    }

    fun intervalPoints(pages: List<IntervalPage>, today: LocalDate): List<HistoryPoint> {
        val first = pages.firstOrNull() ?: return emptyList()
        if (first.interval == 0) return emptyList()
        val base = midnight(today.minusDays(first.dayIndex.toLong()))
        val now = System.currentTimeMillis()
        return pages.sortedBy { it.index }.flatMap { it.values }.mapIndexedNotNull { i, v ->
            val minute = i * first.interval
            val ts = base + minute * 60_000L
            if (v <= 0.0 || minute >= 1440 || ts > now) null else HistoryPoint(ts, v)
        }
    }

    companion object {
        const val CMD_STEPS = 0x43
        const val CMD_TODAY_TOTALS = 0x48
        const val CMD_HEART_RATE = 0x15
        const val CMD_HRV = 0x39
        const val CMD_STRESS = 0x37
        const val CMD_SLEEP = 0x27
        const val CMD_NAP = 0x3E
        const val CMD_SPO2_DAILY = 0x2A
        const val CMD_TEMPERATURE_INTERVAL = 0x77
        private const val SLOT_MS = 15 * 60_000L
    }
}
