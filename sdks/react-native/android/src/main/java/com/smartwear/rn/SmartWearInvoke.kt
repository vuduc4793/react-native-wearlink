package com.smartwear.rn

import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import android.net.Uri
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.bridge.WritableArray
import com.facebook.react.bridge.WritableMap
import com.smartwear.core.Alarm
import com.smartwear.core.AlarmClock
import com.smartwear.core.CallAudioLink
import com.smartwear.core.CallDisplay
import com.smartwear.core.Complication
import com.smartwear.core.ConnectionState
import com.smartwear.core.ContactsSync
import com.smartwear.core.DeviceManager
import com.smartwear.core.FirmwareUpdatable
import com.smartwear.core.MusicRemote
import com.smartwear.core.MusicState
import com.smartwear.core.NotificationDisplay
import com.smartwear.core.RemoteCameraDevice
import com.smartwear.core.SmsQuickReply
import com.smartwear.core.SportType
import com.smartwear.core.TimePosition
import com.smartwear.core.WatchFaceCustomizable
import com.smartwear.core.WatchFaceManager
import com.smartwear.core.WatchFaceStyle
import com.smartwear.core.WearableDevice
import com.smartwear.core.WorkoutRemote
import com.smartwear.core.phone.KeepConnectedService
import com.smartwear.core.phone.PhoneLink
import java.io.File

/** Lỗi trả về JS với mã [code] (`unsupported`, `not_found`, `bad_value`, `failed`, `unknown_method`). */
class InvokeException(val code: String, message: String) : Exception(message)

/**
 * Cổng chung `invoke` (Android) cho các tính năng điện thoại ↔ thiết bị. Cùng tên lệnh, hình dạng `args` và kết quả với
 * `SmartWearImpl.swift` (iOS) và `src/index.ts`. Mỗi lệnh đi qua interface core, không ép kiểu theo hãng.
 */
