import CoreBluetooth
import Foundation
import SmartWearCore

/// Driver QRing cho `DeviceRegistry`.
public struct QRingDriver: DeviceDriver {
    public let id = "qring"
    public let displayName = "QRing"
    /// Báo nhẫn/vòng đây là iPhone (`04 01`) để nhận thông báo; làm thiết bị bị iOS ghép đôi và giữ kết nối mãi.
    /// Mặc định tắt (xem `QRingClient.phoneInfoPacket`).
    @MainActor public static var iosNotifications = false
    /// Nhẫn/vòng đang được iOS giữ kết nối (app khác, hoặc lần chạy trước) không quảng bá; tìm qua dịch vụ của nó.
    /// Cùng danh sách app QRing iOS truyền cho `retrieveConnectedPeripherals`: FEE7, 6E40FFF0, DE5BF728.
    public var systemServices: [CBUUID] { [QRing.advertisedService, QRing.service, QRing.bigDataService] }
    /// App QRing iOS cancel+connect lại mỗi 4 s, không giới hạn: lùi 2 s rồi giữ 4 s thay vì lên tới 60 s.
    public var reconnectBackoff: [TimeInterval]? { [2, 4] }

    public init() {}

    public func match(_ scanned: ScannedDevice) -> DriverMatch? {
        guard QRing.matches(scanned) else { return nil }
        return DriverMatch(
            driverId: id, model: scanned.name, kind: QRing.guessKind(scanned.name), supported: true,
            mac: QRing.macFromAdvertisement(scanned)
        )
    }

    @MainActor
    public func create(_ scanned: ScannedDevice, match: DriverMatch) -> WearableDevice {
        QRingDevice(scanned: scanned, match: match)
    }
}

/// Một thiết bị QRing được quản lý: bắt tay, pin, đo thủ công theo bảng khả năng của chính nó.
@MainActor
public final class QRingDevice: WearableDevice {
    public let client: QRingClient
    private let match: DriverMatch
    private var eventToken: UUID?
    /// Cài đặt đọc từ thiết bị (`QRingSettings`).
    private var settingValues: [String: Int] = [:]

    public init(scanned: ScannedDevice, match: DriverMatch) {
        client = QRingClient(id: scanned.id)
        self.match = match
        super.init(
            id: scanned.id, driverId: "qring", name: scanned.name ?? "QRing",
            kind: match.kind, mac: match.mac
        )
        attach(client.gatt)
        client.onLatency = { [weak self] start in self?.recordLatency(since: start) }
    }

    public var qringInfo: QRingDeviceInfo? { client.deviceInfo }

    override public var measurableCapabilities: [Capability] {
        let order: [Capability] = [.heartRate, .spo2, .temperature, .bloodPressure, .stress, .hrv]
        return order.filter { capabilities.contains($0) && $0.measurementType != nil }
    }

    override public var supportsHistory: Bool { true }

    /// Trình tự đồng bộ ở `QRingHistory.swift`.
    override public func syncHistoryImpl(days: Int, progress: @escaping @MainActor (SyncProgress) -> Void) async throws -> DeviceHistory {
        try await runHistorySync(days: days, progress: progress)
    }

