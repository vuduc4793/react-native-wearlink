import SmartWearCore
import XCTest
@testable import SmartWearVeepoo

final class VeepooMeasureTests: XCTestCase {
    func testCommands() {
        XCTAssertEqual(T.pad([0xD0, 0x01]), VeepooMeasure.heartRateStart)
        XCTAssertEqual([0xD0, 0x00], VeepooMeasure.heartRateStop)
        XCTAssertEqual([0x80, 0x01, 0x02], VeepooMeasure.spo2Start)
        XCTAssertEqual([0x90, 0x01, 0x00], VeepooMeasure.bloodPressureStart)
        XCTAssertEqual(T.pad([0x87, 0x01, 0x01]), VeepooMeasure.temperatureStart)
        XCTAssertEqual(T.pad([0x89, 0x06, 0x02]), VeepooMeasure.stressStop)
        XCTAssertEqual(T.pad([0x89, 0x07, 0x01]), VeepooMeasure.hrvStart)
    }

    func testHeartRateNeedsSamples() {
        let parse = VeepooMeasure.heartRate(samples: 3)
        XCTAssertNil(parse(T.hex("80 01 02 03")))
        XCTAssertEqual(.measuring, parse(T.hex("D0 00 00 00 00 00"))?.0.status)
        for (i, bpm) in [70, 72, 74].enumerated() {
            let (r, done) = parse(T.pad([0xD0, UInt8(bpm)]))!
            XCTAssertEqual(Double(bpm), r.value)
            XCTAssertEqual(i == 2, done)
            XCTAssertEqual(i == 2 ? .ok : .measuring, r.status)
        }
    }

    func testHeartRateErrors() {
        XCTAssertEqual(.notWorn, VeepooMeasure.heartRate()(T.pad([0xD0, 0x01]))?.0.status)
        let (busy, done) = VeepooMeasure.heartRate()(T.hex("D0 48 00 00 00 04"))!
        XCTAssertEqual(.error, busy.status)
        XCTAssertEqual(4, busy.errorCode)
        XCTAssertTrue(done)
        // Trạng thái máy 2/3 không phải bận.
        XCTAssertEqual(.measuring, VeepooMeasure.heartRate()(T.hex("D0 48 00 00 00 03"))?.0.status)
    }

    func testSpo2() {
        let parse = VeepooMeasure.spo2(samples: 2)
        XCTAssertEqual(.measuring, parse(T.hex("80 01 04 61 01 32"))?.0.status)  // đang hiệu chuẩn
        XCTAssertEqual(.measuring, parse(T.hex("80 01 04 61 00 00"))?.0.status)
        let (r, done) = parse(T.hex("80 01 04 62 00 00"))!
        XCTAssertEqual(.ok, r.status)
        XCTAssertEqual(98, r.value)
        XCTAssertTrue(done)
        XCTAssertEqual(.notWorn, VeepooMeasure.spo2()(T.hex("80 01 0C 00"))?.0.status)
        XCTAssertEqual(.notWorn, VeepooMeasure.spo2()(T.hex("80 01 04 01"))?.0.status)
        XCTAssertEqual(10, VeepooMeasure.spo2()(T.hex("80 01 0A 00"))?.0.errorCode)
        // Máy báo xong (11) trước khi đủ mẫu: dùng giá trị cuối.
        let p2 = VeepooMeasure.spo2(samples: 5)
        _ = p2(T.hex("80 01 04 60 00"))
        XCTAssertEqual(96, p2(T.hex("80 01 0B 00 00"))?.0.value)
    }

    func testBloodPressure() {
        let parse = VeepooMeasure.bloodPressure()
        XCTAssertEqual(.measuring, parse(T.hex("90 00 00 32 00 01"))?.0.status)
        let (r, done) = parse(T.hex("90 78 50 64 00 01"))!
        XCTAssertEqual(.ok, r.status)
        XCTAssertEqual(120, r.systolic)
        XCTAssertEqual(80, r.diastolic)
        XCTAssertTrue(done)
        XCTAssertEqual(.notWorn, parse(T.hex("90 00 00 00 FC 00"))?.0.status)
        XCTAssertEqual(255, parse(T.hex("90 00 00 00 FF 00"))?.0.errorCode)
    }

    func testTemperature() {
        let parse = VeepooMeasure.temperature()
        XCTAssertEqual(.measuring, parse(T.hex("87 01 01 00 32 0000 0000"))?.0.status)
        let (r, done) = parse(T.hex("87 01 01 00 64 6D01 4001"))!
        XCTAssertEqual(36.5, r.value)
        XCTAssertTrue(done)
        XCTAssertEqual(.error, parse(T.hex("87 01 01 02 00 0000 0000"))?.0.status)
    }

    func testStressAndHrv() {
        let s = VeepooMeasure.stress()
        XCTAssertEqual(.measuring, s(T.hex("89 06 01 00 32 00"))?.0.status)
        XCTAssertEqual(42, s(T.hex("89 06 01 00 64 2A"))?.0.value)
        XCTAssertEqual(.notWorn, s(T.hex("89 06 01 04"))?.0.status)
        XCTAssertTrue(s(T.hex("89 06 02 00"))!.1)
        XCTAssertNil(s(T.hex("89 07 01 00 30")))
        let h = VeepooMeasure.hrv()
        XCTAssertEqual(48, h(T.hex("89 07 01 00 30"))?.0.value)
        XCTAssertEqual("ms", h(T.hex("89 07 01 00 30"))?.0.unit)
        XCTAssertEqual(2, h(T.hex("89 07 01 02 00"))?.0.errorCode)
        XCTAssertNil(h(T.hex("89 06 01 00 30")))
    }
}
