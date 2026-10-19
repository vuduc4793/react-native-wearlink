import Foundation

// Báo cáo sức khoẻ AI, bước 1 (docs/research/mi-fitness-features.md §2.9): điện thoại tự tổng hợp số liệu từ
// `DeviceHistory`, tất định, không cần mạng. Bước 2 là `HealthFindings` (luật), bước 3 là `HealthReportPrompt` (LLM
// chỉ viết chữ). Bản Kotlin: `HealthSummary.kt`, cùng tên trường và cùng cách tính.

/// Hồ sơ người dùng do app truyền vào (lấy từ cài đặt thiết bị `profile.*`, `goal.steps`). Trường nào chưa biết thì nil.
public struct HealthProfile: Sendable, Equatable, Codable {
    public var age: Int?
    /// true = nam, false = nữ.
    public var male: Bool?
    public var heightCm: Int?
    public var weightKg: Double?
    /// Mục tiêu bước mỗi ngày (mặc định 6000 như Mi Fitness).
    public var stepGoal: Int

    /// Loại thiết bị để lời nhắc đúng ("nhẫn", "đồng hồ", "vòng tay").
    public var device: String?

    public init(
        age: Int? = nil, male: Bool? = nil, heightCm: Int? = nil, weightKg: Double? = nil, stepGoal: Int = 6000, device: String? = nil
    ) {
        self.device = device
        self.age = age
        self.male = male
        self.heightCm = heightCm
        self.weightKg = weightKg
        self.stepGoal = stepGoal
    }

    /// Nhịp tim tối đa = 220 − tuổi, chưa biết tuổi thì coi là 25 (như Mi Fitness `getMaxHrOrDefault`).
    public var maxHeartRate: Int { 220 - (age ?? 25) }

    /// BMI = cân nặng / chiều cao² (m). nil nếu thiếu số.
    public var bmi: Double? {
        guard let h = heightCm, h > 0, let w = weightKg, w > 0 else { return nil }
        let m = Double(h) / 100
        return w / (m * m)
    }
}

/// Kỳ báo cáo: hôm nay, hoặc 7 ngày gần nhất (tính cả hôm nay).
public enum HealthPeriod: String, Sendable, Codable, CaseIterable {
    case day, week

    public var days: Int { self == .day ? 1 : 7 }
    public var title: String { self == .day ? "Hôm nay" : "7 ngày" }
}

/// Trung bình / thấp nhất / cao nhất của một chuỗi.
public struct HealthStat: Sendable, Equatable, Codable {
    public var avg: Double
    public var min: Double
    public var max: Double
    public var count: Int

    public init(avg: Double, min: Double, max: Double, count: Int) {
        self.avg = avg
        self.min = min
        self.max = max
        self.count = count
    }

    /// `values` rỗng thì nil; `lows` (vd SpO2 thấp nhất trong giờ) nếu có thì dùng để tính `min`.
    public static func of(_ values: [Double], lows: [Double]? = nil) -> HealthStat? {
        guard !values.isEmpty else { return nil }
        let low = (lows?.isEmpty == false ? lows! : values).min() ?? 0
        return HealthStat(avg: values.reduce(0, +) / Double(values.count), min: Swift.min(low, values.min() ?? low),
                          max: values.max() ?? 0, count: values.count)
    }
}

/// Huyết áp trong kỳ (mmHg): trung bình, lần đo mới nhất, cao nhất.
public struct BloodPressureStat: Sendable, Equatable, Codable {
    public var avgSystolic: Double
    public var avgDiastolic: Double
    public var latestSystolic: Int
    public var latestDiastolic: Int
    public var maxSystolic: Int
    public var maxDiastolic: Int
    public var count: Int

    /// Điểm `BLOOD_PRESSURE`: value = tâm thu, extra "diastolic" = tâm trương. Bỏ điểm 0.
    public static func of(_ points: [HistoryPoint]) -> BloodPressureStat? {
        let p = points.filter { $0.value > 0 && ($0.extra["diastolic"] ?? 0) > 0 }.sorted { $0.timestamp < $1.timestamp }
        guard let last = p.last else { return nil }
        let sys = p.map(\.value), dia = p.map { $0.extra["diastolic"] ?? 0 }
        return BloodPressureStat(
            avgSystolic: sys.reduce(0, +) / Double(p.count), avgDiastolic: dia.reduce(0, +) / Double(p.count),
            latestSystolic: Int(last.value.rounded()), latestDiastolic: Int((last.extra["diastolic"] ?? 0).rounded()),
            maxSystolic: Int((sys.max() ?? 0).rounded()), maxDiastolic: Int((dia.max() ?? 0).rounded()), count: p.count
        )
    }
}

