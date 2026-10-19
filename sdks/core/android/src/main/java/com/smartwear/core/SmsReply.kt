package com.smartwear.core

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.emptyFlow

/** Cấu hình trả lời SMS nhanh: [templates] = toàn bộ danh sách gửi thiết bị, theo thứ tự. */
data class SmsReplyConfig(val enabled: Boolean = false, val templates: List<String> = emptyList())

/** Thiết bị xin app gửi SMS [text] tới [number]. */
data class SmsReplyRequest(val number: String, val text: String)

private val NO_SMS_REPLY: StateFlow<SmsReplyConfig> = MutableStateFlow(SmsReplyConfig()).asStateFlow()

/**
 * Trả lời SMS nhanh từ thiết bị (chỉ Android): người dùng chọn mẫu trên thiết bị, app gửi SMS rồi báo kết quả.
 * Mặc định: không hỗ trợ, không làm gì.
 */
interface SmsQuickReply {
    val supportsSmsReply: Boolean get() = false

    /** Cấu hình đã lưu (theo thiết bị). */
    val smsReply: StateFlow<SmsReplyConfig> get() = NO_SMS_REPLY

    /** Mẫu cố định luôn gửi sau mẫu của người dùng (như app gốc); app hiển thị, không cho sửa. */
    val smsReplyFixedTemplates: List<String> get() = emptyList()

    /** Số mẫu người dùng tự thêm tối đa. */
    val smsReplyMaxCustom: Int get() = 0

    /** Lưu và gửi xuống thiết bị (nếu đang kết nối). [templates] = toàn bộ danh sách, gồm cả mẫu cố định. */
    suspend fun setSmsReply(enabled: Boolean, templates: List<String>) {}

    /** Thiết bị xin gửi SMS. App gửi rồi gọi [sendSmsReplyResult]. */
    val smsReplyRequests: Flow<SmsReplyRequest> get() = emptyFlow()

    /** Báo thiết bị kết quả gửi SMS. */
    suspend fun sendSmsReplyResult(ok: Boolean) {}
}
