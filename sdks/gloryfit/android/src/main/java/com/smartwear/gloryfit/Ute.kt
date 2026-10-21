package com.smartwear.gloryfit

import com.smartwear.core.ActivityTotals
import com.smartwear.core.Capability
import com.smartwear.core.HistoryPoint
import com.smartwear.core.SleepSegment
import com.smartwear.core.SleepSession
import com.smartwear.core.SleepStage
import com.smartwear.core.Workout
import com.smartwear.core.toHex
import java.time.Instant
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneId
import java.util.UUID
import kotlin.math.roundToInt

/**
 * Giao thức UTE (app GloryFit), xem sdks/gloryfit/docs/01-protocol.md.
 * Gói = opcode + tham số, số nhiều byte big-endian, không checksum mỗi gói.
 */
object Ute {
    private fun uuid16(v: Int): UUID = UUID.fromString("0000%04x-0000-1000-8000-00805f9b34fb".format(v))

    val SERVICE: UUID = uuid16(0x55FF)
    val WRITE: UUID = uuid16(0x33F1)
    val NOTIFY: UUID = uuid16(0x33F2)
    val SERVICE5: UUID = uuid16(0x56FF)
    val WRITE5: UUID = uuid16(0x34F1)
    val NOTIFY5: UUID = uuid16(0x34F2)

    /** Trạng thái dữ liệu chưa đồng bộ (đọc GATT, chỉ SDK iOS dùng: `readDeviceDataStatus:`), doc 10 §2.1. */
    val DATA_STATUS: UUID = uuid16(0x33F3)

    /**
     * UUID 16-bit dịch vụ trong gói quảng bá mà app GloryFit lọc (iOS `setFilerServersArray:`, doc 09 §1.2):
     * dải 0x55xx cũ và `5554, 4544, 4231, 424C, 4F4F, 3455` (Android gốc tìm chúng dưới dạng chuỗi hex).
     */
    val ADVERTISED = listOf(
        0x55FF, 0x5533, 0x55F0, 0x5536, 0x5534, 0x553C, 0x5555,
        0x5554, 0x4544, 0x4231, 0x424C, 0x4F4F, 0x3455,
    ).map(::uuid16)

    fun u(b: ByteArray, i: Int) = b[i].toInt() and 0xFF
    fun be16(b: ByteArray, i: Int) = (u(b, i) shl 8) or u(b, i + 1)
    internal fun be24(b: ByteArray, i: Int) = (u(b, i) shl 16) or (u(b, i + 1) shl 8) or u(b, i + 2)

    /**
     * Gói đặt giờ: `A3 YYYY MM DD hh mm ss` (8 byte, Y25/HT43 đã phản hồi, doc 01 §10).
     * [tzHours] khác null thì thêm 1 byte giờ lệch GMT có dấu như SDK iOS (doc 09 §1.5); chưa kiểm chứng trên đồng hồ.
     */
    fun setTime(t: LocalDateTime, tzHours: Int? = null): ByteArray {
        val base = byteArrayOf(
            0xA3.toByte(), (t.year shr 8).toByte(), t.year.toByte(),
            t.monthValue.toByte(), t.dayOfMonth.toByte(), t.hour.toByte(), t.minute.toByte(), t.second.toByte(),
        )
        return if (tzHours == null) base else base + tzHours.toByte()
    }

    /** Giờ lệch GMT, phần giờ nguyên (chia nguyên như ObjC, suy luận; múi lẻ 30 phút bị cắt). */
    fun tzHours(zone: ZoneId, at: LocalDateTime): Int = zone.rules.getOffset(at).totalSeconds / 3600

    /** Bật đo nhịp tim 24h (`F7 01`, tắt là `F7 02`). */
    val HR24_ENABLE = byteArrayOf(0xF7.toByte(), 0x01)

    /** Chu kỳ đo HR 24h: `F7 09 en mmH mmL` (phút, BE). App iOS chỉ dùng 5..1440 phút, nhỏ nhất 5 (doc 09 §2.2). */
    fun heartRate24hInterval(minutes: Int, enable: Boolean = true): ByteArray {
        val m = minutes.coerceIn(5, 1440)
        return byteArrayOf(0xF7.toByte(), 0x09, (if (enable) 1 else 0).toByte(), (m shr 8).toByte(), m.toByte())
    }

    /** Hỏi trạng thái đo nhịp tim: `E5 AA` → `E5 AA 11` (đang đo) / `E5 AA FF` (doc 09 §2.2). */
    val HR_STATUS = byteArrayOf(0xE5.toByte(), 0xAA.toByte())

    /** Kết quả `E5 AA`: true = đang đo, false = không đo, null = không phải gói này. */
    fun parseHeartRateStatus(p: ByteArray): Boolean? {
        if (p.size < 3 || u(p, 0) != 0xE5 || u(p, 1) != 0xAA) return null
        return u(p, 2) == 0x11
    }

    /** Mã 4 số người dùng thấy trên đồng hồ: mỗi chữ số (ASCII) XOR với "UTE8". */
    fun pairingCode(code: String): ByteArray {
        require(code.length == 4 && code.all { it.isDigit() }) { "Mã phải gồm 4 chữ số" }
        val key = "UTE8"
        return byteArrayOf(0xD5.toByte(), 0x01) + ByteArray(4) { (code[it].code xor key[it].code).toByte() }
    }

    /**
     * `A9` + 18 byte thông tin người dùng (doc §5.2). Mặc định: 170 cm, 65 kg, tắt màn 5 s,
     * mục tiêu 8000 bước, nâng tay sáng màn, tắt báo HR cao, 30 tuổi, nam, ngôn ngữ khác TQ, °C.
     */
    fun userInfo(
        heightCm: Int = 170, weightKg: Int = 65, screenOffSec: Int = 5, stepGoal: Int = 8000,
        raiseToWake: Boolean = true, age: Int = 30, male: Boolean = true,
        hrHighAlert: Int? = null, hrLowAlert: Int? = null, fahrenheit: Boolean = false,
    ) = byteArrayOf(
        0xA9.toByte(), 0x00, heightCm.toByte(), 0x00, weightKg.toByte(), screenOffSec.toByte(),
        (stepGoal shr 24).toByte(), (stepGoal shr 16).toByte(), (stepGoal shr 8).toByte(), stepGoal.toByte(),
        // Byte 11: ngưỡng báo nhịp tim cao (FF = tắt), 18: ngưỡng thấp (0 = tắt), 17: 1 = °C, 2 = °F (doc 01 §5.2).
        (if (raiseToWake) 1 else 0).toByte(), (hrHighAlert ?: 0xFF).toByte(), 0x00, age.toByte(), (if (male) 1 else 2).toByte(),
        0x00, 0x02, (if (fahrenheit) 2 else 1).toByte(), (hrLowAlert ?: 0).toByte(),
    )

