import CoreBluetooth
import Foundation
import Observation

/// Một thiết bị thấy khi quét, đã được phân loại theo driver.
public struct DiscoveredDevice: Identifiable, Sendable {
    public var scanned: ScannedDevice
    public var driverId: String
    public var match: DriverMatch
    public var lastSeen: Date

    public var id: UUID { scanned.id }
    public var displayName: String { match.model ?? scanned.name ?? "Thiết bị BLE" }
}

/// Quét, giữ danh sách thiết bị, kết nối song song nhiều thiết bị (giới hạn mềm `maxConnections`),
/// "đo đồng loạt" một capability trên mọi thiết bị hỗ trợ. Cùng vai trò với `DeviceManager` Android:
///
/// - Thiết bị đã thêm được lưu (`KnownDeviceStore`): UUID CoreBluetooth, driver, tên, model, cờ giữ kết nối.
/// - `start()` dựng lại chúng không cần quét; khi Bluetooth bật thì `retrievePeripherals` và nối lại cái đang giữ.
/// - Giữ kết nối: kết nối lỗi hoặc mất kết nối ngoài ý muốn thì thử lại, lùi dần 2/5/10/30/60 s (driver có thể đặt
///   lịch riêng qua `DeviceDriver.reconnectBackoff`, vd QRing 2/4/4… s như app gốc), cho đến khi nối được
///   hoặc người dùng `disconnect`/`remove`. Lần tự nối lại không giới hạn pha link (CoreBluetooth chờ thiết bị
///   xuất hiện), nên đồng hồ quảng bá thưa hay đang bị điện thoại khác giữ sẽ được nối ngay khi rảnh.
@MainActor
@Observable
public final class DeviceManager {
    /// Lùi dần giữa các lần thử nối lại (giây), giống `BACKOFF_MS` Android.
    public nonisolated static let defaultBackoff: [TimeInterval] = [2, 5, 10, 30, 60]
    /// Chẩn đoán khi thiết bị giữ kết nối mãi không nối được và không thấy quảng bá.
    public nonisolated static let notAdvertisingStatus = "Chưa thấy quảng bá — có thể đang kết nối với điện thoại/app khác"
    public nonisolated static let advertisingStatus = "Thấy quảng bá nhưng chưa nối được — đang thử lại"
    public nonisolated static let unknownToSystemStatus = "iOS không còn nhớ thiết bị này — hãy quét để tìm lại"

    /// Thời gian chờ trước lần thử thứ `attempt + 1` (0 = sau lần lỗi đầu tiên); hết bảng thì giữ giá trị cuối.
    public nonisolated static func backoffDelay(attempt: Int, schedule: [TimeInterval] = defaultBackoff) -> TimeInterval {
        guard let last = schedule.last else { return 0 }
        return attempt < schedule.count ? schedule[max(0, attempt)] : last
    }

    /// Chuỗi chẩn đoán cho thiết bị đang giữ kết nối (nil = không cần báo gì).
    /// - waitingSince: lúc bắt đầu chờ nối lại; lastAdvertised: lần cuối quét thấy quảng bá.
    public nonisolated static func diagnose(
        connected: Bool, waitingSince: Date?, lastAdvertised: Date?, unknownToSystem: Bool,
        now: Date, after: TimeInterval
    ) -> String? {
        guard !connected, let since = waitingSince else { return nil }
        if unknownToSystem { return unknownToSystemStatus }
        guard now.timeIntervalSince(since) >= after else { return nil }
        if let seen = lastAdvertised, now.timeIntervalSince(seen) < 15 { return advertisingStatus }
        return notAdvertisingStatus
    }

    public let registry: DeviceRegistry
    public var maxConnections = 7
    /// Lần bấm kết nối chờ lần tự nối lại đang bắt tay xong tối đa chừng này rồi mới huỷ nó.
    @ObservationIgnored public var settleTimeout: TimeInterval = 30
    /// Lùi dần giữa các lần thử nối lại, cho driver không đặt `reconnectBackoff` riêng.
    @ObservationIgnored public var backoff = DeviceManager.defaultBackoff
    /// Chờ trước khi nối lại sau khi mất kết nối ngoài ý muốn (Android: 2 s).
    @ObservationIgnored public var reconnectDelay: TimeInterval = 2
    /// Giới hạn pha link cho lần kết nối người dùng bấm.
    @ObservationIgnored public var interactiveLinkTimeout: TimeInterval = 40
    /// Giới hạn pha link cho lần tự nối lại. nil = chờ đến khi thiết bị xuất hiện (yêu cầu kết nối chờ của CoreBluetooth).
    @ObservationIgnored public var backgroundLinkTimeout: TimeInterval?
    /// Chờ nối lại quá lâu chừng này thì đặt `linkStatus` chẩn đoán.
    @ObservationIgnored public var diagnoseAfter: TimeInterval = 20
    /// Treo ở pha link/khám phá quá chừng này (có quảng bá) thì nghi đang chờ ghép đôi.
    @ObservationIgnored public var pairingStuckAfter: TimeInterval = ConnectionDiagnostics.pairingStuckAfter
    /// Gọi mỗi lần kết nối thất bại (bấm tay hoặc tự nối lại), kèm giải thích. Vd AutoTest in ra console.
    @ObservationIgnored public var onConnectFailed: ((WearableDevice, ConnectionFailure, Diagnosis) -> Void)?
    /// Nhật ký chung: sự kiện của mọi thiết bị + sự kiện Bluetooth, tối đa `globalLogLimit` dòng.
    public private(set) var events = RingBuffer<ConnectionEvent>(capacity: DeviceManager.globalLogLimit)
    public nonisolated static let globalLogLimit = 500

