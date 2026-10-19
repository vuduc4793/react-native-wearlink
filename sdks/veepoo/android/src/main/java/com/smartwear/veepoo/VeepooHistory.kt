package com.smartwear.veepoo

import com.smartwear.core.ActivityTotals
import com.smartwear.core.SleepSegment
import com.smartwear.core.SleepSession
import com.smartwear.core.SleepStage
import com.smartwear.veepoo.Veepoo.op
import com.smartwear.veepoo.Veepoo.u
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneId

/** Parser lịch sử Veepoo (§6.4): bước hôm nay `A8`/`D8`, 5 phút `DF` (TLV), ngủ `E0` (thường + chính xác). */
object VeepooHistory {

    // ---------- Bước hôm nay ----------

    val STEPS_A8 = Veepoo.bytes(0xA8, 0x00)
    val STEPS_D8 = Veepoo.bytes(0xD8, 0x00)

    /** `A8 s3 s2 s1 s0 ok …`: bước uint32 **BE** ở byte 1–4, chỉ hợp lệ khi byte 5 = 0; `FFFFFFFF` = 0 (`jf/l2.java:149-182`). */
    fun parseA8(p: ByteArray): Int? {
        if (p.op != 0xA8 || p.size < 6 || u(p, 5) != 0) return null
        val v = Veepoo.be32(p, 1)
        return if (v == 0xFFFFFFFFL) 0 else v.toInt()
    }

    /**
     * `D8 ?? bước(LE32) quãng-đường-m(LE32) kcal×10(LE32)` (`jf/i0.java:378-391`). [ActivityTotals.calories] theo quy ước core / app / RN
     * là **cal** (UI chia 1000), nên kcal×10 × 100.
     */
    fun parseD8(p: ByteArray): ActivityTotals? {
        if (p.op != 0xD8 || p.size < 14) return null
        return ActivityTotals(
            steps = Veepoo.le32(p, 2).toInt(),
            calories = (Veepoo.le32(p, 10) * 100).toInt(),
            distanceMeters = Veepoo.le32(p, 6).toInt(),
        )
    }

    // ---------- 5 phút DF ----------

    /** `DF posLo posHi day 00…` (20 byte, `jf/p1.java:1199-1206`); pos bắt đầu từ 1, day 0 = hôm nay. */
    fun dfRequest(day: Int, position: Int = 1): ByteArray =
        Veepoo.padded(20, 0xDF, position and 0xFF, (position shr 8) and 0xFF, day)

    /** Gói kết thúc luồng DF: byte 1 = byte 2 = FF. */
    fun isDfEnd(p: ByteArray) = p.op == 0xDF && p.size >= 3 && u(p, 1) == 0xFF && u(p, 2) == 0xFF

    /**
     * Gói đầu khối DF (`k0.b`, byte 3 = 0): `[1..2]` số khối LE, `[4..5]` tổng khối LE, `[6]` số gói, `[7]` ngày, `[8]` kiểu đọc,
     * `[9]` kiểu dữ liệu, `[10]` số byte hợp lệ, `[11..12]` CRC-16/MODBUS LE, `[13]` độ dài mỗi gói (originProtocol 5; khác = 20).
     */
    data class DfHeader(
        val block: Int, val totalBlocks: Int, val packets: Int, val day: Int, val readType: Int, val dataType: Int,
        val validBytes: Int, val crc: Int, val packetLength: Int,
    )

    fun parseDfHeader(p: ByteArray, protocol5: Boolean = true): DfHeader? {
        if (p.op != 0xDF || p.size < 14 || u(p, 3) != 0 || isDfEnd(p)) return null
        return DfHeader(
            block = Veepoo.le16(p, 1), totalBlocks = Veepoo.le16(p, 4), packets = u(p, 6), day = u(p, 7), readType = u(p, 8),
            dataType = u(p, 9), validBytes = u(p, 10), crc = Veepoo.le16(p, 11),
            packetLength = if (protocol5 && u(p, 13) > 4) u(p, 13) else 20,
        )
    }