    fun accountId(id: Int) = byteArrayOf(0x33, 0x02, (id shr 24).toByte(), (id shr 16).toByte(), (id shr 8).toByte(), id.toByte())

    /** Bảng tính năng đọc từ 33F1 (F1..F7) và 34F1 (độ dài gói + F8..F13). */
    class Features(val groups: Map<Int, Int>, val maxPacketLength: Int?) {
        fun has(group: Int, mask: Int) = (groups[group] ?: 0) and mask == mask

        val usesPairingCode get() = has(1, 0x000001)
        val usesAccountId get() = has(10, 0x080000)
        /** `isHas24HourHRM` (33F1 byte 15 bit 6). */
        val heartRate24h get() = has(2, 0x004000)
        /** `isHasHRMTimedMeasurement` (34F1 byte 8 bit 7): SDK iOS chỉ cho đo tay `E5 11` khi có cờ này. */
        val heartRateTimedMeasurement get() = has(11, 0x800000)
        /**
         * Đồng hồ HR 24h không hỗ trợ đo theo lệnh app (Y25, HT43): app GloryFit iOS không gửi `D6 01`/`E5 11`,
         * nhịp tim lấy từ `F7 03` (đo định kỳ) và `F7 0B` (đo trên đồng hồ), doc 09 §2.
         */
        val heartRateByPush get() = heartRate24h && !heartRateTimedMeasurement
        val sleepHourlyFormat get() = has(1, 0x000400)
        /**
         * `isHasResolveSleep` (33F1 b8.2 = F4 `0x040000`): ngủ do thuật toán trên đồng hồ, lấy bằng `31 01`.
         * SDK mới (`uterkif/uterkint.java:72`) không gửi `B3 FA` khi có bit này.
         */
        val resolveSleep get() = has(4, 0x040000)
        /**
         * Thuật toán CyWee (34F1 b19.5 = F8 `0x000020`, `RkSupportUtils.isSupCywee`, chỉ Y25): bước qua `EB 02 FA`
         * trên 34F1, ngủ qua `EC 01` (`uterkif/uterkthis.java:2884-2902`).
         */
        val cywee get() = has(8, 0x000020)
        /**
         * `isHasDataStatus` (33F1 b9.5 = F4 `0x002000`; app Android gọi là "sync timestamp", `SyncDateUtils.isSupportSyncTimestamp`):
         * lệnh đồng bộ nhận mốc `[op] FA YYYY MM DD HH mm`, đọc được trạng thái dữ liệu `33F3`.
         */
        val syncTimestamp get() = has(4, 0x002000)

        fun capabilities(): Set<Capability> = buildSet {
            add(Capability.STEPS)
            if (has(1, 0x080000)) add(Capability.HEART_RATE)
            if (has(1, 0x100000) || has(5, 0x100000) || has(7, 0x000010)) add(Capability.BLOOD_PRESSURE)
            if (has(5, 0x000040)) add(Capability.SPO2)
            if (has(5, 0x000008)) add(Capability.TEMPERATURE)
            if (has(6, 0x000020)) add(Capability.STRESS)
            if (has(11, 0x000020)) add(Capability.HRV)
            if (has(3, 0x002000)) add(Capability.ECG)
            if (has(8, 0x020000)) add(Capability.BLOOD_SUGAR)
            if (!has(4, 0x008000)) add(Capability.SLEEP)
            if (has(3, 0x008000)) add(Capability.MENSTRUATION)
        }

        companion object {
            /** `33F1`: byte 0..1 = F7 (16 bit), rồi F6, F5, F4, F3, F2, F1 (24 bit mỗi nhóm). */
            fun parse(main: ByteArray?, ble5: ByteArray?): Features {
                val g = mutableMapOf<Int, Int>()
                if (main != null && main.size >= 20) {
                    g[7] = be16(main, 0)
                    for ((k, group) in listOf(6, 5, 4, 3, 2, 1).withIndex()) g[group] = be24(main, 2 + k * 3)
                }
                var maxLen: Int? = null
                if (ble5 != null && ble5.size >= 20) {
                    maxLen = be16(ble5, 0).takeIf { it > 0 }
                    for ((k, group) in listOf(13, 12, 11, 10, 9, 8).withIndex()) g[group] = be24(ble5, 2 + k * 3)
                }
                return Features(g, maxLen)
            }
        }
    }

    /** Thông số mặt đồng hồ trả về từ `26 01` (sdks/gloryfit/docs/02-watchface.md §2). */
    data class DialParams(
        val currentId: Long, val width: Int, val height: Int, val screenType: Int,
        val maxSize: Long, val level: Int, val slots: Int, val corner: Int,
    )

    fun parseDialParams(p: ByteArray): DialParams? {
        if (p.size < 15 || u(p, 0) != 0x26 || u(p, 1) != 0x01) return null
        fun be32(i: Int) = (u(p, i).toLong() shl 24) or (u(p, i + 1).toLong() shl 16) or (u(p, i + 2).toLong() shl 8) or u(p, i + 3).toLong()
        return DialParams(
            currentId = be32(2), width = be16(p, 6), height = be16(p, 8), screenType = u(p, 10), maxSize = be32(11),
            level = if (p.size > 15) u(p, 15) else 0, slots = if (p.size > 16 && u(p, 16) > 0) u(p, 16) else 1,
            corner = if (p.size > 17) u(p, 17) else 0,
        )
    }

    // ---------- Lịch sử ----------

    private fun date(b: ByteArray, i: Int) = Triple(be16(b, i), u(b, i + 2), u(b, i + 3))

    private fun epoch(zone: ZoneId, y: Int, mo: Int, d: Int, h: Int, mi: Int): Long? = runCatching {
        LocalDateTime.of(y, mo, d, 0, 0).plusHours(h.toLong()).plusMinutes(mi.toLong()).atZone(zone).toInstant().toEpochMilli()
    }.getOrNull()

