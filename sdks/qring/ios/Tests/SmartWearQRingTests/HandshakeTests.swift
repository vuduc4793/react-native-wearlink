import CoreBluetooth
import SmartWearCore
import XCTest
@testable import SmartWearQRing

/// Transport giả: ghi lại thứ tự lệnh, trả lời theo `reply` (ném lỗi để giả lập hết giờ / lỗi).
@MainActor
private final class FakeTransport: QRingHandshakeTransport {
    var sent: [UInt8] = []
    var pauses: [TimeInterval] = []
    var timeouts: [TimeInterval] = []
    var reply: (Packet, Int) throws -> Packet = { p, _ in p }

    func request(_ packet: Packet, timeout: TimeInterval) async throws -> Packet {
        sent.append(packet.command)
        timeouts.append(timeout)
        let n = sent.filter { $0 == packet.command }.count
        return try reply(packet, n)
    }

    func pause(_ seconds: TimeInterval) async throws { pauses.append(seconds) }
}

/// Bắt tay theo app QRing iOS 1.3.1 (sdks/qring/docs/ios-qring-app.md §3).
@MainActor
final class HandshakeTests: XCTestCase {
    private func hex(_ s: String) -> [UInt8] { s.split(separator: " ").map { UInt8($0, radix: 16)! } }

    func testPhoneInfoIOSExampleFromDoc() {
        // iOS 18, iPhone 15 Pro (iPhone16,1 → mã 35 = 0x23).
        XCTAssertEqual(
            hex("04 01 12 23 00 00 00 00 00 00 00 00 00 00 00 3A"),
            QRingHandshake.phoneInfoPacket(osMajor: 18, machine: "iPhone16,1").bytes
        )
    }

    func testPhoneInfoModelIndexes() {
        XCTAssertEqual(12, QRingHandshake.iPhoneModelIndex("iPhone10,6"))  // X
        XCTAssertEqual(19, QRingHandshake.iPhoneModelIndex("iPhone12,8"))  // SE 2
        XCTAssertEqual(28, QRingHandshake.iPhoneModelIndex("iPhone14,6"))  // SE 3
        XCTAssertEqual(36, QRingHandshake.iPhoneModelIndex("iPhone16,2"))  // 15 Pro Max
        // Không có trong bảng: 6 Plus, iPhone 16, simulator/Mac.
        XCTAssertEqual(0, QRingHandshake.iPhoneModelIndex("iPhone7,1"))
        XCTAssertEqual(0, QRingHandshake.iPhoneModelIndex("iPhone17,1"))
        XCTAssertEqual(0, QRingHandshake.iPhoneModelIndex("arm64"))
        XCTAssertEqual(
            hex("04 01 11 00 00 00 00 00 00 00 00 00 00 00 00 16"),
            QRingHandshake.phoneInfoPacket(osMajor: 17, machine: "iPhone17,3").bytes
        )
        XCTAssertEqual(
            hex("04 01 10 1A 00 00 00 00 00 00 00 00 00 00 00 2F"),
            QRingHandshake.phoneInfoPacket(osMajor: 16, machine: "iPhone14,2").bytes
        )
    }