/// Một đêm ngủ đã tổng hợp. Tỉ lệ sâu/nông/REM tính trên thời gian ngủ (không gồm lúc thức), như Mi Fitness.
public struct HealthNight: Sendable, Equatable, Codable {
    /// Lúc bắt đầu ngủ (đầu đoạn ngủ đầu tiên) và lúc dậy (cuối đoạn ngủ cuối).
    public var bedtime: Date
    public var wakeTime: Date
    public var asleepMinutes: Int
    public var deepMinutes: Int
    public var lightMinutes: Int
    public var remMinutes: Int
    public var awakeMinutes: Int
    /// Số lần thức giữa giấc (không tính đoạn thức ở đầu / cuối phiên).
    public var wakeUps: Int
    /// Phút trong ngày của giờ ngủ, tính từ 12:00 trưa (23:00 = 660) để không bị gãy qua nửa đêm.
    public var bedtimeFromNoon: Int
    /// Lệch giờ ngủ (phút) so với trung bình các đêm trước trong 7 ngày; nil nếu chưa đủ 2 đêm để so.
    public var bedtimeDeviation: Int?

    public var deepPct: Double { pct(deepMinutes) }
    public var lightPct: Double { pct(lightMinutes) }
    public var remPct: Double { pct(remMinutes) }
    /// Thức trên tổng thời gian nằm (ngủ + thức).
    public var awakePct: Double {
        asleepMinutes + awakeMinutes > 0 ? Double(awakeMinutes) * 100 / Double(asleepMinutes + awakeMinutes) : 0
    }
    /// Điểm ngủ tự tính (xem `HealthFindings.sleepScore`).
    public var score: Int { HealthFindings.sleepScore(self) }

    private func pct(_ m: Int) -> Double { asleepMinutes > 0 ? Double(m) * 100 / Double(asleepMinutes) : 0 }

    /// Tổng hợp một phiên; `calendar` để lấy giờ địa phương.
    public static func of(_ s: SleepSession, calendar: Calendar, priorBedtimes: [Int] = []) -> HealthNight {
        let segs = s.segments.sorted { $0.start < $1.start }
        let sleeping = segs.filter { $0.stage != .awake && $0.stage != .unknown }
        let bed = sleeping.first?.start ?? s.start
        let wake = sleeping.last?.end ?? s.end
        // Số lần thức: số cụm đoạn AWAKE liền nhau nằm giữa hai đoạn ngủ.
        var wakeUps = 0
        if let firstSleep = segs.firstIndex(where: { $0.stage != .awake && $0.stage != .unknown }),
           let lastSleep = segs.lastIndex(where: { $0.stage != .awake && $0.stage != .unknown }), firstSleep < lastSleep {
            var inAwake = false
            for seg in segs[firstSleep...lastSleep] {
                if seg.stage == .awake {
                    if !inAwake { wakeUps += 1 }
                    inAwake = true
                } else if seg.stage != .unknown {
                    inAwake = false
                }
            }
        }
        let fromNoon = minutesFromNoon(bed, calendar: calendar)
        let deviation: Int? = priorBedtimes.count >= 2
            ? Int((Double(fromNoon) - Double(priorBedtimes.reduce(0, +)) / Double(priorBedtimes.count)).magnitude.rounded())
            : nil
        return HealthNight(
            bedtime: bed, wakeTime: wake, asleepMinutes: s.asleepMinutes, deepMinutes: s.minutes(.deep),
            lightMinutes: s.minutes(.light), remMinutes: s.minutes(.rem), awakeMinutes: s.minutes(.awake),
            wakeUps: wakeUps, bedtimeFromNoon: fromNoon, bedtimeDeviation: deviation
        )
    }

    static func minutesFromNoon(_ date: Date, calendar: Calendar) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return ((c.hour ?? 0) * 60 + (c.minute ?? 0) + 720) % 1440
    }
}

/// Vùng nhịp tim theo % nhịp tối đa (Mi Fitness `HrZone`): ≥50 khởi động, >60 đốt mỡ, >70 hiếu khí, >80 kỵ khí,
/// >90 cực hạn, dưới 50 là nhẹ nhàng.
public enum HeartRateZone: String, Sendable, Codable {
    case smooth, warmUp = "warm_up", fatBurn = "fat_burn", aerobic, anaerobic, extreme

    public static func of(_ bpm: Int, maxHeartRate: Int) -> HeartRateZone {
        let pct = Double(bpm) * 100 / Double(Swift.max(maxHeartRate, 1))
        if pct > 90 { return .extreme }
        if pct > 80 { return .anaerobic }
        if pct > 70 { return .aerobic }
        if pct > 60 { return .fatBurn }
        if pct >= 50 { return .warmUp }
        return .smooth
    }
}

