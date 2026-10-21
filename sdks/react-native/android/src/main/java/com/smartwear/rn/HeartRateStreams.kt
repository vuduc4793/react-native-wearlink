package com.smartwear.rn

import com.smartwear.core.ConnectionState
import com.smartwear.core.HeartRateSample
import com.smartwear.core.HeartRateStreaming
import com.smartwear.core.SmartWearLog
import com.smartwear.core.WearableDevice
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

/**
 * Luồng nhịp tim liên tục cho JS (`startHeartRateStream` / `stopHeartRateStream`, sự kiện `heartRate`). Giữ luồng như giữ kết
 * nối: mất kết nối thì báo một mẫu `connected: false` (app đánh dấu khoảng trống), nối lại thì tự mở lại; luồng lỗi thì báo
 * `error` rồi thử lại sau [RETRY_MS]. Gửi tối đa một mẫu mỗi [MIN_GAP_MS]; RR của các mẫu bị gộp vẫn được giữ.
 */
internal class HeartRateStreams(
    private val scope: CoroutineScope,
    private val event: (type: String, deviceId: String, body: Map<String, Any?>) -> Unit,
) {
    private val jobs = mutableMapOf<String, Job>()

    /** Thiết bị phải là [HeartRateStreaming]; chưa kết nối thì chờ (không biết trước được driver có đo được không). */
    fun start(d: WearableDevice) {
        val s = d as? HeartRateStreaming
        if (s == null || (d.state.value == ConnectionState.CONNECTED && !s.supportsHeartRateStream)) {
            throw InvokeException("unsupported", "Thiết bị không hỗ trợ nhịp tim liên tục")
        }
        jobs.remove(d.id)?.cancel()
        jobs[d.id] = scope.launch { run(d, s) }
    }

    fun stop(id: String) {
        jobs.remove(id)?.cancel()
    }

    fun isStreaming(id: String) = jobs[id]?.isActive == true

    private suspend fun run(d: WearableDevice, s: HeartRateStreaming) {
        while (true) {
            d.state.first { it == ConnectionState.CONNECTED }
            if (!s.supportsHeartRateStream) {
                publish(d.id, null, connected = true, error = "unsupported")
                return
            }
            var failure: Throwable? = null
            var lastEmit = 0L
            val rr = mutableListOf<Int>()
            coroutineScope {
                val stream = launch {
                    try {
                        s.heartRateStream().collect { x ->
                            rr += x.rrMs
                            if (x.bpm != null && x.timestamp - lastEmit < MIN_GAP_MS) return@collect
                            lastEmit = x.timestamp
                            publish(d.id, x.copy(rrMs = rr.toList()), connected = true)
                            rr.clear()
                        }
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Throwable) {
                        failure = e
                    }
                }
                val watcher = launch {
                    d.state.first { it != ConnectionState.CONNECTED }
                    stream.cancel()
                }
                stream.join()
                watcher.cancel()
            }
            when {
                d.state.value != ConnectionState.CONNECTED -> publish(d.id, null, connected = false)
                failure != null -> {
                    SmartWearLog.w("[${d.name}] luồng nhịp tim lỗi: ${failure?.message}")
                    publish(d.id, null, connected = true, error = failure?.message ?: "failed")
                    delay(RETRY_MS)
                }
                else -> delay(1_000)
            }
        }
    }

    private fun publish(id: String, x: HeartRateSample?, connected: Boolean, error: String? = null) {
        event(
            "heartRate", id,
            mapOf(
                "bpm" to x?.bpm, "rrMs" to (x?.rrMs ?: emptyList<Int>()), "contact" to x?.contact,
                "t" to (x?.timestamp ?: System.currentTimeMillis()), "connected" to connected, "error" to error,
            ),
        )
    }

    companion object {
        const val MIN_GAP_MS = 750L
        const val RETRY_MS = 3_000L
    }
}
