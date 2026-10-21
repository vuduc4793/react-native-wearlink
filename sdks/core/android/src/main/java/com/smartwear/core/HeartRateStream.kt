package com.smartwear.core

import kotlinx.coroutines.flow.Flow

/**
 * Một mẫu nhịp tim của luồng liên tục. [bpm] null = thiết bị gửi gói nhưng chưa đo được (chưa đeo / cảm biến không chạm da);
 * [rrMs] khoảng RR (ms) nếu thiết bị gửi (dây đo chuẩn 2A37); [contact] = cảm biến chạm da, null nếu thiết bị không báo.
 */
data class HeartRateSample(
    val bpm: Int?,
    val rrMs: List<Int> = emptyList(),
    val contact: Boolean? = null,
    val timestamp: Long = System.currentTimeMillis(),
)

/**
 * Nhịp tim liên tục (vd khi ghi bài chạy bằng GPS điện thoại). Khác [WearableDevice.measure]: không tự kết thúc, phát mỗi giá trị
 * thiết bị gửi tới khi bị huỷ. Không tạo bài tập trên thiết bị. Đừng chạy song song với `measure(HEART_RATE)` trên cùng thiết bị.
 */
interface HeartRateStreaming {
    val supportsHeartRateStream: Boolean get() = false

    /**
     * Luồng chạy tới khi bị huỷ (huỷ thì driver gửi lệnh dừng). Thiết bị phải đang kết nối; mất kết nối thì flow kết thúc
     * (hoặc lỗi), bên gọi tự mở lại khi nối lại.
     */
    fun heartRateStream(): Flow<HeartRateSample> = throw UnsupportedOperationException("Thiết bị không có nhịp tim liên tục")
}
