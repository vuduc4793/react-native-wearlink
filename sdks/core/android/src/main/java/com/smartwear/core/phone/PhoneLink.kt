package com.smartwear.core.phone

import android.Manifest
import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.ContactsContract
import android.provider.Settings
import android.telecom.TelecomManager
import android.telephony.PhoneStateListener
import android.telephony.SmsManager
import android.telephony.TelephonyManager
import com.smartwear.core.CallDisplay
import com.smartwear.core.ConnectionState
import com.smartwear.core.DeviceManager
import com.smartwear.core.MusicRemote
import com.smartwear.core.NotificationDisplay
import com.smartwear.core.SmartWearLog
import com.smartwear.core.SmsQuickReply
import com.smartwear.core.WearableDevice
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.merge
import kotlinx.coroutines.launch

/**
 * Cầu nối điện thoại Android ↔ thiết bị đeo, chạy không cần UI/JS (app lab, React Native dùng chung). Bản Android của
 * `MainService` + `ServicePresenter` + `EndCallUtil` trong GloryFitPro 1.9.0.2 (`P/com/yc/gloryfitpro/services/…`), nhưng chỉ nói
 * chuyện với interface core ([NotificationDisplay], [CallDisplay], [MusicRemote], [SmsQuickReply]) nên hãng nào cài interface
 * là chạy:
 * - thông báo app / SMS nhận từ [PhoneNotificationListener] (người dùng cấp "Truy cập thông báo", xem [hasNotificationAccess]);
 * - cuộc gọi đến (nghe `TelephonyManager`) + cúp máy khi bấm từ chối trên thiết bị (`TelecomManager.endCall`);
 * - điều khiển nhạc: [PhoneMusic] (MediaSession, phím media, âm lượng);
 * - trả lời SMS nhanh: gửi bằng `SmsManager`, báo kết quả cho thiết bị.
 *
 * Quyền: thư viện khai báo READ_PHONE_STATE, FOREGROUND_SERVICE…; quyền nhạy cảm theo chính sách (SEND_SMS, READ_CALL_LOG,
 * ANSWER_PHONE_CALLS, READ_CONTACTS) app chủ tự khai báo trong manifest và xin lúc chạy; thiếu quyền thì tính năng đó bỏ qua.
 *
 * Mỗi tiến trình tạo đúng một [PhoneLink] (giữ ở [instance] để [PhoneNotificationListener] gọi tới), rồi gọi [start].
 */
class PhoneLink(context: Context, val manager: DeviceManager, private val scope: CoroutineScope) {

    private val context = context.applicationContext
    private val main = Handler(Looper.getMainLooper())

    private val _config = MutableStateFlow(PhoneLinkConfig.load(this.context))
    val config: StateFlow<PhoneLinkConfig> = _config.asStateFlow()

    /** Theo dõi trình phát nhạc (bật khi [PhoneNotificationListener] đã kết nối). */
    val music = PhoneMusic(this.context, this, scope)

    init {
        instance = this
    }

    fun setApp(key: String, on: Boolean) = update { it.copy(apps = if (on) it.apps + key else it.apps - key) }
    fun setSms(on: Boolean) = update { it.copy(sms = on) }
    fun setMusic(on: Boolean) = update { it.copy(music = on) }
    fun setSmsReply(on: Boolean) = update { it.copy(smsReply = on) }
    fun setCalls(on: Boolean) {
        update { it.copy(calls = on) }
        if (on) registerCallListener()
    }

    private fun update(change: (PhoneLinkConfig) -> PhoneLinkConfig) {
        val c = change(_config.value)
        _config.value = c
        PhoneLinkConfig.save(context, c)
    }

    fun hasNotificationAccess(): Boolean = hasNotificationAccess(context)

    private fun granted(permission: String) = context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    private fun connected(): List<WearableDevice> = manager.devices.value.filter { it.state.value == ConnectionState.CONNECTED }

    @OptIn(ExperimentalCoroutinesApi::class)
    private inline fun <reified T : Any, R> eachDevice(crossinline select: (T) -> Flow<R>): Flow<Pair<T, R>> =
        manager.devices.flatMapLatest { list -> list.filterIsInstance<T>().map { d -> select(d).map { d to it } }.merge() }

