import CoreBluetooth
import Foundation

/// Một thiết bị thấy được khi quét. Trên iOS `id` là UUID CoreBluetooth (iOS ẩn MAC thật).
/// `@unchecked Sendable`: CBUUID bất biến sau khi tạo.
public struct ScannedDevice: @unchecked Sendable, Identifiable, Hashable {
    public let id: UUID
    public var name: String?
    public var rssi: Int
    public var serviceUuids: [CBUUID]
    /// Key là company id 16 bit (2 byte đầu của manufacturer data, little-endian), value là phần còn lại.
    public var manufacturerData: [UInt16: Data]
    /// Thiết bị đã được hệ thống kết nối sẵn (lấy bằng `retrieveConnectedPeripherals`), không có RSSI quảng bá.
    public var systemConnected: Bool
    /// Gói quảng bá cho phép kết nối (`CBAdvertisementDataIsConnectable`); nil = iOS không báo.
    public var connectable: Bool?

    public init(
        id: UUID, name: String?, rssi: Int, serviceUuids: [CBUUID] = [],
        manufacturerData: [UInt16: Data] = [:], systemConnected: Bool = false, connectable: Bool? = nil
    ) {
        self.connectable = connectable
        self.id = id
        self.name = name
        self.rssi = rssi
        self.serviceUuids = serviceUuids
        self.manufacturerData = manufacturerData
        self.systemConnected = systemConnected
    }

    public func advertises(_ service: CBUUID) -> Bool { serviceUuids.contains(service) }

    /// Tách manufacturer data CoreBluetooth (company id LE + payload).
    public static func splitManufacturerData(_ raw: Data?) -> [UInt16: Data] {
        guard let raw, raw.count >= 2 else { return [:] }
        let bytes = [UInt8](raw)
        let company = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        return [company: Data(bytes[2...])]
    }
}

/// Kết quả nhận diện của một driver cho một thiết bị quét được.
public struct DriverMatch: Sendable, Hashable {
    public let driverId: String
    /// Model đoán được (thường là tên quảng bá).
    public var model: String?
    public var kind: DeviceKind
    /// Driver có điều khiển được thiết bị này hay chỉ nhận ra.
    public var supported: Bool
    /// MAC thật nếu đọc được từ quảng bá (QRing để MAC trong manufacturer data).
    public var mac: String?

    public init(driverId: String, model: String?, kind: DeviceKind, supported: Bool = true, mac: String? = nil) {
        self.driverId = driverId
        self.model = model
        self.kind = kind
        self.supported = supported
        self.mac = mac
    }
}

/// Một loại thiết bị (một SDK thiết bị). Cùng hợp đồng với `DeviceDriver` trên Android.
public protocol DeviceDriver: Sendable {
    var id: String { get }
    var displayName: String { get }
    func match(_ scanned: ScannedDevice) -> DriverMatch?
    @MainActor func create(_ scanned: ScannedDevice, match: DriverMatch) -> WearableDevice
    /// Service cần hỏi `retrieveConnectedPeripherals` để thấy thiết bị đã được hệ thống kết nối sẵn.
    var systemServices: [CBUUID] { get }
    /// Lịch lùi dần khi tự nối lại thiết bị của driver này (giây, hết bảng thì giữ giá trị cuối).
    /// nil = dùng `DeviceManager.backoff` (mặc định 2/5/10/30/60 s).
    var reconnectBackoff: [TimeInterval]? { get }
}

public extension DeviceDriver {
    var systemServices: [CBUUID] { [] }
    var reconnectBackoff: [TimeInterval]? { nil }
}

/// Danh sách driver theo thứ tự ưu tiên: driver cụ thể trước, `standard` sau cùng.
public struct DeviceRegistry: Sendable {
    public let drivers: [any DeviceDriver]

    public init(drivers: [any DeviceDriver]) { self.drivers = drivers }

