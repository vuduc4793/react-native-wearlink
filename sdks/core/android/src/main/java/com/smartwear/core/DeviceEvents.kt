package com.smartwear.core

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow

/** Nút / sự kiện lẻ thiết bị tự gửi (không thuộc tính năng nào khác). */
enum class DeviceEvent {
    /** Bấm nút đổi màn hình. */
    SWITCH_SCREEN_BUTTON,

    /** Giữ phím thứ 2. */
    LONG_PRESS_BUTTON_2,

    /** Giữ phím thứ 3. */
    LONG_PRESS_BUTTON_3,

    /** Bấm nút SOS. */
    SOS_BUTTON,
}

/** Thiết bị gửi sự kiện nút bấm lẻ. Mặc định: không có. */
interface DeviceEvents {
    val deviceEvents: Flow<DeviceEvent> get() = emptyFlow()
}
