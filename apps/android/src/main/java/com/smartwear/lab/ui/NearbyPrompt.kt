package com.smartwear.lab.ui

import android.annotation.SuppressLint
import android.graphics.Color as AndroidColor
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import androidx.webkit.WebViewAssetLoader
import com.smartwear.core.ConnectionState
import com.smartwear.core.DeviceManager
import com.smartwear.core.ScanEntry
import com.smartwear.core.SmartWearLog
import com.smartwear.core.WearableDevice
import kotlinx.coroutines.delay

/**
 * Popup kiểu AirPods: đưa thiết bị hỗ trợ (Y25, HT43, nhẫn R09) chưa kết nối SÁT điện thoại thì hiện bảng có mô hình 3D và nút "Kết nối"
 * (cùng hành vi với `NearbyPrompt.swift` bản iOS). Chỉ chạy khi app đang mở.
 */
object NearbyPrompt {
    /** Ghi đè ngưỡng "sát" cho mọi dòng (null = dùng ngưỡng riêng của từng dòng). Hiệu chỉnh theo log `NEARBY`. */
    @Volatile var nearRssiOverride: Int? = null
    /** Debug (adb `--es action nearbyDemo [--es mac <MAC>]`): hiện thẻ cho MAC này như thể nó vừa quảng bá sát máy. */
    @Volatile var demoAddress: String? = null
    /** Bấm "Để sau" thì không hỏi lại thiết bị đó trong chừng này. */
    const val SNOOZE_MS = 5 * 60_000L

    /**
     * Dòng thiết bị có popup: driver + tiền tố tên quảng bá → mô hình 3D (`apps/shared/watch3d/<model>`), mô tả,
     * ngưỡng "sát" riêng (công suất phát khác nhau) và số lần liền cần đạt. Đo 15/10/2026 trên iPhone 11: HT43 sát
     * máy -42…-46 dBm; Y25 sát máy chỉ -58…-59 dBm và quảng bá thưa hơn ~50 lần ⇒ Y25 chỉ cần 1 lần. 19/10/2026 trên Redmi Note 7 Pro: Y25 đặt sát máy chỉ -69 dBm
     * (ngưỡng -60 theo iPhone làm popup không bao giờ hiện), sau khi xoá app đo lại -73 ⇒ Android dùng -78.
     */
    data class Model(
        val driverId: String, val prefix: String, val model3D: String, val subtitle: String,
        val nearRssi: Int, val hitsNeeded: Int,
    )

    val models = listOf(
        Model("gloryfit", "Y25", "y25", "Đồng hồ thông minh", -78, 1),
        Model("gloryfit", "HT43", "ht43", "Đồng hồ GPS", -47, 2),
        Model("qring", "R09", "r09", "Nhẫn thông minh", -50, 2),
        // DS500/HS500A chưa đo độ sát; tạm theo nhẫn.
        Model("qring", "DS500", "ds500", "Vòng tay thông minh", -50, 2),
        // GE54 sát Redmi đo được −46 dBm (19/10/2026), quảng bá liên tục ⇒ ngưỡng như nhẫn, 1 lần thấy là đủ.
        Model("veepoo", "GE54", "ge54", "Vòng tay thông minh", -50, 1),
    )

    /**
     * Thiết bị hỗ trợ mà Android đang nối GATT ở cấp hệ thống (app khác / lần chạy trước) nhưng app chưa dùng: không
     * quảng bá nên không đo được độ sát; chắc chắn ở gần và nối được ngay ⇒ hiện thẻ luôn (giống bản iOS).
     */
    @SuppressLint("MissingPermission")
    internal fun systemHeld(context: android.content.Context, manager: DeviceManager): List<ScanEntry> {
        val bt = context.getSystemService(android.bluetooth.BluetoothManager::class.java) ?: return emptyList()
        val connected = runCatching { bt.getConnectedDevices(android.bluetooth.BluetoothProfile.GATT) }.getOrDefault(emptyList())
        return connected.mapNotNull { dev ->
            val name = runCatching { dev.name }.getOrNull()
            val scanned = com.smartwear.core.ScannedDevice(dev, dev.address, name, 0, emptyList(), emptyMap())
            manager.registry.classify(scanned)?.takeIf { modelOf(it) != null }
        }
    }

    internal fun modelOf(e: ScanEntry): Model? {
        val name = (e.scanned.name ?: e.match.model).orEmpty().uppercase()
        return models.firstOrNull { it.driverId == e.driver.id && name.startsWith(it.prefix) }
    }
}

