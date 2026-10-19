import SmartWearCore
import SmartWearQRing
import SwiftUI

/// Màn riêng của một thiết bị, sinh hoàn toàn từ capability của chính thiết bị đó.
struct DeviceDetailView: View {
    @Environment(AppState.self) private var app
    let device: WearableDevice
    @State private var focus: Capability?
    @State private var showTech = false
    @State private var confirmForget = false
    @State private var batteryBusy = false

    var body: some View {
        let color = app.color(device.id)
        VStack(spacing: 0) {
            switcher
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(color)
                    if let cap = focused { hero(cap) }
                    measurements
                    if device.supportsHistory { HistorySection(device: device) } else { syncedData }
                    HealthReportCard(device) // báo cáo AI (nil nếu thiết bị không lưu lịch sử)
                    WatchFaceLibrarySection(device) // chỉ đồng hồ GloryFit (nil với thiết bị khác)
                    ControlsSection(device) // cài đặt & điều khiển (nil nếu thiết bị không có)
                    batteryAndInfo
                    technical
                    actions
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 110)
            }
            .scrollIndicators(.hidden)
        }
        .onChange(of: device.id) { focus = nil; showTech = false }
    }

    private var focused: Capability? {
        if let focus, device.measurableCapabilities.contains(focus) { return focus }
        return device.measuring.first ?? device.measurableCapabilities.first
    }

    // MARK: - Chip chuyển thiết bị

    private var switcher: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal) {
                GlassGroup(spacing: 6) {
                    HStack(spacing: 6) {
                        ForEach(app.manager.devices) { d in
                            Button { app.selectedDeviceId = d.id } label: {
                                HStack(spacing: 6) {
                                    StatusDot(color: app.color(d.id))
                                    Text(d.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                                    if !d.measuring.isEmpty { StatusDot(color: .red) }
                                }
                                .foregroundStyle(d.id == device.id ? .white : Palette.secondary)
                                .padding(.horizontal, 12)
                                .frame(height: 34)
                                .glassCapsule(tint: d.id == device.id ? app.color(d.id).opacity(0.5) : nil)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .scrollIndicators(.hidden)
            GlassButton(symbol: "xmark") { withAnimation(.snappy) { app.closeDetail() } }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func header(_ color: Color) -> some View {
        HStack(spacing: 14) {
            ZStack {
                PulseRing(trigger: device.pulse, color: color, size: 56)
                Orb(color: color, size: 56, filled: device.isConnected)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(device.info.model.map { $0 == device.name ? device.name : "\(device.name)" } ?? device.name)
                    .font(.title.weight(.bold)).lineLimit(1).minimumScaleFactor(0.7)
                HStack(spacing: 8) {
                    Text("\(device.kind.title) · \(device.state.title)").foregroundStyle(Palette.secondary)
                    if device.isConnected { BatteryLabel(level: device.battery, charging: device.charging) }
                }
                .font(.subheadline)
                if let s = device.linkStatus, !device.isConnected {
                    Text(s).font(.footnote).foregroundStyle(.orange).lineLimit(2)
                }
                if let diag = device.diagnosis, !device.isConnected {
                    Button { app.openDiagnostics(device) } label: {
                        Label(diag.title, systemImage: "stethoscope").font(.footnote.weight(.semibold))
                            .foregroundStyle(.orange).lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }
                if let e = device.lastError {
                    Text(e).font(.footnote).foregroundStyle(.red.opacity(0.9)).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Thẻ đo chính

    private func hero(_ cap: Capability) -> some View {
        let r = device.latest[cap]
        let last = device.lastResult[cap]
        let isMeasuring = device.measuring.contains(cap)
        let value = Format.value(r?.status == .ok ? r : (isMeasuring ? nil : last))
        let trail = device.trail[cap] ?? []
        let note = r?.needsTouch == true ? nil : r?.note
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(cap.title, systemImage: cap.symbol).font(.headline).foregroundStyle(cap.tint)
                Spacer()
                Text(isMeasuring ? "Đang đo · gói #\(trail.count)" : (last.map { "lần đo " + Format.time.string(from: $0.timestamp).prefix(8) } ?? ""))
                    .font(.footnote).foregroundStyle(Palette.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let value {
                    Text(value).font(.system(size: 76, weight: .semibold, design: .rounded)).monospacedDigit()
                        .contentTransition(.numericText())
                    Text(r?.unit.isEmpty == false ? r!.unit : cap.defaultUnit).font(.title3).foregroundStyle(Palette.secondary)
                } else {
                    Text(heroPlaceholder(r, isMeasuring: isMeasuring))
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .foregroundStyle(r?.status == .notWorn ? .orange : (r?.status == .error ? .red : .white.opacity(0.85)))
                }
            }
            .animation(.snappy, value: value)
            PacketBars(values: trail, color: cap.tint).frame(height: 44)
            // Phép đo cần chạm cảm biến (thành phần máu / cơ thể): nhắc đặt ngón tay, kèm tiến độ khi đang đo.
            if let r, r.needsTouch, isMeasuring || r.status != .ok {
                Text("Đặt ngón tay lên cảm biến của vòng tay"
                     + (isMeasuring ? (r.extra[Reading.progressKey].map { " · \(Int($0)) %" } ?? "") : ""))
                    .font(.callout.weight(.medium)).foregroundStyle(.orange)
            }
            HStack {
                Text(isMeasuring ? (note ?? "Mỗi cột là một gói từ thiết bị") : (note ?? "Chạm Đo để bắt đầu"))
                    .font(.footnote).foregroundStyle(Palette.tertiary).lineLimit(2)
                Spacer()
                if isMeasuring {
                    GlassButton(title: "Dừng", symbol: "stop.fill") { device.stopMeasuring(cap) }
                } else {
                    GlassButton(title: "Đo", symbol: "play.fill", tint: cap.tint.opacity(0.6)) { device.startMeasuring(cap) }
                        .disabled(!device.isConnected)
                        .opacity(device.isConnected ? 1 : 0.4)
                }
            }
        }
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 26, style: .continuous).fill(Palette.card)
            RoundedRectangle(cornerRadius: 26, style: .continuous).fill(
                LinearGradient(colors: [cap.tint.opacity(0.16), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
            )
        }
    }

    private func heroPlaceholder(_ r: Reading?, isMeasuring: Bool) -> String {
        switch r?.status {
        case .notWorn: return "Chưa đeo"
        case .error: return "Lỗi"
        case .measuring: return "Đang đo…"
        default: return isMeasuring ? "Đang đo…" : "chưa đo"
        }
    }

    // MARK: - Lưới phép đo (theo capability)

    private var measurements: some View {
        let caps = device.measurableCapabilities
        return VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Phép đo", trailing: caps.isEmpty ? nil : "\(caps.count) loại")
            if caps.isEmpty {
                Text(device.isConnected ? "Thiết bị này không có phép đo trực tiếp." : "Kết nối để đọc khả năng của thiết bị.")
                    .font(.subheadline).foregroundStyle(Palette.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                    ForEach(caps, id: \.self) { cap in tile(cap) }
                }
            }
        }
    }

    private func tile(_ cap: Capability) -> some View {
        let isFocus = focused == cap
        let r = device.latest[cap] ?? device.lastResult[cap]
        return Button {
            focus = cap
            if device.isConnected, !device.measuring.contains(cap) { device.startMeasuring(cap) }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: cap.symbol).font(.subheadline).foregroundStyle(cap.tint)
                    .frame(width: 30, height: 30).background(cap.tint.opacity(0.15), in: Circle())
                Text(cap.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                Text(device.measuring.contains(cap) ? "Đang đo…" : Format.status(r))
                    .font(.caption).foregroundStyle(r?.status == .ok ? cap.tint : Palette.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .padding(12)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(isFocus ? cap.tint.opacity(0.8) : .clear, lineWidth: 1.2)
            }
        }
        .buttonStyle(.plain)
    }

    /// Capability có nhưng không đo trực tiếp (bước chân, giấc ngủ…): hiển thị trung thực.
    private var syncedData: some View {
        let other = Capability.allCases.filter { device.capabilities.contains($0) && !device.measurableCapabilities.contains($0) }
        return Group {
            if !other.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(text: "Dữ liệu đồng bộ")
                    VStack(spacing: 0) {
                        ForEach(Array(other.enumerated()), id: \.element) { i, cap in
                            HStack(spacing: 12) {
                                Image(systemName: cap.symbol).foregroundStyle(cap.tint).frame(width: 24)
                                Text(cap.title).font(.subheadline)
                                Spacer()
                                Text("đồng bộ lịch sử · chưa có trong bản này").font(.caption).foregroundStyle(Palette.tertiary)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 11)
                            if i < other.count - 1 { Divider().overlay(Palette.hairline).padding(.leading, 50) }
                        }
                    }
                    .card()
                }
            }
        }
    }

    // MARK: - Pin & thông tin

    private var batteryAndInfo: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Pin & thông tin")
            VStack(spacing: 0) {
                HStack {
                    Text("Pin").foregroundStyle(Palette.secondary).font(.subheadline)
                    Spacer()
                    BatteryLabel(level: device.battery, charging: device.charging)
                    Button {
                        batteryBusy = true
                        Task {
                            try? await device.refreshBattery()
                            batteryBusy = false
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise").font(.footnote.weight(.semibold))
                            .rotationEffect(.degrees(batteryBusy ? 180 : 0))
                            .animation(.easeInOut(duration: 0.4), value: batteryBusy)
                    }
                    .buttonStyle(.plain)
                    .disabled(!device.isConnected)
                    .padding(.leading, 8)
                }
                .padding(.vertical, 6)
                KeyValueRow(key: "Model", value: device.info.model)
                KeyValueRow(key: "Hãng", value: device.info.manufacturer)
                KeyValueRow(key: "Firmware", value: device.info.firmware)
                KeyValueRow(key: "Phần cứng", value: device.info.hardware)
                if device.info.software != nil { KeyValueRow(key: "Phần mềm", value: device.info.software) }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .card()
        }
    }

    // MARK: - Chi tiết kỹ thuật

    private var technical: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy) { showTech.toggle() }
            } label: {
                HStack {
                    Text("Chi tiết kỹ thuật").font(.title3.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.down").rotationEffect(.degrees(showTech ? 180 : 0))
                }
                .foregroundStyle(.white)
                .padding(.top, 8)
            }
            .buttonStyle(.plain)

            if showTech {
                VStack(spacing: 0) {
                    KeyValueRow(key: "Driver", value: device.driverId, mono: true)
                    KeyValueRow(key: "ID (CoreBluetooth)", value: device.id.uuidString, mono: true)
                    KeyValueRow(key: "MAC", value: device.mac ?? "iOS ẩn MAC", mono: true)
                    KeyValueRow(key: "Capability", value: Capability.allCases.filter(device.capabilities.contains).map(\.rawValue).joined(separator: " "), mono: true)
                    ForEach(device.info.extra, id: \.key) { e in
                        KeyValueRow(key: e.key, value: e.value, mono: true)
                    }
                    Divider().overlay(Palette.hairline).padding(.vertical, 4)
                    KeyValueRow(key: "RSSI", value: device.stats.rssi.map { "\($0) dBm" }, mono: true)
                    KeyValueRow(key: "Gói đã nhận", value: "\(device.stats.packetsReceived)", mono: true)
                    KeyValueRow(key: "Gói/s (5 s)", value: Format.number(device.stats.packetsPerSecond, decimals: 1), mono: true)
                    KeyValueRow(key: "Lỗi", value: "\(device.stats.errors)", mono: true)
                    KeyValueRow(key: "Độ trễ", value: device.stats.lastLatencyMs.map { "\($0) ms" }, mono: true)
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .card()

                PacketLogView(entries: device.log)
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            if device.state == .connecting, app.manager.isKept(device.id) {
                // Lệnh nối chờ không giới hạn đang chạy: app tự nối ngay khi thiết bị hé tín hiệu, bấm thêm không nhanh hơn.
                Label("Đang chờ \(device.name) phát tín hiệu — app tự nối, không cần bấm. Lâu quá thì chạm sáng màn hình đồng hồ.",
                      systemImage: "antenna.radiowaves.left.and.right")
                    .font(.footnote)
                    .foregroundStyle(Palette.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
            if device.state == .disconnected {
                PrimaryButton(title: "Kết nối lại", symbol: "link") {
                    Task { await app.manager.connect([device.id]) }
                }
            } else {
                GlassButton(title: "Ngắt kết nối", symbol: "power") { app.manager.disconnect(device) }
                    .frame(maxWidth: .infinity)
            }
            GlassButton(title: "Chẩn đoán kết nối", symbol: "stethoscope", tint: device.diagnosis == nil ? nil : .orange.opacity(0.5)) {
                app.openDiagnostics(device)
            }
            .frame(maxWidth: .infinity)
            Toggle(isOn: Binding(
                get: { app.manager.isKept(device.id) },
                set: { app.manager.setKeepConnected($0, for: device) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Giữ kết nối").font(.subheadline.weight(.semibold))
                    Text("Tự nối lại khi mất kết nối và khi mở app").font(.caption).foregroundStyle(Palette.secondary)
                }
            }
            .tint(Color(hex: 0x30D158))
            .padding(.horizontal, 4)
            GlassButton(title: "Quên thiết bị", symbol: "trash", tint: .red.opacity(0.45)) { confirmForget = true }
                .frame(maxWidth: .infinity)
                .confirmationDialog("Quên \(device.name)?", isPresented: $confirmForget, titleVisibility: .visible) {
                    Button("Quên thiết bị", role: .destructive) { app.forget(device) }
                } message: {
                    Text("Bỏ khỏi app và nhả kết nối để điện thoại khác nối được. Muốn dùng lại thì quét và kết nối lại.")
                }
        }
        .padding(.top, 8)
    }
}

struct PacketLogView: View {
    let entries: [PacketLogEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Nhật ký gói tin · \(entries.count) dòng gần nhất").font(.footnote.weight(.semibold)).foregroundStyle(Palette.secondary)
            if entries.isEmpty {
                Text("chưa có gói nào").font(.caption).foregroundStyle(Palette.tertiary)
            }
            ForEach(entries.suffix(80).reversed()) { e in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Format.time.string(from: e.time)).foregroundStyle(Palette.tertiary)
                    Text(arrow(e.direction)).foregroundStyle(color(e.direction))
                    Text(e.channel).foregroundStyle(Palette.secondary)
                    Text(e.hex.isEmpty ? (e.note ?? "") : e.hex + (e.note.map { "  (\($0))" } ?? ""))
                        .foregroundStyle(e.direction == .error ? .red : .white.opacity(0.88))
                }
                .font(.system(size: 10.5, design: .monospaced))
                .lineLimit(3)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func arrow(_ d: TrafficDirection) -> String {
        switch d {
        case .tx: return "→"
        case .rx: return "←"
        case .info: return "•"
        case .error: return "!"
        }
    }

    private func color(_ d: TrafficDirection) -> Color {
        switch d {
        case .tx: return Color(hex: 0x4DA3FF)
        case .rx: return Color(hex: 0x30D158)
        case .info: return Palette.secondary
        case .error: return .red
        }
    }
}
