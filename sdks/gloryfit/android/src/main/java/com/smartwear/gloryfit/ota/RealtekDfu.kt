package com.smartwear.gloryfit.ota

import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeoutOrNull
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.spec.SecretKeySpec

/**
 * Giao thức DFU Realtek, silent mode, hai biến thể theo FFF3 (`protocolType`, chọn lớp ở `utils/a.java:78-99`):
 * - 0x0010: bản Kotlin của `firmware-flasher/flasher.py` (gói `s/` của SDK). Đặc tả: 07-ota-realtek.md §1.4, §6.
 * - 0x0014 (Y25 RB370L73ACV001205 thật báo `14 00`): gói `p/` của SDK (`p/a`, `p/b`, `p/d`, `p/f`). Đặc tả: 07 §8.2.
 *
 * Lớp này không đụng tới Android: nó nói chuyện qua [DfuLink] (ghi control/data) và nhận notify qua
 * [onControlNotification], nên chạy được trong unit test JVM. Phần BluetoothGatt nằm ở [RealtekDfuClient].
 */
object RealtekDfuSpec {
    private const val BASE = "-0000-1000-8000-00805f9b34fb"
    val SERVICE: UUID = UUID.fromString("00006287-3c17-d293-8e48-14fe2e4da212")
    val DATA: UUID = UUID.fromString("00006387-3c17-d293-8e48-14fe2e4da212")
    val CONTROL: UUID = UUID.fromString("00006487-3c17-d293-8e48-14fe2e4da212")
    /** Service OTA (chứa FFF1/FFD2/FFE0…/FFF4…); chỉ để ưu tiên khi tìm characteristic. */
    val OTA_SERVICE: UUID = UUID.fromString("0000d0ff-3c17-d293-8e48-14fe2e4da212")
    val INFO: UUID = UUID.fromString("0000fff1$BASE")
    val PROTOCOL: UUID = UUID.fromString("0000fff3$BASE")
    val MAC: UUID = UUID.fromString("0000ffd2$BASE")
    val BATTERY: UUID = UUID.fromString("00002a19$BASE")
    /** FFE0…FFEE: phiên bản image (SDK quét 0xFFE0 ≤ uuid < 0xFFEF). */
    val IMAGE_VERSIONS: List<UUID> = (0xFFE0 until 0xFFEF).map { UUID.fromString("0000%04x$BASE".format(it)) }
    /** FFF4, FFF5: kích thước section (SDK quét 0xFFF4 ≤ uuid < 0xFFF6). */
    val SECTION_SIZES: List<UUID> = (0xFFF4 until 0xFFF6).map { UUID.fromString("0000%04x$BASE".format(it)) }

    /** Khoá AES-256 đường truyền từ `UteOtaUtils.java` (KHÔNG phải khoá ký firmware). */
    internal val UTE_KEY: ByteArray = intArrayOf(
        78, 70, -8, -59, 9, 85, 84, 69, 95, 82, 75, 12, -47, -10, 16, -5,
        31, 103, 99, -33, -128, 122, 126, 112, -106, 13, 76, -45, 17, -114, 96, 26,
    ).map { it.toByte() }.toByteArray()

    const val OP_START_DFU = 0x01
    const val OP_RECEIVE_FW_IMAGE = 0x02
    const val OP_VALIDATE_FW_IMAGE = 0x03
    const val OP_ACTIVE_IMAGE_RESET = 0x04
    const val OP_REPORT_TARGET_IMAGE_INFO = 0x06
    const val OP_BUSY = 0x08
    const val OP_ENABLE_BUFFER_CHECK = 0x09
    const val OP_REPORT_BUFFER_CRC = 0x0A
    const val OP_CHECK_PUB_KEYS = 0x12
    const val OP_REPORT_IMAGE_NUMBER = 0x13

    /** Protocol 0x0014: opcode 0x12 là ReportImageNumberCmd (`m/m.java:39`: protocol 20/21 ⇒ 18), KHÔNG phải CHECK_PUB_KEYS. */
    const val OP_REPORT_IMAGE_NUMBER_X0014 = 0x12

    const val PROTOCOL_X0010 = 0x10
    const val PROTOCOL_X0014 = 0x14

    /** Gói dữ liệu chế độ thường (không buffer-check): `MAX_PACKET_SIZE` = `primaryMtuSize` = 20 (DfuConfig), app không bật MtuUpdate. */
    const val PLAIN_PACKET_SIZE = 20

    /**
     * Cỡ gói trong một buffer-check như SDK: `onMtuChanged` → `m/d.d(mtu)` → `j/c.a(cfg, mtu - 3)`, cơ chế mặc định
     * V2 (`DfuBufferCheckConfig.Builder` = 2): payload ATT `mtu - 3` > 16 ⇒ làm tròn xuống bội 16, ngược lại 16.
     * Chưa đổi được MTU (null) ⇒ 16 (`BaseDfuTask.s` mặc định).
     */
    fun bufferCheckPacketSize(mtu: Int?): Int {
        val payload = (mtu ?: return 16) - 3
        return if (payload > 16) payload / 16 * 16 else 16
    }

