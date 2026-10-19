import Foundation
import SmartWearCore

/// Nhắc sức khoẻ `E7` (loại 1 ngồi lâu, 2 uống nước, 3 nhìn xa, 4 vận động, 5 uống thuốc, 6 đọc sách, 7 ra ngoài, 8 rửa tay),
/// như `VeepooControls.Remind` Android. Phút tính từ 0:00.
public struct VeepooRemind: Equatable, Sendable {
    public var type: Int
    public var fromMinute: Int
    public var toMinute: Int
    public var interval: Int
    public var on: Bool

    public init(type: Int, fromMinute: Int, toMinute: Int, interval: Int, on: Bool) {
        self.type = type
        self.fromMinute = fromMinute
        self.toMinute = toMinute
        self.interval = interval
        self.on = on
    }
}

/// Cảnh báo nhịp tim `AC` (ngưỡng cao / thấp, bật), như `VeepooControls.HeartAlarm` Android.
public struct VeepooHeartAlarm: Equatable, Sendable {
    public var high: Int
    public var low: Int
    public var on: Bool

    public init(high: Int, low: Int, on: Bool) {
        self.high = high
        self.low = low
        self.on = on
    }
}

/// Trạng thái đọc từ vòng tay (không lưu cục bộ, như Android): nhắc `E7`, cảnh báo nhịp tim `AC`, ngôn ngữ đã đặt trong phiên,
/// giá trị hiệu chuẩn.
public struct VeepooDeviceState: Equatable, Sendable {
    public var reminds: [Int: VeepooRemind] = [:]
    public var heartAlarm: VeepooHeartAlarm?
    /// Mã `F4` đã đặt trong phiên (vòng tay không cho đọc lại).
    public var language: Int?
    public var calibration = VeepooCalibration()

    public init(reminds: [Int: VeepooRemind] = [:], heartAlarm: VeepooHeartAlarm? = nil, language: Int? = nil,
                calibration: VeepooCalibration = VeepooCalibration()) {
        self.reminds = reminds
        self.heartAlarm = heartAlarm
        self.language = language
        self.calibration = calibration
    }
}

/// Cờ tính năng → mục cài đặt, và mục cài đặt → gói lệnh (cùng vai trò `VeepooControls.kt`). Id mục theo bản Android
/// (`unit.hour24`, `unit.system`, `unit.temperature`, `language`, `auto.*`, `alert.*`, `device.*`, `remind.<loại>.*`, `hrAlarm.*`,
/// `calibrate.*`, `find.*`, `device.read`, `device.powerOff`, `data.reset`) để `setControl` của React Native giống nhau trên hai
/// nền tảng. Thêm riêng iOS: `notify.*` (ANCS), `profile.*` / `goal.*` (`A3`), `display.*`, `sedentary.*` (`E1` kiểu cũ).
public enum VeepooControls {
    public static let device = "Thiết bị"
    public static let health = "Theo dõi tự động"
    public static let reminders = "Nhắc nhở"
    public static let alerts = "Cảnh báo"
    public static let calibration = "Hiệu chuẩn"
    public static let display = "Màn hình"
    public static let profile = "Hồ sơ cá nhân"
    public static let goals = "Mục tiêu hằng ngày"
    public static let notifications = "Thông báo (iPhone gửi qua ANCS)"
    public static let system = "Hệ thống"

