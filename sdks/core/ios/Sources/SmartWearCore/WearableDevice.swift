import CoreBluetooth
import Foundation
#if SMARTWEAR_OBSERVATION
import Observation
#endif

/// Một thiết bị đang được quản lý (bản iOS của `WearableDevice` Android). Có cờ `SMARTWEAR_OBSERVATION` (Package.swift) thì mọi thuộc tính quan sát được
/// bằng Observation, nên SwiftUI tự cập nhật. Driver kế thừa và override `connect`, `disconnect`,
/// `measure`, `refreshBattery`; các thuộc tính trạng thái do driver gán.
@MainActor
#if SMARTWEAR_OBSERVATION
@Observable
#endif
open class WearableDevice: Identifiable {
    public let id: UUID
    public let driverId: String
    public var name: String
    public var kind: DeviceKind
    /// MAC thật nếu biết (QRing: từ manufacturer data). iOS không cho đọc MAC trực tiếp.
    public var mac: String?

    public var state: ConnectionState = .disconnected {
        didSet { if oldValue != state { stateListener?(oldValue, state) } }
    }
    public var info = DeviceInfo()
    /// % pin, nil = chưa đọc.
    public var battery: Int?
    public var charging: Bool?
    public var capabilities: Set<Capability> = []
    /// Kết quả mới nhất của từng capability (kể cả trạng thái đang đo / chưa đeo / lỗi).
    public var latest: [Capability: Reading] = [:]
    /// Kết quả hợp lệ gần nhất của từng capability.
    public var lastResult: [Capability: Reading] = [:]
    /// Mỗi gói đo một giá trị (giá trị hoặc tín hiệu thô) để vẽ cột, tối đa `trailLength`.
    public var trail: [Capability: [Double]] = [:]
    public var measuring: Set<Capability> = []
    public var stats = LinkStats()
    /// Nhật ký gói tin thô, mới nhất ở cuối, tối đa `logLimit` dòng.
    public var log: [PacketLogEntry] = []
    /// Tăng mỗi khi nhận một gói, để UI tạo nhịp.
    public var pulse: Int = 0
    public var lastError: String?
    /// Vì sao thiết bị đang giữ kết nối mà chưa nối được (do `DeviceManager` đặt), vd "Chưa thấy quảng bá…".
    /// nil khi đã kết nối hoặc không giữ kết nối.
    public var linkStatus: String?
    public var connectedAt: Date?

    // MARK: Lịch sử

    /// Lịch sử đồng bộ gần nhất (kể cả bản lưu từ lần mở app trước do `DeviceManager` nạp lại). nil = chưa có.
    public internal(set) var history: DeviceHistory?
    /// Tiến độ đồng bộ, nil khi không đồng bộ.
    public private(set) var syncProgress: SyncProgress?
    /// Mốc đồng bộ thành công gần nhất (giữ qua các lần mở app nhờ `HistoryStore`).
    public internal(set) var lastSyncedAt: Date?

    // MARK: Cài đặt & điều khiển

    /// Cài đặt & điều khiển do driver `ConfigurableDevice` dựng theo bảng tính năng. Rỗng = thiết bị không có.
    public var controls: [DeviceControl] = []
    /// Thiết bị yêu cầu tìm điện thoại (true = đổ chuông, false = dừng). App gán.
    public var onFindPhone: ((Bool) -> Void)?
    /// Báo thiết bị là điện thoại đang / đã thôi đổ chuông, để thiết bị tắt màn "đang tìm điện thoại" khi người dùng
    /// bấm "Đã tìm thấy" trên điện thoại. Mặc định không làm gì.
    open func setPhoneRinging(_ ringing: Bool) async {}

    /// Thiết bị có nút chụp ảnh từ xa (điều khiển camera điện thoại).
    open var supportsRemoteCamera: Bool { false }
    /// Sự kiện chụp ảnh từ xa từ thiết bị. App gán.
    public var onRemoteCamera: ((RemoteCameraEvent) -> Void)?
    /// Báo thiết bị app đã mở / đóng màn chụp ảnh (thiết bị hiện / ẩn nút chụp). Mặc định không làm gì.
    open func setRemoteCamera(_ open: Bool) async {}

