import XCTest
@testable import SmartWearGloryFit

/// Gói mẫu đã gửi thật lên Y25 ngày 15/10/2026 (đồng hồ trả `37 FB 01`).
final class UteContactsTests: XCTestCase {
    private func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }
    private let y25 = Ute.Features(groups: [5: 0x002000, 6: 0x6C2A01 | 0x080000], maxPacketLength: 244)

    func testSingleContactMatchesWatchVerifiedPacket() {
        let segs = UteContacts.segments([.init(name: "Test SmartWear", phone: "090 123 4567")], features: y25, packetLength: 244)
        XCTAssertEqual(segs.count, 1)
        XCTAssertEqual(segs[0].count, 244)
        XCTAssertEqual(hex(Array(segs[0].prefix(19))), "37 FB 01 37 FB 0A 1C 30 39 30 31 32 33 34 35 36 37 00 54")
    }

    func testFourRecordsPerPacketAndVietnameseNames() {
        let list = (1...9).map { UteContacts.Contact(name: "Nguyễn Văn Đức số \($0) dài quá", phone: "+84 912 345 67\($0)") }
        let segs = UteContacts.segments(list, features: y25, packetLength: 244)
        XCTAssertEqual(segs.map { $0[2] }, [4, 4, 1])
        // Tên cắt còn 20 ký tự (40 byte UTF-16), số "+84912345671" còn 12 ký tự.
        XCTAssertEqual(segs[0][5], 12)
        XCTAssertEqual(segs[0][6], 40)
        XCTAssertEqual(Array(segs[0][19..<23]), [0x00, 0x4E, 0x00, 0x67]) // "Ng" ngay sau số
        XCTAssertTrue(UteContacts.supported(y25))
        XCTAssertEqual(UteContacts.maxContacts(y25), 70)
    }

    func testCallBluetoothStateParsing() {
        let p: [UInt8] = [0x38, 0x01] + Array("Y25(ID-6E1B)".utf8) + [UInt8](repeating: 0, count: 8) + [0x78, 0x02, 0xB7, 0x03, 0x6E, 0x1B, 1, 1, 1, 0, 0]
        let s = GloryFitDevice.parseCallBluetooth(p)
        XCTAssertEqual(s, CallBluetoothState(name: "Y25(ID-6E1B)", address: "78:02:B7:03:6E:1B", enabled: true, paired: true, connected: true))
    }
}
