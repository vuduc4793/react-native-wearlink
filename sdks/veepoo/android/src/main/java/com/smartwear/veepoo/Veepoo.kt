package com.smartwear.veepoo

import com.smartwear.core.ScannedDevice
import java.time.LocalDateTime
import java.time.ZoneId
import java.util.UUID

/**
 * Hằng số, nhận diện khi quét và các gói bắt tay của giao thức Veepoo (app G Band / VPG Band, SDK `com.veepoo.protocol`).
 * Tài liệu: `sdks/veepoo/docs/01-protocol.md`. Frame = `[opcode][tham số…]`, không header/length/checksum chung;
 * mọi lệnh ghi lên [WRITE] (có phản hồi), mọi phản hồi về [NOTIFY].
 */
object Veepoo {
    val SERVICE: UUID = UUID.fromString("f0080001-0451-4000-b000-000000000000")
    val NOTIFY: UUID = UUID.fromString("f0080002-0451-4000-b000-000000000000")
    val WRITE: UUID = UUID.fromString("f0080003-0451-4000-b000-000000000000")

    /** Kênh file lớn (mặt đồng hồ "DOOG"): ghi điều khiển + notify trên [UI_CONTROL], khối dữ liệu lên [UI_DATA] (không phản hồi). */
    val UI_SERVICE: UUID = UUID.fromString("f0030001-0451-4000-b000-000000000000")
    val UI_CONTROL: UUID = UUID.fromString("f0030002-0451-4000-b000-000000000000")
    val UI_DATA: UUID = UUID.fromString("f0030003-0451-4000-b000-000000000000")

    /** JieLi RCSP (chỉ để nhận diện họ chip; mặt đồng hồ / OTA JieLi cần thư viện native, không làm). */
    val JIELI_SERVICE: UUID = UUID.fromString("0000ae00-0000-1000-8000-00805f9b34fb")

    /** ZK / Bluetrum OTA (chỉ nhận diện). */
    val ZK_SERVICE: UUID = UUID.fromString("0000f003-0000-1000-8000-00805f9b34fb")

    /** Company id trong manufacturer data: `F8 F8` (G Band), `F8 F9` / `F9 F9` (bản thương hiệu riêng). */
    const val COMPANY_VEEPOO = 0xF8F8
    const val COMPANY_VEEPOO_ALT = 0xF9F8
    const val COMPANY_BRAND = 0xF9F9
    val COMPANIES = listOf(COMPANY_VEEPOO, COMPANY_VEEPOO_ALT, COMPANY_BRAND)

    /** MTU app gốc xin ngay khi kết nối (`VOM:843`). */
    const val MTU = 248

    /** Mật khẩu mặc định (G Band luôn gửi "0000"). */
    const val DEFAULT_PASSWORD = "0000"

    fun u(p: ByteArray, i: Int): Int = p[i].toInt() and 0xFF
    fun le16(p: ByteArray, i: Int): Int = u(p, i) or (u(p, i + 1) shl 8)
    fun be16(p: ByteArray, i: Int): Int = (u(p, i) shl 8) or u(p, i + 1)
    fun le32(p: ByteArray, i: Int): Long = le16(p, i).toLong() or (le16(p, i + 2).toLong() shl 16)
    fun be32(p: ByteArray, i: Int): Long = (be16(p, i).toLong() shl 16) or be16(p, i + 2).toLong()

    fun bytes(vararg v: Int) = ByteArray(v.size) { v[it].toByte() }

    /** Gói [size] byte bắt đầu bằng [head], còn lại 0. */
    fun padded(size: Int, vararg head: Int): ByteArray = ByteArray(size).also { b -> head.forEachIndexed { i, v -> b[i] = v.toByte() } }

    val ByteArray.op: Int get() = if (isEmpty()) -1 else this[0].toInt() and 0xFF

    // ---------- Nhận diện khi quét (§2) ----------

    /**
     * Thông tin đọc từ manufacturer data. [mac] theo thứ tự thường. [advertNumber] = LE16 ở byte 6–7 của payload (cái SDK iOS gọi là
     * "device number"); [deviceNumber] = LE16 ở byte 11–12 (trên GE54 trùng device number của `A1`); [firmware] = byte 8–10
     * (trùng byte 7–9 của `A1`; [firmware] chỉ gồm 2 số cuối "95.01"). Hai trường sau chỉ kiểm chứng trên GE54.
     */
    data class Advert(val company: Int, val mac: String?, val advertNumber: Int?, val deviceNumber: Int?, val firmware: String?)