    // MARK: Điện thoại ↔ thiết bị (kế hoạch 2026-10-19 §2; kiểu dữ liệu ở PhoneLink.swift)
    //
    // Mỗi nhóm: cờ `supportsXxx` (mặc định false), phương thức `open` mặc định không làm gì / ném "không hỗ trợ",
    // sự kiện từ thiết bị qua callback `onXxx` do app gán. Tên trùng interface Kotlin cùng tên nhóm.

    // NotificationDisplay. iOS không đọc được thông báo của app khác: thiết bị tự đọc qua ANCS sau khi ghép đôi
    // trong Cài đặt > Bluetooth. Vì vậy bản iOS KHÔNG có `notificationApps` / `sendNotification` / `sendSms`;
    // chỉ có trạng thái quyền ANCS.

    /// Thiết bị hiện được thông báo điện thoại (iOS: qua ANCS).
    open var supportsNotifications: Bool { false }
    /// iOS đã cho thiết bị đọc thông báo qua ANCS chưa; nil = chưa biết (chưa ghép đôi / chưa kết nối).
    open var ancsAuthorized: Bool? { nil }

    // CallDisplay. Trên iOS cuộc gọi đến hiện trên thiết bị qua ANCS (hệ thống lo), app không đọc được số gọi đến nên
    // `incomingCall` / `callEnded` mặc định không làm gì và `supportsIncomingCall` = false.

    /// Thiết bị cần app báo cuộc gọi đến (`incomingCall`). iOS: false (ANCS).
    open var supportsIncomingCall: Bool { false }
    /// Thiết bị có nút từ chối cuộc gọi (báo qua `onRejectCall`).
    open var supportsRejectCall: Bool { false }
    /// Báo cuộc gọi đến. Mặc định (và GloryFit iOS) không làm gì, xem `supportsIncomingCall`.
    open func incomingCall(name: String, number: String?) async {}
    /// Màn cuộc gọi trên thiết bị nên tắt. Mặc định không làm gì.
    open func callEnded() async {}
    /// Người dùng bấm từ chối cuộc gọi trên thiết bị. iOS không cho app cúp cuộc gọi di động (CallKit chỉ cúp cuộc
    /// gọi của chính app): app chỉ ghi nhận / báo người dùng; với ANCS thiết bị tự từ chối qua hệ thống.
    public var onRejectCall: (() -> Void)?

    // MusicRemote.

    /// Thiết bị có màn điều khiển nhạc điện thoại (gửi `onMusicCommand`).
    open var supportsMusicControl: Bool { false }
    /// Thiết bị hiện được tên bài / ca sĩ (`setMusicState` có `title`, `artist`).
    open var supportsTrackInfo: Bool { false }
    /// Lệnh nhạc người dùng bấm trên thiết bị. iOS không cho app điều khiển trình phát của app khác
    /// (Nhạc, Spotify…): app chỉ điều khiển được trình phát của chính mình. Khi thiết bị đã ghép Bluetooth cổ điển,
    /// nút nhạc có thể đi thẳng qua AVRCP tới iPhone (không qua app, chưa kiểm).
    public var onMusicCommand: ((MusicCommand) -> Void)?
    /// Gửi trạng thái trình phát (đang phát, tên bài…) lên thiết bị. Mặc định không làm gì.
    open func setMusicState(_ state: MusicState) async {}
    /// Gửi âm lượng điện thoại (0–100) lên thiết bị. Mặc định không làm gì.
    open func setMusicVolume(_ percent: Int) async {}

    // SmsQuickReply: iOS không cho app gửi SMS ngầm (MFMessageComposeViewController cần người dùng bấm gửi) nên
    // không có trên iOS. Giữ cờ để lớp React Native trả `supportsSmsReply = false`.

    /// Luôn false trên iOS.
    open var supportsSmsReply: Bool { false }

    // ContactsSync.

