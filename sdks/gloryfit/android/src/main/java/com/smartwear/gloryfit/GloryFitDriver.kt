package com.smartwear.gloryfit

import android.content.Context
import com.smartwear.core.AgpsFile
import com.smartwear.core.AgpsInfo
import com.smartwear.core.AgpsRequest
import com.smartwear.core.AgpsRequestType
import com.smartwear.core.AgpsSupport
import com.smartwear.core.BaseWearableDevice
import com.smartwear.core.CallAudioLink
import com.smartwear.core.CallAudioState
import com.smartwear.core.CallDisplay
import com.smartwear.core.ContactsSync
import com.smartwear.core.DeviceEvent
import com.smartwear.core.DeviceEvents
import com.smartwear.core.FirmwareCheck
import com.smartwear.core.FirmwareUpdatable
import com.smartwear.core.FirmwareUpdateOptions
import com.smartwear.core.LocationRequest
import com.smartwear.core.MusicCommand
import com.smartwear.core.MusicRemote
import com.smartwear.core.MusicState
import com.smartwear.core.NotificationApp
import com.smartwear.core.NotificationDisplay
import com.smartwear.core.SmsQuickReply
import com.smartwear.core.SmsReplyConfig
import com.smartwear.core.SmsReplyRequest
import com.smartwear.core.SportName
import com.smartwear.core.SportType
import com.smartwear.core.WatchFaceInfo
import com.smartwear.core.WatchFaceSlot
import com.smartwear.core.WorkoutData
import com.smartwear.core.WorkoutEvent
import com.smartwear.core.WorkoutRemote
import com.smartwear.core.WorkoutState
import com.smartwear.gloryfit.ota.RealtekDfuClient
import com.smartwear.gloryfit.ota.RealtekImage
import com.smartwear.core.BleQuiet
import com.smartwear.core.Capability
import com.smartwear.core.ConfigurableDevice
import com.smartwear.core.WeatherDisplay
import com.smartwear.core.WeatherForecast
import com.smartwear.core.ControlValue
import com.smartwear.core.DeviceControl
import com.smartwear.core.ConnectionState
import com.smartwear.core.DeviceDriver
import com.smartwear.core.DeviceHistory
import com.smartwear.core.DeviceInfo
import com.smartwear.core.DriverMatch
import com.smartwear.core.GattConnection
import com.smartwear.core.GattNotification
import com.smartwear.core.HeartRateSample
import com.smartwear.core.HeartRateStreaming
import com.smartwear.core.HistoryPoint
import com.smartwear.core.PairingPrompt
import com.smartwear.core.RemoteCameraDevice
import com.smartwear.core.RemoteCameraEvent
import com.smartwear.core.Reading
import com.smartwear.core.ReadingStatus
import com.smartwear.core.ScannedDevice
import com.smartwear.core.SleepSession
import com.smartwear.core.SmartWearLog
import com.smartwear.core.SyncProgress
import com.smartwear.core.toHex
import com.smartwear.core.WatchFaceCustomizable
import com.smartwear.core.WatchFaceSpec
import com.smartwear.core.WatchFaceStyle
import com.smartwear.core.WatchWidget
import android.graphics.RectF
import android.graphics.Bitmap
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.mapNotNull
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
import java.time.LocalTime
import java.time.ZoneId
import kotlin.random.Random

/** Driver cho thiết bị dùng app GloryFit (SDK UTE), ví dụ đồng hồ Y25. */
object GloryFitDriver : DeviceDriver {
    override val id = "gloryfit"
    override val displayName = "GloryFit (UTE)"

    /**
     * Ghép đôi hệ thống (bond) khi nối đồng hồ có kênh gọi Bluetooth mà chưa ghép, như app GloryFit/GloryFitPro làm ngay khi bind.
     * Đo 19/10/2026 trên Y25 + Redmi Note 7 Pro: chưa ghép thì Y25 chỉ quảng bá ~4–6 s mỗi lần được đánh thức (nối lại phải chờ người
     * dùng bấm sáng); đã ghép thì app nối lại sau 3–6 s không cần đánh thức (5/5 lần, kể cả khi cả kênh cổ điển lẫn LE đã ngắt).
     * Android hiện hộp thoại xác nhận ghép đôi; mỗi thiết bị chỉ hỏi một lần mỗi phiên. Tắt nếu app tự lo việc ghép.
     */
    @Volatile var bondOnConnect: Boolean = true

    override fun match(device: ScannedDevice): DriverMatch? {
        val name = device.name.orEmpty()
        val advertisesUte = device.serviceUuids.any { it in Ute.ADVERTISED }
        if (!advertisesUte && !name.startsWith("Y25")) return null
        return DriverMatch(name.substringBefore('_').ifEmpty { "Thiết bị GloryFit" })
    }

    override fun create(context: Context, device: ScannedDevice, match: DriverMatch) =
        GloryFitDevice(context, device, match.model)
}

class GloryFitException(message: String) : Exception(message)

