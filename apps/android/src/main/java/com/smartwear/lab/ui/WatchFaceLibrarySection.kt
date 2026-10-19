package com.smartwear.lab.ui

import android.graphics.Bitmap
import androidx.compose.foundation.Image
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.smartwear.core.ConnectionState
import com.smartwear.core.WearableDevice
import com.smartwear.lab.SmartWearApp
import com.smartwear.lab.WatchFaceLibrary
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Thư viện mặt đồng hồ dựng sẵn: chọn một bộ để cài, bộ vừa cài thành mặt mặc định (tự cài lại khi kết nối). */
@Composable
fun WatchFaceLibrarySection(device: WearableDevice) {
    val context = LocalContext.current
    val store = (context.applicationContext as SmartWearApp).watchFaces
    val version by store.version.collectAsState()
    val autoStatus by store.status.collectAsState()
    val state by device.state.collectAsState()
    val current = remember(version) { store.effective(device.id) }
    val previews by produceState(emptyMap<String, Bitmap>()) {
        value = withContext(Dispatchers.IO) {
            WatchFaceLibrary.presets.mapNotNull { p -> WatchFaceLibrary.preview(context, p.id)?.let { p.id to it } }.toMap()
        }
    }
    var selectedId by rememberSaveable(device.id) { mutableStateOf<String?>(null) }
    var sending by remember { mutableStateOf<Float?>(null) }
    var result by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()

    SectionTitle("Thư viện", trailing = "${WatchFaceLibrary.presets.size} mặt · 466 × 466")
    Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
        WatchFaceLibrary.presets.forEach { p ->
            val isDefault = current.preset == p.id
            val isSelected = selectedId == p.id
            Column(
                Modifier.width(104.dp).clickable { selectedId = if (isSelected) null else p.id; result = null },
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                val ring = when {
                    isSelected -> Modifier.border(2.dp, Palette.label, CircleShape)
                    isDefault -> Modifier.border(2.dp, Palette.orange, CircleShape)
                    else -> Modifier
                }
                FaceThumb(previews[p.id], Modifier.size(96.dp).then(ring).padding(4.dp))
                Spacer(Modifier.height(6.dp))
                Text(p.name, style = Type.footnote, color = Palette.label, maxLines = 1)
                Text(
                    when {
                        isDefault -> "Mặc định"
                        p.experimental -> "Thử nghiệm"
                        else -> " "
                    },
                    style = Type.footnote,
                    color = if (isDefault) Palette.orange else Palette.tertiary,
                    maxLines = 1,
                )
            }
        }
    }
    if (current.preset == null) {
        Text("Mặc định hiện tại: thiết kế tự chỉnh.", style = Type.footnote, color = Palette.secondary, modifier = Modifier.padding(top = 8.dp))
    }

    val preset = WatchFaceLibrary.find(selectedId) ?: return
    Spacer(Modifier.height(12.dp))
    GlassCard {
        Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
            FaceThumb(previews[preset.id], Modifier.size(220.dp))
            Spacer(Modifier.height(12.dp))
            Text(preset.name, style = Type.headline, color = Palette.label)
            Text(preset.note, style = Type.footnote, color = Palette.secondary, modifier = Modifier.padding(top = 2.dp))
            if (preset.experimental) {
                Text(
                    "Kim xoay chưa kiểm chứng trên Y25: nếu kim không chạy, chọn lại một mặt khác.",
                    style = Type.footnote,
                    color = Palette.orange,
                    modifier = Modifier.padding(top = 6.dp),
                )
            }
            Spacer(Modifier.height(14.dp))
            val progress = sending
            if (progress != null) {
                Text("Đang cài · ${(progress * 100).toInt()} %", style = Type.callout, color = Palette.label)
                Spacer(Modifier.height(8.dp))
                LinearProgressIndicator(
                    progress = { progress },
                    modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(3.dp)),
                    color = Palette.label,
                    trackColor = Color.White.copy(alpha = 0.12f),
                )
            } else {
                PillButton(
                    if (current.preset == preset.id) "Cài lại lên đồng hồ" else "Cài và đặt làm mặc định",
                    {
                        result = null
                        sending = 0f
                        scope.launch {
                            runCatching { store.installPreset(device, preset.id) { p -> sending = p } }
                                .onSuccess { result = "Đã cài ${preset.name}. Mỗi lần kết nối, app tự cài lại nếu đồng hồ đổi mặt." }
                                .onFailure { result = "Không cài được: ${it.message}" }
                            sending = null
                        }
                    },
                    Modifier.fillMaxWidth(),
                    kind = ButtonKind.PRIMARY,
                    enabled = state == ConnectionState.CONNECTED,
                )
            }
            (result ?: autoStatus[device.id])?.let {
                Text(it, style = Type.footnote, color = Palette.secondary, modifier = Modifier.padding(top = 10.dp))
            }
        }
    }
}

@Composable
private fun FaceThumb(bitmap: Bitmap?, modifier: Modifier) {
    val image = remember(bitmap) { bitmap?.asImageBitmap() }
    if (image != null) {
        Image(image, contentDescription = null, modifier = modifier.clip(CircleShape))
    } else {
        Spacer(modifier.clip(CircleShape).glass(CircleShape))
    }
}
