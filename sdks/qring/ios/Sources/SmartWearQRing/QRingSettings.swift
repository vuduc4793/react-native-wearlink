import Foundation
import SmartWearCore

/// Cài đặt QRing (bản Swift của `QRingSettings.kt`, sdks/qring/docs/02-commands.md §4.6–4.11). Phần lớn mục đọc lại
/// được từ thiết bị (`xx 01`), nên driver đọc khi kết nối rồi ghi đúng các byte không đổi (ngưỡng, cờ…) như đã đọc.
/// Giá trị lưu dạng khoá → số nguyên; khung giờ là `<id>.from` / `<id>.to` (phút trong ngày).
public enum QRingSettings {
    public static let device = "Thiết bị"
    public static let health = "Theo dõi sức khoẻ"
    public static let reminders = "Nhắc nhở"
    public static let goals = "Mục tiêu hằng ngày"
    public static let profile = "Hồ sơ cá nhân"

    public static let defaults: [String: Int] = [
        "hrAuto.enabled": 1, "hrAuto.interval": 30, "hrAuto.start": 5,
        "spo2Auto.enabled": 0, "stressAuto.enabled": 0, "hrvAuto.enabled": 0, "hrvAuto.code": 30,
        "tempAuto.enabled": 0, "tempAuto.interval": 30, "tempAuto.start": 5, "tempAuto.remind": 10,
        "goal.steps": 8000, "goal.calories": 300, "goal.distance": 5, "goal.exercise": 30, "goal.sleep": 480,
        "profile.hour12": 0, "profile.imperial": 0, "profile.gender": 0, "profile.age": 30,
        "profile.height": 170, "profile.weight": 65, "profile.warn": 0, "profile.open": 0,
        "dnd.enabled": 0, "dnd.range.from": 22 * 60, "dnd.range.to": 7 * 60,
        "display.raise": 1, "display.left": 1,
        "sedentary.enabled": 0, "sedentary.interval": 60, "sedentary.range.from": 9 * 60, "sedentary.range.to": 18 * 60,
    ]

    static func value(_ v: [String: Int], _ key: String) -> Int { v[key] ?? defaults[key] ?? 0 }

    /// Lệnh đọc cài đặt. Phản hồi đưa vào `parse`.
    /// `ring`: nhẫn (không màn hình, không có DND/nâng tay/nhắc ngồi). R09 không bật cờ `noScreen`, nên driver truyền theo
    /// loại thiết bị.
    public static func reads(_ caps: QRingCapabilities, ring: Bool) -> [Packet] {
        var out: [Packet] = [.of(0x16, 1)]
        if caps.spo2 { out.append(.of(0x2C, 1)) }
        if caps.stress { out.append(.of(0x36, 1)) }
        if caps.hrv { out.append(.of(0x38, 1, 0, 0, 0, 0, 0, 0)) }
        if caps.temperature { out.append(.of(0x3A, 3, 1)) }
        out.append(.of(0x21, 1))
        out.append(.of(0x0A, 1))
        if !ring {
            out.append(.of(0x06, 1))
            out.append(.of(0x05, 1))
            out.append(.of(0x26))
        }
        return out
    }

    private static func le(_ p: [Int], _ i: Int, _ n: Int) -> Int { (0..<n).reduce(0) { $0 | (p[i + $1] << (8 * $1)) } }
    private static func fromBcd(_ v: Int) -> Int { (v >> 4) * 10 + (v & 0x0F) }
    private static func bcd(_ v: Int) -> UInt8 { UInt8(((v / 10) << 4) | (v % 10)) }

