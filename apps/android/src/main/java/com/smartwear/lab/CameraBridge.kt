package com.smartwear.lab

import android.content.Context
import android.content.Intent
import com.smartwear.core.ConnectionState
import com.smartwear.core.DeviceManager
import com.smartwear.core.RemoteCameraDevice
import com.smartwear.core.RemoteCameraEvent
import com.smartwear.core.SmartWearLog
import com.smartwear.core.WearableDevice
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.merge
import kotlinx.coroutines.launch

/**
 * Chụp ảnh từ xa giữa thiết bị ([RemoteCameraDevice]) và màn [RemoteCameraActivity] của app lab, như
 * `MainService.onDeviceCameraStatus` của GloryFitPro. Phần thông báo / cuộc gọi / nhạc / SMS nằm ở `com.smartwear.core.phone`.
 */
class CameraBridge(private val context: Context, private val manager: DeviceManager, private val scope: CoroutineScope) {

    private val _camera = MutableSharedFlow<RemoteCameraEvent>(extraBufferCapacity = 8)

    /** Lệnh cho [RemoteCameraActivity] đang mở: chụp / đóng. */
    val cameraEvents: SharedFlow<RemoteCameraEvent> = _camera.asSharedFlow()

    /** [RemoteCameraActivity] đang mở (như `MainService.getRunningTasks`). */
    @Volatile
    var cameraShowing = false

    @OptIn(ExperimentalCoroutinesApi::class)
    fun start() {
        scope.launch {
            manager.devices
                .flatMapLatest { list -> list.filterIsInstance<RemoteCameraDevice>().map { it.remoteCameraEvents }.merge() }
                .collect(::onCameraEvent)
        }
    }

    /**
     * Thiết bị mở màn chụp ⇒ mở camera nếu chưa mở; bấm chụp / đóng ⇒ chuyển cho màn camera (SDK đã bỏ lần chụp lặp trong 4 s).
     */
    private fun onCameraEvent(e: RemoteCameraEvent) {
        if (e == RemoteCameraEvent.OPENED && !cameraShowing) {
            runCatching {
                context.startActivity(Intent(context, RemoteCameraActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            }.onFailure { SmartWearLog.w("Không mở được camera: ${it.message}") }
            return
        }
        _camera.tryEmit(e)
    }

    /** Báo mọi thiết bị đang kết nối có chụp ảnh từ xa: mở / đóng màn camera. */
    fun setCameraOpen(open: Boolean) {
        cameraShowing = open
        manager.devices.value
            .filter { it.state.value == ConnectionState.CONNECTED }
            .filterIsInstance<RemoteCameraDevice>()
            .filter { it.supportsRemoteCamera }
            .forEach { scope.launch { it.setRemoteCamera(open) } }
    }

    fun cameraDevices(): List<WearableDevice> = manager.devices.value.filter { it is RemoteCameraDevice && it.supportsRemoteCamera }
}
