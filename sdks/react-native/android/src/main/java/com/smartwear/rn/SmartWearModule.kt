package com.smartwear.rn

import android.content.Context
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReadableArray
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.bridge.ReadableType
import com.facebook.react.bridge.WritableArray
import com.facebook.react.bridge.WritableMap
import com.smartwear.core.AlarmClock
import com.smartwear.core.BlePermissions
import com.smartwear.core.Capability
import com.smartwear.core.ConfigurableDevice
import com.smartwear.core.ConnectionState
import com.smartwear.core.ControlValue
import com.smartwear.core.DeviceControl
import com.smartwear.core.DeviceHistory
import com.smartwear.core.DeviceManager
import com.smartwear.core.DeviceRegistry
import com.smartwear.core.PairingPrompt
import com.smartwear.core.Reading
import com.smartwear.core.WearableDevice
import com.smartwear.core.WeatherCondition
import com.smartwear.core.WeatherDay
import com.smartwear.core.WeatherDisplay
import com.smartwear.core.WeatherForecast
import com.smartwear.core.CallAudioLink
import com.smartwear.core.CallDisplay
import com.smartwear.core.Contact
import com.smartwear.core.ContactsSync
import com.smartwear.core.DeviceEvents
import com.smartwear.core.FirmwareUpdatable
import com.smartwear.core.HeartRateStreaming
import com.smartwear.core.MusicRemote
import com.smartwear.core.NotificationDisplay
import com.smartwear.core.RemoteCameraDevice
import com.smartwear.core.SmsQuickReply
import com.smartwear.core.WatchFaceCustomizable
import com.smartwear.core.WatchFaceManager
import com.smartwear.core.WorkoutEvent
import com.smartwear.core.WorkoutRemote
import com.smartwear.core.phone.KeepConnectedService
import com.smartwear.core.phone.PhoneLink
import com.smartwear.gloryfit.GloryFitDriver
import com.smartwear.veepoo.VeepooDriver
import com.smartwear.qring.QRingDriver
import com.smartwear.standard.StandardDriver
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch

/**
 * TurboModule `SmartWear` cho Android: bọc [DeviceManager] và các driver QRing / GloryFit / Bluetooth chuẩn.
 * Một [DeviceManager] cho cả tiến trình (sống qua việc tải lại JS). Sự kiện thiết bị gửi khi ảnh chụp trạng thái đổi
 * (kiểm mỗi 0,5 s), số đo gửi ngay từng gói.
 */
class SmartWearModule(reactContext: ReactApplicationContext) : NativeSmartWearSpec(reactContext) {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val measureJobs = mutableMapOf<String, Job>()
    private var lastDevices: String? = null
    private var lastDiscovered: String? = null
    private val watched = mutableSetOf<String>()
    private var publishJob: Job? = null
    private var lastScanState: Map<String, Any?>? = null
    private val invoker by lazy {
        SmartWearInvoke(reactApplicationContext, manager, { phoneLink(reactApplicationContext) }, ::event, ::historyMap, scope)
    }

    private val manager: DeviceManager get() = shared(reactApplicationContext)

    override fun getName() = NAME

    override fun invalidate() {
        scope.coroutineContext[Job]?.cancel()
        super.invalidate()
    }

    // ---------- Vòng đời, quét ----------

    /** Gọi lại được (vd sau khi người dùng vừa cấp quyền Bluetooth): nối lại thiết bị đang giữ, không mở vòng lặp thứ hai. */
    override fun start() {
        scope.launch {
            val m = manager
            if (BlePermissions.granted(reactApplicationContext)) m.reconnectSaved()
            // Thông báo / cuộc gọi / nhạc / SMS chạy native (theo cấu hình `setPhoneLinkConfig`), không cần JS sống.
            phoneLink(reactApplicationContext).start()
            // Giữ kết nối ở nền: bật foreground service khi có thiết bị đang giữ (gọi lúc app ở foreground).
            if (SmartWearInvoke.foregroundServiceEnabled(reactApplicationContext)) {
                KeepConnectedService.bind(reactApplicationContext, m, processScope)
            }
            if (publishJob?.isActive == true) return@launch
            publishJob = launch {
                while (true) {
                    publishDevices(m)
                    publishDiscovered(m)
                    publishScanState()
                    for (d in m.devices.value) watch(d)
                    delay(500)
                }
            }
        }
    }