    /// Giải mã phản hồi đọc `command` (payload 14 byte) thành các giá trị.
    public static func parse(_ command: UInt8, _ p: [Int]) -> [String: Int] {
        switch command {
        case 0x16:
            guard p[0] == 1 else { return [:] }
            return ["hrAuto.enabled": p[1] == 1 ? 1 : 0, "hrAuto.interval": p[2], "hrAuto.start": p[3] > 0 ? p[3] : 5,
                    "hrAuto.low": p[4], "hrAuto.high": p[5], "hrAuto.switch": p[6]]
        case 0x2C: return ["spo2Auto.enabled": p[1] == 1 ? 1 : 0, "spo2Auto.interval": p[2]]
        case 0x36: return ["stressAuto.enabled": p[1] == 1 ? 1 : 0]
        case 0x38: return ["hrvAuto.enabled": p[1] == 1 ? 1 : 0, "hrvAuto.code": p[3] > 0 ? p[3] : 30]
        case 0x3A:
            guard p[0] == 3 else { return [:] }
            return ["tempAuto.enabled": p[2] == 1 ? 1 : 0, "tempAuto.interval": p[3], "tempAuto.start": p[4],
                    "tempAuto.remind": p[5], "tempAuto.flags": p[6], "tempAuto.custom": p[7]]
        case 0x21:
            return ["goal.steps": le(p, 1, 3), "goal.calories": le(p, 4, 3) / 1000, "goal.distance": le(p, 7, 3) / 1000,
                    "goal.exercise": le(p, 10, 2), "goal.sleep": le(p, 12, 2)].filter { $0.value > 0 }
        case 0x0A:
            let always: Set = ["profile.hour12", "profile.imperial", "profile.gender", "profile.warn", "profile.open"]
            return ["profile.hour12": p[1], "profile.imperial": p[2], "profile.gender": p[3], "profile.age": p[4],
                    "profile.height": p[5], "profile.weight": p[6], "profile.warn": p[9], "profile.open": p[10]]
                .filter { $0.value > 0 || always.contains($0.key) }
        case 0x06:
            return ["dnd.enabled": p[1] == 1 ? 1 : 0, "dnd.range.from": p[2] * 60 + p[3], "dnd.range.to": p[4] * 60 + p[5]]
        case 0x05: return ["display.raise": p[1] == 1 ? 1 : 0, "display.left": p[2] & 1 != 0 ? 1 : 0]
        case 0x26:
            return ["sedentary.enabled": p[4] != 0 ? 1 : 0,
                    "sedentary.range.from": fromBcd(p[0]) * 60 + fromBcd(p[1]), "sedentary.range.to": fromBcd(p[2]) * 60 + fromBcd(p[3]),
                    "sedentary.interval": [30, 60, 90].contains(p[5]) ? p[5] : 60]
        default: return [:]
        }
    }

    public static func controls(_ caps: QRingCapabilities, _ v: [String: Int], ring: Bool) -> [DeviceControl] {
        var out: [DeviceControl] = []
        func on(_ k: String) -> Bool { value(v, k) != 0 }
        func toggle(_ id: String, _ group: String, _ title: String, detail: String? = nil, enabled: Bool = true) {
            out.append(DeviceControl(id, group: group, title: title, kind: .toggle, value: .bool(on(id)), detail: detail, enabled: enabled))
        }
        func number(_ id: String, _ group: String, _ title: String, _ min: Int, _ max: Int, _ step: Int, _ unit: String, enabled: Bool = true) {
            out.append(DeviceControl(id, group: group, title: title, kind: .number, value: .number(value(v, id)), min: min, max: max, step: step, unit: unit, enabled: enabled))
        }
        func range(_ id: String, _ group: String, _ title: String, enabled: Bool = true) {
            out.append(DeviceControl(id, group: group, title: title, kind: .timeRange, value: .timeRange(from: value(v, "\(id).from"), to: value(v, "\(id).to")), enabled: enabled))
        }

        out.append(DeviceControl("find.start", group: device, title: ring ? "Tìm nhẫn" : "Tìm vòng", kind: .action, detail: "Thiết bị rung để bạn tìm"))
        if !ring { toggle("display.raise", device, "Nâng tay sáng màn hình") }
        toggle("profile.hour12", device, "Định dạng 12 giờ")
        toggle("profile.imperial", device, "Đơn vị Anh (dặm, pound)")

        toggle("hrAuto.enabled", health, "Đo nhịp tim tự động")
        number("hrAuto.interval", health, "Chu kỳ đo nhịp tim", 5, 60, 5, "phút", enabled: on("hrAuto.enabled"))
        if caps.spo2 { toggle("spo2Auto.enabled", health, "Đo SpO2 tự động") }
        if caps.stress { toggle("stressAuto.enabled", health, "Đo căng thẳng tự động") }
        if caps.hrv { toggle("hrvAuto.enabled", health, "Đo HRV tự động") }
        if caps.temperature { toggle("tempAuto.enabled", health, "Đo nhiệt độ tự động") }

        if !ring {
            let sit = on("sedentary.enabled")
            toggle("sedentary.enabled", reminders, "Nhắc vận động", detail: "Rung khi ngồi lâu")
            out.append(DeviceControl("sedentary.interval", group: reminders, title: "Nhắc sau khi ngồi", kind: .choice,
                                     value: .number(max(0, [30, 60, 90].firstIndex(of: value(v, "sedentary.interval")) ?? 0)),
                                     options: ["30 phút", "60 phút", "90 phút"], enabled: sit))
            range("sedentary.range", reminders, "Khung giờ nhắc vận động", enabled: sit)
            toggle("dnd.enabled", reminders, "Không làm phiền theo giờ")
            range("dnd.range", reminders, "Khung giờ không làm phiền", enabled: on("dnd.enabled"))
        }

        number("goal.steps", goals, "Bước chân", 1000, 50_000, 500, "bước")
        number("goal.calories", goals, "Calo", 50, 3000, 50, "kcal")
        number("goal.distance", goals, "Quãng đường", 1, 42, 1, "km")
        number("goal.exercise", goals, "Thời gian vận động", 10, 300, 10, "phút")
        number("goal.sleep", goals, "Giấc ngủ", 240, 720, 30, "phút")

        out.append(DeviceControl("profile.gender", group: profile, title: "Giới tính", kind: .choice, value: .number(value(v, "profile.gender")), options: ["Nam", "Nữ"]))
        number("profile.age", profile, "Tuổi", 5, 100, 1, "tuổi")
        number("profile.height", profile, "Chiều cao", 100, 230, 1, "cm")
        number("profile.weight", profile, "Cân nặng", 20, 200, 1, "kg")
        return out
    }

