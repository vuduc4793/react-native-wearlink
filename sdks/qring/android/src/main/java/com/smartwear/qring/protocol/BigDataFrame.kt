package com.smartwear.qring.protocol

/**
 * Khung "big data" trên service de5bf728 (ghi de5bf72a, notify de5bf729):
 * `BC  cmd  len(LE16)  crc16(LE16)  payload…`, CRC là CRC-16/MODBUS của payload.
 * Khi gửi, cả khung được cắt thành các đoạn bằng kích thước gói (mặc định 20), chỉ đoạn đầu có `BC`.
 * Xem sdks/qring/docs/01-connection.md §5.
 */
class BigDataFrame(val command: Int, val payload: ByteArray) {

    fun encode(): ByteArray {
        val crc = if (payload.isEmpty()) 0xFFFF else crc16Modbus(payload)
        val out = ByteArray(HEADER_SIZE + payload.size)
        out[0] = MAGIC.toByte()
        out[1] = command.toByte()
        out[2] = (payload.size and 0xFF).toByte()
        out[3] = (payload.size shr 8 and 0xFF).toByte()
        out[4] = (crc and 0xFF).toByte()
        out[5] = (crc shr 8 and 0xFF).toByte()
        payload.copyInto(out, HEADER_SIZE)
        return out
    }

    /** Cắt khung thành các đoạn [chunkSize] byte để ghi lần lượt. */
    fun chunks(chunkSize: Int): List<ByteArray> {
        val data = encode()
        return (data.indices step chunkSize).map { data.copyOfRange(it, minOf(it + chunkSize, data.size)) }
    }

    companion object {
        const val MAGIC = 0xBC
        const val HEADER_SIZE = 6

        fun crc16Modbus(data: ByteArray): Int {
            var crc = 0xFFFF
            for (b in data) {
                crc = crc xor (b.toInt() and 0xFF)
                repeat(8) {
                    crc = if (crc and 1 != 0) (crc ushr 1) xor 0xA001 else crc ushr 1
                }
            }
            return crc and 0xFFFF
        }
    }
}

/**
 * Ghép các notify trên de5bf729 thành khung hoàn chỉnh. Không an toàn đa luồng; gọi từ một luồng.
 * Khác SDK gốc: kiểm tra CRC và bỏ khung hỏng thay vì kẹt lại.
 */
class BigDataAssembler(private val onFrame: (BigDataFrame) -> Unit) {
    private var buffer = ByteArray(0)
    private var expected = -1

    fun feed(chunk: ByteArray) {
        if (expected < 0) {
            if (chunk.size < BigDataFrame.HEADER_SIZE || chunk[0].toInt() and 0xFF != BigDataFrame.MAGIC) return
            expected = BigDataFrame.HEADER_SIZE + ((chunk[2].toInt() and 0xFF) or ((chunk[3].toInt() and 0xFF) shl 8))
            buffer = chunk
        } else {
            buffer += chunk
        }
        if (buffer.size >= expected) {
            val frame = buffer.copyOf(expected)
            reset()
            emit(frame)
        }
    }

    fun reset() {
        buffer = ByteArray(0)
        expected = -1
    }

    private fun emit(raw: ByteArray) {
        val payload = raw.copyOfRange(BigDataFrame.HEADER_SIZE, raw.size)
        val crc = (raw[4].toInt() and 0xFF) or ((raw[5].toInt() and 0xFF) shl 8)
        val expectedCrc = if (payload.isEmpty()) 0xFFFF else BigDataFrame.crc16Modbus(payload)
        // Theo tài liệu, SDK gốc không kiểm CRC khi nhận; tạm thời chỉ cảnh báo cho đến khi xác minh trên nhẫn thật.
        if (crc != expectedCrc) com.smartwear.core.SmartWearLog.w("Big-data cmd=${raw[1]} sai CRC: ${"%04X".format(crc)} != ${"%04X".format(expectedCrc)}")
        onFrame(BigDataFrame(raw[1].toInt() and 0xFF, payload))
    }
}
