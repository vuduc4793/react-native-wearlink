package com.smartwear.lab

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.content.Context
import com.smartwear.core.SmartWearLog
import com.smartwear.gloryfit.ota.RealtekDfuClient
import com.smartwear.gloryfit.ota.RealtekImage
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import java.io.File

/**
 * Lệnh OTA firmware Realtek (Y25) cho kênh lệnh adb của [MainActivity]. Mọi dòng log có tiền tố `OTA` (tag `SmartWear`).
 *
 * - `otaCheck`: chỉ đọc + kiểm tra file trên điện thoại, không Bluetooth.
 * - `otaProbe`: kết nối DFU riêng, chỉ ĐỌC năng lực (FFF3/FFF1/FFD2/FFE0…/FFF4…/2A19), không ghi gì.
 * - `ota`: kiểm tra file rồi nạp. Chạy trong scope của tiến trình (không theo Activity) để xoay/tạo lại Activity không cắt
 *   ngang; huỷ bằng `otaCancel` (không bao giờ kích hoạt khi huỷ/lỗi).
 */
object OtaCommands {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    @Volatile private var job: Job? = null

    private fun log(message: String) = SmartWearLog.i("OTA $message")

    /** Đọc + kiểm tra đầy đủ; trả null (đã log lý do) nếu file không hợp lệ. */
    fun check(path: String?): RealtekImage? {
        if (path.isNullOrBlank()) {
            log("thiếu --es file <đường dẫn .bin trên điện thoại>")
            return null
        }
        return runCatching { RealtekImage.load(File(path).readBytes()) }
            .onSuccess { log("file hợp lệ: $path, sha256 ${it.fileSha256}; ${it.summary()}") }
            .onFailure { log("TỪ CHỐI file $path: ${it.message}") }
            .getOrNull()
    }

    @SuppressLint("MissingPermission")
    fun remoteDevice(context: Context, address: String): BluetoothDevice? =
        runCatching { context.getSystemService(BluetoothManager::class.java)?.adapter?.getRemoteDevice(address.uppercase()) }.getOrNull()

    fun probe(context: Context, device: BluetoothDevice) {
        if (!claim("otaProbe")) return
        job = scope.launch {
            try {
                val report = RealtekDfuClient(context, device).probe()
                log("probe xong: protocol=${report.protocol?.let { "0x%04X".format(it) }} caps=${report.capabilities ?: report.capabilityError} " +
                    "pin=${report.battery ?: "không có 2A19"} DFU=${report.hasDfuService}" +
                    (report.imageVersions?.let { " image: ${it.summary()}" } ?: ""))
            } catch (e: CancellationException) {
                log("probe đã huỷ")
                throw e
            } catch (e: Exception) {
                log("probe lỗi: ${e.message}")
            }
        }
    }

    fun flash(context: Context, device: BluetoothDevice, image: RealtekImage, batteryHint: Int?, options: RealtekDfuClient.Options) {
        if (!claim("ota")) return
        job = scope.launch {
            var lastPercent = -1
            try {
                val activated = RealtekDfuClient(context, device).flash(image, batteryHint, options) { sent, total ->
                    val percent = (sent.toLong() * 100 / total).toInt()
                    if (percent != lastPercent) {
                        lastPercent = percent
                        if (percent % 5 == 0) log("tiến độ $percent% ($sent/$total)")
                    }
                }
                log(if (activated) "THÀNH CÔNG: đã validate + gửi kích hoạt; đồng hồ khởi động lại, kết nối lại để xem phiên bản"
                    else "THÀNH CÔNG: đã validate, CHƯA kích hoạt (otaNoActivate)")
            } catch (e: CancellationException) {
                log("ĐÃ HUỶ ở $lastPercent%: không kích hoạt. Chạy lại cùng file để tiếp tục từ offset thiết bị báo")
                throw e
            } catch (e: Exception) {
                log("LỖI ở $lastPercent%: ${e.message}. Không kích hoạt. Chạy lại cùng file để tiếp tục từ offset thiết bị báo")
            }
        }
    }

    fun cancel() {
        val j = job
        if (j == null || !j.isActive) log("không có phiên OTA nào đang chạy") else {
            log("huỷ theo yêu cầu")
            j.cancel()
        }
    }

    private fun claim(action: String): Boolean {
        if (job?.isActive == true || RealtekDfuClient.isRunning) {
            log("bỏ qua $action: đang có phiên OTA khác (dùng --es action otaCancel để huỷ)")
            return false
        }
        return true
    }
}