    /// Công tắc trong `B8` (như `B8_TOGGLES` Android): (id, trang, byte, tiêu đề, nhóm). Chỉ hiện khi vòng tay báo hỗ trợ
    /// (byte ≠ 0); ghi 1 = bật, 2 = tắt.
    public static let customToggles: [(id: String, page: Int, index: Int, title: String, group: String)] = [
        ("auto.hr", 0, VeepooCustomSettings.autoHr, "Đo nhịp tim tự động (5 phút)", health),
        ("auto.bp", 0, VeepooCustomSettings.autoBp, "Đo huyết áp tự động", health),
        ("auto.hrv", 0, VeepooCustomSettings.autoHrv, "Đo HRV tự động", health),
        ("auto.temperature", 1, VeepooCustomSettings.autoTemperature, "Đo nhiệt độ tự động", health),
        ("auto.glucose", 1, VeepooCustomSettings.autoGlucose, "Đo đường huyết tự động", health),
        ("auto.met", 1, VeepooCustomSettings.autoMet, "Đo MET tự động", health),
        ("auto.stress", 1, VeepooCustomSettings.autoStress, "Đo stress tự động", health),
        ("auto.bloodComponent", 1, VeepooCustomSettings.autoBloodComponent, "Đo thành phần máu tự động", health),
        ("auto.ppg", 0, VeepooCustomSettings.ppg, "PPG", health),
        ("alert.spo2Low", 0, VeepooCustomSettings.spo2Low, "Nhắc SpO2 thấp", alerts),
        ("alert.disconnect", 0, VeepooCustomSettings.disconnectRemind, "Nhắc khi mất kết nối", alerts),
        ("alert.sportEnd", 0, VeepooCustomSettings.sportRemind, "Nhắc hết buổi tập", alerts),
        ("alert.fall", 1, VeepooCustomSettings.fallDetect, "Phát hiện ngã", alerts),
        ("alert.hrTrend", 1, VeepooCustomSettings.hrTrend, "Xu hướng nhịp tim bất thường", alerts),
        ("device.findPhoneUi", 0, VeepooCustomSettings.findPhoneUi, "Màn tìm điện thoại", device),
        ("device.stopwatch", 0, VeepooCustomSettings.stopwatch, "Bấm giờ", device),
        ("device.musicControl", 0, VeepooCustomSettings.musicControl, "Điều khiển nhạc", device),
        ("device.autoAnswer", 0, VeepooCustomSettings.autoAnswer, "Tự trả lời cuộc gọi", device),
        ("device.sos", 0, VeepooCustomSettings.sos, "SOS", device),
        ("device.longPressLock", 1, VeepooCustomSettings.longPressLock, "Giữ lâu để khoá màn", device),
        ("device.messageScreenOn", 1, VeepooCustomSettings.messageScreenOn, "Sáng màn khi có tin nhắn", device),
        ("device.powerSound", 1, VeepooCustomSettings.powerSound, "Âm bật/tắt nguồn", device),
        ("device.measureSound", 1, VeepooCustomSettings.measureSound, "Âm khi đo", device),
    ]

    public static func customToggle(_ id: String) -> (page: Int, index: Int)? {
        customToggles.first { $0.id == id }.map { ($0.page, $0.index) }
    }

    /// Ghi `B8` cho một id (công tắc `B8`, `unit.hour24`, `unit.system`, `unit.temperature`), như `b8Change` Android: (trang, byte,
    /// giá trị). nil = id không thuộc `B8`.
    public static func b8Change(_ id: String, _ value: ControlValue) -> (page: Int, index: Int, value: Int)? {
        let on: Bool = { if case .bool(let b) = value { return b }; return false }()
        let n: Int = { if case .number(let x) = value { return x }; return 0 }()
        if let t = customToggle(id) { return (t.page, t.index, on ? 1 : 2) }
        switch id {
        case "unit.hour24": return (0, VeepooCustomSettings.hour, on ? 1 : 2)
        case "unit.system": return (0, VeepooCustomSettings.units, n == 1 ? 2 : 1)
        case "unit.temperature": return (1, VeepooCustomSettings.temperatureUnit, n == 1 ? 2 : 1)
        default: return nil
        }
    }

    // MARK: - Nhắc sức khoẻ E7