    /** CRC buffer-check: XOR các từ 16 bit LE rồi đảo byte (`buffer_crc`; byte lẻ cuối bị bỏ, như flasher.py). */
    fun bufferCrc(data: ByteArray): Int {
        var c = 0
        var i = 0
        while (i < data.size - 1) {
            c = c xor ((data[i].toInt() and 0xFF) or ((data[i + 1].toInt() and 0xFF) shl 8))
            i += 2
        }
        return ((c and 0xFF) shl 8) or (c ushr 8)
    }

    /**
     * Mã hoá AES-256 từng block 16 byte (ECB, không padding) như `encrypt_packet`: mode 0 chỉ block đầu, mode 1 mọi
     * block đủ 16 byte; đuôi < 16 byte giữ nguyên. Không bật AES ⇒ trả lại nguyên dữ liệu.
     */
    fun encryptPacket(data: ByteArray, caps: DfuCapabilities): ByteArray = encryptPacket(data, caps.aes, caps.aesMode)

    fun encryptPacket(data: ByteArray, aes: Boolean, aesMode: Int): ByteArray {
        if (!aes) return data
        val out = data.copyOf()
        val count = if (aesMode != 0) data.size / 16 else minOf(1, data.size / 16)
        if (count == 0) return out
        val cipher = Cipher.getInstance("AES/ECB/NoPadding").apply { init(Cipher.ENCRYPT_MODE, SecretKeySpec(UTE_KEY, "AES")) }
        for (i in 0 until count) cipher.doFinal(data, i * 16, 16, out, i * 16)
        return out
    }

    internal fun le16(v: Int) = byteArrayOf(v.toByte(), (v ushr 8).toByte())
    internal fun le32(v: Int) = byteArrayOf(v.toByte(), (v ushr 8).toByte(), (v ushr 16).toByte(), (v ushr 24).toByte())
    internal fun u16(b: ByteArray, i: Int) = (b[i].toInt() and 0xFF) or ((b[i + 1].toInt() and 0xFF) shl 8)
    internal fun u32(b: ByteArray, i: Int) = u16(b, i) or (u16(b, i + 2) shl 16)
}

class DfuException(message: String, cause: Throwable? = null) : Exception(message, cause)

/**
 * Năng lực DFU đọc từ FFF1 + FFF3 (protocol). 0x0010: `parseX0010`, như `capabilities()` của flasher.py.
 * 0x0014: `DeviceInfo.parseX0014` (`model/DeviceInfo.java:687-716`) + `p/b.java:10-81`; các trường chỉ có ở 0x0014 có giá trị
 * mặc định để code 0x0010 không đổi.
 */
