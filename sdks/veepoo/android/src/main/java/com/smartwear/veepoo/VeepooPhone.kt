package com.smartwear.veepoo

import com.smartwear.core.MusicCommand
import com.smartwear.core.RemoteCameraEvent
import com.smartwear.veepoo.Veepoo.op
import com.smartwear.veepoo.Veepoo.u

/**
 * Gói phía điện thoại ↔ vòng tay (§6.7): nội dung thông báo `C2`, cuộc gọi `C1`, nhạc `99`/`01`, tìm vòng tay / tìm điện thoại `B5`,
 * chụp ảnh `B6`.
 */
object VeepooPhone {

    /** Một app nhận thông báo: [type] = appType Veepoo (`ESocailMsg`), [key] trùng key của GloryFit để cấu hình chuyển tiếp dùng chung. */
    data class App(val key: String, val name: String, val type: Int, val packages: List<String>)

    const val TYPE_PHONE = 0
    const val TYPE_SMS = 1
    const val TYPE_OTHER = 17

    /** Bảng appType (`ESocailMsg.java:7-38`) + gói Android (`MsgNotificationConstants.java:9-50`). Không có điện thoại / SMS / "khác". */
    val APPS = listOf(
        App("wechat", "WeChat", 2, listOf("com.tencent.mm")),
        App("qq", "QQ", 3, listOf("com.tencent.mobileqq")),
        App("sina", "Sina Weibo", 4, listOf("com.sina.weibo")),
        App("facebook", "Facebook", 5, listOf("com.facebook.katana")),
        App("twitter", "X (Twitter)", 6, listOf("com.twitter.android")),
        App("flickr", "Flickr", 7, listOf("com.yahoo.mobile.client.android.flickr")),
        App("linkedin", "LinkedIn", 8, listOf("com.linkedin.android")),
        App("whatsapp", "WhatsApp", 9, listOf("com.whatsapp", "com.whatsapp.w4b")),
        App("line", "LINE", 10, listOf("jp.naver.line.android")),
        App("instagram", "Instagram", 11, listOf("com.instagram.android")),
        App("snapchat", "Snapchat", 12, listOf("com.snapchat.android")),
        App("skype", "Skype", 13, listOf("com.skype.raider", "com.skype.rover", "com.skype.insiders")),
        App("gmail", "Gmail", 14, listOf("com.google.android.gm")),
        App("dingtalk", "DingTalk", 15, listOf("com.alibaba.android.rimet")),
        App("wecom", "WeCom", 16, listOf("com.tencent.wework")),
        App("tiktok", "TikTok", 18, listOf("com.zhiliaoapp.musically", "com.ss.android.ugc.trill")),
        App("telegram", "Telegram", 19, listOf("org.telegram.messenger")),
        App("connected2me", "Connected2.me", 20, listOf("com.connected2.ozzy.c2m")),
        App("kakaotalk", "KakaoTalk", 21, listOf("com.kakao.talk")),
        App("messenger", "Messenger", 23, listOf("com.facebook.orca")),
        App("zalo", "Zalo", 24, listOf("com.zing.zalo")),
        App("viber", "Viber", 25, listOf("com.viber.voip")),
        App("vkontakte", "VK", 27, listOf("com.vkontakte.android")),
        App("max", "MAX", 28, listOf("ru.oneme.app")),
        App("ok", "OK", 29, listOf("ru.ok.android")),
        App("vkmessenger", "VK Messenger", 30, listOf("com.vk.im")),
    )

    /**
     * appType thực sự gửi cho [appKey]: app được vòng tay hỗ trợ (`AD` ≠ 0) ⇒ chính nó; không thì "khác" (17) nếu được hỗ trợ (như
     * `com/veepoo/device/f.java:673-704`); null = không gửi. GE54: Zalo không có trong `AD` ⇒ gửi dạng "khác".
     */
    fun typeFor(appKey: String, switches: VeepooMessageSwitches): Int? {
        val app = APPS.firstOrNull { it.key == appKey }
        if (app != null && switches.status(app.type) != 0) return app.type
        return TYPE_OTHER.takeIf { switches.status(it) != 0 }
    }

