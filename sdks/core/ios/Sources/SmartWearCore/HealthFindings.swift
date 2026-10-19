import Foundation

/// Mức độ của một phát hiện; cũng là màu trạng thái của mục trong báo cáo.
public enum HealthSeverity: String, Sendable, Codable, CaseIterable, Comparable {
    case ok, notice, warn

    public static func < (a: HealthSeverity, b: HealthSeverity) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

/// Một phát hiện có mã ổn định (vd `sleep.short`, `bp.stage1`), mức độ và số liệu kèm theo. LLM chỉ diễn đạt lại.
public struct HealthFinding: Sendable, Equatable, Codable {
    public var code: String
    public var severity: HealthSeverity
    public var values: [String: Double]

    public init(_ code: String, _ severity: HealthSeverity, _ values: [String: Double] = [:]) {
        self.code = code
        self.severity = severity
        self.values = values
    }

    /// Mục báo cáo chứa phát hiện này (`activity`, `heart`, `spo2`, `bp`, `sleep`, `stress`, `workout`, `body`).
    public var area: String { HealthFindings.area(of: code) }
}

/// Báo cáo sức khoẻ AI, bước 2: lớp luật sinh phát hiện có mã từ `HealthSummary` (docs/research/mi-fitness-features.md).
/// Ngưỡng:
/// - Giấc ngủ (Mi Fitness `SleepInterpretationExtKt`, §2.3): ≤420 phút ngắn, >540 dài; sâu ngoài 20–60%; REM (nếu có)
///   ngoài 10–30%; nông ngoài 20–60% (có REM) hoặc 60–80% (không REM); lên giường sau 23:00 là muộn; thức ≥3 lần.
/// - Điểm ngủ: công thức TỰ THIẾT KẾ của SmartWear (§5.1), không phải thuật toán đóng của Xiaomi; xem `sleepScore`.
/// - Nhịp tim (§5.2): TB >100 nhanh, thấp nhất <40, nghỉ >80 hoặc <50; vùng tim theo 220 − tuổi.
/// - SpO2 (§5.3): <90% thấp (cảnh báo); TB <95% hơi thấp.
/// - Huyết áp: phân loại AHA/ACC 2017 (bình thường <120/<80, tăng 120–129/<80, độ 1 130–139 hoặc 80–89,
///   độ 2 ≥140 hoặc ≥90, khủng hoảng >180 hoặc >120); thấp ≤90/≤60.
/// - Stress (nhánh Xiaomi): ≤50 bình thường, 51–80 vừa, >80 cao.
/// - Bước: so với mục tiêu; tuần: TB ngày đủ (bỏ hôm nay). Bài tập tuần: WHO ≥150 phút.
/// - BMI (Mi Fitness `WeightEvaluationHelper`): <18.5 gầy, ≥24 thừa cân, ≥28 béo phì.
public enum HealthFindings {
    public static let areas = ["activity", "heart", "spo2", "bp", "sleep", "stress", "workout", "body"]

    public static func area(of code: String) -> String {
        switch code.split(separator: ".").first.map(String.init) ?? code {
        case "steps": return "activity"
        case "hr": return "heart"
        case "bmi": return "body"
        case let p: return p
        }
    }

    /// Tên mục tiếng Việt cho UI.
    public static func areaTitle(_ area: String) -> String {
        switch area {
        case "activity": return "Vận động"
        case "heart": return "Nhịp tim"
        case "spo2": return "SpO2"
        case "bp": return "Huyết áp"
        case "sleep": return "Giấc ngủ"
        case "stress": return "Căng thẳng"
        case "workout": return "Bài tập"
        case "body": return "Cơ thể"
        default: return area
        }
    }

    /// Mức nặng nhất của các phát hiện thuộc `area` (nil nếu không có).
    public static func worst(_ findings: [HealthFinding], area: String) -> HealthSeverity? {
        findings.filter { $0.area == area }.map(\.severity).max()
    }

