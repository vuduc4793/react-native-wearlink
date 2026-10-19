package com.smartwear.core

/** Một liên hệ gửi lên thiết bị. */
data class Contact(val name: String, val phone: String)

/** Danh bạ trên thiết bị (gọi điện qua thiết bị). Mặc định: không hỗ trợ. */
interface ContactsSync {
    val supportsContacts: Boolean get() = false

    /** Số liên hệ tối đa thiết bị nhận. */
    val maxContacts: Int get() = 0

    /** Thiết bị xoá được toàn bộ danh bạ bằng một lệnh ([clearContacts]). */
    val supportsClearContacts: Boolean get() = false

    /** Ghi danh bạ (thay toàn bộ danh bạ cũ). [progress] từ 0 đến 1. Trả về số liên hệ đã gửi. */
    suspend fun syncContacts(contacts: List<Contact>, progress: (Float) -> Unit = {}): Int =
        throw UnsupportedOperationException("Thiết bị không có danh bạ")

    /** Xoá toàn bộ danh bạ trên thiết bị. App nên hỏi người dùng xác nhận trước. */
    suspend fun clearContacts(): Unit = throw UnsupportedOperationException("Thiết bị không xoá được danh bạ")
}

/**
 * Kênh gọi điện Bluetooth cổ điển (HFP) của thiết bị. [paired]: trên Android lấy theo trạng thái ghép của hệ thống
 * (đáng tin hơn cờ thiết bị báo).
 */
data class CallAudioState(val name: String, val address: String, val enabled: Boolean, val paired: Boolean, val connected: Boolean)

/** Thiết bị gọi điện / trợ lý giọng nói qua Bluetooth cổ điển. Mặc định: không hỗ trợ. */
interface CallAudioLink {
    val supportsCallAudio: Boolean get() = false

    /** Đọc trạng thái kênh gọi (tên, MAC Bluetooth cổ điển, bật, đã ghép, đang nối). */
    suspend fun callAudioState(): CallAudioState = throw UnsupportedOperationException("Thiết bị không gọi điện được")

    /** Bật kênh gọi rồi ghép đôi Bluetooth cổ điển (Android: `createBond`, hệ thống hỏi xác nhận). False nếu đã ghép sẵn. */
    suspend fun pairCallAudio(): Boolean = throw UnsupportedOperationException("Thiết bị không gọi điện được")

    /** Bật / tắt kênh gọi điện trên thiết bị. */
    suspend fun setCallAudio(on: Boolean): Unit = throw UnsupportedOperationException("Thiết bị không gọi điện được")
}
