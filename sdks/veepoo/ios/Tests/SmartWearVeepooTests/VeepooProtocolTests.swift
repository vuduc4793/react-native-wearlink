import CoreBluetooth
import SmartWearCore
import SmartWearGloryFit
import SmartWearQRing
import SmartWearStandard
import XCTest
@testable import SmartWearVeepoo

/// Nhận diện, bắt tay `A1`, pin `A0`, giờ `A5`, CRC (vector dùng chung với `VeepooTest.kt` Android khi có).
final class VeepooProtocolTests: XCTestCase {
    /// GE54 đo thật 19/10/2026: `F8 F8` + payload.
    static let ge54Payload = T.hex("451DE38FF49CA10095 01005C1753FF2F003010")

    private let registry = DeviceRegistry(drivers: [QRingDriver(), GloryFitDriver(), VeepooDriver(), StandardDriver()])

    func testGe54Advert() {
        let a = Veepoo.parseAdvert(company: 0xF8F8, Self.ge54Payload)
        XCTAssertEqual("9C:F4:8F:E3:1D:45", a.mac)
        XCTAssertEqual(161, a.advertNumber)
        XCTAssertEqual(5980, a.deviceNumber)  // = BE16 `17 5C` trong A1 (Android đo thật)
        XCTAssertEqual("95.01", a.firmware)
    }

    func testAltCompanyMacOffset() {
        let a = Veepoo.parseAdvert(company: Veepoo.companyVeepooAlt, T.hex("0000 0000 112233445566"))
        XCTAssertEqual("66:55:44:33:22:11", a.mac)
        XCTAssertNil(a.advertNumber)
        XCTAssertNil(a.deviceNumber)
    }

    func testCleanName() {
        XCTAssertEqual("GE54", Veepoo.cleanName("GE54\u{FFFD}\u{01}"))
        XCTAssertEqual("GE54", Veepoo.cleanName(" GE54 "))
        XCTAssertEqual("", Veepoo.cleanName(nil))
    }

    func testGe54MatchedByManufacturerData() {
        let d = ScannedDevice(id: UUID(), name: "GE54\u{FFFD}", rssi: -46, serviceUuids: [CBUUID(string: "FEE7")],
                              manufacturerData: [0xF8F8: Data(Self.ge54Payload)])
        let m = VeepooDriver().match(d)
        XCTAssertEqual("GE54", m?.model)
        XCTAssertEqual(.band, m?.kind)
        XCTAssertEqual("9C:F4:8F:E3:1D:45", m?.mac)
        XCTAssertEqual("veepoo", registry.classify(d)?.driver.id)
    }

    func testNoNameOrNullIsIgnored() {
        for name in [nil, "", "NULL"] {
            let d = ScannedDevice(id: UUID(), name: name, rssi: -50, manufacturerData: [0xF8F8: Data(Self.ge54Payload)])
            XCTAssertNil(VeepooDriver().match(d), name ?? "nil")
        }
    }

    func testDoesNotStealOtherDevices() {
        // R09 (QRing) phát FEE7 như GE54; dây đo nhịp tim phát 180D: không phải Veepoo.
        let r09 = ScannedDevice(id: UUID(), name: "R09_8404", rssi: -52, serviceUuids: [CBUUID(string: "FEE7")])
        XCTAssertNil(VeepooDriver().match(r09))
        XCTAssertEqual("qring", registry.classify(r09)?.driver.id)
        let strap = ScannedDevice(id: UUID(), name: "Polar H10", rssi: -60, serviceUuids: [CBUUID(string: "180D")])
        XCTAssertNil(VeepooDriver().match(strap))
        XCTAssertEqual("standard", registry.classify(strap)?.driver.id)
        let y25 = ScannedDevice(id: UUID(), name: "Y25_6E1B", rssi: -55)
        XCTAssertEqual("gloryfit", registry.classify(y25)?.driver.id)
        // Manufacturer data công ty khác.
        let other = ScannedDevice(id: UUID(), name: "GE54", rssi: -50, manufacturerData: [0x1234: Data(Self.ge54Payload)])
        XCTAssertNil(VeepooDriver().match(other))
    }

    func testSystemConnectedGe54() {
        // iOS đang giữ kết nối (đã bond ANCS): không có quảng bá, nhận theo tên model / service Veepoo.
        let byName = ScannedDevice(id: UUID(), name: "GE54", rssi: 0, systemConnected: true)
        XCTAssertEqual("veepoo", registry.classify(byName)?.driver.id)
        let byService = ScannedDevice(id: UUID(), name: "X", rssi: 0, serviceUuids: [Veepoo.service], systemConnected: true)
        XCTAssertNotNil(VeepooDriver().match(byService))
        let notHeld = ScannedDevice(id: UUID(), name: "GE54", rssi: -50)
        XCTAssertNil(VeepooDriver().match(notHeld))
    }

    func testSystemServices() {
        XCTAssertEqual([Veepoo.waveService, Veepoo.service], VeepooDriver().systemServices)
        XCTAssertEqual("F0020001-0451-4000-B000-000000000000", Veepoo.waveService.uuidString)
    }

