package com.smartwear.core.phone

import android.app.Notification
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import com.smartwear.core.SmartWearLog

/**
 * Đọc thông báo của điện thoại và chuyển cho [PhoneLink.instance], bộ lọc chép theo GloryFitPro
 * `StatusbarMsgNotificationListener.onNotificationPosted` (`P/com/yc/gloryfitpro/services/StatusbarMsgNotificationListener.java:93-298`).
 * Khai báo sẵn trong manifest của core; người dùng cấp quyền trong Cài đặt → Truy cập thông báo
 * ([PhoneLink.notificationAccessSettingsIntent]). Quyền này cũng cho đọc phiên phát nhạc ([PhoneMusic.start]).
 * App không tạo [PhoneLink] thì service không làm gì.
 */
class PhoneNotificationListener : NotificationListenerService() {

    private val link get() = PhoneLink.instance

    private var lastPackageName = ""
    private var lastExtraTitleText = ""
    private var lastNotificationTime = 0L
    private var lastWatchAppNotificationTime = 0L
    private var whatsappLastExtraTitleText = ""
    private var lastContact = ""
    private var lastContent = ""

    override fun onListenerConnected() {
        super.onListenerConnected()
        SmartWearLog.i("Đã được cấp quyền đọc thông báo")
        link?.music?.start()
    }

    override fun onListenerDisconnected() {
        super.onListenerDisconnected()
        link?.music?.stop()
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        val link = link ?: return
        val pkg = sbn.packageName
        if (pkg == packageName || pkg == "com.github.kr328.clash") return
        val n = sbn.notification
        val ticker = n.tickerText?.toString().orEmpty()
        val priority = @Suppress("DEPRECATION") n.priority
        val channel = n.channelId.orEmpty()
        val title = n.extras.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty()
        val text = n.extras.getCharSequence(Notification.EXTRA_TEXT)?.toString().orEmpty()
        val titleText = if (title.isEmpty() && text.isEmpty()) "" else "$title:$text"
        if (title.isEmpty() && text.isEmpty()) return
        if (priority < 0) return
        if (sameNotificationComeQuick(pkg, titleText)) return
        if (pkg == "com.viber.voip" && (priority == 0 || channel == "system_1")) return
        if (pkg == "com.snapchat.android" && (priority < 1 || channel == "general_group_silent")) return
        if (pkg == "com.tencent.mm" && priority == 2) return
        val config = link.config.value
        val isSms = PhoneText.isSmsApp(pkg)
        // `NotificationPresenter.getSwitchStatus`: tin nhắn luôn qua bước này (lọc bằng công tắc SMS bên dưới); app khác theo
        // công tắc riêng. App ngoài danh sách: bản gốc chỉ gửi nếu người dùng đã thêm vào "app khác", ở đây chưa làm.
        val appKey = if (isSms) null else link.appKeyFor(pkg)?.takeIf { it in config.apps } ?: return
        // Khung "không làm phiền" theo giờ: PhoneLink kiểm theo từng thiết bị.
        if (pkg == "com.whatsapp") {
            if (n.flags == Notification.FLAG_GROUP_SUMMARY) return
            val now = System.currentTimeMillis()
            if (now - lastWatchAppNotificationTime < 1_000) return
            if (n.toString().contains("channel=chat_history_backup")) return
            if (now - lastWatchAppNotificationTime < 6_000 && whatsappLastExtraTitleText == titleText) return
            lastWatchAppNotificationTime = now
            whatsappLastExtraTitleText = titleText
        }
        if (isSms) {
            if (!config.sms) return
            // Google Messages lấy nội dung từ tickerText, app tin nhắn hệ thống lấy từ EXTRA_TEXT.
            val body = if (pkg == PhoneText.GOOGLE_MESSAGES) ticker else text
            if (pkg == PhoneText.GOOGLE_MESSAGES && title.isEmpty()) return
            if (title.isNotEmpty() && lastContact.isNotEmpty() && body.isNotEmpty() && lastContent.isNotEmpty() &&
                lastContact == title && lastContent == body
            ) return
            lastContact = title
            lastContent = body
            link.onSms(title, PhoneText.stripSmsPrefix(body, title))
            return
        }
        link.onAppNotification(appKey ?: return, title, text, ticker)
        lastPackageName = pkg
        lastExtraTitleText = titleText
    }

    /** Cùng app, cùng "tiêu đề:nội dung" trong 200 ms ⇒ bỏ (`isSameNotificationComeQuick`). */
    private fun sameNotificationComeQuick(pkg: String, titleText: String): Boolean {
        val now = System.currentTimeMillis()
        if (pkg == lastPackageName && titleText == lastExtraTitleText && now - lastNotificationTime < 200) return true
        lastNotificationTime = now
        return false
    }
}
