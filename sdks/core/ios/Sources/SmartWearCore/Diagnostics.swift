import CoreBluetooth
import Foundation

// Chẩn đoán kết nối: dòng thời gian sự kiện theo thiết bị, mã lỗi CoreBluetooth, giải thích tiếng Việt + việc nên làm,
// và heuristic "có thể đang chờ ghép đôi". Mọi hàm phân loại là hàm thuần để kiểm thử không cần Bluetooth.

// MARK: - Bộ đệm vòng

/// Bộ đệm vòng dung lượng cố định: đầy thì bỏ phần tử cũ nhất. `elements` theo thứ tự cũ → mới.
public struct RingBuffer<Element> {
    public let capacity: Int
    private var storage: [Element] = []
    /// Vị trí phần tử cũ nhất khi đã đầy.
    private var head = 0

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
        storage.reserveCapacity(self.capacity)
    }

    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }

    public mutating func append(_ e: Element) {
        if storage.count < capacity {
            storage.append(e)
        } else {
            storage[head] = e
            head = (head + 1) % capacity
        }
    }

    /// Cũ → mới.
    public var elements: [Element] {
        head == 0 ? storage : Array(storage[head...] + storage[..<head])
    }

    public var last: Element? {
        guard !storage.isEmpty else { return nil }
        return storage.count < capacity || head == 0 ? storage[storage.count - 1] : storage[head - 1]
    }

    public mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        head = 0
    }
}

extension RingBuffer: Sendable where Element: Sendable {}

// MARK: - Sự kiện

/// Loại sự kiện trên dòng thời gian (rawValue là nhãn hiển thị).
public enum ConnectionEventKind: String, Sendable, CaseIterable {
    case sighting = "Quảng bá"
    case attempt = "Thử nối"
    case link = "Link"
    case discovery = "Service"
    case notify = "Notify"
    case handshake = "Bắt tay"
    case ready = "Sẵn sàng"
    case failure = "Lỗi"
    case disconnect = "Ngắt"
    case reconnect = "Nối lại"
    case driver = "Driver"
    case user = "Người dùng"
    case bluetooth = "Bluetooth"
    case diagnosis = "Chẩn đoán"
}

public enum ConnectionEventLevel: String, Sendable {
    case info = "I", warning = "W", error = "E"
}

/// Một dòng trên dòng thời gian kết nối.
public struct ConnectionEvent: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let time: Date
    /// nil = sự kiện chung (vd Bluetooth bật/tắt).
    public let deviceId: UUID?
    public let deviceName: String?
    public let kind: ConnectionEventKind
    public let level: ConnectionEventLevel
    public let message: String
    /// Mã lỗi CoreBluetooth/ATT nếu có.
    public let code: BleErrorCode?

    public init(
        time: Date = Date(), deviceId: UUID?, deviceName: String?, kind: ConnectionEventKind,
        level: ConnectionEventLevel = .info, message: String, code: BleErrorCode? = nil
    ) {
        id = UUID()
        self.time = time
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.kind = kind
        self.level = level
        self.message = message
        self.code = code
    }

    /// "10:20:11.123 E [Lỗi] Y25: … (CBError 14)" cho file xuất.
    public func line(withDevice: Bool = false) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        let who = withDevice ? (deviceName.map { "\($0): " } ?? "") : ""
        let c = code.map { " (\($0.label))" } ?? ""
        return "\(f.string(from: time)) \(level.rawValue) [\(kind.rawValue)] \(who)\(message)\(c)"
    }
}

/// Lần cuối thấy thiết bị khi quét.
public struct Sighting: Sendable, Equatable {
    public var time: Date
    /// nil = không có RSSI (thiết bị do hệ thống giữ, lấy qua `retrieveConnectedPeripherals`).
    public var rssi: Int?
    /// true = iOS đang giữ kết nối (không phải gói quảng bá).
    public var systemConnected: Bool

    public init(time: Date, rssi: Int?, systemConnected: Bool) {
        self.time = time
        self.rssi = rssi
        self.systemConnected = systemConnected
    }
}

