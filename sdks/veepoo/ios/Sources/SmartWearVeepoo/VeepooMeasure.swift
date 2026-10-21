import Foundation
import SmartWearCore

/// Parser gói đo trực tiếp (§6.2), bản Swift của `VeepooMeasure.kt`. Mỗi hàm trả về một parser có trạng thái (đếm số giá trị
/// hợp lệ) cho một lần đo: gói → (Reading, kết thúc?) hoặc nil nếu bỏ qua.
public enum VeepooMeasure {
    public typealias Parser = ([UInt8]) -> (Reading, Bool)?

    /// Số giá trị nhịp tim hợp lệ liên tiếp trước khi coi là xong (vòng tay đo liên tục tới khi app gửi `D0 00`).
    public static let hrSamples = 6

    // Lệnh bắt đầu / dừng.
    public static let heartRateStart = Veepoo.padded(20, [0xD0, 0x01])
    public static let heartRateStop: [UInt8] = [0xD0, 0x00]
    public static let spo2Start: [UInt8] = [0x80, 0x01, 0x02]
    public static let spo2Stop: [UInt8] = [0x80, 0x02, 0x02]
    public static let bloodPressureStart: [UInt8] = [0x90, 0x01, 0x00]
    public static let bloodPressureStop: [UInt8] = [0x90, 0x00, 0x00]
    public static let temperatureStart = Veepoo.padded(20, [0x87, 0x01, 0x01])
    public static let temperatureStop = Veepoo.padded(20, [0x87, 0x01, 0x02])
    public static let stressStart = Veepoo.padded(20, [0x89, 0x06, 0x01])
    public static let stressStop = Veepoo.padded(20, [0x89, 0x06, 0x02])
    public static let hrvStart = Veepoo.padded(20, [0x89, 0x07, 0x01])
    public static let hrvStop = Veepoo.padded(20, [0x89, 0x07, 0x02])
    public static let metStart = Veepoo.padded(20, [0x89, 0x08, 0x01])
    public static let metStop = Veepoo.padded(20, [0x89, 0x08, 0x02])
    /// Thành phần máu `8A 01 01 chế-độ` (1 = chế độ riêng theo hiệu chuẩn, 0 = chung; `jf/g.java:224-233`).
    public static func bloodComponentStart(privateMode: Bool) -> [UInt8] { Veepoo.padded(20, [0x8A, 0x01, 0x01, privateMode ? 1 : 0]) }
    public static let bloodComponentStop = Veepoo.padded(20, [0x8A, 0x01, 0x02, 0x00])
    /// Thành phần cơ thể đo nhanh `93 04 01` / `93 04 02` (`jf/k.java:143-162`); vòng tay dùng hồ sơ `A3` đã gửi.
    public static let bodyCompositionStart = Veepoo.padded(20, [0x93, 0x04, 0x01])
    public static let bodyCompositionStop = Veepoo.padded(20, [0x93, 0x04, 0x02])

    /// Đường huyết `89 01 01 riêng` / dừng `89 01 02 riêng` (4 byte, `mf/a.java:195-198`); riêng = 1 khi đã bật hiệu chuẩn.
    public static func glucoseStart(privateMode: Bool) -> [UInt8] { [0x89, 0x01, 0x01, privateMode ? 1 : 0] }
    public static func glucoseStop(privateMode: Bool) -> [UInt8] { [0x89, 0x01, 0x02, privateMode ? 1 : 0] }

    /// Khoá `extra` của mỡ máu (như Android).
    public static let lipidKeys = ["totalCholesterol", "triglycerides", "hdl", "ldl"]
    /// Khoá `extra` của thành phần cơ thể (như `VeepooHealth.BODY_KEYS` Android), theo thứ tự 14 trường `BodyComponent` của SDK
    /// Veepoo (`BodyComponent.java:55-69`): BMI, % mỡ, mỡ kg, khối không mỡ kg, % cơ, cơ kg, mỡ dưới da %, % nước, nước kg,
    /// % cơ xương, xương kg, % protein, protein kg, BMR kcal.
    public static let bodyCompositionKeys = [
        "bmi", "bodyFatRate", "fatMass", "fatFreeMass", "muscleRate", "muscleMass", "subcutaneousFat", "bodyWaterRate", "waterMass",
        "skeletalMuscleRate", "boneMass", "proteinRate", "proteinMass", "basalMetabolicRate",
    ]

