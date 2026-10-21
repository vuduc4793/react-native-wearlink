import CoreBluetooth
import Foundation
import SmartWearCore

/// Driver cho thiết bị dùng app G Band / VPG Band (SDK Veepoo), ví dụ vòng tay PALREDIL GE54 (bản iOS của `VeepooDriver.kt`).
/// Nhận diện bằng manufacturer data company `0xF8F8` (luật `isBeyondVpV2` của G Band), hoặc `F8 F9` / `F9 F9`. Không nhận
/// theo FEE7 / 180D (app iOS gốc quét theo các UUID này) vì nhẫn R09 và máy đo nhịp tim cũng phát.
public struct VeepooDriver: DeviceDriver {
    public static let driverId = "veepoo"
    public let id = VeepooDriver.driverId
    public let displayName = "Veepoo (G Band)"

    public init() {}

    /// Vòng tay đã bond với iPhone (ANCS) có thể ngừng quảng bá; app iOS gốc tìm lại bằng
    /// `retrieveConnectedPeripherals([F0020001])`. Thêm F0080001 (service lệnh) cho chắc.
    public var systemServices: [CBUUID] { [Veepoo.waveService, Veepoo.service] }

    public func match(_ scanned: ScannedDevice) -> DriverMatch? {
        guard Veepoo.matches(scanned) else { return nil }
        let name = Veepoo.cleanName(scanned.name)
        return DriverMatch(driverId: id, model: name.isEmpty ? "Thiết bị Veepoo" : name, kind: Veepoo.guessKind(name),
                           mac: Veepoo.advert(scanned)?.mac)
    }

    @MainActor
    public func create(_ scanned: ScannedDevice, match: DriverMatch) -> WearableDevice {
        VeepooDevice(scanned: scanned, match: match)
    }
}

/// Nút gỡ lỗi. Mặc định theo app iOS gốc.
public enum VeepooDebug {
    /// Byte 12 của `A1` = 0 (app iOS gốc, showPair = YES) để vòng tay yêu cầu bond với iPhone (đọc ANCS). false = gửi 1 như
    /// Android. Chưa kiểm trên GE54 (Q9).
    nonisolated(unsafe) public static var requestPairing = true
}

/// Một thiết bị Veepoo: bắt tay `A1` (mật khẩu "0000" + giờ) → gom `A7`×5 / `AD` / `B8` thiết bị tự đẩy, pin `A0`, đo trực
/// tiếp, đồng bộ lịch sử (`VeepooSync.swift`), cài đặt `B8` / `AD` / `A3` / `AA` / `B1` / `B4` / `E1` / `E7` / `AC` / `F4`,
/// hiệu chuẩn, báo thức có chữ `B9`, tìm vòng tay / điện thoại, chụp ảnh, nhạc, danh bạ, thời tiết, mặt đồng hồ Veepoo gốc.
@MainActor
public final class VeepooDevice: WearableDevice {
    public let gatt: GattConnection
    public let model: String
    /// Tên trong gói quảng bá.
    public let advertisedName: String?
    /// Manufacturer data lúc quét (MAC + device number); nil nếu iOS đang giữ kết nối hệ thống.
    public let advert: Veepoo.Advert?
    public private(set) var features = VeepooFeatures()
    public private(set) var messageSwitches = VeepooMessageSwitches(page0: nil, page1: nil)
    public private(set) var customSettings = VeepooCustomSettings(page0: nil, page1: nil)
    public private(set) var passwordReply: Veepoo.PasswordReply?
    /// Cài đặt lưu cục bộ (`VeepooSettings`).
    public private(set) var settings = VeepooSettings()
    /// Cài đặt đọc từ vòng tay sau khi nối (`E7`, `AC`, hiệu chuẩn), như Android.
    public private(set) var deviceState = VeepooDeviceState()

    struct Waiter {
        let match: ([UInt8]) -> Bool
        let channel: PacketChannel
    }

    let lock = AsyncLock()
    /// 3 byte ngày thô (yy mm dd) vòng tay lưu cho từng báo thức (theo id), từ lần đọc `B9 03` gần nhất.
    var alarmDates: [Int: [UInt8]] = [:]
    var waiter: Waiter?
    /// Notify của kênh UI F0030002 trong lúc tải mặt đồng hồ.
    var uiChannel: PacketChannel?
    private var subscribers: [UUID: ([UInt8]) -> Void] = [:]
    private let defaults = UserDefaults(suiteName: "smartwear_veepoo") ?? .standard
    /// Gửi bài đang phát lần lượt (các gói `99 01` không được xen nhau).
    private let musicLock = AsyncLock()

    static let handshakeOps: Set<UInt8> = [0xA1, 0xA7, 0xAD, 0xB8]
    static let handshakeTimeout: TimeInterval = 8
    static let handshakeQuiet: TimeInterval = 0.6
    /// Chờ `A1` (app gốc: 4 s, `VOM:1099-1104`).
    static let passwordTimeout: TimeInterval = 4
    /// Đã có `A1` mà chưa đủ 5 gói `A7` thì chờ thêm tới mốc này.
    static let a7Wait: TimeInterval = 3
    static let measureIdle: TimeInterval = 20

    public init(scanned: ScannedDevice, match: DriverMatch) {
        gatt = GattConnection(id: scanned.id)
        let clean = Veepoo.cleanName(scanned.name)
        model = match.model ?? (clean.isEmpty ? "Thiết bị Veepoo" : clean)
        advertisedName = scanned.name
        advert = Veepoo.advert(scanned)
        super.init(id: scanned.id, driverId: VeepooDriver.driverId, name: clean.isEmpty ? model : clean, kind: match.kind,
                   mac: match.mac ?? advert?.mac)
        info = DeviceInfo(model: model, manufacturer: "Veepoo (G Band)", extra: baseExtra())
        attach(gatt)
        gatt.onNotification = { [weak self] uuid, data in self?.onNotification(uuid, data) }
        settings = VeepooSettings.decode(defaults.string(forKey: settingsKey))

        // Vòng tay tìm điện thoại: `B5 00 …` ⇒ đổ chuông (`g.java:336-358`).
        _ = subscribe { [weak self] p in
            if VeepooPhone.isFindPhone(p) { self?.onFindPhone?(true) }
        }
        // Chụp ảnh từ xa `B6`.
        _ = subscribe { [weak self] p in
            if let e = VeepooPhone.parseCamera(p) { self?.onRemoteCamera?(e) }
        }
        // Nhạc `99 02/03` hoặc kiểu cũ `01 01 01 xx`.
        _ = subscribe { [weak self] p in
            if let c = VeepooPhone.parseMusicCommand(p) { self?.onMusicCommand?(c) }
        }
        // SOS `B7 01 01` / `B7 04` ⇒ SDK gốc trả `B7 04 01` (`VOM:2303-2309`).
        _ = subscribe { [weak self] p in
            guard let self, p.count >= 2, p[0] == 0xB7, p[1] == 0x01 || p[1] == 0x04 else { return }
            self.onDeviceEvent?(.sosButton)
            Task { @MainActor in try? await self.writeCommand(Veepoo.padded(20, [0xB7, 0x04, 0x01])) }
        }
    }

