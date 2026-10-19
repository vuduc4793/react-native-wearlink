import SmartWearCore
import SmartWearGloryFit
import SmartWearQRing
import SwiftUI
import UIKit

/// Chế độ tự kiểm thử qua tham số khởi chạy (giống `--es address … --es measure …` của sample Android):
///
///     xcrun devicectl device process launch --device <id> --console --terminate-existing com.smartwear.lab \
///         -autoConnect 32:35:45:37:4E:00,COROS -measure HEART_RATE -autoExit YES
///
/// - `-autoConnect`: danh sách cách nhau bằng dấu phẩy; mỗi mục khớp MAC (từ quảng bá), UUID CoreBluetooth
///   hoặc một phần tên. Chỉ thiết bị có driver nhận ra mới được xét.
/// - `-measure`: capability (vd HEART_RATE, SPO2), có thể nhiều, cách nhau bằng dấu phẩy.
/// - `-measureTimeout` (giây, mặc định 60), `-scanTimeout` (mặc định 30).
/// - `-screenshot YES`: lưu ảnh màn hình vào Documents (home.png, detail.png).
/// - `-autoExit YES`: ngắt kết nối và thoát khi xong (để `--console` trả về).
/// - `-keep YES`: giữ kết nối các thiết bị đã nối (tự nối lại, cả lần mở app sau). Mặc định KHÔNG giữ, để
///   iPhone không tranh thiết bị với điện thoại khác sau khi kiểm thử.
/// - `-verboseLog YES`: in cả log SDK và từng gói byte.
/// Mọi dòng in bằng `print()` với tiền tố `[AUTO]`.
@MainActor
enum AutoTest {
    static func runIfRequested(_ app: AppState) {
        let d = UserDefaults.standard
        guard let raw = d.string(forKey: "autoConnect"), !raw.isEmpty else { return }
        setvbuf(stdout, nil, _IOLBF, 0)
        if d.bool(forKey: "verboseLog") {
            SmartWearLog.echoToStdout = true
            SmartWearLog.verbose = true
        }
        let targets = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let measures = (d.string(forKey: "measure") ?? "").split(separator: ",").compactMap { Capability(name: String($0)) }
        let config = Config(
            targets: targets, measures: measures,
            measureTimeout: d.double(forKey: "measureTimeout").nonZero ?? 60,
            scanTimeout: d.double(forKey: "scanTimeout").nonZero ?? 30,
            screenshot: d.bool(forKey: "screenshot"),
            exit: d.bool(forKey: "autoExit"),
            keep: d.bool(forKey: "keep"),
            syncDays: d.integer(forKey: "sync"),
            e2e: d.bool(forKey: "e2e"),
            controls: (d.string(forKey: "control") ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty },
            raw: (d.string(forKey: "raw") ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty },
            weather: d.bool(forKey: "weather")
        )
        Task { await run(app, config) }
    }

    struct Config {
        var targets: [String]
        var measures: [Capability]
        var measureTimeout: TimeInterval
        var scanTimeout: TimeInterval
        var screenshot: Bool
        var exit: Bool
        var keep: Bool
        /// `-sync N`: đồng bộ lịch sử N ngày trên mọi thiết bị hỗ trợ, in tóm tắt (0 = không đồng bộ).
        var syncDays: Int
        /// `-e2e YES`: sau kết nối (+ đồng bộ), kiểm thử ngắt → nối lại → quên → iOS đã nhả, in bảng ĐẠT/LỖI.
        var e2e: Bool
        /// `-control id=giá trị,…`: đổi cài đặt / chạy hành động trên mọi thiết bị đã kết nối, in danh sách cài đặt.
        /// Giá trị: `true`/`false`, số, `HH:MM-HH:MM`; hành động chỉ cần id (vd `find.start`). Tiền tố `Tên@` chỉ áp
        /// cho thiết bị có tên chứa "Tên" (vd `R09@goal.steps=5000`).
        var controls: [String]
        /// `-raw "Tên@[5:]HEX,…"`: gửi gói thô cho đồng hồ GloryFit (tiền tố `5:` = kênh 34F1), in mọi phản hồi 4 s.
        var raw: [String]
        /// `-weather YES`: lấy dự báo và gửi lên mọi thiết bị hiển thị được thời tiết.
        var weather: Bool
    }

    static func out(_ s: String) { print("[AUTO] \(s)") }

    static func describe(_ v: ControlValue?) -> String {
        switch v {
        case .bool(let on): on ? "bật" : "tắt"
        case .number(let n): "\(n)"
        case .timeRange(let f, let t): "\(formatMinuteOfDay(f))-\(formatMinuteOfDay(t))"
        case nil: "·"
        }
    }

