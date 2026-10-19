package com.smartwear.qring.protocol

/**
 * Khung lệnh 16 byte trên kênh 6e400002/6e400003:
 * `[0]=cmd  [1..14]=payload (thiếu thì đệm 0)  [15]=checksum = Σ byte[0..14] & 0xFF`.
 * Bit 7 của byte cmd trong phản hồi là cờ lỗi. Xem sdks/qring/docs/01-connection.md §3.3.
 */
class Packet private constructor(val bytes: ByteArray) {

    /** Mã lệnh, đã bỏ cờ lỗi. */
    val command: Int get() = bytes[0].toInt() and 0x7F

    val isError: Boolean get() = bytes[0].toInt() and ERROR_FLAG != 0

    /** 14 byte payload (byte 1..14). */
    val payload: ByteArray get() = bytes.copyOfRange(1, 15)

    /** Byte payload thứ [index] (0..13) dưới dạng số không dấu. */
    fun u8(index: Int): Int = bytes[1 + index].toInt() and 0xFF

    override fun toString(): String = bytes.joinToString(" ") { "%02X".format(it) }

    companion object {
        const val SIZE = 16
        const val ERROR_FLAG = 0x80

        fun of(command: Int, vararg payload: Int): Packet =
            of(command, ByteArray(payload.size) { payload[it].toByte() })

        fun of(command: Int, payload: ByteArray): Packet {
            require(command in 0..0xFF) { "command ngoài khoảng: $command" }
            require(payload.size <= 14) { "payload tối đa 14 byte, nhận ${payload.size}" }
            val b = ByteArray(SIZE)
            b[0] = command.toByte()
            payload.copyInto(b, 1)
            b[15] = checksum(b).toByte()
            return Packet(b)
        }

        /** Trả về null nếu không đúng 16 byte hoặc sai checksum. */
        fun parse(raw: ByteArray): Packet? {
            if (raw.size != SIZE) return null
            if (checksum(raw) != (raw[15].toInt() and 0xFF)) return null
            return Packet(raw.copyOf())
        }

        fun checksum(b: ByteArray): Int {
            var sum = 0
            for (i in 0 until 15) sum += b[i].toInt() and 0xFF
            return sum and 0xFF
        }
    }
}
