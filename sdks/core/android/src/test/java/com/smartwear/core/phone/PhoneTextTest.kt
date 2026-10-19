package com.smartwear.core.phone

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PhoneTextTest {
    @Test fun smsApps() {
        assertTrue(PhoneText.isSmsApp("com.google.android.apps.messaging"))
        assertTrue(PhoneText.isSmsApp("com.android.mms"))
        assertFalse(PhoneText.isSmsApp("com.zing.zalo"))
    }

    @Test fun stripSmsPrefix() {
        assertEquals("Chào bạn", PhoneText.stripSmsPrefix("Mẹ: Chào bạn", "Mẹ"))
        assertEquals("ok", PhoneText.stripSmsPrefix("：ok", ""))
        assertEquals("Mẹ", PhoneText.stripSmsPrefix("Mẹ", "Mẹ"))
    }

    @Test fun volumeScale15() {
        assertEquals(0, PhoneText.volumePercent(0, 15))
        assertEquals(100, PhoneText.volumePercent(15, 15))
        // 7/15 ⇒ 46 %; thang khác 15 quy về 15 bậc.
        assertEquals(46, PhoneText.volumePercent(7, 15))
        assertEquals(53, PhoneText.volumePercent(8, 15))
        assertEquals(0, PhoneText.volumePercent(3, 0))
    }
}