    /** Một lệnh đồng bộ lịch sử: byte gửi, kênh ghi, gói nào thuộc luồng, gói nào kết thúc luồng (docs/feature-matrix.md việc 9). */
    enum class SyncCommand(private vararg val codes: Int) {
        /** `B2 FA` → `B2 YYYY MM DD HH sH sL …` … `B2 FD`. */
        STEPS_HOURLY(0xB2, 0xFA),
        /** `EB 02 FA` ghi vào 34F1 → `EB 02 YYYY MM DD HH sH sL dH dL cal(3)` … `EB 02 FD xx` (CyWee). */
        STEPS_CYWEE(0xEB, 0x02, 0xFA),
        /** `B3 FA` → `B3 YYYY MM DD hh mm rH rL` (hoặc 14 byte gộp giờ) … `B3 FD crc`. */
        SLEEP_ROLL(0xB3, 0xFA),
        /** `31 01` → mỗi ngày `31 01 YYYY MM DD n` + các gói `32 <đoạn 6 byte…>`, kết thúc `31 02`. */
        SLEEP_RESOLVE(0x31, 0x01),
        /** `EC 01` → mỗi ngày `EC 01 YYYY MM DD n` + các gói `EC 02 <đoạn 6 byte…>`, kết thúc `EC 03` (CyWee). */
        SLEEP_CYWEE(0xEC, 0x01),
        /** `F7 FA` → `F7 YYYY MM DD HH v0…v11` … `F7 FD`. */
        HEART_RATE_24H(0xF7, 0xFA),
        /** `E6 FA` → `E6 YYYY MM DD hh mm rr` … `E6 FD`. */
        HEART_RATE(0xE6, 0xFA),
        /** `34 FA` → `34 FA YYYY MM DD HH xx v0…v11` … `34 FA FD crc`. */
        SPO2(0x34, 0xFA),
        /** `C8 FA` → `C8 YYYY MM DD hh mm sys dia` … `C8 FD`. */
        BLOOD_PRESSURE(0xC8, 0xFA);

        val bytes: ByteArray get() = ByteArray(codes.size) { codes[it].toByte() }

        /** Ghi vào 34F1 (kênh BLE5) thay vì 33F1 (`writeCharaBle5` trong app cũ). Phản hồi đến ở 33F2 hoặc 34F2. */
        val usesBle5 get() = this == STEPS_CYWEE

        /** Gói thô nối nhau (`32 …`, `EC 02 …`): không bỏ gói trùng như các luồng bản ghi. */
        val dedupe get() = this != SLEEP_RESOLVE && this != SLEEP_CYWEE

        val hex: String get() = bytes.toHex()

        /**
         * Lệnh nhận mốc thời gian (SDK Pro `uterkif/uterkint.java:23-131`, GloryFit cũ `SyncDateUtils.getSyncTimestampByte`):
         * `B2 FA`, `B3 FA`, `F7 FA`/`E6 FA`, `C8 FA`, `34 FA`. Lệnh CyWee (`EB 02 FA`, `EC 01`) và `31 01` không có mốc.
         */
        val acceptsTimestamp get() = this in setOf(STEPS_HOURLY, SLEEP_ROLL, HEART_RATE_24H, HEART_RATE, SPO2, BLOOD_PRESSURE)

        /**
         * Byte gửi: lệnh + 6 byte mốc `YYYY MM DD HH mm` ([timestamp]) nếu đồng hồ có F4 `0x2000` và lệnh nhận mốc; không thì
         * như [bytes]. Như bản gốc: bước lấy 00:00 của ngày [since]; ngủ `B3` lấy 18:00 ngày hôm trước; còn lại 00:00 của [since].
         */
        fun request(since: LocalDate?, f: Features): ByteArray {
            if (since == null || !f.syncTimestamp || !acceptsTimestamp) return bytes
            val at = if (this == SLEEP_ROLL) since.minusDays(1).atTime(18, 0) else since.atStartOfDay()
            return bytes + timestamp(at)
        }

        fun matches(p: ByteArray): Boolean {
            if (p.isEmpty()) return false
            val op = u(p, 0)
            return when (this) {
                STEPS_CYWEE -> op == 0xEB && p.size >= 2 && u(p, 1) == 0x02
                SLEEP_RESOLVE -> op == 0x32 || (op == 0x31 && p.size >= 2 && (u(p, 1) == 0x01 || u(p, 1) == 0x02))
                SLEEP_CYWEE -> op == 0xEC && p.size >= 2 && u(p, 1) in 1..3
                else -> op == codes[0]
            }
        }

        fun isEnd(p: ByteArray): Boolean = when (this) {
            STEPS_CYWEE -> p.size >= 3 && u(p, 0) == 0xEB && u(p, 1) == 0x02 && u(p, 2) == 0xFD
            SLEEP_RESOLVE -> p.size >= 2 && u(p, 0) == 0x31 && u(p, 1) == 0x02
            SLEEP_CYWEE -> p.size >= 2 && u(p, 0) == 0xEC && u(p, 1) == 0x03
            else -> Ute.isEnd(codes[0], p)
        }
    }

    /**
     * Lệnh đồng bộ theo bảng tính năng. Mỗi mục là danh sách thử lần lượt: lệnh sau chỉ dùng khi lệnh trước
     * **không có gói nào** (kể cả gói kết thúc) — giữ lệnh cũ làm dự phòng cho HT43 và đồng hồ UTE đời cũ.
     */
    class SyncPlan(f: Features, caps: Set<Capability>) {
        val steps: List<SyncCommand> = if (f.cywee) listOf(SyncCommand.STEPS_CYWEE, SyncCommand.STEPS_HOURLY) else listOf(SyncCommand.STEPS_HOURLY)
        // Như SDK mới (`uterkthis.uterksuper`): CyWee ⇒ `EC 01`; còn lại `31 01` khi có bit thuật toán, không thì `B3 FA`.
        val sleep: List<SyncCommand> = if (Capability.SLEEP in caps) buildList {
            if (f.cywee) add(SyncCommand.SLEEP_CYWEE)
            if (f.resolveSleep) add(SyncCommand.SLEEP_RESOLVE)
            add(SyncCommand.SLEEP_ROLL)
        } else emptyList()
        val heartRate: SyncCommand? = if (Capability.HEART_RATE in caps) {
            if (f.heartRate24h) SyncCommand.HEART_RATE_24H else SyncCommand.HEART_RATE
        } else null
        val spo2: SyncCommand? = SyncCommand.SPO2.takeIf { Capability.SPO2 in caps }
        val bloodPressure: SyncCommand? = SyncCommand.BLOOD_PRESSURE.takeIf { Capability.BLOOD_PRESSURE in caps }
    }

