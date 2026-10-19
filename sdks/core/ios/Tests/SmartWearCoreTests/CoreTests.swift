import CoreBluetooth
import XCTest
@testable import SmartWearCore

final class CoreTests: XCTestCase {
    func testCapabilityNamesMatchAndroid() {
        XCTAssertEqual(
            ["HEART_RATE", "SPO2", "TEMPERATURE", "BLOOD_PRESSURE", "STRESS", "HRV", "BLOOD_SUGAR", "ECG",
             "STEPS", "SLEEP", "MENSTRUATION", "GESTURE", "MET", "URIC_ACID", "BLOOD_LIPIDS", "BODY_COMPOSITION"],
            Capability.allCases.map(\.rawValue)
        )
        XCTAssertEqual(.heartRate, Capability(name: "heart_rate"))
        XCTAssertEqual(.bloodPressure, Capability(name: "BLOOD_PRESSURE"))
        XCTAssertNil(Capability(name: "foo"))
        XCTAssertEqual(.uricAcid, Capability(name: "uric_acid"))
        XCTAssertEqual(.bodyComposition, Capability(name: "BODY_COMPOSITION"))
    }

    func testReadingExtraAndAlarm() {
        let r = Reading(capability: .bloodLipids, status: .ok, value: 4.2, unit: "mmol/L", extra: ["hdl": 1.3])
        XCTAssertEqual(1.3, r.extra["hdl"])
        XCTAssertTrue(Reading(capability: .heartRate, status: .ok, value: 70, unit: "bpm").extra.isEmpty)
        let a = Alarm(hour: 7, minute: 30, repeatDays: Alarm.weekdays, label: "Dậy")
        XCTAssertEqual(-1, a.id)
        XCTAssertTrue(a.enabled)
        XCTAssertEqual(0x1F, Alarm.monday | Alarm.tuesday | Alarm.wednesday | Alarm.thursday | Alarm.friday)
        XCTAssertEqual(0x7F, Alarm.everyDay)
    }

    @MainActor
    func testAlarmDefaultsUnsupported() async {
        let d = WearableDevice(id: UUID(), driverId: "x", name: "x", kind: .band)
        XCTAssertFalse(d.supportsAlarms)
        XCTAssertEqual(0, d.maxAlarms)
        do {
            _ = try await d.alarms()
            XCTFail("phải ném lỗi")
        } catch {}
    }

    func testManufacturerDataSplit() {
        let m = ScannedDevice.splitManufacturerData(Data(hex: "3412 FEE7 3032")!)
        XCTAssertEqual(Data([0xFE, 0xE7, 0x30, 0x32]), m[0x1234])
        XCTAssertTrue(ScannedDevice.splitManufacturerData(Data([0x01])).isEmpty)
    }

    func testHex() {
        XCTAssertEqual("01 AB FF", Data([0x01, 0xAB, 0xFF]).hex)
        XCTAssertEqual(Data([0x01, 0xAB]), Data(hex: "01ab"))
        XCTAssertNil(Data(hex: "0"))
    }

    func testPacketRateSlidingWindow() {
        var w = PacketRateWindow(window: 5)
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(0, w.rate(now: t0))
        // 2 gói/giây trong 10 s
        for i in 0..<20 { w.record(at: t0.addingTimeInterval(Double(i) * 0.5)) }
        let now = t0.addingTimeInterval(10)
        XCTAssertEqual(2.0, w.rate(now: now), accuracy: 0.21)
        // im lặng 6 s → 0
        w.prune(now: now.addingTimeInterval(6))
        XCTAssertEqual(0, w.rate(now: now.addingTimeInterval(6)))
    }

    func testPacketRateFirstSecondsUseElapsedTime() {
        var w = PacketRateWindow(window: 5)
        let t0 = Date(timeIntervalSince1970: 0)
        for i in 0..<4 { w.record(at: t0.addingTimeInterval(Double(i) * 0.5)) }
        // 4 gói trong 2 s đầu → 2 gói/s, không chia cho 5
        XCTAssertEqual(2.0, w.rate(now: t0.addingTimeInterval(2)), accuracy: 0.01)
    }

    func testDeviceInfoExtra() {
        var info = DeviceInfo()
        info.setExtra("A", "1")
        info.setExtra("A", "2")
        info.setExtra("B", nil)
        XCTAssertEqual("2", info.extra("A"))
        XCTAssertEqual(1, info.extra.count)
    }

    @MainActor
    func testOneShotTimeoutAndAsyncLockOrder() async throws {
        let shot = OneShot<Int>()
        do {
            _ = try await shot.wait(timeout: 0.05) { GattError.timeout("x") }
            XCTFail("phải hết giờ")
        } catch let e as GattError {
            XCTAssertEqual(.timeout("x"), e)
        }
        let ok = OneShot<Int>()
        Task { @MainActor in ok.succeed(7) }
        let v = try await ok.wait(timeout: 1)
        XCTAssertEqual(7, v)

        let lock = AsyncLock()
        var order: [Int] = []
        await withTaskGroup(of: Void.self) { g in
            for i in 0..<5 {
                g.addTask { @MainActor in
                    await lock.withLock {
                        order.append(i)
                        try? await Task.sleep(nanoseconds: 5_000_000)
                        order.append(i)
                    }
                }
            }
        }
        // Không xen kẽ: mỗi cặp (vào, ra) liền nhau.
        for k in stride(from: 0, to: order.count, by: 2) { XCTAssertEqual(order[k], order[k + 1]) }
    }

    /// Notify kiểu không chờ (QRing): callback lỗi đến muộn chỉ ghi log, không ném / không ngắt; gói notify
    /// đầu tiên là xác nhận.
    @MainActor
    func testTolerantNotifyCallbackNeverFails() async {
        let gatt = GattConnection(id: UUID())
        let ch = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")
        var errors: [String] = []
        gatt.onTraffic = { d, _, _, note in if d == .error { errors.append(note ?? "") } }
        gatt.noteNotifyRequested(ch)
        XCTAssertFalse(gatt.isNotifyConfirmed(ch))
        gatt.notifyStateDidUpdate(ch, error: GattError.timeout("bật notify"))
        XCTAssertEqual(.disconnected, gatt.state, "không đổi trạng thái / không abort")
        XCTAssertFalse(gatt.isNotifyConfirmed(ch))
        XCTAssertEqual(1, errors.count)
        gatt.noteNotification(ch)
        XCTAssertTrue(gatt.isNotifyConfirmed(ch))
        // Callback thành công đến sau: không ghi nhận hai lần.
        gatt.notifyStateDidUpdate(ch, error: nil)
        XCTAssertEqual([ch], gatt.confirmedNotify)
        // Chưa kết nối: bật notify không chờ vẫn báo lỗi rõ (không có peripheral).
        do {
            try await gatt.setNotify(CBUUID(string: "6E40FFF0-B5A3-F393-E0A9-E50E24DCCA9E"), ch, wait: false)
            XCTFail("phải ném notConnected")
        } catch {
            XCTAssertEqual(GattError.notConnected, error as? GattError)
        }
    }
}

