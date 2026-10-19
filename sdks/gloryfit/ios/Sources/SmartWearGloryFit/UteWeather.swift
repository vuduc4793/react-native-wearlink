import Foundation
import SmartWearCore

/// Thời tiết 7 ngày (bản Swift của `UteWeather.kt`; `SevenDayWeatherInfo` trong SDK Realtek của GloryFitPro):
/// - `CB 01 code 00 hiện tại cao thấp pm25(2) aqi(2) tên-thành-phố(8, GB2312)` [+ độ ẩm, UV nếu F6 `0x800`]
/// - `CB 02` (code 00 cao thấp) × ngày 2–5, `CB 03` × ngày 6–7; app gốc gửi gói sau khi đồng hồ trả lời gói trước.
/// Có F6 `0x800` (Y25/HT43) thì cả ba gói đi kênh 34F1, không thì 33F1. Nhiệt độ âm: `|t| | 0x80`.
public enum UteWeather {
    /// `isHasWeatherSeven` (F1 `0x2000`) hoặc F6 `0x80`.
    public static func supported(_ f: Ute.Features) -> Bool { f.has(1, 0x002000) || f.has(6, 0x000080) }
    public static func ble5(_ f: Ute.Features) -> Bool { f.has(6, 0x000800) }
    public static func code(_ d: WeatherDay) -> Int { d.condition.rawValue + 1 }
    public static func temp(_ t: Int) -> Int { t < 0 ? min(abs(t), 127) | 0x80 : min(t, 127) }

    public static func packets(_ f: Ute.Features, _ w: WeatherForecast) -> [[UInt8]] {
        precondition(!w.days.isEmpty, "Thiếu dự báo hôm nay")
        func day(_ i: Int) -> WeatherDay { i < w.days.count ? w.days[i] : w.days[w.days.count - 1] }
        func b(_ v: Int) -> UInt8 { UInt8(truncatingIfNeeded: v) }
        let today = day(0)
        let city = Array(foldAccents(w.city).unicodeScalars.filter { (0x20...0x7E).contains($0.value) }.prefix(8).map { UInt8($0.value) })
        var first: [UInt8] = [0xCB, 0x01, b(code(today)), 0, b(temp(w.currentC)), b(temp(today.highC)), b(temp(today.lowC)), 0, 0, 0, 0]
        first += city + [UInt8](repeating: 0, count: 8 - city.count)
        if ble5(f) { first += [b(max(0, min(100, w.humidity))), b(max(0, min(15, w.uvIndex)))] }
        func block(_ seq: UInt8, _ from: Int, _ count: Int) -> [UInt8] {
            [0xCB, seq] + (from..<from + count).flatMap { i -> [UInt8] in
                let d = day(i)
                return [b(code(d)), 0, b(temp(d.highC)), b(temp(d.lowC))]
            }
        }
        return [first, block(2, 1, 4), block(3, 5, 2)]
    }
}