    /// Nhịp tim `D0 bpm … [5] trạng thái máy` (`jf/u0.java:43-59`): `[5]` ∉ {0,2,3} = máy bận; bpm 1/2 = đeo sai;
    /// 30–210 hợp lệ. Lấy giá trị thứ `samples` (vài giá trị đầu chưa ổn định).
    public static func heartRate(samples: Int = hrSamples) -> Parser {
        var valid = 0
        return { p in
            guard p.count >= 2, p[0] == 0xD0 else { return nil }
            let bpm = Int(p[1])
            let machine = p.count >= 6 ? Int(p[5]) : 0
            let c = Capability.heartRate
            if machine != 0 && machine != 2 && machine != 3 {
                return (Reading(capability: c, status: .error, unit: "bpm", errorCode: machine, note: "Vòng tay đang bận đo việc khác"), true)
            }
            // GE54 đang sạc: `D0 01 00 00 FD …` (byte 4 = FD, như mã 253 "đang sạc" của huyết áp; Android đo thật).
            if p.count >= 5, p[4] == 0xFD {
                return (Reading(capability: c, status: .error, unit: "bpm", errorCode: 0xFD, note: "Vòng tay đang sạc"), true)
            }
            if bpm == 1 || bpm == 2 { return (Reading(capability: c, status: .notWorn, unit: "bpm"), true) }
            if (30...210).contains(bpm) {
                valid += 1
                let done = valid >= samples
                return (Reading(capability: c, status: done ? .ok : .measuring, value: Double(bpm), unit: "bpm"), done)
            }
            return (Reading(capability: c, status: .measuring, unit: "bpm"), false)
        }
    }

    /// Kết quả một gói `D0` của luồng nhịp tim liên tục (`heartRateSample`).
    public enum StreamPacket: Equatable {
        case sample(HeartRateSample)
        /// Vòng tay bận đo việc khác / đang sạc: luồng phải dừng.
        case failed(String)
    }

    /// Một gói `D0` khi đo liên tục (bố cục như `heartRate`, không đếm mẫu): 30–210 ⇒ mẫu có nhịp tim, bpm 1/2 ⇒ chưa đeo
    /// (`bpm` nil, `contact` false), giá trị khác (0 lúc khởi động cảm biến) ⇒ nil (bỏ qua). Như `heartRateSample` Android.
    public static func heartRateSample(_ p: [UInt8], timestamp: Date = Date()) -> StreamPacket? {
        guard p.count >= 2, p[0] == 0xD0 else { return nil }
        let bpm = Int(p[1])
        let machine = p.count >= 6 ? Int(p[5]) : 0
        if machine != 0 && machine != 2 && machine != 3 { return .failed("Vòng tay đang bận đo việc khác (\(machine))") }
        if p.count >= 5, p[4] == 0xFD { return .failed("Vòng tay đang sạc") }
        if bpm == 1 || bpm == 2 { return .sample(HeartRateSample(bpm: nil, contact: false, timestamp: timestamp)) }
        if (30...210).contains(bpm) { return .sample(HeartRateSample(bpm: bpm, contact: true, timestamp: timestamp)) }
        return nil
    }

