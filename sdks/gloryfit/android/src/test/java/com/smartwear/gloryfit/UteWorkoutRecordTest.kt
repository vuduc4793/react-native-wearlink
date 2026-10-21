package com.smartwear.gloryfit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDateTime
import java.time.ZoneId

/** Bản ghi bài tập đầy đủ (gói ≥ 2) dựng theo `BluetoothLeService.java:7340-7556` của app GloryFit. Chưa có gói thật có GPS. */
class UteWorkoutRecordTest {
    private val zone = ZoneId.of("Asia/Ho_Chi_Minh")
    private fun hex(h: String) = h.split(" ").filter { it.isNotEmpty() }.map { it.toInt(16).toByte() }.toByteArray()
    private fun s32(v: Int) = byteArrayOf((v shr 24).toByte(), (v shr 16).toByte(), (v shr 8).toByte(), v.toByte())
    private fun pkt(seq: Int, payload: ByteArray) = byteArrayOf(0xFD.toByte(), (seq shr 8).toByte(), seq.toByte()) + payload

    private val seq0 = hex("FD 00 00 01 00 05 07 EA 0A 0F 08 1E 00 00 00 00 00 00 07 08") // chạy bộ 15/10/2026 08:30, 1800 s
    // 3000 bước, 150 kcal, 2,50 km, HR 140/165/90, pace 6'30", khoảng mẫu 5 s (byte 17)
    private val seq1 = hex("FD 00 01 00 0B B8 00 00 00 96 02 32 8C A5 5A 06 1E 05 00 00")
    // vùng HR 60/600/900/240/0 s, sải bước TB 95 / max 120
    private val seq2 = hex("FD 00 02 00 00 3C 00 02 58 00 03 84 00 00 F0 00 00 00 5F 78")
    // sải bước min 70, pace max 5'10" / min 7'05", kiểu mẫu 1
    private val seq3 = hex("FD 00 03 46 05 0A 07 05 01 00 00 00 00 00 00 00 00 00 00 00")

    /** Mẫu kiểu 1: HR, pace phút, pace giây, nhịp bước, lat, lon. */
    private fun fmt1(hr: Int, min: Int, sec: Int, cad: Int, lat: Double, lon: Double) =
        byteArrayOf(hr.toByte(), min.toByte(), sec.toByte(), cad.toByte()) + s32((lat * 1e6).toInt()) + s32((lon * 1e6).toInt())

    @Test fun fullRecordWithGpsTrack() {
        val data = fmt1(130, 6, 30, 160, 21.028511, 105.804817) +
            fmt1(0, 0, 0, 0, 0.0, 0.0) + // chưa bắt được GPS, không có gì ⇒ bỏ
            fmt1(142, 6, 5, 168, -33.856784, 151.215297) // toạ độ âm
        val packets = listOf(
            hex("FD FA 00 00 00 00 00 00 00 01"), seq0, seq1, seq2, seq3,
            pkt(4, data.copyOfRange(0, 17)),
            hex("FD 01 AA 01"), // đồng hồ xin GPS điện thoại lẫn vào luồng: bỏ
            pkt(5, data.copyOfRange(17, 34)),
            pkt(6, data.copyOfRange(34, 36)),
            hex("FD FD"),
        )
        val w = Ute.parseWorkouts(packets, zone, endIsTimestamp = true, hasDetail = true).single()
        assertEquals(3000, w.steps)
        assertEquals(5, w.sampleIntervalSeconds)
        assertEquals(listOf(60, 600, 900, 240, 0), w.heartRateZoneSeconds)
        assertEquals(95, w.avgStrideCm)
        assertEquals(120, w.maxStrideCm)
        assertEquals(70, w.minStrideCm)

        assertEquals(2, w.samples.size)
        val a = w.samples[0]
        assertEquals(LocalDateTime.of(2026, 10, 15, 8, 30).atZone(zone).toInstant().toEpochMilli(), a.time)
        assertEquals(130, a.heartRate)
        assertEquals(390, a.paceSecondsPerKm)
        assertEquals(160, a.cadence)
        assertEquals(21.028511, a.latitude!!, 1e-6)
        assertEquals(105.804817, a.longitude!!, 1e-6)
        val c = w.samples[1]
        assertEquals(a.time + 10_000, c.time) // mẫu thứ 3 (chỉ số 2) × 5 s
        assertEquals(-33.856784, c.latitude!!, 1e-6)
        assertEquals(151.215297, c.longitude!!, 1e-6)
        assertEquals(2, w.track.size)
    }

    @Test fun withoutDetailFlagPayloadStartsAtSeq2AsHeartRate() {
        // Không có F7 0x80: gói 2 trở đi là chuỗi HR 1 byte (kiểu 0), app chỉ giữ 40 < HR < 200.
        val packets = listOf(seq0, seq1, hex("FD 00 02 50 00 FF 64"), hex("FD FD"))
        val w = Ute.parseWorkouts(packets, zone, endIsTimestamp = true, hasDetail = false).single()
        assertEquals(listOf(80, 100), w.samples.map { it.heartRate })
        assertEquals(listOf(0L, 15_000L), w.samples.map { it.time - w.start })
        assertNull(w.heartRateZoneSeconds)
        assertTrue(w.track.isEmpty())
    }

    @Test fun otherFormats() {
        val t0 = 1_000_000L
        // kiểu 3: tốc độ 25,50 km/h + toạ độ
        val f3 = UteWorkoutRecord.samples(3, byteArrayOf(120, 25, 50, 0) + s32(10_500_000) + s32(106_700_000), t0, 2)
        assertEquals(25.5, f3.single().speedKmh!!, 1e-9)
        assertEquals(10.5, f3.single().latitude!!, 1e-9)
        // kiểu 5: pace = phút × 60 + giây
        val f5 = UteWorkoutRecord.samples(5, byteArrayOf(150.toByte(), 5, 20, 170.toByte()) + s32(1) + s32(2), t0, 1)
        assertEquals(320, f5.single().paceSecondsPerKm)
        assertEquals(150, f5.single().heartRate)
        // kiểu 2/6: 4 byte, không toạ độ
        assertEquals(400, UteWorkoutRecord.samples(6, byteArrayOf(100, 6, 40, 150.toByte()), t0, 1).single().paceSecondsPerKm)
        // kiểu 4: tốc độ
        assertEquals(18.05, UteWorkoutRecord.samples(4, byteArrayOf(110, 18, 5, 0), t0, 1).single().speedKmh!!, 1e-9)
        // kiểu 7: 4 byte, HR + nhịp bước ở byte 1
        assertEquals(88, UteWorkoutRecord.samples(7, byteArrayOf(120, 88, 0, 0), t0, 1).single().cadence)
        // kiểu lạ / dữ liệu lẻ byte: không crash
        assertTrue(UteWorkoutRecord.samples(9, ByteArray(24), t0, 1).isEmpty())
        assertEquals(1, UteWorkoutRecord.samples(1, ByteArray(12) { 100 } + ByteArray(5), t0, 1).size)
    }

    @Test fun intervalOver220() {
        val p = seq1.copyOf().also { it[17] = 225.toByte() }
        assertEquals(5, UteWorkoutRecord.intervalSeconds(p))
        assertNull(UteWorkoutRecord.intervalSeconds(seq1.copyOf().also { it[17] = 0 }))
    }
}
