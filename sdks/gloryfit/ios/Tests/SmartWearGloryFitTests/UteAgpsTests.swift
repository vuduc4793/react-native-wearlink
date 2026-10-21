import Foundation
import SmartWearCore
import XCTest
@testable import SmartWearGloryFit

/// Cùng dữ liệu mẫu với `UteAgpsTest` Android.
final class UteAgpsTests: XCTestCase {
    private func b(_ hex: String) -> [UInt8] { hex.split(separator: " ").map { UInt8($0, radix: 16)! } }

    func testCommands() throws {
        XCTAssertEqual(UteAgps.info, b("01 E9 AA 01"))
        XCTAssertEqual(UteAgps.ephemerisState, b("56 FD"))
        XCTAssertEqual(UteAgps.status(UteAgps.statusDone), b("01 E9 AB 03 01 03"))
        XCTAssertEqual(UteAgps.status(UteAgps.statusNotSupport), b("01 E9 AB 03 01 05"))
        XCTAssertEqual(
            try UteAgps.position(timestamp: 0x12345678, latitude: 21.0285, longitude: 105.8542),
            b("01 E9 AB 02 0C 12 34 56 78 0C 88 B1 C8 3F 18 11 B0")
        )
        XCTAssertEqual(
            try UteAgps.position(timestamp: 1, latitude: -33.8688, longitude: 105.8542),
            b("01 E9 AB 02 0C 00 00 00 01 EB D0 08 00 3F 18 11 B0")
        )
        XCTAssertThrowsError(try UteAgps.position(timestamp: 1, latitude: 91, longitude: 0))
        XCTAssertEqual(UteAgps.dataPacket(0x0102, b("AA BB")[...]), b("01 E9 AB 04 01 02 AA BB"))
        XCTAssertEqual(UteAgps.endPacket(0x5A), b("01 E9 AB 04 FD FD 5A"))
    }

    func testRequests() {
        XCTAssertEqual(UteAgps.parseRequest(b("01 E9 AC 03 01 02")), .status)
        XCTAssertEqual(UteAgps.parseRequest(b("01 E9 AC 03 01 01")), .download)
        XCTAssertEqual(UteAgps.parseRequest(b("01 E9 AC 01 00 01")), .position)
        XCTAssertNil(UteAgps.parseRequest(b("01 E9 AC 01 00 00")))
        XCTAssertNil(UteAgps.parseRequest(b("01 E9 AC 04 01 07")))
        XCTAssertNil(UteAgps.parseRequest(b("FD 01 AA 01")))
        XCTAssertTrue(UteAgps.isTransferResult(b("01 E9 AC 04 01 07")))
        XCTAssertEqual(UteAgps.resendFrom(b("01 E9 AC 04 01 06 01 23")), 0x0123)
        XCTAssertNil(UteAgps.resendFrom(b("01 E9 AC 04 01 07")))
        XCTAssertEqual(UteAgps.parseEphemerisState(b("56 FD 01")), true)
        XCTAssertEqual(UteAgps.parseEphemerisState(b("56 FD 00")), false)
        XCTAssertNil(UteAgps.parseEphemerisState(b("56 01 00")))
    }

    func testInfo() {
        let packets = [
            b("01 E9 AA 01 00 01 01 3C 02 02 00 07 03 0F 67 70 73 5F"),
            b("01 E9 AA 01 01 67 61 6C 3B 67 70 73 5F 62 64 73"),
            b("01 E9 AA 01 FD 00"),
        ]
        XCTAssertTrue(UteAgps.isInfoEnd(packets[2]))
        let info = UteAgps.parseInfo(packets, ephemerisValid: false)
        XCTAssertEqual(info, AgpsInfo(files: ["gps_gal", "gps_bds"], version: 7, interval: 60, ephemerisValid: false))
        XCTAssertEqual(UteAgps.parseInfo([b("01 E9 AA 01 00 03 09 61")]).files, [])
    }

    func testPayloadAndPackets() throws {
        let files = [AgpsFile(name: "gps_gal.dat", data: Data(b("01 02 03"))), AgpsFile(name: "bds", data: Data(b("04 05")))]
        let payload = try UteAgps.payload(files)
        XCTAssertEqual(payload, b("00 14 07 67 70 73 5F 67 61 6C 00 00 00 03 03 62 64 73 00 00 00 02 00 00 00 05 01 02 03 04 05"))
        let packets = UteAgps.packets(payload, chunk: 14)
        XCTAssertEqual(packets.count, 3)
        XCTAssertEqual(packets[2], b("01 E9 AB 04 00 02 03 04 05"))
        XCTAssertEqual(UteAgps.xor(packets), packets.flatMap { $0 }.reduce(0) { $0 ^ Int($1) })
    }

    func testLimits() throws {
        XCTAssertThrowsError(try UteAgps.payload([]))
        XCTAssertThrowsError(try UteAgps.payload([AgpsFile(name: "a", data: Data())]))
        XCTAssertThrowsError(try UteAgps.payload([AgpsFile(name: "a", data: Data(count: UteAgps.maxFileBytes + 1))]))
        XCTAssertThrowsError(try UteAgps.payload([AgpsFile(name: "tên lạ", data: Data([1]))]))
        XCTAssertThrowsError(try UteAgps.payload((0..<3).map { AgpsFile(name: "f\($0)", data: Data(count: UteAgps.maxFileBytes)) }))
        XCTAssertEqual(try UteAgps.stem("dir/gps_gal.dat"), "gps_gal")
    }
}