/// Pha của một lần kết nối.
public enum ConnectPhase: String, Sendable {
    /// Không kết nối / không đang thử.
    case idle = "rảnh"
    /// Đã gửi yêu cầu nối, chờ iOS báo link lên.
    case link = "chờ nối link"
    /// Link lên, đang khám phá service.
    case discovery = "khám phá service"
    /// Đã có service, đang bật notify + bắt tay.
    case setup = "bắt tay"
    /// Sẵn sàng.
    case ready = "sẵn sàng"
}

// MARK: - Mã lỗi CoreBluetooth

/// Mã lỗi CoreBluetooth (`CBErrorDomain`) hoặc ATT (`CBATTErrorDomain`), giữ lại để giải thích.
public struct BleErrorCode: Sendable, Hashable {
    public enum Domain: String, Sendable {
        case core = "CBError"
        case att = "CBATTError"
    }

    public let domain: Domain
    public let code: Int
    /// `localizedDescription` gốc của iOS.
    public let message: String

    public init(domain: Domain, code: Int, message: String = "") {
        self.domain = domain
        self.code = code
        self.message = message
    }

    /// Lấy mã từ lỗi iOS (NSError CB/ATT) hoặc `GattError.ble`. nil nếu không phải lỗi Bluetooth.
    public init?(_ error: Error?) {
        guard let error else { return nil }
        if let g = error as? GattError {
            guard case .ble(_, let c) = g else { return nil }
            self = c
            return
        }
        let ns = error as NSError
        switch ns.domain {
        case CBErrorDomain: self.init(domain: .core, code: ns.code, message: ns.localizedDescription)
        case CBATTErrorDomain: self.init(domain: .att, code: ns.code, message: ns.localizedDescription)
        default: return nil
        }
    }

    // Mã CBError (CBError.Code) hay gặp.
    public static let cbNotConnected = 3
    public static let cbOperationCancelled = 5
    public static let cbConnectionTimeout = 6
    public static let cbPeripheralDisconnected = 7
    public static let cbConnectionFailed = 10
    public static let cbConnectionLimitReached = 11
    public static let cbUnknownDevice = 12
    public static let cbPeerRemovedPairingInformation = 14
    public static let cbEncryptionTimedOut = 15
    public static let cbTooManyLEPairedDevices = 16
    // Mã ATT (CBATTError.Code) liên quan ghép đôi.
    public static let attInsufficientAuthentication = 0x05
    public static let attInsufficientAuthorization = 0x08
    public static let attInsufficientEncryptionKeySize = 0x0C
    public static let attInsufficientEncryption = 0x0F

    /// "CBError 14", "CBATTError 0x0F".
    public var label: String {
        domain == .att ? "\(domain.rawValue) 0x\(String(format: "%02X", code))" : "\(domain.rawValue) \(code)"
    }

    /// Nghĩa ngắn tiếng Việt của mã.
    public var meaning: String {
        switch (domain, code) {
        case (.core, Self.cbNotConnected): return "chưa kết nối"
        case (.core, Self.cbOperationCancelled): return "thao tác bị huỷ"
        case (.core, Self.cbConnectionTimeout): return "kết nối hết giờ (mất sóng)"
        case (.core, Self.cbPeripheralDisconnected): return "thiết bị chủ động ngắt"
        case (.core, Self.cbConnectionFailed): return "kết nối thất bại"
        case (.core, Self.cbConnectionLimitReached): return "đạt giới hạn kết nối"
        case (.core, Self.cbUnknownDevice): return "thiết bị không xác định"
        case (.core, Self.cbPeerRemovedPairingInformation): return "thiết bị đã xoá khoá ghép đôi"
        case (.core, Self.cbEncryptionTimedOut): return "mã hoá hết giờ (ghép đôi chưa xong)"
        case (.core, Self.cbTooManyLEPairedDevices): return "iPhone ghép đôi quá nhiều thiết bị BLE"
        case (.att, Self.attInsufficientAuthentication): return "cần xác thực (ghép đôi)"
        case (.att, Self.attInsufficientAuthorization): return "không được cấp quyền"
        case (.att, Self.attInsufficientEncryptionKeySize): return "khoá mã hoá không đủ"
        case (.att, Self.attInsufficientEncryption): return "cần mã hoá (ghép đôi)"
        default: return message.isEmpty ? "không rõ" : message
        }
    }

