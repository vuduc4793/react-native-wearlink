import Foundation

/// Hiện tượng thời tiết chung (bản Swift của `Weather.kt`); driver đổi sang mã riêng của thiết bị.
public enum WeatherCondition: Int, CaseIterable, Sendable {
    case sunny, cloudy, overcast, shower, thunderstorm, sleet, lightRain, heavyRain, snow, dust, fog, wind

    /// Mã WMO (Open-Meteo `weather_code`, https://open-meteo.com/en/docs).
    public static func fromWmo(_ code: Int) -> WeatherCondition {
        switch code {
        case 0: .sunny
        case 1, 2: .cloudy
        case 3: .overcast
        case 45, 48: .fog
        case 51, 53, 55, 61, 63: .lightRain
        case 56, 57, 66, 67: .sleet
        case 65, 82: .heavyRain
        case 71, 73, 75, 77, 85, 86: .snow
        case 80, 81: .shower
        case 95, 96, 99: .thunderstorm
        default: .cloudy
        }
    }
}

public struct WeatherDay: Equatable, Sendable {
    public var condition: WeatherCondition
    public var highC: Int
    public var lowC: Int
    public init(condition: WeatherCondition, highC: Int, lowC: Int) {
        self.condition = condition
        self.highC = highC
        self.lowC = lowC
    }
}

/// Dự báo gửi xuống thiết bị. `days` phần tử đầu là hôm nay (tối đa 7 ngày).
public struct WeatherForecast: Equatable, Sendable {
    public var city: String
    public var currentC: Int
    public var humidity: Int
    public var uvIndex: Int
    public var days: [WeatherDay]
    public init(city: String, currentC: Int, humidity: Int, uvIndex: Int, days: [WeatherDay]) {
        self.city = city
        self.currentC = currentC
        self.humidity = humidity
        self.uvIndex = uvIndex
        self.days = days
    }
}

/// Thiết bị hiển thị được thời tiết.
@MainActor
public protocol WeatherDisplay: AnyObject {
    var supportsWeather: Bool { get }
    func setWeather(_ forecast: WeatherForecast) async throws
}

/// Bỏ dấu tiếng Việt (màn đồng hồ thường chỉ có ASCII / GB2312): "Hà Nội" → "Ha Noi".
public func foldAccents(_ s: String) -> String {
    s.replacingOccurrences(of: "đ", with: "d").replacingOccurrences(of: "Đ", with: "D")
        .folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
}
