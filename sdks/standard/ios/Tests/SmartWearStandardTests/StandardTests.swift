import CoreBluetooth
import SmartWearCore
import SmartWearQRing
import XCTest
@testable import SmartWearStandard

final class StandardTests: XCTestCase {
    func testHeartRateUInt8() {
        let hr = HeartRateMeasurement.parse(Data([0x00, 0x48]))
        XCTAssertEqual(72, hr?.bpm)
        XCTAssertNil(hr?.sensorContact)
    }

    func testHeartRateUInt16LittleEndian() {
        // flags bit0 = 1 → UInt16 LE: 0x0105 = 261
        XCTAssertEqual(261, HeartRateMeasurement.parse(Data([0x01, 0x05, 0x01]))?.bpm)
    }

    func testHeartRateContactEnergyAndRR() {
        // flags: contact supported+detected (0x06), energy (0x08), RR (0x10)
        let hr = HeartRateMeasurement.parse(Data([0x1E, 0x50, 0x10, 0x00, 0x00, 0x04, 0x00, 0x02]))
        XCTAssertEqual(80, hr?.bpm)
        XCTAssertEqual(true, hr?.sensorContact)
        XCTAssertEqual(16, hr?.energyExpended)
        XCTAssertEqual([1000, 500], hr?.rrIntervalsMs)
        XCTAssertEqual(false, HeartRateMeasurement.parse(Data([0x04, 0x00]))?.sensorContact)
    }

    func testHeartRateRejectsShortData() {
        XCTAssertNil(HeartRateMeasurement.parse(Data([0x01, 0x05])))
        XCTAssertNil(HeartRateMeasurement.parse(Data([0x00])))
    }

    func testCorosMatchesStandard() {
        let d = ScannedDevice(id: UUID(), name: "COROS PACE 3 8E1086", rssi: -69,
                              serviceUuids: ["180F", "180A", "FEE7"].map { CBUUID(string: $0) })
        let m = StandardDriver().match(d)
        XCTAssertEqual("standard", m?.driverId)
        XCTAssertEqual(.watch, m?.kind)
    }

    func testKeyboardWithBatteryIsNotWearable() {
        let d = ScannedDevice(id: UUID(), name: "AULA-F75 5.0 KB", rssi: -70,
                              serviceUuids: ["1812", "180F"].map { CBUUID(string: $0) })
        XCTAssertNil(StandardDriver().match(d))
    }

    func testUnrelatedDeviceDoesNotMatch() {
        let d = ScannedDevice(id: UUID(), name: "TV", rssi: -80, serviceUuids: [CBUUID(string: "FE9F")])
        XCTAssertNil(StandardDriver().match(d))
    }

    /// QRing đứng trước standard: thiết bị vừa phát 180F vừa có manufacturer data QRing thuộc qring.
    func testRegistryPrefersSpecificDriver() {
        let registry = DeviceRegistry(drivers: [QRingDriver(), StandardDriver()])
        let ring = ScannedDevice(id: UUID(), name: "R09_8404", rssi: -50, serviceUuids: [CBUUID(string: "180F")],
                                 manufacturerData: ScannedDevice.splitManufacturerData(Data(hex: "3412FEE7303243318404")))
        XCTAssertEqual("qring", registry.classify(ring)?.driver.id)
        let watch = ScannedDevice(id: UUID(), name: "COROS PACE 3", rssi: -60, serviceUuids: [CBUUID(string: "180F")])
        XCTAssertEqual("standard", registry.classify(watch)?.driver.id)
    }
}
