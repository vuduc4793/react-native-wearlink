package com.smartwear.standard

import android.content.Context
import com.smartwear.core.BaseWearableDevice
import com.smartwear.core.Capability
import com.smartwear.core.ConnectionState
import com.smartwear.core.DeviceDriver
import com.smartwear.core.DeviceInfo
import com.smartwear.core.DriverMatch
import com.smartwear.core.GattConnection
import com.smartwear.core.GattNotification
import com.smartwear.core.HeartRateSample
import com.smartwear.core.HeartRateStreaming
import com.smartwear.core.Reading
import com.smartwear.core.ReadingStatus
import com.smartwear.core.ScannedDevice
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.onCompletion
import kotlinx.coroutines.withContext
import java.util.UUID

/**
 * Driver cho thiết bị dùng dịch vụ Bluetooth SIG chuẩn: Battery (180F), Device Information (180A),
 * Heart Rate (180D). Đứng cuối trong DeviceRegistry để driver cụ thể được ưu tiên.
 */
object StandardDriver : DeviceDriver {
    override val id = "standard"
    override val displayName = "Bluetooth chuẩn"

    override fun match(device: ScannedDevice): DriverMatch? {
        val uuids = device.serviceUuids
        if (Gatt.HEART_RATE !in uuids && Gatt.BATTERY !in uuids) return null
        val name = device.name?.takeIf { it.isNotBlank() } ?: return null
        return DriverMatch(name)
    }

    override fun create(context: Context, device: ScannedDevice, match: DriverMatch) =
        StandardDevice(context, device, match.model)
}

/** UUID chuẩn Bluetooth SIG. */
object Gatt {
    private fun uuid16(short: Int): UUID = UUID.fromString("0000%04x-0000-1000-8000-00805f9b34fb".format(short))

    val BATTERY: UUID = uuid16(0x180F)
    val BATTERY_LEVEL: UUID = uuid16(0x2A19)
    val DEVICE_INFO: UUID = uuid16(0x180A)
    val MODEL_NUMBER: UUID = uuid16(0x2A24)
    val SERIAL_NUMBER: UUID = uuid16(0x2A25)
    val FIRMWARE_REVISION: UUID = uuid16(0x2A26)
    val HARDWARE_REVISION: UUID = uuid16(0x2A27)
    val SOFTWARE_REVISION: UUID = uuid16(0x2A28)
    val MANUFACTURER_NAME: UUID = uuid16(0x2A29)
    val HEART_RATE: UUID = uuid16(0x180D)
    val HEART_RATE_MEASUREMENT: UUID = uuid16(0x2A37)

    /** Giải mã nhịp tim của gói 2A37 ([parseHeartRateMeasurement]); null nếu gói hỏng hoặc nhịp tim = 0. */
    fun parseHeartRate(value: ByteArray): Int? = parseHeartRateMeasurement(value)?.bpm

    /**
     * Giải mã Heart Rate Measurement (2A37, Bluetooth SIG): byte 0 là flags. Bit 0: nhịp tim UInt16 LE (1) hay UInt8 (0);
     * bit 2 = có báo tiếp xúc da, khi đó bit 1 = đang chạm; bit 3 = có Energy Expended (UInt16, bỏ qua); bit 4 = có RR,
     * mỗi RR là UInt16 LE đơn vị 1/1024 s (đổi ra ms, làm tròn). Nhịp tim 0 ⇒ `bpm` null (chưa đo được).
     * Trả về null nếu gói quá ngắn.
     */
    fun parseHeartRateMeasurement(value: ByteArray, timestamp: Long = System.currentTimeMillis()): com.smartwear.core.HeartRateSample? {
        if (value.isEmpty()) return null
        fun u8(i: Int) = value[i].toInt() and 0xFF
        val flags = u8(0)
        var i = 1
        val bpm = if (flags and 0x01 != 0) {
            if (value.size < 3) return null
            (u8(1) or (u8(2) shl 8)).also { i = 3 }
        } else {
            if (value.size < 2) return null
            u8(1).also { i = 2 }
        }
        val contact = if (flags and 0x04 != 0) flags and 0x02 != 0 else null
        if (flags and 0x08 != 0) i += 2
        val rr = mutableListOf<Int>()
        if (flags and 0x10 != 0) {
            while (i + 1 < value.size) {
                rr += Math.round((u8(i) or (u8(i + 1) shl 8)) * 1000.0 / 1024.0).toInt()
                i += 2
            }
        }
        return com.smartwear.core.HeartRateSample(bpm.takeIf { it > 0 }, rr, contact, timestamp)
    }
}