    /** Cắt UTF-8 tối đa [max] byte, không cắt giữa ký tự (như `util/a.j`: bỏ ký tự hỏng ở cuối). */
    fun utf8Prefix(s: String, max: Int): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        var i = 0
        while (i < s.length) {
            val cp = s.codePointAt(i)
            val b = String(Character.toChars(cp)).toByteArray(Charsets.UTF_8)
            if (out.size() + b.size > max) break
            out.write(b)
            i += Character.charCount(cp)
        }
        return out.toByteArray()
    }

    private fun chunks(b: ByteArray, size: Int = 14): List<ByteArray> =
        if (b.isEmpty()) emptyList() else (b.indices step size).map { b.copyOfRange(it, minOf(it + size, b.size)) }

    /** Một gói `C2 type len total idx kind data(≤14)` 20 byte; kind 0 = số điện thoại, 1 = tên, 2 = nội dung. */
    private fun packet(type: Int, total: Int, idx: Int, kind: Int, data: ByteArray) = ByteArray(20).also {
        it[0] = 0xC2.toByte(); it[1] = type.toByte(); it[2] = data.size.toByte(); it[3] = total.toByte(); it[4] = idx.toByte()
        it[5] = kind.toByte(); data.copyInto(it, 6)
    }

    /**
     * Thông báo app (`jf/d2.java:322-361`): nội dung = `tiêu đề:nội dung` (tiêu đề cắt ≤ 12 byte, hoặc ≤ [contactMsgLength]×14 khi khác 0),
     * chia khúc 14 byte, mỗi khúc một gói kind 2; tổng = min(số khúc, [maxPackets]) và chỉ gửi bấy nhiêu gói (`sendSocialMsgContent`).
     */
    fun appMessage(type: Int, title: String, text: String, maxPackets: Int, contactMsgLength: Int): List<ByteArray> {
        val t = String(utf8Prefix(title, if (contactMsgLength == 0) 12 else contactMsgLength * 14), Charsets.UTF_8)
        val content = when {
            t.isNotEmpty() && text.isNotEmpty() -> "$t:$text"
            t.isNotEmpty() -> t
            else -> text
        }
        val parts = chunks(content.toByteArray(Charsets.UTF_8))
        val total = minOf(parts.size, maxPackets)
        return parts.take(total).mapIndexed { i, d -> packet(type, total, i + 1, 2, d) }
    }

    /**
     * SMS (type 1, `d2.java:107-210`): [contactMsgLength] = 0 ⇒ gói 1 là tên/số (≤ 12 byte), các gói sau là nội dung; khác 0 ⇒ tên chiếm
     * tối đa [contactMsgLength] gói 14 byte. Byte 5: 1 = tên trong danh bạ, 0 = số, 2 = nội dung. Gửi tối đa [maxPackets] gói.
     */
    fun sms(sender: String, isName: Boolean, text: String, maxPackets: Int, contactMsgLength: Int): List<ByteArray> {
        val who = sender.ifEmpty { " " }
        val nameParts = if (contactMsgLength == 0) listOf(utf8Prefix(who, 12))
        else chunks(utf8Prefix(who, contactMsgLength * 14)).take(contactMsgLength)
        val body = chunks(text.toByteArray(Charsets.UTF_8))
        val all = nameParts.map { it to (if (isName) 1 else 0) } + body.map { it to 2 }
        val total = maxOf(minOf(all.size, maxPackets), nameParts.size)
        return all.take(total).mapIndexed { i, (d, kind) -> packet(TYPE_SMS, total, i + 1, kind, d) }
    }

    /** Cuộc gọi đến (type 0, `d2.java:211-283`): tên (kind 1) hoặc số (kind 0); [contactMsgLength] = 0 ⇒ một gói ≤ 12 byte. */
    fun incomingCall(nameOrNumber: String, isName: Boolean, contactMsgLength: Int): List<ByteArray> {
        val who = nameOrNumber.ifEmpty { " " }
        val parts = if (contactMsgLength == 0) listOf(utf8Prefix(who, 12)) else chunks(utf8Prefix(who, contactMsgLength * 14)).take(contactMsgLength)
        return parts.mapIndexed { i, d -> packet(TYPE_PHONE, parts.size, i + 1, if (isName) 1 else 0, d) }
    }

    /** `C1 00 00 00`: gác máy / hết đổ chuông (`P:165`). */
    val CALL_END = Veepoo.bytes(0xC1, 0x00, 0x00, 0x00)

    /** Vòng tay báo người dùng bấm từ chối cuộc gọi: `C1 02 …` (`p9/a.java:833-843`). `C1 03` = tắt tiếng, `C1 04` = nghe. */
    fun isRejectCall(p: ByteArray) = p.op == 0xC1 && p.size >= 2 && u(p, 1) == 0x02

    // ---------- Nhạc ----------

    /**
     * Lệnh nhạc từ vòng tay: kiểu mới `99 02 xx` (1 phát, 2 dừng, 3 bài trước, 4 bài sau), `99 03 05/06` tăng/giảm âm lượng
     * (`jf/u.java:44-91`); kiểu cũ `01 01 01 01/04/02` = bài sau / bài trước / phát-dừng (`p9/a.java:854-870`).
     */
    fun parseMusicCommand(p: ByteArray): MusicCommand? {
        if (p.size < 3) return null
        return when (p.op) {
            0x99 -> when (u(p, 1) to u(p, 2)) {
                2 to 1, 2 to 2 -> MusicCommand.PLAY_PAUSE
                2 to 3 -> MusicCommand.PREVIOUS
                2 to 4 -> MusicCommand.NEXT
                3 to 5 -> MusicCommand.VOLUME_UP
                3 to 6 -> MusicCommand.VOLUME_DOWN
                else -> null
            }
            0x01 -> if (p.size >= 4 && u(p, 1) == 1 && u(p, 2) == 1) when (u(p, 3)) {
                1 -> MusicCommand.NEXT
                4 -> MusicCommand.PREVIOUS
                2 -> MusicCommand.PLAY_PAUSE
                else -> null
            } else null
            else -> null
        }
    }

    /**
     * Trạng thái nhạc (`jf/f1.java:93-138`): TLV `A0 album, A1 tên bài, A2 ca sĩ, A3 01 trạng-thái (1 phát / 2 dừng), A4 01 âm-lượng %`
     * bọc trong `F0 len`, cắt khúc 16 byte thành `99 01 idx total` + 16 byte (20 byte/gói). Trường null bỏ qua.
     */
    fun musicPackets(playing: Boolean, title: String?, artist: String?, album: String?, volumePercent: Int?): List<ByteArray> {
        val tlv = java.io.ByteArrayOutputStream()
        fun text(tag: Int, s: String?) {
            if (s.isNullOrEmpty()) return
            val b = utf8Prefix(s, 60)
            tlv.write(tag); tlv.write(b.size); tlv.write(b)
        }
        text(0xA0, album)
        text(0xA1, title)
        text(0xA2, artist)
        tlv.write(0xA3); tlv.write(1); tlv.write(if (playing) 1 else 2)
        if (volumePercent != null) { tlv.write(0xA4); tlv.write(1); tlv.write(volumePercent.coerceIn(0, 100)) }
        val body = tlv.toByteArray()
        return framed(0x99, 0x01, byteArrayOf(0xF0.toByte(), body.size.toByte()) + body)
    }

    /** Cắt [payload] thành gói `[op] [sub] idx total` + 16 byte (`f1.a`, `p.java`, `u2.java`). */
    fun framed(op: Int, sub: Int, payload: ByteArray): List<ByteArray> {
        val total = (payload.size + 15) / 16
        return (1..total).map { idx ->
            ByteArray(20).also {
                it[0] = op.toByte(); it[1] = sub.toByte(); it[2] = idx.toByte(); it[3] = total.toByte()
                val from = (idx - 1) * 16
                payload.copyInto(it, 4, from, minOf(from + 16, payload.size))
            }
        }
    }

    // ---------- Tìm vòng tay / tìm điện thoại ----------

    /** `B5 0A` bắt đầu rung vòng tay, `B5 0B` dừng (20 byte, `jf/j0.java:65-80`). */
    fun findDevice(start: Boolean) = Veepoo.padded(20, 0xB5, if (start) 0x0A else 0x0B)

    /** Trả lời tìm vòng tay `B5 0A/0B st`: 0 không hỗ trợ, 1 đang tìm, 2 đã thấy, 3 không thấy. */
    fun findDeviceStatus(p: ByteArray): Int? =
        if (p.op == 0xB5 && p.size >= 3 && (u(p, 1) == 0x0A || u(p, 1) == 0x0B)) u(p, 2) else null

    /** Vòng tay tìm điện thoại: `B5 00 …` (≥ 3 byte) ⇒ đổ chuông (`g.java:336-358`). */
    fun isFindPhone(p: ByteArray) = p.op == 0xB5 && p.size > 2 && u(p, 1) == 0x00

    /** App báo đã thôi đổ chuông: `B5 02` (`stopFindCYPhone`, `jf/j0.java:83-90`). */
    val FIND_PHONE_STOP = Veepoo.padded(20, 0xB5, 0x02)

    // ---------- Chụp ảnh ----------

    /** `B6 01` mở màn chụp, `B6 00` thoát (`P:174-175`). */
    fun camera(open: Boolean) = Veepoo.bytes(0xB6, if (open) 0x01 else 0x00)

    /**
     * `B6 ok mode [chủ động]` (`jf/l.java:56-69`): mode 2 + ok 1 = bấm chụp; mode 1 + ok 1 = đã mở (byte 3 = 1: người dùng mở trên
     * vòng tay); mode 0 + ok 1 = đã đóng.
     */
    fun parseCamera(p: ByteArray): RemoteCameraEvent? {
        if (p.op != 0xB6 || p.size < 3 || u(p, 1) != 1) return null
        return when (u(p, 2)) {
            2 -> RemoteCameraEvent.SHUTTER
            1 -> if (p.size >= 4 && u(p, 3) == 1) RemoteCameraEvent.OPENED else null
            0 -> RemoteCameraEvent.CLOSED
            else -> null
        }
    }

    /** SOS từ vòng tay: `B7 01 01` / `B7 04` (`p9/a.java:825-831`); SDK tự trả `B7 04 01`. */
    fun isSos(p: ByteArray) = p.op == 0xB7 && p.size >= 2 && ((u(p, 1) == 1 && p.size >= 3 && u(p, 2) == 1) || u(p, 1) == 4)
}
