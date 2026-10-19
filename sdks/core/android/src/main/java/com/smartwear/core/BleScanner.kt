package com.smartwear.core

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.buffer
import kotlinx.coroutines.flow.callbackFlow
import java.util.UUID

/** Một thiết bị thấy được khi quét. [address] là MAC thật trên Android. */
class ScannedDevice(
    val device: BluetoothDevice,
    val address: String,
    val name: String?,
    val rssi: Int,
    val serviceUuids: List<UUID>,
    /** Key là company id (16 bit). */
    val manufacturerData: Map<Int, ByteArray>,
) {
    override fun toString() = "ScannedDevice($address, $name, rssi=$rssi)"
}

/**
 * Quét BLE và lọc bằng [match] (lọc bằng phần mềm, vì ScanFilter của Android không lọc được
 * theo tiền tố tên). Mỗi thiết bị có thể được phát nhiều lần khi RSSI thay đổi.
 * Cần quyền BLUETOOTH_SCAN (Android 12+) hoặc ACCESS_FINE_LOCATION (Android 11-), xem [BlePermissions].
 */
@SuppressLint("MissingPermission")
class BleScanner(private val context: Context) {

    fun scan(match: (ScannedDevice) -> Boolean = { true }): Flow<ScannedDevice> = callbackFlow {
        val adapter = context.getSystemService(BluetoothManager::class.java)?.adapter
        if (adapter == null || !adapter.isEnabled) {
            close(IllegalStateException("Bluetooth đang tắt"))
            return@callbackFlow
        }
        val scanner = adapter.bluetoothLeScanner ?: run {
            close(IllegalStateException("Không có BLE scanner"))
            return@callbackFlow
        }

        val callback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                val scanned = result.toScannedDevice()
                if (match(scanned)) trySend(scanned)
            }

            override fun onBatchScanResults(results: MutableList<ScanResult>) {
                results.forEach { onScanResult(ScanSettings.CALLBACK_TYPE_ALL_MATCHES, it) }
            }

            override fun onScanFailed(errorCode: Int) {
                close(IllegalStateException("Quét BLE thất bại, mã lỗi $errorCode"))
            }
        }

        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()
        SmartWearLog.d("Bắt đầu quét BLE")
        scanner.startScan(null, settings, callback)
        awaitClose {
            SmartWearLog.d("Dừng quét BLE")
            runCatching { scanner.stopScan(callback) }
        }
    }
        // Android gọi ScanCallback trên luồng chính: khung UI chậm (Redmi Note 7 Pro ~70 ms) ⇒ hàng trăm gói dồn rồi xả một lúc,
        // bộ đệm mặc định 64 tràn và trySend vứt 30–50% gói (đo 19/10/2026) ⇒ Y25 chỉ phát vài giây/đợt bị rơi trọn.
        // Phía nhận (phân loại trên luồng nền) trung bình nhanh hơn nhiều ⇒ không giới hạn vẫn không phình.
        .buffer(Channel.UNLIMITED)

    private fun ScanResult.toScannedDevice(): ScannedDevice {
        val record = scanRecord
        val manufacturer = buildMap {
            val data = record?.manufacturerSpecificData
            if (data != null) for (i in 0 until data.size()) put(data.keyAt(i), data.valueAt(i))
        }
        return ScannedDevice(
            device = device,
            address = device.address,
            name = record?.deviceName ?: device.name,
            rssi = rssi,
            serviceUuids = record?.serviceUuids?.map { it.uuid }.orEmpty(),
            manufacturerData = manufacturer,
        )
    }
}
