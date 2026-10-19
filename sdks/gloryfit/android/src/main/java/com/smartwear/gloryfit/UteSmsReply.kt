package com.smartwear.gloryfit

/**
 * Trả lời SMS nhanh từ đồng hồ (doc 10 §2.5, F6 `0x200`, chỉ Android). Viết tắt như [UteNotify].
 *
 * - Bật/tắt: `52 01` / `52 00` (33F1, `T:1403-1418`); đồng hồ trả `52 01 FD` / `52 00 FD`.
 * - Mẫu trả lời: mỗi mẫu `46 FA tổng thứ-tự len <UTF-8 ≤ 90 byte>` lên 34F1, chờ đồng hồ trả `46 FA` rồi gửi mẫu sau;
 *   hết thì `46 FD 00`, đồng hồ trả `46 FD` (`T:196-214`, `P/uterkfor/uterkfinal.java:216-229`). Danh sách rỗng: `46 FB` (`T:1149-1151`).
 * - Đồng hồ xin gửi: `52 nLen <số ASCII> cLen <nội dung UTF-8>` (`uterkfinal.java:74-125`); app gửi SMS
 *   (`EndCallUtil.sendEndCallSmsToCaller`) rồi báo kết quả `52 FE` (thành công) / `52 FF` (lỗi) (`T:1953-1969`),
 *   đồng hồ dội lại `52 FE` / `52 FF`.
 */
object UteSmsReply {
    /** Số mẫu người dùng tự thêm tối đa (`SmsReplyActivity.MAX_COUNT` = 3); app gốc gửi thêm các mẫu cố định sau đó. */
    const val MAX_CUSTOM = 3

    /**
     * Mẫu cố định app gốc luôn gửi sau mẫu của người dùng (`R.array.reply_sms_fixed_content_array`, `SmsReplyPresenter.java:42-55`,
     * `MainHomeModelRkImpl.syncSmsReply`). Bản tiếng Anh trong APK: "I'll call you later, okay?", "Hold on, be right there.",
     * "I'm sorry, I can't answer the phone right now.", "In a meeting, get in touch later.", "No problem."; ở đây dịch tiếng Việt.
     */
    val FIXED_TEMPLATES = listOf(
        "Mình gọi lại sau nhé?",
        "Chờ chút, mình tới ngay.",
        "Xin lỗi, giờ mình không nghe máy được.",
        "Đang họp, liên lạc sau nhé.",
        "Không sao đâu.",
    )

    fun supported(f: Ute.Features) = UteNotify.smsReply(f)

    fun enable(on: Boolean) = byteArrayOf(0x52, if (on) 0x01 else 0x00)

    /** `52 01 FD` / `52 00 FD`: đồng hồ xác nhận bật / tắt. */
    fun isEnableAck(p: ByteArray) = p.size == 3 && Ute.u(p, 0) == 0x52 && Ute.u(p, 2) == 0xFD

    /**
     * `GBUtils.truncateToMaxBytes(s, 90)`: dài hơn 90 byte UTF-8 thì bỏ dần ký tự cuối (đơn vị UTF-16 như `deleteCharAt`)
     * tới khi ≤ 90 byte rồi thêm "..." (nên có thể tới 93 byte, như bản gốc).
     */
    fun truncate(s: String, max: Int = 90): String {
        if (s.isEmpty() || s.toByteArray(Charsets.UTF_8).size <= max) return s
        val sb = StringBuilder(s)
        while (sb.isNotEmpty()) {
            sb.deleteCharAt(sb.length - 1)
            if (sb.toString().toByteArray(Charsets.UTF_8).size <= max) return sb.append("...").toString()
        }
        return ""
    }

    /** Gói mẫu thứ [index] trong [total] mẫu (`T:196-214`, `D0()`). */
    fun template(text: String, index: Int, total: Int): ByteArray {
        val b = truncate(text).toByteArray(Charsets.UTF_8)
        return byteArrayOf(0x46, 0xFA.toByte(), total.toByte(), index.toByte(), b.size.toByte()) + b
    }

    /** `46 FD 00`: gửi xong danh sách mẫu. */
    val TEMPLATES_END = byteArrayOf(0x46, 0xFD.toByte(), 0x00)

    /** `46 FB`: danh sách mẫu rỗng (`uterkcatch()`). */
    val TEMPLATES_EMPTY = byteArrayOf(0x46, 0xFB.toByte())

    /** Đồng hồ yêu cầu gửi SMS [text] tới [number]. */
    data class Request(val number: String, val text: String)

    /**
     * `52 nLen <số> cLen <nội dung>` (gói > 3 byte). Số đọc từng byte thành ký tự (`AsciiStringToString`),
     * nội dung UTF-8 (`utf8ByteToString`). Null nếu không phải gói này hoặc thiếu byte.
     */
    fun parseRequest(p: ByteArray): Request? {
        if (p.size <= 3 || Ute.u(p, 0) != 0x52) return null
        val nLen = Ute.u(p, 1)
        if (p.size < nLen + 3) return null
        val cLen = Ute.u(p, nLen + 2)
        if (p.size < nLen + 3 + cLen) return null
        val number = String(CharArray(nLen) { (p[2 + it].toInt() and 0xFF).toChar() })
        val text = String(p, nLen + 3, cLen, Charsets.UTF_8)
        return Request(number, text)
    }

    /** Kết quả gửi SMS: `52 FE` thành công, `52 FF` lỗi (`notifyDeviceReplySmsResult`, `T:1953-1969`). */
    fun result(ok: Boolean) = byteArrayOf(0x52, if (ok) 0xFE.toByte() else 0xFF.toByte())
}
