package com.smartwear.veepoo

import com.smartwear.core.Contact
import com.smartwear.core.WeatherCondition
import com.smartwear.core.WeatherForecast
import com.smartwear.core.Workout
import com.smartwear.veepoo.Veepoo.op
import com.smartwear.veepoo.Veepoo.u
import java.time.LocalDateTime
import java.time.ZoneId

/** Bài tập (`D3`/`D4`/`DA`), thời tiết (`C8`), danh bạ (`72`). */
object VeepooData {

    // ---------- Bài tập ----------

    /** `D3 01` (20 byte): CRC từng khe bài tập (`jf/k2.java:51-58`). */
    val WORKOUT_CRC = Veepoo.padded(20, 0xD3, 0x01)

    /** `D3 ok 01 crc0 crc1 …` — CRC LE16 từng khe từ byte 3 (`k2.java:85-100`); `D3 00` = lỗi. CRC 0 = khe trống. */
    fun parseWorkoutCrc(p: ByteArray, slots: Int): List<Int>? {
        if (p.op != 0xD3 || p.size < 3 || u(p, 1) == 0 || u(p, 1) == 2) return null
        return (0 until slots).map { i -> if (3 + i * 2 + 1 < p.size) Veepoo.le16(p, 3 + i * 2) else 0 }
    }

    /** `D4 khe` (20 byte, khe 0..sportModelDay−1, `jf/j2.java:117-130`). */
    fun workoutRequest(slot: Int) = Veepoo.padded(20, 0xD4, slot)

    /** Gói `D4 curLo curHi totLo totHi …`: gói cuối khi hiện tại = tổng (`j2.java:150-165`). */
    fun isWorkoutLast(p: ByteArray) = p.op == 0xD4 && p.size >= 5 && Veepoo.le16(p, 1) == Veepoo.le16(p, 3)

    /**
     * Một bài tập ghi trên vòng tay. Hai định dạng (`j2.java`):
     * - kiểu thể thao 4/5/6 (đồng hồ GPS, nhẫn — GE54 = 5): bỏ 5 byte đầu mỗi gói rồi ghép; `A1 len` = đầu bài: giờ bắt đầu / kết thúc
     *   epoch giây LE32 ở byte 4 / 8, thời lượng giây LE32 ở 12, bước / quãng đường / kcal / số lần LE32 ở 18 / 22 / 26 / 30, nhịp tim
     *   max / tb / min ở 34 / 35 / 36, pace max / tb / min LE16 ở 37 / 39 / 41; byte 17 = độ dài phần đầu `b`, môn thể thao LE16 ở `b`+31.
     * - kiểu cổ điển: 3 gói đầu, mỗi gói 14 byte từ byte 6 ghép 42 byte: năm BE… (dùng [parseClassicHeader]).
     * Kiểm trên GE54 (19/10/2026, 3 bài tập): `A1 45 B1 0C start end duration B2 25 bước m cal số-lần maxHR avgHR minHR pace…`; pace tb
     * 736 s/km × 3330 s ⇒ 4,5 km khớp quãng đường 4471 m; kcal thô là cal.
     */
    fun parseWorkout(packets: List<ByteArray>, sportType: Int, zone: ZoneId): Workout? =
        if (sportType == 4 || sportType == 5 || sportType == 6) parseTlvWorkout(packets) else parseClassicHeader(packets, zone)