    /**
     * Đọc manufacturer data Veepoo. [data] là phần SAU company id (như `ScanRecord.getManufacturerSpecificData`).
     * `F8 F8`: byte 0–5 = MAC đảo (LE). `F8 F9`: MAC ở byte 4–9 (SDK iOS).
     * GE54 (đo 19/10/2026): `45 1D E3 8F F4 9C A1 00 95 01 00 5C 17 53 FF 2F 00 30 10` ⇒ MAC `9C:F4:8F:E3:1D:45`, byte 6–7
     * `A1 00` (161, KHÔNG phải device number), byte 8–10 `95 01 00` (firmware `00.95.01`, test `00`), byte 11–12 `5C 17` = 5980
     * = device number trong `A1` (BE16 `17 5C`).
     */
    fun parseAdvert(company: Int, data: ByteArray): Advert {
        val macAt = if (company == COMPANY_VEEPOO_ALT) 4 else 0
        val mac = if (data.size >= macAt + 6) (macAt + 5 downTo macAt).joinToString(":") { "%02X".format(data[it]) } else null
        val main = company == COMPANY_VEEPOO
        return Advert(
            company = company,
            mac = mac,
            advertNumber = if (main && data.size >= 8) le16(data, 6) else null,
            deviceNumber = if (main && data.size >= 13) le16(data, 11) else null,
            firmware = if (main && data.size >= 11) "%02X.%02X".format(u(data, 8), u(data, 9)) else null,
        )
    }

    /** Tên quảng bá đã bỏ ký tự rác ở cuối (GE54 phát "GE54" + 2 byte không phải chữ). */
    fun cleanName(name: String?): String =
        name.orEmpty().takeWhile { it in ' '..'~' || it.isLetterOrDigit() }.trim()

    /** Manufacturer data Veepoo của một kết quả quét (null nếu không phải Veepoo). */
    fun advert(device: ScannedDevice): Advert? {
        for (c in COMPANIES) device.manufacturerData[c]?.let { return parseAdvert(c, it) }
        return null
    }

    // ---------- A1: xác nhận mật khẩu + đặt giờ (§4.2) ----------

    /**
     * `A1 pwLo pwHi 00 yearHi yearLo M D h m s is24h 01 tz15 confirm 00…` (20 byte, `jf/v1.java:99-128`).
     * Mật khẩu là chuỗi thập phân ≤ 4 ký tự, gửi LE16. Múi giờ tính bằng 15 phút, có dấu.
     * [confirmOnDevice] = byte 14 (overload 7 tham số): đồng hồ hiện hộp xác nhận kết nối; G Band mặc định 0.
     */
    fun passwordCheck(
        password: String = DEFAULT_PASSWORD,
        now: LocalDateTime,
        is24h: Boolean,
        zone: ZoneId = ZoneId.systemDefault(),
        confirmOnDevice: Boolean = false,
    ): ByteArray {
        require(password.length in 1..4 && password.all { it.isDigit() }) { "Mật khẩu Veepoo là 1–4 chữ số" }
        val pw = password.toInt()
        val offset15 = zone.rules.getOffset(now).totalSeconds / 900
        return padded(
            20, 0xA1, pw and 0xFF, (pw shr 8) and 0xFF, 0x00,
            (now.year shr 8) and 0xFF, now.year and 0xFF, now.monthValue, now.dayOfMonth, now.hour, now.minute, now.second,
            if (is24h) 1 else 0, 0x01, offset15 and 0xFF, if (confirmOnDevice) 1 else 0,
        )
    }

    enum class PasswordStatus { CHECK_FAIL, CHECK_SUCCESS, SETTING_FAIL, SETTING_SUCCESS, READ_FAIL, READ_SUCCESS, CHECK_AND_TIME_SUCCESS, UNKNOWN }

