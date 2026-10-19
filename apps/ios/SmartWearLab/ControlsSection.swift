import SmartWearCore
import SwiftUI

/// Cài đặt & điều khiển của thiết bị, vẽ theo `DeviceControl.kind` (cùng ý với `ControlsSection` Android). Mục số dùng
/// Stepper và chỉ gửi xuống thiết bị sau 0,7 s không bấm thêm (tránh gửi một lệnh mỗi lần bấm).
struct ControlsSection: View {
    @Environment(AppState.self) private var app
    let device: WearableDevice
    private let configurable: ConfigurableDevice
    @State private var pending: [String: Int] = [:]
    @State private var timers: [String: Task<Void, Never>] = [:]
    @State private var error: String?
    @State private var notice: String?
    /// Hành động đang chờ người dùng xác nhận (`DeviceControl.confirm`).
    @State private var confirming: DeviceControl?

    /// nil nếu thiết bị không có cài đặt, để màn chi tiết chèn thẳng `ControlsSection(device)`.
    init?(_ device: WearableDevice) {
        guard let c = device as? ConfigurableDevice, !device.controls.isEmpty else { return nil }
        self.device = device
        configurable = c
    }

    private static let green = Color(hex: 0x30D158)
    private var connected: Bool { device.state == .connected }

    var body: some View {
        let groups = Dictionary(grouping: device.controls, by: \.group)
        let order = device.controls.map(\.group).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        VStack(alignment: .leading, spacing: 12) {
            ForEach(order, id: \.self) { group in
                SectionTitle(text: group)
                VStack(spacing: 0) {
                    let items = groups[group] ?? []
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, c in
                        if i > 0 { Divider().overlay(Color.white.opacity(0.08)) }
                        row(c).padding(.vertical, 10).opacity(c.enabled ? 1 : 0.4).disabled(!c.enabled)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .card()
            }
            if let w = device as? WeatherDisplay, w.supportsWeather { weatherCard }
            AlarmsCard(device) // báo thức (nil nếu thiết bị không có)
            CallContactsCard(device) // gọi điện + danh bạ (nil nếu không phải đồng hồ GloryFit có tính năng này)
            if device.supportsMusicControl {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Điều khiển nhạc").font(.subheadline.weight(.semibold))
                    Text(app.music.status[device.id]
                         ?? "Nút nhạc trên đồng hồ điều khiển app Nhạc của iPhone. iOS không cho điều khiển Spotify/YouTube hay đổi âm lượng.")
                        .font(.caption).foregroundStyle(Palette.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .card()
            }
            if device.supportsRemoteCamera {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Chụp ảnh từ xa").font(.subheadline.weight(.semibold))
                        Text("Mở camera, bấm nút chụp trên đồng hồ. Ảnh lưu vào Ảnh.").font(.caption).foregroundStyle(Palette.secondary)
                    }
                    Spacer()
                    GlassButton(title: "Mở", symbol: "camera") { app.camera.open(device) }
                        .opacity(connected ? 1 : 0.4).disabled(!connected)
                }
                .padding(16)
                .card()
            }
            if !connected {
                Text("Thay đổi được lưu và gửi xuống khi thiết bị kết nối.").font(.footnote).foregroundStyle(Palette.secondary)
            }
            if let notice { Text(notice).font(.footnote).foregroundStyle(Self.green) }
            if let error { Text(error).font(.footnote).foregroundStyle(.orange) }
        }
        .confirmationDialog(
            confirming?.confirm ?? "", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible
        ) {
            if let c = confirming {
                Button(c.title, role: .destructive) { run(c, confirmed: true) }
            }
            Button("Huỷ", role: .cancel) { confirming = nil }
        }
        .onChange(of: device.id) {
            pending = [:]
            error = nil
            notice = nil
        }
    }

