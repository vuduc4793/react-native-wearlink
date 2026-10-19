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

    /**
     * Giải mã Heart Rate Measurement (2A37): byte 0 là flags, bit 0 = 1 thì nhịp tim là UInt16 LE,
     * ngược lại là UInt8. Trả về null nếu gói quá ngắn.
     */
    fun parseHeartRate(value: ByteArray): Int? {
        if (value.isEmpty()) return null
        val flags = value[0].toInt()
        return if (flags and 0x01 != 0) {
            if (value.size < 3) null else (value[1].toInt() and 0xFF) or ((value[2].toInt() and 0xFF) shl 8)
        } else {
            if (value.size < 2) null else value[1].toInt() and 0xFF
        }
    }
}

class StandardDevice(
    context: Context,
    scanned: ScannedDevice,
    model: String,
) : BaseWearableDevice(scanned.address, scanned.name ?: model, StandardDriver) {

    private val gatt = GattConnection(context.applicationContext, scanned.device)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    @Volatile
    private var heartRateListener: ((Int) -> Unit)? = null

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
        }.onCompletion {
            withContext(NonCancellable) {
                runCatching {
                    if (state.value == ConnectionState.CONNECTED) gatt.disableNotifications(Gatt.HEART_RATE, Gatt.HEART_RATE_MEASUREMENT)
                }
            }
        }
    }

    private fun onNotification(n: GattNotification) {
        onPacketReceived(n.value, note = noteFor(n))
        when (n.characteristic) {
            Gatt.BATTERY_LEVEL -> if (n.value.isNotEmpty()) _battery.value = n.value[0].toInt() and 0xFF
            Gatt.HEART_RATE_MEASUREMENT -> Gatt.parseHeartRate(n.value)?.let { heartRateListener?.invoke(it) }
        }
    }

    private fun noteFor(n: GattNotification): String? = when (n.characteristic) {
        Gatt.BATTERY_LEVEL -> "pin ${n.value.firstOrNull()?.toInt()?.and(0xFF)} %"
        Gatt.HEART_RATE_MEASUREMENT -> Gatt.parseHeartRate(n.value)?.let { "nhịp tim $it bpm" }
        else -> null
    }
}