    /// Số liên hệ tối đa thiết bị nhận; 0 = không hỗ trợ danh bạ.
    open var maxContacts: Int { 0 }
    /// Thiết bị xoá được toàn bộ danh bạ bằng một lệnh (`clearContacts`).
    open var supportsClearContacts: Bool { false }
    /// Ghi danh bạ lên thiết bị (thay toàn bộ danh bạ cũ). `progress` 0–1. Trả về số liên hệ đã gửi.
    @discardableResult
    open func syncContacts(_ contacts: [Contact], progress: ((Double) -> Void)? = nil) async throws -> Int {
        throw GattError.operationFailed("Ghi danh bạ", "thiết bị không hỗ trợ")
    }
    /// Xoá toàn bộ danh bạ trên thiết bị.
    open func clearContacts() async throws { throw GattError.operationFailed("Xoá danh bạ", "thiết bị không hỗ trợ") }

    // CallAudioLink.

    /// Thiết bị gọi điện được qua Bluetooth cổ điển (HFP).
    open var supportsCallAudio: Bool { false }
    open func callAudioState() async throws -> CallAudioState {
        throw GattError.operationFailed("Đọc kênh gọi", "thiết bị không hỗ trợ")
    }
    /// Ghép đôi kênh gọi. iOS luôn ném `CallAudioPairingError` (người dùng ghép trong Cài đặt > Bluetooth).
    open func pairCallAudio() async throws { throw CallAudioPairingError(deviceName: nil) }
    /// Bật / tắt kênh gọi trên thiết bị.
    open func setCallAudio(_ on: Bool) async throws { throw GattError.operationFailed("Bật kênh gọi", "thiết bị không hỗ trợ") }

    // WatchFaceManager.

    /// Thiết bị nhận file mặt đồng hồ.
    open var supportsWatchFace: Bool { false }
    /// Thiết bị liệt kê / xoá được khe mặt đồng hồ đã cài.
    open var supportsWatchFaceSlots: Bool { false }
    open func watchFaceInfo() async throws -> WatchFaceInfo {
        throw GattError.operationFailed("Đọc mặt đồng hồ", "thiết bị không hỗ trợ")
    }
    /// Cài một file mặt đồng hồ dựng sẵn (định dạng riêng của hãng). `progress` 0–1.
    open func installWatchFace(_ file: Data, progress: @escaping (Double) -> Void = { _ in }) async throws {
        throw GattError.operationFailed("Cài mặt đồng hồ", "thiết bị không hỗ trợ")
    }
    open func watchFaceSlots() async throws -> [WatchFaceSlot] {
        throw GattError.operationFailed("Đọc khe mặt đồng hồ", "thiết bị không hỗ trợ")
    }
    open func deleteWatchFaceSlot(_ index: Int) async throws {
        throw GattError.operationFailed("Xoá mặt đồng hồ", "thiết bị không hỗ trợ")
    }

    // WorkoutRemote.

    /// Bắt đầu / tạm dừng / dừng bài tập từ điện thoại.
    open var supportsWorkoutControl: Bool { false }
    /// Đọc / chọn danh sách môn hiện trên thiết bị (`sportTypes`, `setSportList`).
    open var supportsSportList: Bool { false }
    /// Thiết bị xin vị trí điện thoại khi tập ngoài trời (`onLocationRequest` + `sendLocation`).
    open var supportsPhoneLocation: Bool { false }
    open func sportTypes() async throws -> [SportType] { throw GattError.operationFailed("Đọc danh sách môn", "thiết bị không hỗ trợ") }
    /// Số môn được hiện ít / nhiều nhất (đọc cùng `sportTypes`). nil = chưa đọc hoặc thiết bị không giới hạn.
    open var sportListLimits: ClosedRange<Int>? { nil }
    /// Danh mục mọi môn hãng biết (mã → tên). Thiết bị chỉ giữ một phần (`sportTypes`), không thêm được môn ngoài danh sách đó.
    open var sportCatalog: [SportName] { [] }
    /// Ghi danh sách môn (môn có `shown` = true hiện trên thiết bị, theo thứ tự trong mảng).
    open func setSportList(_ sports: [SportType]) async throws { throw GattError.operationFailed("Ghi danh sách môn", "thiết bị không hỗ trợ") }
    open func startWorkout(_ sportType: Int) async throws { throw GattError.operationFailed("Bắt đầu bài tập", "thiết bị không hỗ trợ") }
    open func pauseWorkout() async throws { throw GattError.operationFailed("Tạm dừng bài tập", "thiết bị không hỗ trợ") }
    open func resumeWorkout() async throws { throw GattError.operationFailed("Tiếp tục bài tập", "thiết bị không hỗ trợ") }
    open func stopWorkout() async throws { throw GattError.operationFailed("Dừng bài tập", "thiết bị không hỗ trợ") }
    /// Trạng thái + số liệu realtime của bài tập. App gán.
    public var onWorkoutEvent: ((WorkoutEvent) -> Void)?
    /// Thiết bị xin / thôi xin vị trí điện thoại. App gán, rồi gọi `sendLocation` mỗi vài giây khi `start`.
    public var onLocationRequest: ((LocationRequest) -> Void)?
    /// Gửi một điểm vị trí điện thoại (độ, mét, m/s). Thiết bị không dùng trường nào thì bỏ qua trường đó.
    open func sendLocation(latitude: Double, longitude: Double, altitude: Double? = nil, speed: Double? = nil, accuracy: Double? = nil) async throws {
        throw GattError.operationFailed("Gửi vị trí", "thiết bị không hỗ trợ")
    }

