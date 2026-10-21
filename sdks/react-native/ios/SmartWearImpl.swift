import Foundation
import SmartWearCore
import SmartWearGloryFit
import SmartWearQRing
import SmartWearStandard
import SmartWearVeepoo

/// Phần Swift của TurboModule `SmartWear` (iOS): bọc `DeviceManager` của SmartWearKit. Lớp ObjC++ `SmartWear.mm` gọi vào
/// đây và chuyển sự kiện ra JS qua `emit`. Mọi việc chạy trên MainActor (SDK là `@MainActor`).
/// Cùng hình dạng dữ liệu với `SmartWearModule.kt` Android (xem `src/types.ts`).
@objc(SmartWearImpl)
public final class SmartWearImpl: NSObject {
    public typealias Resolve = (Any?) -> Void
    public typealias Reject = (String, String) -> Void

    /// (tên sự kiện, dữ liệu): `onDevicesChanged`, `onDiscovered`, `onReading`, `onFindPhone`, `onSyncProgress`.
    @objc public var emit: ((String, [String: Any]) -> Void)?

    @MainActor private static var shared: DeviceManager?
    @MainActor private var manager: DeviceManager {
        if let m = Self.shared { return m }
        // Khôi phục CoreBluetooth: iOS mở lại app ở nền khi thiết bị đang chờ nối xuất hiện (cần `bluetooth-central`).
        BleCentral.restoreIdentifier = "com.smartwear.rn.central"
        let m = DeviceManager(registry: DeviceRegistry(drivers: [QRingDriver(), GloryFitDriver(), VeepooDriver(), StandardDriver()]))
        Self.shared = m
        return m
    }

    @MainActor private var ticker: Task<Void, Never>?
    @MainActor private var lastDevices: NSArray?
    @MainActor private var lastDiscovered: NSArray?
    @MainActor private var measureTasks: [String: Task<Void, Never>] = [:]
    @MainActor private var watched: Set<UUID> = []
    /// Mốc thời gian số đo đã gửi JS theo (thiết bị, capability), để gửi số đo thiết bị tự đẩy đúng một lần.
    @MainActor private var sentReadings: [String: Date] = [:]
    @MainActor private var lastScanState: NSDictionary?
    /// Luồng nhịp tim liên tục đang giữ (id thiết bị → task), xem `streamHeartRate`.
    @MainActor private var heartRateTasks: [String: Task<Void, Never>] = [:]

    private func main(_ work: @escaping @MainActor () async -> Void) { Task { @MainActor in await work() } }

    // MARK: Vòng đời, quét

    @objc public func start() {
        main { [self] in
            let m = manager
            m.start()
            guard ticker == nil else { return }
            ticker = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    self?.publish()
                    self?.publishPushedReadings()
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }
    }

    @objc public func invalidate() {
        main { [self] in
            ticker?.cancel()
            ticker = nil
            measureTasks.values.forEach { $0.cancel() }
            measureTasks = [:]
            heartRateTasks.values.forEach { $0.cancel() }
            heartRateTasks = [:]
        }
    }

    @objc public func startScan(_ seconds: Double) { main { [self] in manager.startScan(duration: seconds > 0 ? seconds : nil) } }
    @objc public func stopScan() { main { [self] in manager.stopScan() } }

    @objc public func getDiscovered(_ resolve: @escaping Resolve, reject: @escaping Reject) {
        main { [self] in resolve(discovered()) }
    }

    @objc public func getDevices(_ resolve: @escaping Resolve, reject: @escaping Reject) {
        main { [self] in resolve(devices()) }
    }

    // MARK: Kết nối

    @objc public func connect(_ id: String, keep: Bool, resolve: @escaping Resolve, reject: @escaping Reject) {
        main { [self] in
            guard let uuid = UUID(uuidString: id) else { return reject("bad_id", "Id không hợp lệ: \(id)") }
            let result = await manager.connect([uuid], keep: keep)
            if let error = result[uuid] ?? nil { reject("connect_failed", error.localizedDescription) } else { resolve(nil) }
        }
    }