    /// SpO2 `80 chức-năng máy giá-trị đang-hiệu-chuẩn tiến-độ …` (`jf/f2.java:126-189`). Máy: 10 pin yếu, 11 xong, 12 không
    /// đeo; byte 3 = %; byte 4 = 1/2 ⇒ đang hiệu chuẩn (byte 5 = tiến độ). Giá trị 1 = không đeo. Xong khi có `samples` giá trị
    /// 70–100 không trong lúc hiệu chuẩn, hoặc máy báo 11.
    public static func spo2(samples: Int = 3) -> Parser {
        var valid = 0
        var lastValue: Int?
        return { p in
            guard p.count >= 4, p[0] == 0x80 else { return nil }
            let c = Capability.spo2
            let machine = Int(p[2])
            let value = Int(p[3])
            let calibrating = p.count >= 5 && (p[4] == 1 || p[4] == 2)
            if machine == 12 || value == 1 { return (Reading(capability: c, status: .notWorn, unit: "%"), true) }
            if machine == 10 { return (Reading(capability: c, status: .error, unit: "%", errorCode: 10, note: "Pin yếu"), true) }
            if machine == 1 || machine == 2 || machine == 5 {
                return (Reading(capability: c, status: .error, unit: "%", errorCode: machine, note: "Vòng tay đang bận đo việc khác"), true)
            }
            if (70...100).contains(value), !calibrating {
                valid += 1
                lastValue = value
                let done = valid >= samples || machine == 11
                return (Reading(capability: c, status: done ? .ok : .measuring, value: Double(value), unit: "%"), done)
            }
            if machine == 11 {
                if let v = lastValue { return (Reading(capability: c, status: .ok, value: Double(v), unit: "%"), true) }
                return (Reading(capability: c, status: .error, unit: "%", errorCode: 11), true)
            }
            return (Reading(capability: c, status: .measuring, unit: "%"), false)
        }
    }

    /// Huyết áp `90 tâm-thu tâm-trương tiến-độ trạng-thái có-tiến-độ` (`jf/d.java:114-171`). Trạng thái 1,2,4,5,255 bận;
    /// 254 pin yếu; 253 đang sạc; 252 không đeo. Xong khi tiến độ ≥ 100 và có giá trị.
    public static func bloodPressure() -> Parser {
        { p in
            guard p.count >= 5, p[0] == 0x90 else { return nil }
            let c = Capability.bloodPressure
            let sys = Int(p[1])
            let dia = Int(p[2])
            let progress = Int(p[3])
            switch Int(p[4]) {
            case 252: return (Reading(capability: c, status: .notWorn, unit: "mmHg"), true)
            case 253: return (Reading(capability: c, status: .error, unit: "mmHg", errorCode: 253, note: "Vòng tay đang sạc"), true)
            case 254: return (Reading(capability: c, status: .error, unit: "mmHg", errorCode: 254, note: "Pin yếu"), true)
            case let st where [1, 2, 4, 5, 255].contains(st):
                return (Reading(capability: c, status: .error, unit: "mmHg", errorCode: st, note: "Vòng tay đang bận đo việc khác"), true)
            default:
                if progress >= 100, sys > 0, dia > 0 {
                    return (Reading(capability: c, status: .ok, systolic: sys, diastolic: dia, unit: "mmHg"), true)
                }
                return (Reading(capability: c, status: .measuring, unit: "mmHg", signal: Double(progress)), false)
            }
        }
    }