    // ---------- Bài tập (đa môn thể thao) ----------

    /** Yêu cầu đồng bộ bài tập: `FD FA` + 6 byte mốc (0 = từ đầu) (`WriteCommandToBLE.syncMultipleSportsModes`). */
    val WORKOUT_SYNC = byteArrayOf(0xFD.toByte(), 0xFA.toByte(), 0, 0, 0, 0, 0, 0)

    /**
     * `FD FA` + mốc ngày [since] lúc 00:00 (SDK Pro case 9, `uterkint.java:33-52`) khi đồng hồ có F4 `0x2000`; không thì
     * [WORKOUT_SYNC] (mốc 0 = lấy hết).
     */
    fun workoutSync(since: LocalDate?, f: Features): ByteArray =
        if (since == null || !f.syncTimestamp) WORKOUT_SYNC else byteArrayOf(0xFD.toByte(), 0xFA.toByte()) + timestamp(since.atStartOfDay())

    /** 6 byte mốc `YYYY(2) MM DD HH mm` (`uterkint.uterkif`). */
    fun timestamp(t: LocalDateTime): ByteArray =
        byteArrayOf((t.year shr 8).toByte(), t.year.toByte(), t.monthValue.toByte(), t.dayOfMonth.toByte(), t.hour.toByte(), t.minute.toByte())

    /** Gói đầu `FD FA … nn nn` (10 byte): số bài tập sẽ gửi, byte 8–9 BE (`MultipleSportsModesUtils.syncSportsModesDataCount`). */
    fun workoutCount(p: ByteArray): Int? = if (p.size == 10 && u(p, 0) == 0xFD && u(p, 1) == 0xFA) be16(p, 8) else null

    /** `FD FD`: hết một bài tập. */
    fun isWorkoutEnd(p: ByteArray) = p.size in 2..3 && u(p, 0) == 0xFD && u(p, 1) == 0xFD

    /**
     * Giải mã các gói bài tập (`BluetoothLeService.dealWithSportMode`, `MultipleSportsModesUtils`). Mỗi bài:
     * - gói số 0: `FD 00 00 type rateCnt(2) YYYY MM DD hh mm ss` + kết thúc. [endIsTimestamp] (F5 `0x040000`):
     *   byte 13–16 là epoch giây kết thúc, 17–19 thời gian tập hiệu quả (giây); không thì 13–19 là ngày giờ kết thúc.
     * - gói số 1: bước (u24 @3), số lần (@6), kcal (@8), quãng đường km = b10 + b11/100, HR tb/max/min (@12–14),
     *   pace phút:giây (@15–16).
     * - gói số ≥ 2: vùng nhịp tim, sải bước, chuỗi mẫu (HR, pace/tốc độ, nhịp bước, toạ độ GPS), xem [UteWorkoutRecord].
     *   [hasDetail] = F7 `0x80` (gói 2, 3 là gói tổng hợp). `FD FD` kết thúc bài.
     */
    fun parseWorkouts(packets: List<ByteArray>, zone: ZoneId, endIsTimestamp: Boolean, hasDetail: Boolean = false): List<Workout> {
        val out = mutableListOf<Workout>()
        var cur: Workout? = null
        var interval: Int? = null
        val detail = mutableListOf<ByteArray>()
        fun flush() {
            cur?.let { w -> out += runCatching { UteWorkoutRecord.withDetail(w, detail, interval, hasDetail) }.getOrDefault(w) }
            cur = null; interval = null; detail.clear()
        }
        for (p in packets) {
            if (p.isEmpty() || u(p, 0) != 0xFD || workoutCount(p) != null) continue
            if (isWorkoutEnd(p)) { flush(); continue }
            if (p.size >= 3 && be16(p, 1) >= 2) { if (cur != null) detail += p; continue }
            if (p.size < 13) continue
            when (be16(p, 1)) {
                0 -> {
                    flush()
                    val type = u(p, 3)
                    val start = runCatching {
                        LocalDateTime.of(be16(p, 6), u(p, 8), u(p, 9), u(p, 10), u(p, 11), u(p, 12)).atZone(zone).toInstant().toEpochMilli()
                    }.getOrNull() ?: continue
                    var active = 0
                    var end = start
                    if (p.size >= 20) {
                        if (endIsTimestamp) {
                            active = be24(p, 17)
                            end = start + active * 1000L
                        } else {
                            runCatching {
                                LocalDateTime.of(be16(p, 13), u(p, 15), u(p, 16), u(p, 17), u(p, 18), u(p, 19)).atZone(zone).toInstant().toEpochMilli()
                            }.getOrNull()?.let { end = it; active = ((it - start) / 1000).toInt().coerceAtLeast(0) }
                        }
                    }
                    cur = Workout(type, sportName(type), start, end, active)
                }
                1 -> cur = cur?.let { w ->
                    interval = UteWorkoutRecord.intervalSeconds(p)
                    fun pos(v: Int) = v.takeIf { it > 0 }
                    val km = u(p, 10) + u(p, 11) / 100.0
                    val pace = if (p.size >= 17) u(p, 15) * 60 + u(p, 16) else 0
                    w.copy(
                        steps = pos(be24(p, 3)), calories = pos(be16(p, 8)), distanceMeters = pos((km * 1000).toInt()),
                        avgHeartRate = pos(u(p, 12)), maxHeartRate = pos(u(p, 13)), minHeartRate = pos(u(p, 14)),
                        paceSecondsPerKm = pos(pace),
                    )
                }
            }
        }
        flush()
        return out.sortedByDescending { it.start }
    }

    /** Tên môn theo mã (`SportsMode.MULTIPLE_SPORTS_MODE_*` của SDK UTE). */
    fun sportName(type: Int): String = SPORT_NAMES[type] ?: "Môn thể thao #$type"