    /// Lỗi chắc chắn do ghép đôi/mã hoá (không tính `connectionTimeout`, vì còn tuỳ pha).
    public var isEncryptionRelated: Bool {
        switch domain {
        case .core: return code == Self.cbPeerRemovedPairingInformation || code == Self.cbEncryptionTimedOut
        case .att:
            return [Self.attInsufficientAuthentication, Self.attInsufficientEncryptionKeySize, Self.attInsufficientEncryption]
                .contains(code)
        }
    }
}

// MARK: - Lỗi + chẩn đoán

/// Một lần kết nối thất bại hoặc mất kết nối, đủ thông tin để giải thích.
public struct ConnectionFailure: Sendable, Equatable {
    public var time: Date
    /// Pha xa nhất đã tới khi lỗi.
    public var phase: ConnectPhase
    public var code: BleErrorCode?
    public var gattError: GattError?
    public var message: String
    /// true = lần bấm của người dùng; false = vòng tự nối lại.
    public var interactive: Bool
    /// true = đang kết nối bình thường thì rớt.
    public var lostAfterConnected: Bool
    public var attemptStartedAt: Date?

    public init(
        error: Error?, phase: ConnectPhase, time: Date = Date(), interactive: Bool = true,
        lostAfterConnected: Bool = false, attemptStartedAt: Date? = nil
    ) {
        self.time = time
        self.phase = phase
        code = BleErrorCode(error)
        gattError = error as? GattError
        message = error?.localizedDescription ?? "Mất kết nối"
        self.interactive = interactive
        self.lostAfterConnected = lostAfterConnected
        self.attemptStartedAt = attemptStartedAt
    }

    public var isTimeout: Bool {
        if case .timeout = gattError { return true }
        return false
    }
}

public enum DiagnosisCategory: String, Sendable {
    /// Đồng hồ cần ghép đôi nhưng bị huỷ / mất khoá.
    case pairing
    /// Đang treo kết nối, nhiều khả năng chờ popup ghép đôi.
    case pairingPending
    /// Có quảng bá nhưng không nối được link.
    case advertisingNoLink
    /// Không thấy quảng bá.
    case notAdvertising
    /// iOS (app khác trên iPhone này) đang giữ kết nối.
    case heldBySystem
    /// Không xác nhận bật notify.
    case notifyTimeout
    /// Thiết bị thiếu service driver cần: lưu nhầm driver.
    case wrongDriver
    /// Đã nối nhưng bắt tay lỗi.
    case handshake
    /// Rớt kết nối do mất sóng.
    case linkLost
    /// Thiết bị chủ động ngắt.
    case peerDisconnected
    case bluetoothOff
    case unknownToSystem
    case limitReached
    case generic
}

/// Giải thích một vấn đề kết nối + việc nên làm (tiếng Việt).
public struct Diagnosis: Sendable, Equatable {
    public var category: DiagnosisCategory
    public var title: String
    public var detail: String
    public var action: String

    public init(_ category: DiagnosisCategory, _ title: String, _ detail: String, _ action: String) {
        self.category = category
        self.title = title
        self.detail = detail
        self.action = action
    }

    /// Một dòng cho console / nhật ký: "Tiêu đề — chi tiết → việc nên làm".
    public var line: String { "\(title) — \(detail) → \(action)" }
}

/// Bối cảnh khi giải thích: quảng bá gần nhất, iOS có giữ thiết bị không…
public struct DiagnosisContext: Sendable {
    public var deviceName: String
    public var now: Date
    /// Lần cuối thấy gói quảng bá thật (không tính hệ thống giữ).
    public var lastAdvert: Date?
    public var heldBySystem: Bool
    public var unknownToSystem: Bool
    /// nil = không rõ (bỏ qua).
    public var bluetooth: BluetoothState?