    /** Một khối 5 phút đã ghép và kiểm CRC. [crcOk] = false nếu CRC sai (vẫn trả để log). */
    class DfBlock(val header: DfHeader, val payload: ByteArray, val crcOk: Boolean)

    /**
     * Ghép các gói DF thành khối: gói đầu (`[3]` = 0) rồi các gói dữ liệu cùng số khối (`[3]` = 1..n), mỗi gói góp byte 4..độ-dài-gói,
     * cắt còn [DfHeader.validBytes] rồi kiểm CRC. (Mã gốc `p1.a()` bị jadx dịch sai; luồng này dựng lại từ trường header.)
     */
    fun assembleDf(packets: List<ByteArray>, protocol5: Boolean = true): List<DfBlock> {
        val out = mutableListOf<DfBlock>()
        var header: DfHeader? = null
        var data = java.io.ByteArrayOutputStream()
        fun flush() {
            val h = header ?: return
            val bytes = data.toByteArray()
            if (bytes.size >= h.validBytes) {
                val payload = bytes.copyOf(h.validBytes)
                out += DfBlock(h, payload, Veepoo.crc16(payload) == h.crc)
            }
            header = null
            data = java.io.ByteArrayOutputStream()
        }
        for (p in packets) {
            if (p.op != 0xDF || p.size < 4) continue
            if (isDfEnd(p)) { flush(); continue }
            val h = parseDfHeader(p, protocol5)
            if (h != null) {
                flush()
                header = h
                continue
            }
            val cur = header ?: continue
            if (Veepoo.le16(p, 1) != cur.block) continue
            val end = minOf(cur.packetLength, p.size)
            if (end > 4) data.write(p, 4, end - 4)
        }
        flush()
        return out
    }

    /**
     * Một bản ghi 5 phút từ TLV trong khối DF (`p1.java:400-504`): `B1` tháng, ngày, giờ, phút, `B2` vận động (bước, lượng vận động,
     * quãng đường m, kcal×10: BE16; tư thế, đeo), `B4` nhịp tim theo phút (PPG, 5 giá trị), `B8` huyết áp (cao, thấp), `B9` SpO2
     * (5 giá trị đầu), `B7` HRV (byte 0 kiểu + 50 RR), `C1` stress, `BF` MET ÷10, `C3` nhiệt độ (LE16 nền, LE16 cơ thể, ÷10).
     */
    data class FiveMinute(
        val time: LocalDateTime,
        val steps: Int = 0,
        val sport: Int = 0,
        val distanceMeters: Int = 0,
        val calories10: Int = 0,
        val wear: Int? = null,
        val heartRates: List<Int> = emptyList(),
        val systolic: Int? = null,
        val diastolic: Int? = null,
        val spo2: List<Int> = emptyList(),
        val stress: Int? = null,
        val met: Double? = null,
        val temperature: Double? = null,
        /** Đường huyết mmol/L (tag `BE`, LE16 ÷100; bloodGlucoseType 5: 13 bit thấp, `p1.java:665-690`). */
        val glucose: Double? = null,
        val hrv: List<Int> = emptyList(),
        /** 50 khoảng RR thô của tag `B7` (đơn vị 10 ms; 30..210 hợp lệ), 10 giá trị mỗi phút — dùng vẽ Lorenz. */
        val rr: List<Int> = emptyList(),
        /** Thành phần máu tag `C2` (null nếu toàn 0). */
        val blood: VeepooHealth.BloodValues? = null,
        val tags: Set<Int> = emptySet(),
    )

    /** TLV 1 byte tag + 1 byte độ dài. Tag lạ dừng như mã gốc (C0 / mặc định ⇒ `z10 = false`). */
    fun parseTlv(payload: ByteArray): Map<Int, ByteArray> {
        val out = linkedMapOf<Int, ByteArray>()
        var i = 0
        while (i + 2 <= payload.size) {
            val tag = u(payload, i)
            if (tag !in 0xB1..0xBF && tag !in 0xC1..0xC3) break
            val len = u(payload, i + 1)
            if (i + 2 + len > payload.size) break
            out[tag] = payload.copyOfRange(i + 2, i + 2 + len)
            i += 2 + len
        }
        return out
    }

