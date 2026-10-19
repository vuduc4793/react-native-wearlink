package com.smartwear.core

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.os.Build
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeout
import java.util.UUID

enum class ConnectionState { DISCONNECTED, CONNECTING, CONNECTED, DISCONNECTING }

class GattException(message: String, val status: Int = -1) : Exception(message)

/** Một gói notify nhận được từ thiết bị. */
class GattNotification(val characteristic: UUID, val value: ByteArray)

/**
 * Kết nối GATT với hàng đợi tuần tự: mỗi thao tác (đọc, ghi, bật notify, MTU) chỉ được gửi
 * khi callback của thao tác trước đã về, đúng như Android yêu cầu.
 *
 * Không chứa giao thức của thiết bị cụ thể nào, các SDK thiết bị (qring, …) dựng trên lớp này.
 * Cần quyền BLUETOOTH_CONNECT (Android 12+), xem [BlePermissions].
 */
@SuppressLint("MissingPermission")
class GattConnection(
    private val context: Context,
    val device: BluetoothDevice,
    private val operationTimeoutMs: Long = 5_000,
    /**
     * Gọi `BluetoothGatt.refresh()` khi đóng. Tắt cho kết nối GATT phụ chạy song song với kết nối chính trên cùng
     * thiết bị (ví dụ DFU Realtek): refresh khi liên kết còn sống làm stack khám phá lại service của mọi client.
     */
    private val refreshCacheOnClose: Boolean = true,
) {
    private val _state = MutableStateFlow(ConnectionState.DISCONNECTED)
    val state: StateFlow<ConnectionState> = _state.asStateFlow()

    /**
     * Được gọi đồng bộ trên luồng binder của Bluetooth cho mỗi notify. Đặt trước khi [connect]
     * để không lỡ gói nào. Không làm việc nặng trong callback này.
     */
    @Volatile
    var onNotification: ((GattNotification) -> Unit)? = null

    /** Được gọi khi kết nối bị ngắt ngoài ý muốn (sau khi đã CONNECTED). */
    @Volatile
    var onDisconnected: ((status: Int) -> Unit)? = null

    var mtu: Int = 23
        private set

    private val queue = Mutex()
    private var gatt: BluetoothGatt? = null
    private var connectResult: CompletableDeferred<Unit>? = null
    private var discoverResult: CompletableDeferred<Unit>? = null
    private var pending: Pending? = null

    private class Pending(val kind: Kind, val uuid: UUID?, val result: CompletableDeferred<Any?>)
    private enum class Kind { READ, WRITE, DESCRIPTOR_WRITE, MTU, RSSI }

    /**
     * Kết nối, chờ 500 ms rồi khám phá service. Ném [GattException] nếu thất bại.
     *
     * [autoConnect] = true (nối lại thiết bị đã biết, như `connectPeripheral` của iOS): controller tự nối khi
     * bắt được gói quảng bá, kể cả khi thiết bị quảng bá thưa; không giới hạn thời gian chờ ([timeoutMs] chỉ áp
     * cho bước khám phá service). Huỷ bằng [disconnect] hoặc huỷ coroutine (đều gọi `gatt.disconnect()` + `close()`).
     */
    suspend fun connect(timeoutMs: Long = 40_000, autoConnect: Boolean = false) {
        check(_state.value == ConnectionState.DISCONNECTED) { "Đang ở trạng thái ${_state.value}" }
        _state.value = ConnectionState.CONNECTING
        val connected = CompletableDeferred<Unit>().also { connectResult = it }
        try {
            if (autoConnect) {
                gatt = device.connectGatt(context, true, callback, BluetoothDevice.TRANSPORT_LE)
                    ?: throw GattException("connectGatt trả về null")
                connected.await()
                withTimeout(timeoutMs) { discover() }
            } else {
                withTimeout(timeoutMs) {
                    gatt = device.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE)
                        ?: throw GattException("connectGatt trả về null")
                    connected.await()
                    discover()
                }
            }
            _state.value = ConnectionState.CONNECTED
            SmartWearLog.i("Đã kết nối ${device.address}")
        } catch (e: TimeoutCancellationException) {
            closeGatt()
            throw GattException("Hết thời gian kết nối ${device.address}")
        } catch (e: Exception) {
            closeGatt()
            throw e
        }
    }

    private suspend fun discover() {
        // SDK gốc đợi 500 ms trước khi discoverServices, một số firmware cần khoảng nghỉ này.
        delay(500)
        val discovered = CompletableDeferred<Unit>().also { discoverResult = it }
        if (gatt?.discoverServices() != true) {
            delay(1_000)
            if (gatt?.discoverServices() != true) throw GattException("discoverServices thất bại")
        }
        discovered.await()
    }

    fun hasService(service: UUID): Boolean = gatt?.getService(service) != null

    suspend fun enableNotifications(service: UUID, characteristic: UUID) = setNotifications(service, characteristic, true)

    suspend fun disableNotifications(service: UUID, characteristic: UUID) = setNotifications(service, characteristic, false)

    fun hasCharacteristic(service: UUID, characteristic: UUID): Boolean =
        gatt?.getService(service)?.getCharacteristic(characteristic) != null

    /** Service đầu tiên chứa [characteristic] (tìm trên mọi service đã khám phá), hoặc null. */
    fun serviceOf(characteristic: UUID): UUID? =
        gatt?.services?.firstOrNull { it.getCharacteristic(characteristic) != null }?.uuid

    /** Bảng GATT đã khám phá: service → (characteristic, properties). Chỉ để ghi log/chẩn đoán. */
    fun gattTable(): Map<UUID, List<Pair<UUID, Int>>> =
        gatt?.services.orEmpty().associate { s -> s.uuid to s.characteristics.map { it.uuid to it.properties } }

    /** Characteristic có hỗ trợ ghi có phản hồi (WRITE) không; nếu không thì chỉ ghi không phản hồi. */
    fun supportsWriteWithResponse(service: UUID, characteristic: UUID): Boolean {
        val ch = gatt?.getService(service)?.getCharacteristic(characteristic) ?: return true
        return ch.properties and BluetoothGattCharacteristic.PROPERTY_WRITE != 0
    }

    /** Đọc RSSI hiện tại của kết nối. */
    /** RSSI chỉ để hiển thị: chờ ngắn để không chặn hàng đợi (callback đôi khi đến rất muộn hoặc không đến). */
    suspend fun readRssi(): Int = enqueue(Kind.RSSI, null, timeoutMs = 1_000) { g -> g.readRemoteRssi() } as Int

    private suspend fun setNotifications(service: UUID, characteristic: UUID, enable: Boolean) = enqueue(Kind.DESCRIPTOR_WRITE, characteristic) { g ->
        val ch = characteristic(g, service, characteristic)
        if (!g.setCharacteristicNotification(ch, enable)) throw GattException("setCharacteristicNotification thất bại: $characteristic")
        val cccd = ch.getDescriptor(CCCD) ?: throw GattException("Không có CCCD trên $characteristic")
        val value = if (enable) BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE else BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            g.writeDescriptor(cccd, value) == BluetoothGatt.GATT_SUCCESS
        } else {
            @Suppress("DEPRECATION")
            cccd.value = value
            @Suppress("DEPRECATION")
            g.writeDescriptor(cccd)
        }
    }.let { }

    suspend fun read(service: UUID, characteristic: UUID): ByteArray = enqueue(Kind.READ, characteristic) { g ->
        g.readCharacteristic(characteristic(g, service, characteristic))
    } as ByteArray

    suspend fun write(service: UUID, characteristic: UUID, value: ByteArray, withResponse: Boolean = true) {
        enqueue(Kind.WRITE, characteristic) { g ->
            val ch = characteristic(g, service, characteristic)
            val type = if (withResponse) BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
            else BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                g.writeCharacteristic(ch, value, type) == BluetoothGatt.GATT_SUCCESS
            } else {
                @Suppress("DEPRECATION")
                ch.writeType = type
                @Suppress("DEPRECATION")
                ch.value = value
                @Suppress("DEPRECATION")
                g.writeCharacteristic(ch)
            }
        }
    }

    /** Yêu cầu MTU; trả về MTU thực tế (có thể nhỏ hơn yêu cầu). */
    suspend fun requestMtu(requested: Int): Int = enqueue(Kind.MTU, null) { g -> g.requestMtu(requested) } as Int

    /** Ngắt kết nối và giải phóng tài nguyên. Gọi được nhiều lần. */
    fun disconnect() {
        if (_state.value == ConnectionState.DISCONNECTED) return
        _state.value = ConnectionState.DISCONNECTING
        onDisconnected = null
        closeGatt()
    }

    private suspend fun enqueue(kind: Kind, uuid: UUID?, timeoutMs: Long = operationTimeoutMs, start: (BluetoothGatt) -> Boolean): Any? = queue.withLock {
        val g = gatt ?: throw GattException("Chưa kết nối")
        val result = CompletableDeferred<Any?>()
        pending = Pending(kind, uuid, result)
        try {
            if (!start(g)) throw GattException("Không gửi được thao tác $kind ${uuid ?: ""}")
            withTimeout(timeoutMs) { result.await() }
        } catch (e: TimeoutCancellationException) {
            throw GattException("Hết thời gian chờ $kind ${uuid ?: ""}")
        } finally {
            pending = null
        }
    }

    private fun complete(kind: Kind, uuid: UUID?, status: Int, value: Any?) {
        val p = pending ?: return
        if (p.kind != kind || (p.uuid != null && uuid != null && p.uuid != uuid)) return
        if (status == BluetoothGatt.GATT_SUCCESS) p.result.complete(value)
        else p.result.completeExceptionally(GattException("$kind thất bại", status))
    }

    private fun characteristic(g: BluetoothGatt, service: UUID, characteristic: UUID): BluetoothGattCharacteristic =
        g.getService(service)?.getCharacteristic(characteristic)
            ?: throw GattException("Không tìm thấy characteristic $characteristic trong service $service")

    private fun closeGatt() {
        val g = gatt
        gatt = null
        val error = GattException("Đã ngắt kết nối")
        pending?.result?.completeExceptionally(error)
        connectResult?.completeExceptionally(error)
        discoverResult?.completeExceptionally(error)
        if (g != null) {
            g.disconnect()
            if (refreshCacheOnClose) refreshCache(g)
            g.close()
        }
        _state.value = ConnectionState.DISCONNECTED
    }

    /** Xoá cache service của Android (API ẩn), hữu ích khi firmware đổi bảng GATT sau OTA. */
    private fun refreshCache(g: BluetoothGatt) {
        runCatching { g.javaClass.getMethod("refresh").invoke(g) }
    }

    private val callback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            SmartWearLog.d("onConnectionStateChange status=$status newState=$newState")
            if (status == BluetoothGatt.GATT_SUCCESS && newState == BluetoothProfile.STATE_CONNECTED) {
                connectResult?.complete(Unit)
                return
            }
            val wasConnected = _state.value == ConnectionState.CONNECTED
            val listener = onDisconnected
            if (gatt === g) closeGatt() else g.close()
            if (wasConnected) listener?.invoke(status)
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            if (status == BluetoothGatt.GATT_SUCCESS) discoverResult?.complete(Unit)
            else discoverResult?.completeExceptionally(GattException("Khám phá service thất bại", status))
        }

        @Deprecated("Deprecated in Java")
        override fun onCharacteristicRead(g: BluetoothGatt, ch: BluetoothGattCharacteristic, status: Int) {
            @Suppress("DEPRECATION")
            complete(Kind.READ, ch.uuid, status, ch.value ?: ByteArray(0))
        }

        override fun onCharacteristicRead(g: BluetoothGatt, ch: BluetoothGattCharacteristic, value: ByteArray, status: Int) {
            complete(Kind.READ, ch.uuid, status, value)
        }

        override fun onCharacteristicWrite(g: BluetoothGatt, ch: BluetoothGattCharacteristic, status: Int) {
            complete(Kind.WRITE, ch.uuid, status, null)
        }

        override fun onDescriptorWrite(g: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            complete(Kind.DESCRIPTOR_WRITE, descriptor.characteristic.uuid, status, null)
        }

        override fun onReadRemoteRssi(g: BluetoothGatt, rssi: Int, status: Int) {
            complete(Kind.RSSI, null, status, rssi)
        }

        override fun onMtuChanged(g: BluetoothGatt, mtu: Int, status: Int) {
            if (status == BluetoothGatt.GATT_SUCCESS) this@GattConnection.mtu = mtu
            complete(Kind.MTU, null, status, mtu)
        }

        @Deprecated("Deprecated in Java")
        override fun onCharacteristicChanged(g: BluetoothGatt, ch: BluetoothGattCharacteristic) {
            // Android 13+ gọi overload có value; overload cũ chỉ chạy trên Android 12 trở xuống.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) return
            @Suppress("DEPRECATION")
            dispatch(ch.uuid, ch.value?.copyOf() ?: return)
        }

        override fun onCharacteristicChanged(g: BluetoothGatt, ch: BluetoothGattCharacteristic, value: ByteArray) {
            dispatch(ch.uuid, value)
        }
    }

    private fun dispatch(uuid: UUID, value: ByteArray) {
        SmartWearLog.v { "<- $uuid ${value.toHex()}" }
        try {
            onNotification?.invoke(GattNotification(uuid, value))
        } catch (e: Exception) {
            SmartWearLog.e("Lỗi khi xử lý notify", e)
        }
    }

    companion object {
        val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }
}