    // Nhịp tim liên tục. Mặc định không hỗ trợ.

    /// Thiết bị phát nhịp tim liên tục (`heartRateStream`), vd khi ghi bài chạy bằng GPS điện thoại.
    open var supportsHeartRateStream: Bool { false }
    /// Luồng nhịp tim tới khi bị huỷ (huỷ thì driver gửi lệnh dừng). Khác `measure`: không tự kết thúc, không tạo bài tập
    /// trên thiết bị. Mất kết nối thì luồng kết thúc / lỗi, bên gọi tự mở lại. Đừng chạy song song với `measure(.heartRate)`.
    open func heartRateStream() -> AsyncThrowingStream<HeartRateSample, Error> {
        AsyncThrowingStream { $0.finish(throwing: GattError.operationFailed("Nhịp tim liên tục", "thiết bị không hỗ trợ")) }
    }

    // AGPS (thiết bị có GPS riêng). Mặc định không hỗ trợ. SDK không gọi mạng: app tự lấy file dữ liệu vệ tinh.

    /// Thiết bị nhận AGPS (`agpsInfo`, `sendAgpsPosition`, `uploadAgpsFiles`).
    open var supportsAgps: Bool { false }
    /// Thiết bị hỏi AGPS (driver tự trả lời khi có vị trí / file đặt sẵn, xem `AgpsRequest.handled`). App gán.
    public var onAgpsRequest: ((AgpsRequest) -> Void)?
    /// Tên file thiết bị cần, phiên bản, dữ liệu vệ tinh còn hợp lệ không.
    open func agpsInfo() async throws -> AgpsInfo { throw GattError.operationFailed("Đọc AGPS", "thiết bị không hỗ trợ") }
    /// Vị trí điện thoại (WGS-84) lúc `timestamp`. Gửi ngay nếu đang kết nối; driver giữ lại để tự gửi khi thiết bị hỏi.
    open func sendAgpsPosition(latitude: Double, longitude: Double, timestamp: Date = Date()) async throws {
        throw GattError.operationFailed("Gửi vị trí AGPS", "thiết bị không hỗ trợ")
    }
    /// Gửi các file dữ liệu vệ tinh (một lần truyền gồm mọi file). `progress` 0–1.
    open func uploadAgpsFiles(_ files: [AgpsFile], progress: @escaping (Double) -> Void = { _ in }) async throws {
        throw GattError.operationFailed("Gửi AGPS", "thiết bị không hỗ trợ")
    }
    /// Đặt sẵn file (chỉ trong bộ nhớ) để driver tự trả lời "đã có file" và tự gửi khi thiết bị xin; nil = bỏ.
    open func setAgpsFiles(_ files: [AgpsFile]?) throws {}

    // Alarms (báo thức). Mặc định không hỗ trợ.

