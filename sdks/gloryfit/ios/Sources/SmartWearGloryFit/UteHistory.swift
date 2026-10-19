import Foundation
import SmartWearCore

// Lịch sử UTE (01-protocol.md §4.2, §5.3), bản iOS của phần lịch sử trong `Ute.kt` + chọn lệnh theo bit tính năng
// (docs/feature-matrix.md việc 9). Hàm thuần, không I/O.

public extension Ute.Features {
    /// `isHasResolveSleep` (33F1 b8.2 = F4 `0x040000`): ngủ do thuật toán trên đồng hồ, lấy bằng `31 01`.
    /// SDK mới (`uterkif/uterkint.java:72`) không gửi `B3 FA` khi có bit này.
    var resolveSleep: Bool { has(4, 0x040000) }
    /// Thuật toán CyWee (34F1 b19.5 = F8 `0x000020`, `RkSupportUtils.isSupCywee`, chỉ Y25): bước qua `EB 02 FA`
    /// trên 34F1, ngủ qua `EC 01` (`uterkif/uterkthis.java:2884-2902`).
    var cywee: Bool { has(8, 0x000020) }
}

public extension Ute {
    /// Một lệnh đồng bộ lịch sử: byte gửi, kênh ghi, gói nào thuộc luồng, gói nào kết thúc luồng.
    enum SyncCommand: String, Sendable, CaseIterable {
        /// `B2 FA` → `B2 YYYY MM DD HH sH sL …` … `B2 FD`.
        case stepsHourly
        /// `EB 02 FA` ghi vào 34F1 → `EB 02 YYYY MM DD HH sH sL dH dL cal(3)` … `EB 02 FD xx` (CyWee).
        case stepsCywee
        /// `B3 FA` → `B3 YYYY MM DD hh mm rH rL` (hoặc 14 byte gộp giờ) … `B3 FD crc`.
        case sleepRoll
        /// `31 01` → mỗi ngày `31 01 YYYY MM DD n` + các gói `32 <đoạn 6 byte…>`, kết thúc `31 02`.
        case sleepResolve
        /// `EC 01` → mỗi ngày `EC 01 YYYY MM DD n` + các gói `EC 02 <đoạn 6 byte…>`, kết thúc `EC 03` (CyWee).
        case sleepCywee
        /// `F7 FA` → `F7 YYYY MM DD HH v0…v11` … `F7 FD`.
        case heartRate24h
        /// `E6 FA` → `E6 YYYY MM DD hh mm rr` … `E6 FD`.
        case heartRate
        /// `34 FA` → `34 FA YYYY MM DD HH xx v0…v11` … `34 FA FD crc`.
        case spo2
        /// `C8 FA` → `C8 YYYY MM DD hh mm sys dia` … `C8 FD`.
        case bloodPressure

        public var bytes: [UInt8] {
            switch self {
            case .stepsHourly: return [0xB2, 0xFA]
            case .stepsCywee: return [0xEB, 0x02, 0xFA]
            case .sleepRoll: return [0xB3, 0xFA]
            case .sleepResolve: return [0x31, 0x01]
            case .sleepCywee: return [0xEC, 0x01]
            case .heartRate24h: return [0xF7, 0xFA]
            case .heartRate: return [0xE6, 0xFA]
            case .spo2: return [0x34, 0xFA]
            case .bloodPressure: return [0xC8, 0xFA]
            }
        }

        /// Ghi vào 34F1 (kênh BLE5) thay vì 33F1 (`writeCharaBle5` trong app cũ). Phản hồi đến ở 33F2 hoặc 34F2.
        public var usesBle5: Bool { self == .stepsCywee }

        /// Gói thô nối nhau (`32 …`, `EC 02 …`): không bỏ gói trùng như các luồng bản ghi.
        public var dedupe: Bool { self != .sleepResolve && self != .sleepCywee }

        public var hex: String { bytes.map { String(format: "%02X", $0) }.joined(separator: " ") }

        public func matches(_ p: [UInt8]) -> Bool {
            guard let op = p.first else { return false }
            switch self {
            case .stepsCywee: return op == 0xEB && p.count >= 2 && p[1] == 0x02
            case .sleepResolve: return op == 0x32 || (op == 0x31 && p.count >= 2 && (p[1] == 0x01 || p[1] == 0x02))
            case .sleepCywee: return op == 0xEC && p.count >= 2 && (1...3).contains(p[1])
            default: return op == bytes[0]
            }
        }