/** Theo dõi khi app đang mở; hiện bảng khi Y25 ở sát. [onConnected] mở màn chi tiết. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun NearbyPromptHost(manager: DeviceManager, onConnected: (WearableDevice) -> Unit) {
    // Nhiều thiết bị ở sát cùng lúc ⇒ carousel trượt ngang.
    val candidates = remember { mutableStateListOf<ScanEntry>() }
    val hits = remember { mutableMapOf<String, Int>() }
    val snoozed = remember { mutableMapOf<String, Long>() }
    var lastReport = remember { 0L }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val context = androidx.compose.ui.platform.LocalContext.current

    LaunchedEffect(Unit) {
        lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            try {
                while (true) {
                    if (!manager.scanning.value) manager.startScan(Long.MAX_VALUE)
                    val now = System.currentTimeMillis()
                    for (e in NearbyPrompt.systemHeld(context, manager)) {
                        val id = e.scanned.address
                        if (manager.find(id)?.state?.value == ConnectionState.CONNECTED || manager.isKept(id)) continue
                        if (candidates.any { it.scanned.address == id } || (snoozed[id] ?: 0) > now) continue
                        SmartWearLog.i("NEARBY ${e.match.model}: hệ thống đang giữ kết nối sẵn ⇒ hiện thẻ")
                        candidates += e
                    }
                    NearbyPrompt.demoAddress?.let { mac ->
                        NearbyPrompt.demoAddress = null
                        val bt = context.getSystemService(android.bluetooth.BluetoothManager::class.java)
                        val dev = bt?.adapter?.getRemoteDevice(mac) ?: return@let
                        val e = manager.registry.classify(com.smartwear.core.ScannedDevice(dev, mac, "Y25", -50, emptyList(), emptyMap()))
                        SmartWearLog.i("NEARBY demo $mac → ${e?.match?.model ?: "không nhận ra"}")
                        if (e != null && candidates.none { it.scanned.address == mac }) candidates += e
                    }
                    if (now - lastReport >= 5_000) {
                        lastReport = now
                        val rows = manager.scanResults.value.mapNotNull { e ->
                            val m = NearbyPrompt.modelOf(e) ?: return@mapNotNull null
                            val id = e.scanned.address
                            val why = when {
                                manager.find(id)?.state?.value == ConnectionState.CONNECTED -> "đã kết nối"
                                manager.isKept(id) -> "đang giữ kết nối (app tự nối, không hỏi)"
                                now - e.seenAt > 3_000 -> "không thấy quảng bá ${(now - e.seenAt) / 1000} s"
                                e.scanned.rssi < (NearbyPrompt.nearRssiOverride ?: m.nearRssi) -> "chưa đủ sát (${e.scanned.rssi} < ${NearbyPrompt.nearRssiOverride ?: m.nearRssi})"
                                else -> "đủ sát"
                            }
                            "${e.match.model} rssi=${e.scanned.rssi} → $why"
                        }
                        SmartWearLog.i("NEARBY quét=${if (manager.scanning.value) "bật" else "TẮT"} · " + (rows.ifEmpty { listOf("không thấy Y25/HT43/R09 nào") }.joinToString(" | ")))
                    }
                    for (e in manager.scanResults.value) {
                        val id = e.scanned.address
                        val model = NearbyPrompt.modelOf(e)
                        if (model == null || now - e.seenAt > 3_000) { hits[id] = 0; continue }
                        val d = manager.find(id)
                        if (d?.state?.value == ConnectionState.CONNECTED || manager.isKept(id)) continue
                        if (candidates.any { it.scanned.address == id } || (snoozed[id] ?: 0) > now) continue
                        val threshold = NearbyPrompt.nearRssiOverride ?: model.nearRssi
                        hits[id] = if (e.scanned.rssi >= threshold) (hits[id] ?: 0) + 1 else 0
                        SmartWearLog.i("NEARBY ${e.match.model} rssi=${e.scanned.rssi} ngưỡng=$threshold đạt=${hits[id]}/${model.hitsNeeded}")
                        if ((hits[id] ?: 0) >= model.hitsNeeded) { hits[id] = 0; candidates += e }
                    }
                    delay(1_000)
                }
            } finally {
                // Vào nền: dừng quét liên tục (tốn pin).
                manager.stopScan()
            }
        }
    }

    if (candidates.isEmpty()) return
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    fun remove(e: ScanEntry, snooze: Boolean) {
        if (snooze) snoozed[e.scanned.address] = System.currentTimeMillis() + NearbyPrompt.SNOOZE_MS
        candidates.removeAll { it.scanned.address == e.scanned.address }
    }
    fun dismissAll() {
        val until = System.currentTimeMillis() + NearbyPrompt.SNOOZE_MS
        for (e in candidates) snoozed[e.scanned.address] = until
        candidates.clear()
    }
    ModalBottomSheet(
        onDismissRequest = { dismissAll() },
        sheetState = sheetState,
        containerColor = Color(0xF21C1C1E),
        shape = RoundedCornerShape(topStart = 38.dp, topEnd = 38.dp),
        dragHandle = null,
    ) {
        val list = candidates.toList()
        val pager = rememberPagerState { list.size }
        Column(Modifier.fillMaxWidth().padding(top = 16.dp)) {
            Box(Modifier.fillMaxWidth().padding(horizontal = 22.dp)) {
                if (list.size > 1) {
                    Text("${list.size} thiết bị ở gần", style = Type.footnote, color = Palette.secondary, modifier = Modifier.align(Alignment.CenterStart))
                }
                Box(
                    Modifier.align(Alignment.CenterEnd).size(30.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.12f))
                        .clickable { dismissAll() },
                    contentAlignment = Alignment.Center,
                ) { Text("✕", color = Palette.label) }
            }
            HorizontalPager(state = pager, modifier = Modifier.fillMaxWidth()) { i ->
                val e = list[i]
                NearbyCard(manager, e, onLater = { remove(e, snooze = true) }, onDone = { d ->
                    remove(e, snooze = false)
                    if (candidates.isEmpty()) onConnected(d)
                })
            }
            if (list.size > 1) {
                Row(Modifier.fillMaxWidth().padding(bottom = 18.dp), horizontalArrangement = Arrangement.Center) {
                    repeat(list.size) { i ->
                        Box(
                            Modifier.padding(horizontal = 4.dp).size(7.dp).clip(CircleShape)
                                .background(if (pager.currentPage == i) Palette.label else Palette.tertiary),
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun NearbyCard(manager: DeviceManager, entry: ScanEntry, onLater: () -> Unit, onDone: (WearableDevice) -> Unit) {
    val model = NearbyPrompt.modelOf(entry) ?: NearbyPrompt.models.first()
    var connecting by remember { mutableStateOf(false) }
    val device = manager.find(entry.scanned.address)
    val state = device?.state?.collectAsState()?.value
    val battery = device?.battery?.collectAsState()?.value

    LaunchedEffect(state) {
        if (connecting && state == ConnectionState.CONNECTED && device != null) {
            delay(1_800)
            onDone(device)
        }
    }

    Column(
        Modifier.fillMaxWidth().padding(horizontal = 22.dp).padding(top = 16.dp, bottom = 28.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Watch3D(model.model3D, Modifier.fillMaxWidth().height(250.dp))
        Text(entry.match.model ?: entry.scanned.name ?: "Y25", style = Type.headline, color = Palette.label)
        Text(
            when {
                state == ConnectionState.CONNECTED -> model.subtitle + (battery?.let { " · pin $it%" } ?: "")
                else -> model.subtitle + " · ở gần"
            },
            style = Type.footnote, color = Palette.secondary,
        )
        Spacer(Modifier.height(4.dp))
        when {
            state == ConnectionState.CONNECTED ->
                Text("✓ Đã kết nối", style = Type.headline, color = Color(0xFF30D158))
            connecting -> {
                CircularProgressIndicator(color = Palette.label, modifier = Modifier.size(28.dp))
                Text(
                    "Đang kết nối… App vẫn tự chờ và nối khi đồng hồ phát tín hiệu.",
                    style = Type.footnote, color = Palette.secondary, textAlign = TextAlign.Center,
                )
            }
            else -> {
                PillButton("Kết nối", { connecting = true; manager.connect(listOf(entry)) }, Modifier.fillMaxWidth(), kind = ButtonKind.PRIMARY)
                Text("Để sau", style = Type.footnote, color = Palette.secondary, modifier = Modifier.clickable(onClick = onLater).padding(8.dp))
            }
        }
    }
}

/** Mô hình 3D Y25 (Three.js, assets `watch3d/` dùng chung với iOS), nền trong suốt, tự xoay. */
@SuppressLint("SetJavaScriptEnabled")
@Composable
private fun Watch3D(model: String, modifier: Modifier) {
    AndroidView(modifier = modifier, factory = { context ->
        // Phục vụ assets qua https: <script type="module"> không chạy được từ file:///android_asset.
        val loader = WebViewAssetLoader.Builder()
            .addPathHandler("/assets/", WebViewAssetLoader.AssetsPathHandler(context))
            .build()
        WebView(context).apply {
            // AndroidView mặc định gán WRAP_CONTENT; WebView khi đó dựng trang với viewport cao 0 (để co theo nội dung)
            // ⇒ #stage cao 0, canvas trống. Phải MATCH_PARENT để viewport = 250 dp của khung (19/10/2026).
            layoutParams = android.view.ViewGroup.LayoutParams(
                android.view.ViewGroup.LayoutParams.MATCH_PARENT, android.view.ViewGroup.LayoutParams.MATCH_PARENT,
            )
            setBackgroundColor(AndroidColor.TRANSPARENT)
            settings.javaScriptEnabled = true
            isVerticalScrollBarEnabled = false
            isHorizontalScrollBarEnabled = false
            // Lỗi JS/WebGL của trang 3D ra log SmartWear (WebView không tự in ra logcat).
            webChromeClient = object : android.webkit.WebChromeClient() {
                override fun onConsoleMessage(m: android.webkit.ConsoleMessage): Boolean {
                    if (m.messageLevel() == android.webkit.ConsoleMessage.MessageLevel.ERROR) {
                        SmartWearLog.i("3D lỗi JS: ${m.message()} (${m.sourceId()}:${m.lineNumber()})")
                    }
                    return true
                }
            }
            webViewClient = object : WebViewClient() {
                override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? =
                    loader.shouldInterceptRequest(request.url)
            }
            loadUrl("https://appassets.androidplatform.net/assets/watch3d/$model/index.html")
        }
    })
}