    /// Loại nhắc `E7`: (type, khoá trong id `remind.<khoá>.*`, tiêu đề). Thứ tự theo màn "Health reminders" của G Band.
    public static let remindKinds: [(type: Int, key: String, title: String)] = [
        (1, "sedentary", "Nhắc vận động (ngồi lâu)"), (2, "drink", "Nhắc uống nước"), (3, "longView", "Nhắc nhìn xa"),
        (4, "exercise", "Nhắc tập thể dục"), (5, "medication", "Nhắc uống thuốc"), (6, "book", "Nhắc đọc sách"),
        (7, "travel", "Nhắc ra ngoài"), (8, "handWash", "Nhắc rửa tay"),
    ]

    public static func remindType(key: String) -> Int? { remindKinds.first { $0.key == key }?.type }

    /// `E7 02 type` (20 byte) đọc một loại nhắc (`jf/t0.java:120-131`); type 0 = đọc tất cả.
    public static func remindRead(_ type: Int) -> [UInt8] { Veepoo.padded(20, [0xE7, 0x02, Veepoo.byte(type)]) }

    /// `E7 01 type sh sm eh em interval status` (20 byte, `jf/t0.java:133-152`); status 1 bật / 0 tắt.
    public static func remindWrite(_ r: VeepooRemind) -> [UInt8] {
        Veepoo.padded(20, [
            0xE7, 0x01, Veepoo.byte(r.type), Veepoo.byte(r.fromMinute / 60), Veepoo.byte(r.fromMinute % 60), Veepoo.byte(r.toMinute / 60),
            Veepoo.byte(r.toMinute % 60), Veepoo.byte(min(max(r.interval, 1), 255)), r.on ? 1 : 0,
        ])
    }

    /// Gói cuối khi đọc tất cả (`E7 02 00`): `[10]` = `[11]` (`t0.java:47-54`).
    public static func isLastRemind(_ p: [UInt8]) -> Bool { p.count >= 12 && p[0] == 0xE7 && p[1] == 2 && p[10] == p[11] }

    /// Phản hồi `E7 02 ok type sh sm eh em interval status …` (đọc) / `E7 01 ok …` (ghi) (`jf/t0.java:24-78`). ok ≠ 1 ⇒ lỗi;
    /// `E7 00` = không hỗ trợ. GE54 (Android 19/10/2026): uống nước 08:00–22:00 / 30 phút.
    public static func parseRemind(_ p: [UInt8]) -> VeepooRemind? {
        guard p.count >= 10, p[0] == 0xE7, p[1] == 1 || p[1] == 2, p[2] == 1 else { return nil }
        return VeepooRemind(type: Int(p[3]), fromMinute: Int(p[4]) * 60 + Int(p[5]), toMinute: Int(p[6]) * 60 + Int(p[7]),
                            interval: Int(p[8]), on: p[9] == 1)
    }

    // MARK: - Cảnh báo nhịp tim AC

    /// Đọc `AC 00 00 02` (`jf/r0.java`).
    public static let heartAlarmRead: [UInt8] = [0xAC, 0x00, 0x00, 0x02]

    /// Ghi `AC cao thấp bật` (4 byte); cao 60–220, thấp 30–120.
    public static func heartAlarmWrite(_ a: VeepooHeartAlarm) -> [UInt8] {
        [0xAC, Veepoo.byte(min(max(a.high, 60), 220)), Veepoo.byte(min(max(a.low, 30), 120)), a.on ? 1 : 0]
    }

    /// Phản hồi `AC cao thấp ok thao-tác bật` (`r0.java:120-135`): ok = 1 thành công, 0x10 = không hỗ trợ.
    /// GE54 (Android 19/10/2026): `AC 64 37 01 02 01` = 100/55, bật.
    public static func parseHeartAlarm(_ p: [UInt8]) -> VeepooHeartAlarm? {
        guard p.count >= 6, p[0] == 0xAC, p[3] == 1 else { return nil }
        return VeepooHeartAlarm(high: Int(p[1]), low: Int(p[2]), on: p[5] == 1)
    }

    // MARK: - Hệ thống