    /** `seconds` ≤ 0: quét không giới hạn tới khi `stopScan` (như iOS). */
    override fun startScan(seconds: Double) {
        scope.launch { manager.startScan(if (seconds > 0) (seconds * 1000).toLong() else Long.MAX_VALUE) }
    }

    override fun stopScan() {
        scope.launch { manager.stopScan() }
    }

    override fun getDiscovered(promise: Promise) {
        scope.launch { promise.resolve(discoveredArray(manager)) }
    }

    override fun getDevices(promise: Promise) {
        scope.launch { promise.resolve(devicesArray(manager)) }
    }

    // ---------- Kết nối ----------

    override fun connect(id: String, keep: Boolean, promise: Promise) {
        scope.launch {
            val m = manager
            val d = m.find(id) ?: m.scanResults.value.firstOrNull { it.scanned.address.equals(id, true) }?.let(m::addFromScan)
            if (d == null) return@launch promise.reject("not_found", "Không có thiết bị $id: hãy quét trước")
            if (keep) {
                m.connect(d)
                // Chờ tối đa 40 s cho lần kết nối đầu (giữ kết nối thì sau đó vẫn tự thử tiếp ở nền).
                val ok = waitFor(40_000) { d.state.value == ConnectionState.CONNECTED }
                if (ok) promise.resolve(null) else promise.reject("timeout", d.lastError.value ?: "Chưa kết nối được, đang tiếp tục thử ở nền")
            } else {
                // Có driver (GloryFit) nối kiểu chờ không giới hạn: không giữ kết nối thì chỉ chờ 40 s rồi huỷ.
                runCatching { kotlinx.coroutines.withTimeout(40_000) { d.connect() } }
                    .onSuccess { promise.resolve(null) }
                    .onFailure {
                        if (d.state.value != ConnectionState.CONNECTED) d.disconnect()
                        promise.reject("connect_failed", it.message ?: "Hết thời gian kết nối", it)
                    }
            }
        }
    }

    override fun disconnect(id: String) {
        scope.launch { manager.find(id)?.let(manager::disconnect) }
    }

    override fun forget(id: String) {
        scope.launch { manager.find(id)?.let(manager::remove) }
    }

    override fun setKeepConnected(id: String, keep: Boolean) {
        scope.launch { manager.find(id)?.let { manager.setKeepConnected(it, keep) } }
    }

    override fun submitPairingCode(id: String, code: String) {
        scope.launch { manager.find(id)?.submitPairingCode(code) }
    }

    // ---------- Đo, lịch sử ----------

    override fun measure(id: String, capability: String) {
        scope.launch {
            val d = manager.find(id) ?: return@launch
            val cap = runCatching { Capability.valueOf(capability) }.getOrNull() ?: return@launch
            val key = "$id/$capability"
            measureJobs[key]?.cancel()
            measureJobs[key] = launch {
                runCatching { d.measure(cap).collect { emitOnReading(readingMap(d.id, it)) } }
                measureJobs.remove(key)
            }
        }
    }

    override fun stopMeasure(id: String, capability: String) {
        scope.launch { measureJobs.remove("$id/$capability")?.cancel() }
    }

    override fun syncHistory(id: String, days: Double, promise: Promise) {
        scope.launch {
            val d = manager.find(id) ?: return@launch promise.reject("not_found", "Không có thiết bị $id")
            val progress = launch {
                d.syncProgress.collectLatest { p ->
                    if (p != null) emitOnSyncProgress(Arguments.createMap().apply {
                        putString("deviceId", d.id); putString("step", p.step); putInt("done", p.done); putInt("total", p.total)
                    })
                }
            }
            runCatching { d.syncHistory(days.toInt()) }
                .onSuccess { promise.resolve(historyMap(it)) }
                .onFailure { promise.reject("sync_failed", it.message, it) }
            progress.cancel()
        }
    }

    // ---------- Cài đặt ----------