        public func isEnd(_ p: [UInt8]) -> Bool {
            switch self {
            case .stepsCywee: return p.count >= 3 && p[0] == 0xEB && p[1] == 0x02 && p[2] == 0xFD
            case .sleepResolve: return p.count >= 2 && p[0] == 0x31 && p[1] == 0x02
            case .sleepCywee: return p.count >= 2 && p[0] == 0xEC && p[1] == 0x03
            default: return Ute.isEnd(bytes[0], p)
            }
        }
    }

    /// Lệnh đồng bộ theo bảng tính năng. Mỗi mục là danh sách thử lần lượt: lệnh sau chỉ dùng khi lệnh trước
    /// **không có gói nào** (kể cả gói kết thúc) — đường mới chưa kiểm chứng trên đồng hồ nên giữ lệnh cũ làm dự phòng.
    struct SyncPlan: Sendable, Equatable {
        public var steps: [SyncCommand]
        public var sleep: [SyncCommand]
        public var heartRate: SyncCommand?
        public var spo2: SyncCommand?
        public var bloodPressure: SyncCommand?

        public init(features f: Features, capabilities caps: Set<Capability>) {
            steps = f.cywee ? [.stepsCywee, .stepsHourly] : [.stepsHourly]
            if caps.contains(.sleep) {
                // Như SDK mới (`uterkthis.uterksuper`): CyWee ⇒ `EC 01`; còn lại `31 01` khi có bit thuật toán, không thì `B3 FA`.
                sleep = (f.cywee ? [.sleepCywee] : []) + (f.resolveSleep ? [.sleepResolve] : []) + [.sleepRoll]
            } else {
                sleep = []
            }
            heartRate = caps.contains(.heartRate) ? (f.heartRate24h ? .heartRate24h : .heartRate) : nil
            spo2 = caps.contains(.spo2) ? .spo2 : nil
            bloodPressure = caps.contains(.bloodPressure) ? .bloodPressure : nil
        }
    }

    // MARK: - Bản ghi

    /// Bước theo giờ: `B2 YYYY MM DD HH sH sL [+ chạy/đi]`.
    static func parseSteps(_ packets: [[UInt8]], calendar: Calendar = .current) -> [HistoryPoint] {
        packets.compactMap { p in
            guard p.count >= 8, p[0] == 0xB2, p[1] != 0xFD,
                  let ts = date(calendar, be16(p, 1), u(p, 3), u(p, 4), u(p, 5), 0) else { return nil }
            return HistoryPoint(timestamp: ts, value: Double(be16(p, 6)))
        }
    }

    /// Bước theo giờ CyWee: `EB 02 YYYY MM DD HH sH sL dH dL c c c` (`SWAlgorithmUtil`: quãng đường m, calo cal, BE).
    static func parseCyweeSteps(_ packets: [[UInt8]], calendar: Calendar = .current) -> [HistoryPoint] {
        packets.compactMap { p in
            guard p.count >= 9, p[0] == 0xEB, p[1] == 0x02, p[2] != 0xFD, be16(p, 2) > 0,
                  let ts = date(calendar, be16(p, 2), u(p, 4), u(p, 5), u(p, 6), 0) else { return nil }
            return HistoryPoint(timestamp: ts, value: Double(be16(p, 7)), extra: cyweeExtra(p))
        }
    }

    /// extra "distance" (m), "calories" (cal) của một giờ `EB 01`/`EB 02`. Calo do đồng hồ (CyWee) tự tính, gói ghi
    /// kcal×1000; app chính hãng **không** tính lại từ bước/hồ sơ, chỉ lấy `round1(raw / 1000)` kcal mỗi giờ rồi cộng
    /// (GloryFit `SWAlgorithmUtil.java:47-49`, Pro `uterkint/uterkgoto.java:17-19`) ⇒ làm tròn tới 100 cal (0,1 kcal).
    static func cyweeExtra(_ p: [UInt8]) -> [String: Double] {
        var extra: [String: Double] = [:]
        if p.count >= 11 { extra["distance"] = Double(be16(p, 9)) }
        if p.count >= 14 { extra["calories"] = Double(cyweeCalories(be24(p, 11))) }
        return extra
    }

