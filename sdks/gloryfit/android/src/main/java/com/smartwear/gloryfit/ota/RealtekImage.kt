package com.smartwear.gloryfit.ota

import java.math.BigInteger
import java.security.KeyFactory
import java.security.MessageDigest
import java.security.Signature
import java.security.spec.ECPoint
import java.security.spec.ECPublicKeySpec
import java.security.AlgorithmParameters
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec

/**
 * File OTA Realtek (`.bin`), ví dụ `RB370L73AC_V001205.bin` của Y25. Bố cục và cách kiểm: sdks/gloryfit/docs/05-firmware-analysis.md §1.
 *
 * ```
 * file  = MP header TLV (512 B) + image
 * image = auth (0x130: FF×16, chữ ký 256 B, SHA-256 32 B) + ctrl (12 B) + phần header còn lại (tới 0x400) + payload
 * ```
 *
 * Chỉ đọc và kiểm tra; không ký lại (không có khoá bí mật của hãng). Trước khi nạp qua DFU, dùng [load]
 * (= [parse] + [verify]): từ chối mọi file không qua đủ kiểm tra như `firmware-flasher/flasher.py` (`Image`).
 */
class RealtekImage private constructor(val bytes: ByteArray) {

    /** Offset của image trong file (0x200 nếu có MP header). */
    val imageOffset: Int = if (hasMpHeader(bytes)) MP_HEADER_SIZE else 0

    /** Các trường TLV của MP header: id → giá trị. */
    val mp: Map<Int, ByteArray> = if (imageOffset > 0) parseTlv(bytes) else emptyMap()

    private fun u8(i: Int) = bytes[i].toInt() and 0xFF
    private fun u16(i: Int) = u8(i) or (u8(i + 1) shl 8)
    private fun u32(i: Int) = u16(i).toLong() or (u16(i + 2).toLong() shl 16)
    private val ctrl get() = imageOffset + AUTH_SIZE

    val crc16: Int get() = u16(ctrl)
    val icType: Int get() = u8(ctrl + 2)
    val secureVersion: Int get() = u8(ctrl + 3)
    val ctrlFlag: Int get() = u16(ctrl + 4)
    val imageId: Int get() = u16(ctrl + 6)
    val payloadLength: Long get() = u32(ctrl + 8)
    val encrypted: Boolean get() = ctrlFlag and 0x0002 != 0

    /** Độ dài image (không tính MP header). */
    val imageLength: Int get() = bytes.size - imageOffset

    /** 12 byte ctrl header, gửi kèm lệnh START_DFU. */
    val ctrlHeader: ByteArray get() = bytes.copyOfRange(ctrl, ctrl + CTRL_SIZE)

    /** Phiên bản image (TLV 0x16), dạng số thô như app Realtek đọc. */
    val imageVersion: Long? get() = mp[0x16]?.let { v -> v.foldIndexed(0L) { i, acc, b -> acc or ((b.toLong() and 0xFF) shl (8 * i)) } }

    val partNumber: String? get() = mp[0x03]?.let { String(it).trimEnd('\u0000') }

    /** Khoá công khai ECDSA P-256 dạng không nén `04‖X‖Y` (image + 0x1A0). */
    val publicKey: ByteArray get() = bytes.copyOfRange(imageOffset + PUBKEY_OFFSET, imageOffset + PUBKEY_OFFSET + 65)

    /** 4 byte hash khoá gửi trong lệnh CHECK_PUB_KEYS (0x12): TLV 0x1D, bằng 4 byte cuối SHA-256(khoá). */
    val pubKeyHash: ByteArray get() = mp[0x1D] ?: sha256(publicKey).copyOfRange(28, 32)

    // ---------- Kiểm tra ----------

    /** CRC-16/ARC trên image[0x132 : hết]. */
    fun crcOk(): Boolean = crc16Arc(bytes, ctrl + 2, bytes.size) == crc16

    /** SHA-256 trên image[0x130 : hết], lưu ở image + 0x110. */
    fun shaOk(): Boolean = sha256(bytes, ctrl, bytes.size).contentEquals(bytes.copyOfRange(imageOffset + SHA_OFFSET, imageOffset + SHA_OFFSET + 32))

    /** Chữ ký ECDSA P-256 (`r‖s` ở image + 0x10) trên image[0x110 : hết], bằng khoá trong chính file. */
    fun signatureOk(): Boolean = runCatching {
        val sig = Signature.getInstance("SHA256withECDSA")
        sig.initVerify(ecPublicKey(publicKey))
        sig.update(bytes, imageOffset + SHA_OFFSET, bytes.size - imageOffset - SHA_OFFSET)
        val r = bytes.copyOfRange(imageOffset + SIG_OFFSET, imageOffset + SIG_OFFSET + 32)
        val s = bytes.copyOfRange(imageOffset + SIG_OFFSET + 32, imageOffset + SIG_OFFSET + 64)
        sig.verify(derSignature(r, s))
    }.getOrDefault(false)

