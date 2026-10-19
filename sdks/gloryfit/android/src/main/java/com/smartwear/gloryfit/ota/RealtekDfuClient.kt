package com.smartwear.gloryfit.ota

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.content.Context
import com.smartwear.core.BleQuiet
import com.smartwear.core.GattConnection
import com.smartwear.core.SmartWearLog
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Nạp firmware Realtek (Y25) qua BLE từ Android: [probe] chỉ đọc năng lực, [flash] chạy [RealtekDfu] trên một kết nối GATT.
 *
 * ## Kết nối: mở kết nối GATT RIÊNG, giữ nguyên kết nối UTE của [com.smartwear.gloryfit.GloryFitDevice]
 * Làm đúng như app GloryFitPro: `RkOtaUtil.rkConnectDevice()` chỉ chạy khi `UteBleClient` ĐANG kết nối, rồi `GattDfuAdapter`
 * của Realtek tự `connectGatt` một client riêng tới cùng địa chỉ; kết nối UTE không bị ngắt trong suốt OTA. Android ghép
 * nhiều client GATT trên cùng một liên kết vật lý, nên:
 * - không phải nhả kết nối của driver ⇒ `DeviceManager` không lao vào vòng nối lại giành liên kết giữa chừng;
 * - notify của control point 6487 chỉ tới client đã bật CCCD (client DFU), không lẫn vào bộ phân tích gói UTE;
 * - driver không cần biết gì về DFU (service 6287 tách khỏi 55FF/33F1).
 * Nếu driver không kết nối, client này tự lập liên kết. Trong lúc nạp giữ [BleQuiet] để `DeviceManager` ngừng đọc RSSI và
 * hoãn nối lại thiết bị khác. Kết nối DFU đóng KHÔNG gọi `refresh()` (refresh khi liên kết còn sống làm stack khám phá lại
 * service của cả client UTE). Sau `0x04` đồng hồ khởi động lại: cả hai client rớt, driver tự nối lại như mọi lần mất kết nối.
 *
 * Chỉ một phiên DFU mỗi tiến trình ([running]).
 */