    private val SPORT_NAMES = mapOf(
        1 to "Chạy bộ", 2 to "Đạp xe", 3 to "Nhảy dây", 4 to "Bơi", 5 to "Cầu lông", 6 to "Bóng bàn", 7 to "Quần vợt",
        8 to "Leo núi", 9 to "Đi bộ", 10 to "Bóng rổ", 11 to "Bóng đá", 12 to "Bóng chày", 13 to "Bóng chuyền",
        14 to "Cricket", 15 to "Bóng bầu dục", 16 to "Khúc côn cầu", 17 to "Nhảy", 18 to "Đạp xe trong nhà", 19 to "Yoga",
        20 to "Gập bụng", 21 to "Máy chạy bộ", 22 to "Thể dục dụng cụ", 23 to "Chèo thuyền", 24 to "Bật nhảy",
        25 to "Tập tự do", 26 to "Đi bộ trong nhà", 27 to "Chạy trong nhà", 28 to "Tập sức mạnh", 29 to "Tập bậc thang",
        30 to "Cưỡi ngựa", 31 to "Máy elip", 32 to "Thái cực quyền", 33 to "Đá cầu", 34 to "Quyền anh",
        35 to "Đi bộ ngoài trời", 36 to "Chạy địa hình", 37 to "Trượt tuyết", 39 to "Taekwondo", 41 to "Máy chèo",
        43 to "Đi bộ đường dài", 46 to "Karate", 49 to "Pilates", 75 to "Golf", 81 to "Trượt băng", 96 to "Pickleball",
        97 to "HIIT", 108 to "Hít xà", 109 to "Chống đẩy", 110 to "Plank", 115 to "Marathon", 134 to "Đạp xe trong nhà",
        151 to "Ba môn phối hợp", 155 to "Cử tạ", 166 to "Chạy trong nhà", 167 to "Tập luyện chung",
    )

    /** Gói kết thúc một luồng lịch sử: `[op] FD …` (SpO2: `34 FA FD crc`). */
    fun isEnd(op: Int, p: ByteArray): Boolean = when {
        p.isEmpty() || u(p, 0) != op -> false
        op == 0x34 -> p.size >= 3 && u(p, 1) == 0xFA && u(p, 2) == 0xFD
        else -> p.size >= 2 && u(p, 1) == 0xFD
    }

    /**
     * Nhịp tim đồng hồ tự đẩy: `F7 03 YYYY MM DD hh mm rr` (đo định kỳ chế độ 24h) hoặc
     * `F7 0B YYYY MM DD hh mm rr` (người dùng đo trên đồng hồ, doc 09 §2.2).
     */
    fun parsePushedHeartRate(p: ByteArray, zone: ZoneId): com.smartwear.core.Reading? {
        if (p.size < 9 || u(p, 0) != 0xF7 || (u(p, 1) != 0x03 && u(p, 1) != 0x0B)) return null
        val (y, mo, d) = date(p, 2)
        val bpm = u(p, 8).takeIf { it in 30..220 } ?: return null
        val ts = epoch(zone, y, mo, d, u(p, 6), u(p, 7)) ?: System.currentTimeMillis()
        return com.smartwear.core.Reading(Capability.HEART_RATE, com.smartwear.core.ReadingStatus.OK, value = bpm.toDouble(), timestamp = ts)
    }

    /** Nhịp tim tức thời `E5 fin st rr` (đang đo hoặc kết quả), null nếu chưa có giá trị hợp lệ. */
    fun parseLiveHeartRate(p: ByteArray): com.smartwear.core.Reading? {
        if (p.size < 4 || u(p, 0) != 0xE5 || u(p, 2) != 0) return null
        val bpm = u(p, 3).takeIf { it in 30..220 } ?: return null
        return com.smartwear.core.Reading(Capability.HEART_RATE, com.smartwear.core.ReadingStatus.OK, value = bpm.toDouble())
    }

    /**
     * Mẫu của luồng nhịp tim liên tục: `E5 fin st rr` với st = 0 và rr 30–220 ⇒ nhịp tim; st ≠ 0 ⇒ chưa đeo (`bpm` null,
     * `contact` false); rr = 0 (đang khởi động) ⇒ null. `F7 03`/`F7 0B` (đồng hồ tự đẩy) cũng là một mẫu, giờ là lúc nhận.
     */
    fun parseHeartRateStream(p: ByteArray, timestamp: Long = System.currentTimeMillis()): com.smartwear.core.HeartRateSample? {
        if (p.size >= 9 && u(p, 0) == 0xF7 && (u(p, 1) == 0x03 || u(p, 1) == 0x0B)) {
            return u(p, 8).takeIf { it in 30..220 }?.let { com.smartwear.core.HeartRateSample(it, contact = true, timestamp = timestamp) }
        }
        if (p.size < 4 || u(p, 0) != 0xE5) return null
        if (u(p, 2) != 0) return com.smartwear.core.HeartRateSample(null, contact = false, timestamp = timestamp)
        return u(p, 3).takeIf { it in 30..220 }?.let { com.smartwear.core.HeartRateSample(it, contact = true, timestamp = timestamp) }
    }

    /** Bước theo giờ: `B2 YYYY MM DD HH sH sL`. */
    fun parseSteps(packets: List<ByteArray>, zone: ZoneId): List<HistoryPoint> = packets
        .filter { it.size >= 8 && u(it, 0) == 0xB2 && u(it, 1) != 0xFD }
        .mapNotNull { p ->
            val (y, mo, d) = date(p, 1)
            val ts = epoch(zone, y, mo, d, u(p, 5), 0) ?: return@mapNotNull null
            HistoryPoint(ts, be16(p, 6).toDouble())
        }

    /** Bước theo giờ CyWee: `EB 02 YYYY MM DD HH sH sL dH dL c c c` (`SWAlgorithmUtil`: quãng đường m, calo cal, BE). */
    fun parseCyweeSteps(packets: List<ByteArray>, zone: ZoneId): List<HistoryPoint> = packets
        .filter { it.size >= 9 && u(it, 0) == 0xEB && u(it, 1) == 0x02 && u(it, 2) != 0xFD && be16(it, 2) > 0 }
        .mapNotNull { p -> cyweeHour(p, zone) }