    fun parseTlvWorkout(packets: List<ByteArray>): Workout? {
        val out = java.io.ByteArrayOutputStream()
        for (p in packets) if (p.op == 0xD4 && p.size > 5) out.write(p, 5, p.size - 5)
        val b = out.toByteArray()
        if (b.size < 43 || u(b, 0) != 0xA1) return null
        val len = u(b, 1) + 2
        if (len > b.size) return null
        val start = Veepoo.le32(b, 4) * 1000
        val end = Veepoo.le32(b, 8) * 1000
        if (start <= 0 || end < start) return null
        val hl = u(b, 17)
        val type = if (hl + 32 < len) Veepoo.le16(b, hl + 31) else 0
        return Workout(
            type = type,
            name = sportName(type),
            start = start,
            end = end,
            activeSeconds = Veepoo.le32(b, 12).toInt(),
            steps = Veepoo.le32(b, 18).toInt(),
            distanceMeters = Veepoo.le32(b, 22).toInt(),
            // Thô là cal (GE54: 180866 cho 55 phút đi bộ ⇒ 181 kcal); Workout.calories là kcal.
            calories = (Veepoo.le32(b, 26) / 1000).toInt(),
            maxHeartRate = u(b, 34).takeIf { it > 0 },
            avgHeartRate = u(b, 35).takeIf { it > 0 },
            minHeartRate = u(b, 36).takeIf { it > 0 },
            paceSecondsPerKm = Veepoo.le16(b, 39).takeIf { it > 0 },
        )
    }

    /**
     * Đầu bài tập cổ điển (`j2.java:170-235`): 42 byte = byte 6..19 của 3 gói đầu. Năm bắt đầu LE16 ở 1–2, M D h m s ở 3–7; năm kết thúc
     * LE16 ở 8–9, M D h m s ở 10–14; bước LE32 15–18, quãng đường LE32 19–22 (÷1000 = km), kcal LE32 23–26 (÷1000), số lần 27–30,
     * môn 38 (mã ghép chuỗi hex `[2]+[1]` = LE). Chưa kiểm trên thiết bị thật.
     */
    fun parseClassicHeader(packets: List<ByteArray>, zone: ZoneId): Workout? {
        val d = packets.filter { it.op == 0xD4 && it.size >= 20 }
        if (d.size < 3) return null
        val h = ByteArray(42).also { out -> for (i in 0 until 3) d[i].copyInto(out, i * 14, 6, 20) }
        fun t(yearAt: Int) = runCatching {
            LocalDateTime.of(Veepoo.le16(h, yearAt), u(h, yearAt + 2), u(h, yearAt + 3), u(h, yearAt + 4), u(h, yearAt + 5), u(h, yearAt + 6))
        }.getOrNull()
        val s = t(1) ?: return null
        val e = LocalDateTime.of(Veepoo.le16(h, 8), u(h, 10), u(h, 11), u(h, 12), u(h, 13), u(h, 14))
        val type = u(h, 38)
        val startMs = s.atZone(zone).toInstant().toEpochMilli()
        val endMs = e.atZone(zone).toInstant().toEpochMilli()
        return Workout(
            type = type, name = sportName(type), start = startMs, end = endMs,
            activeSeconds = ((endMs - startMs) / 1000).toInt(),
            steps = Veepoo.le32(h, 15).toInt(),
            distanceMeters = Veepoo.le32(h, 19).toInt(),
            calories = (Veepoo.le32(h, 23) / 1000).toInt(),
        )
    }

    /**
     * Tên môn theo `ESportType` của SDK (`com/veepoo/protocol/model/enums/ESportType.java`, cùng mã cho `D4` và `DA`): 1 chạy ngoài trời,
     * 2 đi bộ ngoài trời, 3 chạy trong nhà, 4 đi bộ trong nhà, 5 leo núi đường dài (HIKE), … 16 yoga (một phần, sửa 19/10/2026; trước đó
     * bảng lệch, 1 bị gọi là "Leo núi").
     */
    fun sportName(type: Int): String = SPORT_NAMES[type] ?: "Bài tập ($type)"

