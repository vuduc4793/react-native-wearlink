import SmartWearCore
import XCTest
@testable import SmartWearGloryFit

/// Cùng dữ liệu mẫu với `UteWeatherTest` Android.
final class UteWeatherTests: XCTestCase {
    private func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }
    private func bytes(_ s: String) -> [UInt8] { s.split(separator: " ").map { UInt8($0, radix: 16)! } }

    private var ht43: Ute.Features { .parse(main: bytes("08 88 6C 2A 01 24 39 43 75 6E DF FE D9 21 00 5D 78 4B A1 DC"), ble5: nil) }
    private let forecast = WeatherForecast(
        city: "Hà Nội", currentC: 27, humidity: 82, uvIndex: 3,
        days: [
            WeatherDay(condition: .sunny, highC: 31, lowC: 25), WeatherDay(condition: .cloudy, highC: 31, lowC: 24),
            WeatherDay(condition: .lightRain, highC: 32, lowC: 24), WeatherDay(condition: .thunderstorm, highC: 30, lowC: 23),
            WeatherDay(condition: .snow, highC: 1, lowC: -3),
        ]
    )

    func testSevenDayPackets() {
        XCTAssertTrue(UteWeather.supported(ht43))
        XCTAssertTrue(UteWeather.ble5(ht43))
        XCTAssertEqual(UteWeather.packets(ht43, forecast).map(hex), [
            "CB 01 01 00 1B 1F 19 00 00 00 00 48 61 20 4E 6F 69 00 00 52 03",
            "CB 02 02 00 1F 18 07 00 20 18 05 00 1E 17 09 00 01 83",
            "CB 03 09 00 01 83 09 00 01 83",
        ])
    }

    func testWithoutHumidityUv() {
        let f = Ute.Features(groups: [1: 0x002000])
        XCTAssertFalse(UteWeather.ble5(f))
        XCTAssertEqual(UteWeather.packets(f, forecast)[0].count, 19)
        XCTAssertFalse(UteWeather.supported(Ute.Features()))
    }

    func testWmoCodes() {
        XCTAssertEqual(WeatherCondition.fromWmo(0), .sunny)
        XCTAssertEqual(WeatherCondition.fromWmo(45), .fog)
        XCTAssertEqual(WeatherCondition.fromWmo(82), .heavyRain)
        XCTAssertEqual(WeatherCondition.fromWmo(95), .thunderstorm)
        XCTAssertEqual(foldAccents("Thành phố Hà Nội Đông"), "Thanh pho Ha Noi Dong")
    }
}