    override fun getControls(id: String, promise: Promise) {
        scope.launch {
            val d = manager.find(id) as? ConfigurableDevice ?: return@launch promise.resolve(Arguments.createArray())
            promise.resolve(Arguments.createArray().apply { d.controls.value.forEach { pushMap(controlMap(it)) } })
        }
    }

    override fun setControl(id: String, controlId: String, value: ReadableMap, promise: Promise) {
        scope.launch {
            val d = manager.find(id) as? ConfigurableDevice ?: return@launch promise.reject("unsupported", "Thiết bị không có cài đặt")
            val v = when (value.getType("value")) {
                ReadableType.Boolean -> ControlValue.Bool(value.getBoolean("value"))
                ReadableType.Number -> ControlValue.Number(value.getDouble("value").toInt())
                ReadableType.Map -> value.getMap("value")!!.let { ControlValue.TimeRange(it.getInt("from"), it.getInt("to")) }
                else -> return@launch promise.reject("bad_value", "Giá trị không hợp lệ")
            }
            runCatching { d.setControl(controlId, v) }
                .onSuccess { promise.resolve(null) }
                .onFailure { promise.reject("control_failed", it.message, it) }
        }
    }

    override fun runAction(id: String, actionId: String, promise: Promise) {
        scope.launch {
            val d = manager.find(id) as? ConfigurableDevice ?: return@launch promise.reject("unsupported", "Thiết bị không có cài đặt")
            runCatching { d.runAction(actionId) }
                .onSuccess { promise.resolve(null) }
                .onFailure { promise.reject("action_failed", it.message, it) }
        }
    }

    // ---------- Thời tiết, gọi điện, danh bạ ----------

    override fun setWeather(id: String, forecast: ReadableMap, promise: Promise) {
        scope.launch {
            val d = manager.find(id) as? WeatherDisplay ?: return@launch promise.reject("unsupported", "Thiết bị không hiển thị thời tiết")
            val days = forecast.getArray("days")?.let { arr ->
                (0 until arr.size()).map { i ->
                    val m = arr.getMap(i)!!
                    WeatherDay(
                        runCatching { WeatherCondition.valueOf(m.getString("condition")!!) }.getOrDefault(WeatherCondition.CLOUDY),
                        m.getDouble("highC").toInt(), m.getDouble("lowC").toInt(),
                    )
                }
            }.orEmpty()
            val f = WeatherForecast(
                forecast.getString("city").orEmpty(), forecast.getDouble("currentC").toInt(),
                forecast.getDouble("humidity").toInt(), forecast.getDouble("uvIndex").toInt(), days,
            )
            runCatching { d.setWeather(f) }
                .onSuccess { promise.resolve(null) }
                .onFailure { promise.reject("weather_failed", it.message, it) }
        }
    }

    override fun syncContacts(id: String, contacts: ReadableArray, promise: Promise) {
        scope.launch {
            val d = (manager.find(id) as? ContactsSync)?.takeIf { it.supportsContacts }
                ?: return@launch promise.reject("unsupported", "Thiết bị không có danh bạ")
            val list = (0 until contacts.size()).mapNotNull { i ->
                contacts.getMap(i)?.let { Contact(it.getString("name").orEmpty(), it.getString("phone").orEmpty()) }
            }
            runCatching { d.syncContacts(list) { f -> event("transferProgress", id, mapOf("what" to "contacts", "fraction" to f.toDouble())) } }
                .onSuccess { promise.resolve(it.toDouble()) }
                .onFailure { promise.reject("contacts_failed", it.message, it) }
        }
    }

    override fun getCallBluetoothState(id: String, promise: Promise) {
        scope.launch {
            val d = (manager.find(id) as? CallAudioLink)?.takeIf { it.supportsCallAudio }
                ?: return@launch promise.reject("unsupported", "Thiết bị không gọi điện được")
            // `paired` theo hệ thống Android (cờ đồng hồ báo không đáng tin), driver đã tính.
            runCatching { d.callAudioState() }
                .onSuccess { s ->
                    promise.resolve(Arguments.createMap().apply {
                        putString("name", s.name); putString("address", s.address); putBoolean("enabled", s.enabled)
                        putBoolean("paired", s.paired); putBoolean("connected", s.connected)
                    })
                }
                .onFailure { promise.reject("call_failed", it.message, it) }
        }
    }

