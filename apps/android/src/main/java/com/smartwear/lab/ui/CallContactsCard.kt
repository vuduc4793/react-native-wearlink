package com.smartwear.lab.ui

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.provider.ContactsContract
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.smartwear.core.ConnectionState
import com.smartwear.core.CallAudioLink
import com.smartwear.core.CallAudioState
import com.smartwear.core.Contact
import com.smartwear.core.ContactsSync
import com.smartwear.core.WearableDevice
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Gọi điện qua đồng hồ (Bluetooth cổ điển) + danh bạ, bản Android của `CallContactsCard.swift`. Android ghép kênh gọi
 * ngay trong app (`createBond`); danh bạ đọc bằng quyền READ_CONTACTS, người dùng tick liên hệ cần gửi.
 */
@Composable
fun CallContactsCard(device: WearableDevice) {
    val audio = (device as? CallAudioLink)?.takeIf { it.supportsCallAudio }
    val contacts = (device as? ContactsSync)?.takeIf { it.supportsContacts }
    if (audio == null && contacts == null) return
    val context = LocalContext.current
    val state by device.state.collectAsState()
    val connected = state == ConnectionState.CONNECTED
    val scope = rememberCoroutineScope()
    var call by remember { mutableStateOf<CallAudioState?>(null) }
    var callText by remember { mutableStateOf<String?>(null) }
    var contactsText by remember { mutableStateOf<String?>(null) }
    var picking by remember { mutableStateOf<List<Contact>?>(null) }
    var busy by remember { mutableStateOf(false) }

    suspend fun refresh() {
        if (audio == null || !connected) return
        runCatching { audio.callAudioState() }
            .onSuccess { call = it; callText = null }
            .onFailure { callText = "Lỗi: ${it.message}" }
    }
    LaunchedEffect(state) { refresh() }

    val contactsPermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) scope.launch { picking = loadContacts(context) } else contactsText = "Cần quyền Danh bạ để chọn liên hệ"
    }

    SectionTitle("Gọi điện & danh bạ")
    GlassCard {
        Column {
            if (audio != null) {
                val c = call
                // `paired` theo trạng thái ghép của Android (cờ của đồng hồ không đáng tin).
                val bonded = c != null && c.paired
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("Gọi điện, trợ lý ảo qua đồng hồ", style = Type.callout, color = Palette.label)
                        Text(
                            callText ?: when {
                                c == null -> if (connected) "Đang đọc trạng thái…" else "Kết nối đồng hồ để ghép"
                                bonded -> "Đã ghép với điện thoại (${c.name})"
                                else -> "Chưa ghép — bấm Ghép đôi, xác nhận trên điện thoại"
                            },
                            style = Type.footnote, color = if (bonded) Palette.green else Palette.secondary,
                        )
                    }
                    PillButton(
                        if (bonded) "Làm mới" else "Ghép đôi",
                        {
                            scope.launch {
                                if (!bonded) runCatching { audio.pairCallAudio() }.onFailure { callText = "Lỗi: ${it.message}" }
                                refresh()
                            }
                        },
                        enabled = connected,
                        kind = ButtonKind.PRIMARY,
                    )
                }
            }
            if (contacts != null) {
                Hairline(Modifier.padding(vertical = 10.dp))
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("Danh bạ trên đồng hồ", style = Type.callout, color = Palette.label)
                        Text(
                            contactsText ?: "Chọn tối đa ${contacts.maxContacts} liên hệ; thay toàn bộ danh bạ trên đồng hồ",
                            style = Type.footnote, color = Palette.secondary,
                        )
                    }
                    PillButton(
                        if (busy) "Đang gửi…" else "Chọn",
                        {
                            if (context.checkSelfPermission(Manifest.permission.READ_CONTACTS) == PackageManager.PERMISSION_GRANTED) {
                                scope.launch { picking = loadContacts(context) }
                            } else {
                                contactsPermission.launch(Manifest.permission.READ_CONTACTS)
                            }
                        },
                        enabled = connected && !busy,
                        kind = ButtonKind.PRIMARY,
                    )
                }
            }
        }
    }

    picking?.let { all ->
        ContactPickerDialog(all, contacts?.maxContacts ?: 0, onDismiss = { picking = null }) { chosen ->
            picking = null
            busy = true
            scope.launch {
                contactsText = runCatching { requireNotNull(contacts).syncContacts(chosen) { contactsText = "Đang gửi ${(it * 100).toInt()} %" } }
                    .fold({ "Đã gửi $it liên hệ" }, { "Lỗi: ${it.message}" })
                busy = false
            }
        }
    }
}

/** Liên hệ có số điện thoại, sắp theo tên, mỗi người một số (ưu tiên di động). */
private suspend fun loadContacts(context: Context): List<Contact> = withContext(Dispatchers.IO) {
    val out = linkedMapOf<Long, Contact>()
    context.contentResolver.query(
        ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
        arrayOf(
            ContactsContract.CommonDataKinds.Phone.CONTACT_ID, ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
            ContactsContract.CommonDataKinds.Phone.NUMBER, ContactsContract.CommonDataKinds.Phone.TYPE,
        ),
        null, null, "${ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME} COLLATE LOCALIZED ASC",
    )?.use { c ->
        while (c.moveToNext()) {
            val id = c.getLong(0)
            val contact = Contact(c.getString(1) ?: continue, c.getString(2) ?: continue)
            val mobile = c.getInt(3) == ContactsContract.CommonDataKinds.Phone.TYPE_MOBILE
            if (id !in out || mobile) out[id] = contact
        }
    }
    out.values.toList()
}

@Composable
private fun ContactPickerDialog(
    all: List<Contact>,
    max: Int,
    onDismiss: () -> Unit,
    onConfirm: (List<Contact>) -> Unit,
) {
    val chosen = remember { mutableStateListOf<Contact>() }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Chọn liên hệ (${chosen.size}/$max)") },
        text = {
            LazyColumn(Modifier.fillMaxWidth().heightIn(max = 420.dp)) {
                items(all) { c ->
                    val on = c in chosen
                    Row(
                        Modifier.fillMaxWidth().clickable {
                            if (on) chosen.remove(c) else if (chosen.size < max) chosen.add(c)
                        },
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Checkbox(checked = on, onCheckedChange = null)
                        Column { Text(c.name); Text(c.phone, style = Type.footnote, color = Palette.secondary) }
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = { onConfirm(chosen.toList()) }, enabled = chosen.isNotEmpty()) { Text("Gửi lên đồng hồ") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Huỷ") } },
    )
}
