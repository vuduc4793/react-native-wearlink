package com.smartwear.gloryfit

import com.smartwear.core.LocationRequest
import com.smartwear.core.SportType
import com.smartwear.core.WorkoutData
import com.smartwear.core.WorkoutEvent
import com.smartwear.core.WorkoutState
import java.math.BigDecimal
import java.math.RoundingMode
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Điều khiển bài tập từ điện thoại, số liệu tức thời, GPS điện thoại, danh sách môn (doc 10 §2.4). Viết tắt như [UteNotify]:
 * `T` = `uterkif/uterkthis.java` (GloryFitPro 1.9.0.2), `W` = `WriteCommandToBLE.java`, `B` = `BluetoothLeService.java`
 * (GloryFit 4.0.12), `U` = `uterkdo/uterkfor.java` (bảng hàm công khai của SDK Pro → hàm dựng lệnh trong `T`).
 *
 * App → đồng hồ:
 * - `FD 11 type intv` bắt đầu, `FD 00 type intv` dừng (33F1; `T:3987-4000` `startSports`, `T:3700-3713` `stopSports`; Pro gọi
 *   `startSports(type, 1)`, `UteBleConnectionRkImpl.java:1986`). intv ngoài 1..255 ⇒ 1.
 * - `FD 22` tạm dừng / `FD 33` tiếp tục / `FD 44` app đẩy số liệu: `FD op type intv h m s` (7 byte); chế độ GPS điện thoại thêm
 *   `kcal(2) kmNguyên kmPhầnTrăm phútPace giâyPace` (13 byte) và F11 `0x10` thêm `bước(3)` (16 byte) (`T:3681-3729`,
 *   `U:458/128/907` `pauseSports`/`continueSports`/`sendSportsDataToBle`; `W:3509-3576` bản cũ giống hệt).
 * - `FD AA` hỏi bài tập đang chạy (33F1, `T:1467`, `queryCurrentSports`).
 * - GPS (34F1): `FD 01 01` đã định vị được / `FD 01 00`, `FD 01 55` thôi gửi, `FD 02 lat lon speed điểm tổng` (`T:4517-4528`,
 *   `AGPSCommandUtil.java:219-247` bản cũ).
 * - Danh sách môn (34F1): đọc `FD 48 AA`; ghi `FD 48 seq [môn hiện vịTrí]…` rồi `FD 48 FD xor` (`T:363`, `T:927-1005`).
 *
 * Đồng hồ → app (`B:7024-7420` `dealWithSportMode`; parser Pro `uterkfor/uterkshort.java` không dịch ngược được, trừ phần danh
 * sách môn `:179-195`): gói 4/13 byte `FD op …` = xác nhận / trạng thái; `FD 04 type st` = người dùng thao tác trên đồng hồ;
 * `FD AA st type` = trả lời hỏi; `FD 01 AA type` = xin vị trí; gói 3 byte `FD 01 55` = thôi xin; gói 14 byte = số liệu tức thời.
 */
object UteWorkout {
    const val OP_STOP = 0x00
    const val OP_START = 0x11
    const val OP_PAUSE = 0x22
    const val OP_RESUME = 0x33
    const val OP_DATA = 0x44

    /** F5 `0x2` (`IS_SUPPORT_SPORT_CONTROL`, iOS `isHasSportPause`): điều khiển bài tập từ app. */
    fun control(f: Ute.Features) = f.has(5, 0x000002)

    /** F6 `0x2000` (`isHasCustomSportIconList`, Pro `isSupSportList`): chọn / sắp xếp môn hiện trên đồng hồ. */
    fun sportList(f: Ute.Features) = f.has(6, 0x002000)

    /** F7 `0x80` (`isHasSportGPS`): bài tập ngoài trời dùng GPS (đồng hồ có thể xin vị trí điện thoại). */
    fun sportGps(f: Ute.Features) = f.has(7, 0x000080)

    /** F11 `0x10` (`isHasFunction_11(16)` trong `T:3683`): gói 22/33/44 chế độ GPS có thêm số bước. */
    fun dataWithSteps(f: Ute.Features) = f.has(11, 0x000010)

    private fun interval(v: Int) = if (v in 1..255) v else 1

    private fun b(v: Int) = v.toByte()

    /** `FD 11 type intv`: bắt đầu bài tập. */
    fun start(sportType: Int, interval: Int = 1) = byteArrayOf(0xFD.toByte(), b(OP_START), b(sportType), b(interval(interval)))

    /** `FD 00 type intv`: dừng bài tập. */
    fun stop(sportType: Int, interval: Int = 1) = byteArrayOf(0xFD.toByte(), b(OP_STOP), b(sportType), b(interval(interval)))

