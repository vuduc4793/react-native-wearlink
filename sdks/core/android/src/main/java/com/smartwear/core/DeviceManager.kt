package com.smartwear.core

import android.content.Context
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.mapNotNull
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/** Một thiết bị thấy khi quét, đã được driver nhận diện. */
data class ScanEntry(
    val scanned: ScannedDevice,
    val driver: DeviceDriver,
    val match: DriverMatch,
    /** Lúc nhận gói quảng bá này (ms), để biết tín hiệu còn mới (popup "thiết bị ở gần"). */
    val seenAt: Long = System.currentTimeMillis(),
)

/** Danh sách driver theo thứ tự ưu tiên: driver cụ thể trước, driver chung (standard) sau cùng. */
class DeviceRegistry(val drivers: List<DeviceDriver>) {
    fun classify(device: ScannedDevice): ScanEntry? {
        for (driver in drivers) {
            val match = driver.match(device) ?: continue
            return ScanEntry(device, driver, match)
        }
        return null
    }
}

/**
 * Quản lý nhiều thiết bị, nhiều loại, cùng lúc: quét + phân loại, kết nối song song,
 * đo đồng loạt. Mỗi thiết bị có hàng đợi GATT riêng nên các thiết bị chạy song song.
 */
class DeviceManager(context: Context, val registry: DeviceRegistry) {

    private val context = context.applicationContext
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val scanner = BleScanner(this.context)

    private val _devices = MutableStateFlow<List<WearableDevice>>(emptyList())
    val devices: StateFlow<List<WearableDevice>> = _devices.asStateFlow()

    private val _scanResults = MutableStateFlow<List<ScanEntry>>(emptyList())
    val scanResults: StateFlow<List<ScanEntry>> = _scanResults.asStateFlow()

    private val _scanning = MutableStateFlow(false)
    val scanning: StateFlow<Boolean> = _scanning.asStateFlow()

    private val _scanError = MutableStateFlow<String?>(null)
    val scanError: StateFlow<String?> = _scanError.asStateFlow()

    private var scanJob: Job? = null

    /** Giới hạn mềm: Android thường chỉ cho khoảng 7 kết nối GATT đồng thời. */
    val maxConnections = 7

    /**
     * Thiết bị người dùng muốn giữ kết nối. Mất kết nối ngoài ý muốn thì tự nối lại;
     * ngắt bằng tay thì bỏ khỏi tập này. Lưu qua các lần mở app.
     */
    private val wanted = mutableSetOf<String>()
    private val connectLoops = mutableMapOf<String, Job>()
    private val modelOf = mutableMapOf<String, String>()
    private val prefs = this.context.getSharedPreferences("smartwear_devices", Context.MODE_PRIVATE)

    private val _keepConnected = MutableStateFlow(0)

    /** Số thiết bị đang được giữ kết nối (để app bật/tắt foreground service). */
    val keepConnected: StateFlow<Int> = _keepConnected.asStateFlow()

    init {
        restoreSavedDevices()
        // Cập nhật thống kê và RSSI định kỳ cho mọi thiết bị đang kết nối.
        scope.launch {
            var tick = 0
            while (true) {
                delay(1_000)
                tick++
                for (d in _devices.value) {
                    (d as? BaseWearableDevice)?.tickStats()
                    if (tick % 3 == 0 && d.state.value == ConnectionState.CONNECTED && d.measuring.value == null && !BleQuiet.active) {
                        launch { runCatching { d.refreshRssi() } }
                    }
                }
            }
        }
    }