    public func classify(_ scanned: ScannedDevice) -> (driver: any DeviceDriver, match: DriverMatch)? {
        for driver in drivers {
            if let match = driver.match(scanned) { return (driver, match) }
        }
        return nil
    }

    public func driver(id: String) -> (any DeviceDriver)? { drivers.first { $0.id == id } }
}

/// Thiết bị đã biết, lưu qua các lần mở app (bản iOS của dòng prefs Android: driver, địa chỉ, tên, model, cờ giữ).
public struct KnownDevice: Codable, Equatable, Sendable, Identifiable {
    /// UUID CoreBluetooth (iOS không cho đọc MAC), dùng cho `retrievePeripherals(withIdentifiers:)`.
    public var id: UUID
    public var driverId: String
    public var name: String
    public var model: String?
    public var kind: DeviceKind
    /// MAC thật nếu đọc được từ quảng bá (QRing).
    public var mac: String?
    /// Người dùng muốn giữ kết nối: mở app / mất kết nối thì tự nối lại.
    public var keepConnected: Bool

    public init(
        id: UUID, driverId: String, name: String, model: String? = nil, kind: DeviceKind = .unknown,
        mac: String? = nil, keepConnected: Bool = false
    ) {
        self.id = id
        self.driverId = driverId
        self.name = name
        self.model = model
        self.kind = kind
        self.mac = mac
        self.keepConnected = keepConnected
    }
}

/// Lưu danh sách `KnownDevice` (JSON) trong UserDefaults. Kiểm thử thì tiêm `UserDefaults(suiteName:)` riêng.
public struct KnownDeviceStore: @unchecked Sendable {
    public let defaults: UserDefaults
    public let key: String

    public init(defaults: UserDefaults = .standard, key: String = "smartwear.knownDevices") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> [KnownDevice] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([KnownDevice].self, from: data)) ?? []
    }

    public func save(_ devices: [KnownDevice]) {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        defaults.set(data, forKey: key)
    }
}

public struct DeviceInfo: Sendable, Equatable {
    public var model: String?
    public var manufacturer: String?
    public var hardware: String?
    public var firmware: String?
    public var software: String?
    /// Chi tiết kỹ thuật riêng của driver (bảng bit QRing, MAC trong manufacturer data…), theo thứ tự hiển thị.
    public var extra: [(key: String, value: String)]

    public init(
        model: String? = nil, manufacturer: String? = nil, hardware: String? = nil, firmware: String? = nil,
        software: String? = nil, extra: [(key: String, value: String)] = []
    ) {
        self.model = model
        self.manufacturer = manufacturer
        self.hardware = hardware
        self.firmware = firmware
        self.software = software
        self.extra = extra
    }

    public static func == (a: DeviceInfo, b: DeviceInfo) -> Bool {
        a.model == b.model && a.manufacturer == b.manufacturer && a.hardware == b.hardware
            && a.firmware == b.firmware && a.software == b.software
            && a.extra.map { "\($0.key)=\($0.value)" } == b.extra.map { "\($0.key)=\($0.value)" }
    }

    public mutating func setExtra(_ key: String, _ value: String?) {
        extra.removeAll { $0.key == key }
        if let value { extra.append((key, value)) }
    }

    public func extra(_ key: String) -> String? { extra.first { $0.key == key }?.value }
}

public enum ReadingStatus: String, Sendable {
    /// Đang đo, chưa có giá trị.
    case measuring = "MEASURING"
    /// Có giá trị hợp lệ.
    case ok = "OK"
    /// Thiết bị báo chưa đeo.
    case notWorn = "NOT_WORN"
    /// Thiết bị báo lỗi.
    case error = "ERROR"
}