    /** `FD AA`: hỏi bài tập đang chạy. */
    val QUERY = byteArrayOf(0xFD.toByte(), 0xAA.toByte())

    /**
     * Gói `FD op type intv h m s [kcal(2) kmNguyên kmPhầnTrăm pacePhút paceGiây [bước(3)]]` ([op] = [OP_PAUSE], [OP_RESUME],
     * [OP_DATA]). [data] null ⇒ 7 byte (đồng hồ tự đo); khác null ⇒ chế độ GPS điện thoại. Quãng đường đổi ra km làm tròn 2 số lẻ
     * (`DecimalFormat("0.00")`, HALF_EVEN), pace > 99:59 ⇒ 0:00 như bản gốc.
     */
    fun control(op: Int, sportType: Int, interval: Int, durationSec: Int, data: WorkoutData?, withSteps: Boolean): ByteArray {
        val d = durationSec.coerceAtLeast(0)
        val head = byteArrayOf(0xFD.toByte(), b(op), b(sportType), b(interval(interval)), b(d / 3600), b(d % 3600 / 60), b(d % 60))
        if (data == null) return head
        val km = BigDecimal(data.distanceMeters.coerceAtLeast(0)).divide(BigDecimal(1000), 2, RoundingMode.HALF_EVEN)
        val kmInt = km.toBigInteger().toInt()
        val kmFrac = km.subtract(BigDecimal(kmInt)).movePointRight(2).toInt()
        var paceMin = data.paceSecondsPerKm.coerceAtLeast(0) / 60
        var paceSec = data.paceSecondsPerKm.coerceAtLeast(0) % 60
        if (paceMin * 60 + paceSec > 5999) { paceMin = 0; paceSec = 0 }
        val kcal = data.calories.coerceAtLeast(0)
        val gps = head + byteArrayOf(b(kcal shr 8), b(kcal), b(kmInt), b(kmFrac), b(paceMin), b(paceSec))
        if (!withSteps) return gps
        val steps = (data.steps ?: 0).coerceAtLeast(0)
        return gps + byteArrayOf(b(steps shr 16), b(steps shr 8), b(steps))
    }

    // ---------- GPS điện thoại ----------

    /** `FD 01 01` / `FD 01 00`: điện thoại đã / không định vị được (`sendAppLocationStatus`). */
    fun locationStatus(ok: Boolean) = byteArrayOf(0xFD.toByte(), 0x01, if (ok) 0x01 else 0x00)

    /** `FD 01 55`: điện thoại thôi gửi vị trí (`stopSendLocationData`). */
    val LOCATION_STOP = byteArrayOf(0xFD.toByte(), 0x01, 0x55)

    /**
     * `FD 02 lat(4) lon(4) speed(2) điểm(4) tổng(4)` (20 byte, số có dấu big-endian; `T:4517-4528` `sendAppLocationData`):
     * lat/lon × 10⁶ cắt phần lẻ, tốc độ m/s × 100 (làm tròn), quãng đường mét: [pointMeters] từ điểm trước, [totalMeters] cộng dồn
     * (theo tên trường `AppLocationDataInfo` của SDK, giống bản iOS `UteSport.location`).
     * Lưu ý: GloryFit 4.0.12 đưa vào SDK `speed = (int)(m/s × 10)` (`GoogleLocationGpsService.java:215`) và quãng đường theo dm
     * (`:221`), không đặt tổng (0) ⇒ đơn vị đồng hồ thật sự dùng chưa kiểm (doc: câu hỏi mở).
     */
    fun location(latitude: Double, longitude: Double, speedMs: Double?, pointMeters: Int, totalMeters: Int): ByteArray {
        fun be32(v: Int) = byteArrayOf(b(v shr 24), b(v shr 16), b(v shr 8), b(v))
        val lat = (latitude * 1_000_000.0).toInt()
        val lon = (longitude * 1_000_000.0).toInt()
        val speed = Math.round((speedMs ?: 0.0).coerceAtLeast(0.0) * 100).toInt()
        return byteArrayOf(0xFD.toByte(), 0x02) + be32(lat) + be32(lon) + byteArrayOf(b(speed shr 8), b(speed)) + be32(pointMeters) + be32(totalMeters)
    }

    /** Khoảng cách hai điểm (m), công thức haversine, bán kính 6 371 km. */
    fun distanceMeters(lat1: Double, lon1: Double, lat2: Double, lon2: Double): Double {
        val r = 6_371_000.0
        val dLat = Math.toRadians(lat2 - lat1)
        val dLon = Math.toRadians(lon2 - lon1)
        val a = sin(dLat / 2) * sin(dLat / 2) + cos(Math.toRadians(lat1)) * cos(Math.toRadians(lat2)) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * atan2(sqrt(a), sqrt(1 - a))
    }

