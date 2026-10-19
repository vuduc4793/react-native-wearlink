package com.smartwear.core

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first

/**
 * Giữ sóng BLE yên khi đang truyền file lớn (mặt đồng hồ): [DeviceManager] hoãn các lần thử nối lại thiết bị khác
 * và ngừng đọc RSSI định kỳ cho đến khi hết [hold]. RSSI đi chung hàng đợi GATT với gói dữ liệu: một lần đọc chậm
 * làm luồng ghi đứng vài giây và đồng hồ HT43 huỷ nhận (`26 03 01`).
 */
object BleQuiet {
    private val holders = MutableStateFlow(0)

    suspend fun <T> hold(block: suspend () -> T): T {
        holders.value++
        try {
            return block()
        } finally {
            holders.value--
        }
    }

    /** Đang có ai giữ (đang truyền file lớn). */
    val active: Boolean get() = holders.value > 0

    /** Chờ tới khi không còn ai giữ. */
    suspend fun awaitIdle() {
        holders.first { it == 0 }
    }
}
