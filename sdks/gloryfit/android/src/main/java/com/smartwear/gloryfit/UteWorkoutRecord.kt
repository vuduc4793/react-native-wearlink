package com.smartwear.gloryfit

import com.smartwear.core.Workout
import com.smartwear.core.WorkoutSample

/**
 * Phần chi tiết của một bản ghi bài tập `FD FA` (gói số ≥ 2), theo `BluetoothLeService.dealWithSportMode` +
 * `saveMultipleSportsData` (app GloryFit 4.0.12, `:7340-7556`) và `MultipleSportsModesUtils` (`:146-213`):
 *
 * - Đồng hồ có F7 `0x80` (bit "GPS thể thao" b1.7; Y25 và HT43 đều có):
 *   - gói 2: thời gian 5 vùng nhịp tim, mỗi vùng u24 BE ở byte 3, 6, 9, 12, 15 (giây); sải bước TB @18, max @19.
 *   - gói 3: sải bước min @3, pace max @4–5 và min @6–7 (phút, giây), **kiểu dữ liệu mẫu @8**. Byte 9–19 chỉ có nghĩa khi
 *     F9 `0x10000` (bơi/chèo; Y25, HT43 không có), bỏ qua.
 *   - gói ≥ 4: dữ liệu mẫu.
 * - Không có F7 `0x80`: gói ≥ 2 là dữ liệu mẫu, kiểu 0.
 *
 * Dữ liệu mẫu = nối phần từ byte 3 của các gói theo đúng thứ tự số gói (`copyByteArrayAtEnd`). Mẫu thứ i ở
 * `start + i × khoảng mẫu` (byte 17 của gói 1, > 220 thì trừ 220). Kiểu mẫu:
 *
 * | Kiểu | Byte/mẫu | Nội dung |
 * |---|---|---|
 * | 0 | 1 | HR (app chỉ giữ 40 < HR < 200) |
 * | 1 | 12 | HR, pace phút, pace giây, nhịp bước, lat s32 BE / 1e6, lon s32 BE / 1e6 |
 * | 2, 6 | 4 | HR, pace phút, pace giây, nhịp bước |
 * | 3 | 12 | HR, tốc độ nguyên, tốc độ phần trăm (km/h), (bỏ), lat, lon |
 * | 4 | 4 | HR, tốc độ nguyên, tốc độ phần trăm |
 * | 5 | 12 | như kiểu 1 (pace = phút × 60 + giây) |
 * | 7 | 4 | HR, nhịp bước |
 *
 * Chỉ kiểu 1, 3, 5 có toạ độ. Kiểu lạ thì bỏ dữ liệu mẫu, giữ phần tổng. Chưa có bản ghi thật có GPS để đối chiếu.
 */
internal object UteWorkoutRecord {

    /** Có F7 `0x80`: gói 2, 3 là gói tổng hợp, mẫu bắt đầu từ gói 4. */
    fun firstSampleSeq(hasDetail: Boolean) = if (hasDetail) 4 else 2

    /** Khoảng mẫu (giây) ở byte 17 của gói 1 (`bleTimeInterval`). */
    fun intervalSeconds(seq1: ByteArray): Int? {
        if (seq1.size < 18) return null
        val v = Ute.u(seq1, 17)
        return (if (v > 220) v - 220 else v).takeIf { it > 0 }
    }

    /** Gói 2: vùng nhịp tim + sải bước TB/max. */
    fun applySeq2(w: Workout, p: ByteArray): Workout {
        if (p.size < 20) return w
        val zones = listOf(3, 6, 9, 12, 15).map { Ute.be24(p, it) }
        return w.copy(
            heartRateZoneSeconds = zones,
            avgStrideCm = Ute.u(p, 18).takeIf { it > 0 },
            maxStrideCm = Ute.u(p, 19).takeIf { it > 0 },
        )
    }

    /** Gói 3: sải bước min và kiểu dữ liệu mẫu (byte 8). */
    fun applySeq3(w: Workout, p: ByteArray): Pair<Workout, Int?> {
        if (p.size < 9) return w to null
        return w.copy(minStrideCm = Ute.u(p, 3).takeIf { it > 0 }) to Ute.u(p, 8)
    }

