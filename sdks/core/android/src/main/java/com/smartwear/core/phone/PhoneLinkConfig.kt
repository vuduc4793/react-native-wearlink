package com.smartwear.core.phone

import android.content.Context

/**
 * Công tắc phía điện thoại cho [PhoneLink], lưu SharedPreferences "phone_link" (cùng tệp và khoá app lab dùng trước đây):
 * - [apps]: key app được chuyển thông báo ([com.smartwear.core.NotificationApp.key]), mặc định không app nào (như `SPDao` của Pro);
 * - [sms]: chuyển tin SMS; [calls]: báo cuộc gọi đến (mặc định tắt);
 * - [music]: điều khiển nhạc + đẩy bài đang phát; [smsReply]: gửi SMS khi thiết bị yêu cầu (mặc định bật, thiết bị chỉ yêu cầu
 *   khi người dùng đã bật trả lời SMS nhanh cho thiết bị đó).
 */
data class PhoneLinkConfig(
    val apps: Set<String> = emptySet(),
    val sms: Boolean = false,
    val calls: Boolean = false,
    val music: Boolean = true,
    val smsReply: Boolean = true,
) {
    internal companion object {
        const val PREFS = "phone_link"

        fun load(context: Context): PhoneLinkConfig {
            val p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            return PhoneLinkConfig(
                apps = p.getStringSet("apps", emptySet()).orEmpty().toSet(),
                sms = p.getBoolean("sms", false),
                calls = p.getBoolean("calls", false),
                music = p.getBoolean("music", true),
                smsReply = p.getBoolean("smsReply", true),
            )
        }

        fun save(context: Context, c: PhoneLinkConfig) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                .putStringSet("apps", c.apps)
                .putBoolean("sms", c.sms)
                .putBoolean("calls", c.calls)
                .putBoolean("music", c.music)
                .putBoolean("smsReply", c.smsReply)
                .apply()
        }
    }
}
