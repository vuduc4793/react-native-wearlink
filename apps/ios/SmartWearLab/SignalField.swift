import SmartWearCore
import SwiftUI

/// "Trường tín hiệu" kiểu Find My: điện thoại ở tâm, mỗi thiết bị là một quả cầu,
/// càng gần tâm RSSI càng mạnh; quả cầu nhịp theo từng gói tin nhận được.
struct SignalField: View {
    @Environment(AppState.self) private var app

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let center = CGPoint(x: size.width / 2, y: size.height * 0.55)
            ZStack {
                rings(size: size, center: center)
                // Tâm: điện thoại này.
                Circle().fill(.white).frame(width: 12, height: 12)
                    .shadow(color: .white.opacity(0.6), radius: 8)
                    .position(center)
                let items = app.fieldItems
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    orb(item)
                        .position(position(item, index: index, count: items.count, size: size, center: center))
                        .animation(.spring(response: 0.9, dampingFraction: 0.8), value: item.rssi)
                }
            }
        }
    }

    private func rings(size: CGSize, center: CGPoint) -> some View {
        ZStack {
            ForEach(1...4, id: \.self) { i in
                let f = CGFloat(i) / 4
                Ellipse()
                    .stroke(Color.white.opacity(0.10 - Double(i) * 0.015), lineWidth: 1)
                    .frame(width: size.width * 0.92 * f, height: size.height * 0.8 * f)
                    .position(center)
            }
        }
    }

    @ViewBuilder
    private func orb(_ item: FieldItem) -> some View {
        let color = app.color(item.id)
        let d = item.device
        VStack(spacing: 4) {
            ZStack {
                if let d { PulseRing(trigger: d.pulse, color: color, size: 30) }
                Orb(color: color, size: item.connected ? 30 : 22, filled: item.connected)
                if d?.id == app.selectedDeviceId {
                    Circle().stroke(.white.opacity(0.9), lineWidth: 1.5).frame(width: 40, height: 40)
                }
            }
            Text(shortName(item.name))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(item.connected ? 1 : 0.7))
                .lineLimit(1)
            Text(subtitle(item))
                .font(.caption2)
                .foregroundStyle(subtitleColor(item))
                .lineLimit(1)
        }
        .frame(width: 104)
        .contentShape(Rectangle())
        .onTapGesture {
            if let d { app.open(d) } else {
                app.tab = .add
                app.selectedForConnect.insert(item.id)
            }
        }
    }

    private func position(_ item: FieldItem, index: Int, count: Int, size: CGSize, center: CGPoint) -> CGPoint {
        // Góc chia đều theo thứ tự (không chồng nhau), bán kính theo RSSI (-40 dBm gần tâm, -100 dBm ở rìa).
        let seed = item.id.uuidString.unicodeScalars.reduce(UInt32(7)) { ($0 &* 31) &+ $1.value }
        let jitter = Double(seed % 20) - 10
        let angle = (-150 + Double(index) * 360 / Double(max(count, 1)) + jitter) * .pi / 180
        let rssi = Double(item.rssi ?? -85)
        let r = min(1, max(0.45, (-rssi - 35) / 60))
        return CGPoint(
            x: center.x + cos(angle) * r * size.width * 0.40,
            y: center.y + sin(angle) * r * size.height * 0.36
        )
    }

    /// "COROS PACE 3 8E1086" → "COROS PACE 3", "R09_8404" giữ nguyên.
    private func shortName(_ name: String) -> String {
        var parts = name.split(separator: " ").map(String.init)
        if parts.count > 2, let last = parts.last, last.count >= 5, last.allSatisfy(\.isHexDigit) { parts.removeLast() }
        let n = parts.joined(separator: " ")
        return n.count > 13 ? String(n.prefix(12)) + "…" : n
    }

    private func subtitle(_ item: FieldItem) -> String {
        guard let d = item.device else { return item.rssi.map { "\($0) dBm" } ?? "chưa kết nối" }
        if let cap = d.measuring.first ?? d.measurableCapabilities.first(where: { d.latest[$0] != nil }),
           let r = d.latest[cap] {
            return Format.status(r)
        }
        if !d.isConnected { return d.state.title.lowercased() }
        return d.battery.map { "\($0) %" } ?? "đã kết nối"
    }

    private func subtitleColor(_ item: FieldItem) -> Color {
        guard let d = item.device, let cap = d.measuring.first ?? d.measurableCapabilities.first(where: { d.latest[$0] != nil }),
              d.latest[cap]?.status == .ok else { return Palette.secondary }
        return cap.tint
    }
}

/// Vùng màu chuyển động chậm phía sau (màu nhận diện của thiết bị đang kết nối).
struct AmbientBackground: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let colors = app.manager.devices.filter(\.isConnected).map { app.color($0.id) }
        let palette = colors.isEmpty ? [Color(hex: 0x1C2A33), Color(hex: 0x2A2418)] : colors
        TimelineView(.animation(minimumInterval: 1 / 20)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                ZStack {
                    Palette.background
                    ForEach(Array(palette.prefix(4).enumerated()), id: \.offset) { i, c in
                        let phase = t / (14 + Double(i) * 3) + Double(i) * 1.7
                        Circle()
                            .fill(c.opacity(colors.isEmpty ? 0.35 : 0.30))
                            .frame(width: geo.size.width * 0.9, height: geo.size.width * 0.9)
                            .position(
                                x: geo.size.width * (0.5 + 0.32 * cos(phase)),
                                y: geo.size.height * (0.22 + 0.12 * sin(phase * 1.3))
                            )
                    }
                }
                .blur(radius: 70)
            }
        }
        .ignoresSafeArea()
    }
}