    /// Áp thay đổi của mục `id`. CHOICE chu kỳ nhắc ngồi lưu số phút.
    public static func apply(_ v: [String: Int], _ id: String, _ value: ControlValue) -> [String: Int] {
        var v = v
        switch value {
        case .bool(let on): v[id] = on ? 1 : 0
        case .number(let n): v[id] = id == "sedentary.interval" ? ([30, 60, 90].indices.contains(n) ? [30, 60, 90][n] : 60) : n
        case .timeRange(let from, let to):
            v["\(id).from"] = from
            v["\(id).to"] = to
        }
        return v
    }

    private static func le(_ value: Int, _ n: Int) -> [UInt8] { (0..<n).map { UInt8((value >> (8 * $0)) & 0xFF) } }
    private static func b(_ v: Int) -> UInt8 { UInt8(truncatingIfNeeded: v) }

    /// Gói ghi cho mục `id` (đã áp vào `v`); nil nếu mục không cần lệnh.
    public static func write(_ id: String, _ v: [String: Int]) -> Packet? {
        func g(_ k: String) -> Int { value(v, k) }
        switch id.split(separator: ".").first.map(String.init) ?? id {
        case "find": return find
        case "hrAuto":
            return .of(0x16, 2, g("hrAuto.enabled") != 0 ? 1 : 2, b(g("hrAuto.interval")), b(g("hrAuto.start")),
                       b(g("hrAuto.low")), b(g("hrAuto.high")), b(g("hrAuto.switch")))
        case "spo2Auto":
            return g("spo2Auto.interval") > 0 ? .of(0x2C, 2, b(g("spo2Auto.enabled")), b(g("spo2Auto.interval")))
                : .of(0x2C, 2, b(g("spo2Auto.enabled")))
        case "stressAuto": return .of(0x36, 2, b(g("stressAuto.enabled")))
        case "hrvAuto": return .of(0x38, 2, b(g("hrvAuto.enabled")), 0x0A, b(g("hrvAuto.code")), 0, 0, 0)
        case "tempAuto":
            return .of(0x3A, 3, 2, b(g("tempAuto.enabled")), b(g("tempAuto.interval")), b(g("tempAuto.start")),
                       b(g("tempAuto.remind")), b(g("tempAuto.flags")), b(g("tempAuto.custom")))
        // Calo gửi theo cal, quãng đường theo mét (`GoalSettingViewModel`: ×1000), phút u16 LE.
        case "goal":
            var p: [UInt8] = [2]
            p += le(g("goal.steps"), 3)
            p += le(g("goal.calories") * 1000, 3)
            p += le(g("goal.distance") * 1000, 3)
            p += le(g("goal.exercise"), 2)
            p += le(g("goal.sleep"), 2)
            return .of(0x21, payload: p)
        case "profile":
            return .of(0x0A, 2, b(g("profile.hour12")), b(g("profile.imperial")), b(g("profile.gender")), b(g("profile.age")),
                       b(g("profile.height")), b(g("profile.weight")), 120, 90, b(g("profile.warn")), b(g("profile.open")))
        case "dnd":
            let f = g("dnd.range.from"), t = g("dnd.range.to")
            return .of(0x06, 2, g("dnd.enabled") != 0 ? 1 : 2, b(f / 60), b(f % 60), b(t / 60), b(t % 60))
        case "display": return .of(0x05, 2, g("display.raise") != 0 ? 1 : 2, g("display.left") != 0 ? 1 : 2)
        case "sedentary":
            let f = g("sedentary.range.from"), t = g("sedentary.range.to")
            return .of(0x25, bcd(f / 60), bcd(f % 60), bcd(t / 60), bcd(t % 60), g("sedentary.enabled") != 0 ? 0x7F : 0, b(g("sedentary.interval")))
        default: return nil
        }
    }

    /// `50 55 AA`: thiết bị rung (`FindDeviceReq`).
    public static let find: Packet = .of(0x50, 0x55, 0xAA)
}
