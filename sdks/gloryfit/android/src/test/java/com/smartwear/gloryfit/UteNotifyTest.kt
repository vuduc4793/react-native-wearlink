package com.smartwear.gloryfit

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Byte đối chiếu với GloryFitPro 1.9.0.2 (`uterkthis.java`, `GBUtils.java`, `uterkfinal.java`), xem [UteNotify]. */
class UteNotifyTest {
    private fun hex(s: String) = s.split(" ").map { it.toInt(16).toByte() }.toByteArray()
    private fun hexOf(b: ByteArray) = b.joinToString(" ") { "%02X".format(it) }

    /** `33F1` đọc từ Y25 thật (doc 10 §1.1, 01-protocol §10). */
    private val y25 = Ute.Features.parse(hex("08 88 6C 2A 01 24 39 43 75 6E DF FE D9 21 00 5D 78 5B A0 DC"), null)
    /** Đồng hồ cũ: không UCS-2, không tin dài, không tên người gửi. */
    private val old = Ute.Features(mapOf(1 to 0x080000), null)

    @Test fun y25FeatureBits() {
        assertTrue(UteNotify.unicode(y25))
        assertTrue(UteNotify.longMessage(y25))
        assertTrue(UteNotify.smsSender(y25))
        assertTrue(UteNotify.smsReply(y25))
        assertTrue(UteNotify.displayList(y25))
        assertTrue(UteNotify.hangup(y25))
        assertEquals(240, UteNotify.maxTextBytes(y25))
        assertEquals(242, UteNotify.messageCap(y25))
        assertFalse(UteNotify.unicode(old))
        assertEquals(160, UteNotify.maxTextBytes(old))
    }

    @Test fun shortMessageIsOnePacket() {
        val payload = UteNotify.payload(UteNotify.TYPE_WHATSAPP, "Hi", y25)!!
        assertEquals("07 04 00 48 00 69", hexOf(payload))
        val sections = UteNotify.sections(0xC5, payload, UteNotify.messageCap(y25))
        assertEquals(listOf("C5 00 07 04 00 48 00 69"), sections.map(::hexOf))
        assertEquals("C5 FD", hexOf(UteNotify.end(0xC5)))
    }

    @Test fun vietnameseIsUcs2BigEndian() {
        assertEquals("1B 08 00 43 00 68 00 E0 00 6F", hexOf(UteNotify.payload(UteNotify.TYPE_ZALO, "Chào", y25)!!))
        assertEquals("1E A1", hexOf(UteNotify.encode("ạ", y25)))
    }

    @Test fun controlCharactersAreDropped() {
        // `string2unicode`: bỏ < 0x20, 0x7F..0x9F, U+200E/200F.
        assertEquals("00 61 00 62 00 63", hexOf(UteNotify.encode("a\nb‎c\u0085", y25)))
    }

    @Test fun emptyTextSendsNothing() {
        assertNull(UteNotify.payload(UteNotify.TYPE_CALL, "", y25))
        assertNull(UteNotify.payload(UteNotify.TYPE_CALL, "\n", y25))
    }

    @Test fun longMessageIsCutAt240Bytes() {
        val payload = UteNotify.payload(UteNotify.TYPE_OTHERS, "x".repeat(200), y25)!!
        assertEquals(242, payload.size)
        assertEquals(0xF0, payload[1].toInt() and 0xFF)
        val sections = UteNotify.sections(0xC5, payload, UteNotify.messageCap(y25))
        // 242 = 13 × 18 + 8: 13 gói 20 byte + gói cuối 10 byte, seq 0..13.
        assertEquals(14, sections.size)
        assertTrue(sections.dropLast(1).all { it.size == 20 })
        assertEquals(10, sections.last().size)
        assertEquals((0..13).toList(), sections.map { it[1].toInt() })
        assertTrue(sections.all { it[0] == 0xC5.toByte() })
    }

    @Test fun exactMultipleOf18() {
        // 2 + 16 byte = 18: một gói đầy, rồi app gửi `C5 FD`.
        val payload = UteNotify.payload(3, "12345678", y25)!!
        assertEquals(1, UteNotify.sections(0xC5, payload, 242).size)
        assertEquals(20, UteNotify.sections(0xC5, payload, 242)[0].size)
    }

    @Test fun gb2312WithoutUnicodeBit() {
        assertEquals("03 02 41 42", hexOf(UteNotify.payload(3, "AB", old)!!))
        assertEquals("D6 D0", hexOf(UteNotify.encode("中", old)))
    }

    @Test fun senderNameIsCutAt30Bytes() {
        assertEquals("03 04 00 41 00 6E", hexOf(UteNotify.senderPayload("An", y25)))
        val long = UteNotify.senderPayload("Nguyễn Văn Bình Minh", y25)
        assertEquals(32, long.size)
        assertEquals(30, long[1].toInt())
        assertEquals(2, UteNotify.sections(0xC6, long, UteNotify.SENDER_CAP).size)
        assertEquals("C6 01", hexOf(UteNotify.sections(0xC6, long, UteNotify.SENDER_CAP)[1].copyOf(2)))
        // Tên rỗng: "unkown" như bản gốc.
        assertEquals(14, UteNotify.senderPayload("", y25).size)
    }

