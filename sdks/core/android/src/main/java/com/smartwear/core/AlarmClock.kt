package com.smartwear.core

/**
 * Một báo thức trên thiết bị. [repeatDays]: bit0 = thứ Hai … bit6 = Chủ nhật, 0 = một lần. [label] = chữ hiện khi báo thức
 * (thiết bị không có chữ thì null). [id] do thiết bị / driver cấp; id < 0 khi thêm mới.
 */
data class Alarm(
    val id: Int,
    val hour: Int,
    val minute: Int,
    val repeatDays: Int,
    val enabled: Boolean,
    val label: String? = null,
)

/** Thiết bị có báo thức đọc/ghi được từ điện thoại. */
interface AlarmClock {
    val supportsAlarms: Boolean
    /** Số báo thức tối đa thiết bị giữ. */
    val maxAlarms: Int

    /** Đọc danh sách báo thức hiện có trên thiết bị. */
    suspend fun alarms(): List<Alarm>

    /** Thêm hoặc sửa theo [Alarm.id]: id < 0 hoặc chưa có trên thiết bị = thêm mới (driver cấp id). */
    suspend fun setAlarm(alarm: Alarm)

    suspend fun deleteAlarm(id: Int)
}
