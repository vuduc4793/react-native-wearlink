package com.smartwear.lab.ui

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.smartwear.core.CallDisplay
import com.smartwear.core.ConfigurableDevice
import com.smartwear.core.ConnectionState
import com.smartwear.core.MusicRemote
import com.smartwear.core.NotificationDisplay
import com.smartwear.core.RemoteCameraDevice
import com.smartwear.core.SmsQuickReply
import com.smartwear.core.WearableDevice
import com.smartwear.core.phone.PhoneLink
import com.smartwear.lab.RemoteCameraActivity
import com.smartwear.lab.SmartWearApp
import kotlinx.coroutines.launch

/**
 * Thông báo, cuộc gọi, trả lời SMS, nhạc và chụp ảnh từ xa (doc 10 §2.5–2.6), theo các màn `AppRemindActivity` /
 * `CallRemindActivity` / `SmsReplyActivity` của GloryFitPro. Chỉ dùng interface core ([NotificationDisplay], [CallDisplay],
 * [SmsQuickReply], [MusicRemote], [RemoteCameraDevice]) và [PhoneLink]. Quyền chỉ xin khi người dùng bật tính năng.
 */
@Composable
fun PhoneLinkCard(device: WearableDevice) {
    val notify = device as? NotificationDisplay
    val calls = device as? CallDisplay
    val reply = device as? SmsQuickReply
    val music = device as? MusicRemote
    val camera = device as? RemoteCameraDevice
    if (notify?.supportsNotifications != true && calls?.supportsIncomingCall != true) return
    val context = LocalContext.current
    val bridge = (context.applicationContext as SmartWearApp).phone
    val switches by bridge.config.collectAsState()
    val state by device.state.collectAsState()
    val connected = state == ConnectionState.CONNECTED
    // Danh sách icon (`DB AA`) đọc lúc kết nối, đổi `dnd.endCall` làm `controls` phát lại ⇒ đọc lại theo hai luồng này.
    val controls = (device as? ConfigurableDevice)?.controls?.collectAsState()?.value
    val apps = remember(state, controls) { notify?.notificationApps().orEmpty() }
    val rejectOn = remember(controls) { calls?.rejectCallEnabled == true }
    val smsReply = reply?.smsReply?.collectAsState()?.value
    val fixedTemplates = reply?.smsReplyFixedTemplates.orEmpty()
    val scope = rememberCoroutineScope()
    var access by remember { mutableStateOf(bridge.hasNotificationAccess()) }
    var message by remember { mutableStateOf<String?>(null) }
    var showAllApps by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf<Int?>(null) } // chỉ số mẫu đang sửa, -1 = thêm mới

    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle) {
        val observer = LifecycleEventObserver { _, e -> if (e == Lifecycle.Event.ON_RESUME) access = bridge.hasNotificationAccess() }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }

    fun granted(p: String) = context.checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED
    fun setReject(on: Boolean) = scope.launch {
        runCatching { calls?.setRejectCallEnabled(on) }.onFailure { message = "Lỗi: ${it.message}" }
    }
    fun saveReply(enabled: Boolean, custom: List<String>) = scope.launch {
        runCatching { reply?.setSmsReply(enabled, custom + fixedTemplates) }.onFailure { message = "Lỗi: ${it.message}" }
    }
    val custom = smsReply?.templates.orEmpty().filter { it !in fixedTemplates }

    // Như `UtePermissionsUtils.checkPermissionCall`: điện thoại, nhật ký cuộc gọi (để có số gọi đến), danh bạ (để có tên).
    val callPermissions = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        if (granted(Manifest.permission.READ_PHONE_STATE)) bridge.setCalls(true)
        else message = "Cần quyền Điện thoại để báo cuộc gọi đến"
    }
    val answerPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { ok ->
        if (ok) setReject(true) else message = "Cần quyền quản lý cuộc gọi để cúp máy từ đồng hồ"
    }
    val smsPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { ok ->
        if (ok) saveReply(true, custom) else message = "Cần quyền gửi SMS để trả lời từ đồng hồ"
    }

    SectionTitle("Thông báo & cuộc gọi")
    GlassCard {
        Column {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Quyền đọc thông báo", style = Type.callout, color = Palette.label)
                    Text(
                        if (access) "Đã cấp: đẩy thông báo, tin nhắn lên đồng hồ và điều khiển nhạc"
                        else "Cần cấp để đẩy thông báo, tin nhắn và điều khiển nhạc",
                        style = Type.footnote, color = if (access) Palette.green else Palette.secondary,
                    )
                }
                if (!access) PillButton("Cấp quyền", { openListenerSettings(context) }, kind = ButtonKind.PRIMARY)
            }
            Hairline(Modifier.padding(vertical = 6.dp))
            SwitchRow("Báo cuộc gọi đến", "Hiện tên/số người gọi trên đồng hồ", switches.calls) { on ->
                if (!on) bridge.setCalls(false)
                else if (granted(Manifest.permission.READ_PHONE_STATE) && granted(Manifest.permission.READ_CALL_LOG)) bridge.setCalls(true)
                else callPermissions.launch(arrayOf(Manifest.permission.READ_PHONE_STATE, Manifest.permission.READ_CALL_LOG, Manifest.permission.READ_CONTACTS))
            }
            if (calls?.supportsRejectCall == true && switches.calls) {
                SwitchRow("Từ chối cuộc gọi từ đồng hồ", "Bấm từ chối trên đồng hồ để cúp máy", rejectOn) { on ->
                    if (on && Build.VERSION.SDK_INT >= 28 && !granted(Manifest.permission.ANSWER_PHONE_CALLS)) {
                        answerPermission.launch(Manifest.permission.ANSWER_PHONE_CALLS)
                    } else {
                        setReject(on)
                    }
                }
            }
            SwitchRow("Tin nhắn SMS", "Tin nhắn và tên người gửi", switches.sms, enabled = access) { bridge.setSms(it) }
            // Như `AppRemindUtils.appRemindDynamicDisplayEn`: chỉ app mà đồng hồ có icon (mặt nạ `DB AA`).
            val withIcon = apps.filter { it.hasIcon }
            val shown = if (showAllApps) withIcon else withIcon.take(6)
            for (a in shown) SwitchRow(a.name, null, a.key in switches.apps, enabled = access) { bridge.setApp(a.key, it) }
            if (withIcon.size > shown.size || showAllApps && withIcon.size > 6) {
                Text(
                    if (showAllApps) "Thu gọn" else "Xem thêm ${withIcon.size - shown.size} ứng dụng",
                    style = Type.callout, color = Palette.accent,
                    modifier = Modifier.clickable { showAllApps = !showAllApps }.padding(vertical = 8.dp),
                )
            }
        }
    }

    if (reply?.supportsSmsReply == true && smsReply != null) {
        SectionTitle("Trả lời SMS nhanh")
        GlassCard {
            Column {
                SwitchRow("Trả lời SMS từ đồng hồ", "Từ chối cuộc gọi rồi chọn mẫu trên đồng hồ để gửi SMS cho người gọi", smsReply.enabled, enabled = connected) { on ->
                    if (on && !granted(Manifest.permission.SEND_SMS)) smsPermission.launch(Manifest.permission.SEND_SMS)
                    else saveReply(on, custom)
                }
                if (smsReply.enabled) {
                    custom.forEachIndexed { i, t ->
                        Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                            Text(t, style = Type.callout, color = Palette.label, modifier = Modifier.weight(1f).clickable { editing = i })
                            Text("Xoá", style = Type.callout, color = Palette.red,
                                modifier = Modifier.clickable(enabled = connected) { saveReply(true, custom.filterIndexed { k, _ -> k != i }) }.padding(6.dp))
                        }
                    }
                    if (custom.size < reply.smsReplyMaxCustom) {
                        Text("+ Thêm mẫu", style = Type.callout, color = Palette.accent,
                            modifier = Modifier.clickable(enabled = connected) { editing = -1 }.padding(vertical = 8.dp))
                    }
                    Hairline(Modifier.padding(vertical = 4.dp))
                    for (t in fixedTemplates) Text(t, style = Type.footnote, color = Palette.secondary, modifier = Modifier.padding(vertical = 3.dp))
                }
            }
        }
    }

    val musicOn = music?.supportsMusicControl == true || music?.supportsTrackInfo == true
    val cameraOn = camera?.supportsRemoteCamera == true
    if (musicOn || cameraOn) {
        SectionTitle("Nhạc & máy ảnh")
        GlassCard {
            Column {
                if (musicOn) {
                    Row(Modifier.padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text("Điều khiển nhạc từ đồng hồ", style = Type.callout, color = Palette.label)
                            Text(
                                if (access) "Phát/tạm dừng, chuyển bài, âm lượng; tên bài hiện trên đồng hồ" else "Cần quyền đọc thông báo",
                                style = Type.footnote, color = Palette.secondary,
                            )
                        }
                    }
                }
                if (cameraOn) {
                    if (musicOn) Hairline(Modifier.padding(vertical = 6.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text("Chụp ảnh từ xa", style = Type.callout, color = Palette.label)
                            Text("Bấm chụp trên đồng hồ; ảnh lưu vào Ảnh/SmartWear. Mở màn chụp trên đồng hồ cũng mở camera.",
                                style = Type.footnote, color = Palette.secondary)
                        }
                        PillButton("Mở camera", { context.startActivity(Intent(context, RemoteCameraActivity::class.java)) }, kind = ButtonKind.PRIMARY)
                    }
                }
            }
        }
    }
    message?.let { Text(it, style = Type.footnote, color = Palette.orange, modifier = Modifier.padding(top = 8.dp)) }

    editing?.let { index ->
        var text by remember(index) { mutableStateOf(custom.getOrNull(index).orEmpty()) }
        AlertDialog(
            onDismissRequest = { editing = null },
            title = { Text(if (index < 0) "Thêm mẫu trả lời" else "Sửa mẫu trả lời") },
            text = {
                OutlinedTextField(
                    value = text,
                    onValueChange = { text = it },
                    supportingText = { Text("${text.toByteArray().size}/90 byte (dài hơn sẽ bị cắt)") },
                )
            },
            confirmButton = {
                TextButton(enabled = text.isNotBlank(), onClick = {
                    val list = if (index < 0) custom + text.trim() else custom.mapIndexed { k, v -> if (k == index) text.trim() else v }
                    saveReply(true, list)
                    editing = null
                }) { Text("Lưu") }
            },
            dismissButton = { TextButton(onClick = { editing = null }) { Text("Huỷ") } },
        )
    }
}

@Composable
private fun SwitchRow(title: String, detail: String?, checked: Boolean, enabled: Boolean = true, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(title, style = Type.callout, color = if (enabled) Palette.label else Palette.tertiary)
            detail?.let { Text(it, style = Type.footnote, color = Palette.secondary) }
        }
        Switch(
            checked = checked,
            onCheckedChange = onChange,
            enabled = enabled,
            colors = SwitchDefaults.colors(checkedTrackColor = Palette.green, checkedThumbColor = Color.White),
        )
    }
}

private fun openListenerSettings(context: Context) {
    runCatching { context.startActivity(PhoneLink.notificationAccessSettingsIntent()) }
}