    @ViewBuilder
    private func row(_ c: DeviceControl) -> some View {
        switch c.kind {
        case .action:
            HStack {
                label(c)
                Spacer()
                GlassButton(title: c.confirm == nil ? "Bắt đầu" : "Xoá", symbol: c.confirm == nil ? "dot.radiowaves.left.and.right" : "trash") { run(c) }
                    .opacity(connected ? 1 : 0.4)
                    .disabled(!connected)
            }
        case .toggle:
            Toggle(isOn: Binding(
                get: { if case .bool(let on) = c.value { on } else { false } },
                set: { send(c.id, .bool($0)) }
            )) { label(c) }
            .tint(Self.green)
        case .number:
            let stored: Int = { if case .number(let n) = c.value { n } else { c.min } }()
            let current = pending[c.id] ?? stored
            Stepper(value: Binding(get: { current }, set: { schedule(c.id, $0) }), in: c.min...max(c.min, c.max), step: c.step) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.title).font(.subheadline.weight(.semibold))
                    Text("\(current) \(c.unit)").font(.footnote.monospacedDigit())
                        .foregroundStyle(pending[c.id] != nil ? Color.accentColor : Palette.secondary)
                }
            }
        case .choice:
            let index: Int = { if case .number(let n) = c.value { n } else { 0 } }()
            HStack {
                label(c)
                Spacer()
                Picker(c.title, selection: Binding(get: { index }, set: { send(c.id, .number($0)) })) {
                    ForEach(Array(c.options.enumerated()), id: \.offset) { i, name in Text(name).tag(i) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
        case .timeRange:
            if case .timeRange(let from, let to) = c.value {
                HStack {
                    label(c)
                    Spacer()
                    DatePicker("", selection: Binding(get: { date(from) }, set: { send(c.id, .timeRange(from: minute($0), to: to)) }),
                               displayedComponents: .hourAndMinute).labelsHidden()
                    Text("–").foregroundStyle(Palette.secondary)
                    DatePicker("", selection: Binding(get: { date(to) }, set: { send(c.id, .timeRange(from: from, to: minute($0))) }),
                               displayedComponents: .hourAndMinute).labelsHidden()
                }
            }
        }
    }

    @State private var weatherBusy = false

    /// Dự báo 7 ngày (Open-Meteo) theo vị trí gần đúng, tự gửi khi kết nối.
    private var weatherCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: "Thời tiết")
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dự báo 7 ngày trên đồng hồ").font(.subheadline.weight(.semibold))
                    Text(app.weather.status[device.id] ?? "Tự gửi khi kết nối, theo vị trí gần đúng của iPhone")
                        .font(.caption).foregroundStyle(Palette.secondary)
                }
                Spacer()
                GlassButton(title: weatherBusy ? "Đang gửi…" : "Cập nhật", symbol: "cloud.sun") {
                    weatherBusy = true
                    Task {
                        await app.weather.push(to: device, refresh: true)
                        weatherBusy = false
                    }
                }
                .opacity(connected && !weatherBusy ? 1 : 0.4)
                .disabled(!connected || weatherBusy)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .card()
        }
    }

    private func label(_ c: DeviceControl) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(c.title).font(.subheadline.weight(.semibold))
            if let d = c.detail { Text(d).font(.caption).foregroundStyle(Palette.secondary) }
        }
    }

    private func date(_ minute: Int) -> Date {
        Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date()
    }

    private func minute(_ d: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    private func schedule(_ id: String, _ value: Int) {
        pending[id] = value
        timers[id]?.cancel()
        timers[id] = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled, pending[id] == value else { return }
            pending[id] = nil
            send(id, .number(value))
        }
    }

    private func send(_ id: String, _ value: ControlValue) {
        Task {
            error = nil
            do { try await configurable.setControl(id, value) } catch { self.error = error.localizedDescription }
        }
    }

    private func run(_ c: DeviceControl, confirmed: Bool = false) {
        if c.confirm != nil, !confirmed {
            confirming = c
            return
        }
        confirming = nil
        Task {
            error = nil
            do {
                try await configurable.runAction(c.id)
                notice = "Đã gửi: \(c.title)"
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
