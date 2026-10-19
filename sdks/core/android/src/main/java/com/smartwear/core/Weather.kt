package com.smartwear.core

/** Hiện tượng thời tiết chung; driver đổi sang mã riêng của thiết bị. */
enum class WeatherCondition {
    SUNNY, CLOUDY, OVERCAST, SHOWER, THUNDERSTORM, SLEET, LIGHT_RAIN, HEAVY_RAIN, SNOW, DUST, FOG, WIND;

    companion object {
        /** Mã WMO (Open-Meteo `weather_code`, https://open-meteo.com/en/docs). */
        fun fromWmo(code: Int): WeatherCondition = when (code) {
            0 -> SUNNY
            1, 2 -> CLOUDY
            3 -> OVERCAST
            45, 48 -> FOG
            51, 53, 55, 61, 63 -> LIGHT_RAIN
            56, 57, 66, 67 -> SLEET
            65, 82 -> HEAVY_RAIN
            71, 73, 75, 77, 85, 86 -> SNOW
            80, 81 -> SHOWER
            95, 96, 99 -> THUNDERSTORM
            else -> CLOUDY
        }
    }
}

data class WeatherDay(val condition: WeatherCondition, val highC: Int, val lowC: Int)

/** Dự báo gửi xuống thiết bị. [days] phần tử đầu là hôm nay (tối đa 7 ngày). */
data class WeatherForecast(
    val city: String,
    val currentC: Int,
    val humidity: Int,
    val uvIndex: Int,
    val days: List<WeatherDay>,
)

/** Thiết bị hiển thị được thời tiết. */
interface WeatherDisplay {
    val supportsWeather: Boolean
    suspend fun setWeather(forecast: WeatherForecast)
}

/** Bỏ dấu tiếng Việt (màn đồng hồ thường chỉ có ASCII / GB2312): "Hà Nội" → "Ha Noi". */
fun foldAccents(s: String): String =
    java.text.Normalizer.normalize(s.replace('đ', 'd').replace('Đ', 'D'), java.text.Normalizer.Form.NFD)
        .replace(Regex("\\p{M}+"), "")
