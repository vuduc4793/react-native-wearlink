import CoreBluetooth
import Foundation
import SmartWearCore

/// Driver cho thiết bị dùng dịch vụ Bluetooth SIG chuẩn: Battery 180F, Device Info 180A, Heart Rate 180D.
/// Nhận diện: quảng bá 180D hoặc 180F. Đặt cuối `DeviceRegistry` để driver cụ thể được ưu tiên.
public struct StandardDriver: DeviceDriver {
    public let id = "standard"
    public let displayName = "Bluetooth chuẩn"

    public init() {}

    public var systemServices: [CBUUID] { [StandardGatt.heartRateService, StandardGatt.batteryService] }

    public func match(_ scanned: ScannedDevice) -> DriverMatch? {
        let hr = scanned.advertises(StandardGatt.heartRateService)
        let battery = scanned.advertises(StandardGatt.batteryService)
        guard hr || battery || scanned.systemConnected else { return nil }
        // Bàn phím/chuột BLE (HID 1812) cũng phát 180F nhưng không phải thiết bị đeo.
        if !hr, scanned.advertises(StandardGatt.humanInterfaceDevice) { return nil }
        return DriverMatch(driverId: id, model: scanned.name, kind: Self.guessKind(scanned.name, heartRate: hr))
    }

    @MainActor
    public func create(_ scanned: ScannedDevice, match: DriverMatch) -> WearableDevice {
        StandardDevice(scanned: scanned, match: match)
    }

    static func guessKind(_ name: String?, heartRate: Bool) -> DeviceKind {
        let n = (name ?? "").lowercased()
        let watches = ["coros", "pace", "watch", "forerunner", "fenix", "garmin", "amazfit", "polar", "suunto", "apex", "vertix"]
        if watches.contains(where: n.contains) { return .watch }
        if ["band", "fit", "mi smart"].contains(where: n.contains) { return .band }
        if ["air", "buds", "pods", "earfun", "headphone", "wh-", "wf-"].contains(where: n.contains) { return .earbuds }
        if heartRate || ["hrm", "h10", "h9", "tickr", "strap"].contains(where: n.contains) { return .sensor }
        return .unknown
    }
}

/// Thiết bị Bluetooth chuẩn: đọc pin + thông tin thiết bị, nhịp tim nếu có service 180D.
@MainActor
public final class StandardDevice: WearableDevice {
    public let gatt: GattConnection
    /// Không có gói nhịp tim nào trong khoảng này thì kết thúc phép đo.
    public var heartRateIdleTimeout: TimeInterval = 12
    private var heartRateHandlers: [UUID: (Data) -> Void] = [:]

    public init(scanned: ScannedDevice, match: DriverMatch) {
        gatt = GattConnection(id: scanned.id)
        super.init(id: scanned.id, driverId: "standard", name: scanned.name ?? "Thiết bị BLE", kind: match.kind)
        if scanned.advertises(StandardGatt.heartRateService) { capabilities = [.heartRate] }
        attach(gatt)
        gatt.onNotification = { [weak self] uuid, data in self?.onNotification(uuid, data) }
    }

    override public var measurableCapabilities: [Capability] {
        capabilities.contains(.heartRate) ? [.heartRate] : []
    }

    override public func connect() async throws {
        guard state == .disconnected else { return }
        state = .connecting
        lastError = nil
        do {
            try await gatt.connect()
            gatt.onDisconnected = { [weak self] error in
                self?.lastError = "Mất kết nối" + (error.map { ": \($0.localizedDescription)" } ?? "")
            }
            info = await readDeviceInfo()
            gatt.noteStep("Đọc Device Info 180A xong")
            // HEART_RATE chỉ khi thiết bị thật sự có service 180D.
            capabilities = gatt.hasService(StandardGatt.heartRateService) ? [.heartRate] : []
            markConnected()
            if gatt.hasCharacteristic(StandardGatt.batteryService, StandardGatt.batteryLevel) {
                do {
                    try await refreshBattery()
                    try await gatt.setNotify(StandardGatt.batteryService, StandardGatt.batteryLevel)
                } catch {
                    record(.error, "2A19", Data(), "Pin: \(error.localizedDescription)")
                }
            }
        } catch {
            gatt.disconnect()
            state = .disconnected
            lastError = error is CancellationError ? nil : error.localizedDescription
            throw error
        }
    }

