import CoreBluetooth
import Foundation
import SmartWearCore

/// Driver cho thiết bị dùng app GloryFit (SDK UTE), ví dụ đồng hồ Y25, HT43 (bản iOS của `GloryFitDriver.kt`).
/// iOS không có MAC: nhận diện bằng UUID 0x55xx trong quảng bá hoặc tên.
public struct GloryFitDriver: DeviceDriver {
    public static let driverId = "gloryfit"
    public let id = GloryFitDriver.driverId
    public let displayName = "GloryFit (UTE)"

    public init() {}

    /// Đồng hồ có thể đang được hệ thống nối sẵn (BT Classic gọi điện), khi đó không quảng bá nữa.
    /// Đồng hồ iOS đang giữ (ghép đôi thông báo / gọi BT) ngừng quảng bá; app GloryFit iOS tìm qua 55FF và 55F0.
    public var systemServices: [CBUUID] { [Ute.service, CBUUID(string: "55F0")] }

    public func match(_ scanned: ScannedDevice) -> DriverMatch? {
        guard Ute.matches(scanned) else { return nil }
        return DriverMatch(driverId: id, model: Ute.model(fromName: scanned.name), kind: .watch)
    }

    @MainActor
    public func create(_ scanned: ScannedDevice, match: DriverMatch) -> WearableDevice {
        GloryFitDevice(scanned: scanned, match: match)
    }
}

/// Nút gỡ lỗi (truyền mặt đồng hồ, đặt giờ). Mặc định không đổi hành vi.
public enum GloryFitDebug {
    /// Ghi log thời gian từng khối 4 KB và mọi gói `26 …` nhận giữa khối.
    nonisolated(unsafe) public static var trace = false
    /// Ép độ dài gói `27` (gồm 3 byte đầu); nil = theo bảng tính năng và độ dài ghi tối đa.
    nonisolated(unsafe) public static var packetLength: Int?
    /// Nghỉ sau mỗi gói (ms); 0 = nhịp như app gốc (20 ms mỗi 10 gói).
    nonisolated(unsafe) public static var packetDelayMs = 0
    /// Tắt lần gửi lại tự động khi đồng hồ huỷ giữa chừng.
    nonisolated(unsafe) public static var noRetry = false
    /// Gửi `A3` 9 byte (thêm giờ lệch GMT như SDK iOS gốc, doc 09 §1.5). Chưa kiểm chứng trên Y25/HT43 nên mặc định tắt.
    nonisolated(unsafe) public static var timeZoneByte = false
    /// In mọi gói `FD` của luồng đồng bộ bài tập (hex), để đối chiếu bản ghi có GPS với `UteWorkoutRecord`.
    nonisolated(unsafe) public static var workoutPackets = false

    /// Trạng thái trả lời khi đồng hồ hỏi AGPS (`01 E9 AC 03 01 02`) mà app chưa đặt file: 5 = không hỗ trợ (mặc định, để
    /// đồng hồ thôi hỏi mỗi 60 s; **chưa kiểm trên máy**), 1 = đang chuẩn bị (GloryFitPro gửi khi chưa có file), nil = không trả lời.
    nonisolated(unsafe) public static var agpsNoFileStatus: Int? = UteAgps.statusNotSupport
}

/// Yêu cầu người dùng trong lúc bind. Core iOS chưa có khái niệm `PairingPrompt` nên để ở driver.
public enum GloryFitPairingPrompt: Equatable, Sendable {
    /// Đồng hồ hiện mã, người dùng nhập vào app rồi gọi `submitPairingCode`.
    case enterCode(digits: Int, message: String)
    /// Đồng hồ hỏi xác nhận, người dùng bấm trên đồng hồ.
    case confirmOnDevice(message: String)
}

/// Một đồng hồ GloryFit được quản lý: bắt tay (bind, A3 giờ, A1 firmware, A2 pin, A0 đơn vị, A9 người dùng),
/// đo trực tiếp theo bảng tính năng, cài mặt đồng hồ `.bin`.
@MainActor
public final class GloryFitDevice: WearableDevice {
    public let gatt: GattConnection
    public let model: String
    /// Tên trong gói quảng bá (iOS không cho đọc MAC).
    public let advertisedName: String?
    public private(set) var features = Ute.Features()
    public private(set) var dialParams: Ute.DialParams?
    /// Yêu cầu bind đang chờ người dùng (nil = không có). TODO: UI SmartWear Lab chưa hiển thị.
    public private(set) var pairingPrompt: GloryFitPairingPrompt? {
        didSet {
            if oldValue != pairingPrompt { onPairingPrompt?(pairingPrompt) }
        }
    }
    public var onPairingPrompt: ((GloryFitPairingPrompt?) -> Void)?

    private struct Waiter {
        let match: ([UInt8]) -> Bool
        let channel: PacketChannel
    }

    private let lock = AsyncLock()
    private var waiter: Waiter?
    private var subscribers: [UUID: ([UInt8]) -> Void] = [:]
    private var codeInput: OneShot<String>?
    private let defaults = UserDefaults(suiteName: "smartwear_gloryfit") ?? .standard
    /// Cài đặt người dùng (`UteSettings`), lưu theo thiết bị.
    public private(set) var settings = UteSettings()

    /// Cờ trong kết quả `uploadWatchFace`: đồng hồ báo lỗi trước khi gửi xong.
    private static let aborted = 0x100
    /// `26 03 03 HH LL`: SDK iOS gốc dừng 0,6 s rồi gửi lại từ gói HHLL (`dispatch_after` 0x23c34600 ns, doc 09 §3).
    private static let resendPauseNs: UInt64 = 600_000_000

    /// Nhịp tim đồng hồ tự đẩy gần nhất (`F7 03`/`F7 0B`/`E5 … rr`) và lúc nhận.
    private var lastPushedHr: Reading?
    private var lastPushedHrAt = Date.distantPast
    /// Lần bấm chụp gần nhất (chống chụp lặp).
    private var lastShutter = Date.distantPast
    private static let shutterGap: TimeInterval = 4
    /// Đã gửi `F7 01` + `F7 09` trong lần kết nối này.
    private var hr24Configured = false
    /// Chu kỳ đo HR 24h nhỏ nhất app iOS dùng (phút).
    private static let hr24IntervalMin = 5
    /// Giá trị đồng hồ đẩy còn coi là "vừa đo".
    private static let hrRecent: TimeInterval = 10 * 60
    /// Chờ tối đa một chu kỳ đo + 1 phút.
    private static let hr24Wait: TimeInterval = TimeInterval(hr24IntervalMin + 1) * 60
    /// Thời gian để Y25 đo một lần theo lệnh `E5 11` trước khi app gửi `E5 00` lấy kết quả (25 s cho 82 bpm khi thử).
    private static let hrManualWindow: TimeInterval = 25
    private static let hr24Note = "Đồng hồ tự đo theo chu kỳ — đo trên đồng hồ để có kết quả ngay"

    /// Gửi bài đang phát lần lượt (các gói `3A` không được xen nhau).
    private let musicLock = AsyncLock()
    /// Âm lượng gửi lần trước (chọn `D1 0D` hay `D1 0E`).
    private var lastVolume: Int?
    /// Bài tập đang chạy (để điền thời gian trong `FD 22/33` và môn trong `FD 00`).
    private var workout: WorkoutClock?
    /// Phiên gửi vị trí điện thoại (đặt lại mỗi lần đồng hồ xin / thôi xin).
    private var location = LocationSession()
    /// Số môn hiện ít / nhiều nhất trên đồng hồ (đọc từ `FD 48 AA`).
    private var readSportListLimits: ClosedRange<Int>?

    public init(scanned: ScannedDevice, match: DriverMatch) {
        gatt = GattConnection(id: scanned.id)
        model = match.model ?? Ute.model(fromName: scanned.name)
        advertisedName = scanned.name
        super.init(id: scanned.id, driverId: GloryFitDriver.driverId, name: scanned.name ?? model, kind: match.kind)
        info = DeviceInfo(model: model, extra: baseExtra())
        attach(gatt)
        // Như SDK UTE iOS gốc (`connectPeripheral:options:` luôn có `EnableTransportBridging = YES`, doc 09 §1.4).
        // Kiểm chứng 16/10/2026 trên Y25 đã ghép kênh gọi: tắt bridging rồi app tự ngắt BLE ⇒ đồng hồ (vẫn nối cổ điển
        // với iPhone) thôi quảng bá BLE hẳn, app không nối lại được (Mac mini cũng không thấy gói nào).
        gatt.transportBridging = true
        gatt.onNotification = { [weak self] uuid, data in self?.onNotification(uuid, data) }
        // Nhịp tim đồng hồ tự đẩy: `F7 03 …` (24h), `F7 0B …` (đo trên đồng hồ, doc 09 §2.2) hoặc `E5 11 00 rr`
        // khi đo trên chính đồng hồ (kiểm chứng trên Y25), nên hiển thị cả khi app không chạy phép đo.
        _ = subscribe { [weak self] p in
            guard let self, let r = Ute.parsePushedHeartRate(p) ?? Ute.parseLiveHeartRate(p) else { return }
            self.lastPushedHr = r
            self.lastPushedHrAt = Date()
            self.publish(r)
        }
        settings = UteSettings.decode(defaults.string(forKey: settingsKey))
        // Chụp ảnh từ xa: `C4 02` (GloryFit `BluetoothLeService` → OnResult 21) hoặc `D1 03` (GloryFitPro) = bấm chụp;
        // `D1 11` / `D1 0F` = người dùng mở / đóng màn chụp trên đồng hồ. Bỏ lần chụp lặp trong `shutterGap`
        // (GloryFit `FragmentHomePage`: `isTakePhoto` khoá 4 s).
        _ = subscribe { [weak self] p in
            guard let self, p.count >= 2 else { return }
            let event: RemoteCameraEvent?
            switch (p[0], p[1]) {
            case (0xC4, 0x02), (0xD1, 0x03): event = .shutter
            case (0xD1, 0x11): event = .opened
            case (0xD1, 0x0F): event = .closed
            default: event = nil
            }
            guard let event else { return }
            if event == .shutter {
                guard Date().timeIntervalSince(self.lastShutter) >= Self.shutterGap else { return }
                self.lastShutter = Date()
            }
            self.onRemoteCamera?(event)
        }
        // Nhạc `D1 07/08/09/0D/0E`, từ chối cuộc gọi `D1 02`, nút `D1 01/04/05/06` (Pro `uterkchar.java:139-215`).
        _ = subscribe { [weak self] p in
            guard let self, p.first == 0xD1 else { return }
            if let cmd = UteMusic.parseCommand(p) { self.onMusicCommand?(cmd) }
            if UteSystem.isRejectCall(p) { self.onRejectCall?() }
            if let e = UteSystem.parseButton(p) { self.onDeviceEvent?(e) }
        }
        // Bài tập điều khiển từ điện thoại, số liệu realtime, xin vị trí điện thoại (`FD …` ngoài luồng đồng bộ).
        _ = subscribe { [weak self] p in self?.handleSportPacket(p) }
        // AGPS: đồng hồ có GNSS hỏi dữ liệu vệ tinh / vị trí điện thoại (`01 E9 AC …`).
        _ = subscribe { [weak self] p in self?.handleAgpsPacket(p) }
        // `D1 0A` (2 byte): đồng hồ bắt đầu tìm điện thoại; `D1 0A xx 00` (4 byte): dừng (`BluetoothLeService`).
        // `D1 0A xx 01` là đồng hồ dội lại `setPhoneRinging(true)`, không phải lệnh dừng.
        _ = subscribe { [weak self] p in
            guard p.count >= 2, p[0] == 0xD1, p[1] == 0x0A, p.count == 2 || (p.count == 4 && p[3] == 0) else { return }
            self?.onFindPhone?(p.count == 2)
        }
    }