/// Một bài tập trong kỳ (rút gọn từ `Workout`).
public struct HealthWorkout: Sendable, Equatable, Codable {
    public var name: String
    public var start: Date
    public var minutes: Int
    public var calories: Int?
    public var distanceMeters: Int?
    public var avgHeartRate: Int?
    public var maxHeartRate: Int?
    /// Vùng của nhịp tim trung bình.
    public var zone: HeartRateZone?
}

/// Số liệu một ngày (0:00–24:00 giờ địa phương).
public struct HealthDay: Sendable, Equatable, Codable {
    public var date: Date
    public var steps: Int
    /// kcal (lịch sử lưu cal, đã chia 1000).
    public var calories: Int
    public var distanceMeters: Int
    public var activeMinutes: Int?
    public var heartRate: HealthStat?
    /// Nhịp tim nghỉ ước lượng: TB 10% số đo thấp nhất trong lúc ngủ đêm kết thúc hôm nay; nil nếu không có.
    public var restingHeartRate: Int?
    public var spo2: HealthStat?
    public var bloodPressure: BloodPressureStat?
    /// Giấc ngủ đêm kết thúc trong ngày (giấc dài nhất không phải ngủ trưa).
    public var sleep: HealthNight?
    public var napMinutes: Int
    public var workouts: Int

    public var hasData: Bool {
        steps > 0 || heartRate != nil || spo2 != nil || bloodPressure != nil || sleep != nil || napMinutes > 0 || workouts > 0
    }
}

/// Số liệu của cả kỳ, đầu vào của `HealthFindings` và `HealthReportPrompt`.
public struct HealthSummary: Sendable, Equatable, Codable {
    public var period: HealthPeriod
    public var profile: HealthProfile
    /// Mốc tạo báo cáo; ngày cuối của kỳ là hôm nay và đang diễn ra tới mốc này.
    public var generatedAt: Date
    public var timeZone: TimeZone
    /// Cũ → mới; ngày cuối là hôm nay.
    public var days: [HealthDay]
    // Gộp mọi điểm trong kỳ:
    public var heartRate: HealthStat?
    public var restingHeartRate: Int?
    public var spo2: HealthStat?
    /// Số lần SpO2 (thấp nhất trong giờ) dưới 90%.
    public var spo2Below90: Int
    public var bloodPressure: BloodPressureStat?
    public var stress: HealthStat?
    public var hrv: HealthStat?
    public var temperature: HealthStat?
    public var workouts: [HealthWorkout]

    public var today: HealthDay? { days.last }
    public var nights: [HealthNight] { days.compactMap(\.sleep) }
    public var totalSteps: Int { days.reduce(0) { $0 + $1.steps } }

    /// Ngày dùng để tính TB bước: bỏ hôm nay (chưa hết ngày) và ngày 0 bước (không đeo / chưa đồng bộ).
    /// Kỳ "hôm nay" thì chỉ có hôm nay.
    public var stepDays: [HealthDay] {
        let full = days.dropLast().filter { $0.steps > 0 }
        return full.isEmpty ? Array(days.suffix(1)) : Array(full)
    }
    public var averageSteps: Int {
        let d = stepDays
        return d.isEmpty ? 0 : Int((Double(d.reduce(0) { $0 + $1.steps }) / Double(d.count)).rounded())
    }
    public var daysGoalMet: Int { stepDays.filter { $0.steps >= profile.stepGoal }.count }
    public var averageSleepMinutes: Int? {
        nights.isEmpty ? nil : Int((Double(nights.reduce(0) { $0 + $1.asleepMinutes }) / Double(nights.count)).rounded())
    }
    public var averageSleepScore: Int? {
        nights.isEmpty ? nil : Int((Double(nights.reduce(0) { $0 + $1.score }) / Double(nights.count)).rounded())
    }