    /// Thiết bị đọc / ghi được báo thức (`alarms`, `setAlarm`, `deleteAlarm`).
    open var supportsAlarms: Bool { false }
    /// Số báo thức tối đa thiết bị giữ; 0 = không hỗ trợ.
    open var maxAlarms: Int { 0 }
    /// Đọc danh sách báo thức hiện có trên thiết bị.
    open func alarms() async throws -> [Alarm] { throw GattError.operationFailed("Đọc báo thức", "thiết bị không hỗ trợ") }
    /// Thêm (`alarm.id < 0`) hoặc sửa (trùng `id`) một báo thức.
    open func setAlarm(_ alarm: Alarm) async throws { throw GattError.operationFailed("Ghi báo thức", "thiết bị không hỗ trợ") }
    /// Xoá báo thức theo `id`.
    open func deleteAlarm(_ id: Int) async throws { throw GattError.operationFailed("Xoá báo thức", "thiết bị không hỗ trợ") }

    // DeviceEvents.

    /// Nút / sự kiện lẻ của thiết bị. App gán.
    public var onDeviceEvent: ((DeviceEvent) -> Void)?

    // MARK: Chẩn đoán kết nối

    /// Dòng thời gian sự kiện kết nối (bộ đệm vòng `timelineLimit` dòng): quảng bá, thử nối, link, notify, bắt tay,
    /// ngắt (kèm mã CBError), hẹn nối lại, đổi driver, thao tác người dùng.
    public private(set) var timeline = RingBuffer<ConnectionEvent>(capacity: WearableDevice.timelineLimit)
    /// Pha của lần kết nối hiện tại (`.idle` khi không thử).
    public private(set) var phase: ConnectPhase = .idle
    /// Lúc vào pha hiện tại.
    public private(set) var phaseSince: Date?
    /// Pha xa nhất của lần thử gần nhất (giữ lại sau khi lỗi để giải thích).
    public private(set) var lastAttemptPhase: ConnectPhase = .idle
    /// Lần cuối thấy gói quảng bá thật (có RSSI).
    public internal(set) var lastAdvert: Sighting?
    /// Lần cuối thấy iOS đang giữ kết nối thiết bị (`retrieveConnectedPeripherals`).
    public internal(set) var lastSystemSighting: Sighting?
    /// Lỗi kết nối / mất kết nối gần nhất (giữ cả sau khi nối lại được, để xem lại).
    public internal(set) var lastFailure: ConnectionFailure?
    /// Giải thích vấn đề hiện tại + việc nên làm (do `DeviceManager` cập nhật). nil khi đang kết nối tốt.
    public internal(set) var diagnosis: Diagnosis?
    /// Lúc bắt đầu lần thử kết nối gần nhất và có phải người dùng bấm không.
    public internal(set) var attemptStartedAt: Date?
    public internal(set) var attemptInteractive = false
    /// Lần gần nhất thiết bị sẵn sàng (lỗi cũ hơn mốc này không còn là vấn đề hiện tại).
    public private(set) var lastReadyAt: Date?

    public nonisolated static let timelineLimit = 200
    /// Ghi sự kiện "quảng bá" lên dòng thời gian tối đa một lần mỗi chừng này giây (quét gửi nhiều gói/giây).
    public var sightingLogInterval: TimeInterval = 20
    private var lastSightingLogged: Date?
    /// `DeviceManager` nhận mọi sự kiện của thiết bị để ghi nhật ký chung.
    var eventListener: ((ConnectionEvent) -> Void)?

    public var logLimit = 300
    public var trailLength = 28
    public private(set) var connection: GattConnection?
    private var rate = PacketRateWindow(window: 5)
    private var logSeq = 0
    private var measureTasks: [Capability: Task<Void, Never>] = [:]
    /// (trạng thái cũ, trạng thái mới) mỗi lần `state` đổi. `DeviceManager` dùng để phát hiện mất kết nối.
    var stateListener: ((ConnectionState, ConnectionState) -> Void)?

    /// Giới hạn pha nối link của lần `connect` tới (xem `GattConnection.linkTimeout`). nil = chờ đến khi thiết bị
    /// xuất hiện. Không có kết nối GATT gắn kèm thì bỏ qua.
    public var linkTimeout: TimeInterval? {
        get { connection?.linkTimeout }
        set { connection?.linkTimeout = newValue }
    }

    public init(id: UUID, driverId: String, name: String, kind: DeviceKind, mac: String? = nil) {
        self.id = id
        self.driverId = driverId
        self.name = name
        self.kind = kind
        self.mac = mac
    }

    // MARK: - Hợp đồng cho driver

