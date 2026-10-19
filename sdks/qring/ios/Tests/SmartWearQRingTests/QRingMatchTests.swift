import CoreBluetooth
import SmartWearCore
import XCTest
@testable import SmartWearQRing

/// Quảng bá thật quét được ngày 2026-10-13.
final class QRingMatchTests: XCTestCase {
    private func manu(_ s: String) -> [UInt16: Data] {
        ScannedDevice.splitManufacturerData(Data(hex: s))
    }

    func testR09ByNameAndManufacturerData() {
        let d = ScannedDevice(id: UUID(), name: "R09_8404", rssi: -52, serviceUuids: [CBUUID(string: "FEE7")],
                              manufacturerData: manu("3412 FEE7 303243318404"))
        XCTAssertTrue(QRing.matches(d))
        XCTAssertEqual("30:32:43:31:84:04", QRing.macFromAdvertisement(d))
        XCTAssertEqual(.ring, QRingDriver().match(d)?.kind)
    }

    func testHS500AByManufacturerDataOnly() {
        let d = ScannedDevice(id: UUID(), name: nil, rssi: -60, serviceUuids: [CBUUID(string: "FE00")],
                              manufacturerData: manu("3412 FEE7 323545374E00"))
        let m = QRingDriver().match(d)
        XCTAssertNotNil(m)
        XCTAssertEqual("32:35:45:37:4E:00", m?.mac)
    }

    func testCorosWithFEE7IsNotQRing() {
        let d = ScannedDevice(id: UUID(), name: "COROS PACE 3 8E1086", rssi: -69,
                              serviceUuids: ["180F", "180A", "FEE7"].map { CBUUID(string: $0) })
        XCTAssertFalse(QRing.matches(d))
    }

    func testModelFromHardware() {
        XCTAssertEqual("HS500A", QRingDevice.model(fromHardware: "HS500A_V1.0"))
        XCTAssertEqual("RT09", QRingDevice.model(fromHardware: "RT09_V3.1"))
        XCTAssertNil(QRingDevice.model(fromHardware: ""))
    }

    /// Thiết bị iOS đang giữ kết nối không có quảng bá: nhận theo dịch vụ GATT riêng của QRing; DS500 là vòng tay.
    func testMatchesSystemConnectedByServiceAndDS500IsBand() {
        let held = ScannedDevice(id: UUID(), name: "DS500_4E00", rssi: 0, serviceUuids: [QRing.service, QRing.bigDataService, CBUUID(string: "180A")])
        XCTAssertNotNil(QRingDriver().match(held))
        XCTAssertEqual(QRingDriver().match(held)?.kind, .band)
        let noName = ScannedDevice(id: UUID(), name: nil, rssi: 0, serviceUuids: [QRing.bigDataService])
        XCTAssertNotNil(QRingDriver().match(noName))
        let other = ScannedDevice(id: UUID(), name: "COROS PACE 3", rssi: -60, serviceUuids: [CBUUID(string: "FEE7"), CBUUID(string: "180D")])
        XCTAssertNil(QRingDriver().match(other))
    }
}
