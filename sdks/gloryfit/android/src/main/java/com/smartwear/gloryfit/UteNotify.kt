package com.smartwear.gloryfit

import java.nio.charset.Charset

/**
 * Thông báo app, cuộc gọi đến, tên người gửi SMS (sdks/gloryfit/docs/10-y25-feature-audit.md §2.5).
 * Byte theo SDK Realtek "RK" trong GloryFitPro 1.9.0.2 (Y25 dùng nhánh này), viết tắt như doc 10:
 * `T` = `research/xapk-pro/jadx-out/sources/uterkif/uterkthis.java`, `W` = `research/jadx-out/.../sdk/WriteCommandToBLE.java`
 * (GloryFit 4.0.12), `P/` = `research/xapk-pro/jadx-out/sources/`.
 *
 * Luồng `C5` (`T:3509-3535` dựng, `T:2478-2524` chia gói, `P/uterkfor/uterkfinal.java:474-528` nhận):
 * nội dung `[loại][độ dài][chữ]` chia `C5 seq <18 byte>` (gói 20 byte cố định). Đồng hồ trả `C5 seq` ⇒ gửi gói sau,
 * `C5 FF` ⇒ gửi lại từ gói 0. Gửi hết thì app gửi `C5 FD`, đồng hồ trả `C5 FD loại` = xong.
 * Loại 3 (SMS) + F7 `0x800`/`0x2000`: tiếp `C6` tên người gửi, cùng cách chia gói (`T:1848-1888`, `W:1251-1344`).
 * Loại 0/3 + F6 `0x200` (có trả lời SMS): sau `C5 FD` gửi số điện thoại `45 FA len <số>` lên 34F1 (`T:2722-2734`,
 * `P/uterkfor/uterkfinal.java:566-576`).
 */
object UteNotify {
    // `P/com/yc/gloryfitpro/config/RemindType.java:47-226`
    const val TYPE_CALL = 0
    const val TYPE_QQ = 1
    const val TYPE_WECHAT = 2
    const val TYPE_SMS = 3
    const val TYPE_OTHERS = 4
    const val TYPE_FACEBOOK = 5
    const val TYPE_TWITTER = 6
    const val TYPE_WHATSAPP = 7
    const val TYPE_SKYPE = 8
    const val TYPE_FACEBOOK_MESSENGER = 9
    const val TYPE_HANGOUTS = 10
    const val TYPE_LINE = 11
    const val TYPE_LINKEDIN = 12
    const val TYPE_INSTAGRAM = 13
    const val TYPE_VIBER = 14
    const val TYPE_KAKAO_TALK = 15
    const val TYPE_VKONTAKTE = 16
    const val TYPE_SNAPCHAT = 17
    const val TYPE_GMAIL = 19
    const val TYPE_FLICKR = 20
    const val TYPE_TUMBLR = 21
    const val TYPE_PINTEREST = 22
    const val TYPE_YOUTUBE = 23
    const val TYPE_TELEGRAM = 24
    const val TYPE_TRUECALLER = 25
    const val TYPE_PAYTM = 26
    const val TYPE_ZALO = 27
    const val TYPE_IMO = 28
    const val TYPE_MICROSOFT_TEAMS = 29
    const val TYPE_MAX = 163
    const val TYPE_VK_MESSENGER = 173
    const val TYPE_OK = 174
    const val TYPE_YANDEX_TELEMOST = 175
    const val TYPE_RU_ZEN = 176
    const val TYPE_MAIL = 177
    const val TYPE_YANDEX_MAIL = 178

    /** Gói tin nhắn của hệ thống: đi đường SMS (loại 3), không đi đường app (`RemindType.PACKAGE_NAME_MMS`). */
    val SMS_PACKAGES = com.smartwear.core.phone.PhoneText.SMS_PACKAGES

    /** Google Messages: cũng đi đường SMS, lấy nội dung từ `tickerText` (`StatusbarMsgNotificationListener.java:229-262`). */
    const val GOOGLE_MESSAGES = com.smartwear.core.phone.PhoneText.GOOGLE_MESSAGES

