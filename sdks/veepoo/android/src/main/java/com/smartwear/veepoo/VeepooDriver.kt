package com.smartwear.veepoo

import android.content.Context
import com.smartwear.core.Alarm
import com.smartwear.core.AlarmClock
import com.smartwear.core.ConfigurableDevice
import com.smartwear.core.Contact
import com.smartwear.core.ContactsSync
import com.smartwear.core.ControlValue
import com.smartwear.core.CallDisplay
import com.smartwear.core.DeviceControl
import com.smartwear.core.DeviceEvent
import com.smartwear.core.DeviceEvents
import com.smartwear.core.FirmwareUpdatable
import com.smartwear.core.MusicCommand
import com.smartwear.core.MusicRemote
import com.smartwear.core.MusicState
import com.smartwear.core.NotificationApp
import com.smartwear.core.NotificationDisplay
import com.smartwear.core.RemoteCameraDevice
import com.smartwear.core.RemoteCameraEvent
import com.smartwear.core.WatchFaceInfo
import com.smartwear.core.WatchFaceManager
import com.smartwear.core.WeatherDisplay
import com.smartwear.core.WeatherForecast
import com.smartwear.core.WorkoutEvent
import com.smartwear.core.WorkoutRemote
import com.smartwear.core.WorkoutState
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.mapNotNull
import com.smartwear.core.ActivityTotals
import com.smartwear.core.BaseWearableDevice
import com.smartwear.core.DeviceHistory
import com.smartwear.core.SleepSession
import com.smartwear.core.SyncProgress
import com.smartwear.core.Workout
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
import com.smartwear.core.SmartWearLog
import com.smartwear.core.toHex
import com.smartwear.veepoo.Veepoo.op
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.onCompletion
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import java.time.LocalDate
import java.time.LocalDateTime
import java.time.ZoneId

/**
 * Driver cho thiết bị dùng app G Band / VPG Band (SDK Veepoo), ví dụ vòng tay PALREDIL GE54.
 * Nhận diện bằng manufacturer data company `0xF8F8` (luật `isBeyondVpV2` của G Band), hoặc `F8 F9` / `F9 F9`.
 */
object VeepooDriver : DeviceDriver {
    override val id = "veepoo"
    override val displayName = "Veepoo (G Band)"

    override fun match(device: ScannedDevice): DriverMatch? {
        Veepoo.advert(device) ?: return null
        // G Band bỏ thiết bị tên rỗng / "NULL" (`VBC:1394`, `AddDeviceViewModel.java:191`).
        val name = Veepoo.cleanName(device.name)
        if (name.isEmpty() || name == "NULL") return null
        return DriverMatch(name)
    }

    override fun create(context: Context, device: ScannedDevice, match: DriverMatch) =
        VeepooDevice(context, device, match.model)
}

class VeepooException(message: String) : Exception(message)