    /// Kết nối và bắt tay. Driver override, gán `state`, `info`, `capabilities`, `battery`.
    open func connect() async throws { throw GattError.operationFailed("Kết nối", "driver chưa cài đặt") }

    open func disconnect() {
        cancelAllMeasurements()
        // Qua DISCONNECTING để DeviceManager biết đây là ngắt chủ động, không tự nối lại.
        if state != .disconnected { state = .disconnecting }
        connection?.disconnect()
        state = .disconnected
    }

    open func refreshBattery() async throws {}

    /// Luồng kết quả đo của một capability. Kết thúc khi đo xong / chưa đeo / lỗi; huỷ (dừng lặp) thì
    /// driver tự gửi lệnh dừng.
    open func measure(_ capability: Capability) -> AsyncThrowingStream<Reading, Error> {
        AsyncThrowingStream { $0.finish(throwing: GattError.operationFailed("Đo", "không hỗ trợ \(capability.rawValue)")) }
    }

    /// Các capability đo trực tiếp được (thứ tự hiển thị). Các capability còn lại là dữ liệu đồng bộ.
    open var measurableCapabilities: [Capability] { [] }

    /// Thiết bị có lưu dữ liệu lịch sử để đồng bộ không. Driver có lịch sử override cùng `syncHistoryImpl`.
    open var supportsHistory: Bool { false }

    /// Driver cài đặt: đồng bộ `days` ngày gần nhất, báo tiến độ qua `progress`. Bước lỗi ghi vào `errors`.
    open func syncHistoryImpl(days: Int, progress: @escaping @MainActor (SyncProgress) -> Void) async throws -> DeviceHistory {
        DeviceHistory(errors: ["Thiết bị này không lưu dữ liệu lịch sử"])
    }

    /// Đồng bộ lịch sử `days` ngày gần nhất (1 = hôm nay). Kết quả ở `history`; lỗi từng bước ghi vào nhật ký gói.
    /// Ném lỗi nếu đang đồng bộ hoặc driver ném (vd chưa kết nối).
    @discardableResult
    public func syncHistory(days: Int = 7) async throws -> DeviceHistory {
        guard syncProgress == nil else { throw GattError.operationFailed("Đồng bộ", "đang đồng bộ") }
        syncProgress = SyncProgress(step: "Bắt đầu", done: 0, total: 1)
        defer { syncProgress = nil }
        let result = try await syncHistoryImpl(days: days) { [weak self] p in self?.syncProgress = p }
        history = result
        lastSyncedAt = result.syncedAt
        for e in result.errors {
            record(.error, "", Data(), "Đồng bộ: \(e)")
            SmartWearLog.w("[\(name)] đồng bộ: \(e)")
        }
        logEvent(.user, "Đồng bộ \(result.days) ngày xong: \(result.summary)")
        return result
    }

    /// Nạp lịch sử đã lưu (không đè dữ liệu mới hơn).
    func restoreHistory(_ saved: DeviceHistory) {
        guard history.map({ $0.syncedAt < saved.syncedAt }) ?? true else { return }
        history = saved
        lastSyncedAt = saved.syncedAt
    }

    // MARK: - Tiện ích cho UI

    public var isConnected: Bool { state == .connected }

    public func supports(_ capability: Capability) -> Bool { capabilities.contains(capability) }

    /// Bắt đầu đo (nếu chưa đo) và cập nhật `latest`/`trail`. Trả về Task để chờ kết thúc.
    @discardableResult
    public func startMeasuring(_ capability: Capability, onReading: ((Reading) -> Void)? = nil) -> Task<Void, Never> {
        if let running = measureTasks[capability] { return running }
        measuring.insert(capability)
        trail[capability] = []
        latest[capability] = Reading(capability: capability, status: .measuring, unit: lastResult[capability]?.unit ?? "")
        let stream = measure(capability)
        let task = Task { @MainActor [weak self] in
            do {
                for try await reading in stream {
                    guard let self else { return }
                    self.apply(reading)
                    onReading?(reading)
                }
            } catch is CancellationError {
            } catch {
                self?.latest[capability] = Reading(capability: capability, status: .error, unit: "", note: error.localizedDescription)
                self?.lastError = error.localizedDescription
                self?.stats.errors += 1
            }
            self?.finishMeasuring(capability)
        }
        measureTasks[capability] = task
        return task
    }