class StandardDevice(
    context: Context,
    scanned: ScannedDevice,
    model: String,
) : BaseWearableDevice(scanned.address, scanned.name ?: model, StandardDriver), HeartRateStreaming {

    private val gatt = GattConnection(context.applicationContext, scanned.device)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    @Volatile
    private var heartRateListener: ((Int) -> Unit)? = null

    @Volatile
    private var streamListener: ((HeartRateSample) -> Unit)? = null

    init {
        _info.value = DeviceInfo(model = model, extra = mapOf("Driver" to "Bluetooth chuẩn (sdks/standard)", "Địa chỉ" to id))
        gatt.onNotification = ::onNotification
        gatt.onDisconnected = { status -> onError("Mất kết nối (status=$status)") }
        scope.launch { gatt.state.collect(::onTransportState) }
    }

    override suspend fun connect() {
        _lastError.value = null
        try {
            val started = System.currentTimeMillis()
            gatt.connect()
            onLatency(System.currentTimeMillis() - started)

            val extra = linkedMapOf("Driver" to "Bluetooth chuẩn (sdks/standard)", "Địa chỉ" to id)
            suspend fun readString(uuid: UUID): String? =
                if (gatt.hasCharacteristic(Gatt.DEVICE_INFO, uuid)) {
                    runCatching { gatt.read(Gatt.DEVICE_INFO, uuid).decodeToString().trim('\u0000', ' ') }.getOrNull()
                } else null
            val manufacturer = readString(Gatt.MANUFACTURER_NAME)
            val model = readString(Gatt.MODEL_NUMBER)
            val firmware = readString(Gatt.FIRMWARE_REVISION)
            val hardware = readString(Gatt.HARDWARE_REVISION)
            val software = readString(Gatt.SOFTWARE_REVISION)
            manufacturer?.let { extra["Hãng"] = it }
            software?.let { extra["Phần mềm"] = it }
            extra["Dịch vụ chuẩn"] = listOfNotNull(
                "Pin (180F)".takeIf { gatt.hasService(Gatt.BATTERY) },
                "Thông tin (180A)".takeIf { gatt.hasService(Gatt.DEVICE_INFO) },
                "Nhịp tim (180D)".takeIf { gatt.hasService(Gatt.HEART_RATE) },
            ).joinToString().ifEmpty { "không có" }
            _info.value = DeviceInfo(
                model = listOfNotNull(manufacturer, model).joinToString(" ").ifEmpty { _info.value?.model ?: name },
                hardware = hardware,
                firmware = firmware,
                extra = extra,
            )

            // Nhịp tim chỉ là capability khi thiết bị thật sự có service 180D.
            val hasHeartRate = gatt.hasCharacteristic(Gatt.HEART_RATE, Gatt.HEART_RATE_MEASUREMENT)
            _capabilities.value = if (hasHeartRate) setOf(Capability.HEART_RATE) else emptySet()
            _measurable.value = _capabilities.value

            if (gatt.hasCharacteristic(Gatt.BATTERY, Gatt.BATTERY_LEVEL)) {
                refreshBattery()
                runCatching { gatt.enableNotifications(Gatt.BATTERY, Gatt.BATTERY_LEVEL) }
            }
            refreshRssi()
            markReady()
        } catch (e: Exception) {
            onError("Kết nối lỗi: ${e.message}")
            throw e
        }
    }

    override fun disconnect() = gatt.disconnect()

    override suspend fun refreshBattery() {
        if (!gatt.hasCharacteristic(Gatt.BATTERY, Gatt.BATTERY_LEVEL)) return
        runCatching { gatt.read(Gatt.BATTERY, Gatt.BATTERY_LEVEL) }
            .onSuccess { if (it.isNotEmpty()) _battery.value = it[0].toInt() and 0xFF }
            .onFailure { onError("Đọc pin lỗi: ${it.message}") }
    }

    override suspend fun refreshRssi() {
        runCatching { gatt.readRssi() }.onSuccess(::onRssi)
    }

    /** Nhịp tim chuẩn là luồng liên tục: phát mỗi khi thiết bị gửi, đến khi bị huỷ. */
    override fun measureImpl(capability: Capability): Flow<Reading> {
        if (capability != Capability.HEART_RATE || capability !in measurable.value) return emptyFlow()
        return callbackFlow {
            trySend(Reading(capability, ReadingStatus.MEASURING))
            heartRateListener = { bpm -> trySend(Reading(capability, ReadingStatus.OK, value = bpm.toDouble())) }
            gatt.enableNotifications(Gatt.HEART_RATE, Gatt.HEART_RATE_MEASUREMENT)
            awaitClose { heartRateListener = null }
        }.onCompletion { disableHeartRateIfIdle() }
    }

    override val supportsHeartRateStream: Boolean get() = Capability.HEART_RATE in measurable.value

    /** Mỗi gói 2A37 một mẫu (thường 1 s/lần), kèm RR và tiếp xúc da nếu dây đo gửi. */
    override fun heartRateStream(): Flow<HeartRateSample> {
        if (!supportsHeartRateStream) throw UnsupportedOperationException("Thiết bị không có dịch vụ nhịp tim 180D")
        return callbackFlow {
            streamListener = { trySend(it) }
            gatt.enableNotifications(Gatt.HEART_RATE, Gatt.HEART_RATE_MEASUREMENT)
            awaitClose { streamListener = null }
        }.onCompletion { disableHeartRateIfIdle() }
    }

    /** Tắt notify 2A37 khi cả phép đo lẫn luồng nhịp tim đều đã dừng. */
    private suspend fun disableHeartRateIfIdle() = withContext(NonCancellable) {
        runCatching {
            if (heartRateListener == null && streamListener == null && state.value == ConnectionState.CONNECTED) {
                gatt.disableNotifications(Gatt.HEART_RATE, Gatt.HEART_RATE_MEASUREMENT)
            }
        }
    }

    private fun onNotification(n: GattNotification) {
        onPacketReceived(n.value, note = noteFor(n))
        when (n.characteristic) {
            Gatt.BATTERY_LEVEL -> if (n.value.isNotEmpty()) _battery.value = n.value[0].toInt() and 0xFF
            Gatt.HEART_RATE_MEASUREMENT -> Gatt.parseHeartRateMeasurement(n.value)?.let { sample ->
                sample.bpm?.let { heartRateListener?.invoke(it) }
                streamListener?.invoke(sample)
            }
        }
    }

    private fun noteFor(n: GattNotification): String? = when (n.characteristic) {
        Gatt.BATTERY_LEVEL -> "pin ${n.value.firstOrNull()?.toInt()?.and(0xFF)} %"
        Gatt.HEART_RATE_MEASUREMENT -> Gatt.parseHeartRate(n.value)?.let { "nhịp tim $it bpm" }
        else -> null
    }
}