    public static func evaluate(_ s: HealthSummary) -> [HealthFinding] {
        var out: [HealthFinding] = []
        let week = s.period == .week

        // Vận động
        let goal = Double(s.profile.stepGoal)
        if week {
            let avg = Double(s.averageSteps)
            out.append(HealthFinding(avg >= goal ? "steps.goal_met" : "steps.below_goal", avg >= goal ? .ok : .notice, [
                "avg": avg, "goal": goal, "daysMet": Double(s.daysGoalMet), "days": Double(s.stepDays.count),
            ]))
        } else if let d = s.today {
            let steps = Double(d.steps)
            out.append(HealthFinding(steps >= goal ? "steps.goal_met" : "steps.below_goal", steps >= goal ? .ok : .notice, [
                "steps": steps, "goal": goal, "pct": round1(steps * 100 / max(goal, 1)),
            ]))
        }

        // Nhịp tim
        if let hr = s.heartRate {
            var v = ["avg": round1(hr.avg), "min": hr.min, "max": hr.max]
            if let r = s.restingHeartRate { v["resting"] = Double(r) }
            let before = out.count
            if hr.min < 40 { out.append(HealthFinding("hr.low", .warn, v)) }
            if hr.avg > 100 { out.append(HealthFinding("hr.avg_high", .notice, v)) }
            if let r = s.restingHeartRate, r > 80 { out.append(HealthFinding("hr.resting_high", .notice, v)) }
            if let r = s.restingHeartRate, r < 50 { out.append(HealthFinding("hr.resting_low", .notice, v)) }
            if out.count == before { out.append(HealthFinding("hr.normal", .ok, v)) }
        }

        // SpO2
        if let o = s.spo2 {
            let v = ["avg": round1(o.avg), "min": o.min, "below90": Double(s.spo2Below90)]
            if o.min < 90 {
                out.append(HealthFinding("spo2.low", .warn, v))
            } else if o.avg < 95 {
                out.append(HealthFinding("spo2.borderline", .notice, v))
            } else {
                out.append(HealthFinding("spo2.normal", .ok, v))
            }
        }

        // Huyết áp
        if let bp = s.bloodPressure {
            let v = [
                "avgSys": round1(bp.avgSystolic), "avgDia": round1(bp.avgDiastolic), "maxSys": Double(bp.maxSystolic),
                "maxDia": Double(bp.maxDiastolic), "n": Double(bp.count),
            ]
            let (code, sev) = bloodPressureCategory(systolic: bp.avgSystolic, diastolic: bp.avgDiastolic)
            if bp.maxSystolic > 180 || bp.maxDiastolic > 120 {
                out.append(HealthFinding("bp.crisis", .warn, v))
            } else {
                out.append(HealthFinding(code, sev, v))
            }
        }

        // Giấc ngủ
        out += sleepFindings(s)

        // Căng thẳng
        if let st = s.stress {
            let v = ["avg": round1(st.avg), "max": st.max]
            if st.avg > 80 {
                out.append(HealthFinding("stress.high", .notice, v))
            } else if st.avg > 50 {
                out.append(HealthFinding("stress.moderate", .notice, v))
            } else {
                out.append(HealthFinding("stress.normal", .ok, v))
            }
        }

        // Bài tập
        let minutes = Double(s.workouts.reduce(0) { $0 + $1.minutes })
        if week {
            out.append(HealthFinding(minutes >= 150 ? "workout.who_met" : "workout.who_below", minutes >= 150 ? .ok : .notice,
                                     ["minutes": minutes, "count": Double(s.workouts.count), "target": 150]))
        } else if !s.workouts.isEmpty {
            out.append(HealthFinding("workout.done", .ok, ["minutes": minutes, "count": Double(s.workouts.count)]))
        }

        // Cơ thể
        if let bmi = s.profile.bmi {
            let v = ["bmi": round1(bmi)]
            if bmi < 18.5 {
                out.append(HealthFinding("bmi.under", .notice, v))
            } else if bmi >= 28 {
                out.append(HealthFinding("bmi.obese", .notice, v))
            } else if bmi >= 24 {
                out.append(HealthFinding("bmi.over", .notice, v))
            } else {
                out.append(HealthFinding("bmi.normal", .ok, v))
            }
        }
        return out
    }

    /// Phân loại huyết áp AHA/ACC 2017 (+ huyết áp thấp ≤90/≤60). Mức "warn" thì báo cáo khuyên gặp bác sĩ.
    public static func bloodPressureCategory(systolic: Double, diastolic: Double) -> (String, HealthSeverity) {
        if systolic > 180 || diastolic > 120 { return ("bp.crisis", .warn) }
        if systolic >= 140 || diastolic >= 90 { return ("bp.stage2", .warn) }
        if systolic >= 130 || diastolic >= 80 { return ("bp.stage1", .warn) }
        if systolic >= 120 { return ("bp.elevated", .notice) }
        if systolic <= 90 || diastolic <= 60 { return ("bp.low", .notice) }
        return ("bp.normal", .ok)
    }

    /// Mã luật của một đêm (Mi Fitness §2.3), không gồm `sleep.normal`.
    public static func nightCodes(_ n: HealthNight) -> [String] {
        var c: [String] = []
        if n.asleepMinutes <= 420 { c.append("sleep.short") }
        if n.asleepMinutes > 540 { c.append("sleep.long") }
        if n.deepPct < 20 { c.append("sleep.deep_low") }
        if n.deepPct > 60 { c.append("sleep.deep_high") }
        let hasRem = n.remMinutes > 0
        if hasRem ? (n.lightPct < 20 || n.lightPct > 60) : (n.lightPct < 60 || n.lightPct > 80) { c.append("sleep.light_abnormal") }
        if hasRem && n.remPct < 10 { c.append("sleep.rem_low") }
        if hasRem && n.remPct > 30 { c.append("sleep.rem_high") }
        if lateMinutes(n) > 0 { c.append("sleep.late") }
        if n.wakeUps >= 3 { c.append("sleep.wake_many") }
        return c
    }

