import Foundation
import SmartWearCore

/// Parser lịch sử Veepoo (01-protocol §6.4–6.5), bản Swift của `VeepooHistory.kt`: bước hôm nay `A8`/`D8`, dữ liệu 5 phút
/// `DF` (TLV, GE54) / `D1` (kiểu cũ), ngủ `E0` (thường + chính xác, có REM), buổi tập `D3`/`D4`. Hàm thuần (không I/O) để
/// kiểm thử bằng vector byte; luồng gửi lệnh ở `VeepooSync.swift`.
public enum VeepooHistory {

    // MARK: - Bước hôm nay

    public static let currentStepsRead: [UInt8] = [0xA8, 0x00]
    public static let sportModelStepsRead: [UInt8] = [0xD8, 0x00]

    /// `A8 s3 s2 s1 s0 ok …`: bước BE32 ở byte 1–4, chỉ hợp lệ khi byte 5 = 0; `FFFFFFFF` = 0 (`jf/l2.java:149-182`).
    public static func parseCurrentSteps(_ p: [UInt8]) -> Int? {
        guard p.count >= 6, p[0] == 0xA8, p[5] == 0 else { return nil }
        let v = Veepoo.be32(p, 1)
        return v == 0xFFFF_FFFF ? 0 : v
    }

    /// `D8 ?? bước(LE32) quãng-đường-m(LE32) kcal×10(LE32)` (`jf/i0.java:378-391`). `calories` theo cal như core
    /// (`ActivityTotals`: "UI chia 1000 ra kcal") ⇒ kcal×10 × 100.
    public static func parseSportModelSteps(_ p: [UInt8]) -> ActivityTotals? {
        guard p.count >= 14, p[0] == 0xD8 else { return nil }
        return ActivityTotals(steps: Veepoo.le32(p, 2), calories: Veepoo.le32(p, 10) * 100, distanceMeters: Veepoo.le32(p, 6))
    }

    /// Bước chân (m) theo chiều cao, như `SportUtil.getStepLength` (làm tròn 3 chữ số).
    public static func stepLength(heightCm: Int) -> Double {
        let h = Double(heightCm)
        let raw = h < 155 ? h * 20 / 42 : h < 174 ? h * 13 / 28 : h * 19 / 42
        return (raw / 100 * 1000).rounded() / 1000
    }

    /// Quãng đường (m) và calo (cal) tự tính từ số bước khi thiết bị không gửi (`SportUtil.getDistance3` / `getKcal`:
    /// kcal = km × 65,4). Chỉ dùng cho `A8` / `D1` kiểu cũ.
    public static func estimate(steps: Int, heightCm: Int) -> (distanceMeters: Int, calories: Int) {
        let km = (stepLength(heightCm: heightCm) * Double(steps) / 1000 * 1000).rounded() / 1000
        return (Int((km * 1000).rounded()), Int((km * 65.4 * 1000).rounded()))
    }

    // MARK: - Ngày giờ