    @Test fun phoneNumberAndCallEnd() {
        assertEquals("45 FA 0A 30 39 31 32 33 34 35 36 37 38", hexOf(UteNotify.phoneNumber("0912345678")))
        assertEquals("45 FA 0C 2B 38 34 39 31 32 33 34 35 36 37 38", hexOf(UteNotify.phoneNumber("+84912345678")))
        assertEquals("C1 04", hexOf(UteNotify.CALL_END))
        assertEquals("DB AA", hexOf(UteNotify.QUERY_DISPLAY))
    }

    @Test fun displayMasks() {
        val p = hex("DB AA 00 00 00 55 55 55 44 44 44 33 33 33 00 00 0F 80 23 E6")
        val m = UteNotify.parseDisplay(p)!!
        assertEquals(0x8023E6, m[0])
        assertEquals(0x00000F, m[1])
        assertEquals(0x333333, m[2])
        assertEquals(0x444444, m[3])
        assertEquals(0x555555, m[4])
        assertNull(UteNotify.parseDisplay(p.copyOf(19)))
        val zalo = UteNotify.appFor("com.zing.zalo")!!
        assertTrue(UteNotify.displayed(zalo, m))
        assertTrue(UteNotify.displayed(UteNotify.appFor("com.instagram.android")!!, m))
        assertFalse(UteNotify.displayed(UteNotify.appFor("com.google.android.talk")!!, m))
        assertTrue(UteNotify.displayed(zalo, null))
    }

    @Test fun appTypes() {
        assertEquals(27, UteNotify.appType("com.zing.zalo"))
        assertEquals(24, UteNotify.appType("org.telegram.messenger"))
        assertEquals(7, UteNotify.appType("com.whatsapp.w4b"))
        assertEquals(9, UteNotify.appType("com.facebook.orca"))
        assertEquals(8, UteNotify.appType("com.skype.raider"))
        assertEquals(19, UteNotify.appType("com.google.android.gm"))
        assertEquals(4, UteNotify.appType("com.example.app"))
    }

    @Test fun appContentFollowsProRules() {
        // Instagram/Gmail, Android ≤ 14: "tiêu đề:nội dung".
        assertEquals("Lan:Chào", UteNotify.appContent("com.instagram.android", 13, "Lan", "Chào", "Lan: Chào", 34))
        // App khác có tickerText: chỉ nội dung.
        assertEquals("Chào", UteNotify.appContent("com.zing.zalo", 27, "Lan", "Chào", "Lan: Chào", 34))
        // Không có tickerText: "tiêu đề:nội dung".
        assertEquals("Lan:Chào", UteNotify.appContent("com.zing.zalo", 27, "Lan", "Chào", "", 35))
        // Instagram trên Android 15 đi nhánh thường.
        assertEquals("Chào", UteNotify.appContent("com.instagram.android", 13, "Lan", "Chào", "x", 35))
        // Emoji bị bỏ.
        assertEquals("Hi ", UteNotify.appContent("com.zing.zalo", 27, "", "Hi 😀", "", 34))
    }

    @Test fun emojiFilter() {
        assertEquals("ok", UteNotify.filterEmoji("o❤️k"))
        assertEquals("Tiếng Việt", UteNotify.filterEmoji("Tiếng Việt"))
        assertEquals("ab", UteNotify.filterEmoji("a👨‍👩‍👧b"))
    }

    @Test fun smsPrefix() {
        assertEquals("hello", UteNotify.stripSmsPrefix("An: hello", "An"))
        assertEquals("hello", UteNotify.stripSmsPrefix("：hello", "B"))
        assertEquals("An", UteNotify.stripSmsPrefix("An", "An"))
    }

    @Test fun quietHours() {
        assertTrue(UteNotify.inQuietHours(22 * 60, 7 * 60, 23 * 60 + 30))
        assertTrue(UteNotify.inQuietHours(22 * 60, 7 * 60, 7 * 60))
        assertFalse(UteNotify.inQuietHours(22 * 60, 7 * 60, 12 * 60))
        assertTrue(UteNotify.inQuietHours(9 * 60, 18 * 60, 18 * 60))
        assertFalse(UteNotify.inQuietHours(9 * 60, 18 * 60, 18 * 60 + 1))
    }

    @Test fun sectionsKeepBytes() {
        val payload = ByteArray(40) { it.toByte() }
        val joined = UteNotify.sections(0xC5, payload, 242).fold(ByteArray(0)) { acc, p -> acc + p.copyOfRange(2, p.size) }
        assertArrayEquals(payload, joined)
    }
}
