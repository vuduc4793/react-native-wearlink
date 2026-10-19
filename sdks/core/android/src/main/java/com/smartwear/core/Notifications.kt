package com.smartwear.core

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow

/**
 * Một app có thể đẩy thông báo lên thiết bị. [key] ổn định (vd "zalo"), dùng trong [NotificationDisplay.sendNotification]
 * và trong cấu hình chuyển tiếp (`com.smartwear.core.phone.PhoneLinkConfig.apps`). [packages] = gói Android của app.
 * [hasIcon] = thiết bị có icon riêng cho app này (đọc từ thiết bị nếu được; không đọc được thì coi như có).
 */
data class NotificationApp(val key: String, val name: String, val packages: List<String>, val hasIcon: Boolean)

/**
 * Thiết bị hiện thông báo app / tin SMS do điện thoại đẩy (Android). Bên iOS hệ thống tự đẩy qua ANCS nên chỉ có
 * `ancsAuthorized`, không gửi. Mặc định: không hỗ trợ, không làm gì.
 */
interface NotificationDisplay {
    val supportsNotifications: Boolean get() = false

    /** Danh sách app thiết bị nhận thông báo (thứ tự như app gốc), để app dựng công tắc từng app. */
    fun notificationApps(): List<NotificationApp> = emptyList()

    /**
     * Đẩy một thông báo của app [appKey] (một [NotificationApp.key]; key lạ = "app khác"). [ticker] là `tickerText` của
     * thông báo Android: một số thiết bị chọn nội dung theo nó (GloryFit làm như app gốc). Trả về false nếu chưa kết nối,
     * nội dung rỗng hoặc thiết bị không xác nhận.
     */
    suspend fun sendNotification(appKey: String, title: String, text: String, ticker: String? = null): Boolean = false

    /** Đẩy một tin SMS: [sender] là tên trong danh bạ (không có thì số). */
    suspend fun sendSms(sender: String, text: String): Boolean = false

    /** Đang trong khung "không làm phiền" theo giờ đã đặt cho thiết bị ⇒ app không nên đẩy thông báo/SMS. Cuộc gọi không kiểm. */
    fun inQuietHours(): Boolean = false
}

/**
 * Thiết bị báo cuộc gọi đến (Android) và cho từ chối cuộc gọi ngay trên thiết bị. Bên iOS cuộc gọi đi qua ANCS/HFP.
 * Mặc định: không hỗ trợ, không làm gì.
 */
interface CallDisplay {
    val supportsIncomingCall: Boolean get() = false
    val supportsRejectCall: Boolean get() = false

    /** Người dùng đã bật "từ chối cuộc gọi từ thiết bị" (cài đặt lưu theo thiết bị, gửi xuống thiết bị). */
    val rejectCallEnabled: Boolean get() = false

    /** Bật/tắt nút từ chối cuộc gọi trên thiết bị (lưu lại và gửi xuống nếu đang kết nối). */
    suspend fun setRejectCallEnabled(enabled: Boolean) {}

    /** Có cuộc gọi đến: [name] = tên trong danh bạ (không có thì số), [number] = số gọi đến nếu biết. */
    suspend fun incomingCall(name: String, number: String?): Boolean = false

    /** Màn cuộc gọi trên thiết bị nên tắt (nghe máy, cúp máy, gọi nhỡ). */
    suspend fun callEnded() {}

    /** Người dùng bấm từ chối trên thiết bị (chỉ phát khi [rejectCallEnabled]): app cúp máy. */
    val rejectCallRequests: Flow<Unit> get() = emptyFlow()
}
