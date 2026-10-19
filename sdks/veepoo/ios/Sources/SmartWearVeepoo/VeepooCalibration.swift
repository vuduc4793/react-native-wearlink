import Foundation
import SmartWearCore

/// Hiệu chuẩn (màn "Health & Monitor" của G Band): huyết áp chế độ riêng `91`, đường huyết một điểm `89 02` / nhiều điểm `89 03`,
/// thành phần máu `8A 02`. Giá trị đọc từ vòng tay sau khi nối; mỗi lần đổi một mục thì ghi lại cả bộ.
/// Id control như Android: `calibrate.bp.{enabled,systolic,diastolic}`, `calibrate.glucose.{enabled,value}` /
/// `calibrate.glucose.<bữa>{Time,Before,After}` (bữa ∈ breakfast/lunch/dinner), `calibrate.bloodComponent.{enabled,uricAcid,
/// totalCholesterol,triglycerides,hdl,ldl}`.
public struct VeepooCalibration: Equatable, Sendable {
    /// Huyết áp chế độ riêng: bật + tâm thu / tâm trương tham chiếu (mmHg).
    public struct BloodPressure: Equatable, Sendable {
        public var on: Bool
        public var systolic: Int
        public var diastolic: Int
        public init(on: Bool, systolic: Int, diastolic: Int) {
            self.on = on
            self.systolic = systolic
            self.diastolic = diastolic
        }
    }

    /// Một bữa trong hiệu chuẩn đường huyết nhiều điểm: giờ + giá trị trước / sau ăn (mmol/L × 100).
    public struct Meal: Equatable, Sendable {
        public var beforeMinute: Int
        public var before: Int
        public var afterMinute: Int
        public var after: Int
        public init(beforeMinute: Int, before: Int, afterMinute: Int, after: Int) {
            self.beforeMinute = beforeMinute
            self.before = before
            self.afterMinute = afterMinute
            self.after = after
        }
    }

    /// Đường huyết: một điểm (`value`, mmol/L × 100) hoặc nhiều điểm (3 bữa `meals`).
    public struct Glucose: Equatable, Sendable {
        public var on: Bool
        public var value: Int
        public var meals: [Meal]
        public init(on: Bool, value: Int = 0, meals: [Meal] = []) {
            self.on = on
            self.value = value
            self.meals = meals
        }
    }

    /// Thành phần máu: acid uric (µmol/L × 10), cholesterol toàn phần, triglycerid, HDL, LDL (mmol/L × 100). 0 = chưa đặt.
    public struct BloodComponent: Equatable, Sendable {
        public var on: Bool
        public var uricAcid: Int
        public var totalCholesterol: Int
        public var triglycerides: Int
        public var hdl: Int
        public var ldl: Int
        public init(on: Bool, uricAcid: Int = 0, totalCholesterol: Int = 0, triglycerides: Int = 0, hdl: Int = 0, ldl: Int = 0) {
            self.on = on
            self.uricAcid = uricAcid
            self.totalCholesterol = totalCholesterol
            self.triglycerides = triglycerides
            self.hdl = hdl
            self.ldl = ldl
        }
    }

    public var bp: BloodPressure?
    public var glucose: Glucose?
    public var bloodComponent: BloodComponent?

    public init(bp: BloodPressure? = nil, glucose: Glucose? = nil, bloodComponent: BloodComponent? = nil) {
        self.bp = bp
        self.glucose = glucose
        self.bloodComponent = bloodComponent
    }

    /// Tên bữa trong id `calibrate.glucose.<bữa>.*` (thứ tự khối 1, 2, 3 của `89 03`).
    public static let mealKeys = ["breakfast", "lunch", "dinner"]
    static let mealTitles = ["Bữa sáng", "Bữa trưa", "Bữa tối"]
    /// Mặc định khi vòng tay chưa có hiệu chuẩn (như màn G Band: 120/80).
    static let defaultBp = BloodPressure(on: false, systolic: 120, diastolic: 80)
    static let defaultMeals = [
        Meal(beforeMinute: 7 * 60, before: 500, afterMinute: 9 * 60, after: 700),
        Meal(beforeMinute: 12 * 60, before: 500, afterMinute: 14 * 60, after: 700),
        Meal(beforeMinute: 18 * 60, before: 500, afterMinute: 20 * 60, after: 700),
    ]

