package com.smartwear.veepoo

import com.smartwear.veepoo.Veepoo.op
import com.smartwear.veepoo.Veepoo.u

/**
 * Mặt đồng hồ Veepoo gốc qua kênh "big data" (`sdks/veepoo/docs/03-watchface-ota.md` §1): điều khiển `50` trên F0080003, dữ liệu trên
 * F0030001 (gói "DOOG" lên F0030002 có phản hồi, khối thô lên F0030003 không phản hồi). Chỉ dùng khi `bigDataTranType` = 2 và chip không
 * phải JieLi (1) / ZK (3, 4): JieLi cần xác thực RCSP + thư viện native (`libjl_*`), ZK cần nén PAR (`libabpartool.so`) — không làm.
 */
object VeepooWatchFace {
    const val TYPE_SERVER = 1
    const val TYPE_CUSTOM = 2

    /** `50 02 type` (20 byte): đọc thông tin vùng mặt đồng hồ (`jf/t2.java:253-261`). */
    fun infoRequest(type: Int) = Veepoo.padded(20, 0x50, 0x02, type)

    /**
     * Phản hồi SERVER `50 02 01 ok addr(LE32) maxLen(LE32) binType(LE16) dialShape(LE16) crc(LE16) … idx` (`t2.java:134-141`).
     * CUSTOM: `… addr(LE32) maxLen(LE24) EWatchUIType …`.
     */
    data class Info(val type: Int, val address: Long, val maxBytes: Long, val binType: Int, val dialShape: Int, val crc: Int, val uiType: Int)

    fun parseInfo(p: ByteArray): Info? {
        if (p.op != 0x50 || p.size < 18 || u(p, 1) != 0x02 || u(p, 3) != 1) return null
        return when (val type = u(p, 2)) {
            TYPE_SERVER -> Info(type, Veepoo.le32(p, 4), Veepoo.le32(p, 8), Veepoo.le16(p, 12), Veepoo.le16(p, 14), Veepoo.le16(p, 16), 0)
            TYPE_CUSTOM -> Info(type, Veepoo.le32(p, 4), (Veepoo.le16(p, 8) or (u(p, 10) shl 16)).toLong(), 0, 0, Veepoo.le16(p, 17), u(p, 11))
            else -> null
        }
    }

    /** Màn hình theo `EWatchUIType` (một phần, `customui/WatchUIType.java`): (rộng, cao, tròn). */
    fun screenOf(uiType: Int, dialShape: Int): Triple<Int, Int, Boolean> = when (uiType) {
        1 -> Triple(240, 240, true)
        2 -> Triple(240, 240, false)
        3 -> Triple(240, 280, false)
        else -> if (dialShape == 1) Triple(240, 240, true) else Triple(240, 280, false)
    }

    /** File đệm `FF` tới bội số 4 (`UiUpdateUtil.java:488-496`). */
    fun pad4(file: ByteArray): ByteArray = if (file.size % 4 == 0) file else file + ByteArray(4 - file.size % 4) { 0xFF.toByte() }

    /**
     * Vào chế độ cập nhật: `50 01 type addr(LE32) len(LE32) …` (`t2.java:188-250`); SERVER thêm byte 11–12 `binType` LE16, 13–14 CRC LE16,
     * 15 = 01. Thiết bị trả `50 01 type 01`.
     */
    fun startUpdate(info: Info, length: Int, crc: Int): ByteArray = ByteArray(20).also {
        it[0] = 0x50; it[1] = 0x01; it[2] = info.type.toByte()
        for (i in 0 until 4) it[3 + i] = (info.address shr (8 * i)).toByte()
        for (i in 0 until 4) it[7 + i] = (length shr (8 * i)).toByte()
        if (info.type == TYPE_SERVER) {
            it[11] = (info.binType and 0xFF).toByte(); it[12] = (info.binType shr 8).toByte()
            it[13] = (crc and 0xFF).toByte(); it[14] = (crc shr 8).toByte()
            it[15] = 0x01
        }
    }

    private val DOOG = byteArrayOf(0x44, 0x4F, 0x4F, 0x47)

    /** `DOOG 05 00`: bắt đầu (lên F0030002). */
    val DOOG_START = DOOG + byteArrayOf(0x05, 0x00)

    /** `DOOG 01 addr(LE32) len(LE32)` (13 byte): xoá vùng nhớ, sau khi thiết bị báo `05`. */
    fun doogErase(address: Long, length: Int): ByteArray = DOOG + byteArrayOf(0x01) +
        ByteArray(4) { (address shr (8 * it)).toByte() } + ByteArray(4) { (length shr (8 * it)).toByte() }

    /** `DOOG 02` đệm 20 byte: đã gửi hết khối dữ liệu. */
    val DOOG_DONE: ByteArray = (DOOG + byteArrayOf(0x02)).copyOf(20)

    /** `DOOG 03 crc(LE32)` đệm 20 byte: kiểm CRC-16/MODBUS cả file (sau khi thiết bị báo `02`). */
    fun doogCheck(crc: Int): ByteArray = (DOOG + byteArrayOf(0x03) + ByteArray(4) { (crc shr (8 * it)).toByte() }).copyOf(20)

    /** Chỉ chip Veepoo gốc (không JieLi / ZK) và `bigDataTranType` = 2 có mặt server / tuỳ chỉnh. */
    fun supported(f: VeepooFeatures) = f.nativeWatchFace && f.cpuType !in setOf(1, 3, 4)
}