    override public func connect() async throws {
        guard state == .disconnected else { return }
        state = .connecting
        lastError = nil
        do {
            let qi = try await client.connect()
            client.onDisconnected = { [weak self] error in
                self?.lastError = "Mất kết nối" + (error.map { ": \($0.localizedDescription)" } ?? "")
            }
            let caps = qi.qringCapabilities
            capabilities = qi.capabilities
            if let k = QRing.kind(fromHardware: qi.hardwareRevision) { kind = k }
            if mac == nil, let m = qi.systemIdMac { mac = m }
            var di = DeviceInfo(
                model: Self.model(fromHardware: qi.hardwareRevision) ?? name,
                manufacturer: "QRing (Colmi / Oudmon)",
                hardware: qi.hardwareRevision,
                firmware: qi.firmwareRevision
            )
            di.setExtra("MAC (quảng bá)", match.mac ?? "không có trong quảng bá")
            di.setExtra("MAC (System ID 2A23)", qi.systemIdMac ?? "không đọc được")
            di.setExtra("SetTime 0x01", qi.timeCapabilities.hex)
            di.setExtra("DeviceSupport 0x3C", qi.supportCapabilities.hex)
            di.setExtra("Cờ khả năng", caps.flags.filter(\.on).map(\.name).joined(separator: ", "))
            di.setExtra("Big-data", client.gatt.hasService(QRing.bigDataService) ? "có (de5bf728)" : "không")
            info = di
            if let token = eventToken { client.unsubscribe(token) }
            eventToken = client.subscribe { [weak self] p in self?.onEvent(p) }
            try Task.checkCancellation() // bị huỷ giữa chừng: không đánh dấu đã kết nối
            controls = QRingSettings.controls(caps, settingValues, ring: isRing(caps))
            markConnected()
            Task { await self.loadSettings(caps) }
            do {
                try await refreshBattery()
            } catch {
                record(.error, "", Data(), "Đọc pin lỗi: \(error.localizedDescription)")
            }
        } catch {
            state = .disconnected
            lastError = error is CancellationError ? nil : error.localizedDescription
            throw error
        }
    }

    override public func disconnect() {
        cancelAllMeasurements()
        state = .disconnecting
        // Để lệnh stop đo kịp gửi trước khi ngắt.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            self.client.disconnect()
            self.state = .disconnected
        }
    }

    override public func refreshBattery() async throws {
        let b = try await client.battery()
        battery = b.level
        charging = b.charging
    }

    override public func measure(_ capability: Capability) -> AsyncThrowingStream<Reading, Error> {
        guard let type = capability.measurementType, capabilities.contains(capability) else {
            return super.measure(capability)
        }
        let source = client.measure(type)
        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    for try await r in source { continuation.yield(r.reading) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Gói ring tự gửi. `73 0C xx`: pin thay đổi (sdks/qring/docs/devices.md).
    private func onEvent(_ p: Packet) {
        if p.command == QRingClient.cmdDeviceNotify, p.u8(0) == 0x0C {
            battery = p.u8(1)
        }
        // `22 01` = thiết bị tìm điện thoại, `22 02` = dừng (`FindPhoneRsp`).
        if p.command == 0x22, (1...2).contains(p.u8(0)) { onFindPhone?(p.u8(0) == 1) }
    }

    /// "HS500A_V1.0" → "HS500A", "RT09_V3.1" → "RT09".
    nonisolated static func model(fromHardware hw: String) -> String? {
        let m = hw.split(separator: "_").first.map(String.init)
        return (m?.isEmpty ?? true) ? nil : m
    }
}

// MARK: - Cài đặt

extension QRingDevice: ConfigurableDevice {
    /// Nhẫn: cờ `noScreen` hoặc loại thiết bị (R09 không bật cờ, `QRing.kind(fromHardware:)` nhận ra là nhẫn).
    func isRing(_ caps: QRingCapabilities) -> Bool { caps.noScreen || kind == .ring }

    /// Đọc cài đặt hiện tại trên thiết bị; mục không trả lời giữ mặc định.
    func loadSettings(_ caps: QRingCapabilities) async {
        for req in QRingSettings.reads(caps, ring: isRing(caps)) {
            guard state == .connected else { return }
            if let rsp = try? await client.request(req, timeout: 2) {
                settingValues.merge(QRingSettings.parse(rsp.command, (0..<14).map { rsp.u8($0) })) { $1 }
            }
        }
        controls = QRingSettings.controls(caps, settingValues, ring: isRing(caps))
    }

    public func setControl(_ id: String, _ value: ControlValue) async throws {
        guard let caps = client.deviceInfo?.qringCapabilities else { throw QRingError("Thiết bị chưa kết nối") }
        settingValues = QRingSettings.apply(settingValues, id, value)
        controls = QRingSettings.controls(caps, settingValues, ring: isRing(caps))
        guard state == .connected, let packet = QRingSettings.write(id, settingValues) else { return }
        try await client.sendNoResponse(packet)
    }

    public func runAction(_ id: String) async throws {
        guard state == .connected else { throw QRingError("Thiết bị chưa kết nối") }
        guard id == "find.start" else { return }
        try await client.sendNoResponse(QRingSettings.find)
    }
}
