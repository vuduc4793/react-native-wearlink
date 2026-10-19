import CoreBluetooth
import Foundation

/// Kết nối GATT tới một peripheral với hàng đợi tuần tự: mỗi thao tác (đọc, ghi, bật notify) chỉ được
/// gửi khi callback của thao tác trước đã về, có timeout cho từng thao tác. Các peripheral khác nhau
/// chạy song song. Không chứa giao thức của thiết bị cụ thể nào (bản iOS của `GattConnection` Android).
@MainActor
public final class GattConnection: NSObject {
    public let id: UUID
    public private(set) var state: ConnectionState = .disconnected {
        didSet { if oldValue != state { onStateChange?(state) } }
    }

    /// Mỗi gói notify (không phải phản hồi của lệnh đọc đang chờ).
    public var onNotification: ((CBUUID, Data) -> Void)?
    /// Kết nối bị ngắt ngoài ý muốn (sau khi đã CONNECTED).
    public var onDisconnected: ((Error?) -> Void)?
    public var onStateChange: ((ConnectionState) -> Void)?
    /// Mọi gói gửi/nhận và lỗi, cho nhật ký gói tin và LinkStats.
    public var onTraffic: ((TrafficDirection, CBUUID?, Data, String?) -> Void)?
    /// Sự kiện cho dòng thời gian chẩn đoán (link lên, khám phá xong, notify, lỗi có mã…). `WearableDevice.attach` gắn.
    public var onEvent: ((ConnectionEventKind, ConnectionEventLevel, String, BleErrorCode?) -> Void)?
    /// Pha kết nối đổi (link → khám phá → bắt tay → rảnh).
    public var onPhase: ((ConnectPhase) -> Void)?
    /// Rớt kết nối sau khi đã CONNECTED (kèm lỗi iOS gốc), cho chẩn đoán. Khác `onDisconnected` (driver dùng).
    public var onLinkLost: ((Error?) -> Void)?
    public private(set) var phase: ConnectPhase = .idle {
        didSet { if oldValue != phase { onPhase?(phase) } }
    }

    public let operationTimeout: TimeInterval
    /// Nối với `CBConnectPeripheralOptionEnableTransportBridgingKey` (thiết bị hai chế độ có kênh gọi cổ điển).
    public var transportBridging = false
    /// iOS đã cho thiết bị đọc thông báo + cuộc gọi qua ANCS chưa (người dùng đã ghép đôi và bật "Chia sẻ thông báo
    /// hệ thống" trong Cài đặt → Bluetooth). nil khi chưa có peripheral hoặc không phải iOS.
    public var ancsAuthorized: Bool? {
        #if os(iOS)
        return peripheral?.ancsAuthorized
        #else
        return nil
        #endif
    }
    private let central: BleCentral
    private var peripheral: CBPeripheral?
    private let queue = AsyncLock()

    private var connectShot: OneShot<Void>?
    private var linkStarted: Date?
    private var discoverShot: OneShot<Void>?
    private var pendingCharacteristicDiscoveries = 0
    private var pending: Pending?
    private var writeReadyShot: OneShot<Void>?
    private var rssiShot: OneShot<Int>?
    /// Characteristic đã bật notify kiểu không chờ (`wait: false`) mà chưa có xác nhận.
    private var unconfirmedNotify: Set<CBUUID> = []
    /// Characteristic đã xác nhận notify chạy: callback `didUpdateNotificationState` thành công hoặc đã nhận gói notify.
    public private(set) var confirmedNotify: Set<CBUUID> = []

    private enum Kind: String { case read = "Đọc", write = "Ghi", notify = "Bật notify" }
    private struct Pending {
        let kind: Kind
        let uuid: CBUUID
        let shot: OneShot<Data>
    }

    public init(id: UUID, central: BleCentral? = nil, operationTimeout: TimeInterval = 5) {
        self.id = id
        self.central = central ?? .shared
        self.operationTimeout = operationTimeout
        super.init()
    }

    // MARK: - Kết nối

    /// Giới hạn pha nối link (từ `connect` tới khi iOS báo đã nối). nil = không giới hạn: CoreBluetooth giữ yêu cầu
    /// kết nối chờ (kể cả khi app ở nền) và nối ngay khi thiết bị quảng bá lại / được điện thoại khác nhả ra.
    /// `DeviceManager` để nil cho các lần tự nối lại, 40 s cho lần kết nối người dùng bấm.
    public var linkTimeout: TimeInterval? = 40
    /// Giới hạn pha khám phá service sau khi đã nối link. Các thao tác sau đó có `operationTimeout` riêng.
    public var discoveryTimeout: TimeInterval = 20