data class DfuCapabilities(
    val ic: Int,
    val spec: Int,
    val buffer: Boolean,
    val aes: Boolean,
    val aesMode: Int,
    val copy: Boolean,
    val report: Boolean,
    val bank: Int,
    val tempKb: Int,
    val mtu: Int,
    val rws: Boolean,
    val compression: Boolean,
    val protocol: Int = RealtekDfuSpec.PROTOCOL_X0010,
    /** 0x0014 bit 3 cờ (`DeviceInfo.k`, getUpdateImageFlag). */
    val updateImageFlag: Int = 0,
    /** 0x0014 bit 4: có normal mode LE (`leNormalModeSupported`). */
    val leNormalMode: Boolean = false,
    /** 0x0014 bit 5: flash NAND (`nandFlashSupported`). */
    val nandFlash: Boolean = false,
    /** 0x0014 bit 7: phiên bản image 8 byte trong FFE0 (`longImageVersionSupported`). */
    val longImageVersion: Boolean = false,
    /** 0x0014 byte 3 bit 0-1 (`rwsMode`; 2 = RWS engaged ⇒ [rws]). */
    val rwsMode: Int = 0,
    /** 0x0014: vùng tạm nhận image, byte (FFF1 u16 × 4096, `p/f.java:173`). */
    val tempBufferBytes: Long = 0,
    /** 0x0014 byte 9: chỉ báo bank của boot image (`bootBankInfo`, 0 = không bank). */
    val bootBank: Int = 0,
    /** `updateMechanism` (`k/c.java:104-116`): 1 = từng image, 2 = all-in-one, 3 = all-in-one qua temp buffer. */
    val updateMechanism: Int = 0,
) {
    companion object {
        fun parse(info: ByteArray, protocol: Int): DfuCapabilities = when (protocol) {
            RealtekDfuSpec.PROTOCOL_X0010 -> parseX0010(info)
            RealtekDfuSpec.PROTOCOL_X0014 -> parseX0014(info)
            else -> throw DfuException("Chỉ hỗ trợ protocol 0x0010 và 0x0014 (thiết bị báo 0x%04X)".format(protocol))
        }

        private fun parseX0010(info: ByteArray): DfuCapabilities {
            if (info.size < 10) throw DfuException("Chỉ hỗ trợ protocol 0x0010 với FFF1 ít nhất 10 byte (FFF1 %d byte)".format(info.size))
            val spec = info[1].toInt() and 0x0F
            val flags = info[2].toInt() and 0xFF
            if (spec !in 4..8) throw DfuException("Spec $spec chưa được hỗ trợ (hỗ trợ 4–8)")
            return DfuCapabilities(
                ic = info[0].toInt() and 0xFF,
                spec = spec,
                buffer = flags and 1 != 0,
                aes = flags and 2 != 0,
                aesMode = (flags shr 2) and 1,
                copy = flags and 8 != 0,
                report = flags and 128 != 0,
                bank = info[5].toInt() and 0xFF,
                tempKb = info[4].toInt() and 0xFF,
                mtu = RealtekDfuSpec.u16(info, 6),
                rws = info[3].toInt() and 16 != 0,
                compression = info[9].toInt() and 4 != 0,
            )
        }

        /**
         * FFF1 của protocol 0x0014, đúng `p/b.a(byte[], 0)`:
         * `[0] icType · [1]&0x0F specVersion · [2] cờ: b0 bufferCheck, b1 AES, b2 AES mode, b3 updateImageFlag, b4 LE normal mode,
         * b5 NAND, b6 nén, b7 version dài · [3] b0-1 rwsMode, b2-3 (m) · [4..5] temp buffer (đơn vị 4 KB) · [6] bank normal
         * (0 ⇒ imageVersionIndicator 3, updateBank 0; 1 ⇒ 1/2; 2 ⇒ 2/1) · [7..8] MTU · [9] bank boot · [10..13] chỉ khi spec ≥ 4`.
         * Chỉ nhận spec 1..3: spec ≥ 4 thêm byte nén ở START_DFU (`p/d.java:191-193`) mà ta chưa kiểm chứng.
         */
        fun parseX0014(info: ByteArray): DfuCapabilities {
            if (info.size < 10) throw DfuException("Protocol 0x0014 cần FFF1 ít nhất 10 byte (FFF1 %d byte)".format(info.size))
            val spec = info[1].toInt() and 0x0F
            if (spec !in 1..3) throw DfuException("Protocol 0x0014 spec $spec chưa được hỗ trợ (hỗ trợ 1–3)")
            val flags = info[2].toInt() and 0xFF
            val b3 = info[3].toInt() and 0xFF
            val tempUnits = RealtekDfuSpec.u16(info, 4)
            val normalBank = info[6].toInt() and 0xFF
            val updateImageFlag = (flags shr 3) and 1
            // k/c.k(): bank normal ⇒ 2; ngược lại updateImageFlag 1 ⇒ (temp buffer > 0 ? 3 : 2); còn lại 1.
            val mechanism = when {
                normalBank != 0 -> 2
                updateImageFlag != 1 -> 1
                tempUnits > 0 -> 3
                else -> 2
            }
            return DfuCapabilities(
                ic = info[0].toInt() and 0xFF,
                spec = spec,
                buffer = flags and 1 != 0,
                aes = flags and 2 != 0,
                aesMode = (flags shr 2) and 1,
                copy = false,
                report = true, // p/d.java:222: ReportImageNumber gửi mỗi khi spec ≥ 1
                bank = normalBank,
                tempKb = tempUnits * 4,
                mtu = RealtekDfuSpec.u16(info, 7),
                rws = b3 and 3 == 2,
                compression = flags and 64 != 0,
                protocol = RealtekDfuSpec.PROTOCOL_X0014,
                updateImageFlag = updateImageFlag,
                leNormalMode = flags and 16 != 0,
                nandFlash = flags and 32 != 0,
                longImageVersion = flags and 128 != 0,
                rwsMode = b3 and 3,
                tempBufferBytes = tempUnits * 4096L,
                bootBank = info[9].toInt() and 0xFF,
                updateMechanism = mechanism,
            )
        }
    }
}

/**
 * Phiên bản + kích thước section từng image mà đồng hồ báo (FFE0…FFEE, FFF4…FFF5), protocol 0x0014.
 *
 * Cách SDK ghép và giải (`DeviceInfo.appendImageVersionBytes` `model/DeviceInfo.java:128-140`,
 * `ImageVersionInfoParser.a(int, byte[], byte[], boolean)` `model/ImageVersionInfoParser.java:48-106`):
 * - mỗi characteristic version: byte 0 = 0 ⇒ phần còn lại nối vào danh sách ACTIVE, khác 0 ⇒ INACTIVE; giá trị rỗng bỏ qua;
 * - danh sách = `[n] + n × (imageId LE16 + version)`; version 4 byte LE, riêng image 0x2790 (OTA Header) đọc big-endian, 8 byte LE
 *   nếu [DfuCapabilities.longImageVersion];
 * - section (FFF4 + FFF5 nối nguyên) = `[n] + n × (imageId LE16 + size LE32)`, SDK chỉ duyệt tới số mục của danh sách version.
 * Version lưu không dấu (SDK `toInt` có dấu rồi gán vào long, nên 0x96A01040 hiển thị FFFFFFFF96A01040 trong log SDK).
 */