    /// `FF 55 01 73 40` + 0: khôi phục cài đặt gốc (`jf/w0.java:305-314`).
    public static let factoryReset = Veepoo.padded(20, [0xFF, 0x55, 0x01, 0x73, 0x40])
    /// `F2 04`: tắt máy (G Band chỉ hiện với thiết bị không màn, 02 §3.2).
    public static let powerOff = Veepoo.padded(20, [0xF2, 0x04])

    // MARK: - Danh sách mục

    public static func controls(
        _ f: VeepooFeatures, _ b8: VeepooCustomSettings, _ ad: VeepooMessageSwitches, _ s: VeepooSettings,
        _ st: VeepooDeviceState = VeepooDeviceState()
    ) -> [DeviceControl] {
        var out: [DeviceControl] = []
        func toggle(_ id: String, _ group: String, _ title: String, _ on: Bool, detail: String? = nil, enabled: Bool = true) {
            out.append(DeviceControl(id, group: group, title: title, kind: .toggle, value: .bool(on), detail: detail, enabled: enabled))
        }
        func number(_ id: String, _ group: String, _ title: String, _ value: Int, _ min: Int, _ max: Int, _ step: Int, _ unit: String,
                    enabled: Bool = true) {
            out.append(DeviceControl(id, group: group, title: title, kind: .number, value: .number(value), min: min, max: max,
                                     step: step, unit: unit, enabled: enabled))
        }
        func range(_ id: String, _ group: String, _ title: String, _ from: Int, _ to: Int, enabled: Bool = true) {
            out.append(DeviceControl(id, group: group, title: title, kind: .timeRange, value: .timeRange(from: from, to: to), enabled: enabled))
        }
        func choice(_ id: String, _ group: String, _ title: String, _ value: Int, _ options: [String]) {
            out.append(DeviceControl(id, group: group, title: title, kind: .choice, value: .number(value), options: options))
        }

        // Thiết bị
        if f.findDeviceByPhone {
            out.append(DeviceControl("find.start", group: device, title: "Tìm vòng tay (rung)", kind: .action, detail: "Vòng tay rung"))
            out.append(DeviceControl("find.stop", group: device, title: "Dừng tìm vòng tay", kind: .action))
        }
        out.append(DeviceControl("device.read", group: device, title: "Đọc lại cài đặt từ vòng tay", kind: .action))
        if b8.supported(0, VeepooCustomSettings.hour) { toggle("unit.hour24", device, "Định dạng 24 giờ", b8.is24h) }
        if b8.supported(0, VeepooCustomSettings.units) {
            choice("unit.system", device, "Đơn vị", b8.metric ? 0 : 1, ["Mét (km, kg)", "Anh (dặm, lb)"])
        }
        if b8.supported(1, VeepooCustomSettings.temperatureUnit) {
            choice("unit.temperature", device, "Đơn vị nhiệt độ", b8.value(1, VeepooCustomSettings.temperatureUnit) == 2 ? 1 : 0, ["°C", "°F"])
        }
        // Vòng tay không màn (A7 gói 5 byte 4 = 1, như GE54) không có chữ để đổi ngôn ngữ (như Android).
        if f.hasScreen {
            let index = VeepooSettings.languages.firstIndex { $0.code == st.language } ?? 0
            choice("language", device, "Ngôn ngữ", index, VeepooSettings.languages.map(\.name))
        }
        for t in customToggles where b8.supported(t.page, t.index) {
            toggle(t.id, t.group, t.title, b8.isOn(t.page, t.index))
        }

        // Nhắc nhở: `E7` (đọc từ vòng tay, chỉ hiện loại đã đọc được) hoặc `E1` kiểu cũ (lưu cục bộ).
        if f.healthRemind {
            for k in remindKinds {
                guard let r = st.reminds[k.type] else { continue }
                let id = "remind.\(k.key)"
                toggle("\(id).enabled", reminders, k.title, r.on)
                number("\(id).interval", reminders, "Chu kỳ nhắc", r.interval, 15, 240, 15, "phút", enabled: r.on)
                range("\(id).range", reminders, "Khung giờ nhắc", r.fromMinute, r.toMinute, enabled: r.on)
            }
        }
        if f.longSeat {
            toggle("sedentary.enabled", reminders, "Nhắc vận động", s.on("sedentary.enabled"))
            number("sedentary.interval", reminders, "Ngồi quá", s["sedentary.interval"], 30, 240, 15, "phút", enabled: s.on("sedentary.enabled"))
            range("sedentary.range", reminders, "Khung giờ nhắc vận động", s["sedentary.range.from"], s["sedentary.range.to"],
                  enabled: s.on("sedentary.enabled"))
        }

        // Cảnh báo nhịp tim `AC`
        if f.heartRateAlarm, let a = st.heartAlarm {
            toggle("hrAlarm.enabled", alerts, "Cảnh báo nhịp tim", a.on)
            number("hrAlarm.high", alerts, "Ngưỡng cao", a.high, 100, 200, 5, "bpm", enabled: a.on)
            number("hrAlarm.low", alerts, "Ngưỡng thấp", a.low, 30, 70, 5, "bpm", enabled: a.on)
        }

        // Hiệu chuẩn
        out += VeepooCalibration.controls(f, st.calibration, group: calibration)

        // Màn hình
        if f.hasScreen, f.wristTurnType != 2 {
            toggle("display.raise", display, "Nâng tay sáng màn", s.on("display.raise"))
            range("display.raise.range", display, "Khung giờ nâng tay sáng màn", s["display.raise.range.from"], s["display.raise.range.to"],
                  enabled: s.on("display.raise"))
        }
        if f.brightness {
            number("display.brightness", display, "Độ sáng", s["display.brightness"], 1, f.b(1, 13) > 1 ? f.b(1, 13) : 5, 1, "")
        }
        if f.screenOnTime { number("display.screenOn", display, "Thời gian sáng màn", s["display.screenOn"], 3, 30, 1, "giây") }

        // Hồ sơ + mục tiêu (A3)
        number("profile.height", profile, "Chiều cao", s["profile.height"], 100, 230, 1, "cm")
        number("profile.weight", profile, "Cân nặng", s["profile.weight"], 20, 200, 1, "kg")
        number("profile.age", profile, "Tuổi", s["profile.age"], 5, 100, 1, "tuổi")
        choice("profile.gender", profile, "Giới tính", s["profile.gender"], ["Nam", "Nữ"])
        number("goal.steps", goals, "Mục tiêu bước", s["goal.steps"], 1000, 50000, 500, "bước")
        number("goal.sleep", goals, "Mục tiêu ngủ", s["goal.sleep"], 4, 12, 1, "giờ")

        // Thông báo (AD). Nội dung do vòng tay đọc qua ANCS sau khi ghép đôi; app chỉ bật/tắt từng app.
        if ad.any {
            out.append(DeviceControl("notify.pair", group: notifications, title: "Yêu cầu ghép đôi để nhận thông báo", kind: .action,
                                     detail: "Chấp nhận ghép đôi rồi bật \"Chia sẻ thông báo hệ thống\" trong Cài đặt > Bluetooth"))
            for t in ad.supportedTypes {
                toggle("notify.\(t)", notifications, VeepooMessageSwitches.appNames[t] ?? "App \(t)", ad.isOn(t))
            }
        }

        // Hệ thống. Tắt máy: G Band chỉ hiện với vòng tay không màn.
        if f.screenless {
            out.append(DeviceControl("device.powerOff", group: system, title: "Tắt vòng tay", kind: .action,
                                     confirm: "Tắt vòng tay? Bật lại bằng cách cắm sạc."))
        }
        out.append(DeviceControl("data.reset", group: system, title: "Khôi phục cài đặt gốc", kind: .action,
                                 confirm: "Khôi phục cài đặt gốc và xoá toàn bộ dữ liệu trên vòng tay?"))
        return out
    }

