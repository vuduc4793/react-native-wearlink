package com.smartwear.qring

import android.bluetooth.BluetoothDevice
import android.content.Context
import com.smartwear.core.Capability
import com.smartwear.core.ConnectionState
import com.smartwear.core.GattConnection
import com.smartwear.core.GattNotification
import com.smartwear.core.SmartWearLog
import com.smartwear.core.toHex
import com.smartwear.qring.protocol.BigDataAssembler
import com.smartwear.qring.protocol.BigDataFrame
import com.smartwear.qring.protocol.Packet
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.channelFlow
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.onCompletion
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import java.util.Calendar
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap

class QRingException(message: String) : Exception(message)

/** Thông tin đọc được trong lúc bắt tay. */
data class QRingDeviceInfo(
    val hardwareRevision: String,
    val firmwareRevision: String,
    /** Phản hồi thô của lệnh 0x01 SetTime: bảng khả năng (xem sdks/qring/docs/01-connection.md §4.2). */
    val timeCapabilities: ByteArray,
    /** Phản hồi thô của lệnh 0x3C DeviceSupport. */
    val supportCapabilities: ByteArray,
) {
    val qringCapabilities: QRingCapabilities get() = QRingCapabilities(timeCapabilities, supportCapabilities)

    /** Khả năng chuẩn hoá để UI sinh chức năng theo thiết bị. */
    val capabilities: Set<Capability> get() = qringCapabilities.toCapabilities()
}

data class Battery(val level: Int, val charging: Boolean)

/**
 * Client cho một chiếc nhẫn QRing. Một request/response tại một thời điểm; các notify ring tự
 * gửi (không khớp request nào) được phát qua [events].
 */
class QRingClient(context: Context, device: BluetoothDevice) {

    private val gatt = GattConnection(context.applicationContext, device)
    private val requestLock = Mutex()
    private val waiters = ConcurrentHashMap<Int, CompletableDeferred<Packet>>()
    private val bigDataWaiters = ConcurrentHashMap<Int, CompletableDeferred<BigDataFrame>>()
    private val collectors = ConcurrentHashMap<Int, Channel<Packet>>()
    private val bigData = BigDataAssembler(::onBigDataFrame)
    private var bigDataChunkSize = 20

    val address: String = device.address
    val state: StateFlow<ConnectionState> get() = gatt.state

    private val _events = MutableSharedFlow<Packet>(extraBufferCapacity = 64, onBufferOverflow = BufferOverflow.DROP_OLDEST)

    /** Gói 16 byte ring tự gửi, không phải phản hồi của request đang chờ. */
    val events: SharedFlow<Packet> = _events

    var deviceInfo: QRingDeviceInfo? = null
        private set

    /** Hook theo dõi kênh (log gói tin, thống kê). Gọi trên luồng Bluetooth, không làm việc nặng. */
    interface Listener {
        fun onPacketSent(bytes: ByteArray) {}
        fun onPacketReceived(bytes: ByteArray) {}
        fun onLatency(ms: Long) {}
        fun onTimeout(command: Int) {}
    }

    @Volatile
    var listener: Listener? = null

    var onDisconnected: ((status: Int) -> Unit)?
        get() = gatt.onDisconnected
        set(value) { gatt.onDisconnected = value }

    init {
        gatt.onNotification = ::onNotification
    }

    /** Kết nối và chạy các bước bắt tay giống app QRing. */
    suspend fun connect(): QRingDeviceInfo {
        gatt.connect()
        try {
            gatt.enableNotifications(QRing.SERVICE, QRing.NOTIFY)
            val hw = gatt.read(QRing.DEVICE_INFO, QRing.HARDWARE_REVISION).decodeToString().trim()
            val fw = gatt.read(QRing.DEVICE_INFO, QRing.FIRMWARE_REVISION).decodeToString().trim()
            if (gatt.hasService(QRing.BIG_DATA_SERVICE)) {
                gatt.enableNotifications(QRing.BIG_DATA_SERVICE, QRing.BIG_DATA_NOTIFY)
            }
            val time = setTime()
            sendNoResponse(phoneInfoPacket())
            val support = request(Packet.of(CMD_DEVICE_SUPPORT))
            val info = QRingDeviceInfo(hw, fw, time.payload, support.payload)
            deviceInfo = info
            SmartWearLog.i("QRing $address sẵn sàng: hw=$hw fw=$fw")
            return info
        } catch (e: Exception) {
            disconnect()
            throw e
        }
    }