    val SPORT_NAMES = mapOf(
        1 to "Chạy ngoài trời", 2 to "Đi bộ ngoài trời", 3 to "Chạy trong nhà", 4 to "Đi bộ trong nhà", 5 to "Đi bộ đường dài",
        6 to "Máy chạy bộ", 7 to "Đạp xe ngoài trời", 8 to "Đạp xe trong nhà", 9 to "Máy elip", 10 to "Máy chèo thuyền", 11 to "Leo núi",
        12 to "Bơi", 13 to "Gập bụng", 14 to "Trượt tuyết", 15 to "Nhảy dây", 16 to "Yoga", 17 to "Bóng bàn", 18 to "Bóng rổ",
        19 to "Bóng chuyền", 20 to "Bóng đá", 21 to "Cầu lông", 22 to "Quần vợt", 23 to "Leo cầu thang", 24 to "Thể hình", 25 to "Cử tạ",
        27 to "Quyền anh", 31 to "Nhảy múa", 32 to "HIIT", 33 to "Leo vách đá", 45 to "Marathon", 46 to "Hít đất",
    )

    /** `DA 01 typeLE16 ctrl` điều khiển buổi tập từ app (`jf/h2.java:28-80`): 1 bắt đầu, 2 tạm dừng, 3 tiếp tục, 4 kết thúc. */
    fun workoutControl(type: Int, ctrl: Int) = Veepoo.padded(20, 0xDA, 0x01, type and 0xFF, (type shr 8) and 0xFF, ctrl)

    // ---------- Thời tiết ----------

    /** Mã thời tiết Veepoo (bảng đổi mã QWeather → thiết bị `home/other/utils/WeatherStatueChange.java`). */
    fun weatherCode(c: WeatherCondition): Int = when (c) {
        WeatherCondition.SUNNY -> 1
        WeatherCondition.CLOUDY -> 5
        WeatherCondition.OVERCAST -> 13
        WeatherCondition.SHOWER -> 17
        WeatherCondition.THUNDERSTORM -> 18
        WeatherCondition.SLEET -> 73
        WeatherCondition.LIGHT_RAIN -> 33
        WeatherCondition.HEAVY_RAIN -> 49
        WeatherCondition.SNOW -> 85
        WeatherCondition.DUST -> 105
        WeatherCondition.FOG -> 113
        WeatherCondition.WIND -> 140
    }

    private fun cToF(c: Int) = (c * 9 + 160) / 5