    private var settingsKey: String { "settings_\(id.uuidString)" }

    private func baseExtra() -> [(key: String, value: String)] {
        var e: [(key: String, value: String)] = [
            ("Driver", "Veepoo / G Band (sdks/veepoo)"), ("Tên quảng bá", advertisedName ?? "không có"), ("UUID iOS", id.uuidString),
        ]
        if let a = advert {
            e.append(("Manufacturer data", String(format: "%04X", a.company)))
            if let m = a.mac { e.append(("MAC (quảng bá)", m)) }
            if let n = a.deviceNumber { e.append(("Device number (quảng bá)", "\(n)")) }
            if let n = a.advertNumber { e.append(("Mã quảng bá (byte 6–7)", "\(n)")) }
            if let fw = a.firmware { e.append(("Firmware (quảng bá)", fw)) }
        }
        return e
    }

    // MARK: - Kết nối + bắt tay

    override public func connect() async throws {
        guard state == .disconnected else { return }
        state = .connecting
        lastError = nil
        do {
            let started = Date()
            try await gatt.connect()
            recordLatency(since: started)
            gatt.onDisconnected = { [weak self] error in
                guard let self else { return }
                self.lastError = "Mất kết nối" + (error.map { ": \($0.localizedDescription)" } ?? "")
                self.waiter?.channel.close(GattError.disconnected)
                self.uiChannel?.close(GattError.disconnected)
            }
            guard gatt.hasService(Veepoo.service) else { throw VeepooError("Không có service F0080001: không phải thiết bị Veepoo") }
            // iOS tự thương lượng MTU (app Android xin 248). Như `VOM:842`: bật notify sau 500 ms.
            try await Task.sleep(nanoseconds: 500_000_000)
            try await gatt.setNotify(Veepoo.service, Veepoo.notify)
            gatt.noteStep("Notify F0080002 OK, ghi tối đa \(gatt.maximumWriteLength(withResponse: false)) byte, " +
                          "JieLi AE00=\(gatt.hasService(Veepoo.jieliService)), ZK F003=\(gatt.hasService(Veepoo.zkService)), " +
                          "UI F0030001=\(gatt.hasService(Veepoo.uiService))")

            try await handshake()
            try Task.checkCancellation()
            applyFeatures()
            do {
                try await refreshBattery()
            } catch {
                record(.error, "", Data(), "Đọc pin lỗi: \(error.localizedDescription)")
            }
            // Như chuỗi đọc/ghi sau kết nối của G Band (§4.4): gửi hồ sơ người dùng `A3`.
            if (try? await request(VeepooControls.userInfo(settings), timeout: 2) { $0.first == 0xA3 }) == nil {
                SmartWearLog.w("[\(name)] A3 không có phản hồi")
            }
            try Task.checkCancellation()
            deviceState = VeepooDeviceState()
            rebuildControls()
            gatt.noteStep("Bắt tay Veepoo xong, firmware \(passwordReply?.testVersion ?? "?")")
            markConnected()
            await updateRSSI()
            // Như Android: đọc nền nhắc `E7`, cảnh báo `AC`, hiệu chuẩn rồi dựng lại danh sách cài đặt.
            Task { @MainActor [weak self] in await self?.readDeviceState() }
        } catch {
            state = .disconnected
            lastError = error is CancellationError ? nil : "Kết nối lỗi: \(error.localizedDescription)"
            gatt.disconnect()
            throw error
        }
    }

    /// `A1` mật khẩu + giờ (§4.2), rồi gom các gói thiết bị tự đẩy: `A7` ×5, `AD`, `B8`. Dừng khi đã có `A1` + đủ 5 trang `A7`
    /// và im lặng `handshakeQuiet`, tối đa `handshakeTimeout`. Thiếu `AD` / `B8` thì đọc bằng lệnh.
    private func handshake() async throws {
        let password = defaults.string(forKey: "password_\(id.uuidString)") ?? Veepoo.defaultPassword
        let packet = try Veepoo.passwordCheck(password: password, now: Date(), is24h: Self.phoneUses24h(),
                                              requestPairing: VeepooDebug.requestPairing)
        var packets: [[UInt8]] = []
        try await lock.withLock {
            let channel = PacketChannel()
            waiter = Waiter(match: { Self.handshakeOps.contains($0.first ?? 0) }, channel: channel)
            defer { waiter = nil }
            let started = Date()
            try await writeCommand(packet)
            while Date().timeIntervalSince(started) < Self.handshakeTimeout {
                let left = Self.handshakeTimeout - Date().timeIntervalSince(started)
                if let p = try await channel.receive(timeout: min(Self.handshakeQuiet, left)) {
                    if p.first == 0xA1, !packets.contains(where: { $0.first == 0xA1 }) { recordLatency(since: started) }
                    packets.append(p)
                    continue
                }
                let hasA1 = packets.contains { $0.first == 0xA1 }
                let pages = Set(packets.filter { $0.first == 0xA7 && $0.count >= 20 }.map { Int($0[19]) })
                let elapsed = Date().timeIntervalSince(started)
                if hasA1 && pages.isSuperset(of: 1...5) { break }
                if hasA1 && elapsed > Self.a7Wait { break }
                if !hasA1 && elapsed > Self.passwordTimeout { break }
            }
        }
        for p in packets { SmartWearLog.i("[\(name)] bắt tay ← \(p.hex)") }
        guard let reply = packets.first(where: { $0.first == 0xA1 }).flatMap(Veepoo.parsePasswordReply) else {
            throw VeepooError("Vòng tay không trả lời A1 (mật khẩu)")
        }
        guard Veepoo.passwordAccepted(reply) else {
            try? await writeCommand(Veepoo.disconnectCommand)
            throw VeepooError("Sai mật khẩu (A1 trạng thái \(reply.status.rawValue))")
        }
        passwordReply = reply
        features = VeepooFeatures(packets: packets)
        var ad = packets.filter { $0.first == 0xAD && $0.count >= 20 }
        var b8 = packets.filter { $0.first == 0xB8 && $0.count >= 20 }
        if ad.isEmpty { ad = (try? await collect(VeepooMessageSwitches.read, idle: 1) { $0.first == 0xAD && $0.count >= 20 }) ?? [] }
        if b8.isEmpty { b8 = (try? await collect(VeepooCustomSettings.read, idle: 1) { $0.first == 0xB8 && $0.count >= 20 }) ?? [] }
        messageSwitches = VeepooMessageSwitches(packets: ad)
        customSettings = VeepooCustomSettings(packets: b8)
        gatt.noteStep("A1 \(reply.status), device number \(reply.deviceNumber), firmware \(reply.testVersion), " +
                      "A7 \(features.pages.count)/5 trang, AD \(ad.count) gói, B8 \(b8.count) gói")
        SmartWearLog.i("[\(name)] \(features.describe())")
        SmartWearLog.i("[\(name)] \(messageSwitches.description); \(customSettings.description)")
    }