class GloryFitDevice(
    context: Context,
    scanned: ScannedDevice,
    private val model: String,
) : BaseWearableDevice(scanned.address, scanned.name ?: model, GloryFitDriver), WatchFaceCustomizable, ConfigurableDevice, WeatherDisplay,
    RemoteCameraDevice, NotificationDisplay, CallDisplay, MusicRemote, SmsQuickReply, ContactsSync, CallAudioLink, WorkoutRemote, HeartRateStreaming, AgpsSupport,
    FirmwareUpdatable, DeviceEvents {

    private val appContext = context.applicationContext
    private val btDevice = scanned.device
    private val gatt = GattConnection(context.applicationContext, scanned.device)
    private val prefs = context.applicationContext.getSharedPreferences("smartwear_gloryfit", Context.MODE_PRIVATE)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val zone = ZoneId.systemDefault()

    private val lock = Mutex()
    private class Waiter(val match: (ByteArray) -> Boolean, val channel: Channel<ByteArray>)

    @Volatile
    private var waiter: Waiter? = null
    private val events = MutableSharedFlow<ByteArray>(extraBufferCapacity = 64, onBufferOverflow = BufferOverflow.DROP_OLDEST)
    private var features = Ute.Features(emptyMap(), null)
    private var writeWithResponse = true
    /**
     * 34F1 nhận ghi có phản hồi không. Y25 (Redmi, 19/10/2026): ghi có phản hồi lên 34F1 bị từ chối `status 3`
     * (GATT_WRITE_NOT_PERMITTED, cả `38 01`, `46 FA`, `FD 48 AA`), ghi không phản hồi thì đồng hồ trả lời bình thường ⇒ theo
     * thuộc tính characteristic như khi gửi mặt đồng hồ.
     */
    private var writeWithResponse5 = true
    private var codeInput: CompletableDeferred<String>? = null

    /** Nhịp tim đồng hồ tự đẩy gần nhất (`F7 03`/`F7 0B`/`E5 … rr`) và lúc nhận. */
    @Volatile
    private var lastPushedHr: Reading? = null
    @Volatile
    private var lastPushedHrAt = 0L
    /** Đã gửi `F7 01` + `F7 09` trong lần kết nối này. */
    @Volatile
    private var hr24Configured = false

    override val supportsHistory: Boolean get() = true

    // ---------- Cài đặt (UteSettings) ----------

    private var settings = UteSettings.decode(prefs.getString("settings_${scanned.address}", null))
    /** Ngôn ngữ / phím tắt đọc từ đồng hồ lúc kết nối ([readDeviceState]). */
    @Volatile
    private var readState = UteReadState()
    private val _controls = MutableStateFlow<List<DeviceControl>>(emptyList())
    override val controls: StateFlow<List<DeviceControl>> = _controls.asStateFlow()

    /**
     * `D1 0A` (2 byte): đồng hồ bắt đầu tìm điện thoại; `D1 0A xx 00` (4 byte): dừng (`BluetoothLeService`).
     * `D1 0A xx 01` là đồng hồ dội lại [setPhoneRinging] (true), không phải lệnh dừng.
     */
    override val findPhoneRequests = events
        .filter { it.size >= 2 && Ute.u(it, 0) == 0xD1 && Ute.u(it, 1) == 0x0A && (it.size == 2 || (it.size == 4 && Ute.u(it, 3) == 0)) }
        .mapNotNull { it.size == 2 }

    /**
     * `D1 0A 01 01/00`: điện thoại đang đổ chuông / đã dừng ⇒ đồng hồ tắt màn tìm điện thoại
     * (`WriteCommandToBLE.phoneRingStatus`, gọi từ `BluetoothLeService.findPhonePlayerStop`).
     */
    override suspend fun setPhoneRinging(ringing: Boolean) {
        if (!features.has(2, 0x000020) || state.value != ConnectionState.CONNECTED) return
        runCatching { writeCommand(byteArrayOf(0xD1.toByte(), 0x0A, 0x01, if (ringing) 0x01 else 0x00)) }
    }

    // Khai báo trước `init` vì bộ thu sự kiện chụp ảnh trong `init` dùng tới.
    private val _remoteCamera = MutableSharedFlow<RemoteCameraEvent>(extraBufferCapacity = 8, onBufferOverflow = BufferOverflow.DROP_OLDEST)
    @Volatile
    private var lastShutter = 0L

    init {
        _info.value = DeviceInfo(model = model, extra = mapOf("Driver" to "GloryFit / UTE (sdks/gloryfit)", "Địa chỉ" to id))
        gatt.onNotification = ::onNotification
        gatt.onDisconnected = { status -> onError("Mất kết nối (status=$status)") }
        scope.launch { gatt.state.collect(::onTransportState) }
        // Nhịp tim 24h đồng hồ tự đẩy: `F7 03 YYYY MM DD hh mm rr` (kiểm chứng trên Y25: … 11 05 57 = 87 bpm),
        // `F7 0B …` khi người dùng đo trên đồng hồ (doc 09 §2.2). Y25 đo trên đồng hồ còn đẩy `E5 11 00 rr`
        // khoảng mỗi giây (kiểm chứng: 71–80 bpm lúc 18:24), nên hiển thị cả khi app không chạy phép đo.
        scope.launch {
            events.collect { p ->
                (Ute.parsePushedHeartRate(p, zone) ?: Ute.parseLiveHeartRate(p))?.let {
                    lastPushedHr = it
                    lastPushedHrAt = System.currentTimeMillis()
                    publish(it)
                }
            }
        }
        // Chụp ảnh từ xa: `C4 02` (GloryFit `BluetoothLeService` → OnResult 21; GloryFitPro `uterkbyte.java:145-150`) hoặc
        // `D1 03` (Pro `uterkchar.java:153-155`) = bấm chụp; `D1 11` / `D1 0F` = người dùng mở / đóng màn chụp trên đồng hồ
        // (`uterkchar.java:205-210`). Bỏ lần chụp lặp trong [SHUTTER_GAP_MS], như bản iOS (GloryFit `FragmentHomePage`:
        // `isTakePhoto` khoá 4 s; GloryFitPro `MainService.onDeviceCameraStatus` chỉ khoá 2 s).
        scope.launch {
            events.collect { p ->
                if (p.size < 2) return@collect
                val event = when (Ute.u(p, 0) to Ute.u(p, 1)) {
                    0xC4 to 0x02, 0xD1 to 0x03 -> RemoteCameraEvent.SHUTTER
                    0xD1 to 0x11 -> RemoteCameraEvent.OPENED
                    0xD1 to 0x0F -> RemoteCameraEvent.CLOSED
                    else -> return@collect
                }
                if (event == RemoteCameraEvent.SHUTTER) {
                    val now = System.currentTimeMillis()
                    if (now - lastShutter < SHUTTER_GAP_MS) return@collect
                    lastShutter = now
                }
                _remoteCamera.tryEmit(event)
            }
        }
    }

    // ---------- Kết nối + bind ----------

    /**
     * Cũng `autoConnect = true`: Y25 chỉ quảng bá ~4–6 s mỗi lần được đánh thức / vừa mất kết nối rồi im (đo 19/10/2026,
     * Redmi + Mac mini). Nối trực tiếp (40 s rồi lùi) có lúc lỡ trọn đợt phát; lệnh chờ của controller bắt được ngay
     * gói đầu tiên (15:18:35 nối trước cả khi app quét thấy). Chờ không giới hạn, huỷ bằng [disconnect].
     */
    override suspend fun connect() = openLink(autoConnect = true)

    /** Nối lại thiết bị đã lưu: `autoConnect = true`, chờ đồng hồ quảng bá không giới hạn (như iOS, doc 09 §1.4). */
    override suspend fun reconnect() = openLink(autoConnect = true)

    private suspend fun openLink(autoConnect: Boolean) {
        _lastError.value = null
        hr24Configured = false
        try {
            val started = System.currentTimeMillis()
            gatt.connect(autoConnect = autoConnect)
            if (!autoConnect) onLatency(System.currentTimeMillis() - started)
            if (!gatt.hasService(Ute.SERVICE)) throw GloryFitException("Không có service 55FF: không phải thiết bị UTE")
            gatt.enableNotifications(Ute.SERVICE, Ute.NOTIFY)
            val hasBle5 = gatt.hasService(Ute.SERVICE5)
            if (hasBle5) runCatching { gatt.enableNotifications(Ute.SERVICE5, Ute.NOTIFY5) }
            val main = runCatching { gatt.read(Ute.SERVICE, Ute.WRITE) }.getOrNull()
            val ble5 = if (hasBle5) runCatching { gatt.read(Ute.SERVICE5, Ute.WRITE5) }.getOrNull() else null
            features = Ute.Features.parse(main, ble5)
            runCatching { gatt.requestMtu(247) }
            writeWithResponse = gatt.supportsWriteWithResponse(Ute.SERVICE, Ute.WRITE)
            writeWithResponse5 = !hasBle5 || gatt.supportsWriteWithResponse(Ute.SERVICE5, Ute.WRITE5)
            SmartWearLog.i("[$name] tính năng 33F1=${main?.toHex()} 34F1=${ble5?.toHex()}")

            bind()

            // `A3` 8 byte (Y25/HT43 đã phản hồi). Byte múi giờ như SDK iOS chỉ gửi khi bật GloryFitDebug.timeZoneByte.
            val now = LocalDateTime.now()
            runCatching { request(Ute.setTime(now, if (GloryFitDebug.timeZoneByte) Ute.tzHours(zone, now) else null)) { it.op == 0xA3 } }
                .onFailure { onError("Đặt giờ không có phản hồi") }
            val firmware = runCatching { request(byteArrayOf(0xA1.toByte())) { it.op == 0xA1 && it.size > 2 } }
                .getOrNull()?.drop(1)?.toByteArray()?.decodeToString()?.trim('\u0000', ' ')

            val caps = features.capabilities()
            _capabilities.value = caps
            _measurable.value = caps intersect setOf(Capability.HEART_RATE, Capability.SPO2, Capability.BLOOD_PRESSURE, Capability.TEMPERATURE)
            _info.value = DeviceInfo(
                model = model,
                firmware = firmware,
                extra = linkedMapOf(
                    "Driver" to "GloryFit / UTE (sdks/gloryfit)",
                    "Địa chỉ" to id,
                    "Bảng tính năng 33F1" to (main?.toHex() ?: "không đọc được"),
                    "Bảng tính năng 34F1" to (ble5?.toHex() ?: "không có"),
                    "Kiểu bind" to when {
                        features.usesPairingCode -> "Mã 4 số"
                        features.usesAccountId -> "Account ID"
                        else -> "Không cần"
                    },
                    "Độ dài gói tối đa" to (features.maxPacketLength?.toString() ?: "20"),
                ),
            )
            refreshBattery()
            // Như app GloryFit: gửi đơn vị và thông tin người dùng trước khi đo/đồng bộ.
            runCatching { request(UteControls.units(settings)) { it.op == 0xA0 } }.onFailure { SmartWearLog.w("[$name] A0 không có phản hồi") }
            runCatching { request(UteControls.userInfo(settings)) { it.op == 0xA9 } }.onFailure { SmartWearLog.w("[$name] A9 không có phản hồi") }
            if (features.heartRateByPush && settings.on("hr24.enabled")) configureHeartRate24h()
            // Như GloryFitPro `syncDeviceMonitorSetting`: gửi lại công tắc + chu kỳ SpO2 tự động mỗi lần kết nối.
            if (with(UteControls) { features.spo2Auto() }) {
                UteControls.commands("spo2Auto.enabled", features, settings).forEach { runCatching { writeCommand(it) } }
            }
            // Như GloryFitPro `setTimeClockRk` (`MainHomeModelRkImpl.java:222-225`): F5 `0x800` ⇒ đọc danh sách icon `DB AA`.
            if (UteNotify.displayList(features)) {
                _remindDisplay.value = runCatching { request(UteNotify.QUERY_DISPLAY) { it.op == 0xDB } }
                    .onFailure { SmartWearLog.w("[$name] DB AA không có phản hồi") }
                    .getOrNull()?.let(UteNotify::parseDisplay)
            }
            _controls.value = UteControls.controls(features, settings, read = readState)
            refreshRssi()
            markReady()
            // Như `MainHomeModelRkImpl.setAPPParamsToDeviceRk` → `syncSmsReply` (`:996-1014`): gửi lại công tắc + mẫu trả lời SMS
            // mỗi lần kết nối. Chạy sau khi sẵn sàng để không làm chậm kết nối.
            if (supportsSmsReply) scope.launch { runCatching { syncSmsReply() }.onFailure { SmartWearLog.w("[$name] đồng bộ trả lời SMS: ${it.message}") } }
            // Chỉ đọc: ngôn ngữ đang dùng (`AF AA`), phím tắt nhanh (`BE 01/02`). Chạy nền để không làm chậm kết nối.
            scope.launch { runCatching { readDeviceState() }.onFailure { SmartWearLog.w("[$name] đọc cài đặt đồng hồ: ${it.message}") } }
            if (GloryFitDriver.bondOnConnect && supportsCallBluetooth && !bondAsked) {
                bondAsked = true
                scope.launch {
                    runCatching { if (pairCallBluetooth()) SmartWearLog.i("[$name] đã yêu cầu ghép đôi hệ thống (nối lại nhanh, không cần đánh thức)") }
                        .onFailure { SmartWearLog.w("[$name] ghép đôi hệ thống: ${it.message}") }
                }
            }
        } catch (e: Exception) {
            _pairingPrompt.value = null
            // Huỷ (người dùng ngắt khi đang chờ nối) không phải lỗi.
            if (e !is kotlinx.coroutines.CancellationException) onError("Kết nối lỗi: ${e.message}")
            gatt.disconnect()
            throw e
        }
    }

    private suspend fun bind() {
        when {
            features.usesPairingCode -> bindWithCode()
            features.usesAccountId -> bindWithAccountId()
            else -> SmartWearLog.i("[$name] thiết bị không yêu cầu bind")
        }
        _pairingPrompt.value = null
    }

    /** Luồng mã 4 số: đồng hồ hiện mã, người dùng nhập vào app. Mã đúng được lưu cho lần sau. */
    private suspend fun bindWithCode() {
        prefs.getString("code_$id", null)?.let { saved ->
            val rsp = runCatching { request(Ute.pairingCode(saved)) { it.op == 0xD5 } }.getOrNull()
            if (rsp != null && rsp.size >= 2 && Ute.u(rsp, 1) == 0x01) return
            prefs.edit().remove("code_$id").apply()
        }
        runCatching { request(byteArrayOf(0xD5.toByte(), 0x02), timeoutMs = 10_000) { it.op == 0xD5 } }
        repeat(3) { attempt ->
            val input = CompletableDeferred<String>().also { codeInput = it }
            _pairingPrompt.value = PairingPrompt.EnterCode(
                digits = 4,
                message = if (attempt == 0) "Nhập mã 4 số đang hiện trên $name" else "Mã chưa đúng, nhập lại mã trên $name",
            )
            val code = withTimeoutOrNull(120_000) { input.await() } ?: throw GloryFitException("Hết thời gian nhập mã")
            _pairingPrompt.value = null
            val rsp = request(Ute.pairingCode(code), timeoutMs = 10_000) { it.op == 0xD5 }
            when (Ute.u(rsp, 1)) {
                0x01 -> {
                    prefs.edit().putString("code_$id", code).apply()
                    return
                }
                0x03 -> throw GloryFitException("Đồng hồ báo hết thời gian ghép mã")
                else -> Unit // 0xFF: sai mã, hỏi lại
            }
        }
        throw GloryFitException("Nhập sai mã quá 3 lần")
    }

    /** Luồng Account ID: gửi id, đồng hồ hỏi người dùng xác nhận rồi trả `33 04 01`. */
    private suspend fun bindWithAccountId() {
        val accountId = prefs.getInt("id_$id", 0).takeIf { it > 0 } ?: Random.nextInt(1, 99_999_999)
        lock.withLock {
            val channel = Channel<ByteArray>(Channel.UNLIMITED)
            waiter = Waiter({ it.op == 0x33 && it.size >= 3 && Ute.u(it, 1) == 0x04 }, channel)
            try {
                writeCommand(Ute.accountId(accountId))
                withTimeout(90_000) {
                    while (true) {
                        val rsp = channel.receive()
                        when (Ute.u(rsp, 2)) {
                            0x01 -> {
                                prefs.edit().putInt("id_$id", accountId).apply()
                                return@withTimeout
                            }
                            0x02 -> prefs.edit().putInt("id_$id", accountId).apply()
                            0x03, 0x04 -> _pairingPrompt.value = PairingPrompt.ConfirmOnDevice("Bấm đồng ý trên $name để kết nối")
                            0x05 -> throw GloryFitException("Người dùng từ chối trên đồng hồ")
                        }
                    }
                }
            } catch (e: TimeoutCancellationException) {
                throw GloryFitException("Đồng hồ không xác nhận trong 90 giây")
            } finally {
                waiter = null
            }
        }
    }

    override fun submitPairingCode(code: String) {
        codeInput?.complete(code.trim())
    }

    override fun disconnect() {
        codeInput?.cancel()
        _pairingPrompt.value = null
        gatt.disconnect()
    }

    override suspend fun refreshBattery() {
        runCatching { request(byteArrayOf(0xA2.toByte())) { it.op == 0xA2 && it.size >= 2 } }
            .onSuccess { _battery.value = Ute.u(it, 1).coerceAtMost(100) }
            .onFailure { onError("Đọc pin lỗi: ${it.message}") }
    }

    override suspend fun refreshRssi() {
        runCatching { gatt.readRssi() }.onSuccess(::onRssi)
    }

    // ---------- Đo trực tiếp ----------

    override fun measureImpl(capability: Capability): Flow<Reading> = when (capability) {
        // Đồng hồ HR 24h (Y25, HT43): app GloryFit iOS không đo theo lệnh, lấy giá trị đồng hồ tự đẩy (doc 09 §2).
        Capability.HEART_RATE -> if (features.heartRateByPush) heartRateByPush() else
            // App GloryFit đo tĩnh: D6 01 (chọn chế độ tĩnh), chờ 1,5 s trên chip Realtek, rồi E5 11 (RateDetailsActivity:363-370).
            // Thiếu D6 01 thì Y25 bỏ qua E5 11 (kiểm chứng 2026-10-13).
            live(capability, start = bytes(0xE5, 0x11), stop = bytes(0xE5, 0x00), ops = setOf(0xE5, 0xF7), prepare = bytes(0xD6, 0x01), parse = ::heartRatePacket)
        Capability.SPO2 -> live(capability, start = bytes(0x34, 0x11), stop = bytes(0x34, 0x00), ops = setOf(0x34)) { p ->
            val sub = Ute.u(p, 1)
            when {
                sub != 0x11 && sub != 0x00 -> null
                p.size == 2 -> Reading(capability, ReadingStatus.MEASURING) to false
                p.size >= 4 -> {
                    val done = sub == 0x00
                    val valid = Ute.u(p, 2) == 0 && Ute.u(p, 3) in 70..100
                    when {
                        valid -> Reading(capability, ReadingStatus.OK, value = Ute.u(p, 3).toDouble())
                        done -> Reading(capability, ReadingStatus.NOT_WORN)
                        else -> Reading(capability, ReadingStatus.MEASURING)
                    } to done
                }
                else -> null
            }
        }
        Capability.BLOOD_PRESSURE -> live(capability, start = bytes(0xC7, 0x11), stop = bytes(0xC7, 0x00), ops = setOf(0xC7)) { p ->
            if (p.size < 5) return@live (Reading(capability, ReadingStatus.MEASURING) to false)
            val done = Ute.u(p, 1) == 0x00
            val valid = Ute.u(p, 2) == 0 && Ute.u(p, 3) > 0 && Ute.u(p, 4) > 0
            when {
                valid -> Reading(capability, ReadingStatus.OK, systolic = Ute.u(p, 3), diastolic = Ute.u(p, 4))
                done -> Reading(capability, ReadingStatus.NOT_WORN)
                else -> Reading(capability, ReadingStatus.MEASURING)
            } to done
        }
        Capability.TEMPERATURE -> channelFlow {
            send(Reading(capability, ReadingStatus.MEASURING))
            val p = request(bytes(0x24, 0x01), timeoutMs = 8_000) { it.op == 0x24 && it.size >= 11 && Ute.u(it, 1) == 0x01 }
            val raw = Ute.be16(p, 9)
            send(if (raw == 0xFFFF) Reading(capability, ReadingStatus.NOT_WORN) else Reading(capability, ReadingStatus.OK, value = raw / 100.0))
        }
        else -> emptyFlow()
    }

    /** Gói nhịp tim trong phép đo: `F7 03/0B` (đồng hồ đẩy) hoặc `E5 fin st rr` (kết quả `E5 11`). */
    private fun heartRatePacket(p: ByteArray): Pair<Reading, Boolean>? {
        val capability = Capability.HEART_RATE
        return when {
            p.op == 0xF7 -> Ute.parsePushedHeartRate(p, zone)?.let { it to true }
            p.op != 0xE5 -> null
            p.size == 2 && Ute.u(p, 1) == 0x11 -> Reading(capability, ReadingStatus.MEASURING) to false
            p.size == 2 && Ute.u(p, 1) == 0xFD -> Reading(capability, ReadingStatus.ERROR, errorCode = 0xFD) to true
            p.size >= 4 -> {
                val done = Ute.u(p, 1) == 0x00
                val valid = Ute.u(p, 2) == 0 && Ute.u(p, 3) > 0
                when {
                    valid -> Reading(capability, ReadingStatus.OK, value = Ute.u(p, 3).toDouble())
                    done -> Reading(capability, ReadingStatus.NOT_WORN)
                    else -> Reading(capability, ReadingStatus.MEASURING)
                } to done
            }
            else -> null
        }
    }

    /** Bật HR 24h (`F7 01`) và chu kỳ trong cài đặt (mặc định 5 phút như app GloryFit iOS, doc 09 §2.2). */
    private suspend fun configureHeartRate24h() {
        runCatching {
            UteControls.heartRate24h(settings).forEach { writeCommand(it) }
            hr24Configured = true
        }.onFailure { SmartWearLog.w("[$name] bật HR 24h lỗi: ${it.message}") }
    }

    /** Hỏi đồng hồ có đang đo nhịp tim không (`E5 AA`); null nếu không có phản hồi. */
    suspend fun heartRateMeasuring(): Boolean? =
        runCatching { request(Ute.HR_STATUS) { it.op == 0xE5 && it.size >= 3 && Ute.u(it, 1) == 0xAA } }
            .getOrNull()?.let(Ute::parseHeartRateStatus)

    /**
     * Nhịp tim trên đồng hồ HR 24h (doc 09 §2, doc 01 "Y25 đo theo lệnh"). Kiểm chứng 16/10/2026 trên Y25: khi HR 24h
     * đang bật, `E5 11` bị treo (không ack) cho tới khi tắt 24h; kết quả chỉ trả khi app gửi `E5 00` (`E5 00 00 rr`),
     * không gửi thì đèn đo chạy mãi. Nên: `F7 02` (tạm tắt 24h) → `D6 01` → `E5 11` (ack) → chờ [HR_MANUAL_WINDOW_MS] →
     * `E5 00` lấy kết quả → bật lại 24h. Không có kết quả (HT43 bỏ qua `E5`) thì dùng giá trị đẩy trong [HR_RECENT_MS]
     * hoặc chờ `F7 03`/`F7 0B` tới [HR24_WAIT_MS]. Kết thúc sớm vẫn gửi `E5 00` và bật lại 24h.
     */
    private fun heartRateByPush(): Flow<Reading> {
        val capability = Capability.HEART_RATE
        var stopped = false
        var paused = false
        return channelFlow {
            send(Reading(capability, ReadingStatus.MEASURING))
            val listener = launch(start = CoroutineStart.UNDISPATCHED) {
                events.collect { p ->
                    // Đồng hồ tự đẩy (người dùng đo trên đồng hồ / đo định kỳ) hoặc E5 11 00 rr giữa chừng.
                    val pushed = p.op == 0xF7 || (p.op == 0xE5 && p.size >= 4 && Ute.u(p, 1) == 0x11)
                    if (!pushed) return@collect
                    val (reading, _) = heartRatePacket(p) ?: return@collect
                    if (reading.status != ReadingStatus.OK) return@collect
                    send(reading)
                    if (p.op == 0xF7) channel.close()
                }
            }
            val hr24 = settings.on("hr24.enabled")
            val result = runCatching {
                if (hr24) {
                    writeCommand(bytes(0xF7, 0x02))
                    paused = true
                }
                writeCommand(bytes(0xD6, 0x01))
                delay(1_500)
                writeCommand(bytes(0xE5, 0x11))
                delay(HR_MANUAL_WINDOW_MS)
                stopped = true
                request(bytes(0xE5, 0x00)) { it.op == 0xE5 && it.size >= 4 && Ute.u(it, 1) == 0x00 }
            }.getOrNull()?.let(::heartRatePacket)?.first
            stopped = true
            if (paused) {
                paused = false
                configureHeartRate24h()
            }
            // Kênh có thể đã đóng (đồng hồ tự đẩy F7 giữa chừng) ⇒ trySend.
            if (result != null) {
                trySend(result)
            } else if (!channel.isClosedForSend) {
                val recent = lastPushedHr?.takeIf { System.currentTimeMillis() - lastPushedHrAt < HR_RECENT_MS }
                if (recent != null) trySend(recent) else {
                    trySend(Reading(capability, ReadingStatus.MEASURING, note = HR24_NOTE))
                    withTimeoutOrNull(HR24_WAIT_MS - HR_MANUAL_WINDOW_MS) { awaitClose() }
                }
            }
            listener.cancel()
        }.onCompletion {
            withContext(NonCancellable) {
                runCatching {
                    if (state.value != ConnectionState.CONNECTED) return@runCatching
                    if (!stopped) writeCommand(bytes(0xE5, 0x00))
                    if (paused) configureHeartRate24h()
                }
            }
        }
    }

    // ---------- Nhịp tim liên tục ----------

    override val supportsHeartRateStream: Boolean get() = Capability.HEART_RATE in measurable.value

    /**
     * Đo lặp: (`F7 02` tạm tắt HR 24h nếu đang bật) → `D6 01` → mỗi vòng `E5 11`, nhận `E5 11 00 rr` giữa chừng (Y25 đẩy khoảng
     * mỗi giây khi đo trên đồng hồ, kiểm chứng 18:24; khi app ra lệnh **chưa kiểm**), tới khi đồng hồ tự kết thúc `E5 00 …`
     * hoặc hết [HR_MANUAL_WINDOW_MS] thì gửi `E5 00` lấy kết quả (Y25 kiểm chứng 16/10), rồi vòng mới. Không tạo bài tập trên
     * đồng hồ (không dùng `FD 11`). Huỷ ⇒ `E5 00` và bật lại HR 24h. Đồng hồ không trả lời 3 vòng liền ⇒ lỗi.
     */
    override fun heartRateStream(): Flow<HeartRateSample> {
        if (!supportsHeartRateStream) throw UnsupportedOperationException("Đồng hồ không đo nhịp tim")
        var paused = false
        return channelFlow {
            var last = System.currentTimeMillis()
            val ended = Channel<Unit>(Channel.CONFLATED)
            launch(start = CoroutineStart.UNDISPATCHED) {
                events.collect { p ->
                    val sample = Ute.parseHeartRateStream(p) ?: return@collect
                    last = System.currentTimeMillis()
                    send(sample)
                    if (p.op == 0xE5 && Ute.u(p, 1) == 0x00) ended.trySend(Unit)
                }
            }
            if (features.heartRateByPush && settings.on("hr24.enabled")) {
                writeCommand(bytes(0xF7, 0x02))
                paused = true
            }
            writeCommand(bytes(0xD6, 0x01))
            delay(1_500)
            var silentCycles = 0
            while (true) {
                val cycleStart = System.currentTimeMillis()
                ended.tryReceive()
                writeCommand(bytes(0xE5, 0x11))
                if (withTimeoutOrNull(HR_MANUAL_WINDOW_MS) { ended.receive() } == null) {
                    runCatching { request(bytes(0xE5, 0x00)) { it.op == 0xE5 && it.size >= 4 && Ute.u(it, 1) == 0x00 } }
                        .getOrNull()?.let(Ute::parseHeartRateStream)?.let { last = System.currentTimeMillis(); send(it) }
                }
                silentCycles = if (last >= cycleStart) 0 else silentCycles + 1
                if (silentCycles >= 3) throw GloryFitException("Đồng hồ không gửi nhịp tim")
                delay(300)
            }
        }.onCompletion {
            withContext(NonCancellable) {
                runCatching {
                    if (state.value != ConnectionState.CONNECTED) return@runCatching
                    writeCommand(bytes(0xE5, 0x00))
                    if (paused) configureHeartRate24h()
                }
            }
        }
    }

    /**
     * Phép đo trực tiếp: gửi [prepare] (nếu có) rồi [start], nhận các gói có opcode trong [ops] ([parse] trả về Reading và cờ kết thúc),
     * luôn gửi [stop] khi flow kết thúc.
     */
    private fun live(
        capability: Capability,
        start: ByteArray,
        stop: ByteArray,
        ops: Set<Int>,
        prepare: ByteArray? = null,
        parse: (ByteArray) -> Pair<Reading, Boolean>?,
    ): Flow<Reading> {
        // Chỉ gửi lệnh dừng nếu thiết bị đã phản hồi phép đo này: tránh cắt ngang phép đo người dùng
        // tự bấm trên đồng hồ khi đồng hồ bỏ qua lệnh của app.
        var started = false
        return liveFlow(start, ops, prepare, parse) { started = true }.onCompletion {
            if (started) withContext(NonCancellable) { runCatching { if (state.value == ConnectionState.CONNECTED) writeCommand(stop) } }
        }
    }

    private fun liveFlow(
        start: ByteArray,
        ops: Set<Int>,
        prepare: ByteArray?,
        parse: (ByteArray) -> Pair<Reading, Boolean>?,
        onResponse: () -> Unit,
    ): Flow<Reading> = channelFlow {
        var last = System.currentTimeMillis()
        val listener = launch(start = CoroutineStart.UNDISPATCHED) {
            events.collect { p ->
                if (p.op !in ops) return@collect
                val (reading, done) = parse(p) ?: return@collect
                last = System.currentTimeMillis()
                onResponse()
                send(reading)
                if (done) channel.close()
            }
        }
        val watchdog = launch {
            while (true) {
                delay(1_000)
                if (System.currentTimeMillis() - last > 120_000) channel.close()
            }
        }
        if (prepare != null) {
            writeCommand(prepare)
            delay(1_500)
        }
        writeCommand(start)
        awaitClose()
        listener.cancel()
        watchdog.cancel()
    }

    // ---------- Lịch sử ----------

    /**
     * Đồng bộ lịch sử, chọn lệnh theo bit tính năng ([Ute.SyncPlan], như bản iOS `runHistorySync`): CyWee (Y25) ⇒
     * bước `EB 02 FA` trên 34F1, ngủ `EC 01`; có thuật toán ngủ trên đồng hồ (Y25, HT43) ⇒ ngủ `31 01`.
     * Lệnh mới không có gói nào thì thử lệnh cũ (`B2 FA`, `B3 FA`) và ghi rõ vào log.
     */
    override suspend fun syncHistoryImpl(days: Int, progress: (SyncProgress) -> Unit): DeviceHistory {
        val start = LocalDate.now().minusDays((days.coerceIn(1, 30) - 1).toLong())
        val from = start.atStartOfDay(zone).toInstant().toEpochMilli()
        // Mốc thời gian chỉ gửi khi bật [GloryFitDebug.syncSince] (chưa kiểm hết trên Y25).
        val since = start.takeIf { GloryFitDebug.syncSince }
        val plan = Ute.SyncPlan(features, capabilities.value)
        // F4 `0x2000`: lệnh nhận mốc thời gian ⇒ chỉ lấy từ đầu ngày [since] (SyncDateUtils / `uterkint`); `33F3` chỉ ghi log.
        if (features.syncTimestamp) readDataStatus()?.let { note("33F3 = $it") }
        val series = mutableMapOf<Capability, List<HistoryPoint>>()
        var sleep = emptyList<SleepSession>()
        var workouts = emptyList<com.smartwear.core.Workout>()
        var today: com.smartwear.core.ActivityTotals? = null
        val errors = mutableListOf<String>()

        data class Step(val label: String, val run: suspend () -> Unit)
        val steps = mutableListOf(
            Step("Bước chân") {
                series[Capability.STEPS] = firstResponding(plan.steps, "bước", since) { cmd, packets ->
                    if (cmd == Ute.SyncCommand.STEPS_CYWEE) Ute.parseCyweeSteps(packets, zone) else Ute.parseSteps(packets, zone)
                }
                if (features.cywee) today = Ute.todayTotals(series[Capability.STEPS].orEmpty(), currentHourActivity(), zone)
            },
        )
        if (plan.sleep.isNotEmpty()) steps += Step("Giấc ngủ") {
            sleep = firstResponding(plan.sleep, "ngủ", since) { cmd, packets ->
                when (cmd) {
                    Ute.SyncCommand.SLEEP_RESOLVE, Ute.SyncCommand.SLEEP_CYWEE -> {
                        val sleepDays = Ute.sleepDays(packets, cywee = cmd == Ute.SyncCommand.SLEEP_CYWEE)
                        for (d in sleepDays) if (d.declaredCount != d.sectionCount) {
                            // Byte [6] chưa rõ là số đoạn hay số giấc: chỉ ghi lại để đối chiếu trên đồng hồ thật.
                            note("${cmd.hex} ngày ${d.year}-${d.month}-${d.day}: byte n = ${d.declaredCount}, nhận ${d.sectionCount} đoạn 6 byte")
                        }
                        Ute.parseSleepDays(sleepDays, zone)
                    }
                    else -> Ute.parseSleep(packets, zone, features.sleepHourlyFormat)
                }
            }
        }
        plan.heartRate?.let { cmd ->
            steps += Step("Nhịp tim") {
                val packets = historyStreamSince(cmd, since).packets
                series[Capability.HEART_RATE] =
                    if (cmd == Ute.SyncCommand.HEART_RATE_24H) Ute.parseHeartRate24h(packets, zone) else Ute.parseHeartRate(packets, zone)
            }
        }
        plan.spo2?.let { cmd -> steps += Step("SpO2") { series[Capability.SPO2] = Ute.parseSpo2(historyStreamSince(cmd, since).packets, zone) } }
        // `C8 FA` (Y25 có huyết áp, HT43 không).
        plan.bloodPressure?.let { cmd ->
            steps += Step("Huyết áp") { series[Capability.BLOOD_PRESSURE] = Ute.parseBloodPressure(historyStreamSince(cmd, since).packets, zone) }
        }
        // Bài tập đa môn (chạy, đạp xe, yoga…). F5 0x040000: giờ kết thúc dạng epoch + thời gian tập hiệu quả.
        // F7 0x80 (b1.7 "GPS thể thao"): bản ghi có gói vùng nhịp tim / sải bước và chuỗi mẫu kèm toạ độ GPS.
        steps += Step("Bài tập") {
            workouts = Ute.parseWorkouts(streamWorkouts(since), zone, features.has(5, 0x040000), hasDetail = features.has(7, 0x0080))
        }

        steps.forEachIndexed { i, step ->
            progress(SyncProgress(step.label, i, steps.size))
            runCatching { step.run() }.onFailure { errors += "${step.label}: ${it.message}" }
        }
        return DeviceHistory(
            series = series.mapValues { (_, v) -> v.filter { it.timestamp >= from }.distinctBy { it.timestamp }.sortedBy { it.timestamp } },
            sleep = sleep.filter { it.end >= from },
            workouts = workouts.filter { it.end >= from },
            today = today,
            days = days,
            syncedAt = System.currentTimeMillis(),
            errors = errors,
        )
    }

    /**
     * Thử lần lượt các lệnh trong [commands]: lệnh không có gói nào (kể cả gói kết thúc) hoặc lỗi gửi thì sang lệnh
     * sau. Lệnh cuối không phản hồi thì trả về kết quả rỗng (đồng hồ chưa có dữ liệu).
     */
    private suspend fun <T> firstResponding(
        commands: List<Ute.SyncCommand>, label: String, since: LocalDate?, parse: (Ute.SyncCommand, List<ByteArray>) -> List<T>,
    ): List<T> {
        for ((i, cmd) in commands.withIndex()) {
            val isLast = i == commands.lastIndex
            val r = try {
                historyStreamSince(cmd, since)
            } catch (e: Exception) {
                if (isLast || e is kotlinx.coroutines.CancellationException || state.value != ConnectionState.CONNECTED) throw e
                note("$label: ${cmd.hex} lỗi (${e.message}), thử ${commands[i + 1].hex}")
                continue
            }
            if (r.packets.isEmpty() && !r.ended && !isLast) {
                note("$label: ${cmd.hex} không có gói nào trong 5 s, thử ${commands[i + 1].hex}")
                continue
            }
            val parsed = parse(cmd, r.packets)
            note("$label: dùng ${cmd.hex} → ${r.packets.size} gói${if (r.ended) "" else ", không có gói kết thúc"}, ${parsed.size} mục")
            return parsed
        }
        return emptyList()
    }

    /** Bước/quãng đường/kcal của giờ đang chạy (`EB 01` trên 34F1, CyWee); null nếu đồng hồ không trả lời. */
    private suspend fun currentHourActivity(): ByteArray? = runCatching {
        request(bytes(0xEB, 0x01), ble5 = true) { it.size >= 9 && it.op == 0xEB && Ute.u(it, 1) == 0x01 }
    }.getOrNull()

    /** Ghi chú đồng bộ vào log SDK (lệnh nào được dùng, lệnh nào bị bỏ qua). */
    private fun note(message: String) = SmartWearLog.i("[$name] đồng bộ $message")

    // ---------- Cài đặt ----------

    private fun saveSettings(s: UteSettings) {
        settings = s
        prefs.edit().putString("settings_$id", s.encode()).apply()
        _controls.value = UteControls.controls(features, s, read = readState)
    }

    override suspend fun setControl(id: String, value: ControlValue) {
        saveSettings(settings.with(id, value))
        if (state.value != ConnectionState.CONNECTED) return
        for (cmd in UteControls.commands(id, features, settings)) {
            when (cmd.op) {
                // A9/A0 có phản hồi cùng opcode; lệnh khác đồng hồ không trả lời.
                0xA9, 0xA0 -> request(cmd) { it.op == cmd.op }
                else -> writeCommand(cmd)
            }
        }
        if (id.startsWith("hr24")) hr24Configured = settings.on("hr24.enabled")
    }

    override suspend fun runAction(id: String) {
        if (state.value != ConnectionState.CONNECTED) throw GloryFitException("Đồng hồ chưa kết nối")
        when (id) {
            "find.start" -> writeCommand(UteControls.FIND_WATCH)
            "device.read" -> readDeviceState()
            "contacts.clear" -> clearContacts()
            // App phải hỏi người dùng trước (`DeviceControl.confirm`). Đồng hồ không trả gói (ack qua write callback, `uterktry.java:688`).
            "data.reset" -> {
                SmartWearLog.w("[$name] gửi AD: xoá dữ liệu / khôi phục gốc")
                writeCommand(Ute.FACTORY_RESET)
            }
            else -> throw GloryFitException("Không có hành động $id")
        }
    }

    /**
     * Đọc (không ghi gì) ngôn ngữ đang dùng `AF AA` (F3 `0x20`) và phím tắt nhanh `BE 01` / `BE 02` (F4 `0x10000`), rồi dựng
     * lại [controls]. Ngôn ngữ đọc được không ghi đè lựa chọn đã lưu, chỉ hiện ở dòng mô tả.
     */
    private suspend fun readDeviceState() {
        var r = readState
        if (with(UteControls) { features.readLanguage() }) {
            runCatching { request(UteControls.LANGUAGE_QUERY) { it.op == 0xAF && it.size >= 3 && Ute.u(it, 1) == 0xAA } }
                .onSuccess { p ->
                    r = r.copy(language = UteControls.parseLanguage(p))
                    SmartWearLog.i("[$name] AF AA: ngôn ngữ ${r.language}, mặt nạ ${UteControls.parseLanguageMasks(p)?.joinToString { "%06X".format(it) }}")
                }
                .onFailure { SmartWearLog.w("[$name] AF AA không có phản hồi") }
        }
        if (with(UteControls) { features.shortcuts() }) {
            for (sub in 1..2) {
                runCatching { request(if (sub == 1) UteControls.SHORTCUT_SUPPORT else UteControls.SHORTCUT_STATUS) { it.op == 0xBE && it.size >= 2 && Ute.u(it, 1) == sub } }
                    .onSuccess { p ->
                        val mask = UteControls.parseShortcuts(p, sub)
                        SmartWearLog.i("[$name] BE %02X = ${p.toHex()} → ${mask?.let { "%06X".format(it) }}".format(sub))
                        r = if (sub == 1) r.copy(shortcutSupport = mask) else r.copy(shortcutStatus = mask)
                    }
                    .onFailure { SmartWearLog.w("[$name] BE %02X không có phản hồi".format(sub)) }
            }
        }
        readState = r
        _controls.value = UteControls.controls(features, settings, read = r)
    }

    /**
     * Đọc `33F3` (trạng thái dữ liệu chưa đồng bộ, F4 `0x2000`); null nếu đồng hồ không có characteristic hoặc đọc lỗi.
     * Ý nghĩa bit là suy luận ([Ute.DataStatus]).
     */
    suspend fun readDataStatus(): Ute.DataStatus? {
        if (!features.syncTimestamp) return null
        val service = if (gatt.hasCharacteristic(Ute.SERVICE, Ute.DATA_STATUS)) Ute.SERVICE else gatt.serviceOf(Ute.DATA_STATUS) ?: return null
        return runCatching { gatt.read(service, Ute.DATA_STATUS) }
            .onFailure { SmartWearLog.w("[$name] đọc 33F3 lỗi: ${it.message}") }
            .getOrNull()?.let { Ute.DataStatus(it) }
    }

    // ---------- Thời tiết ----------

    override val supportsWeather: Boolean get() = UteWeather.supported(features)

    /** Gửi `CB 01/02/03` (xem [UteWeather]); gói sau đi sau khi đồng hồ trả lời gói trước, không trả lời trong 3 s vẫn gửi tiếp. */
    override suspend fun setWeather(forecast: WeatherForecast) {
        if (state.value != ConnectionState.CONNECTED) throw GloryFitException("Đồng hồ chưa kết nối")
        if (!supportsWeather) throw GloryFitException("Đồng hồ không hỗ trợ thời tiết 7 ngày")
        val ble5 = UteWeather.ble5(features)
        for (p in UteWeather.packets(features, forecast)) {
            runCatching { request(p, ble5 = ble5) { it.op == 0xCB } }
                .onSuccess { SmartWearLog.i("[$name] thời tiết ${p[1]} → ${it.toHex()}") }
                .onFailure { SmartWearLog.w("[$name] thời tiết ${p[1]}: ${it.message}") }
        }
    }

    // ---------- Gọi điện (Bluetooth 3.0) và danh bạ ----------

    /** `isHasBluetooth3` (33F1 b2.2 = F6 `0x40000`): đồng hồ gọi điện qua Bluetooth cổ điển (HFP). */
    val supportsCallBluetooth: Boolean get() = features.has(6, 0x040000)

    /** Đã hỏi ghép đôi hệ thống trong phiên này (xem [GloryFitDriver.bondOnConnect]). */
    @Volatile private var bondAsked = false
    override val supportsContacts: Boolean get() = UteContacts.supported(features)
    /** Số liên hệ tối đa đồng hồ nhận. */
    override val maxContacts: Int get() = UteContacts.maxContacts(features)
    override val supportsClearContacts: Boolean get() = UteContacts.clearSupported(features)

    override val supportsCallAudio: Boolean get() = supportsCallBluetooth

    /** [callBluetoothState] với cờ ghép lấy theo Android ([isCallBluetoothBonded]); cờ của Y25 không đáng tin. */
    override suspend fun callAudioState(): CallAudioState {
        val s = callBluetoothState()
        return CallAudioState(s.name, s.address, s.enabled, paired = isCallBluetoothBonded(s.address), connected = s.connected)
    }

    override suspend fun pairCallAudio(): Boolean = pairCallBluetooth()

    override suspend fun setCallAudio(on: Boolean) = setCallBluetooth(on)

    /**
     * `38 01 02 00 r0..r3` (34F1) → `38 01 tên(20) MAC(6) bật ghép kết-nối`. Lưu ý: trên Y25 cờ ghép/kết nối không đáng
     * tin (gọi vẫn được khi báo `00 00`), nên chỉ dùng tên + MAC để ghép.
     */
    suspend fun callBluetoothState(): UteContacts.CallBluetoothState {
        if (state.value != ConnectionState.CONNECTED) throw GloryFitException("Đồng hồ chưa kết nối")
        val nonce = ByteArray(4).also { java.security.SecureRandom().nextBytes(it) }
        val p = request(byteArrayOf(0x38, 0x01, 0x02, 0x00) + nonce, timeoutMs = 4_000, ble5 = true) {
            it.size >= 31 && it.op == 0x38 && Ute.u(it, 1) == 0x01
        }
        return UteContacts.parseCallBluetooth(p) ?: throw GloryFitException("Phản hồi 38 01 không hợp lệ: ${p.toHex()}")
    }

    /** `38 02 01/00`: bật/tắt kênh gọi điện trên đồng hồ (`openDeviceBt3`). */
    suspend fun setCallBluetooth(on: Boolean) {
        if (state.value != ConnectionState.CONNECTED) throw GloryFitException("Đồng hồ chưa kết nối")
        writeCommand(byteArrayOf(0x38, 0x02, if (on) 1 else 0))
    }

    /**
     * Ghép kênh gọi điện (Bluetooth cổ điển) ngay trong app, như GloryFitPro Android (`START_PAIRING_BT3_ACTION`):
     * bật kênh trên đồng hồ rồi `createBond` theo MAC đồng hồ báo. Android hiện hộp thoại xác nhận ghép đôi.
     * Trả về false nếu đã ghép sẵn.
     */
    @android.annotation.SuppressLint("MissingPermission")
    suspend fun pairCallBluetooth(): Boolean {
        val st = callBluetoothState()
        if (!st.enabled) setCallBluetooth(true)
        val adapter = appContext.getSystemService(android.bluetooth.BluetoothManager::class.java).adapter
        val dev = adapter.getRemoteDevice(st.address)
        if (dev.bondState == android.bluetooth.BluetoothDevice.BOND_BONDED) return false
        SmartWearLog.i("[$name] ghép kênh gọi ${st.name} ${st.address}")
        if (!dev.createBond()) throw GloryFitException("Android từ chối ghép ${st.address}")
        return true
    }

    /** Ghép kênh gọi đã xong chưa (theo Android, đáng tin hơn cờ của đồng hồ). */
    @android.annotation.SuppressLint("MissingPermission")
    fun isCallBluetoothBonded(address: String): Boolean = runCatching {
        appContext.getSystemService(android.bluetooth.BluetoothManager::class.java).adapter.getRemoteDevice(address).bondState ==
            android.bluetooth.BluetoothDevice.BOND_BONDED
    }.getOrDefault(false)

    override suspend fun syncContacts(contacts: List<com.smartwear.core.Contact>, progress: (Float) -> Unit): Int =
        syncContacts(contacts.map { UteContacts.Contact(it.name, it.phone) }, progress)

    /** Ghi danh bạ lên đồng hồ (thay toàn bộ danh bạ cũ), xem [UteContacts]. Trả về số liên hệ đã gửi. */
    @JvmName("syncUteContacts")
    suspend fun syncContacts(contacts: List<UteContacts.Contact>, progress: (Float) -> Unit = {}): Int {
        if (state.value != ConnectionState.CONNECTED) throw GloryFitException("Đồng hồ chưa kết nối")
        if (!supportsContacts) throw GloryFitException("Đồng hồ không hỗ trợ danh bạ")
        val list = contacts.filter { UteContacts.cleanPhone(it.phone).isNotEmpty() }.take(UteContacts.maxContacts(features))
        val length = minOf(features.maxPacketLength ?: 20, gatt.mtu - 3).coerceAtLeast(20)
        val segments = UteContacts.segments(list, features, length)
        request(byteArrayOf(0x37, 0xFA.toByte(), list.size.toByte()), timeoutMs = 5_000, ble5 = true) { it.size >= 2 && it.op == 0x37 && Ute.u(it, 1) == 0xFA }
        segments.forEachIndexed { i, seg ->
            request(seg, timeoutMs = 5_000, ble5 = true) { it.size >= 2 && it.op == 0x37 && Ute.u(it, 1) == 0xFB }
            progress((i + 1f) / segments.size)
        }
        request(byteArrayOf(0x37, 0xFC.toByte(), 0xFD.toByte()), timeoutMs = 5_000, ble5 = true) { it.size >= 2 && it.op == 0x37 && Ute.u(it, 1) == 0xFC }
        SmartWearLog.i("[$name] đã ghi ${list.size} liên hệ (${segments.size} gói)")
        return list.size
    }

    /** `37 BA` (34F1) → `37 BA`: xoá toàn bộ danh bạ trên đồng hồ ([UteContacts.CLEAR]). */
    override suspend fun clearContacts() {
        if (state.value != ConnectionState.CONNECTED) throw GloryFitException("Đồng hồ chưa kết nối")
        if (!supportsClearContacts) throw GloryFitException("Đồng hồ không xoá được danh bạ")
        request(UteContacts.CLEAR, timeoutMs = 5_000, ble5 = true) { it.size >= 2 && it.op == 0x37 && Ute.u(it, 1) == 0xBA }
        SmartWearLog.i("[$name] đã xoá danh bạ trên đồng hồ")
    }

    // ---------- Thông báo, cuộc gọi đến (UteNotify) ----------

    private val _remindDisplay = MutableStateFlow<IntArray?>(null)

    /** 5 mặt nạ icon thông báo đồng hồ hiển thị được (`DB AA`, đọc lúc kết nối); null = chưa đọc / đồng hồ không có F5 `0x800`. */
    val remindDisplay: StateFlow<IntArray?> = _remindDisplay.asStateFlow()

    /** Từ chối cuộc gọi trên đồng hồ (`isHasHangup`, F1 `0x400000`). */
    override val supportsRejectCall: Boolean get() = UteNotify.hangup(features)

    /** Báo cuộc gọi đến (`C5` loại 0) có ở mọi đồng hồ UTE. */
    override val supportsIncomingCall: Boolean get() = true

    /** Người dùng bật "từ chối cuộc gọi từ đồng hồ" (bit 3 của `D7`, khoá `dnd.endCall`). */
    override val rejectCallEnabled: Boolean get() = settings.on("dnd.endCall")

    override suspend fun setRejectCallEnabled(enabled: Boolean) = setControl("dnd.endCall", ControlValue.Bool(enabled))

    /** Thông báo app (`isHasSocialNotification` F2 `0x40` hoặc `isHasSocialNotification2` F3 `0x800`). */
    override val supportsNotifications: Boolean get() = features.has(2, 0x000040) || features.has(3, 0x000800)

    /** [UteNotify.APPS] (thứ tự `appRemindDynamicDisplayEn`); [NotificationApp.hasIcon] theo mặt nạ `DB AA` đọc lúc kết nối. */
    override fun notificationApps(): List<NotificationApp> {
        val masks = _remindDisplay.value
        return UteNotify.APPS.map { NotificationApp(it.key, it.name, it.packages, UteNotify.displayed(it, masks)) }
    }

    /**
     * Thông báo của app [appKey]: loại theo [UteNotify.APPS] (key lạ = loại 4 "khác"), nội dung theo [UteNotify.appContent]
     * (`NotificationPresenter.sendMessage` của Pro, cần [ticker]), rồi [sendAppNotification].
     */
    override suspend fun sendNotification(appKey: String, title: String, text: String, ticker: String?): Boolean {
        val app = UteNotify.APPS.firstOrNull { it.key == appKey }
        val type = app?.type ?: UteNotify.TYPE_OTHERS
        val content = UteNotify.appContent(app?.packages?.first().orEmpty(), type, title, text, ticker.orEmpty(), android.os.Build.VERSION.SDK_INT)
        if (content.isEmpty()) return false
        return sendAppNotification(type, content)
    }

    override suspend fun sendSms(sender: String, text: String): Boolean = sendSmsNotification(sender, text)

    /**
     * Đang trong khung "không làm phiền theo giờ" của app ⇒ không đẩy thông báo app/SMS (GloryFitPro
     * `StatusbarMsgNotificationListener.java:150-158` kiểm cùng khung giờ với lệnh `D7`). Cuộc gọi không kiểm.
     */
    fun inQuietHours(now: LocalTime): Boolean =
        settings.on("dnd.scheduled") && UteNotify.inQuietHours(settings["dnd.range.from"], settings["dnd.range.to"], now.hour * 60 + now.minute)

    override fun inQuietHours(): Boolean = inQuietHours(LocalTime.now())

    /**
     * Đẩy thông báo app [text] loại [type] ([UteNotify.appType], `RemindType.java`) bằng `C5`
     * (`UteBleConnectionRkImpl.appRemind` → `T:3509-3535`). Trả về false nếu chưa kết nối / chữ rỗng / đồng hồ không trả lời.
     */
    suspend fun sendAppNotification(type: Int, text: String): Boolean = push(type, text, sender = null, number = null)

    /**
     * Tin SMS: `C5` loại 3 với [text], rồi `C6` tên người gửi [sender] nếu đồng hồ có F7 `0x800`/`0x2000`
     * (`smsRemind(contact, content)`, `T:5026-5029`; luồng `C6` theo GloryFit `BluetoothLeService.java:3813-3876`).
     * Như Pro, không gửi số `45 FA` cho SMS (`smsRemind` 2 tham số xoá số đã lưu).
     */
    suspend fun sendSmsNotification(sender: String, text: String): Boolean = push(UteNotify.TYPE_SMS, text, sender = sender, number = null)

    /**
     * Cuộc gọi đến: `C5` loại 0 với [name] (tên trong danh bạ, không có thì số), rồi `45 FA len <số>` lên 34F1 nếu đồng hồ
     * có F6 `0x200` (`callRemind(contact, number)`, `uterkdo/uterkfor.java:1893-1896`; `uterkfinal.java:566-576`).
     */
    override suspend fun incomingCall(name: String, number: String?): Boolean = push(UteNotify.TYPE_CALL, name, sender = null, number = number)

    /** Màn cuộc gọi trên đồng hồ tắt (nghe máy, cúp máy, gọi nhỡ): `C1 04` (`callerInterfaceDisappears`, `T:1241-1244`). */
    override suspend fun callEnded() {
        if (state.value != ConnectionState.CONNECTED) return
        runCatching { writeCommand(UteNotify.CALL_END) }
    }

    /**
     * Người dùng bấm từ chối cuộc gọi trên đồng hồ: `D1 02` (`uterkchar.java:150-152` → `onCallRemindStatus(1004)` →
     * `UteBleConnectionRkImpl.incomingCallReject` → `EndCallUtil.endCall`). Chỉ phát khi [rejectCallEnabled] (như `EndCallUtil`).
     */
    override val rejectCallRequests: Flow<Unit> = events
        .filter { it.size >= 2 && it.op == 0xD1 && Ute.u(it, 1) == 0x02 }
        .filter { rejectCallEnabled.also { on -> if (!on) SmartWearLog.i("[$name] từ chối cuộc gọi: công tắc đang tắt") } }
        .map { }

    /**
     * Gửi `C5` (và `C6`, `45 FA`) theo lượt: mỗi gói chờ đồng hồ trả lời (xem [UteNotify]). Giữ [lock] cả lượt để
     * gói của lệnh khác không chen vào giữa.
     */
    private suspend fun push(type: Int, text: String, sender: String?, number: String?): Boolean {
        if (state.value != ConnectionState.CONNECTED) return false
        val payload = UteNotify.payload(type, text, features) ?: return false
        return lock.withLock {
            val channel = Channel<ByteArray>(Channel.UNLIMITED)
            waiter = Waiter({ it.op == 0xC5 || it.op == 0xC6 }, channel)
            try {
                val done = sendSections(0xC5, UteNotify.sections(0xC5, payload, UteNotify.messageCap(features)), channel)
                    ?: return@withLock false
                SmartWearLog.i("[$name] thông báo loại $type xong (C5 FD %02X)".format(done and 0xFF))
                if (type == UteNotify.TYPE_SMS && sender != null && UteNotify.smsSender(features)) {
                    sendSections(0xC6, UteNotify.sections(0xC6, UteNotify.senderPayload(sender, features), UteNotify.SENDER_CAP), channel)
                }
                if ((type == UteNotify.TYPE_CALL || type == UteNotify.TYPE_SMS) && UteNotify.smsReply(features) && !number.isNullOrEmpty() &&
                    gatt.hasCharacteristic(Ute.SERVICE5, Ute.WRITE5)
                ) {
                    val p = UteNotify.phoneNumber(number)
                    onPacketSent(p)
                    write5(p)
                }
                true
            } catch (e: Exception) {
                if (e is kotlinx.coroutines.CancellationException) throw e
                SmartWearLog.w("[$name] gửi thông báo lỗi: ${e.message}")
                false
            } finally {
                waiter = null
            }
        }
    }

    /**
     * Gửi các gói [packets] của lệnh [op] (`C5`/`C6`): đồng hồ trả `op seq` ⇒ gói sau; `op FF` ⇒ gửi lại từ gói 0
     * (bản gốc không giới hạn số lần, ở đây tối đa 3); gửi hết thì `op FD`; đồng hồ trả `op FD loại` ⇒ trả về loại.
     * Null nếu đồng hồ im lặng quá [PUSH_ACK_MS] (GloryFit cũ: 10 s cho cả tin, `WriteCommandToBLE.sendTextToBle`).
     */
    private suspend fun sendSections(op: Int, packets: List<ByteArray>, channel: Channel<ByteArray>): Int? {
        var i = 0
        var resends = 0
        repeat(packets.size + 8) {
            writeCommand(if (i < packets.size) packets[i] else UteNotify.end(op))
            val r = withTimeoutOrNull(PUSH_ACK_MS) {
                var p: ByteArray
                do { p = channel.receive() } while (p.op != op || p.size < 2)
                p
            } ?: run {
                SmartWearLog.w("[$name] %02X: đồng hồ không trả lời gói %d/%d".format(op, i, packets.size))
                return null
            }
            when (Ute.u(r, 1)) {
                0xFD -> return if (r.size >= 3) Ute.u(r, 2) else 0
                0xFF -> {
                    if (++resends > 3) return null
                    i = 0
                }
                else -> i++
            }
        }
        return null
    }

    // ---------- Nhạc (UteMusic) ----------

    /** Đồng hồ có màn điều khiển nhạc điện thoại (F5 `0x1`). */
    override val supportsMusicControl: Boolean get() = UteMusic.control(features)

    /** Đồng hồ hiện tên bài (F5 `0x1000`). */
    override val supportsTrackInfo: Boolean get() = UteMusic.songInfo(features)

    /** Lệnh nhạc người dùng bấm trên đồng hồ (`D1 07/08/09/0D/0E`). App điều khiển trình phát và âm lượng điện thoại. */
    override val musicCommands: Flow<MusicCommand> = events.mapNotNull(UteMusic::parseCommand)

    private val musicLock = Mutex()

    /**
     * Trạng thái + bài đang phát lên đồng hồ. F5 `0x1000`: `3A 01/06/04` lên 34F1 cách nhau 100 ms rồi `3A FA`, đồng hồ trả
     * `3A FA xor` (so với [UteMusic.checksum], chỉ ghi log). Không có F5 `0x1000`: `D1 0C 01/02` (GloryFit `controlBandMusic`).
     * GloryFitPro chỉ gửi playing + title (`SearchDeviceModelImpl.java:235-238`); các trường khác null = `FF`.
     * [MusicState.durationSec]/[MusicState.positionSec] chưa gửi: đơn vị của `total`/`cur` trong `3A 01` chưa xác định.
     */
    override suspend fun setMusicState(state: MusicState) {
        if (this.state.value != ConnectionState.CONNECTED) return
        musicLock.withLock {
            if (UteMusic.songInfo(features) && gatt.hasCharacteristic(Ute.SERVICE5, Ute.WRITE5)) {
                val packets = UteMusic.songPackets(state.playing, state.title, state.artist, state.volumePercent, null, null, null)
                packets.forEachIndexed { i, p ->
                    if (i > 0) delay(100)
                    onPacketSent(p)
                    write5(p)
                }
                delay(100)
                val expect = UteMusic.checksum(packets)
                runCatching { request(UteMusic.SONG_END, ble5 = true) { it.op == 0x3A && it.size >= 3 && Ute.u(it, 1) == 0xFA } }
                    .onSuccess { if (Ute.u(it, 2) != expect) SmartWearLog.w("[$name] 3A FA: đồng hồ báo %02X, app tính %02X".format(Ute.u(it, 2), expect)) }
                    .onFailure { SmartWearLog.w("[$name] 3A FA không có phản hồi") }
            } else if (UteMusic.control(features)) {
                runCatching { writeCommand(UteMusic.playState(state.playing)) }
            }
        }
    }

    @Volatile
    private var lastVolume = 0

    /**
     * Âm lượng điện thoại lên đồng hồ: `D1 0D pct` khi tăng / bằng lần gửi trước, `D1 0E pct` khi giảm (như
     * `SearchDeviceModelImpl.java:225-230`, so với lần trước). Không phản hồi.
     */
    override suspend fun setMusicVolume(percent: Int) {
        val up = lastVolume <= percent
        lastVolume = percent
        if (state.value != ConnectionState.CONNECTED || !UteMusic.control(features)) return
        runCatching { writeCommand(UteMusic.volume(percent, up)) }
    }

    // ---------- Trả lời SMS nhanh (UteSmsReply) ----------

    /**
     * Cấu hình trả lời SMS nhanh lưu theo thiết bị (như `SPDao.getSmsReplySwitch` + `SmsReplyInfoDao` của Pro).
     * Danh sách mẫu = toàn bộ danh sách gửi đồng hồ; chưa cấu hình thì là [UteSmsReply.FIXED_TEMPLATES] như app gốc.
     */
    private val _smsReply = MutableStateFlow(
        SmsReplyConfig(
            enabled = prefs.getBoolean("smsReply_${scanned.address}", false),
            templates = prefs.getString("smsReplyTemplates_${scanned.address}", null)?.split('\u0001')?.filter { it.isNotEmpty() }
                ?: UteSmsReply.FIXED_TEMPLATES,
        ),
    )
    override val smsReply: StateFlow<SmsReplyConfig> = _smsReply.asStateFlow()

    /** F6 `0x200` (`RkSupportUtils.isSupSmsReply`). */
    override val supportsSmsReply: Boolean get() = UteSmsReply.supported(features)

    override val smsReplyFixedTemplates: List<String> get() = UteSmsReply.FIXED_TEMPLATES

    override val smsReplyMaxCustom: Int get() = UteSmsReply.MAX_CUSTOM

    /** Lưu và gửi xuống đồng hồ (nếu đang kết nối): `52 en`, rồi danh sách mẫu [templates] (đủ cả mẫu cố định, theo thứ tự gửi). */
    override suspend fun setSmsReply(enabled: Boolean, templates: List<String>) {
        val config = SmsReplyConfig(enabled, templates.map { it.trim() }.filter { it.isNotEmpty() })
        _smsReply.value = config
        prefs.edit()
            .putBoolean("smsReply_$id", config.enabled)
            .putString("smsReplyTemplates_$id", config.templates.joinToString("\u0001"))
            .apply()
        if (state.value == ConnectionState.CONNECTED && supportsSmsReply) syncSmsReply()
    }

    /** `52 01/00` (chờ `52 xx FD`), rồi mẫu `46 FA …` từng cái (chờ `46 FA`), cuối `46 FD 00` (chờ `46 FD`). */
    private suspend fun syncSmsReply() {
        val config = _smsReply.value
        runCatching { request(UteSmsReply.enable(config.enabled), match = UteSmsReply::isEnableAck) }
            .onFailure { SmartWearLog.w("[$name] 52 không có phản hồi") }
        if (!gatt.hasCharacteristic(Ute.SERVICE5, Ute.WRITE5)) return
        if (config.templates.isEmpty()) {
            onPacketSent(UteSmsReply.TEMPLATES_EMPTY)
            write5(UteSmsReply.TEMPLATES_EMPTY)
            return
        }
        config.templates.forEachIndexed { i, t ->
            request(UteSmsReply.template(t, i, config.templates.size), ble5 = true) { it.op == 0x46 && it.size >= 2 && Ute.u(it, 1) == 0xFA }
        }
        request(UteSmsReply.TEMPLATES_END, ble5 = true) { it.op == 0x46 && it.size >= 2 && Ute.u(it, 1) in setOf(0xFB, 0xFD) }
        SmartWearLog.i("[$name] đã gửi ${config.templates.size} mẫu trả lời SMS")
    }

    /** Đồng hồ yêu cầu gửi SMS (`52 nLen số cLen nội dung`). App gửi rồi gọi [sendSmsReplyResult]. */
    override val smsReplyRequests: Flow<SmsReplyRequest> =
        events.mapNotNull { p -> UteSmsReply.parseRequest(p)?.let { SmsReplyRequest(it.number, it.text) } }

    /** Báo kết quả gửi SMS: `52 FE` thành công / `52 FF` lỗi. */
    override suspend fun sendSmsReplyResult(ok: Boolean) {
        if (state.value != ConnectionState.CONNECTED) return
        runCatching { writeCommand(UteSmsReply.result(ok)) }
    }

    // ---------- Chụp ảnh từ xa ----------

    /** Chụp ảnh từ xa không cần bit riêng; chỉ ẩn khi đồng hồ bật "ẩn chụp ảnh" (F12 `0x2000`), như bản iOS. */
    override val supportsRemoteCamera: Boolean get() = !features.has(12, 0x002000)

    override val remoteCameraEvents: SharedFlow<RemoteCameraEvent> = _remoteCamera.asSharedFlow()

    /**
     * `C4 01` / `C4 03`: app mở / đóng màn chụp (`openDeviceCameraMode`, `T:1575-1591`; GloryFitPro `CameraActivity`
     * gửi `C4 01` trong `onCreate` khi có quyền camera, `C4 03` trong `onDestroy`). Đồng hồ không trả gói (ack qua write callback).
     */
    override suspend fun setRemoteCamera(open: Boolean) {
        if (state.value != ConnectionState.CONNECTED) return
        runCatching { writeCommand(byteArrayOf(0xC4.toByte(), if (open) 0x01 else 0x03)) }
    }

    // ---------- Mặt đồng hồ ----------

    private var dialParams: Ute.DialParams? = null
    private val renderer = WatchFaceRenderer()

    override val supportsWatchFace: Boolean get() = true

    /** `isHasSwitchDialOnline` (33F1 b12.0 = F3 `0x100`): mặt online trong khe, xem `26 09` / xoá `26 08`. */
    override val supportsWatchFaceSlots: Boolean get() = features.has(3, 0x000100)

    override suspend fun watchFaceInfo(): WatchFaceInfo {
        val spec = watchFaceSpec()
        val p = dialParams ?: queryDialParams().also { dialParams = it }
        return WatchFaceInfo(spec.width, spec.height, spec.round, spec.maxBytes, p.currentId, p.slots, customActive = p.currentId == CUSTOM_FACE_ID)
    }

    override suspend fun installWatchFace(file: ByteArray, progress: (Float) -> Unit) = installWatchFaceFile(file, progress)

    /**
     * Khe mặt đồng hồ: `26 09` như GloryFitPro (`queryAllWatchFaceInfo`, nhiều gói tới `26 09 FD`); đồng hồ không trả lời thì
     * thử `26 05 00` (một gói). Mỗi mục `[khe][mã 4 byte]` ([Ute.parseDialSlots]).
     */
    override suspend fun watchFaceSlots(): List<WatchFaceSlot> {
        if (state.value != ConnectionState.CONNECTED) throw GloryFitException("Đồng hồ chưa kết nối")
        val packets = collect(Ute.DIAL_SLOTS_ALL, ble5 = false, idleMs = 3_000, match = { it.op == 0x26 && it.size >= 3 && Ute.u(it, 1) == 0x09 }) {
            Ute.u(it, 2) == 0xFD
        }
        if (packets.isNotEmpty()) return Ute.parseDialSlotPackets(packets)
        SmartWearLog.i("[$name] 26 09 không có phản hồi, thử 26 05 00")
        val p = request(Ute.dialSlotsQuery(0)) { it.op == 0x26 && it.size >= 2 && Ute.u(it, 1) == 0x05 }
        return Ute.parseDialSlots(p.copyOfRange(2, p.size))
    }

    /** `26 08 khe` → `26 08 khe max st` (st 1 = đã xoá, 0 = lỗi, khác = không có mặt để xoá). */
    override suspend fun deleteWatchFaceSlot(index: Int) {
        if (state.value != ConnectionState.CONNECTED) throw GloryFitException("Đồng hồ chưa kết nối")
        val p = request(Ute.dialSlotDelete(index), timeoutMs = 5_000) { it.op == 0x26 && it.size >= 5 && Ute.u(it, 1) == 0x08 }
        SmartWearLog.i("[$name] xoá khe $index: ${p.toHex()}")
        when (Ute.parseDialDelete(p)) {
            1 -> Unit
            0 -> throw GloryFitException("Đồng hồ báo xoá khe $index lỗi")
            else -> throw GloryFitException("Không có mặt đồng hồ nào để xoá ở khe $index")
        }
    }

    // ---------- Bài tập từ điện thoại (UteWorkout) ----------

    override val supportsWorkoutControl: Boolean get() = UteWorkout.control(features)
    override val supportsSportList: Boolean get() = UteWorkout.sportList(features)
    override val supportsPhoneLocation: Boolean get() = UteWorkout.sportGps(features)

    /** Số môn hiện tối thiểu..tối đa đọc kèm [sportTypes] (gói cuối `FD 48 AA FD`); null = chưa đọc. */
    @Volatile override var sportListLimits: IntRange? = null
        private set

    override val sportCatalog: List<SportName>
        get() = UteSportCatalog.NAMES.map { (type, n) -> SportName(type, n.first, n.second) }

    /** Bài tập đang chạy (theo lệnh app và gói `FD 04`/xác nhận của đồng hồ): môn, thời gian tập đã tích luỹ. */
    @Volatile private var workoutType: Int? = null
    @Volatile private var workoutActiveMs = 0L
    @Volatile private var workoutResumedAt: Long? = null
    /** Số liệu điện thoại tự tính gần nhất ([sendWorkoutData]) ⇒ tạm dừng / tiếp tục dùng gói chế độ GPS như app gốc. */
    @Volatile private var lastWorkoutData: WorkoutData? = null
    /** Đã báo `FD 01 01` cho lần xin vị trí hiện tại; điểm gửi trước để tính quãng đường giữa hai điểm. */
    @Volatile private var locationAnnounced = false
    @Volatile private var lastFix: Pair<Double, Double>? = null
    @Volatile private var totalMeters = 0

    init {
        // Theo dõi bài tập theo gói của đồng hồ: người dùng bắt đầu / tạm dừng / dừng trên đồng hồ (`FD 04`) hoặc xác nhận lệnh
        // app; đồng hồ xin vị trí lại ⇒ lần gửi vị trí sau báo `FD 01 01` trước.
        scope.launch {
            events.collect { p ->
                when (val w = UteWorkout.parse(p)) {
                    is UteWorkout.Parsed.Event -> (w.event as? WorkoutEvent.State)?.let { trackWorkout(it.sportType, it.state) }
                    is UteWorkout.Parsed.Location -> {
                        locationAnnounced = false
                        if (w.request.start) {
                            lastFix = null
                            totalMeters = 0
                        }
                    }
                    else -> Unit
                }
            }
        }
    }

    private fun trackWorkout(type: Int, st: WorkoutState) {
        val now = System.currentTimeMillis()
        when (st) {
            WorkoutState.STARTED, WorkoutState.RESUMED -> {
                if (workoutType != type) {
                    workoutType = type
                    workoutActiveMs = 0
                    workoutResumedAt = null
                    lastWorkoutData = null
                }
                if (workoutResumedAt == null) workoutResumedAt = now
            }
            WorkoutState.PAUSED -> {
                workoutType = type
                workoutResumedAt?.let { workoutActiveMs += now - it }
                workoutResumedAt = null
            }
            WorkoutState.STOPPED -> {
                workoutType = null
                workoutResumedAt = null
                workoutActiveMs = 0
                lastWorkoutData = null
            }
        }
    }

    private fun workoutSeconds(): Int =
        ((workoutActiveMs + (workoutResumedAt?.let { System.currentTimeMillis() - it } ?: 0L)) / 1000).toInt()

    private fun requireWorkout(): Int {
        if (state.value != ConnectionState.CONNECTED) throw GloryFitException("Đồng hồ chưa kết nối")
        if (!supportsWorkoutControl) throw GloryFitException("Đồng hồ không điều khiển bài tập từ app được")
        return workoutType ?: throw GloryFitException("Không có bài tập đang chạy")
    }

    /** `FD 11 type 01` (33F1): bắt đầu bài tập môn [sportType] ([Ute.sportName]). Đồng hồ trả `FD 11 type …`. */
    override suspend fun startWorkout(sportType: Int) {
        if (state.value != ConnectionState.CONNECTED) throw GloryFitException("Đồng hồ chưa kết nối")
        if (!supportsWorkoutControl) throw GloryFitException("Đồng hồ không điều khiển bài tập từ app được")
        trackWorkout(sportType, WorkoutState.STOPPED)
        trackWorkout(sportType, WorkoutState.STARTED)
        locationAnnounced = false
        lastFix = null
        totalMeters = 0
        writeCommand(UteWorkout.start(sportType))
    }

    /** `FD 22 type 01 h m s [số liệu GPS]`: tạm dừng, kèm thời gian tập app đếm. */
    override suspend fun pauseWorkout() {
        val type = requireWorkout()
        val sec = workoutSeconds()
        trackWorkout(type, WorkoutState.PAUSED)
        writeCommand(UteWorkout.control(UteWorkout.OP_PAUSE, type, 1, sec, lastWorkoutData, UteWorkout.dataWithSteps(features)))
    }

    /** `FD 33 type 01 h m s [số liệu GPS]`: tiếp tục. */
    override suspend fun resumeWorkout() {
        val type = requireWorkout()
        writeCommand(UteWorkout.control(UteWorkout.OP_RESUME, type, 1, workoutSeconds(), lastWorkoutData, UteWorkout.dataWithSteps(features)))
        trackWorkout(type, WorkoutState.RESUMED)
    }

    /** `FD 00 type 01`: dừng (đồng hồ lưu bài, lấy lại bằng [syncHistory]). */
    override suspend fun stopWorkout() {
        val type = requireWorkout()
        writeCommand(UteWorkout.stop(type))
        trackWorkout(type, WorkoutState.STOPPED)
        if (locationAnnounced) runCatching { writeBle5(UteWorkout.LOCATION_STOP) }
        locationAnnounced = false
    }

    /** `FD AA` → `FD AA st type` (4 byte): bài tập đang chạy / tạm dừng / không có (riêng GloryFit, như bản iOS). */
    suspend fun queryWorkout(): WorkoutEvent.State? {
        if (state.value != ConnectionState.CONNECTED || !supportsWorkoutControl) return null
        val p = runCatching { request(UteWorkout.QUERY) { it.op == 0xFD && (it.size == 4 || it.size == 13) && Ute.u(it, 1) == 0xAA } }.getOrNull()
            ?: return null
        val status = (UteWorkout.parse(p) as? UteWorkout.Parsed.Event)?.event as? WorkoutEvent.State ?: return null
        trackWorkout(status.sportType, status.state)
        return status
    }

    override val workoutEvents: Flow<WorkoutEvent> =
        events.mapNotNull { (UteWorkout.parse(it) as? UteWorkout.Parsed.Event)?.event }

    override val locationRequests: Flow<LocationRequest> =
        events.mapNotNull { (UteWorkout.parse(it) as? UteWorkout.Parsed.Location)?.request }

    /**
     * Một điểm vị trí điện thoại (34F1): lần đầu sau mỗi lần đồng hồ xin vị trí gửi `FD 01 01` trước (như app gốc báo "định vị
     * được điểm đầu"), rồi `FD 02 …` ([UteWorkout.location], quãng đường tính từ điểm trước). [altitude], [accuracy] không có
     * trong gói của UTE.
     */
    override suspend fun sendLocation(latitude: Double, longitude: Double, altitude: Double?, speed: Double?, accuracy: Double?) {
        if (state.value != ConnectionState.CONNECTED) throw GloryFitException("Đồng hồ chưa kết nối")
        if (!locationAnnounced) {
            writeBle5(UteWorkout.locationStatus(true))
            locationAnnounced = true
        }
        val point = lastFix?.let { (lat, lon) -> Math.round(UteWorkout.distanceMeters(lat, lon, latitude, longitude)).toInt() } ?: 0
        totalMeters += point
        lastFix = latitude to longitude
        writeBle5(UteWorkout.location(latitude, longitude, speed, point, totalMeters))
    }

    /** `FD 44 type 01 h m s kcal km pace [bước]` (33F1): điện thoại đẩy số liệu bài tập (chế độ GPS điện thoại). */
    override suspend fun sendWorkoutData(data: WorkoutData) {
        val type = requireWorkout()
        lastWorkoutData = data
        writeCommand(UteWorkout.control(UteWorkout.OP_DATA, type, 1, data.durationSec, data, UteWorkout.dataWithSteps(features)))
    }

    /** `FD 48 AA` (34F1) → các gói `FD 48 AA seq …` tới `FD 48 AA FD … min max`. */
    override suspend fun sportTypes(): List<SportType> {
        if (state.value != ConnectionState.CONNECTED) throw GloryFitException("Đồng hồ chưa kết nối")
        if (!supportsSportList) throw GloryFitException("Đồng hồ không có danh sách môn")
        val packets = collect(UteWorkout.QUERY_SPORTS, ble5 = true, idleMs = 3_000, match = UteWorkout::isSportListPacket, isEnd = UteWorkout::isSportListEnd)
        SmartWearLog.i("[$name] FD 48 AA: ${packets.size} gói")
        val list = UteWorkout.parseSportList(packets) ?: throw GloryFitException("FD 48 AA không có phản hồi")
        sportListLimits = list.minShown..maxOf(list.minShown, list.maxShown)
        return list.sports
    }

    /**
     * Ghi danh sách môn ([UteWorkout.sportListPackets], 34F1): sau mỗi gói chờ `FD 48 FB` (gửi tiếp, như GloryFit cũ
     * `B:7273-7276`), sau gói cuối chờ `FD 48 FD` = xong; không xác nhận ⇒ ném lỗi.
     */
    override suspend fun setSportList(sports: List<SportType>) {
        if (state.value != ConnectionState.CONNECTED) throw GloryFitException("Đồng hồ chưa kết nối")
        if (!supportsSportList) throw GloryFitException("Đồng hồ không chọn môn được")
        val list = try {
            UteWorkout.normalizeSportList(sports, sportListLimits)
        } catch (e: IllegalArgumentException) {
            throw GloryFitException(e.message ?: "Danh sách môn không hợp lệ")
        }
        val length = minOf(features.maxPacketLength ?: 20, gatt.mtu - 3).coerceAtLeast(20)
        val packets = UteWorkout.sportListPackets(list, length)
        if (packets.isEmpty()) throw GloryFitException("Danh sách môn rỗng")
        val ok = lock.withLock {
            val channel = Channel<ByteArray>(Channel.UNLIMITED)
            waiter = Waiter({ UteWorkout.isSportListPacket(it) && Ute.u(it, 2) != 0xAA }, channel)
            try {
                var ok = false
                for ((i, p) in packets.withIndex()) {
                    writeBle5(p)
                    val r = withTimeoutOrNull(3_000) { channel.receive() }
                    SmartWearLog.i("[$name] FD 48 gói $i/${packets.size}: ${r?.toHex() ?: "không trả lời"}")
                    if (i == packets.lastIndex) ok = r != null && Ute.u(r, 2) == 0xFD
                }
                ok
            } finally {
                waiter = null
            }
        }
        if (!ok) throw GloryFitException("Đồng hồ không xác nhận danh sách môn (FD 48 FD)")
    }

    // ---------- Sự kiện nút ----------

    override val deviceEvents: Flow<DeviceEvent> = events.mapNotNull(Ute::parseDeviceEvent)

    // ---------- Firmware (OTA Realtek) ----------

    /** Chip Realtek 8762Cx (`Is8762Cx`, F7 `0x800`) và model Y25: chỉ có image Y25 chính hãng ([RealtekImage.TRUSTED_PUBKEY_HASH]). */
    override val supportsFirmwareUpdate: Boolean get() = features.has(7, 0x000800) && isY25

    private val isY25: Boolean get() = model.startsWith("Y25", ignoreCase = true) || name.startsWith("Y25", ignoreCase = true)

    private val _firmwareUpdating = MutableStateFlow(false)
    override val firmwareUpdating: StateFlow<Boolean> = _firmwareUpdating.asStateFlow()
    @Volatile private var firmwareJob: Deferred<Boolean>? = null

    /** Chỉ đọc file: [RealtekImage.load] (MP header, ic 0x11, khoá ký Y25, CRC, SHA-256, chữ ký ECDSA) + đúng model Y25. */
    override fun checkFirmware(image: ByteArray): FirmwareCheck {
        if (!isY25) return FirmwareCheck(false, model, reason = "Firmware Realtek RB370L73AC chỉ dành cho Y25 ($name)")
        return runCatching { RealtekImage.load(image) }.fold(
            { img -> FirmwareCheck(true, "Y25", img.imageVersion?.let { "0x%08X".format(it) }, details = img.summary()) },
            { e -> FirmwareCheck(false, "Y25", reason = e.message) },
        )
    }

    /**
     * Bọc [RealtekDfuClient.flash] (kết nối DFU riêng, giữ kết nối UTE; pin ≥ [RealtekDfuClient.MIN_BATTERY] %). Kiểm lại file
     * trước khi mở kết nối; huỷ bằng [cancelFirmwareUpdate] (không bao giờ kích hoạt khi huỷ / lỗi).
     */
    override suspend fun updateFirmware(image: ByteArray, options: FirmwareUpdateOptions, progress: (Float) -> Unit): Boolean {
        val check = checkFirmware(image)
        if (!check.valid) throw GloryFitException("Từ chối firmware: ${check.reason}")
        if (RealtekDfuClient.isRunning) throw GloryFitException("Đang có một phiên OTA khác")
        val img = RealtekImage.load(image)
        _firmwareUpdating.value = true
        try {
            return coroutineScope {
                val job = async {
                    RealtekDfuClient(appContext, btDevice).flash(
                        img,
                        batteryHint = battery.value.takeIf { state.value == ConnectionState.CONNECTED },
                        options = RealtekDfuClient.Options(
                            packetDelayMs = options.packetDelayMs.coerceIn(0, 1_000),
                            activate = options.activate,
                            declaredBattery = options.declaredBattery?.takeIf { it in 0..100 },
                            trace = options.trace,
                        ),
                    ) { sent, total -> if (total > 0) progress(sent.toFloat() / total) }
                }
                firmwareJob = job
                job.await()
            }
        } finally {
            firmwareJob = null
            _firmwareUpdating.value = false
        }
    }

    override fun cancelFirmwareUpdate() {
        firmwareJob?.cancel()
    }

    override suspend fun watchFaceSpec(): WatchFaceSpec {
        val p = dialParams ?: queryDialParams().also { dialParams = it }
        // Y25 (466×466) trả screenType = 0; màn vuông cạnh lớn coi như màn tròn (suy luận).
        val round = p.screenType == 2 || (p.width == p.height && p.width >= 360)
        return WatchFaceSpec(p.width, p.height, round, p.maxSize)
    }

    override fun renderWatchFace(image: Bitmap, spec: WatchFaceSpec, style: WatchFaceStyle, exclude: WatchWidget?): Bitmap =
        synchronized(renderer) { renderer.preview(image, spec, style, exclude) }

    override fun watchFaceLayout(image: Bitmap, spec: WatchFaceSpec, style: WatchFaceStyle): Map<WatchWidget, RectF> =
        synchronized(renderer) { renderer.layout(image, spec, style) }

    override fun renderWidget(image: Bitmap, spec: WatchFaceSpec, style: WatchFaceStyle, widget: WatchWidget): Bitmap =
        synchronized(renderer) { renderer.sprite(image, spec, style, widget) }

    /** `26 01` trả mã mặt đang hiển thị: `FF FF FF FE` = mặt tuỳ chỉnh (kiểm chứng trên Y25), `FF FF FF FF` = chưa có. */
    override suspend fun isCustomWatchFaceActive(): Boolean {
        val p = queryDialParams().also { dialParams = it }
        return p.currentId == CUSTOM_FACE_ID
    }

    override fun watchFaceSize(image: Bitmap, spec: WatchFaceSpec, style: WatchFaceStyle): Int =
        UteWatchFace.build(spec.width, spec.height, dialParams?.level ?: 0, synchronized(renderer) { renderer.elements(image, spec, style) }).size

    override suspend fun setWatchFace(image: Bitmap, style: WatchFaceStyle, progress: (Float) -> Unit): WatchFaceStyle {
        val spec = watchFaceSpec()
        val level = dialParams?.level ?: 0
        // Chữ số giờ không được nén: nếu file vượt dung lượng, thu nhỏ chữ dần cho vừa.
        var used = style
        var bin = UteWatchFace.build(spec.width, spec.height, level, synchronized(renderer) { renderer.elements(image, spec, used) })
        while (bin.size > spec.maxBytes && used.timeSize > 0.12f) {
            used = used.copy(timeSize = used.timeSize - 0.01f)
            bin = UteWatchFace.build(spec.width, spec.height, level, synchronized(renderer) { renderer.elements(image, spec, used) })
        }
        SmartWearLog.i("[$name] mặt đồng hồ ${bin.size} byte (tối đa ${spec.maxBytes}), cỡ giờ ${used.timeSize}")
        if (bin.size > spec.maxBytes) throw GloryFitException("Mặt đồng hồ ${bin.size / 1024} KB vượt giới hạn ${spec.maxBytes / 1024} KB")
        sendWatchFace(bin, progress)
        // Định dạng giờ 12/24 của đồng hồ đi theo lệnh đơn vị A0 (km, 1 = 24 giờ, 2 = 12 giờ).
        saveSettings(settings.with("unit.hour12", ControlValue.Bool(used.hour12)))
        runCatching { request(UteControls.units(settings)) { it.op == 0xA0 } }
        return used
    }

    /**
     * Cài một file mặt đồng hồ `.bin` dựng sẵn (định dạng doc 02 §4, ví dụ từ kho GloryFit hoặc công cụ khác).
     * Kiểm tra kích thước màn, độ dài và CRC-32 trong header trước khi gửi.
     */
    suspend fun installWatchFaceFile(bin: ByteArray, progress: (Float) -> Unit = {}) {
        val spec = watchFaceSpec()
        val buf = java.nio.ByteBuffer.wrap(bin).order(java.nio.ByteOrder.LITTLE_ENDIAN)
        if (bin.size < 24) throw GloryFitException("File mặt đồng hồ quá ngắn")
        val width = buf.getShort(12).toInt() and 0xFFFF
        val height = buf.getShort(14).toInt() and 0xFFFF
        if (width != spec.width || height != spec.height) throw GloryFitException("File ${width}×$height, màn đồng hồ ${spec.width}×${spec.height}")
        if (buf.getInt(4) != bin.size - 24) throw GloryFitException("Độ dài trong header không khớp file")
        val crc = java.util.zip.CRC32().apply { update(bin, 24, bin.size - 24) }.value.toInt()
        if (buf.getInt(8) != crc) throw GloryFitException("CRC-32 trong header không khớp file")
        if (bin.size > spec.maxBytes) throw GloryFitException("Mặt đồng hồ ${bin.size / 1024} KB vượt giới hạn ${spec.maxBytes / 1024} KB")
        if (bin[19].toInt() >= 2 && (dialParams?.level ?: 0) < 2) throw GloryFitException("File nén RLE nhưng đồng hồ không hỗ trợ nén")
        SmartWearLog.i("[$name] cài file mặt đồng hồ ${bin.size} byte")
        sendWatchFace(bin, progress)
    }

    private suspend fun sendWatchFace(bin: ByteArray, progress: (Float) -> Unit) {
        var result = BleQuiet.hold { uploadWatchFace(bin, progress, slowStart = false) }
        if (result and ABORTED != 0 && !GloryFitDebug.noRetry) {
            // Đồng hồ huỷ giữa chừng (thường do nhiễu/sóng bận): gửi lại từ đầu một lần, chậm hơn.
            SmartWearLog.w("[$name] đồng hồ huỷ nhận giữa chừng, gửi lại chậm hơn")
            delay(2_000)
            result = BleQuiet.hold { uploadWatchFace(bin, progress, slowStart = true) }
        }
        when (result and ABORTED.inv()) {
            0x00 -> SmartWearLog.i("[$name] đã cài mặt đồng hồ")
            0x01 -> throw GloryFitException("Đồng hồ báo nhận lỗi (26 03 01: sai CRC hoặc huỷ giữa chừng)")
            0x02 -> throw GloryFitException("Đồng hồ báo file quá lớn")
            else -> throw GloryFitException("Đồng hồ trả mã %02X".format(result))
        }
    }

    /**
     * Truyền file mặt đồng hồ (doc 02 §5): `26 02` → các gói `27 seqHi seqLo + dữ liệu` lên 34F1,
     * cứ hết mỗi khối 4 KB chờ `26 03 04` (tối đa 5 s), `26 03 03 HH LL` = gửi lại từ gói HHLL,
     * cuối cùng `26 03 00` → kết quả `26 03 00/01/02`.
     */
    private suspend fun uploadWatchFace(bin: ByteArray, progress: (Float) -> Unit, slowStart: Boolean): Int = lock.withLock {
        val channel = Channel<ByteArray>(Channel.UNLIMITED)
        waiter = Waiter({ it.op == 0x26 }, channel)
        try {
            suspend fun next(sub: Int, ms: Long): ByteArray? = withTimeoutOrNull(ms) {
                var p: ByteArray
                do { p = channel.receive() } while (p.size < 2 || Ute.u(p, 1) != sub)
                p
            }
            writeCommand(bytes(0x26, 0x02))
            next(0x02, 5_000) ?: throw GloryFitException("Đồng hồ không sẵn sàng nhận mặt đồng hồ (26 02)")
            val packetLength = (GloryFitDebug.packetLength ?: minOf(features.maxPacketLength ?: 20, gatt.mtu - 3)).coerceAtLeast(20)
            val chunk = packetLength - 3
            val total = (bin.size + chunk - 1) / chunk
            val withResponse = gatt.supportsWriteWithResponse(Ute.SERVICE5, Ute.WRITE5)
            SmartWearLog.i("[$name] gửi ${bin.size} byte: $total gói × $chunk byte, ghi ${if (withResponse) "có" else "không"} phản hồi")
            var seq = 0
            var lastSector = 0
            var resends = 0
            var silentSectors = 0
            var slow = slowStart // như app gốc: bị yêu cầu gửi lại quá 2 lần thì chậm lại 100 ms/gói
            // `26 03 01`/`02` có thể đến giữa chừng (đồng hồ huỷ nhận): dừng ngay, như app gốc (stopOnlineDialData).
            fun failed(p: ByteArray) = p.size >= 3 && Ute.u(p, 1) == 0x03 && Ute.u(p, 2) in 1..2
            val trace = GloryFitDebug.trace
            val started = System.currentTimeMillis()
            var sectorStarted = started
            var early: ByteArray? = null // `26 03 04` đến trước khi vòng lặp tới chỗ chờ khối: giữ lại, đừng bỏ
            while (seq < total) {
                val from = seq * chunk
                val packet = byteArrayOf(0x27, (seq shr 8).toByte(), seq.toByte()) + bin.copyOfRange(from, minOf(bin.size, from + chunk))
                gatt.write(Ute.SERVICE5, Ute.WRITE5, packet, withResponse = withResponse)
                progress((seq + 1f) / total)
                // Đồng hồ yêu cầu gửi lại hoặc huỷ?
                val pushed = channel.tryReceive().getOrNull()
                if (pushed != null && trace) SmartWearLog.i("[$name] trace +${System.currentTimeMillis() - started} ms gói $seq: nhận giữa khối ${pushed.toHex()}")
                if (pushed != null && pushed.size >= 3 && Ute.u(pushed, 1) == 0x03 && Ute.u(pushed, 2) == 0x04) early = pushed
                if (pushed != null && failed(pushed)) {
                    SmartWearLog.w("[$name] đồng hồ huỷ nhận ở gói $seq/$total: ${pushed.toHex()}")
                    return@withLock ABORTED or Ute.u(pushed, 2)
                }
                if (pushed != null && pushed.size >= 5 && Ute.u(pushed, 1) == 0x03 && Ute.u(pushed, 2) == 0x03) {
                    seq = Ute.be16(pushed, 3)
                    if (++resends > 20) throw GloryFitException("Đồng hồ yêu cầu gửi lại quá nhiều lần")
                    slow = slow || resends > 2
                    continue
                }
                val sector = ((seq + 1) * chunk) / 4096
                if (seq < total - 1 && sector != lastSector) {
                    lastSector = sector
                    val waitFrom = System.currentTimeMillis()
                    val r = early ?: next(0x03, 5_000)
                    early = null
                    if (trace) {
                        val now = System.currentTimeMillis()
                        SmartWearLog.i("[$name] trace +${now - started} ms khối $sector (gói $seq): gửi ${waitFrom - sectorStarted} ms, chờ ${now - waitFrom} ms → ${r?.toHex() ?: "hết giờ"}")
                        sectorStarted = now
                    }
                    if (r != null && failed(r)) {
                        SmartWearLog.w("[$name] đồng hồ huỷ nhận ở gói $seq/$total: ${r.toHex()}")
                        return@withLock ABORTED or Ute.u(r, 2)
                    }
                    if (r != null && r.size >= 5 && Ute.u(r, 2) == 0x03) {
                        seq = Ute.be16(r, 3)
                        if (++resends > 20) throw GloryFitException("Đồng hồ yêu cầu gửi lại quá nhiều lần")
                        slow = slow || resends > 2
                        continue
                    }
                    // App gốc coi hết 5 s là xong khối và gửi tiếp; im lặng nhiều khối liền thì đồng hồ đã bỏ phiên.
                    silentSectors = if (r == null) silentSectors + 1 else 0
                    if (silentSectors >= 3) throw GloryFitException("Đồng hồ ngừng phản hồi ở gói $seq/$total")
                } else if (slow) {
                    delay(100)
                } else if (GloryFitDebug.packetDelayMs > 0) {
                    delay(GloryFitDebug.packetDelayMs)
                } else if (seq > 0 && seq % 10 == 0) {
                    delay(20)
                }
                seq++
            }
            delay(500)
            writeCommand(bytes(0x26, 0x03, 0x00))
            val result = withTimeoutOrNull(30_000) {
                var p: ByteArray
                do { p = channel.receive() } while (!(p.size >= 3 && Ute.u(p, 1) == 0x03 && Ute.u(p, 2) in 0..2))
                p
            } ?: throw GloryFitException("Không nhận được kết quả 26 03")
            SmartWearLog.i("[$name] kết quả mặt đồng hồ: ${result.toHex()}")
            Ute.u(result, 2)
        } finally {
            waiter = null
        }
    }

    private companion object {
        const val CUSTOM_FACE_ID = 0xFFFFFFFEL
        /** Chu kỳ đo HR 24h nhỏ nhất app iOS dùng (phút). */
        const val HR24_INTERVAL_MIN = 5
        /** Giá trị đồng hồ đẩy còn coi là "vừa đo". */
        const val HR_RECENT_MS = 10 * 60_000L
        /** Chờ tối đa một chu kỳ đo + 1 phút. */
        const val HR24_WAIT_MS = (HR24_INTERVAL_MIN + 1) * 60_000L
        /** Thời gian để Y25 đo một lần theo lệnh `E5 11` trước khi app gửi `E5 00` lấy kết quả (25 s cho 82 bpm khi thử). */
        const val HR_MANUAL_WINDOW_MS = 25_000L
        const val HR24_NOTE = "Đồng hồ tự đo theo chu kỳ — đo trên đồng hồ để có kết quả ngay"
        /** Cờ trong kết quả [uploadWatchFace]: đồng hồ báo lỗi trước khi gửi xong. */
        const val ABORTED = 0x100
        /** Chờ đồng hồ trả lời mỗi gói `C5`/`C6`. */
        const val PUSH_ACK_MS = 3_000L
        /** Bỏ lần bấm chụp lặp (GloryFit `FragmentHomePage.isTakePhoto`: 4000 ms; bản iOS cũng 4 s). */
        const val SHUTTER_GAP_MS = 4_000L
    }

    /** Hỏi thông số mặt đồng hồ (`26 01`, chỉ đọc). */
    suspend fun queryDialParams(): Ute.DialParams {
        val p = request(bytes(0x26, 0x01), timeoutMs = 5_000) { it.op == 0x26 && it.size > 1 && Ute.u(it, 1) == 0x01 }
        SmartWearLog.i("[$name] 26 01 = ${p.toHex()}")
        return Ute.parseDialParams(p) ?: throw GloryFitException("Phản hồi 26 01 không hợp lệ: ${p.toHex()}")
    }

    // ---------- AGPS (UteAgps) ----------

    private val _agpsRequests = MutableSharedFlow<AgpsRequest>(extraBufferCapacity = 8, onBufferOverflow = BufferOverflow.DROP_OLDEST)
    override val agpsRequests: Flow<AgpsRequest> = _agpsRequests.asSharedFlow()

    /** Vị trí điện thoại app đưa gần nhất (giây Unix, vĩ độ, kinh độ) và lúc gửi lên đồng hồ lần cuối. */
    @Volatile
    private var agpsPosition: Triple<Long, Double, Double>? = null
    @Volatile
    private var agpsPositionSentAt = 0L
    /** File app đặt sẵn ([setAgpsFiles]), chỉ trong bộ nhớ. */
    @Volatile
    private var agpsFiles: List<AgpsFile>? = null
    @Volatile
    private var agpsUploading = false

    override val supportsAgps: Boolean get() = UteAgps.supported(features)

    init {
        // Đồng hồ hỏi AGPS (HT43: `01 E9 AC 03 01 02` mỗi 60 s khi hết dữ liệu vệ tinh). Trả lời bằng vị trí / file app đặt sẵn.
        scope.launch {
            events.collect { p ->
                val type = UteAgps.parseRequest(p) ?: return@collect
                val handled = runCatching { answerAgps(type) }
                    .onFailure { SmartWearLog.w("[$name] trả lời AGPS lỗi: ${it.message}") }
                    .getOrDefault(false)
                _agpsRequests.tryEmit(AgpsRequest(type, handled))
            }
        }
    }

    /** true = đã trả lời bằng dữ liệu app đặt (vị trí hoặc file). */
    private suspend fun answerAgps(type: AgpsRequestType): Boolean {
        if (state.value != ConnectionState.CONNECTED) return false
        val files = agpsFiles
        return when (type) {
            AgpsRequestType.POSITION -> sendStoredAgpsPosition(force = true)
            AgpsRequestType.STATUS -> {
                // Như GloryFitPro `getEphemerisParams`: vị trí điện thoại trước, rồi trạng thái file (`responseEphemerisRequired`).
                val sentPosition = sendStoredAgpsPosition(force = false)
                val st = if (files != null) UteAgps.STATUS_DONE else GloryFitDebug.agpsNoFileStatus
                if (st != null) writeBle5(UteAgps.status(st))
                files != null || sentPosition
            }
            AgpsRequestType.DOWNLOAD -> {
                if (files == null || agpsUploading) return false
                transferAgps(UteAgps.payload(files)) {}
                true
            }
        }
    }

    /** Gửi vị trí đã lưu nếu còn mới; không [force] thì tối đa mỗi [UteAgps.POSITION_RESEND_MS] (đồng hồ hỏi mỗi phút). */
    private suspend fun sendStoredAgpsPosition(force: Boolean): Boolean {
        val (ts, lat, lon) = agpsPosition ?: return false
        val now = System.currentTimeMillis()
        if (now - ts * 1000 > UteAgps.POSITION_MAX_AGE_MS) return false
        if (!force && now - agpsPositionSentAt < UteAgps.POSITION_RESEND_MS) return false
        writeBle5(UteAgps.position(ts, lat, lon))
        agpsPositionSentAt = now
        return true
    }

    private fun requireAgps() {
        if (state.value != ConnectionState.CONNECTED) throw GloryFitException("Đồng hồ chưa kết nối")
        if (!supportsAgps) throw UnsupportedOperationException("Đồng hồ không hỗ trợ AGPS")
    }

    /** `56 FD` (33F1, dữ liệu còn hợp lệ) + `01 E9 AA 01` (34F1, tên file / phiên bản). */
    override suspend fun agpsInfo(): AgpsInfo {
        requireAgps()
        val valid = runCatching { request(UteAgps.EPHEMERIS_STATE) { UteAgps.parseEphemerisState(it) != null } }
            .getOrNull()?.let(UteAgps::parseEphemerisState)
        val packets = collect(UteAgps.INFO, ble5 = true, idleMs = 3_000, match = UteAgps::isInfoPacket, isEnd = UteAgps::isInfoEnd)
        SmartWearLog.i("[$name] AGPS: 56 FD → $valid, AA 01 → ${packets.joinToString(" | ") { it.toHex() }}")
        if (packets.none(UteAgps::isInfoEnd)) throw GloryFitException("Đồng hồ không trả thông tin AGPS (01 E9 AA 01)")
        return UteAgps.parseInfo(packets, valid)
    }

    /** `01 E9 AB 02 0C ts lat lon`; lưu lại để tự gửi khi đồng hồ hỏi. Chưa kết nối thì chỉ lưu. */
    override suspend fun sendAgpsPosition(latitude: Double, longitude: Double, timestampMs: Long) {
        val ts = timestampMs / 1000
        val packet = UteAgps.position(ts, latitude, longitude)
        agpsPosition = Triple(ts, latitude, longitude)
        if (state.value != ConnectionState.CONNECTED) return
        requireAgps()
        runCatching { request(packet, ble5 = true) { UteAgps.isPositionAck(it) } }
            .onFailure { SmartWearLog.w("[$name] AGPS: đồng hồ không xác nhận vị trí (${it.message})") }
        agpsPositionSentAt = System.currentTimeMillis()
    }

    override fun setAgpsFiles(files: List<AgpsFile>?) {
        if (files != null) UteAgps.payload(files) // kiểm giới hạn ngay để app biết lỗi
        agpsFiles = files?.toList()
    }

    /**
     * Như luồng app gốc: báo đã có file (`AB 03 01 03`), chờ đồng hồ xin (`AC 03 01 01`, tối đa 10 s; không xin vẫn gửi), rồi
     * truyền ([transferAgps]).
     */
    override suspend fun uploadAgpsFiles(files: List<AgpsFile>, progress: (Float) -> Unit) {
        requireAgps()
        val payload = UteAgps.payload(files)
        val asked = runCatching {
            request(UteAgps.status(UteAgps.STATUS_DONE), timeoutMs = 10_000, ble5 = true) { UteAgps.parseRequest(it) == AgpsRequestType.DOWNLOAD }
        }.isSuccess
        if (!asked) SmartWearLog.w("[$name] AGPS: đồng hồ chưa xin file sau AB 03 01 03, vẫn gửi")
        transferAgps(payload, progress)
    }

    /**
     * Truyền [payload] bằng các gói `01 E9 AB 04 idx…` lên 34F1 (`uterkcase.java:225-309`): qua mỗi mốc 4 KB chờ
     * `AC 04 01 07` (tối đa 5 s), `AC 04 01 06 HH LL` = gửi lại từ gói HHLL; sau gói cuối 500 ms gửi `AB 04 FD FD xor`, chờ
     * `AC 04 01 01`.
     */
    private suspend fun transferAgps(payload: ByteArray, progress: (Float) -> Unit): Unit = lock.withLock {
        val channel = Channel<ByteArray>(Channel.UNLIMITED)
        waiter = Waiter(UteAgps::isTransferResult, channel)
        agpsUploading = true
        try {
            val packetLength = (GloryFitDebug.packetLength ?: minOf(features.maxPacketLength ?: 20, gatt.mtu - 3)).coerceAtLeast(20)
            val chunk = packetLength - 6
            val packets = UteAgps.packets(payload, chunk)
            SmartWearLog.i("[$name] AGPS: gửi ${payload.size} byte, ${packets.size} gói × $chunk byte")
            fun fail(st: Int): Nothing = throw GloryFitException(
                when (st) {
                    UteAgps.TRANSFER_CANCELLED -> "Đồng hồ huỷ nhận AGPS"
                    UteAgps.TRANSFER_CRC -> "Đồng hồ báo sai CRC dữ liệu AGPS"
                    UteAgps.TRANSFER_TOO_LARGE -> "Dữ liệu AGPS quá lớn với đồng hồ"
                    else -> "Đồng hồ trả mã AGPS %02X".format(st)
                },
            )
            // Gói kết quả giữa chừng: trả về gói cần gửi lại, null = tiếp tục; lỗi thì ném.
            fun check(r: ByteArray): Int? = when (val st = UteAgps.transferStatus(r)) {
                UteAgps.TRANSFER_RESEND -> UteAgps.resendFrom(r)
                UteAgps.TRANSFER_CONTINUE, UteAgps.TRANSFER_OK -> null
                else -> fail(st)
            }
            var seq = 0
            var lastSector = 0
            var resends = 0
            var silentSectors = 0
            var early = false // `AC 04 01 07` đến trước mốc khối: giữ lại
            while (seq < packets.size) {
                write5(packets[seq])
                progress((seq + 1f) / packets.size)
                var resendAt: Int? = null
                val pushed = channel.tryReceive().getOrNull()
                if (pushed != null) {
                    if (UteAgps.transferStatus(pushed) == UteAgps.TRANSFER_CONTINUE) early = true
                    resendAt = check(pushed)
                }
                val sector = ((seq + 1) * chunk) / UteAgps.SECTOR_BYTES
                if (resendAt == null && seq < packets.size - 1 && sector != lastSector) {
                    lastSector = sector
                    val r = if (early) null else withTimeoutOrNull(5_000) { channel.receive() }
                    silentSectors = if (r == null && !early) silentSectors + 1 else 0
                    early = false
                    if (silentSectors >= 3) throw GloryFitException("Đồng hồ ngừng phản hồi khi nhận AGPS ở gói $seq/${packets.size}")
                    if (r != null) resendAt = check(r)
                } else if (resendAt == null && packetLength <= 20) {
                    delay(50) // như SDK iOS khi gói ≤ 20 byte
                } else if (resendAt == null && seq > 0 && seq % 10 == 0) {
                    delay(20)
                }
                val from = resendAt
                if (from != null) {
                    if (++resends > 20) throw GloryFitException("Đồng hồ yêu cầu gửi lại AGPS quá nhiều lần")
                    seq = from.coerceIn(0, packets.size - 1)
                } else {
                    seq++
                }
            }
            delay(500)
            val end = UteAgps.endPacket(UteAgps.xor(packets))
            onPacketSent(end)
            write5(end)
            val result = withTimeoutOrNull(30_000) {
                var r: ByteArray
                do { r = channel.receive() } while (UteAgps.transferStatus(r) == UteAgps.TRANSFER_CONTINUE)
                r
            } ?: throw GloryFitException("Không nhận được kết quả truyền AGPS")
            if (UteAgps.transferStatus(result) != UteAgps.TRANSFER_OK) fail(UteAgps.transferStatus(result))
            SmartWearLog.i("[$name] AGPS: đồng hồ nhận xong ${payload.size} byte")
        } finally {
            waiter = null
            agpsUploading = false
        }
    }

    // ---------- Kênh lệnh ----------

    /**
     * Gỡ lỗi qua adb (app lab): gửi gói thô [bytes] lên 33F1 hoặc 34F1 ([ble5]) rồi gom mọi gói cùng opcode trong [listenMs].
     * Chỉ dùng cho lệnh đọc; lỗi ghi trả về mã trạng thái GATT trong thông báo.
     */
    suspend fun debugExchange(bytes: ByteArray, ble5: Boolean, withResponse: Boolean = true, listenMs: Long = 3_000): List<ByteArray> {
        if (state.value != ConnectionState.CONNECTED) throw GloryFitException("Đồng hồ chưa kết nối")
        return lock.withLock {
            val channel = Channel<ByteArray>(Channel.UNLIMITED)
            waiter = Waiter({ it.op == bytes[0].toInt() and 0xFF }, channel)
            try {
                try {
                    onPacketSent(bytes)
                    if (ble5) gatt.write(Ute.SERVICE5, Ute.WRITE5, bytes, withResponse) else gatt.write(Ute.SERVICE, Ute.WRITE, bytes, withResponse)
                } catch (e: com.smartwear.core.GattException) {
                    throw GloryFitException("${e.message} (status ${e.status})")
                }
                val out = mutableListOf<ByteArray>()
                withTimeoutOrNull(listenMs) { while (true) out += channel.receive() }
                out
            } finally {
                waiter = null
            }
        }
    }

    /**
     * Một lần ghi 34F1 theo [writeWithResponse5]; đồng hồ từ chối ghi có phản hồi (`status 3`) thì ghi lại không phản hồi và
     * nhớ cho các lần sau.
     */
    private suspend fun write5(bytes: ByteArray) {
        try {
            gatt.write(Ute.SERVICE5, Ute.WRITE5, bytes, withResponse = writeWithResponse5)
        } catch (e: com.smartwear.core.GattException) {
            if (!writeWithResponse5 || e.status != 3) throw e
            SmartWearLog.w("[$name] 34F1 từ chối ghi có phản hồi (status 3), chuyển sang ghi không phản hồi")
            writeWithResponse5 = false
            gatt.write(Ute.SERVICE5, Ute.WRITE5, bytes, withResponse = false)
        }
    }

    /** Ghi lên 34F1 (không phản hồi qua notify; ack qua write callback). */
    private suspend fun writeBle5(bytes: ByteArray) {
        if (!gatt.hasCharacteristic(Ute.SERVICE5, Ute.WRITE5)) throw GloryFitException("Không có kênh 34F1")
        onPacketSent(bytes)
        write5(bytes)
    }

    /** Gửi [bytes] (33F1 hoặc 34F1) rồi gom mọi gói khớp [match], tới gói [isEnd] (có gồm gói đó) hoặc khi im lặng quá [idleMs]. */
    private suspend fun collect(
        bytes: ByteArray, ble5: Boolean, idleMs: Long, match: (ByteArray) -> Boolean, isEnd: (ByteArray) -> Boolean,
    ): List<ByteArray> = lock.withLock {
        val channel = Channel<ByteArray>(Channel.UNLIMITED)
        waiter = Waiter(match, channel)
        val packets = mutableListOf<ByteArray>()
        try {
            if (ble5) writeBle5(bytes) else writeCommand(bytes)
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

    private val ByteArray.op get() = if (isEmpty()) -1 else this[0].toInt() and 0xFF

    private fun bytes(vararg v: Int) = ByteArray(v.size) { v[it].toByte() }

    private suspend fun writeCommand(bytes: ByteArray) {
        SmartWearLog.v { "-> [$name] ${bytes.toHex()}" }
        onPacketSent(bytes)
        gatt.write(Ute.SERVICE, Ute.WRITE, bytes, withResponse = writeWithResponse)
    }

    /** Gửi lệnh và chờ gói đầu tiên khớp [match]. */
    private suspend fun request(bytes: ByteArray, timeoutMs: Long = 3_000, ble5: Boolean = false, match: (ByteArray) -> Boolean): ByteArray = lock.withLock {
        val channel = Channel<ByteArray>(Channel.UNLIMITED)
        waiter = Waiter(match, channel)
        try {
            val started = System.currentTimeMillis()
            if (ble5) {
                onPacketSent(bytes)
                write5(bytes)
            } else {
                writeCommand(bytes)
            }
            withTimeout(timeoutMs) { channel.receive() }.also { onLatency(System.currentTimeMillis() - started) }
        } catch (e: TimeoutCancellationException) {
            throw GloryFitException("Lệnh %02X không có phản hồi".format(bytes[0]))
        } finally {
            waiter = null
        }
    }

    /**
     * Luồng bài tập `FD FA [mốc]`: gói đầu báo số bài, mỗi bài kết thúc bằng `FD FD`; dừng khi đủ số bài hoặc im lặng.
     * Gói `FD` khác (số liệu tức thời, trạng thái bài tập) đến giữa chừng cũng bị gom vào đây; [Ute.parseWorkouts] bỏ qua.
     */
    private suspend fun streamWorkouts(since: LocalDate? = null, idleMs: Long = 5_000): List<ByteArray> = lock.withLock {
        val channel = Channel<ByteArray>(Channel.UNLIMITED)
        waiter = Waiter({ it.op == 0xFD }, channel)
        val packets = mutableListOf<ByteArray>()
        try {
            writeCommand(Ute.workoutSync(since, features))
            var expected = -1
            var done = 0
            while (true) {
                val p = withTimeoutOrNull(idleMs) { channel.receive() } ?: break
                packets += p
                if (GloryFitDebug.workoutPackets) SmartWearLog.i("[$name] bài tập gói: ${p.toHex()}")
                Ute.workoutCount(p)?.let { expected = it }
                if (expected == 0) break
                if (Ute.isWorkoutEnd(p) && ++done >= expected && expected > 0) break
            }
            SmartWearLog.i("[$name] bài tập: báo $expected, nhận $done bài, ${packets.size} gói")
            packets
        } finally {
            waiter = null
        }
    }

    /** Kết quả một luồng lịch sử; [ended] = đã nhận gói kết thúc. */
    private class HistoryStream(val packets: List<ByteArray>, val ended: Boolean)

    /**
     * Luồng lịch sử: gửi [command] (33F1, hoặc 34F1 nếu [Ute.SyncCommand.usesBle5]), gom gói thuộc luồng đến gói
     * kết thúc hoặc khi im lặng quá [idleMs].
     */
    /**
     * [historyStream] có mốc [since] ([Ute.SyncCommand.request]); lệnh có mốc mà đồng hồ im lặng hoàn toàn thì gửi lại lệnh
     * không mốc (an toàn cho đồng hồ đời cũ báo F4 `0x2000` nhưng không hiểu mốc).
     */
    private suspend fun historyStreamSince(command: Ute.SyncCommand, since: LocalDate?): HistoryStream {
        val bytes = command.request(since, features)
        val r = historyStream(command, bytes)
        if (r.packets.isNotEmpty() || r.ended || bytes.contentEquals(command.bytes)) return r
        note("${bytes.toHex()} không có gói nào, thử lại không mốc ${command.hex}")
        return historyStream(command)
    }

    private suspend fun historyStream(command: Ute.SyncCommand, bytes: ByteArray = command.bytes, idleMs: Long = 5_000): HistoryStream = lock.withLock {
        val channel = Channel<ByteArray>(Channel.UNLIMITED)
        waiter = Waiter(command::matches, channel)
        val packets = mutableListOf<ByteArray>()
        try {
            val started = System.currentTimeMillis()
            if (command.usesBle5) {
                if (!gatt.hasCharacteristic(Ute.SERVICE5, Ute.WRITE5)) throw GloryFitException("Không có kênh 34F1")
                onPacketSent(bytes)
                write5(bytes)
            } else {
                writeCommand(bytes)
            }
            var first = true
            while (true) {
                val p = withTimeoutOrNull(idleMs) { channel.receive() } ?: break
                if (first) {
                    onLatency(System.currentTimeMillis() - started)
                    first = false
                }
                if (command.isEnd(p)) return@withLock HistoryStream(packets, ended = true)
                // App GloryFit bỏ qua gói trùng y hệt gói trước (trừ luồng gói thô `32 …`/`EC 02 …`).
                if (command.dedupe && packets.lastOrNull()?.contentEquals(p) == true) continue
                packets += p
            }
            HistoryStream(packets, ended = false)
        } finally {
            waiter = null
        }
    }

    private fun onNotification(n: GattNotification) {
        onPacketReceived(n.value, note = describe(n.value))
        val w = waiter
        if (w != null && w.match(n.value)) w.channel.trySend(n.value) else events.tryEmit(n.value)
    }

    private fun describe(p: ByteArray): String? = when (p.op) {
        0xA2 -> if (p.size >= 2) "pin ${Ute.u(p, 1)} %" else null
        0xE5 -> if (p.size >= 4) "nhịp tim ${Ute.u(p, 3)} (fin=${Ute.u(p, 1)})" else null
        0xF7 -> when {
            p.size < 9 -> null
            Ute.u(p, 1) == 0x03 -> "nhịp tim định kỳ ${Ute.u(p, 8)}"
            Ute.u(p, 1) == 0x0B -> "nhịp tim đo trên đồng hồ ${Ute.u(p, 8)}"
            else -> null
        }
        0x33 -> if (p.size >= 3 && Ute.u(p, 1) == 0x04) "bind: ${Ute.u(p, 2)}" else null
        0xD5 -> if (p.size >= 2) "mã ghép: ${Ute.u(p, 1)}" else null
        0xD1 -> when {
            p.size < 2 -> null
            Ute.u(p, 1) == 0x02 -> "từ chối cuộc gọi"
            Ute.u(p, 1) == 0x03 -> "chụp ảnh"
            Ute.u(p, 1) == 0x11 -> "mở màn chụp ảnh"
            Ute.u(p, 1) == 0x0F -> "đóng màn chụp ảnh"
            else -> UteMusic.parseCommand(p)?.let { "nhạc: $it" } ?: Ute.parseDeviceEvent(p)?.let { "nút: $it" }
        }
        0xC4 -> if (p.size >= 2 && Ute.u(p, 1) == 0x02) "chụp ảnh" else null
        0xFD -> when (val w = UteWorkout.parse(p)) {
            is UteWorkout.Parsed.Event -> "bài tập: ${w.event}"
            is UteWorkout.Parsed.Location -> "vị trí: ${w.request}"
            else -> null
        }
        0xAF -> UteControls.parseLanguage(p)?.let { "ngôn ngữ $it" }
        0x52 -> UteSmsReply.parseRequest(p)?.let { "trả lời SMS tới ${it.number}" }
        else -> null
    }
}
