package com.smartwear.core

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.emptyFlow

/**
 * Lớp "Cài đặt & điều khiển" chung: mỗi tính năng không phải phép đo (tìm đồng hồ, nhắc vận động, không làm phiền,
 * mục tiêu, đo tự động…) là một [DeviceControl]. Driver dựng danh sách theo bảng tính năng của chính thiết bị và giữ
 * lệnh thật; app chỉ vẽ theo [DeviceControl.kind], nên thêm tính năng không cần sửa giao diện.
 */
data class DeviceControl(
    /** Khoá ổn định, vd "sedentary.enabled". */
    val id: String,
    /** Nhóm hiển thị, vd "Nhắc nhở". */
    val group: String,
    val title: String,
    val kind: Kind,
    val value: ControlValue? = null,
    val detail: String? = null,
    /** NUMBER: khoảng và bước. */
    val min: Int = 0,
    val max: Int = 0,
    val step: Int = 1,
    val unit: String = "",
    /** CHOICE: nhãn các lựa chọn (giá trị là chỉ số). */
    val options: List<String> = emptyList(),
    /** Ẩn/khoá khi mục cha đang tắt (vd chu kỳ nhắc khi đang tắt nhắc). */
    val enabled: Boolean = true,
    /**
     * ACTION nguy hiểm / không hoàn tác được (xoá dữ liệu, xoá danh bạ): câu hỏi app PHẢI hiện cho người dùng xác nhận
     * trước khi gọi [ConfigurableDevice.runAction]. Null = chạy ngay.
     */
    val confirm: String? = null,
) {
    enum class Kind { ACTION, TOGGLE, NUMBER, TIME_RANGE, CHOICE }
}

sealed interface ControlValue {
    data class Bool(val on: Boolean) : ControlValue
    data class Number(val value: Int) : ControlValue
    /** Khung giờ, phút tính từ 0:00. */
    data class TimeRange(val fromMinute: Int, val toMinute: Int) : ControlValue
}

/** Thiết bị có cài đặt / điều khiển. */
interface ConfigurableDevice {
    val controls: StateFlow<List<DeviceControl>>

    /** Đổi một mục (lưu lại và gửi xuống thiết bị ngay nếu đang kết nối). */
    suspend fun setControl(id: String, value: ControlValue)

    /** Chạy một hành động (vd "find.start"). */
    suspend fun runAction(id: String)

    /** Thiết bị yêu cầu tìm điện thoại: true = đổ chuông, false = dừng. */
    val findPhoneRequests: Flow<Boolean> get() = emptyFlow()

    /**
     * Báo thiết bị là điện thoại đang / đã thôi đổ chuông, để thiết bị tắt màn "đang tìm điện thoại" khi người dùng
     * bấm "Đã tìm thấy" trên điện thoại. Mặc định không làm gì.
     */
    suspend fun setPhoneRinging(ringing: Boolean) {}
}

/** Phút trong ngày → "hh:mm". */
fun formatMinuteOfDay(m: Int): String = "%02d:%02d".format((m / 60) % 24, m % 60)
