import XCTest
@testable import SmartWearGloryFit

/// Port của sdks/gloryfit/android/src/test/.../UteWatchFaceTest.kt (ví dụ trong sdks/gloryfit/docs/02-watchface.md §4)
/// và các bước kiểm tra của `installWatchFaceFile`.
final class UteWatchFaceTests: XCTestCase {
    private func hex(_ s: String) -> [UInt8] { s.split(separator: " ").map { UInt8($0, radix: 16)! } }
    private func le32(_ b: [UInt8], _ i: Int) -> Int { UteWatchFace.le32(b, i) }

    func testCrc32CheckValue() {
        XCTAssertEqual(0xCBF4_3926, UteWatchFace.crc32(Array("123456789".utf8)))
        XCTAssertEqual(0, UteWatchFace.crc32([UInt8]()))
    }

    func testRgb565BigEndianAndNearBlack() {
        XCTAssertEqual(hex("F8 00 FF FF 10 42"), UteWatchFace.rgb565([0xFFFF_0000, 0xFFFF_FFFF, 0xFF00_0000]))
    }

    func testRleTwoRuns() {
        // 100 px "đen" (0x0000) rồi 140 px trắng: 01 64 00 00 01 8C FF FF.
        var px = [UInt8](repeating: 0, count: 240 * 2)
        for i in 100..<240 { px[2 * i] = 0xFF; px[2 * i + 1] = 0xFF }
        let out = UteWatchFace.rle(px, w: 240, h: 1)
        XCTAssertEqual(4 + 8, le32(out, 0))  // bảng 1 dòng (4 byte) + 8 byte dữ liệu
        XCTAssertEqual(4, le32(out, 4))  // dòng 0 bắt đầu sau bảng
        XCTAssertEqual(hex("01 64 00 00 01 8C FF FF"), Array(out[8..<16]))
    }

    func testRleMergesSinglePixels() {
        let out = UteWatchFace.rle(hex("11 11 22 22 33 33"), w: 3, h: 1)
        XCTAssertEqual(hex("03 01 11 11 22 22 33 33"), Array(out[8...]))
    }

    private func sampleBin(level: Int = 0) throws -> [UInt8] {
        let bg = try UteWatchFace.Element(type: UteWatchFace.typeBackground, x: 0, y: 0, w: 2, h: 1, frames: [[0xFFFF_FFFF, 0xFFFF_FFFF]])
        let digit = try UteWatchFace.Element(type: UteWatchFace.typeHourTens, x: 5, y: 6, w: 1, h: 1,
                                             frames: Array(repeating: [0xFFFF_FFFF], count: 14))
        return UteWatchFace.build(width: 466, height: 466, level: level, elements: [digit, bg])
    }

    func testHeaderAndTable() throws {
        let bin = try sampleBin()
        XCTAssertEqual(hex("FE FF FF FF"), Array(bin[0..<4]))
        let payload = Array(bin[24...])
        XCTAssertEqual(payload.count, le32(bin, 4))
        XCTAssertEqual(Int(UteWatchFace.crc32(payload)), le32(bin, 8))
        XCTAssertEqual(hex("D2 01 D2 01 00 01 FF 00 FF FF FF FF"), Array(bin[12..<24]))
        // Element sắp theo type: nền (17) trước chữ số (57); dữ liệu bắt đầu ở (2+1)*24+2 = 74.
        XCTAssertEqual(17, bin[24])
        XCTAssertEqual(74, le32(bin, 24 + 4))
        XCTAssertEqual(57, bin[48])
        XCTAssertEqual(74 + 4, le32(bin, 48 + 4))
        XCTAssertEqual(14, bin[48 + 16])
    }

    func testElementSizeMismatchThrows() {
        XCTAssertThrowsError(try UteWatchFace.Element(type: 17, x: 0, y: 0, w: 2, h: 2, frames: [[0]]))
        XCTAssertThrowsError(try UteWatchFace.Element(type: 17, x: 0, y: 0, w: 1, h: 1, frames: []))
    }

    // MARK: - validate (installWatchFaceFile)

    private func assertRejects(_ bin: [UInt8], width: Int = 466, height: Int = 466, maxBytes: Int = 1_048_576, level: Int = 2,
                               _ fragment: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try UteWatchFace.validate(bin, width: width, height: height, maxBytes: maxBytes, level: level),
                             file: file, line: line) { error in
            XCTAssertTrue(error.localizedDescription.contains(fragment), "\(error.localizedDescription)", file: file, line: line)
        }
    }

    func testValidateAcceptsBuiltFile() throws {
        let bin = try sampleBin()
        XCTAssertNoThrow(try UteWatchFace.validate(bin, width: 466, height: 466, maxBytes: 1_048_576, level: 2))
        XCTAssertNoThrow(try UteWatchFace.validate(bin, width: 466, height: 466, maxBytes: bin.count, level: 0))
    }

    func testValidateRejects() throws {
        let bin = try sampleBin()
        assertRejects(Array(bin[0..<20]), "quá ngắn")
        assertRejects(bin, width: 240, height: 240, "466×466")
        assertRejects(bin + [0x00], "Độ dài")
        var corrupt = bin
        corrupt[corrupt.count - 1] ^= 0xFF
        assertRejects(corrupt, "CRC-32")
        assertRejects(bin, maxBytes: bin.count - 1, "vượt giới hạn")
        let compressed = try sampleBin(level: 2)
        XCTAssertEqual(2, compressed[19])
        assertRejects(compressed, level: 0, "nén RLE")
    }
}