public struct Reading: Sendable, Equatable {
    public var capability: Capability
    public var status: ReadingStatus
    public var value: Double?
    public var systolic: Int?
    public var diastolic: Int?
    public var unit: String
    public var timestamp: Date
    /// Tín hiệu thô đi kèm gói (QRing: giá trị PPG khi chưa có kết quả). Chỉ để vẽ.
    public var signal: Double?
    /// Mã lỗi / ghi chú của thiết bị.
    public var errorCode: Int?
    /// Ghi chú cho người dùng. Giá trị máy đọc được: `Reading.touchSensorNote` ("TOUCH_SENSOR").
    public var note: String?
    /// Giá trị phụ của phép đo nhiều chỉ số (cùng khoá với `Reading.extra` Android): mỡ máu "totalCholesterol",
    /// "triglycerides", "hdl", "ldl"; thành phần cơ thể theo khoá driver. Rỗng = không có.
    public var extra: [String: Double]

    public init(
        capability: Capability, status: ReadingStatus, value: Double? = nil, systolic: Int? = nil,
        diastolic: Int? = nil, unit: String, timestamp: Date = Date(), signal: Double? = nil,
        errorCode: Int? = nil, note: String? = nil, extra: [String: Double] = [:]
    ) {
        self.extra = extra
        self.capability = capability
        self.status = status
        self.value = value
        self.systolic = systolic
        self.diastolic = diastolic
        self.unit = unit
        self.timestamp = timestamp
        self.signal = signal
        self.errorCode = errorCode
        self.note = note
    }

    public var hasValue: Bool { value != nil || (systolic != nil && diastolic != nil) }

    /// `note` = "TOUCH_SENSOR" (như `Reading.NOTE_TOUCH_SENSOR` Android): phép đo cần ngón tay đặt lên cảm biến / điện cực của
    /// vòng tay (thành phần máu, thành phần cơ thể). `measuring`: nhắc "Đặt ngón tay lên cảm biến của vòng tay"; `notWorn` /
    /// `error`: đo hỏng vì không chạm.
    public static let touchSensorNote = "TOUCH_SENSOR"
    /// Khoá `extra` tiến độ 0–100 (%) khi `measuring`, nếu thiết bị báo.
    public static let progressKey = "progress"
    public var needsTouch: Bool { note == Reading.touchSensorNote }
}

public struct LinkStats: Sendable, Equatable {
    public var rssi: Int?
    public var packetsReceived: Int = 0
    /// Đo thật, cửa sổ trượt 5 s.
    public var packetsPerSecond: Double = 0
    public var errors: Int = 0
    /// Thời gian từ lúc gửi request đến phản hồi đầu tiên.
    public var lastLatencyMs: Int?

    public init() {}
}

/// Đếm gói trong cửa sổ trượt. Tách riêng để kiểm thử được.
public struct PacketRateWindow: Sendable {
    public let window: TimeInterval
    private var times: [Date] = []
    private var firstPacket: Date?

    public init(window: TimeInterval = 5) { self.window = window }

    public mutating func record(at time: Date) {
        times.append(time)
        if firstPacket == nil { firstPacket = time }
        prune(now: time)
    }

    public mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-window)
        if let idx = times.firstIndex(where: { $0 > cutoff }) {
            if idx > 0 { times.removeFirst(idx) }
        } else {
            times.removeAll()
        }
    }

    /// Gói/giây trong cửa sổ. Trong 5 s đầu chia theo thời gian thực đã trôi qua (tối thiểu 1 s).
    public func rate(now: Date) -> Double {
        let cutoff = now.addingTimeInterval(-window)
        let count = times.filter { $0 > cutoff }.count
        guard count > 0, let first = firstPacket else { return 0 }
        let span = min(window, max(1, now.timeIntervalSince(first)))
        return Double(count) / span
    }

    public mutating func reset() {
        times.removeAll()
        firstPacket = nil
    }
}

public enum TrafficDirection: String, Sendable {
    case tx, rx, info, error
}

/// Một dòng nhật ký gói tin thô.
public struct PacketLogEntry: Sendable, Identifiable, Equatable {
    public let id: Int
    public let time: Date
    public let direction: TrafficDirection
    /// UUID characteristic rút gọn (vd "6E400003", "2A19").
    public let channel: String
    public let hex: String
    public let note: String?
}