    @objc public func disconnect(_ id: String) { main { [self] in device(id).map(manager.disconnect) } }
    @objc public func forget(_ id: String) { main { [self] in device(id).map(manager.remove) } }
    @objc public func setKeepConnected(_ id: String, keep: Bool) {
        main { [self] in if let d = device(id) { manager.setKeepConnected(keep, for: d) } }
    }
    @objc public func submitPairingCode(_ id: String, code: String) {
        main { [self] in (device(id) as? GloryFitDevice)?.submitPairingCode(code) }
    }

    /// Số đo thiết bị tự đẩy (HR 24h, đo trên đồng hồ…) không đi qua `measure`: gửi `onReading` khi `latest` đổi.
    @MainActor private func publishPushedReadings() {
        for d in manager.devices {
            for (cap, r) in d.latest {
                let key = "\(d.id.uuidString)/\(cap.rawValue)"
                if sentReadings[key] == r.timestamp { continue }
                sentReadings[key] = r.timestamp
                if d.measuring.contains(cap) { continue }  // đang đo bằng measure(): luồng đo đã gửi
                emit?("onReading", Self.reading(d.id, r))
            }
        }
    }

    // MARK: Đo, lịch sử

    @objc public func measure(_ id: String, capability: String) {
        main { [self] in
            guard let d = device(id), let cap = Capability(rawValue: capability) else { return }
            let key = "\(id)/\(capability)"
            measureTasks[key]?.cancel()
            measureTasks[key] = d.startMeasuring(cap) { [weak self] r in self?.emit?("onReading", Self.reading(d.id, r)) }
        }
    }

    @objc public func stopMeasure(_ id: String, capability: String) {
        main { [self] in
            measureTasks.removeValue(forKey: "\(id)/\(capability)")?.cancel()
            if let d = device(id), let cap = Capability(rawValue: capability) { d.stopMeasuring(cap) }
        }
    }

