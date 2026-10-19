import CoreBluetooth
import SmartWearCore
import XCTest
@testable import SmartWearVeepoo

/// Thiết bị chưa kết nối (không cần Bluetooth): thuộc tính dựng từ quảng bá, giá trị mặc định của các nhóm API.
@MainActor
final class VeepooDeviceTests: XCTestCase {
    func testCreateFromAdvert() async throws {
        let scanned = ScannedDevice(id: UUID(), name: "GE54\u{FFFD}", rssi: -46, serviceUuids: [CBUUID(string: "FEE7")],
                                    manufacturerData: [0xF8F8: Data(VeepooProtocolTests.ge54Payload)])
        let match = try XCTUnwrap(VeepooDriver().match(scanned))
        let d = try XCTUnwrap(VeepooDriver().create(scanned, match: match) as? VeepooDevice)
        XCTAssertEqual("veepoo", d.driverId)
        XCTAssertEqual("GE54", d.name)
        XCTAssertEqual("GE54", d.model)
        XCTAssertEqual(.band, d.kind)
        XCTAssertEqual("9C:F4:8F:E3:1D:45", d.mac)
        XCTAssertEqual("5980", d.info.extra("Device number (quảng bá)"))
        XCTAssertEqual("161", d.info.extra("Mã quảng bá (byte 6–7)"))
        XCTAssertEqual(.disconnected, d.state)
        XCTAssertTrue(d.supportsHistory)
        XCTAssertTrue(d.measurableCapabilities.isEmpty)  // chưa có bảng A7
        XCTAssertFalse(d.supportsNotifications)
        XCTAssertFalse(d.supportsWatchFace)
        XCTAssertFalse(d.supportsWeather)
        XCTAssertEqual(0, d.maxContacts)
        XCTAssertFalse(d.supportsIncomingCall)  // iOS: cuộc gọi qua ANCS
        XCTAssertFalse(d.supportsSmsReply)
        do {
            try await d.runAction("find.start")
            XCTFail("chưa kết nối phải ném lỗi")
        } catch {
            XCTAssertEqual("Vòng tay chưa kết nối", error.localizedDescription)
        }
        // Mục cài đặt lưu cục bộ được nhận cả khi chưa kết nối.
        try await d.setControl("goal.steps", .number(9000))
        XCTAssertEqual(9000, d.settings["goal.steps"])
    }

    func testPhone24hDetectionDoesNotCrash() {
        _ = VeepooDevice.phoneUses24h()
    }
}