    override fun pairCallBluetooth(id: String, promise: Promise) {
        scope.launch {
            val d = (manager.find(id) as? CallAudioLink)?.takeIf { it.supportsCallAudio }
                ?: return@launch promise.reject("unsupported", "Thiết bị không gọi điện được")
            runCatching { d.pairCallAudio() }
                .onSuccess { promise.resolve(it) }
                .onFailure { promise.reject("pair_failed", it.message, it) }
        }
    }

    override fun setPhoneRinging(id: String, ringing: Boolean, promise: Promise) {
        scope.launch {
            val d = manager.find(id) as? ConfigurableDevice ?: return@launch promise.reject("not_found", "Không có thiết bị $id")
            d.setPhoneRinging(ringing)
            promise.resolve(null)
        }
    }

    // ---------- Sự kiện ----------

    // ---------- Cổng chung invoke (tính năng điện thoại ↔ thiết bị, xem SmartWearInvoke) ----------

    override fun invoke(method: String, deviceId: String, args: ReadableMap, promise: Promise) {
        scope.launch {
            try {
                val v = invoker.run(method, deviceId, args)
                promise.resolve(Arguments.createMap().apply { SmartWearInvoke.put(this, "value", v) })
            } catch (e: InvokeException) {
                promise.reject(e.code, e.message, e)
            } catch (e: kotlinx.coroutines.CancellationException) {
                throw e
            } catch (e: UnsupportedOperationException) {
                promise.reject("unsupported", e.message ?: "Không hỗ trợ", e)
            } catch (e: Exception) {
                promise.reject("failed", e.message ?: e.toString(), e)
            }
        }
    }

    private fun event(type: String, deviceId: String, body: Map<String, Any?>) {
        emitOnEvent(SmartWearInvoke.map(body + mapOf("type" to type, "deviceId" to deviceId)))
    }

    private fun publishScanState() {
        val s = invoker.scanState()
        if (s == lastScanState) return
        lastScanState = s
        event("scanState", "", s)
    }

    /** Gắn nghe cho mỗi thiết bị một lần: số đo thiết bị tự đẩy (HR 24h, đo trên đồng hồ…) và "tìm điện thoại". */
    private fun watch(d: WearableDevice) {
        if (!watched.add(d.id)) return
        scope.launch {
            val sent = mutableMapOf<Capability, Long>()
            d.latest.collect { latest ->
                for ((cap, r) in latest) {
                    if (sent[cap] == r.timestamp) continue
                    sent[cap] = r.timestamp
                    // Đang đo bằng measure() thì luồng đo đã gửi rồi.
                    if (measureJobs["${d.id}/${cap.name}"]?.isActive == true) continue
                    emitOnReading(readingMap(d.id, r))
                }
            }
        }
        val id = d.id
        (d as? CallDisplay)?.let { c -> scope.launch { c.rejectCallRequests.collect { event("rejectCall", id, emptyMap()) } } }
        (d as? MusicRemote)?.let { c -> scope.launch { c.musicCommands.collect { event("musicCommand", id, mapOf("command" to it.name)) } } }
        (d as? SmsQuickReply)?.let { c ->
            scope.launch { c.smsReplyRequests.collect { event("smsReplyRequest", id, mapOf("number" to it.number, "text" to it.text)) } }
        }
        (d as? RemoteCameraDevice)?.let { c -> scope.launch { c.remoteCameraEvents.collect { event("remoteCamera", id, mapOf("event" to it.name)) } } }
        (d as? DeviceEvents)?.let { c -> scope.launch { c.deviceEvents.collect { event("deviceEvent", id, mapOf("event" to it.name)) } } }
        (d as? WorkoutRemote)?.let { c ->
            scope.launch {
                c.workoutEvents.collect { e ->
                    event("workout", id, when (e) {
                        is WorkoutEvent.State -> mapOf("kind" to "state", "state" to e.state.name, "sportType" to e.sportType, "byDevice" to e.byDevice)
                        is WorkoutEvent.Realtime -> mapOf(
                            "kind" to "realtime", "sportType" to e.sportType, "heartRate" to e.heartRate, "calories" to e.calories,
                            "paceSecondsPerKm" to e.paceSecondsPerKm, "steps" to e.steps, "count" to e.count, "distanceMeters" to e.distanceMeters,
                        )
                    })
                }
            }
            scope.launch { c.locationRequests.collect { event("locationRequest", id, mapOf("start" to it.start, "sportType" to it.sportType)) } }
        }
        val c = d as? ConfigurableDevice ?: return
        scope.launch {
            c.findPhoneRequests.collect { ringing ->
                emitOnFindPhone(Arguments.createMap().apply { putString("deviceId", d.id); putBoolean("ringing", ringing) })
            }
        }
    }