    /// Tổng hợp `period` từ lịch sử. `now` và `calendar` tiêm được để kiểm thử.
    public static func make(
        history: DeviceHistory, period: HealthPeriod, profile: HealthProfile = HealthProfile(),
        now: Date = Date(), calendar: Calendar = .current
    ) -> HealthSummary {
        let today = calendar.startOfDay(for: now)
        let first = calendar.date(byAdding: .day, value: -(period.days - 1), to: today) ?? today
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? now
        let mains = history.sleep.filter { !$0.nap }

        func night(_ s: SleepSession) -> HealthNight {
            let weekAgo = s.end.addingTimeInterval(-7 * 86_400)
            let prior = mains.filter { $0 != s && $0.end >= weekAgo && $0.end < s.end && $0.asleepMinutes > 0 }
                .map { HealthNight.of($0, calendar: calendar).bedtimeFromNoon }
            return HealthNight.of(s, calendar: calendar, priorBedtimes: prior)
        }

        var days: [HealthDay] = []
        var resting: [Int] = []
        for i in 0..<period.days {
            let s = calendar.date(byAdding: .day, value: i, to: first) ?? first
            let e = calendar.date(byAdding: .day, value: 1, to: s) ?? s
            let slots = history.points(.steps, from: s, to: e)
            var steps = Int(slots.reduce(0) { $0 + $1.value })
            var cal = Int(slots.reduce(0) { $0 + ($1.extra["calories"] ?? 0) })
            var dist = Int(slots.reduce(0) { $0 + ($1.extra["distance"] ?? 0) })
            var active: Int?
            // Tổng thiết bị báo chỉ đúng cho ngày đồng bộ.
            if let t = history.today, calendar.isDate(history.syncedAt, inSameDayAs: s) {
                steps = t.steps; cal = t.calories; dist = t.distanceMeters; active = t.activeMinutes
            }
            let main = mains.filter { $0.end >= s && $0.end < e && $0.asleepMinutes > 0 }.max { $0.asleepMinutes < $1.asleepMinutes }
            let naps = history.sleep.filter { $0.nap && $0.end >= s && $0.end < e }
                .reduce(0) { $0 + ($1.asleepMinutes > 0 ? $1.asleepMinutes : Int($1.end.timeIntervalSince($1.start) / 60)) }
            let hr = history.points(.heartRate, from: s, to: e).filter { $0.value > 0 }
            var rest: Int?
            if let m = main {
                let during = hr.filter { $0.timestamp >= m.start && $0.timestamp <= m.end }.map(\.value).sorted()
                if !during.isEmpty {
                    let low = during.prefix(Swift.max(1, during.count / 10))
                    rest = Int((low.reduce(0, +) / Double(low.count)).rounded())
                }
            }
            if let rest { resting.append(rest) }
            let spo = history.points(.spo2, from: s, to: e).filter { $0.value > 0 }
            days.append(HealthDay(
                date: s, steps: steps, calories: Int((Double(cal) / 1000).rounded()), distanceMeters: dist,
                activeMinutes: active, heartRate: HealthStat.of(hr.map(\.value)), restingHeartRate: rest,
                spo2: HealthStat.of(spo.map(\.value), lows: spo.map { $0.extra["min"] ?? $0.value }),
                bloodPressure: BloodPressureStat.of(history.points(.bloodPressure, from: s, to: e)),
                sleep: main.map(night), napMinutes: naps,
                workouts: history.workouts.filter { $0.start >= s && $0.start < e }.count
            ))
        }

        let hr = history.points(.heartRate, from: first, to: end).filter { $0.value > 0 }
        let spo = history.points(.spo2, from: first, to: end).filter { $0.value > 0 }
        let spoLows = spo.map { $0.extra["min"] ?? $0.value }
        func stat(_ c: Capability) -> HealthStat? {
            HealthStat.of(history.points(c, from: first, to: end).map(\.value).filter { $0 > 0 })
        }
        let maxHr = profile.maxHeartRate
        let workouts = history.workouts.filter { $0.start >= first && $0.start < end }.sorted { $0.start < $1.start }.map { w in
            HealthWorkout(
                name: w.name, start: w.start, minutes: Int((Double(w.activeSeconds) / 60).rounded()), calories: w.calories,
                distanceMeters: w.distanceMeters, avgHeartRate: w.avgHeartRate, maxHeartRate: w.maxHeartRate,
                zone: w.avgHeartRate.map { HeartRateZone.of($0, maxHeartRate: maxHr) }
            )
        }
        return HealthSummary(
            period: period, profile: profile, generatedAt: now, timeZone: calendar.timeZone, days: days,
            heartRate: HealthStat.of(hr.map(\.value)),
            restingHeartRate: resting.isEmpty ? nil : Int((Double(resting.reduce(0, +)) / Double(resting.count)).rounded()),
            spo2: HealthStat.of(spo.map(\.value), lows: spoLows), spo2Below90: spoLows.filter { $0 < 90 }.count,
            bloodPressure: BloodPressureStat.of(history.points(.bloodPressure, from: first, to: end)),
            stress: stat(.stress), hrv: stat(.hrv), temperature: stat(.temperature), workouts: workouts
        )
    }
}