    fun parseFiveMinute(payload: ByteArray, date: LocalDate, glucoseRiskBits: Boolean = false): FiveMinute? {
        val t = parseTlv(payload)
        val time = t[0xB1]?.takeIf { it.size >= 4 && (it[0].toInt() != 0 || it[1].toInt() != 0) } ?: return null
        val hour = u(time, 2)
        val minute = u(time, 3)
        if (hour > 23 || minute > 59) return null
        // B1 = tháng, ngày, giờ, phút (GE54: `0A 13 0F 2D` = 19/10 15:45); ngày đọc chỉ dùng để suy năm.
        val at = dateNear(date, u(time, 0), u(time, 1), hour, minute) ?: date.atTime(hour, minute)
        val sport = t[0xB2]?.takeIf { it.size >= 10 }
        fun be(b: ByteArray, i: Int) = Veepoo.be16(b, i)
        val bp = t[0xB8]?.takeIf { it.size >= 2 && u(it, 0) > 0 && u(it, 1) > 0 }
        val temp = t[0xC3]?.takeIf { it.size >= 4 }?.let { Veepoo.le16(it, 2) }?.takeIf { it in 120..480 }
        val hrvRaw = t[0xB7]?.takeIf { it.size >= 51 }
        return FiveMinute(
            time = at,
            steps = sport?.let { be(it, 0) } ?: 0,
            sport = sport?.let { be(it, 2) } ?: 0,
            distanceMeters = sport?.let { be(it, 4) } ?: 0,
            calories10 = sport?.let { be(it, 6) } ?: 0,
            wear = sport?.let { u(it, 9) },
            heartRates = t[0xB4]?.map { it.toInt() and 0xFF }.orEmpty(),
            systolic = bp?.let { u(it, 0) },
            diastolic = bp?.let { u(it, 1) },
            spo2 = t[0xB9]?.take(5)?.map { it.toInt() and 0xFF }.orEmpty(),
            stress = t[0xC1]?.takeIf { it.isNotEmpty() }?.let { u(it, 0) }?.takeIf { it > 0 },
            met = t[0xBF]?.takeIf { it.isNotEmpty() }?.let { u(it, 0) / 10.0 }?.takeIf { it > 0 },
            temperature = temp?.let { it / 10.0 },
            glucose = t[0xBE]?.takeIf { it.size >= 2 }?.let { Veepoo.le16(it, 0).let { v -> if (glucoseRiskBits) v and 0x1FFF else v } }
                ?.takeIf { it in 100..3000 }?.let { it / 100.0 },
            hrv = hrvRaw?.let { hrv5(it) }.orEmpty(),
            rr = hrvRaw?.let { b -> (1..50).map { u(b, it) } }.orEmpty(),
            blood = t[0xC2]?.let { VeepooHealth.BloodValues.parseDf(it) },
            tags = t.keys,
        )
    }

    /** HRV 5 giá trị (mỗi phút) từ 50 RR trong tag `B7`, như `p1.java:620-660`: trung bình |RR(i) − RR(i−1)| × 10, mod 211. */
    fun hrv5(b7: ByteArray): List<Int> {
        val rr = (1..50).map { u(b7, it) }
        return (0 until 5).map { g ->
            var sum = 0
            var n = 0
            var prev = -1
            for (i in g * 10 until g * 10 + 10) {
                val v = rr[i]
                if (v in 30..210) {
                    if (prev != -1) { sum += kotlin.math.abs(prev - v); n++ }
                    prev = v
                }
            }
            if (n > 0) Math.round((sum * 10f) / n) % 211 else 0
        }
    }