    /// Ví dụ trong 01-protocol §4.2: 2026-10-19 14:05:30 GMT+7, "0000", 12h.
    func testPasswordCheckDocExample() throws {
        let p = try Veepoo.passwordCheck(now: T.date(2026, 10, 19, 14, 5, 30), is24h: false, timeZone: T.tz, calendar: T.calendar)
        XCTAssertEqual(T.hex("A1 0000 00 07EA 0A 13 0E 05 1E 00 01 1C 00 0000000000"), p)
    }

    func testPasswordCheckIosPairingAndPassword() throws {
        let p = try Veepoo.passwordCheck(password: "1234", now: T.date(2026, 1, 2, 3, 4, 5), is24h: true, timeZone: T.tz,
                                         calendar: T.calendar, requestPairing: true, confirmOnDevice: true)
        XCTAssertEqual(T.hex("A1 D204 00 07EA 01 02 03 04 05 01 00 1C 01 0000000000"), p)
        // Múi giờ âm (GMT−3:30 = −14 × 15 phút).
        let west = TimeZone(secondsFromGMT: -(3 * 3600 + 1800))!
        let q = try Veepoo.passwordCheck(now: T.date(2026, 1, 2), is24h: true, timeZone: west, calendar: T.calendar)
        XCTAssertEqual(0xF2, q[13])
        XCTAssertThrowsError(try Veepoo.passwordCheck(password: "12345", now: Date(), is24h: true))
        XCTAssertThrowsError(try Veepoo.passwordCheck(password: "ab", now: Date(), is24h: true))
    }

    func testPasswordReply() throws {
        let r = try XCTUnwrap(Veepoo.parsePasswordReply(T.hex("A1 0000 01 175C 00 95 01 00 00 02 451DE38FF49C 01 02")))
        XCTAssertEqual(.checkSuccess, r.status)
        XCTAssertEqual(5980, r.deviceNumber)
        XCTAssertEqual("00.95.01", r.firmware)
        XCTAssertEqual("00.95.01.00", r.testVersion)
        XCTAssertEqual(2, r.nightWrist)
        XCTAssertEqual("9C:F4:8F:E3:1D:45", r.mac)
        XCTAssertEqual(1, r.findPhone)
        XCTAssertEqual(2, r.wearDetect)
        XCTAssertTrue(Veepoo.passwordAccepted(r))
        let fail = try XCTUnwrap(Veepoo.parsePasswordReply(T.pad(T.hex("A1 0000 00"))))
        XCTAssertEqual(.checkFail, fail.status)
        XCTAssertFalse(Veepoo.passwordAccepted(fail))
        XCTAssertNil(Veepoo.parsePasswordReply(T.hex("A1 0000 01")))
    }

    func testBattery() throws {
        let b = try XCTUnwrap(Veepoo.parseBattery(T.hex("A0 00 9B 00 04 01 5A 00")))
        XCTAssertEqual(90, b.percent)
        XCTAssertFalse(b.charging)
        XCTAssertTrue(b.exactPercent)
        let bars = try XCTUnwrap(Veepoo.parseBattery(T.hex("A0 01 80 00 03 00 00 02")))
        XCTAssertEqual(75, bars.percent)
        XCTAssertTrue(bars.charging)
        XCTAssertTrue(bars.low)
        XCTAssertNil(Veepoo.parseBattery(T.hex("A0 00 00 00 00 01 50 00")))
        XCTAssertEqual([0xA0, 0x00], Veepoo.batteryRead)
    }

    func testSetTimeAndFixedCommands() {
        XCTAssertEqual(T.pad(T.hex("A5 07EA 0A 13 0E 05 1E 02")), Veepoo.setTime(T.date(2026, 10, 19, 14, 5, 30), is24h: true, calendar: T.calendar))
        XCTAssertEqual(T.pad(T.hex("BC 01")), Veepoo.pairWithPhone)
        XCTAssertEqual([0xAF, 0x00], Veepoo.disconnectCommand)
    }

    func testCrc16Modbus() {
        XCTAssertEqual(0x4B37, Veepoo.crc16(Array("123456789".utf8)))
        XCTAssertEqual(0xFFFF, Veepoo.crc16([UInt8]()))
    }

    func testChunked() {
        let payload = [UInt8](1...20)
        let p = Veepoo.chunked(payload, op: 0x72, sub: 0x01)
        XCTAssertEqual(2, p.count)
        XCTAssertEqual([0x72, 0x01, 0x01, 0x02] + [UInt8](1...16), p[0])
        XCTAssertEqual(T.pad([0x72, 0x01, 0x02, 0x02] + [UInt8](17...20)), p[1])
        XCTAssertEqual([0xC8, 0x04, 0x02, 0x01], Array(Veepoo.chunked(payload, op: 0xC8, sub: 0x04, totalFirst: true)[0].prefix(4)))
        XCTAssertEqual(Array("Hà".utf8), Veepoo.utf8Prefix("Hà Nội", max: 3))
        XCTAssertEqual(Array("H".utf8), Veepoo.utf8Prefix("Hà", max: 2))
    }
}