    /**
     * Một app có công tắc riêng và icon trên đồng hồ. [display]/[mask]: nhóm mặt nạ `DB AA` (1..5) và bit
     * (`PushMessageUtil.IS_DISPLAY_*`), như `AppRemindUtils.appRemindDynamicDisplayEn` (`P/.../services/AppRemindUtils.java:207-305`).
     */
    data class RemindApp(val key: String, val name: String, val type: Int, val packages: List<String>, val display: Int, val mask: Int)

    /** Thứ tự như `appRemindDynamicDisplayEn`. */
    val APPS = listOf(
        RemindApp("instagram", "Instagram", TYPE_INSTAGRAM, listOf("com.instagram.android"), 1, 0x002000),
        RemindApp("youtube", "YouTube", TYPE_YOUTUBE, listOf("com.google.android.youtube"), 1, 0x800000),
        RemindApp("messenger", "Messenger", TYPE_FACEBOOK_MESSENGER, listOf("com.facebook.orca"), 1, 0x000100),
        RemindApp("gmail", "Gmail", TYPE_GMAIL, listOf("com.google.android.gm"), 1, 0x080000),
        RemindApp("snapchat", "Snapchat", TYPE_SNAPCHAT, listOf("com.snapchat.android"), 1, 0x020000),
        RemindApp("facebook", "Facebook", TYPE_FACEBOOK, listOf("com.facebook.katana"), 1, 0x000020),
        RemindApp("twitter", "X (Twitter)", TYPE_TWITTER, listOf("com.twitter.android"), 1, 0x000040),
        RemindApp("whatsapp", "WhatsApp", TYPE_WHATSAPP, listOf("com.whatsapp", "com.whatsapp.w4b"), 1, 0x000080),
        RemindApp("pinterest", "Pinterest", TYPE_PINTEREST, listOf("com.pinterest"), 1, 0x400000),
        RemindApp("hangouts", "Hangouts", TYPE_HANGOUTS, listOf("com.google.android.talk"), 1, 0x000800),
        RemindApp("linkedin", "LinkedIn", TYPE_LINKEDIN, listOf("com.linkedin.android"), 1, 0x001000),
        RemindApp("skype", "Skype", TYPE_SKYPE, listOf("com.skype.rover", "com.skype.raider", "com.skype.insiders"), 1, 0x000400),
        RemindApp("tumblr", "Tumblr", TYPE_TUMBLR, listOf("com.tumblr"), 1, 0x200000),
        RemindApp("viber", "Viber", TYPE_VIBER, listOf("com.viber.voip"), 1, 0x004000),
        RemindApp("line", "LINE", TYPE_LINE, listOf("jp.naver.line.android"), 1, 0x000200),
        RemindApp("flickr", "Flickr", TYPE_FLICKR, listOf("com.yahoo.mobile.client.android.flickr"), 1, 0x100000),
        RemindApp("wechat", "WeChat", TYPE_WECHAT, listOf("com.tencent.mm"), 1, 0x000004),
        RemindApp("qq", "QQ", TYPE_QQ, listOf("com.tencent.mobileqq"), 1, 0x000002),
        RemindApp("vkontakte", "VKontakte", TYPE_VKONTAKTE, listOf("com.vkontakte.android"), 1, 0x010000),
        RemindApp("kakaotalk", "KakaoTalk", TYPE_KAKAO_TALK, listOf("com.kakao.talk"), 1, 0x008000),
        RemindApp("telegram", "Telegram", TYPE_TELEGRAM, listOf("org.telegram.messenger"), 2, 0x000001),
        RemindApp("truecaller", "Truecaller", TYPE_TRUECALLER, listOf("com.truecaller"), 2, 0x000002),
        RemindApp("paytm", "Paytm", TYPE_PAYTM, listOf("net.one97.paytm"), 2, 0x000004),
        RemindApp("zalo", "Zalo", TYPE_ZALO, listOf("com.zing.zalo"), 2, 0x000008),
        RemindApp("imo", "imo", TYPE_IMO, listOf("com.imo.android.imoim"), 2, 0x000010),
        RemindApp("teams", "Microsoft Teams", TYPE_MICROSOFT_TEAMS, listOf("com.microsoft.teams"), 2, 0x000020),
        RemindApp("max", "MAX", TYPE_MAX, listOf("ru.oneme.app"), 5, 0x000100),
        RemindApp("vkmessenger", "VK Messenger", TYPE_VK_MESSENGER, listOf("com.vk.im"), 5, 0x000200),
        RemindApp("ok", "OK", TYPE_OK, listOf("ru.ok.android"), 5, 0x000300),
        RemindApp("telemost", "Yandex Telemost", TYPE_YANDEX_TELEMOST, listOf("ru.yandex.telemost"), 5, 0x000400),
        RemindApp("ruzen", "Дзен", TYPE_RU_ZEN, listOf("ru.zen.android"), 5, 0x001000),
        RemindApp("mail", "Mail.ru", TYPE_MAIL, listOf("ru.mail.mailapp"), 5, 0x002000),
        RemindApp("yandexmail", "Yandex Mail", TYPE_YANDEX_MAIL, listOf("ru.yandex.mail"), 5, 0x000400),
    )