    private var settingsKey: String { "settings_\(id.uuidString)" }

    override public var measurableCapabilities: [Capability] {
        [.heartRate, .spo2, .bloodPressure, .temperature].filter { capabilities.contains($0) }
    }

    override public var supportsHistory: Bool { true }

    /// Chọn lệnh theo bảng tính năng và đồng bộ, xem `GloryFitHistory.swift`.
    override public func syncHistoryImpl(days: Int, progress: @escaping @MainActor (SyncProgress) -> Void) async throws -> DeviceHistory {
        try await runHistorySync(days: days, progress: progress)
    }

    // MARK: - Kết nối + bind

    override public func connect() async throws {
        guard state == .disconnected else { return }
        state = .connecting
        lastError = nil
        hr24Configured = false
        do {
            let started = Date()
            try await gatt.connect()
            recordLatency(since: started)
            gatt.onDisconnected = { [weak self] error in
                guard let self else { return }
                self.lastError = "Mất kết nối" + (error.map { ": \($0.localizedDescription)" } ?? "")
                self.waiter?.channel.close(GattError.disconnected)
            }
            guard gatt.hasService(Ute.service) else { throw GloryFitError("Không có service 55FF: không phải thiết bị UTE") }
            try await gatt.setNotify(Ute.service, Ute.notify)
            let hasBle5 = gatt.hasService(Ute.service5)
            if hasBle5 { try? await gatt.setNotify(Ute.service5, Ute.notify5) }
            let main = try? await gatt.read(Ute.service, Ute.write)
            let ble5 = hasBle5 ? try? await gatt.read(Ute.service5, Ute.write5) : nil
            // `try?` nuốt cả lỗi huỷ: bị huỷ giữa chừng thì dừng hẳn, không đánh dấu "đã kết nối" với bảng rỗng.
            try Task.checkCancellation()
            // Không có bảng tính năng thì không biết thiết bị làm được gì: coi là nối lỗi để vòng giữ kết nối thử lại.
            guard main != nil else { throw GloryFitError("Không đọc được bảng tính năng 33F1") }
            features = Ute.Features.parse(main: main.map { [UInt8]($0) }, ble5: ble5.map { [UInt8]($0) })
            // iOS tự thương lượng MTU (không có requestMtu như Android).
            SmartWearLog.i("[\(name)] tính năng 33F1=\(main?.hex ?? "-") 34F1=\(ble5?.hex ?? "-")")
            gatt.noteStep("Bảng tính năng 33F1 \(main == nil ? "không đọc được" : "OK")\(hasBle5 ? ", 34F1 \(ble5 == nil ? "không đọc được" : "OK")" : "")")

            try await bind()
            gatt.noteStep("Bind xong (\(features.usesPairingCode ? "mã 4 số" : features.usesAccountId ? "account ID" : "không cần"))")

            // `A3` 8 byte (Y25/HT43 đã phản hồi). Byte múi giờ như SDK iOS gốc chỉ gửi khi bật GloryFitDebug.timeZoneByte.
            let now = Date()
            let tz = GloryFitDebug.timeZoneByte ? Ute.tzHours(.current, at: now) : nil
            do {
                _ = try await request(Ute.setTime(now, tzHours: tz)) { $0.first == 0xA3 }
            } catch {
                record(.error, "", Data(), "Đặt giờ không có phản hồi")
                gatt.noteStep("Đặt giờ A3 không có phản hồi", level: .warning)
            }
            let firmware = (try? await request([0xA1]) { $0.first == 0xA1 && $0.count > 2 }).map {
                String(decoding: $0.dropFirst(), as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\u{0} "))
            }

            try Task.checkCancellation()
            capabilities = features.capabilities()
            var di = DeviceInfo(model: model, manufacturer: "UTE (GloryFit)", firmware: firmware, extra: baseExtra())
            di.setExtra("Bảng tính năng 33F1", main?.hex ?? "không đọc được")
            di.setExtra("Bảng tính năng 34F1", ble5?.hex ?? "không có")
            di.setExtra("Kiểu bind", features.usesPairingCode ? "Mã 4 số" : features.usesAccountId ? "Account ID" : "Không cần")
            di.setExtra("Độ dài gói tối đa", features.maxPacketLength.map(String.init) ?? "20")
            di.setExtra("Độ dài ghi iOS", "\(gatt.maximumWriteLength(withResponse: false))")
            info = di
            do {
                try await refreshBattery()
            } catch {
                record(.error, "", Data(), "Đọc pin lỗi: \(error.localizedDescription)")
            }
            // Như app GloryFit: gửi đơn vị và thông tin người dùng trước khi đo/đồng bộ
            // (thiếu A0 + A9 thì Y25 không trả lời E5 11).
            if (try? await request(UteControls.units(settings)) { $0.first == 0xA0 }) == nil {
                SmartWearLog.w("[\(name)] A0 không có phản hồi")
            }
            if (try? await request(UteControls.userInfo(settings)) { $0.first == 0xA9 }) == nil {
                SmartWearLog.w("[\(name)] A9 không có phản hồi")
            }
            if features.heartRateByPush && settings.on("hr24.enabled") { await configureHeartRate24h() }
            // Như GloryFitPro: đọc ngôn ngữ hiện tại + danh sách hỗ trợ (`AF AA`) để mục chọn khớp đồng hồ.
            if features.language, let p = try? await request([0xAF, 0xAA], match: { $0.count == 20 && $0[0] == 0xAF && $0[1] == 0xAA }),
               let l = Ute.parseLanguages(p) {
                settings = settings.withWatchLanguages(current: l.current, masks: l.masks)
                defaults.set(settings.encode(), forKey: settingsKey)
            }
            // Như GloryFitPro `syncDeviceMonitorSetting`: gửi lại công tắc + chu kỳ SpO2 tự động mỗi lần kết nối.
            if features.spo2Auto {
                for cmd in UteControls.commands("spo2Auto.enabled", features, settings) { try? await writeCommand(cmd) }
            }
            // Như GloryFitPro (`RkSupportUtils:226-266`): đọc phím tắt nhanh để biết cài đặt nào đổi được trên đồng hồ.
            await readShortcuts()
            workout = nil
            location = LocationSession()
            controls = UteControls.controls(features, settings)
            try Task.checkCancellation()
            gatt.noteStep("Bắt tay UTE xong, firmware \(firmware ?? "?")")
            markConnected()
            await updateRSSI()
        } catch {
            pairingPrompt = nil
            state = .disconnected
            // Huỷ (người dùng ngắt khi đang chờ nối) không phải lỗi.
            lastError = error is CancellationError ? nil : "Kết nối lỗi: \(error.localizedDescription)"
            gatt.disconnect()
            throw error
        }
    }

    private func baseExtra() -> [(key: String, value: String)] {
        [("Driver", "GloryFit / UTE (sdks/gloryfit)"), ("Tên quảng bá", advertisedName ?? "không có"), ("UUID iOS", id.uuidString)]
    }

    private func bind() async throws {
        defer { pairingPrompt = nil }
        if features.usesPairingCode {
            try await bindWithCode()
        } else if features.usesAccountId {
            try await bindWithAccountId()
        } else {
            SmartWearLog.i("[\(name)] thiết bị không yêu cầu bind")
        }
    }

    /// Luồng mã 4 số: đồng hồ hiện mã, người dùng nhập vào app (`submitPairingCode`). Mã đúng được lưu cho lần sau.
    /// Chưa kiểm chứng trên thiết bị thật (Y25, HT43 không cần bind).
    private func bindWithCode() async throws {
        let key = "code_\(id.uuidString)"
        if let saved = defaults.string(forKey: key), let packet = try? Ute.pairingCode(saved) {
            let rsp = try? await request(packet) { $0.first == 0xD5 }
            if let rsp, rsp.count >= 2, rsp[1] == 0x01 { return }
            defaults.removeObject(forKey: key)
        }
        _ = try? await request([0xD5, 0x02], timeout: 10) { $0.first == 0xD5 }
        for attempt in 0..<3 {
            let input = OneShot<String>()
            codeInput = input
            pairingPrompt = .enterCode(
                digits: 4,
                message: attempt == 0 ? "Nhập mã 4 số đang hiện trên \(name)" : "Mã chưa đúng, nhập lại mã trên \(name)"
            )
            record(.info, "", Data(), "Chờ nhập mã 4 số trên đồng hồ")
            let code = try await input.wait(timeout: 120) { GloryFitError("Hết thời gian nhập mã") }
            codeInput = nil
            pairingPrompt = nil
            let rsp = try await request(try Ute.pairingCode(code), timeout: 10) { $0.first == 0xD5 }
            switch rsp.count >= 2 ? rsp[1] : 0xFF {
            case 0x01:
                defaults.set(code, forKey: key)
                return
            case 0x03:
                throw GloryFitError("Đồng hồ báo hết thời gian ghép mã")
            default:
                continue  // 0xFF: sai mã, hỏi lại
            }
        }
        throw GloryFitError("Nhập sai mã quá 3 lần")
    }

    /// Luồng Account ID: gửi id, đồng hồ hỏi người dùng xác nhận rồi trả `33 04 01`. Chưa kiểm chứng trên thiết bị thật.
    private func bindWithAccountId() async throws {
        let key = "id_\(id.uuidString)"
        let saved = defaults.integer(forKey: key)
        let accountId = saved > 0 ? saved : Int.random(in: 1..<99_999_999)
        try await lock.withLock {
            let channel = PacketChannel()
            waiter = Waiter(match: { $0.count >= 3 && $0[0] == 0x33 && $0[1] == 0x04 }, channel: channel)
            defer { waiter = nil }
            try await writeCommand(Ute.accountId(accountId))
            let deadline = Date().addingTimeInterval(90)
            while true {
                guard let rsp = try await channel.receive(timeout: deadline.timeIntervalSinceNow) else {
                    throw GloryFitError("Đồng hồ không xác nhận trong 90 giây")
                }
                switch rsp[2] {
                case 0x01:
                    defaults.set(accountId, forKey: key)
                    return
                case 0x02:
                    defaults.set(accountId, forKey: key)
                case 0x03, 0x04:
                    pairingPrompt = .confirmOnDevice(message: "Bấm đồng ý trên \(name) để kết nối")
                case 0x05:
                    throw GloryFitError("Người dùng từ chối trên đồng hồ")
                default:
                    break
                }
            }
        }
    }

    /// Mã 4 số người dùng đọc trên đồng hồ (khi `pairingPrompt` là `.enterCode`).
    public func submitPairingCode(_ code: String) {
        codeInput?.succeed(code.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    override public func disconnect() {
        cancelAllMeasurements()
        codeInput?.fail(CancellationError())
        codeInput = nil
        pairingPrompt = nil
        state = .disconnecting
        // Để lệnh dừng đo kịp gửi trước khi ngắt.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            self.waiter?.channel.close(GattError.disconnected)
            self.gatt.disconnect()
            self.state = .disconnected
        }
    }

    override public func refreshBattery() async throws {
        let p = try await request([0xA2]) { $0.first == 0xA2 && $0.count >= 2 }
        battery = min(Int(p[1]), 100)
    }

    // MARK: - Đo trực tiếp

    override public func measure(_ capability: Capability) -> AsyncThrowingStream<Reading, Error> {
        guard measurableCapabilities.contains(capability) else { return super.measure(capability) }
        switch capability {
        case .heartRate:
            // Đồng hồ HR 24h (Y25, HT43): app GloryFit iOS không đo theo lệnh, lấy giá trị đồng hồ tự đẩy (doc 09 §2).
            if features.heartRateByPush { return heartRateByPush() }
            // App GloryFit đo tĩnh: D6 01 (chọn chế độ tĩnh), chờ 1,5 s trên chip Realtek, rồi E5 11 (RateDetailsActivity:363-370).
            // Thiếu D6 01 thì Y25 bỏ qua E5 11 (kiểm chứng 2026-10-13).
            return live(capability, start: [0xE5, 0x11], stop: [0xE5, 0x00], ops: [0xE5, 0xF7], prepare: [0xD6, 0x01],
                        parse: Self.heartRatePacket)
        case .spo2:
            return live(capability, start: [0x34, 0x11], stop: [0x34, 0x00], ops: [0x34]) { p in
                guard p.count >= 2 else { return nil }
                let sub = p[1]
                guard sub == 0x11 || sub == 0x00 else { return nil }
                if p.count == 2 { return (Reading(capability: capability, status: .measuring, unit: "%"), false) }
                guard p.count >= 4 else { return nil }
                let done = sub == 0x00
                let valid = p[2] == 0 && (70...100).contains(p[3])
                if valid { return (Reading(capability: capability, status: .ok, value: Double(p[3]), unit: "%"), done) }
                return (Reading(capability: capability, status: done ? .notWorn : .measuring, unit: "%"), done)
            }
        case .bloodPressure:
            return live(capability, start: [0xC7, 0x11], stop: [0xC7, 0x00], ops: [0xC7]) { p in
                guard p.count >= 5 else { return (Reading(capability: capability, status: .measuring, unit: "mmHg"), false) }
                let done = p[1] == 0x00
                let valid = p[2] == 0 && p[3] > 0 && p[4] > 0
                if valid {
                    return (Reading(capability: capability, status: .ok, systolic: Int(p[3]), diastolic: Int(p[4]), unit: "mmHg"), done)
                }
                return (Reading(capability: capability, status: done ? .notWorn : .measuring, unit: "mmHg"), done)
            }
        case .temperature:
            return AsyncThrowingStream { continuation in
                let task = Task { @MainActor [weak self] in
                    continuation.yield(Reading(capability: .temperature, status: .measuring, unit: "°C"))
                    guard let self else { return continuation.finish() }
                    do {
                        let p = try await self.request([0x24, 0x01], timeout: 8) { $0.first == 0x24 && $0.count >= 11 && $0[1] == 0x01 }
                        let raw = Ute.be16(p, 9)
                        continuation.yield(raw == 0xFFFF
                            ? Reading(capability: .temperature, status: .notWorn, unit: "°C")
                            : Reading(capability: .temperature, status: .ok, value: Double(raw) / 100, unit: "°C"))
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        default:
            return super.measure(capability)
        }
    }

    /// Gói nhịp tim trong phép đo: `F7 03/0B` (đồng hồ đẩy) hoặc `E5 fin st rr` (kết quả `E5 11`).
    nonisolated static func heartRatePacket(_ p: [UInt8]) -> (Reading, Bool)? {
        guard let op = p.first else { return nil }
        if op == 0xF7 { return Ute.parsePushedHeartRate(p).map { ($0, true) } }
        guard op == 0xE5 else { return nil }
        if p.count == 2, p[1] == 0x11 { return (Reading(capability: .heartRate, status: .measuring, unit: "bpm"), false) }
        if p.count == 2, p[1] == 0xFD {
            return (Reading(capability: .heartRate, status: .error, unit: "bpm", errorCode: 0xFD), true)
        }
        guard p.count >= 4 else { return nil }
        let done = p[1] == 0x00
        let valid = p[2] == 0 && p[3] > 0
        if valid { return (Reading(capability: .heartRate, status: .ok, value: Double(p[3]), unit: "bpm"), done) }
        return (Reading(capability: .heartRate, status: done ? .notWorn : .measuring, unit: "bpm"), done)
    }

    /// Bật HR 24h (`F7 01`) và chu kỳ trong cài đặt (mặc định 5 phút như app GloryFit iOS, doc 09 §2.2).
    private func configureHeartRate24h() async {
        do {
            for cmd in UteControls.heartRate24h(settings) { try await writeCommand(cmd) }
            hr24Configured = true
        } catch {
            SmartWearLog.w("[\(name)] bật HR 24h lỗi: \(error.localizedDescription)")
        }
    }

    /// Chụp ảnh từ xa không cần bit riêng; chỉ ẩn khi đồng hồ bật "ẩn chụp ảnh" (F12 `0x2000`).
    override public var supportsRemoteCamera: Bool { !features.has(12, 0x002000) }

    /// `C4 01` / `C4 03`: app mở / đóng màn chụp (GloryFit `openShakeMode` / `closeShakeMode` trong `CameraActivity`).
    override public func setRemoteCamera(_ open: Bool) async {
        guard gatt.state == .connected else { return }
        try? await writeCommand([0xC4, open ? 0x01 : 0x03])
    }

    /// Đồng hồ đọc thông báo/cuộc gọi của iPhone qua ANCS (GloryFit iOS `uteManagerANCSAuthorization:`); nil = chưa biết.
    override public var ancsAuthorized: Bool? { gatt.ancsAuthorized }

    /// Bước/quãng đường/kcal của giờ đang chạy (`EB 01` trên 34F1, CyWee); nil nếu đồng hồ không trả lời.
    func currentHourActivity() async -> [UInt8]? {
        try? await request([0xEB, 0x01], ble5: true) { $0.count >= 9 && $0[0] == 0xEB && $0[1] == 0x01 }
    }

    /// `D1 0A 01 01/00`: điện thoại đang đổ chuông / đã dừng ⇒ đồng hồ tắt màn tìm điện thoại
    /// (`WriteCommandToBLE.phoneRingStatus`, gọi từ `BluetoothLeService.findPhonePlayerStop`).
    override public func setPhoneRinging(_ ringing: Bool) async {
        guard features.findPhone, gatt.state == .connected else { return }
        try? await writeCommand([0xD1, 0x0A, 0x01, ringing ? 0x01 : 0x00])
    }

    /// Hỏi đồng hồ có đang đo nhịp tim không (`E5 AA`); nil nếu không có phản hồi.
    public func heartRateMeasuring() async -> Bool? {
        let p = try? await request(Ute.hrStatus) { $0.count >= 3 && $0[0] == 0xE5 && $0[1] == 0xAA }
        return p.flatMap(Ute.parseHeartRateStatus)
    }

    /// Nhịp tim trên đồng hồ HR 24h (doc 09 §2, doc 01 "Y25 đo theo lệnh"). Kiểm chứng 16/10/2026 trên Y25: khi HR 24h
    /// đang bật, `E5 11` bị treo (không ack) cho tới khi tắt 24h; kết quả chỉ trả khi app gửi `E5 00` (`E5 00 00 rr`), không
    /// gửi thì đèn đo chạy mãi. Nên: `F7 02` (tạm tắt 24h) → `D6 01` → `E5 11` (ack) → chờ `hrManualWindow` → `E5 00` lấy kết
    /// quả → bật lại 24h. Không có kết quả (HT43 bỏ qua `E5`) thì dùng giá trị đẩy trong `hrRecent` hoặc chờ `F7 03`/`F7 0B`
    /// tới `hr24Wait`. Kết thúc sớm vẫn gửi `E5 00` và bật lại 24h.
    private func heartRateByPush() -> AsyncThrowingStream<Reading, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(Reading(capability: .heartRate, status: .measuring, unit: "bpm"))
            let stopped = Box(false)
            let paused = Box(false)
            let token = subscribe { p in
                // Đồng hồ tự đẩy (người dùng đo trên đồng hồ / đo định kỳ) hoặc E5 11 00 rr giữa chừng.
                guard let op = p.first, op == 0xF7 || (op == 0xE5 && p.count >= 4 && p[1] == 0x11),
                      let (reading, _) = Self.heartRatePacket(p), reading.status == .ok else { return }
                continuation.yield(reading)
                if op == 0xF7 { continuation.finish() }
            }
            let runner = Task { @MainActor [weak self] in
                guard let self else { return continuation.finish() }
                let hr24 = self.settings.on("hr24.enabled")
                var result: Reading?
                do {
                    if hr24 {
                        try await self.writeCommand([0xF7, 0x02])
                        paused.value = true
                    }
                    try await self.writeCommand([0xD6, 0x01])
                    try await Task.sleep(nanoseconds: 1_500_000_000)
                    try await self.writeCommand([0xE5, 0x11])
                    try await Task.sleep(nanoseconds: UInt64(Self.hrManualWindow * 1_000_000_000))
                    stopped.value = true
                    let p = try await self.request([0xE5, 0x00], timeout: 5) { $0.count >= 4 && $0[0] == 0xE5 && $0[1] == 0x00 }
                    result = Self.heartRatePacket(p)?.0
                } catch {
                    if Task.isCancelled { return }
                }
                stopped.value = true
                if paused.value {
                    paused.value = false
                    await self.configureHeartRate24h()
                }
                if let result { continuation.yield(result); return continuation.finish() }
                if let recent = self.lastPushedHr, Date().timeIntervalSince(self.lastPushedHrAt) < Self.hrRecent {
                    continuation.yield(recent); return continuation.finish()
                }
                continuation.yield(Reading(capability: .heartRate, status: .measuring, unit: "bpm", note: Self.hr24Note))
                try? await Task.sleep(nanoseconds: UInt64((Self.hr24Wait - Self.hrManualWindow) * 1_000_000_000))
                continuation.finish()
            }
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    runner.cancel()
                    guard let self else { return }
                    self.unsubscribe(token)
                    guard self.gatt.state == .connected else { return }
                    if !stopped.value { try? await self.writeCommand([0xE5, 0x00]) }
                    if paused.value {
                        paused.value = false
                        await self.configureHeartRate24h()
                    }
                }
            }
        }
    }

    // MARK: - Nhịp tim liên tục

    /// Đồng hồ chỉ tự đẩy HR theo chu kỳ (`heartRateByPush`, vd. HT43) không trả lời `E5 11`/`D6 01` ⇒ không có luồng.
    override public var supportsHeartRateStream: Bool { measurableCapabilities.contains(.heartRate) && !features.heartRateByPush }

    /// Đo lặp như Android: (`F7 02` nếu HR 24h đang bật) → `D6 01` → mỗi vòng `E5 11`, nhận `E5 11 00 rr` giữa chừng (Y25 đẩy
    /// khoảng mỗi giây khi đo trên đồng hồ; khi app ra lệnh **chưa kiểm**) tới khi đồng hồ tự kết thúc `E5 00 …` hoặc hết
    /// `hrManualWindow` thì gửi `E5 00` lấy kết quả, rồi vòng mới. Không tạo bài tập trên đồng hồ. Huỷ ⇒ `E5 00`, bật lại HR 24h.
    /// 3 vòng liền không có gói nào ⇒ lỗi.
    override public func heartRateStream() -> AsyncThrowingStream<HeartRateSample, Error> {
        guard supportsHeartRateStream else { return super.heartRateStream() }
        return AsyncThrowingStream { continuation in
            let paused = Box(false)
            let last = Box(Date())
            let ended = Box(false)
            let token = subscribe { p in
                guard let x = Ute.parseHeartRateStream(p) else { return }
                last.value = Date()
                continuation.yield(x)
                if p.first == 0xE5, p.count >= 2, p[1] == 0x00 { ended.value = true }
            }
            let runner = Task { @MainActor [weak self] in
                guard let self else { return continuation.finish() }
                do {
                    if self.features.heartRateByPush && self.settings.on("hr24.enabled") {
                        try await self.writeCommand([0xF7, 0x02])
                        paused.value = true
                    }
                    try await self.writeCommand([0xD6, 0x01])
                    try await Task.sleep(nanoseconds: 1_500_000_000)
                    var silentCycles = 0
                    while !Task.isCancelled {
                        let cycleStart = Date()
                        ended.value = false
                        try await self.writeCommand([0xE5, 0x11])
                        while !ended.value, Date().timeIntervalSince(cycleStart) < Self.hrManualWindow {
                            try await Task.sleep(nanoseconds: 250_000_000)
                        }
                        if !ended.value,
                           let p = try? await self.request([0xE5, 0x00], timeout: 5, match: { $0.count >= 4 && $0[0] == 0xE5 && $0[1] == 0x00 }),
                           let x = Ute.parseHeartRateStream(p) {
                            last.value = Date()
                            continuation.yield(x)
                        }
                        silentCycles = last.value >= cycleStart ? 0 : silentCycles + 1
                        if silentCycles >= 3 { throw GloryFitError("Đồng hồ không gửi nhịp tim") }
                        try await Task.sleep(nanoseconds: 300_000_000)
                    }
                } catch is CancellationError {
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    runner.cancel()
                    guard let self else { return }
                    self.unsubscribe(token)
                    guard self.gatt.state == .connected else { return }
                    try? await self.writeCommand([0xE5, 0x00])
                    if paused.value {
                        paused.value = false
                        await self.configureHeartRate24h()
                    }
                }
            }
        }
    }

    /// Phép đo trực tiếp: gửi `prepare` (nếu có) rồi `start`, nhận các gói có opcode trong `ops` (`parse` trả về
    /// Reading và cờ kết thúc). Khi luồng kết thúc chỉ gửi `stop` nếu thiết bị đã phản hồi phép đo này: tránh
    /// cắt ngang phép đo người dùng tự bấm trên đồng hồ khi đồng hồ bỏ qua lệnh của app.
    private func live(
        _ capability: Capability, start: [UInt8], stop: [UInt8], ops: Set<UInt8>, prepare: [UInt8]? = nil,
        parse: @escaping ([UInt8]) -> (Reading, Bool)?
    ) -> AsyncThrowingStream<Reading, Error> {
        AsyncThrowingStream { continuation in
            let last = Box(Date())
            let responded = Box(false)
            let token = subscribe { p in
                guard let op = p.first, ops.contains(op), let (reading, done) = parse(p) else { return }
                last.value = Date()
                responded.value = true
                continuation.yield(reading)
                if done { continuation.finish() }
            }
            let watchdog = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if Date().timeIntervalSince(last.value) > 120 {
                        continuation.finish()
                        return
                    }
                }
            }
            let starter = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    if let prepare {
                        try await self.writeCommand(prepare)
                        try await Task.sleep(nanoseconds: 1_500_000_000)
                    }
                    try await self.writeCommand(start)
                } catch is CancellationError {
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    watchdog.cancel()
                    starter.cancel()
                    guard let self else { return }
                    self.unsubscribe(token)
                    if responded.value, self.gatt.state == .connected { try? await self.writeCommand(stop) }
                }
            }
        }
    }

    /// Kết quả đồng hồ tự đẩy (không thuộc phép đo nào đang chạy) vào `latest` / `lastResult`.
    private func publish(_ r: Reading) {
        guard !measuring.contains(r.capability) else { return }
        latest[r.capability] = r
        if r.status == .ok, r.hasValue { lastResult[r.capability] = r }
    }

    // TODO: đồng bộ lịch sử (B2/B3/E6|F7/34 FA) chưa port: core iOS chưa có syncHistory.

    // MARK: - Mặt đồng hồ

    // TODO: dựng mặt tuỳ chỉnh từ ảnh (WatchFaceRenderer.kt + setWatchFace) chưa port; mới có cài file `.bin` dựng sẵn.

    /// Hỏi thông số mặt đồng hồ (`26 01`, chỉ đọc).
    public func queryDialParams() async throws -> Ute.DialParams {
        let p = try await request([0x26, 0x01], timeout: 5) { $0.first == 0x26 && $0.count > 1 && $0[1] == 0x01 }
        SmartWearLog.i("[\(name)] 26 01 = \(p.hex)")
        guard let params = Ute.parseDialParams(p) else { throw GloryFitError("Phản hồi 26 01 không hợp lệ: \(p.hex)") }
        dialParams = params
        info.setExtra("Mặt đồng hồ (26 01)", "\(params.width)×\(params.height), tối đa \(params.maxSize / 1024) KB, level \(params.level)")
        return params
    }

    /// Mặt đang hiển thị có phải mặt tuỳ chỉnh không (`26 01` trả `FF FF FF FE`, kiểm chứng trên Y25).
    public func isCustomWatchFaceActive() async throws -> Bool {
        try await queryDialParams().currentId == Ute.customFaceId
    }

    /// Cài một file mặt đồng hồ `.bin` dựng sẵn (định dạng doc 02 §4, ví dụ từ kho GloryFit hoặc công cụ khác).
    /// Kiểm tra kích thước màn, độ dài và CRC-32 trong header, dung lượng, mức nén trước khi gửi.
    public func installWatchFaceFile(_ bin: Data, progress: (Double) -> Void = { _ in }) async throws {
        let bytes = [UInt8](bin)
        let spec = try await dialParamsOrQuery()
        try UteWatchFace.validate(bytes, width: spec.width, height: spec.height, maxBytes: spec.maxSize, level: spec.level)
        SmartWearLog.i("[\(name)] cài file mặt đồng hồ \(bytes.count) byte")
        try await sendWatchFace(bytes, progress: progress)
    }

    private func dialParamsOrQuery() async throws -> Ute.DialParams {
        if let dialParams { return dialParams }
        return try await queryDialParams()
    }

    private func sendWatchFace(_ bin: [UInt8], progress: (Double) -> Void) async throws {
        var result = try await BleQuiet.hold { try await uploadWatchFace(bin, progress: progress, slowStart: false) }
        if result & Self.aborted != 0, !GloryFitDebug.noRetry {
            // Đồng hồ huỷ giữa chừng (thường do nhiễu/sóng bận): gửi lại từ đầu một lần, chậm hơn.
            SmartWearLog.w("[\(name)] đồng hồ huỷ nhận giữa chừng, gửi lại chậm hơn")
            try await Task.sleep(nanoseconds: 2_000_000_000)
            result = try await BleQuiet.hold { try await uploadWatchFace(bin, progress: progress, slowStart: true) }
        }
        switch result & ~Self.aborted {
        case 0x00: SmartWearLog.i("[\(name)] đã cài mặt đồng hồ")
        case 0x01: throw GloryFitError("Đồng hồ báo nhận lỗi (26 03 01: sai CRC hoặc huỷ giữa chừng)")
        case 0x02: throw GloryFitError("Đồng hồ báo file quá lớn")
        default: throw GloryFitError(String(format: "Đồng hồ trả mã %02X", result))
        }
    }

    /// Truyền file mặt đồng hồ (doc 02 §5): `26 02` → các gói `27 seqHi seqLo + dữ liệu` lên 34F1 (ghi không phản hồi),
    /// cứ hết mỗi khối 4 KB chờ `26 03 04` (tối đa 5 s), `26 03 03 HH LL` = chờ 600 ms rồi gửi lại từ gói HHLL
    /// (như SDK iOS gốc, doc 09 §3), cuối cùng `26 03 00` → kết quả `26 03 00/01/02`.
    private func uploadWatchFace(_ bin: [UInt8], progress: (Double) -> Void, slowStart: Bool) async throws -> Int {
        try await lock.withLock {
            let channel = PacketChannel()
            waiter = Waiter(match: { $0.first == 0x26 }, channel: channel)
            defer { waiter = nil }
            func sub(_ p: [UInt8], _ s: UInt8) -> Bool { p.count >= 2 && p[1] == s }
            // `26 03 01`/`02` có thể đến giữa chừng (đồng hồ huỷ nhận): dừng ngay, như app gốc (stopOnlineDialData).
            func failed(_ p: [UInt8]) -> Bool { p.count >= 3 && p[1] == 0x03 && (p[2] == 0x01 || p[2] == 0x02) }

            try await writeCommand([0x26, 0x02])
            guard try await channel.receive(timeout: 5, where: { sub($0, 0x02) }) != nil else {
                throw GloryFitError("Đồng hồ không sẵn sàng nhận mặt đồng hồ (26 02)")
            }
            let writable = gatt.maximumWriteLength(withResponse: false)
            let packetLength = max(20, GloryFitDebug.packetLength ?? min(features.maxPacketLength ?? 20, writable))
            let chunk = packetLength - 3
            let total = (bin.count + chunk - 1) / chunk
            SmartWearLog.i("[\(name)] gửi \(bin.count) byte: \(total) gói × \(chunk) byte, ghi không phản hồi")
            var seq = 0
            var lastSector = 0
            var resends = 0
            var silentSectors = 0
            let slow = slowStart  // lần gửi lại sau khi bị huỷ: 100 ms/gói
            let trace = GloryFitDebug.trace
            let started = Date()
            var sectorStarted = started
            var early: [UInt8]?  // `26 03 04` đến trước khi vòng lặp tới chỗ chờ khối: giữ lại, đừng bỏ
            func ms(_ from: Date, _ to: Date = Date()) -> Int { Int(to.timeIntervalSince(from) * 1000) }

            while seq < total {
                let from = seq * chunk
                let packet: [UInt8] = [0x27, UInt8((seq >> 8) & 0xFF), UInt8(seq & 0xFF)] + bin[from..<min(bin.count, from + chunk)]
                try await gatt.write(Ute.service5, Ute.write5, Data(packet), withResponse: false)
                progress(Double(seq + 1) / Double(total))
                // Đồng hồ yêu cầu gửi lại hoặc huỷ?
                if let pushed = channel.tryReceive() {
                    if trace { SmartWearLog.i("[\(name)] trace +\(ms(started)) ms gói \(seq): nhận giữa khối \(pushed.hex)") }
                    if pushed.count >= 3, pushed[1] == 0x03, pushed[2] == 0x04 { early = pushed }
                    if failed(pushed) {
                        SmartWearLog.w("[\(name)] đồng hồ huỷ nhận ở gói \(seq)/\(total): \(pushed.hex)")
                        return Self.aborted | Int(pushed[2])
                    }
                    if pushed.count >= 5, pushed[1] == 0x03, pushed[2] == 0x03 {
                        seq = Ute.be16(pushed, 3)
                        resends += 1
                        if resends > 20 { throw GloryFitError("Đồng hồ yêu cầu gửi lại quá nhiều lần") }
                        try await Task.sleep(nanoseconds: Self.resendPauseNs)
                        continue
                    }
                }
                let sector = ((seq + 1) * chunk) / 4096
                if seq < total - 1, sector != lastSector {
                    lastSector = sector
                    let waitFrom = Date()
                    let r: [UInt8]?
                    if let e = early {
                        r = e
                    } else {
                        r = try await channel.receive(timeout: 5, where: { sub($0, 0x03) })
                    }
                    early = nil
                    if trace {
                        let now = Date()
                        SmartWearLog.i("[\(name)] trace +\(ms(started, now)) ms khối \(sector) (gói \(seq)): gửi \(ms(sectorStarted, waitFrom)) ms, chờ \(ms(waitFrom, now)) ms → \(r?.hex ?? "hết giờ")")
                        sectorStarted = now
                    }
                    if let r, failed(r) {
                        SmartWearLog.w("[\(name)] đồng hồ huỷ nhận ở gói \(seq)/\(total): \(r.hex)")
                        return Self.aborted | Int(r[2])
                    }
                    if let r, r.count >= 5, r[2] == 0x03 {
                        seq = Ute.be16(r, 3)
                        resends += 1
                        if resends > 20 { throw GloryFitError("Đồng hồ yêu cầu gửi lại quá nhiều lần") }
                        try await Task.sleep(nanoseconds: Self.resendPauseNs)
                        continue
                    }
                    // App gốc coi hết 5 s là xong khối và gửi tiếp; im lặng nhiều khối liền thì đồng hồ đã bỏ phiên.
                    silentSectors = r == nil ? silentSectors + 1 : 0
                    if silentSectors >= 3 { throw GloryFitError("Đồng hồ ngừng phản hồi ở gói \(seq)/\(total)") }
                } else if slow {
                    try await Task.sleep(nanoseconds: 100_000_000)
                } else if GloryFitDebug.packetDelayMs > 0 {
                    try await Task.sleep(nanoseconds: UInt64(GloryFitDebug.packetDelayMs) * 1_000_000)
                } else if seq > 0, seq % 10 == 0 {
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                seq += 1
            }
            try await Task.sleep(nanoseconds: 500_000_000)
            try await writeCommand([0x26, 0x03, 0x00])
            guard let result = try await channel.receive(timeout: 30, where: { $0.count >= 3 && $0[1] == 0x03 && $0[2] <= 0x02 }) else {
                throw GloryFitError("Không nhận được kết quả 26 03")
            }
            SmartWearLog.i("[\(name)] kết quả mặt đồng hồ: \(result.hex)")
            return Int(result[2])
        }
    }

    // MARK: - Điện thoại ↔ đồng hồ (core, kế hoạch 2026-10-19 §2)

    /// Thông báo: thông báo app (F2 `0x40`, F3 `0x800`) hoặc icon ANCS (F5 `0x800`). iOS: đồng hồ đọc qua ANCS.
    override public var supportsNotifications: Bool { features.has(2, 0x000040) || features.has(3, 0x000800) || features.has(5, 0x000800) }

    /// Nút từ chối cuộc gọi (`isHasHangup`); đồng hồ chỉ hiện nút khi bật `dnd.endCall` (bit 3 của `D7`).
    override public var supportsRejectCall: Bool { UteSystem.hangup(features) }

    // Nhạc (`UteMusic`).

    override public var supportsMusicControl: Bool { UteMusic.control(features) || UteMusic.songInfo(features) }
    override public var supportsTrackInfo: Bool { UteMusic.songInfo(features) }

    /// Trạng thái + bài đang phát. F5 `0x1000`: `3A 01/06/04` lên 34F1 cách nhau 100 ms rồi `3A FA`, đồng hồ trả `3A FA xor`
    /// (so với `UteMusic.checksum`, chỉ ghi log). Không có F5 `0x1000`: `D1 0C 01/02` (GloryFit `controlBandMusic`).
    /// `durationSec`, `positionSec`, `volumePercent` không gửi trong `3A 01` (app gốc cũng không, chưa rõ đơn vị).
    override public func setMusicState(_ music: MusicState) async {
        guard state == .connected else { return }
        await musicLock.withLock {
            if UteMusic.songInfo(features), gatt.hasCharacteristic(Ute.service5, Ute.write5) {
                let packets = UteMusic.songPackets(playing: music.playing, title: music.title, artist: music.artist)
                do {
                    for (i, p) in packets.enumerated() {
                        if i > 0 { try await Task.sleep(nanoseconds: 100_000_000) }
                        try await gatt.write(Ute.service5, Ute.write5, Data(p), withResponse: true)
                    }
                    try await Task.sleep(nanoseconds: 100_000_000)
                    let expect = UteMusic.checksum(packets)
                    let r = try await request(UteMusic.songEnd, ble5: true) { $0.count >= 3 && $0[0] == 0x3A && $0[1] == 0xFA }
                    if r[2] != expect { SmartWearLog.w("[\(name)] 3A FA: đồng hồ báo \(String(format: "%02X", r[2])), app tính \(String(format: "%02X", expect))") }
                } catch {
                    SmartWearLog.w("[\(name)] gửi bài đang phát lỗi: \(error.localizedDescription)")
                }
            } else if UteMusic.control(features) {
                try? await writeCommand(UteMusic.playState(music.playing))
            }
        }
    }

    /// `D1 0D pct` khi âm lượng tăng / bằng lần gửi trước, `D1 0E pct` khi giảm (`T:3968-3979`). Không phản hồi.
    override public func setMusicVolume(_ percent: Int) async {
        guard state == .connected, UteMusic.control(features) else { return }
        let up = percent >= (lastVolume ?? 0)
        lastVolume = percent
        try? await writeCommand(UteMusic.volume(percent, up: up))
    }

    // Danh bạ (`UteContacts`).

    override public var maxContacts: Int { supportsContacts ? UteContacts.maxContacts(features) : 0 }
    override public var supportsClearContacts: Bool { supportsContacts && UteSystem.contactsClearSupported(features) }

    /// Ghi danh bạ lên đồng hồ (thay toàn bộ danh bạ cũ), xem `UteContacts`. Trả về số liên hệ đã gửi.
    @discardableResult
    override public func syncContacts(_ contacts: [Contact], progress: ((Double) -> Void)? = nil) async throws -> Int {
        guard state == .connected else { throw GloryFitError("Đồng hồ chưa kết nối") }
        guard supportsContacts else { throw GloryFitError("Đồng hồ không hỗ trợ danh bạ") }
        let list = Array(contacts.filter { !UteContacts.cleanPhone($0.phone).isEmpty }.prefix(UteContacts.maxContacts(features)))
        let length = min(features.maxPacketLength ?? 20, gatt.maximumWriteLength(withResponse: false))
        let segments = UteContacts.segments(list, features: features, packetLength: length)
        _ = try await request([0x37, 0xFA, UInt8(list.count)], ble5: true, timeout: 5) { $0.count >= 2 && $0[0] == 0x37 && $0[1] == 0xFA }
        for (i, seg) in segments.enumerated() {
            _ = try await request(seg, ble5: true, timeout: 5) { $0.count >= 2 && $0[0] == 0x37 && $0[1] == 0xFB }
            progress?(Double(i + 1) / Double(segments.count))
        }
        _ = try await request([0x37, 0xFC, 0xFD], ble5: true, timeout: 5) { $0.count >= 2 && $0[0] == 0x37 && $0[1] == 0xFC }
        SmartWearLog.i("[\(name)] đã ghi \(list.count) liên hệ (\(segments.count) gói)")
        return list.count
    }

    /// `37 BA` (34F1) → `37 BA`: xoá toàn bộ danh bạ (`isHasContactDel`).
    override public func clearContacts() async throws {
        guard state == .connected else { throw GloryFitError("Đồng hồ chưa kết nối") }
        guard supportsClearContacts else { throw GloryFitError("Đồng hồ không hỗ trợ xoá danh bạ") }
        _ = try await request(UteSystem.clearContacts, ble5: true, timeout: 5) { $0.count >= 2 && $0[0] == 0x37 && $0[1] == 0xBA }
        SmartWearLog.i("[\(name)] đã xoá danh bạ")
    }

    // Gọi điện Bluetooth cổ điển.

    override public var supportsCallAudio: Bool { supportsCallBluetooth }
    override public func callAudioState() async throws -> CallAudioState { try await callBluetoothState() }
    override public func setCallAudio(_ on: Bool) async throws { try await setCallBluetooth(on) }
    /// iOS: người dùng ghép trong Cài đặt > Bluetooth (tên đọc từ `38 01` nếu được).
    override public func pairCallAudio() async throws {
        let bt = state == .connected ? try? await callBluetoothState() : nil
        throw CallAudioPairingError(deviceName: bt.map(\.name).flatMap { $0.isEmpty ? nil : $0 })
    }

    // Mặt đồng hồ.

    /// Cài file `.bin` không cần bit riêng (mọi đồng hồ có `26 01`); quản lý khe cần `isHasSwitchDialOnline`.
    override public var supportsWatchFace: Bool { true }
    override public var supportsWatchFaceSlots: Bool { UteSystem.watchFaceOnline(features) }

    override public func watchFaceInfo() async throws -> WatchFaceInfo {
        guard state == .connected else { throw GloryFitError("Đồng hồ chưa kết nối") }
        let p = try await queryDialParams()
        // Y25 (466×466) trả screenType = 0; màn vuông cạnh lớn coi như màn tròn (suy luận, như Android).
        let round = p.screenType == 2 || (p.width == p.height && p.width >= 360)
        return WatchFaceInfo(width: p.width, height: p.height, round: round, maxBytes: p.maxSize, currentId: p.currentId,
                             slotCount: p.slots, customActive: p.currentId == Ute.customFaceId)
    }

    override public func installWatchFace(_ file: Data, progress: @escaping (Double) -> Void = { _ in }) async throws {
        guard state == .connected else { throw GloryFitError("Đồng hồ chưa kết nối") }
        try await installWatchFaceFile(file, progress: progress)
    }

    /// `26 09` → `26 09 seq [idx id(4)]…` … `26 09 FD` (như GloryFitPro trước khi xoá mặt). Không có trả lời thì thử
    /// `26 05 00` (doc 10 §2.8; ý nghĩa tham số chưa rõ).
    override public func watchFaceSlots() async throws -> [WatchFaceSlot] {
        guard state == .connected else { throw GloryFitError("Đồng hồ chưa kết nối") }
        let all = try await collect(UteSystem.watchFaceSlotsRead, idle: 3, match: { $0.count >= 3 && $0[0] == 0x26 && $0[1] == 0x09 },
                                    end: { $0[2] == 0xFD })
        if !all.isEmpty {
            SmartWearLog.i("[\(name)] 26 09: \(all.map(\.hex).joined(separator: " | "))")
            return UteSystem.parseSlots(all)
        }
        let one = try await request(UteSystem.watchFaceSlotRead(0), timeout: 3) { $0.count >= 2 && $0[0] == 0x26 && $0[1] == 0x05 }
        SmartWearLog.i("[\(name)] 26 05 = \(one.hex)")
        return UteSystem.parseSlots([one])
    }

    /// `26 08 n` → `26 08 n max state`.
    override public func deleteWatchFaceSlot(_ index: Int) async throws {
        guard state == .connected else { throw GloryFitError("Đồng hồ chưa kết nối") }
        let p = try await request(UteSystem.watchFaceSlotDelete(index), timeout: 5) { $0.count >= 2 && $0[0] == 0x26 && $0[1] == 0x08 }
        switch UteSystem.parseSlotDelete(p) {
        case .deleted: SmartWearLog.i("[\(name)] đã xoá khe mặt đồng hồ \(index)")
        case .nothingToDelete: throw GloryFitError("Khe \(index) không có mặt đồng hồ để xoá")
        case .failed, nil: throw GloryFitError("Đồng hồ không xoá được khe \(index): \(p.hex)")
        }
    }

    // Bài tập (`UteSport`).

    override public var supportsWorkoutControl: Bool { UteSport.control(features) }
    override public var supportsSportList: Bool { UteSport.sportList(features) }
    override public var supportsPhoneLocation: Bool { UteSport.phoneGps(features) }

    /// `FD 48 AA` (34F1) → các gói `FD 48 AA seq …` tới `FD 48 AA FD crc min max`. Số môn hiện ít / nhiều nhất lưu ở
    /// `sportListLimits`.
    override public func sportTypes() async throws -> [SportType] {
        guard state == .connected else { throw GloryFitError("Đồng hồ chưa kết nối") }
        guard supportsSportList else { throw GloryFitError("Đồng hồ không hỗ trợ danh sách môn") }
        let packets = try await collect(UteSport.sportListRead, ble5: true, idle: 3,
                                        match: { $0.count >= 4 && $0[0] == 0xFD && $0[1] == 0x48 && $0[2] == 0xAA },
                                        end: UteSport.isSportListEnd)
        guard !packets.isEmpty else { throw GloryFitError("Đồng hồ không trả danh sách môn (FD 48 AA)") }
        let list = UteSport.parseSportList(packets)
        // Như Kotlin / GloryFitPro: min ≤ 0 ⇒ 1, max ≤ 0 ⇒ 4.
        let lo = (list.minShown ?? 0) > 0 ? list.minShown! : 1
        let hi = (list.maxShown ?? 0) > 0 ? list.maxShown! : 4
        readSportListLimits = lo...max(lo, hi)
        return list.sports
    }

    override public var sportListLimits: ClosedRange<Int>? { readSportListLimits }

    override public var sportCatalog: [SportName] {
        UteSportCatalog.names.keys.sorted().map { SportName(type: $0, name: UteSportCatalog.names[$0]!.vi, nameEn: UteSportCatalog.names[$0]!.en) }
    }

    /// Ghi danh sách môn: gửi mọi môn trong mảng (nên sửa từ kết quả `sportTypes`), môn hiện đánh lại vị trí 1..n
    /// (`UteSport.normalizeSportList`), số môn hiện phải trong `sportListLimits`.
    override public func setSportList(_ sports: [SportType]) async throws {
        guard state == .connected else { throw GloryFitError("Đồng hồ chưa kết nối") }
        guard supportsSportList else { throw GloryFitError("Đồng hồ không hỗ trợ danh sách môn") }
        guard gatt.hasCharacteristic(Ute.service5, Ute.write5) else { throw GloryFitError("Không có kênh 34F1") }
        guard !sports.isEmpty else { throw GloryFitError("Danh sách môn rỗng") }
        let list = try UteSport.normalizeSportList(sports, limits: readSportListLimits)
        let length = min(features.maxPacketLength ?? 20, gatt.maximumWriteLength(withResponse: false))
        let packets = UteSport.sportListPackets(list, packetLength: length)
        try await lock.withLock {
            let channel = PacketChannel()
            waiter = Waiter(match: { $0.count >= 3 && $0[0] == 0xFD && $0[1] == 0x48 && ($0[2] == 0xFB || $0[2] == 0xFD) }, channel: channel)
            defer { waiter = nil }
            for p in packets.dropLast() {
                try await gatt.write(Ute.service5, Ute.write5, Data(p), withResponse: true)
                // Bản gốc gửi gói sau khi nhận `FD 48 FB`; không nhận được trong 3 s thì vẫn gửi tiếp (như hết giờ lệnh 3 s).
                if try await channel.receive(timeout: 3, where: { $0[2] == 0xFB }) == nil {
                    SmartWearLog.w("[\(name)] FD 48: không có FB sau gói \(p[2])")
                }
            }
            try await gatt.write(Ute.service5, Ute.write5, Data(packets[packets.count - 1]), withResponse: true)
            guard try await channel.receive(timeout: 5, where: { $0[2] == 0xFD }) != nil else {
                throw GloryFitError("Đồng hồ không xác nhận danh sách môn (FD 48 FD)")
            }
        }
    }

    override public func startWorkout(_ sportType: Int) async throws {
        try checkWorkoutControl()
        try await writeCommand(UteSport.start(sportType))
        workout = WorkoutClock(sportType: sportType)
    }

    override public func pauseWorkout() async throws {
        try checkWorkoutControl()
        let w = workout ?? WorkoutClock(sportType: 0)
        try await writeCommand(UteSport.pause(w.sportType, elapsed: w.elapsed()))
    }

    override public func resumeWorkout() async throws {
        try checkWorkoutControl()
        let w = workout ?? WorkoutClock(sportType: 0)
        try await writeCommand(UteSport.resume(w.sportType, elapsed: w.elapsed()))
    }

    override public func stopWorkout() async throws {
        try checkWorkoutControl()
        try await writeCommand(UteSport.stop(workout?.sportType ?? 0))
    }

    private func checkWorkoutControl() throws {
        guard state == .connected else { throw GloryFitError("Đồng hồ chưa kết nối") }
        guard supportsWorkoutControl else { throw GloryFitError("Đồng hồ không hỗ trợ điều khiển bài tập") }
    }

    /// Hỏi bài tập đang chạy (`FD AA` → `FD AA st type`); nil nếu đồng hồ không trả lời.
    public func queryWorkout() async -> (state: WorkoutState, sportType: Int)? {
        guard state == .connected else { return nil }
        let p = try? await request(UteSport.query) { $0.count == 4 && $0[0] == 0xFD && $0[1] == 0xAA }
        return p.flatMap(UteSport.parseQuery)
    }

    /// Điểm vị trí điện thoại lên đồng hồ (34F1): lần đầu sau khi đồng hồ xin gửi `FD 01 01` (đã định vị), rồi
    /// `FD 02 lat lon speed pointDist totalDist` (pointDist tính từ điểm trước, totalDist cộng dồn; độ cao và độ chính xác
    /// không có trong giao thức). GloryFit cũ gửi mỗi 3 s.
    override public func sendLocation(latitude: Double, longitude: Double, altitude: Double? = nil, speed: Double? = nil, accuracy: Double? = nil) async throws {
        guard state == .connected else { throw GloryFitError("Đồng hồ chưa kết nối") }
        guard gatt.hasCharacteristic(Ute.service5, Ute.write5) else { throw GloryFitError("Không có kênh 34F1") }
        if !location.statusSent {
            try await gatt.write(Ute.service5, Ute.write5, Data(UteSport.locationStatus(true)), withResponse: true)
            location.statusSent = true
        }
        let point = location.last.map { Int(UteSport.distanceMeters($0.0, $0.1, latitude, longitude).rounded()) } ?? 0
        location.total += point
        location.last = (latitude, longitude)
        let p = UteSport.location(latitude: latitude, longitude: longitude, speed: speed ?? 0, pointMeters: point, totalMeters: location.total)
        try await gatt.write(Ute.service5, Ute.write5, Data(p), withResponse: true)
    }

    /// Gói `FD …` đồng hồ tự đẩy (ngoài luồng đồng bộ): trạng thái, realtime, xin vị trí.
    private func handleSportPacket(_ p: [UInt8]) {
        guard p.first == 0xFD else { return }
        if let req = UteSport.parseLocationRequest(p) {
            location = LocationSession()
            onLocationRequest?(req)
            return
        }
        if let rt = UteSport.parseRealtime(p) {
            onWorkoutEvent?(.realtime(rt))
            return
        }
        guard let event = UteSport.parseState(p) else { return }
        if case .state(let st, let type, _) = event {
            switch st {
            case .started: workout = WorkoutClock(sportType: type)
            case .paused: workout?.pause()
            case .resumed: workout?.resume()
            case .stopped: workout = nil
            }
        }
        onWorkoutEvent?(event)
    }

    // MARK: - AGPS (UteAgps)

    /// Vị trí điện thoại app đưa gần nhất (giây Unix, vĩ độ, kinh độ) và lúc gửi lên đồng hồ lần cuối.
    private var agpsPosition: (timestamp: Int64, latitude: Double, longitude: Double)?
    private var agpsPositionSentAt = Date.distantPast
    /// File app đặt sẵn (`setAgpsFiles`), chỉ trong bộ nhớ.
    private var agpsFiles: [AgpsFile]?
    private var agpsUploading = false

    override public var supportsAgps: Bool { UteAgps.supported(features) }

    /// Đồng hồ hỏi AGPS (HT43: `01 E9 AC 03 01 02` mỗi 60 s khi hết dữ liệu vệ tinh): trả lời bằng vị trí / file app đặt sẵn.
    private func handleAgpsPacket(_ p: [UInt8]) {
        guard let type = UteAgps.parseRequest(p) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            var handled = false
            do {
                handled = try await self.answerAgps(type)
            } catch {
                SmartWearLog.w("[\(self.name)] trả lời AGPS lỗi: \(error.localizedDescription)")
            }
            self.onAgpsRequest?(AgpsRequest(type: type, handled: handled))
        }
    }

    /// true = đã trả lời bằng dữ liệu app đặt (vị trí hoặc file).
    private func answerAgps(_ type: AgpsRequestType) async throws -> Bool {
        guard state == .connected else { return false }
        switch type {
        case .position:
            return try await sendStoredAgpsPosition(force: true)
        case .status:
            // Như GloryFitPro `getEphemerisParams`: vị trí điện thoại trước, rồi trạng thái file (`responseEphemerisRequired`).
            let sentPosition = try await sendStoredAgpsPosition(force: false)
            if let st = agpsFiles != nil ? UteAgps.statusDone : GloryFitDebug.agpsNoFileStatus {
                try await writeBle5(UteAgps.status(st))
            }
            return agpsFiles != nil || sentPosition
        case .download:
            guard let files = agpsFiles, !agpsUploading else { return false }
            try await transferAgps(try UteAgps.payload(files)) { _ in }
            return true
        }
    }

    /// Gửi vị trí đã lưu nếu còn mới; không `force` thì tối đa mỗi `UteAgps.positionResend` (đồng hồ hỏi mỗi phút).
    private func sendStoredAgpsPosition(force: Bool) async throws -> Bool {
        guard let pos = agpsPosition else { return false }
        let now = Date()
        guard now.timeIntervalSince1970 - Double(pos.timestamp) <= UteAgps.positionMaxAge else { return false }
        if !force, now.timeIntervalSince(agpsPositionSentAt) < UteAgps.positionResend { return false }
        try await writeBle5(try UteAgps.position(timestamp: pos.timestamp, latitude: pos.latitude, longitude: pos.longitude))
        agpsPositionSentAt = now
        return true
    }

    private func requireAgps() throws {
        guard state == .connected else { throw GloryFitError("Đồng hồ chưa kết nối") }
        guard supportsAgps else { throw GattError.operationFailed("AGPS", "đồng hồ không hỗ trợ") }
    }

    private func writeBle5(_ bytes: [UInt8]) async throws {
        guard gatt.hasCharacteristic(Ute.service5, Ute.write5) else { throw GloryFitError("Không có kênh 34F1") }
        try await gatt.write(Ute.service5, Ute.write5, Data(bytes), withResponse: true)
    }

    /// `56 FD` (33F1, dữ liệu còn hợp lệ) + `01 E9 AA 01` (34F1, tên file / phiên bản).
    override public func agpsInfo() async throws -> AgpsInfo {
        try requireAgps()
        let reply = try? await request(UteAgps.ephemerisState) { UteAgps.parseEphemerisState($0) != nil }
        let valid = reply.flatMap(UteAgps.parseEphemerisState)
        let packets = try await collect(UteAgps.info, ble5: true, idle: 3, match: UteAgps.isInfoPacket, end: UteAgps.isInfoEnd)
        SmartWearLog.i("[\(name)] AGPS: 56 FD → \(String(describing: valid)), AA 01 → \(packets.map(\.hex).joined(separator: " | "))")
        guard packets.contains(where: UteAgps.isInfoEnd) else { throw GloryFitError("Đồng hồ không trả thông tin AGPS (01 E9 AA 01)") }
        return UteAgps.parseInfo(packets, ephemerisValid: valid)
    }

    /// `01 E9 AB 02 0C ts lat lon`; lưu lại để tự gửi khi đồng hồ hỏi. Chưa kết nối thì chỉ lưu.
    override public func sendAgpsPosition(latitude: Double, longitude: Double, timestamp: Date = Date()) async throws {
        let ts = Int64(timestamp.timeIntervalSince1970)
        let packet = try UteAgps.position(timestamp: ts, latitude: latitude, longitude: longitude)
        agpsPosition = (ts, latitude, longitude)
        guard state == .connected else { return }
        try requireAgps()
        do {
            _ = try await request(packet, ble5: true) { UteAgps.isPositionAck($0) }
        } catch {
            SmartWearLog.w("[\(name)] AGPS: đồng hồ không xác nhận vị trí (\(error.localizedDescription))")
        }
        agpsPositionSentAt = Date()
    }

    override public func setAgpsFiles(_ files: [AgpsFile]?) throws {
        if let files { _ = try UteAgps.payload(files) }  // kiểm giới hạn ngay để app biết lỗi
        agpsFiles = files
    }

    /// Như luồng app gốc: báo đã có file (`AB 03 01 03`), chờ đồng hồ xin (`AC 03 01 01`, tối đa 10 s; không xin vẫn gửi),
    /// rồi truyền (`transferAgps`).
    override public func uploadAgpsFiles(_ files: [AgpsFile], progress: @escaping (Double) -> Void = { _ in }) async throws {
        try requireAgps()
        let payload = try UteAgps.payload(files)
        let asked = (try? await request(UteAgps.status(UteAgps.statusDone), ble5: true, timeout: 10) { UteAgps.parseRequest($0) == .download }) != nil
        if !asked { SmartWearLog.w("[\(name)] AGPS: đồng hồ chưa xin file sau AB 03 01 03, vẫn gửi") }
        try await transferAgps(payload, progress: progress)
    }

    /// Truyền `payload` bằng các gói `01 E9 AB 04 idx…` lên 34F1: qua mỗi mốc 4 KB chờ `AC 04 01 07` (tối đa 5 s),
    /// `AC 04 01 06 HH LL` = gửi lại từ gói HHLL; sau gói cuối 500 ms gửi `AB 04 FD FD xor`, chờ `AC 04 01 01`.
    private func transferAgps(_ payload: [UInt8], progress: (Double) -> Void) async throws {
        try await lock.withLock {
            let channel = PacketChannel()
            waiter = Waiter(match: UteAgps.isTransferResult, channel: channel)
            agpsUploading = true
            defer {
                waiter = nil
                agpsUploading = false
            }
            let writable = gatt.maximumWriteLength(withResponse: false)
            let packetLength = max(20, GloryFitDebug.packetLength ?? min(features.maxPacketLength ?? 20, writable))
            let chunk = packetLength - 6
            let packets = UteAgps.packets(payload, chunk: chunk)
            SmartWearLog.i("[\(name)] AGPS: gửi \(payload.count) byte, \(packets.count) gói × \(chunk) byte")
            func failure(_ st: Int) -> GloryFitError {
                switch st {
                case UteAgps.transferCancelled: return GloryFitError("Đồng hồ huỷ nhận AGPS")
                case UteAgps.transferCrc: return GloryFitError("Đồng hồ báo sai CRC dữ liệu AGPS")
                case UteAgps.transferTooLarge: return GloryFitError("Dữ liệu AGPS quá lớn với đồng hồ")
                default: return GloryFitError(String(format: "Đồng hồ trả mã AGPS %02X", st))
                }
            }
            // Gói kết quả giữa chừng: trả về gói cần gửi lại, nil = tiếp tục; lỗi thì ném.
            func check(_ r: [UInt8]) throws -> Int? {
                let st = UteAgps.transferStatus(r)
                if st == UteAgps.transferResend { return UteAgps.resendFrom(r) }
                if st == UteAgps.transferContinue || st == UteAgps.transferOk { return nil }
                throw failure(st)
            }
            var seq = 0
            var lastSector = 0
            var resends = 0
            var silentSectors = 0
            var early = false  // `AC 04 01 07` đến trước mốc khối: giữ lại
            while seq < packets.count {
                try await gatt.write(Ute.service5, Ute.write5, Data(packets[seq]), withResponse: false)
                progress(Double(seq + 1) / Double(packets.count))
                var resendAt: Int?
                if let pushed = channel.tryReceive() {
                    if UteAgps.transferStatus(pushed) == UteAgps.transferContinue { early = true }
                    resendAt = try check(pushed)
                }
                let sector = ((seq + 1) * chunk) / UteAgps.sectorBytes
                if resendAt == nil, seq < packets.count - 1, sector != lastSector {
                    lastSector = sector
                    var r: [UInt8]?
                    if !early { r = try await channel.receive(timeout: 5) }
                    silentSectors = (r == nil && !early) ? silentSectors + 1 : 0
                    early = false
                    if silentSectors >= 3 { throw GloryFitError("Đồng hồ ngừng phản hồi khi nhận AGPS ở gói \(seq)/\(packets.count)") }
                    if let r { resendAt = try check(r) }
                } else if resendAt == nil, packetLength <= 20 {
                    try await Task.sleep(nanoseconds: 50_000_000)  // như SDK iOS gốc khi gói ≤ 20 byte
                } else if resendAt == nil, seq > 0, seq % 10 == 0 {
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                if let from = resendAt {
                    resends += 1
                    if resends > 20 { throw GloryFitError("Đồng hồ yêu cầu gửi lại AGPS quá nhiều lần") }
                    seq = min(max(from, 0), packets.count - 1)
                } else {
                    seq += 1
                }
            }
            try await Task.sleep(nanoseconds: 500_000_000)
            try await gatt.write(Ute.service5, Ute.write5, Data(UteAgps.endPacket(UteAgps.xor(packets))), withResponse: false)
            guard let result = try await channel.receive(timeout: 30, where: { UteAgps.transferStatus($0) != UteAgps.transferContinue }) else {
                throw GloryFitError("Không nhận được kết quả truyền AGPS")
            }
            if UteAgps.transferStatus(result) != UteAgps.transferOk { throw failure(UteAgps.transferStatus(result)) }
            SmartWearLog.i("[\(name)] AGPS: đồng hồ nhận xong \(payload.count) byte")
        }
    }

    // Sự kiện lẻ / hệ thống.

    /// Đọc trạng thái dữ liệu `33F3` (`isHasDataStatus`). Ý nghĩa bit là suy luận, xem `UteSystem.DataStatus`.
    public func readDataStatus() async throws -> UteSystem.DataStatus {
        guard state == .connected else { throw GloryFitError("Đồng hồ chưa kết nối") }
        guard gatt.hasCharacteristic(Ute.service, UteSystem.dataStatusCharacteristic) else { throw GloryFitError("Không có characteristic 33F3") }
        let d = try await gatt.read(Ute.service, UteSystem.dataStatusCharacteristic)
        SmartWearLog.i("[\(name)] 33F3 = \(d.hex)")
        return UteSystem.DataStatus(raw: [UInt8](d))
    }

    /// Đọc phím tắt nhanh `BE 01` (có) + `BE 02` (đang bật) và lưu vào cài đặt (`shortcut.support` / `shortcut.status`).
    @discardableResult
    public func readShortcuts() async -> UteSystem.Shortcuts? {
        guard UteSystem.shortcuts(features),
              let a = try? await request(UteSystem.shortcutSupportRead, timeout: 2, match: { $0.count >= 2 && $0[0] == 0xBE && $0[1] == 0x01 }),
              let b = try? await request(UteSystem.shortcutStatusRead, timeout: 2, match: { $0.count >= 2 && $0[0] == 0xBE && $0[1] == 0x02 })
        else { return nil }
        SmartWearLog.i("[\(name)] BE 01 = \(a.hex), BE 02 = \(b.hex)")
        guard let support = UteSystem.parseShortcutMask(a, sub: 0x01), let status = UteSystem.parseShortcutMask(b, sub: 0x02) else { return nil }
        var v = settings.values
        v["shortcut.support"] = support
        v["shortcut.status"] = status
        settings = UteSettings(v)
        defaults.set(settings.encode(), forKey: settingsKey)
        return UteSystem.Shortcuts(support: support, status: status)
    }

    /// Gửi `command` (33F1 hoặc 34F1) và gom gói khớp `match` tới gói `end` (kể cả gói `end`) hoặc im lặng `idle` giây.
    private func collect(
        _ command: [UInt8], ble5: Bool = false, idle: TimeInterval, match: @escaping ([UInt8]) -> Bool, end: @escaping ([UInt8]) -> Bool
    ) async throws -> [[UInt8]] {
        try await lock.withLock {
            let channel = PacketChannel()
            waiter = Waiter(match: match, channel: channel)
            defer { waiter = nil }
            if ble5 {
                guard gatt.hasCharacteristic(Ute.service5, Ute.write5) else { throw GloryFitError("Không có kênh 34F1") }
                try await gatt.write(Ute.service5, Ute.write5, Data(command), withResponse: true)
            } else {
                try await writeCommand(command)
            }
            var out: [[UInt8]] = []
            while let p = try await channel.receive(timeout: idle) {
                out.append(p)
                if end(p) { break }
            }
            return out
        }
    }

    // MARK: - Kênh lệnh

    private func writeCommand(_ bytes: [UInt8]) async throws {
        // Ghi có phản hồi nếu 33F1 hỗ trợ (GattConnection tự chuyển sang không phản hồi nếu không).
        try await gatt.write(Ute.service, Ute.write, Data(bytes), withResponse: true)
    }

    /// Gửi lệnh và chờ gói đầu tiên khớp `match`.
    private func request(_ bytes: [UInt8], ble5: Bool = false, timeout: TimeInterval = 3, match: @escaping ([UInt8]) -> Bool) async throws -> [UInt8] {
        try await lock.withLock {
            let channel = PacketChannel()
            waiter = Waiter(match: match, channel: channel)
            defer { waiter = nil }
            let started = Date()
            if ble5 {
                try await gatt.write(Ute.service5, Ute.write5, Data(bytes), withResponse: true)
            } else {
                try await writeCommand(bytes)
            }
            guard let p = try await channel.receive(timeout: timeout) else {
                throw GloryFitError(String(format: "Lệnh %02X không có phản hồi", bytes.first ?? 0))
            }
            recordLatency(since: started)
            return p
        }
    }

    /// Luồng lịch sử: gửi `command` (33F1, hoặc 34F1 nếu `usesBle5`), gom gói thuộc luồng đến gói kết thúc hoặc khi
    /// im lặng quá `idle` giây. `ended` = đã nhận gói kết thúc. Bỏ gói trùng y hệt gói trước như app GloryFit.
    /// Luồng bài tập `FD FA`: gói đầu báo số bài, mỗi bài kết thúc bằng `FD FD`; dừng khi đủ số bài hoặc im lặng.
    func workoutStream(idle: TimeInterval = 5) async throws -> [[UInt8]] {
        try await lock.withLock {
            let channel = PacketChannel()
            waiter = Waiter(match: { $0.first == 0xFD }, channel: channel)
            defer { waiter = nil }
            try await writeCommand(Ute.workoutSync)
            var packets: [[UInt8]] = []
            var expected = -1
            var done = 0
            while let p = try await channel.receive(timeout: idle) {
                packets.append(p)
                if GloryFitDebug.workoutPackets { SmartWearLog.i("[\(name)] bài tập gói: \(p.map { String(format: "%02X", $0) }.joined(separator: " "))") }
                if let n = Ute.workoutCount(p) { expected = n }
                if expected == 0 { break }
                if Ute.isWorkoutEnd(p) {
                    done += 1
                    if expected > 0, done >= expected { break }
                }
            }
            SmartWearLog.i("[\(name)] bài tập: báo \(expected), nhận \(done) bài, \(packets.count) gói")
            return packets
        }
    }

    func historyStream(_ command: Ute.SyncCommand, idle: TimeInterval = 5) async throws -> (packets: [[UInt8]], ended: Bool) {
        try await lock.withLock {
            let channel = PacketChannel()
            waiter = Waiter(match: command.matches, channel: channel)
            defer { waiter = nil }
            let started = Date()
            if command.usesBle5 {
                guard gatt.hasCharacteristic(Ute.service5, Ute.write5) else { throw GloryFitError("Không có kênh 34F1") }
                try await gatt.write(Ute.service5, Ute.write5, Data(command.bytes), withResponse: true)
            } else {
                try await writeCommand(command.bytes)
            }
            var packets: [[UInt8]] = []
            var first = true
            while let p = try await channel.receive(timeout: idle) {
                if first { recordLatency(since: started); first = false }
                if command.isEnd(p) { return (packets, true) }
                if command.dedupe, packets.last == p { continue }
                packets.append(p)
            }
            return (packets, false)
        }
    }

    private func subscribe(_ handler: @escaping ([UInt8]) -> Void) -> UUID {
        let token = UUID()
        subscribers[token] = handler
        return token
    }

    private func unsubscribe(_ token: UUID) { subscribers[token] = nil }

    /// Gói từ 33F2 và 34F2: gói khớp lệnh đang chờ thì giao cho lệnh đó, còn lại là gói đồng hồ tự đẩy.
    private func onNotification(_ uuid: CBUUID, _ value: Data) {
        guard uuid == Ute.notify || uuid == Ute.notify5 else { return }
        let p = [UInt8](value)
        guard !p.isEmpty else { return }
        if let w = waiter, w.match(p) {
            w.channel.send(p)
        } else {
            for handler in subscribers.values { handler(p) }
        }
    }
}