    private var started = false

    /** Bắt đầu nghe thiết bị (từ chối cuộc gọi, trả lời SMS, nút nhạc), cuộc gọi và broadcast. Gọi một lần; gọi lại không làm gì. */
    fun start() {
        if (started) return
        started = true
        scope.launch { eachDevice<CallDisplay, Unit> { it.rejectCallRequests }.collect { (d, _) -> rejectCall(d) } }
        scope.launch { eachDevice<SmsQuickReply, com.smartwear.core.SmsReplyRequest> { it.smsReplyRequests }.collect { (d, r) -> sendReplySms(d, r.number, r.text) } }
        scope.launch { eachDevice<MusicRemote, com.smartwear.core.MusicCommand> { it.musicCommands }.collect { (_, c) -> if (_config.value.music) music.onCommand(c) } }
        registerCallListener()
        registerReceivers()
        // Quyền đọc thông báo đã cấp từ trước: hệ thống tự nối [PhoneNotificationListener] và gọi [PhoneMusic.start].
    }

    // ---------- Thông báo app / SMS ----------

    /** Key app (theo [NotificationDisplay.notificationApps] của các thiết bị) chứa gói [pkg]; null = app không có trong danh sách. */
    fun appKeyFor(pkg: String): String? = manager.devices.value.asSequence().filterIsInstance<NotificationDisplay>()
        .flatMap { it.notificationApps() }.firstOrNull { pkg in it.packages }?.key

    /**
     * Thông báo app đã qua bộ lọc của [PhoneNotificationListener]: gửi mọi thiết bị đang kết nối có thông báo, trừ thiết bị
     * đang trong khung không làm phiền theo giờ ([NotificationDisplay.inQuietHours]).
     */
    internal fun onAppNotification(appKey: String, title: String, text: String, ticker: String) {
        for (d in connected().filterIsInstance<NotificationDisplay>()) {
            if (!d.supportsNotifications || d.inQuietHours()) continue
            scope.launch { d.sendNotification(appKey, title, text, ticker) }
        }
    }

    private var lastSmsTime = 0L

    /**
     * Tin SMS (Google Messages / app tin nhắn hệ thống): bỏ nếu tin trước mới gửi chưa đầy 2 s (`ServicePresenter.sendSmsMessage`),
     * tên người gửi = tên trong danh bạ nếu [contact] là số, không thì giữ nguyên (`SearchDeviceModelImpl.getPhoneContact`).
     */
    internal fun onSms(contact: String, content: String) {
        val now = System.currentTimeMillis()
        if (now - lastSmsTime < 2_000) {
            SmartWearLog.i("SMS đến quá nhanh, bỏ qua")
            return
        }
        lastSmsTime = now
        if (content.isEmpty()) return
        val sender = contactName(contact) ?: contact
        for (d in connected().filterIsInstance<NotificationDisplay>()) {
            if (!d.supportsNotifications || d.inQuietHours()) continue
            scope.launch { d.sendSms(sender, content) }
        }
    }