    private fun publishDevices(m: DeviceManager) {
        val arr = devicesArray(m)
        val key = arr.toArrayList().toString()
        if (key == lastDevices) return
        lastDevices = key
        emitOnDevicesChanged(Arguments.createMap().apply { putArray("devices", devicesArray(m)) })
    }

    private fun publishDiscovered(m: DeviceManager) {
        val key = discoveredArray(m).toArrayList().toString()
        if (key == lastDiscovered) return
        lastDiscovered = key
        emitOnDiscovered(Arguments.createMap().apply { putArray("devices", discoveredArray(m)) })
    }

    private fun discoveredArray(m: DeviceManager): WritableArray = Arguments.createArray().apply {
        m.scanResults.value.forEach { e ->
            pushMap(Arguments.createMap().apply {
                putString("id", e.scanned.address); putString("name", e.scanned.name); putString("driver", e.driver.id)
                putString("model", e.match.model); putInt("rssi", e.scanned.rssi)
                // Quảng bá dịch vụ nhịp tim chuẩn 180D (dây đo nhịp tim, đồng hồ phát nhịp tim): lọc ở màn ghép khi bắt đầu chạy.
                putBoolean("heartRateService", com.smartwear.standard.Gatt.HEART_RATE in e.scanned.serviceUuids)
            })
        }
    }

    private fun devicesArray(m: DeviceManager): WritableArray = Arguments.createArray().apply {
        m.devices.value.forEach { d -> pushMap(deviceMap(m, d)) }
    }

    private fun deviceMap(m: DeviceManager, d: WearableDevice): WritableMap = Arguments.createMap().apply {
        putString("id", d.id)
        putString("name", d.name)
        putString("driver", d.driver.id)
        putString("model", d.info.value?.model)
        putString("state", d.state.value.name)
        putBoolean("kept", m.isKept(d.id))
        d.battery.value?.let { putInt("battery", it) } ?: putNull("battery")
        d.stats.value.rssi?.let { putInt("rssi", it) } ?: putNull("rssi")
        putString("firmware", d.info.value?.firmware)
        putArray("capabilities", Arguments.fromList(d.capabilities.value.map { it.name }.sorted()))
        putArray("measurable", Arguments.fromList(d.measurable.value.map { it.name }))
        putBoolean("supportsHistory", d.supportsHistory)
        putBoolean("supportsWeather", (d as? WeatherDisplay)?.supportsWeather == true)
        putBoolean("supportsContacts", (d as? ContactsSync)?.supportsContacts == true)
        putBoolean("supportsCallBluetooth", (d as? CallAudioLink)?.supportsCallAudio == true)
        putString("hardware", d.info.value?.hardware)
        d.charging.value?.let { putBoolean("charging", it) } ?: putNull("charging")
        putArray("measuring", Arguments.fromList(listOfNotNull(d.measuring.value?.name)))
        putMap("features", featuresMap(d))
        putInt("controlCount", (d as? ConfigurableDevice)?.controls?.value?.size ?: 0)
        putString("lastError", d.lastError.value)
        when (val p = d.pairingPrompt.value) {
            is PairingPrompt.EnterCode -> putMap("pairingPrompt", Arguments.createMap().apply {
                putString("type", "code"); putInt("digits", p.digits); putString("message", p.message)
            })
            is PairingPrompt.ConfirmOnDevice -> putMap("pairingPrompt", Arguments.createMap().apply {
                putString("type", "confirm"); putString("message", p.message)
            })
            null -> putNull("pairingPrompt")
        }
    }

