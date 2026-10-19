package com.smartwear.gloryfit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Byte đối chiếu với `uterkthis.java:196-214, 1403-1418, 1953-1969` và `uterkfinal.java:74-125`. */
class UteSmsReplyTest {
    private fun hex(s: String) = s.split(" ").map { it.toInt(16).toByte() }.toByteArray()
    private fun hexOf(b: ByteArray) = b.joinToString(" ") { "%02X".format(it) }

    @Test fun enableAndResult() {
        assertEquals("52 01", hexOf(UteSmsReply.enable(true)))
        assertEquals("52 00", hexOf(UteSmsReply.enable(false)))
        assertEquals("52 FE", hexOf(UteSmsReply.result(true)))
        assertEquals("52 FF", hexOf(UteSmsReply.result(false)))
        assertTrue(UteSmsReply.isEnableAck(hex("52 01 FD")))
        assertTrue(UteSmsReply.isEnableAck(hex("52 00 FD")))
        assertFalse(UteSmsReply.isEnableAck(hex("52 FE")))
    }

    @Test fun templates() {
        assertEquals("46 FA 03 00 02 4F 4B", hexOf(UteSmsReply.template("OK", 0, 3)))
        assertEquals("46 FA 03 02 04 C4 91 C3 A1", hexOf(UteSmsReply.template("đá", 2, 3)))
        assertEquals("46 FD 00", hexOf(UteSmsReply.TEMPLATES_END))
        assertEquals("46 FB", hexOf(UteSmsReply.TEMPLATES_EMPTY))
    }

    @Test fun truncateLikeGbUtils() {
        assertEquals("a".repeat(90), UteSmsReply.truncate("a".repeat(90)))
        assertEquals("a".repeat(90) + "...", UteSmsReply.truncate("a".repeat(100)))
        // "ẩ" = 3 byte UTF-8: 31 ký tự = 93 byte ⇒ còn 30 ký tự + "...".
        assertEquals("ẩ".repeat(30) + "...", UteSmsReply.truncate("ẩ".repeat(31)))
        assertEquals(93, UteSmsReply.template("a".repeat(120), 0, 1)[4].toInt())
    }

    @Test fun watchRequest() {
        val p = hex("52 0A 30 39 31 32 33 34 35 36 37 38 06 C4 90 61 6E 67 20")
        val r = UteSmsReply.parseRequest(p)!!
        assertEquals("0912345678", r.number)
        assertEquals("Đang ", r.text)
        assertNull(UteSmsReply.parseRequest(hex("52 FE")))
        assertNull(UteSmsReply.parseRequest(hex("52 01 FD")))
        assertNull(UteSmsReply.parseRequest(p.copyOf(15)))
        assertNull(UteSmsReply.parseRequest(hex("46 0A 30 39 31")))
    }
}