    /// Số phút lên giường sau 23:00 (Mi Fitness: giờ ngủ trong [23:00, 09:00] là muộn); 0 nếu không muộn.
    public static func lateMinutes(_ n: HealthNight) -> Int {
        n.bedtimeFromNoon > 660 && n.bedtimeFromNoon <= 1260 ? n.bedtimeFromNoon - 660 : 0
    }

    /// Điểm ngủ 0–100, công thức của SmartWear (không phải của Xiaomi): 100 trừ dần
    /// - thời lượng ngoài 7–9 giờ: ngắn trừ (420 − phút) / 8, dài trừ (phút − 540) / 6, tối đa 30;
    /// - % sâu ngoài 20–60: trừ số điểm % lệch, tối đa 15;
    /// - % REM ngoài 10–30 (chỉ khi thiết bị có REM): như trên, tối đa 15;
    /// - thức ≥3 lần: trừ 5 cho mỗi lần từ lần thứ 3, tối đa 15;
    /// - ngủ sau 23:00: trừ 1 cho mỗi 15 phút muộn, tối đa 10;
    /// - lệch giờ ngủ so với TB 7 ngày >30 phút: trừ (lệch − 30) / 4, tối đa 15.
    public static func sleepScore(_ n: HealthNight) -> Int {
        guard n.asleepMinutes > 0 else { return 0 }
        let d = Double(n.asleepMinutes)
        var p = 0.0
        if d < 420 { p += min(30, (420 - d) / 8) }
        if d > 540 { p += min(30, (d - 540) / 6) }
        p += min(15, outside(n.deepPct, 20, 60))
        if n.remMinutes > 0 { p += min(15, outside(n.remPct, 10, 30)) }
        if n.wakeUps >= 3 { p += min(15, Double(n.wakeUps - 2) * 5) }
        p += min(10, Double(lateMinutes(n)) / 15)
        if let dev = n.bedtimeDeviation, dev > 30 { p += min(15, Double(dev - 30) / 4) }
        return max(0, min(100, Int((100 - p).rounded())))
    }

    /// Nhãn điểm như Mi Fitness: <60 kém, 60–79 trung bình, 80–89 tốt, ≥90 rất tốt.
    public static func scoreLabel(_ score: Int) -> String {
        switch score {
        case ..<60: return "Kém"
        case ..<80: return "Trung bình"
        case ..<90: return "Tốt"
        default: return "Rất tốt"
        }
    }

    private static func sleepFindings(_ s: HealthSummary) -> [HealthFinding] {
        let nights = s.nights
        guard !nights.isEmpty else { return [HealthFinding("sleep.no_data", .notice)] }
        var out: [HealthFinding] = []
        if s.period == .day, let n = nights.last {
            let v: [String: Double] = [
                "asleepMin": Double(n.asleepMinutes), "deepPct": round1(n.deepPct), "lightPct": round1(n.lightPct),
                "remPct": round1(n.remPct), "wakeUps": Double(n.wakeUps), "lateMin": Double(lateMinutes(n)),
            ]
            out = nightCodes(n).map { HealthFinding($0, .notice, v) }
            if out.isEmpty { out.append(HealthFinding("sleep.normal", .ok, v)) }
            let score = n.score
            out.append(HealthFinding("sleep.score", score >= 80 ? .ok : .notice, ["score": Double(score)]))
        } else {
            // Tuần: luật nào trúng ≥2 đêm (hoặc ≥1 nếu chỉ có 1–2 đêm) thì báo, kèm số đêm.
            let need = nights.count < 3 ? 1 : 2
            var counts: [String: Int] = [:]
            for n in nights { for c in nightCodes(n) { counts[c, default: 0] += 1 } }
            for code in allNightCodes where (counts[code] ?? 0) >= need {
                out.append(HealthFinding(code, .notice, ["nights": Double(counts[code]!), "of": Double(nights.count)]))
            }
            let devs = nights.compactMap(\.bedtimeDeviation)
            if devs.count >= 3, Double(devs.reduce(0, +)) / Double(devs.count) > 30 {
                out.append(HealthFinding("sleep.irregular", .notice, ["avgDeviationMin": round1(Double(devs.reduce(0, +)) / Double(devs.count))]))
            }
            if out.isEmpty { out.append(HealthFinding("sleep.normal", .ok, ["nights": Double(nights.count)])) }
            let score = s.averageSleepScore ?? 0
            out.append(HealthFinding("sleep.score", score >= 80 ? .ok : .notice, ["score": Double(score), "nights": Double(nights.count)]))
        }
        return out
    }

    static let allNightCodes = [
        "sleep.short", "sleep.long", "sleep.deep_low", "sleep.deep_high", "sleep.light_abnormal", "sleep.rem_low",
        "sleep.rem_high", "sleep.late", "sleep.wake_many",
    ]

    private static func outside(_ v: Double, _ lo: Double, _ hi: Double) -> Double { v < lo ? lo - v : v > hi ? v - hi : 0 }

    /// Làm tròn 1 chữ số thập phân (nửa lên), giống bản Kotlin để JSON hai nền tảng trùng nhau.
    static func round1(_ v: Double) -> Double { (v * 10).rounded(.toNearestOrAwayFromZero) / 10 }
}