    // MARK: - Huyết áp `91` (`jf/i0.java:129-193`, `:282-372`)

    /// Đọc `91 02 00 00` (gói dựng sẵn `mf/a.java:164`).
    public static let bpRead: [UInt8] = [0x91, 0x02, 0x00, 0x00]

    /// Ghi `91 riêng tâm-thu tâm-trương angio(0)` (đủ 20 byte, như Android: gói `91` thiếu byte bị GE54 hiểu là "đặt chế độ
    /// thường 0/0", đo 19/10/2026).
    public static func bpWrite(_ b: BloodPressure) -> [UInt8] {
        Veepoo.padded(20, [0x91, b.on ? 1 : 0, Veepoo.byte(b.systolic), Veepoo.byte(b.diastolic), 0])
    }

    /// Phản hồi `91 kết-quả tâm-thu tâm-trương chế-độ thao-tác …`: kết quả 1 = OK; chế độ 1 = riêng.
    public static func parseBp(_ p: [UInt8]) -> BloodPressure? {
        guard p.count >= 5, p[0] == 0x91, p[1] == 1 else { return nil }
        return BloodPressure(on: p[4] == 1, systolic: Int(p[2]), diastolic: Int(p[3]))
    }

    // MARK: - Đường huyết (`jf/h.java`)

    /// Một điểm: đọc `89 02 02 00 00 00` (`mf/a.java:194`).
    public static let glucoseSingleRead: [UInt8] = [0x89, 0x02, 0x02, 0x00, 0x00, 0x00]

    /// Một điểm: ghi `89 02 01 lo hi bật` (mmol/L × 100, `h.java:282-293`).
    public static func glucoseSingleWrite(_ g: Glucose) -> [UInt8] {
        Veepoo.padded(20, [0x89, 0x02, 0x01, Veepoo.byte(g.value), Veepoo.byte(g.value >> 8), g.on ? 1 : 0])
    }

    /// Một điểm: phản hồi `89 02 thao-tác ok lo hi bật` (`h.java:132-170`).
    public static func parseGlucoseSingle(_ p: [UInt8]) -> Glucose? {
        guard p.count >= 7, p[0] == 0x89, p[1] == 0x02, p[3] == 1 else { return nil }
        return Glucose(on: p[6] == 1, value: Veepoo.le16(p, 4))
    }

    /// Nhiều điểm: đọc `89 03 02 01 01` (`mf/a.java:199`).
    public static let glucoseMultiRead: [UInt8] = [0x89, 0x03, 0x02, 0x01, 0x01]

    /// Thân 25 byte: bật + 3 khối 8 byte `giờ phút trước(LE16 ×100) giờ phút sau(LE16 ×100)` (`h.java:42-68`).
    static func glucoseBody(_ g: Glucose) -> [UInt8] {
        var body: [UInt8] = [g.on ? 1 : 0]
        for i in 0..<3 {
            let m = i < g.meals.count ? g.meals[i] : defaultMeals[i]
            body += [Veepoo.byte(m.beforeMinute / 60), Veepoo.byte(m.beforeMinute % 60), Veepoo.byte(m.before), Veepoo.byte(m.before >> 8),
                     Veepoo.byte(m.afterMinute / 60), Veepoo.byte(m.afterMinute % 60), Veepoo.byte(m.after), Veepoo.byte(m.after >> 8)]
        }
        return body
    }

    /// Nhiều điểm: ghi 2 gói `89 03 01 01 02` + thân[0..14] và `89 03 01 02 02` + thân[15..24] (`h.java:255-279`).
    public static func glucoseMultiWrite(_ g: Glucose) -> [[UInt8]] {
        let body = glucoseBody(g)
        return [[0x89, 0x03, 0x01, 0x01, 0x02] + body[0..<15], Veepoo.padded(20, [0x89, 0x03, 0x01, 0x02, 0x02] + body[15..<25])]
    }