    public init(
        deviceName: String, now: Date = Date(), lastAdvert: Date? = nil, heldBySystem: Bool = false,
        unknownToSystem: Bool = false, bluetooth: BluetoothState? = nil
    ) {
        self.deviceName = deviceName
        self.now = now
        self.lastAdvert = lastAdvert
        self.heldBySystem = heldBySystem
        self.unknownToSystem = unknownToSystem
        self.bluetooth = bluetooth
    }
}

public enum ConnectionDiagnostics {
    /// Treo ở pha link/khám phá quá chừng này (giây) mà vẫn thấy quảng bá thì nghi đang chờ ghép đôi.
    public static let pairingStuckAfter: TimeInterval = 10
    /// Quảng bá thấy trong khoảng này (giây) trước lúc bắt đầu chờ được coi là "gần đây".
    public static let advertWindow: TimeInterval = 30

    static func forgetAction(_ name: String) -> String {
        "iPhone: Cài đặt → Bluetooth → Quên \(name), rồi bấm Thử lại"
    }

    /// Lỗi `code` có phải do ghép đôi không. `connectionTimeout` chỉ tính khi chưa từng sẵn sàng
    /// (huỷ popup ghép đôi thường kết thúc bằng mã này), rớt khi đang dùng thì là mất sóng.
    public static func isPairingRelated(_ code: BleErrorCode?, phase: ConnectPhase, lostAfterConnected: Bool) -> Bool {
        guard let code else { return false }
        if code.isEncryptionRelated { return true }
        return code.domain == .core && code.code == BleErrorCode.cbConnectionTimeout
            && !lostAfterConnected && phase != .ready && phase != .idle
    }

