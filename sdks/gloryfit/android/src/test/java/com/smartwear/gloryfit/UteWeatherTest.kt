package com.smartwear.gloryfit

import com.smartwear.core.WeatherCondition
import com.smartwear.core.WeatherCondition.CLOUDY
import com.smartwear.core.WeatherCondition.LIGHT_RAIN
import com.smartwear.core.WeatherCondition.SNOW
import com.smartwear.core.WeatherCondition.SUNNY
import com.smartwear.core.WeatherCondition.THUNDERSTORM
import com.smartwear.core.WeatherDay
import com.smartwear.core.WeatherForecast
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Cùng dữ liệu mẫu với `UteWeatherTests` iOS. */
class UteWeatherTest {
    private fun hexOf(b: ByteArray) = b.joinToString(" ") { "%02X".format(it) }

    /** Bảng 33F1 thật của HT43 (F1 `0x2000` thời tiết 7 ngày, F6 `0x800` độ ẩm/UV). */
    private val ht43 = Ute.Features.parse(
        "08 88 6C 2A 01 24 39 43 75 6E DF FE D9 21 00 5D 78 4B A1 DC".split(" ").map { it.toInt(16).toByte() }.toByteArray(), null,
    )
    private val forecast = WeatherForecast(
        city = "Hà Nội", currentC = 27, humidity = 82, uvIndex = 3,
        days = listOf(
            WeatherDay(SUNNY, 31, 25), WeatherDay(CLOUDY, 31, 24), WeatherDay(LIGHT_RAIN, 32, 24),
            WeatherDay(THUNDERSTORM, 30, 23), WeatherDay(SNOW, 1, -3),
        ),
    )

    @Test fun sevenDayPackets() {
        assertTrue(UteWeather.supported(ht43))
        assertTrue(UteWeather.ble5(ht43))
        val p = UteWeather.packets(ht43, forecast).map(::hexOf)
        assertEquals(
            listOf(
                "CB 01 01 00 1B 1F 19 00 00 00 00 48 61 20 4E 6F 69 00 00 52 03",
                "CB 02 02 00 1F 18 07 00 20 18 05 00 1E 17 09 00 01 83",
                "CB 03 09 00 01 83 09 00 01 83",
            ),
            p,
        )
    }

    @Test fun withoutHumidityUv() {
        val f = Ute.Features(mapOf(1 to 0x002000), null)
        assertFalse(UteWeather.ble5(f))
        assertEquals(19, UteWeather.packets(f, forecast)[0].size)
        assertFalse(UteWeather.supported(Ute.Features(emptyMap(), null)))
    }

    @Test fun wmoCodes() {
        assertEquals(SUNNY, WeatherCondition.fromWmo(0))
        assertEquals(WeatherCondition.FOG, WeatherCondition.fromWmo(45))
        assertEquals(WeatherCondition.HEAVY_RAIN, WeatherCondition.fromWmo(82))
        assertEquals(THUNDERSTORM, WeatherCondition.fromWmo(95))
    }
}
