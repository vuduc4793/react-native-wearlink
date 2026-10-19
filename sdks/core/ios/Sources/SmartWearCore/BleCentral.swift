import CoreBluetooth
import Foundation

/// Phần của `BleCentral` mà `DeviceManager` dùng, tách ra để kiểm thử bằng central giả.
@MainActor
public protocol BleCentralProviding: AnyObject {
    var state: BluetoothState { get }
    var onStateChange: ((BluetoothState) -> Void)? { get set }
    func activate()
    func startScan(_ handler: @escaping (ScannedDevice) -> Void)
    func stopScan()
    func retrieveConnected(services: [CBUUID]) -> [ScannedDevice]
    /// Id trong `ids` mà CoreBluetooth còn nhớ (`retrievePeripherals(withIdentifiers:)`), không cần quét.
    func retrieveKnown(_ ids: [UUID]) -> Set<UUID>
    /// Yêu cầu iOS nhả kết nối / huỷ lệnh chờ nối với các thiết bị này (kể cả kết nối được giữ lại khi app bị
    /// tắt nhờ khôi phục trạng thái). Không gọi thì "quên thiết bị" xong máy khác vẫn không nối được.
    func release(_ ids: [UUID])
    /// Thiết bị iOS khôi phục từ lần chạy trước (nó vẫn đang nối / chờ nối hộ app).
    var restoredIds: Set<UUID> { get }
}

/// Một `CBCentralManager` duy nhất cho cả app (peripheral thuộc về central đã tìm ra nó).
/// Delegate chạy trên main queue, nên mọi trạng thái nằm trên MainActor.
///
/// Tạo central sẽ làm iOS hỏi quyền Bluetooth lần đầu (cần `NSBluetoothAlwaysUsageDescription`).
@MainActor
public final class BleCentral: NSObject {
    public static let shared = BleCentral()

    public private(set) var state: BluetoothState = .unknown
    public private(set) var isScanning = false

    /// Gọi mỗi khi trạng thái Bluetooth đổi.
    public var onStateChange: ((BluetoothState) -> Void)?

    /// Bật khôi phục trạng thái CoreBluetooth (iOS mở lại app ở nền khi một kết nối đang chờ hoàn tất).
    /// Phải gán TRƯỚC lần dùng đầu tiên, và app phải có `bluetooth-central` trong `UIBackgroundModes`,
    /// nếu không CoreBluetooth sẽ dừng app. nil = tắt (mặc định, an toàn cho app khác dùng SDK).
    public static var restoreIdentifier: String?

    private lazy var manager: CBCentralManager = {
        var options: [String: Any] = [CBCentralManagerOptionShowPowerAlertKey: true]
        if let id = Self.restoreIdentifier { options[CBCentralManagerOptionRestoreIdentifierKey] = id }
        return CBCentralManager(delegate: self, queue: .main, options: options)
    }()
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var scanHandler: ((ScannedDevice) -> Void)?
    private var connections: [UUID: WeakConnection] = [:]
    private var stateWaiters: [OneShot<Void>] = []

    private struct WeakConnection { weak var value: GattConnection? }

    override private init() { super.init() }

    /// Khởi tạo central (hiện hộp thoại xin quyền nếu cần).
    public func activate() { _ = manager }

    /// Chờ Bluetooth bật. Ném lỗi nếu bị từ chối quyền / không hỗ trợ / hết giờ.
    public func waitUntilPoweredOn(timeout: TimeInterval = 30) async throws {
        activate()
        while state != .poweredOn {
            if state == .unauthorized || state == .unsupported {
                throw GattError.bluetoothUnavailable(state.rawValue)
            }
            let shot = OneShot<Void>()
            stateWaiters.append(shot)
            try await shot.wait(timeout: timeout) { GattError.bluetoothUnavailable("chờ quá \(Int(timeout)) s, trạng thái \(self.state.rawValue)") }
        }
    }

    public func peripheral(_ id: UUID) -> CBPeripheral? {
        if let p = peripherals[id] { return p }
        if let p = manager.retrievePeripherals(withIdentifiers: [id]).first {
            peripherals[id] = p
            return p
        }
        return nil
    }

    /// Quét liên tục (cho phép trùng để cập nhật RSSI). Gọi lại thì thay handler.
    public func startScan(_ handler: @escaping (ScannedDevice) -> Void) {
        scanHandler = handler
        guard state == .poweredOn else { return }
        manager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        isScanning = true
        SmartWearLog.d("Bắt đầu quét BLE")
    }

    public func stopScan() {
        scanHandler = nil
        guard isScanning else { return }
        manager.stopScan()
        isScanning = false
        SmartWearLog.d("Dừng quét BLE")
    }