    /** App có công tắc riêng chứa [pkg] (null = app khác). */
    fun appFor(pkg: String): RemindApp? = APPS.firstOrNull { pkg in it.packages }

    /**
     * Loại thông báo theo package, y hệt `NotificationPresenter.getAppType` (Pro): app không có trong bảng là 4 ("khác").
     * Lưu ý bản gốc kiểm Skype bằng `"com.skype.rover || com.skype.raider || com.skype.insiders".contains(pkg)`.
     */
    fun appType(pkg: String): Int {
        if (pkg.isNotEmpty() && "com.skype.rover || com.skype.raider || com.skype.insiders".contains(pkg)) return TYPE_SKYPE
        return appFor(pkg)?.type ?: TYPE_OTHERS
    }

    /** App có icon trên đồng hồ theo mặt nạ `DB AA` (null = chưa đọc được ⇒ coi như có, như danh sách tĩnh của Pro). */
    fun displayed(app: RemindApp, masks: IntArray?): Boolean =
        masks == null || (masks.getOrElse(app.display - 1) { 0 } and app.mask) == app.mask

    // ---------- Bit tính năng ----------

    /** F1 `0x4` (`isHasFunction_1(4)`): chữ gửi dạng UCS-2 (`string2unicode`), không thì GB2312. */
    fun unicode(f: Ute.Features) = f.has(1, 0x000004)

    /** F6 `0x400000`: tin dài 240 byte (không thì 160) (`T:3530`). */
    fun longMessage(f: Ute.Features) = f.has(6, 0x400000)

    /** F7 `0x800` / `0x2000`: đồng hồ nhận tên người gửi SMS bằng `C6` (`P/uterkfor/uterkfinal.java:486`, `BluetoothLeService.java:3823`). */
    fun smsSender(f: Ute.Features) = f.has(7, 0x000800) || f.has(7, 0x002000)

    /** F6 `0x200` (`RkSupportUtils.isSupSmsReply`): trả lời SMS nhanh; kèm theo là gửi số gọi đến `45 FA`. */
    fun smsReply(f: Ute.Features) = f.has(6, 0x000200)

    /** F5 `0x800`: đồng hồ có danh sách icon động, đọc bằng `DB AA` lúc kết nối (`MainHomeModelRkImpl.java:222-225`). */
    fun displayList(f: Ute.Features) = f.has(5, 0x000800)

    /** F1 `0x400000` (`isHasHangup`, `33F1 b17.6`): từ chối cuộc gọi trên đồng hồ. */
    fun hangup(f: Ute.Features) = f.has(1, 0x400000)

    // ---------- Mã hoá chữ ----------

    /**
     * Bỏ emoji như `EmojiUtil.filterEmoji` (`P/com/yc/utesdk/utils/open/EmojiUtil.java`): ký tự trong các khoảng biểu tượng
     * (©, ®, ™, U+2328, U+23E9..23FA, U+25B6..27BF, U+2B50, U+3030, U+F000..FFFF, ZWJ U+200D, VS16 U+FE0F).
     * Khác bản gốc: bỏ luôn mọi ký tự ngoài BMP (cặp surrogate). Bản gốc chỉ xoá ~120 chuỗi emoji liệt kê sẵn, emoji khác
     * lọt qua và `string2unicode` dựng ra 5 + 4 chữ số hex làm lệch cả phần sau của tin.
     */
    fun filterEmoji(s: String): String = buildString {
        var i = 0
        while (i < s.length) {
            val cp = s.codePointAt(i)
            i += Character.charCount(cp)
            if (cp > 0xFFFF || isEmojiChar(cp)) continue
            appendCodePoint(cp)
        }
    }

