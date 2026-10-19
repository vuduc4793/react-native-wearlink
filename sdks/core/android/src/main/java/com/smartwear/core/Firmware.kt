package com.smartwear.core

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Kết quả kiểm tra một file firmware cho thiết bị này: [valid] = đúng model, đúng định dạng, chữ ký chính hãng hợp lệ.
 * [reason] = lý do từ chối (khi không hợp lệ); [details] = mô tả kỹ thuật để ghi log.
 */
data class FirmwareCheck(
    val valid: Boolean,
    val model: String? = null,
    val version: String? = null,
    val reason: String? = null,
    val details: String? = null,
)

/** Tuỳ chọn nạp firmware. [activate] = false: truyền + kiểm tra, không kích hoạt. [declaredBattery]: pin người dùng khai (khi không đọc được). */
data class FirmwareUpdateOptions(
    val activate: Boolean = true,
    val packetDelayMs: Long = 10,
    val declaredBattery: Int? = null,
    val trace: Boolean = false,
)

private val NOT_UPDATING: StateFlow<Boolean> = MutableStateFlow(false).asStateFlow()

/**
 * Cập nhật firmware (Android). Chỉ nhận image chính hãng đã ký, đúng model; driver giữ mọi bước kiểm tra.
 * Mặc định: không hỗ trợ.
 */
interface FirmwareUpdatable {
    val supportsFirmwareUpdate: Boolean get() = false

    /** Kiểm tra file (không Bluetooth, không ghi gì). */
    fun checkFirmware(image: ByteArray): FirmwareCheck = FirmwareCheck(false, reason = "Thiết bị không hỗ trợ cập nhật firmware")

    /**
     * Kiểm tra lại rồi nạp [image]. [progress] từ 0 đến 1. Trả về true nếu đã gửi lệnh kích hoạt. Lỗi / huỷ ⇒ ném ngoại lệ,
     * không kích hoạt.
     */
    suspend fun updateFirmware(image: ByteArray, options: FirmwareUpdateOptions = FirmwareUpdateOptions(), progress: (Float) -> Unit = {}): Boolean =
        throw UnsupportedOperationException("Thiết bị không hỗ trợ cập nhật firmware")

    /** Huỷ phiên đang nạp (không bao giờ kích hoạt khi huỷ). */
    fun cancelFirmwareUpdate() {}

    val firmwareUpdating: StateFlow<Boolean> get() = NOT_UPDATING
}
