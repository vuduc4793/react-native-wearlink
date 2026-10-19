import SmartWearCore
import SwiftUI

// MARK: - Màu

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255, opacity: alpha
        )
    }
}

enum Palette {
    static let background = Color(hex: 0x050506)
    static let card = Color.white.opacity(0.06)
    static let hairline = Color.white.opacity(0.08)
    static let secondary = Color.white.opacity(0.62)
    static let tertiary = Color.white.opacity(0.38)

    /// Màu nhận diện thiết bị (tiết chế, không tím).
    static let identity: [Color] = [
        Color(hex: 0x5ED6C4), Color(hex: 0xE8B85A), Color(hex: 0x5AA9F0), Color(hex: 0xF0805E),
        Color(hex: 0x8FD46B), Color(hex: 0xF27BA0), Color(hex: 0xB7C4D6),
    ]
}

// MARK: - Nhãn tiếng Việt

extension Capability {
    var title: String {
        switch self {
        case .heartRate: return "Nhịp tim"
        case .spo2: return "SpO2"
        case .temperature: return "Nhiệt độ"
        case .bloodPressure: return "Huyết áp"
        case .stress: return "Stress"
        case .hrv: return "HRV"
        case .bloodSugar: return "Đường huyết"
        case .ecg: return "ECG"
        case .steps: return "Bước chân"
        case .sleep: return "Giấc ngủ"
        case .menstruation: return "Chu kỳ"
        case .gesture: return "Cử chỉ"
        case .met: return "MET"
        case .uricAcid: return "Acid uric"
        case .bloodLipids: return "Mỡ máu"
        case .bodyComposition: return "Thành phần cơ thể"
        }
    }

    var symbol: String {
        switch self {
        case .heartRate: return "heart.fill"
        case .spo2: return "drop.fill"
        case .temperature: return "thermometer.medium"
        case .bloodPressure: return "heart.text.square.fill"
        case .stress: return "gauge.with.dots.needle.33percent"
        case .hrv: return "waveform.path.ecg"
        case .bloodSugar: return "drop.halffull"
        case .ecg: return "waveform.path.ecg.rectangle.fill"
        case .steps: return "figure.walk"
        case .sleep: return "moon.fill"
        case .menstruation: return "calendar"
        case .gesture: return "hand.tap.fill"
        case .met: return "flame.fill"
        case .uricAcid: return "testtube.2"
        case .bloodLipids: return "drop.triangle.fill"
        case .bodyComposition: return "figure.arms.open"
        }
    }

    var tint: Color {
        switch self {
        case .heartRate: return Color(hex: 0xFF4D4D)
        case .spo2: return Color(hex: 0x4DA3FF)
        case .temperature: return Color(hex: 0xFF9F0A)
        case .bloodPressure: return Color(hex: 0xFF5C8A)
        case .stress: return Color(hex: 0x5ED6C4)
        case .hrv: return Color(hex: 0x7DA0FF)
        case .bloodSugar: return Color(hex: 0xFFD60A)
        case .ecg: return Color(hex: 0x30D158)
        case .steps: return Color(hex: 0x30D158)
        case .sleep: return Color(hex: 0x64D2FF)
        case .menstruation: return Color(hex: 0xFF6F91)
        case .gesture: return Color(hex: 0xB7C4D6)
        case .met: return Color(hex: 0xFF9F0A)
        case .uricAcid: return Color(hex: 0xBF5AF2)
        case .bloodLipids: return Color(hex: 0xFFB340)
        case .bodyComposition: return Color(hex: 0x5AC8FA)
        }
    }

    /// Đơn vị hiển thị khi chưa có số đo.
    var defaultUnit: String {
        switch self {
        case .heartRate: return "bpm"
        case .spo2: return "%"
        case .temperature: return "°C"
        case .bloodPressure: return "mmHg"
        case .stress: return "điểm"
        case .hrv: return "ms"
        case .uricAcid: return "µmol/L"
        case .bloodLipids: return "mmol/L"
        case .bodyComposition: return "%"
        default: return ""
        }
    }
}

extension DeviceKind {
    var title: String {
        switch self {
        case .ring: return "Nhẫn"
        case .watch: return "Đồng hồ"
        case .band: return "Vòng tay"
        case .earbuds: return "Tai nghe"
        case .sensor: return "Cảm biến"
        case .unknown: return "Chưa rõ loại"
        }
    }
}

extension ConnectionState {
    var title: String {
        switch self {
        case .connected: return "Đã kết nối"
        case .connecting: return "Đang kết nối…"
        case .disconnecting: return "Đang ngắt…"
        case .disconnected: return "Chưa kết nối"
        }
    }
}

enum Format {
    /// "36,6" (dấu phẩy thập phân kiểu Việt), số nguyên không có phần lẻ.
    static func number(_ v: Double, decimals: Int? = nil) -> String {
        let d = decimals ?? (v.rounded() == v ? 0 : 1)
        return String(format: "%.\(d)f", v).replacingOccurrences(of: ".", with: ",")
    }

    /// Giá trị chính của một kết quả, nil nếu chưa có số.
    static func value(_ r: Reading?) -> String? {
        guard let r else { return nil }
        if let s = r.systolic, let d = r.diastolic { return "\(s)/\(d)" }
        guard let v = r.value else { return nil }
        return number(v, decimals: [.temperature, .met, .bloodLipids, .bodyComposition, .bloodSugar].contains(r.capability) ? 1 : 0)
    }

    static func status(_ r: Reading?) -> String {
        guard let r else { return "chưa đo" }
        switch r.status {
        case .measuring: return "Đang đo…"
        case .notWorn: return r.needsTouch ? "Chưa chạm cảm biến" : "Chưa đeo"
        case .error where r.needsTouch: return "Lỗi: chưa chạm cảm biến"
        case .error: return "Lỗi" + (r.note.map { ": \($0)" } ?? (r.errorCode.map { " (mã \($0))" } ?? ""))
        case .ok: return value(r).map { "\($0) \(r.unit)" } ?? "chưa đo"
        }
    }

    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}

// MARK: - Kính (Liquid Glass thật trên iOS 26, vật liệu mờ trên iOS 17–18)

struct GlassBackground<S: Shape>: ViewModifier {
    var shape: S
    var tint: Color?
    var interactive: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(interactive ? Glass.regular.tint(tint).interactive() : Glass.regular.tint(tint), in: shape)
        } else {
            content
                .background {
                    ZStack {
                        shape.fill(.ultraThinMaterial)
                        if let tint { shape.fill(tint.opacity(0.22)) }
                    }
                }
                .overlay {
                    shape.stroke(
                        LinearGradient(
                            colors: [.white.opacity(0.32), .white.opacity(0.06), .white.opacity(0.14)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.8
                    )
                }
                .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        }
    }
}

extension View {
    func glass<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        modifier(GlassBackground(shape: shape, tint: tint, interactive: interactive))
    }

    func glassCapsule(tint: Color? = nil, interactive: Bool = true) -> some View {
        glass(Capsule(), tint: tint, interactive: interactive)
    }

    /// Thẻ nền tối mờ (không phải kính), dùng cho nội dung trong sheet.
    func card(_ radius: CGFloat = 22) -> some View {
        background(Palette.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// Bọc nhóm các phần tử kính để chúng hoà vào nhau trên iOS 26.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}