    /// Nhiệt độ `87 01 thao-tác máy tiến-độ tLo tHi bLo bHi` (`jf/o2.java:18-34`; xử lý trong app `home/viewModel/a0.java:62-117`):
    /// thao tác (byte 2) 0 = lỗi, 2 = đã dừng; máy (byte 3) **0 hoặc 7 = đang đo bình thường**, 1–6 bận, 8 pin yếu, khác = không
    /// hợp lệ; byte 5–6 LE ÷10 = nhiệt độ cơ thể, 7–8 = nền (da). Xong khi tiến độ ≥ 100.
    /// GE54 (Android 19/10/2026, đang đeo): `87 01 01 07 00 72 01 69 01` = đang đo, 37,0 °C / nền 36,1 °C.
    public static func temperature() -> Parser {
        { p in
            guard p.count >= 9, p[0] == 0x87 else { return nil }
            let c = Capability.temperature
            let operation = Int(p[2])
            let machine = Int(p[3])
            let progress = Int(p[4])
            let t = Double(Veepoo.le16(p, 5)) / 10
            if operation == 0 { return (Reading(capability: c, status: .error, unit: "°C", errorCode: 0, note: "Đo nhiệt độ không hợp lệ"), true) }
            if operation == 2 { return (Reading(capability: c, status: .error, unit: "°C", errorCode: 2, note: "Vòng tay đã dừng đo"), true) }
            if (1...6).contains(machine) {
                return (Reading(capability: c, status: .error, unit: "°C", errorCode: machine, note: "Vòng tay đang bận đo việc khác"), true)
            }
            if machine == 8 { return (Reading(capability: c, status: .error, unit: "°C", errorCode: 8, note: "Pin yếu"), true) }
            if machine != 0 && machine != 7 { return (Reading(capability: c, status: .error, unit: "°C", errorCode: machine), true) }
            if progress >= 100, t > 0 { return (Reading(capability: c, status: .ok, value: t, unit: "°C"), true) }
            return (Reading(capability: c, status: .measuring, value: t > 0 ? t : nil, unit: "°C", signal: Double(progress)), false)
        }
    }

    /// Nhiệt độ nền (da) trong gói `87` (byte 7–8 LE ÷10), nil nếu không có.
    public static func temperatureBase(_ p: [UInt8]) -> Double? {
        guard p.count >= 9, p[0] == 0x87, Veepoo.le16(p, 7) > 0 else { return nil }
        return Double(Veepoo.le16(p, 7)) / 10
    }

    /// Stress `89 06 01 ack tiến-độ giá-trị` (`jf/u1.java:16-70`): ack 0 OK, 1/3 bận, 2 pin yếu, 4 không đeo. Xong khi tiến độ
    /// 100 và giá trị > 0. `89 06 02` = đã dừng.
    public static func stress() -> Parser {
        { p in
            guard p.count >= 4, p[0] == 0x89, p[1] == 0x06 else { return nil }
            let c = Capability.stress
            if p[2] == 2 { return (Reading(capability: c, status: .error, unit: "", errorCode: 0, note: "Vòng tay đã dừng đo"), true) }
            guard p[2] == 1 else { return nil }
            switch Int(p[3]) {
            case 0:
                let progress = Veepoo.u(p, 4)
                let value = Veepoo.u(p, 5)
                if progress >= 100, value > 0 { return (Reading(capability: c, status: .ok, value: Double(value), unit: ""), true) }
                return (Reading(capability: c, status: .measuring, unit: "", signal: Double(progress)), false)
            case 4: return (Reading(capability: c, status: .notWorn, unit: ""), true)
            case let ack: return (Reading(capability: c, status: .error, unit: "", errorCode: ack), true)
            }
        }
    }

    /// HRV `89 07 01 ack giá-trị` (`jf/v0.java:20-62`): ack 0 ⇒ byte 4 = HRV (ms), 2 pin yếu, 1/3 bận, 4 không đeo.
    /// `89 07 02` = đã dừng. Chỉ thiết bị `hrvByApp` (A7 trang 2 byte 8 = 7/8). Giá trị 0 = chưa có.
    public static func hrv() -> Parser {
        { p in
            guard p.count >= 4, p[0] == 0x89, p[1] == 0x07 else { return nil }
            let c = Capability.hrv
            if p[2] == 2 { return (Reading(capability: c, status: .error, unit: "ms", errorCode: 0, note: "Vòng tay đã dừng đo"), true) }
            guard p[2] == 1 else { return nil }
            switch Int(p[3]) {
            case 0:
                let value = Veepoo.u(p, 4)
                if value > 0 { return (Reading(capability: c, status: .ok, value: Double(value), unit: "ms"), true) }
                return (Reading(capability: c, status: .measuring, unit: "ms"), false)
            case 4: return (Reading(capability: c, status: .notWorn, unit: "ms"), true)
            case let ack: return (Reading(capability: c, status: .error, unit: "ms", errorCode: ack), true)
            }
        }
    }