internal class SmartWearInvoke(
    private val context: Context,
    private val manager: DeviceManager,
    private val phoneLink: () -> PhoneLink,
    private val event: (type: String, deviceId: String, body: Map<String, Any?>) -> Unit,
    private val history: (com.smartwear.core.DeviceHistory) -> WritableMap,
) {

    suspend fun run(method: String, id: String, a: ReadableMap): Any? {
        // ---------- Lệnh cấp module ----------
        when (method) {
            "getScanState" -> return scanState()
            "getPhoneLinkConfig" -> return phoneLink().config.value.let { c ->
                mapOf("apps" to c.apps.sorted(), "sms" to c.sms, "calls" to c.calls, "music" to c.music, "smsReply" to c.smsReply)
            }
            "setPhoneLinkConfig" -> {
                val link = phoneLink()
                if (a.hasKey("apps")) {
                    val want = a.getArray("apps")?.toArrayList()?.map { it.toString() }?.toSet().orEmpty()
                    val have = link.config.value.apps
                    (have - want).forEach { link.setApp(it, false) }
                    (want - have).forEach { link.setApp(it, true) }
                }
                if (a.hasKey("sms")) link.setSms(a.getBoolean("sms"))
                if (a.hasKey("calls")) link.setCalls(a.getBoolean("calls"))
                if (a.hasKey("music")) link.setMusic(a.getBoolean("music"))
                if (a.hasKey("smsReply")) link.setSmsReply(a.getBoolean("smsReply"))
                return null
            }
            "hasNotificationAccess" -> return PhoneLink.hasNotificationAccess(context)
            "openNotificationAccessSettings" -> {
                context.startActivity(PhoneLink.notificationAccessSettingsIntent().addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                return null
            }
            "setForegroundService" -> {
                val on = a.getBoolean("enabled")
                foregroundServiceEnabled(context, on)
                if (on) {
                    if (manager.keepConnected.value > 0) runCatching { KeepConnectedService.start(context) }
                } else {
                    KeepConnectedService.stop(context)
                }
                return null
            }
        }

        val d = manager.find(id) ?: throw InvokeException("not_found", "Không có thiết bị $id")
        return when (method) {
            "refreshBattery" -> {
                if (d.state.value == ConnectionState.CONNECTED) d.refreshBattery()
                d.battery.value
            }
            "getHistory" -> d.history.value?.let(history)

            // ---------- Thông báo, cuộc gọi, SMS ----------
            "getNotificationApps" -> need<NotificationDisplay>(d, "thông báo") { it.supportsNotifications }.notificationApps().map {
                mapOf("key" to it.key, "name" to it.name, "packages" to it.packages, "hasIcon" to it.hasIcon)
            }
            "sendNotification" -> need<NotificationDisplay>(d, "thông báo") { it.supportsNotifications }
                .sendNotification(str(a, "appKey"), str(a, "title"), str(a, "text"))
            "sendSms" -> need<NotificationDisplay>(d, "thông báo") { it.supportsNotifications }.sendSms(str(a, "sender"), str(a, "text"))
            "notifyIncomingCall" -> need<CallDisplay>(d, "báo cuộc gọi") { it.supportsIncomingCall }
                .incomingCall(str(a, "name"), optStr(a, "number"))
            "notifyCallEnded" -> need<CallDisplay>(d, "báo cuộc gọi") { it.supportsIncomingCall }.callEnded().let { null }
            "getSmsReply" -> need<SmsQuickReply>(d, "trả lời SMS") { it.supportsSmsReply }.let { s ->
                val c = s.smsReply.value
                mapOf("enabled" to c.enabled, "templates" to c.templates, "fixedTemplates" to s.smsReplyFixedTemplates, "maxCustom" to s.smsReplyMaxCustom)
            }
            "setSmsReply" -> need<SmsQuickReply>(d, "trả lời SMS") { it.supportsSmsReply }
                .setSmsReply(a.getBoolean("enabled"), a.getArray("templates")?.toArrayList()?.map { it.toString() }.orEmpty()).let { null }
            "sendSmsReplyResult" -> need<SmsQuickReply>(d, "trả lời SMS") { it.supportsSmsReply }.sendSmsReplyResult(a.getBoolean("ok")).let { null }

            // ---------- Nhạc ----------
            "setMusicState" -> need<MusicRemote>(d, "nhạc") { it.supportsMusicControl || it.supportsTrackInfo }.setMusicState(
                MusicState(
                    playing = a.hasKey("playing") && a.getBoolean("playing"),
                    title = optStr(a, "title"), artist = optStr(a, "artist"), volumePercent = optInt(a, "volumePercent"),
                    durationSec = optInt(a, "durationSec"), positionSec = optInt(a, "positionSec"),
                ),
            ).let { null }
            "setMusicVolume" -> need<MusicRemote>(d, "nhạc") { it.supportsMusicControl }.setMusicVolume(optInt(a, "percent") ?: 0).let { null }

            // ---------- Danh bạ, gọi điện Bluetooth ----------
            "clearContacts" -> need<ContactsSync>(d, "xoá danh bạ") { it.supportsClearContacts }.clearContacts().let { null }
            "setCallBluetooth" -> need<CallAudioLink>(d, "gọi điện Bluetooth") { it.supportsCallAudio }.setCallAudio(a.getBoolean("on")).let { null }

            // ---------- Mặt đồng hồ ----------
            "getWatchFaceInfo" -> need<WatchFaceManager>(d, "mặt đồng hồ") { it.supportsWatchFace }.watchFaceInfo().let { i ->
                mapOf(
                    "width" to i.width, "height" to i.height, "round" to i.round, "maxBytes" to i.maxBytes, "currentId" to i.currentId,
                    "slotCount" to i.slotCount, "customActive" to i.customActive,
                )
            }
            "installWatchFace" -> {
                val w = need<WatchFaceManager>(d, "mặt đồng hồ") { it.supportsWatchFace }
                val bytes = optStr(a, "base64")?.let { android.util.Base64.decode(it, android.util.Base64.DEFAULT) }
                    ?: optStr(a, "path")?.let(::readFile) ?: throw InvokeException("bad_value", "Thiếu path hoặc base64")
                w.installWatchFace(bytes) { f -> event("transferProgress", d.id, mapOf("what" to "watchFace", "fraction" to f.toDouble())) }
                null
            }
            "getWatchFaceSlots" -> need<WatchFaceManager>(d, "khe mặt đồng hồ") { it.supportsWatchFaceSlots }.watchFaceSlots().map {
                mapOf("index" to it.index, "faceId" to it.faceId)
            }
            "deleteWatchFaceSlot" -> need<WatchFaceManager>(d, "khe mặt đồng hồ") { it.supportsWatchFaceSlots }
                .deleteWatchFaceSlot(optInt(a, "index") ?: throw InvokeException("bad_value", "Thiếu index")).let { null }
            "setWatchFaceImage" -> {
                val w = d as? WatchFaceCustomizable ?: throw InvokeException("unsupported", "Thiết bị không dựng được mặt đồng hồ từ ảnh")
                val bytes = readFile(str(a, "path"))
                val image = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: throw InvokeException("bad_value", "Không đọc được ảnh")
                val base = WatchFaceStyle()
                val style = base.copy(
                    timePosition = optStr(a, "timePosition")?.let { TimePosition.valueOf(it) } ?: base.timePosition,
                    textColor = optLong(a, "textColor")?.toInt() ?: base.textColor,
                    accentColor = optLong(a, "accentColor")?.toInt() ?: base.accentColor,
                    backgroundColor = optLong(a, "backgroundColor")?.toInt() ?: base.backgroundColor,
                    hour12 = if (a.hasKey("hour12")) a.getBoolean("hour12") else base.hour12,
                    complications = a.getArray("complications")?.toArrayList()?.map { Complication.valueOf(it.toString()) }?.toSet()
                        ?: base.complications,
                )
                w.setWatchFace(image, style) { f -> event("transferProgress", d.id, mapOf("what" to "watchFace", "fraction" to f.toDouble())) }
                null
            }

            // ---------- Bài tập ----------
            "getSportTypes" -> need<WorkoutRemote>(d, "danh sách môn") { it.supportsSportList }.sportTypes().map {
                mapOf("type" to it.type, "name" to it.name, "shown" to it.shown, "position" to it.position)
            }
            "setSportList" -> {
                val list = (a.getArray("sports")?.toArrayList() ?: arrayListOf()).map { o ->
                    val m = o as Map<*, *>
                    SportType(
                        type = (m["type"] as Number).toInt(), name = m["name"]?.toString().orEmpty(),
                        shown = m["shown"] == true, position = (m["position"] as? Number)?.toInt() ?: 0,
                    )
                }
                need<WorkoutRemote>(d, "danh sách môn") { it.supportsSportList }.setSportList(list)
                null
            }
            "startWorkout" -> workout(d).startWorkout(optInt(a, "sportType") ?: throw InvokeException("bad_value", "Thiếu sportType")).let { null }
            "pauseWorkout" -> workout(d).pauseWorkout().let { null }
            "resumeWorkout" -> workout(d).resumeWorkout().let { null }
            "stopWorkout" -> workout(d).stopWorkout().let { null }
            "sendLocation" -> need<WorkoutRemote>(d, "vị trí điện thoại") { it.supportsPhoneLocation }.sendLocation(
                latitude = optDouble(a, "latitude") ?: throw InvokeException("bad_value", "Thiếu latitude"),
                longitude = optDouble(a, "longitude") ?: throw InvokeException("bad_value", "Thiếu longitude"),
                altitude = optDouble(a, "altitude"), speed = optDouble(a, "speed"), accuracy = optDouble(a, "accuracy"),
            ).let { null }

            // ---------- Báo thức ----------
            "getAlarms" -> need<AlarmClock>(d, "báo thức") { it.supportsAlarms }.alarms().map(::alarmMap)
            "setAlarm" -> need<AlarmClock>(d, "báo thức") { it.supportsAlarms }.setAlarm(
                Alarm(
                    id = optInt(a, "id") ?: -1,
                    hour = optInt(a, "hour") ?: throw InvokeException("bad_value", "Thiếu hour"),
                    minute = optInt(a, "minute") ?: throw InvokeException("bad_value", "Thiếu minute"),
                    repeatDays = optInt(a, "repeatDays") ?: 0,
                    enabled = !a.hasKey("enabled") || a.isNull("enabled") || a.getBoolean("enabled"),
                    label = optStr(a, "label"),
                ),
            ).let { null }
            "deleteAlarm" -> need<AlarmClock>(d, "báo thức") { it.supportsAlarms }
                .deleteAlarm(optInt(a, "id") ?: optInt(a, "alarmId") ?: throw InvokeException("bad_value", "Thiếu id")).let { null }

            // ---------- Camera ----------
            "setRemoteCamera" -> need<RemoteCameraDevice>(d, "chụp ảnh từ xa") { it.supportsRemoteCamera }.setRemoteCamera(a.getBoolean("open")).let { null }

            // ---------- Firmware (chỉ image chính hãng) ----------
            "checkFirmware" -> need<FirmwareUpdatable>(d, "cập nhật firmware") { it.supportsFirmwareUpdate }.checkFirmware(readFile(str(a, "path"))).let { c ->
                mapOf("valid" to c.valid, "model" to c.model, "version" to c.version, "reason" to c.reason, "details" to c.details)
            }
            "updateFirmware" -> {
                val f = need<FirmwareUpdatable>(d, "cập nhật firmware") { it.supportsFirmwareUpdate }
                val image = readFile(str(a, "path"))
                val check = f.checkFirmware(image)
                if (!check.valid) throw InvokeException("bad_value", check.reason ?: "Firmware không hợp lệ cho thiết bị này")
                f.updateFirmware(image) { p -> event("transferProgress", d.id, mapOf("what" to "firmware", "fraction" to p.toDouble())) }
            }
            "cancelFirmwareUpdate" -> (d as? FirmwareUpdatable)?.cancelFirmwareUpdate().let { null }

            else -> throw InvokeException("unknown_method", "Không có lệnh $method")
        }
    }

    fun scanState(): Map<String, Any?> {
        val adapter = context.getSystemService(android.bluetooth.BluetoothManager::class.java)?.adapter
        val bluetooth = when {
            adapter == null -> "unknown"
            !com.smartwear.core.BlePermissions.granted(context) -> "unauthorized"
            adapter.isEnabled -> "on"
            else -> "off"
        }
        return mapOf("scanning" to manager.scanning.value, "error" to manager.scanError.value, "bluetooth" to bluetooth)
    }

    private fun alarmMap(x: Alarm): Map<String, Any?> = mapOf(
        "id" to x.id, "hour" to x.hour, "minute" to x.minute, "repeatDays" to x.repeatDays, "enabled" to x.enabled, "label" to x.label,
    )

    private fun workout(d: WearableDevice) = need<WorkoutRemote>(d, "điều khiển bài tập") { it.supportsWorkoutControl }

    private inline fun <reified T> need(d: WearableDevice, what: String, supported: (T) -> Boolean): T {
        val t = d as? T
        if (t == null || !supported(t)) throw InvokeException("unsupported", "Thiết bị không hỗ trợ $what")
        return t
    }

    /** Đọc file app chỉ tới: đường dẫn, `file://` hoặc `content://`. */
    private fun readFile(path: String): ByteArray =
        if (path.startsWith("content://")) {
            context.contentResolver.openInputStream(Uri.parse(path))?.use { it.readBytes() }
                ?: throw InvokeException("bad_value", "Không mở được $path")
        } else {
            val f = File(path.removePrefix("file://"))
            if (!f.isFile) throw InvokeException("bad_value", "Không có file $path")
            f.readBytes()
        }

    private fun str(a: ReadableMap, k: String): String = optStr(a, k) ?: throw InvokeException("bad_value", "Thiếu $k")
    private fun optStr(a: ReadableMap, k: String): String? = if (a.hasKey(k) && !a.isNull(k)) a.getString(k) else null
    private fun optDouble(a: ReadableMap, k: String): Double? = if (a.hasKey(k) && !a.isNull(k)) a.getDouble(k) else null
    private fun optInt(a: ReadableMap, k: String): Int? = optDouble(a, k)?.toInt()
    private fun optLong(a: ReadableMap, k: String): Long? = optDouble(a, k)?.toLong()

    companion object {
        private const val PREFS = "smartwear_rn"

        fun foregroundServiceEnabled(context: Context): Boolean =
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean("foregroundService", true)

        fun foregroundServiceEnabled(context: Context, on: Boolean) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean("foregroundService", on).apply()
        }

        /** Giá trị Kotlin (null, Boolean, số, String, List, Map, WritableMap/Array) → giá trị đặt được vào map JS. */
        fun put(m: WritableMap, k: String, v: Any?) {
            when (v) {
                null, Unit -> m.putNull(k)
                is Boolean -> m.putBoolean(k, v)
                is Int -> m.putInt(k, v)
                is Long -> m.putDouble(k, v.toDouble())
                is Float -> m.putDouble(k, v.toDouble())
                is Double -> m.putDouble(k, v)
                is String -> m.putString(k, v)
                is WritableMap -> m.putMap(k, v)
                is WritableArray -> m.putArray(k, v)
                is Map<*, *> -> m.putMap(k, map(v))
                is Iterable<*> -> m.putArray(k, array(v))
                is Enum<*> -> m.putString(k, v.name)
                else -> m.putString(k, v.toString())
            }
        }

        fun map(v: Map<*, *>): WritableMap = Arguments.createMap().apply { v.forEach { (k, x) -> put(this, k.toString(), x) } }

        fun array(v: Iterable<*>): WritableArray = Arguments.createArray().apply {
            v.forEach { x ->
                when (x) {
                    null -> pushNull()
                    is Boolean -> pushBoolean(x)
                    is Int -> pushInt(x)
                    is Long -> pushDouble(x.toDouble())
                    is Float -> pushDouble(x.toDouble())
                    is Double -> pushDouble(x)
                    is String -> pushString(x)
                    is WritableMap -> pushMap(x)
                    is Map<*, *> -> pushMap(map(x))
                    is Iterable<*> -> pushArray(array(x))
                    else -> pushString(x.toString())
                }
            }
        }
    }
}