    /// Nhiều điểm: phản hồi đọc `89 03 02 ok idx total …` ×2, ghép gói 1 [0..19] + gói 2 [6..16] (`h.java:198-238`):
    /// [6] bật, [7..14] / [15..22] / [23..30] ba bữa.
    public static func parseGlucoseMulti(_ packets: [[UInt8]]) -> Glucose? {
        let ps = packets.filter { $0.count >= 6 && $0[0] == 0x89 && $0[1] == 0x03 && $0[2] == 0x02 && $0[3] != 0 }
            .sorted { $0[4] < $1[4] }
        guard ps.count >= 2, ps[0].count >= 20, ps[1].count >= 17 else { return nil }
        let b = Array(ps[0].prefix(20)) + ps[1][6..<17]
        let meals = (0..<3).map { i -> Meal in
            let o = 7 + i * 8
            return Meal(beforeMinute: Int(b[o]) * 60 + Int(b[o + 1]), before: Veepoo.le16(b, o + 2),
                        afterMinute: Int(b[o + 4]) * 60 + Int(b[o + 5]), after: Veepoo.le16(b, o + 6))
        }
        return Glucose(on: b[6] == 1, meals: meals)
    }

    // MARK: - Thành phần máu `8A 02` (`jf/g.java:77-221`)

    public static let bloodRead = Veepoo.padded(20, [0x8A, 0x02, 0x02])

    /// Ghi `8A 02 01 bật UA TC TG HDL LDL` (LE16; UA µmol/L × 10, mỡ máu mmol/L × 100; chưa đặt = 0).
    public static func bloodWrite(_ c: BloodComponent) -> [UInt8] {
        var p: [UInt8] = [0x8A, 0x02, 0x01, c.on ? 1 : 0]
        for v in [c.uricAcid, c.totalCholesterol, c.triglycerides, c.hdl, c.ldl] { p += [Veepoo.byte(v), Veepoo.byte(v >> 8)] }
        return Veepoo.padded(20, p)
    }

    /// Phản hồi `8A 02 thao-tác ok bật UA TC TG HDL LDL` (ok = 1).
    public static func parseBlood(_ p: [UInt8]) -> BloodComponent? {
        guard p.count >= 15, p[0] == 0x8A, p[1] == 0x02, p[3] == 1 else { return nil }
        return BloodComponent(on: p[4] == 1, uricAcid: Veepoo.le16(p, 5), totalCholesterol: Veepoo.le16(p, 7),
                              triglycerides: Veepoo.le16(p, 9), hdl: Veepoo.le16(p, 11), ldl: Veepoo.le16(p, 13))
    }

    // MARK: - Mục cài đặt

