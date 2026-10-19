import CoreLocation
import SmartWearCore
import SwiftUI

/// Lấy dự báo 7 ngày cho vị trí gần đúng của iPhone và gửi lên các thiết bị hiển thị được thời tiết (`WeatherDisplay`).
/// Nguồn: Open-Meteo (miễn phí, không cần khoá). Toạ độ làm tròn 2 chữ số (~1 km) trước khi gửi đi.
/// Tự gửi khi thiết bị kết nối (dự báo dùng lại trong 1 giờ) và khi bấm "Cập nhật thời tiết".
@MainActor
@Observable
final class WeatherService: NSObject, CLLocationManagerDelegate {
    private(set) var forecast: WeatherForecast?
    private(set) var fetchedAt: Date?
    /// Trạng thái gửi theo thiết bị, vd "Đã gửi 19:52".
    private(set) var status: [UUID: String] = [:]
    var lastError: String?

    @ObservationIgnored private let location = CLLocationManager()
    @ObservationIgnored private var locationWaiters: [CheckedContinuation<CLLocation, Error>] = []

    override init() {
        super.init()
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    /// Gọi khi thiết bị kết nối: gửi dự báo (lấy mới nếu cũ hơn 1 giờ).
    func onConnected(_ device: WearableDevice) {
        guard let w = device as? WeatherDisplay, w.supportsWeather else { return }
        Task { await push(to: device, refresh: false) }
    }

    func push(to device: WearableDevice, refresh: Bool) async {
        guard let w = device as? WeatherDisplay else { return }
        do {
            let f = try await current(refresh: refresh)
            try await w.setWeather(f)
            status[device.id] = "Đã gửi \(f.city.isEmpty ? "" : f.city + ", ")\(f.currentC)°C lúc \(Date().formatted(date: .omitted, time: .shortened))"
            lastError = nil
        } catch {
            status[device.id] = "Lỗi: \(error.localizedDescription)"
            lastError = error.localizedDescription
        }
    }

    func current(refresh: Bool) async throws -> WeatherForecast {
        if !refresh, let forecast, let fetchedAt, Date().timeIntervalSince(fetchedAt) < 3600 { return forecast }
        let loc = try await currentLocation()
        let lat = (loc.coordinate.latitude * 100).rounded() / 100
        let lon = (loc.coordinate.longitude * 100).rounded() / 100
        async let city = cityName(loc)
        var f = try await Self.fetch(latitude: lat, longitude: lon)
        f.city = await city
        forecast = f
        fetchedAt = Date()
        return f
    }

    private func cityName(_ loc: CLLocation) async -> String {
        let marks = try? await CLGeocoder().reverseGeocodeLocation(loc, preferredLocale: Locale(identifier: "vi_VN"))
        guard let p = marks?.first else { return "" }
        return Self.shortCity(p.administrativeArea ?? p.locality ?? "")
    }

    /// Đồng hồ hiện tối đa 8 ký tự: dùng tỉnh/thành phố, bỏ dấu và tiền tố ("Thành phố Hà Nội" → "Ha Noi").
    nonisolated static func shortCity(_ name: String) -> String {
        var s = foldAccents(name).trimmingCharacters(in: .whitespaces)
        for prefix in ["Thanh pho ", "Thanh Pho ", "Tinh ", "TP. ", "TP "] where s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        let known = ["Ho Chi Minh": "HCM", "Ba Ria - Vung Tau": "Vung Tau", "Thua Thien Hue": "Hue"]
        return known[s] ?? s
    }

    // MARK: Open-Meteo

    private struct Response: Decodable {
        struct Current: Decodable {
            let temperature_2m: Double
            let relative_humidity_2m: Double
            let weather_code: Int
            let uv_index: Double?
        }
        struct Daily: Decodable {
            let weather_code: [Int]
            let temperature_2m_max: [Double]
            let temperature_2m_min: [Double]
        }
        let current: Current
        let daily: Daily
    }

    static func fetch(latitude: Double, longitude: Double) async throws -> WeatherForecast {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,relative_humidity_2m,weather_code,uv_index"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "7"),
        ]
        let (data, rsp) = try await URLSession.shared.data(from: c.url!)
        guard (rsp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return parse(try JSONDecoder().decode(Response.self, from: data))
    }

    private static func parse(_ r: Response) -> WeatherForecast {
        let d = r.daily
        let n = min(d.weather_code.count, d.temperature_2m_max.count, d.temperature_2m_min.count)
        var days = (0..<n).map {
            WeatherDay(condition: .fromWmo(d.weather_code[$0]), highC: Int(d.temperature_2m_max[$0].rounded()), lowC: Int(d.temperature_2m_min[$0].rounded()))
        }
        // Hôm nay dùng hiện tượng hiện tại (khớp với nhiệt độ hiện tại đang hiển thị).
        if !days.isEmpty { days[0].condition = .fromWmo(r.current.weather_code) }
        return WeatherForecast(
            city: "", currentC: Int(r.current.temperature_2m.rounded()), humidity: Int(r.current.relative_humidity_2m.rounded()),
            uvIndex: Int((r.current.uv_index ?? 0).rounded()), days: days
        )
    }

    // MARK: Vị trí

    private func currentLocation() async throws -> CLLocation {
        if let l = location.location, Date().timeIntervalSince(l.timestamp) < 1800 { return l }
        switch location.authorizationStatus {
        case .denied, .restricted: throw WeatherError("Chưa cho phép vị trí: Cài đặt → SmartWear Lab → Vị trí")
        default: break
        }
        return try await withCheckedThrowingContinuation { cont in
            locationWaiters.append(cont)
            if location.authorizationStatus == .notDetermined {
                location.requestWhenInUseAuthorization()
            } else {
                location.requestLocation()
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways: if !self.locationWaiters.isEmpty { manager.requestLocation() }
            case .denied, .restricted: self.finish(.failure(WeatherError("Chưa cho phép vị trí: Cài đặt → SmartWear Lab → Vị trí")))
            default: break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last else { return }
        Task { @MainActor in self.finish(.success(l)) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(.failure(error)) }
    }

    private func finish(_ r: Result<CLLocation, Error>) {
        let waiters = locationWaiters
        locationWaiters = []
        for w in waiters { w.resume(with: r) }
    }
}

struct WeatherError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
