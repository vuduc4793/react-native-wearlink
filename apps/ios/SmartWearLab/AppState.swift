import Observation
import SmartWearCore
import SmartWearGloryFit
import SmartWearQRing
import SmartWearStandard
import SmartWearVeepoo
import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case devices, add, feasibility

    var id: String { rawValue }

    var title: String {
        switch self {
        case .devices: return "Thiết bị"
        case .add: return "Thêm"
        case .feasibility: return "Khả thi"
        }
    }

    var symbol: String {
        switch self {
        case .devices: return "dot.radiowaves.left.and.right"
        case .add: return "plus.circle"
        case .feasibility: return "waveform.path.ecg"
        }
    }
}

/// Trạng thái giao diện + DeviceManager dùng chung.
@MainActor
@Observable
final class AppState {
    let manager: DeviceManager
    /// Mặt đồng hồ mặc định, tự cài khi đồng hồ GloryFit kết nối.
    let watchFaces = WatchFaceStore()
    /// Popup "Y25 ở gần mà chưa kết nối" (kiểu AirPods).
    let nearby = NearbyPrompt()
    /// Đổ chuông khi đồng hồ/vòng bấm "tìm điện thoại".
    let findPhone = FindPhoneRinger()
    let camera = RemoteCamera()
    /// Nút nhạc trên đồng hồ ↔ app Nhạc của iPhone.
    let music = MusicBridge()
    /// Dự báo thời tiết gửi lên đồng hồ.
    let weather = WeatherService()
    /// Báo cáo sức khoẻ AI (LLM runpod-ai), lưu báo cáo cuối của từng thiết bị.
    let healthReport = HealthReportService()
    var tab: AppTab = .devices
    /// Thiết bị đang mở màn chi tiết (trong sheet).
    var selectedDeviceId: UUID?
    var sheetExpanded = false
    /// Chọn nhiều để kết nối song song ở tab Thêm.
    var selectedForConnect: Set<UUID> = []
    var bulkCapability: Capability = .heartRate
    var connecting = false
    /// Thiết bị đang mở màn "Chẩn đoán" (sheet).
    var diagnosticsDeviceId: UUID?

    @ObservationIgnored private var colorIndex: [UUID: Int] = [:]

    init() {
        // Khôi phục trạng thái CoreBluetooth: iOS mở lại app ở nền khi thiết bị đang chờ kết nối xuất hiện
        // (cần `bluetooth-central` trong UIBackgroundModes, xem project.yml). Gán trước khi central được tạo.
        BleCentral.restoreIdentifier = "com.smartwear.lab.central"
        // Driver cụ thể trước, Bluetooth chuẩn sau cùng (cùng thứ tự với Android).
        // `-forgetAll YES`: xoá mọi thiết bị đã lưu + bản ghi mặt đồng hồ trước khi dựng manager (bắt đầu sạch).
        if UserDefaults.standard.bool(forKey: "forgetAll") {
            let d = UserDefaults.standard
            for key in d.dictionaryRepresentation().keys where key == "smartwear.knownDevices" || key.hasPrefix("watchface.") {
                d.removeObject(forKey: key)
            }
            print("[AUTO] Đã xoá mọi thiết bị đã lưu")
        }
        // `-logConsole YES`: in nhật ký ra console (devicectl --console) khi chạy bình thường, không tự kiểm thử.
        if UserDefaults.standard.bool(forKey: "logConsole") { SmartWearLog.echoToStdout = true }
        manager = DeviceManager(registry: DeviceRegistry(drivers: [QRingDriver(), GloryFitDriver(), VeepooDriver(), StandardDriver()]))
        // Gọi cả khi tự nối lại, để mặt đồng hồ mặc định luôn được kiểm tra.
        manager.onConnected = { [weak self] device in
            self?.watchFaces.onConnected(device)
            self?.findPhone.attach(device)
            self?.camera.attach(device)
            self?.music.attach(device)
            self?.weather.onConnected(device)
        }
        // Khởi động ngay (không chờ giao diện): khi iOS mở lại app ở nền thì chưa có cửa sổ nào.
        manager.start()
        CommandChannel.start(self)
        // `-forgetAll YES` / `-releaseAll YES`: bảo iOS nhả mọi kết nối (kể cả kết nối hệ thống giữ lại khi app
        // bị tắt), để máy khác (vd điện thoại Android) nối được ngay. Chờ Bluetooth bật rồi mới nhả.
        let d = UserDefaults.standard
        // `-connectId <UUID>=<driver>=<tên>`: nối thẳng theo UUID iOS, không quét (thiết bị chỉ quảng bá có hướng).
        if let spec = d.string(forKey: "connectId") {
            let parts = spec.split(separator: "=").map(String.init)
            if parts.count >= 2, let id = UUID(uuidString: parts[0]) {
                let manager = manager
                Task { @MainActor in
                    for _ in 0..<100 where manager.bluetoothState != .poweredOn { try? await Task.sleep(nanoseconds: 100_000_000) }
                    let ok = manager.connectKnown(id: id, driverId: parts[1], name: parts.count > 2 ? parts[2] : parts[0]) != nil
                    print("[AUTO] Nối thẳng \(parts[0]) (\(parts[1])): \(ok ? "đang chờ thiết bị" : "iOS không còn nhớ id này / không có driver")")
                }
            }
        }
        if d.bool(forKey: "forgetAll") || d.bool(forKey: "releaseAll") {
            let manager = manager
            Task { @MainActor in
                for _ in 0..<100 where manager.bluetoothState != .poweredOn {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                manager.releaseAll()
                print("[AUTO] Đã nhả mọi kết nối Bluetooth")
            }
        }
    }

    func color(_ id: UUID) -> Color {
        if let i = colorIndex[id] { return Palette.identity[i % Palette.identity.count] }
        let i = colorIndex.count
        colorIndex[id] = i
        return Palette.identity[i % Palette.identity.count]
    }

    var selectedDevice: WearableDevice? { selectedDeviceId.flatMap { manager.device($0) } }

    func open(_ device: WearableDevice) {
        tab = .devices
        selectedDeviceId = device.id
        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) { sheetExpanded = true }
    }

