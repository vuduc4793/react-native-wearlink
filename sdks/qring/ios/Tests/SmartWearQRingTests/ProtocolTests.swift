import XCTest
@testable import SmartWearQRing

/// Port của sdks/qring/android/src/test/.../protocol/ProtocolTest.kt (cùng vector hex).
final class ProtocolTests: XCTestCase {
    private func hex(_ s: String) -> [UInt8] { s.split(separator: " ").map { UInt8($0, radix: 16)! } }

    func testSetTimeExampleFromDocs() {
        // sdks/qring/docs/01-connection.md §4.2: 2025-01-15 10:30:45, tiếng Anh
        let p = Packet.of(0x01, 0x25, 0x01, 0x15, 0x10, 0x30, 0x45, 0x01)
        XCTAssertEqual(hex("01 25 01 15 10 30 45 01 00 00 00 00 00 00 00 C2"), p.bytes)
    }

    func testBatteryRequestAndResponse() {
        XCTAssertEqual(hex("03 00 00 00 00 00 00 00 00 00 00 00 00 00 00 03"), Packet.of(0x03).bytes)
        let rsp = Packet.parse(hex("03 55 00 00 00 00 00 00 00 00 00 00 00 00 00 58"))!
        XCTAssertEqual(3, rsp.command)
        XCTAssertEqual(85, rsp.u8(0))
    }

    func testParseRejectsBadChecksumAndLength() {
        XCTAssertNil(Packet.parse(hex("03 55 00 00 00 00 00 00 00 00 00 00 00 00 00 59")))
        XCTAssertNil(Packet.parse(hex("03 55")))
    }

    func testErrorFlag() {
        let p = Packet.parse(Packet.of(0x83).bytes)!
        XCTAssertTrue(p.isError)
        XCTAssertEqual(3, p.command)
    }

    func testCrc16ModbusCheckValue() {
        XCTAssertEqual(0x4B37, BigDataFrame.crc16Modbus(Array("123456789".utf8)))
    }

    func testBigDataExamplesFromDocs() {
        XCTAssertEqual(hex("BC 2C 01 00 7E 80 01"), BigDataFrame(command: 0x2C, payload: hex("01")).encode())
        XCTAssertEqual(hex("BC 27 02 00 C0 70 00 01"), BigDataFrame(command: 0x27, payload: hex("00 01")).encode())
        XCTAssertEqual(hex("BC 01 00 00 FF FF"), BigDataFrame(command: 0x01, payload: []).encode())
    }

    func testAssemblerJoinsChunks() {
        let payload = (0..<50).map { UInt8($0) }
        var frames: [BigDataFrame] = []
        let assembler = BigDataAssembler { frames.append($0) }
        BigDataFrame(command: 0x27, payload: payload).chunks(20).forEach(assembler.feed)
        XCTAssertEqual(1, frames.count)
        XCTAssertEqual(0x27, frames[0].command)
        XCTAssertEqual(payload, frames[0].payload)
    }

    func testPhoneInfoExampleFromDocs() {
        // 01-connection.md: model "Pixel 7" → 04 02 0A 50 69 78 65 6C 20 37 00 00 00 00 00 69
        let p = Packet.of(0x04, payload: [0x02, 0x0A] + Array("Pixel 7".utf8))
        XCTAssertEqual(hex("04 02 0A 50 69 78 65 6C 20 37 00 00 00 00 00 69"), p.bytes)
    }

    func testLanguageCode() {
        XCTAssertEqual(18, QRingClient.languageCode("vi-VN"))
        XCTAssertEqual(1, QRingClient.languageCode("en"))
        XCTAssertEqual(1, QRingClient.languageCode("xx"))
    }
}
