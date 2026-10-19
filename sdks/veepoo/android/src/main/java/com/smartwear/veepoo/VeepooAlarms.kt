package com.smartwear.veepoo

import com.smartwear.core.Alarm
import com.smartwear.veepoo.Veepoo.op
import com.smartwear.veepoo.Veepoo.u
import java.time.LocalDateTime

/**
 * Báo thức có chữ `B9` (A7 gói 1 byte 17 = 5/6/7, tối đa 10), theo `jf/q2.java` (TextAlarmOprate):
 *
 * - Mỗi báo thức là TLV `A1 len { B1 08 id bật lặp giờ phút yy MM dd, B2 n nhãn-UTF8 }` ([entry]).
 * - CRC danh sách = CRC-16/MODBUS của các TLV ghép theo thứ tự; danh sách rỗng = 0 (`Alarm2Util.getAlarmCrc16`).
 * - Đọc: `B9 03 00 00 A0 02 crcLE` (CRC app đang có; gửi 0 để luôn nhận đủ) → các gói `B9 03 total idx` + phần thân; ghép phần thân
 *   (bỏ 4 byte đầu mỗi gói) = `A0 03 st crcLE` rồi các `A1 …`.
 * - Thêm / sửa (cùng id): `B9 02 01 01 A0 02 crcMới` + TLV; xoá: `B9 01 01 01 A0 02 crcMới` + TLV của báo thức bị xoá. MTU < 82 thì
 *   cắt thân thành nhiều gói `B9 op total idx` + (MTU − 4) byte. Vòng tay trả `B9 op … A0 03 st crcLE`: st = 1 và crc = crcMới ⇒ OK.
 * - Lặp: bit0 = thứ Hai … bit6 = Chủ nhật (`AddEditAlarmFragment.java:385-398`); 0 = một lần, khi đó yy MM dd = ngày báo.
 *
 * GE54 19/10/2026: `B9 03 01 01 A0 03 01 31 3C A1 0C B1 08 01 00 00 0D 2C 30 00 00 B2 00` = một báo thức id 1, 13:44, tắt,
 * không lặp, ngày thô `30 00 00`, nhãn rỗng; CRC 0x3C31.
 */
object VeepooAlarms {
    const val MAX = 10

    /** Một báo thức như trên dây; [year]/[month]/[day] giữ nguyên byte thô (cần đúng từng byte để CRC khớp). */
    data class TextAlarm(
        val id: Int, val enabled: Boolean, val repeat: Int, val hour: Int, val minute: Int,
        val year: Int = 0, val month: Int = 0, val day: Int = 0, val label: String = "",
    ) {
        fun toAlarm() = Alarm(id, hour, minute, repeat and 0x7F, enabled, label.ifEmpty { null })
    }

    /** Nhãn tối đa 30 byte UTF-8 (cắt ở ranh giới ký tự). */
    fun labelBytes(label: String): ByteArray {
        var s = label
        while (s.toByteArray(Charsets.UTF_8).size > 30) s = s.dropLast(1)
        return s.toByteArray(Charsets.UTF_8)
    }

    /** TLV một báo thức (`q2.c()`). */
    fun entry(a: TextAlarm): ByteArray {
        val text = labelBytes(a.label)
        val head = byteArrayOf(0xA1.toByte(), (text.size + 12).toByte(), 0xB1.toByte(), 8, a.id.toByte(), (if (a.enabled) 1 else 0).toByte(),
            a.repeat.toByte(), a.hour.toByte(), a.minute.toByte(), a.year.toByte(), a.month.toByte(), a.day.toByte(), 0xB2.toByte(), text.size.toByte())
        return head + text
    }

    /** CRC danh sách (rỗng = 0). */
    fun crc(list: List<TextAlarm>): Int {
        val all = list.fold(ByteArray(0)) { acc, a -> acc + entry(a) }
        return if (all.isEmpty()) 0 else Veepoo.crc16(all)
    }

    /** `B9 03 00 00 A0 02 crcLE` (20 byte). */
    fun readRequest(crc: Int = 0) = Veepoo.padded(20, 0xB9, 0x03, 0x00, 0x00, 0xA0, 0x02, crc and 0xFF, (crc shr 8) and 0xFF)