    // ---------- Gói từ đồng hồ ----------

    /** Kết quả phân tích một gói `FD` ngoài luồng đồng bộ. */
    sealed class Parsed {
        data class Event(val event: WorkoutEvent) : Parsed()
        data class Location(val request: LocationRequest) : Parsed()

        /** Xác nhận không mang trạng thái (`FD 44`, `FD 02`, `FD 01 01`). */
        data class Ack(val op: Int) : Parsed()
    }

    /** Mã trạng thái `00` dừng, `11` bắt đầu, `22` tạm dừng, `33` tiếp tục (`B:7057-7064`); mã lạ coi như bắt đầu như bản gốc. */
    private fun state(code: Int): WorkoutState = when (code) {
        0x00 -> WorkoutState.STOPPED
        0x22 -> WorkoutState.PAUSED
        0x33 -> WorkoutState.RESUMED
        else -> WorkoutState.STARTED
    }

    /**
     * Phân tích gói `FD` (bỏ qua luồng đồng bộ `FD FA`/`FD FD`/bản ghi và danh sách môn `FD 48`), như `B:7024-7420`:
     * - 14 byte: số liệu tức thời `FD type HR kcal(2) paceMin paceSec bước(3) lần(2) kmNguyên kmPhầnTrăm`
     *   (`MultipleSportsModesUtils.*Real`). Thử trên Y25 19/10/2026 (đi bộ, không đeo): không có gói định kỳ, chỉ một gói 14 byte
     *   ngay sau xác nhận tạm dừng / tiếp tục với giá trị vô lý ⇒ bố cục này chưa xác nhận trên Y25;
     * - 4/13 byte: `FD 00/11/22/33 type …` xác nhận lệnh app, `FD 04 type st` đồng hồ tự đổi, `FD AA st type` trả lời hỏi,
     *   `FD 01 AA type` xin vị trí, `FD 44 …` xác nhận số liệu;
     * - 2/3 byte: `FD 01 55` thôi xin vị trí, `FD 01 01` / `FD 02` xác nhận.
     */
    fun parse(p: ByteArray): Parsed? {
        if (p.size < 2 || Ute.u(p, 0) != 0xFD) return null
        val op = Ute.u(p, 1)
        if (p.size == 14) {
            val hr = Ute.u(p, 2)
            return Parsed.Event(
                WorkoutEvent.Realtime(
                    sportType = op,
                    heartRate = hr.takeIf { it > 0 },
                    calories = Ute.be16(p, 3),
                    paceSecondsPerKm = Ute.u(p, 5) * 60 + Ute.u(p, 6),
                    steps = (Ute.u(p, 7) shl 16) or Ute.be16(p, 8),
                    count = Ute.be16(p, 10),
                    distanceMeters = Ute.u(p, 12) * 1000 + Ute.u(p, 13) * 10,
                ),
            )
        }
        if ((p.size == 4 || p.size == 13) && op != 0x48) {
            return when (op) {
                OP_STOP, OP_START, OP_PAUSE, OP_RESUME -> Parsed.Event(WorkoutEvent.State(state(op), Ute.u(p, 2), byDevice = false))
                0x04 -> Parsed.Event(WorkoutEvent.State(state(Ute.u(p, 3)), Ute.u(p, 2), byDevice = true))
                0xAA -> Parsed.Event(WorkoutEvent.State(state(Ute.u(p, 2)), Ute.u(p, 3), byDevice = false))
                0x01 -> if (Ute.u(p, 2) == 0xAA) Parsed.Location(LocationRequest(start = true, sportType = Ute.u(p, 3))) else null
                OP_DATA -> Parsed.Ack(op)
                else -> null
            }
        }
        if (p.size == 2 || p.size == 3) {
            return when {
                op == 0x01 && p.size == 3 && Ute.u(p, 2) == 0x55 -> Parsed.Location(LocationRequest(start = false, sportType = null))
                op == 0x01 || op == 0x02 -> Parsed.Ack(op)
                else -> null
            }
        }
        return null
    }

    // ---------- Danh sách môn ----------

    /** `FD 48 AA`: đọc danh sách môn (34F1). */
    val QUERY_SPORTS = byteArrayOf(0xFD.toByte(), 0x48, 0xAA.toByte())

    /** Gói thuộc luồng danh sách môn (`FD 48 …`). */
    fun isSportListPacket(p: ByteArray) = p.size >= 3 && Ute.u(p, 0) == 0xFD && Ute.u(p, 1) == 0x48

