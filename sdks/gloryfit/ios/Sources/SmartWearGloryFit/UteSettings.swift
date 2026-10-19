import Foundation
import SmartWearCore

/// Cài đặt đồng hồ UTE (bản Swift của `UteSettings.kt`). Đồng hồ không cho đọc lại phần lớn cài đặt (app GloryFit cũng
/// chỉ lưu cục bộ rồi ghi xuống), nên SDK lưu theo thiết bị dạng khoá → số nguyên và gửi lệnh khi người dùng đổi.
/// Khung giờ lưu 2 khoá `<id>.from` / `<id>.to` (phút trong ngày).
///
/// Định dạng lệnh: `WriteCommandToBLE` (GloryFit 4.0.12) và SDK Realtek trong GloryFitPro 1.9; cờ tính năng theo
/// docs/feature-matrix.md.
public struct UteSettings: Equatable, Sendable {
    public var values: [String: Int]

    public init(_ values: [String: Int] = [:]) { self.values = values }

    public subscript(_ key: String) -> Int { values[key] ?? Self.defaults[key] ?? 0 }
    public func on(_ key: String) -> Bool { self[key] != 0 }

    /// Ngày bắt đầu kỳ kinh gần nhất (mặc định hôm nay), `period.start` là số ngày kể từ 1970-01-01.
    public func periodStart(today: Date, calendar: Calendar) -> Date {
        guard let d = values["period.start"] else { return calendar.startOfDay(for: today) }
        let c = Self.utc.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: TimeInterval(d) * 86_400))
        return calendar.date(from: DateComponents(year: c.year, month: c.month, day: c.day)) ?? today
    }

    /// "Cách đây n ngày" được lưu thành ngày tuyệt đối (`period.start`) để không trôi theo thời gian.
    public func with(_ id: String, _ value: ControlValue, today: Date = Date(), calendar: Calendar = .current) -> UteSettings {
        var v = values
        switch value {
        case .bool(let on): v[id] = on ? 1 : 0
        case .number(let n) where id == "period.daysAgo":
            let start = calendar.date(byAdding: .day, value: -n, to: calendar.startOfDay(for: today)) ?? today
            v["period.start"] = Self.epochDay(start, calendar: calendar)
        case .number(let n): v[id] = n
        case .timeRange(let from, let to):
            v["\(id).from"] = from
            v["\(id).to"] = to
        }
        return UteSettings(v)
    }

    /// Ngày lịch (theo `calendar`) → số ngày từ 1970-01-01, như `LocalDate.toEpochDay` Android.
    static func epochDay(_ date: Date, calendar: Calendar) -> Int {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        let d = utc.date(from: DateComponents(year: c.year, month: c.month, day: c.day))!
        return Int((d.timeIntervalSince1970 / 86_400).rounded(.down))
    }

    private static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// "k=v;k=v" để lưu UserDefaults (cùng định dạng với Android).
    public func encode() -> String { values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ";") }

    public static func decode(_ s: String?) -> UteSettings {
        var v: [String: Int] = [:]
        for e in (s ?? "").split(separator: ";") {
            let kv = e.split(separator: "=", maxSplits: 1)
            if kv.count == 2, let n = Int(kv[1]), !kv[0].isEmpty { v[String(kv[0])] = n }
        }
        return UteSettings(v)
    }

    public static let defaults: [String: Int] = [
        "profile.height": 170, "profile.weight": 65, "profile.age": 30, "profile.gender": 0,
        "display.raise": 1, "display.screenOff": 5,
        "unit.hour12": 0, "unit.fahrenheit": 0,
        "goal.steps": 8000, "goal.calories": 300, "goal.distance": 3,
        "hr24.enabled": 1, "hr24.interval": 5,
        "hrHigh.enabled": 0, "hrHigh.value": 160, "hrLow.enabled": 0, "hrLow.value": 45,
        "spo2Auto.enabled": 0, "spo2Auto.interval": 60,
        "sedentary.enabled": 0, "sedentary.interval": 60, "sedentary.range.from": 9 * 60,
        "sedentary.range.to": 18 * 60, "sedentary.lunch": 1,
        "drink.enabled": 0, "drink.interval": 60, "drink.range.from": 8 * 60, "drink.range.to": 20 * 60,
        "dnd.scheduled": 0, "dnd.range.from": 22 * 60, "dnd.range.to": 7 * 60,
        "dnd.messages": 1, "dnd.vibration": 1, "dnd.endCall": 0,
        "spo2Range.enabled": 0, "spo2Range.range.from": 22 * 60, "spo2Range.range.to": 7 * 60,
        "hr24Range.enabled": 0, "hr24Range.range.from": 0, "hr24Range.range.to": 23 * 60 + 59,
        "raiseRange.enabled": 0, "raiseRange.range.from": 8 * 60, "raiseRange.range.to": 22 * 60,
        "findPhone.enabled": 1, "language": 0,
        "period.enabled": 0, "period.duration": 5, "period.cycle": 28,
    ]

    /// Ngôn ngữ đồng hồ (`BandLanguagePage.BAND_LANGUAGE_*`); mục 0 = giữ nguyên.
    public static let languages: [(name: String, code: Int)] = [
        ("Giữ nguyên", 0), ("Tiếng Việt", 99), ("English", 2), ("中文", 1), ("日本語", 4), ("한국어", 3),
        ("Français", 7), ("Deutsch", 5), ("Español", 6), ("Italiano", 8), ("ไทย", 21),
        ("Português", 9), ("Polski", 13), ("Русский", 14), ("Nederlands", 15),
    ]

    /// Ngôn ngữ đồng hồ hỗ trợ: 5 mặt nạ 24 bit đọc bằng `AF AA` (lưu ở `language.m1`…`m5`), nhóm g bit k ⇒ mã
    /// (g−1)·24 + k + 1 (GloryFitPro `LanguageUtils` + `DeviceLanguageType`). Rỗng = chưa đọc.
    public var watchLanguages: Set<Int> {
        var out = Set<Int>()
        for g in 1...5 {
            let m = self["language.m\(g)"]
            for k in 0..<24 where m & (1 << k) != 0 { out.insert((g - 1) * 24 + k + 1) }
        }
        return out
    }

    /// Lựa chọn ngôn ngữ (mục `language` là chỉ số trong danh sách này): như Pro, chỉ những ngôn ngữ đồng hồ hỗ trợ.
    public var languageChoices: [(name: String, code: Int)] {
        let supported = watchLanguages
        guard !supported.isEmpty else { return Self.languages }
        let known = Self.languages.dropFirst().filter { supported.contains($0.code) }
        let unnamed = supported.subtracting(known.map(\.code)).sorted().map { (name: "Mã \($0)", code: $0) }
        return [Self.languages[0]] + known + unnamed
    }

    /// Ghi kết quả `AF AA` (ngôn ngữ hiện tại + mặt nạ) vào cài đặt; mục chọn trỏ đúng ngôn ngữ đang dùng.
    public func withWatchLanguages(current: Int, masks: [Int]) -> UteSettings {
        var v = values
        for (i, m) in masks.prefix(5).enumerated() { v["language.m\(i + 1)"] = m }
        let s = UteSettings(v)
        v["language"] = s.languageChoices.firstIndex { $0.code == current } ?? 0
        return UteSettings(v)
    }
}