    fun disconnect() {
        gatt.disconnect()
        val error = QRingException("Đã ngắt kết nối")
        waiters.values.forEach { it.completeExceptionally(error) }
        bigDataWaiters.values.forEach { it.completeExceptionally(error) }
        bigData.reset()
    }

    suspend fun readRssi(): Int = gatt.readRssi()

    suspend fun battery(): Battery {
        val p = request(Packet.of(CMD_BATTERY))
        return Battery(level = p.u8(0), charging = p.u8(1) == 1)
    }

    /**
     * Đo thủ công và phát từng gói kết quả cho đến khi bị huỷ. Khi flow kết thúc (huỷ, lỗi,
     * ring im lặng quá [idleTimeoutMs], hoặc người dùng dừng collect), SDK tự gửi lệnh stop.
     */
    fun measure(type: MeasurementType, idleTimeoutMs: Long = 5_000): Flow<MeasurementReading> = channelFlow {
        var lastPacketAt = System.currentTimeMillis()
        val listener = launch(start = CoroutineStart.UNDISPATCHED) {
            events
                .filter { it.command == CMD_START_MEASURE && (it.isError || it.u8(0) == type.code) }
                .collect {
                    lastPacketAt = System.currentTimeMillis()
                    val reading = MeasurementReading.parse(type, it)
                    send(reading)
                    // Ring tự dừng đo sau khi báo chưa đeo / lỗi (đã kiểm chứng trên R09), nên kết thúc flow.
                    if (reading.status == MeasurementStatus.NOT_WORN || reading.status == MeasurementStatus.ERROR) channel.close()
                }
        }
        // Ring không gửi gói kết thúc: sau khi có kết quả nó im lặng (R09: ~5 s sau giá trị đầu tiên).
        // Không dùng keep-alive 1E 03 như app gốc vì firmware R09 trả lỗi 9E cho lệnh đó.
        val watchdog = launch {
            while (true) {
                delay(1_000)
                if (System.currentTimeMillis() - lastPacketAt > idleTimeoutMs) channel.close()
            }
        }
        sendNoResponse(Packet.of(CMD_START_MEASURE, type.code, type.sub))
        awaitClose()
        listener.cancel()
        watchdog.cancel()
    }.onCompletion {
        withContext(NonCancellable) {
            runCatching { if (state.value == ConnectionState.CONNECTED) sendNoResponse(Packet.of(CMD_STOP_MEASURE, type.code)) }
        }
    }

    /** Đo và trả về kết quả hợp lệ đầu tiên. Ném [QRingException] nếu chưa đeo nhẫn, ring báo lỗi hoặc hết giờ. */
    suspend fun measureOnce(type: MeasurementType, timeoutMs: Long = 60_000): MeasurementReading = try {
        withTimeout(timeoutMs) {
            measure(type).first { it.status != MeasurementStatus.MEASURING }
        }.also {
            if (it.status == MeasurementStatus.NOT_WORN) throw QRingException("Chưa đeo nhẫn")
            if (it.status == MeasurementStatus.ERROR) throw QRingException("Ring báo lỗi khi đo $type (mã ${it.errorCode})")
        }
    } catch (e: TimeoutCancellationException) {
        throw QRingException("Hết thời gian đo $type")
    }

    /** Đặt giờ ring theo giờ địa phương của điện thoại. Phản hồi là bảng khả năng của ring. */
    suspend fun setTime(now: Calendar = Calendar.getInstance()): Packet {
        val t = (now.clone() as Calendar).apply { add(Calendar.SECOND, 1) }
        return request(
            Packet.of(
                CMD_SET_TIME,
                bcd(t.get(Calendar.YEAR) % 2000), bcd(t.get(Calendar.MONTH) + 1), bcd(t.get(Calendar.DAY_OF_MONTH)),
                bcd(t.get(Calendar.HOUR_OF_DAY)), bcd(t.get(Calendar.MINUTE)), bcd(t.get(Calendar.SECOND)),
                languageCode(),
            ),
        )
    }