    /// Giải thích một lần lỗi/mất kết nối.
    public static func explain(_ f: ConnectionFailure, _ ctx: DiagnosisContext) -> Diagnosis {
        let name = ctx.deviceName
        let codeText = f.code.map { " (\($0.label): \($0.meaning))" } ?? ""

        if let bt = ctx.bluetooth, bt != .poweredOn {
            return bluetoothDiagnosis(bt)
        }
        if case .bluetoothUnavailable = f.gattError { return bluetoothDiagnosis(ctx.bluetooth ?? .unknown) }

        if isPairingRelated(f.code, phase: f.phase, lostAfterConnected: f.lostAfterConnected) {
            return Diagnosis(
                .pairing, "Cần ghép đôi lại",
                "Đồng hồ yêu cầu ghép đôi nhưng bị huỷ hoặc mất khoá ghép đôi\(codeText)",
                forgetAction(name)
            )
        }
        if f.gattError == .peripheralNotFound || ctx.unknownToSystem {
            return Diagnosis(
                .unknownToSystem, "iOS không còn nhớ thiết bị",
                "CoreBluetooth không trả về thiết bị theo UUID đã lưu (đã quên trong Cài đặt hoặc đổi UUID)",
                "Mở tab Thêm, quét lại rồi kết nối"
            )
        }

        if f.lostAfterConnected {
            switch f.code?.code {
            case BleErrorCode.cbPeripheralDisconnected where f.code?.domain == .core:
                return Diagnosis(
                    .peerDisconnected, "Thiết bị chủ động ngắt",
                    "\(name) tự ngắt kết nối (tắt Bluetooth, khởi động lại, hoặc chuyển sang nối với máy khác)\(codeText)",
                    "Mở màn hình thiết bị; nếu đang giữ kết nối, SDK tự nối lại khi thiết bị quảng bá lại"
                )
            case BleErrorCode.cbConnectionTimeout where f.code?.domain == .core:
                return Diagnosis(
                    .linkLost, "Mất sóng",
                    "Liên kết hết giờ: thiết bị ra khỏi tầm, bị che sóng hoặc hết pin\(codeText)",
                    "Đưa thiết bị lại gần iPhone; bật Giữ kết nối để tự nối lại"
                )
            default:
                return Diagnosis(
                    .linkLost, "Mất kết nối", "\(f.message)\(codeText)",
                    "Đưa thiết bị lại gần, bấm Thử lại; bật Giữ kết nối để tự nối lại"
                )
            }
        }

        if f.code?.domain == .core {
            switch f.code?.code {
            case BleErrorCode.cbConnectionLimitReached:
                return Diagnosis(
                    .limitReached, "iPhone hết chỗ kết nối", "Đã đạt giới hạn kết nối BLE đồng thời\(codeText)",
                    "Ngắt bớt thiết bị khác rồi Thử lại"
                )
            case BleErrorCode.cbTooManyLEPairedDevices:
                return Diagnosis(
                    .limitReached, "iPhone ghép đôi quá nhiều thiết bị", "iOS từ chối ghép đôi thêm\(codeText)",
                    "Cài đặt → Bluetooth: Quên bớt thiết bị BLE không dùng, rồi Thử lại"
                )
            default: break
            }
        }

        switch f.gattError {
        case .serviceNotFound, .characteristicNotFound:
            return Diagnosis(
                .wrongDriver, "Không đúng driver",
                "Thiết bị không có service/characteristic mà driver cần — có thể đã lưu nhầm driver: \(f.message)",
                "Quên thiết bị trong app, quét lại để driver đúng nhận ra rồi kết nối"
            )
        default: break
        }

        // Hết giờ / lỗi ở pha nối link: phân biệt theo quảng bá.
        if f.phase == .link { return linkTimeout(f, ctx) }
        if f.phase == .discovery, f.isTimeout {
            return Diagnosis(
                .pairingPending, "Nối được link nhưng không đọc được service",
                "Thiết bị không trả bảng service — thường do đang chờ ghép đôi (popup bị ẩn/bỏ qua) hoặc thiết bị bận",
                "Xem popup ghép đôi trên iPhone; nếu đã huỷ: \(forgetAction(name))"
            )
        }

        if f.message.lowercased().contains("notify") {
            return Diagnosis(
                .notifyTimeout, "Không bật được notify",
                "Thiết bị không xác nhận bật notify — sóng yếu hoặc thiết bị đang bận\(codeText)",
                "Đưa thiết bị lại gần (RSSI > -80 dBm) rồi Thử lại; đang giữ kết nối thì SDK tự thử lại"
            )
        }

        if f.phase == .setup {
            return Diagnosis(
                .handshake, "Bắt tay thất bại",
                "Đã nối nhưng thiết bị không trả lời đúng giao thức: \(f.message)",
                "Thử lại; nếu lặp lại, kiểm tra driver (có thể lưu nhầm) — Quên thiết bị rồi quét lại"
            )
        }

        return Diagnosis(.generic, "Kết nối lỗi", "\(f.message)\(codeText)", "Bấm Thử lại; xem dòng thời gian bên dưới")
    }

    static func bluetoothDiagnosis(_ bt: BluetoothState) -> Diagnosis {
        switch bt {
        case .unauthorized:
            return Diagnosis(
                .bluetoothOff, "Chưa cho phép Bluetooth", "App chưa được cấp quyền Bluetooth",
                "Cài đặt → SmartWear Lab → bật Bluetooth"
            )
        case .unsupported:
            return Diagnosis(.bluetoothOff, "Không hỗ trợ BLE", "Máy này không có Bluetooth LE", "Dùng iPhone thật")
        default:
            return Diagnosis(
                .bluetoothOff, "Bluetooth iPhone chưa bật", "Trạng thái Bluetooth: \(bt.rawValue)",
                "Bật Bluetooth trong Trung tâm điều khiển rồi Thử lại"
            )
        }
    }

    /// Có quảng bá quanh lúc bắt đầu chờ (từ `since - advertWindow` trở đi).
    static func advertisedRecently(_ lastAdvert: Date?, since: Date?, now: Date) -> Bool {
        guard let lastAdvert else { return false }
        return lastAdvert >= (since ?? now).addingTimeInterval(-advertWindow)
    }