    /** Bản ghi 5 phút → chuỗi lịch sử chuẩn (STEPS extra "calories" cal (như GloryFit) / "distance" m, BLOOD_SUGAR mmol/L, HEART_RATE và SPO2 theo phút, BLOOD_PRESSURE
     *  extra "diastolic", STRESS, HRV theo phút (extra "rr0".."rr9" ms), TEMPERATURE, MET, URIC_ACID μmol/L, BLOOD_LIPIDS mmol/L (giá trị = cholesterol
     *  toàn phần, extra "totalCholesterol"/"triglycerides"/"hdl"/"ldl")). */
    fun toSeries(records: List<FiveMinute>, zone: ZoneId): Map<com.smartwear.core.Capability, List<com.smartwear.core.HistoryPoint>> {
        val out = mutableMapOf<com.smartwear.core.Capability, MutableList<com.smartwear.core.HistoryPoint>>()
        fun add(cap: com.smartwear.core.Capability, p: com.smartwear.core.HistoryPoint) { out.getOrPut(cap) { mutableListOf() } += p }
        for (r in records.distinctBy { it.time }.sortedBy { it.time }) {
            val ts = r.time.atZone(zone).toInstant().toEpochMilli()
            add(com.smartwear.core.Capability.STEPS, com.smartwear.core.HistoryPoint(ts, r.steps.toDouble(),
                mapOf("calories" to r.calories10 * 100.0, "distance" to r.distanceMeters.toDouble())))
            r.glucose?.let { add(com.smartwear.core.Capability.BLOOD_SUGAR, com.smartwear.core.HistoryPoint(ts, it)) }
            r.heartRates.forEachIndexed { i, v -> if (v in 30..220) add(com.smartwear.core.Capability.HEART_RATE, com.smartwear.core.HistoryPoint(ts + i * 60_000L, v.toDouble())) }
            r.spo2.forEachIndexed { i, v -> if (v in 70..100) add(com.smartwear.core.Capability.SPO2, com.smartwear.core.HistoryPoint(ts + i * 60_000L, v.toDouble())) }
            if (r.systolic != null && r.diastolic != null) add(com.smartwear.core.Capability.BLOOD_PRESSURE,
                com.smartwear.core.HistoryPoint(ts, r.systolic.toDouble(), mapOf("diastolic" to r.diastolic.toDouble())))
            r.stress?.let { add(com.smartwear.core.Capability.STRESS, com.smartwear.core.HistoryPoint(ts, it.toDouble())) }
            // HRV theo phút; extra "rr0".."rr9" = các khoảng RR hợp lệ của phút đó (ms) để vẽ Lorenz (RR(n) so RR(n+1)).
            r.hrv.forEachIndexed { i, v ->
                if (v <= 0) return@forEachIndexed
                val rr = r.rr.drop(i * 10).take(10).filter { it in 30..210 }.withIndex().associate { (k, x) -> "rr$k" to x * 10.0 }
                add(com.smartwear.core.Capability.HRV, com.smartwear.core.HistoryPoint(ts + i * 60_000L, v.toDouble(), rr))
            }
            r.met?.let { add(com.smartwear.core.Capability.MET, com.smartwear.core.HistoryPoint(ts, it)) }
            r.blood?.let { b ->
                val extra = b.extra()
                if (b.uricAcid10 > 0) add(com.smartwear.core.Capability.URIC_ACID, com.smartwear.core.HistoryPoint(ts, extra.getValue("uricAcid")))
                if (b.cholesterol100 > 0) add(com.smartwear.core.Capability.BLOOD_LIPIDS,
                    com.smartwear.core.HistoryPoint(ts, extra.getValue("totalCholesterol"), extra - "uricAcid"))
            }
            r.temperature?.let { add(com.smartwear.core.Capability.TEMPERATURE, com.smartwear.core.HistoryPoint(ts, it)) }
        }
        return out
    }

    // ---------- 5 phút D1 (originProtocolVersion ∉ {3, 5}) ----------

    /** `D1 posLo posHi day` (4 byte, `jf/q1.java:153-154`); pos từ 1. */
    fun d1Request(day: Int, position: Int = 1) = Veepoo.bytes(0xD1, position and 0xFF, (position shr 8) and 0xFF, day)

    /** Gói `D1 cur(LE16) total(LE16) …`: hết khi hiện tại = tổng hoặc tổng = 0. */
    fun isD1End(p: ByteArray) = p.op == 0xD1 && p.size >= 5 && (Veepoo.le16(p, 3) == 0 || Veepoo.le16(p, 1) == Veepoo.le16(p, 3))