data class DfuImageVersions(
    val active: Map<Int, Long>,
    val inactive: Map<Int, Long>,
    val sectionSizes: Map<Int, Long>,
) {
    fun summary(): String = buildString {
        fun id(i: Int) = "%04X".format(i)
        append("active[").append(active.entries.joinToString { "${id(it.key)}=%08X".format(it.value) }).append("]")
        if (inactive.isNotEmpty()) append(" inactive[").append(inactive.entries.joinToString { "${id(it.key)}=%08X".format(it.value) }).append("]")
        append(" section[").append(sectionSizes.entries.joinToString { "${id(it.key)}=${it.value}" }).append("]")
    }

    companion object {
        val EMPTY = DfuImageVersions(emptyMap(), emptyMap(), emptyMap())

        /** Image OTA Header: version đọc big-endian (`ImageVersionInfoParser.java:69-71`). */
        const val IMAGE_ID_OTA_HEADER = 0x2790

        fun parseX0014(versionValues: List<ByteArray>, sectionValues: List<ByteArray>, longVersion: Boolean): DfuImageVersions {
            val active = java.io.ByteArrayOutputStream()
            val inactive = java.io.ByteArrayOutputStream()
            for (v in versionValues) {
                if (v.isEmpty()) continue
                (if (v[0].toInt() == 0) active else inactive).write(v, 1, v.size - 1)
            }
            val sections = java.io.ByteArrayOutputStream().apply { sectionValues.forEach { write(it) } }.toByteArray()
            val (a, sa) = list(active.toByteArray(), sections, longVersion)
            val (i, si) = list(inactive.toByteArray(), sections, longVersion)
            return DfuImageVersions(a, i, sa + si)
        }

        private fun list(values: ByteArray, sections: ByteArray, longVersion: Boolean): Pair<Map<Int, Long>, Map<Int, Long>> {
            if (values.isEmpty()) return emptyMap<Int, Long>() to emptyMap()
            val count = values[0].toInt() and 0xFF
            val stride = if (longVersion) 10 else 6
            val versions = linkedMapOf<Int, Long>()
            val sizes = linkedMapOf<Int, Long>()
            var off = 1
            for (n in 0 until count) {
                if (off + stride <= values.size) {
                    val id = RealtekDfuSpec.u16(values, off)
                    versions[id] = when {
                        longVersion -> (0 until 8).fold(0L) { acc, k -> acc or ((values[off + 2 + k].toLong() and 0xFF) shl (8 * k)) }
                        id == IMAGE_ID_OTA_HEADER -> (0 until 4).fold(0L) { acc, k -> (acc shl 8) or (values[off + 2 + k].toLong() and 0xFF) }
                        else -> RealtekDfuSpec.u32(values, off + 2).toLong() and 0xFFFFFFFFL
                    }
                }
                if (off + 6 <= sections.size) {
                    sizes[RealtekDfuSpec.u16(sections, off)] = RealtekDfuSpec.u32(sections, off + 2).toLong() and 0xFFFFFFFFL
                }
                off += stride
            }
            return versions to sizes
        }
    }
}

/** Kết quả kiểm trước khi nạp ở protocol 0x0014 ([RealtekDfu.preflightX0014]). */
data class DfuPreflight(
    val deviceVersion: Long?,
    val fileVersion: Long?,
    val sectionSize: Long?,
) {
    /** File cùng phiên bản với image đang chạy (nạp lại cùng bản). SDK không chặn: app tắt version check (`RkOtaUtil.java:66`). */
    val sameVersion: Boolean get() = deviceVersion != null && deviceVersion == fileVersion

    fun summary(): String = "phiên bản đồng hồ %s, file %s%s; section %s".format(
        deviceVersion?.let { "0x%08X".format(it) } ?: "?", fileVersion?.let { "0x%08X".format(it) } ?: "?",
        if (sameVersion) " (CÙNG phiên bản: nạp lại)" else "", sectionSize?.toString() ?: "?",
    )
}

/** Phần image cần cho DFU (tách khỏi [RealtekImage] để test dùng image giả, như `FakeImage` của test Python). */
class DfuImage(val id: Int, val ic: Int, val ctrl: ByteArray, val keyHash: ByteArray, val wire: ByteArray, val version: Long? = null) {
    companion object {
        /** Chỉ nhận image đã qua [RealtekImage.verify] (gọi lại để chắc chắn). */
        fun from(image: RealtekImage): DfuImage {
            image.verify()
            return DfuImage(image.imageId, image.icType, image.ctrlHeader, image.pubKeyHash, image.wire, image.imageVersion)
        }
    }
}

/** Kênh ghi xuống thiết bị: control point 6487 (ghi có/không phản hồi theo property) và data 6387 (ghi không phản hồi). */
interface DfuLink {
    suspend fun writeControl(value: ByteArray)
    suspend fun writeData(value: ByteArray)
}