    private fun isEmojiChar(c: Int) = c == 169 || c == 174 || c == 8482 || c == 12336 || c in 9654..10175 || c == 9000 ||
        c in 9193..9210 || c in 61440..65535 || c in 9986..10160 || c in 62977..63055 || c == 8205 || c == 65039 || c == 11088

    /**
     * Chữ → byte gửi đồng hồ. UCS-2 big-endian như `GBUtils.string2unicode` (bỏ ký tự điều khiển < 0x20, 0x7F..0x9F,
     * U+2005, U+200E, U+200F, U+2614, U+26C4); đồng hồ không có F1 `0x4` thì GB2312.
     */
    fun encode(text: String, f: Ute.Features): ByteArray {
        if (!unicode(f)) return runCatching { text.toByteArray(Charset.forName("GB2312")) }.getOrDefault(text.toByteArray(Charsets.US_ASCII))
        val out = java.io.ByteArrayOutputStream()
        var i = 0
        while (i < text.length) {
            val cp = text.codePointAt(i)
            i += Character.charCount(cp)
            if (cp < 32 || cp == 8197 || cp in 127..159 || cp == 9924 || cp == 9748 || cp == 8206 || cp == 8207 || cp > 0xFFFF) continue
            out.write(cp shr 8)
            out.write(cp)
        }
        return out.toByteArray()
    }

    /** Số byte chữ tối đa trong `C5`: 240 với F6 `0x400000`, không thì 160 (`GBUtils.hexStringToBytess`, nhánh RK). */
    fun maxTextBytes(f: Ute.Features) = if (longMessage(f)) 240 else 160

    /**
     * Nội dung `C5`: `[loại][độ dài][chữ]` (`GBUtils.hexStringToBytess(hex, type)`); chữ cắt ở [maxTextBytes].
     * null khi chữ rỗng (bản gốc trả null, không gửi gì).
     */
    fun payload(type: Int, text: String, f: Ute.Features): ByteArray? {
        val bytes = encode(text, f)
        if (bytes.isEmpty()) return null
        val n = minOf(bytes.size, maxTextBytes(f))
        return byteArrayOf(type.toByte(), n.toByte()) + bytes.copyOf(n)
    }

    /** Nội dung `C6`: `[loại][độ dài ≤ 30][tên]` (`GBUtils.hexStringToBytess6`); tên rỗng thì "unkown" như bản gốc (`T:4701-4706`). */
    fun senderPayload(name: String, f: Ute.Features): ByteArray {
        val bytes = encode(name.ifEmpty { "unkown" }, f)
        val n = minOf(bytes.size, 30)
        return byteArrayOf(TYPE_SMS.toByte(), n.toByte()) + bytes.copyOf(n)
    }

    /**
     * Chia [payload] thành gói `op seq <18 byte>` (gói cuối ngắn hơn), như `uterksuper(int)` (`C5`, tối đa [cap] byte:
     * 242 / 162) và `uterkthrow(int)` (`C6`, tối đa 32 byte). Gói `op FD` gửi riêng sau gói cuối.
     */
    fun sections(op: Int, payload: ByteArray, cap: Int): List<ByteArray> {
        val length = minOf(payload.size, cap)
        return (0 until length step 18).mapIndexed { seq, from ->
            byteArrayOf(op.toByte(), seq.toByte()) + payload.copyOfRange(from, minOf(length, from + 18))
        }
    }

    /** Giới hạn tổng nội dung `C5` (`T:3530`: `uterkwhile` = 242 / 162). */
    fun messageCap(f: Ute.Features) = if (longMessage(f)) 242 else 162

    const val SENDER_CAP = 32

    /** `C5 FD` / `C6 FD`: app báo đã gửi hết (`T:400-410`). */
    fun end(op: Int) = byteArrayOf(op.toByte(), 0xFD.toByte())