    /// Kết nối (pha link giới hạn bởi `linkTimeout`), khám phá toàn bộ service + characteristic
    /// (giới hạn bởi `discoveryTimeout`). Ném `GattError` nếu thất bại / hết giờ.
    public func connect() async throws {
        guard state == .disconnected else { throw GattError.operationFailed("Kết nối", "đang ở trạng thái \(state.rawValue)") }
        let linkLimit = linkTimeout
        try await central.waitUntilPoweredOn(timeout: 10)
        guard let p = central.peripheral(id) else { throw GattError.peripheralNotFound }
        peripheral = p
        p.delegate = self
        central.register(self, for: id)
        unconfirmedNotify = []
        confirmedNotify = []
        state = .connecting
        let connected = OneShot<Void>()
        connectShot = connected
        let started = Date()
        linkStarted = started
        phase = .link
        do {
            central.connect(p, transportBridging: transportBridging)
            // CoreBluetooth không tự hết giờ khi kết nối: chỉ đặt watchdog nếu có giới hạn.
            try await connected.wait(timeout: linkLimit) {
                self.event(.link, .error, "Hết \(Int(linkLimit ?? 0)) s chờ nối link")
                return GattError.timeout("kết nối (\(Int(linkLimit ?? 0)) s), thiết bị không quảng bá hoặc đang nối với máy khác")
            }
            phase = .discovery
            let discovered = OneShot<Void>()
            discoverShot = discovered
            p.discoverServices(nil)
            try await discovered.wait(timeout: discoveryTimeout) {
                self.event(.discovery, .error, "Hết \(Int(self.discoveryTimeout)) s chờ khám phá service")
                return GattError.timeout("khám phá service (\(Int(self.discoveryTimeout)) s)")
            }
            state = .connected
            phase = .setup
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            traffic(.info, nil, Data(), "Đã kết nối, \(p.services?.count ?? 0) service, \(ms) ms")
            event(.discovery, .info, "Khám phá xong \(p.services?.count ?? 0) service (\(ms) ms từ lúc nối)")
            SmartWearLog.i("Đã kết nối \(id) (\(p.name ?? "?")) sau \(ms) ms")
        } catch {
            abort(error)
            throw error
        }
    }

    /// Ngắt kết nối. Gọi được nhiều lần.
    public func disconnect() {
        guard state != .disconnected else { return }
        state = .disconnecting
        onDisconnected = nil
        abort(GattError.disconnected)
    }

    public var services: [CBService] { peripheral?.services ?? [] }

    public func hasService(_ service: CBUUID) -> Bool { find(service) != nil }

    public func hasCharacteristic(_ service: CBUUID, _ characteristic: CBUUID) -> Bool {
        find(service)?.characteristics?.contains { $0.uuid == characteristic } ?? false
    }

    /// Kích thước ghi tối đa (iOS tự thương lượng MTU).
    public func maximumWriteLength(withResponse: Bool) -> Int {
        peripheral?.maximumWriteValueLength(for: withResponse ? .withResponse : .withoutResponse) ?? 20
    }

    // MARK: - Thao tác GATT (tuần tự)

    public func read(_ service: CBUUID, _ characteristic: CBUUID) async throws -> Data {
        try await enqueue(.read, service, characteristic) { p, ch in p.readValue(for: ch) }
    }

    /// Bật/tắt notify. `wait: true` (mặc định) chờ `didUpdateNotificationState`, lỗi/hết giờ thì ném lỗi.
    /// `wait: false` bắn rồi quên như app QRing iOS: gửi `setNotifyValue` rồi trả về ngay (CoreBluetooth vẫn xếp
    /// thao tác ATT theo thứ tự nên lệnh ghi sau đó đi sau CCCD). Callback đến muộn, lỗi hoặc không đến chỉ ghi log;
    /// callback thành công hoặc gói notify đầu tiên được coi là xác nhận (`confirmedNotify`).
    /// Chỉ ném lỗi khi không có characteristic / không hỗ trợ notify / chưa kết nối.
    public func setNotify(_ service: CBUUID, _ characteristic: CBUUID, enabled: Bool = true, wait: Bool = true) async throws {
        let start: (CBPeripheral, CBCharacteristic) throws -> Void = { p, ch in
            guard ch.properties.contains(.notify) || ch.properties.contains(.indicate) else {
                throw GattError.operationFailed("Bật notify", "\(characteristic.short) không hỗ trợ notify")
            }
            p.setNotifyValue(enabled, for: ch)
        }
        let what = "\(enabled ? "Bật" : "Tắt") notify \(characteristic.short)"
        guard !wait else {
            do {
                _ = try await enqueue(.notify, service, characteristic, start)
            } catch {
                event(.notify, .error, "\(what): \(error.localizedDescription)", BleErrorCode(error))
                throw error
            }
            if enabled { confirmedNotify.insert(characteristic) } else { confirmedNotify.remove(characteristic) }
            event(.notify, .info, "\(what) OK")
            return
        }
        try await queue.withLock {
            let (p, ch) = try resolve(service, characteristic)
            do {
                try start(p, ch)
            } catch {
                traffic(.error, characteristic, Data(), error.localizedDescription)
                event(.notify, .error, "\(what): \(error.localizedDescription)")
                throw error
            }
            if enabled {
                noteNotifyRequested(characteristic)
                event(.notify, .info, "\(what) (không chờ xác nhận)")
            }
        }
    }

