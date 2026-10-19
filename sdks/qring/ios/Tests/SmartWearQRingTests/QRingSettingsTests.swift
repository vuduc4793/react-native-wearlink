import SmartWearCore
import XCTest
@testable import SmartWearQRing

/// Cùng dữ liệu mẫu với `QRingSettingsTest` Android.
final class QRingSettingsTests: XCTestCase {
    private func payload(_ v: Int...) -> [Int] { (0..<14).map { $0 < v.count ? v[$0] : 0 } }
    private func caps(noScreen: Bool) -> QRingCapabilities {
        var t = [UInt8](repeating: 0, count: 14); t[3] = 0x02
        var s = [UInt8](repeating: 0, count: 14); if noScreen { s[1] = 0x40 }
        return QRingCapabilities(timeCaps: t, supportCaps: s)
    }

    func testParsesReads() {
        let hr = QRingSettings.parse(0x16, payload(1, 1, 10, 0, 40, 150, 1, 60))
        XCTAssertEqual(hr["hrAuto.enabled"], 1)
        XCTAssertEqual(hr["hrAuto.interval"], 10)
        XCTAssertEqual(hr["hrAuto.start"], 5)
        XCTAssertEqual(hr["hrAuto.high"], 150)
        let goals = QRingSettings.parse(0x21, payload(1, 0x40, 0x1F, 0, 0xE0, 0x93, 0x04, 0x88, 0x13, 0, 30, 0, 0xE0, 0x01))
        XCTAssertEqual(goals, ["goal.steps": 8000, "goal.calories": 300, "goal.distance": 5, "goal.exercise": 30, "goal.sleep": 480])
        let sit = QRingSettings.parse(0x26, payload(0x09, 0x30, 0x18, 0x00, 0x7F, 90))
        XCTAssertEqual(sit["sedentary.range.from"], 9 * 60 + 30)
        XCTAssertEqual(sit["sedentary.range.to"], 18 * 60)
        XCTAssertEqual(sit["sedentary.interval"], 90)
    }

    func testWritesPreserveReadBytes() {
        var v = QRingSettings.parse(0x16, payload(1, 1, 10, 5, 40, 150, 1))
        v = QRingSettings.apply(v, "hrAuto.enabled", .bool(false))
        XCTAssertEqual(QRingSettings.write("hrAuto.enabled", v), .of(0x16, 2, 2, 10, 5, 40, 150, 1))
        v = QRingSettings.apply(v, "goal.steps", .number(10_000))
        XCTAssertEqual(QRingSettings.write("goal.steps", v), .of(0x21, 2, 0x10, 0x27, 0, 0xE0, 0x93, 0x04, 0x88, 0x13, 0, 30, 0, 0xE0, 0x01))
        v = QRingSettings.apply(v, "sedentary.interval", .number(0))
        v = QRingSettings.apply(v, "sedentary.enabled", .bool(true))
        XCTAssertEqual(QRingSettings.write("sedentary.enabled", v), .of(0x25, 0x09, 0x00, 0x18, 0x00, 0x7F, 30))
        XCTAssertEqual(QRingSettings.write("find.start", v)?.description, "50 55 AA 00 00 00 00 00 00 00 00 00 00 00 00 4F")
    }

    func testRingHasNoScreenSettings() {
        let ring = QRingSettings.controls(caps(noScreen: true), [:], ring: true).map(\.id)
        XCTAssertTrue(ring.contains("find.start"))
        XCTAssertTrue(ring.contains("spo2Auto.enabled"))
        XCTAssertFalse(ring.contains("dnd.enabled"))
        XCTAssertFalse(ring.contains("display.raise"))
        let band = QRingSettings.controls(caps(noScreen: false), [:], ring: false).map(\.id)
        XCTAssertTrue(band.contains("dnd.enabled"))
        XCTAssertTrue(band.contains("sedentary.range"))
        XCTAssertEqual(QRingSettings.reads(caps(noScreen: false), ring: true).map(\.command), [0x16, 0x2C, 0x21, 0x0A])
    }
}
