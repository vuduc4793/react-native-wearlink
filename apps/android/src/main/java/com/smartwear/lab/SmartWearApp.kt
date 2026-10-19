package com.smartwear.lab

import android.app.Application
import com.smartwear.core.DeviceManager
import com.smartwear.core.DeviceRegistry
import com.smartwear.core.SmartWearLog
import com.smartwear.core.phone.KeepConnectedService
import com.smartwear.core.phone.PhoneLink
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.launch
import com.smartwear.gloryfit.GloryFitDriver
import com.smartwear.qring.QRingDriver
import com.smartwear.standard.StandardDriver
import com.smartwear.veepoo.VeepooDriver

class SmartWearApp : Application() {

    /**
     * Một DeviceManager cho cả app, sống qua việc xoay/tạo lại Activity.
     * Thứ tự driver: driver cụ thể trước, Bluetooth chuẩn sau cùng.
     */
    val manager: DeviceManager by lazy {
        DeviceManager(this, DeviceRegistry(listOf(QRingDriver, GloryFitDriver, VeepooDriver, StandardDriver)))
    }

    private val scope = MainScope()

    /** Thiết kế mặt đồng hồ đã lưu + tự cài lại khi kết nối. */
    val watchFaces: WatchFaceStore by lazy { WatchFaceStore(this, manager) }

    /** Đổ chuông khi đồng hồ/vòng bấm "tìm điện thoại". */
    val findPhone: FindPhoneRinger by lazy { FindPhoneRinger(this, manager, scope) }

    /** Dự báo thời tiết gửi lên đồng hồ. */
    val weather: WeatherService by lazy { WeatherService(this, manager, scope) }

    /** Thông báo, cuộc gọi, nhạc, trả lời SMS giữa điện thoại và thiết bị (core `com.smartwear.core.phone`). */
    val phone: PhoneLink by lazy { PhoneLink(this, manager, scope) }

    /** Chụp ảnh từ xa (màn camera của app lab). */
    val camera: CameraBridge by lazy { CameraBridge(this, manager, scope) }

    override fun onCreate() {
        super.onCreate()
        SmartWearLog.verbose = BuildConfig.DEBUG
        watchFaces.start()
        findPhone.start()
        weather.start()
        phone.start()
        camera.start()
    }

    /**
     * Bật foreground service khi có thiết bị cần giữ kết nối, tắt khi không còn. Gọi từ Activity
     * (lúc app đang ở foreground), vì Android 12+ không cho bật foreground service từ nền.
     */
    fun bindConnectionService() = KeepConnectedService.bind(this, manager, scope)
}