// MARK: - Gỡ lỗi

extension GloryFitDevice {
    private final class PacketBox { var packets: [[UInt8]] = [] }

    /// Gỡ lỗi giao thức: gửi gói thô lên 33F1 (hoặc 34F1 nếu `ble5`) và trả mọi gói đồng hồ tự gửi trong `listen` giây.
    /// Gói khớp lệnh đang chờ khác không được tính.
    public func debugExchange(_ bytes: [UInt8], ble5: Bool = false, listen: TimeInterval = 4) async throws -> [[UInt8]] {
        let box = PacketBox()
        let token = subscribe { box.packets.append($0) }
        defer { unsubscribe(token) }
        if ble5 {
            try await gatt.write(Ute.service5, Ute.write5, Data(bytes), withResponse: true)
        } else {
            try await writeCommand(bytes)
        }
        try await Task.sleep(nanoseconds: UInt64(listen * 1_000_000_000))
        return box.packets
    }
}

// MARK: - Cài đặt

extension GloryFitDevice: ConfigurableDevice {
    private func save(_ s: UteSettings) {
        settings = s
        defaults.set(s.encode(), forKey: settingsKey)
        controls = UteControls.controls(features, s)
    }

    public func setControl(_ id: String, _ value: ControlValue) async throws {
        guard !UteControls.readOnly(id) else { return }
        save(settings.with(id, value))
        guard state == .connected else { return }
        for cmd in UteControls.commands(id, features, settings) {
            switch cmd.first {
            // A9/A0 có phản hồi cùng opcode; lệnh khác đồng hồ không trả lời.
            case 0xA9, 0xA0: _ = try await request(cmd) { $0.first == cmd.first }
            default: try await writeCommand(cmd)
            }
        }
        if id.hasPrefix("hr24") { hr24Configured = settings.on("hr24.enabled") }
    }

