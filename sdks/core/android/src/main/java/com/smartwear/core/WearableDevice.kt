package com.smartwear.core

import android.content.Context
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow

enum class ReadingStatus { MEASURING, OK, NOT_WORN, ERROR }

/** Một giá trị đo, chuẩn hoá cho mọi loại thiết bị. */
data class Reading(
    val capability: Capability,
    val status: ReadingStatus,
    val value: Double? = null,
    val systolic: Int? = null,
    val diastolic: Int? = null,
    val errorCode: Int = 0,
    val timestamp: Long = System.currentTimeMillis(),
    /**
     * Ghi chú cho người dùng (ví dụ cách lấy kết quả nhanh hơn), như `note` bên iOS. Giá trị máy đọc được: [NOTE_TOUCH_SENSOR].
     */
    val note: String? = null,
    /**
     * Giá trị phụ của phép đo nhiều chỉ số (cùng khoá trên Android/iOS/RN): mỡ máu `totalCholesterol`, `triglycerides`, `hdl`,
     * `ldl` (mmol/L), acid uric `uricAcid` (μmol/L); thành phần cơ thể xem [Capability.BODY_COMPOSITION] của driver.
     */
    val extra: Map<String, Double> = emptyMap(),
) {
    /** [note] = [NOTE_TOUCH_SENSOR]: app cần nhắc đặt ngón tay lên cảm biến của vòng tay. */
    val needsTouch: Boolean get() = note == NOTE_TOUCH_SENSOR

    companion object {
        /**
         * `note` = "TOUCH_SENSOR": phép đo cần ngón tay đặt lên cảm biến / điện cực của vòng tay (thành phần máu, thành phần cơ thể).
         * Khi `MEASURING`: app nhắc "Đặt ngón tay lên cảm biến của vòng tay"; khi `NOT_WORN` / `ERROR`: đo hỏng vì không chạm.
         */
        const val NOTE_TOUCH_SENSOR = "TOUCH_SENSOR"

        /** Khoá `extra` tiến độ 0–100 (%) khi `MEASURING`, nếu thiết bị báo. */
        const val EXTRA_PROGRESS = "progress"
    }
}

/** Thông tin thiết bị. [extra] là chi tiết kỹ thuật riêng của driver (hiển thị trong "Chi tiết kỹ thuật"). */
data class DeviceInfo(
    val model: String,
    val hardware: String? = null,
    val firmware: String? = null,
    val extra: Map<String, String> = emptyMap(),
)

/** Thống kê kênh BLE của một thiết bị, đo thật trong lúc chạy. */
data class LinkStats(
    val rssi: Int? = null,
    val packetsReceived: Long = 0,
    /** Gói nhận được mỗi giây, cửa sổ trượt 5 s. */
    val packetsPerSecond: Double = 0.0,
    /** Số gói mỗi giây trong 20 s gần nhất, phần tử cuối là giây hiện tại. */
    val history: List<Int> = emptyList(),
    val errors: Int = 0,
    /** Thời gian từ lúc gửi request đến phản hồi đầu tiên, lần gần nhất. */
    val lastLatencyMs: Long? = null,
)

data class PacketLogEntry(
    val timestamp: Long,
    val outgoing: Boolean,
    val hex: String,
    val note: String? = null,
)

/**
 * Một thiết bị đang được quản lý, bất kể loại. UI chỉ làm việc qua interface này,
 * nên thêm loại thiết bị mới không cần sửa UI.
 */
interface WearableDevice {
    /** Android: MAC. */
    val id: String
    val name: String
    val driver: DeviceDriver

    val state: StateFlow<ConnectionState>
    val info: StateFlow<DeviceInfo?>
    val battery: StateFlow<Int?>

    /** Đang sạc (true/false); null nếu thiết bị không báo. */
    val charging: StateFlow<Boolean?>
    val capabilities: StateFlow<Set<Capability>>

    /** Capability có thể đo trực tiếp bằng [measure]. */
    val measurable: StateFlow<Set<Capability>>
    val latest: StateFlow<Map<Capability, Reading>>

    /** Capability đang đo (null nếu không đo). */
    val measuring: StateFlow<Capability?>
    val stats: StateFlow<LinkStats>
    val log: StateFlow<List<PacketLogEntry>>

    /** Lỗi gần nhất (kết nối/đo), để UI hiển thị. */
    val lastError: StateFlow<String?>

    /** Thao tác ghép nối đang chờ người dùng (null nếu không có). */
    val pairingPrompt: StateFlow<PairingPrompt?>

    /** Gửi mã ghép nối người dùng nhập, khi [pairingPrompt] là [PairingPrompt.EnterCode]. */
    fun submitPairingCode(code: String)

    /** Thiết bị có lưu dữ liệu lịch sử để đồng bộ không. */
    val supportsHistory: Boolean
    val history: StateFlow<DeviceHistory?>

    /** Tiến độ đồng bộ, null khi không đồng bộ. */
    val syncProgress: StateFlow<SyncProgress?>

    suspend fun connect()

    /**
     * Nối lại ở nền thiết bị đã lưu / vừa mất kết nối. Driver hỗ trợ thì chờ thiết bị quảng bá không giới hạn
     * (Android `autoConnect = true`); mặc định như [connect]. Huỷ bằng [disconnect].
     */
    suspend fun reconnect() = connect()
    fun disconnect()

    /** Đồng bộ dữ liệu lịch sử [days] ngày gần nhất (0 = hôm nay). Kết quả ở [history]. */
    suspend fun syncHistory(days: Int = 7): DeviceHistory

    /** Đo một capability. Flow kết thúc khi thiết bị báo xong / chưa đeo / lỗi, hoặc khi bị huỷ. */
    fun measure(capability: Capability): Flow<Reading>
    suspend fun refreshBattery()
    suspend fun refreshRssi()
}

/** Yêu cầu người dùng thao tác để ghép nối (bind) thiết bị trong lúc kết nối. */
sealed class PairingPrompt {
    /** Thiết bị hiện mã; người dùng nhập mã đó vào app rồi gọi [WearableDevice.submitPairingCode]. */
    data class EnterCode(val digits: Int, val message: String) : PairingPrompt()

    /** Người dùng cần bấm đồng ý trên chính thiết bị. */
    data class ConfirmOnDevice(val message: String) : PairingPrompt()
}

/** Kết quả driver nhận diện một thiết bị khi quét. */
data class DriverMatch(val model: String)

/** Một loại thiết bị (một SDK). */
interface DeviceDriver {
    val id: String
    val displayName: String
    fun match(device: ScannedDevice): DriverMatch?
    fun create(context: Context, device: ScannedDevice, match: DriverMatch): WearableDevice
}
