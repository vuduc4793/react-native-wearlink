package com.smartwear.gloryfit

import com.smartwear.core.AgpsFile
import com.smartwear.core.AgpsInfo
import com.smartwear.core.AgpsRequestType

/**
 * AGPS của đồng hồ Realtek có GNSS (HT43, có thể cả Y25), lệnh `01 E9` trên 34F1/34F2. Theo GloryFitPro 1.9.0.2
 * (`uterkif/uterkcase.java`, router `uterkdo/uterkbyte.java:466-471`) và GloryFit iOS (doc 09 §4). SDK không gọi server: file
 * dữ liệu vệ tinh do app tự lấy.
 *
 * - Đồng hồ hỏi: `01 E9 AC 03 01 op` (op 2 = hỏi đã có file chưa, 1 = muốn nhận file; `EphemerisRequired`).
 *   iOS còn có `01 E9 AC 01 xx en` = xin vị trí điện thoại (doc 09 §4.1; app Android không xử lý).
 * - App trả trạng thái `01 E9 AB 03 01 st` (`EphemerisStatus`: 1 chuẩn bị, 2 đang gửi, 3 đã có file, 4 lỗi, 5 không hỗ trợ),
 *   đồng hồ xác nhận `01 E9 AB 03`.
 * - Vị trí: `01 E9 AB 02 0C ts(4) lat(4) lon(4)`, ts = giây Unix, toạ độ × 10⁷ (`uterkcase.java:361-367`), xác nhận `01 E9 AB 02`.
 * - Thông tin: `01 E9 AA 01` → `01 E9 AA 01 seq data…` (seq 0 mở đầu), kết thúc `01 E9 AA 01 FD crc`; dữ liệu TLV
 *   `tag len value` (1 = interval, 2 = version, 3 = danh sách file ASCII ngăn `;`) (`uterkcase.java:107-150`).
 * - Dữ liệu còn hợp lệ: `56 FD` (33F1) → `56 FD st`, st 1 = hợp lệ (`uterkcase.java:75-78`, `:210-217`).
 * - File: [payload] chia gói `01 E9 AB 04 idxHi idxLo <L-6 byte>`; qua mỗi mốc 4 KB chờ `01 E9 AC 04 01 07`; sau gói cuối
 *   `01 E9 AB 04 FD FD xor` (XOR mọi byte các gói dữ liệu); kết quả `01 E9 AC 04 01 st` (`uterkcase.java:129-201`, `:225-309`).
 */
internal object UteAgps {
    /** `isHasFunction_9(0x400000)` = 34F1 b14.6 (`RkSupportUtils.isSupEphemerisService`). */
    fun supported(f: Ute.Features) = f.has(9, 0x400000)

    const val STATUS_PREPARE = 1
    const val STATUS_DONE = 3
    const val STATUS_FAIL = 4
    const val STATUS_NOT_SUPPORT = 5

    /** Kết quả truyền `01 E9 AC 04 01 st`. */
    const val TRANSFER_OK = 1
    const val TRANSFER_CANCELLED = 3
    const val TRANSFER_CRC = 4
    const val TRANSFER_TOO_LARGE = 5
    const val TRANSFER_RESEND = 6
    const val TRANSFER_CONTINUE = 7

    /** Giới hạn cho dữ liệu app đưa vào (file AGPS thật vài chục KB). */
    const val MAX_FILES = 16
    const val MAX_FILE_BYTES = 256 * 1024
    const val MAX_TOTAL_BYTES = 512 * 1024
    const val SECTOR_BYTES = 4096

    /** Vị trí điện thoại cũ hơn chừng này không gửi nữa. */
    const val POSITION_MAX_AGE_MS = 6 * 3_600_000L
    /** Đồng hồ hỏi mỗi phút: gửi lại vị trí tối đa mỗi chừng này. */
    const val POSITION_RESEND_MS = 10 * 60_000L

    val INFO = bytes(0x01, 0xE9, 0xAA, 0x01)
    val EPHEMERIS_STATE = bytes(0x56, 0xFD)

    fun status(st: Int) = bytes(0x01, 0xE9, 0xAB, 0x03, 0x01, st)

    fun position(timestampSec: Long, latitude: Double, longitude: Double): ByteArray {
        require(latitude in -90.0..90.0 && longitude in -180.0..180.0) { "Toạ độ không hợp lệ" }
        val out = bytes(0x01, 0xE9, 0xAB, 0x02, 0x0C) + be32(timestampSec.toInt()) +
            be32((latitude * 1e7).toInt()) + be32((longitude * 1e7).toInt())
        return out
    }

    fun dataPacket(index: Int, chunk: ByteArray) = bytes(0x01, 0xE9, 0xAB, 0x04, index shr 8, index) + chunk

    fun endPacket(xor: Int) = bytes(0x01, 0xE9, 0xAB, 0x04, 0xFD, 0xFD, xor)

    private fun isE9(p: ByteArray, a: Int, b: Int) =
        p.size >= 4 && Ute.u(p, 0) == 0x01 && Ute.u(p, 1) == 0xE9 && Ute.u(p, 2) == a && Ute.u(p, 3) == b

    /** Đồng hồ hỏi AGPS ([AgpsRequestType]); null nếu không phải gói hỏi. */
    fun parseRequest(p: ByteArray): AgpsRequestType? = when {
        isE9(p, 0xAC, 0x03) && p.size >= 6 -> when (Ute.u(p, 5)) {
            1 -> AgpsRequestType.DOWNLOAD
            2 -> AgpsRequestType.STATUS
            else -> null
        }
        isE9(p, 0xAC, 0x01) && p.size >= 6 && Ute.u(p, 5) == 1 -> AgpsRequestType.POSITION
        else -> null
    }