    /// Mục hiệu chuẩn (id, đơn vị, khoảng như `calibrationControls` Android): chỉ hiện nhóm vòng tay đã trả lời khi đọc. Giá trị là
    /// số nguyên đúng như trên dây (đường huyết / mỡ máu × 100, acid uric × 10) để ghi lại không mất chữ số.
    static func controls(_ f: VeepooFeatures, _ c: VeepooCalibration, group: String) -> [DeviceControl] {
        var out: [DeviceControl] = []
        func toggle(_ id: String, _ title: String, _ on: Bool) {
            out.append(DeviceControl(id, group: group, title: title, kind: .toggle, value: .bool(on)))
        }
        func number(_ id: String, _ title: String, _ v: Int, _ min: Int, _ max: Int, _ step: Int, _ unit: String, _ on: Bool) {
            out.append(DeviceControl(id, group: group, title: title, kind: .number, value: .number(v), min: min, max: max, step: step,
                                     unit: unit, enabled: on))
        }
        let unitGlucose = "×0,01 mmol/L"
        if f.bloodPressure, let b = c.bp {
            toggle("calibrate.bp.enabled", "Hiệu chuẩn huyết áp (chế độ riêng)", b.on)
            number("calibrate.bp.systolic", "Tâm thu gốc", b.systolic, 80, 200, 1, "mmHg", b.on)
            number("calibrate.bp.diastolic", "Tâm trương gốc", b.diastolic, 40, 130, 1, "mmHg", b.on)
        }
        if f.glucoseMultiCalibration || f.glucoseSingleCalibration, let g = c.glucose {
            toggle("calibrate.glucose.enabled", "Hiệu chuẩn đường huyết", g.on)
            if f.glucoseMultiCalibration {
                for (i, key) in mealKeys.enumerated() {
                    let m = i < g.meals.count ? g.meals[i] : defaultMeals[i]
                    let id = "calibrate.glucose.\(key)"
                    out.append(DeviceControl("\(id)Time", group: group, title: "\(mealTitles[i]): giờ trước / sau ăn", kind: .timeRange,
                                             value: .timeRange(from: m.beforeMinute, to: m.afterMinute), enabled: g.on))
                    number("\(id)Before", "\(mealTitles[i]): trước ăn", m.before, 0, 3000, 10, unitGlucose, g.on)
                    number("\(id)After", "\(mealTitles[i]): sau ăn", m.after, 0, 3000, 10, unitGlucose, g.on)
                }
            } else {
                number("calibrate.glucose.value", "Đường huyết gốc", g.value, 200, 3000, 10, unitGlucose, g.on)
            }
        }
        if f.bloodComponent, let b = c.bloodComponent {
            let id = "calibrate.bloodComponent"
            toggle("\(id).enabled", "Hiệu chuẩn thành phần máu", b.on)
            number("\(id).uricAcid", "Acid uric gốc", b.uricAcid, 0, 9000, 10, "×0,1 µmol/L", b.on)
            number("\(id).totalCholesterol", "Cholesterol toàn phần gốc", b.totalCholesterol, 0, 3000, 10, unitGlucose, b.on)
            number("\(id).triglycerides", "Triglycerid gốc", b.triglycerides, 0, 3000, 10, unitGlucose, b.on)
            number("\(id).hdl", "HDL gốc", b.hdl, 0, 3000, 10, unitGlucose, b.on)
            number("\(id).ldl", "LDL gốc", b.ldl, 0, 3000, 10, unitGlucose, b.on)
        }
        return out
    }

    /// Bộ hiệu chuẩn mới sau khi đổi mục `id` (giá trị thô như trên dây). nil = id / kiểu giá trị không hợp lệ.
    func with(_ id: String, _ value: ControlValue) -> VeepooCalibration? {
        let parts = id.split(separator: ".").map(String.init)
        guard parts.count == 3, parts[0] == "calibrate" else { return nil }
        var c = self
        let field = parts[2]
        let on: Bool? = { if case .bool(let b) = value { return b }; return nil }()
        let n: Int? = { if case .number(let x) = value { return x }; return nil }()
        switch parts[1] {
        case "bp":
            var b = c.bp ?? Self.defaultBp
            switch field {
            case "enabled": guard let on else { return nil }; b.on = on
            case "systolic": guard let n else { return nil }; b.systolic = n
            case "diastolic": guard let n else { return nil }; b.diastolic = n
            default: return nil
            }
            c.bp = b
        case "glucose":
            var g = c.glucose ?? Glucose(on: false, value: 500, meals: Self.defaultMeals)
            if g.meals.count < 3 { g.meals += Self.defaultMeals[g.meals.count...] }
            if field == "enabled" {
                guard let on else { return nil }
                g.on = on
            } else if field == "value" {
                guard let n else { return nil }
                g.value = n
            } else {
                guard let i = Self.mealKeys.firstIndex(where: { field.hasPrefix($0) }) else { return nil }
                switch (String(field.dropFirst(Self.mealKeys[i].count)), value) {
                case ("Time", .timeRange(let from, let to)):
                    g.meals[i].beforeMinute = from
                    g.meals[i].afterMinute = to
                case ("Before", .number(let x)): g.meals[i].before = x
                case ("After", .number(let x)): g.meals[i].after = x
                default: return nil
                }
            }
            c.glucose = g
        case "bloodComponent":
            var b = c.bloodComponent ?? BloodComponent(on: false)
            if field == "enabled" {
                guard let on else { return nil }
                b.on = on
            } else {
                guard let n else { return nil }
                switch field {
                case "uricAcid": b.uricAcid = n
                case "totalCholesterol": b.totalCholesterol = n
                case "triglycerides": b.triglycerides = n
                case "hdl": b.hdl = n
                case "ldl": b.ldl = n
                default: return nil
                }
            }
            c.bloodComponent = b
        default: return nil
        }
        return c
    }
}