    public func stopMeasuring(_ capability: Capability) {
        measureTasks[capability]?.cancel()
    }

    public func cancelAllMeasurements() {
        for task in measureTasks.values { task.cancel() }
    }

    private func apply(_ reading: Reading) {
        let previous = latest[reading.capability]
        latest[reading.capability] = reading
        if reading.status == .ok, reading.hasValue { lastResult[reading.capability] = reading }
        if let v = reading.value ?? reading.systolic.map(Double.init) ?? reading.signal {
            // Tín hiệu thô và kết quả khác thang đo: khi có kết quả đầu tiên thì cột chuyển sang kết quả.
            let firstResult = reading.status == .ok && previous?.status != .ok
            var t = firstResult ? [] : (trail[reading.capability] ?? [])
            t.append(v)
            if t.count > trailLength { t.removeFirst(t.count - trailLength) }
            trail[reading.capability] = t
        }
    }

    private func finishMeasuring(_ capability: Capability) {
        measuring.remove(capability)
        measureTasks[capability] = nil
        // Dừng giữa chừng (chưa có kết quả mới) thì quay về kết quả hợp lệ gần nhất.
        if latest[capability]?.status == .measuring { latest[capability] = lastResult[capability] }
    }

    // MARK: - Dành cho driver

    /// Gắn kết nối GATT để ghi nhật ký gói tin, đếm gói và đọc RSSI.
    public func attach(_ connection: GattConnection) {
        self.connection = connection
        connection.onTraffic = { [weak self] dir, uuid, data, note in
            self?.record(dir, uuid?.short ?? "", data, note)
        }
        connection.onEvent = { [weak self] kind, level, message, code in
            self?.logEvent(kind, message, level: level, code: code)
        }
        connection.onPhase = { [weak self] p in
            guard let self else { return }
            // GATT đã sẵn sàng nhưng thiết bị còn bắt tay: pha `.setup`; về `.idle` chỉ khi thiết bị chưa CONNECTED.
            if p == .idle, self.state == .connected { return }
            self.setPhase(p)
        }
        connection.onLinkLost = { [weak self] error in
            guard let self else { return }
            self.lastFailure = ConnectionFailure(error: error, phase: .ready, lostAfterConnected: true)
        }
        connection.onStateChange = { [weak self] s in
            guard let self else { return }
            // Trạng thái thiết bị do driver quyết (CONNECTED sau bắt tay), chỉ phản ánh rớt kết nối.
            if s == .disconnected, self.state != .disconnected {
                self.state = .disconnected
                self.connectedAt = nil
                self.cancelAllMeasurements()
            }
        }
    }

    public func record(_ direction: TrafficDirection, _ channel: String, _ data: Data, _ note: String? = nil) {
        logSeq += 1
        log.append(PacketLogEntry(id: logSeq, time: Date(), direction: direction, channel: channel, hex: data.hex, note: note))
        if log.count > logLimit { log.removeFirst(log.count - logLimit) }
        switch direction {
        case .rx:
            let now = Date()
            rate.record(at: now)
            stats.packetsReceived += 1
            stats.packetsPerSecond = rate.rate(now: now)
            pulse &+= 1
        case .error:
            stats.errors += 1
        case .tx, .info:
            break
        }
    }

    public func recordLatency(since start: Date) {
        stats.lastLatencyMs = Int(Date().timeIntervalSince(start) * 1000)
    }

    public func markConnected() {
        state = .connected
        connectedAt = Date()
        lastError = nil
        rate.reset()
        lastReadyAt = connectedAt
        setPhase(.ready)
    }

    // MARK: - Chẩn đoán

    /// Ghi một sự kiện lên dòng thời gian của thiết bị (và nhật ký chung của `DeviceManager`).
    public func logEvent(
        _ kind: ConnectionEventKind, _ message: String, level: ConnectionEventLevel = .info, code: BleErrorCode? = nil
    ) {
        let e = ConnectionEvent(deviceId: id, deviceName: name, kind: kind, level: level, message: message, code: code)
        timeline.append(e)
        eventListener?(e)
        if level != .info || SmartWearLog.echoing { SmartWearLog.d("[\(name)] \(kind.rawValue): \(message)") }
    }

