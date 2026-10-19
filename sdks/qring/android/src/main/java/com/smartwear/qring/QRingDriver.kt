package com.smartwear.qring

import android.content.Context
import com.smartwear.core.BaseWearableDevice
import com.smartwear.core.Capability
import com.smartwear.core.ConfigurableDevice
import com.smartwear.core.ControlValue
import com.smartwear.core.DeviceControl
import com.smartwear.core.ConnectionState
import com.smartwear.core.DeviceDriver
import com.smartwear.core.DeviceInfo
import com.smartwear.core.DriverMatch
import com.smartwear.core.Reading
import com.smartwear.core.ReadingStatus
import com.smartwear.core.ScannedDevice
import com.smartwear.core.toHex
import com.smartwear.core.ActivityTotals
import com.smartwear.core.DeviceHistory
import com.smartwear.core.HistoryPoint
import com.smartwear.core.SleepSession
import com.smartwear.core.SyncProgress
import com.smartwear.qring.protocol.HistoryParser
import com.smartwear.qring.protocol.Packet
import java.time.LocalDate
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch

/** Driver cho dòng thiết bị chạy giao thức QRing (Colmi R0x/R1x, HS500A…). */
object QRingDriver : DeviceDriver {
    override val id = "qring"
    override val displayName = "QRing / QWatch"

    override fun match(device: ScannedDevice): DriverMatch? {
        if (!QRing.matches(device)) return null
        val name = device.name.orEmpty()
        val model = when {
            name.startsWith("R") && name.getOrNull(1)?.isDigit() == true -> "Colmi ${name.substringBefore('_')}"
            name.isNotEmpty() -> name.substringBefore('_')
            else -> "Thiết bị QRing"
        }
        return DriverMatch(model)
    }

    override fun create(context: Context, device: ScannedDevice, match: DriverMatch) =
        QRingDevice(context, device, match.model)
}