    /** Khoá trong file có khớp hash 0x1D của MP header không. */
    fun pubKeyHashOk(): Boolean = mp[0x1D]?.contentEquals(sha256(publicKey).copyOfRange(28, 32)) ?: true

    /** Dòng byte gửi qua DFU: image từ auth header tới hết (MP header 512 B KHÔNG gửi), như `Image.wire` của flasher.py. */
    val wire: ByteArray by lazy { bytes.copyOfRange(imageOffset, bytes.size) }

    /** SHA-256 của cả file (để đối chiếu với bản đã biết). */
    val fileSha256: String by lazy { sha256(bytes).joinToString("") { "%02x".format(it) } }

    /**
     * Kiểm tra nghiêm ngặt trước khi nạp, đúng thứ tự `Image.__init__` của flasher.py, thêm ghim khoá [TRUSTED_PUBKEY_HASH]:
     * MP header TLV hợp lệ, ic 0x11, image App 0x2793, không mã hoá, magic, độ dài payload, độ dài/imageId/hash khoá trong
     * MP header, CRC-16/ARC, SHA-256, chữ ký ECDSA P-256. Sai một mục ⇒ ném [RealtekImageException].
     */
    fun verify(): RealtekImage {
        fun fail(reason: RealtekImageException.Reason, message: String): Nothing = throw RealtekImageException(reason, message)
        if (bytes.size < MP_HEADER_SIZE + HEADER_SIZE || !hasMpHeader(bytes))
            fail(RealtekImageException.Reason.FORMAT, "Chỉ hỗ trợ image App Realtek có MP header 512 byte")
        val tlv = strictTlv(bytes) ?: fail(RealtekImageException.Reason.FORMAT, "MP TLV hỏng hoặc trùng trường")
        if (icType != IC_TYPE_Y25 || imageId != IMAGE_ID_APP || encrypted)
            fail(RealtekImageException.Reason.CHIP, "Chỉ hỗ trợ App ic=0x11, imageId=0x2793, image không mã hoá (file: ic=0x%02X id=0x%04X flag=0x%04X)".format(icType, imageId, ctrlFlag))
        if (u32(imageOffset + MAGIC_OFFSET) != IMAGE_MAGIC) fail(RealtekImageException.Reason.FORMAT, "Magic Realtek không đúng")
        if (payloadLength != (bytes.size - MP_HEADER_SIZE - HEADER_SIZE).toLong()) fail(RealtekImageException.Reason.LENGTH, "Độ dài payload không khớp")
        val wireLength = le(bytes.size - MP_HEADER_SIZE, 4)
        for (tag in intArrayOf(0x04, 0x14)) {
            if (!tlv[tag].contentEqualsOrNull(wireLength)) fail(RealtekImageException.Reason.LENGTH, "MP length 0x%02x không khớp".format(tag))
        }
        if (!tlv[0x12].contentEqualsOrNull(le(imageId, 2))) fail(RealtekImageException.Reason.CHIP, "MP imageId không khớp")
        val keyHash = sha256(publicKey).copyOfRange(28, 32)
        if (!tlv[0x1D].contentEqualsOrNull(keyHash)) fail(RealtekImageException.Reason.KEY_HASH, "Hash public key không khớp MP header")
        if (hex(keyHash) != TRUSTED_PUBKEY_HASH)
            fail(RealtekImageException.Reason.UNTRUSTED_KEY, "Khoá ký ${hex(keyHash)} không phải khoá của firmware Y25 gốc ($TRUSTED_PUBKEY_HASH)")
        if (!crcOk()) fail(RealtekImageException.Reason.CRC, "CRC16 sai")
        if (!shaOk()) fail(RealtekImageException.Reason.SHA, "SHA256 sai")
        if (!signatureOk()) fail(RealtekImageException.Reason.SIGNATURE, "Chữ ký ECDSA không hợp lệ")
        return this
    }

    fun summary(): String = "image 0x%04X ic 0x%02X, %d byte, version %s, key hash %s, CRC %s, SHA %s, chữ ký %s".format(
        imageId, icType, imageLength, imageVersion?.let { "0x%08X".format(it) } ?: "?",
        pubKeyHash.joinToString("") { "%02X".format(it) },
        ok(crcOk()), ok(shaOk()), ok(signatureOk()),
    )

    private fun ok(b: Boolean) = if (b) "đúng" else "SAI"

    private fun ByteArray?.contentEqualsOrNull(other: ByteArray) = this != null && contentEquals(other)