@SuppressLint("MissingPermission")
class RealtekDfuClient(
    context: Context,
    private val device: BluetoothDevice,
    private val log: (String) -> Unit = { SmartWearLog.i("OTA $it") },
) {
    private val appContext = context.applicationContext

    /** Kết quả đọc năng lực (FFF3/FFF1/FFD2/FFE0…/FFF4…/2A19), như `read_device` của flasher.py. */
    class DeviceReport(
        val gattTable: Map<UUID, List<Pair<UUID, Int>>>,
        /** Giá trị đọc được theo UUID characteristic (null = có characteristic nhưng đọc lỗi). */
        val values: Map<UUID, ByteArray?>,
        val protocol: Int?,
        val capabilities: DfuCapabilities?,
        val capabilityError: String?,
        val battery: Int?,
        val hasDfuService: Boolean,
        /** Protocol 0x0014: phiên bản/section từng image (FFE0…/FFF4…); null với 0x0010 hoặc khi chưa đọc được năng lực. */
        val imageVersions: DfuImageVersions? = null,
    )

    class Options(
        /** Nghỉ giữa các gói dữ liệu (flasher.py `--delay`, mặc định 10 ms). */
        val packetDelayMs: Long = 10,
        val timeoutMs: Long = 15_000,
        /** false = truyền + VALIDATE, không gửi `0x04` (flasher.py `--no-activate`). */
        val activate: Boolean = true,
        /** Mức pin người dùng khai báo khi không đọc được pin (flasher.py `--battery`). */
        val declaredBattery: Int? = null,
        /** In từng gói control TX/RX (rất nhiều dòng). */
        val trace: Boolean = false,
    )

    /** Chỉ kết nối + khám phá + ĐỌC; không bật notify, không ghi, không đổi MTU. */
    suspend fun probe(): DeviceReport = withLink { gatt -> readDevice(gatt) }

    /**
     * Nạp [image] (phải qua [RealtekImage.verify], kiểm lại ở đây). [batteryHint] = pin đọc qua kênh khác (ví dụ lệnh UTE A2),
     * dùng khi không có Battery Service. [progress] nhận (byte đã xác nhận, tổng). Trả true nếu đã gửi lệnh kích hoạt.
     * Lỗi/huỷ ⇒ ném ngoại lệ và KHÔNG kích hoạt; chạy lại với cùng file để thiết bị trả offset resume.
     */
    suspend fun flash(
        image: RealtekImage,
        batteryHint: Int? = null,
        options: Options = Options(),
        progress: (sent: Int, total: Int) -> Unit = { _, _ -> },
    ): Boolean {
        val dfuImage = DfuImage.from(image)
        if (!running.compareAndSet(false, true)) throw DfuException("Đang có một phiên OTA khác")
        try {
            return BleQuiet.hold {
                withLink { gatt ->
                    val report = readDevice(gatt)
                    val caps = report.capabilities ?: throw DfuException("Thiếu/không hỗ trợ FFF1/FFF3: ${report.capabilityError}")
                    if (!report.hasDfuService) throw DfuException("Thiếu dịch vụ DFU silent 6287/6387/6487; không tự chuyển sang normal mode")
                    val battery = report.battery ?: batteryHint ?: options.declaredBattery
                        ?: throw DfuException("Không đọc được pin; truyền mức pin trên đồng hồ (battery)")
                    val source = when {
                        report.battery != null -> "BLE 2A19"
                        batteryHint != null -> "driver"
                        else -> "người dùng khai báo"
                    }
                    if (battery !in MIN_BATTERY..100) throw DfuException("Pin $battery% ($source); yêu cầu ít nhất $MIN_BATTERY%")
                    log("Pin $battery% ($source)")
                    if (caps.protocol == RealtekDfuSpec.PROTOCOL_X0014) {
                        // Mọi kiểm cục bộ chạy TRƯỚC khi bật notify hay ghi bất cứ gì.
                        val pre = RealtekDfu.preflightX0014(dfuImage, caps, report.imageVersions ?: DfuImageVersions.EMPTY)
                        log("Kiểm trước 0x0014: ${pre.summary()}")
                    }

                    val dfu = RealtekDfu(
                        link = object : DfuLink {
                            private val controlWithResponse = gatt.supportsWriteWithResponse(RealtekDfuSpec.SERVICE, RealtekDfuSpec.CONTROL)
                            override suspend fun writeControl(value: ByteArray) =
                                gatt.write(RealtekDfuSpec.SERVICE, RealtekDfuSpec.CONTROL, value, withResponse = controlWithResponse)
                            override suspend fun writeData(value: ByteArray) =
                                gatt.write(RealtekDfuSpec.SERVICE, RealtekDfuSpec.DATA, value, withResponse = false)
                        },
                        timeoutMs = options.timeoutMs,
                        log = log,
                        trace = if (options.trace) log else null,
                    )
                    gatt.onNotification = { n -> if (n.characteristic == RealtekDfuSpec.CONTROL) dfu.onControlNotification(n.value) }
                    gatt.onDisconnected = { status -> dfu.fail(DfuException("status=$status")) }
                    gatt.enableNotifications(RealtekDfuSpec.SERVICE, RealtekDfuSpec.CONTROL)
                    // SDK: requestMtu(256) (`m/e.C()`). 0x0010: gói vẫn 16 B (buffer-check) / 20 B như flasher.py, MTU chỉ để ghi log.
                    // 0x0014: gói buffer-check = MTU − 3 làm tròn 16 như SDK (`m/d.d(mtu)`); không đổi được MTU ⇒ 16 B.
                    val mtu = runCatching { gatt.requestMtu(MTU) }
                        .onSuccess { log("MTU $it") }
                        .onFailure { log("Không đổi được MTU: ${it.message}") }
                        .getOrNull()
                    log("Bắt đầu nạp image 0x%04X (%d byte) lên %s, caps=%s".format(dfuImage.id, dfuImage.wire.size, device.address, caps))
                    val started = System.currentTimeMillis()
                    val activated = dfu.upload(dfuImage, caps, options.packetDelayMs, options.activate, mtu, progress)
                    log("Xong sau ${(System.currentTimeMillis() - started) / 1000} s, kích hoạt=${activated}")
                    activated
                }
            }
        } finally {
            running.set(false)
        }
    }

    private suspend fun <T> withLink(block: suspend (GattConnection) -> T): T {
        val gatt = GattConnection(appContext, device, operationTimeoutMs = 10_000, refreshCacheOnClose = false)
        log("Mở kết nối DFU riêng tới ${device.address}")
        gatt.connect(timeoutMs = 40_000)
        try {
            return block(gatt)
        } finally {
            gatt.onNotification = null
            gatt.disconnect()
            log("Đã đóng kết nối DFU")
        }
    }

    private suspend fun readDevice(gatt: GattConnection): DeviceReport {
        val table = gatt.gattTable()
        for ((service, chars) in table) {
            log("GATT $service: " + chars.joinToString { (uuid, props) -> "${short(uuid)}(${propsText(props)})" })
        }
        val values = linkedMapOf<UUID, ByteArray?>()
        suspend fun read(uuid: UUID): ByteArray? {
            val service = if (gatt.hasCharacteristic(RealtekDfuSpec.OTA_SERVICE, uuid)) RealtekDfuSpec.OTA_SERVICE else gatt.serviceOf(uuid) ?: return null
            val value = runCatching { gatt.read(service, uuid) }
                .onFailure { log("Đọc ${short(uuid)} lỗi: ${it.message}") }
                .getOrNull()
            values[uuid] = value
            if (value != null) log("${short(uuid)} = ${value.hex()}")
            return value
        }
        val protocolRaw = read(RealtekDfuSpec.PROTOCOL)
        val info = read(RealtekDfuSpec.INFO)
        read(RealtekDfuSpec.MAC)
        val versionValues = RealtekDfuSpec.IMAGE_VERSIONS.mapNotNull { read(it) }
        val sectionValues = RealtekDfuSpec.SECTION_SIZES.mapNotNull { read(it) }
        val battery = read(RealtekDfuSpec.BATTERY)?.firstOrNull()?.toInt()?.and(0xFF)
        val protocol = protocolRaw?.takeIf { it.size >= 2 }?.let { RealtekDfuSpec.u16(it, 0) }
        var capsError: String? = null
        val caps = when {
            protocolRaw == null || info == null -> null.also { capsError = "không có FFF3/FFF1" }
            protocol == null -> null.also { capsError = "FFF3 quá ngắn" }
            else -> runCatching { DfuCapabilities.parse(info, protocol) }.onFailure { capsError = it.message }.getOrNull()
        }
        val hasDfu = gatt.hasCharacteristic(RealtekDfuSpec.SERVICE, RealtekDfuSpec.CONTROL) &&
            gatt.hasCharacteristic(RealtekDfuSpec.SERVICE, RealtekDfuSpec.DATA)
        val versions = caps?.takeIf { it.protocol == RealtekDfuSpec.PROTOCOL_X0014 }
            ?.let { DfuImageVersions.parseX0014(versionValues, sectionValues, it.longImageVersion) }
        log("protocol=${protocol?.let { "0x%04X".format(it) }} caps=${caps ?: "?"}${capsError?.let { " ($it)" } ?: ""} pin=${battery ?: "?"} dịch vụ DFU=${if (hasDfu) "có" else "KHÔNG"}")
        versions?.let { log("image: ${it.summary()}") }
        return DeviceReport(table, values, protocol, caps, capsError, battery, hasDfu, versions)
    }

    private fun short(uuid: UUID): String = uuid.toString().let { if (it.endsWith("-0000-1000-8000-00805f9b34fb")) it.substring(4, 8) else it }

    private fun propsText(p: Int) = buildList {
        if (p and 0x02 != 0) add("read")
        if (p and 0x04 != 0) add("writeNoRsp")
        if (p and 0x08 != 0) add("write")
        if (p and 0x10 != 0) add("notify")
        if (p and 0x20 != 0) add("indicate")
    }.joinToString("|")

    companion object {
        const val MIN_BATTERY = 50
        const val MTU = 256
        private val running = AtomicBoolean(false)

        /** Có phiên OTA đang chạy trong tiến trình không. */
        val isRunning: Boolean get() = running.get()
    }
}