/** Một thiết bị QRing theo mô hình chung [com.smartwear.core.WearableDevice]. */
class QRingDevice(
    context: Context,
    scanned: ScannedDevice,
    private val model: String,
) : BaseWearableDevice(scanned.address, scanned.name ?: model, QRingDriver), ConfigurableDevice {

    val client = QRingClient(context, scanned.device)
    private val parser = HistoryParser()

    // ---------- Cài đặt (QRingSettings) ----------

    @Volatile
    private var settingValues: Map<String, Int> = emptyMap()
    private val _controls = MutableStateFlow<List<DeviceControl>>(emptyList())
    override val controls: StateFlow<List<DeviceControl>> = _controls.asStateFlow()

    /** `22 01` = thiết bị tìm điện thoại, `22 02` = dừng (`FindPhoneRsp`). */
    override val findPhoneRequests = client.events
        .filter { it.command == 0x22 && it.u8(0) in 1..2 }
        .map { it.u8(0) == 1 }
    private var qringCaps: QRingCapabilities? = null

    override val supportsHistory: Boolean get() = true
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val advertisedMac = QRing.macFromAdvertisement(scanned)

    init {
        client.listener = object : QRingClient.Listener {
            override fun onPacketSent(bytes: ByteArray) = this@QRingDevice.onPacketSent(bytes)
            override fun onPacketReceived(bytes: ByteArray) = this@QRingDevice.onPacketReceived(bytes, describe(bytes))
            override fun onLatency(ms: Long) = this@QRingDevice.onLatency(ms)
            override fun onTimeout(command: Int) = onError("Lệnh 0x%02X không có phản hồi".format(command))
        }
        client.onDisconnected = { status -> onError("Mất kết nối (status=$status)") }
        _info.value = DeviceInfo(model = model, extra = baseExtra())
        scope.launch { client.state.collect(::onTransportState) }
        // Notify 0x73 dataType 12: pin thay đổi (kiểm chứng trên R09: 73 0C 13 = 19 %).
        scope.launch {
            client.events.collect { p ->
                if (p.command == 0x73 && p.u8(0) == 12) _battery.value = p.u8(1)
            }
        }
    }

    override suspend fun connect() {
        _lastError.value = null
        try {
            val info = client.connect()
            val caps = info.qringCapabilities
            qringCaps = caps
            _capabilities.value = info.capabilities
            _measurable.value = info.capabilities.filter { it.measurementType() != null }.toSet()
            _info.value = DeviceInfo(
                model = model,
                hardware = info.hardwareRevision,
                firmware = info.firmwareRevision,
                extra = baseExtra() + linkedMapOf(
                    "Bảng SetTime (0x01)" to info.timeCapabilities.toHex(),
                    "Bảng DeviceSupport (0x3C)" to info.supportCapabilities.toHex(),
                    "Giấc ngủ" to if (caps.newSleepProtocol) "Giao thức mới (big-data 0x27)" else "Giao thức cũ (0x44)",
                    "Yêu cầu ghép đôi" to if (caps.blePair) "Có (blePair)" else "Không",
                    "Màn hình" to if (caps.noScreen) "Không" else "Có",
                ),
            )
            refreshBattery()
            refreshRssi()
            _controls.value = QRingSettings.controls(caps, settingValues, isRing(caps))
            markReady()
            scope.launch { loadSettings(caps) }
        } catch (e: Exception) {
            onError("Kết nối lỗi: ${e.message}")
            throw e
        }
    }

    override fun disconnect() = client.disconnect()

    /** Nhẫn: cờ `noScreen` hoặc phần cứng/tên kiểu nhẫn (R09 không bật cờ; phần cứng `RT09_V3.1`, tên `R09_8404`). */
    private fun isRing(caps: QRingCapabilities): Boolean {
        val hw = _info.value?.hardware.orEmpty().uppercase()
        return caps.noScreen || hw.startsWith("RT0") || hw.startsWith("RT1") || Regex("^R\\d").containsMatchIn(name.uppercase())
    }

    /** Đọc cài đặt hiện tại trên thiết bị; mục không trả lời giữ mặc định. */
    private suspend fun loadSettings(caps: QRingCapabilities) {
        for (req in QRingSettings.reads(caps, isRing(caps))) {
            if (state.value != ConnectionState.CONNECTED) return
            runCatching { client.request(req, timeoutMs = 2_000) }
                .onSuccess { rsp -> settingValues = settingValues + QRingSettings.parse(rsp.command, IntArray(14) { rsp.u8(it) }) }
        }
        _controls.value = QRingSettings.controls(caps, settingValues, isRing(caps))
    }

    override suspend fun setControl(id: String, value: ControlValue) {
        val caps = qringCaps ?: throw QRingException("Chưa kết nối")
        settingValues = QRingSettings.apply(settingValues, id, value)
        _controls.value = QRingSettings.controls(caps, settingValues, isRing(caps))
        if (state.value != ConnectionState.CONNECTED) return
        QRingSettings.write(id, settingValues)?.let { client.sendNoResponse(it) }
    }

    override suspend fun runAction(id: String) {
        if (state.value != ConnectionState.CONNECTED) throw QRingException("Thiết bị chưa kết nối")
        when (id) {
            "find.start" -> client.sendNoResponse(QRingSettings.FIND)
            else -> throw QRingException("Không có hành động $id")
        }
    }

    override suspend fun refreshBattery() {
        runCatching { client.battery() }
            .onSuccess { _battery.value = it.level; _charging.value = it.charging }
            .onFailure { onError("Đọc pin lỗi: ${it.message}") }
    }

    override suspend fun refreshRssi() {
        runCatching { client.readRssi() }.onSuccess(::onRssi)
    }

    /**
     * Đồng bộ lịch sử theo trình tự của app QRing (03-history-sync.md §6), mỗi bước độc lập:
     * bước lỗi được ghi vào [DeviceHistory.errors], các bước khác vẫn chạy.
     */
    override suspend fun syncHistoryImpl(days: Int, progress: (SyncProgress) -> Unit): DeviceHistory {
        val caps = qringCaps ?: throw QRingException("Chưa kết nối")
        val dayCount = days.coerceIn(1, 7)
        val today = LocalDate.now()
        val series = mutableMapOf<Capability, MutableList<HistoryPoint>>()
        val errors = mutableListOf<String>()
        var sleep = emptyList<SleepSession>()
        var totals: ActivityTotals? = null

        data class Step(val label: String, val run: suspend () -> Unit)
        val steps = mutableListOf<Step>()
        fun add(cap: Capability, points: List<HistoryPoint>) {
            series.getOrPut(cap) { mutableListOf() } += points
        }

        steps += Step("Tổng hôm nay") { totals = parser.parseTodayTotals(client.request(Packet.of(HistoryParser.CMD_TODAY_TOTALS))) }
        for (d in 0 until dayCount) {
            val date = today.minusDays(d.toLong())
            val label = if (d == 0) "hôm nay" else "$d ngày trước"
            steps += Step("Bước chân $label") {
                add(Capability.STEPS, parser.parseSteps(client.requestStream(parser.stepsRequest(d), isComplete = parser::stepsComplete)))
            }
            steps += Step("Nhịp tim $label") {
                add(Capability.HEART_RATE, parser.parseHeartRate(client.requestStream(parser.heartRateRequest(date), isComplete = parser::heartRateComplete), date))
            }
            if (caps.hrv) steps += Step("HRV $label") {
                add(Capability.HRV, parser.parseDaily(client.requestStream(parser.hrvRequest(d), isComplete = parser::dailyComplete), date))
            }
            if (caps.stress) steps += Step("Stress $label") {
                add(Capability.STRESS, parser.parseDaily(client.requestStream(parser.stressRequest(d), isComplete = parser::dailyComplete), date))
            }
            if (caps.temperature) steps += Step("Nhiệt độ $label") {
                val pages = mutableListOf<HistoryParser.IntervalPage>()
                var page = 0
                while (page < 16) {
                    val frame = client.requestBigData(parser.intervalRequest(HistoryParser.CMD_TEMPERATURE_INTERVAL, d, page))
                    val parsed = parser.parseIntervalPage(frame.payload, twoByteValues = true) ?: break
                    if (parsed.count == 0) break
                    pages += parsed
                    if (parsed.index >= parsed.count - 1) break
                    page++
                }
                add(Capability.TEMPERATURE, parser.intervalPoints(pages, today))
            }
        }
        if (caps.newSleepProtocol) steps += Step("Giấc ngủ") {
            val frames = client.requestBigDataMulti(parser.sleepRequest(), setOf(HistoryParser.CMD_SLEEP, HistoryParser.CMD_NAP))
            sleep = frames[HistoryParser.CMD_SLEEP]?.let { parser.parseSleep(it.payload, today) }.orEmpty() +
                frames[HistoryParser.CMD_NAP]?.let { parser.parseSleep(it.payload, today, nap = true) }.orEmpty()
        } else {
            errors += "Giấc ngủ: thiết bị dùng giao thức cũ (0x44), SDK chưa hỗ trợ"
        }
        if (caps.spo2) steps += Step("SpO2") {
            add(Capability.SPO2, parser.parseSpo2(client.requestBigData(parser.spo2Request()).payload, today))
        }

        steps.forEachIndexed { i, step ->
            progress(SyncProgress(step.label, i, steps.size))
            runCatching { step.run() }.onFailure { errors += "${step.label}: ${it.message}" }
        }
        return DeviceHistory(
            series = series.mapValues { (_, v) -> v.distinctBy { it.timestamp }.sortedBy { it.timestamp } },
            sleep = sleep.sortedBy { it.start },
            today = totals,
            days = dayCount,
            syncedAt = System.currentTimeMillis(),
            errors = errors,
        )
    }

    override fun measureImpl(capability: Capability): Flow<Reading> {
        val type = capability.measurementType() ?: return emptyFlow()
        return client.measure(type)
            .map { it.toReading(capability) }
            .catch { e ->
                onError("Đo lỗi: ${e.message}")
                emit(Reading(capability, ReadingStatus.ERROR))
            }
    }

    private fun baseExtra() = buildMap {
        put("Driver", "QRing (sdks/qring)")
        put("Địa chỉ", id)
        if (advertisedMac != null) put("MAC trong quảng bá", advertisedMac)
    }

    /** Mô tả ngắn cho log gói tin. */
    private fun describe(bytes: ByteArray): String? {
        if (bytes.size != 16) return null
        val cmd = bytes[0].toInt() and 0x7F
        val p1 = bytes[1].toInt() and 0xFF
        val p2 = bytes[2].toInt() and 0xFF
        val p3 = bytes[3].toInt() and 0xFF
        return when {
            bytes[0].toInt() and 0x80 != 0 -> "lỗi lệnh 0x%02X".format(cmd)
            cmd == 0x03 -> "pin $p1 %"
            cmd == 0x69 && p2 == 1 -> "chưa đeo"
            cmd == 0x69 && p3 > 0 -> "giá trị $p3 (loại $p1)"
            cmd == 0x69 -> "đang đo (loại $p1)"
            cmd == 0x73 -> "thông báo loại $p1"
            cmd == 0x2F -> "kích thước gói $p1"
            else -> null
        }
    }

    fun close() {
        disconnect()
        scope.cancel()
    }
}

private fun MeasurementReading.toReading(capability: Capability) = Reading(
    capability = capability,
    status = when (status) {
        MeasurementStatus.MEASURING -> ReadingStatus.MEASURING
        MeasurementStatus.OK -> ReadingStatus.OK
        MeasurementStatus.NOT_WORN -> ReadingStatus.NOT_WORN
        MeasurementStatus.ERROR -> ReadingStatus.ERROR
    },
    value = value,
    systolic = systolic,
    diastolic = diastolic,
    errorCode = errorCode,
)
