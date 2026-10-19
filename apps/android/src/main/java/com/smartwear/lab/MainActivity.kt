package com.smartwear.lab

import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.util.Log
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.lifecycle.lifecycleScope
import com.smartwear.core.BlePermissions
import com.smartwear.core.Capability
import com.smartwear.core.ConnectionState
import com.smartwear.core.SmartWearLog
import com.smartwear.lab.ui.AppScreen
import com.smartwear.lab.ui.SmartWearTheme
import com.smartwear.lab.ui.StartRoute
import com.smartwear.lab.ui.Tab
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

class MainActivity : ComponentActivity() {

    private val manager get() = (application as SmartWearApp).manager

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge(SystemBarStyle.dark(android.graphics.Color.TRANSPARENT), SystemBarStyle.dark(android.graphics.Color.TRANSPARENT))
        val needed = BlePermissions.required().toList() +
            if (Build.VERSION.SDK_INT >= 33) listOf(android.Manifest.permission.POST_NOTIFICATIONS) else emptyList()
        val missing = needed.filter { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
        if (missing.isNotEmpty()) requestPermissions(missing.toTypedArray(), 1)
        (application as SmartWearApp).bindConnectionService()

        val start = StartRoute(
            tab = intent.getStringExtra("tab")?.let { name -> Tab.entries.firstOrNull { it.name.equals(name, true) } } ?: Tab.DEVICES,
            deviceId = intent.getStringExtra("detail"),
            watchFaceEditor = intent.getBooleanExtra("faceEditor", false),
        )
        setContent { SmartWearTheme { AppScreen(manager, start) } }
        if (savedInstanceState == null) autoRun()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (BlePermissions.granted(this)) manager.reconnectSaved()
    }

    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        autoRun()
    }

    /**
     * Chạy tự động qua adb, chỉ kết nối đúng các MAC chỉ định:
     *   adb shell am start -n com.smartwear.lab/.MainActivity \
     *     --es connect 30:32:43:31:84:04,32:35:45:37:4E:00 --es measure HEART_RATE [--es tab lab] [--es detail <mac>]
     */
    private fun autoRun() {
        val action = intent.getStringExtra("action")
        // OTA firmware Y25 (xem OtaCommands; log tag SmartWear, tiền tố "OTA"):
        //   kiểm file, không Bluetooth:   --es action otaCheck --es file <đường dẫn .bin trên điện thoại>
        //   huỷ phiên đang chạy:          --es action otaCancel
        //   chỉ đọc năng lực DFU:         --es connect <MAC> --es action otaProbe
        //   nạp:                          --es connect <MAC> --es action ota --es file <đường dẫn>
        //                                 [--el otaDelay 10] [--ez otaNoActivate true] [--ei battery 80] [--ez otaTrace true] [--ez otaAnyModel true]
        when (action) {
            "otaCheck" -> { OtaCommands.check(intent.getStringExtra("file")); return }
            "otaCancel" -> { OtaCommands.cancel(); return }
            // Ép popup "thiết bị ở gần" (thử mô hình 3D khi đồng hồ không quảng bá).
            "nearbyDemo" -> { com.smartwear.lab.ui.NearbyPrompt.demoAddress = intent.getStringExtra("mac") ?: "78:02:B7:03:6E:1B"; return }
        }
        // File sai thì dừng trước khi quét/kết nối.
        val otaImage = if (action == "ota") OtaCommands.check(intent.getStringExtra("file")) ?: return else null
        // Mỗi mục là MAC (có dấu ':') hoặc tiền tố tên thiết bị.
        val targets = intent.getStringExtra("connect")?.split(',')?.map { it.trim() }?.filter { it.isNotEmpty() } ?: run {
            if (action == "ota" || action == "otaProbe") SmartWearLog.i("OTA thiếu --es connect <MAC đồng hồ>")
            return
        }
        // Gỡ lỗi truyền mặt đồng hồ: --ez faceTrace true --ei facePacket 128 --el faceDelay 10 --ez faceNoRetry true --ez faceAuto false
        com.smartwear.gloryfit.GloryFitDebug.trace = intent.getBooleanExtra("faceTrace", false)
        com.smartwear.gloryfit.GloryFitDebug.packetLength = intent.getIntExtra("facePacket", 0).takeIf { it > 0 }
        com.smartwear.gloryfit.GloryFitDebug.packetDelayMs = intent.getLongExtra("faceDelay", 0)
        com.smartwear.gloryfit.GloryFitDebug.noRetry = intent.getBooleanExtra("faceNoRetry", false)
        // Đồng bộ lịch sử từ mốc thời gian (F4 0x2000), mặc định tắt: --ez syncSince true
        com.smartwear.gloryfit.GloryFitDebug.syncSince = intent.getBooleanExtra("syncSince", false)
        // OTA: mặc định không tự cài mặt đồng hồ khi kết nối (tránh truyền file lớn song song với DFU).
        (application as SmartWearApp).watchFaces.paused = !intent.getBooleanExtra("faceAuto", action != "ota" && action != "otaProbe")
        fun matches(t: String, e: com.smartwear.core.ScanEntry) =
            if (':' in t) e.scanned.address.equals(t, true) else e.scanned.name.orEmpty().startsWith(t, true)
        val measure = intent.getStringExtra("measure")?.let { Capability.valueOf(it) }
        val scanMs = (intent.getStringExtra("scanSeconds")?.toLongOrNull() ?: 25) * 1_000
        lifecycleScope.launch {
            log("Tự động: tìm ${targets.joinToString()}")
            manager.startScan(scanMs)
            val found = withTimeoutOrNull(scanMs) {
                manager.scanResults.first { results -> targets.all { t -> results.any { matches(t, it) } } }
            } ?: manager.scanResults.value
            val entries = found.filter { e -> targets.any { matches(it, e) } }
            log("Thấy ${entries.size}/${targets.size}: ${entries.joinToString { "${it.match.model} (${it.driver.id})" }}")
            manager.connect(entries)
            // Chờ đến khi mọi thiết bị đã kết nối (DeviceManager tự thử lại tối đa 3 lần).
            withTimeoutOrNull(150_000) {
                // Chỉ chờ các thiết bị được chỉ định (thiết bị đã lưu khác có thể không bao giờ nối được).
                fun targeted(d: com.smartwear.core.WearableDevice) =
                    entries.any { it.scanned.address.equals(d.id, true) } || targets.any { ':' in it && it.equals(d.id, true) }
                while (manager.devices.value.any { targeted(it) && it.state.value != ConnectionState.CONNECTED }) {
                    manager.devices.value.forEach { d -> d.pairingPrompt.value?.let { log("${d.name} chờ ghép nối: $it") } }
                    delay(1_000)
                }
            }
            for (d in manager.devices.value) {
                log("${d.name}: ${d.state.value} hw=${d.info.value?.hardware} fw=${d.info.value?.firmware} pin=${d.battery.value} sạc=${d.charging.value} " +
                    "caps=${d.capabilities.value} lỗi=${d.lastError.value}")
            }
            val syncDays = intent.getStringExtra("sync")?.toIntOrNull()
            if (syncDays != null) {
                val ready = manager.devices.value.filter { it.state.value == ConnectionState.CONNECTED && it.supportsHistory }
                ready.forEach { manager.syncHistory(it, syncDays) }
                delay(500)
                withTimeoutOrNull(180_000) { while (ready.any { it.syncProgress.value != null }) delay(500) }
                for (d in ready) {
                    val h = d.history.value ?: continue
                    log("Lịch sử ${d.name}: " + h.series.entries.joinToString { "${it.key}=${it.value.size}" } +
                        " ngủ=${h.sleep.size} hôm nay=${h.today} lỗi=${h.errors}")
                    h.sleep.forEach { s -> log("  ngủ ${java.util.Date(s.start)} → ${java.util.Date(s.end)} ngủ ${s.asleepMinutes} phút, ${s.segments.size} đoạn") }
                }
            }
            val faceImage by lazy { assets.open("watchface_default.png").use { android.graphics.BitmapFactory.decodeStream(it) } }
            when (action) {
                "otaProbe", "ota" -> runOta(action, targets, entries, otaImage)
                "faceDryRun" -> devicesOf<com.smartwear.core.WatchFaceCustomizable>().forEach { (_, d) ->
                    runCatching {
                        val spec = d.watchFaceSpec()
                        val style = faceStyle()
                        val preview = d.renderWatchFace(faceImage, spec, style)
                        java.io.File(getExternalFilesDir(null), "watchface_preview.png").outputStream().use { preview.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
                        log("Thử mặt đồng hồ: $spec, file ${d.watchFaceSize(faceImage, spec, style)} byte")
                    }.onFailure { log("Thử mặt đồng hồ lỗi: ${it.message}") }
                }
                "watchface" -> devicesOf<com.smartwear.core.WatchFaceCustomizable>().forEach { (w, d) ->
                    var last = -1
                    runCatching {
                        d.setWatchFace(faceImage, faceStyle()) { p ->
                            val pct = (p * 100).toInt()
                            if (pct / 10 != last / 10) { last = pct; log("Gửi mặt đồng hồ: $pct %") }
                        }
                    }.onSuccess { log("Đã cài mặt đồng hồ lên ${w.name}") }
                        .onFailure { log("Cài mặt đồng hồ lỗi: ${it.message}") }
                }
                // File .bin dựng sẵn: `--es action faceBin --es file <đường dẫn trên máy>` (ví dụ /sdcard/Android/data/<pkg>/files/x.bin).
                "faceBin" -> devicesOf<com.smartwear.core.WatchFaceManager>().forEach { (w, d) ->
                    var last = -1
                    runCatching {
                        val bin = java.io.File(requireNotNull(intent.getStringExtra("file")) { "thiếu --es file" }).readBytes()
                        d.installWatchFace(bin) { p ->
                            val pct = (p * 100).toInt()
                            if (pct / 10 != last / 10) { last = pct; log("Gửi file mặt đồng hồ: $pct %") }
                        }
                    }.onSuccess { log("Đã cài file mặt đồng hồ lên ${w.name}") }
                        .onFailure { log("Cài file mặt đồng hồ lỗi: ${it.message}") }
                }
                // Bộ trong thư viện: `--es action facePreset --es preset peacock-3d` (cài và đặt làm mặc định).
                "facePreset" -> devicesOf<com.smartwear.core.WatchFaceManager>().forEach { (d, _) ->
                    var last = -1
                    val id = intent.getStringExtra("preset") ?: WatchFaceLibrary.DEFAULT_ID
                    runCatching {
                        (application as SmartWearApp).watchFaces.installPreset(d, id) { p ->
                            val pct = (p * 100).toInt()
                            if (pct / 10 != last / 10) { last = pct; log("Cài $id: $pct %") }
                        }
                    }.onSuccess { log("Đã cài $id lên ${d.name} và đặt làm mặc định") }
                        .onFailure { log("Cài $id lỗi: ${it.message}") }
                }
                "dialInfo" -> devicesOf<com.smartwear.core.WatchFaceManager>().forEach { (w, d) ->
                    runCatching { d.watchFaceInfo() }
                        .onSuccess { log("Mặt đồng hồ ${w.name}: $it") }
                        .onFailure { log("26 01 lỗi: ${it.message}") }
                }
                // Chỉ đọc, để thử trên đồng hồ thật: khe mặt (26 09 / 26 05), danh sách môn (FD 48 AA), ngôn ngữ + phím tắt
                // (AF AA, BE 01/02), trạng thái dữ liệu (33F3), bài tập đang chạy (FD AA).
                "faceSlots" -> devicesOf<com.smartwear.core.WatchFaceManager>().forEach { (w, d) ->
                    runCatching { d.watchFaceSlots() }
                        .onSuccess { log("Khe mặt đồng hồ ${w.name}: $it") }
                        .onFailure { log("Khe mặt đồng hồ lỗi: ${it.message}") }
                }
                "sportList" -> devicesOf<com.smartwear.core.WorkoutRemote>().forEach { (w, d) ->
                    runCatching { d.sportTypes() }
                        .onSuccess { log("Môn trên ${w.name}: ${it.size} môn, hiện ${(w as? com.smartwear.gloryfit.GloryFitDevice)?.sportListLimits}: $it") }
                        .onFailure { log("FD 48 AA lỗi: ${it.message}") }
                }
                "deviceRead" -> devicesOf<com.smartwear.core.ConfigurableDevice>().forEach { (w, d) ->
                    runCatching { d.runAction("device.read") }
                        .onSuccess {
                            d.controls.value.filter { it.id == "language" || it.id.startsWith("shortcut.") }
                                .forEach { c -> log("${w.name} ${c.id} \"${c.title}\" = ${c.value} ${c.detail.orEmpty()}") }
                        }
                        .onFailure { log("Đọc cài đặt lỗi: ${it.message}") }
                }
                // Gỡ lỗi, chỉ lệnh đọc: --es action raw --es hex "FD 48 AA" [--ez ble5 true] [--ez noRsp true]
                "raw" -> manager.devices.value.filterIsInstance<com.smartwear.gloryfit.GloryFitDevice>().forEach { d ->
                    val bytes = intent.getStringExtra("hex").orEmpty().trim().split(" ").filter { it.isNotEmpty() }.map { it.toInt(16).toByte() }.toByteArray()
                    runCatching { d.debugExchange(bytes, intent.getBooleanExtra("ble5", false), !intent.getBooleanExtra("noRsp", false)) }
                        .onSuccess { r -> log("raw ${intent.getStringExtra("hex")} → ${r.size} gói: ${r.joinToString(" | ") { p -> p.joinToString(" ") { "%02X".format(it) } }}") }
                        .onFailure { log("raw lỗi: ${it.message}") }
                }
                // Vòng tay Veepoo, chỉ lệnh đọc: --es action vraw --es hex "B8 02" [--el listen 3000] [--ez anyOp true]
                "vraw" -> manager.devices.value.filterIsInstance<com.smartwear.veepoo.VeepooDevice>().filter { it.state.value == ConnectionState.CONNECTED }.forEach { d ->
                    for (cmd in intent.getStringExtra("hex").orEmpty().split(',').map { it.trim() }.filter { it.isNotEmpty() }) {
                        val bytes = cmd.split(" ").filter { it.isNotEmpty() }.map { it.toInt(16).toByte() }.toByteArray()
                        runCatching { d.debugExchange(bytes, intent.getLongExtra("listen", 3_000), intent.getBooleanExtra("anyOp", false)) }
                            .onSuccess { r -> log("vraw $cmd → ${r.size} gói: ${r.joinToString(" | ") { p -> p.joinToString(" ") { "%02X".format(it) } }}") }
                            .onFailure { log("vraw $cmd lỗi: ${it.message}") }
                    }
                }
                // Báo thức (AlarmClock): --es action alarms | alarmAdd --ei hour 7 --ei minute 30 [--ei repeat 31] [--es label "…"] [--ei id 2]
                //   | alarmDelete --ei id 2
                "alarms", "alarmAdd", "alarmDelete" -> devicesOf<com.smartwear.core.AlarmClock>().forEach { (w, d) ->
                    runCatching {
                        if (!d.supportsAlarms) return@runCatching log("${w.name}: không có báo thức")
                        when (action) {
                            "alarmAdd" -> d.setAlarm(com.smartwear.core.Alarm(intent.getIntExtra("id", -1), intent.getIntExtra("hour", 7),
                                intent.getIntExtra("minute", 0), intent.getIntExtra("repeat", 0), true, intent.getStringExtra("label")))
                            "alarmDelete" -> d.deleteAlarm(intent.getIntExtra("id", -1))
                        }
                        val list = d.alarms()
                        log("${w.name} báo thức (${list.size}/${d.maxAlarms}): ${list.joinToString(" | ")}")
                    }.onFailure { log("$action ${w.name} lỗi: ${it.message}") }
                }
                // Thử interface core trên mọi thiết bị đang kết nối (lọc theo --es only <driverId> nếu cần):
                //   --es action notify --es app zalo --es title "Tên" --es text "Nội dung"
                //   --es action sms --es title "Người gửi" --es text "Nội dung"
                //   --es action call --es title "Tên" --es number 0901234567 [--ei seconds 8]
                //   --es action find | camera [--ei seconds 20] | controls | music --es title "Bài" --es text "Ca sĩ"
                //   --es action setControl --es id unit.hour24 --es value true|12|480-1320
                "notify", "sms", "call", "find", "camera", "controls", "setControl", "music", "events" -> {
                    val only = intent.getStringExtra("only")
                    val ready = manager.devices.value.filter { it.state.value == ConnectionState.CONNECTED && (only == null || it.driver.id == only) }
                    for (d in ready) runCatching {
                        when (action) {
                            "notify" -> (d as? com.smartwear.core.NotificationDisplay)?.let {
                                log("${d.name} apps: ${it.notificationApps().joinToString { a -> a.key + if (a.hasIcon) "" else "(khác)" }}")
                                log("${d.name} notify → ${it.sendNotification(intent.getStringExtra("app") ?: "zalo", intent.getStringExtra("title").orEmpty(), intent.getStringExtra("text").orEmpty())}")
                            }
                            "sms" -> (d as? com.smartwear.core.NotificationDisplay)?.let {
                                log("${d.name} sms → ${it.sendSms(intent.getStringExtra("title").orEmpty(), intent.getStringExtra("text").orEmpty())}")
                            }
                            "call" -> (d as? com.smartwear.core.CallDisplay)?.let { c ->
                                val watch = launch { c.rejectCallRequests.collect { log("${d.name}: người dùng từ chối cuộc gọi trên thiết bị") } }
                                log("${d.name} call → ${c.incomingCall(intent.getStringExtra("title").orEmpty(), intent.getStringExtra("number"))}")
                                delay(intent.getIntExtra("seconds", 8) * 1_000L)
                                c.callEnded()
                                watch.cancel()
                                log("${d.name} callEnded")
                            }
                            "find" -> (d as? com.smartwear.core.ConfigurableDevice)?.runAction("find.start")?.also { log("${d.name} find.start đã gửi") }
                            "camera" -> (d as? com.smartwear.core.RemoteCameraDevice)?.let { c ->
                                val watch = launch { c.remoteCameraEvents.collect { log("${d.name} camera: $it") } }
                                c.setRemoteCamera(true)
                                log("${d.name} camera mở, chờ ${intent.getIntExtra("seconds", 20)} s")
                                delay(intent.getIntExtra("seconds", 20) * 1_000L)
                                c.setRemoteCamera(false)
                                watch.cancel()
                            }
                            "events" -> {
                                val jobs = listOfNotNull(
                                    (d as? com.smartwear.core.MusicRemote)?.let { m -> launch { m.musicCommands.collect { log("${d.name} nhạc: $it") } } },
                                    (d as? com.smartwear.core.ConfigurableDevice)?.let { m -> launch { m.findPhoneRequests.collect { log("${d.name} tìm điện thoại: $it") } } },
                                    (d as? com.smartwear.core.DeviceEvents)?.let { m -> launch { m.deviceEvents.collect { log("${d.name} sự kiện: $it") } } },
                                    (d as? com.smartwear.core.RemoteCameraDevice)?.let { m -> launch { m.remoteCameraEvents.collect { log("${d.name} camera: $it") } } },
                                )
                                log("${d.name}: nghe sự kiện ${intent.getIntExtra("seconds", 30)} s")
                                delay(intent.getIntExtra("seconds", 30) * 1_000L)
                                jobs.forEach { it.cancel() }
                            }
                            "controls" -> (d as? com.smartwear.core.ConfigurableDevice)?.controls?.value?.forEach { c ->
                                log("${d.name} [${c.group}] ${c.id} \"${c.title}\" ${c.kind} = ${c.value}${if (c.enabled) "" else " (khoá)"}")
                            }
                            "setControl" -> (d as? com.smartwear.core.ConfigurableDevice)?.let { c ->
                                val id = intent.getStringExtra("id").orEmpty()
                                val raw = intent.getStringExtra("value").orEmpty()
                                val v: com.smartwear.core.ControlValue = when {
                                    raw == "true" || raw == "false" -> com.smartwear.core.ControlValue.Bool(raw == "true")
                                    '-' in raw -> raw.split('-').let { com.smartwear.core.ControlValue.TimeRange(it[0].toInt(), it[1].toInt()) }
                                    else -> com.smartwear.core.ControlValue.Number(raw.toInt())
                                }
                                c.setControl(id, v)
                                log("${d.name} setControl $id = $v → ${c.controls.value.firstOrNull { it.id == id }?.value}")
                            }
                            "music" -> (d as? com.smartwear.core.MusicRemote)?.let { m ->
                                m.setMusicState(com.smartwear.core.MusicState(true, intent.getStringExtra("title"), intent.getStringExtra("text"), 60))
                                log("${d.name} music state đã gửi (supports=${m.supportsMusicControl}/${m.supportsTrackInfo})")
                            }
                        }
                    }.onFailure { log("$action ${d.name} lỗi: ${it.message}") }
                }
                "dataStatus" -> manager.devices.value.filterIsInstance<com.smartwear.gloryfit.GloryFitDevice>().forEach { d ->
                    log("33F3 ${d.name}: ${runCatching { d.readDataStatus() }.getOrElse { "lỗi ${it.message}" }}")
                }
                "workoutQuery" -> manager.devices.value.filterIsInstance<com.smartwear.gloryfit.GloryFitDevice>().forEach { d ->
                    log("FD AA ${d.name}: ${runCatching { d.queryWorkout() }.getOrElse { "lỗi ${it.message}" }}")
                }
                // Điều khiển bài tập (đồng hồ ghi một bài tập): --es action workoutStart --ei sport 9 [--ei seconds 60]
                "workoutStart", "workoutPause", "workoutResume", "workoutStop" -> devicesOf<com.smartwear.core.WorkoutRemote>().forEach { (w, d) ->
                    val watch = launch {
                        kotlinx.coroutines.flow.merge(
                            d.workoutEvents,
                            (w as? com.smartwear.core.DeviceEvents)?.deviceEvents ?: kotlinx.coroutines.flow.emptyFlow(),
                            d.locationRequests,
                        ).collect { log("${w.name} sự kiện: $it") }
                    }
                    runCatching {
                        when (action) {
                            "workoutStart" -> d.startWorkout(intent.getIntExtra("sport", 9))
                            "workoutPause" -> d.pauseWorkout()
                            "workoutResume" -> d.resumeWorkout()
                            else -> d.stopWorkout()
                        }
                    }.onSuccess { log("$action ${w.name}: đã gửi") }.onFailure { log("$action ${w.name} lỗi: ${it.message}") }
                    delay(intent.getIntExtra("seconds", 20) * 1_000L)
                    watch.cancel()
                }
            }
            // Đo lần lượt, in từng giá trị: --es measures HEART_RATE,SPO2,BLOOD_PRESSURE
            intent.getStringExtra("measures")?.split(',')?.map { Capability.valueOf(it.trim()) }?.forEach { cap ->
                for (d in manager.devices.value.filter { it.state.value == ConnectionState.CONNECTED && cap in it.measurable.value }) {
                    log("Đo $cap trên ${d.name}…")
                    runCatching { withTimeoutOrNull(120_000) { d.measure(cap).collect { r -> log("  $cap ${d.name}: $r") } } }
                        .onFailure { log("  $cap ${d.name} lỗi: ${it.message}") }
                }
            }
            if (measure != null) {
                delay(1_000)
                log("Đo đồng loạt $measure trên ${manager.measureAll(measure)} thiết bị")
            }
        }
    }

    /**
     * Chọn đúng MỘT đồng hồ GloryFit theo `--es connect` rồi chạy OTA trên kết nối DFU riêng (kết nối UTE giữ nguyên).
     * Mặc định chỉ nhận thiết bị tên `Y25…` (firmware RB370L73AC là của Y25); `--ez otaAnyModel true` để bỏ chặn.
     */
    private fun runOta(action: String, targets: List<String>, entries: List<com.smartwear.core.ScanEntry>, image: com.smartwear.gloryfit.ota.RealtekImage?) {
        fun stop(reason: String) { SmartWearLog.i("OTA dừng: $reason") }
        fun matches(t: String, id: String, name: String?) = if (':' in t) id.equals(t, true) else name.orEmpty().startsWith(t, true)
        val glory = manager.devices.value.filter { it is com.smartwear.core.FirmwareUpdatable }
            .filter { d -> targets.any { matches(it, d.id, d.name) } }
        if (glory.size > 1) return stop("${glory.size} đồng hồ khớp ${targets.joinToString()}, chỉ định đúng một MAC")
        val driver = glory.singleOrNull()
        val address = driver?.id ?: targets.singleOrNull { ':' in it }
            ?: return stop("không tìm thấy đồng hồ GloryFit khớp ${targets.joinToString()}; dùng --es connect <MAC>")
        val device = OtaCommands.remoteDevice(this, address) ?: return stop("địa chỉ $address không hợp lệ")
        @android.annotation.SuppressLint("MissingPermission")
        val name = driver?.name ?: entries.firstOrNull { it.scanned.address.equals(address, true) }?.scanned?.name
            ?: runCatching { device.name }.getOrNull()
        if (!intent.getBooleanExtra("otaAnyModel", false) && name?.startsWith("Y25", true) != true)
            return stop("$address tên \"$name\" không phải Y25; firmware này chỉ dành cho Y25 (--ez otaAnyModel true để bỏ chặn)")
        val connected = driver?.state?.value == ConnectionState.CONNECTED
        SmartWearLog.i("OTA đích $name $address, kết nối UTE ${if (connected) "đang mở (giữ nguyên)" else "không có"}")
        when (action) {
            "otaProbe" -> OtaCommands.probe(this, device)
            "ota" -> OtaCommands.flash(
                this, device, image ?: return,
                batteryHint = if (connected) driver?.battery?.value else null,
                options = com.smartwear.gloryfit.ota.RealtekDfuClient.Options(
                    packetDelayMs = intent.getLongExtra("otaDelay", 10).coerceIn(0, 1_000),
                    activate = !intent.getBooleanExtra("otaNoActivate", false),
                    declaredBattery = intent.getIntExtra("battery", -1).takeIf { it in 0..100 },
                    trace = intent.getBooleanExtra("otaTrace", false),
                ),
            )
        }
    }

    /** Style thử từ adb: `--es face all` bật mọi thành phần (kể cả thử nghiệm). */
    private fun faceStyle() = when (intent.getStringExtra("face")) {
        "all" -> com.smartwear.core.WatchFaceStyle(hour12 = true, complications = com.smartwear.core.Complication.entries.toSet())
        "verified" -> com.smartwear.core.WatchFaceStyle(complications = com.smartwear.core.Complication.entries.filter { it.verified }.toSet())
        else -> com.smartwear.core.WatchFaceStyle()
    }

    /** Thiết bị đang quản lý cài interface [T] (cặp thiết bị, interface). */
    private inline fun <reified T> devicesOf(): List<Pair<com.smartwear.core.WearableDevice, T>> =
        manager.devices.value.mapNotNull { d -> (d as? T)?.let { d to it } }

    private fun log(message: String) = Log.i("Sample", message)
}