    /// iPhone đang dùng định dạng 24 giờ (mẫu giờ địa phương không có "a").
    static func phoneUses24h() -> Bool {
        !(DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "").contains("a")
    }

    private func applyFeatures() {
        let f = features
        capabilities = f.capabilities()
        if let r = passwordReply, r.mac != "00:00:00:00:00:00" { mac = r.mac }
        var di = DeviceInfo(model: model, manufacturer: "Veepoo (G Band)",
                            hardware: passwordReply.map { "Veepoo #\($0.deviceNumber)" }, firmware: passwordReply?.testVersion,
                            extra: baseExtra())
        if let r = passwordReply {
            di.setExtra("Device number (A1)", "\(r.deviceNumber)")
            di.setExtra("MAC (A1)", r.mac)
        }
        di.setExtra("Chip", f.cpuName)
        di.setExtra("Lịch sử 5 phút", f.usesDf ? "DF (origin \(f.originProtocolVersion))" : "D1 (origin \(f.originProtocolVersion))")
        di.setExtra("Ngủ", !f.sleep ? "không có" : f.preciseSleep ? "chính xác (sleepTag \(f.sleepTag))" : "thường")
        di.setExtra("Số ngày lịch sử", "\(f.watchDays)")
        di.setExtra("Mặt đồng hồ", "server \(f.watchUiServerCount), tuỳ chỉnh \(f.watchUiCustomCount), kiểu dựng sẵn \(f.screenStyleCount), bigData \(f.bigDataTranType)")
        di.setExtra("Độ dài ghi iOS", "\(gatt.maximumWriteLength(withResponse: false))")
        for page in 1...5 { di.setExtra("A7 gói \(page)", f.pages[page]?.hex ?? "không có") }
        di.setExtra("AD", messageSwitches.description)
        di.setExtra("B8", customSettings.description)
        info = di
    }