    /** Cùng khoá với iOS (`DeviceFeatures` trong `types.ts`). */
    private fun featuresMap(d: WearableDevice): WritableMap = SmartWearInvoke.map(
        mapOf(
            "notifications" to ((d as? NotificationDisplay)?.supportsNotifications == true),
            "ancsAuthorized" to null,
            "incomingCall" to ((d as? CallDisplay)?.supportsIncomingCall == true),
            "rejectCall" to ((d as? CallDisplay)?.supportsRejectCall == true),
            "musicControl" to ((d as? MusicRemote)?.supportsMusicControl == true),
            "trackInfo" to ((d as? MusicRemote)?.supportsTrackInfo == true),
            "smsReply" to ((d as? SmsQuickReply)?.supportsSmsReply == true),
            "maxContacts" to ((d as? ContactsSync)?.takeIf { it.supportsContacts }?.maxContacts ?: 0),
            "clearContacts" to ((d as? ContactsSync)?.supportsClearContacts == true),
            "callAudio" to ((d as? CallAudioLink)?.supportsCallAudio == true),
            "watchFace" to ((d as? WatchFaceManager)?.supportsWatchFace == true),
            "watchFaceSlots" to ((d as? WatchFaceManager)?.supportsWatchFaceSlots == true),
            "customWatchFace" to (d is WatchFaceCustomizable),
            "workoutControl" to ((d as? WorkoutRemote)?.supportsWorkoutControl == true),
            "sportList" to ((d as? WorkoutRemote)?.supportsSportList == true),
            "phoneLocation" to ((d as? WorkoutRemote)?.supportsPhoneLocation == true),
            "remoteCamera" to ((d as? RemoteCameraDevice)?.supportsRemoteCamera == true),
            "firmwareUpdate" to ((d as? FirmwareUpdatable)?.supportsFirmwareUpdate == true),
            "alarms" to ((d as? AlarmClock)?.supportsAlarms == true),
            "heartRateStream" to ((d as? HeartRateStreaming)?.supportsHeartRateStream == true),
            "maxAlarms" to ((d as? AlarmClock)?.takeIf { it.supportsAlarms }?.maxAlarms ?: 0),
        ),
    )

    private fun readingMap(deviceId: String, r: Reading): WritableMap = Arguments.createMap().apply {
        putString("deviceId", deviceId)
        putString("capability", r.capability.name)
        putString("status", r.status.name)
        r.value?.let { putDouble("value", it) } ?: putNull("value")
        r.systolic?.let { putInt("systolic", it) } ?: putNull("systolic")
        r.diastolic?.let { putInt("diastolic", it) } ?: putNull("diastolic")
        putString("note", r.note)
        putDouble("timestamp", r.timestamp.toDouble())
        // Mỡ máu / acid uric / thành phần cơ thể: các chỉ số phụ (khoá xem `Reading.extra` trong types.ts).
        if (r.extra.isNotEmpty()) putMap("extra", Arguments.createMap().apply { r.extra.forEach { (k, v) -> putDouble(k, v) } })
    }