    /** Gói cuối của một chuỗi `B9 op total idx`. */
    fun isLast(p: ByteArray) = p.op == 0xB9 && p.size >= 4 && u(p, 3) >= u(p, 2)

    /**
     * Gói ghi: [op] 2 = thêm/sửa, 1 = xoá; [listCrc] = CRC danh sách SAU thao tác. [mtu] ≥ 82 ⇒ một gói (như `q2.settingTextAlarm`).
     */
    fun writePackets(op: Int, a: TextAlarm, listCrc: Int, mtu: Int): List<ByteArray> {
        val body = byteArrayOf(0xA0.toByte(), 2, (listCrc and 0xFF).toByte(), ((listCrc shr 8) and 0xFF).toByte()) + entry(a)
        if (mtu >= 82) return listOf(byteArrayOf(0xB9.toByte(), op.toByte(), 1, 1) + body)
        val chunk = mtu - 4
        val n = (body.size + chunk - 1) / chunk
        return (0 until n).map { i ->
            ByteArray(mtu).also { p ->
                p[0] = 0xB9.toByte(); p[1] = op.toByte(); p[2] = n.toByte(); p[3] = (i + 1).toByte()
                val from = i * chunk
                System.arraycopy(body, from, p, 4, minOf(chunk, body.size - from))
            }
        }
    }

    /** Kết quả gói `B9 op ? ? A0 03 st crcLE` (op 1/2/3): (st, crc) hoặc null. */
    fun parseStatus(p: ByteArray): Pair<Int, Int>? {
        if (p.op != 0xB9 || p.size < 9 || u(p, 4) != 0xA0 || u(p, 5) != 3) return null
        return u(p, 6) to Veepoo.le16(p, 7)
    }

    /** Danh sách từ các gói đọc `B9 03 total idx …` (ghép phần thân, bỏ 4 byte đầu mỗi gói, như `q2.f()` + `q2.g()`). */
    fun parseList(packets: List<ByteArray>): List<TextAlarm> {
        val body = packets.filter { it.op == 0xB9 && it.size > 4 }.fold(ByteArray(0)) { acc, p -> acc + p.copyOfRange(4, p.size) }
        if (body.size < 2) return emptyList()
        val out = mutableListOf<TextAlarm>()
        var i = u(body, 1) + 2
        while (i + 2 <= body.size && u(body, i) == 0xA1) {
            val len = u(body, i + 1)
            if (i + 2 + len > body.size) break
            parseEntry(body.copyOfRange(i + 2, i + 2 + len))?.let { out += it }
            i += 2 + len
        }
        return out
    }

    /** Thân một `A1` (bắt đầu bằng `B1 08`), `q2.a()`. */
    fun parseEntry(b: ByteArray): TextAlarm? {
        if (b.size < 10 || u(b, 0) != 0xB1) return null
        val label = if (b.size >= 12 && u(b, 10) == 0xB2) {
            val n = u(b, 11).coerceAtMost(b.size - 12)
            String(b, 12, n, Charsets.UTF_8)
        } else ""
        return TextAlarm(u(b, 2), u(b, 3) != 0, u(b, 4), u(b, 5), u(b, 6), u(b, 7), u(b, 8), u(b, 9), label)
    }

    /**
     * Báo thức core → dây. Một lần ([Alarm.repeatDays] = 0): ngày báo là hôm nay nếu giờ chưa qua, không thì ngày mai (yy = năm − 2000).
     */
    fun fromAlarm(a: Alarm, id: Int, now: LocalDateTime = LocalDateTime.now()): TextAlarm {
        val repeat = a.repeatDays and 0x7F
        var y = 0; var m = 0; var d = 0
        if (repeat == 0) {
            val today = now.toLocalDate()
            val date = if (now.toLocalTime() < java.time.LocalTime.of(a.hour, a.minute)) today else today.plusDays(1)
            y = date.year - 2000; m = date.monthValue; d = date.dayOfMonth
        }
        return TextAlarm(id, a.enabled, repeat, a.hour.coerceIn(0, 23), a.minute.coerceIn(0, 59), y, m, d, a.label.orEmpty())
    }

    /** Id trống nhỏ nhất 1..[MAX] (`Alarm2Util.getUnAddTextAlarmId`), null nếu đầy. */
    fun freeId(list: List<TextAlarm>): Int? = (1..MAX).firstOrNull { id -> list.none { it.id == id } }
}