    /**
     * Một bản ghi `D1` 20 byte (`jf/q1.java:160-256`). Layout thường: `[5]` ngày lệch (0 hôm nay, 1 hôm qua, 2 hôm kia), `[7]` ngày trong tháng,
     * `[8]` giờ, `[9]` phút, bước BE16 `[10..11]`, vận động BE16 `[12..13]`, HR `[14]`, HA `[15]`/`[16]`. Layout "sport model" ([sportLayout]):
     * `[5]` = ngày×32 + giờ, kcal×10 BE16 `[6..7]`, quãng đường m BE16 `[8..9]`, bước/vận động/HR/HA như trên, `[19]` phút. Chưa kiểm trên
     * thiết bị thật (GE54 dùng `DF`).
     */
    fun parseD1(p: ByteArray, today: LocalDate, sportLayout: Boolean): FiveMinute? {
        if (p.op != 0xD1 || p.size < 20 || Veepoo.le16(p, 3) == 0) return null
        val hr = u(p, 14)
        val sys = u(p, 15)
        val dia = u(p, 16)
        val time = if (sportLayout) {
            val dayOff = u(p, 5) / 32
            val hour = u(p, 5) % 32
            val minute = u(p, 19)
            if (hour > 23 || minute > 59) return null
            today.minusDays(dayOff.toLong()).atTime(hour, minute)
        } else {
            val date = today.minusDays(u(p, 5).toLong())
            if (u(p, 7) != date.dayOfMonth || u(p, 8) > 23 || u(p, 9) > 59) return null
            date.atTime(u(p, 8), u(p, 9))
        }
        return FiveMinute(
            time = time,
            steps = Veepoo.be16(p, 10),
            sport = Veepoo.be16(p, 12),
            distanceMeters = if (sportLayout) Veepoo.be16(p, 8) else 0,
            calories10 = if (sportLayout) Veepoo.be16(p, 6) else 0,
            heartRates = if (hr in 30..220) listOf(hr) else emptyList(),
            systolic = sys.takeIf { it > 0 && dia > 0 },
            diastolic = dia.takeIf { it > 0 && sys > 0 },
        )
    }

    // ---------- Ngủ E0 ----------

    fun sleepRequest(day: Int) = Veepoo.bytes(0xE0, day)

    /** Gói ngủ: `[1]` số gói còn lại (0 = cuối), `[2]` số bản ghi, `[3]` ngày, `[4..19]` 16 byte dữ liệu. */
    fun isSleepLast(p: ByteArray) = p.op == 0xE0 && p.size >= 20 && u(p, 1) == 0