    /// Giá trị thành phần máu: acid uric µmol/L, mỡ máu mmol/L.
    public struct BloodComponentValues: Equatable, Sendable {
        public var uricAcid: Double
        public var totalCholesterol: Double
        public var triglycerides: Double
        public var hdl: Double
        public var ldl: Double

        public var lipids: [String: Double] {
            ["totalCholesterol": totalCholesterol, "triglycerides": triglycerides, "hdl": hdl, "ldl": ldl]
        }
        /// Cả 5 chỉ số (khoá như `BloodValues.extra()` Android): "uricAcid" + mỡ máu.
        public var all: [String: Double] { lipids.merging(["uricAcid": uricAcid]) { a, _ in a } }
        public var isEmpty: Bool { uricAcid == 0 && totalCholesterol == 0 && triglycerides == 0 && hdl == 0 && ldl == 0 }
    }

    /// Đo thành phần máu `8A 01 01 st tiến-độ UA TC TG HDL LDL` (LE16, UA ÷10, mỡ máu ÷100; `jf/g.java:53-66`, `:125-176`).
    public static func parseBloodComponentLive(_ p: [UInt8]) -> BloodComponentValues? {
        guard p.count >= 15, p[0] == 0x8A, p[1] == 0x01 else { return nil }
        return BloodComponentValues(uricAcid: Double(Veepoo.le16(p, 5)) / 10, totalCholesterol: Double(Veepoo.le16(p, 7)) / 100,
                                    triglycerides: Double(Veepoo.le16(p, 9)) / 100, hdl: Double(Veepoo.le16(p, 11)) / 100,
                                    ldl: Double(Veepoo.le16(p, 13)) / 100)
    }

    /// Thành phần máu `8A 01 01 trạng-thái tiến-độ uric TCHO TAG HDL LDL 00×5` (`jf/g.java:125-176`, `a()` :53-66), như Android
    /// `VeepooMeasure.bloodComponent`. Trạng thái 0 = bình thường (byte 4 tiến độ %, 5..14 ước lượng đang chạy), 1 đang đo việc khác,
    /// 2 pin yếu, 3 bận, 4 đeo/tiếp xúc không đạt; `8A 01 02` = đã dừng. Kết quả = gói tiến độ 100. Giao thức không có cờ "có ngón tay"
    /// / "đo thật" ⇒ suốt phép đo phát `measuring` + note `Reading.touchSensorNote` + `extra["progress"]`.
    /// GE54 19/10/2026 (`8A 01 01 00`): `8A 01 01 00 64 69 08 AB 01 66 00 68 00 0C 01` = 215,3 µmol/L; 4,27 / 1,02 / 1,04 / 2,68 mmol/L.
    public static func bloodComponent(_ capability: Capability) -> Parser {
        let unit = capability == .uricAcid ? "µmol/L" : "mmol/L"
        return { p in
            guard p.count >= 4, p[0] == 0x8A, p[1] == 0x01 else { return nil }
            let c = capability
            if p[2] == 2 { return (Reading(capability: c, status: .error, unit: unit, errorCode: 0, note: "Vòng tay đã dừng đo"), true) }
            guard p[2] == 1 else { return nil }
            switch Int(p[3]) {
            case 0:
                let progress = Veepoo.u(p, 4)
                if progress < 100 { return (touching(c, unit: unit, progress: progress), false) }
                guard let v = parseBloodComponentLive(p), !v.isEmpty else {
                    return (Reading(capability: c, status: .error, unit: unit, errorCode: -2, note: Reading.touchSensorNote), true)
                }
                let value = c == .uricAcid ? v.uricAcid : v.totalCholesterol
                return (Reading(capability: c, status: .ok, value: value, unit: unit, extra: v.all), true)
            case 2: return (Reading(capability: c, status: .error, unit: unit, errorCode: 2, note: "Pin yếu"), true)
            case 1, 3: return (Reading(capability: c, status: .error, unit: unit, errorCode: Int(p[3]), note: "Vòng tay đang bận đo việc khác"), true)
            case 4: return (Reading(capability: c, status: .notWorn, unit: unit, errorCode: 4, note: Reading.touchSensorNote), true)
            case let st: return (Reading(capability: c, status: .error, unit: unit, errorCode: st, note: "Đo không hợp lệ"), true)
            }
        }
    }

