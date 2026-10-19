import SmartWearCore
import SwiftUI

/// Tab "Khả thi": kết nối song song có ổn không, đo đồng loạt, chỉ số kết nối thật.
struct FeasibilityTab: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        let m = app.manager
        let connected = m.connectedDevices.count
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Khả thi").font(.largeTitle.weight(.bold))
                    Text("Kết nối song song có ổn không").font(.subheadline).foregroundStyle(Palette.secondary)
                }

                HStack(alignment: .center, spacing: 16) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(connected)").font(.system(size: 76, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text("/ \(m.maxConnections)").font(.title.weight(.medium)).foregroundStyle(Palette.secondary)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 5) {
                            ForEach(0..<m.maxConnections, id: \.self) { i in
                                let d = i < connected ? m.connectedDevices[i] : nil
                                Circle().fill(d.map { app.color($0.id) } ?? Palette.hairline).frame(width: 10, height: 10)
                            }
                        }
                        Text("kết nối GATT đồng thời\ngiới hạn mềm \(m.maxConnections) thiết bị")
                            .font(.footnote).foregroundStyle(Palette.secondary)
                    }
                }

                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(app.bulkCapabilities, id: \.self) { c in
                            Button { app.bulkCapability = c } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: c.symbol).font(.caption)
                                    Text(c.title).font(.subheadline.weight(.semibold))
                                }
                                .foregroundStyle(app.bulkCapability == c ? .black : .white)
                                .padding(.horizontal, 14).frame(height: 36)
                                .background(app.bulkCapability == c ? AnyShapeStyle(.white) : AnyShapeStyle(Palette.card), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .scrollIndicators(.hidden)

                let targets = m.devicesSupporting(app.bulkCapability)
                if m.isMeasuringAny {
                    PrimaryButton(title: "Dừng tất cả", symbol: "stop.fill") { m.stopAll() }
                } else {
                    PrimaryButton(
                        title: "Đo đồng loạt · \(targets.count) thiết bị", symbol: "play.fill", enabled: !targets.isEmpty
                    ) { m.measureAll(app.bulkCapability) }
                }

                if !m.devices.isEmpty {
                    VStack(spacing: 10) {
                        ForEach(m.devices) { d in
                            HStack(spacing: 10) {
                                StatusDot(color: app.color(d.id))
                                Text("\(d.name) · \(app.bulkCapability.title)").font(.subheadline).lineLimit(1)
                                Spacer()
                                Text(resultText(d)).font(.subheadline.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(resultColor(d))
                            }
                        }
                    }
                    .padding(16)
                    .card()
                }

                SectionTitle(text: "Giám sát song song")
                StatsTable()

                Text("Số liệu đo thật trên kết nối hiện tại. Gói/s là cửa sổ trượt 5 s, độ trễ là thời gian từ lệnh đến phản hồi đầu tiên. Ô \"chưa đo\" là chưa có số.")
                    .font(.footnote).foregroundStyle(Palette.tertiary)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 110)
        }
        .scrollIndicators(.hidden)
    }

    private func resultText(_ d: WearableDevice) -> String {
        let c = app.bulkCapability
        guard d.measurableCapabilities.contains(c) else { return d.isConnected ? "không hỗ trợ" : d.state.title.lowercased() }
        return Format.status(d.latest[c] ?? d.lastResult[c])
    }

    private func resultColor(_ d: WearableDevice) -> Color {
        let r = d.latest[app.bulkCapability]
        switch r?.status {
        case .ok: return app.bulkCapability.tint
        case .notWorn: return .orange
        case .error: return .red
        default: return Palette.secondary
        }
    }
}

struct StatsTable: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let m = app.manager
        VStack(spacing: 0) {
            row(["Thiết bị", "RSSI", "Gói/s", "Lỗi", "Độ trễ"], header: true, color: nil)
            ForEach(m.devices) { d in
                Divider().overlay(Palette.hairline)
                let s = d.stats
                row(
                    [
                        d.name,
                        s.rssi.map(String.init) ?? "chưa đo",
                        s.packetsReceived == 0 ? "chưa đo" : Format.number(s.packetsPerSecond, decimals: 1),
                        "\(s.errors)",
                        s.lastLatencyMs.map { "\($0) ms" } ?? "chưa đo",
                    ],
                    header: false, color: app.color(d.id)
                )
            }
            if m.devices.isEmpty {
                Divider().overlay(Palette.hairline)
                Text("Chưa có thiết bị nào được kết nối").font(.footnote).foregroundStyle(Palette.tertiary).padding(14)
            }
        }
        .card()
    }

    private func row(_ cells: [String], header: Bool, color: Color?) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                if let color { StatusDot(color: color) }
                Text(cells[0]).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(1..<cells.count, id: \.self) { i in
                Text(cells[i])
                    .foregroundStyle(cells[i] == "chưa đo" ? Palette.tertiary : (header ? Palette.tertiary : .white))
                    .frame(width: i == 4 ? 64 : 48, alignment: .trailing)
            }
        }
        .font(header ? .caption.weight(.semibold) : .footnote.monospacedDigit())
        .foregroundStyle(header ? Palette.tertiary : .white)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}