    private fun historyMap(h: DeviceHistory): WritableMap = Arguments.createMap().apply {
        putInt("days", h.days)
        putDouble("syncedAt", h.syncedAt.toDouble())
        h.today?.let { t ->
            putMap("today", Arguments.createMap().apply {
                putInt("steps", t.steps); putInt("calories", t.calories / 1000); putInt("distanceMeters", t.distanceMeters)
                t.activeMinutes?.let { putInt("activeMinutes", it) } ?: putNull("activeMinutes")
            })
        } ?: putNull("today")
        putMap("series", Arguments.createMap().apply {
            for ((cap, pts) in h.series) {
                putArray(cap.name, Arguments.createArray().apply {
                    pts.forEach { p ->
                        pushMap(Arguments.createMap().apply {
                            putDouble("t", p.timestamp.toDouble()); putDouble("v", p.value)
                            // vd huyết áp: "diastolic"; SpO2: "min"; bước: "calories"/"distance".
                            if (p.extra.isNotEmpty()) putMap("extra", Arguments.createMap().apply { p.extra.forEach { (k, v) -> putDouble(k, v) } })
                        })
                    }
                })
            }
        })
        putArray("sleep", Arguments.createArray().apply {
            h.sleep.forEach { s ->
                pushMap(Arguments.createMap().apply {
                    putDouble("start", s.start.toDouble()); putDouble("end", s.end.toDouble()); putBoolean("nap", s.nap)
                    putArray("segments", Arguments.createArray().apply {
                        s.segments.forEach { g ->
                            pushMap(Arguments.createMap().apply {
                                putDouble("start", g.start.toDouble()); putInt("minutes", g.minutes); putString("stage", g.stage.name)
                            })
                        }
                    })
                })
            }
        })
        putArray("workouts", Arguments.createArray().apply {
            h.workouts.forEach { w ->
                pushMap(Arguments.createMap().apply {
                    putInt("type", w.type); putString("name", w.name)
                    putDouble("start", w.start.toDouble()); putDouble("end", w.end.toDouble()); putInt("activeSeconds", w.activeSeconds)
                    w.steps?.let { putInt("steps", it) } ?: putNull("steps")
                    w.calories?.let { putInt("calories", it) } ?: putNull("calories")
                    w.distanceMeters?.let { putInt("distanceMeters", it) } ?: putNull("distanceMeters")
                    w.avgHeartRate?.let { putInt("avgHeartRate", it) } ?: putNull("avgHeartRate")
                    w.maxHeartRate?.let { putInt("maxHeartRate", it) } ?: putNull("maxHeartRate")
                    w.minHeartRate?.let { putInt("minHeartRate", it) } ?: putNull("minHeartRate")
                    w.paceSecondsPerKm?.let { putInt("paceSecondsPerKm", it) } ?: putNull("paceSecondsPerKm")
                })
            }
        })
        putArray("errors", Arguments.fromList(h.errors))
    }

    private fun controlMap(c: DeviceControl): WritableMap = Arguments.createMap().apply {
        putString("id", c.id); putString("group", c.group); putString("title", c.title)
        putString(
            "kind",
            when (c.kind) {
                DeviceControl.Kind.ACTION -> "action"; DeviceControl.Kind.TOGGLE -> "toggle"; DeviceControl.Kind.NUMBER -> "number"
                DeviceControl.Kind.TIME_RANGE -> "timeRange"; DeviceControl.Kind.CHOICE -> "choice"
            },
        )
        when (val v = c.value) {
            is ControlValue.Bool -> putBoolean("value", v.on)
            is ControlValue.Number -> putInt("value", v.value)
            is ControlValue.TimeRange -> putMap("value", Arguments.createMap().apply { putInt("from", v.fromMinute); putInt("to", v.toMinute) })
            null -> putNull("value")
        }
        putString("detail", c.detail)
        putInt("min", c.min); putInt("max", c.max); putInt("step", c.step); putString("unit", c.unit)
        putArray("options", Arguments.fromList(c.options))
        putBoolean("enabled", c.enabled)
        putString("confirm", c.confirm)
    }

    private suspend fun waitFor(timeoutMs: Long, cond: () -> Boolean): Boolean {
        val end = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < end) {
            if (cond()) return true
            delay(200)
        }
        return cond()
    }

    companion object {
        const val NAME = "SmartWear"

        @Volatile private var instance: DeviceManager? = null
        @Volatile private var link: PhoneLink? = null

        /** Phạm vi sống cùng tiến trình (không huỷ khi JS tải lại) cho PhoneLink và foreground service. */
        private val processScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

        /** Một PhoneLink cho cả tiến trình (thông báo, cuộc gọi, nhạc, SMS). */
        fun phoneLink(context: Context): PhoneLink = link ?: synchronized(this) {
            link ?: PhoneLink(context.applicationContext, shared(context), processScope).also { link = it }
        }

        /** Một DeviceManager cho cả tiến trình. Thứ tự driver: cụ thể trước, Bluetooth chuẩn sau cùng. */
        fun shared(context: Context): DeviceManager = instance ?: synchronized(this) {
            instance ?: DeviceManager(context.applicationContext, DeviceRegistry(listOf(QRingDriver, GloryFitDriver, VeepooDriver, StandardDriver))).also { instance = it }
        }
    }
}