    static func linkTimeout(_ f: ConnectionFailure, _ ctx: DiagnosisContext) -> Diagnosis {
        if advertisedRecently(ctx.lastAdvert, since: f.attemptStartedAt, now: f.time) {
            return Diagnosis(
                .advertisingNoLink, "Có quảng bá nhưng không nối được",
                "Có quảng bá nhưng không nối được — thường do popup ghép đôi bị bỏ qua",
                "Thử lại và bấm Ghép đôi khi iOS hỏi; nếu không thấy popup: \(forgetAction(ctx.deviceName))"
            )
        }
        if ctx.heldBySystem {
            return Diagnosis(
                .heldBySystem, "iOS đang giữ thiết bị",
                "Thiết bị đang nối với iPhone này qua app khác (app hãng) hoặc hệ thống",
                "Đóng app hãng hoặc Cài đặt → Bluetooth → ngắt \(ctx.deviceName), rồi Thử lại"
            )
        }
        return Diagnosis(
            .notAdvertising, "Không thấy thiết bị",
            "Thiết bị không quảng bá: có thể đang nối với máy khác hoặc đang ngủ",
            "Mở màn hình thiết bị / tắt Bluetooth máy khác, rồi Thử lại"
        )
    }

    /// Heuristic "có thể đang chờ ghép đôi": đang ở pha nối (chưa sẵn sàng) và
    /// - có lỗi mã hoá/xác thực gần đây, hoặc
    /// - treo ở pha link/khám phá quá `stuckAfter` giây trong khi vẫn thấy quảng bá quanh lúc bắt đầu chờ.
    public static func pairingLikelyPending(
        phase: ConnectPhase, phaseSince: Date?, lastAdvert: Date?, recentCodes: [BleErrorCode], now: Date,
        stuckAfter: TimeInterval = pairingStuckAfter
    ) -> Bool {
        guard phase == .link || phase == .discovery || phase == .setup else { return false }
        if recentCodes.contains(where: \.isEncryptionRelated) { return true }
        guard phase != .setup, let since = phaseSince, now.timeIntervalSince(since) >= stuckAfter else { return false }
        return advertisedRecently(lastAdvert, since: since, now: now)
    }

    /// Chẩn đoán lúc đang kết nối (chưa có lỗi): nil = chưa thấy gì bất thường.
    public static func live(
        phase: ConnectPhase, phaseSince: Date?, lastAdvert: Date?, recentCodes: [BleErrorCode], now: Date,
        deviceName: String, stuckAfter: TimeInterval = pairingStuckAfter
    ) -> Diagnosis? {
        if pairingLikelyPending(
            phase: phase, phaseSince: phaseSince, lastAdvert: lastAdvert, recentCodes: recentCodes, now: now,
            stuckAfter: stuckAfter
        ) {
            let waited = phaseSince.map { " \(Int(now.timeIntervalSince($0))) s" } ?? ""
            return Diagnosis(
                .pairingPending, "Có thể đang chờ ghép đôi",
                "Kết nối treo\(waited) ở pha \(phase.rawValue) dù thiết bị vẫn quảng bá — thường do popup ghép đôi của iOS bị bỏ qua",
                "Xem popup ghép đôi trên iPhone và bấm Ghép đôi; nếu đã huỷ: \(forgetAction(deviceName))"
            )
        }
        if phase == .link, let since = phaseSince, now.timeIntervalSince(since) >= stuckAfter,
           !advertisedRecently(lastAdvert, since: since, now: now) {
            return Diagnosis(
                .notAdvertising, "Đang chờ thiết bị xuất hiện",
                "Chưa thấy quảng bá: thiết bị có thể đang nối với máy khác hoặc đang ngủ",
                "Mở màn hình thiết bị / tắt Bluetooth máy khác; iOS sẽ nối ngay khi thiết bị quảng bá"
            )
        }
        return nil
    }
}
