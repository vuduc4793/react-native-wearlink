import CoreBluetooth
import SmartWearCore
import XCTest
@testable import SmartWearGloryFit

/// Port của sdks/gloryfit/android/src/test/.../UteTest.kt (ví dụ hex lấy từ sdks/gloryfit/docs/01-protocol.md §7, §11).
/// Phần lịch sử (bước, ngủ, nhịp tim, SpO2) chưa port nên không có test tương ứng.
final class UteTests: XCTestCase {
    private func hex(_ s: String) -> [UInt8] { s.split(separator: " ").map { UInt8($0, radix: 16)! } }

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        return c
    }

    private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }

    func testCommands() throws {
        XCTAssertEqual(hex("A3 07 EA 0A 0D 10 1E 05"), Ute.setTime(at(2026, 10, 13, 16, 30, 5), calendar: calendar))
        XCTAssertEqual(hex("D5 01 64 66 76 0C"), try Ute.pairingCode("1234"))
        XCTAssertEqual(hex("33 02 00 BC 61 4E"), Ute.accountId(12_345_678))
        XCTAssertEqual(hex("A9 00 AA 00 41 05 00 00 1F 40 01 FF 00 1E 01 00 02 01 00"), Ute.userInfo())
    }

    func testPairingCodeRejectsInvalid() {
        XCTAssertThrowsError(try Ute.pairingCode("123"))
        XCTAssertThrowsError(try Ute.pairingCode("12a4"))
    }

    func testFeatureGroups() {
        // 33F1: F7 (2 byte), F6, F5, F4, F3, F2, F1 (3 byte mỗi nhóm).
        let main = hex("00 00 00 00 20 00 00 48 00 00 00 00 00 00 00 40 00 18 00 01")
        let ble5 = hex("00 F4 00 00 00 00 00 00 00 00 20 08 00 00 00 00 00 00 00 00")
        let f = Ute.Features.parse(main: main, ble5: ble5)
        XCTAssertTrue(f.usesPairingCode)  // F1 0x000001
        XCTAssertTrue(f.usesAccountId)  // F10 0x080000
        XCTAssertTrue(f.heartRate24h)  // F2 0x004000
        XCTAssertEqual(244, f.maxPacketLength)
        XCTAssertEqual(
            [.steps, .sleep, .heartRate, .bloodPressure, .spo2, .temperature, .stress, .hrv],
            f.capabilities()
        )
    }

    func testFeaturesHT43() {
        // doc 01 §11: không có huyết áp, không cần bind.
        let f = Ute.Features.parse(main: hex("08 88 6C 2A 01 24 39 43 75 6E DF FE D9 21 00 5D 78 4B A1 DC"), ble5: nil)
        XCTAssertFalse(f.usesPairingCode)
        XCTAssertFalse(f.usesAccountId)
        XCTAssertNil(f.maxPacketLength)
        // b12.7 (F3 0x8000) `isHasMenstruationReminder`: HT43 có theo dõi chu kỳ.
        XCTAssertEqual([.steps, .sleep, .heartRate, .spo2, .menstruation], f.capabilities())
    }

    func testFeaturesShortTablesIgnored() {
        let f = Ute.Features.parse(main: hex("00 01"), ble5: nil)
        XCTAssertTrue(f.groups.isEmpty)
        XCTAssertEqual([.steps, .sleep], f.capabilities())
    }

    func testEndOfStream() {
        XCTAssertTrue(Ute.isEnd(0xB2, hex("B2 FD")))
        XCTAssertFalse(Ute.isEnd(0xB2, hex("B2 07 EA 0A 0D 08 03 E8")))
        XCTAssertTrue(Ute.isEnd(0x34, hex("34 FA FD E7")))
        XCTAssertFalse(Ute.isEnd(0x34, hex("34 FA 07 EA 0A 0D 0F 00 62")))
        XCTAssertFalse(Ute.isEnd(0xB2, []))
    }

    func testPushedHeartRateFromY25() throws {
        let r = try XCTUnwrap(Ute.parsePushedHeartRate(hex("F7 03 07 EA 0A 0D 11 05 57"), calendar: calendar))
        XCTAssertEqual(87, r.value)
        XCTAssertEqual(.heartRate, r.capability)
        XCTAssertEqual(at(2026, 10, 13, 17, 5), r.timestamp)
        XCTAssertNil(Ute.parsePushedHeartRate(hex("F7 04 07 EA 0A 0D 11 2A 53 53 53"), calendar: calendar))
    }

    func testManualHeartRateF70B() throws {
        // `F7 0B YYYY MM DD hh mm bpm`: người dùng đo trên đồng hồ (doc 09 §2.2).
        let r = try XCTUnwrap(Ute.parsePushedHeartRate(hex("F7 0B 07 EA 0A 0F 09 2A 48"), calendar: calendar))
        XCTAssertEqual(72, r.value)
        XCTAssertEqual(.ok, r.status)
        XCTAssertEqual(at(2026, 10, 15, 9, 42), r.timestamp)
        XCTAssertNil(Ute.parsePushedHeartRate(hex("F7 0B 07 EA 0A 0F 09 2A 00"), calendar: calendar))
        XCTAssertNil(Ute.parsePushedHeartRate(hex("F7 0B 07 EA"), calendar: calendar))
        // Trong phép đo: F7 0B kết thúc với kết quả.
        let (reading, done) = try XCTUnwrap(GloryFitDevice.heartRatePacket(hex("F7 0B 07 EA 0A 0F 09 2A 48")))
        XCTAssertEqual(72, reading.value)
        XCTAssertTrue(done)
        XCTAssertNil(GloryFitDevice.heartRatePacket(hex("E5 AA 11")))
        XCTAssertEqual(false, GloryFitDevice.heartRatePacket(hex("E5 11"))?.1)
    }

    func testHeartRateByPushGate() {
        // Bảng thật (doc 01 §10, §11; 34F1 HT43 từ doc 08 §3.2): cả hai có isHas24HourHRM (33F1 byte 15 bit 6),
        // không có isHasHRMTimedMeasurement (34F1 byte 8 bit 7).
        let ble5 = hex("00 F4 00 00 00 00 00 00 00 00 00 05 00 00 40 00 00 00 04 00")
        let y25 = Ute.Features.parse(main: hex("08 88 6C 2A 01 24 39 43 75 6E DF FE D9 21 00 5D 78 5B A0 DC"), ble5: ble5)
        let ht43 = Ute.Features.parse(main: hex("08 88 6C 2A 01 24 39 43 75 6E DF FE D9 21 00 5D 78 4B A1 DC"), ble5: ble5)
        for f in [y25, ht43] {
            XCTAssertTrue(f.heartRate24h)
            XCTAssertFalse(f.heartRateTimedMeasurement)
            XCTAssertTrue(f.heartRateByPush)
        }
        // Bỏ bit 6 của byte 15 ⇒ đường cũ D6 01 / E5 11.
        let no24h = Ute.Features.parse(main: hex("08 88 6C 2A 01 24 39 43 75 6E DF FE D9 21 00 1D 78 5B A0 DC"), ble5: ble5)
        XCTAssertFalse(no24h.heartRate24h)
        XCTAssertFalse(no24h.heartRateByPush)
        // Có isHasHRMTimedMeasurement ⇒ SDK iOS cho đo tay E5 11.
        let timed = Ute.Features.parse(
            main: hex("08 88 6C 2A 01 24 39 43 75 6E DF FE D9 21 00 5D 78 5B A0 DC"),
            ble5: hex("00 F4 00 00 00 00 00 00 80 00 00 05 00 00 40 00 00 00 04 00")
        )
        XCTAssertTrue(timed.heartRateTimedMeasurement)
        XCTAssertFalse(timed.heartRateByPush)
        XCTAssertFalse(Ute.Features().heartRateByPush)
    }

    func testHeartRate24hCommands() {
        XCTAssertEqual(hex("F7 01"), Ute.hr24Enable)
        XCTAssertEqual(hex("F7 09 01 00 05"), Ute.heartRate24hInterval(minutes: 5))
        XCTAssertEqual(hex("F7 09 01 00 05"), Ute.heartRate24hInterval(minutes: 1))  // nhỏ nhất 5 phút
        XCTAssertEqual(hex("F7 09 01 00 3C"), Ute.heartRate24hInterval(minutes: 60))
        XCTAssertEqual(hex("E5 AA"), Ute.hrStatus)
        XCTAssertEqual(true, Ute.parseHeartRateStatus(hex("E5 AA 11")))
        XCTAssertEqual(false, Ute.parseHeartRateStatus(hex("E5 AA FF")))
        XCTAssertNil(Ute.parseHeartRateStatus(hex("E5 11 00 4C")))
    }

    func testSetTimeWithTimeZone() {
        let t = at(2026, 10, 13, 16, 30, 5)
        XCTAssertEqual(hex("A3 07 EA 0A 0D 10 1E 05 07"), Ute.setTime(t, calendar: calendar, tzHours: 7))
        XCTAssertEqual(hex("A3 07 EA 0A 0D 10 1E 05 F9"), Ute.setTime(t, calendar: calendar, tzHours: -7))
        XCTAssertEqual(7, Ute.tzHours(TimeZone(identifier: "Asia/Ho_Chi_Minh")!, at: t))
        XCTAssertEqual(-3, Ute.tzHours(TimeZone(identifier: "America/St_Johns")!, at: at(2026, 1, 10, 12, 0)))  // −3:30
    }

    func testLiveHeartRateFromWatch() {
        XCTAssertEqual(76, Ute.parseLiveHeartRate(hex("E5 11 00 4C"))?.value)  // gói thật từ Y25
        XCTAssertNil(Ute.parseLiveHeartRate(hex("E5 11 00 00")))
        XCTAssertNil(Ute.parseLiveHeartRate(hex("E5 11")))
    }

    func testHeartRateStream() {
        XCTAssertEqual(72, Ute.parseHeartRateStream(hex("E5 11 00 48"))?.bpm)
        let done = Ute.parseHeartRateStream(hex("E5 00 00 52"))
        XCTAssertEqual(82, done?.bpm)
        XCTAssertEqual(true, done?.contact)
        XCTAssertNil(Ute.parseHeartRateStream(hex("E5 11 00 00")))
        let off = Ute.parseHeartRateStream(hex("E5 00 01 00"))
        XCTAssertNotNil(off)
        XCTAssertNil(off?.bpm)
        XCTAssertEqual(false, off?.contact)
        XCTAssertEqual(87, Ute.parseHeartRateStream(hex("F7 03 07 EA 0A 10 11 05 57"))?.bpm)
        XCTAssertEqual(80, Ute.parseHeartRateStream(hex("F7 0B 07 EA 0A 10 11 05 50"))?.bpm)
        XCTAssertNil(Ute.parseHeartRateStream(hex("E5 11")))
        XCTAssertNil(Ute.parseHeartRateStream(hex("A2 50")))
    }

    func testDialParamsY25AndHT43() throws {
        // doc 01 §11: Y25 và HT43 trả giống hệt nhau (466 × 466, 1 MB, level 2, 1 khe).
        let p = try XCTUnwrap(Ute.parseDialParams(hex("26 01 FF FF FF FF 01 D2 01 D2 00 00 10 00 00 02 01 00 00 00")))
        XCTAssertEqual(0xFFFF_FFFF, p.currentId)
        XCTAssertEqual(466, p.width)
        XCTAssertEqual(466, p.height)
        XCTAssertEqual(0, p.screenType)
        XCTAssertEqual(1_048_576, p.maxSize)
        XCTAssertEqual(2, p.level)
        XCTAssertEqual(1, p.slots)
        XCTAssertEqual(0, p.corner)
        XCTAssertEqual(Ute.customFaceId, Ute.parseDialParams(hex("26 01 FF FF FF FE 01 D2 01 D2 00 00 10 00 00"))?.currentId)
        XCTAssertNil(Ute.parseDialParams(hex("26 02 FF FF FF FF 01 D2 01 D2 00 00 10 00 00")))
        XCTAssertNil(Ute.parseDialParams(hex("26 01 FF")))
    }

    func testUuids() {
        XCTAssertEqual(CBUUID(string: "000055FF-0000-1000-8000-00805F9B34FB"), Ute.service)
        XCTAssertEqual(CBUUID(string: "000034F1-0000-1000-8000-00805F9B34FB"), Ute.write5)
    }
}
