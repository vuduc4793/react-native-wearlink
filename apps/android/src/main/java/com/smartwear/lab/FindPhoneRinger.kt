package com.smartwear.lab

import android.content.Context
import android.media.AudioAttributes
import android.media.Ringtone
import android.media.RingtoneManager
import com.smartwear.core.ConfigurableDevice
import com.smartwear.core.DeviceManager
import com.smartwear.core.SmartWearLog
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.merge
import kotlinx.coroutines.launch

/**
 * Đồng hồ/vòng bấm "tìm điện thoại": đổ chuông báo thức tối đa 30 giây, dừng khi thiết bị báo dừng
 * hoặc người dùng bấm "Đã tìm thấy". Báo thiết bị lúc bắt đầu và lúc dừng ([ConfigurableDevice.setPhoneRinging])
 * để đồng hồ tắt màn "đang tìm điện thoại".
 */
class FindPhoneRinger(private val context: Context, private val manager: DeviceManager, private val scope: CoroutineScope) {
    private val _ringing = MutableStateFlow<String?>(null)
    /** Tên thiết bị đang tìm điện thoại, null khi không đổ chuông. */
    val ringing: StateFlow<String?> = _ringing.asStateFlow()
    private var ringtone: Ringtone? = null
    private var timeout: Job? = null
    /** Thiết bị đang tìm điện thoại. */
    private var source: ConfigurableDevice? = null

    @OptIn(ExperimentalCoroutinesApi::class)
    fun start() {
        scope.launch {
            manager.devices
                .flatMapLatest { list ->
                    list.filterIsInstance<ConfigurableDevice>().map { d -> d.findPhoneRequests.map { d to it } }.merge()
                }
                .collect { (device, on) -> if (on) ring(device) else stop() }
        }
    }

    private fun ring(device: ConfigurableDevice) {
        val name = (device as? com.smartwear.core.WearableDevice)?.name ?: "Thiết bị"
        SmartWearLog.i("[$name] tìm điện thoại")
        _ringing.value = name
        source = device
        scope.launch { device.setPhoneRinging(true) }
        if (ringtone?.isPlaying != true) {
            val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM) ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
            ringtone = RingtoneManager.getRingtone(context, uri)?.apply {
                audioAttributes = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).build()
                if (android.os.Build.VERSION.SDK_INT >= 28) isLooping = true
                play()
            }
        }
        timeout?.cancel()
        timeout = scope.launch { delay(30_000); stop() }
    }

    fun stop() {
        timeout?.cancel()
        ringtone?.stop()
        ringtone = null
        _ringing.value = null
        source?.let { device ->
            source = null
            scope.launch { device.setPhoneRinging(false) }
        }
    }
}
