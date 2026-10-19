import SmartWearCore
import SwiftUI

/// Tab "Thiết bị": danh sách sống trong sheet, "Đo đồng loạt".
struct DevicesTab: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let m = app.manager
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Thiết bị").font(.largeTitle.weight(.bold))
                        Text(summary).font(.subheadline).foregroundStyle(Palette.secondary)
                    }
                    Spacer()
                    GlassButton(symbol: "plus") {
                        withAnimation(.snappy) { app.tab = .add }
                        if !m.isScanning { m.startScan() }
                    }
                }

                if !m.connectedDevices.isEmpty { bulkRow }

                if m.devices.isEmpty {
                    empty
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(m.devices.enumerated()), id: \.element.id) { i, d in
                            DeviceRow(device: d)
                            if let diag = d.diagnosis, !d.isConnected { DiagnosisSummaryRow(device: d, diagnosis: diag) }
                            if i < m.devices.count - 1 { Divider().overlay(Palette.hairline).padding(.leading, 70) }
                        }
                    }
                    .card()
                }

                if app.connecting {
                    HStack(spacing: 8) {
                        ProgressView().tint(.white)
                        Text("Đang kết nối song song…").font(.footnote).foregroundStyle(Palette.secondary)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 110)
        }
        .scrollIndicators(.hidden)
    }

    private var summary: String {
        let m = app.manager
        let hr = m.connectedDevices.filter { $0.measurableCapabilities.contains(.heartRate) }.count
        return "\(m.connectedDevices.count) đang kết nối · \(hr) hỗ trợ nhịp tim"
    }

    private var bulkRow: some View {
        @Bindable var app = app
        let measuring = app.manager.isMeasuringAny
        return HStack(spacing: 10) {
            Button {
                if measuring { app.manager.stopAll() } else { app.manager.measureAll(app.bulkCapability) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: measuring ? "stop.fill" : "play.fill").font(.footnote.weight(.bold))
                    Text(measuring ? "Dừng tất cả" : "Đo đồng loạt").font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(.black)
                .padding(.horizontal, 18)
                .frame(height: 44)
                .background(.white, in: Capsule())
            }
            .buttonStyle(.plain)

            Menu {
                Picker("Phép đo", selection: $app.bulkCapability) {
                    ForEach(app.bulkCapabilities, id: \.self) { c in
                        Label(c.title, systemImage: c.symbol).tag(c)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    StatusDot(color: app.bulkCapability.tint)
                    Text(app.bulkCapability.title).font(.subheadline.weight(.semibold))
                    Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 44)
                .glassCapsule()
            }
            Spacer()
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "dot.radiowaves.left.and.right").font(.title2).foregroundStyle(Palette.secondary)
            Text("Chưa có thiết bị").font(.headline)
            Text("Chạm + để quét, chọn nhiều thiết bị rồi kết nối song song. Mỗi thiết bị có màn riêng với đủ chức năng của nó.")
                .font(.subheadline).foregroundStyle(Palette.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

struct DeviceRow: View {
    @Environment(AppState.self) private var app
    let device: WearableDevice

    var body: some View {
        let color = app.color(device.id)
        let primary = primaryCapability
        HStack(spacing: 14) {
            ZStack {
                PulseRing(trigger: device.pulse, color: color, size: 40)
                Orb(color: color, size: 40, filled: device.isConnected)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(device.name).font(.headline).lineLimit(1)
                HStack(spacing: 6) {
                    StatusDot(color: statusColor)
                    Text(statusText).font(.footnote).foregroundStyle(Palette.secondary).lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 3) {
                if let primary, let v = Format.value(device.latest[primary] ?? device.lastResult[primary]) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(v).font(.title2.weight(.semibold)).monospacedDigit().foregroundStyle(primary.tint)
                        Text((device.latest[primary] ?? device.lastResult[primary])?.unit ?? "").font(.caption).foregroundStyle(Palette.secondary)
                    }
                }
                if device.isConnected { BatteryLabel(level: device.battery, charging: device.charging) }
            }
            .fixedSize()
            Button {
                if device.state == .disconnected {
                    Task { await app.manager.connect([device.id]) }
                } else {
                    app.manager.disconnect(device)
                }
            } label: {
                Image(systemName: device.state == .disconnected ? "link" : "power")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.secondary)
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture { app.open(device) }
    }

    private var primaryCapability: Capability? {
        device.measuring.first ?? device.measurableCapabilities.first { device.latest[$0] != nil || device.lastResult[$0] != nil }
    }

    private var statusText: String {
        if let s = device.linkStatus, !device.isConnected { return s }
        if let e = device.lastError, device.state == .disconnected { return e }
        if let c = device.measuring.first { return "Đang đo \(c.title)" }
        if let c = primaryCapability, let r = device.latest[c], r.status != .ok { return "\(c.title): \(Format.status(r))" }
        return "\(device.kind.title) · \(device.state.title)"
    }

    private var statusColor: Color {
        if device.linkStatus != nil, !device.isConnected { return .orange }
        if device.lastError != nil, device.state == .disconnected { return .red }
        if let c = device.measuring.first { return c.tint }
        switch device.state {
        case .connected: return Color(hex: 0x30D158)
        case .connecting, .disconnecting: return .orange
        case .disconnected: return Palette.tertiary
        }
    }
}