    public private(set) var bluetoothState: BluetoothState = .unknown
    public private(set) var isScanning = false
    /// Thiết bị quét được có driver nhận ra, theo id.
    public private(set) var discovered: [UUID: DiscoveredDevice] = [:]
    /// Số thiết bị BLE khác quét thấy nhưng không driver nào nhận.
    public private(set) var ignoredCount = 0
    /// Thiết bị đang quản lý, theo thứ tự thêm vào.
    public private(set) var devices: [WearableDevice] = []
    /// Thiết bị đã lưu (kể cả cờ giữ kết nối), theo thứ tự thêm vào.
    public private(set) var knownDevices: [KnownDevice] = []
    /// Gọi sau MỖI lần một thiết bị kết nối + bắt tay thành công, kể cả tự nối lại
    /// (vd app tự cài mặt đồng hồ mặc định).
    @ObservationIgnored public var onConnected: ((WearableDevice) -> Void)?

    @ObservationIgnored private let central: any BleCentralProviding
    @ObservationIgnored private let store: KnownDeviceStore
    /// Lịch sử đồng bộ gần nhất của từng thiết bị (nil = không lưu, vd kiểm thử).
    @ObservationIgnored public let historyStore: HistoryStore?
    /// Thiết bị có lượt đồng bộ đã hẹn (Task chưa chạy tới `syncHistory`), chặn bấm hai lần.
    @ObservationIgnored private var syncing: Set<UUID> = []
    @ObservationIgnored private var ignored: Set<UUID> = []
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var scanStopper: Task<Void, Never>?
    @ObservationIgnored private var restored = false
    /// Vòng giữ kết nối đang chạy theo thiết bị (token để task cũ không xoá task mới).
    @ObservationIgnored private var loops: [UUID: (token: UUID, task: Task<Void, Never>)] = [:]
    /// Lúc bắt đầu chờ nối lại, cho chẩn đoán.
    @ObservationIgnored private var waitingSince: [UUID: Date] = [:]
    /// Thiết bị iOS không còn nhớ (`peripheralNotFound`), cần quét lại.
    @ObservationIgnored private var unknownToSystem: Set<UUID> = []
    /// Mọi thiết bị đã quét thấy trong phiên, kể cả đã bị ẩn khỏi `discovered` vì lâu không quảng bá.
    /// Thiết bị quảng bá thưa (Y25, vòng DS500) vẫn kết nối được dù lần cuối thấy đã hơn 20 s.
    @ObservationIgnored private var seen: [UUID: DiscoveredDevice] = [:]
    /// Thiết bị iOS đang giữ kết nối (`retrieveConnectedPeripherals`), cập nhật mỗi giây khi có thiết bị chưa nối.
    @ObservationIgnored private var systemHeld: Set<UUID> = []

    public init(
        registry: DeviceRegistry, central: (any BleCentralProviding)? = nil, store: KnownDeviceStore = KnownDeviceStore(),
        historyStore: HistoryStore? = HistoryStore()
    ) {
        self.registry = registry
        self.central = central ?? BleCentral.shared
        self.store = store
        self.historyStore = historyStore
        knownDevices = store.load()
    }

    /// Bật central (hỏi quyền Bluetooth), dựng lại thiết bị đã lưu, nối lại những cái đang giữ khi Bluetooth bật,
    /// và chạy bộ đếm LinkStats/RSSI/chẩn đoán định kỳ. Gọi nhiều lần được.
    public func start() {
        central.onStateChange = { [weak self] s in self?.bluetoothChanged(s) }
        central.activate()
        restoreSavedDevices()
        bluetoothChanged(central.state)
        guard ticker == nil else { return }
        ticker = Task { @MainActor [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                tick += 1
                let now = Date()
                for d in self.devices { d.tickStats(now: now) }
                if tick % 2 == 0 {
                    for d in self.devices where d.isConnected { Task { await d.updateRSSI() } }
                }
                self.pruneDiscovered(now: now)
                self.updateLinkStatus(now: now)
                self.refreshDiagnostics(now: now)
            }
        }
    }

    private func bluetoothChanged(_ s: BluetoothState) {
        if s != bluetoothState {
            logGlobal(.bluetooth, "Bluetooth: \(s.rawValue)", level: s == .poweredOn ? .info : .warning)
        }
        bluetoothState = s
        if s == .poweredOn {
            // iOS khôi phục và tiếp tục nối hộ app cả những thiết bị đã quên / bỏ giữ: huỷ ngay, không thì thiết bị
            // bị khoá vào iPhone (máy khác không nối được) dù app không dùng (kiểm chứng R09 15/10/2026).
            let unwanted = central.restoredIds.filter { !isKept($0) }
            if !unwanted.isEmpty {
                logGlobal(.bluetooth, "Huỷ \(unwanted.count) kết nối iOS khôi phục mà không còn giữ")
                central.release(Array(unwanted))
            }
            addSystemConnected()
            reconnectSaved()
        } else {
            isScanning = false
        }
    }

    // MARK: - Quét