    /// Đã xác nhận notify của `characteristic` chạy chưa (xem `setNotify(wait:)`).
    public func isNotifyConfirmed(_ characteristic: CBUUID) -> Bool { confirmedNotify.contains(characteristic) }

    func noteNotifyRequested(_ uuid: CBUUID) {
        if !confirmedNotify.contains(uuid) { unconfirmedNotify.insert(uuid) }
    }

    /// Callback `didUpdateNotificationState` của lần bật không chờ. Không bao giờ ném lỗi hay ngắt kết nối.
    func notifyStateDidUpdate(_ uuid: CBUUID, error: Error?) {
        if let error {
            let msg = "Bật notify \(uuid.short) lỗi (bỏ qua, chờ gói notify): \(error.localizedDescription)"
            SmartWearLog.w(msg)
            traffic(.error, uuid, Data(), msg)
            event(.notify, .warning, msg, BleErrorCode(error))
            return
        }
        confirmNotify(uuid, via: "callback")
    }

    /// Nhận gói notify: coi như notify của characteristic đó đã chạy.
    func noteNotification(_ uuid: CBUUID) {
        guard unconfirmedNotify.contains(uuid) else { return }
        confirmNotify(uuid, via: "gói notify đầu tiên")
    }

    private func confirmNotify(_ uuid: CBUUID, via: String) {
        guard unconfirmedNotify.remove(uuid) != nil else { return }
        confirmedNotify.insert(uuid)
        traffic(.info, uuid, Data(), "Notify \(uuid.short) đã chạy (\(via))")
        event(.notify, .info, "Notify \(uuid.short) đã chạy (\(via))")
    }

    /// Characteristic báo có `.write` nhưng thiết bị từ chối ghi có phản hồi (ATT 3): từ đó ghi không phản hồi.
    /// Y25 làm vậy với 34F1 (đo trên Android 19/10/2026: mọi lần ghi có phản hồi trả status 3).
    private var writeWithoutResponseOnly: Set<CBUUID> = []

    /// Ghi. `withResponse` sẽ tự chuyển sang không phản hồi nếu characteristic chỉ hỗ trợ kiểu đó, hoặc thiết bị từ chối
    /// ghi có phản hồi (ATT 3, "write not permitted") mà characteristic có ghi không phản hồi.
    public func write(_ service: CBUUID, _ characteristic: CBUUID, _ value: Data, withResponse: Bool = true) async throws {
        do {
            try await writeOnce(service, characteristic, value, withResponse: withResponse)
        } catch {
            guard withResponse, BleErrorCode(error).map({ $0.domain == .att && $0.code == 3 }) == true,
                  (try? resolve(service, characteristic))?.1.properties.contains(.writeWithoutResponse) == true
            else { throw error }
            writeWithoutResponseOnly.insert(characteristic)
            event(.failure, .warning, "\(characteristic.short) từ chối ghi có phản hồi, chuyển sang ghi không phản hồi")
            try await writeOnce(service, characteristic, value, withResponse: false)
        }
    }

