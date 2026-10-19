import Foundation
import SmartWearCore

/// Giải mã dữ liệu lịch sử QRing (sdks/qring/docs/03-history-sync.md), bản iOS của `HistoryParser.kt`. Hàm thuần, không I/O.
///
/// Ring chỉ biết giờ tường địa phương, không biết múi giờ: mọi mốc thời gian quy đổi theo `calendar` (múi giờ của
/// điện thoại). `p.u8(i)` là byte `i+1` của gói 16 byte (byte 0 là mã lệnh). Các tham số "ngày" là một thời điểm
/// bất kỳ trong ngày đó (theo `calendar`).
public struct HistoryParser: @unchecked Sendable {
    public static let cmdSteps: UInt8 = 0x43
    public static let cmdTodayTotals: UInt8 = 0x48
    public static let cmdHeartRate: UInt8 = 0x15
    public static let cmdHrv: UInt8 = 0x39
    public static let cmdStress: UInt8 = 0x37
    public static let cmdSleep: UInt8 = 0x27
    public static let cmdNap: UInt8 = 0x3E
    public static let cmdSpo2Daily: UInt8 = 0x2A
    public static let cmdTemperatureInterval: UInt8 = 0x77
    public static let cmdBloodPressure: UInt8 = 0x14
    /// Số bản ghi huyết áp đo tay tối đa mỗi lần đọc (`Constants.BAND_PRESSURE_COUNT`).
    public static let bloodPressureMax = 50
    private static let slotSeconds: TimeInterval = 15 * 60

    public let calendar: Calendar
    /// Mốc "bây giờ" để bỏ điểm tương lai (kiểm thử thì cố định).
    public let now: () -> Date

    public init(calendar: Calendar = .current, now: @escaping () -> Date = Date.init) {
        self.calendar = calendar
        self.now = now
    }

    private func midnight(_ day: Date) -> Date { calendar.startOfDay(for: day) }
    private func midnight(_ day: Date, minusDays n: Int) -> Date {
        calendar.date(byAdding: .day, value: -n, to: midnight(day)) ?? midnight(day)
    }
    private func bcd(_ v: Int) -> Int { (v >> 4) * 10 + (v & 0x0F) }
    private func le16(_ lo: Int, _ hi: Int) -> Int { lo | (hi << 8) }

    // MARK: - Bước chân: lệnh 0x43, khung 15 phút

    /// Request bước chân của ngày `dayOffset` (0 = hôm nay), đủ 96 khung.
    public func stepsRequest(_ dayOffset: Int) -> Packet {
        Packet.of(Self.cmdSteps, UInt8(truncatingIfNeeded: dayOffset), 0x0F, 0, 95, 0x01)
    }

    public func stepsComplete(_ packets: [Packet]) -> Bool {
        guard let first = packets.first else { return false }
        if first.u8(0) == 0xFF { return true }
        let last = packets[packets.count - 1]
        return last.u8(0) != 0xF0 && last.u8(4) == last.u8(5) - 1
    }

    /// Mỗi khung có dữ liệu thành một điểm: value = số bước, extra calories (cal) và distance (m).
    public func parseSteps(_ packets: [Packet]) -> [HistoryPoint] {
        guard let first = packets.first, first.u8(0) != 0xFF else { return [] }
        var newCalorieProtocol = false
        var points: [HistoryPoint] = []
        for p in packets {
            if p.u8(0) == 0xF0 {
                newCalorieProtocol = p.u8(2) == 1
                continue
            }
            guard let day = calendar.date(from: DateComponents(year: 2000 + bcd(p.u8(0)), month: bcd(p.u8(1)), day: bcd(p.u8(2)))) else { continue }
            let slot = p.u8(3)
            let calories = le16(p.u8(6), p.u8(7)) * (newCalorieProtocol ? 10 : 1)
            let steps = le16(p.u8(8), p.u8(9))
            let distance = le16(p.u8(10), p.u8(11))
            points.append(HistoryPoint(
                timestamp: midnight(day).addingTimeInterval(TimeInterval(slot) * Self.slotSeconds),
                value: Double(steps),
                extra: ["calories": Double(calories), "distance": Double(distance)]
            ))
        }
        return points
    }