    /// kcal×1000 của gói CyWee → cal, làm tròn 0,1 kcal như app (`TempratureUtils.roundingToFloat(1, …)`, nửa lên).
    static func cyweeCalories(_ raw: Int) -> Int { (raw + 50) / 100 * 100 }

    /// Tổng hôm nay (CyWee, Y25): cộng các giờ `EB 02` của hôm nay + giờ đang chạy `EB 01` (cùng định dạng, chưa có
    /// trong `EB 02`). Bước, quãng đường (m), calo theo cal (gói ghi kcal×1000). Như GloryFit `FragmentHomePage.updateSteps`
    /// (`:1385-1426`, cộng thêm bài tập) và GloryFitPro `MainHomePresenter` (`:44-83`): tổng = Σ calo từng giờ của đồng hồ.
    static func todayTotals(hourly: [HistoryPoint], current: [UInt8]?, calendar: Calendar = .current, now: Date = Date()) -> ActivityTotals? {
        var points = hourly.filter { calendar.isDate($0.timestamp, inSameDayAs: now) }
        if let p = current, p.count >= 9, p[0] == 0xEB, p[1] == 0x01,
           let ts = date(calendar, be16(p, 2), u(p, 4), u(p, 5), u(p, 6), 0),
           calendar.isDate(ts, inSameDayAs: now), !points.contains(where: { $0.timestamp == ts }) {
            points.append(HistoryPoint(timestamp: ts, value: Double(be16(p, 7)), extra: cyweeExtra(p)))
        }
        guard !points.isEmpty else { return nil }
        let steps = points.reduce(0) { $0 + $1.value }
        let distance = points.reduce(0) { $0 + ($1.extra["distance"] ?? 0) }
        // cal (gói ghi kcal×1000), theo quy ước `ActivityTotals.calories`; UI/RN tự chia 1000.
        let calories = points.reduce(0) { $0 + ($1.extra["calories"] ?? 0) }
        return ActivityTotals(steps: Int(steps), calories: Int(calories.rounded()), distanceMeters: Int(distance))
    }

    /// Nhịp tim từng lần đo: `E6 YYYY MM DD hh mm rr`.
    static func parseHeartRate(_ packets: [[UInt8]], calendar: Calendar = .current) -> [HistoryPoint] {
        packets.compactMap { p in
            guard p.count >= 8, p[0] == 0xE6, p[1] != 0xFD, (30...220).contains(Int(p[7])),
                  let ts = date(calendar, be16(p, 1), u(p, 3), u(p, 4), u(p, 5), u(p, 6)) else { return nil }
            return HistoryPoint(timestamp: ts, value: Double(p[7]))
        }
    }

    /// Nhịp tim 24h: `F7 YYYY MM DD HH v0…v11`, ô byte b (6..17) ở phút HH×60 − (17−b)×10; chỉ 40 < v < 200.
    static func parseHeartRate24h(_ packets: [[UInt8]], calendar: Calendar = .current) -> [HistoryPoint] {
        packets.filter { $0.count >= 7 && $0[0] == 0xF7 && $0[1] == 0x07 }.flatMap { p -> [HistoryPoint] in
            let hour = u(p, 5)
            return (6..<min(p.count, 18)).compactMap { b in
                let v = u(p, b)
                guard v > 40, v < 200, let ts = date(calendar, be16(p, 1), u(p, 3), u(p, 4), 0, hour * 60 - (17 - b) * 10) else { return nil }
                return HistoryPoint(timestamp: ts, value: Double(v))
            }
        }
    }