    /**
     * Gửi một lệnh 16 byte và chờ phản hồi có cùng mã lệnh. Ném [QRingException] khi hết giờ
     * hoặc ring trả cờ lỗi.
     */
    suspend fun request(packet: Packet, timeoutMs: Long = 5_000): Packet = requestLock.withLock {
        val waiter = CompletableDeferred<Packet>()
        waiters[packet.command] = waiter
        try {
            val started = System.currentTimeMillis()
            write(packet)
            val rsp = withTimeout(timeoutMs) { waiter.await() }
            listener?.onLatency(System.currentTimeMillis() - started)
            if (rsp.isError) throw QRingException("Ring báo lỗi cho lệnh 0x%02X: %s".format(packet.command, rsp))
            rsp
        } catch (e: TimeoutCancellationException) {
            listener?.onTimeout(packet.command)
            throw QRingException("Không nhận được phản hồi lệnh 0x%02X".format(packet.command))
        } finally {
            waiters.remove(packet.command, waiter)
        }
    }

    /**
     * Gửi một lệnh có phản hồi nhiều gói (dữ liệu lịch sử) và gom các gói cùng mã lệnh cho đến khi
     * [isComplete] trả về true. Nếu ring ngừng gửi quá [idleTimeoutMs] thì trả về phần đã nhận
     * (có thể rỗng); SDK gốc không có timeout, còn ở đây không bao giờ treo.
     */
    suspend fun requestStream(
        packet: Packet,
        idleTimeoutMs: Long = 4_000,
        isComplete: (List<Packet>) -> Boolean,
    ): List<Packet> = requestLock.withLock {
        val channel = Channel<Packet>(Channel.UNLIMITED)
        collectors[packet.command] = channel
        val received = mutableListOf<Packet>()
        try {
            val started = System.currentTimeMillis()
            write(packet)
            while (true) {
                val next = withTimeoutOrNull(idleTimeoutMs) { channel.receive() } ?: break
                if (received.isEmpty()) listener?.onLatency(System.currentTimeMillis() - started)
                if (next.isError) throw QRingException("Ring báo lỗi cho lệnh 0x%02X".format(packet.command))
                received += next
                if (isComplete(received)) break
            }
            if (received.isEmpty()) listener?.onTimeout(packet.command)
            received
        } finally {
            collectors.remove(packet.command, channel)
            channel.close()
        }
    }

    /** Gửi lệnh không chờ phản hồi. */
    suspend fun sendNoResponse(packet: Packet) = requestLock.withLock { write(packet) }

    /** Gửi khung big-data và chờ khung phản hồi cùng mã lệnh. */
    suspend fun requestBigData(frame: BigDataFrame, timeoutMs: Long = 10_000): BigDataFrame = requestLock.withLock {
        val waiter = CompletableDeferred<BigDataFrame>()
        bigDataWaiters[frame.command] = waiter
        try {
            for (chunk in frame.chunks(bigDataChunkSize)) {
                listener?.onPacketSent(chunk)
                gatt.write(QRing.BIG_DATA_SERVICE, QRing.BIG_DATA_WRITE, chunk, withResponse = false)
            }
            withTimeout(timeoutMs) { waiter.await() }
        } catch (e: TimeoutCancellationException) {
            throw QRingException("Không nhận được phản hồi big-data 0x%02X".format(frame.command))
        } finally {
            bigDataWaiters.remove(frame.command, waiter)
        }
    }

