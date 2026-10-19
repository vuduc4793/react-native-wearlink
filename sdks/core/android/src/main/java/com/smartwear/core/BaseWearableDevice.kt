package com.smartwear.core

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.onCompletion
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.flow.onStart
import java.util.ArrayDeque

/**
 * Phần dùng chung cho driver: giữ state, thống kê kênh, log gói tin và kết quả đo gần nhất.
 * Driver con chỉ cần gọi [onPacketReceived]/[onPacketSent]/[onLatency]/[onError] và cài [measureImpl].
 */
abstract class BaseWearableDevice(
    final override val id: String,
    final override val name: String,
    final override val driver: DeviceDriver,
) : WearableDevice {

    private val _state = MutableStateFlow(ConnectionState.DISCONNECTED)

    /**
     * CONNECTED chỉ sau khi driver bắt tay xong ([markReady]); trong lúc bắt tay vẫn là CONNECTING,
     * dù kết nối GATT đã mở.
     */
    final override val state: StateFlow<ConnectionState> = _state.asStateFlow()

    protected val _info = MutableStateFlow<DeviceInfo?>(null)
    protected val _battery = MutableStateFlow<Int?>(null)
    /** Driver biết trạng thái sạc thì đặt; mặc định null (không biết). */
    protected val _charging = MutableStateFlow<Boolean?>(null)
    protected val _capabilities = MutableStateFlow<Set<Capability>>(emptySet())
    protected val _measurable = MutableStateFlow<Set<Capability>>(emptySet())
    private val _latest = MutableStateFlow<Map<Capability, Reading>>(emptyMap())
    private val _measuring = MutableStateFlow<Capability?>(null)
    private val _stats = MutableStateFlow(LinkStats())
    private val _log = MutableStateFlow<List<PacketLogEntry>>(emptyList())
    protected val _lastError = MutableStateFlow<String?>(null)
    protected val _pairingPrompt = MutableStateFlow<PairingPrompt?>(null)
    override val pairingPrompt: StateFlow<PairingPrompt?> = _pairingPrompt.asStateFlow()
    override fun submitPairingCode(code: String) {}

    private val _history = MutableStateFlow<DeviceHistory?>(null)
    private val _syncProgress = MutableStateFlow<SyncProgress?>(null)

    override val info: StateFlow<DeviceInfo?> = _info.asStateFlow()
    override val battery: StateFlow<Int?> = _battery.asStateFlow()
    override val charging: StateFlow<Boolean?> = _charging.asStateFlow()
    override val capabilities: StateFlow<Set<Capability>> = _capabilities.asStateFlow()
    override val measurable: StateFlow<Set<Capability>> = _measurable.asStateFlow()
    override val latest: StateFlow<Map<Capability, Reading>> = _latest.asStateFlow()
    override val measuring: StateFlow<Capability?> = _measuring.asStateFlow()
    override val stats: StateFlow<LinkStats> = _stats.asStateFlow()
    override val log: StateFlow<List<PacketLogEntry>> = _log.asStateFlow()
    override val lastError: StateFlow<String?> = _lastError.asStateFlow()
    override val history: StateFlow<DeviceHistory?> = _history.asStateFlow()
    override val syncProgress: StateFlow<SyncProgress?> = _syncProgress.asStateFlow()
    override val supportsHistory: Boolean get() = false

    private val packetTimes = ArrayDeque<Long>()
    private val lock = Any()

    protected abstract fun measureImpl(capability: Capability): Flow<Reading>

    /** Driver có lịch sử thì override cùng [supportsHistory]. */
    protected open suspend fun syncHistoryImpl(days: Int, progress: (SyncProgress) -> Unit): DeviceHistory =
        DeviceHistory(errors = listOf("Thiết bị này không lưu dữ liệu lịch sử"))

    final override suspend fun syncHistory(days: Int): DeviceHistory {
        check(_syncProgress.value == null) { "Đang đồng bộ" }
        _syncProgress.value = SyncProgress("Bắt đầu", 0, 1)
        try {
            val result = syncHistoryImpl(days) { _syncProgress.value = it }
            _history.value = result
            result.errors.forEach { onError(it) }
            return result
        } finally {
            _syncProgress.value = null
        }
    }

    /** Driver gọi khi kết nối GATT thay đổi trạng thái. */
    protected fun onTransportState(transport: ConnectionState) {
        _state.value = when (transport) {
            ConnectionState.CONNECTED -> if (_state.value == ConnectionState.CONNECTED) ConnectionState.CONNECTED else ConnectionState.CONNECTING
            else -> transport
        }
    }

    /** Driver gọi khi đã bắt tay xong và thiết bị sẵn sàng nhận lệnh. */
    protected fun markReady() {
        _state.value = ConnectionState.CONNECTED
    }

    final override fun measure(capability: Capability): Flow<Reading> {
        var before: Reading? = null
        return measureImpl(capability)
            .onStart {
                _measuring.value = capability
                before = _latest.value[capability]
            }
            .onEach { reading ->
                // Giữ giá trị OK gần nhất; trạng thái khác chỉ ghi đè nếu chưa có giá trị OK
                // (hoặc mang ghi chú cho người dùng, ví dụ cách lấy kết quả nhanh hơn).
                val previous = _latest.value[capability]
                if (reading.status == ReadingStatus.OK || previous?.status != ReadingStatus.OK ||
                    reading.status == ReadingStatus.NOT_WORN || reading.note != null
                ) {
                    _latest.value = _latest.value + (capability to reading)
                }
                if (reading.status == ReadingStatus.ERROR) onError("Đo ${capability.name} lỗi (mã ${reading.errorCode})")
            }
            .onCompletion {
                if (_measuring.value == capability) _measuring.value = null
                // Dừng / hết giờ khi chưa có kết quả mới: quay về giá trị trước khi đo (như iOS).
                val prior = before
                if (_latest.value[capability]?.status == ReadingStatus.MEASURING && prior != null) {
                    _latest.value = _latest.value + (capability to prior)
                }
            }
    }

    /** Driver gọi khi thiết bị tự đẩy một giá trị đo (không qua [measure]). */
    protected fun publish(reading: Reading) {
        _latest.value = _latest.value + (reading.capability to reading)
    }

    protected fun onPacketReceived(bytes: ByteArray, note: String? = null) {
        val now = System.currentTimeMillis()
        synchronized(lock) {
            packetTimes.addLast(now)
            while (packetTimes.isNotEmpty() && now - packetTimes.first() > HISTORY_MS) packetTimes.removeFirst()
            val recent = packetTimes.count { now - it <= WINDOW_MS }
            val history = (HISTORY_SECONDS - 1 downTo 0).map { ago ->
                packetTimes.count { (now - it) / 1000 == ago.toLong() }
            }
            _stats.value = _stats.value.copy(
                packetsReceived = _stats.value.packetsReceived + 1,
                packetsPerSecond = recent * 1000.0 / WINDOW_MS,
                history = history,
            )
        }
        appendLog(PacketLogEntry(now, outgoing = false, hex = bytes.toHex(), note = note))
    }

    protected fun onPacketSent(bytes: ByteArray, note: String? = null) {
        appendLog(PacketLogEntry(System.currentTimeMillis(), outgoing = true, hex = bytes.toHex(), note = note))
    }

    protected fun onLatency(ms: Long) {
        _stats.value = _stats.value.copy(lastLatencyMs = ms)
    }

    protected fun onRssi(rssi: Int) {
        _stats.value = _stats.value.copy(rssi = rssi)
    }

    protected fun onError(message: String) {
        _stats.value = _stats.value.copy(errors = _stats.value.errors + 1)
        _lastError.value = message
        SmartWearLog.w("[$name] $message")
    }

    /** Cập nhật số gói/giây khi không có gói mới (để biểu đồ trôi về 0). Gọi định kỳ. */
    fun tickStats() {
        val now = System.currentTimeMillis()
        synchronized(lock) {
            while (packetTimes.isNotEmpty() && now - packetTimes.first() > HISTORY_MS) packetTimes.removeFirst()
            _stats.value = _stats.value.copy(
                packetsPerSecond = packetTimes.count { now - it <= WINDOW_MS } * 1000.0 / WINDOW_MS,
                history = (HISTORY_SECONDS - 1 downTo 0).map { ago -> packetTimes.count { (now - it) / 1000 == ago.toLong() } },
            )
        }
    }

    private fun appendLog(entry: PacketLogEntry) {
        val current = _log.value
        _log.value = if (current.size >= LOG_SIZE) current.drop(current.size - LOG_SIZE + 1) + entry else current + entry
    }

    companion object {
        private const val WINDOW_MS = 5_000L
        private const val HISTORY_SECONDS = 20
        private const val HISTORY_MS = HISTORY_SECONDS * 1_000L
        private const val LOG_SIZE = 200
    }
}