    /// `measuring` nhắc đặt ngón tay lên cảm biến, kèm tiến độ 0–100 (cả `extra["progress"]` lẫn `signal`).
    public static func touching(_ capability: Capability, unit: String, progress: Int = 0) -> Reading {
        let pct = Double(min(max(progress, 0), 100))
        return Reading(capability: capability, status: .measuring, unit: unit, signal: pct, note: Reading.touchSensorNote,
                       extra: [Reading.progressKey: pct])
    }

    /// Số gói thành phần cơ thể liền nhau báo "chưa chạm điện cực" trước khi dừng (G Band: 4, `home/viewModel/x.java:68-85`).
    public static let bodyLeadOffLimit = 4

    /// Đường huyết `89 01 01 st tiến-độ giá-trị(LE16)` (`jf/h.java:89-130`): `[2]` 0 không hỗ trợ, 1 có số, 2 đã dừng; st 0/1 đang đo,
    /// 2 pin yếu, 3 bận, 4 đeo sai; giá trị 13 bit thấp ÷100 = mmol/L (3 bit cao = mức rủi ro). Như `bloodGlucose` Android.
    public static func bloodGlucose() -> Parser {
        { p in
            guard p.count >= 4, p[0] == 0x89, p[1] == 0x01 else { return nil }
            let c = Capability.bloodSugar
            switch p[2] {
            case 0: return (Reading(capability: c, status: .error, unit: "mmol/L", errorCode: 0, note: "Vòng tay không hỗ trợ đo đường huyết"), true)
            case 2: return (Reading(capability: c, status: .error, unit: "mmol/L", errorCode: 0, note: "Vòng tay đã dừng đo"), true)
            case 1: break
            default: return nil
            }
            switch Int(p[3]) {
            case 0, 1:
                let progress = Veepoo.u(p, 4)
                let v = p.count >= 7 ? Double(Veepoo.le16(p, 5) & 0x1FFF) / 100 : 0
                if progress >= 100, v > 0 { return (Reading(capability: c, status: .ok, value: v, unit: "mmol/L"), true) }
                return (Reading(capability: c, status: .measuring, unit: "mmol/L", signal: Double(progress)), false)
            case 2: return (Reading(capability: c, status: .error, unit: "mmol/L", errorCode: 2, note: "Pin yếu"), true)
            case 3: return (Reading(capability: c, status: .error, unit: "mmol/L", errorCode: 3, note: "Vòng tay đang bận đo việc khác"), true)
            case 4: return (Reading(capability: c, status: .notWorn, unit: "mmol/L"), true)
            case let st: return (Reading(capability: c, status: .error, unit: "mmol/L", errorCode: st), true)
            }
        }
    }

    /// MET `89 08 01 st tiến-độ MET×10` (`jf/c1.java:24-65`): st 0 OK, 1/3 bận, 2 pin yếu, 4 không đeo. Chỉ thiết bị `metByApp`.
    public static func met() -> Parser {
        { p in
            guard p.count >= 4, p[0] == 0x89, p[1] == 0x08 else { return nil }
            let c = Capability.met
            if p[2] == 2 { return (Reading(capability: c, status: .error, unit: "MET", errorCode: 0, note: "Vòng tay đã dừng đo"), true) }
            guard p[2] == 1 else { return nil }
            switch Int(p[3]) {
            case 0:
                let progress = Veepoo.u(p, 4)
                let value = Double(Veepoo.u(p, 5)) / 10
                if progress >= 100, value > 0 { return (Reading(capability: c, status: .ok, value: value, unit: "MET"), true) }
                return (Reading(capability: c, status: .measuring, unit: "MET", signal: Double(progress)), false)
            case 2: return (Reading(capability: c, status: .error, unit: "MET", errorCode: 2, note: "Pin yếu"), true)
            case 4: return (Reading(capability: c, status: .notWorn, unit: "MET"), true)
            case let st: return (Reading(capability: c, status: .error, unit: "MET", errorCode: st, note: "Vòng tay đang bận đo việc khác"), true)
            }
        }
    }