    /// Lệnh 0x48: tổng hôm nay, các trường 24 bit big-endian.
    public func parseTodayTotals(_ p: Packet) -> ActivityTotals {
        func be24(_ i: Int) -> Int { (p.u8(i) << 16) | (p.u8(i + 1) << 8) | p.u8(i + 2) }
        return ActivityTotals(
            steps: be24(0), calories: be24(6), distanceMeters: be24(9), activeMinutes: (p.u8(12) << 8) | p.u8(13)
        )
    }

    // MARK: - Nhịp tim theo ngày: lệnh 0x15

    /// Giây "giờ tường" của 00:00 ngày `day` (coi giờ địa phương như UTC), ring dùng làm mốc.
    func localEpoch(_ day: Date) -> Int {
        let c = calendar.dateComponents([.year, .month, .day], from: day)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let d = utc.date(from: DateComponents(year: c.year, month: c.month, day: c.day)) ?? Date(timeIntervalSince1970: 0)
        return Int(d.timeIntervalSince1970)
    }

    /// Đổi "giờ tường" (giây, như UTC) của ring ra `Date` theo múi giờ của `calendar`.
    func fromLocalEpoch(_ seconds: Int) -> Date? {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let c = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date(timeIntervalSince1970: TimeInterval(seconds)))
        return calendar.date(from: c)
    }

    /// Request nhịp tim cho `day`: 4 byte "giờ tường" của 00:00 ngày đó, little-endian.
    public func heartRateRequest(_ day: Date) -> Packet {
        let e = localEpoch(day)
        return Packet.of(Self.cmdHeartRate, UInt8(e & 0xFF), UInt8((e >> 8) & 0xFF), UInt8((e >> 16) & 0xFF), UInt8((e >> 24) & 0xFF))
    }

    public func heartRateComplete(_ packets: [Packet]) -> Bool { indexedComplete(packets) }

    public func parseHeartRate(_ packets: [Packet], day: Date) -> [HistoryPoint] {
        indexedSeries(packets, firstOffset: 5, day: day)
    }

    // MARK: - HRV (0x39) và stress (0x37): theo ngày lệch

    public func hrvRequest(_ dayOffset: Int) -> Packet { Packet.of(Self.cmdHrv, UInt8(truncatingIfNeeded: dayOffset)) }
    public func stressRequest(_ dayOffset: Int) -> Packet { Packet.of(Self.cmdStress, UInt8(truncatingIfNeeded: dayOffset)) }
    public func dailyComplete(_ packets: [Packet]) -> Bool { indexedComplete(packets) }

    public func parseDaily(_ packets: [Packet], day: Date) -> [HistoryPoint] {
        indexedSeries(packets, firstOffset: 2, day: day)
    }

    /// Khuôn chung của 0x15 / 0x39 / 0x37: gói 0 = (size, range); gói 1 có phần đầu riêng rồi giá trị;
    /// gói k ≥ 2 có 13 giá trị. `0xFF` ở gói đầu = không có dữ liệu.
    private func indexedComplete(_ packets: [Packet]) -> Bool {
        guard let first = packets.first else { return false }
        if first.u8(0) == 0xFF { return true }
        guard let header = packets.first(where: { $0.u8(0) == 0 }) else { return false }
        let size = header.u8(1)
        return size <= 1 || packets.contains { $0.u8(0) == size - 1 }
    }

    private func indexedSeries(_ packets: [Packet], firstOffset: Int, day: Date) -> [HistoryPoint] {
        guard let header = packets.first(where: { $0.u8(0) == 0 }) else { return [] }
        let range = header.u8(2)
        guard range > 0 else { return [] }
        var values: [Int] = []
        for p in packets.filter({ (1...0xFE).contains($0.u8(0)) }).sorted(by: { $0.u8(0) < $1.u8(0) }) {
            let from = p.u8(0) == 1 ? firstOffset : 1
            for i in from...13 { values.append(p.u8(i)) }
        }
        let base = midnight(day)
        let limit = now()
        return values.enumerated().compactMap { i, v in
            let minute = i * range
            let ts = base.addingTimeInterval(TimeInterval(minute * 60))
            if v == 0 || minute >= 1440 || ts > limit { return nil }
            return HistoryPoint(timestamp: ts, value: Double(v))
        }
    }

    // MARK: - Giấc ngủ, giao thức mới: big-data 0x27

    /// `sel = 0xFF`: mọi ngày ring còn lưu (suy luận từ app: 0x00 = hôm nay, 0xFF = lịch sử).
    public func sleepRequest(allDays: Bool = true) -> BigDataFrame {
        BigDataFrame(command: Self.cmdSleep, payload: [allDays ? 0xFF : 0, 0x01])
    }

    /// Khung 0x27 (giấc chính) và 0x3E (ngủ trưa) cùng định dạng: kiểm chứng trên DS500, khung 0x3E
    /// `02 | 06 08 FE 02 27 03 02 1F 02 0A | 05 08 …` là 2 giấc trưa 12:46–13:27 (41 phút) và 12:37–13:26.
    public func parseSleep(_ payload: [UInt8], today: Date, nap: Bool = false) -> [SleepSession] {
        guard !payload.isEmpty else { return [] }
        func u(_ i: Int) -> Int { Int(payload[i]) }
        let dayCount = u(0)
        var sessions: [SleepSession] = []
        var offset = 1
        for _ in 0..<dayCount {
            if offset + 6 > payload.count { return sessions }
            let daysAgo = u(offset)
            let length = u(offset + 1) + 2
            let endMinute = le16(u(offset + 4), u(offset + 5))
            let pairsEnd = min(offset + length, payload.count)
            var stages: [(SleepStage, Int)] = []
            var i = offset + 6
            while i + 1 < pairsEnd {
                stages.append((Self.stage(u(i)), u(i + 1)))
                i += 2
            }
            offset += length
            if stages.isEmpty { continue }
            // Neo theo giờ kết thúc rồi lùi theo tổng thời lượng: đêm qua nửa đêm không cần xử lý riêng.
            let end = midnight(today, minusDays: daysAgo).addingTimeInterval(TimeInterval(endMinute * 60))
            let total = stages.reduce(0) { $0 + $1.1 }
            let start = end.addingTimeInterval(-TimeInterval(total * 60))
            var cursor = start
            let segments = stages.map { stage, minutes -> SleepSegment in
                defer { cursor = cursor.addingTimeInterval(TimeInterval(minutes * 60)) }
                return SleepSegment(start: cursor, minutes: minutes, stage: stage)
            }
            sessions.append(SleepSession(start: start, end: end, segments: segments, nap: nap))
        }
        return sessions
    }

    static func stage(_ code: Int) -> SleepStage {
        switch code {
        case 2: return .light
        case 3: return .deep
        case 4: return .rem
        case 5: return .awake
        default: return .unknown
        }
    }

    // MARK: - SpO2 theo giờ: big-data 0x2A

    public func spo2Request() -> BigDataFrame { BigDataFrame(command: Self.cmdSpo2Daily, payload: [0xFF]) }

    /// Bản ghi 49 byte: daysAgo + 24 cặp (cao nhất, thấp nhất) theo giờ. value = cao nhất, extra "min".
    public func parseSpo2(_ payload: [UInt8], today: Date) -> [HistoryPoint] {
        var points: [HistoryPoint] = []
        let limit = now()
        for r in 0..<(payload.count / 49) {
            let base = r * 49
            let dayStart = midnight(today, minusDays: Int(payload[base]))
            for h in 0..<24 {
                let maxV = Int(payload[base + 1 + h * 2])
                let minV = Int(payload[base + 2 + h * 2])
                let ts = dayStart.addingTimeInterval(TimeInterval(h * 3600))
                if maxV == 0 || ts > limit { continue }
                points.append(HistoryPoint(timestamp: ts, value: Double(maxV), extra: ["min": Double(minV)]))
            }
        }
        return points.sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: - Chuỗi theo interval có phân trang: nhiệt độ 0x77 (HR 0x75, SpO2 0x5F cùng khuôn)

    public struct IntervalPage: Sendable, Equatable {
        public let dayIndex: Int
        public let interval: Int
        public let count: Int
        public let index: Int
        public let values: [Double]
    }

    public func intervalRequest(_ command: UInt8, dayIndex: Int, page: Int) -> BigDataFrame {
        BigDataFrame(command: command, payload: [UInt8(truncatingIfNeeded: dayIndex), UInt8(truncatingIfNeeded: page)])
    }

    public func parseIntervalPage(_ payload: [UInt8], twoByteValues: Bool) -> IntervalPage? {
        guard payload.count >= 4 else { return nil }
        func u(_ i: Int) -> Int { Int(payload[i]) }
        let values: [Double] = twoByteValues
            ? stride(from: 4, to: payload.count - 1, by: 2).map { Double(le16(u($0), u($0 + 1))) / 100 }
            : (4..<payload.count).map { Double(u($0)) }
        return IntervalPage(dayIndex: u(0), interval: u(1), count: u(2), index: u(3), values: values)
    }

    public func intervalPoints(_ pages: [IntervalPage], today: Date) -> [HistoryPoint] {
        guard let first = pages.first, first.interval != 0 else { return [] }
        let base = midnight(today, minusDays: first.dayIndex)
        let limit = now()
        return pages.sorted { $0.index < $1.index }.flatMap(\.values).enumerated().compactMap { i, v in
            let minute = i * first.interval
            let ts = base.addingTimeInterval(TimeInterval(minute * 60))
            if v <= 0 || minute >= 1440 || ts > limit { return nil }
            return HistoryPoint(timestamp: ts, value: v)
        }
    }

    // MARK: - Huyết áp đo tay: lệnh 0x14 (03-history-sync.md §5.5)

    /// `14 ts(4 LE) 00 32`: đọc tối đa 50 bản ghi từ mốc `ts` (0 = tất cả, như app gốc).
    /// Không dùng `0x0D` (HA "tự động"): giá trị là nhịp tim, app QRing tự sinh SBP/DBP.
    public func bloodPressureRequest(since localEpoch: Int = 0) -> Packet {
        let e = localEpoch
        return Packet.of(
            Self.cmdBloodPressure, UInt8(e & 0xFF), UInt8((e >> 8) & 0xFF), UInt8((e >> 16) & 0xFF), UInt8((e >> 24) & 0xFF),
            0x00, UInt8(Self.bloodPressureMax)
        )
    }

    /// Kết thúc khi gặp bản ghi `FF FF FF FF` hoặc đã đủ 50 gói.
    public func bloodPressureComplete(_ packets: [Packet]) -> Bool {
        guard let last = packets.last else { return false }
        return (0..<4).allSatisfy { last.u8($0) == 0xFF } || packets.count >= Self.bloodPressureMax
    }

    /// Mỗi gói một bản ghi: `14 ts(4 LE, giờ tường) DBP SBP`. value = tâm thu, extra "diastolic".
    public func parseBloodPressure(_ packets: [Packet]) -> [HistoryPoint] {
        packets.compactMap { p in
            let ts = p.u8(0) | (p.u8(1) << 8) | (p.u8(2) << 16) | (p.u8(3) << 24)
            guard ts != 0, ts != 0xFFFF_FFFF, let date = fromLocalEpoch(ts) else { return nil }
            let dbp = p.u8(4), sbp = p.u8(5)
            guard (50...250).contains(sbp), (30...200).contains(dbp) else { return nil }
            return HistoryPoint(timestamp: date, value: Double(sbp), extra: ["diastolic": Double(dbp)])
        }
    }
}
