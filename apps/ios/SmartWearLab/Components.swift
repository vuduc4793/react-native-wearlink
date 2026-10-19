import SmartWearCore
import SwiftUI

/// Quả cầu nhận diện thiết bị (placeholder trừu tượng, không vẽ sản phẩm).
struct Orb: View {
    var color: Color
    var size: CGFloat
    var filled: Bool = true

    var body: some View {
        ZStack {
            if filled {
                Circle().fill(
                    RadialGradient(
                        colors: [color.opacity(1).mix(.white, 0.55), color, color.mix(.black, 0.45)],
                        center: .init(x: 0.35, y: 0.3), startRadius: 0, endRadius: size * 0.75
                    )
                )
                .shadow(color: color.opacity(0.45), radius: size * 0.35)
            } else {
                Circle().stroke(color.opacity(0.75), lineWidth: max(1.2, size * 0.06))
                Circle().fill(color.opacity(0.08))
            }
        }
        .frame(width: size, height: size)
    }
}

extension Color {
    func mix(_ other: Color, _ amount: Double) -> Color {
        let a = UIColor(self), b = UIColor(other)
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        a.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        b.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        let t = CGFloat(amount)
        return Color(red: r1 + (r2 - r1) * t, green: g1 + (g2 - g1) * t, blue: b1 + (b2 - b1) * t, opacity: a1)
    }
}

/// Vòng toả ra mỗi khi `trigger` đổi (mỗi gói tin).
struct PulseRing: View {
    var trigger: Int
    var color: Color
    var size: CGFloat
    @State private var scale: CGFloat = 1
    @State private var opacity: Double = 0

    var body: some View {
        Circle()
            .stroke(color, lineWidth: 1.5)
            .frame(width: size, height: size)
            .scaleEffect(scale)
            .opacity(opacity)
            .onChange(of: trigger) {
                scale = 1
                opacity = 0.8
                withAnimation(.easeOut(duration: 0.9)) {
                    scale = 2.1
                    opacity = 0
                }
            }
            .allowsHitTesting(false)
    }
}

struct BatteryLabel: View {
    var level: Int?
    var charging: Bool?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(color)
            Text(level.map { "\($0) %" } ?? "–")
                .monospacedDigit()
        }
        .font(.footnote)
        .foregroundStyle(Palette.secondary)
    }

    private var symbol: String {
        if charging == true { return "battery.100.bolt" }
        guard let level else { return "battery.0" }
        switch level {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }

    private var color: Color {
        guard let level else { return Palette.tertiary }
        return level < 20 ? .red : Palette.secondary
    }
}

/// Cột tín hiệu: mỗi cột là một gói.
struct PacketBars: View {
    var values: [Double]
    var color: Color
    var slots = 28

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width / CGFloat(slots)
            let lo = values.min() ?? 0, hi = values.max() ?? 1
            HStack(alignment: .bottom, spacing: w * 0.35) {
                ForEach(0..<slots, id: \.self) { i in
                    let idx = i - (slots - values.count)
                    let h: CGFloat = idx >= 0 ? CGFloat(0.18 + 0.82 * ((values[idx] - lo) / max(hi - lo, 1))) : 0.06
                    Capsule()
                        .fill(idx >= 0 ? color.opacity(0.35 + 0.65 * Double(idx + 1) / Double(max(values.count, 1))) : Palette.hairline)
                        .frame(width: w * 0.65, height: max(3, geo.size.height * h))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .animation(.easeOut(duration: 0.25), value: values)
        }
    }
}

struct StatusDot: View {
    var color: Color
    var body: some View { Circle().fill(color).frame(width: 7, height: 7) }
}

struct SectionTitle: View {
    var text: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text).font(.title3.weight(.semibold))
            Spacer()
            if let trailing { Text(trailing).font(.footnote).foregroundStyle(Palette.tertiary) }
        }
        .padding(.top, 8)
    }
}

/// Nút trắng nổi bật (hành động chính).
struct PrimaryButton: View {
    var title: String
    var symbol: String?
    var enabled = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol { Image(systemName: symbol).font(.footnote.weight(.bold)) }
                Text(title).font(.body.weight(.semibold))
            }
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Color.white.opacity(enabled ? 1 : 0.35), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// Nút kính nhỏ.
struct GlassButton: View {
    var title: String?
    var symbol: String?
    var tint: Color?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).font(.subheadline.weight(.semibold)) }
                if let title { Text(title).font(.subheadline.weight(.semibold)) }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, title == nil ? 0 : 16)
            .frame(minWidth: 40, minHeight: 40)
            .glassCapsule(tint: tint)
        }
        .buttonStyle(.plain)
    }
}

struct KeyValueRow: View {
    var key: String
    var value: String?
    var mono = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(key).foregroundStyle(Palette.secondary)
            Spacer(minLength: 8)
            Text(value ?? "chưa đọc")
                .font(mono ? .system(.footnote, design: .monospaced) : .body)
                .foregroundStyle(value == nil ? Palette.tertiary : .white)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.subheadline)
        .padding(.vertical, 6)
    }
}
