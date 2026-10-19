import SmartWearCore
import SwiftUI
import UIKit

/// Màn "Chẩn đoán" kết nối của một thiết bị: trạng thái, quảng bá gần nhất, iOS có đang giữ không, lỗi gần nhất
/// đã giải thích + việc nên làm, dòng thời gian, và các nút Thử lại ngay / Quên / Giữ kết nối / Xuất nhật ký.
/// Mở màn thì quét liên tục để thấy thiết bị còn quảng bá không (cần cho heuristic "chờ ghép đôi").
struct DiagnosticsView: View {
    @Environment(AppState.self) private var app
    let device: WearableDevice
    @State private var scope: Scope = .device
    @State private var startedScan = false
    @State private var retrying = false
    @State private var export: ExportFile?
    @State private var confirmForget = false

    enum Scope: String, CaseIterable, Identifiable {
        case device = "Thiết bị này", all = "Mọi thiết bị"
        var id: String { rawValue }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                diagnosisCard
                // Chỉ phần trạng thái cập nhật mỗi giây ("x s trước").
                TimelineView(.periodic(from: .now, by: 1)) { ctx in statusCard(now: ctx.date) }
                actions
                timeline
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .scrollIndicators(.hidden)
        .background(Palette.background)
        .preferredColorScheme(.dark)
        .onAppear {
            guard !app.manager.isScanning else { return }
            app.manager.startScan(duration: nil)
            startedScan = true
        }
        .onDisappear {
            if startedScan { app.manager.stopScan() }
        }
        .sheet(item: $export) { ActivityView(items: [$0.url]) }
        .confirmationDialog("Quên \(device.name)?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Quên thiết bị", role: .destructive) {
                app.forget(device)
            }
        } message: {
            Text("Chỉ bỏ khỏi app. Nếu iPhone đã ghép đôi, vào Cài đặt → Bluetooth → Quên \(device.name) để xoá khoá ghép đôi.")
        }
    }

    // MARK: - Đầu màn

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "stethoscope").font(.title2).foregroundStyle(app.color(device.id))
            VStack(alignment: .leading, spacing: 2) {
                Text("Chẩn đoán").font(.title2.weight(.bold))
                Text("\(device.name) · \(device.state.title)").font(.subheadline).foregroundStyle(Palette.secondary)
            }
            Spacer()
            GlassButton(symbol: "xmark") { app.diagnosticsDeviceId = nil }
        }
    }

    private var diagnosisCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if device.isConnected {
                Label("Đang kết nối tốt", systemImage: "checkmark.circle.fill").font(.headline).foregroundStyle(Color(hex: 0x30D158))
                Text("Không có vấn đề. Lỗi cũ (nếu có) vẫn nằm trong dòng thời gian bên dưới.")
                    .font(.footnote).foregroundStyle(Palette.secondary)
            } else if let diag = device.diagnosis {
                Label(diag.title, systemImage: icon(diag.category)).font(.headline).foregroundStyle(.orange)
                Text(diag.detail).font(.subheadline)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "arrow.right.circle.fill").foregroundStyle(.white)
                    Text(diag.action).font(.subheadline.weight(.semibold))
                }
                .padding(.top, 2)
            } else {
                Label("Chưa phát hiện vấn đề", systemImage: "questionmark.circle").font(.headline)
                Text(device.state == .connecting ? "Đang kết nối… sau ~10 s treo sẽ có chẩn đoán." : "Bấm Thử lại ngay để kết nối và theo dõi từng bước.")
                    .font(.footnote).foregroundStyle(Palette.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func icon(_ c: DiagnosisCategory) -> String {
        switch c {
        case .pairing, .pairingPending, .advertisingNoLink: return "lock.trianglebadge.exclamationmark"
        case .notAdvertising, .linkLost, .peerDisconnected: return "antenna.radiowaves.left.and.right.slash"
        case .heldBySystem: return "iphone.radiowaves.left.and.right"
        case .bluetoothOff: return "bolt.horizontal.circle"
        case .wrongDriver, .handshake: return "puzzlepiece.extension"
        default: return "exclamationmark.triangle"
        }
    }

    // MARK: - Trạng thái

    private func statusCard(now: Date) -> some View {
        let m = app.manager
        let held = m.isHeldBySystem(device.id)
        return VStack(spacing: 0) {
            KeyValueRow(key: "Trạng thái", value: "\(device.state.title) · \(device.phase.rawValue)" + (device.phaseSince.map { " · \(ago($0, now))" } ?? ""))
            KeyValueRow(key: "Quảng bá gần nhất", value: device.lastAdvert.map { a in
                "\(ago(a.time, now))" + (a.rssi.map { " · \($0) dBm" } ?? "")
            } ?? (m.isScanning ? "chưa thấy (đang quét…)" : "chưa thấy trong phiên này"))
            KeyValueRow(key: "iOS đang giữ kết nối", value: held ? "Có (app khác / hệ thống)" : "Không")
            KeyValueRow(key: "iOS còn nhớ thiết bị", value: m.isUnknownToSystem(device.id) ? "Không — cần quét lại" : "Có")
            KeyValueRow(key: "Giữ kết nối", value: m.isKept(device.id) ? "Bật" : "Tắt")
            KeyValueRow(key: "Driver", value: device.driverId, mono: true)
            if let s = device.linkStatus { KeyValueRow(key: "Vòng nối lại", value: s) }
            if let f = device.lastFailure {
                KeyValueRow(key: "Lỗi gần nhất", value: "\(ago(f.time, now)) · \(f.message)" + (f.code.map { " [\($0.label)]" } ?? ""))
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .card()
    }

    private func ago(_ t: Date, _ now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(t)))
        let clock = String(Format.time.string(from: t).prefix(8))
        if s < 60 { return "\(clock) (\(s) s trước)" }
        if s < 3600 { return "\(clock) (\(s / 60) phút trước)" }
        return clock
    }

    // MARK: - Hành động

    private var actions: some View {
        VStack(spacing: 10) {
            PrimaryButton(
                title: retrying ? "Đang thử…" : "Thử lại ngay", symbol: "arrow.clockwise",
                enabled: !retrying && !device.isConnected
            ) {
                retrying = true
                Task {
                    await app.manager.retryNow(device)
                    retrying = false
                }
            }
            Toggle(isOn: Binding(
                get: { app.manager.isKept(device.id) },
                set: { app.manager.setKeepConnected($0, for: device) }
            )) {
                Text("Giữ kết nối").font(.subheadline.weight(.semibold))
            }
            .tint(Color(hex: 0x30D158))
            .padding(.horizontal, 4)
            HStack(spacing: 10) {
                GlassButton(title: "Xuất nhật ký", symbol: "square.and.arrow.up") { exportLog() }
                    .frame(maxWidth: .infinity)
                GlassButton(title: "Quên thiết bị", symbol: "trash", tint: .red.opacity(0.45)) { confirmForget = true }
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// Ghi file .txt (thông tin app + thiết bị + dòng thời gian + nhật ký chung) rồi mở bảng chia sẻ.
    private func exportLog() {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let header = [
            "App: SmartWear Lab \(version) (\(build))",
            "iOS: \(UIDevice.current.systemName) \(UIDevice.current.systemVersion), máy \(Self.machine)",
        ]
        var text = app.manager.diagnosticsReport(for: device, header: header)
        let all = app.manager.events.elements
        if !all.isEmpty {
            text += "\n--- Nhật ký chung, mọi thiết bị (\(all.count) sự kiện) ---\n"
            text += all.map { $0.line(withDevice: true) }.joined(separator: "\n") + "\n"
        }
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let safeName = device.name.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "_")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SmartWear-\(safeName)-\(stamp.string(from: Date())).txt")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            export = ExportFile(url: url)
        } catch {
            device.logEvent(.user, "Xuất nhật ký lỗi: \(error.localizedDescription)", level: .error)
        }
    }

    private static var machine: String {
        var u = utsname()
        uname(&u)
        return withUnsafeBytes(of: &u.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    // MARK: - Dòng thời gian

    private var timeline: some View {
        let events = scope == .device ? device.timeline.elements : app.manager.events.elements
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Dòng thời gian").font(.title3.weight(.semibold))
                Spacer()
                Text("\(events.count) sự kiện").font(.footnote).foregroundStyle(Palette.tertiary)
            }
            Picker("Phạm vi", selection: $scope) {
                ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            if events.isEmpty {
                Text("Chưa có sự kiện").font(.footnote).foregroundStyle(Palette.tertiary)
            }
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(events.reversed()) { e in EventRow(event: e, showDevice: scope == .all) }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
    }
}

/// Một dòng sự kiện: giờ, mức (màu), loại, nội dung + mã lỗi.
struct EventRow: View {
    let event: ConnectionEvent
    var showDevice = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(String(Format.time.string(from: event.time).prefix(8)))
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.tertiary)
            StatusDot(color: color)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.kind.rawValue + (showDevice ? " · \(event.deviceName ?? "chung")" : ""))
                    .font(.caption.weight(.semibold)).foregroundStyle(Palette.secondary)
                Text(event.message + (event.code.map { " [\($0.label)]" } ?? ""))
                    .font(.footnote).foregroundStyle(event.level == .error ? .red.opacity(0.95) : .white.opacity(0.9))
                    .textSelection(.enabled)
            }
        }
    }

    private var color: Color {
        switch event.level {
        case .info: return event.kind == .ready ? Color(hex: 0x30D158) : Palette.tertiary
        case .warning: return .orange
        case .error: return .red
        }
    }
}

/// Dòng tóm tắt chẩn đoán dưới thiết bị trong danh sách; chạm để mở màn Chẩn đoán.
struct DiagnosisSummaryRow: View {
    @Environment(AppState.self) private var app
    let device: WearableDevice
    let diagnosis: Diagnosis

    var body: some View {
        Button { app.openDiagnostics(device) } label: {
            HStack(spacing: 8) {
                Image(systemName: "stethoscope").font(.footnote.weight(.semibold)).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(diagnosis.title).font(.footnote.weight(.semibold)).foregroundStyle(.white)
                    Text(diagnosis.action).font(.caption).foregroundStyle(Palette.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text("Chẩn đoán").font(.caption.weight(.semibold)).foregroundStyle(Palette.secondary)
                Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(Palette.tertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.leading, 68).padding(.trailing, 14).padding(.bottom, 10)
        }
        .buttonStyle(.plain)
    }
}

struct ExportFile: Identifiable {
    let url: URL
    var id: URL { url }
}

/// Bảng chia sẻ iOS (UIActivityViewController) cho file nhật ký.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