    /// SpO2: `34 FA YYYY MM DD HH xx v0…v11`, ô i (byte 8+i) ở phút HH×60 − (11−i)×10, FF = trống.
    static func parseSpo2(_ packets: [[UInt8]], calendar: Calendar = .current) -> [HistoryPoint] {
        packets.filter { $0.count >= 9 && $0[0] == 0x34 && $0[1] == 0xFA && $0[2] != 0xFD }.flatMap { p -> [HistoryPoint] in
            let hour = u(p, 6)
            return (0..<12).compactMap { i in
                guard 8 + i < p.count else { return nil }
                let v = u(p, 8 + i)
                guard v != 0xFF, v != 0, let ts = date(calendar, be16(p, 2), u(p, 4), u(p, 5), 0, hour * 60 - (11 - i) * 10) else { return nil }
                return HistoryPoint(timestamp: ts, value: Double(min(max(v, 70), 100)))
            }
        }
    }

    /// Huyết áp: `C8 YYYY MM DD hh mm sys dia` (`DataProcessing.java:1733-1735`). value = tâm thu, extra "diastolic".
    static func parseBloodPressure(_ packets: [[UInt8]], calendar: Calendar = .current) -> [HistoryPoint] {
        packets.compactMap { p in
            guard p.count >= 9, p[0] == 0xC8, p[1] != 0xFD else { return nil }
            let sys = u(p, 7), dia = u(p, 8)
            guard (50...250).contains(sys), (30...200).contains(dia),
                  let ts = date(calendar, be16(p, 1), u(p, 3), u(p, 4), u(p, 5), u(p, 6)) else { return nil }
            return HistoryPoint(timestamp: ts, value: Double(sys), extra: ["diastolic": Double(dia)])
        }
    }

    // MARK: - Ngủ

    /// Ngủ (định dạng thường): `B3 YYYY MM DD hh mm rH rL`, r = số lần cử động ("roll count") của đoạn.
    /// Phân loại rút gọn theo app: r ≤ 3 sâu, ≤ 40 nông, lớn hơn là thức (suy luận, xem doc §5.3).
    /// Các mốc cách nhau quá 2 giờ được tách thành phiên khác nhau.
    static func parseSleep(_ packets: [[UInt8]], calendar: Calendar = .current, hourlyFormat: Bool = false) -> [SleepSession] {
        let records = packets.filter { $0.count >= 9 && $0[0] == 0xB3 && $0[1] != 0xFD }
        var marks: [(Date, Int)]
        if hourlyFormat {
            // 14 byte: `B3 YYYY MM DD hh (m, r)×4`, FF FF = ô trống.
            marks = records.flatMap { p -> [(Date, Int)] in
                (0..<4).compactMap { k in
                    let i = 6 + k * 2
                    guard i + 1 < p.count, !(p[i] == 0xFF && p[i + 1] == 0xFF),
                          let ts = date(calendar, be16(p, 1), u(p, 3), u(p, 4), u(p, 5), u(p, i)) else { return nil }
                    return (ts, u(p, i + 1))
                }
            }
        } else {
            marks = records.compactMap { p in
                date(calendar, be16(p, 1), u(p, 3), u(p, 4), u(p, 5), u(p, 6)).map { ($0, be16(p, 7)) }
            }
        }
        marks.sort { $0.0 < $1.0 }
        var sessions: [SleepSession] = []
        var current: [(Date, Int)] = []
        func flush() {
            if current.count >= 2 {
                let segments = zip(current, current.dropFirst()).map { a, b -> SleepSegment in
                    let stage: SleepStage = a.1 <= 3 ? .deep : (a.1 <= 40 ? .light : .awake)
                    return SleepSegment(start: a.0, minutes: Int(b.0.timeIntervalSince(a.0) / 60), stage: stage)
                }
                sessions.append(SleepSession(start: current[0].0, end: current[current.count - 1].0, segments: segments))
            }
            current = []
        }
        for m in marks {
            if let last = current.last, m.0.timeIntervalSince(last.0) > 2 * 3600 { flush() }
            current.append(m)
        }
        flush()
        return sessions
    }

    /// Dữ liệu ngủ một ngày của luồng `31 01` / `EC 01`: ngày (theo gói mở đầu) + các đoạn 6 byte nối lại.
    struct SleepDay: Sendable, Equatable {
        public var year: Int
        public var month: Int
        public var day: Int
        /// Byte [6] của gói mở đầu (`bandAlgorithmSleepCount`); chỉ để đối chiếu.
        public var declaredCount: Int
        public var raw: [UInt8]

        public var sectionCount: Int { raw.count / 6 }
    }