    /// Driver ghi một bước bắt tay (driver có `GattConnection` dùng `GattConnection.noteStep`).
    public func noteStep(_ message: String, level: ConnectionEventLevel = .info) {
        logEvent(.handshake, message, level: level)
    }

    /// Đặt pha kết nối. Driver không dùng `GattConnection` tự gọi; `GattConnection` gắn qua `attach`.
    public func setPhase(_ p: ConnectPhase, at now: Date = Date()) {
        guard p != phase else { return }
        phase = p
        phaseSince = now
        if p != .idle { lastAttemptPhase = p }
    }

    /// Bắt đầu một lần thử kết nối (do `DeviceManager` gọi trước `connect()`).
    func beginAttempt(interactive: Bool, attempt: Int? = nil, at now: Date = Date()) {
        attemptStartedAt = now
        attemptInteractive = interactive
        lastAttemptPhase = .idle
        let limit = linkTimeout.map { "chờ link tối đa \(Int($0)) s" } ?? "chờ link không giới hạn (đến khi thiết bị xuất hiện)"
        let who = interactive ? "Người dùng bấm kết nối" : "Tự nối lại" + (attempt.map { " lần \($0)" } ?? "")
        logEvent(.attempt, "\(who), \(limit)")
    }

    /// Ghi nhận thiết bị vừa được quét thấy (gói quảng bá hoặc hệ thống đang giữ).
    func noteSighting(rssi: Int?, systemConnected: Bool, connectable: Bool? = nil, at now: Date = Date()) {
        let s = Sighting(time: now, rssi: rssi, systemConnected: systemConnected)
        // Cập nhật tối đa ~1 lần/giây để UI không vẽ lại theo từng gói.
        func due(_ old: Sighting?) -> Bool { old.map { now.timeIntervalSince($0.time) >= 1 } ?? true }
        if systemConnected {
            if due(lastSystemSighting) { lastSystemSighting = s }
        } else if due(lastAdvert) {
            lastAdvert = s
        }
        guard lastSightingLogged.map({ now.timeIntervalSince($0) >= sightingLogInterval }) ?? true else { return }
        lastSightingLogged = now
        let kind = connectable.map { $0 ? ", cho phép nối" : ", KHÔNG cho phép nối" } ?? ""
        logEvent(.sighting, systemConnected ? "iOS đang giữ kết nối thiết bị (không có quảng bá)" : "Thấy quảng bá, RSSI \(rssi.map { "\($0) dBm" } ?? "?")\(kind)")
    }

    /// Mã lỗi Bluetooth trên dòng thời gian trong `within` giây gần nhất.
    public func recentErrorCodes(within: TimeInterval = 60, now: Date = Date()) -> [BleErrorCode] {
        timeline.elements.reversed().prefix { now.timeIntervalSince($0.time) <= within }.compactMap(\.code)
    }

    /// Chép dòng thời gian từ thiết bị cũ (khi `DeviceManager` dựng lại với driver đúng).
    func inheritDiagnostics(from old: WearableDevice) {
        timeline = old.timeline
        lastAdvert = old.lastAdvert
        lastSystemSighting = old.lastSystemSighting
        lastFailure = old.lastFailure
    }

    /// Gọi định kỳ (DeviceManager mỗi giây) để gói/giây giảm về 0 khi im lặng.
    public func tickStats(now: Date = Date()) {
        rate.prune(now: now)
        let r = rate.rate(now: now)
        if r != stats.packetsPerSecond { stats.packetsPerSecond = r }
    }

    /// Đọc RSSI qua kết nối đang mở. Bỏ qua khi `BleQuiet.active` (đang truyền file lớn).
    public func updateRSSI() async {
        guard isConnected, !BleQuiet.active, let connection else { return }
        if let rssi = try? await connection.readRSSI(), rssi != 127 { stats.rssi = rssi }
    }
}

/// Sự kiện chụp ảnh từ xa do thiết bị gửi.
public enum RemoteCameraEvent: Sendable, Equatable {
    /// Bấm nút chụp trên thiết bị.
    case shutter
    /// Người dùng mở màn chụp trên thiết bị: app nên mở camera.
    case opened
    /// Người dùng đóng màn chụp trên thiết bị.
    case closed
}