    /// Thiết bị đã được hệ thống kết nối (vd đồng hồ đang nối với app hãng) không quảng bá nữa,
    /// chỉ thấy được bằng cách hỏi theo service.
    public func retrieveConnected(services: [CBUUID]) -> [ScannedDevice] {
        guard state == .poweredOn, !services.isEmpty else { return [] }
        return manager.retrieveConnectedPeripherals(withServices: services).map { p in
            peripherals[p.identifier] = p
            return ScannedDevice(
                id: p.identifier, name: p.name, rssi: 0, serviceUuids: p.services?.map(\.uuid) ?? [],
                systemConnected: true
            )
        }
    }

    public func retrieveKnown(_ ids: [UUID]) -> Set<UUID> {
        guard state == .poweredOn, !ids.isEmpty else { return [] }
        var known = Set<UUID>()
        for p in manager.retrievePeripherals(withIdentifiers: ids) {
            peripherals[p.identifier] = p
            known.insert(p.identifier)
        }
        return known
    }

    func register(_ connection: GattConnection, for id: UUID) {
        connections[id] = WeakConnection(value: connection)
    }

    /// Báo mất kết nối cả khi app ở nền (giống app QRing iOS). Không dùng `EnableAutoReconnect`: DeviceManager tự nối lại.
    /// KHÔNG bật `EnableTransportBridging` (SDK UTE iOS có bật, doc gloryfit 09 §1.4): với đồng hồ hai chế độ có
    /// nghe gọi (Y25) nó kéo theo kênh Classic → iOS hiện popup ghép đôi và giữ thiết bị ở cấp hệ thống, app không
    /// nhả được, máy khác không nối được (suy luận từ thời điểm popup xuất hiện 15/10/2026). Bật lại qua
    /// `transportBridging` khi cần nghe gọi qua đồng hồ. Driver bật riêng cho từng kết nối qua
    /// `GattConnection.transportBridging` (GloryFit bật, như SDK UTE gốc).
    public static var transportBridging = false

    func connect(_ peripheral: CBPeripheral, transportBridging: Bool = false) {
        var options: [String: Any] = [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true]
        #if os(iOS)
        if transportBridging || Self.transportBridging { options[CBConnectPeripheralOptionEnableTransportBridgingKey] = true }
        #endif
        manager.connect(peripheral, options: options)
    }

    public private(set) var restoredIds: Set<UUID> = []

    public func release(_ ids: [UUID]) {
        guard state == .poweredOn, !ids.isEmpty else { return }
        // Dùng đúng đối tượng iOS đã khôi phục (huỷ trên đối tượng khác có thể không gỡ được lệnh chờ nối cũ).
        let retrieved = Dictionary(manager.retrievePeripherals(withIdentifiers: ids).map { ($0.identifier, $0) }) { a, _ in a }
        for id in ids {
            guard let p = peripherals[id] ?? retrieved[id] else { continue }
            manager.cancelPeripheralConnection(p)
        }
        restoredIds.subtract(ids)
    }

    func cancel(_ peripheral: CBPeripheral) {
        manager.cancelPeripheralConnection(peripheral)
    }
}

extension BleCentral: BleCentralProviding {}

extension BleCentral: CBCentralManagerDelegate {
    nonisolated public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        MainActor.assumeIsolated {
            let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral]) ?? []
            // Giữ lại để `GattConnection` dùng đúng đối tượng iOS trả về; DeviceManager nối lại theo danh sách đã lưu.
            for p in restored { peripherals[p.identifier] = p }
            restoredIds = Set(restored.map(\.identifier))
            SmartWearLog.i("Khôi phục trạng thái BLE: \(restored.map { $0.name ?? $0.identifier.uuidString })")
        }
    }

    nonisolated public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            state = BluetoothState(central.state)
            SmartWearLog.d("Bluetooth: \(state.rawValue)")
            if state == .poweredOn, let handler = scanHandler, !isScanning {
                startScan(handler)
            }
            if state != .poweredOn {
                isScanning = false
                for c in connections.values { c.value?.centralLost() }
            }
            let waiters = stateWaiters
            stateWaiters.removeAll()
            waiters.forEach { $0.succeed(()) }
            onStateChange?(state)
        }
    }

    nonisolated public func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        MainActor.assumeIsolated {
            peripherals[peripheral.identifier] = peripheral
            let rssi = RSSI.intValue
            guard rssi != 127 else { return }  // 127 = không đọc được
            var uuids = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
            uuids += (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID]) ?? []
            let scanned = ScannedDevice(
                id: peripheral.identifier,
                name: (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name,
                rssi: rssi,
                serviceUuids: uuids,
                manufacturerData: ScannedDevice.splitManufacturerData(
                    advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
                ),
                connectable: (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue
            )
            scanHandler?(scanned)
        }
    }

    nonisolated public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            connections[peripheral.identifier]?.value?.didConnect()
        }
    }

    nonisolated public func centralManager(
        _ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?
    ) {
        MainActor.assumeIsolated {
            connections[peripheral.identifier]?.value?.didFailToConnect(error)
        }
    }

    nonisolated public func centralManager(
        _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?
    ) {
        MainActor.assumeIsolated {
            connections[peripheral.identifier]?.value?.didDisconnect(error)
        }
    }
}