    /**
     * Một giờ `EB 01`/`EB 02` (cùng định dạng từ byte 2) → điểm bước, extra "distance" (m), "calories" (cal).
     * Calo: đồng hồ (CyWee) tự tính, gói ghi kcal×1000; app chính hãng **không** tính lại từ bước/hồ sơ, chỉ lấy
     * `round1(raw / 1000)` kcal mỗi giờ rồi cộng (GloryFit `SWAlgorithmUtil.java:47-49`, Pro `uterkint/uterkgoto.java:17-19`).
     * Ở đây làm tròn y như vậy theo cal: bội số 100 cal gần nhất (0,1 kcal).
     */
    private fun cyweeHour(p: ByteArray, zone: ZoneId): HistoryPoint? {
        val (y, mo, d) = date(p, 2)
        val ts = epoch(zone, y, mo, d, u(p, 6), 0) ?: return null
        val extra = buildMap {
            if (p.size >= 11) put("distance", be16(p, 9).toDouble())
            if (p.size >= 14) put("calories", cyweeCalories(be24(p, 11)).toDouble())
        }
        return HistoryPoint(ts, be16(p, 7).toDouble(), extra)
    }

    /** kcal×1000 của gói CyWee → cal, làm tròn 0,1 kcal như app (`TempratureUtils.roundingToFloat(1, …)`, nửa lên). */
    fun cyweeCalories(raw: Int): Int = (raw + 50) / 100 * 100

    /**
     * Tổng hôm nay (CyWee, Y25): cộng các giờ `EB 02` của hôm nay + giờ đang chạy `EB 01` (cùng định dạng, chưa có
     * trong `EB 02`). Bước, quãng đường (m), calo theo **cal** (gói ghi kcal×1000; quy ước chung `ActivityTotals.calories`, UI/RN
     * tự chia 1000 — trước 19/10/2026 chia ở đây nên RN ra 0 kcal). Như GloryFit `FragmentHomePage.updateSteps`
     * (`:1385-1426`, cộng thêm bài tập) và GloryFitPro `MainHomePresenter` (`:44-83`): tổng = Σ calo từng giờ của đồng hồ.
     */
    fun todayTotals(hourly: List<HistoryPoint>, current: ByteArray?, zone: ZoneId, now: Long = System.currentTimeMillis()): ActivityTotals? {
        val today = Instant.ofEpochMilli(now).atZone(zone).toLocalDate()
        fun isToday(ts: Long) = Instant.ofEpochMilli(ts).atZone(zone).toLocalDate() == today
        val points = hourly.filter { isToday(it.timestamp) }.toMutableList()
        if (current != null && current.size >= 9 && u(current, 0) == 0xEB && u(current, 1) == 0x01) {
            cyweeHour(current, zone)?.takeIf { p -> isToday(p.timestamp) && points.none { it.timestamp == p.timestamp } }?.let { points += it }
        }
        if (points.isEmpty()) return null
        val steps = points.sumOf { it.value }
        val distance = points.sumOf { it.extra["distance"] ?: 0.0 }
        val calories = points.sumOf { it.extra["calories"] ?: 0.0 }
        return ActivityTotals(steps = steps.toInt(), calories = calories.roundToInt(), distanceMeters = distance.toInt())
    }

    /** Nhịp tim từng lần đo: `E6 YYYY MM DD hh mm rr`. */
    fun parseHeartRate(packets: List<ByteArray>, zone: ZoneId): List<HistoryPoint> = packets
        .filter { it.size >= 8 && u(it, 0) == 0xE6 && u(it, 1) != 0xFD }
        .mapNotNull { p ->
            val (y, mo, d) = date(p, 1)
            val ts = epoch(zone, y, mo, d, u(p, 5), u(p, 6)) ?: return@mapNotNull null
            u(p, 7).takeIf { it in 30..220 }?.let { HistoryPoint(ts, it.toDouble()) }
        }

    /** Nhịp tim 24h: `F7 YYYY MM DD HH v0…v11`, ô byte b (6..17) ở phút HH×60 − (17−b)×10; chỉ 40 < v < 200. */
    fun parseHeartRate24h(packets: List<ByteArray>, zone: ZoneId): List<HistoryPoint> = packets
        .filter { it.size >= 7 && u(it, 0) == 0xF7 && u(it, 1) == 0x07 }
        .flatMap { p ->
            val (y, mo, d) = date(p, 1)
            val hour = u(p, 5)
            (6 until minOf(p.size, 18)).mapNotNull { b ->
                val v = u(p, b)
                if (v <= 40 || v >= 200) return@mapNotNull null
                epoch(zone, y, mo, d, 0, hour * 60 - (17 - b) * 10)?.let { HistoryPoint(it, v.toDouble()) }
            }
        }

    /** SpO2: `34 FA YYYY MM DD HH xx v0…v11`, ô i (byte 8+i) ở phút HH×60 − (11−i)×10, FF = trống. */
    fun parseSpo2(packets: List<ByteArray>, zone: ZoneId): List<HistoryPoint> = packets
        .filter { it.size >= 9 && u(it, 0) == 0x34 && u(it, 1) == 0xFA && u(it, 2) != 0xFD }
        .flatMap { p ->
            val (y, mo, d) = date(p, 2)
            val hour = u(p, 6)
            (0 until 12).mapNotNull { i ->
                val v = p.getOrNull(8 + i)?.toInt()?.and(0xFF) ?: return@mapNotNull null
                if (v == 0xFF || v == 0) return@mapNotNull null
                epoch(zone, y, mo, d, 0, hour * 60 - (11 - i) * 10)?.let { HistoryPoint(it, v.coerceIn(70, 100).toDouble()) }
            }
        }

    /** Huyết áp: `C8 YYYY MM DD hh mm sys dia` (`DataProcessing.java:1733-1735`). value = tâm thu, extra "diastolic". */
    fun parseBloodPressure(packets: List<ByteArray>, zone: ZoneId): List<HistoryPoint> = packets
        .filter { it.size >= 9 && u(it, 0) == 0xC8 && u(it, 1) != 0xFD }
        .mapNotNull { p ->
            val sys = u(p, 7)
            val dia = u(p, 8)
            if (sys !in 50..250 || dia !in 30..200) return@mapNotNull null
            val (y, mo, d) = date(p, 1)
            val ts = epoch(zone, y, mo, d, u(p, 5), u(p, 6)) ?: return@mapNotNull null
            HistoryPoint(ts, sys.toDouble(), mapOf("diastolic" to dia.toDouble()))
        }

