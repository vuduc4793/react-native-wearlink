package com.smartwear.gloryfit

import com.smartwear.core.WeatherDay
import com.smartwear.core.WeatherForecast
import com.smartwear.core.foldAccents
import kotlin.math.abs

/**
 * Thời tiết 7 ngày (`SevenDayWeatherInfo` trong SDK Realtek của GloryFitPro, `uterkif.uterkthis`):
 * - `CB 01 code 00 hiện tại cao thấp pm25(2) aqi(2) tên-thành-phố(8, GB2312)` [+ độ ẩm, UV nếu F6 `0x800`]
 * - `CB 02` (code 00 cao thấp) × ngày 2–5, `CB 03` × ngày 6–7; app gốc gửi gói sau khi đồng hồ trả lời gói trước.
 * Có F6 `0x800` (`isHasWeatherHumidityUV`, Y25/HT43) thì cả ba gói đi kênh 34F1, không thì 33F1.
 * Nhiệt độ âm: `|t| or 0x80`. Mã: 1 nắng, 2 có mây, 3 âm u, 4 mưa rào, 5 dông, 6 mưa tuyết, 7 mưa nhỏ, 8 mưa to,
 * 9 tuyết, 10 bụi, 11 sương mù, 12 gió (`WeatherUtil.changeWeatherCodeRk`).
 */
object UteWeather {
    /** `isHasWeatherSeven` (F1 `0x2000`) hoặc F6 `0x80`. */
    fun supported(f: Ute.Features) = f.has(1, 0x002000) || f.has(6, 0x000080)

    fun ble5(f: Ute.Features) = f.has(6, 0x000800)

    fun code(d: WeatherDay) = d.condition.ordinal + 1

    fun temp(t: Int) = if (t < 0) abs(t).coerceAtMost(127) or 0x80 else t.coerceAtMost(127)

    fun packets(f: Ute.Features, w: WeatherForecast): List<ByteArray> {
        require(w.days.isNotEmpty()) { "Thiếu dự báo hôm nay" }
        fun day(i: Int) = w.days.getOrElse(i) { w.days.last() }
        fun b(v: Int) = v.toByte()
        val today = day(0)
        val city = foldAccents(w.city).filter { it.code in 0x20..0x7E }.take(8).toByteArray(Charsets.US_ASCII)
        val first = byteArrayOf(0xCB.toByte(), 0x01, b(code(today)), 0, b(temp(w.currentC)), b(temp(today.highC)), b(temp(today.lowC)), 0, 0, 0, 0) +
            city + ByteArray(8 - city.size) +
            (if (ble5(f)) byteArrayOf(b(w.humidity.coerceIn(0, 100)), b(w.uvIndex.coerceIn(0, 15))) else ByteArray(0))
        fun block(seq: Int, from: Int, count: Int) = byteArrayOf(0xCB.toByte(), b(seq)) +
            (from until from + count).flatMap { i -> day(i).let { listOf(b(code(it)), 0, b(temp(it.highC)), b(temp(it.lowC))) } }
        return listOf(first, block(2, 1, 4), block(3, 5, 2))
    }
}