    /**
     * Gửi một khung big-data và chờ các khung phản hồi có mã trong [expect] (ví dụ giấc ngủ 0x27
     * kéo theo ngủ trưa 0x3E). Trả về những khung đã nhận khi đủ hoặc hết [timeoutMs].
     */
    suspend fun requestBigDataMulti(frame: BigDataFrame, expect: Set<Int>, timeoutMs: Long = 10_000): Map<Int, BigDataFrame> =
        requestLock.withLock {
            val pending = expect.associateWith { CompletableDeferred<BigDataFrame>() }
            pending.forEach { (cmd, waiter) -> bigDataWaiters[cmd] = waiter }
            try {
                for (chunk in frame.chunks(bigDataChunkSize)) {
                    listener?.onPacketSent(chunk)
                    gatt.write(QRing.BIG_DATA_SERVICE, QRing.BIG_DATA_WRITE, chunk, withResponse = false)
                }
                withTimeoutOrNull(timeoutMs) { pending.values.forEach { it.await() } }
                pending.filterValues { it.isCompleted && !it.isCancelled }.mapValues { it.value.getCompleted() }
            } finally {
                pending.forEach { (cmd, waiter) -> bigDataWaiters.remove(cmd, waiter) }
            }
        }

    private suspend fun write(packet: Packet) {
        SmartWearLog.v { "-> $packet" }
        listener?.onPacketSent(packet.bytes)
        gatt.write(QRing.SERVICE, QRing.WRITE, packet.bytes, withResponse = true)
    }

    private fun onNotification(n: GattNotification) {
        listener?.onPacketReceived(n.value)
        when (n.characteristic) {
            QRing.NOTIFY -> {
                val p = Packet.parse(n.value)
                if (p == null) {
                    SmartWearLog.w("Bỏ gói 16 byte không hợp lệ (${n.value.size} byte)")
                    return
                }
                if (p.command == CMD_PACKAGE_LENGTH) bigDataChunkSize = maxOf(p.u8(0), 20)
                val collector = collectors[p.command]
                if (collector != null) {
                    collector.trySend(p)
                    return
                }
                val waiter = waiters[p.command]
                if (waiter != null && !waiter.isCompleted) waiter.complete(p) else _events.tryEmit(p)
            }
            QRing.BIG_DATA_NOTIFY -> synchronized(bigData) { bigData.feed(n.value) }
        }
    }

    private fun onBigDataFrame(frame: BigDataFrame) {
        SmartWearLog.d("Big-data <- 0x%02X (%d byte): %s".format(frame.command, frame.payload.size, frame.payload.take(80).toByteArray().toHex()))
        bigDataWaiters[frame.command]?.complete(frame)
            ?: SmartWearLog.d("Big-data 0x%02X không có ai chờ (%d byte)".format(frame.command, frame.payload.size))
    }

    /** Lệnh 0x04: báo hệ điều hành và model điện thoại (sdks/qring/docs/01-connection.md §4.2). */
    private fun phoneInfoPacket(): Packet {
        val sdk = android.os.Build.VERSION.SDK_INT
        val osCode = when (sdk) { 28 -> 0x09; 26, 27 -> 0x08; else -> 0x0A }
        val model = android.os.Build.MODEL.toByteArray(Charsets.UTF_8).take(12).toByteArray()
        return Packet.of(CMD_PHONE_INFO, byteArrayOf(0x02, osCode.toByte()) + model)
    }

    private fun bcd(v: Int): Int = ((v / 10) shl 4) or (v % 10)

    private fun languageCode(): Int = LANGUAGES[Locale.getDefault().language] ?: 1

    companion object {
        const val CMD_SET_TIME = 0x01
        const val CMD_BATTERY = 0x03
        const val CMD_PHONE_INFO = 0x04
        const val CMD_PACKAGE_LENGTH = 0x2F
        const val CMD_DEVICE_SUPPORT = 0x3C
        const val CMD_START_MEASURE = 0x69
        const val CMD_STOP_MEASURE = 0x6A

        /** Mã ngôn ngữ của lệnh SetTime (SetTimeReq.java:34-64). */
        private val LANGUAGES = mapOf(
            "zh" to 0, "en" to 1, "el" to 3, "fr" to 4, "de" to 5, "it" to 6, "es" to 7, "nl" to 8, "pt" to 9,
            "ru" to 10, "tr" to 11, "ja" to 12, "ko" to 13, "pl" to 14, "ro" to 15, "ar" to 16, "th" to 17,
            "vi" to 18, "in" to 19, "id" to 19, "hi" to 20, "cs" to 21, "sk" to 22, "hu" to 23, "iw" to 24,
            "he" to 24, "hr" to 25, "sl" to 26, "ur" to 35,
        )
    }
}