    /**
     * Phản hồi `A1` (≥ 20 byte, `jf/v1.java:28-92`). [deviceNumber] BE16 ở byte 4–5, firmware hex ở byte 6–8 (+9 bản test),
     * MAC LE ở byte 12–17 (chỉ iOS đọc). Trạng thái chức năng: 0 không hỗ trợ / 1 bật / 2 tắt — riêng [nightWrist]
     * (byte 11) là 0 = tắt, 1 = bật, 2 = không hỗ trợ.
     */
    data class PasswordReply(
        val status: PasswordStatus,
        val deviceNumber: Int,
        val firmware: String,
        val testVersion: String,
        val hasDrinkData: Boolean,
        val nightWrist: Int,
        val mac: String,
        val findPhone: Int,
        val wearDetect: Int,
    )

    fun parsePasswordReply(p: ByteArray): PasswordReply? {
        if (p.size < 20 || p.op != 0xA1) return null
        val status = PasswordStatus.entries.getOrNull(u(p, 3))?.takeIf { it != PasswordStatus.UNKNOWN } ?: PasswordStatus.UNKNOWN
        val fw = "%02X.%02X.%02X".format(u(p, 6), u(p, 7), u(p, 8))
        return PasswordReply(
            status = status,
            deviceNumber = be16(p, 4),
            firmware = fw,
            testVersion = "$fw.%02X".format(u(p, 9)),
            hasDrinkData = u(p, 10) == 1,
            nightWrist = u(p, 11),
            mac = (17 downTo 12).joinToString(":") { "%02X".format(p[it]) },
            findPhone = u(p, 18),
            wearDetect = u(p, 19),
        )
    }

    /** Trạng thái coi là đăng nhập thành công (G Band: mọi trạng thái trừ CHECK_FAIL, `VBC:5513-5538`). */
    fun passwordAccepted(r: PasswordReply) = r.status != PasswordStatus.CHECK_FAIL && r.status != PasswordStatus.UNKNOWN

    /** `AF 00`: báo ngắt kết nối (app gốc gửi trước khi đóng GATT 500 ms). */
    val DISCONNECT = bytes(0xAF, 0x00)

    // ---------- A0: pin (§6.1) ----------

    val BATTERY = bytes(0xA0, 0x00)

    /**
     * `A0 powerModel bat state level(0–4) hasPercent percent low` (`jf/f.java:168-199`). [percent]: dùng byte 6 nếu
     * byte 5 = 1, không thì quy vạch × 25. Vạch = 0 ⇒ SDK gốc không điền gì ⇒ null.
     */
    data class Battery(val percent: Int, val level: Int, val charging: Boolean, val low: Boolean, val exactPercent: Boolean)

    fun parseBattery(p: ByteArray): Battery? {
        if (p.size < 8 || p.op != 0xA0) return null
        val level = u(p, 4)
        if (level == 0) return null
        val exact = u(p, 5) == 1
        return Battery(
            percent = (if (exact) u(p, 6) else level * 25).coerceIn(0, 100),
            level = level.coerceAtMost(4),
            charging = u(p, 1) == 1,
            low = u(p, 7) == 2,
            exactPercent = exact,
        )
    }

    // ---------- A5: đặt giờ (§6.6) ----------

    /** `A5 yearHi yearLo M D h m s mode` (mode 1 = 12h, 2 = 24h) (`jf/s2.java:53-97`). */
    fun setTime(now: LocalDateTime, is24h: Boolean): ByteArray = bytes(
        0xA5, (now.year shr 8) and 0xFF, now.year and 0xFF, now.monthValue, now.dayOfMonth, now.hour, now.minute, now.second,
        if (is24h) 2 else 1,
    )

    // ---------- CRC-16/MODBUS (§3.2) ----------

    /** CRC-16/MODBUS: đa thức phản xạ 0xA001, khởi 0xFFFF, không XOR cuối (`util/a.java:22, 133-142`). */
    fun crc16(data: ByteArray, from: Int = 0, to: Int = data.size): Int {
        var crc = 0xFFFF
        for (i in from until to) {
            crc = crc xor (data[i].toInt() and 0xFF)
            repeat(8) { crc = if (crc and 1 != 0) (crc ushr 1) xor 0xA001 else crc ushr 1 }
        }
        return crc and 0xFFFF
    }
}