extension VeepooDevice {
    /// Đọc hiệu chuẩn theo cờ A7 (lỗi / không trả lời thì giữ giá trị cũ).
    func readCalibration(_ old: VeepooCalibration) async -> VeepooCalibration {
        let f = features
        var c = old
        if f.bloodPressure, let p = try? await request(VeepooCalibration.bpRead, timeout: 2, match: { $0.first == 0x91 }) {
            SmartWearLog.i("[\(name)] 91 02 = \(p.hex)")
            c.bp = VeepooCalibration.parseBp(p) ?? c.bp
        }
        if f.glucoseMultiCalibration {
            let ps = (try? await collect(VeepooCalibration.glucoseMultiRead, idle: 1.5, end: { $0.count >= 6 && $0[4] == $0[5] }) {
                $0.count >= 6 && $0[0] == 0x89 && $0[1] == 0x03 && $0[2] == 0x02
            }) ?? []
            SmartWearLog.i("[\(name)] 89 03 02 = \(ps.map(\.hex).joined(separator: " | "))")
            c.glucose = VeepooCalibration.parseGlucoseMulti(ps) ?? c.glucose
        } else if f.glucoseSingleCalibration,
                  let p = try? await request(VeepooCalibration.glucoseSingleRead, timeout: 2, match: { $0.count >= 3 && $0[0] == 0x89 && $0[1] == 0x02 }) {
            SmartWearLog.i("[\(name)] 89 02 02 = \(p.hex)")
            c.glucose = VeepooCalibration.parseGlucoseSingle(p) ?? c.glucose
        }
        if f.bloodComponent,
           let p = try? await request(VeepooCalibration.bloodRead, timeout: 2, match: { $0.count >= 3 && $0[0] == 0x8A && $0[1] == 0x02 }) {
            SmartWearLog.i("[\(name)] 8A 02 02 = \(p.hex)")
            c.bloodComponent = VeepooCalibration.parseBlood(p) ?? c.bloodComponent
        }
        return c
    }

    /// Đổi một mục `calibrate.*` rồi ghi lại cả bộ của nhóm đó; vòng tay từ chối thì ném lỗi.
    func writeCalibration(_ id: String, _ value: ControlValue?, _ old: VeepooCalibration) async throws -> VeepooCalibration {
        guard let value, let next = old.with(id, value) else { throw VeepooError("Không có mục \(id)") }
        if id.hasPrefix("calibrate.bp."), let b = next.bp {
            let rsp = try await request(VeepooCalibration.bpWrite(b), timeout: 3) { $0.first == 0x91 }
            guard rsp.count >= 2, rsp[1] == 1 else { throw VeepooError("Vòng tay từ chối hiệu chuẩn huyết áp: \(rsp.hex)") }
        } else if id.hasPrefix("calibrate.glucose."), let g = next.glucose {
            if features.glucoseMultiCalibration {
                let rsp = try await sendAndWait(VeepooCalibration.glucoseMultiWrite(g), timeout: 3) {
                    $0.count >= 6 && $0[0] == 0x89 && $0[1] == 0x03 && $0[2] == 0x01 && ($0[3] == 0 || $0[4] == $0[5])
                }
                guard let rsp, rsp[3] != 0 else { throw VeepooError("Vòng tay từ chối hiệu chuẩn đường huyết: \(rsp?.hex ?? "không trả lời")") }
            } else {
                let rsp = try await request(VeepooCalibration.glucoseSingleWrite(g), timeout: 3) { $0.count >= 4 && $0[0] == 0x89 && $0[1] == 0x02 }
                guard rsp[3] == 1 else { throw VeepooError("Vòng tay từ chối hiệu chuẩn đường huyết: \(rsp.hex)") }
            }
        } else if id.hasPrefix("calibrate.bloodComponent."), let b = next.bloodComponent {
            let rsp = try await request(VeepooCalibration.bloodWrite(b), timeout: 3) { $0.count >= 4 && $0[0] == 0x8A && $0[1] == 0x02 }
            guard rsp[3] == 1 else { throw VeepooError("Vòng tay từ chối hiệu chuẩn thành phần máu: \(rsp.hex)") }
        }
        return next
    }
}
