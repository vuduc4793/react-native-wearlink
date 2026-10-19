import Foundation
import SmartWearCore

/// Cài đặt lưu cục bộ theo thiết bị (hồ sơ, mục tiêu, nâng tay, độ sáng, nhắc ngồi lâu `E1`): khoá → số nguyên, như
/// `UteSettings`. Các mục vòng tay đọc lại được (`B8`, `AD`, `E7`, `AC`, hiệu chuẩn) lấy thẳng từ vòng tay
/// (`VeepooCustomSettings`, `VeepooMessageSwitches`, `VeepooDeviceState`).
/// Khung giờ lưu 2 khoá `<id>.from` / `<id>.to` (phút trong ngày).
public struct VeepooSettings: Equatable, Sendable {
    public var values: [String: Int]

    public init(_ values: [String: Int] = [:]) { self.values = values }

    public subscript(_ key: String) -> Int { values[key] ?? Self.defaults[key] ?? 0 }
    public func on(_ key: String) -> Bool { self[key] != 0 }

    public func with(_ id: String, _ value: ControlValue) -> VeepooSettings {
        var v = values
        switch value {
        case .bool(let on): v[id] = on ? 1 : 0
        case .number(let n): v[id] = n
        case .timeRange(let from, let to):
            v["\(id).from"] = from
            v["\(id).to"] = to
        }
        return VeepooSettings(v)
    }

    /// "k=v;k=v" để lưu UserDefaults (cùng định dạng với `UteSettings`).
    public func encode() -> String { values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ";") }

    public static func decode(_ s: String?) -> VeepooSettings {
        var v: [String: Int] = [:]
        for e in (s ?? "").split(separator: ";") {
            let kv = e.split(separator: "=", maxSplits: 1)
            if kv.count == 2, let n = Int(kv[1]), !kv[0].isEmpty { v[String(kv[0])] = n }
        }
        return VeepooSettings(v)
    }

    public static let defaults: [String: Int] = [
        "profile.height": 170, "profile.weight": 65, "profile.age": 30, "profile.gender": 0,
        "goal.steps": 8000, "goal.sleep": 8,
        "display.raise": 1, "display.raise.range.from": 8 * 60, "display.raise.range.to": 22 * 60,
        "display.brightness": 3, "display.screenOn": 6,
        "sedentary.enabled": 0, "sedentary.interval": 60, "sedentary.range.from": 9 * 60, "sedentary.range.to": 18 * 60,
    ]

    /// Ngôn ngữ vòng tay (`F4`, `jf/w0.java:317-730`): (tên, mã), cùng thứ tự với `VeepooControls.LANGUAGES` Android; giá trị
    /// control `language` là chỉ số trong bảng này.
    public static let languages: [(name: String, code: Int)] = [
        ("Tiếng Việt", 10), ("English", 2), ("中文", 1), ("日本語", 3), ("한국어", 4), ("Deutsch", 5), ("Русский", 6),
        ("Español", 7), ("Italiano", 8), ("Français", 9), ("Português", 11), ("ไทย", 13),
    ]
}