    /** Số byte mỗi mẫu theo kiểu; null = kiểu chưa biết. */
    fun sampleSize(format: Int): Int? = when (format) {
        0 -> 1
        1, 3, 5 -> 12
        2, 4, 6, 7 -> 4
        else -> null
    }

    /** Giải mã dữ liệu mẫu [data] (đã nối) theo [format]. Kiểu lạ ⇒ rỗng. Mẫu không có gì (HR 0, không toạ độ) bị bỏ. */
    fun samples(format: Int, data: ByteArray, start: Long, intervalSeconds: Int): List<WorkoutSample> {
        val size = sampleSize(format) ?: return emptyList()
        val out = ArrayList<WorkoutSample>(data.size / size)
        for (i in 0 until data.size / size) {
            val o = i * size
            val t = start + i * intervalSeconds * 1000L
            fun b(k: Int) = Ute.u(data, o + k)
            fun hr() = b(0).takeIf { it in 1..254 }
            fun coord(k: Int): Double = s32(data, o + k) / 1_000_000.0
            val s = when (format) {
                0 -> b(0).takeIf { it in 41..199 }?.let { WorkoutSample(t, heartRate = it) }
                1, 5 -> withCoords(WorkoutSample(t, hr(), pace(b(1), b(2)), cadence = b(3).takeIf { it > 0 }), coord(4), coord(8))
                2, 6 -> WorkoutSample(t, hr(), pace(b(1), b(2)), cadence = b(3).takeIf { it > 0 })
                3 -> withCoords(WorkoutSample(t, hr(), speedKmh = speed(b(1), b(2))), coord(4), coord(8))
                4 -> WorkoutSample(t, hr(), speedKmh = speed(b(1), b(2)))
                7 -> WorkoutSample(t, hr(), cadence = b(1).takeIf { it > 0 })
                else -> null
            }
            if (s != null && !s.isEmpty()) out += s
        }
        return out
    }

    /**
     * Gắn phần chi tiết vào bài [w]: [detail] là các gói số ≥ 2 của bài, theo thứ tự nhận. Gói nhảy số (gói `FD` khác lẫn
     * vào luồng, vd. `FD 01 AA type` xin GPS điện thoại) bị bỏ; dữ liệu mẫu chỉ lấy chuỗi gói liền số từ [firstSampleSeq].
     */
    fun withDetail(w: Workout, detail: List<ByteArray>, interval: Int?, hasDetail: Boolean): Workout {
        var out = w.copy(sampleIntervalSeconds = interval)
        var format = 0
        val first = firstSampleSeq(hasDetail)
        var next = first
        var data = ByteArray(0)
        for (p in detail) {
            if (p.size < 3) continue
            val seq = Ute.be16(p, 1)
            when {
                hasDetail && seq == 2 -> out = applySeq2(out, p)
                hasDetail && seq == 3 -> applySeq3(out, p).let { (x, f) -> out = x; if (f != null) format = f }
                seq == next -> { data += p.copyOfRange(3, p.size); next++ }
            }
        }
        if (data.isEmpty() || interval == null) return out
        return out.copy(samples = samples(format, data, w.start, interval))
    }

    private fun pace(min: Int, sec: Int): Int? = (min * 60 + sec).takeIf { it > 0 }

    private fun speed(whole: Int, hundredths: Int): Double? = (whole + hundredths / 100.0).takeIf { it > 0 }

    /** Toạ độ (0, 0) hoặc ngoài khoảng = chưa bắt được GPS ở mẫu đó. */
    private fun withCoords(s: WorkoutSample, lat: Double, lon: Double): WorkoutSample =
        if ((lat == 0.0 && lon == 0.0) || lat !in -90.0..90.0 || lon !in -180.0..180.0) s else s.copy(latitude = lat, longitude = lon)

    private fun WorkoutSample.isEmpty() =
        heartRate == null && paceSecondsPerKm == null && speedKmh == null && cadence == null && latitude == null

    private fun s32(p: ByteArray, i: Int): Int =
        (Ute.u(p, i) shl 24) or (Ute.u(p, i + 1) shl 16) or (Ute.u(p, i + 2) shl 8) or Ute.u(p, i + 3)
}