/// Cờ tính năng → mục cài đặt, và mục cài đặt → gói lệnh (bản Swift của `UteControls` Android).
public enum UteControls {
    public static let device = "Thiết bị"
    public static let health = "Theo dõi sức khoẻ"
    public static let reminders = "Nhắc nhở"
    public static let goals = "Mục tiêu hằng ngày"
    public static let profile = "Hồ sơ cá nhân"
    public static let cycle = "Chu kỳ kinh nguyệt"
    public static let shortcutGroup = "Phím tắt trên đồng hồ"
    public static let data = "Dữ liệu trên đồng hồ"

    public static func controls(_ f: Ute.Features, _ s: UteSettings, today: Date = Date(), calendar: Calendar = .current) -> [DeviceControl] {
        var out: [DeviceControl] = []
        func toggle(_ id: String, _ group: String, _ title: String, detail: String? = nil, enabled: Bool = true) {
            out.append(DeviceControl(id, group: group, title: title, kind: .toggle, value: .bool(s.on(id)), detail: detail, enabled: enabled))
        }
        func number(_ id: String, _ group: String, _ title: String, _ min: Int, _ max: Int, _ step: Int, _ unit: String, enabled: Bool = true) {
            out.append(DeviceControl(id, group: group, title: title, kind: .number, value: .number(s[id]), min: min, max: max, step: step, unit: unit, enabled: enabled))
        }
        func range(_ id: String, _ group: String, _ title: String, enabled: Bool = true) {
            out.append(DeviceControl(id, group: group, title: title, kind: .timeRange, value: .timeRange(from: s["\(id).from"], to: s["\(id).to"]), enabled: enabled))
        }
        func choice(_ id: String, _ group: String, _ title: String, _ options: [String]) {
            out.append(DeviceControl(id, group: group, title: title, kind: .choice, value: .number(s[id]), options: options))
        }

        out.append(DeviceControl("find.start", group: device, title: "Tìm đồng hồ", kind: .action, detail: "Đồng hồ rung để bạn tìm"))
        if f.findPhone { toggle("findPhone.enabled", device, "Tìm điện thoại từ đồng hồ", detail: "Điện thoại đổ chuông khi bấm trên đồng hồ") }
        if f.raiseToWake {
            toggle("display.raise", device, "Nâng tay sáng màn hình")
            // `69 AB 01 05` chỉ có trong SDK, GloryFitPro không gọi cho RK; chưa kiểm trên Y25 (doc 10 §3 P2 #22).
            toggle("raiseRange.enabled", device, "Nâng tay sáng màn chỉ trong khung giờ", detail: "Chưa kiểm trên đồng hồ",
                   enabled: s.on("display.raise"))
            range("raiseRange.range", device, "Khung giờ nâng tay sáng màn", enabled: s.on("display.raise") && s.on("raiseRange.enabled"))
        }
        number("display.screenOff", device, "Thời gian sáng màn hình", 5, 30, 5, "giây")
        toggle("unit.hour12", device, "Định dạng 12 giờ")
        if f.tempUnit { toggle("unit.fahrenheit", device, "Nhiệt độ theo °F") }
        if f.language { choice("language", device, "Ngôn ngữ đồng hồ", s.languageChoices.map(\.name)) }

        if f.heartRate24h {
            toggle("hr24.enabled", health, "Đo nhịp tim tự động", detail: "Đồng hồ tự đo theo chu kỳ, cả khi app tắt")
            number("hr24.interval", health, "Chu kỳ đo nhịp tim", 5, 60, 5, "phút", enabled: s.on("hr24.enabled"))
            toggle("hr24Range.enabled", health, "Đo nhịp tim tự động chỉ trong khung giờ", detail: "Lệnh F7 0F, chưa kiểm trên đồng hồ",
                   enabled: s.on("hr24.enabled"))
            range("hr24Range.range", health, "Khung giờ đo nhịp tim", enabled: s.on("hr24.enabled") && s.on("hr24Range.enabled"))
        }
        if f.hrHighAlert {
            toggle("hrHigh.enabled", health, "Cảnh báo nhịp tim cao")
            number("hrHigh.value", health, "Ngưỡng nhịp tim cao", 100, 200, 5, "bpm", enabled: s.on("hrHigh.enabled"))
        }
        if f.hrLowAlert {
            toggle("hrLow.enabled", health, "Cảnh báo nhịp tim thấp")
            number("hrLow.value", health, "Ngưỡng nhịp tim thấp", 30, 60, 5, "bpm", enabled: s.on("hrLow.enabled"))
        }
        if f.spo2Auto {
            toggle("spo2Auto.enabled", health, "Đo SpO2 tự động")
            number("spo2Auto.interval", health, "Chu kỳ đo SpO2", 10, 240, 10, "phút", enabled: s.on("spo2Auto.enabled"))
            toggle("spo2Range.enabled", health, "Đo SpO2 tự động chỉ trong khung giờ", enabled: s.on("spo2Auto.enabled"))
            range("spo2Range.range", health, "Khung giờ đo SpO2", enabled: s.on("spo2Auto.enabled") && s.on("spo2Range.enabled"))
        }

        if f.sedentary {
            let on = s.on("sedentary.enabled")
            toggle("sedentary.enabled", reminders, "Nhắc vận động", detail: "Rung khi ngồi lâu")
            number("sedentary.interval", reminders, "Nhắc sau khi ngồi", 30, 180, 15, "phút", enabled: on)
            if f.sedentaryRange {
                range("sedentary.range", reminders, "Khung giờ nhắc vận động", enabled: on)
                toggle("sedentary.lunch", reminders, "Không nhắc giờ nghỉ trưa (12:00–14:00)", enabled: on)
            }
        }
        if f.drink {
            let on = s.on("drink.enabled")
            toggle("drink.enabled", reminders, "Nhắc uống nước")
            number("drink.interval", reminders, "Nhắc mỗi", 30, 240, 15, "phút", enabled: on)
            range("drink.range", reminders, "Khung giờ nhắc uống nước", enabled: on)
        }
        if f.dnd {
            toggle("dnd.scheduled", reminders, "Không làm phiền theo giờ")
            range("dnd.range", reminders, "Khung giờ không làm phiền", enabled: s.on("dnd.scheduled"))
            toggle("dnd.messages", reminders, "Khi không làm phiền: chặn thông báo")
            toggle("dnd.vibration", reminders, "Khi không làm phiền: tắt rung")
            if f.hangup {
                // Bit 3 của `D7` (GloryFitPro `EndCallUtil`): đồng hồ hiện nút từ chối, bấm thì gửi `D1 02`.
                toggle("dnd.endCall", reminders, "Từ chối cuộc gọi trên đồng hồ",
                       detail: "iOS: app không cúp được cuộc gọi; khi đã ghép đôi, từ chối đi qua ANCS")
            }
        }

        number("goal.steps", goals, "Bước chân", 1000, 50_000, 500, "bước")
        if f.goals {
            number("goal.calories", goals, "Calo", 50, 3000, 50, "kcal")
            number("goal.distance", goals, "Quãng đường", 1, 42, 1, "km")
        }

        choice("profile.gender", profile, "Giới tính", ["Nam", "Nữ"])
        number("profile.age", profile, "Tuổi", 5, 100, 1, "tuổi")
        number("profile.height", profile, "Chiều cao", 100, 230, 1, "cm")
        number("profile.weight", profile, "Cân nặng", 20, 200, 1, "kg")

        if f.period {
            let on = s.on("period.enabled")
            toggle("period.enabled", cycle, "Theo dõi chu kỳ trên đồng hồ")
            let start = s.periodStart(today: today, calendar: calendar)
            let daysAgo = max(0, calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: today)).day ?? 0)
            out.append(DeviceControl("period.daysAgo", group: cycle, title: "Kỳ gần nhất bắt đầu cách đây", kind: .number,
                                     value: .number(daysAgo), min: 0, max: 60, unit: "ngày", enabled: on))
            number("period.duration", cycle, "Số ngày hành kinh", 2, 15, 1, "ngày", enabled: on)
            number("period.cycle", cycle, "Độ dài chu kỳ", 15, 60, 1, "ngày", enabled: on)
        }
        // Phím tắt nhanh (`BE 01/02`, đọc lúc kết nối): chỉ hiển thị, đổi bằng phím tắt trên đồng hồ. GloryFitPro ẩn cài
        // đặt trùng phím tắt (`RkSupportUtils:226-266`); ở đây giữ cài đặt và ghi chú.
        let shortcuts = UteSystem.Shortcuts(support: s["shortcut.support"], status: s["shortcut.status"])
        for sc in shortcuts.available {
            out.append(DeviceControl("shortcut.\(sc.rawValue)", group: shortcutGroup, title: sc.title, kind: .toggle,
                                     value: .bool(shortcuts.on(sc)), detail: "Chỉ đọc: đổi bằng phím tắt trên đồng hồ", enabled: false))
        }

        if f.contacts && UteSystem.contactsClearSupported(f) {
            out.append(DeviceControl("contacts.clear", group: data, title: "Xoá danh bạ trên đồng hồ", kind: .action,
                                     detail: "Lệnh 37 BA", confirm: "Xoá toàn bộ danh bạ đã ghi trên đồng hồ?"))
        }
        out.append(DeviceControl("data.reset", group: data, title: "Xoá dữ liệu đồng hồ", kind: .action,
                                 detail: "Lệnh AD: xoá dữ liệu sức khoẻ, bài tập trên đồng hồ (khôi phục gốc)",
                                 confirm: "Xoá toàn bộ dữ liệu trên đồng hồ? Không khôi phục được."))
        return out
    }

    /// Mục chỉ đọc (không gửi lệnh, không lưu).
    public static func readOnly(_ id: String) -> Bool { id.hasPrefix("shortcut.") }

    /// Gói lệnh cần gửi khi mục `id` đổi (đã áp vào `s`). Mục không cần lệnh trả về rỗng.
    public static func commands(_ id: String, _ f: Ute.Features, _ s: UteSettings, today: Date = Date(), calendar: Calendar = .current) -> [[UInt8]] {
        let key = id.split(separator: ".").first.map(String.init) ?? id
        switch true {
        case ["profile", "display", "hrHigh", "hrLow"].contains(key) || id == "unit.fahrenheit": return [userInfo(s)]
        case id == "goal.steps": return [userInfo(s)] + (f.goals ? [target(4, s["goal.steps"], size: 4)] : [])
        case id == "goal.calories": return [target(3, s["goal.calories"], size: 2)]
        case id == "goal.distance": return [target(5, s["goal.distance"] * 1000, size: 4)]
        case id == "unit.hour12": return [units(s)]
        case key == "hr24": return heartRate24h(s)
        case key == "spo2Auto":
            let i = s["spo2Auto.interval"]
            return [[0x34, 0x03, b(s["spo2Auto.enabled"]), b(i >> 8), b(i)]]
        case key == "sedentary": return [reminder(0xD3, "sedentary", s, withRange: f.sedentaryRange)]
        case key == "drink": return [reminder(0xD4, "drink", s, withRange: true)]
        case key == "dnd": return [dnd(s)]
        case key == "spo2Range": return [window(0x34, 0x04, "spo2Range", s)]
        case key == "hr24Range": return [window(0xF7, 0x0F, "hr24Range", s)]
        case key == "raiseRange":
            let from = s["raiseRange.range.from"], to = s["raiseRange.range.to"]
            return [[0x69, 0xAB, 0x01, 0x05, b(s["raiseRange.enabled"]), b(from / 60), b(from % 60), b(to / 60), b(to % 60)]]
        case key == "findPhone": return [[0xD1, 0x0A, b(s["findPhone.enabled"])]]
        case key == "language":
            let i = s["language"], choices = s.languageChoices
            guard choices.indices.contains(i), choices[i].code > 0 else { return [] }
            return [[0xAF, 0xAB, b(choices[i].code)]]
        case key == "period": return [period(s, today: today, calendar: calendar)]
        default: return []
        }
    }

    static func b(_ v: Int) -> UInt8 { UInt8(truncatingIfNeeded: v) }

    /// `A9`: hồ sơ, mục tiêu bước, màn hình, ngưỡng nhịp tim, đơn vị nhiệt.
    public static func userInfo(_ s: UteSettings) -> [UInt8] {
        Ute.userInfo(
            heightCm: s["profile.height"], weightKg: s["profile.weight"], screenOffSec: s["display.screenOff"],
            stepGoal: s["goal.steps"], raiseToWake: s.on("display.raise"), age: s["profile.age"], male: s["profile.gender"] == 0,
            hrHighAlert: s.on("hrHigh.enabled") ? s["hrHigh.value"] : nil,
            hrLowAlert: s.on("hrLow.enabled") ? s["hrLow.value"] : nil,
            fahrenheit: s.on("unit.fahrenheit")
        )
    }

    /// `A0 unit hour`: unit 1 = mét, hour 1 = 24 giờ, 2 = 12 giờ (`setDeviceUnitHourFormat`).
    public static func units(_ s: UteSettings) -> [UInt8] { [0xA0, 0x01, s.on("unit.hour12") ? 0x02 : 0x01] }

    /// `F7 01` + `F7 09 01 mm` khi bật, `F7 02` khi tắt.
    public static func heartRate24h(_ s: UteSettings) -> [[UInt8]] {
        s.on("hr24.enabled") ? [Ute.hr24Enable, Ute.heartRate24hInterval(minutes: s["hr24.interval"])] : [[0xF7, 0x02]]
    }

    /// `3F type en value` (`setTodayTarget`): 4 = bước (u32), 3 = kcal (u16), 5 = mét (u32).
    public static func target(_ type: Int, _ value: Int, size: Int) -> [UInt8] {
        [0x3F, b(type), 0x01] + (0..<size).map { b(value >> (8 * (size - 1 - $0))) }
    }

    /// `D3`/`D4 en interval 02 03 01 00 [fromH fromM toH toM lunch]` (nhắc vận động / uống nước).
    public static func reminder(_ op: UInt8, _ id: String, _ s: UteSettings, withRange: Bool) -> [UInt8] {
        let head: [UInt8] = [op, b(s["\(id).enabled"]), b(s["\(id).interval"]), 0x02, 0x03, 0x01, 0x00]
        guard withRange else { return head }
        let from = s["\(id).range.from"], to = s["\(id).range.to"]
        let lunch = op == 0xD3 ? s["sedentary.lunch"] : 0
        return head + [b(from / 60), b(from % 60), b(to / 60), b(to % 60), b(lunch)]
    }

    /// `D7 mask fromH fromM toH toM timed`: mask = cúp máy·8 + thông báo·4 + rung·2 (SDK Realtek bỏ bit màn hình,
    /// `T:4029-4070`). Bit 3 (`dnd.endCall`) = đồng hồ cho từ chối cuộc gọi, như Android.
    public static func dnd(_ s: UteSettings) -> [UInt8] {
        let mask = (s.on("dnd.endCall") ? 8 : 0) | (s.on("dnd.messages") ? 4 : 0) | (s.on("dnd.vibration") ? 2 : 0)
        let from = s["dnd.range.from"], to = s["dnd.range.to"]
        return [0xD7, b(mask), b(from / 60), b(from % 60), b(to / 60), b(to % 60), b(s["dnd.scheduled"])]
    }

    /// Khung giờ `op sub en fromH fromM toH toM`: SpO2 tự động `34 04` (`T:3264-3279`), HR 24h `F7 0F`
    /// (`W:721-735` `syncRateTimedTestTimePeriod`).
    public static func window(_ op: UInt8, _ sub: UInt8, _ id: String, _ s: UteSettings) -> [UInt8] {
        let from = s["\(id).range.from"], to = s["\(id).range.to"]
        return [op, sub, b(s["\(id).enabled"]), b(from / 60), b(from % 60), b(to / 60), b(to % 60)]
    }

    /// `29 en YYYY MM DD duration cycle` (`setPhysiologicalPeriod`).
    public static func period(_ s: UteSettings, today: Date, calendar: Calendar) -> [UInt8] {
        let c = calendar.dateComponents([.year, .month, .day], from: s.periodStart(today: today, calendar: calendar))
        let y = c.year ?? 2000
        return [0x29, b(s["period.enabled"]), b(y >> 8), b(y), b(c.month ?? 1), b(c.day ?? 1), b(s["period.duration"]), b(s["period.cycle"])]
    }

    /// `AB 00 00 00 01 02 07 01`: đồng hồ rung để tìm (`findBand(2)`).
    public static let findWatch: [UInt8] = [0xAB, 0, 0, 0, 1, 2, 7, 1]
}

extension Ute.Features {
    var raiseToWake: Bool { has(1, 0x000040) }
    var hrHighAlert: Bool { has(1, 0x000080) }
    var hrLowAlert: Bool { has(4, 0x000800) }
    var dnd: Bool { has(1, 0x000008) }
    var sedentary: Bool { has(1, 0x010000) }
    var sedentaryRange: Bool { has(2, 0x000010) }
    var findPhone: Bool { has(2, 0x000020) }
    var drink: Bool { has(5, 0x080000) }
    var goals: Bool { has(5, 0x200000) }
    var tempUnit: Bool { has(3, 0x001000) }
    var period: Bool { has(3, 0x008000) }
    /// GloryFitPro (RK) chỉ cần F5 `0x40` (`RkSupportUtils.isSupOxygenSetting`); F9 `0x1000` là điều kiện của SDK cũ.
    var spo2Auto: Bool { has(9, 0x001000) || has(5, 0x000040) }
    var language: Bool { has(2, 0x000008) || has(3, 0x004000) || has(4, 0x100000) }
    var hangup: Bool { UteSystem.hangup(self) }
    var contacts: Bool { UteContacts.supported(self) }
}