    static func parseValue(_ s: String) -> ControlValue? {
        if s == "true" { return .bool(true) }
        if s == "false" { return .bool(false) }
        if let n = Int(s) { return .number(n) }
        let r = s.split(separator: "-").map { $0.split(separator: ":").compactMap { Int($0) } }
        guard r.count == 2, r.allSatisfy({ $0.count == 2 }) else { return nil }
        return .timeRange(from: r[0][0] * 60 + r[0][1], to: r[1][0] * 60 + r[1][1])
    }

    static func run(_ app: AppState, _ c: Config) async {
        let m = app.manager
        out("SmartWear Lab \(SmartWear.version) tự kiểm thử: targets=\(c.targets) measure=\(c.measures.map(\.rawValue))")
        // Mỗi lần kết nối lỗi (bấm hoặc tự nối lại): in lý do đã giải thích + việc nên làm.
        m.onConnectFailed = { d, f, diag in
            let code = f.code.map { ", \($0.label)" } ?? ""
            out("\(d.name): CHẨN ĐOÁN (\(f.interactive ? "lần kết nối" : "tự nối lại"), pha \(f.phase.rawValue)\(code)): \(diag.line)")
        }
        m.start()
        do {
            try await BleCentral.shared.waitUntilPoweredOn(timeout: 60)
        } catch {
            out("Bluetooth không sẵn sàng: \(error.localizedDescription). Nếu lần đầu chạy, bấm \"Cho phép\" trên iPhone.")
            return finish(c, code: 1)
        }
        out("Bluetooth: poweredOn, quét tối đa \(Int(c.scanTimeout)) s")
        m.startScan(duration: nil)

        var found: [String: DiscoveredDevice] = [:]
        let deadline = Date().addingTimeInterval(c.scanTimeout)
        while Date() < deadline, found.count < c.targets.count {
            for t in c.targets where found[t] == nil {
                if let hit = m.discoveredSorted.first(where: { matches(t, $0) && !found.values.map(\.id).contains($0.id) }) {
                    found[t] = hit
                    out("Thấy \"\(t)\": \(hit.displayName) driver=\(hit.driverId) kind=\(hit.match.kind.rawValue) id=\(hit.id.uuidString) mac=\(hit.match.mac ?? "-") rssi=\(hit.scanned.rssi) services=\(hit.scanned.serviceUuids.map(\.short))")
                }
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        m.stopScan()
        for t in c.targets where found[t] == nil { out("KHÔNG thấy \"\(t)\" sau \(Int(c.scanTimeout)) s") }
        let ids = c.targets.compactMap { found[$0]?.id }
        guard !ids.isEmpty else { return finish(c, code: 2) }

        out("Kết nối song song \(ids.count) thiết bị\(c.keep ? ", giữ kết nối" : "")…")
        let started = Date()
        let results = await m.connect(ids, keep: c.keep)
        for id in ids {
            guard let d = m.device(id) else { continue }
            if let error = results[id] ?? nil {
                out("\(d.name): LỖI kết nối: \(error.localizedDescription)")
                continue
            }
            out("\(d.name): đã kết nối + bắt tay (\(Int(Date().timeIntervalSince(started) * 1000)) ms kể từ lúc bắt đầu)")
            printDevice(d)
        }

        if c.screenshot {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            save("home")
        }

        for cap in c.measures {
            let targets = m.devicesSupporting(cap)
            for d in m.connectedDevices where !targets.contains(where: { $0 === d }) {
                out("\(d.name): không hỗ trợ đo \(cap.rawValue), bỏ qua")
            }
            guard !targets.isEmpty else { continue }
            out("Đo đồng loạt \(cap.rawValue) trên \(targets.map(\.name))")
            if c.screenshot, let first = targets.first { app.open(first) }
            let tasks = targets.map { d in
                d.startMeasuring(cap) { r in
                    var line = "\(d.name): \(cap.rawValue) \(r.status.rawValue)"
                    if let v = Format.value(r) { line += " \(v) \(r.unit)" }
                    if let s = r.signal, r.status == .measuring { line += " raw=\(Int(s))" }
                    if let e = r.errorCode { line += " err=\(e)" }
                    if let n = r.note { line += " (\(n))" }
                    out(line)
                }
            }
            let timeout = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(c.measureTimeout * 1_000_000_000))
                if !Task.isCancelled {
                    out("Hết \(Int(c.measureTimeout)) s, dừng đo \(cap.rawValue)")
                    tasks.forEach { $0.cancel() }
                    targets.forEach { $0.stopMeasuring(cap) }
                }
            }
            if c.screenshot {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                save("detail")
            }
            for t in tasks { await t.value }
            timeout.cancel()
            for d in targets {
                let r = d.latest[cap] ?? d.lastResult[cap]
                out("\(d.name): KẾT QUẢ \(cap.rawValue) = \(r.map { "\($0.status.rawValue) \(Format.value($0) ?? "") \($0.unit)" } ?? "không có")")
            }
            if c.screenshot { save("detail-done") }
        }

        if c.syncDays > 0 {
            for d in m.connectedDevices where d.supportsHistory {
                out("\(d.name): đồng bộ lịch sử \(c.syncDays) ngày…")
                let started = Date()
                guard let h = await m.syncHistory(d, days: c.syncDays)?.value else {
                    out("\(d.name): LỖI đồng bộ: \(d.lastError ?? "không rõ")")
                    continue
                }
                let secs = String(format: "%.1f", Date().timeIntervalSince(started))
                let series = h.series.map { "\($0.key.rawValue)=\($0.value.count)" }.sorted().joined(separator: " ")
                let today = h.today.map { "bước=\($0.steps) kcal=\($0.calories / 1000) m=\($0.distanceMeters)" } ?? "không có"
                let sleep = h.sleep.map { "\($0.asleepMinutes) phút" }.joined(separator: ", ")
                out("\(d.name): LỊCH SỬ (\(secs) s) hôm nay: \(today) · giấc ngủ: \(sleep.isEmpty ? "không có" : sleep) · chuỗi: \(series.isEmpty ? "không có" : series) · bài tập: \(h.workouts.count)")
                for w in h.workouts { out("\(d.name):   bài tập \(w.name) \(w.start) \(w.activeSeconds) s, \(w.distanceMeters ?? 0) m, \(w.calories ?? 0) kcal, HR tb \(w.avgHeartRate ?? 0)") }
                for e in h.errors { out("\(d.name):   bước lỗi: \(e)") }
            }
        }

        if !c.controls.isEmpty {
            for d in m.connectedDevices {
                guard let cd = d as? ConfigurableDevice else { continue }
                try? await Task.sleep(nanoseconds: 3_000_000_000) // QRing đọc cài đặt nền sau khi kết nối
                out("\(d.name): CÀI ĐẶT \(d.controls.count) mục: " + d.controls.map { "\($0.id)=\(describe($0.value))" }.joined(separator: " "))
                for full in c.controls {
                    // `Tên@id=giá trị`: chỉ áp cho thiết bị có tên chứa "Tên".
                    let at = full.split(separator: "@", maxSplits: 1).map(String.init)
                    if at.count == 2, !d.name.localizedCaseInsensitiveContains(at[0]) { continue }
                    let spec = at.last ?? full
                    let parts = spec.split(separator: "=", maxSplits: 1).map(String.init)
                    do {
                        if parts.count == 1 {
                            try await cd.runAction(parts[0])
                        } else if let v = parseValue(parts[1]) {
                            try await cd.setControl(parts[0], v)
                        }
                        out("\(d.name): \(spec) ✓")
                    } catch {
                        out("\(d.name): \(spec) LỖI: \(error.localizedDescription)")
                    }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }

        if c.weather {
            for d in m.connectedDevices {
                guard let w = d as? WeatherDisplay, w.supportsWeather else { continue }
                await app.weather.push(to: d, refresh: true)
                if let f = app.weather.forecast {
                    out("\(d.name): THỜI TIẾT \(f.city) \(f.currentC)°C ẩm \(f.humidity)% UV \(f.uvIndex) · " +
                        f.days.map { "\($0.condition)" + " \($0.lowC)–\($0.highC)" }.joined(separator: ", "))
                }
                out("\(d.name): \(app.weather.status[d.id] ?? "-")")
            }
        }

        for full in c.raw {
            let at = full.split(separator: "@", maxSplits: 1).map(String.init)
            var spec = at.last ?? full
            let ble5 = spec.hasPrefix("5:")
            if ble5 { spec.removeFirst(2) }
            let bytes = spec.split(separator: " ").compactMap { UInt8($0, radix: 16) }
            for d in m.connectedDevices {
                guard let g = d as? GloryFitDevice, at.count == 1 || d.name.localizedCaseInsensitiveContains(at[0]) else { continue }
                do {
                    let got = try await g.debugExchange(bytes, ble5: ble5)
                    out("\(d.name): RAW \(ble5 ? "34F1" : "33F1") \(spec) → \(got.isEmpty ? "không phản hồi" : got.map { $0.map { String(format: "%02X", $0) }.joined(separator: " ") }.joined(separator: " | "))")
                } catch {
                    out("\(d.name): RAW \(spec) LỖI: \(error.localizedDescription)")
                }
            }
        }

        if c.screenshot, c.measures.isEmpty, let first = m.connectedDevices.first {
            app.open(first)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            save("detail")
        }

        if c.e2e { await endToEnd(m, ids: ids, connectResults: results) }

        for d in m.devices {
            let s = d.stats
            out("\(d.name): stats rssi=\(s.rssi.map(String.init) ?? "-") packets=\(s.packetsReceived) pps=\(String(format: "%.2f", s.packetsPerSecond)) errors=\(s.errors) latency=\(s.lastLatencyMs.map { "\($0)ms" } ?? "-")")
        }
        finish(c, code: 0)
    }

    /// Kiểm thử đầu-cuối từng thiết bị: bắt tay đủ (firmware, pin, tính năng) → ngắt → nối lại (đo thời gian) →
    /// quên (bỏ khỏi app + bảo iOS nhả) → kiểm tra iOS không còn giữ. In một dòng `E2E` mỗi thiết bị + tổng kết.
    private static func endToEnd(_ m: DeviceManager, ids: [UUID], connectResults: [UUID: Error?]) async {
        var rows: [(name: String, ok: Bool, detail: String)] = []
        for id in ids {
            guard let d = m.device(id) else { continue }
            var steps: [String] = []
            var ok = true
            func check(_ cond: Bool, _ label: String) { steps.append("\(label) \(cond ? "✓" : "✗")"); if !cond { ok = false } }
            check((connectResults[id] ?? nil) == nil && d.isConnected, "kết nối")
            check(d.info.firmware != nil, "firmware")
            check(d.battery != nil, "pin")
            check(!d.measurableCapabilities.isEmpty, "tính năng")
            // Ngắt theo ý người dùng rồi nối lại (lần bấm).
            m.disconnect(d)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            check(d.state == .disconnected, "ngắt")
            let t0 = Date()
            let r = await m.connect([id], keep: false)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            check((r[id] ?? nil) == nil && d.isConnected && d.info.firmware != nil, "nối lại \(ms) ms")
            // Quên: bỏ khỏi app + nhả, rồi xem iOS còn giữ không.
            m.remove(d)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            let held = m.isHeldBySystem(id)
            check(!held, held ? "quên (iOS vẫn giữ: đã ghép đôi hệ thống → Cài đặt → Bluetooth → Quên)" : "quên + iOS đã nhả")
            out("E2E \(d.name): \(ok ? "ĐẠT" : "LỖI") — \(steps.joined(separator: " · "))")
            rows.append((d.name, ok, steps.joined(separator: " · ")))
        }
        out("E2E tổng: \(rows.filter(\.ok).count)/\(rows.count) đạt")
    }

    private static func printDevice(_ d: WearableDevice) {
        let i = d.info
        out("\(d.name):   driver=\(d.driverId) kind=\(d.kind.rawValue) mac=\(d.mac ?? "-")")
        out("\(d.name):   model=\(i.model ?? "-") hãng=\(i.manufacturer ?? "-") hw=\(i.hardware ?? "-") fw=\(i.firmware ?? "-") sw=\(i.software ?? "-")")
        out("\(d.name):   pin=\(d.battery.map { "\($0)%" } ?? "chưa đọc")\(d.charging == true ? " (đang sạc)" : "")")
        out("\(d.name):   capabilities=\(Capability.allCases.filter(d.capabilities.contains).map(\.rawValue))")
        out("\(d.name):   đo được=\(d.measurableCapabilities.map(\.rawValue))")
        for e in i.extra { out("\(d.name):   \(e.key) = \(e.value)") }
    }

    private static func matches(_ target: String, _ d: DiscoveredDevice) -> Bool {
        let t = target.lowercased()
        if let mac = d.match.mac?.lowercased(), mac == t { return true }
        if d.id.uuidString.lowercased() == t { return true }
        if let n = d.scanned.name?.lowercased(), n.contains(t) { return true }
        return false
    }

    private static func save(_ name: String) {
        if let url = ScreenCapture.save(name) { out("Ảnh màn hình: Documents/\(url.lastPathComponent)") }
    }

    private static func finish(_ c: Config, code: Int32) {
        out("DONE (code \(code))")
        guard c.exit else { return }
        Task { @MainActor in
            AppStateHolder.shared?.manager.disconnectAll()
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            exit(code)
        }
    }
}

/// Giữ tham chiếu AppState cho AutoTest.finish.
@MainActor
enum AppStateHolder {
    static weak var shared: AppState?
}

@MainActor
enum ScreenCapture {
    /// Chụp cửa sổ app vào Documents/<name>.png (kéo về bằng `devicectl device copy from`).
    static func save(_ name: String) -> URL? {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first else { return nil }
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let data = image.pngData() else { return nil }
        let url = dir.appendingPathComponent("\(name).png")
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}

private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}