    /// Gom gói `31 01 YYYY MM DD n` + `32 <raw>` (`cywee = false`, `BluetoothLeService.java:7640-7681`) hoặc
    /// `EC 01 YYYY MM DD n` + `EC 02 <raw>` (`cywee = true`, `:9888-9925`) thành từng ngày.
    static func sleepDays(_ packets: [[UInt8]], cywee: Bool) -> [SleepDay] {
        var days: [SleepDay] = []
        let startOp: UInt8 = cywee ? 0xEC : 0x31
        for p in packets {
            if p.count >= 7, p[0] == startOp, p[1] == 0x01 {
                days.append(SleepDay(year: be16(p, 2), month: u(p, 4), day: u(p, 5), declaredCount: u(p, 6), raw: []))
            } else if !cywee, p.first == 0x32, !days.isEmpty {
                days[days.count - 1].raw += p.dropFirst()
            } else if cywee, p.count >= 2, p[0] == 0xEC, p[1] == 0x02, !days.isEmpty {
                days[days.count - 1].raw += p.dropFirst(2)
            }
        }
        return days
    }

    /// Mã trạng thái của đoạn ngủ do đồng hồ tính (`SleepInfo.SLEEP_STATUS_*` của SDK mới; CyWee dùng `raw − 1`
    /// với cùng thứ tự): 1 sâu, 2 nông, 3 thức, 4 REM. `FF` = hết một phiên (CyWee: tách giấc đêm / ngủ trưa).
    static func sleepStage(_ code: UInt8) -> SleepStage {
        switch code {
        case 1: return .deep
        case 2: return .light
        case 3: return .awake
        case 4: return .rem
        default: return .unknown
        }
    }

    /// Đoạn 6 byte `hh mm st ?? dH dL` (giờ:phút bắt đầu, trạng thái, ?, thời lượng phút BE) → phiên ngủ.
    /// Mốc ngày (suy luận theo app GloryFitPro, ngày ngủ tính từ 20:00 hôm trước): đoạn đầu bắt đầu từ 20:00 trở đi
    /// thuộc tối hôm trước; giờ lùi lại so với đoạn trước nghĩa là đã qua nửa đêm. Đoạn `FF` hoặc khoảng trống
    /// quá 2 giờ thì tách phiên. Phiên bắt đầu 09:00–18:00 và ≤ 3 giờ coi là ngủ trưa (suy luận).
    static func parseSleepDays(_ days: [SleepDay], calendar: Calendar = .current) -> [SleepSession] {
        var sessions: [SleepSession] = []
        for d in days {
            guard let midnight = calendar.date(from: DateComponents(year: d.year, month: d.month, day: d.day)) else { continue }
            var base: Date?
            var prevMinute = -1
            var segments: [SleepSegment] = []
            func flush() {
                defer { segments = [] }
                guard let first = segments.first, let last = segments.last else { return }
                let start = first.start, end = last.end
                let hour = calendar.component(.hour, from: start)
                let nap = (9..<18).contains(hour) && end.timeIntervalSince(start) <= 3 * 3600
                sessions.append(SleepSession(start: start, end: end, segments: segments, nap: nap))
            }
            for k in 0..<d.sectionCount {
                let s = Array(d.raw[(k * 6)..<(k * 6 + 6)])
                let h = Int(s[0]), m = Int(s[1])
                guard h <= 23, m <= 59 else { continue }
                if s[2] == 0xFF {
                    flush()
                    continue
                }
                let minute = h * 60 + m
                if base == nil {
                    base = minute >= 20 * 60 ? calendar.date(byAdding: .day, value: -1, to: midnight) : midnight
                } else if minute < prevMinute, let b = base {
                    base = calendar.date(byAdding: .day, value: 1, to: b)
                }
                prevMinute = minute
                let duration = (Int(s[4]) << 8) | Int(s[5])
                guard duration > 0, let b = base else { continue }
                let start = b.addingTimeInterval(TimeInterval(minute * 60))
                if let last = segments.last, start.timeIntervalSince(last.end) > 2 * 3600 { flush() }
                segments.append(SleepSegment(start: start, minutes: duration, stage: sleepStage(s[2])))
            }
            flush()
        }
        return sessions.sorted { $0.start < $1.start }
    }
}