    private func writeOnce(_ service: CBUUID, _ characteristic: CBUUID, _ value: Data, withResponse requested: Bool) async throws {
        try await queue.withLock {
            let (p, ch) = try resolve(service, characteristic)
            let props = ch.properties
            let withResponse = requested && !writeWithoutResponseOnly.contains(characteristic)
            let useResponse = withResponse ? props.contains(.write) || !props.contains(.writeWithoutResponse)
                                           : !props.contains(.writeWithoutResponse) && props.contains(.write)
            traffic(.tx, characteristic, value, nil)
            do {
                if useResponse {
                    let shot = OneShot<Data>()
                    pending = Pending(kind: .write, uuid: characteristic, shot: shot)
                    defer { pending = nil }
                    p.writeValue(value, for: ch, type: .withResponse)
                    _ = try await shot.wait(timeout: operationTimeout) { GattError.timeout("ghi \(characteristic.short)") }
                } else {
                    if !p.canSendWriteWithoutResponse {
                        let ready = OneShot<Void>()
                        writeReadyShot = ready
                        defer { writeReadyShot = nil }
                        try await ready.wait(timeout: operationTimeout) { GattError.timeout("chờ ghi không phản hồi") }
                    }
                    p.writeValue(value, for: ch, type: .withoutResponse)
                }
            } catch {
                traffic(.error, characteristic, Data(), error.localizedDescription)
                // Chỉ đưa lên dòng thời gian lỗi có mã ATT (vd cần mã hoá), không phải mọi lần ghi hết giờ.
                if let code = BleErrorCode(error) { event(.failure, .error, "Ghi \(characteristic.short): \(code.meaning)", code) }
                throw error
            }
        }
    }

    /// Đọc RSSI kết nối (không đi qua hàng đợi vì không chặn thao tác khác).
    public func readRSSI() async throws -> Int {
        guard state == .connected, let p = peripheral else { throw GattError.notConnected }
        if rssiShot != nil { throw GattError.operationFailed("Đọc RSSI", "đang đọc") }
        let shot = OneShot<Int>()
        rssiShot = shot
        defer { if rssiShot === shot { rssiShot = nil } }
        p.readRSSI()
        return try await shot.wait(timeout: operationTimeout) { GattError.timeout("đọc RSSI") }
    }

    private func enqueue(
        _ kind: Kind, _ service: CBUUID, _ characteristic: CBUUID,
        _ start: (CBPeripheral, CBCharacteristic) throws -> Void
    ) async throws -> Data {
        try await queue.withLock {
            let (p, ch) = try resolve(service, characteristic)
            let shot = OneShot<Data>()
            pending = Pending(kind: kind, uuid: characteristic, shot: shot)
            defer { pending = nil }
            do {
                try start(p, ch)
                return try await shot.wait(timeout: operationTimeout) {
                    GattError.timeout("\(kind.rawValue.lowercased()) \(characteristic.short)")
                }
            } catch {
                traffic(.error, characteristic, Data(), error.localizedDescription)
                if kind != .notify, let code = BleErrorCode(error) {
                    event(.failure, .error, "\(kind.rawValue) \(characteristic.short): \(code.meaning)", code)
                }
                throw error
            }
        }
    }

    private func resolve(_ service: CBUUID, _ characteristic: CBUUID) throws -> (CBPeripheral, CBCharacteristic) {
        guard state == .connected || state == .connecting, let p = peripheral else { throw GattError.notConnected }
        guard let s = find(service) else { throw GattError.serviceNotFound(service.short) }
        guard let ch = s.characteristics?.first(where: { $0.uuid == characteristic }) else {
            throw GattError.characteristicNotFound(characteristic.short)
        }
        return (p, ch)
    }

    private func find(_ service: CBUUID) -> CBService? {
        peripheral?.services?.first { $0.uuid == service }
    }

    private func event(_ kind: ConnectionEventKind, _ level: ConnectionEventLevel, _ message: String, _ code: BleErrorCode? = nil) {
        onEvent?(kind, level, message, code)
    }

    /// Driver ghi một bước bắt tay lên dòng thời gian chẩn đoán (vd "0x01 SetTime OK").
    public func noteStep(_ message: String, level: ConnectionEventLevel = .info) {
        event(.handshake, level, message)
    }

    private func traffic(_ d: TrafficDirection, _ uuid: CBUUID?, _ data: Data, _ note: String?) {
        if d == .tx || d == .rx { SmartWearLog.v("\(d == .tx ? "->" : "<-") \(uuid?.short ?? "") \(data.hex)") }
        onTraffic?(d, uuid, data, note)
    }

    // MARK: - Sự kiện từ BleCentral

    func didConnect() {
        guard let shot = connectShot, !shot.isCompleted else { return }
        let ms = linkStarted.map { Int(Date().timeIntervalSince($0) * 1000) }
        event(.link, .info, "Link lên" + (ms.map { " sau \($0) ms" } ?? ""))
        shot.succeed(())
    }