    /// Như `VOM:2568-2572`: báo `AF 00` rồi mới đóng GATT.
    override public func disconnect() {
        cancelAllMeasurements()
        let wasConnected = state == .connected && gatt.state == .connected
        state = .disconnecting
        Task { @MainActor in
            if wasConnected {
                try? await self.writeCommand(Veepoo.disconnectCommand)
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            self.waiter?.channel.close(GattError.disconnected)
            self.uiChannel?.close(GattError.disconnected)
            self.gatt.disconnect()
            self.state = .disconnected
        }
    }

    override public func refreshBattery() async throws {
        let p = try await request(Veepoo.batteryRead) { $0.first == 0xA0 && $0.count >= 8 }
        SmartWearLog.i("[\(name)] pin \(p.hex)")
        if let b = Veepoo.parseBattery(p) {
            battery = b.percent
            charging = b.charging
        }
    }

    // MARK: - Đo trực tiếp

    override public var measurableCapabilities: [Capability] {
        var out: [Capability] = []
        if capabilities.contains(.heartRate) { out.append(.heartRate) }
        if capabilities.contains(.spo2) { out.append(.spo2) }
        if capabilities.contains(.bloodPressure) { out.append(.bloodPressure) }
        // GE54 báo nhiệt độ kiểu 5 (ZK) nhưng vẫn trả lời `87` (Android đo thật 19/10/2026) ⇒ không lọc theo kiểu.
        if capabilities.contains(.temperature) { out.append(.temperature) }
        if capabilities.contains(.stress) { out.append(.stress) }
        if capabilities.contains(.hrv), features.hrvByApp { out.append(.hrv) }
        if capabilities.contains(.bloodSugar) { out.append(.bloodSugar) }
        // MET đo từ app chỉ khi kiểu 3 (GE54 = 2: MET chỉ có trong lịch sử).
        if capabilities.contains(.met), features.metByApp { out.append(.met) }
        if capabilities.contains(.uricAcid) { out.append(.uricAcid) }
        if capabilities.contains(.bloodLipids) { out.append(.bloodLipids) }
        if capabilities.contains(.bodyComposition) { out.append(.bodyComposition) }
        return out
    }

    override public func measure(_ capability: Capability) -> AsyncThrowingStream<Reading, Error> {
        guard measurableCapabilities.contains(capability) else { return super.measure(capability) }
        switch capability {
        case .heartRate:
            return live(capability, start: VeepooMeasure.heartRateStart, stop: VeepooMeasure.heartRateStop, op: 0xD0,
                        parse: VeepooMeasure.heartRate())
        case .spo2:
            return live(capability, start: VeepooMeasure.spo2Start, stop: VeepooMeasure.spo2Stop, op: 0x80, parse: VeepooMeasure.spo2())
        case .bloodPressure:
            return live(capability, start: VeepooMeasure.bloodPressureStart, stop: VeepooMeasure.bloodPressureStop, op: 0x90,
                        parse: VeepooMeasure.bloodPressure())
        case .temperature:
            return live(capability, start: VeepooMeasure.temperatureStart, stop: VeepooMeasure.temperatureStop, op: 0x87,
                        parse: VeepooMeasure.temperature())
        case .stress:
            return live(capability, start: VeepooMeasure.stressStart, stop: VeepooMeasure.stressStop, op: 0x89,
                        parse: VeepooMeasure.stress())
        case .hrv:
            return live(capability, start: VeepooMeasure.hrvStart, stop: VeepooMeasure.hrvStop, op: 0x89, parse: VeepooMeasure.hrv())
        case .bloodSugar:
            let privateMode = deviceState.calibration.glucose?.on ?? false
            return live(capability, start: VeepooMeasure.glucoseStart(privateMode: privateMode), stop: VeepooMeasure.glucoseStop(privateMode: privateMode),
                        op: 0x89, parse: VeepooMeasure.bloodGlucose())
        case .met:
            return live(capability, start: VeepooMeasure.metStart, stop: VeepooMeasure.metStop, op: 0x89, parse: VeepooMeasure.met())
        case .uricAcid, .bloodLipids:
            // Một lần đo `8A` cho cả acid uric và mỡ máu. Luôn chế độ thường `8A 01 01 00` như mặc định G Band (như Android): chế độ
            // riêng bám giá trị hiệu chuẩn đang lưu (GE54 19/10: hiệu chuẩn 15/12/10/15 ⇒ 15,58/12,26/10,03/16,09 mmol/L).
            return live(capability, start: VeepooMeasure.bloodComponentStart(privateMode: false), stop: VeepooMeasure.bloodComponentStop,
                        op: 0x8A, parse: VeepooMeasure.bloodComponent(capability),
                        first: VeepooMeasure.touching(capability, unit: capability == .uricAcid ? "µmol/L" : "mmol/L"))
        case .bodyComposition:
            return live(capability, start: VeepooMeasure.bodyCompositionStart, stop: VeepooMeasure.bodyCompositionStop, op: 0x93,
                        parse: VeepooMeasure.bodyComposition(), first: VeepooMeasure.touching(capability, unit: "%"))
        default:
            return super.measure(capability)
        }
    }

    /// Phép đo trực tiếp (như `live` Android): gửi `start`, nhận gói opcode `op` (`parse` trả Reading + cờ kết thúc), luôn gửi
    /// `stop` khi luồng kết thúc (kể cả bị huỷ). Không có gói nào trong `measureIdle` ⇒ báo lỗi và kết thúc. `first` = Reading phát
    /// ngay khi bắt đầu (vd nhắc chạm cảm biến).
    private func live(
        _ capability: Capability, start: [UInt8], stop: [UInt8], op: UInt8, parse: @escaping VeepooMeasure.Parser, first: Reading? = nil
    ) -> AsyncThrowingStream<Reading, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(first ?? Reading(capability: capability, status: .measuring, unit: ""))
            let last = Box(Date())
            let token = subscribe { p in
                guard p.first == op, let (reading, done) = parse(p) else { return }
                last.value = Date()
                continuation.yield(reading)
                if done { continuation.finish() }
            }
            let watchdog = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if Date().timeIntervalSince(last.value) > Self.measureIdle {
                        continuation.yield(Reading(capability: capability, status: .error, unit: "", errorCode: -1,
                                                   note: "Vòng tay không gửi kết quả"))
                        continuation.finish()
                        return
                    }
                }
            }
            let starter = Task { @MainActor [weak self] in
                do {
                    try await self?.writeCommand(start)
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
                    if self.gatt.state == .connected { try? await self.writeCommand(stop) }
                }
            }
        }
    }

    // MARK: - Nhịp tim liên tục

    override public var supportsHeartRateStream: Bool { capabilities.contains(.heartRate) }

    /// `D0 01` rồi nhận mọi gói `D0` (vòng tay đo tới khi app gửi `D0 00`), như Android. Im lặng quá `measureIdle` thì gửi lại
    /// `D0 01`; im lặng lần nữa ⇒ lỗi. Vòng tay bận / đang sạc ⇒ lỗi. Huỷ thì gửi `D0 00`.
    override public func heartRateStream() -> AsyncThrowingStream<HeartRateSample, Error> {
        guard supportsHeartRateStream else { return super.heartRateStream() }
        return AsyncThrowingStream { continuation in
            let last = Box(Date())
            let token = subscribe { p in
                guard p.first == 0xD0 else { return }
                last.value = Date()
                switch VeepooMeasure.heartRateSample(p) {
                case .sample(let x)?: continuation.yield(x)
                case .failed(let message)?: continuation.finish(throwing: VeepooError(message))
                case nil: break
                }
            }
            let runner = Task { @MainActor [weak self] in
                do {
                    try await self?.writeCommand(VeepooMeasure.heartRateStart)
                    var restartedAt: Date?
                    while !Task.isCancelled {
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                        let now = Date()
                        if let r = restartedAt, last.value > r { restartedAt = nil }
                        guard now.timeIntervalSince(last.value) > Self.measureIdle else { continue }
                        if restartedAt != nil { throw VeepooError("Vòng tay không gửi nhịp tim") }
                        restartedAt = now
                        last.value = now
                        try await self?.writeCommand(VeepooMeasure.heartRateStart)
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
                    if self.gatt.state == .connected { try? await self.writeCommand(VeepooMeasure.heartRateStop) }
                }
            }
        }
    }

    // MARK: - Lịch sử

    override public var supportsHistory: Bool { true }

    override public func syncHistoryImpl(days: Int, progress: @escaping @MainActor (SyncProgress) -> Void) async throws -> DeviceHistory {
        try await runHistorySync(days: days, progress: progress)
    }

    // MARK: - Điện thoại ↔ vòng tay

    /// Có bảng `AD` ⇒ vòng tay hiện thông báo. iOS: vòng tay đọc ANCS sau khi ghép đôi; app chỉ bật/tắt từng app (`AD 01`).
    override public var supportsNotifications: Bool { messageSwitches.any }
    override public var ancsAuthorized: Bool? { gatt.ancsAuthorized }

    override public var supportsRemoteCamera: Bool { features.camera }

    /// `B6 01` / `B6 00`: báo vòng tay app đã mở / đóng màn chụp.
    override public func setRemoteCamera(_ open: Bool) async {
        guard gatt.state == .connected else { return }
        try? await writeCommand(VeepooPhone.camera(open))
    }

    /// Người dùng đã thấy điện thoại ⇒ `B5 02` để vòng tay tắt màn tìm điện thoại. Bắt đầu đổ chuông thì không cần gửi gì.
    override public func setPhoneRinging(_ ringing: Bool) async {
        guard !ringing, gatt.state == .connected else { return }
        try? await writeCommand(VeepooPhone.findPhoneStop)
    }

    // Nhạc

    override public var supportsMusicControl: Bool {
        features.musicType != 0 || customSettings.supported(0, VeepooCustomSettings.musicControl)
    }
    override public var supportsTrackInfo: Bool { features.musicType == 1 }

    override public func setMusicState(_ music: MusicState) async {
        guard state == .connected, supportsTrackInfo else { return }
        await musicLock.withLock {
            for p in VeepooPhone.musicPackets(music) {
                do { try await writeCommand(p) } catch {
                    SmartWearLog.w("[\(name)] gửi bài đang phát lỗi: \(error.localizedDescription)")
                    return
                }
            }
        }
    }

    override public func setMusicVolume(_ percent: Int) async {
        guard state == .connected, supportsTrackInfo else { return }
        await musicLock.withLock {
            for p in VeepooPhone.volumePackets(percent) { try? await writeCommand(p) }
        }
    }

    // Danh bạ

    override public var maxContacts: Int { features.maxContacts }
    override public var supportsClearContacts: Bool { features.contacts }

    /// Xoá các id 1…`maxContacts` (`72 04 id`, cách nhau 100 ms như `deleteContacts`), rồi thêm lần lượt từng liên hệ id 1, 2…
    /// (`72 01 idx total` + 16 byte, chờ `72 01 01`). Liên hệ SOS: thiết bị có SOS (kiểu 2/3) thì gửi `A4 01 00`.
    @discardableResult
    override public func syncContacts(_ contacts: [Contact], progress: ((Double) -> Void)? = nil) async throws -> Int {
        guard state == .connected else { throw VeepooError("Vòng tay chưa kết nối") }
        guard features.contacts else { throw VeepooError("Vòng tay không hỗ trợ danh bạ") }
        let list = Array(contacts.filter { !VeepooPhone.cleanPhone($0.phone).isEmpty }.prefix(features.maxContacts))
        try await clearContacts()
        let sos: Bool? = features.contactType >= 2 ? false : nil
        for (i, c) in list.enumerated() {
            let packets = VeepooPhone.contactPackets(id: i + 1, name: c.name, phone: VeepooPhone.cleanPhone(c.phone), sos: sos)
            let saved = try await sendAndWait(packets, timeout: 3) { VeepooPhone.isContactSaved($0) != nil }
            if let saved, VeepooPhone.isContactSaved(saved) == false {
                SmartWearLog.w("[\(name)] vòng tay báo lỗi khi lưu liên hệ \(i + 1): \(saved.hex)")
            }
            progress?(Double(i + 1) / Double(max(list.count, 1)))
        }
        SmartWearLog.i("[\(name)] đã ghi \(list.count) liên hệ")
        return list.count
    }

    override public func clearContacts() async throws {
        guard state == .connected else { throw VeepooError("Vòng tay chưa kết nối") }
        guard features.contacts else { throw VeepooError("Vòng tay không hỗ trợ danh bạ") }
        for id in 1...max(features.maxContacts, 1) {
            try await writeCommand(VeepooPhone.contactDelete(id: id))
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    // MARK: - Báo thức có chữ `B9` (VeepooAlarm.swift)

    override public var supportsAlarms: Bool { features.textAlarm }
    override public var maxAlarms: Int { features.textAlarm ? VeepooAlarm.maxCount : 0 }
    override public func alarms() async throws -> [Alarm] { try await readTextAlarms() }
    override public func setAlarm(_ alarm: Alarm) async throws { try await writeTextAlarm(alarm) }
    override public func deleteAlarm(_ id: Int) async throws { try await deleteTextAlarm(id) }

    // MARK: - Mặt đồng hồ (Veepoo gốc)

    override public var supportsWatchFace: Bool { features.nativeWatchFace && gatt.hasService(Veepoo.uiService) }

    /// `50 02 01` (mặt chợ: dung lượng, CRC mặt đang cài) + `50 02 02` (mặt tuỳ chỉnh: kích thước màn) + `C7 02` (mặt đang chọn).
    override public func watchFaceInfo() async throws -> WatchFaceInfo {
        guard state == .connected else { throw VeepooError("Vòng tay chưa kết nối") }
        guard supportsWatchFace else { throw VeepooError("Vòng tay không có mặt đồng hồ Veepoo gốc (chip \(features.cpuName))") }
        let server = try await serverFaceInfo()
        let custom = features.watchUiCustomCount > 0
            ? (try? await request(VeepooWatchFace.infoRead(VeepooWatchFace.typeCustom), timeout: 3) { $0.first == 0x50 && $0.count >= 20 && $0[2] == VeepooWatchFace.typeCustom })
                .flatMap(VeepooWatchFace.parseCustomInfo) : nil
        let style = (try? await request(VeepooWatchFace.styleRead, timeout: 2) { $0.first == 0xC7 }).flatMap(VeepooWatchFace.parseStyle)
        let screen = custom.flatMap { VeepooWatchFace.screen(uiType: $0.uiType) }
        return WatchFaceInfo(
            width: screen?.width ?? 0, height: screen?.height ?? 0, round: screen?.round ?? (features.screenShape == 4),
            maxBytes: server.maxLength, currentId: server.crcId, slotCount: features.watchUiServerCount,
            customActive: style?.from == 2
        )
    }

    private func serverFaceInfo() async throws -> VeepooWatchFace.ServerInfo {
        let p = try await request(VeepooWatchFace.infoRead(VeepooWatchFace.typeServer), timeout: 3) {
            $0.first == 0x50 && $0.count >= 20 && $0[1] == 0x02 && $0[2] == VeepooWatchFace.typeServer
        }
        SmartWearLog.i("[\(name)] 50 02 01 = \(p.hex)")
        guard let info = VeepooWatchFace.parseServerInfo(p) else { throw VeepooError("Phản hồi 50 02 01 không hợp lệ: \(p.hex)") }
        return info
    }

    /// Cài file mặt đồng hồ chợ Veepoo (`.bin` tải từ chợ của hãng cho đúng device number) theo luồng `UiUpdateUtil`
    /// (03-watchface-ota §1c): `50 02 01` → đệm `FF` bội 4 + CRC-16 (trùng CRC mặt đang cài ⇒ xong) → `50 01 01 …` →
    /// `DOOG 05 00` → ← `05` → `DOOG 01 addr len` → ← `01 03` → khối thô MTU−5 byte lên F0030003 (không phản hồi) →
    /// `DOOG 02` → ← `02` → `DOOG 03 crc` → ← `03 crc` → kích hoạt `C7 01 01 01`.
    override public func installWatchFace(_ file: Data, progress: @escaping (Double) -> Void = { _ in }) async throws {
        guard state == .connected else { throw VeepooError("Vòng tay chưa kết nối") }
        guard supportsWatchFace else { throw VeepooError("Vòng tay không có mặt đồng hồ Veepoo gốc (chip \(features.cpuName))") }
        let server = try await serverFaceInfo()
        let (data, crc) = VeepooWatchFace.prepare([UInt8](file))
        guard data.count <= server.maxLength || server.maxLength == 0 else {
            throw VeepooError("File \(data.count) byte lớn hơn dung lượng \(server.maxLength) byte")
        }
        if crc == server.crcId {
            SmartWearLog.i("[\(name)] mặt đồng hồ đã cài (CRC trùng \(String(format: "%04X", crc)))")
            progress(1)
            return
        }
        try await BleQuiet.hold { try await self.uploadFace(data, crc: crc, server: server, progress: progress) }
        _ = try? await request(VeepooWatchFace.select(index: 1, from: 1), timeout: 3) { $0.first == 0xC7 }
        SmartWearLog.i("[\(name)] đã cài mặt đồng hồ \(data.count) byte, CRC \(String(format: "%04X", crc))")
    }

    private func uploadFace(_ data: [UInt8], crc: Int, server: VeepooWatchFace.ServerInfo, progress: (Double) -> Void) async throws {
        try await gatt.setNotify(Veepoo.uiService, Veepoo.uiControl)
        let enter = VeepooWatchFace.updateModeServer(address: server.address, length: data.count, binDataType: server.binDataType, crc: crc)
        let ack = try await request(enter, timeout: 5) { $0.first == 0x50 && $0.count >= 4 && $0[1] == 0x01 }
        guard ack[3] == 1 else { throw VeepooError("Vòng tay từ chối chế độ nhận mặt đồng hồ: \(ack.hex)") }
        try await lock.withLock {
            let channel = PacketChannel()
            uiChannel = channel
            defer { uiChannel = nil }
            func next(_ timeout: TimeInterval, _ what: String) async throws -> VeepooWatchFace.Event {
                while true {
                    guard let p = try await channel.receive(timeout: timeout) else { throw VeepooError("Hết giờ chờ \(what)") }
                    if let e = VeepooWatchFace.parseEvent(p) {
                        if e == .lengthNotMultipleOf4 { throw VeepooError("Vòng tay báo độ dài file không phải bội 4") }
                        return e
                    }
                }
            }
            try await gatt.write(Veepoo.uiService, Veepoo.uiControl, Data(VeepooWatchFace.doogStart), withResponse: true)
            guard try await next(10, "DOOG 05") == .ready else { throw VeepooError("Vòng tay không sẵn sàng nhận (DOOG 05)") }
            try await gatt.write(Veepoo.uiService, Veepoo.uiControl,
                                 Data(VeepooWatchFace.doogErase(address: server.address, length: data.count)), withResponse: true)
            while true {
                let e = try await next(60, "xoá vùng nhớ")
                if e == .eraseDone { break }
            }
            let chunk = VeepooWatchFace.chunkSize(maxWriteLength: gatt.maximumWriteLength(withResponse: false))
            var offset = 0
            while offset < data.count {
                let end = min(offset + chunk, data.count)
                try await gatt.write(Veepoo.uiService, Veepoo.uiData, Data(data[offset..<end]), withResponse: false)
                offset = end
                progress(Double(offset) / Double(data.count))
            }
            try await gatt.write(Veepoo.uiService, Veepoo.uiControl, Data(VeepooWatchFace.doogEnd), withResponse: true)
            guard try await next(15, "DOOG 02") == .received else { throw VeepooError("Vòng tay không xác nhận đã nhận đủ dữ liệu") }
            try await gatt.write(Veepoo.uiService, Veepoo.uiControl, Data(VeepooWatchFace.doogCheck(crc: crc)), withResponse: true)
            guard case .crc(let deviceCrc) = try await next(15, "kiểm CRC") else { throw VeepooError("Không nhận được CRC từ vòng tay") }
            guard deviceCrc == crc else {
                throw VeepooError(String(format: "Sai CRC: vòng tay %04X, app %04X", deviceCrc, crc))
            }
        }
    }

    // MARK: - Gỡ lỗi

    private final class PacketBox { var packets: [[UInt8]] = [] }

    /// Gỡ lỗi giao thức: gửi gói thô lên F0080003 và trả mọi gói vòng tay tự gửi trong `listen` giây (gói khớp lệnh đang chờ
    /// khác không được tính). Chỉ dùng cho lệnh đọc.
    public func debugExchange(_ bytes: [UInt8], listen: TimeInterval = 3) async throws -> [[UInt8]] {
        let box = PacketBox()
        let token = subscribe { box.packets.append($0) }
        defer { unsubscribe(token) }
        try await writeCommand(bytes)
        try await Task.sleep(nanoseconds: UInt64(listen * 1_000_000_000))
        return box.packets
    }

    /// Đổi mật khẩu đã lưu (dùng ở lần kết nối sau) khi vòng tay từng được đặt mật khẩu khác "0000" (Q7).
    public func setPassword(_ password: String) throws {
        _ = try Veepoo.passwordCheck(password: password, now: Date(), is24h: true)
        defaults.set(password, forKey: "password_\(id.uuidString)")
    }

    // MARK: - Kênh lệnh

    func writeCommand(_ bytes: [UInt8]) async throws {
        try await gatt.write(Veepoo.service, Veepoo.write, Data(bytes), withResponse: true)
    }

    /// Gửi lệnh và chờ gói đầu tiên khớp `match`.
    func request(_ bytes: [UInt8], timeout: TimeInterval = 3, match: @escaping ([UInt8]) -> Bool) async throws -> [UInt8] {
        try await lock.withLock {
            let channel = PacketChannel()
            waiter = Waiter(match: match, channel: channel)
            defer { waiter = nil }
            let started = Date()
            try await writeCommand(bytes)
            guard let p = try await channel.receive(timeout: timeout) else {
                throw VeepooError(String(format: "Lệnh %02X không có phản hồi", bytes.first ?? 0))
            }
            recordLatency(since: started)
            return p
        }
    }

    /// Gửi lần lượt các gói rồi chờ gói khớp `match` (nil nếu hết giờ).
    func sendAndWait(_ packets: [[UInt8]], timeout: TimeInterval, match: @escaping ([UInt8]) -> Bool) async throws -> [UInt8]? {
        try await lock.withLock {
            let channel = PacketChannel()
            waiter = Waiter(match: match, channel: channel)
            defer { waiter = nil }
            for p in packets { try await writeCommand(p) }
            return try await channel.receive(timeout: timeout)
        }
    }

    /// Gửi `command` rồi gom mọi gói khớp `match` tới gói `end` (có gồm) hoặc khi im lặng quá `idle` giây.
    func collect(
        _ command: [UInt8], idle: TimeInterval, end: @escaping ([UInt8]) -> Bool = { _ in false }, match: @escaping ([UInt8]) -> Bool
    ) async throws -> [[UInt8]] {
        try await lock.withLock {
            let channel = PacketChannel()
            waiter = Waiter(match: match, channel: channel)
            defer { waiter = nil }
            try await writeCommand(command)
            var out: [[UInt8]] = []
            while let p = try await channel.receive(timeout: idle) {
                out.append(p)
                if end(p) { break }
            }
            return out
        }
    }

    private func subscribe(_ handler: @escaping ([UInt8]) -> Void) -> UUID {
        let token = UUID()
        subscribers[token] = handler
        return token
    }

    private func unsubscribe(_ token: UUID) { subscribers[token] = nil }

    /// Gói F0080002: khớp lệnh đang chờ thì giao cho lệnh đó, còn lại là gói vòng tay tự đẩy. Gói F0030002 cho luồng mặt đồng hồ.
    private func onNotification(_ uuid: CBUUID, _ value: Data) {
        let p = [UInt8](value)
        guard !p.isEmpty else { return }
        if uuid == Veepoo.uiControl {
            uiChannel?.send(p)
            return
        }
        guard uuid == Veepoo.notify else { return }
        if let w = waiter, w.match(p) {
            w.channel.send(p)
        } else {
            for handler in subscribers.values { handler(p) }
        }
    }
}

// MARK: - Cài đặt

extension VeepooDevice: ConfigurableDevice {
    func rebuildControls() {
        controls = VeepooControls.controls(features, customSettings, messageSwitches, settings, deviceState)
    }

    private func save(_ s: VeepooSettings) {
        settings = s
        defaults.set(s.encode(), forKey: settingsKey)
        rebuildControls()
    }

    /// Đọc (không ghi) `E7` từng loại nhắc, cảnh báo nhịp tim `AC`, hiệu chuẩn; rồi dựng lại `controls` (như `readDeviceState`
    /// Android). Lệnh lỗi / vòng tay không trả lời thì bỏ qua mục đó.
    func readDeviceState() async {
        guard state == .connected else { return }
        let f = features
        var st = deviceState
        if f.healthRemind {
            // G Band đọc tất cả bằng `E7 02 00`: vòng tay trả từng loại tới gói `[10]` = `[11]`.
            let all = (try? await collect(VeepooControls.remindRead(0), idle: 1.5, end: VeepooControls.isLastRemind) {
                $0.first == 0xE7 && $0.count >= 3 && $0[1] == 2
            }) ?? []
            SmartWearLog.i("[\(name)] E7 02 00 = \(all.map(\.hex).joined(separator: " | "))")
            for r in all.compactMap(VeepooControls.parseRemind) { st.reminds[r.type] = r }
            // Không đọc được kiểu gộp thì đọc từng loại như Android.
            if all.isEmpty {
                for k in VeepooControls.remindKinds {
                    let p = try? await request(VeepooControls.remindRead(k.type), timeout: 2) { $0.first == 0xE7 && $0.count >= 3 && $0[1] == 2 }
                    SmartWearLog.i("[\(name)] E7 02 \(k.type) = \(p?.hex ?? "không trả lời")")
                    if let r = p.flatMap(VeepooControls.parseRemind) { st.reminds[k.type] = r }
                }
            }
        }
        if f.heartRateAlarm {
            let p = try? await request(VeepooControls.heartAlarmRead, timeout: 2) { $0.first == 0xAC }
            SmartWearLog.i("[\(name)] AC = \(p?.hex ?? "không trả lời")")
            if let a = p.flatMap(VeepooControls.parseHeartAlarm) { st.heartAlarm = a }
        }
        st.calibration = await readCalibration(st.calibration)
        deviceState = st
        rebuildControls()
    }

    /// Ghi một byte `B8` (giữ nguyên các byte khác như đã đọc), chờ `B8` cùng trang (có thể không trả lời: bỏ qua).
    private func writeCustom(_ page: Int, _ index: Int, _ value: Int) async throws {
        guard let p = customSettings.write(page, index, value) else { throw VeepooError("Chưa đọc được cài đặt B8 trang \(page)") }
        let rsp = try? await request(p, timeout: 2) { $0.first == 0xB8 && $0.count >= 20 && Int($0[19]) == page }
        SmartWearLog.i("[\(name)] B8 \(page).\(index)=\(value) → \(rsp?.hex ?? "không trả lời")")
        customSettings = customSettings.with(page, index, value)
    }

    public func setControl(_ id: String, _ value: ControlValue) async throws {
        let on: Bool = { if case .bool(let b) = value { return b }; return false }()
        let number: Int = { if case .number(let n) = value { return n }; return 0 }()
        let key = id.split(separator: ".").first.map(String.init) ?? id

        // Mục lưu cục bộ (hồ sơ, mục tiêu, màn hình, E1): nhận cả khi chưa kết nối, gửi khi đang kết nối.
        if ["profile", "goal", "display"].contains(key) || (key == "sedentary" && !features.healthRemind) {
            save(settings.with(id, value))
            guard state == .connected else { return }
            for cmd in VeepooControls.commands(id, features, settings) { try await writeCommand(cmd) }
            return
        }
        guard state == .connected else { throw VeepooError("Vòng tay chưa kết nối") }

        if let c = VeepooControls.b8Change(id, value) {
            try await writeCustom(c.page, c.index, c.value)
            // Đổi 12/24h: gửi lại giờ `A5` kèm chế độ mới (app gốc làm vậy).
            if id == "unit.hour24" { try? await writeCommand(Veepoo.setTime(Date(), is24h: on)) }
        } else if let (type, field) = Self.remindTarget(id) {
            let cur = deviceState.reminds[type] ?? VeepooRemind(type: type, fromMinute: 9 * 60, toMinute: 18 * 60, interval: 60, on: false)
            var next = cur
            switch (field, value) {
            case ("enabled", .bool(let b)): next.on = b
            case ("interval", .number(let n)): next.interval = n
            case ("range", .timeRange(let from, let to)):
                next.fromMinute = from
                next.toMinute = to
            default: throw VeepooError("Giá trị không hợp lệ cho \(id)")
            }
            let rsp = try await request(VeepooControls.remindWrite(next), timeout: 3) { $0.first == 0xE7 && $0.count >= 3 && $0[1] == 1 }
            guard rsp[2] == 1 else { throw VeepooError("Vòng tay từ chối E7: \(rsp.hex)") }
            deviceState.reminds[type] = next
        } else if key == "hrAlarm" {
            var next = deviceState.heartAlarm ?? VeepooHeartAlarm(high: 160, low: 45, on: false)
            switch id {
            case "hrAlarm.enabled": next.on = on
            case "hrAlarm.high": next.high = number
            case "hrAlarm.low": next.low = number
            default: throw VeepooError("Không có mục \(id)")
            }
            let rsp = try? await request(VeepooControls.heartAlarmWrite(next), timeout: 3) { $0.first == 0xAC }
            SmartWearLog.i("[\(name)] AC ghi → \(rsp?.hex ?? "không trả lời")")
            deviceState.heartAlarm = next
        } else if id == "language" {
            guard let packet = VeepooControls.language(number) else { throw VeepooError("Không có ngôn ngữ \(number)") }
            let rsp = try? await request(packet, timeout: 3) { $0.first == 0xF4 }
            SmartWearLog.i("[\(name)] F4 → \(rsp?.hex ?? "không trả lời")")
            deviceState.language = VeepooSettings.languages[number].code
        } else if key == "calibrate" {
            deviceState.calibration = try await writeCalibration(id, value, deviceState.calibration)
        } else if key == "notify", let type = Int(id.dropFirst("notify.".count)) {
            let next = messageSwitches.with(type, on: on)
            for p in next.writePackets(next.isOn) { try await writeCommand(p) }
            messageSwitches = next
        } else {
            throw VeepooError("Không có mục \(id)")
        }
        rebuildControls()
    }

    /// `remind.<loại>.<trường>` → (type `E7`, trường). Nhận cả `sedentary.*` / `drink.*` cho vòng tay `E7` (id cũ).
    static func remindTarget(_ id: String) -> (type: Int, field: String)? {
        let parts = id.split(separator: ".").map(String.init)
        if parts.count == 3, parts[0] == "remind", let t = VeepooControls.remindType(key: parts[1]) { return (t, parts[2]) }
        if parts.count == 2, parts[0] == "sedentary" || parts[0] == "drink", let t = VeepooControls.remindType(key: parts[0]) {
            return (t, parts[1])
        }
        return nil
    }

    public func runAction(_ id: String) async throws {
        guard state == .connected else { throw VeepooError("Vòng tay chưa kết nối") }
        switch id {
        case "find.start": try await writeCommand(VeepooPhone.findDeviceStart)
        case "find.stop": try await writeCommand(VeepooPhone.findDeviceStop)
        case "device.read":
            let b8 = (try? await collect(VeepooCustomSettings.read, idle: 1) { $0.first == 0xB8 && $0.count >= 20 }) ?? []
            if !b8.isEmpty {
                let fresh = VeepooCustomSettings(packets: b8)
                customSettings = VeepooCustomSettings(page0: fresh.page0 ?? customSettings.page0, page1: fresh.page1 ?? customSettings.page1)
            }
            await readDeviceState()
        // iOS: vòng tay tự khởi xướng bond để đọc ANCS (`BC 01`, chỉ có trong SDK iOS).
        case "notify.pair": try await writeCommand(Veepoo.pairWithPhone)
        // Hành động nguy hiểm: app phải hỏi người dùng theo `DeviceControl.confirm` trước khi gọi.
        case "data.reset":
            try await writeCommand(VeepooControls.factoryReset)
            SmartWearLog.w("[\(name)] đã gửi FF 55 (khôi phục cài đặt gốc)")
        case "device.powerOff":
            try await writeCommand(VeepooControls.powerOff)
            SmartWearLog.w("[\(name)] đã gửi F2 04 (tắt máy)")
        default: throw VeepooError("Không có hành động \(id)")
        }
    }
}

// MARK: - Thời tiết

extension VeepooDevice: WeatherDisplay {
    public var supportsWeather: Bool { features.weather }

    /// `C8 03 01 00` (bật, °C) rồi TLV đầy đủ `C8 04 total idx` + 16 byte, cách nhau 50 ms (`u2.java`, `com/veepoo/device/f.java`).
    public func setWeather(_ forecast: WeatherForecast) async throws {
        guard state == .connected else { throw VeepooError("Vòng tay chưa kết nối") }
        guard supportsWeather else { throw VeepooError("Vòng tay không hỗ trợ thời tiết") }
        try await writeCommand(VeepooWeather.status(enabled: true))
        for p in VeepooWeather.packets(forecast) {
            try await writeCommand(p)
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