    /** Tên trong danh bạ của [number] (cần READ_CONTACTS); null nếu không có. Dùng PhoneLookup (bản gốc so khớp chính xác `data1`). */
    private fun contactName(number: String): String? {
        if (number.isEmpty() || !granted(Manifest.permission.READ_CONTACTS)) return null
        return runCatching {
            val uri = Uri.withAppendedPath(ContactsContract.PhoneLookup.CONTENT_FILTER_URI, Uri.encode(number))
            context.contentResolver.query(uri, arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME), null, null, null)?.use { c ->
                if (c.moveToFirst()) c.getString(0) else null
            }
        }.getOrNull()?.takeIf { it.isNotEmpty() }
    }

    // ---------- Cuộc gọi ----------

    private var callListener: PhoneStateListener? = null
    private var lastPhoneState = TelephonyManager.CALL_STATE_IDLE
    private var incomingNumber = ""
    private var notifiedAnswer = false

    /**
     * Nghe trạng thái cuộc gọi như `MainService.registerPhoneStateListener` (`TelephonyManager.listen(…, LISTEN_CALL_STATE)`),
     * cần READ_PHONE_STATE; số gọi đến cần thêm READ_CALL_LOG (Android 10+). Đăng ký một lần, lọc theo [PhoneLinkConfig.calls]
     * khi xử lý. App chủ gọi lại sau khi người dùng cấp quyền.
     */
    @Suppress("DEPRECATION")
    fun registerCallListener() {
        if (callListener != null || !granted(Manifest.permission.READ_PHONE_STATE)) return
        main.post {
            if (callListener != null) return@post
            val tm = context.getSystemService(TelephonyManager::class.java) ?: return@post
            val l = object : PhoneStateListener() {
                @Deprecated("Deprecated in Java")
                override fun onCallStateChanged(state: Int, phoneNumber: String?) {
                    if (!phoneNumber.isNullOrEmpty()) incomingNumber = phoneNumber
                    // Đổ chuông: xử lý sau 200 ms như bản gốc.
                    if (state == TelephonyManager.CALL_STATE_RINGING) main.postDelayed({ onPhoneState(state) }, 200) else onPhoneState(state)
                }
            }
            runCatching { tm.listen(l, PhoneStateListener.LISTEN_CALL_STATE) }
                .onSuccess { callListener = l }
                .onFailure { SmartWearLog.w("Không nghe được cuộc gọi: ${it.message}") }
        }
    }

    /**
     * `MainService.phonePushMessage` (không có "báo cuộc gọi trễ"): đổ chuông ⇒ [CallDisplay.incomingCall] (nếu có số);
     * nghe máy (đổ chuông → nhấc máy) ⇒ [CallDisplay.callEnded]; cúp sau khi nghe ⇒ [CallDisplay.callEnded]; hết chuông mà không
     * nghe (nhỡ/từ chối) và có số ⇒ [CallDisplay.callEnded].
     */
    private fun onPhoneState(state: Int) {
        val ws = connected().filterIsInstance<CallDisplay>().filter { it.supportsIncomingCall }
        if (ws.isNotEmpty() && _config.value.calls) {
            when (state) {
                TelephonyManager.CALL_STATE_IDLE -> {
                    if (lastPhoneState == TelephonyManager.CALL_STATE_RINGING) {
                        if (incomingNumber.isNotEmpty()) {
                            ws.forEach { scope.launch { it.callEnded() } }
                            incomingNumber = ""
                        }
                    } else if (lastPhoneState == TelephonyManager.CALL_STATE_OFFHOOK && notifiedAnswer) {
                        ws.forEach { scope.launch { it.callEnded() } }
                    }
                    notifiedAnswer = false
                }
                TelephonyManager.CALL_STATE_RINGING -> {
                    if (incomingNumber.isNotEmpty()) {
                        val number = incomingNumber
                        val name = contactName(number) ?: number
                        ws.forEach { scope.launch { it.incomingCall(name, number) } }
                        incomingNumber = ""
                    }
                    notifiedAnswer = false
                }
                TelephonyManager.CALL_STATE_OFFHOOK -> if (lastPhoneState == TelephonyManager.CALL_STATE_RINGING) {
                    notifiedAnswer = true
                    ws.forEach { scope.launch { it.callEnded() } }
                }
            }
        }
        lastPhoneState = state
    }

    /**
     * Thiết bị bấm từ chối ⇒ `EndCallUtil.endCall`: Android 9+ dùng `TelecomManager.endCall()` (cần ANSWER_PHONE_CALLS, app chủ
     * khai báo). Android 8 bản gốc gọi `ITelephony` ẩn qua reflection, ở đây không làm. Thiết bị chỉ phát khi người dùng đã bật.
     */
    @SuppressLint("MissingPermission")
    private fun rejectCall(d: CallDisplay) {
        val name = (d as? WearableDevice)?.name
        if (Build.VERSION.SDK_INT < 28 || !granted(Manifest.permission.ANSWER_PHONE_CALLS)) {
            SmartWearLog.w("[$name] từ chối cuộc gọi: thiếu quyền ANSWER_PHONE_CALLS hoặc Android < 9")
            return
        }
        @Suppress("DEPRECATION")
        val ok = runCatching { context.getSystemService(TelecomManager::class.java)?.endCall() == true }.getOrDefault(false)
        SmartWearLog.i("[$name] từ chối cuộc gọi: endCall = $ok")
    }

    // ---------- Trả lời SMS nhanh ----------

    /** Thiết bị đang chờ kết quả gửi SMS. */
    @Volatile
    private var replyDevice: SmsQuickReply? = null

    private val smsSentAction get() = "${context.packageName}.smartwear.SMS_SENT"

    /**
     * `EndCallUtil.sendEndCallSmsToCaller`: chia tin (`divideMessage`), gửi từng phần kèm PendingIntent "đã gửi"; mỗi kết quả
     * (`MainService` `SMS_SEND_ACTION`, mã -1 = thành công) báo thiết bị. Khác bản gốc: thiếu quyền SEND_SMS (app chủ khai báo)
     * hoặc tắt [PhoneLinkConfig.smsReply] thì báo lỗi ngay (bản gốc im lặng).
     */
    @SuppressLint("MissingPermission")
    private fun sendReplySms(d: SmsQuickReply, number: String, text: String) {
        SmartWearLog.i("[${(d as? WearableDevice)?.name}] trả lời SMS tới $number")
        if (!_config.value.smsReply || !granted(Manifest.permission.SEND_SMS) || number.isEmpty()) {
            scope.launch { d.sendSmsReplyResult(false) }
            return
        }
        replyDevice = d
        val sms = if (Build.VERSION.SDK_INT >= 31) context.getSystemService(SmsManager::class.java) else @Suppress("DEPRECATION") SmsManager.getDefault()
        val sent = PendingIntent.getBroadcast(context, 0, Intent(smsSentAction).setPackage(context.packageName), PendingIntent.FLAG_IMMUTABLE)
        runCatching { for (part in sms.divideMessage(text)) sms.sendTextMessage(number, null, part, sent, null) }
            .onFailure {
                SmartWearLog.w("Gửi SMS lỗi: ${it.message}")
                scope.launch { d.sendSmsReplyResult(false) }
            }
    }

    // ---------- Broadcast ----------

    private fun registerReceivers() {
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(c: Context, intent: Intent) {
                when (intent.action) {
                    smsSentAction -> {
                        val ok = resultCode == -1 // Activity.RESULT_OK
                        SmartWearLog.i("Gửi SMS trả lời: mã $resultCode")
                        replyDevice?.let { d -> scope.launch { d.sendSmsReplyResult(ok) } }
                    }
                    VOLUME_CHANGED -> if (intent.getIntExtra(EXTRA_VOLUME_STREAM_TYPE, -1) == AudioManager.STREAM_MUSIC) {
                        music.pushVolume()
                    }
                }
            }
        }
        val filter = IntentFilter().apply {
            addAction(smsSentAction)
            addAction(VOLUME_CHANGED)
        }
        if (Build.VERSION.SDK_INT >= 33) context.registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
        else context.registerReceiver(receiver, filter)
    }

    companion object {
        /** [PhoneLink] của tiến trình (tạo gần nhất); [PhoneNotificationListener] chuyển thông báo tới đây. */
        @Volatile
        var instance: PhoneLink? = null
            private set

        /** `RtkAudioManagerCompat.VOLUME_CHANGED_ACTION` / `EXTRA_VOLUME_STREAM_TYPE` (hằng ẩn của Android). */
        const val VOLUME_CHANGED = "android.media.VOLUME_CHANGED_ACTION"
        const val EXTRA_VOLUME_STREAM_TYPE = "android.media.EXTRA_VOLUME_STREAM_TYPE"

        /**
         * App đã được cấp "Truy cập thông báo" cho [PhoneNotificationListener] (cũng là điều kiện đọc phiên phát nhạc, như
         * `NotificationEnabledUtils` của Pro).
         */
        fun hasNotificationAccess(context: Context): Boolean {
            val enabled = Settings.Secure.getString(context.contentResolver, "enabled_notification_listeners").orEmpty()
            val me = ComponentName(context, PhoneNotificationListener::class.java)
            return enabled.split(':').any { ComponentName.unflattenFromString(it) == me }
        }

        /** Màn Cài đặt → Truy cập thông báo (thêm FLAG_ACTIVITY_NEW_TASK để mở từ ngoài Activity). */
        fun notificationAccessSettingsIntent(): Intent =
            Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }
}