    /** Gói cuối khi đọc: `FD 48 AA FD ? min(2) max(2)` (9 byte, `SportManagementUtil.getMaxMinSportsNumber`). */
    fun isSportListEnd(p: ByteArray) = isSportListPacket(p) && Ute.u(p, 2) == 0xAA && p.size >= 4 && Ute.u(p, 3) == 0xFD

    /**
     * Gom các gói trả lời `FD 48 AA seq [môn hiện vịTrí]…` (seq 0 = bắt đầu lại) và gói cuối (min/max số môn hiện,
     * `uterkshort.java:179-195`; Pro thay min ≤ 0 bằng 1, max ≤ 0 bằng 4). Bỏ môn mã 0 như bản cũ (`SportManagementUtil.java:86-95`).
     */
    /** Danh sách môn đọc được + số môn hiện tối thiểu / tối đa (Pro thay ≤ 0 bằng 1 / 4). */
    data class SportList(val sports: List<SportType>, val minShown: Int, val maxShown: Int)

    fun parseSportList(packets: List<ByteArray>): SportList? {
        var sports = mutableListOf<SportType>()
        var min = 0
        var max = 0
        var ended = false
        for (p in packets) {
            if (!isSportListPacket(p) || Ute.u(p, 2) != 0xAA || p.size < 4) continue
            if (isSportListEnd(p)) {
                if (p.size >= 9) {
                    min = Ute.be16(p, 5)
                    max = Ute.be16(p, 7)
                }
                ended = true
                continue
            }
            if (Ute.u(p, 3) == 0) sports = mutableListOf()
            var i = 4
            while (i + 2 < p.size) {
                val id = Ute.u(p, i)
                if (id > 0) sports += SportType(id, Ute.sportName(id), shown = Ute.u(p, i + 1) == 1, position = Ute.u(p, i + 2), nameEn = Ute.sportNameEn(id))
                i += 3
            }
        }
        if (!ended && sports.isEmpty()) return null
        return SportList(sports, if (min <= 0) 1 else min, if (max <= 0) 4 else max)
    }

    /**
     * Chuẩn hoá danh sách trước khi ghi, như GloryFit `sendSportManagementListsSection` (`WriteCommandToBLE.java:4840-4940`):
     * gửi **mọi** môn đồng hồ có; môn hiện đánh số 1..n theo [SportType.position] (bằng nhau thì giữ thứ tự danh sách), môn ẩn = 0.
     * Số môn hiện phải nằm trong [limits] (nếu biết), không thì [IllegalArgumentException].
     */
    fun normalizeSportList(sports: List<SportType>, limits: IntRange?): List<SportType> {
        require(sports.map { it.type }.toSet().size == sports.size) { "Danh sách môn có mã trùng" }
        require(sports.all { it.type in 1..255 }) { "Mã môn phải trong 1..255" }
        val shown = sports.withIndex().filter { it.value.shown }.sortedWith(compareBy({ it.value.position.takeIf { p -> p > 0 } ?: Int.MAX_VALUE }, { it.index }))
        if (limits != null) {
            require(shown.size in limits) { "Số môn hiện ${shown.size} ngoài giới hạn ${limits.first}..${limits.last}" }
        }
        val pos = shown.withIndex().associate { (n, iv) -> iv.value.type to n + 1 }
        return sports.map { it.copy(position = pos[it.type] ?: 0) }
    }

    /**
     * Gói ghi danh sách môn (`T:927-1005` `l0`/`k0`): mỗi gói `FD 48 seq` + tối đa `(độ dài gói − 3) / 3` môn
     * `[mã hiện(1/0) vịTrí]`; cuối cùng `FD 48 FD xor` với xor = XOR mọi byte từ vị trí 2 của các gói trước.
     * Danh sách rỗng ⇒ không có gói nào (bản gốc không gửi gì).
     */
    fun sportListPackets(sports: List<SportType>, packetLength: Int): List<ByteArray> {
        if (sports.isEmpty()) return emptyList()
        val perPacket = ((packetLength - 3) / 3).coerceAtLeast(1)
        var xor = 0
        val out = sports.chunked(perPacket).mapIndexed { seq, chunk ->
            var p = byteArrayOf(0xFD.toByte(), 0x48, b(seq))
            for (s in chunk) p += byteArrayOf(b(s.type), if (s.shown) 1 else 0, b(s.position))
            for (i in 2 until p.size) xor = xor xor (p[i].toInt() and 0xFF)
            p
        }
        return out + byteArrayOf(0xFD.toByte(), 0x48, 0xFD.toByte(), b(xor))
    }
}