    /// Ngày giờ gần ngày đọc `readDate` nhất cho tháng/ngày/giờ/phút (giấc ngủ có thể bắt đầu từ hôm trước, hoặc năm trước khi
    /// đọc đầu tháng 1), như `dateNear` Android.
    public static func dateNear(_ readDate: Date, month: Int, day: Int, hour: Int, minute: Int, calendar: Calendar = .current) -> Date? {
        guard (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60 else { return nil }
        let ref = calendar.startOfDay(for: readDate)
        let year = calendar.component(.year, from: ref)
        return [year - 1, year, year + 1].compactMap { y -> Date? in
            let c = DateComponents(year: y, month: month, day: day, hour: hour, minute: minute)
            guard c.isValidDate(in: calendar) else { return nil }
            return calendar.date(from: c)
        }.min { abs($0.timeIntervalSince(ref)) < abs($1.timeIntervalSince(ref)) }
    }

    static func day(_ offset: Int, from now: Date, _ calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: now)) ?? now
    }

    // MARK: - Dữ liệu 5 phút

    /// Một bản ghi 5 phút (gộp `DF` và `D1`), như `FiveMinute` Android. Trường thiết bị không gửi thì rỗng / nil.
    public struct FiveMinute: Equatable, Sendable {
        public var time: Date
        public var steps: Int
        public var sport: Int
        public var distanceMeters: Int
        /// cal (như core). `DF`: kcal×10 × 100.
        public var calories: Int
        public var wear: Int?
        /// Nhịp tim từng phút (`DF` `B4`: 5 giá trị; `D1`: 1 giá trị).
        public var heartRates: [Int]
        public var systolic: Int?
        public var diastolic: Int?
        /// SpO2 từng phút (`B9`, 5 giá trị đầu).
        public var spo2: [Int]
        public var stress: Int?
        public var met: Double?
        public var temperature: Double?
        /// HRV từng phút tính từ 50 RR (`B7`).
        public var hrv: [Int]
        /// 50 RR thô (`B7` byte 1–50, đơn vị 10 ms), 10 giá trị mỗi phút.
        public var rr: [Int] = []
        /// Đường huyết mmol/L (`BE`).
        public var glucose: Double?
        /// Thành phần máu (`C2`).
        public var bloodComponent: VeepooMeasure.BloodComponentValues?

        public init(
            time: Date, steps: Int = 0, sport: Int = 0, distanceMeters: Int = 0, calories: Int = 0, wear: Int? = nil,
            heartRates: [Int] = [], systolic: Int? = nil, diastolic: Int? = nil, spo2: [Int] = [], stress: Int? = nil,
            met: Double? = nil, temperature: Double? = nil, hrv: [Int] = [], glucose: Double? = nil,
            bloodComponent: VeepooMeasure.BloodComponentValues? = nil
        ) {
            self.time = time; self.steps = steps; self.sport = sport; self.distanceMeters = distanceMeters; self.calories = calories
            self.wear = wear; self.heartRates = heartRates; self.systolic = systolic; self.diastolic = diastolic; self.spo2 = spo2
            self.stress = stress; self.met = met; self.temperature = temperature; self.hrv = hrv; self.glucose = glucose
            self.bloodComponent = bloodComponent
        }
    }

    /// `DF posLo posHi day 00…` (20 byte, `jf/p1.java:1199-1206`); pos từ 1, day 0 = hôm nay.
    public static func dfRequest(day: Int, position: Int = 1) -> [UInt8] {
        Veepoo.padded(20, [0xDF, Veepoo.byte(position), Veepoo.byte(position >> 8), Veepoo.byte(day)])
    }

    /// Gói kết thúc luồng `DF`: byte 1 = byte 2 = `FF`.
    public static func isDfEnd(_ p: [UInt8]) -> Bool { p.count >= 3 && p[0] == 0xDF && p[1] == 0xFF && p[2] == 0xFF }

    /// Gói đầu khối `DF` (`k0.b`, byte 3 = 0): `[1..2]` số khối LE, `[4..5]` tổng khối LE, `[6]` số gói, `[7]` ngày, `[8]` kiểu đọc,
    /// `[9]` kiểu dữ liệu, `[10]` số byte hợp lệ, `[11..12]` CRC-16/MODBUS LE, `[13]` độ dài mỗi gói (originProtocol 5; khác = 20).
    /// GE54: `DF 01 00 00 21 00 02 00 00 00 EF B9 20 CD` ⇒ khối 1/33, 2 gói, 239 byte, CRC 0x20B9, gói 205 byte.
    public struct DfHeader: Equatable, Sendable {
        public let block: Int
        public let totalBlocks: Int
        public let packets: Int
        public let day: Int
        public let validBytes: Int
        public let crc: Int
        public let packetLength: Int
    }

    public static func parseDfHeader(_ p: [UInt8], protocol5: Bool = true) -> DfHeader? {
        guard p.count >= 14, p[0] == 0xDF, p[3] == 0, !isDfEnd(p) else { return nil }
        return DfHeader(block: Veepoo.le16(p, 1), totalBlocks: Veepoo.le16(p, 4), packets: Int(p[6]), day: Int(p[7]),
                        validBytes: Int(p[10]), crc: Veepoo.le16(p, 11), packetLength: protocol5 && p[13] > 4 ? Int(p[13]) : 20)
    }

    /// Một khối 5 phút đã ghép; `crcOk` = false nếu CRC sai (vẫn trả để log).
    public struct DfBlock: Equatable, Sendable {
        public let header: DfHeader
        public let payload: [UInt8]
        public let crcOk: Bool
    }

    /// Ghép các gói `DF` thành khối: gói đầu (`[3]` = 0) rồi các gói dữ liệu cùng số khối (`[3]` = 1..n), mỗi gói góp byte
    /// 4..<độ dài gói, cắt còn số byte hợp lệ rồi kiểm CRC (như `assembleDf` Android; mã gốc `p1.a()` bị jadx dịch sai).
    public static func assembleDf(_ packets: [[UInt8]], protocol5: Bool = true) -> [DfBlock] {
        var out: [DfBlock] = []
        var header: DfHeader?
        var data: [UInt8] = []
        func flush() {
            guard let h = header else { return }
            if data.count >= h.validBytes {
                let payload = Array(data.prefix(h.validBytes))
                out.append(DfBlock(header: h, payload: payload, crcOk: Veepoo.crc16(payload) == h.crc))
            }
            header = nil
            data = []
        }
        for p in packets where p.count >= 4 && p[0] == 0xDF {
            if isDfEnd(p) { flush(); continue }
            if let h = parseDfHeader(p, protocol5: protocol5) {
                flush()
                header = h
                continue
            }
            guard let cur = header, Veepoo.le16(p, 1) == cur.block else { continue }
            let end = min(cur.packetLength, p.count)
            if end > 4 { data += p[4..<end] }
        }
        flush()
        return out
    }

    /// TLV 1 byte tag + 1 byte độ dài; tag lạ dừng như mã gốc (`C0` / mặc định ⇒ `z10 = false`).
    public static func parseTlv(_ payload: [UInt8]) -> [UInt8: [UInt8]] {
        var out: [UInt8: [UInt8]] = [:]
        var i = 0
        while i + 2 <= payload.count {
            let tag = payload[i]
            guard (0xB1...0xBF).contains(tag) || (0xC1...0xC3).contains(tag) else { break }
            let len = Int(payload[i + 1])
            guard i + 2 + len <= payload.count else { break }
            out[tag] = Array(payload[(i + 2)..<(i + 2 + len)])
            i += 2 + len
        }
        return out
    }

    /// Một bản ghi 5 phút từ TLV khối `DF` (`p1.java:400-504`): `B1` tháng, ngày, giờ, phút (GE54: `0A 13 0F 2D` = 19/10 15:45;
    /// ngày đọc `readDate` chỉ để suy năm), `B2` vận động (bước, lượng vận động, quãng đường m, kcal×10: BE16; tư thế, đeo),
    /// `B4` nhịp tim theo phút, `B8` huyết áp (cao, thấp), `B9` SpO2 (5 giá trị đầu), `B7` HRV (byte 0 kiểu + 50 RR),
    /// `C1` stress, `BF` MET ÷10, `C3` nhiệt độ (LE16 nền, LE16 cơ thể, ÷10, hợp lệ 12,0–48,0 °C), `BE` đường huyết (LE16 ÷100;
    /// kiểu 5: 13 bit thấp, như Android), `C2` thành phần máu (TC, TG, HDL, LDL LE16 ÷100 rồi acid uric LE16 ÷10 — khác thứ tự đo
    /// trực tiếp `8A`, `p1.java:542-555`; toàn 0 = không có). GE54 19/10 15:50: `C2 0A 21 06 D2 04 EA 03 65 06 09 04` ⇒ acid uric
    /// 103,3 µmol/L (G Band hiện 102–108 hôm đó).
    public static func parseFiveMinute(_ payload: [UInt8], readDate: Date, calendar: Calendar = .current,
                                       glucoseRiskBits: Bool = false) -> FiveMinute? {
        let t = parseTlv(payload)
        guard let time = t[0xB1], time.count >= 4, time[0] != 0 || time[1] != 0, time[2] < 24, time[3] < 60 else { return nil }
        let at = dateNear(readDate, month: Int(time[0]), day: Int(time[1]), hour: Int(time[2]), minute: Int(time[3]), calendar: calendar)
            ?? calendar.date(bySettingHour: Int(time[2]), minute: Int(time[3]), second: 0, of: readDate)
        guard let at else { return nil }
        var r = FiveMinute(time: at)
        if let s = t[0xB2], s.count >= 10 {
            r.steps = Veepoo.be16(s, 0)
            r.sport = Veepoo.be16(s, 2)
            r.distanceMeters = Veepoo.be16(s, 4)
            r.calories = Veepoo.be16(s, 6) * 100
            r.wear = Int(s[9])
        }
        r.heartRates = (t[0xB4] ?? []).map(Int.init)
        if let bp = t[0xB8], bp.count >= 2, bp[0] > 0, bp[1] > 0 {
            r.systolic = Int(bp[0])
            r.diastolic = Int(bp[1])
        }
        r.spo2 = (t[0xB9] ?? []).prefix(5).map(Int.init)
        if let s = t[0xC1]?.first, s > 0 { r.stress = Int(s) }
        if let m = t[0xBF]?.first, m > 0 { r.met = Double(m) / 10 }
        if let c = t[0xC3], c.count >= 4, (120...480).contains(Veepoo.le16(c, 2)) { r.temperature = Double(Veepoo.le16(c, 2)) / 10 }
        if let b7 = t[0xB7], b7.count >= 51 {
            r.hrv = hrv5(b7)
            r.rr = (1...50).map { Int(b7[$0]) }
        }
        if let g = t[0xBE], g.count >= 2 {
            let raw = Veepoo.le16(g, 0)
            let v = glucoseRiskBits ? raw & 0x1FFF : raw
            if (100...3000).contains(v) { r.glucose = Double(v) / 100 }
        }
        if let c = t[0xC2], c.count >= 10 {
            let v = VeepooMeasure.BloodComponentValues(
                uricAcid: Double(Veepoo.le16(c, 8)) / 10, totalCholesterol: Double(Veepoo.le16(c, 0)) / 100,
                triglycerides: Double(Veepoo.le16(c, 2)) / 100, hdl: Double(Veepoo.le16(c, 4)) / 100, ldl: Double(Veepoo.le16(c, 6)) / 100
            )
            if !v.isEmpty { r.bloodComponent = v }
        }
        return r
    }

    /// HRV 5 giá trị (mỗi phút) từ 50 RR trong tag `B7`, như `p1.java:620-660` / `hrv5` Android: trung bình |RR(i) − RR(i−1)| × 10
    /// trên các RR hợp lệ 30–210, mod 211.
    public static func hrv5(_ b7: [UInt8]) -> [Int] {
        let rr = (1...50).map { Veepoo.u(b7, $0) }
        return (0..<5).map { g in
            var sum = 0
            var n = 0
            var prev = -1
            for i in (g * 10)..<(g * 10 + 10) where (30...210).contains(rr[i]) {
                if prev != -1 {
                    sum += abs(prev - rr[i])
                    n += 1
                }
                prev = rr[i]
            }
            return n > 0 ? Int((Float(sum * 10) / Float(n)).rounded()) % 211 : 0
        }
    }

    /// `D1 posLo posHi day` (4 byte): pos từ 1, day 0 = hôm nay (`jf/q1.java:153-154`). Chỉ thiết bị originProtocol ∉ {3, 5}.
    public static func d1Request(day: Int, position: Int = 1) -> [UInt8] {
        [0xD1, Veepoo.byte(position), Veepoo.byte(position >> 8), Veepoo.byte(day)]
    }

    /// Bộ đếm gói `D1`/`D2`/`D9`/`D4`: hiện tại LE16 byte 1–2, tổng LE16 byte 3–4.
    public static func counters(_ p: [UInt8]) -> (current: Int, total: Int) { (Veepoo.le16(p, 1), Veepoo.le16(p, 3)) }

    /// Gói cuối của một ngày `D1`: hiện tại = tổng, hoặc tổng = 0, hoặc hiện tại = 0 (`q1.java:276-284`).
    public static func isD1End(_ p: [UInt8]) -> Bool {
        let c = counters(p)
        return c.current == c.total || c.total == 0 || c.current == 0
    }

    /// Một gói `D1` (20 byte) = một bản ghi 5 phút (`jf/q1.java:157-256`; chưa có thiết bị thật để kiểm, GE54 dùng `DF`).
    /// Layout thường: byte 5 = ngày lệch (0 hôm nay, 1 hôm qua, 2 hôm kia), 7 = ngày trong tháng (khác ⇒ bỏ), 8 giờ, 9 phút,
    /// 10–11 bước BE, 12–13 vận động BE, 14 nhịp tim, 15–16 HA cao/thấp; quãng đường + calo tự tính theo chiều cao.
    /// Layout "sport model" (`sportLayout`): byte 5 = ngày × 32 + giờ, 6–7 kcal ×10 BE, 8–9 quãng đường (m) BE, 17 đeo, 19 phút.
    public static func parseD1(_ p: [UInt8], sportLayout: Bool, heightCm: Int = 170, now: Date = Date(), calendar: Calendar = .current) -> FiveMinute? {
        guard p.count >= 20, p[0] == 0xD1, counters(p).total > 0 else { return nil }
        let steps = Veepoo.be16(p, 10)
        var r = FiveMinute(time: now, steps: steps, sport: Veepoo.be16(p, 12))
        if sportLayout {
            let hour = Int(p[5]) % 32
            guard hour < 24, p[19] < 60,
                  let t = calendar.date(bySettingHour: hour, minute: Int(p[19]), second: 0, of: day(Int(p[5]) / 32, from: now, calendar))
            else { return nil }
            r.time = t
            r.calories = Veepoo.be16(p, 6) * 100
            r.distanceMeters = Veepoo.be16(p, 8)
            r.wear = Int(p[17])
        } else {
            let d = day((0...2).contains(Int(p[5])) ? Int(p[5]) : 0, from: now, calendar)
            guard calendar.component(.day, from: d) == Int(p[7]), p[8] < 24, p[9] < 60,
                  let t = calendar.date(bySettingHour: Int(p[8]), minute: Int(p[9]), second: 0, of: d) else { return nil }
            r.time = t
            (r.distanceMeters, r.calories) = estimate(steps: steps, heightCm: heightCm)
        }
        r.heartRates = [Int(p[14])]
        if p[15] > 0, p[16] > 0 {
            r.systolic = Int(p[15])
            r.diastolic = Int(p[16])
        }
        return r
    }

    /// Bản ghi 5 phút → chuỗi lịch sử chuẩn, như `toSeries` Android: STEPS (extra "calories" cal / "distance" m), HEART_RATE và
    /// SPO2 theo phút (30–220 / 70–100), BLOOD_PRESSURE (extra "diastolic"), STRESS, HRV theo phút (extra "rr0"… ms), TEMPERATURE, BLOOD_SUGAR
    /// (mmol/L), MET, URIC_ACID (µmol/L), BLOOD_LIPIDS (value = cholesterol toàn phần, extra 4 chỉ số mỡ máu).
    public static func series(_ records: [FiveMinute]) -> [Capability: [HistoryPoint]] {
        var s: [Capability: [HistoryPoint]] = [:]
        var seen = Set<Date>()
        for r in records.sorted(by: { $0.time < $1.time }) where seen.insert(r.time).inserted {
            func at(_ i: Int) -> Date { r.time.addingTimeInterval(TimeInterval(i * 60)) }
            s[.steps, default: []].append(HistoryPoint(timestamp: r.time, value: Double(r.steps),
                                                       extra: ["calories": Double(r.calories), "distance": Double(r.distanceMeters)]))
            for (i, v) in r.heartRates.enumerated() where (30...220).contains(v) {
                s[.heartRate, default: []].append(HistoryPoint(timestamp: at(i), value: Double(v)))
            }
            for (i, v) in r.spo2.enumerated() where (70...100).contains(v) {
                s[.spo2, default: []].append(HistoryPoint(timestamp: at(i), value: Double(v)))
            }
            if let sys = r.systolic, let dia = r.diastolic {
                s[.bloodPressure, default: []].append(HistoryPoint(timestamp: r.time, value: Double(sys), extra: ["diastolic": Double(dia)]))
            }
            if let st = r.stress { s[.stress, default: []].append(HistoryPoint(timestamp: r.time, value: Double(st))) }
            for (i, v) in r.hrv.enumerated() where v > 0 {
                // Như Android: extra "rr0"… = các RR hợp lệ (30–210) của phút đó, ×10 ⇒ ms.
                let rr = r.rr.dropFirst(i * 10).prefix(10).filter { (30...210).contains($0) }
                let extra = Dictionary(uniqueKeysWithValues: rr.enumerated().map { ("rr\($0.offset)", Double($0.element * 10)) })
                s[.hrv, default: []].append(HistoryPoint(timestamp: at(i), value: Double(v), extra: extra))
            }
            if let t = r.temperature { s[.temperature, default: []].append(HistoryPoint(timestamp: r.time, value: t)) }
            if let g = r.glucose { s[.bloodSugar, default: []].append(HistoryPoint(timestamp: r.time, value: g)) }
            if let m = r.met { s[.met, default: []].append(HistoryPoint(timestamp: r.time, value: m)) }
            if let b = r.bloodComponent {
                if b.uricAcid > 0 { s[.uricAcid, default: []].append(HistoryPoint(timestamp: r.time, value: b.uricAcid)) }
                if b.totalCholesterol > 0 || b.triglycerides > 0 || b.hdl > 0 || b.ldl > 0 {
                    s[.bloodLipids, default: []].append(HistoryPoint(timestamp: r.time, value: b.totalCholesterol, extra: b.lipids))
                }
            }
        }
        return s.mapValues(DeviceHistory.normalized)
    }

    /// Tổng hôm nay từ chuỗi bước 5 phút (khi `D8` / `A8` không trả lời), như Android.
    public static func todayTotals(_ series: [Capability: [HistoryPoint]], now: Date = Date(), calendar: Calendar = .current) -> ActivityTotals? {
        let start = calendar.startOfDay(for: now)
        guard let pts = series[.steps]?.filter({ $0.timestamp >= start }), !pts.isEmpty else { return nil }
        return ActivityTotals(steps: Int(pts.reduce(0) { $0 + $1.value }), calories: Int(pts.reduce(0) { $0 + ($1.extra["calories"] ?? 0) }),
                              distanceMeters: Int(pts.reduce(0) { $0 + ($1.extra["distance"] ?? 0) }))
    }

    // MARK: - Ngủ (E0)

    /// `E0 day` (2 byte, `jf/c2.java:56`).
    public static func sleepRequest(day: Int) -> [UInt8] { [0xE0, Veepoo.byte(day)] }

    /// Gói `E0` 20 byte: byte 1 = số gói còn lại (0 = gói cuối), 2 = số bản ghi, 3 = ngày, 4–19 dữ liệu (`VOM:1707-1767`).
    public static func isSleepEnd(_ p: [UInt8]) -> Bool { p.count >= 20 && p[0] == 0xE0 && p[1] == 0 }

    /// Ghép byte 4–19 của mọi gói `E0`.
    public static func sleepPayload(_ packets: [[UInt8]]) -> [UInt8] {
        packets.filter { $0.count >= 20 && $0[0] == 0xE0 }.flatMap { $0[4..<20] }
    }

    public static func stage(_ code: Int) -> SleepStage {
        switch code {
        case 0: .deep
        case 1: .light
        case 2: .rem
        case 3, 4: .awake
        default: .unknown
        }
    }

    /// Gom các điểm liên tiếp cùng giai đoạn; mỗi điểm `secondsPerPoint` giây, phút làm tròn (như `preciseToSession` Android).
    static func segments(_ stages: [SleepStage], start: Date, secondsPerPoint: Int) -> [SleepSegment] {
        var out: [SleepSegment] = []
        var i = 0
        while i < stages.count {
            var j = i
            while j < stages.count, stages[j] == stages[i] { j += 1 }
            let minutes = ((j - i) * secondsPerPoint + 30) / 60
            if minutes > 0 {
                out.append(SleepSegment(start: start.addingTimeInterval(TimeInterval(i * secondsPerPoint)), minutes: minutes, stage: stages[i]))
            }
            i = j
        }
        return out
    }

    /// Ngủ thường (`kf/b.java`, sleepTag = 0): dữ liệu ghép chia bản ghi 96 byte (số bản ghi ở byte 2 của gói).
    public static func parseNormalSleep(_ packets: [[UInt8]], day: Int, now: Date = Date(), calendar: Calendar = .current) -> [SleepSession] {
        let data = sleepPayload(packets)
        let readDate = Self.day(day, from: now, calendar)
        return stride(from: 0, to: data.count - 95, by: 96).compactMap {
            parseNormalSleepRecord(Array(data[$0..<($0 + 96)]), readDate: readDate, calendar: calendar)
        }
    }

    /// Một bản ghi ngủ thường 96 byte (`kf/b.java:21-104`): 1–4 giờ ngủ (M D h m), 5–8 giờ dậy, 9 sâu ×5 phút, 10 nông ×5,
    /// 11 chất lượng (255 = bỏ), 12–42 đường ngủ 248 bit (MSB trước, mỗi bit 5 phút), 43 số điểm hợp lệ (≤ 248), 55 số đoạn
    /// thức, 45+k / 57+k điểm đầu / cuối đoạn thức (bản gốc chỉ đánh dấu khi có ngủ sâu và số mức nông ≥ độ dài đoạn).
    /// Bit 0/1 = nông/sâu chưa kiểm trên thiết bị (Q4; GE54 dùng ngủ chính xác): Android cố định 1 = sâu; ở đây chọn cách khớp
    /// số mức sâu (byte 9) nhất, hoà thì 1 = sâu.
    public static func parseNormalSleepRecord(_ r: [UInt8], readDate: Date, calendar: Calendar = .current) -> SleepSession? {
        guard r.count >= 67, r[11] != 255,
              let down = dateNear(readDate, month: Int(r[1]), day: Int(r[2]), hour: Int(r[3]), minute: Int(r[4]), calendar: calendar),
              let up = dateNear(readDate, month: Int(r[5]), day: Int(r[6]), hour: Int(r[7]), minute: Int(r[8]), calendar: calendar),
              down < up else { return nil }
        let points = min(Int(r[43]), 248)
        var bits: [Int] = []
        for b in r[12..<43] { for k in (0..<8).reversed() { bits.append(Int(b >> UInt8(k)) & 1) } }
        bits = Array(bits.prefix(points))
        let deep = Int(r[9])
        let light = Int(r[10])
        if deep != 0 {
            for k in 0..<min(Int(r[55]), 10) {
                let s = Int(r[45 + k])
                let len = Int(r[57 + k]) - s
                guard len > 0, light >= len else { continue }
                for i in s..<min(s + len, bits.count) { bits[i] = 2 }
            }
        }
        let ones = bits.filter { $0 == 1 }.count
        let oneIsDeep = abs(ones - deep) <= abs(ones - light)
        let stages: [SleepStage] = bits.map {
            switch $0 {
            case 2: .awake
            case 1: oneIsDeep ? .deep : .light
            default: oneIsDeep ? .light : .deep
            }
        }
        return SleepSession(start: down, end: up, segments: segments(stages, start: down, secondsPerPoint: 300))
    }

    /// Một giấc ngủ chính xác (`A3` tóm tắt + đường ngủ `A5`), như `PreciseSleep` Android.
    public struct PreciseSleep: Equatable, Sendable {
        public var start: Date
        public var end: Date
        public var quality: Int
        public var wakeCount: Int
        public var deepMinutes: Int
        public var lightMinutes: Int
        public var totalMinutes: Int
        /// 2 = đường ngủ 2 bit / điểm; khác = 16 bit / điểm.
        public var accurateType: Int
        public var pointSeconds: Int
        /// Mã giai đoạn mỗi điểm: 0 sâu, 1 nông, 2 REM, 3 thức / mất ngủ, 4 thức dậy (`PrecisionSleepView.java:184-251`).
        public var line: [Int]

        public var session: SleepSession {
            var segs = VeepooHistory.segments(line.map(VeepooHistory.stage), start: start, secondsPerPoint: pointSeconds)
            if segs.isEmpty, end > start {
                // Không có đường ngủ: chỉ tổng sâu / nông.
                if deepMinutes > 0 { segs.append(SleepSegment(start: start, minutes: deepMinutes, stage: .deep)) }
                if lightMinutes > 0 {
                    segs.append(SleepSegment(start: start.addingTimeInterval(TimeInterval(deepMinutes * 60)), minutes: lightMinutes, stage: .light))
                }
            }
            return SleepSession(start: start, end: end, segments: segs)
        }
    }

    /// Ngủ chính xác (sleepTag ≠ 0, `kf/c.java`): tìm khối `A1 lenLE16` (độ dài gồm 3 byte đầu). **Kiểm trên GE54 (Android,
    /// 19/10/2026): độ dài là LE16** (`A1 24 03` = 804 byte; jadx cho ra BE, sai với thiết bị thật). Trong khối: TLV `A2`..`A7`
    /// độ dài 1 byte, riêng `A5` (đường ngủ) độ dài LE16 = số byte; khi accurateType (byte cuối `A3`) = 2 thì mỗi byte gói 4 điểm
    /// 2 bit (MSB trước, chưa kiểm) và độ dài là số điểm; còn lại mỗi điểm là từ BE16, giai đoạn ở bit 15..13 (GE54: `20 00` nông,
    /// `40 00` REM, `80 00` thức dậy, `00 00` sâu, khớp tổng trong `A3`).
    public static func parsePrecise(_ payload: [UInt8], readDate: Date, calendar: Calendar = .current) -> [PreciseSleep] {
        var records: [[UInt8]] = []
        var i = 0
        while i < payload.count {
            if payload[i] == 0xA1, i + 3 <= payload.count {
                let len = Veepoo.le16(payload, i + 1)
                if len >= 3, i + len <= payload.count {
                    records.append(Array(payload[(i + 3)..<(i + len)]))
                    i += len
                    continue
                }
            }
            i += 1
        }
        return records.compactMap { parsePreciseRecord($0, readDate: readDate, calendar: calendar) }
    }

    public static func parsePreciseSleep(_ packets: [[UInt8]], day: Int, now: Date = Date(), calendar: Calendar = .current) -> [SleepSession] {
        parsePrecise(sleepPayload(packets), readDate: Self.day(day, from: now, calendar), calendar: calendar).map(\.session)
    }

    public static func parsePreciseRecord(_ rec: [UInt8], readDate: Date, calendar: Calendar = .current) -> PreciseSleep? {
        var summary: [UInt8]?
        var curve: [UInt8]?
        var curvePoints = 0
        var packed = false
        var i = 0
        while i < rec.count, (0xA1...0xA7).contains(rec[i]) {
            let tag = rec[i]
            i += 1
            if tag == 0xA5 {
                guard i + 2 <= rec.count else { break }
                let n = Veepoo.le16(rec, i)
                i += 2
                let bytes = packed ? (n + 3) / 4 : n
                guard i + bytes <= rec.count else { break }
                curve = Array(rec[i..<(i + bytes)])
                curvePoints = packed ? n : n / 2
                i += bytes
            } else {
                guard i < rec.count else { break }
                let n = Int(rec[i])
                i += 1
                guard i + n <= rec.count else { break }
                let v = Array(rec[i..<(i + n)])
                if tag == 0xA3 {
                    summary = v
                    packed = v.last == 2
                }
                i += n
            }
        }
        guard let s = summary, s.count >= 36,
              let start = dateNear(readDate, month: Int(s[0]), day: Int(s[1]), hour: Int(s[2]), minute: Int(s[3]), calendar: calendar),
              let end = dateNear(readDate, month: Int(s[4]), day: Int(s[5]), hour: Int(s[6]), minute: Int(s[7]), calendar: calendar)
        else { return nil }
        let accurate = Int(s[35])
        var stages: [Int] = []
        if let c = curve {
            if accurate == 2 {
                for b in c { for shift in [6, 4, 2, 0] { let v = Int(b >> UInt8(shift)) & 3; stages.append(v == 3 ? 4 : v) } }
                stages = Array(stages.prefix(curvePoints))
            } else {
                for k in stride(from: 0, to: c.count - 1, by: 2) { stages.append(min((Veepoo.be16(c, k) & 0xE000) >> 13, 4)) }
            }
        }
        let total = Veepoo.le16(s, 25)
        let pointSeconds = Veepoo.le16(s, 33)
        return PreciseSleep(
            start: start, end: end, quality: Int(s[15]), wakeCount: Int(s[16]), deepMinutes: Veepoo.le16(s, 19),
            lightMinutes: Veepoo.le16(s, 21), totalMinutes: total, accurateType: accurate,
            pointSeconds: (1...600).contains(pointSeconds) ? pointSeconds : 60,
            line: total >= 1 && total < stages.count ? Array(stages.prefix(total)) : stages
        )
    }

    // MARK: - Buổi tập (D3 / D4)

    /// `D3 01` + 0: CRC LE16 của từng khe buổi tập (`jf/k2.java:51-113`).
    public static let sportCrcRead = Veepoo.padded(20, [0xD3, 0x01])

    /// `D3 01 xx c0lo c0hi c1lo c1hi …` → CRC từng khe (`slots` = A7 trang 2 byte 5). nil nếu đọc lỗi (`[1]` = 0) / không phải gói.
    public static func parseSportCrc(_ p: [UInt8], slots: Int) -> [Int]? {
        guard p.count >= 3, p[0] == 0xD3, p[1] == 1 else { return nil }
        return (0..<slots).map { Veepoo.le16(p, 3 + $0 * 2) }
    }

    /// `D4 slot` + 0 (`jf/j2.java:117-128`).
    public static func workoutRequest(slot: Int) -> [UInt8] { Veepoo.padded(20, [0xD4, Veepoo.byte(slot)]) }

    /// Gói cuối buổi tập: hiện tại = tổng (`j2.java:166`).
    public static func isWorkoutEnd(_ p: [UInt8]) -> Bool {
        guard p.count >= 5, p[0] == 0xD4 else { return false }
        let c = counters(p)
        return c.current == c.total
    }

    /// Buổi tập kiểu cổ điển (`j2.java:170-262`, không phải đồng hồ GPS): 3 gói đầu ghép byte 6–19 thành header 42 byte —
    /// 1–2 năm LE + 3–7 M D h m s (bắt đầu), 8–9 năm + 10–14 (kết thúc), 15–18 bước LE32, 19–22 quãng đường (m) LE32,
    /// 23–26 calo (cal, `Workout.calories` là kcal ⇒ ÷1000 như Android) LE32, 27–30 vận động, 31–32 số bản ghi, 33 số lần dừng, 34–35 thời gian dừng (s) LE16, 36–37 CRC,
    /// 38 môn. Các gói sau mỗi gói một phút, byte 6 = nhịp tim.
    public static func parseWorkout(_ packets: [[UInt8]], calendar: Calendar = .current) -> Workout? {
        let ps = packets.filter { $0.count >= 20 && $0[0] == 0xD4 }
        guard ps.count >= 3 else { return nil }
        let h = ps.prefix(3).flatMap { $0[6..<20] }
        func time(_ at: Int) -> Date? {
            let year = Veepoo.le16(h, at)
            guard year > 2000 else { return nil }
            return calendar.date(from: DateComponents(year: year, month: Int(h[at + 2]), day: Int(h[at + 3]),
                                                      hour: Int(h[at + 4]), minute: Int(h[at + 5]), second: Int(h[at + 6])))
        }
        guard let start = time(1), let end = time(8), end >= start else { return nil }
        let duration = Int(end.timeIntervalSince(start))
        let pause = Veepoo.le16(h, 34)
        let rates = ps.dropFirst(3).map { Int($0[6]) }.filter { (30...200).contains($0) }
        let type = Int(h[38])
        let distance = Veepoo.le32(h, 19)
        let active = max(0, duration - pause)
        return Workout(
            type: type, name: sportName(type), start: start, end: end, activeSeconds: active, steps: Veepoo.le32(h, 15),
            calories: Veepoo.le32(h, 23) / 1000, distanceMeters: distance,
            avgHeartRate: rates.isEmpty ? nil : rates.reduce(0, +) / rates.count, maxHeartRate: rates.max(), minHeartRate: rates.min(),
            paceSecondsPerKm: distance > 0 ? Int(Double(active) / (Double(distance) / 1000)) : nil
        )
    }

    /// Buổi tập kiểu thể thao 4/5/6 (đồng hồ GPS, nhẫn; GE54 = 5), như `parseTlvWorkout` Android (`j2.java`): bỏ 5 byte đầu
    /// mỗi gói `D4` rồi ghép; `A1 len` = đầu bài: bắt đầu / kết thúc epoch giây LE32 ở byte 4 / 8, thời lượng giây LE32 ở 12,
    /// bước / quãng đường (m) / calo (cal) / số lần LE32 ở 18 / 22 / 26 / 30, nhịp tim max / tb / min ở 34 / 35 / 36, pace max / tb /
    /// min LE16 ở 37 / 39 / 41; byte 17 = độ dài phần `B2`, môn LE16 ở byte 17 + 31 (tag `B5`).
    /// GE54 (Android 19/10/2026, khe 1): 1352 s, 2712 bước, 2313 m, 143 kcal, HR 150/122/83.
    public static func parseTlvWorkout(_ packets: [[UInt8]]) -> Workout? {
        let b = packets.filter { $0.first == 0xD4 && $0.count > 5 }.flatMap { $0[5...] }
        guard b.count >= 43, b[0] == 0xA1 else { return nil }
        let len = Int(b[1]) + 2
        guard len <= b.count else { return nil }
        let start = Veepoo.le32(b, 4)
        let end = Veepoo.le32(b, 8)
        guard start > 0, end >= start else { return nil }
        let hl = Int(b[17])
        let type = hl + 32 < len ? Veepoo.le16(b, hl + 31) : 0
        func positive(_ v: Int) -> Int? { v > 0 ? v : nil }
        return Workout(
            type: type, name: sportName(type), start: Date(timeIntervalSince1970: TimeInterval(start)),
            end: Date(timeIntervalSince1970: TimeInterval(end)), activeSeconds: Veepoo.le32(b, 12), steps: Veepoo.le32(b, 18),
            calories: Veepoo.le32(b, 26) / 1000, distanceMeters: Veepoo.le32(b, 22),
            avgHeartRate: positive(Int(b[35])), maxHeartRate: positive(Int(b[34])), minHeartRate: positive(Int(b[36])),
            paceSecondsPerKm: positive(Veepoo.le16(b, 39))
        )
    }

    // MARK: - Thành phần cơ thể đã lưu (`93 05` / `93 06`)

    /// `93 05 01`: danh sách id bản ghi thành phần cơ thể (`jf/i.java:63-127`).
    public static let bodyCompositionIdsRead = Veepoo.padded(20, [0x93, 0x05, 0x01])

    /// Phản hồi `93 05 …`: `[4]` số bản ghi (≤ 7), id LE16 từ `[5]`. `[2]` = A1 là báo bản ghi mới (nil).
    public static func parseBodyCompositionIds(_ p: [UInt8]) -> [Int]? {
        guard p.count >= 5, p[0] == 0x93, p[1] == 0x05, p[2] != 0xA1 else { return nil }
        let n = min(Int(p[4]), 7)
        var ids: [Int] = []
        for i in 0..<n {
            let at = 5 + i * 2
            if at + 1 < p.count { ids.append(Veepoo.le16(p, at)) }
        }
        return ids
    }

    /// `93 06 01 idLo idHi`: đọc một bản ghi (`jf/j.java:67-165`).
    public static func bodyCompositionRecordRead(id: Int) -> [UInt8] {
        Veepoo.padded(20, [0x93, 0x06, 0x01, Veepoo.byte(id), Veepoo.byte(id >> 8)])
    }

    /// Gói cuối bản ghi `93 06 kiểu idx total …`.
    public static func isBodyCompositionRecordEnd(_ p: [UInt8]) -> Bool { p.count >= 5 && p[0] == 0x93 && p[1] == 0x06 && p[3] >= p[4] }

    /// Bản ghi `93 06` (15 byte từ `[5]` mỗi gói): `A0 len` + 14 chỉ số (như đo nhanh), rồi `A1 07 năm-2000 M D h m s thời-lượng`.
    /// Năm = 2000 + byte (jadx ghi `b + ACTION_RECODING`, suy luận; chưa đối chiếu gói thật). Ngày 0 ⇒ bỏ.
    public static func parseBodyCompositionRecord(_ packets: [[UInt8]], calendar: Calendar = .current) -> HistoryPoint? {
        let ps = packets.filter { $0.count >= 5 && $0[0] == 0x93 && $0[1] == 0x06 }.sorted { $0[3] < $1[3] }
        let b = ps.flatMap { $0.count > 5 ? Array($0[5..<min($0.count, 20)]) : [] }
        guard b.count >= 39, let values = VeepooMeasure.parseBodyComposition(b), b[30] == 0xA1 else { return nil }
        guard b[33] != 0 || b[34] != 0,
              let t = calendar.date(from: DateComponents(year: 2000 + Int(b[32]), month: Int(b[33]), day: Int(b[34]), hour: Int(b[35]),
                                                         minute: Int(b[36]), second: Int(b[37]))) else { return nil }
        return HistoryPoint(timestamp: t, value: values["bodyFatRate"] ?? 0, extra: values)
    }

    /// Tên môn theo `ESportType` (môn thường gặp).
    public static func sportName(_ type: Int) -> String {
        let names: [Int: String] = [
            1: "Chạy ngoài trời", 2: "Đi bộ ngoài trời", 3: "Chạy trong nhà", 4: "Đi bộ trong nhà", 5: "Leo núi", 6: "Máy chạy bộ",
            7: "Đạp xe ngoài trời", 8: "Đạp xe trong nhà", 9: "Máy elip", 10: "Máy chèo thuyền", 12: "Bơi", 14: "Trượt tuyết",
            15: "Nhảy dây", 16: "Yoga", 17: "Bóng bàn", 18: "Bóng rổ", 19: "Bóng chuyền", 20: "Bóng đá", 21: "Cầu lông", 22: "Quần vợt",
            23: "Leo cầu thang", 24: "Thể hình", 25: "Cử tạ", 27: "Quyền anh", 31: "Khiêu vũ", 32: "HIIT",
        ]
        return names[type] ?? "Bài tập (môn \(type))"
    }
}