    override public func disconnect() {
        cancelAllMeasurements()
        state = .disconnecting
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            self.gatt.disconnect()
            self.state = .disconnected
        }
    }

    override public func refreshBattery() async throws {
        let start = Date()
        let data = try await gatt.read(StandardGatt.batteryService, StandardGatt.batteryLevel)
        recordLatency(since: start)
        if let level = data.first { battery = Int(level) }
    }

    override public func measure(_ capability: Capability) -> AsyncThrowingStream<Reading, Error> {
        guard capability == .heartRate, capabilities.contains(.heartRate) else { return super.measure(capability) }
        return AsyncThrowingStream { continuation in
            let token = UUID()
            let lastPacketAt = Box(Date())
            let started = Date()
            let gotFirst = Box(false)
            heartRateHandlers[token] = { [weak self] data in
                guard let hr = HeartRateMeasurement.parse(data) else { return }
                lastPacketAt.value = Date()
                if !gotFirst.value {
                    gotFirst.value = true
                    self?.recordLatency(since: started)
                }
                let notWorn = hr.sensorContact == false
                continuation.yield(Reading(
                    capability: .heartRate,
                    status: notWorn ? .notWorn : (hr.bpm > 0 ? .ok : .measuring),
                    value: !notWorn && hr.bpm > 0 ? Double(hr.bpm) : nil,
                    unit: "bpm",
                    signal: Double(hr.bpm),
                    note: hr.rrIntervalsMs.isEmpty ? nil : "RR " + hr.rrIntervalsMs.map { String(format: "%.0f", $0) }.joined(separator: ", ") + " ms"
                ))
            }
            let starter = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await self.gatt.setNotify(StandardGatt.heartRateService, StandardGatt.heartRateMeasurement)
                    lastPacketAt.value = Date()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            let idle = heartRateIdleTimeout
            let watchdog = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if Date().timeIntervalSince(lastPacketAt.value) > idle {
                        continuation.finish(throwing: GattError.operationFailed(
                            "Đo nhịp tim",
                            gotFirst.value ? "thiết bị ngừng gửi" : "thiết bị không gửi nhịp tim (bật chế độ phát nhịp tim trên thiết bị)"
                        ))
                        return
                    }
                }
            }
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    starter.cancel()
                    watchdog.cancel()
                    guard let self else { return }
                    self.heartRateHandlers[token] = nil
                    if self.heartRateHandlers.isEmpty, self.gatt.state == .connected {
                        try? await self.gatt.setNotify(StandardGatt.heartRateService, StandardGatt.heartRateMeasurement, enabled: false)
                    }
                }
            }
        }
    }

    override public var supportsHeartRateStream: Bool { capabilities.contains(.heartRate) }

    /// Mỗi gói 2A37 một mẫu (thường 1 s/lần), kèm RR và tiếp xúc da nếu dây đo gửi. Im lặng quá `heartRateIdleTimeout` ⇒ lỗi.
    override public func heartRateStream() -> AsyncThrowingStream<HeartRateSample, Error> {
        guard supportsHeartRateStream else { return super.heartRateStream() }
        return AsyncThrowingStream { continuation in
            let token = UUID()
            let lastPacketAt = Box(Date())
            heartRateHandlers[token] = { data in
                guard let hr = HeartRateMeasurement.parse(data) else { return }
                lastPacketAt.value = Date()
                continuation.yield(HeartRateSample(
                    bpm: hr.bpm > 0 ? hr.bpm : nil, rrMs: hr.rrIntervalsMs.map { Int($0.rounded()) }, contact: hr.sensorContact
                ))
            }
            let starter = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await self.gatt.setNotify(StandardGatt.heartRateService, StandardGatt.heartRateMeasurement)
                    lastPacketAt.value = Date()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            let idle = heartRateIdleTimeout
            let watchdog = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if Date().timeIntervalSince(lastPacketAt.value) > idle {
                        continuation.finish(throwing: GattError.operationFailed("Nhịp tim liên tục", "thiết bị ngừng gửi"))
                        return
                    }
                }
            }
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    starter.cancel()
                    watchdog.cancel()
                    guard let self else { return }
                    self.heartRateHandlers[token] = nil
                    if self.heartRateHandlers.isEmpty, self.gatt.state == .connected {
                        try? await self.gatt.setNotify(StandardGatt.heartRateService, StandardGatt.heartRateMeasurement, enabled: false)
                    }
                }
            }
        }
    }

    private func onNotification(_ uuid: CBUUID, _ data: Data) {
        switch uuid {
        case StandardGatt.batteryLevel:
            if let level = data.first { battery = Int(level) }
        case StandardGatt.heartRateMeasurement:
            for h in heartRateHandlers.values { h(data) }
        default:
            break
        }
    }

    private func readDeviceInfo() async -> DeviceInfo {
        var di = DeviceInfo()
        let s = StandardGatt.deviceInfoService
        func read(_ c: CBUUID) async -> String? {
            guard gatt.hasCharacteristic(s, c) else { return nil }
            guard let data = try? await gatt.read(s, c) else { return nil }
            let str = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
            return str.isEmpty ? nil : str
        }
        di.model = await read(StandardGatt.modelNumber)
        di.manufacturer = await read(StandardGatt.manufacturerName)
        di.firmware = await read(StandardGatt.firmwareRevision)
        di.hardware = await read(StandardGatt.hardwareRevision)
        di.software = await read(StandardGatt.softwareRevision)
        di.setExtra("Serial", await read(StandardGatt.serialNumber))
        if gatt.hasCharacteristic(StandardGatt.heartRateService, StandardGatt.bodySensorLocation),
           let loc = try? await gatt.read(StandardGatt.heartRateService, StandardGatt.bodySensorLocation), let v = loc.first {
            di.setExtra("Vị trí cảm biến", bodySensorLocationName(v))
        }
        di.setExtra("Service", gatt.services.map(\.uuid.short).joined(separator: ", "))
        return di
    }
}