    func didFailToConnect(_ error: Error?) {
        let wrapped = GattError.wrap("Kết nối", error)
        event(.link, .error, "iOS báo nối link thất bại: \(wrapped.localizedDescription)", BleErrorCode(error))
        connectShot?.fail(wrapped)
    }

    func didDisconnect(_ error: Error?) {
        let wasConnected = state == .connected
        let wasConnecting = state == .connecting
        let listener = onDisconnected
        let lost = onLinkLost
        abort(error.map { GattError.wrap("Kết nối", $0) } ?? GattError.disconnected, cancelPeripheral: false)
        let code = BleErrorCode(error)
        let reason = code.map { "\($0.meaning) — \($0.message)" } ?? error?.localizedDescription
        if wasConnected {
            traffic(.error, nil, Data(), "Mất kết nối" + (error.map { ": \($0.localizedDescription)" } ?? ""))
            event(.disconnect, .error, "Mất kết nối" + (reason.map { ": \($0)" } ?? ""), code)
            lost?(error)
            listener?(error)
        } else if wasConnecting {
            event(.disconnect, .error, "Rớt link khi đang kết nối" + (reason.map { ": \($0)" } ?? ""), code)
        }
    }

    func centralLost() {
        guard state != .disconnected else { return }
        didDisconnect(GattError.bluetoothUnavailable("Bluetooth tắt"))
    }

    private func abort(_ error: Error, cancelPeripheral: Bool = true) {
        connectShot?.fail(error)
        discoverShot?.fail(error)
        pending?.shot.fail(error)
        writeReadyShot?.fail(error)
        rssiShot?.fail(error)
        if cancelPeripheral, let p = peripheral { central.cancel(p) }
        state = .disconnected
        phase = .idle
    }
}

extension GattConnection: CBPeripheralDelegate {
    nonisolated public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            if let error {
                event(.discovery, .error, "Khám phá service lỗi: \(error.localizedDescription)", BleErrorCode(error))
                discoverShot?.fail(GattError.wrap("Khám phá service", error))
                return
            }
            let services = peripheral.services ?? []
            pendingCharacteristicDiscoveries = services.count
            if services.isEmpty { discoverShot?.succeed(()) }
            for s in services { peripheral.discoverCharacteristics(nil, for: s) }
        }
    }

    nonisolated public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            if let error { SmartWearLog.w("Khám phá characteristic \(service.uuid.short) lỗi: \(error.localizedDescription)") }
            pendingCharacteristicDiscoveries -= 1
            if pendingCharacteristicDiscoveries <= 0 { discoverShot?.succeed(()) }
        }
    }

    nonisolated public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            let value = characteristic.value ?? Data()
            if let p = pending, p.kind == .read, p.uuid == characteristic.uuid {
                if let error {
                    p.shot.fail(GattError.wrap("Đọc \(characteristic.uuid.short)", error))
                } else {
                    traffic(.rx, characteristic.uuid, value, "đọc")
                    p.shot.succeed(value)
                }
                return
            }
            guard error == nil else { return }
            traffic(.rx, characteristic.uuid, value, nil)
            noteNotification(characteristic.uuid)
            onNotification?(characteristic.uuid, value)
        }
    }

    nonisolated public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard let p = pending, p.kind == .write, p.uuid == characteristic.uuid else { return }
            if let error {
                p.shot.fail(GattError.wrap("Ghi \(characteristic.uuid.short)", error))
            } else {
                p.shot.succeed(Data())
            }
        }
    }

    nonisolated public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard let p = pending, p.kind == .notify, p.uuid == characteristic.uuid else {
                // Lần bật không chờ (`wait: false`): chỉ ghi nhận.
                if unconfirmedNotify.contains(characteristic.uuid) { notifyStateDidUpdate(characteristic.uuid, error: error) }
                return
            }
            if let error {
                p.shot.fail(GattError.wrap("Bật notify \(characteristic.uuid.short)", error))
            } else {
                p.shot.succeed(Data())
            }
        }
    }

    nonisolated public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        MainActor.assumeIsolated { writeReadyShot?.succeed(()) }
    }

    nonisolated public func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        MainActor.assumeIsolated {
            if let error {
                rssiShot?.fail(GattError.operationFailed("Đọc RSSI", error.localizedDescription))
            } else {
                rssiShot?.succeed(RSSI.intValue)
            }
        }
    }

    nonisolated public func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        MainActor.assumeIsolated {
            traffic(.info, nil, Data(), "Thiết bị đổi bảng service (\(invalidatedServices.count))")
        }
    }
}