    /**
     * Số điện thoại cho đồng hồ (để trả lời SMS): `45 FA len <byte UTF-8 của số>` lên 34F1, không phản hồi
     * (`T:2722-2734` `stringToASCII`; ack qua write callback `P/uterkdo/uterktry.java:680-683`).
     */
    fun phoneNumber(number: String): ByteArray {
        val b = number.toByteArray(Charsets.UTF_8).let { it.copyOf(minOf(it.size, 255)) }
        return byteArrayOf(0x45, 0xFA.toByte(), b.size.toByte()) + b
    }

    /** `C1 04`: màn cuộc gọi trên đồng hồ tắt (nghe máy, cúp máy, nhỡ) — `callerInterfaceDisappears` (`T:1241-1244`). */
    val CALL_END = byteArrayOf(0xC1.toByte(), 0x04)

    /** `DB AA`: hỏi danh sách icon thông báo đồng hồ hiển thị được (`T:899-902`). */
    val QUERY_DISPLAY = byteArrayOf(0xDB.toByte(), 0xAA.toByte())

    /**
     * Phản hồi `DB AA` (20 byte): 15 byte cuối = 5 mặt nạ 24 bit; byte 17..19 = mặt nạ 1, 14..16 = 2, 11..13 = 3,
     * 8..10 = 4, 5..7 = 5 (`P/uterkfor/uterkfinal.java:531-558`). Trả về [mặt nạ 1..5]; null nếu không đủ 20 byte.
     */
    fun parseDisplay(p: ByteArray): IntArray? {
        if (p.size != 20 || Ute.u(p, 0) != 0xDB) return null
        fun be24(i: Int) = (Ute.u(p, i) shl 16) or (Ute.u(p, i + 1) shl 8) or Ute.u(p, i + 2)
        return intArrayOf(be24(17), be24(14), be24(11), be24(8), be24(5))
    }

    // ---------- Nội dung tin (phía app) ----------

    /**
     * Nội dung gửi đồng hồ cho thông báo app, nhánh RK của `NotificationPresenter.sendMessage` (Pro, giải mã lại bằng
     * `jadx --show-bad-code`): Instagram/Gmail trên Android ≤ 14 dùng "tiêu đề:nội dung" (không có nội dung thì tickerText);
     * app khác: không có tickerText thì "tiêu đề:nội dung", có thì chỉ nội dung. Tiêu đề không gửi riêng (`appRemind(type, content)`).
     * Rồi bỏ emoji ([filterEmoji]). Yandex Telemost: tickerText = nội dung.
     */
    fun appContent(pkg: String, type: Int, title: String, text: String, ticker: String, sdkInt: Int): String {
        @Suppress("NAME_SHADOWING") val ticker = if (pkg == "ru.yandex.telemost") text else ticker
        val content = if ((type == TYPE_INSTAGRAM || type == TYPE_GMAIL) && sdkInt <= 34) {
            if (text.isNotEmpty()) (if (title.isNotEmpty()) "$title:$text" else text) else ticker
        } else {
            if (ticker.isEmpty() && text.isNotEmpty() && title.isNotEmpty()) "$title:$text" else text
        }
        return filterEmoji(content)
    }

    /**
     * Bỏ phần "người gửi:" ở đầu tin SMS như `StatusbarMsgNotificationListener.java:247-258`: nếu tin bắt đầu bằng
     * [contact] (và khác [contact]) thì xoá [contact], rồi bỏ một tiền tố ": ", "：" hoặc ":".
     */
    fun stripSmsPrefix(content: String, contact: String): String = com.smartwear.core.phone.PhoneText.stripSmsPrefix(content, contact)

    /**
     * Đang trong khung "không làm phiền" theo giờ của app ⇒ không đẩy thông báo (`StatusbarMsgNotificationListener.java:150-158`,
     * `NotificationPresenter.isCurrentInTimeScope`): khung trong ngày [from, to]; qua đêm (from ≥ to): từ [from] hôm trước
     * đến [to], hoặc từ [from] hôm nay. Phút trong ngày, hai đầu tính là trong khung.
     */
    fun inQuietHours(fromMinute: Int, toMinute: Int, nowMinute: Int): Boolean =
        if (fromMinute < toMinute) nowMinute in fromMinute..toMinute else nowMinute <= toMinute || nowMinute >= fromMinute
}