    /// Quét; `duration` nil = quét đến khi gọi `stopScan()`.
    public func startScan(duration: TimeInterval? = 30) {
        isScanning = true
        central.startScan { [weak self] scanned in self?.handle(scanned) }
        addSystemConnected()
        scanStopper?.cancel()
        if let duration {
            scanStopper = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.stopScan()
            }
        }
    }

    public func stopScan() {
        scanStopper?.cancel()
        central.stopScan()
        isScanning = false
    }

    /// Thiết bị quét được, đã sắp theo driver (theo thứ tự registry) rồi RSSI.
    public var discoveredSorted: [DiscoveredDevice] {
        let order = Dictionary(uniqueKeysWithValues: registry.drivers.enumerated().map { ($1.id, $0) })
        return discovered.values.sorted {
            let a = order[$0.driverId] ?? 99, b = order[$1.driverId] ?? 99
            if a != b { return a < b }
            return $0.scanned.rssi > $1.scanned.rssi
        }
    }

    private func handle(_ scanned: ScannedDevice) {
        if ignored.contains(scanned.id) {
            // Tên có thể đến sau ở gói scan response, phân loại lại khi có tên mới.
            guard scanned.name != nil, registry.classify(scanned) != nil else { return }
            ignored.remove(scanned.id)
            ignoredCount = ignored.count
        }
        guard let (driver, match) = registry.classify(scanned) else {
            ignored.insert(scanned.id)
            ignoredCount = ignored.count
            return
        }
        var merged = scanned
        if let old = discovered[scanned.id]?.scanned {
            if merged.name == nil { merged.name = old.name }
            if merged.serviceUuids.isEmpty { merged.serviceUuids = old.serviceUuids }
            if merged.manufacturerData.isEmpty { merged.manufacturerData = old.manufacturerData }
        }
        discovered[scanned.id] = DiscoveredDevice(scanned: merged, driverId: driver.id, match: match, lastSeen: Date())
        seen[scanned.id] = discovered[scanned.id]
        correctDriver(scanned.id, driver: driver, match: match)
        if scanned.systemConnected { systemHeld.insert(scanned.id) }
        if let d = device(scanned.id) {
            if !d.isConnected, scanned.rssi != 0 { d.stats.rssi = scanned.rssi }
            d.noteSighting(rssi: scanned.rssi == 0 ? nil : scanned.rssi, systemConnected: scanned.systemConnected, connectable: scanned.connectable)
        }
    }

    /// Thiết bị đã lưu với driver khác driver vừa nhận ra (vd DS500 từng bị driver Bluetooth chuẩn nhận nhầm khi
    /// chưa có dữ liệu quảng bá): sửa bản ghi, bỏ thiết bị cũ để lần nối sau dựng lại đúng driver.
    func correctDriver(_ id: UUID, driver: DeviceDriver, match: DriverMatch) {
        guard let i = knownDevices.firstIndex(where: { $0.id == id }), knownDevices[i].driverId != driver.id else { return }
        let note = "Đã lưu với driver \(knownDevices[i].driverId), quảng bá khớp driver \(driver.id): sửa bản ghi"
        SmartWearLog.w("\(knownDevices[i].name): đổi driver \(knownDevices[i].driverId) → \(driver.id)")
        if let old = device(id) {
            old.logEvent(.driver, note, level: .warning)
        } else {
            logGlobal(.driver, note, level: .warning, deviceId: id, name: knownDevices[i].name)
        }
        knownDevices[i].driverId = driver.id
        knownDevices[i].kind = match.kind
        if let model = match.model { knownDevices[i].model = model }
        store.save(knownDevices)
        guard let old = device(id), old.driverId != driver.id else { return }
        let kept = knownDevices[i].keepConnected
        stopLoop(id)
        old.disconnect()
        devices.removeAll { $0 === old }
        if kept, let fresh = add(id) {
            fresh.inheritDiagnostics(from: old)
            startLoop(fresh, initialDelay: 1)
        }
    }

    /// Nhả mọi thiết bị: dừng tự nối lại, ngắt, và bảo iOS nhả cả những kết nối hệ thống đang giữ (dịch vụ của
    /// mọi driver), và tắt cờ giữ kết nối để lần mở app sau không giành lại. Dùng trước khi chuyển thiết bị sang
    /// máy khác (vd test Android). Vẫn nhớ thiết bị (bật lại "Giữ kết nối" là nối lại được).
    public func releaseAll() {
        logGlobal(.user, "Nhả mọi thiết bị")
        for id in Array(loops.keys) { stopLoop(id) }
        for i in knownDevices.indices { knownDevices[i].keepConnected = false }
        store.save(knownDevices)
        for d in devices where d.state != .disconnected { d.disconnect() }
        let ids = Set(devices.map(\.id) + knownDevices.map(\.id) + central.retrieveConnected(services: systemServices).map(\.id))
        central.release(Array(ids))
    }

    private func addSystemConnected() {
        for s in central.retrieveConnected(services: systemServices) where discovered[s.id] == nil {
            handle(s)
        }
    }

    /// Service hỏi `retrieveConnectedPeripherals`: của mọi driver + Battery/Device Info chuẩn.
    private var systemServices: [CBUUID] {
        Array(Set(registry.drivers.flatMap(\.systemServices) + [CBUUID(string: "180F"), CBUUID(string: "180A")]))
    }

    func pruneDiscovered(now: Date) {
        let stale = discovered.values.filter { !$0.scanned.systemConnected && now.timeIntervalSince($0.lastSeen) > 20 }
        for d in stale where device(d.id) == nil { discovered[d.id] = nil }
    }

    // MARK: - Thiết bị

    public func device(_ id: UUID) -> WearableDevice? { devices.first { $0.id == id } }

    public var connectedDevices: [WearableDevice] { devices.filter(\.isConnected) }

    /// Thiết bị có đang được giữ kết nối (tự nối lại) không.
    public func isKept(_ id: UUID) -> Bool { knownDevices.first { $0.id == id }?.keepConnected ?? false }

    /// Số thiết bị đang giữ kết nối.
    public var keptCount: Int { knownDevices.filter(\.keepConnected).count }

    /// Lấy (hoặc tạo) thiết bị quản lý cho một kết quả quét. Thiết bị mới được lưu (chưa giữ kết nối).
    @discardableResult
    public func add(_ id: UUID) -> WearableDevice? {
        if let d = device(id) { return d }
        guard let found = discovered[id] ?? seen[id], let driver = registry.driver(id: found.driverId) else { return nil }
        let d = driver.create(found.scanned, match: found.match)
        d.stats.rssi = found.scanned.rssi == 0 ? nil : found.scanned.rssi
        manage(d)
        d.noteSighting(
            rssi: found.scanned.rssi == 0 ? nil : found.scanned.rssi, systemConnected: found.scanned.systemConnected,
            connectable: found.scanned.connectable, at: found.lastSeen
        )
        remember(d, model: found.match.model)
        return d
    }

    /// Đưa một thiết bị đã tạo sẵn vào danh sách quản lý (vd thiết bị mẫu). Không lưu.
    public func adopt(_ device: WearableDevice) {
        guard self.device(device.id) == nil else { return }
        manage(device)
    }

    /// Kết nối song song (lần người dùng bấm, pha link giới hạn `interactiveLinkTimeout`). Trả về lỗi theo id
    /// (nil = thành công / đã kết nối sẵn). Vượt `maxConnections` thì báo lỗi.
    ///
    /// `keep` = giữ kết nối: lỗi thì tiếp tục thử lại ở nền, mất kết nối thì tự nối lại, mở app thì tự nối.
    /// `keep: false` (vd tự kiểm thử) không bật giữ cho thiết bị chưa giữ: chỉ thử một lần, để iPhone không tranh thiết bị
    /// với máy khác. Thiết bị người dùng ĐÃ bật giữ thì vẫn giữ.
    @discardableResult
    public func connect(_ ids: [UUID], keep: Bool = true) async -> [UUID: Error?] {
        let all = ids.compactMap { add($0) }
        var missing: [UUID: Error?] = [:]
        for id in ids where device(id) == nil {
            SmartWearLog.w("Kết nối \(id): không còn thông tin quét, cần quét lại")
            missing[id] = GattError.operationFailed("Kết nối", "không còn thông tin quét, hãy quét lại")
        }
        // Vòng tự nối lại đang chạy: lần thử nền đang bắt tay thì chờ nó xong (huỷ giữa chừng làm hỏng bắt tay),
        // còn đang chờ backoff / chờ link thì huỷ để thử ngay với giới hạn thời gian của lần bấm.
        await withTaskGroup(of: Void.self) { group in
            for d in all where loops[d.id] != nil {
                group.addTask { @MainActor in await self.settleLoop(d) }
            }
        }
        let targets = all.filter { $0.state == .disconnected }
        let slots = max(0, maxConnections - devices.filter { $0.state != .disconnected }.count)
        var results: [UUID: Error?] = [:]
        for d in targets.dropFirst(slots) {
            d.lastError = "Vượt giới hạn \(maxConnections) kết nối đồng thời"
            d.logEvent(.failure, d.lastError ?? "", level: .error)
            results[d.id] = GattError.operationFailed("Kết nối", d.lastError)
        }
        let allowed = Array(targets.prefix(slots))
        let skipped = Set(targets.dropFirst(slots).map(\.id))
        // `keep: false` chỉ là "không bật giữ": KHÔNG tắt cờ người dùng đã bật (tắt là việc của `disconnect` /
        // `setKeepConnected(false)`). Trước đây lần tự kiểm thử tắt mất cờ của Y25 nên nó không tự nối lại.
        if keep { for d in all where !skipped.contains(d.id) { setKeep(d, true) } }
        await withTaskGroup(of: (UUID, Error?).self) { group in
            for d in allowed {
                group.addTask { @MainActor in
                    d.linkTimeout = self.interactiveLinkTimeout
                    d.beginAttempt(interactive: true)
                    do {
                        try await d.connect()
                        guard d.isConnected else { throw GattError.operationFailed("Kết nối", d.lastError) }
                        self.didConnect(d)
                        return (d.id, nil)
                    } catch {
                        d.lastError = error.localizedDescription
                        self.noteFailure(d, error, interactive: true)
                        return (d.id, error)
                    }
                }
            }
            for await (id, error) in group { results[id] = error }
        }
        // Giữ kết nối: lần bấm lỗi thì thử tiếp ở nền.
        for d in allowed where results[d.id].flatMap({ $0 }) != nil && isKept(d.id) {
            // Hết giờ ở pha link (thiết bị chưa phát tín hiệu): chờ lại NGAY bằng lệnh chờ không giới hạn — nghỉ thì
            // dễ lỡ quãng phát ngắn (Y25). Lỗi sau khi đã thấy thiết bị (bắt tay…) thì vẫn nghỉ theo backoff.
            let notSeen = d.lastAttemptPhase == .link
            startLoop(d, initialDelay: notSeen ? 0 : Self.backoffDelay(attempt: 0, schedule: backoffSchedule(for: d)), firstAttempt: 1)
        }
        for d in all where results[d.id] == nil { results[d.id] = .some(nil) }
        results.merge(missing) { old, _ in old }
        return results
    }

    /// Bật/tắt giữ kết nối cho một thiết bị. Bật mà đang ngắt thì bắt đầu nối lại ngay.
    public func setKeepConnected(_ keep: Bool, for device: WearableDevice) {
        if isKept(device.id) != keep { device.logEvent(.user, keep ? "Bật giữ kết nối" : "Tắt giữ kết nối") }
        setKeep(device, keep)
        if keep {
            if device.state == .disconnected { startLoop(device, initialDelay: 0) }
        } else {
            stopLoop(device.id)
        }
    }

    /// Ngắt theo ý người dùng: bỏ giữ kết nối, dừng vòng tự nối lại.
    public func disconnect(_ device: WearableDevice) {
        device.logEvent(.user, "Người dùng ngắt kết nối (bỏ giữ kết nối)")
        if knownDevices.contains(where: { $0.id == device.id }) { setKeep(device, false) }
        stopLoop(device.id)
        device.disconnect()
    }

    /// Quên thiết bị: ngắt, bỏ khỏi danh sách quản lý và danh sách đã lưu.
    public func remove(_ device: WearableDevice) {
        device.logEvent(.user, "Quên thiết bị (bỏ khỏi danh sách đã lưu)")
        stopLoop(device.id)
        device.stateListener = nil
        device.disconnect()
        central.release([device.id])
        devices.removeAll { $0 === device }
        knownDevices.removeAll { $0.id == device.id }
        store.save(knownDevices)
        historyStore?.remove(device.id)
    }

    /// Ngắt mọi thiết bị (vd khi thoát) nhưng GIỮ cờ giữ kết nối: lần mở app sau vẫn tự nối lại.
    public func disconnectAll() {
        for id in Array(loops.keys) { stopLoop(id) }
        for d in devices { d.disconnect() }
    }

    /// Nối lại mọi thiết bị đang giữ kết nối (tự gọi khi Bluetooth bật). Không quét: lấy peripheral iOS còn nhớ.
    public func reconnectSaved() {
        guard central.state == .poweredOn else { return }
        let kept = devices.filter { isKept($0.id) }
        guard !kept.isEmpty else { return }
        let known = central.retrieveKnown(kept.map(\.id))
        for d in kept {
            if known.contains(d.id) { unknownToSystem.remove(d.id) } else { unknownToSystem.insert(d.id) }
            if d.state == .disconnected { startLoop(d, initialDelay: 0) }
        }
    }

    // MARK: - Giữ kết nối

    private func manage(_ d: WearableDevice) {
        devices.append(d)
        // Lịch sử lần đồng bộ trước (mở lại app vẫn thấy dữ liệu + "đồng bộ lúc …").
        if d.supportsHistory, let saved = historyStore?.load(d.id) { d.restoreHistory(saved) }
        d.eventListener = { [weak self] e in self?.events.append(e) }
        d.stateListener = { [weak self, weak d] old, new in
            guard let self, let d else { return }
            self.stateChanged(d, from: old, to: new)
        }
    }

    private func stateChanged(_ d: WearableDevice, from old: ConnectionState, to new: ConnectionState) {
        if new == .disconnected { d.setPhase(.idle) }
        // Mất kết nối ngoài ý muốn: từ CONNECTED rơi thẳng về DISCONNECTED (ngắt chủ động đi qua DISCONNECTING).
        guard old == .connected, new == .disconnected, isKept(d.id) else { return }
        SmartWearLog.i("\(d.name) mất kết nối, sẽ tự nối lại")
        startLoop(d, initialDelay: reconnectDelay)
    }

    private func startLoop(_ d: WearableDevice, initialDelay: TimeInterval, firstAttempt: Int = 0) {
        guard loops[d.id] == nil else { return }
        if waitingSince[d.id] == nil { waitingSince[d.id] = Date() }
        d.logEvent(.reconnect, initialDelay > 0 ? "Hẹn tự nối lại sau \(Self.seconds(initialDelay))" : "Tự nối lại ngay")
        let token = UUID()
        let task = Task { @MainActor [weak self] in
            await self?.runLoop(d, initialDelay: initialDelay, attempt: firstAttempt)
            if self?.loops[d.id]?.token == token { self?.loops[d.id] = nil }
        }
        loops[d.id] = (token, task)
    }

    /// Trước lần bấm kết nối: nếu vòng tự nối lại đang có lần thử dở (đã qua pha link: khám phá / bắt tay / vừa
    /// CONNECTED) thì chờ nó kết thúc, tối đa `settleTimeout`. Nối được → giữ nguyên (lần bấm coi như thành công);
    /// lỗi → vòng quay về chờ backoff thì huỷ vòng, lần bấm thử tiếp. Vòng đang ngủ backoff hoặc chỉ đang chờ link
    /// (chưa có trao đổi GATT) thì huỷ ngay.
    private func settleLoop(_ d: WearableDevice) async {
        guard let loop = loops[d.id] else { return }
        if d.state != .disconnected, d.phase != .link {
            d.logEvent(.reconnect, "Lần tự nối lại đang dở (\(d.state.rawValue), pha \(d.phase.rawValue)): chờ xong thay vì huỷ")
            let deadline = Date().addingTimeInterval(settleTimeout)
            while loops[d.id]?.token == loop.token, d.state != .disconnected, Date() < deadline {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            // Đã nối xong (vòng tự kết thúc sau `didConnect`): không làm gì thêm.
            guard loops[d.id]?.token == loop.token else { return }
            if d.state != .disconnected {
                d.logEvent(.reconnect, "Lần tự nối lại quá \(Self.seconds(settleTimeout)) chưa xong: huỷ để thử lại", level: .warning)
            }
        }
        stopLoop(d.id)
        await loop.task.value
    }

    private func stopLoop(_ id: UUID) {
        loops.removeValue(forKey: id)?.task.cancel()
        waitingSince[id] = nil
        device(id)?.linkStatus = nil
    }

    /// Thử kết nối cho đến khi được hoặc người dùng không giữ nữa. Lỗi tạm (hết giờ bật notify khi sóng yếu,
    /// GATT bận…) không làm dừng: driver đã đóng link, lần sau thử lại.
    private func runLoop(_ d: WearableDevice, initialDelay: TimeInterval, attempt first: Int) async {
        var attempt = first
        var delay = initialDelay
        while true {
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard shouldTry(d) else { return }
            await waitUntilReady()
            guard shouldTry(d) else { return }
            d.linkTimeout = backgroundLinkTimeout
            d.beginAttempt(interactive: false, attempt: attempt + 1)
            do {
                try await d.connect()
                guard d.isConnected else { throw GattError.operationFailed("Kết nối", d.lastError) }
                didConnect(d)
                return
            } catch {
                guard !Task.isCancelled, isKept(d.id) else { return }
                noteFailure(d, error, interactive: false)
                SmartWearLog.w("Kết nối \(d.name) lỗi (lần \(attempt + 1)): \(error.localizedDescription)")
            }
            delay = Self.backoffDelay(attempt: attempt, schedule: backoffSchedule(for: d))
            d.logEvent(.reconnect, "Lần \(attempt + 1) lỗi, thử lại sau \(Self.seconds(delay))")
            attempt += 1
        }
    }

    /// Lịch lùi dần của driver thiết bị nếu có, không thì `backoff` chung.
    func backoffSchedule(for d: WearableDevice) -> [TimeInterval] {
        registry.driver(id: d.driverId)?.reconnectBackoff ?? backoff
    }

    private func shouldTry(_ d: WearableDevice) -> Bool {
        !Task.isCancelled && isKept(d.id) && d.state == .disconnected && device(d.id) === d
    }

    /// Chờ Bluetooth bật và không có truyền file lớn (BleQuiet) trước mỗi lần thử.
    private func waitUntilReady() async {
        while !Task.isCancelled {
            if BleQuiet.active {
                await BleQuiet.awaitIdle()
            } else if central.state != .poweredOn {
                try? await Task.sleep(nanoseconds: 500_000_000)
            } else {
                return
            }
        }
    }

    private func didConnect(_ d: WearableDevice) {
        waitingSince[d.id] = nil
        unknownToSystem.remove(d.id)
        d.linkStatus = nil
        d.diagnosis = nil
        let ms = d.attemptStartedAt.map { " sau \(Int(Date().timeIntervalSince($0) * 1000)) ms" } ?? ""
        d.logEvent(.ready, "Sẵn sàng\(ms) (kết nối + bắt tay)")
        onConnected?(d)
    }

    private func noteFailure(_ d: WearableDevice, _ error: Error, interactive: Bool) {
        if let e = error as? GattError, e == .peripheralNotFound { unknownToSystem.insert(d.id) }
        guard !(error is CancellationError) else { return }
        let f = ConnectionFailure(
            error: error, phase: d.lastAttemptPhase, interactive: interactive, attemptStartedAt: d.attemptStartedAt
        )
        d.lastFailure = f
        let diag = ConnectionDiagnostics.explain(f, context(d, now: f.time))
        d.diagnosis = diag
        d.logEvent(.failure, "\(interactive ? "Kết nối" : "Tự nối lại") lỗi ở pha \(f.phase.rawValue): \(f.message)", level: .error, code: f.code)
        d.logEvent(.diagnosis, diag.line, level: .warning)
        onConnectFailed?(d, f, diag)
    }

    // MARK: - Chẩn đoán

    /// iOS có đang giữ kết nối thiết bị không (app khác trên iPhone này / hệ thống). Hỏi CoreBluetooth ngay.
    public func isHeldBySystem(_ id: UUID) -> Bool {
        let held = central.retrieveConnected(services: systemServices).contains { $0.id == id }
        if held { systemHeld.insert(id) } else { systemHeld.remove(id) }
        return held
    }

    /// iOS không còn nhớ thiết bị (`retrievePeripherals` không trả về).
    public func isUnknownToSystem(_ id: UUID) -> Bool { unknownToSystem.contains(id) }

    func context(_ d: WearableDevice, now: Date) -> DiagnosisContext {
        DiagnosisContext(
            deviceName: d.name, now: now, lastAdvert: d.lastAdvert?.time,
            // Đang do chính app này nối thì không tính là "iOS giữ".
            heldBySystem: !d.isConnected && systemHeld.contains(d.id),
            unknownToSystem: unknownToSystem.contains(d.id), bluetooth: central.state
        )
    }

    /// Chẩn đoán hiện tại của thiết bị: nil khi đã kết nối hoặc không có gì bất thường.
    public func diagnosis(for d: WearableDevice, now: Date = Date()) -> Diagnosis? {
        if d.isConnected { return nil }
        let failed = d.lastFailure.flatMap { f in f.time >= (d.lastReadyAt ?? .distantPast) ? f : nil }
        if d.state == .connecting {
            let live = ConnectionDiagnostics.live(
                phase: d.phase, phaseSince: d.phaseSince, lastAdvert: d.lastAdvert?.time,
                recentCodes: d.recentErrorCodes(now: now), now: now, deviceName: d.name, stuckAfter: pairingStuckAfter
            )
            if let live { return live }
            // Vòng tự nối lại đang chờ: vẫn hiện lý do lần lỗi trước.
            return d.attemptInteractive ? nil : failed.map { ConnectionDiagnostics.explain($0, context(d, now: now)) }
        }
        return failed.map { ConnectionDiagnostics.explain($0, context(d, now: now)) }
    }

    /// Cập nhật `diagnosis` của mọi thiết bị (mỗi giây); ghi lên dòng thời gian khi chẩn đoán đổi loại.
    func refreshDiagnostics(now: Date = Date()) {
        if devices.contains(where: { !$0.isConnected }), central.state == .poweredOn {
            systemHeld = Set(central.retrieveConnected(services: systemServices).map(\.id))
        }
        for d in devices {
            let diag = diagnosis(for: d, now: now)
            guard diag != d.diagnosis else { continue }
            if let diag, diag.category != d.diagnosis?.category, d.state == .connecting {
                d.logEvent(.diagnosis, diag.line, level: .warning)
            }
            d.diagnosis = diag
        }
    }

    /// "Thử lại ngay". KHÔNG huỷ lệnh nối chờ đang chạy: lệnh chờ không giới hạn đã là cách nhanh nhất (nối ngay khi
    /// thiết bị hé tín hiệu; Y25 chỉ phát một quãng ngắn). Trước đây nút này thay lệnh chờ bằng một lần thử 40 s rồi
    /// nghỉ backoff ⇒ bấm nhiều lần còn dễ lỡ quãng phát. Giờ: bật giữ kết nối (app tự thử mãi), đang ngủ backoff
    /// hoặc chưa có vòng thì đặt lệnh chờ ngay.
    @discardableResult
    public func retryNow(_ d: WearableDevice) async -> Error? {
        d.logEvent(.user, "Thử lại ngay")
        guard !d.isConnected else { return nil }
        setKeep(d, true)
        if loops[d.id] != nil, d.state != .disconnected {
            d.logEvent(.reconnect, "Đang chờ thiết bị phát tín hiệu (lệnh chờ không giới hạn), giữ nguyên")
            return nil
        }
        stopLoop(d.id)
        startLoop(d, initialDelay: 0)
        return nil
    }

    func logGlobal(
        _ kind: ConnectionEventKind, _ message: String, level: ConnectionEventLevel = .info, deviceId: UUID? = nil,
        name: String? = nil
    ) {
        events.append(ConnectionEvent(deviceId: deviceId, deviceName: name, kind: kind, level: level, message: message))
    }

    nonisolated static func seconds(_ t: TimeInterval) -> String {
        t.rounded() == t ? "\(Int(t)) s" : String(format: "%.2f s", t)
    }

    /// Báo cáo văn bản để xuất: thông tin thiết bị, chẩn đoán, dòng thời gian, sự kiện Bluetooth chung.
    /// `header`: dòng do app thêm (phiên bản app, iOS…).
    public func diagnosticsReport(for d: WearableDevice, header: [String] = [], now: Date = Date()) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        func ago(_ t: Date) -> String { "\(df.string(from: t)) (\(Int(now.timeIntervalSince(t))) s trước)" }
        var lines = ["SmartWear — nhật ký chẩn đoán kết nối", "Xuất lúc: \(df.string(from: now))"]
        lines += header
        lines.append("SDK: SmartWear \(SmartWear.version)")
        lines.append("")
        lines.append("Thiết bị: \(d.name) · driver \(d.driverId) · \(d.kind.rawValue)")
        lines.append("UUID iOS: \(d.id.uuidString)")
        lines.append("MAC: \(d.mac ?? "không rõ")")
        if let m = d.info.model { lines.append("Model: \(m)") }
        if let fw = d.info.firmware { lines.append("Firmware: \(fw)") }
        lines.append("Trạng thái: \(d.state.rawValue), pha \(d.phase.rawValue)" + (d.phaseSince.map { " từ \(ago($0))" } ?? ""))
        lines.append("Bluetooth iPhone: \(central.state.rawValue)")
        lines.append("Giữ kết nối: \(isKept(d.id) ? "có" : "không")")
        lines.append("Quảng bá gần nhất: " + (d.lastAdvert.map { "\(ago($0.time)), RSSI \($0.rssi.map { "\($0) dBm" } ?? "?")" } ?? "chưa thấy trong phiên này"))
        lines.append("iOS hệ thống đang giữ: \(isHeldBySystem(d.id) ? "có" : "không")" + (d.lastSystemSighting.map { ", lần cuối \(ago($0.time))" } ?? ""))
        lines.append("iOS còn nhớ thiết bị: \(unknownToSystem.contains(d.id) ? "không" : "có")")
        if let s = d.linkStatus { lines.append("Trạng thái giữ kết nối: \(s)") }
        if let f = d.lastFailure {
            lines.append("Lỗi gần nhất: \(ago(f.time)) pha \(f.phase.rawValue): \(f.message)" + (f.code.map { " [\($0.label): \($0.meaning)]" } ?? ""))
            lines.append("Giải thích: \(ConnectionDiagnostics.explain(f, context(d, now: now)).line)")
        }
        if let diag = diagnosis(for: d, now: now) { lines.append("Chẩn đoán hiện tại: \(diag.line)") }
        let stats = d.stats
        lines.append("LinkStats: rssi=\(stats.rssi.map(String.init) ?? "-") gói=\(stats.packetsReceived) lỗi=\(stats.errors)")
        lines.append("")
        let tl = d.timeline.elements
        lines.append("--- Dòng thời gian (\(tl.count) sự kiện, cũ → mới) ---")
        lines += tl.map { $0.line() }
        let global = events.elements.filter { $0.deviceId == nil }
        if !global.isEmpty {
            lines.append("")
            lines.append("--- Sự kiện chung ---")
            lines += global.map { $0.line(withDevice: true) }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func updateLinkStatus(now: Date) {
        for d in devices {
            let status = isKept(d.id) ? Self.diagnose(
                connected: d.isConnected, waitingSince: waitingSince[d.id],
                lastAdvertised: discovered[d.id].flatMap { $0.scanned.systemConnected ? nil : $0.lastSeen },
                unknownToSystem: unknownToSystem.contains(d.id), now: now, after: diagnoseAfter
            ) : nil
            if d.linkStatus != status { d.linkStatus = status }
        }
    }

    /// Dựng lại thiết bị đã lưu (một lần), chưa kết nối. Peripheral lấy khi kết nối (`retrievePeripherals`).
    /// Nối thẳng một thiết bị iOS còn nhớ (UUID CoreBluetooth), KHÔNG cần quét, và giữ kết nối. iOS chờ tới khi
    /// thiết bị phát tín hiệu, kể cả quảng bá có hướng chỉ gửi riêng iPhone này mà máy quét thường không thấy
    /// (đồng hồ đã ghép đôi như Y25). Trả về nil nếu không có driver hoặc iOS không còn nhớ id.
    @discardableResult
    public func connectKnown(id: UUID, driverId: String, name: String) -> WearableDevice? {
        guard let driver = registry.driver(id: driverId), !central.retrieveKnown([id]).isEmpty else { return nil }
        let d = device(id) ?? {
            let scanned = ScannedDevice(id: id, name: name, rssi: 0)
            let fresh = driver.create(scanned, match: DriverMatch(driverId: driverId, model: name, kind: .unknown, mac: nil))
            manage(fresh)
            return fresh
        }()
        if !knownDevices.contains(where: { $0.id == id }) { remember(d, model: name) }
        setKeep(d, true)
        logGlobal(.user, "Nối thẳng theo UUID (không quét), chờ thiết bị phát tín hiệu", deviceId: id, name: name)
        if d.state == .disconnected { startLoop(d, initialDelay: 0) }
        return d
    }

    private func restoreSavedDevices() {
        guard !restored else { return }
        restored = true
        for k in knownDevices where device(k.id) == nil {
            guard let driver = registry.driver(id: k.driverId) else { continue }
            let scanned = ScannedDevice(id: k.id, name: k.name, rssi: 0)
            let match = DriverMatch(driverId: k.driverId, model: k.model, kind: k.kind, mac: k.mac)
            manage(driver.create(scanned, match: match))
        }
    }

    private func remember(_ d: WearableDevice, model: String?) {
        let old = knownDevices.first { $0.id == d.id }
        let k = KnownDevice(
            id: d.id, driverId: d.driverId, name: d.name, model: model ?? old?.model, kind: d.kind,
            mac: d.mac ?? old?.mac, keepConnected: old?.keepConnected ?? false
        )
        if let i = knownDevices.firstIndex(where: { $0.id == d.id }) { knownDevices[i] = k } else { knownDevices.append(k) }
        store.save(knownDevices)
    }

    private func setKeep(_ d: WearableDevice, _ keep: Bool) {
        if !knownDevices.contains(where: { $0.id == d.id }) { remember(d, model: nil) }
        guard let i = knownDevices.firstIndex(where: { $0.id == d.id }), knownDevices[i].keepConnected != keep else { return }
        knownDevices[i].keepConnected = keep
        store.save(knownDevices)
    }

    // MARK: - Đo đồng loạt

    /// Thiết bị đang kết nối hỗ trợ đo capability này.
    public func devicesSupporting(_ capability: Capability) -> [WearableDevice] {
        connectedDevices.filter { $0.measurableCapabilities.contains(capability) }
    }

    /// Bắt đầu đo `capability` trên mọi thiết bị hỗ trợ, song song. Trả về các Task để chờ.
    @discardableResult
    public func measureAll(_ capability: Capability) -> [Task<Void, Never>] {
        devicesSupporting(capability).map { $0.startMeasuring(capability) }
    }

    public func stopAll() {
        for d in devices { d.cancelAllMeasurements() }
    }

    public var isMeasuringAny: Bool { devices.contains { !$0.measuring.isEmpty } }

    // MARK: - Lịch sử

    /// Đồng bộ lịch sử ở nền (như `DeviceManager.syncHistory` Android). Đang đồng bộ thì bỏ qua và trả về nil.
    /// Thành công thì lưu vào `historyStore`; lỗi cả lượt (vd chưa kết nối) thì đặt `lastError`.
    @discardableResult
    public func syncHistory(_ device: WearableDevice, days: Int = 7) -> Task<DeviceHistory?, Never>? {
        guard device.syncProgress == nil, !syncing.contains(device.id) else { return nil }
        syncing.insert(device.id)
        return Task { @MainActor [weak self] in
            defer { self?.syncing.remove(device.id) }
            do {
                let h = try await device.syncHistory(days: days)
                self?.historyStore?.save(h, for: device.id)
                return h
            } catch {
                SmartWearLog.w("Đồng bộ \(device.name) lỗi: \(error.localizedDescription)")
                device.lastError = "Đồng bộ lỗi: \(error.localizedDescription)"
                return nil
            }
        }
    }

    /// Đồng bộ mọi thiết bị đang kết nối có lịch sử, song song.
    @discardableResult
    public func syncAllHistory(days: Int = 7) -> [Task<DeviceHistory?, Never>] {
        connectedDevices.filter(\.supportsHistory).compactMap { syncHistory($0, days: days) }
    }

    public var isSyncingAny: Bool { devices.contains { $0.syncProgress != nil } }
}
