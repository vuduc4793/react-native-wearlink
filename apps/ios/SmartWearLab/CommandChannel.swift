import Foundation
import SmartWearCore
import SmartWearGloryFit

/// Kênh lệnh gỡ lỗi: app đang chạy đọc `Documents/cmd.txt` mỗi giây (đẩy vào bằng `devicectl device copy to`), chạy
/// từng dòng rồi ghi kết quả vào `Documents/cmd-out.txt` và console. Kiểm thử tính năng mà KHÔNG khởi động lại app
/// (khởi động lại làm rớt mọi kết nối). Lệnh (`Tên` = một phần tên thiết bị):
/// - `status`: trạng thái, pin, khả năng, số mục cài đặt của mọi thiết bị
/// - `measure Tên CAP [giây]`: đo trực tiếp (vd `measure Y25 HEART_RATE 60`)
/// - `sync Tên ngày`: đồng bộ lịch sử
/// - `control Tên@id=giá trị` / `control Tên@id` (hành động): như `-control` của AutoTest
/// - `controls Tên`: in mọi mục cài đặt
/// - `raw Tên@[5:]HEX`: gói thô GloryFit
/// - `weather Tên`: lấy và gửi thời tiết
/// - `report Tên day|week`: báo cáo sức khoẻ AI (đồng bộ nếu cũ → luật → LLM), in phát hiện, báo cáo và thời gian
@MainActor
enum CommandChannel {
    private static var docs: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    static func start(_ app: AppState) {
        Task { @MainActor in
            while true {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let url = docs.appendingPathComponent("cmd.txt")
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                try? FileManager.default.removeItem(at: url)
                for line in text.split(whereSeparator: \.isNewline).map(String.init) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    out("> \(line)")
                    await run(app, line)
                }
                out("— xong —")
            }
        }
    }

    static func out(_ s: String) {
        let line = "\(Date().formatted(date: .omitted, time: .standard)) \(s)"
        print("[CMD] \(line)")
        let url = docs.appendingPathComponent("cmd-out.txt")
        let data = Data((line + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: url)
        }
    }

    private static func find(_ app: AppState, _ name: String) -> WearableDevice? {
        app.manager.devices.first { $0.name.localizedCaseInsensitiveContains(name) }
    }

    private static func run(_ app: AppState, _ line: String) async {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        let words = arg.split(separator: " ").map(String.init)
        switch parts[0] {
        case "status":
            for d in app.manager.devices {
                out("\(d.name): \(d.state.rawValue) giữ=\(app.manager.isKept(d.id)) pin=\(d.battery.map { "\($0)%" } ?? "-") rssi=\(d.stats.rssi.map(String.init) ?? "-") fw=\(d.info.firmware ?? "-") khả năng=\(d.capabilities.map(\.rawValue).sorted()) đo được=\(d.measurableCapabilities.map(\.rawValue)) cài đặt=\(d.controls.count) mục")
            }
        case "measure":
            guard words.count >= 2, let d = find(app, words[0]), let cap = Capability(name: words[1]) else { return out("cú pháp: measure Tên CAP [giây]") }
            let seconds = words.count > 2 ? Double(words[2]) ?? 60 : 60
            let started = Date()
            var last = ""
            let task = d.startMeasuring(cap) { r in
                var s = "\(r.status.rawValue)"
                if let v = Format.value(r) { s += " \(v) \(r.unit)" }
                if let n = r.note { s += " (\(n))" }
                if s != last { out("\(d.name) \(cap.rawValue): \(s) +\(Int(Date().timeIntervalSince(started))) s"); last = s }
            }
            let timeout = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if !Task.isCancelled { task.cancel(); d.stopMeasuring(cap); out("\(d.name) \(cap.rawValue): hết \(Int(seconds)) s") }
            }
            await task.value
            timeout.cancel()
            let r = d.lastResult[cap]
            out("\(d.name) \(cap.rawValue): KẾT QUẢ \(r.map { "\(Format.value($0) ?? "-") \($0.unit)" } ?? "không có") sau \(Int(Date().timeIntervalSince(started))) s")
        case "sync":
            guard let name = words.first, let d = find(app, name) else { return out("cú pháp: sync Tên ngày") }
            let days = words.count > 1 ? Int(words[1]) ?? 7 : 7
            let started = Date()
            guard let h = await app.manager.syncHistory(d, days: days)?.value else { return out("\(d.name): LỖI đồng bộ: \(d.lastError ?? "?")") }
            let series = h.series.map { "\($0.key.rawValue)=\($0.value.count)" }.sorted().joined(separator: " ")
            let today = h.today.map { "bước=\($0.steps) kcal=\($0.calories / 1000) m=\($0.distanceMeters)" } ?? "không có"
            let sleep = h.sleep.map { "\($0.start.formatted(date: .abbreviated, time: .shortened)) \($0.asleepMinutes) phút" }.joined(separator: ", ")
            out("\(d.name): LỊCH SỬ \(String(format: "%.1f", Date().timeIntervalSince(started))) s · hôm nay: \(today) · ngủ: \(sleep.isEmpty ? "không có" : sleep) · chuỗi: \(series.isEmpty ? "không có" : series) · bài tập: \(h.workouts.count)")
            for (cap, pts) in h.series.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                if let l = pts.last { out("\(d.name):   \(cap.rawValue) mới nhất \(l.timestamp.formatted(date: .abbreviated, time: .shortened)) = \(l.value)") }
            }
            for w in h.workouts { out("\(d.name):   bài tập \(w.name) \(w.start.formatted()) \(w.activeSeconds) s") }
            for e in h.errors { out("\(d.name):   bước lỗi: \(e)") }
        case "controls":
            guard let d = find(app, arg) else { return out("không có thiết bị \(arg)") }
            out("\(d.name): " + d.controls.map { "\($0.id)=\(AutoTest.describe($0.value))\($0.enabled ? "" : "(khoá)")" }.joined(separator: " "))
        case "control":
            let at = arg.split(separator: "@", maxSplits: 1).map(String.init)
            guard at.count == 2, let d = find(app, at[0]), let cd = d as? ConfigurableDevice else { return out("cú pháp: control Tên@id[=giá trị]") }
            let kv = at[1].split(separator: "=", maxSplits: 1).map(String.init)
            do {
                if kv.count == 1 { try await cd.runAction(kv[0]) } else if let v = AutoTest.parseValue(kv[1]) { try await cd.setControl(kv[0], v) }
                out("\(d.name): \(at[1]) ✓")
            } catch {
                out("\(d.name): \(at[1]) LỖI: \(error.localizedDescription)")
            }
        case "raw":
            let at = arg.split(separator: "@", maxSplits: 1).map(String.init)
            guard at.count == 2, let g = find(app, at[0]) as? GloryFitDevice else { return out("cú pháp: raw Tên@[5:]HEX (chỉ GloryFit)") }
            var spec = at[1]
            let ble5 = spec.hasPrefix("5:")
            if ble5 { spec.removeFirst(2) }
            do {
                let got = try await g.debugExchange(spec.split(separator: " ").compactMap { UInt8($0, radix: 16) }, ble5: ble5)
                out("\(g.name): RAW \(spec) → \(got.isEmpty ? "không phản hồi" : got.map(\.hex).joined(separator: " | "))")
            } catch {
                out("\(g.name): RAW LỖI \(error.localizedDescription)")
            }
        case "disconnect":
            // Như người dùng bấm nút ngắt trên app (bỏ giữ kết nối).
            guard let d = find(app, arg) else { return out("không có thiết bị \(arg)") }
            app.manager.disconnect(d)
            out("\(d.name): đã ngắt (bỏ giữ kết nối)")
        case "connect":
            // Như người dùng bấm kết nối (giữ kết nối); in kết quả sau tối đa 45 s.
            guard let d = find(app, arg) else { return out("không có thiết bị \(arg)") }
            let started = Date()
            if let error = await app.manager.connect([d.id])[d.id] ?? nil {
                out("\(d.name): kết nối LỖI sau \(Int(Date().timeIntervalSince(started))) s: \(error.localizedDescription)")
            } else {
                out("\(d.name): đã kết nối sau \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            }
        case "face":
            // face Tên preset — cài mặt đồng hồ trong thư viện (vd ben10) và đặt làm mặt mặc định
            guard words.count >= 2, let g = find(app, words[0]) as? GloryFitDevice else { return out("cú pháp: face Tên preset") }
            let started = Date()
            do {
                try await app.watchFaces.install(words[1], on: g)
                out("\(g.name): đã cài \(words[1]) sau \(Int(Date().timeIntervalSince(started))) s")
            } catch { out("\(g.name): cài \(words[1]) LỖI \(error.localizedDescription)") }
        case "camera":
            // camera Tên open|shoot|close
            guard words.count >= 2, let d = find(app, words[0]) else { return out("cú pháp: camera Tên open|shoot|close") }
            switch words[1] {
            case "open": app.camera.open(d)
            case "shoot": app.camera.shoot(); try? await Task.sleep(nanoseconds: 3_000_000_000)
            default: app.camera.close()
            }
            out("\(d.name): camera \(words[1]) → \(app.camera.status ?? (app.camera.device == nil ? "đã đóng" : "đang mở"))")
        case "callbt":
            guard let g = find(app, arg) as? GloryFitDevice else { return out("cú pháp: callbt Tên (GloryFit)") }
            do {
                let c = try await g.callBluetoothState()
                out("\(g.name): kênh gọi \(c.name) \(c.address) bật=\(c.enabled) ghép=\(c.paired) kết nối=\(c.connected) ANCS=\(g.ancsAuthorized.map(String.init) ?? "?")")
            } catch { out("\(g.name): kênh gọi LỖI \(error.localizedDescription)") }
        case "weather":
            guard let d = find(app, arg) else { return out("không có thiết bị \(arg)") }
            await app.weather.push(to: d, refresh: true)
            out("\(d.name): \(app.weather.status[d.id] ?? "-")")
        case "report":
            guard let name = words.first, let d = find(app, name) else { return out("cú pháp: report Tên day|week") }
            let period: HealthPeriod = words.count > 1 && words[1] == "week" ? .week : .day
            let started = Date()
            switch await app.healthReport.run(d, period: period, manager: app.manager) {
            case .success(let e):
                out("\(d.name): BÁO CÁO \(period.title) sau \(String(format: "%.1f", Date().timeIntervalSince(started))) s (đồng bộ \(String(format: "%.1f", e.syncSeconds)) s, AI \(String(format: "%.1f", e.llmSeconds)) s) · phát hiện: \(e.findings.map { "\($0.code)=\($0.severity.rawValue)" }.joined(separator: " "))")
                for line in e.report.text.split(separator: "\n") { out("\(d.name):   \(line)") }
            case .failure(let error):
                out("\(d.name): LỖI báo cáo sau \(String(format: "%.1f", Date().timeIntervalSince(started))) s: \(error.localizedDescription)")
            }
        default:
            out("lệnh không rõ: \(parts[0])")
        }
    }
}