    public func runAction(_ id: String) async throws {
        guard state == .connected else { throw GloryFitError("Đồng hồ chưa kết nối") }
        switch id {
        case "find.start": try await writeCommand(UteControls.findWatch)
        // Hành động nguy hiểm: app phải hỏi người dùng theo `DeviceControl.confirm` trước khi gọi.
        case "contacts.clear": try await clearContacts()
        case "data.reset":
            try await writeCommand(UteSystem.factoryReset)
            SmartWearLog.w("[\(name)] đã gửi AD (xoá dữ liệu đồng hồ)")
        default: throw GloryFitError("Không có hành động \(id)")
        }
    }
}

// MARK: - Thời tiết

extension GloryFitDevice: WeatherDisplay {
    public var supportsWeather: Bool { UteWeather.supported(features) }

    /// Gửi `CB 01/02/03` (xem `UteWeather`); gói sau đi sau khi đồng hồ trả lời gói trước, như app gốc
    /// (không trả lời trong 3 s vẫn gửi tiếp).
    public func setWeather(_ forecast: WeatherForecast) async throws {
        guard state == .connected else { throw GloryFitError("Đồng hồ chưa kết nối") }
        guard supportsWeather else { throw GloryFitError("Đồng hồ không hỗ trợ thời tiết 7 ngày") }
        let ble5 = UteWeather.ble5(features)
        for p in UteWeather.packets(features, forecast) {
            do {
                let rsp = try await request(p, ble5: ble5) { $0.first == 0xCB }
                SmartWearLog.i("[\(name)] thời tiết \(p[1]) → \(rsp.hex)")
            } catch {
                SmartWearLog.w("[\(name)] thời tiết \(p[1]): \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Gọi điện (Bluetooth 3.0) và danh bạ

/// Kênh gọi điện Bluetooth cổ điển của đồng hồ (`DeviceBt3StateInfo`); cùng kiểu với `CallAudioState` của core.
public typealias CallBluetoothState = CallAudioState

extension GloryFitDevice {
    /// `isHasBluetooth3` (33F1 b2.2 = F6 `0x40000`): đồng hồ gọi điện qua Bluetooth cổ điển (HFP).
    public var supportsCallBluetooth: Bool { features.has(6, 0x040000) }
    public var supportsContacts: Bool { UteContacts.supported(features) }

    /// `38 01 02 00 r0..r3` (34F1) → `38 01 tên(20) MAC(6) bật ghép kết-nối`. Kiểm chứng Y25: trước khi ghép `01 00 00`,
    /// sau khi ghép trong Cài đặt iOS `01 01 01`.
    public func callBluetoothState() async throws -> CallBluetoothState {
        guard state == .connected else { throw GloryFitError("Đồng hồ chưa kết nối") }
        var nonce = [UInt8](repeating: 0, count: 4)
        for i in nonce.indices { nonce[i] = UInt8.random(in: 0...255) }
        let p = try await request([0x38, 0x01, 0x02, 0x00] + nonce, ble5: true, timeout: 4) { $0.count >= 31 && $0[0] == 0x38 && $0[1] == 0x01 }
        return Self.parseCallBluetooth(p)
    }

    nonisolated static func parseCallBluetooth(_ p: [UInt8]) -> CallBluetoothState {
        let nameBytes = p[2..<22].prefix { $0 != 0 }
        let mac = p[22..<28].map { String(format: "%02X", $0) }.joined(separator: ":")
        return CallBluetoothState(
            name: String(decoding: nameBytes, as: UTF8.self), address: mac,
            enabled: p[28] == 1, paired: p[29] == 1, connected: p[30] == 1
        )
    }

    /// `38 02 01/00`: bật/tắt kênh gọi điện trên đồng hồ (`openDeviceBt3`).
    public func setCallBluetooth(_ on: Bool) async throws {
        guard state == .connected else { throw GloryFitError("Đồng hồ chưa kết nối") }
        try await writeCommand([0x38, 0x02, on ? 1 : 0])
    }

}


// MARK: - Trạng thái bài tập / vị trí

/// Đồng hồ bấm giờ của bài tập đang chạy: thời gian tập (trừ lúc tạm dừng) cho gói `FD 22/33`.
struct WorkoutClock {
    let sportType: Int
    let started: Date
    var pausedAt: Date?
    var pausedTotal: TimeInterval = 0

    init(sportType: Int, started: Date = Date()) {
        self.sportType = sportType
        self.started = started
    }

    mutating func pause(at now: Date = Date()) { if pausedAt == nil { pausedAt = now } }

    mutating func resume(at now: Date = Date()) {
        if let p = pausedAt { pausedTotal += now.timeIntervalSince(p) }
        pausedAt = nil
    }

    func elapsed(at now: Date = Date()) -> Int {
        let paused = pausedTotal + (pausedAt.map { now.timeIntervalSince($0) } ?? 0)
        return max(0, Int(now.timeIntervalSince(started) - paused))
    }
}

/// Phiên gửi vị trí: đã báo `FD 01 01` chưa, điểm trước, quãng đường cộng dồn (mét).
struct LocationSession {
    var statusSent = false
    var last: (Double, Double)?
    var total = 0
}