/**
 * Máy trạng thái DFU, bản port của lớp `Dfu` trong flasher.py. Notify của control point đưa vào [onControlNotification]:
 * `10 08 01/00` = thiết bị bận/rảnh, `10 <opcode> <status> …` = phản hồi.
 *
 * Bảo đảm an toàn: `ACTIVE_IMAGE_RESET (0x04)` chỉ được gửi sau khi `VALIDATE (0x03)` trả status 1; lỗi, hết giờ hoặc
 * huỷ coroutine đều dừng trước bước đó.
 */
class RealtekDfu(
    private val link: DfuLink,
    private val timeoutMs: Long = 15_000,
    /** Mốc chính (tiến độ, kết quả). */
    private val log: (String) -> Unit = {},
    /** Từng gói control TX/RX (nhiều dòng; null = tắt). */
    private val trace: ((String) -> Unit)? = null,
) {
    private val responses = Channel<ByteArray>(Channel.UNLIMITED)
    private val ready = MutableStateFlow(true)

    /** Thiết bị đang báo bận (`10 08 01`). */
    val busy: Boolean get() = !ready.value

    fun onControlNotification(value: ByteArray) {
        trace?.invoke("RX ${value.hex()}")
        if (value.size >= 3 && value[0].toInt() == 0x10 && value[1].toInt() == RealtekDfuSpec.OP_BUSY) {
            ready.value = value[2].toInt() != 1
        } else if (value.size >= 3 && value[0].toInt() == 0x10) {
            responses.trySend(value.copyOf())
        }
    }

    /** Kết nối mất: mọi lệnh đang chờ phản hồi kết thúc ngay bằng lỗi thay vì chờ hết giờ. */
    fun fail(cause: Throwable) {
        responses.close(DfuException("Mất kết nối DFU: ${cause.message}", cause))
        ready.value = true
    }

    private suspend fun awaitReady() {
        withTimeoutOrNull(timeoutMs) { ready.first { it } } ?: throw DfuException("Thiết bị báo bận quá ${timeoutMs / 1000} giây")
    }

    suspend fun send(command: ByteArray) {
        awaitReady()
        trace?.invoke("TX control ${command.hex()}")
        link.writeControl(command)
    }

    /** Gửi lệnh và chờ phản hồi cùng opcode; trả `status + phần còn lại` (rsp[2:]). Status ngoài [statuses] ⇒ lỗi. */
    suspend fun request(command: ByteArray, timeoutMs: Long = this.timeoutMs, statuses: Set<Int> = setOf(1)): ByteArray {
        send(command)
        val op = command[0].toInt() and 0xFF
        val rsp = withTimeoutOrNull(timeoutMs) { receiveFor(op) }
            ?: throw DfuException("Hết thời gian chờ phản hồi opcode 0x%02x".format(op))
        val status = rsp[2].toInt() and 0xFF
        if (status !in statuses) {
            val extra = if (op == RealtekDfuSpec.OP_CHECK_PUB_KEYS) " (khoá không được thiết bị tin cậy)" else ""
            throw DfuException("Opcode 0x%02x bị từ chối: status=0x%02x%s".format(op, status, extra))
        }
        return rsp.copyOfRange(2, rsp.size)
    }

    /**
     * Truyền [image] theo silent mode. Chọn đường theo [DfuCapabilities.protocol]:
     *
     * **0x0010** — đúng thứ tự `Dfu.upload` của flasher.py:
     * `0x12` CHECK_PUB_KEYS (spec ≥ 6) → `0x09` (nếu buffer-check) → `0x06` (offset resume) → `0x13` (nếu report) → `0x01` (khi
     * offset = 0) → `0x02` → stream (buffer-check: khối [block] chia gói 16 B + `0x0A` CRC, tối đa 3 lần; không buffer-check: gói
     * 20 B) → `0x03` VALIDATE → `0x04` ACTIVE_IMAGE_RESET.
     *
     * **0x0014** — xem [uploadX0014].
     *
     * `0x04` chỉ gửi khi [activate] và VALIDATE trả status 1. [mtu] = MTU ATT đã thương lượng (chỉ dùng cho cỡ gói buffer-check
     * của 0x0014). [progress] nhận (byte đã xác nhận, tổng byte). Trả true nếu đã gửi lệnh kích hoạt.
     */
    suspend fun upload(
        image: DfuImage,
        caps: DfuCapabilities,
        packetDelayMs: Long = 10,
        activate: Boolean = true,
        mtu: Int? = null,
        progress: (sent: Int, total: Int) -> Unit = { _, _ -> },
    ): Boolean {
        if (caps.ic != image.ic || caps.rws) throw DfuException("Chip không khớp (thiết bị ic=0x%02X, file ic=0x%02X) hoặc thiết bị RWS chưa hỗ trợ".format(caps.ic, image.ic))
        return when (caps.protocol) {
            RealtekDfuSpec.PROTOCOL_X0010 -> uploadX0010(image, caps, packetDelayMs, activate, progress)
            RealtekDfuSpec.PROTOCOL_X0014 -> uploadX0014(image, caps, packetDelayMs, activate, mtu, progress)
            else -> throw DfuException("Protocol 0x%04X chưa được hỗ trợ".format(caps.protocol))
        }
    }

    private suspend fun uploadX0010(
        image: DfuImage,
        caps: DfuCapabilities,
        packetDelayMs: Long,
        activate: Boolean,
        progress: (sent: Int, total: Int) -> Unit,
    ): Boolean {
        val wire = image.wire
        if (caps.spec >= 6) {
            request(byteArrayOf(RealtekDfuSpec.OP_CHECK_PUB_KEYS.toByte(), 1) + RealtekDfuSpec.le16(image.id) + image.keyHash)
            log("Thiết bị chấp nhận khoá ${image.keyHash.hex("")}")
        }
        val blockSize = if (caps.buffer) enableBufferCheck() else 0
        val info = request(byteArrayOf(RealtekDfuSpec.OP_REPORT_TARGET_IMAGE_INFO.toByte()) + RealtekDfuSpec.le16(image.id))
        if (info.size < 9) throw DfuException("Đáp target image info quá ngắn; không đoán offset")
        val resumeRaw = RealtekDfuSpec.u32(info, 5).toLong() and 0xFFFFFFFFL
        if (resumeRaw > wire.size) throw DfuException("Resume offset $resumeRaw ngoài image")
        val offset = resumeRaw.toInt()
        if (offset in 1 until 12) throw DfuException("Resume offset $offset không hợp lệ")
        if (caps.report) send(byteArrayOf(RealtekDfuSpec.OP_REPORT_IMAGE_NUMBER.toByte()) + RealtekDfuSpec.le16(image.id) + byteArrayOf(1, 1))
        if (offset == 0) startDfu(image, caps)
        send(receiveCommand(image.id, offset))
        stream(image, caps, offset, blockSize, if (blockSize > 0) 16 else RealtekDfuSpec.PLAIN_PACKET_SIZE, packetDelayMs, progress)
        validate(image)
        return activate(activate, byteArrayOf(RealtekDfuSpec.OP_ACTIVE_IMAGE_RESET.toByte()))
    }

    /**
     * Protocol 0x0014, đúng `p/d.R()` (`p/d.java:211-240`) + `p/f.i()` (`p/f.java:131-151`) với cấu hình của GloryFitPro
     * (`RkOtaUtil.startOta`: silent 16, version check tắt; còn lại mặc định `DfuConfig`):
     * 1. `0x09` ENABLE_BUFFER_CHECK nếu cờ bit 0 FFF1 (`p/d.H()`); đáp `[status, maxBufferSize LE16]` (`m/h.java:42-47`).
     * 2. `0x06 id` REPORT_TARGET_IMAGE_INFO; đáp 7 byte `[status, version LE16, offset LE32]` hoặc 11 byte
     *    `[status, version LE32, offset LE32, bufferCheckOffset LE16]` (`t/d.java:19-45`).
     * 3. Offset resume bị bỏ: `isBreakpointResumeEnabled` mặc định false (`DfuConfig` j) ⇒ `m/e.A()` đặt offset = 0, luôn START_DFU.
     * 4. `0x12 id 01 01` ReportImageNumber (spec ≥ 1, `m/e.D()`, không chờ đáp). KHÔNG có CHECK_PUB_KEYS ở protocol này.
     * 5. `0x01` + ctrl 12 B + `00 00 00 00` (AES nếu cờ AES) — `p/d.Q()`; status phải 1.
     * 6. `0x02 id offset` (`m/n.java:37-42`, không chờ đáp) → stream: buffer-check khối = maxBufferSize, gói = MTU−3 làm tròn
     *    16 ([RealtekDfuSpec.bufferCheckPacketSize]), CRC `0x0A` như 0x0010; không buffer-check: gói 20 B.
     * 7. `0x03 id 01` VALIDATE (`m/q.java:40-58`) → `0x04 00` ACTIVE_IMAGE_RESET (`p/d.E()`, `p/d.java:31-33`).
     */
    private suspend fun uploadX0014(
        image: DfuImage,
        caps: DfuCapabilities,
        packetDelayMs: Long,
        activate: Boolean,
        mtu: Int?,
        progress: (sent: Int, total: Int) -> Unit,
    ): Boolean {
        if (caps.spec !in 1..3) throw DfuException("Protocol 0x0014 spec ${caps.spec} chưa được hỗ trợ")
        if (caps.nandFlash) throw DfuException("Thiết bị dùng flash NAND; image này là NOR (BaseBinInputStream.checkNAndFlashFeature)")
        val blockSize = if (caps.buffer) enableBufferCheck() else 0
        val info = request(byteArrayOf(RealtekDfuSpec.OP_REPORT_TARGET_IMAGE_INFO.toByte()) + RealtekDfuSpec.le16(image.id))
        val (deviceVersion, reported) = when (info.size) {
            7 -> RealtekDfuSpec.u16(info, 1).toLong() to (RealtekDfuSpec.u32(info, 3).toLong() and 0xFFFFFFFFL)
            11 -> (RealtekDfuSpec.u32(info, 1).toLong() and 0xFFFFFFFFL) to (RealtekDfuSpec.u32(info, 5).toLong() and 0xFFFFFFFFL)
            else -> throw DfuException("Đáp target image info ${info.size} byte (chờ 7 hoặc 11); không đoán offset")
        }
        log("Target image 0x%04X: version 0x%X, offset thiết bị báo %d; SDK tắt resume ⇒ nạp lại từ 0".format(image.id, deviceVersion, reported))
        send(byteArrayOf(RealtekDfuSpec.OP_REPORT_IMAGE_NUMBER_X0014.toByte()) + RealtekDfuSpec.le16(image.id) + byteArrayOf(1, 1))
        startDfu(image, caps)
        send(receiveCommand(image.id, 0))
        val packetSize = if (blockSize > 0) RealtekDfuSpec.bufferCheckPacketSize(mtu) else RealtekDfuSpec.PLAIN_PACKET_SIZE
        stream(image, caps, 0, blockSize, packetSize, packetDelayMs, progress)
        validate(image)
        return activate(activate, byteArrayOf(RealtekDfuSpec.OP_ACTIVE_IMAGE_RESET.toByte(), 0))
    }

    /** `0x09`: đáp `[status=1, maxBufferSize LE16]`; trả cỡ khối buffer-check. */
    private suspend fun enableBufferCheck(): Int {
        val rsp = request(byteArrayOf(RealtekDfuSpec.OP_ENABLE_BUFFER_CHECK.toByte()))
        if (rsp.size < 3) throw DfuException("Đáp buffer-check quá ngắn")
        val blockSize = RealtekDfuSpec.u16(rsp, 1)
        if (blockSize !in 16..65520 || blockSize % 16 != 0) throw DfuException("Buffer size $blockSize không hỗ trợ")
        return blockSize
    }

    private suspend fun startDfu(image: DfuImage, caps: DfuCapabilities) {
        val header = image.ctrl + ByteArray(4) // mode = 0, padding = 0
        request(byteArrayOf(RealtekDfuSpec.OP_START_DFU.toByte()) + RealtekDfuSpec.encryptPacket(header, caps))
    }

    /** Stream từ [start]: buffer-check ([blockSize] > 0, gói [packetSize] + CRC `0x0A`, tối đa 3 lần) hoặc gói [packetSize]. */
    private suspend fun stream(
        image: DfuImage,
        caps: DfuCapabilities,
        start: Int,
        blockSize: Int,
        packetSize: Int,
        packetDelayMs: Long,
        progress: (sent: Int, total: Int) -> Unit,
    ) {
        val wire = image.wire
        var offset = start
        log("Truyền ${wire.size} byte; bắt đầu tại $offset; buffer-check ${if (blockSize > 0) "$blockSize B" else "tắt"}; gói $packetSize B; AES ${if (caps.aes) "mode ${caps.aesMode}" else "tắt"}")
        var lastPercent = -1
        progress(offset, wire.size)
        while (offset < wire.size) {
            val end = minOf(offset + (if (blockSize > 0) blockSize else packetSize), wire.size)
            // Mã hoá cả buffer một lần như SDK (mode 0: chỉ 16 byte đầu buffer; mode 1: mọi block 16 byte), rồi mới cắt gói.
            // CRC buffer tính trên dữ liệu ĐÃ mã hoá.
            val block = RealtekDfuSpec.encryptPacket(wire.copyOfRange(offset, end), caps)
            for (attempt in 0 until 3) {
                var i = 0
                while (i < block.size) {
                    awaitReady()
                    link.writeData(block.copyOfRange(i, minOf(i + packetSize, block.size)))
                    if (packetDelayMs > 0) delay(packetDelayMs)
                    i += packetSize
                }
                if (blockSize == 0) break
                val rsp = request(
                    byteArrayOf(RealtekDfuSpec.OP_REPORT_BUFFER_CRC.toByte()) + RealtekDfuSpec.le16(block.size) + RealtekDfuSpec.le16(RealtekDfuSpec.bufferCrc(block)),
                    statuses = setOf(1, 5, 6),
                )
                if (rsp.size < 5) throw DfuException("Đáp buffer CRC quá ngắn")
                val target = RealtekDfuSpec.u32(rsp, 1)
                if (rsp[0].toInt() == 1) {
                    if (target != end) throw DfuException("Offset ACK $target khác dự kiến $end; dừng truyền")
                    break
                }
                if (attempt == 2) throw DfuException("Buffer CRC lỗi sau 3 lần gửi")
                if (target != offset) throw DfuException("Offset retry $target không khớp $offset; dừng để tránh gửi sai vị trí")
                send(receiveCommand(image.id, offset))
                log("Gửi lại buffer tại $offset")
            }
            offset = end
            progress(offset, wire.size)
            val percent = (offset.toLong() * 100 / wire.size).toInt()
            if (percent != lastPercent) {
                log("Tiến độ $percent% ($offset/${wire.size})")
                lastPercent = percent
            }
        }
    }

    private suspend fun validate(image: DfuImage) {
        request(byteArrayOf(RealtekDfuSpec.OP_VALIDATE_FW_IMAGE.toByte()) + RealtekDfuSpec.le16(image.id) + byteArrayOf(1), timeoutMs = VALIDATE_TIMEOUT_MS)
        log("Thiết bị xác thực image thành công")
    }

    /** Chỉ gọi SAU khi [validate] trả status 1. */
    private suspend fun activate(activate: Boolean, command: ByteArray): Boolean {
        if (!activate) {
            log("Chưa kích hoạt (activate = false)")
            return false
        }
        try {
            send(command)
            log("Đã gửi kích hoạt/khởi động lại. Cần kết nối lại để xác nhận phiên bản")
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            // Đồng hồ khởi động lại ngay khi nhận 0x04 nên lần ghi có phản hồi có thể không về kịp. SDK Realtek cũng bỏ qua
            // (`isWaitActiveCmdAckEnabled` = false: "active cmd has no response, ignore").
            log("Lệnh kích hoạt không có xác nhận ghi (${e.message}); đồng hồ có thể đã khởi động lại")
        }
        return true
    }

    /** Phản hồi kế tiếp của [op]; phản hồi opcode khác (ví dụ của 0x13 gửi không chờ) bị bỏ qua. Kênh đóng ⇒ ném lý do đóng. */
    private suspend fun receiveFor(op: Int): ByteArray {
        while (true) {
            val r = responses.receive()
            if ((r[1].toInt() and 0xFF) == op) return r
            trace?.invoke("Bỏ phản hồi opcode khác: ${r.hex()}")
        }
    }

    private fun receiveCommand(id: Int, offset: Int) =
        byteArrayOf(RealtekDfuSpec.OP_RECEIVE_FW_IMAGE.toByte()) + RealtekDfuSpec.le16(id) + RealtekDfuSpec.le32(offset)

    companion object {
        /**
         * Validate: 30 s như flasher.py (SDK 0x0010: max(30 s, (MB+1)·4 s + 5 s) = 30 s cho file 1,6 MB; SDK 0x0014 chỉ chờ
         * `notificationTimeout` 10 s, `p/d.java:444-458` — ta chờ lâu hơn, không hại).
         */
        const val VALIDATE_TIMEOUT_MS = 30_000L

        /**
         * Kiểm trước khi gửi lệnh ghi nào ở protocol 0x0014, từ những gì SDK đọc trong `p/f.T()` (FFF1/FFD2/FFE0…/FFF4…) và
         * `p/c.loadImageBinInfo` (đường single image):
         * - ic file = ic thiết bị (`BinInfo.checkIcType`, icCheck bật mặc định trong `DfuConfig`);
         * - thiết bị không NAND (image không có TLV 0x21 ⇒ NOR, `BaseBinInputStream.checkNAndFlashFeature`);
         * - image ≤ section size thiết bị báo cho imageId đó (`c/f.java:18-29`; SDK chỉ kiểm cho ic 4/6/7/8/10/13, ta kiểm thêm);
         * - image ≤ temp buffer khi cơ chế là all-in-one qua temp buffer (`p/f.java:173`; ta kiểm thêm).
         * KHÔNG chặn cùng phiên bản hay hạ cấp: GloryFitPro tắt version check (`RkOtaUtil.java:66` → `k/b.java:153`).
         */
        fun preflightX0014(image: DfuImage, caps: DfuCapabilities, versions: DfuImageVersions): DfuPreflight {
            if (caps.protocol != RealtekDfuSpec.PROTOCOL_X0014) throw DfuException("preflightX0014 chỉ dùng cho protocol 0x0014")
            if (caps.ic != image.ic) throw DfuException("Chip không khớp (thiết bị ic=0x%02X, file ic=0x%02X)".format(caps.ic, image.ic))
            if (caps.nandFlash) throw DfuException("Thiết bị dùng flash NAND; image này là NOR")
            val section = versions.sectionSizes[image.id]
            if (section != null && section > 0 && image.wire.size > section)
                throw DfuException("Image ${image.wire.size} byte vượt section $section byte của image 0x%04X".format(image.id))
            if (caps.updateMechanism == 3 && caps.tempBufferBytes > 0 && image.wire.size > caps.tempBufferBytes)
                throw DfuException("Image ${image.wire.size} byte vượt temp buffer ${caps.tempBufferBytes} byte")
            return DfuPreflight(versions.active[image.id], image.version, section)
        }
    }
}

internal fun ByteArray.hex(separator: String = " "): String = joinToString(separator) { "%02x".format(it) }