    // MARK: - Gói lệnh mục lưu cục bộ

    /// `A3 cm kg tuổi giới(1 nam / 0 nữ) stepHi stepLo sleepHi sleepLo` (mục tiêu ngủ tính phút, `jf/t1.java:47-61`).
    public static func userInfo(_ s: VeepooSettings) -> [UInt8] {
        let steps = s["goal.steps"]
        let sleep = s["goal.sleep"] * 60
        return Veepoo.padded(20, [
            0xA3, Veepoo.byte(s["profile.height"]), Veepoo.byte(s["profile.weight"]), Veepoo.byte(s["profile.age"]),
            s["profile.gender"] == 1 ? 0 : 1, Veepoo.byte(steps >> 8), Veepoo.byte(steps), Veepoo.byte(sleep >> 8), Veepoo.byte(sleep),
        ])
    }

    /// `F4 code code 00 flag` (flag 0 với tiếng Trung, 1 với ngôn ngữ khác), như `language(code)` Android. `index` = chỉ số trong
    /// `VeepooSettings.languages`; nil nếu ngoài bảng.
    public static func language(_ index: Int) -> [UInt8]? {
        guard VeepooSettings.languages.indices.contains(index) else { return nil }
        let code = VeepooSettings.languages[index].code
        return Veepoo.padded(20, [0xF4, Veepoo.byte(code), Veepoo.byte(code), 0x00, code == 1 ? 0 : 1])
    }

