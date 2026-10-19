import SmartWearCore
import XCTest
@testable import SmartWearQRing

/// Dữ liệu thật đọc từ thiết bị ngày 2026-10-13 (sdks/qring/docs/devices.md). Port của QRingCapabilitiesTest.kt.
final class QRingCapabilitiesTests: XCTestCase {
    private func hex(_ s: String) -> [UInt8] { s.split(separator: " ").map { UInt8($0, radix: 16)! } }

    func testR09() {
        let caps = QRingCapabilities(
            timeCaps: hex("01 00 00 02 00 00 00 00 01 00 20 00 00 30"),
            supportCaps: hex("00 AC 27 00 00 00 00 00 00 00 00 00 00 00")
        )
        XCTAssertEqual(
            [.heartRate, .steps, .sleep, .spo2, .temperature, .stress, .hrv, .gesture] as Set<Capability>,
            caps.toCapabilities()
        )
        XCTAssertTrue(caps.newSleepProtocol)
        XCTAssertTrue(caps.blePair)
        XCTAssertFalse(caps.noScreen)
    }

    func testHS500A() {
        let caps = QRingCapabilities(
            timeCaps: hex("00 00 01 16 00 00 00 00 01 00 20 00 00 30"),
            supportCaps: hex("00 40 00 A0 00 00 08 30 00 00 00 00 00 00")
        )
        XCTAssertEqual(
            [.heartRate, .steps, .sleep, .spo2, .bloodPressure, .stress, .hrv, .menstruation] as Set<Capability>,
            caps.toCapabilities()
        )
        XCTAssertTrue(caps.noScreen)
        XCTAssertFalse(caps.temperature)
    }

    func testMeasurementTypeMapping() {
        XCTAssertEqual(MeasurementType.temperature, Capability.temperature.measurementType)
        XCTAssertNil(Capability.steps.measurementType)
        XCTAssertEqual(11, MeasurementType.temperature.code)
        XCTAssertEqual(MeasurementType.hrv, MeasurementType.fromCode(10))
    }
}