    /// 14 chỉ số thành phần cơ thể từ khối `A0 len` + 14 × LE16 ÷10 (`BodyComponent.java:43-69`). nil nếu thiếu.
    public static func parseBodyComposition(_ payload: [UInt8]) -> [String: Double]? {
        guard payload.count >= 30, payload[0] == 0xA0 else { return nil }
        var out: [String: Double] = [:]
        for (i, k) in bodyCompositionKeys.enumerated() { out[k] = Double(Veepoo.le16(payload, 2 + i * 2)) / 10 }
        return out
    }

    /// Đo nhanh thành phần cơ thể `93 04` (`jf/k.java:54-141`): `[2]` = 2 đã dừng; `[2]` = 1, `[3]`: 0 đang đo (`[4]` tiến độ,
    /// `[5]` = 1 cảnh báo tiếp xúc — app gốc dừng khi 4 gói liền), 1 có kết quả (`[4]` gói thứ, `[5]` tổng gói, 14 byte từ `[6]`),
    /// 2 lỗi, 3 bận, 4 pin yếu. Kết quả: value = % mỡ, `extra` = 14 chỉ số (`bodyCompositionKeys`).
    public static func bodyComposition() -> Parser {
        var warnings = 0
        var parts: [Int: [UInt8]] = [:]
        return { p in
            guard p.count >= 4, p[0] == 0x93, p[1] == 0x04 else { return nil }
            let c = Capability.bodyComposition
            if p[2] == 2 { return (Reading(capability: c, status: .error, unit: "%", errorCode: 0, note: "Vòng tay đã dừng đo"), true) }
            guard p[2] == 1 else { return nil }
            switch Int(p[3]) {
            case 0:
                // Byte 5 = 1: chưa chạm điện cực (`jf/k.java:70-77`); GE54 19/10 không chạm: `93 04 01 00 xx 01`.
                let progress = Veepoo.u(p, 4)
                warnings = Veepoo.u(p, 5) == 1 ? warnings + 1 : 0
                if warnings >= bodyLeadOffLimit {
                    return (Reading(capability: c, status: .notWorn, unit: "%", note: Reading.touchSensorNote), true)
                }
                if warnings > 0 { return (touching(c, unit: "%", progress: progress), false) }
                let pct = Double(min(progress, 100))
                return (Reading(capability: c, status: .measuring, unit: "%", signal: pct, extra: [Reading.progressKey: pct]), false)
            case 1:
                guard p.count >= 6 else { return nil }
                let index = Int(p[4])
                let total = max(Int(p[5]), 1)
                parts[index] = Array(p[6..<min(p.count, 20)])
                guard parts.count >= total else { return (Reading(capability: c, status: .measuring, unit: "%"), false) }
                let payload = (1...total).flatMap { parts[$0] ?? [] }
                guard let values = parseBodyComposition(payload) else {
                    return (Reading(capability: c, status: .error, unit: "%", errorCode: -2, note: "Kết quả không hợp lệ"), true)
                }
                return (Reading(capability: c, status: .ok, value: values["bodyFatRate"], unit: "%", extra: values), true)
            case 4: return (Reading(capability: c, status: .error, unit: "%", errorCode: 4, note: "Pin yếu"), true)
            case 3: return (Reading(capability: c, status: .error, unit: "%", errorCode: 3, note: "Vòng tay đang bận đo việc khác"), true)
            case let st: return (Reading(capability: c, status: .error, unit: "%", errorCode: st, note: "Đo thất bại"), true)
            }
        }
    }
}