    func testSetTimePacketIsBCDPlusOneSecond() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let date = cal.date(from: DateComponents(year: 2025, month: 1, day: 15, hour: 10, minute: 30, second: 44))!
        // sdks/qring/docs/01-connection.md §4.2: 2025-01-15 10:30:45, tiếng Anh.
        XCTAssertEqual(
            hex("01 25 01 15 10 30 45 01 00 00 00 00 00 00 00 C2"),
            QRingHandshake.setTimePacket(date, language: 1, calendar: cal).bytes
        )
    }

    func testOrderPhoneInfoThenSetTimeThenSupport() async throws {
        let t = FakeTransport()
        let r = try await QRingHandshake.run(t, phoneInfo: QRingHandshake.phoneInfoPacket(osMajor: 18, machine: "x"),
                                             setTime: { Packet.of(0x01) })
        XCTAssertEqual([0x04, 0x01, 0x3C], t.sent)
        XCTAssertEqual(QRingHandshake.phoneInfoTimeout, t.timeouts.first)
        XCTAssertTrue(r.phoneInfoAcked)
        XCTAssertEqual([], t.pauses)
    }

    func testPhoneInfoTimeoutDoesNotAbortAndSetTimeRetries() async throws {
        let t = FakeTransport()
        var built = 0
        t.reply = { p, n in
            if p.command == 0x04 { throw GattError.timeout("0x04") }
            if p.command == 0x01, n < 3 { throw QRingError("Không nhận được phản hồi lệnh 0x01") }
            return p
        }
        let r = try await QRingHandshake.run(t, phoneInfo: Packet.of(0x04, 0x01), setTime: {
            built += 1
            return Packet.of(0x01)
        })
        XCTAssertFalse(r.phoneInfoAcked)
        XCTAssertEqual([0x04, 0x01, 0x01, 0x01, 0x3C], t.sent)
        XCTAssertEqual([1, 1], t.pauses)
        XCTAssertEqual(3, built, "mỗi lần thử dựng lại gói SetTime để giờ luôn mới")
    }

    func testSetTimeFailsAfterThreeAttempts() async {
        let t = FakeTransport()
        t.reply = { p, _ in
            if p.command == 0x01 { throw QRingError("hết giờ") }
            return p
        }
        do {
            _ = try await QRingHandshake.run(t, phoneInfo: Packet.of(0x04), setTime: { Packet.of(0x01) })
            XCTFail("phải ném lỗi")
        } catch {
            XCTAssertEqual(QRingError("hết giờ"), error as? QRingError)
        }
        XCTAssertEqual([0x04, 0x01, 0x01, 0x01], t.sent, "không gửi 0x3C khi SetTime hỏng")
        XCTAssertEqual([1, 1], t.pauses)
    }

    func testSupportRetriesAndDisconnectStopsImmediately() async {
        let t = FakeTransport()
        t.reply = { p, n in
            if p.command == 0x3C, n == 1 { throw QRingError("hết giờ") }
            if p.command == 0x3C { throw GattError.disconnected }
            return p
        }
        do {
            _ = try await QRingHandshake.run(t, phoneInfo: Packet.of(0x04), setTime: { Packet.of(0x01) })
            XCTFail("phải ném lỗi")
        } catch {
            XCTAssertEqual(GattError.disconnected, error as? GattError)
        }
        XCTAssertEqual([0x04, 0x01, 0x3C, 0x3C], t.sent)
        XCTAssertEqual([1], t.pauses)
    }

    func testMacFromSystemId() {
        // MAC 30:32:43:31:84:04 → System ID 04 84 31 FE FF 43 32 30 (EUI-64 kiểu Nordic).
        XCTAssertEqual("30:32:43:31:84:04", QRingHandshake.macFromSystemId(Data(hex: "0484 31FE FF43 3230")!))
        XCTAssertNil(QRingHandshake.macFromSystemId(Data([1, 2, 3])))
        XCTAssertNil(QRingHandshake.macFromSystemId(Data(count: 8)))
    }

    func testDriverServicesAndShortBackoff() {
        let d = QRingDriver()
        XCTAssertEqual(["FEE7", "6E40FFF0-B5A3-F393-E0A9-E50E24DCCA9E", "DE5BF728-D711-4E47-AF26-65E3012A5DC7"],
                       d.systemServices.map(\.uuidString))
        let schedule = d.reconnectBackoff ?? []
        XCTAssertEqual([2, 4, 4, 4, 4, 4], (0..<6).map { DeviceManager.backoffDelay(attempt: $0, schedule: schedule) })
    }

    func testStopPacketCarriesLastValue() {
        func ok(_ type: MeasurementType, _ bytes: [UInt8]) -> MeasurementReading {
            MeasurementReading.parse(type, Packet.of(0x69, payload: bytes))
        }
        // 02-commands.md §4.5.2: 6A 01 48 … (HR 72).
        XCTAssertEqual(hex("6A 01 48 00 00 00 00 00 00 00 00 00 00 00 00 B3"),
                       MeasurementType.heartRate.stopPacket(last: ok(.heartRate, [1, 0, 0x48])).bytes)
        XCTAssertEqual(hex("6A 01 00 00 00 00 00 00 00 00 00 00 00 00 00 6B"),
                       MeasurementType.heartRate.stopPacket(last: nil).bytes)
        XCTAssertEqual([0x6A, 0x02, 120, 80], Array(MeasurementType.bloodPressure.stopPacket(
            last: ok(.bloodPressure, [2, 0, 0, 120, 80])).bytes.prefix(4)))
        // Nhiệt độ: byte thô 0xA5 = 165 → 36.5 °C → gửi lại 0xA5.
        XCTAssertEqual([0x6A, 0x0B, 0xA5], Array(MeasurementType.temperature.stopPacket(
            last: ok(.temperature, [11, 0, 0xA5])).bytes.prefix(3)))
        // Start giữ nguyên byte 0x25 đã kiểm chứng trên Android.
        XCTAssertEqual(0x25, MeasurementType.spo2.sub)
    }

    func testKindByNameAndHardware() {
        XCTAssertEqual(.ring, QRing.guessKind("R09_8404"))
        XCTAssertEqual(.ring, QRing.guessKind("RING1"))
        XCTAssertEqual(.band, QRing.guessKind("DS500_1234"))
        XCTAssertEqual(.band, QRing.guessKind("ds520"))
        XCTAssertEqual(.band, QRing.guessKind("HS500A"))
        XCTAssertEqual(.band, QRing.guessKind("H59 Pro"))
        XCTAssertEqual(.band, QRing.guessKind("DS1314"))
        XCTAssertEqual(.band, QRing.guessKind("DS12"))
        XCTAssertEqual(.unknown, QRing.guessKind(nil))
        XCTAssertEqual(.unknown, QRing.guessKind("Yawell"))
        XCTAssertEqual(.band, QRing.kind(fromHardware: "HS500A_V1.0"))
        XCTAssertEqual(.ring, QRing.kind(fromHardware: "RT09_V3.1"))
        XCTAssertNil(QRing.kind(fromHardware: ""))
        XCTAssertNil(QRing.kind(fromHardware: "XYZ_V1"))
    }

    /// Mặc định không gửi cờ iOS (04 01) để nhẫn/vòng không bị iOS ghép đôi giữ kết nối mãi.
    func testNeutralPhoneInfoIsAndroidForm() {
        let b = QRingHandshake.neutralPhoneInfoPacket(machine: "iPhone12,1").bytes
        XCTAssertEqual(Array(b[0...2]), [0x04, 0x02, 0x0A])
        XCTAssertEqual(String(decoding: b[3..<13], as: UTF8.self), "iPhone12,1")
        XCTAssertEqual(Packet.parse(b)?.bytes, b, "checksum đúng")
    }
}