    fun isInfoPacket(p: ByteArray) = isE9(p, 0xAA, 0x01) && p.size >= 5
    fun isInfoEnd(p: ByteArray) = isInfoPacket(p) && Ute.u(p, 4) == 0xFD
    fun isPositionAck(p: ByteArray) = isE9(p, 0xAB, 0x02)
    fun isStatusAck(p: ByteArray) = isE9(p, 0xAB, 0x03)
    fun isTransferResult(p: ByteArray) = isE9(p, 0xAC, 0x04) && p.size >= 6
    fun transferStatus(p: ByteArray) = Ute.u(p, 5)
    /** `01 E9 AC 04 01 06 HH LL`: gửi lại từ gói HHLL. */
    fun resendFrom(p: ByteArray): Int? = if (p.size >= 8 && transferStatus(p) == TRANSFER_RESEND) Ute.be16(p, 6) else null

    /** `56 FD st` → còn dữ liệu vệ tinh hợp lệ. */
    fun parseEphemerisState(p: ByteArray): Boolean? =
        if (p.size >= 3 && Ute.u(p, 0) == 0x56 && Ute.u(p, 1) == 0xFD) Ute.u(p, 2) == 1 else null

    /** Ghép các gói `01 E9 AA 01 seq data` (seq 0 mở đầu, `FD` kết thúc) rồi đọc TLV. */
    fun parseInfo(packets: List<ByteArray>, ephemerisValid: Boolean? = null): AgpsInfo {
        var data = ByteArray(0)
        for (p in packets) {
            if (!isInfoPacket(p) || Ute.u(p, 4) == 0xFD) continue
            val part = p.copyOfRange(5, p.size)
            data = if (Ute.u(p, 4) == 0) part else data + part
        }
        var interval: Int? = null
        var version: Int? = null
        var files = emptyList<String>()
        var i = 0
        while (i + 2 <= data.size) {
            val tag = Ute.u(data, i)
            val len = Ute.u(data, i + 1)
            if (i + 2 + len > data.size) break
            val v = data.copyOfRange(i + 2, i + 2 + len)
            when (tag) {
                1 -> interval = beN(v)
                2 -> version = beN(v)
                3 -> files = String(v, Charsets.US_ASCII).split(';').map { it.trim() }.filter { it.isNotEmpty() }
            }
            i += 2 + len
        }
        return AgpsInfo(files, version, interval, ephemerisValid)
    }

    /**
     * Nội dung truyền (`uterkcase.java:311-346`): `u16 len(desc) || desc || u32 tổng || dữ liệu`, desc = mỗi file
     * `u8 len(tên) || tên ASCII || u32 cỡ`. Tên bỏ phần mở rộng như app gốc. Kiểm giới hạn vì dữ liệu từ ngoài vào.
     */
    fun payload(files: List<AgpsFile>): ByteArray {
        require(files.isNotEmpty()) { "Chưa có file AGPS" }
        require(files.size <= MAX_FILES) { "Quá $MAX_FILES file AGPS" }
        var desc = ByteArray(0)
        var total = 0
        for (f in files) {
            require(f.data.isNotEmpty() && f.data.size <= MAX_FILE_BYTES) { "File AGPS ${f.name} rỗng hoặc quá ${MAX_FILE_BYTES / 1024} KB" }
            val name = stem(f.name).toByteArray(Charsets.US_ASCII)
            desc += byteArrayOf(name.size.toByte()) + name + be32(f.data.size)
            total += f.data.size
        }
        require(total <= MAX_TOTAL_BYTES) { "Tổng file AGPS quá ${MAX_TOTAL_BYTES / 1024} KB" }
        val out = ByteArray(2 + desc.size + 4 + total)
        out[0] = (desc.size shr 8).toByte(); out[1] = desc.size.toByte()
        desc.copyInto(out, 2)
        be32(total).copyInto(out, 2 + desc.size)
        var at = 2 + desc.size + 4
        for (f in files) { f.data.copyInto(out, at); at += f.data.size }
        return out
    }

    /** Tên file trong mô tả: bỏ phần mở rộng (`name.substring(0, lastIndexOf("."))`), chỉ ASCII in được, ≤ 64 ký tự. */
    fun stem(name: String): String {
        val s = name.substringAfterLast('/').let { if ('.' in it) it.substringBeforeLast('.') else it }
        require(s.isNotEmpty() && s.length <= 64 && s.all { it.code in 0x21..0x7E }) { "Tên file AGPS không hợp lệ: $name" }
        return s
    }

    /** Các gói `AB 04` của [payload] với [chunk] byte mỗi gói. */
    fun packets(payload: ByteArray, chunk: Int): List<ByteArray> =
        (0 until (payload.size + chunk - 1) / chunk).map { i -> dataPacket(i, payload.copyOfRange(i * chunk, minOf(payload.size, (i + 1) * chunk))) }

    /** XOR mọi byte của mọi gói dữ liệu (cả 6 byte đầu gói), như `f4496uterkfor`. */
    fun xor(packets: List<ByteArray>): Int = packets.fold(0) { acc, p -> p.fold(acc) { a, b -> a xor (b.toInt() and 0xFF) } }

    private fun beN(v: ByteArray): Int? = if (v.isEmpty() || v.size > 4) null else v.fold(0) { a, b -> (a shl 8) or (b.toInt() and 0xFF) }
    private fun be32(v: Int) = bytes(v ushr 24, v ushr 16, v ushr 8, v)
    private fun bytes(vararg v: Int) = ByteArray(v.size) { v[it].toByte() }
}