    @objc public func syncHistory(_ id: String, days: Double, resolve: @escaping Resolve, reject: @escaping Reject) {
        main { [self] in
            guard let d = device(id) else { return reject("not_found", "Không có thiết bị \(id)") }
            let progress = Task { @MainActor [weak self] in
                var last: SyncProgress?
                while !Task.isCancelled {
                    if let p = d.syncProgress, p != last {
                        last = p
                        self?.emit?("onSyncProgress", ["deviceId": id, "step": p.step, "done": p.done, "total": p.total])
                    }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
            defer { progress.cancel() }
            guard let h = await manager.syncHistory(d, days: Int(days))?.value else {
                return reject("sync_failed", d.lastError ?? "Đồng bộ lỗi")
            }
            resolve(Self.history(h))
        }
    }

    // MARK: Cài đặt

    @objc public func getControls(_ id: String, resolve: @escaping Resolve, reject: @escaping Reject) {
        main { [self] in resolve((device(id)?.controls ?? []).map(Self.control)) }
    }

    @objc public func setControl(_ id: String, controlId: String, value: NSDictionary, resolve: @escaping Resolve, reject: @escaping Reject) {
        main { [self] in
            guard let c = device(id) as? ConfigurableDevice else { return reject("unsupported", "Thiết bị không có cài đặt") }
            let raw = value["value"]
            let v: ControlValue
            if let n = raw as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() {
                v = .bool(n.boolValue)
            } else if let n = raw as? NSNumber {
                v = .number(n.intValue)
            } else if let r = raw as? NSDictionary, let f = r["from"] as? NSNumber, let t = r["to"] as? NSNumber {
                v = .timeRange(from: f.intValue, to: t.intValue)
            } else {
                return reject("bad_value", "Giá trị không hợp lệ")
            }
            do {
                try await c.setControl(controlId, v)
                resolve(nil)
            } catch {
                reject("control_failed", error.localizedDescription)
            }
        }
    }

    @objc public func runAction(_ id: String, actionId: String, resolve: @escaping Resolve, reject: @escaping Reject) {
        main { [self] in
            guard let c = device(id) as? ConfigurableDevice else { return reject("unsupported", "Thiết bị không có cài đặt") }
            do {
                try await c.runAction(actionId)
                resolve(nil)
            } catch {
                reject("action_failed", error.localizedDescription)
            }
        }
    }

    // MARK: Thời tiết, gọi điện, danh bạ

    @objc public func setWeather(_ id: String, forecast: NSDictionary, resolve: @escaping Resolve, reject: @escaping Reject) {
        main { [self] in
            guard let w = device(id) as? WeatherDisplay else { return reject("unsupported", "Thiết bị không hiển thị thời tiết") }
            let days = (forecast["days"] as? [NSDictionary] ?? []).map { d in
                WeatherDay(
                    condition: Self.condition(d["condition"] as? String),
                    highC: (d["highC"] as? NSNumber)?.intValue ?? 0, lowC: (d["lowC"] as? NSNumber)?.intValue ?? 0
                )
            }
            let f = WeatherForecast(
                city: forecast["city"] as? String ?? "", currentC: (forecast["currentC"] as? NSNumber)?.intValue ?? 0,
                humidity: (forecast["humidity"] as? NSNumber)?.intValue ?? 0, uvIndex: (forecast["uvIndex"] as? NSNumber)?.intValue ?? 0,
                days: days
            )
            guard !days.isEmpty else { return reject("bad_value", "Thiếu dự báo") }
            do {
                try await w.setWeather(f)
                resolve(nil)
            } catch {
                reject("weather_failed", error.localizedDescription)
            }
        }
    }

    @objc public func syncContacts(_ id: String, contacts: NSArray, resolve: @escaping Resolve, reject: @escaping Reject) {
        main { [self] in
            guard let g = device(id) as? GloryFitDevice else { return reject("unsupported", "Thiết bị không có danh bạ") }
            let list = (contacts as? [NSDictionary] ?? []).map {
                UteContacts.Contact(name: $0["name"] as? String ?? "", phone: $0["phone"] as? String ?? "")
            }
            do {
                resolve(try await g.syncContacts(list))
            } catch {
                reject("contacts_failed", error.localizedDescription)
            }
        }
    }

    @objc public func getCallBluetoothState(_ id: String, resolve: @escaping Resolve, reject: @escaping Reject) {
        main { [self] in
            guard let g = device(id) as? GloryFitDevice else { return reject("unsupported", "Thiết bị không gọi điện được") }
            do {
                let s = try await g.callBluetoothState()
                resolve(["name": s.name, "address": s.address, "enabled": s.enabled, "paired": s.paired, "connected": s.connected])
            } catch {
                reject("call_failed", error.localizedDescription)
            }
        }
    }

    @objc public func pairCallBluetooth(_ id: String, resolve: @escaping Resolve, reject: @escaping Reject) {
        main { [self] in
            let name = (device(id) as? GloryFitDevice)?.name ?? "đồng hồ"
            reject("ios_settings", "iOS không cho app tự ghép Bluetooth âm thanh: mở Cài đặt → Bluetooth, chọn \"\(name)\" → Ghép đôi")
        }
    }

    @objc public func setPhoneRinging(_ id: String, ringing: Bool, resolve: @escaping Resolve, reject: @escaping Reject) {
        main { [self] in
            guard let d = device(id) else { return reject("not_found", "Không có thiết bị \(id)") }
            await d.setPhoneRinging(ringing)
            resolve(nil)
        }
    }

    // MARK: Cổng chung invoke (tính năng điện thoại ↔ thiết bị, xem `index.ts`)

    @MainActor private func event(_ type: String, _ deviceId: String, _ body: [String: Any] = [:]) {
        var e = body
        e["type"] = type
        e["deviceId"] = deviceId
        emit?("onEvent", e)
    }

    /// Luồng nhịp tim liên tục như `HeartRateStreams` Android: chờ kết nối, mở `heartRateStream`, gửi sự kiện `heartRate` (tối đa
    /// một mẫu mỗi 0,75 s, RR của mẫu bị gộp vẫn giữ). Mất kết nối ⇒ một mẫu `connected: false`, nối lại thì mở lại; luồng lỗi ⇒
    /// mẫu có `error`, thử lại sau 3 s. Chạy tới khi `stopHeartRateStream`.
    @MainActor private func streamHeartRate(_ d: WearableDevice) async {
        let id = d.id.uuidString
        func send(_ x: HeartRateSample?, connected: Bool, error: String? = nil) {
            event("heartRate", id, [
                "bpm": x?.bpm ?? NSNull(), "rrMs": x?.rrMs ?? [], "contact": x?.contact ?? NSNull(),
                "t": (x?.timestamp ?? Date()).timeIntervalSince1970 * 1000, "connected": connected, "error": error ?? NSNull(),
            ])
        }
        func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
        while !Task.isCancelled {
            while d.state != .connected {
                await sleep(0.5)
                if Task.isCancelled { return }
            }
            guard d.supportsHeartRateStream else { return send(nil, connected: true, error: "unsupported") }
            let failure = Box<String?>(nil)
            let done = Box(false)
            let stream = d.heartRateStream()
            let consumer = Task { @MainActor in
                var lastEmit = Date.distantPast
                var rr: [Int] = []
                do {
                    for try await x in stream {
                        rr += x.rrMs
                        if x.bpm != nil, x.timestamp.timeIntervalSince(lastEmit) < 0.75 { continue }
                        lastEmit = x.timestamp
                        var y = x
                        y.rrMs = rr
                        rr = []
                        send(y, connected: true)
                    }
                } catch is CancellationError {
                } catch {
                    failure.value = error.localizedDescription
                }
                done.value = true
            }
            while !done.value {
                if Task.isCancelled || d.state != .connected { consumer.cancel() }
                await sleep(0.25)
            }
            if Task.isCancelled { return }
            if d.state != .connected {
                send(nil, connected: false)
            } else if let f = failure.value {
                SmartWearLog.w("[\(d.name)] luồng nhịp tim lỗi: \(f)")
                send(nil, connected: true, error: f)
                await sleep(3)
            } else {
                await sleep(1)
            }
        }
    }

    /// Kết quả luôn là `{ value }` (TurboModule chỉ trả object).
    @objc public func invoke(_ method: String, deviceId: String, args: NSDictionary, resolve: @escaping Resolve, reject: @escaping Reject) {
        main { [self] in
            do {
                resolve(["value": try await run(method, deviceId, args) ?? NSNull()])
            } catch let e as InvokeError {
                reject(e.code, e.message)
            } catch {
                reject("failed", error.localizedDescription)
            }
        }
    }

    private struct InvokeError: Error {
        let code: String
        let message: String
        static func unsupported(_ what: String) -> InvokeError { InvokeError(code: "unsupported", message: "\(what): iOS không hỗ trợ") }
    }

    @MainActor private func run(_ method: String, _ id: String, _ a: NSDictionary) async throws -> Any? {
        func int(_ k: String) -> Int? { (a[k] as? NSNumber)?.intValue }
        func dbl(_ k: String) -> Double? { (a[k] as? NSNumber)?.doubleValue }
        func str(_ k: String) -> String? { a[k] as? String }
        func bool(_ k: String) -> Bool { (a[k] as? NSNumber)?.boolValue ?? false }

        // Lệnh cấp module.
        switch method {
        case "getScanState": return scanState()
        case "getPhoneLinkConfig":
            return ["apps": [String](), "sms": false, "calls": false, "music": false, "smsReply": false]
        case "setPhoneLinkConfig", "setForegroundService", "openNotificationAccessSettings": return nil  // iOS: hệ thống lo
        case "hasNotificationAccess": return false
        default: break
        }

        guard let d = device(id) else { throw InvokeError(code: "not_found", message: "Không có thiết bị \(id)") }
        switch method {
        case "refreshBattery":
            try await d.refreshBattery()
            return d.battery
        case "getHistory": return d.history.map(Self.history)

        case "getNotificationApps", "sendNotification", "sendSms", "notifyIncomingCall", "notifyCallEnded",
             "getSmsReply", "setSmsReply", "sendSmsReplyResult":
            throw InvokeError.unsupported("\(method) (iPhone gửi thông báo/cuộc gọi qua ANCS)")

        case "setMusicState":
            await d.setMusicState(MusicState(
                playing: bool("playing"), title: str("title"), artist: str("artist"), volumePercent: int("volumePercent"),
                durationSec: int("durationSec"), positionSec: int("positionSec")
            ))
            return nil
        case "setMusicVolume":
            await d.setMusicVolume(int("percent") ?? 0)
            return nil

        case "clearContacts":
            try await d.clearContacts()
            return nil
        case "setCallBluetooth":
            try await d.setCallAudio(bool("on"))
            return nil

        case "getWatchFaceInfo":
            let i = try await d.watchFaceInfo()
            return [
                "width": i.width, "height": i.height, "round": i.round, "maxBytes": i.maxBytes, "currentId": i.currentId,
                "slotCount": i.slotCount, "customActive": i.customActive,
            ]
        case "installWatchFace":
            let data: Data?
            if let b = str("base64") { data = Data(base64Encoded: b) } else if let p = str("path") {
                data = try Data(contentsOf: URL(fileURLWithPath: p.replacingOccurrences(of: "file://", with: "")))
            } else { data = nil }
            guard let data else { throw InvokeError(code: "bad_value", message: "Thiếu path hoặc base64") }
            try await d.installWatchFace(data) { [weak self] f in self?.event("transferProgress", id, ["what": "watchFace", "fraction": f]) }
            return nil
        case "getWatchFaceSlots": return try await d.watchFaceSlots().map { ["index": $0.index, "faceId": $0.faceId] }
        case "deleteWatchFaceSlot":
            try await d.deleteWatchFaceSlot(int("index") ?? -1)
            return nil
        case "setWatchFaceImage": throw InvokeError.unsupported("Dựng mặt đồng hồ từ ảnh")

        case "getSportTypes":
            return try await d.sportTypes().map { ["type": $0.type, "name": $0.name, "shown": $0.shown, "position": $0.position] }
        case "setSportList":
            let list = (a["sports"] as? [NSDictionary] ?? []).map {
                SportType(
                    type: ($0["type"] as? NSNumber)?.intValue ?? 0, name: $0["name"] as? String ?? "",
                    shown: ($0["shown"] as? NSNumber)?.boolValue ?? false, position: ($0["position"] as? NSNumber)?.intValue ?? 0
                )
            }
            try await d.setSportList(list)
            return nil
        case "startWorkout":
            try await d.startWorkout(int("sportType") ?? 0)
            return nil
        case "pauseWorkout": try await d.pauseWorkout(); return nil
        case "resumeWorkout": try await d.resumeWorkout(); return nil
        case "stopWorkout": try await d.stopWorkout(); return nil
        case "sendLocation":
            guard let lat = dbl("latitude"), let lon = dbl("longitude") else {
                throw InvokeError(code: "bad_value", message: "Thiếu latitude/longitude")
            }
            try await d.sendLocation(latitude: lat, longitude: lon, altitude: dbl("altitude"), speed: dbl("speed"), accuracy: dbl("accuracy"))
            return nil

        case "setRemoteCamera":
            await d.setRemoteCamera(bool("open"))
            return nil

        case "getAlarms": return try await d.alarms().map(Self.alarm)
        case "setAlarm":
            // args = chính đối tượng báo thức {id?, hour, minute, repeatDays?, enabled?, label?} (nhận cả {alarm: {...}});
            // id < 0 / thiếu = thêm mới.
            let o = (a["alarm"] as? NSDictionary) ?? a
            func oi(_ k: String) -> Int? { (o[k] as? NSNumber)?.intValue }
            guard let hour = oi("hour"), let minute = oi("minute") else {
                throw InvokeError(code: "bad_value", message: "Thiếu hour/minute")
            }
            let label = (o["label"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            try await d.setAlarm(Alarm(
                id: oi("id") ?? -1, hour: hour, minute: minute, repeatDays: oi("repeatDays") ?? 0,
                enabled: (o["enabled"] as? NSNumber)?.boolValue ?? true, label: label
            ))
            return nil
        case "deleteAlarm":
            // `index.ts` gửi `{ id }`; nhận cả `{ alarmId }`.
            guard let alarmId = int("id") ?? int("alarmId") else { throw InvokeError(code: "bad_value", message: "Thiếu id") }
            try await d.deleteAlarm(alarmId)
            return nil

        case "checkFirmware", "updateFirmware", "cancelFirmwareUpdate": throw InvokeError.unsupported("Nạp firmware")
        case "startHeartRateStream":
            if d.state == .connected, !d.supportsHeartRateStream {
                throw InvokeError(code: "unsupported", message: "Thiết bị không hỗ trợ nhịp tim liên tục")
            }
            let key = d.id.uuidString
            heartRateTasks[key]?.cancel()
            heartRateTasks[key] = Task { @MainActor [weak self] in await self?.streamHeartRate(d) }
            return nil
        case "stopHeartRateStream":
            heartRateTasks.removeValue(forKey: d.id.uuidString)?.cancel()
            return nil

        default: throw InvokeError(code: "unknown_method", message: "Không có lệnh \(method)")
        }
    }

    // MARK: Sự kiện

    @MainActor private func publish() {
        let m = manager
        for d in m.devices where watched.insert(d.id).inserted {
            let id = d.id.uuidString
            d.onFindPhone = { [weak self] on in self?.emit?("onFindPhone", ["deviceId": id, "ringing": on]) }
            // RN giữ các callback này (mỗi callback một chỗ): app nghe qua `onEvent`.
            d.onRejectCall = { [weak self] in self?.event("rejectCall", id) }
            d.onMusicCommand = { [weak self] c in self?.event("musicCommand", id, ["command": c.rawValue]) }
            d.onRemoteCamera = { [weak self] e in
                let name: String
                switch e {
                case .shutter: name = "SHUTTER"
                case .opened: name = "OPENED"
                case .closed: name = "CLOSED"
                }
                self?.event("remoteCamera", id, ["event": name])
            }
            d.onDeviceEvent = { [weak self] e in self?.event("deviceEvent", id, ["event": e.rawValue]) }
            d.onLocationRequest = { [weak self] r in
                self?.event("locationRequest", id, ["start": r.start, "sportType": Self.opt(r.sportType)])
            }
            d.onWorkoutEvent = { [weak self] e in
                switch e {
                case .state(let st, let sport, let byDevice):
                    self?.event("workout", id, ["kind": "state", "state": st.rawValue, "sportType": sport, "byDevice": byDevice])
                case .realtime(let r):
                    self?.event("workout", id, [
                        "kind": "realtime", "sportType": r.sportType, "heartRate": Self.opt(r.heartRate), "calories": r.calories,
                        "paceSecondsPerKm": r.paceSecondsPerKm, "steps": r.steps, "count": r.count, "distanceMeters": r.distanceMeters,
                    ])
                }
            }
        }
        let scan = scanState() as NSDictionary
        if scan != lastScanState {
            lastScanState = scan
            emit?("onEvent", ["type": "scanState"].merging(scan as! [String: Any]) { a, _ in a })
        }
        let devs = devices() as NSArray
        if devs != lastDevices {
            lastDevices = devs
            emit?("onDevicesChanged", ["devices": devs])
        }
        let disc = discovered() as NSArray
        if disc != lastDiscovered {
            lastDiscovered = disc
            emit?("onDiscovered", ["devices": disc])
        }
    }

    // MARK: Chuyển dữ liệu

    @MainActor private func device(_ id: String) -> WearableDevice? {
        UUID(uuidString: id).flatMap { manager.device($0) }
    }

    @MainActor private func discovered() -> [[String: Any]] {
        manager.discoveredSorted.map { d in
            [
                "id": d.id.uuidString, "name": d.scanned.name ?? NSNull(), "driver": d.driverId, "model": d.match.model ?? NSNull(),
                "rssi": d.scanned.rssi, "heartRateService": d.scanned.advertises(StandardGatt.heartRateService),
            ]
        }
    }

    @MainActor private func devices() -> [[String: Any]] {
        let m = manager
        return m.devices.map { d in
            let g = d as? GloryFitDevice
            var prompt: Any = NSNull()
            switch g?.pairingPrompt {
            case .enterCode(let digits, let message)?: prompt = ["type": "code", "digits": digits, "message": message]
            case .confirmOnDevice(let message)?: prompt = ["type": "confirm", "message": message]
            case nil: break
            }
            return [
                "id": d.id.uuidString, "name": d.name, "driver": d.driverId, "model": d.info.model ?? NSNull(),
                "state": d.state.rawValue, "kept": m.isKept(d.id),
                "battery": d.battery ?? NSNull(), "rssi": d.stats.rssi ?? NSNull(), "firmware": d.info.firmware ?? NSNull(),
                "capabilities": d.capabilities.map(\.rawValue).sorted(), "measurable": d.measurableCapabilities.map(\.rawValue),
                "supportsHistory": d.supportsHistory,
                "supportsWeather": (d as? WeatherDisplay)?.supportsWeather ?? false,
                "supportsContacts": g?.supportsContacts ?? false, "supportsCallBluetooth": g?.supportsCallBluetooth ?? false,
                "controlCount": d.controls.count, "lastError": d.lastError ?? NSNull(), "pairingPrompt": prompt,
                "hardware": d.info.hardware ?? NSNull(), "charging": d.charging ?? NSNull(),
                "measuring": d.measuring.map(\.rawValue).sorted(), "features": Self.features(d),
            ]
        }
    }

    private static func ms(_ d: Date) -> Double { (d.timeIntervalSince1970 * 1000).rounded() }
    private static func opt(_ v: Int?) -> Any { v ?? NSNull() }

    private static func reading(_ id: UUID, _ r: Reading) -> [String: Any] {
        var m: [String: Any] = [
            "deviceId": id.uuidString, "capability": r.capability.rawValue, "status": r.status.rawValue,
            "value": r.value ?? NSNull(), "systolic": opt(r.systolic), "diastolic": opt(r.diastolic),
            "note": r.note ?? NSNull(), "timestamp": ms(r.timestamp),
        ]
        // Giá trị phụ (mỡ máu, thành phần cơ thể…): chỉ gửi khi có, như Android.
        if !r.extra.isEmpty { m["extra"] = r.extra }
        return m
    }

    private static func alarm(_ a: Alarm) -> [String: Any] {
        ["id": a.id, "hour": a.hour, "minute": a.minute, "repeatDays": a.repeatDays, "enabled": a.enabled, "label": a.label ?? NSNull()]
    }

    private static func history(_ h: DeviceHistory) -> [String: Any] {
        var series: [String: Any] = [:]
        for (cap, pts) in h.series {
            series[cap.rawValue] = pts.map { p -> [String: Any] in
                // Giá trị phụ: huyết áp "diastolic", SpO2 "min", bước "calories"/"distance", mỡ máu, thành phần cơ thể.
                var m: [String: Any] = ["t": ms(p.timestamp), "v": p.value]
                if !p.extra.isEmpty { m["extra"] = p.extra }
                return m
            }
        }
        return [
            "days": h.days, "syncedAt": ms(h.syncedAt),
            "today": h.today.map {
                ["steps": $0.steps, "calories": $0.calories / 1000, "distanceMeters": $0.distanceMeters, "activeMinutes": opt($0.activeMinutes)]
            } ?? NSNull(),
            "series": series,
            "sleep": h.sleep.map { s in
                [
                    "start": ms(s.start), "end": ms(s.end), "nap": s.nap,
                    "segments": s.segments.map { ["start": ms($0.start), "minutes": $0.minutes, "stage": $0.stage.rawValue] },
                ] as [String: Any]
            },
            "workouts": h.workouts.map { w in
                [
                    "type": w.type, "name": w.name, "start": ms(w.start), "end": ms(w.end), "activeSeconds": w.activeSeconds,
                    "steps": opt(w.steps), "calories": opt(w.calories), "distanceMeters": opt(w.distanceMeters),
                    "avgHeartRate": opt(w.avgHeartRate), "maxHeartRate": opt(w.maxHeartRate),
                    "minHeartRate": opt(w.minHeartRate), "paceSecondsPerKm": opt(w.paceSecondsPerKm),
                ] as [String: Any]
            },
            "errors": h.errors,
        ]
    }

    /// Tính năng điện thoại ↔ thiết bị (cùng khoá với Android, `DeviceFeatures` trong `types.ts`).
    @MainActor private static func features(_ d: WearableDevice) -> [String: Any] {
        [
            "notifications": false,  // iOS: thiết bị đọc thông báo qua ANCS, app không gửi
            "ancsAuthorized": d.ancsAuthorized ?? NSNull(),
            "incomingCall": false, "rejectCall": d.supportsRejectCall,
            "musicControl": d.supportsMusicControl, "trackInfo": d.supportsTrackInfo,
            "smsReply": false, "maxContacts": d.maxContacts, "clearContacts": d.supportsClearContacts,
            "callAudio": d.supportsCallAudio, "watchFace": d.supportsWatchFace, "watchFaceSlots": d.supportsWatchFaceSlots,
            "customWatchFace": false, "workoutControl": d.supportsWorkoutControl, "sportList": d.supportsSportList,
            "phoneLocation": d.supportsPhoneLocation, "remoteCamera": d.supportsRemoteCamera, "firmwareUpdate": false,
            "alarms": d.supportsAlarms, "maxAlarms": d.maxAlarms, "heartRateStream": d.supportsHeartRateStream,
        ]
    }

    @MainActor private func scanState() -> [String: Any] {
        let bt: String
        switch manager.bluetoothState {
        case .poweredOn: bt = "on"
        case .poweredOff: bt = "off"
        case .unauthorized: bt = "unauthorized"
        default: bt = "unknown"
        }
        return ["scanning": manager.isScanning, "error": NSNull(), "bluetooth": bt]
    }

    private static func control(_ c: DeviceControl) -> [String: Any] {
        let kind: String
        switch c.kind {
        case .action: kind = "action"
        case .toggle: kind = "toggle"
        case .number: kind = "number"
        case .timeRange: kind = "timeRange"
        case .choice: kind = "choice"
        }
        let value: Any
        switch c.value {
        case .bool(let on)?: value = on
        case .number(let n)?: value = n
        case .timeRange(let f, let t)?: value = ["from": f, "to": t]
        case nil: value = NSNull()
        }
        return [
            "id": c.id, "group": c.group, "title": c.title, "kind": kind, "value": value, "detail": c.detail ?? NSNull(),
            "min": c.min, "max": c.max, "step": c.step, "unit": c.unit, "options": c.options, "enabled": c.enabled,
            "confirm": c.confirm ?? NSNull(),
        ]
    }

    private static func condition(_ s: String?) -> WeatherCondition {
        let names: [String: WeatherCondition] = [
            "SUNNY": .sunny, "CLOUDY": .cloudy, "OVERCAST": .overcast, "SHOWER": .shower, "THUNDERSTORM": .thunderstorm,
            "SLEET": .sleet, "LIGHT_RAIN": .lightRain, "HEAVY_RAIN": .heavyRain, "SNOW": .snow, "DUST": .dust, "FOG": .fog, "WIND": .wind,
        ]
        return s.flatMap { names[$0] } ?? .cloudy
    }
}
