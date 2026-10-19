package com.smartwear.core.phone

/**
 * Quy tắc thuần (không cần Android) của phần "dán" điện thoại ↔ thiết bị, chép theo GloryFitPro 1.9.0.2
 * (`P/` = `sdks/gloryfit/research/xapk-pro/jadx-out/sources/`).
 */
object PhoneText {
    /** Google Messages: nội dung tin lấy từ `tickerText` (`StatusbarMsgNotificationListener.java:229-262`). */
    const val GOOGLE_MESSAGES = "com.google.android.apps.messaging"

    /** App tin nhắn hệ thống: đi đường SMS, không đi đường app (`RemindType.PACKAGE_NAME_MMS`). */
    val SMS_PACKAGES = listOf(
        "com.android.mms", "com.hihonor.mms", "com.android.mms.service", "com.huawei.mms", "com.oppo.mms", "com.vivo.mms",
    )

    fun isSmsApp(pkg: String) = pkg == GOOGLE_MESSAGES || pkg in SMS_PACKAGES

    /**
     * Bỏ phần "người gửi:" ở đầu tin SMS như `StatusbarMsgNotificationListener.java:247-258`: nếu tin bắt đầu bằng
     * [contact] (và khác [contact]) thì xoá [contact], rồi bỏ một tiền tố ": ", "：" hoặc ":".
     */
    fun stripSmsPrefix(content: String, contact: String): String {
        var s = content
        if (contact.isNotEmpty() && s.startsWith(contact) && s != contact) s = s.replace(contact, "")
        for (p in listOf(": ", "：", ":")) if (s.startsWith(p)) s = s.replaceFirst(p, "")
        return s
    }

    /**
     * Âm lượng thang 15 như `ServicePresenter.getCurrentVolume` (`getMaxVolume()` = 15) rồi ra phần trăm
     * `min(cur·100/15, 100)` (`SearchDeviceModelImpl.java:227`). jadx in phép chia `stream / max` không ép kiểu (sẽ chỉ ra 0
     * hoặc 15); ở đây chia số thực, đúng ý định của bản gốc.
     */
    fun volumePercent(streamVolume: Int, streamMax: Int): Int {
        if (streamMax <= 0) return 0
        val scaled = Math.round(streamVolume.toFloat() / streamMax * 15).coerceIn(0, 15)
        return minOf(scaled * 100 / 15, 100)
    }
}