    /**
     * Ngủ (định dạng thường): `B3 YYYY MM DD hh mm rH rL`, r = số lần cử động ("roll count") của đoạn.
     * Phân loại rút gọn theo app: r ≤ 3 sâu, ≤ 40 nông, lớn hơn là thức (suy luận, xem doc §5.3).
     * Các mốc cách nhau quá 2 giờ được tách thành phiên khác nhau.
     */
    fun parseSleep(packets: List<ByteArray>, zone: ZoneId, hourlyFormat: Boolean = false): List<SleepSession> {
        val records = packets.filter { it.size >= 9 && u(it, 0) == 0xB3 && u(it, 1) != 0xFD }
        val marks = if (hourlyFormat) {
            // 14 byte: `B3 YYYY MM DD hh (m, r)×4`, FF FF = ô trống.
            records.flatMap { p ->
                val (y, mo, d) = date(p, 1)
                (0 until 4).mapNotNull { k ->
                    val i = 6 + k * 2
                    if (i + 1 >= p.size || (u(p, i) == 0xFF && u(p, i + 1) == 0xFF)) return@mapNotNull null
                    epoch(zone, y, mo, d, u(p, 5), u(p, i))?.let { it to u(p, i + 1) }
                }
            }
        } else {
            records.mapNotNull { p ->
                val (y, mo, d) = date(p, 1)
                epoch(zone, y, mo, d, u(p, 5), u(p, 6))?.let { it to be16(p, 7) }
            }
        }.sortedBy { it.first }
        val sessions = mutableListOf<SleepSession>()
        var current = mutableListOf<Pair<Long, Int>>()
        fun flush() {
            if (current.size >= 2) {
                val segments = current.zipWithNext { (t, roll), (next, _) ->
                    val stage = when { roll <= 3 -> SleepStage.DEEP; roll <= 40 -> SleepStage.LIGHT; else -> SleepStage.AWAKE }
                    SleepSegment(t, ((next - t) / 60_000).toInt(), stage)
                }
                sessions += SleepSession(current.first().first, current.last().first, segments)
            }
            current = mutableListOf()
        }
        for (m in marks) {
            if (current.isNotEmpty() && m.first - current.last().first > 2 * 3_600_000L) flush()
            current += m
        }
        flush()
        return sessions
    }

    /** Dữ liệu ngủ một ngày của luồng `31 01` / `EC 01`: ngày (theo gói mở đầu) + các đoạn 6 byte nối lại. */
    class SleepDay(
        val year: Int,
        val month: Int,
        val day: Int,
        /** Byte [6] của gói mở đầu (`bandAlgorithmSleepCount`); chỉ để đối chiếu. */
        val declaredCount: Int,
    ) {
        var raw = ByteArray(0)
            internal set

        val sectionCount get() = raw.size / 6
    }

    /**
     * Gom gói `31 01 YYYY MM DD n` + `32 <raw>` (`cywee = false`, `BluetoothLeService.java:7640-7681`) hoặc
     * `EC 01 YYYY MM DD n` + `EC 02 <raw>` (`cywee = true`, `:9888-9925`) thành từng ngày.
     */
    fun sleepDays(packets: List<ByteArray>, cywee: Boolean): List<SleepDay> {
        val days = mutableListOf<SleepDay>()
        val startOp = if (cywee) 0xEC else 0x31
        for (p in packets) {
            when {
                p.size >= 7 && u(p, 0) == startOp && u(p, 1) == 0x01 -> days += SleepDay(be16(p, 2), u(p, 4), u(p, 5), u(p, 6))
                days.isEmpty() -> continue
                !cywee && p.isNotEmpty() && u(p, 0) == 0x32 -> days.last().raw += p.copyOfRange(1, p.size)
                cywee && p.size >= 2 && u(p, 0) == 0xEC && u(p, 1) == 0x02 -> days.last().raw += p.copyOfRange(2, p.size)
            }
        }
        return days
    }

    /**
     * Mã trạng thái của đoạn ngủ do đồng hồ tính (`SleepInfo.SLEEP_STATUS_*` của SDK mới; CyWee dùng `raw − 1`
     * với cùng thứ tự): 1 sâu, 2 nông, 3 thức, 4 REM. `FF` = hết một phiên (CyWee: tách giấc đêm / ngủ trưa).
     */
    fun sleepStage(code: Int): SleepStage = when (code) {
        1 -> SleepStage.DEEP
        2 -> SleepStage.LIGHT
        3 -> SleepStage.AWAKE
        4 -> SleepStage.REM
        else -> SleepStage.UNKNOWN
    }

    /**
     * Đoạn 6 byte `hh mm st ?? dH dL` (giờ:phút bắt đầu, trạng thái, ?, thời lượng phút BE) → phiên ngủ.
     * Mốc ngày (suy luận theo app GloryFitPro, ngày ngủ tính từ 20:00 hôm trước): đoạn đầu bắt đầu từ 20:00 trở đi
     * thuộc tối hôm trước; giờ lùi lại so với đoạn trước nghĩa là đã qua nửa đêm. Đoạn `FF` hoặc khoảng trống
     * quá 2 giờ thì tách phiên. Phiên bắt đầu 09:00–18:00 và ≤ 3 giờ coi là ngủ trưa (suy luận).
     */
    fun parseSleepDays(days: List<SleepDay>, zone: ZoneId): List<SleepSession> {
        val sessions = mutableListOf<SleepSession>()
        fun SleepSegment.end() = start + minutes * 60_000L
        for (d in days) {
            val midnight = runCatching { LocalDate.of(d.year, d.month, d.day) }.getOrNull() ?: continue
            var base: LocalDate? = null
            var prevMinute = -1
            var segments = mutableListOf<SleepSegment>()
            fun flush() {
                if (segments.isNotEmpty()) {
                    val start = segments.first().start
                    val end = segments.last().end()
                    val hour = Instant.ofEpochMilli(start).atZone(zone).hour
                    val nap = hour in 9 until 18 && end - start <= 3 * 3_600_000L
                    sessions += SleepSession(start, end, segments, nap)
                }
                segments = mutableListOf()
            }
            for (k in 0 until d.sectionCount) {
                val i = k * 6
                val h = u(d.raw, i)
                val m = u(d.raw, i + 1)
                if (h > 23 || m > 59) continue
                if (u(d.raw, i + 2) == 0xFF) {
                    flush()
                    continue
                }
                val minute = h * 60 + m
                val b = when {
                    base == null -> if (minute >= 20 * 60) midnight.minusDays(1) else midnight
                    minute < prevMinute -> base.plusDays(1)
                    else -> base
                }
                base = b
                prevMinute = minute
                val duration = be16(d.raw, i + 4)
                if (duration <= 0) continue
                val start = b.atStartOfDay(zone).toInstant().toEpochMilli() + minute * 60_000L
                if (segments.isNotEmpty() && start - segments.last().end() > 2 * 3_600_000L) flush()
                segments += SleepSegment(start, duration, sleepStage(u(d.raw, i + 2)))
            }
            flush()
        }
        return sessions.sortedBy { it.start }
    }