    fun startScan(durationMs: Long = 12_000) {
        scanJob?.cancel()
        _scanResults.value = emptyList()
        _scanError.value = null
        scanJob = scope.launch {
            _scanning.value = true
            try {
                // Chỗ đông người có hàng chục thiết bị phát vài chục gói/giây: phân loại trên luồng nền, mỗi thiết bị cập nhật
                // danh sách tối đa ~2 lần/giây. Trước đây làm hết trên Main ⇒ Redmi Note 7 Pro 2–5 s/khung, popup 3D không vẽ.
                val lastEmit = HashMap<String, Long>()
                val lastIgnoredLog = HashMap<String, Long>()
                // Android hạ lượt quét không lọc chạy quá 30 phút xuống gần như không nhận gói (dumpsys: "Forced" sau ~1 890 s,
                // đo 19/10/2026) ⇒ quét dài thì tự mở lượt mới mỗi SCAN_RESTART_MS.
                withTimeoutOrNull(durationMs) {
                    while (true) {
                        withTimeoutOrNull(SCAN_RESTART_MS) {
                            scanner.scan().mapNotNull { scanned ->
                                val entry = registry.classify(scanned)
                                if (entry == null) {
                                    val now = System.currentTimeMillis()
                                    if (SmartWearLog.verbose && now - (lastIgnoredLog[scanned.address] ?: 0) >= IGNORED_LOG_MS) {
                                        lastIgnoredLog[scanned.address] = now
                                        SmartWearLog.v { "Bỏ qua ${scanned.address} ${scanned.name} rssi=${scanned.rssi} uuids=${scanned.serviceUuids} manu=${scanned.manufacturerData.mapValues { it.value.toHex() }}" }
                                    }
                                    return@mapNotNull null
                                }
                                val last = lastEmit[scanned.address]
                                if (last != null && entry.seenAt - last < SCAN_UPDATE_MS) return@mapNotNull null
                                lastEmit[scanned.address] = entry.seenAt
                                entry
                            }.flowOn(Dispatchers.Default).collect { entry ->
                                val scanned = entry.scanned
                                val list = _scanResults.value
                                val index = list.indexOfFirst { it.scanned.address == scanned.address }
                                if (index < 0) SmartWearLog.d("Quét thấy ${entry.match.model} ${scanned.address} (${entry.driver.id}, ${scanned.rssi} dBm)")
                                _scanResults.value = if (index >= 0) list.toMutableList().also { it[index] = entry } else list + entry
                            }
                        }
                    }
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                _scanError.value = e.message
            } finally {
                // Lượt quét cũ bị huỷ có thể kết thúc sau khi lượt mới đã chạy (flowOn): không tắt cờ của lượt mới.
                if (scanJob === coroutineContext[Job]) _scanning.value = false
            }
        }
    }

    fun stopScan() {
        scanJob?.cancel()
        _scanning.value = false
    }

    fun find(id: String): WearableDevice? = _devices.value.firstOrNull { it.id.equals(id, ignoreCase = true) }

    /** Thiết bị đang được giữ kết nối (app tự nối lại). */
    fun isKept(id: String): Boolean = wanted.any { it.equals(id, ignoreCase = true) }

    /** Thêm (nếu chưa có) và kết nối song song các thiết bị đã chọn. */
    fun connect(entries: List<ScanEntry>) {
        stopScan()
        for (entry in entries) {
            val device = find(entry.scanned.address) ?: add(entry.driver, entry.scanned, entry.match.model)
            connect(device)
        }
    }

    /** Giữ kết nối với thiết bị: kết nối ngay, và tự nối lại khi mất kết nối. */
    fun connect(device: WearableDevice) {
        if (device.id !in wanted) {
            val connected = _devices.value.count { it.id in wanted }
            if (connected >= maxConnections) {
                SmartWearLog.w("Đã đạt giới hạn $maxConnections kết nối, bỏ qua ${device.name}")
                return
            }
            wanted += device.id
            saveDevices()
        }
        startConnectLoop(device, initialDelayMs = 0)
    }

    /**
     * Bật/tắt giữ kết nối (như `setKeepConnected` iOS). Bật: kết nối ngay và tự nối lại. Tắt: vẫn giữ kết nối hiện tại
     * nhưng mất thì không nối lại.
     */
    fun setKeepConnected(device: WearableDevice, keep: Boolean) {
        if (keep) return connect(device)
        wanted -= device.id
        connectLoops.remove(device.id)?.cancel()
        saveDevices()
    }

    /** Lấy (hoặc dựng) thiết bị quản lý cho một kết quả quét, chưa kết nối. */
    fun addFromScan(entry: ScanEntry): WearableDevice = find(entry.scanned.address) ?: add(entry.driver, entry.scanned, entry.match.model)

    /** Ngắt theo ý người dùng: không tự nối lại. */
    fun disconnect(device: WearableDevice) {
        wanted -= device.id
        connectLoops.remove(device.id)?.cancel()
        saveDevices()
        device.disconnect()
    }

    /** Quên thiết bị: ngắt và xoá khỏi danh sách đã lưu. */
    fun remove(device: WearableDevice) {
        disconnect(device)
        _devices.value = _devices.value - device
        saveDevices()
    }

    private fun add(driver: DeviceDriver, scanned: ScannedDevice, model: String): WearableDevice {
        val device = driver.create(context, scanned, DriverMatch(model))
        _devices.value = _devices.value + device
        modelOf[device.id] = model
        // Mất kết nối ngoài ý muốn → tự nối lại nếu người dùng vẫn muốn giữ kết nối.
        scope.launch {
            var wasConnected = false
            device.state.collect { state ->
                if (state == ConnectionState.CONNECTED) wasConnected = true
                if (state == ConnectionState.DISCONNECTED && wasConnected && device.id in wanted) {
                    wasConnected = false
                    SmartWearLog.i("${device.name} mất kết nối, sẽ tự nối lại")
                    startConnectLoop(device, initialDelayMs = 2_000, background = true)
                }
            }
        }
        saveDevices()
        return device
    }

    /**
     * Thử kết nối cho đến khi được hoặc người dùng không muốn nữa. Lỗi GATT 133/147 hay gặp và
     * thường hết khi thử lại (app QRing gốc thử lại sau 2 s); sau đó lùi dần tới 60 s.
     *
     * [background] = true (nối lại thiết bị đang giữ): dùng [WearableDevice.reconnect] (autoConnect, chờ thiết bị
     * quảng bá không giới hạn). Lần nối do người dùng bấm dùng [WearableDevice.connect] (nhanh, có timeout);
     * nếu lần đầu lỗi thì các lần sau cũng chuyển sang nối nền.
     */
    private fun startConnectLoop(device: WearableDevice, initialDelayMs: Long, background: Boolean = false) {
        if (connectLoops[device.id]?.isActive == true) return
        connectLoops[device.id] = scope.launch {
            delay(initialDelayMs)
            var attempt = 0
            while (device.id in wanted && device.state.value == ConnectionState.DISCONNECTED) {
                BleQuiet.awaitIdle()
                if (device.id !in wanted || device.state.value != ConnectionState.DISCONNECTED) break
                val result = runCatching { if (background || attempt > 0) device.reconnect() else device.connect() }
                if (result.isSuccess) break
                SmartWearLog.w("Kết nối ${device.name} lỗi (lần ${attempt + 1}): ${result.exceptionOrNull()?.message}")
                delay(BACKOFF_MS[attempt.coerceAtMost(BACKOFF_MS.lastIndex)])
                attempt++
            }
            connectLoops.remove(device.id)
        }
    }

    // ---------- Lưu danh sách thiết bị ----------

    private fun saveDevices() {
        val lines = _devices.value.joinToString("\n") { d ->
            listOf(d.driver.id, d.id, d.name, modelOf[d.id] ?: d.name, if (d.id in wanted) "1" else "0").joinToString("\t")
        }
        prefs.edit().putString(KEY_DEVICES, lines).apply()
        _keepConnected.value = wanted.size
    }

    /** Dựng lại thiết bị đã lưu (không cần quét: Android kết nối thẳng bằng MAC) và nối lại những cái đang giữ. */
    @android.annotation.SuppressLint("MissingPermission")
    private fun restoreSavedDevices() {
        val adapter = context.getSystemService(android.bluetooth.BluetoothManager::class.java)?.adapter ?: return
        val lines = prefs.getString(KEY_DEVICES, null)?.lines()?.filter { it.isNotBlank() } ?: return
        for (line in lines) {
            val parts = line.split('\t')
            if (parts.size < 5) continue
            val (driverId, address, name, model, keep) = parts
            val driver = registry.drivers.firstOrNull { it.id == driverId } ?: continue
            val remote = runCatching { adapter.getRemoteDevice(address) }.getOrNull() ?: continue
            val scanned = ScannedDevice(remote, address, name, rssi = 0, serviceUuids = emptyList(), manufacturerData = emptyMap())
            // Đánh dấu trước khi add(): add() ghi lại file, nếu chưa đánh dấu sẽ ghi đè cờ "giữ kết nối" thành 0.
            if (keep == "1") wanted += address
            add(driver, scanned, model)
        }
        saveDevices()
        if (BlePermissions.granted(context)) reconnectSaved()
    }

    /** Nối lại mọi thiết bị đang giữ kết nối (gọi sau khi có quyền Bluetooth). */
    fun reconnectSaved() {
        _devices.value.filter { it.id in wanted }.forEach { startConnectLoop(it, initialDelayMs = 0, background = true) }
    }

    /** Đo một capability trên mọi thiết bị đang kết nối có hỗ trợ. Trả về số thiết bị được đo. */
    fun measureAll(capability: Capability): Int {
        val targets = _devices.value.filter {
            it.state.value == ConnectionState.CONNECTED && capability in it.measurable.value && it.measuring.value == null
        }
        targets.forEach { measure(it, capability) }
        return targets.size
    }

    private val measureJobs = mutableMapOf<String, Job>()

    fun measure(device: WearableDevice, capability: Capability) {
        measureJobs[device.id]?.cancel()
        measureJobs[device.id] = scope.launch {
            // Rộng hơn chu kỳ đo HR 24h 5 phút (GloryFit chờ F7 03 tối đa 6 phút); driver tự có watchdog riêng.
            runCatching { withTimeoutOrNull(400_000) { device.measure(capability).collect {} } }
                .onFailure { SmartWearLog.w("Đo ${device.name} lỗi: ${it.message}") }
        }
    }

    /** Đồng bộ lịch sử một thiết bị (chạy nền, kết quả ở [WearableDevice.history]). */
    fun syncHistory(device: WearableDevice, days: Int = 7) {
        if (device.syncProgress.value != null) return
        scope.launch {
            runCatching { device.syncHistory(days) }
                .onFailure { SmartWearLog.w("Đồng bộ ${device.name} lỗi: ${it.message}") }
        }
    }

    fun stopMeasure(device: WearableDevice) {
        measureJobs.remove(device.id)?.cancel()
    }

    fun stopAllMeasurements() {
        measureJobs.values.forEach { it.cancel() }
        measureJobs.clear()
    }

    fun close() {
        _devices.value.forEach { it.disconnect() }
        scope.cancel()
    }

    private companion object {
        const val KEY_DEVICES = "devices"
        val BACKOFF_MS = longArrayOf(2_000, 5_000, 10_000, 30_000, 60_000)
        /** Khoảng tối thiểu giữa hai lần cập nhật một thiết bị trong [scanResults]. */
        const val SCAN_UPDATE_MS = 500L
        const val SCAN_RESTART_MS = 25 * 60_000L
        /** Mỗi thiết bị không hỗ trợ chỉ ghi log "Bỏ qua" một lần trong khoảng này. */
        const val IGNORED_LOG_MS = 10_000L
    }
}