    /**
     * Thời tiết đầy đủ (`jf/u2.java:103-360`, `util/t.java`): `F0 lenLE16 { A1 02 crcLE, A2 n thành-phố, A3 01 nguồn, A4 05 yy M D h m,
     * A6 lenLE16 { C0 n { C1 03 yy M D, C2 04 ±maxF ±minF, C3 04 ±maxC ±minC, C4 01 uv, C5 01 ngày, C6 01 đêm, C7 02 gió, C8 02 tầm-nhìn } … } }`
     * (dấu: 1 = dương, 0 = âm/0), cắt `C8 04 total idx` + 16 byte. App gốc gửi cách nhau 50 ms. [crc] = mã nhận dạng bản tin (thiết bị trả
     * lại trong `C8 02` để app biết đã có bản mới).
     */
    fun weatherPackets(f: WeatherForecast, now: LocalDateTime, crc: Int): List<ByteArray> {
        fun signed(v: Int) = byteArrayOf(if (v > 0) 1 else 0, minOf(kotlin.math.abs(v), 255).toByte())
        val days = java.io.ByteArrayOutputStream()
        f.days.take(7).forEachIndexed { i, d ->
            val date = now.toLocalDate().plusDays(i.toLong())
            val item = java.io.ByteArrayOutputStream()
            item.write(byteArrayOf(0xC1.toByte(), 3, (date.year - 2000).toByte(), date.monthValue.toByte(), date.dayOfMonth.toByte()))
            item.write(byteArrayOf(0xC2.toByte(), 4) + signed(cToF(d.highC)) + signed(cToF(d.lowC)))
            item.write(byteArrayOf(0xC3.toByte(), 4) + signed(d.highC) + signed(d.lowC))
            item.write(byteArrayOf(0xC4.toByte(), 1, (if (i == 0) f.uvIndex else 0).coerceIn(0, 255).toByte()))
            item.write(byteArrayOf(0xC5.toByte(), 1, weatherCode(d.condition).toByte()))
            item.write(byteArrayOf(0xC6.toByte(), 1, weatherCode(d.condition).toByte()))
            item.write(byteArrayOf(0xC7.toByte(), 2, 1, 3))
            item.write(byteArrayOf(0xC8.toByte(), 2, 0x10, 0x27)) // tầm nhìn 10 km
            val b = item.toByteArray()
            days.write(0xC0); days.write(b.size); days.write(b)
        }
        val body = java.io.ByteArrayOutputStream()
        body.write(byteArrayOf(0xA1.toByte(), 2, (crc and 0xFF).toByte(), ((crc shr 8) and 0xFF).toByte()))
        val city = VeepooPhone.utf8Prefix(f.city, 60)
        if (city.isNotEmpty()) { body.write(0xA2); body.write(city.size); body.write(city) }
        body.write(byteArrayOf(0xA3.toByte(), 1, 0))
        body.write(byteArrayOf(0xA4.toByte(), 5, (now.year - 2000).toByte(), now.monthValue.toByte(), now.dayOfMonth.toByte(), now.hour.toByte(), now.minute.toByte()))
        val d = days.toByteArray()
        if (d.isNotEmpty()) { body.write(0xA6); body.write(d.size and 0xFF); body.write(d.size shr 8); body.write(d) }
        val b = body.toByteArray()
        val all = byteArrayOf(0xF0.toByte(), (b.size and 0xFF).toByte(), (b.size shr 8).toByte()) + b
        val total = (all.size + 15) / 16
        return (1..total).map { idx ->
            ByteArray(20).also {
                it[0] = 0xC8.toByte(); it[1] = 0x04; it[2] = total.toByte(); it[3] = idx.toByte()
                val from = (idx - 1) * 16
                all.copyInto(it, 4, from, minOf(from + 16, all.size))
            }
        }
    }

    /** `C8 03 bật đơn-vị` bật/tắt hiển thị thời tiết (đơn vị 0 °C, 1 °F) (`u2.java:420-431`). */
    fun weatherSwitch(on: Boolean, fahrenheit: Boolean) = Veepoo.padded(20, 0xC8, 0x03, if (on) 1 else 0, if (fahrenheit) 1 else 0)

    // ---------- Danh bạ ----------

    /**
     * Một liên hệ (`jf/p.java:97-150`): `A0 lenLE16 A1 01 id A2 n tên(≤20 byte) A3 n số(≤22 byte) [A4 01 sos]` (len gồm 3 byte đầu), cắt
     * `72 01 idx total` + 16 byte.
     */
    fun contactPackets(id: Int, c: Contact, sos: Boolean? = null): List<ByteArray> {
        val name = VeepooPhone.utf8Prefix(c.name, 20)
        val number = VeepooPhone.utf8Prefix(c.phone.filter { it.isDigit() || it == '+' || it == '*' || it == '#' }, 22)
        val tlv = java.io.ByteArrayOutputStream()
        tlv.write(byteArrayOf(0xA1.toByte(), 1, id.toByte()))
        tlv.write(0xA2); tlv.write(name.size); tlv.write(name)
        tlv.write(0xA3); tlv.write(number.size); tlv.write(number)
        if (sos != null) tlv.write(byteArrayOf(0xA4.toByte(), 1, if (sos) 1 else 0))
        val b = tlv.toByteArray()
        val n = b.size + 3
        val all = byteArrayOf(0xA0.toByte(), (n and 0xFF).toByte(), (n shr 8).toByte()) + b
        return VeepooPhone.framed(0x72, 0x01, all)
    }

    /** `72 04 id`: xoá một liên hệ (`p.java:180-190`). */
    fun contactDelete(id: Int) = Veepoo.padded(20, 0x72, 0x04, id)
}
