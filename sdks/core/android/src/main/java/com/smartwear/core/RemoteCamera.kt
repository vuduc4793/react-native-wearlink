package com.smartwear.core

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow

/** Sự kiện chụp ảnh từ xa do thiết bị gửi (như `RemoteCameraEvent` bên iOS, `WearableDevice.swift`). */
enum class RemoteCameraEvent {
    /** Bấm nút chụp trên thiết bị. */
    SHUTTER,

    /** Người dùng mở màn chụp trên thiết bị: app nên mở camera. */
    OPENED,

    /** Người dùng đóng màn chụp trên thiết bị. */
    CLOSED,
}

/**
 * Thiết bị có nút chụp ảnh từ xa (điều khiển camera điện thoại). Bản Android của `supportsRemoteCamera`,
 * `onRemoteCamera`, `setRemoteCamera(_:)` bên iOS. Mặc định: không hỗ trợ, không làm gì.
 */
interface RemoteCameraDevice {
    val supportsRemoteCamera: Boolean get() = false

    /** Sự kiện chụp ảnh từ xa từ thiết bị (driver đã bỏ lần chụp lặp quá nhanh). */
    val remoteCameraEvents: Flow<RemoteCameraEvent> get() = emptyFlow()

    /** Báo thiết bị app đã mở / đóng màn chụp ảnh (thiết bị hiện / ẩn nút chụp). */
    suspend fun setRemoteCamera(open: Boolean) {}
}