    func closeDetail() {
        selectedDeviceId = nil
    }

    var diagnosticsDevice: WearableDevice? { diagnosticsDeviceId.flatMap { manager.device($0) } }

    func openDiagnostics(_ device: WearableDevice) {
        diagnosticsDeviceId = device.id
    }

    /// Thông báo sau khi quên thiết bị mà iOS vẫn giữ kết nối (đã ghép đôi cấp hệ thống).
    var forgetNotice: String?

    /// Quên thiết bị: bỏ khỏi app, bảo iOS nhả kết nối, rồi kiểm tra lại. iOS không cho app xoá ghép đôi hệ thống,
    /// nên nếu vẫn bị giữ thì hướng dẫn người dùng xoá trong Cài đặt.
    func forget(_ device: WearableDevice) {
        let id = device.id, name = device.name
        diagnosticsDeviceId = nil
        closeDetail()
        manager.remove(device)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if manager.isHeldBySystem(id) {
                forgetNotice = "iPhone vẫn giữ kết nối với \(name) vì đã ghép đôi ở cấp hệ thống (app không có quyền xoá). " +
                    "Vào Cài đặt → Bluetooth → bấm (i) cạnh \(name) → Quên thiết bị này. Sau đó máy khác mới nối được."
            }
        }
    }

    /// Capability đo được trên ít nhất một thiết bị đang kết nối (cho "Đo đồng loạt").
    var bulkCapabilities: [Capability] {
        let all = Set(manager.connectedDevices.flatMap(\.measurableCapabilities))
        let order: [Capability] = [.heartRate, .spo2, .temperature, .bloodPressure, .stress, .hrv]
        let list = order.filter { all.contains($0) }
        return list.isEmpty ? [.heartRate, .spo2, .temperature] : list
    }

    func connectSelected() {
        let ids = Array(selectedForConnect)
        guard !ids.isEmpty else { return }
        selectedForConnect.removeAll()
        connecting = true
        manager.stopScan()
        for id in ids { manager.add(id) }
        tab = .devices
        Task {
            await manager.connect(ids)
            connecting = false
        }
    }

    /// Thiết bị hiện trên trường tín hiệu: thiết bị đang quản lý + thiết bị quét thấy gần nhất.
    var fieldItems: [FieldItem] {
        var items: [FieldItem] = manager.devices.map { d in
            FieldItem(id: d.id, name: d.name, rssi: d.stats.rssi, connected: d.isConnected, device: d)
        }
        let managed = Set(items.map(\.id))
        let extra = manager.discoveredSorted
            .filter { !managed.contains($0.id) }
            .sorted { $0.scanned.rssi > $1.scanned.rssi }
            .prefix(max(0, 9 - items.count))
            .map { FieldItem(id: $0.id, name: $0.displayName, rssi: $0.scanned.rssi == 0 ? nil : $0.scanned.rssi, connected: false, device: nil) }
        items += extra
        return items
    }
}

struct FieldItem: Identifiable {
    let id: UUID
    let name: String
    let rssi: Int?
    let connected: Bool
    let device: WearableDevice?
}
