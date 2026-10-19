import SmartWearCore
import SmartWearQRing
import SwiftUI

/// Chế độ `-demo YES` (máy ảo không có Bluetooth): nạp thiết bị mẫu để xem giao diện. Mọi con số là số đo
/// THẬT đã ghi lại (sdks/qring/docs/devices.md, kết nối COROS ngày 2026-10-13), có nhãn "Dữ liệu mẫu".
@MainActor
final class DemoDevice: WearableDevice {
    private let caps: [Capability]

    init(name: String, driverId: String, kind: DeviceKind, mac: String?, caps: [Capability]) {
        self.caps = caps
        super.init(id: UUID(), driverId: driverId, name: name, kind: kind, mac: mac)
    }

    override var measurableCapabilities: [Capability] { caps }
    override func connect() async throws { markConnected() }
    override func disconnect() { state = .disconnected }

    override func measure(_ capability: Capability) -> AsyncThrowingStream<Reading, Error> {
        AsyncThrowingStream { $0.finish(throwing: GattError.operationFailed("Đo", "dữ liệu mẫu, không có Bluetooth")) }
    }

    func set(_ r: Reading, trail values: [Double] = []) {
        latest[r.capability] = r
        if r.status == .ok { lastResult[r.capability] = r }
        if !values.isEmpty { trail[r.capability] = values }
    }
}

@MainActor
enum DemoData {
    static var isOn: Bool { UserDefaults.standard.bool(forKey: "demo") }

    private static func hex(_ s: String) -> [UInt8] { s.split(separator: " ").map { UInt8($0, radix: 16)! } }

    static func load(into app: AppState) {
        let r09Caps = QRingCapabilities(
            timeCaps: hex("01 00 00 02 00 00 00 00 01 00 20 00 00 30"),
            supportCaps: hex("00 AC 27 00 00 00 00 00 00 00 00 00 00 00")
        )
        let r09 = DemoDevice(name: "R09_8404", driverId: "qring", kind: .ring, mac: "30:32:43:31:84:04",
                             caps: [.heartRate, .spo2, .temperature, .stress, .hrv])
        r09.capabilities = r09Caps.toCapabilities()
        r09.battery = 19
        r09.info = DeviceInfo(model: "RT09", manufacturer: "QRing (Colmi / Oudmon)", hardware: "RT09_V3.1",
                              firmware: "RT09_3.10.22_260420",
                              extra: [("SetTime 0x01", r09Caps.timeCaps.hex), ("DeviceSupport 0x3C", r09Caps.supportCaps.hex),
                                      ("Cờ khả năng", r09Caps.flags.filter(\.on).map(\.name).joined(separator: ", "))])
        // Kết quả 79–82 bpm (devices.md).
        r09.set(Reading(capability: .heartRate, status: .ok, value: 82, unit: "bpm"), trail: [79, 80, 82, 81, 82, 80, 79, 81, 82, 82])
        r09.set(Reading(capability: .spo2, status: .ok, value: 98, unit: "%"))
        r09.set(Reading(capability: .temperature, status: .ok, value: 36.6, unit: "°C"))
        r09.stats.rssi = -72
        r09.stats.packetsReceived = 61
        r09.stats.packetsPerSecond = 2
        r09.stats.lastLatencyMs = 180

        let hsCaps = QRingCapabilities(
            timeCaps: hex("00 00 01 16 00 00 00 00 01 00 20 00 00 30"),
            supportCaps: hex("00 40 00 A0 00 00 08 30 00 00 00 00 00 00")
        )
        let hs = DemoDevice(name: "HS500A", driverId: "qring", kind: .band, mac: "32:35:45:37:4E:00",
                            caps: [.heartRate, .spo2, .bloodPressure, .stress, .hrv])
        hs.capabilities = hsCaps.toCapabilities()
        hs.info = DeviceInfo(model: "HS500A", manufacturer: "QRing (Colmi / Oudmon)", hardware: "HS500A_V1.0",
                             firmware: "HS500A_1.00.05_260725",
                             extra: [("SetTime 0x01", hsCaps.timeCaps.hex), ("DeviceSupport 0x3C", hsCaps.supportCaps.hex)])
        hs.set(Reading(capability: .heartRate, status: .notWorn, unit: "bpm", errorCode: 1))
        hs.stats.rssi = -64

        let coros = DemoDevice(name: "COROS PACE 3 8E1086", driverId: "standard", kind: .watch, mac: nil, caps: [.heartRate])
        coros.capabilities = [.heartRate]
        coros.battery = 42
        coros.info = DeviceInfo(model: "COROS W331", hardware: "W31BV77075", software: "V 3.0510.0",
                                extra: [("Serial", "2F22098E367C"), ("Service", "180F, 180A, 6E400001, 180D, FEE7, 1814, 3802")])
        coros.stats.rssi = -78
        coros.stats.packetsReceived = 5
        coros.stats.lastLatencyMs = 297

        for d in [r09, hs, coros] {
            d.markConnected()
            app.manager.adopt(d)
        }
        if UserDefaults.standard.bool(forKey: "demoDetail") { app.open(r09) }
        if let tab = UserDefaults.standard.string(forKey: "demoTab"), let t = AppTab(rawValue: tab) { app.tab = t }
    }
}

/// Nhãn nhắc đây là dữ liệu mẫu.
struct DemoBadge: View {
    var body: some View {
        Text("Dữ liệu mẫu")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .glassCapsule(tint: .orange.opacity(0.35), interactive: false)
            .fixedSize()
    }
}
