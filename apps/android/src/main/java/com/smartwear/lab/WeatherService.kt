package com.smartwear.lab

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.location.Geocoder
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Looper
import com.smartwear.core.ConnectionState
import com.smartwear.core.DeviceManager
import com.smartwear.core.SmartWearLog
import com.smartwear.core.WearableDevice
import com.smartwear.core.WeatherCondition
import com.smartwear.core.WeatherDay
import com.smartwear.core.WeatherDisplay
import com.smartwear.core.WeatherForecast
import com.smartwear.core.foldAccents
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.Locale
import kotlin.coroutines.resume
import kotlin.math.roundToInt

/**
 * Lấy dự báo 7 ngày cho vị trí gần đúng và gửi lên thiết bị hiển thị được thời tiết ([WeatherDisplay]); bản Android của
 * `WeatherService.swift`. Nguồn Open-Meteo (miễn phí, không khoá), toạ độ làm tròn 2 chữ số (~1 km).
 * Tự gửi khi thiết bị kết nối (dự báo dùng lại trong 1 giờ).
 */
class WeatherService(private val context: Context, private val manager: DeviceManager, private val scope: CoroutineScope) {
    private val _status = MutableStateFlow<Map<String, String>>(emptyMap())
    /** Trạng thái gửi theo id thiết bị. */
    val status: StateFlow<Map<String, String>> = _status.asStateFlow()
    private var cached: WeatherForecast? = null
    private var fetchedAt = 0L
    private val watched = mutableSetOf<String>()

    fun start() {
        scope.launch {
            manager.devices.collect { list ->
                for (d in list) {
                    if (d !is WeatherDisplay || !watched.add(d.id)) continue
                    scope.launch {
                        d.state.collect { if (it == ConnectionState.CONNECTED && (d as WeatherDisplay).supportsWeather) { delay(5_000); push(d, refresh = false) } }
                    }
                }
            }
        }
    }

    fun hasPermission() = context.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED

    suspend fun push(device: WearableDevice, refresh: Boolean) {
        val w = device as? WeatherDisplay ?: return
        val text = runCatching {
            val f = current(refresh)
            w.setWeather(f)
            "Đã gửi ${if (f.city.isEmpty()) "" else f.city + ", "}${f.currentC}°C lúc %tR".format(System.currentTimeMillis())
        }.getOrElse { "Lỗi: ${it.message}" }
        SmartWearLog.i("[${device.name}] thời tiết: $text")
        _status.value = _status.value + (device.id to text)
    }

    private suspend fun current(refresh: Boolean): WeatherForecast {
        cached?.takeIf { !refresh && System.currentTimeMillis() - fetchedAt < 3_600_000 }?.let { return it }
        if (!hasPermission()) throw IllegalStateException("Chưa cho phép vị trí")
        val loc = location() ?: throw IllegalStateException("Chưa lấy được vị trí")
        val lat = (loc.latitude * 100).roundToInt() / 100.0
        val lon = (loc.longitude * 100).roundToInt() / 100.0
        val f = withContext(Dispatchers.IO) { fetch(lat, lon).copy(city = city(loc)) }
        cached = f
        fetchedAt = System.currentTimeMillis()
        return f
    }

    @SuppressLint("MissingPermission")
    private suspend fun location(): Location? {
        val lm = context.getSystemService(LocationManager::class.java)
        val providers = listOf(LocationManager.NETWORK_PROVIDER, LocationManager.GPS_PROVIDER, LocationManager.PASSIVE_PROVIDER)
        providers.mapNotNull { runCatching { lm.getLastKnownLocation(it) }.getOrNull() }
            .maxByOrNull { it.time }?.takeIf { System.currentTimeMillis() - it.time < 30 * 60_000 }?.let { return it }
        val provider = providers.firstOrNull { runCatching { lm.isProviderEnabled(it) }.getOrDefault(false) } ?: return null
        return withTimeoutOrNull(20_000) {
            suspendCancellableCoroutine { cont ->
                val listener = object : LocationListener {
                    override fun onLocationChanged(l: Location) {
                        lm.removeUpdates(this)
                        if (cont.isActive) cont.resume(l)
                    }
                }
                lm.requestLocationUpdates(provider, 0L, 0f, listener, Looper.getMainLooper())
                cont.invokeOnCancellation { lm.removeUpdates(listener) }
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun city(loc: Location): String = runCatching {
        val a = Geocoder(context, Locale("vi", "VN")).getFromLocation(loc.latitude, loc.longitude, 1)?.firstOrNull()
        shortCity(a?.adminArea ?: a?.locality ?: "")
    }.getOrDefault("")

    companion object {
        /** Đồng hồ hiện tối đa 8 ký tự: dùng tỉnh/thành phố, bỏ dấu và tiền tố ("Thành phố Hà Nội" → "Ha Noi"). */
        fun shortCity(name: String): String {
            var s = foldAccents(name).trim()
            for (p in listOf("Thanh pho ", "Thanh Pho ", "Tinh ", "TP. ", "TP ")) if (s.startsWith(p)) s = s.removePrefix(p)
            return mapOf("Ho Chi Minh" to "HCM", "Ba Ria - Vung Tau" to "Vung Tau", "Thua Thien Hue" to "Hue")[s] ?: s
        }

        fun fetch(lat: Double, lon: Double): WeatherForecast {
            val url = URL(
                "https://api.open-meteo.com/v1/forecast?latitude=$lat&longitude=$lon" +
                    "&current=temperature_2m,relative_humidity_2m,weather_code,uv_index" +
                    "&daily=weather_code,temperature_2m_max,temperature_2m_min&timezone=auto&forecast_days=7",
            )
            val conn = url.openConnection() as HttpURLConnection
            conn.connectTimeout = 10_000
            conn.readTimeout = 10_000
            val body = try {
                if (conn.responseCode != 200) throw IllegalStateException("Open-Meteo trả mã ${conn.responseCode}")
                conn.inputStream.bufferedReader().readText()
            } finally {
                conn.disconnect()
            }
            return parse(body)
        }

        fun parse(json: String): WeatherForecast {
            val o = JSONObject(json)
            val cur = o.getJSONObject("current")
            val d = o.getJSONObject("daily")
            val codes = d.getJSONArray("weather_code")
            val hi = d.getJSONArray("temperature_2m_max")
            val lo = d.getJSONArray("temperature_2m_min")
            val days = (0 until minOf(codes.length(), hi.length(), lo.length())).map {
                WeatherDay(WeatherCondition.fromWmo(codes.getInt(it)), hi.getDouble(it).roundToInt(), lo.getDouble(it).roundToInt())
            }.toMutableList()
            // Hôm nay dùng hiện tượng hiện tại (khớp nhiệt độ hiện tại đang hiển thị).
            if (days.isNotEmpty()) days[0] = days[0].copy(condition = WeatherCondition.fromWmo(cur.getInt("weather_code")))
            return WeatherForecast(
                city = "", currentC = cur.getDouble("temperature_2m").roundToInt(),
                humidity = cur.getDouble("relative_humidity_2m").roundToInt(),
                uvIndex = cur.optDouble("uv_index", 0.0).roundToInt(), days = days,
            )
        }
    }
}
