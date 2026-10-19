import SmartWearCore
import XCTest
@testable import SmartWearQRing

/// Gói 0x69 thật từ R09 (sdks/qring/docs/devices.md, 2026-10-13).
final class MeasurementTests: XCTestCase {
    private func packet(_ s: String) -> Packet {
        var b = s.split(separator: " ").map { UInt8($0, radix: 16)! }
        b += [UInt8](repeating: 0, count: 15 - b.count)
        b.append(Packet.checksum(b + [0]))
        return Packet.parse(b)!
    }

    func testHeartRateValue() {
        let r = MeasurementReading.parse(.heartRate, packet("69 01 00 4F 00 00 FA 02"))
        XCTAssertEqual(.ok, r.status)
        XCTAssertEqual(79, r.value)
        XCTAssertEqual(0x02FA, r.rawSignal)
        XCTAssertEqual(.ok, r.reading.status)
        XCTAssertEqual(.heartRate, r.reading.capability)
    }

    func testHeartRateStillMeasuringCarriesRawSignal() {
        let r = MeasurementReading.parse(.heartRate, packet("69 01 00 00 00 00 89 02"))
        XCTAssertEqual(.measuring, r.status)
        XCTAssertNil(r.value)
        XCTAssertEqual(0x0289, r.rawSignal)
    }

    func testSpo2AndTemperature() {
        XCTAssertEqual(99, MeasurementReading.parse(.spo2, packet("69 03 00 63 01")).value)
        let t = MeasurementReading.parse(.temperature, packet("69 0B 00 A6 00 00 B3 02"))
        XCTAssertEqual(.ok, t.status)
        XCTAssertEqual(36.6, t.value!, accuracy: 0.0001)
    }

    func testNotWorn() {
        let r = MeasurementReading.parse(.heartRate, packet("69 01 01 00"))
        XCTAssertEqual(.notWorn, r.status)
        XCTAssertNil(r.value)
        XCTAssertEqual(.notWorn, r.reading.status)
    }

    func testErrorFlagAndOtherErrorCodes() {
        XCTAssertEqual(.error, MeasurementReading.parse(.heartRate, packet("E9 01")).status)
        XCTAssertEqual(.error, MeasurementReading.parse(.heartRate, packet("69 01 05 00")).status)
        XCTAssertEqual(.measuring, MeasurementReading.parse(.heartRate, packet("69 01 02 00")).status)
    }

    func testBloodPressure() {
        let r = MeasurementReading.parse(.bloodPressure, packet("69 02 00 00 76 4C"))
        XCTAssertEqual(.ok, r.status)
        XCTAssertNil(r.value)
        XCTAssertEqual(118, r.systolic)
        XCTAssertEqual(76, r.diastolic)
        XCTAssertTrue(r.reading.hasValue)
    }
}
