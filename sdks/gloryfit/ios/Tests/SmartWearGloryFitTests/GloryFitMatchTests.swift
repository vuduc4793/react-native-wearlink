import CoreBluetooth
import SmartWearCore
import SmartWearQRing
import XCTest
@testable import SmartWearGloryFit

/// Nhận diện khi quét: iOS không có MAC, chỉ dựa vào tên quảng bá và UUID 0x55xx.
final class GloryFitMatchTests: XCTestCase {
    private let registry = DeviceRegistry(drivers: [QRingDriver(), GloryFitDriver()])

    func testY25ByNameIsGloryFitNotQRing() {
        let d = ScannedDevice(id: UUID(), name: "Y25_6E1B", rssi: -55)
        XCTAssertFalse(QRing.matches(d))
        let m = GloryFitDriver().match(d)
        XCTAssertEqual("Y25", m?.model)
        XCTAssertEqual(.watch, m?.kind)
        XCTAssertEqual("gloryfit", registry.classify(d)?.driver.id)
    }

    func testHT43ByName() {
        let d = ScannedDevice(id: UUID(), name: "HT43(ID-2750)", rssi: -60)
        XCTAssertEqual("HT43(ID-2750)", GloryFitDriver().match(d)?.model)
    }

    func testByAdvertisedServiceWithoutName() {
        let d = ScannedDevice(id: UUID(), name: nil, rssi: -70, serviceUuids: [CBUUID(string: "5533")])
        XCTAssertEqual("Thiết bị GloryFit", GloryFitDriver().match(d)?.model)
    }

    func testByNewAdvertisedServices() {
        // doc 09 §1.2: UUID app GloryFit iOS lọc ngoài dải 0x55xx.
        for uuid in ["5554", "4544", "4231", "424C", "4F4F", "3455"] {
            let d = ScannedDevice(id: UUID(), name: nil, rssi: -70, serviceUuids: [CBUUID(string: uuid)])
            XCTAssertNotNil(GloryFitDriver().match(d), uuid)
        }
        XCTAssertEqual(13, Ute.advertised.count)
        XCTAssertTrue(Ute.advertised.contains(CBUUID(string: "55FF")))
    }

    func testOtherDevicesNotMatched() {
        let coros = ScannedDevice(id: UUID(), name: "COROS PACE 3 8E1086", rssi: -69,
                                  serviceUuids: ["180F", "180A", "FEE7"].map { CBUUID(string: $0) })
        XCTAssertNil(GloryFitDriver().match(coros))
        let r09 = ScannedDevice(id: UUID(), name: "R09_8404", rssi: -52, serviceUuids: [CBUUID(string: "FEE7")])
        XCTAssertEqual("qring", registry.classify(r09)?.driver.id)
    }

    func testSystemServices() {
        XCTAssertEqual([CBUUID(string: "55FF"), CBUUID(string: "55F0")], GloryFitDriver().systemServices)
    }
}