    // ---------- Trạng thái dữ liệu (33F3) ----------

    /**
     * Giá trị đọc từ `33F3` (SDK iOS `receiveDeviceDataStatus:` `0x1e731c`). Ý nghĩa bit là **suy luận** (doc 10 §2.1): byte cuối
     * bit0 GPS, 1 bước, 2 ngủ, 3 bơi, 4 nhảy dây, 5 huyết áp, 6 nhịp tim, 7 xe đạp; byte áp chót bit0 bóng, 1 nhịp tim thể thao,
     * 2 nhịp tim 24h, 3 body fat; bit = 1 nghĩa là có dữ liệu chưa đồng bộ. Chưa đối chiếu trên đồng hồ nên driver chỉ ghi log,
     * không bỏ bước đồng bộ nào theo bit.
     */
    class DataStatus(val raw: ByteArray) {
        val pending: Set<String> get() = buildSet {
            if (raw.isEmpty()) return@buildSet
            val last = u(raw, raw.size - 1)
            listOf("gps", "steps", "sleep", "swim", "skip", "bloodPressure", "heartRate", "bike").forEachIndexed { i, k -> if (last shr i and 1 == 1) add(k) }
            if (raw.size >= 2) {
                val prev = u(raw, raw.size - 2)
                listOf("ball", "sportHeartRate", "heartRate24h", "bodyFat").forEachIndexed { i, k -> if (prev shr i and 1 == 1) add(k) }
            }
        }

        override fun toString() = "${raw.toHex()} (suy luận: $pending)"
    }

    // ---------- Khe mặt đồng hồ (26 05 / 26 08 / 26 09) ----------

    /** `26 09`: liệt kê mọi khe (`queryAllWatchFaceInfo` → `T:1323-1326`); trả về nhiều gói `26 09 seq …`, kết thúc `26 09 FD`. */
    val DIAL_SLOTS_ALL = byteArrayOf(0x26, 0x09)

    /** `26 05 n` (`queryWhichWatchFaceInfo(n)`, `T:2235-2238`); một gói `26 05 [khe mã(4)]…`. Ý nghĩa [n] chưa rõ (doc 10 dùng 0). */
    fun dialSlotsQuery(n: Int = 0) = byteArrayOf(0x26, 0x05, n.toByte())

    /** `26 08 n`: xoá mặt ở khe [index] (`deleteDeviceWatchFaceOnline`, `T:3260-3263`). */
    fun dialSlotDelete(index: Int) = byteArrayOf(0x26, 0x08, index.toByte())

    /**
     * Các mục 5 byte `[khe][mã 4 byte BE]` (`watchface/close/uterkelse.java:183-197` → `WatchFaceSerialNumberInfo`): dùng cho phần
     * dữ liệu sau `26 05` (từ byte 2) và sau `26 09 seq` (từ byte 3, nối các gói). Phần lẻ < 5 byte bị bỏ.
     */
    fun parseDialSlots(data: ByteArray): List<com.smartwear.core.WatchFaceSlot> =
        (0 until data.size / 5).map { k ->
            val i = k * 5
            val id = (u(data, i + 1).toLong() shl 24) or (u(data, i + 2).toLong() shl 16) or (u(data, i + 3).toLong() shl 8) or u(data, i + 4).toLong()
            com.smartwear.core.WatchFaceSlot(u(data, i), faceId = id)
        }

    /** Ghép các gói trả lời `26 09`: `26 09 seq <mục…>` (seq 0 = bắt đầu lại), `26 09 FD` = hết (`uterkelse.java:120-134`). */
    fun parseDialSlotPackets(packets: List<ByteArray>): List<com.smartwear.core.WatchFaceSlot> {
        var data = ByteArray(0)
        for (p in packets) {
            if (p.size < 3 || u(p, 0) != 0x26 || u(p, 1) != 0x09 || u(p, 2) == 0xFD) continue
            val part = p.copyOfRange(3, p.size)
            data = if (u(p, 2) == 0) part else data + part
        }
        return parseDialSlots(data)
    }

    /** Kết quả xoá `26 08 khe max st`: st 1 = đã xoá, 0 = lỗi, khác = không có mặt nào để xoá (`WatchFaceUtil.DELETE_*`). */
    fun parseDialDelete(p: ByteArray): Int? = if (p.size >= 5 && u(p, 0) == 0x26 && u(p, 1) == 0x08) u(p, 4) else null

    // ---------- Nút đồng hồ (D1) ----------

    /**
     * `D1 01` bấm đổi màn, `D1 04` / `D1 06` giữ phím 2 / 3, `D1 05` nút SOS (`P/uterkfor/uterkchar.java:137-165` →
     * `SimpleCallbackListener.PRESS_SWITCH_SCREEN_BUTTON` 9, `LONG_PRESS_BUTTON_SECOND` 10, `LONG_PRESS_BUTTON_THIRD` 11,
     * `PRESS_SOS_BUTTON` 7).
     */
    fun parseDeviceEvent(p: ByteArray): com.smartwear.core.DeviceEvent? {
        if (p.size < 2 || u(p, 0) != 0xD1) return null
        return when (u(p, 1)) {
            0x01 -> com.smartwear.core.DeviceEvent.SWITCH_SCREEN_BUTTON
            0x04 -> com.smartwear.core.DeviceEvent.LONG_PRESS_BUTTON_2
            0x05 -> com.smartwear.core.DeviceEvent.SOS_BUTTON
            0x06 -> com.smartwear.core.DeviceEvent.LONG_PRESS_BUTTON_3
            else -> null
        }
    }

    // ---------- Xoá dữ liệu ----------

    /** `AD`: xoá dữ liệu / khôi phục cài đặt gốc (`deviceFactoryDataReset` → `T:1286-1288`); ack qua write callback. */
    val FACTORY_RESET = byteArrayOf(0xAD.toByte())
}