class VeepooDevice(
    context: Context,
    scanned: ScannedDevice,
    private val model: String,
) : BaseWearableDevice(scanned.address, Veepoo.cleanName(scanned.name).ifEmpty { model }, VeepooDriver), ConfigurableDevice,
    NotificationDisplay, CallDisplay, MusicRemote, RemoteCameraDevice, ContactsSync, WeatherDisplay, WorkoutRemote, WatchFaceManager,
    FirmwareUpdatable, DeviceEvents, AlarmClock {

    private val appContext = context.applicationContext
    private val gatt = GattConnection(appContext, scanned.device)
    private val prefs = appContext.getSharedPreferences("smartwear_veepoo", Context.MODE_PRIVATE)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val zone = ZoneId.systemDefault()
    private val advert = Veepoo.advert(scanned)

    private val lock = Mutex()
    private class Waiter(val match: (ByteArray) -> Boolean, val channel: Channel<ByteArray>)

    @Volatile
    private var waiter: Waiter? = null
    private val events = MutableSharedFlow<ByteArray>(extraBufferCapacity = 64, onBufferOverflow = BufferOverflow.DROP_OLDEST)
    private var writeWithResponse = true

    /** Bảng tính năng + công tắc thông báo + cài đặt tuỳ chỉnh đọc trong lần kết nối này. */
    @Volatile
    var features = VeepooFeatures(emptyMap())
        private set
    @Volatile
    var messageSwitches = VeepooMessageSwitches(null, null)
        private set
    @Volatile
    var customSettings = VeepooCustomSettings(null, null)
        private set
    @Volatile
    var passwordReply: Veepoo.PasswordReply? = null
        private set

    // Khai báo trước `init` vì bộ thu sự kiện trong `init` dùng tới.
    private val _remoteCamera = MutableSharedFlow<RemoteCameraEvent>(extraBufferCapacity = 8, onBufferOverflow = BufferOverflow.DROP_OLDEST)
    @Volatile
    private var lastShutter = 0L
    @Volatile
    private var lastCameraCommand = 0L
    private val _deviceEvents = MutableSharedFlow<DeviceEvent>(extraBufferCapacity = 8, onBufferOverflow = BufferOverflow.DROP_OLDEST)
    private val _controls = MutableStateFlow<List<DeviceControl>>(emptyList())

    init {
        _info.value = DeviceInfo(model = model, extra = baseInfo())
        gatt.onNotification = ::onNotification
        gatt.onDisconnected = { status -> onError("Mất kết nối (status=$status)") }
        scope.launch { gatt.state.collect(::onTransportState) }
        // Chụp ảnh từ xa `B6 01 mode`; SOS `B7`: SDK gốc tự trả `B7 04 01` (`VOM:2303-2309`).
        scope.launch {
            events.collect { p ->
                VeepooPhone.parseCamera(p)?.let { ev ->
                    // GE54 trả lời chính lệnh `B6 01`/`B6 00` của app bằng `B6 01 01 01` + `B6 01 01 00` (hoặc `B6 01 00 …`): không phát lại
                    // thành sự kiện mở/đóng, kẻo app mở camera rồi gửi `B6 01` lần nữa (đo 19/10/2026).
                    if (ev != RemoteCameraEvent.SHUTTER && System.currentTimeMillis() - lastCameraCommand < CAMERA_ECHO_MS) return@let
                    if (ev == RemoteCameraEvent.SHUTTER) {
                        val now = System.currentTimeMillis()
                        if (now - lastShutter < SHUTTER_GAP_MS) return@let
                        lastShutter = now
                    }
                    _remoteCamera.tryEmit(ev)
                }
                if (VeepooPhone.isSos(p)) {
                    _deviceEvents.tryEmit(DeviceEvent.SOS_BUTTON)
                    runCatching { writeCommand(Veepoo.bytes(0xB7, 0x04, 0x01)) }
                }
                // Vòng tay tự đẩy `A0 …` khi cắm / rút sạc (đo 19/10/2026): cập nhật pin + trạng thái sạc.
                if (p.op == 0xA0) Veepoo.parseBattery(p)?.let { b -> _battery.value = b.percent; _charging.value = b.charging }
                // Thiết bị tự đẩy B8 (vd sau khi app khác đổi cài đặt): cập nhật bản sao.
                if (p.op == 0xB8 && p.size >= 20 && Veepoo.u(p, 1) == 2) {
                    customSettings = if (Veepoo.u(p, 19) == 0) VeepooCustomSettings(p, customSettings.page1) else VeepooCustomSettings(customSettings.page0, p)
                    rebuildControls()
                }
            }
        }
    }

    private fun baseInfo(): Map<String, String> = linkedMapOf(
        "Driver" to "Veepoo / G Band (sdks/veepoo)",
        "Địa chỉ" to id,
    ).apply {
        advert?.let { a ->
            a.deviceNumber?.let { put("Device number (quảng bá)", it.toString()) }
            a.firmware?.let { put("Firmware (quảng bá)", it) }
        }
    }

    // ---------- Kết nối + bắt tay ----------

    override suspend fun connect() = openLink(autoConnect = false)

    /** Nối lại nền: `autoConnect = true`, chờ vòng tay quảng bá không giới hạn. Huỷ bằng [disconnect]. */
    override suspend fun reconnect() = openLink(autoConnect = true)

    private suspend fun openLink(autoConnect: Boolean) {
        _lastError.value = null
        try {
            val started = System.currentTimeMillis()
            gatt.connect(autoConnect = autoConnect)
            if (!autoConnect) onLatency(System.currentTimeMillis() - started)
            if (!gatt.hasService(Veepoo.SERVICE)) throw VeepooException("Không có service F0080001: không phải thiết bị Veepoo")
            // Như `VOM:843`: xin MTU 248 ngay, bật notify sau 500 ms.
            runCatching { gatt.requestMtu(Veepoo.MTU) }.onFailure { SmartWearLog.w("[$name] MTU: ${it.message}") }
            delay(500)
            gatt.enableNotifications(Veepoo.SERVICE, Veepoo.NOTIFY)
            writeWithResponse = gatt.supportsWriteWithResponse(Veepoo.SERVICE, Veepoo.WRITE)
            SmartWearLog.i("[$name] GATT: MTU ${gatt.mtu}, ghi ${if (writeWithResponse) "có" else "không"} phản hồi, " +
                "JieLi AE00=${gatt.hasService(Veepoo.JIELI_SERVICE)}, ZK F003=${gatt.hasService(Veepoo.ZK_SERVICE)}, UI F0030001=${gatt.hasService(Veepoo.UI_SERVICE)}")

            handshake()
            applyFeatures()
            refreshBattery()
            refreshRssi()
            rebuildControls()
            markReady()
            scope.launch { runCatching { readDeviceState() }.onFailure { SmartWearLog.w("[$name] đọc cài đặt: ${it.message}") } }
        } catch (e: Exception) {
            if (e !is kotlinx.coroutines.CancellationException) onError("Kết nối lỗi: ${e.message}")
            gatt.disconnect()
            throw e
        }
    }

    /**
     * `A1` mật khẩu + giờ (§4.2), rồi gom các gói thiết bị tự đẩy: `A7` ×5 (bảng tính năng), `AD` (thông báo), `B8` (cài đặt).
     * Dừng khi đã có `A1` + đủ 5 trang `A7` và im lặng [HANDSHAKE_QUIET_MS], tối đa [HANDSHAKE_MS]. Thiếu `AD`/`B8` thì đọc bằng lệnh.
     */
    private suspend fun handshake() {
        val password = prefs.getString("password_$id", null) ?: Veepoo.DEFAULT_PASSWORD
        val packets = mutableListOf<ByteArray>()
        lock.withLock {
            val channel = Channel<ByteArray>(Channel.UNLIMITED)
            waiter = Waiter({ it.op in HANDSHAKE_OPS }, channel)
            try {
                writeCommand(Veepoo.passwordCheck(password, LocalDateTime.now(), is24h = hour24Preference(), zone = zone))
                val started = System.currentTimeMillis()
                withTimeoutOrNull(HANDSHAKE_MS) {
                    while (true) {
                        val p = withTimeoutOrNull(HANDSHAKE_QUIET_MS) { channel.receive() }
                        if (p == null) {
                            val pages = packets.filter { it.op == 0xA7 && it.size >= 20 }.map { Veepoo.u(it, 19) }.toSet()
                            if (packets.any { it.op == 0xA1 } && pages.containsAll(listOf(1, 2, 3, 4, 5))) break
                            if (packets.any { it.op == 0xA1 } && System.currentTimeMillis() - started > A7_WAIT_MS) break
                            if (packets.none { it.op == 0xA1 } && System.currentTimeMillis() - started > PASSWORD_TIMEOUT_MS) break
                            continue
                        }
                        packets += p
                        if (p.op == 0xA1) onLatency(System.currentTimeMillis() - started)
                    }
                }
            } finally {
                waiter = null
            }
        }
        for (p in packets) SmartWearLog.i("[$name] bắt tay ← ${p.toHex()}")
        val reply = packets.firstOrNull { it.op == 0xA1 }?.let(Veepoo::parsePasswordReply)
            ?: throw VeepooException("Vòng tay không trả lời A1 (mật khẩu)")
        if (!Veepoo.passwordAccepted(reply)) {
            runCatching { writeCommand(Veepoo.DISCONNECT) }
            throw VeepooException("Sai mật khẩu (A1 trạng thái ${reply.status})")
        }
        passwordReply = reply
        features = VeepooFeatures(packets.filter { it.op == 0xA7 && it.size >= 20 }.associateBy { Veepoo.u(it, 19) })
        var ad = packets.filter { it.op == 0xAD && it.size >= 20 }
        var b8 = packets.filter { it.op == 0xB8 && it.size >= 20 }
        if (ad.isEmpty()) ad = collectPackets(Veepoo.bytes(0xAD, 0x02), { it.op == 0xAD && it.size >= 20 }, idleMs = 1_000)
        if (b8.isEmpty()) b8 = collectPackets(VeepooCustomSettings.READ, { it.op == 0xB8 && it.size >= 20 }, idleMs = 1_000)
        messageSwitches = VeepooMessageSwitches(
            ad.lastOrNull { (Veepoo.u(it, 19) shr 4) == 0 },
            ad.lastOrNull { (Veepoo.u(it, 19) shr 4) == 1 },
        )
        customSettings = VeepooCustomSettings(b8.lastOrNull { Veepoo.u(it, 19) == 0 }, b8.lastOrNull { Veepoo.u(it, 19) == 1 })
        SmartWearLog.i("[$name] A1: ${reply.status}, device number ${reply.deviceNumber}, firmware ${reply.testVersion}, MAC ${reply.mac}")
        SmartWearLog.i("[$name] ${features.describe()}")
        SmartWearLog.i("[$name] $messageSwitches; $customSettings")
    }

    /** 24h theo cài đặt điện thoại (G Band gửi false trong `A1` rồi sửa bằng `B8`; ở đây gửi đúng ngay). */
    private fun hour24Preference(): Boolean = android.text.format.DateFormat.is24HourFormat(appContext)

    private fun applyFeatures() {
        val f = features
        val caps = f.capabilities()
        _capabilities.value = caps
        _measurable.value = (caps intersect MEASURABLE).filter { it != Capability.MET || f.metLive }.toSet()
        val r = passwordReply
        _info.value = DeviceInfo(
            model = model,
            hardware = r?.deviceNumber?.let { "Veepoo #$it" },
            firmware = r?.testVersion,
            extra = LinkedHashMap(baseInfo()).apply {
                if (r != null) {
                    put("Device number (A1)", r.deviceNumber.toString())
                    put("MAC (A1)", r.mac)
                }
                put("Chip", f.cpuName)
                put("Lịch sử 5 phút", if (f.usesDf) "DF (origin ${f.originProtocolVersion})" else "D1 (origin ${f.originProtocolVersion})")
                put("Ngủ", if (!f.sleep) "không có" else if (f.preciseSleep) "chính xác (sleepTag ${f.sleepTag})" else "thường")
                put("Số ngày lịch sử", f.watchDays.toString())
                put("Mặt đồng hồ", "server ${f.watchUiServerCount}, tuỳ chỉnh ${f.watchUiCustomCount}, kiểu dựng sẵn ${f.screenStyleCount}, bigData ${f.bigDataTranType}")
                put("MTU", gatt.mtu.toString())
                for (page in 1..5) put("A7 gói $page", f.pages[page]?.toHex() ?: "không có")
                put("AD", messageSwitches.toString())
                put("B8", customSettings.toString())
            },
        )
    }

    override fun disconnect() {
        // Như `VOM:2568-2572`: báo `AF 00` rồi mới đóng GATT.
        if (state.value == ConnectionState.CONNECTED) {
            scope.launch {
                runCatching { withTimeout(1_000) { writeCommand(Veepoo.DISCONNECT) } }
                delay(300)
                gatt.disconnect()
            }
        } else {
            gatt.disconnect()
        }
    }

    override suspend fun refreshBattery() {
        runCatching { request(Veepoo.BATTERY) { it.op == 0xA0 && it.size >= 8 } }
            .onSuccess { p ->
                val b = Veepoo.parseBattery(p)
                SmartWearLog.i("[$name] pin ${p.toHex()} → $b")
                if (b != null) {
                    _battery.value = b.percent
                    _charging.value = b.charging
                }
            }
            .onFailure { onError("Đọc pin lỗi: ${it.message}") }
    }

    override suspend fun refreshRssi() {
        runCatching { gatt.readRssi() }.onSuccess(::onRssi)
    }

    // ---------- Đo trực tiếp ----------

    override fun measureImpl(capability: Capability): Flow<Reading> = when (capability) {
        Capability.HEART_RATE -> live(capability, start = Veepoo.padded(20, 0xD0, 0x01), stop = Veepoo.bytes(0xD0, 0x00), op = 0xD0,
            parse = VeepooMeasure.heartRate())
        Capability.SPO2 -> live(capability, start = Veepoo.bytes(0x80, 0x01, 0x02), stop = Veepoo.bytes(0x80, 0x02, 0x02), op = 0x80,
            parse = VeepooMeasure.spo2())
        // Đã bật hiệu chuẩn (chế độ riêng `91`) thì đo kiểu riêng `90 01 01`, như ô "chế độ riêng" của G Band.
        Capability.BLOOD_PRESSURE -> (if (extra.bp?.enabled == true) 1 else 0).let { m ->
            live(capability, start = Veepoo.bytes(0x90, 0x01, m), stop = Veepoo.bytes(0x90, 0x00, m), op = 0x90, parse = VeepooMeasure.bloodPressure())
        }
        Capability.TEMPERATURE -> live(capability, start = Veepoo.padded(20, 0x87, 0x01, 0x01), stop = Veepoo.padded(20, 0x87, 0x01, 0x02), op = 0x87,
            parse = VeepooMeasure.temperature())
        Capability.STRESS -> live(capability, start = Veepoo.padded(20, 0x89, 0x06, 0x01), stop = Veepoo.padded(20, 0x89, 0x06, 0x02), op = 0x89,
            parse = VeepooMeasure.stress())
        // Đường huyết `89 01 01 riêng` (riêng = đã bật hiệu chuẩn) / dừng `89 01 02 riêng` (`mf.a.b0..e0`, gói 4 byte).
        Capability.BLOOD_SUGAR -> (if (extra.glucose?.enabled == true) 1 else 0).let { m ->
            live(capability, start = Veepoo.bytes(0x89, 0x01, 0x01, m), stop = Veepoo.bytes(0x89, 0x01, 0x02, m), op = 0x89, parse = VeepooMeasure.bloodGlucose())
        }
        Capability.MET -> live(capability, start = Veepoo.padded(20, 0x89, 0x08, 0x01), stop = Veepoo.padded(20, 0x89, 0x08, 0x02), op = 0x89,
            parse = VeepooMeasure.met())
        // Acid uric + mỡ máu chung một phép đo `8A 01` (G Band "Quick Measurement" của thành phần máu). Luôn chế độ thường
        // `8A 01 01 00` như mặc định G Band (chế độ riêng là ô người dùng tự chọn): chế độ riêng bám giá trị hiệu chuẩn đang lưu
        // (GE54 19/10: hiệu chuẩn 15/12/10/15 ⇒ đo ra 15,58/12,26/10,03/16,09 mmol/L), chế độ thường ra 4,27/1,02/1,04/2,68.
        Capability.URIC_ACID, Capability.BLOOD_LIPIDS -> live(capability, start = VeepooHealth.bloodComponentStart(calibrated = false),
            stop = VeepooHealth.BLOOD_COMPONENT_STOP, op = 0x8A, parse = VeepooMeasure.bloodComponent(capability),
            first = VeepooMeasure.touching(capability))
        Capability.BODY_COMPOSITION -> live(capability, start = VeepooHealth.BODY_START, stop = VeepooHealth.BODY_STOP, op = 0x93,
            parse = VeepooMeasure.bodyComposition(), first = VeepooMeasure.touching(capability))
        else -> emptyFlow()
    }

    /**
     * Phép đo trực tiếp: gửi [start], nhận gói opcode [op] ([parse] trả Reading + cờ kết thúc), luôn gửi [stop] khi flow kết thúc
     * (kể cả bị huỷ). Không có gói nào trong [MEASURE_IDLE_MS] ⇒ kết thúc. [first] = Reading phát ngay khi bắt đầu (vd nhắc chạm cảm biến).
     */
    private fun live(
        capability: Capability, start: ByteArray, stop: ByteArray, op: Int, parse: (ByteArray) -> Pair<Reading, Boolean>?,
        first: Reading = Reading(capability, ReadingStatus.MEASURING),
    ): Flow<Reading> =
        channelFlow {
            send(first)
            var last = System.currentTimeMillis()
            val listener = launch(start = CoroutineStart.UNDISPATCHED) {
                events.collect { p ->
                    if (p.op != op) return@collect
                    last = System.currentTimeMillis()
                    val (reading, done) = parse(p) ?: return@collect
                    send(reading)
                    if (done) channel.close()
                }
            }
            val watchdog = launch {
                while (true) {
                    delay(1_000)
                    if (System.currentTimeMillis() - last > MEASURE_IDLE_MS) {
                        trySend(Reading(capability, ReadingStatus.ERROR, errorCode = -1, note = "Vòng tay không gửi kết quả"))
                        channel.close()
                    }
                }
            }
            writeCommand(start)
            awaitClose()
            listener.cancel()
            watchdog.cancel()
        }.onCompletion {
            withContext(NonCancellable) { runCatching { if (state.value == ConnectionState.CONNECTED) writeCommand(stop) } }
        }

    // ---------- Cài đặt (VeepooControls) ----------

    override val controls: StateFlow<List<DeviceControl>> = _controls.asStateFlow()

    /** Nhắc sức khoẻ `E7` đọc từ vòng tay (type → giá trị). */
    @Volatile
    private var reminds = emptyMap<Int, VeepooControls.Remind>()
    @Volatile
    private var heartAlarm: VeepooControls.HeartAlarm? = null
    @Volatile
    private var language: Int? = null

    /** Hiệu chuẩn đọc từ vòng tay + hồ sơ lưu cục bộ. */
    @Volatile
    private var extra = VeepooControls.Extra()

    private fun rebuildControls() {
        _controls.value = VeepooControls.controls(features, customSettings, reminds, heartAlarm, language, extra.copy(profile = profile()))
    }

    /** Hồ sơ + mục tiêu (lưu theo MAC; vòng tay không đọc lại được `A3`). */
    private fun profile(): VeepooHealth.Profile {
        val v = prefs.getString("profile_$id", null)?.split(',')?.mapNotNull { it.toIntOrNull() }
        if (v == null || v.size < 6) return VeepooHealth.Profile()
        return VeepooHealth.Profile(v[0], v[1], v[2], v[3] == 1, v[4], v[5])
    }

    private fun saveProfile(p: VeepooHealth.Profile) {
        prefs.edit().putString("profile_$id", listOf(p.heightCm, p.weightKg, p.age, if (p.female) 1 else 0, p.stepGoal, p.sleepMinutes).joinToString(",")).apply()
    }

    /** Gửi hồ sơ + mục tiêu `A3` (G Band gửi mỗi lần kết nối, §4.4); vòng tay trả `A3 01`. */
    private suspend fun sendProfile(): Boolean {
        val p = runCatching { request(VeepooHealth.profile(profile()), timeoutMs = 2_000) { it.op == 0xA3 } }.getOrNull()
        SmartWearLog.i("[$name] A3 ${profile()} → ${p?.toHex() ?: "không có phản hồi"}")
        return p != null && p.size >= 2 && Veepoo.u(p, 1) == 1
    }

    /**
     * Gửi `A3`, rồi đọc (không ghi) `E7` từng loại nhắc, cảnh báo nhịp tim `AC`, hiệu chuẩn HA `91 02`, đường huyết `89 02`/`89 03`,
     * thành phần máu `8A 02`; rồi dựng lại [controls].
     */
    private suspend fun readDeviceState() {
        val f = features
        sendProfile()
        if (f.healthRemind) {
            val r = reminds.toMutableMap()
            for ((type, _) in VeepooControls.REMIND_TYPES) {
                runCatching { request(VeepooControls.remindRead(type)) { it.op == 0xE7 && it.size >= 10 && Veepoo.u(it, 1) == 2 } }
                    .onSuccess { p -> SmartWearLog.i("[$name] E7 02 $type = ${p.toHex()}"); VeepooControls.parseRemind(p)?.let { r[type] = it } }
                    .onFailure { SmartWearLog.w("[$name] E7 02 $type: ${it.message}") }
            }
            reminds = r
        }
        if (f.heartRateAlarm) {
            runCatching { request(VeepooControls.HEART_ALARM_READ) { it.op == 0xAC } }
                .onSuccess { p -> SmartWearLog.i("[$name] AC = ${p.toHex()}"); heartAlarm = VeepooControls.parseHeartAlarm(p) }
                .onFailure { SmartWearLog.w("[$name] AC: ${it.message}") }
        }
        readCalibrations()
        rebuildControls()
    }

    /** Chỉ lệnh đọc. Gói `91` phải đủ 4 byte `91 02 00 00` (gói `91` ngắn hơn bị hiểu là lệnh ghi, xem [VeepooHealth.bpCalibrationWrite]). */
    private suspend fun readCalibrations() {
        val f = features
        var e = extra
        if (f.bloodPressure) runCatching { request(VeepooHealth.BP_CALIBRATION_READ) { it.op == 0x91 && it.size >= 6 } }
            .onSuccess { p -> SmartWearLog.i("[$name] 91 = ${p.toHex()}"); VeepooHealth.parseBpCalibration(p)?.let { e = e.copy(bp = it) } }
            .onFailure { SmartWearLog.w("[$name] 91: ${it.message}") }
        if (f.glucoseCalibrationMulti) runCatching {
            collectPackets(VeepooHealth.GLUCOSE_MULTI_READ, { it.op == 0x89 && it.size >= 6 && Veepoo.u(it, 1) == 3 }, idleMs = 1_500) {
                Veepoo.u(it, 4) >= Veepoo.u(it, 5)
            }
        }.onSuccess { ps ->
            SmartWearLog.i("[$name] 89 03 = ${ps.joinToString(" | ") { it.toHex() }}")
            if (ps.size >= 2) VeepooHealth.parseGlucoseMulti(ps[0], ps[1])?.let { e = e.copy(glucose = it) }
        }.onFailure { SmartWearLog.w("[$name] 89 03: ${it.message}") }
        else if (f.glucoseCalibrationSingle) runCatching { request(VeepooHealth.GLUCOSE_CALIBRATION_READ) { it.op == 0x89 && it.size >= 7 && Veepoo.u(it, 1) == 2 } }
            .onSuccess { p -> SmartWearLog.i("[$name] 89 02 = ${p.toHex()}"); VeepooHealth.parseGlucoseCalibration(p)?.let { e = e.copy(glucose = it) } }
            .onFailure { SmartWearLog.w("[$name] 89 02: ${it.message}") }
        if (f.bloodComponentCalibration) runCatching { request(VeepooHealth.BLOOD_CALIBRATION_READ) { it.op == 0x8A && it.size >= 15 && Veepoo.u(it, 1) == 2 } }
            .onSuccess { p -> SmartWearLog.i("[$name] 8A 02 = ${p.toHex()}"); VeepooHealth.parseBloodCalibration(p)?.let { e = e.copy(blood = it) } }
            .onFailure { SmartWearLog.w("[$name] 8A 02: ${it.message}") }
        extra = e
    }

    override suspend fun setControl(id: String, value: ControlValue) {
        if (state.value != ConnectionState.CONNECTED) throw VeepooException("Vòng tay chưa kết nối")
        VeepooControls.b8Change(id, value)?.let { (page, index, v) ->
            val packet = customSettings.write(page, index, v) ?: throw VeepooException("Chưa đọc được B8 gói $page")
            val rsp = runCatching { request(packet) { it.op == 0xB8 && it.size >= 20 && Veepoo.u(it, 19) == page } }.getOrNull()
            SmartWearLog.i("[$name] B8 $id=$v → ${rsp?.toHex()}")
            customSettings = customSettings.with(page, index, v)
            rebuildControls()
            return
        }
        val key = id.substringBefore('.')
        val remindType = VeepooControls.remindTypeOf(id)
        if (remindType != null) {
            val cur = reminds[remindType] ?: VeepooControls.Remind(remindType, 9 * 60, 18 * 60, 60, false)
            val next = when (id.substringAfterLast('.')) {
                "enabled" -> cur.copy(on = (value as ControlValue.Bool).on)
                "interval" -> cur.copy(interval = (value as ControlValue.Number).value)
                "range" -> (value as ControlValue.TimeRange).let { cur.copy(fromMinute = it.fromMinute, toMinute = it.toMinute) }
                else -> throw VeepooException("Không có mục $id")
            }
            val rsp = request(VeepooControls.remindWrite(next)) { it.op == 0xE7 && it.size >= 3 && Veepoo.u(it, 1) == 1 }
            if (Veepoo.u(rsp, 2) != 1) throw VeepooException("Vòng tay từ chối E7: ${rsp.toHex()}")
            reminds = reminds + (remindType to next)
            rebuildControls()
            return
        }
        if (key == "hrAlarm") {
            val cur = heartAlarm ?: VeepooControls.HeartAlarm(160, 45, false)
            val next = when (id) {
                "hrAlarm.enabled" -> cur.copy(on = (value as ControlValue.Bool).on)
                "hrAlarm.high" -> cur.copy(high = (value as ControlValue.Number).value)
                "hrAlarm.low" -> cur.copy(low = (value as ControlValue.Number).value)
                else -> throw VeepooException("Không có mục $id")
            }
            runCatching { request(VeepooControls.heartAlarmWrite(next)) { it.op == 0xAC } }.onSuccess { SmartWearLog.i("[$name] AC ghi → ${it.toHex()}") }
            heartAlarm = next
            rebuildControls()
            return
        }
        // Hiệu chuẩn: ghi xuống vòng tay, đọc lại kết quả từ phản hồi (unit test bytes; KHÔNG thử trên vòng tay thật).
        if (id.startsWith("calibrate.")) {
            val next = runCatching { VeepooControls.applyCalibration(id, value, extra) }.getOrElse { throw VeepooException(it.message ?: "Không có mục $id") }!!
            val packets = VeepooControls.calibrationPackets(id, features, next)
            val op = Veepoo.u(packets.first(), 0)
            packets.dropLast(1).forEach { writeCommand(it) }
            val rsp = request(packets.last()) { it.op == op && it.size >= 4 && (op != 0x89 || Veepoo.u(it, 1) == Veepoo.u(packets.last(), 1)) && (op != 0x8A || Veepoo.u(it, 1) == 2) }
            SmartWearLog.i("[$name] hiệu chuẩn $id → ${rsp.toHex()}")
            val ok = when (op) {
                0x91 -> VeepooHealth.parseBpCalibration(rsp) != null
                0x8A -> VeepooHealth.parseBloodCalibration(rsp) != null
                else -> Veepoo.u(rsp, 3) == 1
            }
            if (!ok) throw VeepooException("Vòng tay từ chối hiệu chuẩn: ${rsp.toHex()}")
            extra = next
            rebuildControls()
            return
        }
        VeepooControls.applyProfile(id, value, profile())?.let { p ->
            saveProfile(p)
            if (!sendProfile()) SmartWearLog.w("[$name] A3 không xác nhận, sẽ gửi lại lần nối sau")
            rebuildControls()
            return
        }
        if (id == "language") {
            val code = VeepooControls.LANGUAGES.getOrNull((value as ControlValue.Number).value)?.second ?: return
            runCatching { request(VeepooControls.language(code)) { it.op == 0xF4 } }.onSuccess { SmartWearLog.i("[$name] F4 → ${it.toHex()}") }
            language = code
            rebuildControls()
            return
        }
        throw VeepooException("Không có mục $id")
    }

    override suspend fun runAction(id: String) {
        if (state.value != ConnectionState.CONNECTED) throw VeepooException("Vòng tay chưa kết nối")
        when (id) {
            "find.start" -> findDevice(true)
            "find.stop" -> findDevice(false)
            // Nguy hiểm, app phải hỏi lại người dùng (DeviceControl.confirm). Không chạy thử trên vòng tay thật.
            "device.powerOff" -> writeCommand(VeepooHealth.POWER_OFF)
            "data.reset" -> writeCommand(VeepooHealth.FACTORY_RESET)
            "device.read" -> {
                val b8 = collectPackets(VeepooCustomSettings.READ, { it.op == 0xB8 && it.size >= 20 }, idleMs = 1_000)
                if (b8.isNotEmpty()) customSettings = VeepooCustomSettings(
                    b8.lastOrNull { Veepoo.u(it, 19) == 0 } ?: customSettings.page0, b8.lastOrNull { Veepoo.u(it, 19) == 1 } ?: customSettings.page1,
                )
                readDeviceState()
            }
            else -> throw VeepooException("Không có hành động $id")
        }
    }

    /** Rung vòng tay `B5 0A` / dừng `B5 0B`; trả về trạng thái vòng tay báo (0 không hỗ trợ, 1 đang tìm, 2 đã thấy, 3 không thấy). */
    suspend fun findDevice(start: Boolean): Int? {
        val p = runCatching { request(VeepooPhone.findDevice(start)) { VeepooPhone.findDeviceStatus(it) != null } }.getOrNull()
        SmartWearLog.i("[$name] tìm vòng tay ${if (start) "bắt đầu" else "dừng"} → ${p?.toHex()}")
        return p?.let(VeepooPhone::findDeviceStatus)
    }

    /** Vòng tay tìm điện thoại: `B5 00 …` ⇒ đổ chuông. Vòng tay không gửi lệnh dừng (G Band bỏ qua `B5 02`). */
    override val findPhoneRequests: Flow<Boolean> = events.filter(VeepooPhone::isFindPhone).map { true }

    /** Người dùng tắt chuông trên điện thoại ⇒ `B5 02` (`stopFindCYPhone`). */
    override suspend fun setPhoneRinging(ringing: Boolean) {
        if (ringing || state.value != ConnectionState.CONNECTED) return
        runCatching { writeCommand(VeepooPhone.FIND_PHONE_STOP) }
    }

    // ---------- Thông báo + cuộc gọi ----------

    /** Thiết bị gửi bảng `AD` khi bắt tay ⇒ có thông báo (`VBC:1295-1300`). */
    override val supportsNotifications: Boolean get() = messageSwitches.any

    /**
     * App vòng tay nhận: app có trong `AD` (≠ 0); nếu vòng tay hỗ trợ "khác" (17) thì mọi app trong bảng đều gửi được dưới dạng "khác"
     * ([NotificationApp.hasIcon] = false), như GE54 với Zalo.
     */
    override fun notificationApps(): List<NotificationApp> {
        val sw = messageSwitches
        val other = sw.status(VeepooPhone.TYPE_OTHER) != 0
        return VeepooPhone.APPS.mapNotNull { a ->
            val own = sw.status(a.type) != 0
            if (!own && !other) null else NotificationApp(a.key, a.name, a.packages, hasIcon = own)
        }
    }

    override suspend fun sendNotification(appKey: String, title: String, text: String, ticker: String?): Boolean {
        val type = VeepooPhone.typeFor(appKey, messageSwitches) ?: return false
        if (title.isEmpty() && text.isEmpty()) return false
        return sendC2(VeepooPhone.appMessage(type, title, text, features.messagePackets, features.contactMsgLength))
    }

    override suspend fun sendSms(sender: String, text: String): Boolean {
        if (messageSwitches.status(VeepooPhone.TYPE_SMS) == 0 || text.isEmpty()) return false
        val isName = sender.any { it.isLetter() }
        return sendC2(VeepooPhone.sms(sender, isName, text, features.messagePackets, features.contactMsgLength))
    }

    override val supportsIncomingCall: Boolean get() = messageSwitches.any
    override val supportsRejectCall: Boolean get() = messageSwitches.any
    override val rejectCallEnabled: Boolean get() = prefs.getBoolean("rejectCall_$id", true)

    override suspend fun setRejectCallEnabled(enabled: Boolean) {
        prefs.edit().putBoolean("rejectCall_$id", enabled).apply()
    }

    override suspend fun incomingCall(name: String, number: String?): Boolean {
        val who = name.ifEmpty { number.orEmpty() }
        if (who.isEmpty()) return false
        return sendC2(VeepooPhone.incomingCall(who, isName = name.isNotEmpty() && name != number, contactMsgLength = features.contactMsgLength))
    }

    override suspend fun callEnded() {
        if (state.value != ConnectionState.CONNECTED) return
        runCatching { writeCommand(VeepooPhone.CALL_END) }
    }

    /** `C1 02` = người dùng bấm từ chối trên vòng tay. */
    override val rejectCallRequests: Flow<Unit> = events.filter(VeepooPhone::isRejectCall)
        .filter { rejectCallEnabled.also { on -> if (!on) SmartWearLog.i("[$name] từ chối cuộc gọi: công tắc đang tắt") } }
        .map { }

    /** Gửi lần lượt các gói `C2` (ghi có phản hồi), rồi chờ `C2 FF kết-quả` tối đa 1,5 s (chỉ để log; không có vẫn coi là đã gửi). */
    private suspend fun sendC2(packets: List<ByteArray>): Boolean {
        if (state.value != ConnectionState.CONNECTED || packets.isEmpty()) return false
        return try {
            lock.withLock {
                val channel = Channel<ByteArray>(Channel.UNLIMITED)
                waiter = Waiter({ it.op == 0xC2 }, channel)
                try {
                    packets.forEach { writeCommand(it) }
                    val r = withTimeoutOrNull(1_500) { channel.receive() }
                    SmartWearLog.i("[$name] C2 ${packets.size} gói (loại ${Veepoo.u(packets[0], 1)}) → ${r?.toHex() ?: "không có phản hồi"}")
                    r == null || Veepoo.u(r, 1) != 0xFF || (r.size > 2 && Veepoo.u(r, 2) != 0)
                } finally {
                    waiter = null
                }
            }
        } catch (e: Exception) {
            if (e is kotlinx.coroutines.CancellationException) throw e
            SmartWearLog.w("[$name] gửi thông báo lỗi: ${e.message}")
            false
        }
    }

    // ---------- Nhạc ----------

    /** A7 gói 3 byte 6 (`musicType`) ≠ 0. */
    override val supportsMusicControl: Boolean get() = features.musicType != 0
    override val supportsTrackInfo: Boolean get() = features.musicType == 1

    override val musicCommands: Flow<MusicCommand> = events.mapNotNull(VeepooPhone::parseMusicCommand)

    @Volatile
    private var lastMusic: MusicState? = null

    /** `99 01 idx total` + TLV `F0` (bài, ca sĩ, trạng thái, âm lượng). */
    override suspend fun setMusicState(state: MusicState) {
        if (this.state.value != ConnectionState.CONNECTED || features.musicType != 1) return
        val merged = lastMusic?.let { old -> state.copy(title = state.title ?: old.title, artist = state.artist ?: old.artist, volumePercent = state.volumePercent ?: old.volumePercent) } ?: state
        lastMusic = merged
        runCatching { VeepooPhone.musicPackets(merged.playing, merged.title, merged.artist, null, merged.volumePercent).forEach { writeCommand(it) } }
            .onFailure { SmartWearLog.w("[$name] gửi nhạc lỗi: ${it.message}") }
    }

    override suspend fun setMusicVolume(percent: Int) {
        val s = lastMusic ?: MusicState(playing = false)
        setMusicState(s.copy(volumePercent = percent))
    }

    // ---------- Chụp ảnh từ xa ----------

    override val supportsRemoteCamera: Boolean get() = features.camera
    override val remoteCameraEvents: SharedFlow<RemoteCameraEvent> = _remoteCamera.asSharedFlow()

    /** `B6 01` mở / `B6 00` thoát màn chụp; vòng tay trả `B6 01 01` / `B6 01 00`. */
    override suspend fun setRemoteCamera(open: Boolean) {
        if (state.value != ConnectionState.CONNECTED) return
        lastCameraCommand = System.currentTimeMillis()
        runCatching { writeCommand(VeepooPhone.camera(open)) }
    }

    // ---------- Sự kiện ----------

    override val deviceEvents: Flow<DeviceEvent> = _deviceEvents.asSharedFlow()

    // ---------- Danh bạ ----------

    override val supportsContacts: Boolean get() = features.contacts
    override val maxContacts: Int get() = features.maxContacts
    override val supportsClearContacts: Boolean get() = features.contacts

    /** Xoá khe 1..[maxContacts] (`72 04 id`) rồi ghi từng liên hệ (`72 01 …`), cách nhau 100 ms như app gốc. */
    override suspend fun syncContacts(contacts: List<Contact>, progress: (Float) -> Unit): Int {
        if (state.value != ConnectionState.CONNECTED) throw VeepooException("Vòng tay chưa kết nối")
        if (!supportsContacts) throw VeepooException("Vòng tay không có danh bạ")
        val list = contacts.filter { it.phone.any(Char::isDigit) }.take(maxContacts)
        clearContacts()
        list.forEachIndexed { i, c ->
            VeepooData.contactPackets(i + 1, c, sos = if (features.contactType >= 2) false else null).forEach { writeCommand(it) }
            delay(100)
            progress((i + 1f) / list.size)
        }
        return list.size
    }

    override suspend fun clearContacts() {
        if (!supportsContacts) throw VeepooException("Vòng tay không có danh bạ")
        for (id in 1..maxContacts) {
            writeCommand(VeepooData.contactDelete(id))
            delay(100)
        }
    }

    // ---------- Thời tiết ----------

    override val supportsWeather: Boolean get() = features.weather

    override suspend fun setWeather(forecast: WeatherForecast) {
        if (state.value != ConnectionState.CONNECTED) throw VeepooException("Vòng tay chưa kết nối")
        if (!supportsWeather) throw VeepooException("Vòng tay không hiển thị thời tiết")
        val now = LocalDateTime.now(zone)
        val packets = VeepooData.weatherPackets(forecast, now, crc = (now.toLocalDate().toEpochDay().toInt() * 24 + now.hour) and 0xFFFF)
        runCatching { writeCommand(VeepooData.weatherSwitch(true, fahrenheit = customSettings.get(1, VeepooCustomSettings.TEMPERATURE_UNIT) == 2)) }
        for (p in packets) {
            writeCommand(p)
            delay(50)
        }
    }

    // ---------- Bài tập ----------

    /** `DA` (A7 gói 4 byte 13): app bắt đầu / tạm dừng / tiếp tục / kết thúc buổi tập trên vòng tay. */
    override val supportsWorkoutControl: Boolean get() = features.sportControl

    @Volatile
    private var workoutType = 0
    private val _workoutEvents = MutableSharedFlow<WorkoutEvent>(extraBufferCapacity = 16, onBufferOverflow = BufferOverflow.DROP_OLDEST)
    override val workoutEvents: Flow<WorkoutEvent> = _workoutEvents.asSharedFlow()

    private suspend fun controlWorkout(ctrl: Int, st: WorkoutState) {
        if (state.value != ConnectionState.CONNECTED) throw VeepooException("Vòng tay chưa kết nối")
        if (!supportsWorkoutControl) throw VeepooException("Vòng tay không điều khiển bài tập được")
        val p = runCatching { request(VeepooData.workoutControl(workoutType, ctrl), timeoutMs = 3_000) { it.op == 0xDA } }.getOrNull()
        SmartWearLog.i("[$name] DA $ctrl → ${p?.toHex()}")
        _workoutEvents.tryEmit(WorkoutEvent.State(st, workoutType, byDevice = false))
    }

    override suspend fun startWorkout(sportType: Int) {
        workoutType = sportType
        controlWorkout(1, WorkoutState.STARTED)
    }

    override suspend fun pauseWorkout() = controlWorkout(2, WorkoutState.PAUSED)
    override suspend fun resumeWorkout() = controlWorkout(3, WorkoutState.RESUMED)
    override suspend fun stopWorkout() = controlWorkout(4, WorkoutState.STOPPED)

    // ---------- Mặt đồng hồ (chỉ Veepoo gốc) ----------

    override val supportsWatchFace: Boolean get() = VeepooWatchFace.supported(features)

    private suspend fun watchFaceInfoRaw(type: Int): VeepooWatchFace.Info {
        val p = request(VeepooWatchFace.infoRequest(type), timeoutMs = 4_000) { it.op == 0x50 && it.size >= 4 && Veepoo.u(it, 1) == 2 }
        SmartWearLog.i("[$name] 50 02 $type = ${p.toHex()}")
        return VeepooWatchFace.parseInfo(p) ?: throw VeepooException("Phản hồi 50 02 không hợp lệ: ${p.toHex()}")
    }

    override suspend fun watchFaceInfo(): WatchFaceInfo {
        if (!supportsWatchFace) throw VeepooException("Vòng tay không có mặt đồng hồ Veepoo gốc (chip ${features.cpuName}, kiểu màn ${features.screenShape})")
        val info = watchFaceInfoRaw(if (features.watchUiServerCount > 0) VeepooWatchFace.TYPE_SERVER else VeepooWatchFace.TYPE_CUSTOM)
        val (w, h, round) = VeepooWatchFace.screenOf(info.uiType, info.dialShape)
        return WatchFaceInfo(w, h, round, info.maxBytes, info.crc.toLong(), features.watchUiServerCount, customActive = false)
    }

    /**
     * Cài file mặt đồng hồ "server" (đúng định dạng của thiết bị, từ chợ mặt Veepoo) theo luồng DOOG (doc 03 §1c): `50 01` → `DOOG 05 00`
     * → thiết bị `05` ⇒ `DOOG 01` xoá → `01 03` ⇒ khối MTU−5 lên F0030003 → `DOOG 02` → thiết bị `02` ⇒ `DOOG 03 crc` → `03 crc`.
     * CHƯA KIỂM trên thiết bị thật (GE54 là JieLi, không màn hình).
     */
    override suspend fun installWatchFace(file: ByteArray, progress: (Float) -> Unit) {
        if (state.value != ConnectionState.CONNECTED) throw VeepooException("Vòng tay chưa kết nối")
        if (!supportsWatchFace) throw VeepooException("Vòng tay không cài được mặt đồng hồ Veepoo gốc")
        if (!gatt.hasService(Veepoo.UI_SERVICE)) throw VeepooException("Không có kênh F0030001")
        val info = watchFaceInfoRaw(VeepooWatchFace.TYPE_SERVER)
        val bin = VeepooWatchFace.pad4(file)
        if (bin.size > info.maxBytes) throw VeepooException("File ${bin.size} byte vượt dung lượng ${info.maxBytes}")
        val crc = Veepoo.crc16(bin)
        if (crc == info.crc) { progress(1f); return }
        if ((_battery.value ?: 100) < 30) throw VeepooException("Pin yếu, không cài mặt đồng hồ")
        runCatching { gatt.enableNotifications(Veepoo.UI_SERVICE, Veepoo.UI_CONTROL) }
        request(VeepooWatchFace.startUpdate(info, bin.size, crc), timeoutMs = 5_000) { it.op == 0x50 && it.size >= 4 && Veepoo.u(it, 1) == 1 }
            .also { if (Veepoo.u(it, 3) != 1) throw VeepooException("Vòng tay từ chối 50 01: ${it.toHex()}") }
        val ui = Channel<ByteArray>(Channel.UNLIMITED)
        uiChannel = ui
        try {
            suspend fun ctl(b: ByteArray) { onPacketSent(b); gatt.write(Veepoo.UI_SERVICE, Veepoo.UI_CONTROL, b, withResponse = true) }
            suspend fun next(ms: Long = 15_000): ByteArray = withTimeout(ms) { ui.receive() }
            ctl(VeepooWatchFace.DOOG_START)
            while (next().let { Veepoo.u(it, 0) != 0x05 }) Unit
            ctl(VeepooWatchFace.doogErase(info.address, bin.size))
            while (true) { val p = next(60_000); if (Veepoo.u(p, 0) == 0x01 && p.size >= 2 && Veepoo.u(p, 1) == 0x03) break }
            val chunk = (minOf(gatt.mtu, 248) - 5).coerceIn(20, 512)
            var off = 0
            while (off < bin.size) {
                val end = minOf(off + chunk, bin.size)
                gatt.write(Veepoo.UI_SERVICE, Veepoo.UI_DATA, bin.copyOfRange(off, end), withResponse = false)
                off = end
                progress(off.toFloat() / bin.size)
            }
            ctl(VeepooWatchFace.DOOG_DONE)
            while (next().let { Veepoo.u(it, 0) != 0x02 }) Unit
            ctl(VeepooWatchFace.doogCheck(crc))
            val r = next()
            if (Veepoo.u(r, 0) != 0x03 || r.size < 3 || Veepoo.le16(r, 1) != crc) throw VeepooException("CRC mặt đồng hồ không khớp: ${r.toHex()}")
        } finally {
            uiChannel = null
        }
    }

    @Volatile
    private var uiChannel: Channel<ByteArray>? = null

    // ---------- Lịch sử ----------

    override val supportsHistory: Boolean get() = true

    /**
     * Đồng bộ như G Band (`BleReadManager1$startSyncOriginData$1`): ngủ `E0` từng ngày, 5 phút `DF`/`D1` từng ngày, bước hôm nay
     * `D8`/`A8`, bài tập `D3`→`D4`. Số ngày tối đa = A7 gói 2 byte 2 (GE54: 3). Mỗi bước lỗi không làm hỏng bước khác.
     */
    override suspend fun syncHistoryImpl(days: Int, progress: (SyncProgress) -> Unit): DeviceHistory {
        val f = features
        val n = days.coerceIn(1, f.watchDays)
        val today = LocalDate.now(zone)
        val errors = mutableListOf<String>()
        val sleep = mutableListOf<SleepSession>()
        val five = mutableListOf<VeepooHistory.FiveMinute>()
        var totals: ActivityTotals? = null
        var workouts = emptyList<Workout>()
        data class Step(val label: String, val run: suspend () -> Unit)
        val steps = mutableListOf<Step>()
        if (f.sleep) for (d in 0 until n) steps += Step("Giấc ngủ ngày -$d") { sleep += readSleep(d, today.minusDays(d.toLong())) }
        for (d in 0 until n) steps += Step("Dữ liệu 5 phút ngày -$d") { five += readFiveMinute(d, today.minusDays(d.toLong())) }
        steps += Step("Bước hôm nay") { totals = readTodayTotals() }
        if (f.sportModel) steps += Step("Bài tập") { workouts = readWorkouts() }
        steps.forEachIndexed { i, step ->
            progress(SyncProgress(step.label, i, steps.size))
            runCatching { step.run() }.onFailure {
                if (it is kotlinx.coroutines.CancellationException) throw it
                errors += "${step.label}: ${it.message}"
            }
        }
        val series = VeepooHistory.toSeries(five, zone)
        val t = totals ?: series[Capability.STEPS]?.filter { it.timestamp >= today.atStartOfDay(zone).toInstant().toEpochMilli() }?.let { pts ->
            ActivityTotals(pts.sumOf { it.value }.toInt(), pts.sumOf { it.extra["calories"] ?: 0.0 }.toInt(), pts.sumOf { it.extra["distance"] ?: 0.0 }.toInt())
        }
        SmartWearLog.i("[$name] đồng bộ: ${five.size} bản ghi 5 phút, ${sleep.size} giấc ngủ, ${workouts.size} bài tập, hôm nay $t")
        return DeviceHistory(
            series = series,
            sleep = sleep.distinctBy { it.start }.sortedBy { it.start },
            workouts = workouts.sortedByDescending { it.start },
            today = t,
            days = n,
            syncedAt = System.currentTimeMillis(),
            errors = errors,
        )
    }

    /** `E0 day` → các gói tới gói `[1]` = 0 (app gốc chờ tối đa 30 s). */
    private suspend fun readSleep(day: Int, date: LocalDate): List<SleepSession> {
        val packets = collectPackets(VeepooHistory.sleepRequest(day), { it.op == 0xE0 }, idleMs = 5_000, isEnd = VeepooHistory::isSleepLast)
        val payload = VeepooHistory.sleepPayload(packets)
        SmartWearLog.i("[$name] E0 ngày -$day: ${packets.size} gói, ${payload.size} byte")
        if (packets.isNotEmpty()) SmartWearLog.v { "[$name] E0 -$day ${packets.joinToString(" | ") { it.toHex() }}" }
        return if (features.preciseSleep) {
            VeepooHistory.parsePrecise(payload, date).also { list ->
                list.forEach { SmartWearLog.i("[$name] ngủ ${it.start}→${it.end} tổng ${it.totalMinutes} sâu ${it.deepMinutes} nông ${it.lightMinutes} chất lượng ${it.quality}, ${it.line.size} điểm (kiểu ${it.accurateType}, ${it.pointSeconds} s/điểm)") }
            }.map { VeepooHistory.preciseToSession(it, zone) }
        } else {
            VeepooHistory.parseNormal(payload, date, zone)
        }
    }

    /** `DF pos day` (originProtocol 3/5) → khối TLV tới gói `DF FF FF`; im lặng 5 s thì dừng (như app gốc). */
    private suspend fun readFiveMinute(day: Int, date: LocalDate): List<VeepooHistory.FiveMinute> {
        if (!features.usesDf) {
            // `D1`: mỗi gói một bản ghi 5 phút (app gốc chờ 35 s cả ngày).
            val packets = collectPackets(VeepooHistory.d1Request(day), { it.op == 0xD1 }, idleMs = 5_000, isEnd = VeepooHistory::isD1End)
            val sportLayout = features.sportModel || features.originProtocolVersion == 4
            SmartWearLog.i("[$name] D1 ngày -$day: ${packets.size} gói")
            return packets.mapNotNull { VeepooHistory.parseD1(it, LocalDate.now(zone), sportLayout) }
        }
        val packets = collectPackets(VeepooHistory.dfRequest(day), { it.op == 0xDF }, idleMs = 5_000, isEnd = VeepooHistory::isDfEnd)
        val blocks = VeepooHistory.assembleDf(packets, protocol5 = features.originProtocolVersion == 5)
        val bad = blocks.count { !it.crcOk }
        SmartWearLog.i("[$name] DF ngày -$day: ${packets.size} gói, ${blocks.size} khối${if (bad > 0) ", $bad khối sai CRC" else ""}")
        packets.take(6).forEach { SmartWearLog.v { "[$name] DF -$day ${it.toHex()}" } }
        packets.lastOrNull()?.let { SmartWearLog.v { "[$name] DF -$day cuối ${it.toHex()}" } }
        return blocks.filter { it.crcOk }.mapNotNull { VeepooHistory.parseFiveMinute(it.payload, date, glucoseRiskBits = features.bloodGlucoseType == 5) }
    }

    /** Bước/quãng đường/kcal hôm nay: `D8 00` (có chế độ thể thao / origin 4,5) hoặc `A8 00`. */
    private suspend fun readTodayTotals(): ActivityTotals? {
        val f = features
        return if (f.sportModel || f.originProtocolVersion == 4 || f.originProtocolVersion == 5) {
            val p = request(VeepooHistory.STEPS_D8) { it.op == 0xD8 && it.size >= 14 }
            SmartWearLog.i("[$name] D8 = ${p.toHex()}")
            VeepooHistory.parseD8(p)
        } else {
            val p = request(VeepooHistory.STEPS_A8) { it.op == 0xA8 && it.size >= 6 }
            SmartWearLog.i("[$name] A8 = ${p.toHex()}")
            VeepooHistory.parseA8(p)?.let { ActivityTotals(it, 0, 0) }
        }
    }

    /** Bài tập ghi trên vòng tay (`D3` CRC từng khe → `D4` từng khe có dữ liệu), xem [VeepooWorkout]. */
    private suspend fun readWorkouts(): List<Workout> {
        val f = features
        val crcPacket = request(VeepooData.WORKOUT_CRC) { it.op == 0xD3 }
        val crcs = VeepooData.parseWorkoutCrc(crcPacket, f.sportModelSlots)
        SmartWearLog.i("[$name] D3 = ${crcPacket.toHex()} → CRC khe $crcs")
        val out = mutableListOf<Workout>()
        crcs?.forEachIndexed { slot, crc ->
            if (crc == 0) return@forEachIndexed
            val packets = collectPackets(VeepooData.workoutRequest(slot), { it.op == 0xD4 }, idleMs = 5_000, isEnd = VeepooData::isWorkoutLast)
            SmartWearLog.i("[$name] D4 khe $slot: ${packets.size} gói")
            packets.take(4).forEach { SmartWearLog.v { "[$name] D4 $slot ${it.toHex()}" } }
            VeepooData.parseWorkout(packets, f.multiSportType, zone)?.let { out += it }
        }
        return out
    }

    // ---------- Báo thức có chữ (B9) ----------

    override val supportsAlarms: Boolean get() = features.textAlarm
    override val maxAlarms: Int get() = if (features.textAlarm) VeepooAlarms.MAX else 0

    /** Danh sách đọc gần nhất (giữ nguyên byte ngày thô để CRC khớp khi ghi). */
    @Volatile
    private var alarmCache: List<VeepooAlarms.TextAlarm>? = null

    private suspend fun readAlarms(): List<VeepooAlarms.TextAlarm> {
        if (state.value != ConnectionState.CONNECTED) throw VeepooException("Vòng tay chưa kết nối")
        if (!supportsAlarms) throw VeepooException("Vòng tay không có báo thức có chữ")
        val packets = collectPackets(VeepooAlarms.readRequest(0), { it.op == 0xB9 && it.size >= 4 && Veepoo.u(it, 1) == 3 }, idleMs = 2_000,
            isEnd = VeepooAlarms::isLast)
        packets.forEach { SmartWearLog.i("[$name] B9 03 ← ${it.toHex()}") }
        val status = packets.firstOrNull()?.let(VeepooAlarms::parseStatus) ?: throw VeepooException("Vòng tay không trả danh sách báo thức")
        // GE54 trả báo thức mới thêm lên đầu nhưng giữ CRC app gửi (tính theo thứ tự app); sắp theo id như G Band thì CRC khớp lại.
        val list = VeepooAlarms.parseList(packets).sortedBy { it.id }
        if (list.isNotEmpty() && VeepooAlarms.crc(list) != status.second) SmartWearLog.w("[$name] CRC báo thức lệch: vòng tay %04X, tính %04X".format(status.second, VeepooAlarms.crc(list)))
        alarmCache = list
        return list
    }

    override suspend fun alarms(): List<Alarm> = readAlarms().map { it.toAlarm() }

    /** Ghi một thao tác [op] (2 thêm/sửa, 1 xoá) và chờ vòng tay xác nhận CRC danh sách mới [after]. */
    private suspend fun writeAlarm(op: Int, a: VeepooAlarms.TextAlarm, after: List<VeepooAlarms.TextAlarm>) {
        val crc = VeepooAlarms.crc(after)
        val packets = VeepooAlarms.writePackets(op, a, crc, gatt.mtu - 3)
        packets.dropLast(1).forEach { writeCommand(it) }
        val rsp = request(packets.last(), timeoutMs = 4_000) { it.op == 0xB9 && it.size >= 9 && Veepoo.u(it, 1) == op && Veepoo.u(it, 4) == 0xA0 }
        SmartWearLog.i("[$name] B9 %02X id ${a.id} → ${rsp.toHex()}".format(op))
        val st = VeepooAlarms.parseStatus(rsp)
        alarmCache = null
        if (st == null || st.first != 1 || st.second != crc) throw VeepooException("Vòng tay từ chối báo thức: ${rsp.toHex()} (chờ CRC %04X)".format(crc))
        alarmCache = after
    }

    override suspend fun setAlarm(alarm: Alarm) {
        val list = readAlarms()
        val existing = list.firstOrNull { it.id == alarm.id }
        val id = existing?.id ?: VeepooAlarms.freeId(list) ?: throw VeepooException("Vòng tay đã đủ ${VeepooAlarms.MAX} báo thức")
        // Giữ ngày thô của báo thức cũ nếu không đổi giờ/lặp (để không đổi ngày báo của báo thức một lần).
        val next = VeepooAlarms.fromAlarm(alarm, id, LocalDateTime.now(zone)).let { n ->
            if (existing != null && existing.hour == n.hour && existing.minute == n.minute && existing.repeat == n.repeat) n.copy(year = existing.year, month = existing.month, day = existing.day) else n
        }
        writeAlarm(2, next, if (existing != null) list.map { if (it.id == id) next else it } else list + next)
    }

    override suspend fun deleteAlarm(id: Int) {
        val list = readAlarms()
        val a = list.firstOrNull { it.id == id } ?: throw VeepooException("Không có báo thức id $id")
        writeAlarm(1, a, list - a)
    }

    // ---------- Gỡ lỗi ----------

    /**
     * Gỡ lỗi qua adb (app lab): gửi gói thô [bytes] lên F0080003 rồi gom mọi gói cùng opcode trong [listenMs].
     * Chỉ dùng cho lệnh đọc.
     */
    suspend fun debugExchange(bytes: ByteArray, listenMs: Long = 3_000, anyOp: Boolean = false): List<ByteArray> {
        if (state.value != ConnectionState.CONNECTED) throw VeepooException("Vòng tay chưa kết nối")
        val op = bytes[0].toInt() and 0xFF
        return lock.withLock {
            val channel = Channel<ByteArray>(Channel.UNLIMITED)
            waiter = Waiter({ anyOp || it.op == op }, channel)
            try {
                writeCommand(bytes)
                val out = mutableListOf<ByteArray>()
                withTimeoutOrNull(listenMs) { while (true) out += channel.receive() }
                out
            } finally {
                waiter = null
            }
        }
    }

    // ---------- Kênh lệnh ----------

    private suspend fun writeCommand(bytes: ByteArray) {
        SmartWearLog.v { "-> [$name] ${bytes.toHex()}" }
        onPacketSent(bytes)
        gatt.write(Veepoo.SERVICE, Veepoo.WRITE, bytes, withResponse = writeWithResponse)
    }

    /** Gửi lệnh và chờ gói đầu tiên khớp [match]. */
    private suspend fun request(bytes: ByteArray, timeoutMs: Long = 3_000, match: (ByteArray) -> Boolean): ByteArray = lock.withLock {
        val channel = Channel<ByteArray>(Channel.UNLIMITED)
        waiter = Waiter(match, channel)
        try {
            val started = System.currentTimeMillis()
            writeCommand(bytes)
            withTimeout(timeoutMs) { channel.receive() }.also { onLatency(System.currentTimeMillis() - started) }
        } catch (e: TimeoutCancellationException) {
            throw VeepooException("Lệnh %02X không có phản hồi".format(bytes[0]))
        } finally {
            waiter = null
        }
    }

    /** Gửi [bytes] rồi gom mọi gói khớp [match] tới gói [isEnd] (có gồm) hoặc khi im lặng quá [idleMs]. */
    private suspend fun collectPackets(
        bytes: ByteArray, match: (ByteArray) -> Boolean, idleMs: Long = 3_000, isEnd: (ByteArray) -> Boolean = { false },
    ): List<ByteArray> = lock.withLock {
        val channel = Channel<ByteArray>(Channel.UNLIMITED)
        waiter = Waiter(match, channel)
        val packets = mutableListOf<ByteArray>()
        try {
            writeCommand(bytes)
            while (true) {
                val p = withTimeoutOrNull(idleMs) { channel.receive() } ?: break
                packets += p
                if (isEnd(p)) break
            }
            packets
        } finally {
            waiter = null
        }
    }

    private fun onNotification(n: GattNotification) {
        onPacketReceived(n.value, note = describe(n.value))
        if (n.characteristic == Veepoo.UI_CONTROL) {
            uiChannel?.trySend(n.value)
            return
        }
        val w = waiter
        if (w != null && w.match(n.value)) w.channel.trySend(n.value) else events.tryEmit(n.value)
    }

    private fun describe(p: ByteArray): String? = when (p.op) {
        0xA0 -> Veepoo.parseBattery(p)?.let { "pin ${it.percent} %" }
        0xA1 -> Veepoo.parsePasswordReply(p)?.let { "mật khẩu: ${it.status}, fw ${it.firmware}" }
        0xA7 -> if (p.size >= 20) "bảng tính năng gói ${Veepoo.u(p, 19)}" else null
        0xD0 -> if (p.size >= 2) "nhịp tim ${Veepoo.u(p, 1)}" else null
        0x80 -> if (p.size >= 4) "SpO2 ${Veepoo.u(p, 3)} (máy ${Veepoo.u(p, 2)})" else null
        0x90 -> if (p.size >= 5) "huyết áp ${Veepoo.u(p, 1)}/${Veepoo.u(p, 2)} ${Veepoo.u(p, 3)}%" else null
        else -> null
    }

    private companion object {
        val HANDSHAKE_OPS = setOf(0xA1, 0xA7, 0xAD, 0xB8)
        const val HANDSHAKE_MS = 8_000L
        const val HANDSHAKE_QUIET_MS = 600L
        /** Chờ `A1` (app gốc: 4 s, `VOM:1099-1104`). */
        const val PASSWORD_TIMEOUT_MS = 4_000L
        /** Đã có `A1` mà chưa đủ 5 gói `A7` thì chờ thêm tới mốc này. */
        const val A7_WAIT_MS = 3_000L
        const val MEASURE_IDLE_MS = 20_000L
        /** Bỏ lần bấm chụp lặp trong khoảng này (như GloryFit). */
        const val SHUTTER_GAP_MS = 2_000L
        const val CAMERA_ECHO_MS = 3_000L
        val MEASURABLE = setOf(
            Capability.HEART_RATE, Capability.SPO2, Capability.BLOOD_PRESSURE, Capability.TEMPERATURE, Capability.STRESS, Capability.BLOOD_SUGAR,
            Capability.URIC_ACID, Capability.BLOOD_LIPIDS, Capability.BODY_COMPOSITION, Capability.MET,
        )
    }
}