    fun sleepPayload(packets: List<ByteArray>): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        for (p in packets) if (p.op == 0xE0 && p.size >= 20) out.write(p, 4, 16)
        return out.toByteArray()
    }

    /** Tóm tắt giấc ngủ chính xác (TLV `A3`, `kf/c.java:113-140`) + đường ngủ (`A5`). */
    data class PreciseSleep(
        val start: LocalDateTime,
        val end: LocalDateTime,
        val quality: Int,
        val wakeCount: Int,
        val deepMinutes: Int,
        val lightMinutes: Int,
        val totalMinutes: Int,
        val accurateType: Int,
        val pointSeconds: Int,
        /** Mã giai đoạn mỗi điểm: 0 sâu, 1 nông, 2 REM, 3 thức/mất ngủ, 4 thức dậy (`PrecisionSleepView.java:184-251`). */
        val line: List<Int>,
    )

    /**
     * Ngủ chính xác (sleepTag ≠ 0, `kf/c.java`): tìm `A1 lenLE16` (độ dài gồm 3 byte đầu), trong đó là TLV 1 byte độ dài `A2` CRC,
     * `A3` tóm tắt, `A4`/`A7` mất ngủ, `A6` cờ; riêng `A5` (đường ngủ) độ dài LE16 = số byte, và khi accurateType (byte cuối `A3`) = 2
     * thì mỗi byte gói 4 điểm 2 bit (MSB trước, chưa kiểm) và độ dài là số điểm; còn lại mỗi điểm là một từ BE16, giai đoạn ở bit 15..13.
     * Kiểm trên GE54 (19/10/2026): độ dài `A1` là **LE16** (`A1 24 03` = 804 byte; jadx cho ra `twoByteToUnsignedInt(b0, b1)` = BE,
     * sai với thiết bị thật); từ `20 00` = nông, `40 00` = REM, `80 00` = thức dậy, `00 00` = sâu, khớp tổng trong `A3`.
     * Năm suy từ ngày đọc [readDate] (tháng lớn hơn tháng hiện tại ⇒ năm trước).
     */
    fun parsePrecise(payload: ByteArray, readDate: LocalDate): List<PreciseSleep> {
        val records = mutableListOf<ByteArray>()
        var i = 0
        while (i < payload.size) {
            if (u(payload, i) == 0xA1 && i + 3 <= payload.size) {
                val len = Veepoo.le16(payload, i + 1)
                if (len >= 3 && i + len <= payload.size) {
                    records += payload.copyOfRange(i + 3, i + len)
                    i += len
                    continue
                }
            }
            i++
        }
        return records.mapNotNull { parsePreciseRecord(it, readDate) }
    }

    fun parsePreciseRecord(rec: ByteArray, readDate: LocalDate): PreciseSleep? {
        var summary: ByteArray? = null
        var curve: ByteArray? = null
        var curvePoints = 0
        var i = 0
        var packed = false
        while (i < rec.size) {
            val tag = u(rec, i)
            if (tag !in 0xA1..0xA7) break
            i++
            if (tag == 0xA5) {
                if (i + 2 > rec.size) break
                val n = Veepoo.le16(rec, i)
                i += 2
                val bytes = if (packed) (n + 3) / 4 else n
                if (i + bytes > rec.size) break
                curve = rec.copyOfRange(i, i + bytes)
                curvePoints = if (packed) n else n / 2
                i += bytes
            } else {
                if (i >= rec.size) break
                val n = u(rec, i)
                i++
                if (i + n > rec.size) break
                val v = rec.copyOfRange(i, i + n)
                if (tag == 0xA3) {
                    summary = v
                    packed = v.isNotEmpty() && u(v, v.size - 1) == 2
                }
                i += n
            }
        }
        val s = summary?.takeIf { it.size >= 36 } ?: return null
        val start = dateNear(readDate, u(s, 0), u(s, 1), u(s, 2), u(s, 3)) ?: return null
        val end = dateNear(readDate, u(s, 4), u(s, 5), u(s, 6), u(s, 7)) ?: return null
        val accurate = u(s, 35)
        val stages = mutableListOf<Int>()
        val c = curve
        if (c != null) {
            if (accurate == 2) {
                for (b in c) for (shift in intArrayOf(6, 4, 2, 0)) {
                    val v = ((b.toInt() and 0xFF) shr shift) and 0x03
                    stages += if (v == 3) 4 else v
                }
                while (stages.size > curvePoints) stages.removeAt(stages.lastIndex)
            } else {
                var k = 0
                while (k + 1 < c.size) {
                    stages += ((Veepoo.be16(c, k) and 0xE000) shr 13).coerceAtMost(4)
                    k += 2
                }
            }
        }
        val total = Veepoo.le16(s, 25)
        return PreciseSleep(
            start = start, end = end, quality = u(s, 15), wakeCount = u(s, 16),
            deepMinutes = Veepoo.le16(s, 19), lightMinutes = Veepoo.le16(s, 21), totalMinutes = total,
            accurateType = accurate, pointSeconds = Veepoo.le16(s, 33).takeIf { it in 1..600 } ?: 60,
            line = if (total in 1 until stages.size) stages.take(total) else stages,
        )
    }

    /** Ngày giờ gần [readDate] nhất cho tháng/ngày/giờ/phút (giấc ngủ có thể bắt đầu từ hôm trước, hoặc năm trước khi đọc tháng 1). */
    fun dateNear(readDate: LocalDate, month: Int, day: Int, hour: Int, minute: Int): LocalDateTime? {
        if (month !in 1..12 || day !in 1..31 || hour > 23 || minute > 59) return null
        val candidates = listOf(readDate.year - 1, readDate.year, readDate.year + 1).mapNotNull { y ->
            runCatching { LocalDateTime.of(y, month, day, hour, minute) }.getOrNull()
        }
        return candidates.minByOrNull { kotlin.math.abs(java.time.Duration.between(readDate.atStartOfDay(), it).toHours()) }
    }

    fun preciseToSession(p: PreciseSleep, zone: ZoneId): SleepSession {
        val startMs = p.start.atZone(zone).toInstant().toEpochMilli()
        val endMs = p.end.atZone(zone).toInstant().toEpochMilli()
        val segments = mutableListOf<SleepSegment>()
        var runStage = -1
        var runStart = 0
        fun close(idx: Int) {
            if (runStage < 0) return
            val secs = (idx - runStart) * p.pointSeconds
            segments += SleepSegment(startMs + runStart * p.pointSeconds * 1000L, (secs + 30) / 60, stageOf(runStage))
        }
        p.line.forEachIndexed { idx, st ->
            if (st != runStage) {
                close(idx)
                runStage = st
                runStart = idx
            }
        }
        close(p.line.size)
        if (segments.isEmpty() && endMs > startMs) {
            // Không có đường ngủ: chỉ tổng sâu/nông.
            if (p.deepMinutes > 0) segments += SleepSegment(startMs, p.deepMinutes, SleepStage.DEEP)
            if (p.lightMinutes > 0) segments += SleepSegment(startMs + p.deepMinutes * 60_000L, p.lightMinutes, SleepStage.LIGHT)
        }
        return SleepSession(startMs, endMs, segments.filter { it.minutes > 0 })
    }

    fun stageOf(code: Int): SleepStage = when (code) {
        0 -> SleepStage.DEEP
        1 -> SleepStage.LIGHT
        2 -> SleepStage.REM
        3, 4 -> SleepStage.AWAKE
        else -> SleepStage.UNKNOWN
    }

    /**
     * Ngủ thường (sleepTag = 0, `kf/b.java`): dữ liệu ghép chia bản ghi 96 byte: `[1..4]` giờ ngủ M D h m, `[5..8]` giờ dậy, `[9]` sâu ×5 phút,
     * `[10]` nông ×5 phút, `[11]` chất lượng, `[12..42]` đường ngủ (mỗi bit 5 phút, MSB trước; 1 = sâu, 0 = nông — chưa kiểm, doc Q4),
     * `[43]` số điểm hợp lệ, `[45..54]` đầu các đoạn thức, `[55]` số đoạn thức, `[57..66]` cuối các đoạn (đơn vị điểm).
     */
    fun parseNormal(payload: ByteArray, readDate: LocalDate, zone: ZoneId): List<SleepSession> {
        val out = mutableListOf<SleepSession>()
        var off = 0
        while (off + 96 <= payload.size) {
            val r = payload.copyOfRange(off, off + 96)
            off += 96
            val start = dateNear(readDate, u(r, 1), u(r, 2), u(r, 3), u(r, 4)) ?: continue
            val end = dateNear(readDate, u(r, 5), u(r, 6), u(r, 7), u(r, 8)) ?: continue
            if (!end.isAfter(start)) continue
            val points = u(r, 43).coerceAtMost(248)
            val stage = IntArray(points) { i -> (u(r, 12 + i / 8) shr (7 - i % 8)) and 1 }
            val wakes = u(r, 55).coerceAtMost(10)
            for (w in 0 until wakes) {
                val a = u(r, 45 + w)
                val b = u(r, 57 + w)
                for (k in a until minOf(b, points)) stage[k] = 2
            }
            val startMs = start.atZone(zone).toInstant().toEpochMilli()
            val segments = mutableListOf<SleepSegment>()
            var i = 0
            while (i < points) {
                var j = i
                while (j < points && stage[j] == stage[i]) j++
                val st = when (stage[i]) { 1 -> SleepStage.DEEP; 2 -> SleepStage.AWAKE; else -> SleepStage.LIGHT }
                segments += SleepSegment(startMs + i * 5 * 60_000L, (j - i) * 5, st)
                i = j
            }
            out += SleepSession(startMs, end.atZone(zone).toInstant().toEpochMilli(), segments)
        }
        return out
    }
}