    companion object {
        const val MP_HEADER_SIZE = 0x200
        const val AUTH_SIZE = 0x130
        const val CTRL_SIZE = 12
        const val HEADER_SIZE = 0x400
        private const val SIG_OFFSET = 0x10
        private const val SHA_OFFSET = 0x110
        private const val PUBKEY_OFFSET = 0x1A0
        private const val MAGIC_OFFSET = 0x160
        private const val IMAGE_MAGIC = 0x5A5A12A5L

        /** Chip của Y25 (`ic_type` trong ctrl header, cũng là byte 0 của FFF1). */
        const val IC_TYPE_Y25 = 0x11

        /** 4 byte cuối SHA-256 của khoá công khai trong firmware Y25 gốc (TLV 0x1D). File ký bằng khoá khác bị từ chối. */
        const val TRUSTED_PUBKEY_HASH = "985B8AC4"

        /** Đọc + kiểm tra đầy đủ ([verify]); dùng hàm này trước mọi lần nạp. */
        fun load(bytes: ByteArray): RealtekImage {
            if (bytes.size < MP_HEADER_SIZE + HEADER_SIZE)
                throw RealtekImageException(RealtekImageException.Reason.FORMAT, "Chỉ hỗ trợ image App Realtek có MP header 512 byte")
            return RealtekImage(bytes).verify()
        }

        private fun hex(b: ByteArray) = b.joinToString("") { "%02X".format(it) }

        private fun le(v: Int, n: Int) = ByteArray(n) { (v ushr (8 * it)).toByte() }

        /** TLV như flasher.py: dừng ở id 0 hoặc sau 0xFE; tràn khỏi 512 byte hoặc trùng id ⇒ null. */
        private fun strictTlv(b: ByteArray): Map<Int, ByteArray>? {
            val out = linkedMapOf<Int, ByteArray>()
            var i = 0
            while (i + 3 <= MP_HEADER_SIZE) {
                val id = (b[i].toInt() and 0xFF) or ((b[i + 1].toInt() and 0xFF) shl 8)
                val len = b[i + 2].toInt() and 0xFF
                if (id == 0) break
                if (i + 3 + len > MP_HEADER_SIZE || id in out) return null
                out[id] = b.copyOfRange(i + 3, i + 3 + len)
                i += 3 + len
                if (id == 0xFE) break
            }
            return out
        }

        /** Image ứng dụng (bảng `BinIndicator` của SDK Realtek). */
        const val IMAGE_ID_APP = 0x2793

        fun parse(bytes: ByteArray): RealtekImage {
            require(bytes.size > MP_HEADER_SIZE + HEADER_SIZE) { "File quá ngắn (${bytes.size} byte)" }
            return RealtekImage(bytes)
        }

        /** MP header mở đầu bằng TLV id 0x0001 dài 2 byte (binId). */
        private fun hasMpHeader(b: ByteArray) = b[0].toInt() == 0x01 && b[1].toInt() == 0x00 && b[2].toInt() == 0x02

        private fun parseTlv(b: ByteArray): Map<Int, ByteArray> {
            val out = linkedMapOf<Int, ByteArray>()
            var i = 0
            while (i + 3 <= MP_HEADER_SIZE) {
                val id = (b[i].toInt() and 0xFF) or ((b[i + 1].toInt() and 0xFF) shl 8)
                val len = b[i + 2].toInt() and 0xFF
                if (id == 0 || i + 3 + len > MP_HEADER_SIZE) break
                out[id] = b.copyOfRange(i + 3, i + 3 + len)
                if (id == 0xFE) break
                i += 3 + len
            }
            return out
        }

        /** CRC-16/ARC: đa thức phản chiếu 0xA001, init 0, không xor cuối. */
        fun crc16Arc(b: ByteArray, from: Int, to: Int): Int {
            var c = 0
            for (k in from until to) {
                c = c xor (b[k].toInt() and 0xFF)
                repeat(8) { c = if (c and 1 != 0) (c ushr 1) xor 0xA001 else c ushr 1 }
            }
            return c
        }

        fun sha256(b: ByteArray, from: Int = 0, to: Int = b.size): ByteArray =
            MessageDigest.getInstance("SHA-256").apply { update(b, from, to - from) }.digest()

        private fun ecPublicKey(point: ByteArray): java.security.PublicKey {
            require(point.size == 65 && point[0].toInt() == 0x04) { "Khoá không ở dạng không nén" }
            val params = AlgorithmParameters.getInstance("EC").apply { init(ECGenParameterSpec("secp256r1")) }
                .getParameterSpec(ECParameterSpec::class.java)
            val w = ECPoint(BigInteger(1, point.copyOfRange(1, 33)), BigInteger(1, point.copyOfRange(33, 65)))
            return KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(w, params))
        }

        /** `r‖s` 32+32 byte → DER SEQUENCE { INTEGER r, INTEGER s }. */
        private fun derSignature(r: ByteArray, s: ByteArray): ByteArray {
            fun int(v: ByteArray): ByteArray {
                val t = BigInteger(1, v).toByteArray() // tự thêm 00 nếu bit cao bật
                return byteArrayOf(0x02, t.size.toByte()) + t
            }
            val body = int(r) + int(s)
            return byteArrayOf(0x30, body.size.toByte()) + body
        }
    }
}

/** File firmware không qua kiểm tra của [RealtekImage.verify]; [reason] cho biết mục nào sai. */
class RealtekImageException(val reason: Reason, message: String) : Exception(message) {
    enum class Reason { FORMAT, CHIP, LENGTH, KEY_HASH, UNTRUSTED_KEY, CRC, SHA, SIGNATURE }
}
