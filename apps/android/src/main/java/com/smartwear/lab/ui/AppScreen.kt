package com.smartwear.lab.ui

import androidx.activity.compose.BackHandler
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.Orientation
import androidx.compose.foundation.gestures.draggable
import androidx.compose.foundation.gestures.rememberDraggableState
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.dp
import com.smartwear.core.DeviceManager
import com.smartwear.core.WearableDevice

/** Điều hướng ban đầu, dùng cho chạy tự động qua adb (chụp màn hình, kiểm thử). */
data class StartRoute(val tab: Tab = Tab.DEVICES, val deviceId: String? = null, val watchFaceEditor: Boolean = false)

/**
 * Bố cục Find My + Liquid Glass: nửa trên là trường tín hiệu trên nền vùng màu thiết bị,
 * nửa dưới là sheet kính kéo được; thanh tab kính nổi phía dưới.
 */
@Composable
fun AppScreen(manager: DeviceManager, start: StartRoute = StartRoute()) {
    val devices by manager.devices.collectAsState()
    var tab by rememberSaveable { mutableStateOf(start.tab) }
    var selectedId by rememberSaveable { mutableStateOf(start.deviceId) }
    var editingFace by rememberSaveable { mutableStateOf(start.watchFaceEditor) }
    val selected = devices.firstOrNull { it.id.equals(selectedId, ignoreCase = true) }
    val colorOf: (WearableDevice) -> Color = { d ->
        Palette.devices[(devices.indexOf(d).takeIf { it >= 0 } ?: 0) % Palette.devices.size]
    }

    LaunchedEffect(start) {
        if (start.tab == Tab.ADD) manager.startScan()
    }
    BackHandler(enabled = selected != null && !editingFace) { selectedId = null }
    // Popup kiểu AirPods khi đưa Y25 chưa kết nối sát điện thoại.
    NearbyPromptHost(manager) { d -> tab = Tab.DEVICES; selectedId = d.id }
    FindPhoneHost()

    BoxWithConstraints(Modifier.fillMaxSize().background(Palette.background)) {
        val density = LocalDensity.current
        val full = maxHeight
        // Sheet có 2 nấc: một nửa (thấy trường tín hiệu) và gần toàn màn hình.
        var expanded by rememberSaveable { mutableStateOf(false) }
        val collapsedTop = full * 0.40f
        val expandedTop = 72.dp
        val sheetTop by animateDpAsState(if (expanded) expandedTop else collapsedTop, label = "sheet")

        ColorFields(devices.filter { it.state.collectAsState().value.name == "CONNECTED" }.map(colorOf))

        Box(Modifier.fillMaxWidth().height(collapsedTop).windowInsetsPadding(WindowInsets.statusBars)) {
            SignalField(
                devices = devices,
                colorOf = colorOf,
                selectedId = selectedId,
                onSelect = { selectedId = it.id; tab = Tab.DEVICES },
            )
        }

        // Sheet kính.
        Column(
            Modifier
                .padding(top = sheetTop)
                .fillMaxSize()
                .clip(RoundedCornerShape(topStart = 34.dp, topEnd = 34.dp))
                .background(Brush.verticalGradient(listOf(Color(if (expanded) 0xFF1A1C20 else 0xE6202328), Color(if (expanded) 0xFF0E1013 else 0xFA0E1013))))
                .glass(RoundedCornerShape(topStart = 34.dp, topEnd = 34.dp), strength = 0.6f),
        ) {
            Box(
                Modifier
                    .fillMaxWidth()
                    .draggable(
                        rememberDraggableState { delta -> if (delta < -6) expanded = true else if (delta > 6) expanded = false },
                        Orientation.Vertical,
                    )
                    .padding(vertical = 10.dp),
                contentAlignment = Alignment.Center,
            ) {
                Box(Modifier.width(38.dp).height(5.dp).clip(RoundedCornerShape(3.dp)).background(Color.White.copy(alpha = 0.3f)))
            }
            // Mỗi tab / mỗi thiết bị có vị trí cuộn riêng.
            val scroll = key(tab, selectedId) { rememberScrollState() }
            Column(
                Modifier
                    .fillMaxSize()
                    .verticalScroll(scroll)
                    .padding(horizontal = 20.dp),
            ) {
                when {
                    tab == Tab.DEVICES && selected != null && editingFace -> WatchFaceEditor(selected, onClose = { editingFace = false })
                    tab == Tab.DEVICES && selected != null -> DeviceDetail(
                        device = selected,
                        devices = devices,
                        manager = manager,
                        colorOf = colorOf,
                        onSwitch = { selectedId = it.id },
                        onBack = { selectedId = null },
                        onOpenWatchFace = { editingFace = true },
                    )
                    tab == Tab.DEVICES -> DevicesList(devices, manager, colorOf, onOpen = { selectedId = it.id }, onAdd = {
                        tab = Tab.ADD
                        manager.startScan()
                    })
                    tab == Tab.ADD -> AddScreen(manager, devices, onConnected = { tab = Tab.DEVICES; selectedId = null })
                    tab == Tab.LAB -> LabScreen(devices, manager, colorOf)
                }
                Spacer(Modifier.navigationBarsPadding().height(120.dp))
            }
        }

        TabBar(
            selected = tab,
            onSelect = {
                if (it == Tab.ADD && tab != Tab.ADD) manager.startScan()
                if (it == Tab.DEVICES && tab == Tab.DEVICES) selectedId = null
                tab = it
            },
            modifier = Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(bottom = 12.dp),
        )

        PairingOverlay(devices, colorOf)
    }
}

/** Hộp thoại khi đồng hồ/vòng đang tìm điện thoại (chuông do [com.smartwear.lab.FindPhoneRinger] phát). */
@Composable
private fun FindPhoneHost() {
    val ringer = (androidx.compose.ui.platform.LocalContext.current.applicationContext as com.smartwear.lab.SmartWearApp).findPhone
    val name by ringer.ringing.collectAsState()
    val who = name ?: return
    androidx.compose.material3.AlertDialog(
        onDismissRequest = { ringer.stop() },
        confirmButton = { androidx.compose.material3.TextButton(onClick = { ringer.stop() }) { Text("Đã tìm thấy") } },
        title = { Text("Đang tìm điện thoại") },
        text = { Text("$who đang tìm điện thoại này.") },
    )
}
