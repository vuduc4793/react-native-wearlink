package com.smartwear.qring

import com.smartwear.core.ScannedDevice
import java.util.UUID

/** Hằng số và bộ lọc quét cho dòng nhẫn chạy app QRing (Colmi R0x/R1x, Yawell…). */
object QRing {
    val SERVICE: UUID = UUID.fromString("6e40fff0-b5a3-f393-e0a9-e50e24dcca9e")
    val WRITE: UUID = UUID.fromString("6e400002-b5a3-f393-e0a9-e50e24dcca9e")
    val NOTIFY: UUID = UUID.fromString("6e400003-b5a3-f393-e0a9-e50e24dcca9e")

    val BIG_DATA_SERVICE: UUID = UUID.fromString("de5bf728-d711-4e47-af26-65e3012a5dc7")
    val BIG_DATA_NOTIFY: UUID = UUID.fromString("de5bf729-d711-4e47-af26-65e3012a5dc7")
    val BIG_DATA_WRITE: UUID = UUID.fromString("de5bf72a-d711-4e47-af26-65e3012a5dc7")

    val DEVICE_INFO: UUID = UUID.fromString("0000180a-0000-1000-8000-00805f9b34fb")
    val FIRMWARE_REVISION: UUID = UUID.fromString("00002a26-0000-1000-8000-00805f9b34fb")
    val HARDWARE_REVISION: UUID = UUID.fromString("00002a27-0000-1000-8000-00805f9b34fb")

    /** Service 16-bit nhẫn phát khi quảng bá (FEE7). Service 6e40fff0 chỉ thấy sau khi kết nối. */
    val ADVERTISED_SERVICE: UUID = UUID.fromString("0000fee7-0000-1000-8000-00805f9b34fb")

    /**
     * Tiền tố tên trong app QRing (server có thể bổ sung, nên danh sách này không đủ, ví dụ thiếu R09).
     * Bỏ "Y25": thiết bị Y25 của người dùng dùng app GloryFit, chưa xác nhận là giao thức QRing.
     * Xem sdks/qring/docs/01-connection.md §1.2.
     */
    val NAME_PREFIXES = listOf(
        "R0", "R1", "RING1", "boAtring", "Hello Ring", "MERLIN", "VK-5098", "H59", "DS1314", "DS520", "DS12", "DS500",
    )

    /**
     * Manufacturer data nhẫn phát khi quảng bá: company id 0x1234, payload `FE E7` + 6 byte MAC
     * (kiểm chứng trên R09: `FE E7 30 32 43 31 84 04` ứng với MAC 30:32:43:31:84:04).
     */
    const val MANUFACTURER_ID = 0x1234

    /**
     * Bộ lọc mặc định cho [com.smartwear.core.BleScanner.scan]. Không lọc theo FEE7 đơn thuần vì
     * nhiều thiết bị khác cũng phát UUID này (ví dụ đồng hồ COROS).
     */
    fun matches(device: ScannedDevice): Boolean {
        val name = device.name.orEmpty()
        return NAME_PREFIXES.any { name.startsWith(it) } || macFromAdvertisement(device) != null
    }

    /** MAC lấy từ manufacturer data, dùng được cả trên nền tảng ẩn MAC (iOS/macOS). */
    fun macFromAdvertisement(device: ScannedDevice): String? {
        val data = device.manufacturerData[MANUFACTURER_ID] ?: return null
        if (data.size < 8 || data[0] != 0xFE.toByte() || data[1] != 0xE7.toByte()) return null
        return (2 until 8).joinToString(":") { "%02X".format(data[it]) }
    }
}