    /// `AA open sh sm eh em` (6 byte, dạng dựng sẵn `mf/a.java:160-162`).
    public static func raiseToWake(_ s: VeepooSettings) -> [UInt8] {
        let from = s["display.raise.range.from"]
        let to = s["display.raise.range.to"]
        return [0xAA, s.on("display.raise") ? 1 : 0, Veepoo.byte(from / 60), Veepoo.byte(from % 60), Veepoo.byte(to / 60), Veepoo.byte(to % 60)]
    }

    /// `B1 01 sh sm eh em level other auto` (`jf/z1.java:19-35`): đặt cùng một mức cho cả hai khung giờ, tắt tự động.
    public static func brightness(_ level: Int) -> [UInt8] {
        Veepoo.padded(20, [0xB1, 0x01, 22, 0, 7, 0, Veepoo.byte(level), Veepoo.byte(level), 0])
    }

    /// `B4 01 giây` (`jf/b2.java`).
    public static func screenOn(seconds: Int) -> [UInt8] { Veepoo.padded(20, [0xB4, 0x01, Veepoo.byte(seconds)]) }

    /// `E1 sh sm eh em ngưỡng open` (7 byte, `jf/f.java:155`): nhắc ngồi lâu kiểu cũ (A7 gói 1 byte 3 = 1).
    public static func sedentary(_ s: VeepooSettings) -> [UInt8] {
        let from = s["sedentary.range.from"]
        let to = s["sedentary.range.to"]
        return [0xE1, Veepoo.byte(from / 60), Veepoo.byte(from % 60), Veepoo.byte(to / 60), Veepoo.byte(to % 60),
                Veepoo.byte(s["sedentary.interval"]), s.on("sedentary.enabled") ? 1 : 0]
    }

    /// Lệnh cho mục cài đặt lưu cục bộ (các mục đọc từ vòng tay do `VeepooDevice.setControl` xử lý riêng).
    public static func commands(_ id: String, _ f: VeepooFeatures, _ s: VeepooSettings) -> [[UInt8]] {
        switch id {
        case _ where id.hasPrefix("profile.") || id.hasPrefix("goal."): [userInfo(s)]
        case _ where id.hasPrefix("display.raise"): f.wristTurnType != 2 ? [raiseToWake(s)] : []
        case "display.brightness": f.brightness ? [brightness(s["display.brightness"])] : []
        case "display.screenOn": f.screenOnTime ? [screenOn(seconds: s["display.screenOn"])] : []
        case _ where id.hasPrefix("sedentary."): f.longSeat ? [sedentary(s)] : []
        default: []
        }
    }
}
