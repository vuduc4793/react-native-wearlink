import XCTest
@testable import SmartWearCore

/// Báo cáo sức khoẻ AI: tổng hợp, luật, prompt, đọc kết quả. Cùng dữ liệu mẫu với `HealthReportTest` Kotlin
/// (Y25 sáng 16/10/2026: 28 bước, HR 79–88, SpO2 98, HA 122/72 và 121/73, chưa có giấc ngủ).
final class HealthReportTests: XCTestCase {
    private let tz = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = tz
        return c
    }

    private func at(_ day: Int, _ h: Int, _ m: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: h, minute: m))!
    }

    private func night(_ day: Int, _ h: Int, _ m: Int, _ segs: [(SleepStage, Int)]) -> SleepSession {
        var t = at(day, h, m)
        var out: [SleepSegment] = []
        for (stage, minutes) in segs {
            out.append(SleepSegment(start: t, minutes: minutes, stage: stage))
            t = t.addingTimeInterval(TimeInterval(minutes * 60))
        }
        return SleepSession(start: at(day, h, m), end: t, segments: out)
    }

    private let profile = HealthProfile(age: 30, male: true, heightCm: 170, weightKg: 65, stepGoal: 8000)
    private var now: Date { at(16, 10, 30) }

    /// Y25 đo thật sáng 16/10: một khung bước theo giờ 28 bước, nhịp tim 79–88, SpO2 98, huyết áp 2 lần.
    private func y25Day() -> DeviceHistory {
        DeviceHistory(
            series: [
                .steps: [HistoryPoint(timestamp: at(16, 9), value: 28, extra: ["calories": 1100, "distance": 19])],
                .heartRate: [79, 83, 88, 81, 84].enumerated().map { HistoryPoint(timestamp: at(16, 8, $0.offset * 30), value: $0.element) },
                .spo2: [HistoryPoint(timestamp: at(16, 9), value: 98, extra: ["min": 98])],
                .bloodPressure: [
                    HistoryPoint(timestamp: at(16, 8, 30), value: 122, extra: ["diastolic": 72]),
                    HistoryPoint(timestamp: at(16, 9, 45), value: 121, extra: ["diastolic": 73]),
                ],
            ],
            today: ActivityTotals(steps: 28, calories: 1100, distanceMeters: 19), days: 1, syncedAt: at(16, 10, 25)
        )
    }

    private static let y25JSON =
        #"{"activity":{"distanceM":19,"kcal":1,"steps":28},"asOf":"10:30","bp":{"avgDia":72.5,"avgSys":121.5,"latest":"121/73","n":2},"date":"2026-10-16","findings":[{"code":"steps.below_goal","sev":"notice","v":{"goal":8000,"pct":0.4,"steps":28}},{"code":"hr.normal","sev":"ok","v":{"avg":83,"max":88,"min":79}},{"code":"spo2.normal","sev":"ok","v":{"avg":98,"below90":0,"min":98}},{"code":"bp.elevated","sev":"notice","v":{"avgDia":72.5,"avgSys":121.5,"maxDia":73,"maxSys":122,"n":2}},{"code":"sleep.no_data","sev":"notice"},{"code":"bmi.normal","sev":"ok","v":{"bmi":22.5}}],"heart":{"avg":83,"max":88,"min":79,"n":5},"period":"day","profile":{"age":30,"bmi":22.5,"heightCm":170,"hrMax":190,"sex":"nam","stepGoal":8000,"weightKg":65},"spo2":{"avg":98,"below90":0,"max":98,"min":98,"n":1}}"#

    func testY25DaySummary() {
        let s = HealthSummary.make(history: y25Day(), period: .day, profile: profile, now: now, calendar: cal)
        XCTAssertEqual(s.days.count, 1)
        let d = s.today!
        XCTAssertEqual(d.steps, 28)
        XCTAssertEqual(d.calories, 1)
        XCTAssertEqual(d.distanceMeters, 19)
        XCTAssertEqual(s.heartRate, HealthStat(avg: 83, min: 79, max: 88, count: 5))
        XCTAssertNil(s.restingHeartRate)
        XCTAssertEqual(s.spo2?.avg, 98)
        XCTAssertEqual(s.spo2Below90, 0)
        let bp = s.bloodPressure!
        XCTAssertEqual(bp.avgSystolic, 121.5)
        XCTAssertEqual(bp.avgDiastolic, 72.5)
        XCTAssertEqual("\(bp.latestSystolic)/\(bp.latestDiastolic)", "121/73")
        XCTAssertNil(d.sleep)
        XCTAssertEqual(profile.maxHeartRate, 190)
        XCTAssertEqual(profile.bmi!, 22.49, accuracy: 0.01)
    }

    func testY25DayFindingsAndPrompt() {
        let s = HealthSummary.make(history: y25Day(), period: .day, profile: profile, now: now, calendar: cal)
        let f = HealthFindings.evaluate(s)
        XCTAssertEqual(f.map(\.code), ["steps.below_goal", "hr.normal", "spo2.normal", "bp.elevated", "sleep.no_data", "bmi.normal"])
        XCTAssertEqual(f.map(\.severity), [.notice, .ok, .ok, .notice, .notice, .ok])
        XCTAssertEqual(HealthFindings.worst(f, area: "bp"), .notice)
        XCTAssertNil(HealthFindings.worst(f, area: "stress"))
        // Chuỗi JSON gửi LLM trùng từng ký tự với bản Kotlin.
        let json = HealthReportPrompt.userJSON(s, findings: f)
        XCTAssertEqual(json, Self.y25JSON)

        let body = HealthReportPrompt.requestBody(model: "Qwen/Qwen3.6-35B-A3B-FP8", summary: s, findings: f)
        let obj = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
        XCTAssertEqual(obj["model"] as? String, "Qwen/Qwen3.6-35B-A3B-FP8")
        XCTAssertEqual((obj["chat_template_kwargs"] as? [String: Any])?["enable_thinking"] as? Bool, false)
        let msgs = obj["messages"] as! [[String: String]]
        XCTAssertEqual(msgs.map { $0["role"]! }, ["system", "user"])
        XCTAssertEqual(msgs[1]["content"], Self.y25JSON)
        XCTAssertTrue(msgs[0]["content"]!.contains("bác sĩ"))
    }

    func testStaleDeviceTotalsIgnored() {
        var h = y25Day()
        h.today = ActivityTotals(steps: 9999, calories: 400_000, distanceMeters: 7000)
        h.syncedAt = at(15, 21)
        h.series[.steps]!.append(HistoryPoint(timestamp: at(16, 10), value: 100, extra: ["calories": 3000, "distance": 70]))
        let d = HealthSummary.make(history: h, period: .day, profile: profile, now: now, calendar: cal).today!
        XCTAssertEqual(d.steps, 128)
        XCTAssertEqual(d.calories, 4)
        XCTAssertEqual(d.distanceMeters, 89)
    }

    // MARK: - Tuần có giấc ngủ

    private func week() -> DeviceHistory {
        let normal: [(SleepStage, Int)] = [(.light, 120), (.deep, 100), (.rem, 90), (.light, 140)]
        let sleeps = [
            night(9, 22, 30, normal),
            night(10, 22, 45, normal),
            night(11, 22, 40, normal),
            // Ngủ 00:30: ngắn, ít ngủ sâu, ít REM, nhiều nông, thức 3 lần.
            night(13, 0, 30, [(.light, 60), (.deep, 50), (.awake, 10), (.light, 100), (.awake, 5), (.rem, 30), (.awake, 10), (.light, 125)]),
            night(13, 23, 50, [(.light, 150), (.deep, 90), (.rem, 80), (.light, 80)]),
            night(14, 22, 30, normal),
            night(15, 23, 30, [(.light, 120), (.deep, 60), (.awake, 5), (.rem, 70), (.light, 160)]),
        ]
        var steps: [HistoryPoint] = []
        for (day, n) in [(10, 9000), (11, 7000), (13, 8500), (14, 12000), (15, 5000)] {
            steps.append(HistoryPoint(timestamp: at(day, 12), value: Double(n), extra: ["calories": Double(n) * 40, "distance": Double(n) * 0.7]))
        }
        steps.append(HistoryPoint(timestamp: at(16, 9), value: 1200))
        let hr = [(16, 1, 58.0), (16, 3, 55), (16, 5, 60), (16, 9, 80), (14, 18, 150)].map {
            HistoryPoint(timestamp: at($0.0, $0.1), value: $0.2)
        }
        return DeviceHistory(
            series: [.steps: steps, .heartRate: hr, .stress: [HistoryPoint(timestamp: at(15, 10), value: 35)]],
            sleep: sleeps,
            workouts: [Workout(type: 1, name: "Chạy bộ", start: at(14, 18), end: at(14, 18, 32), activeSeconds: 1800, calories: 250,
                               distanceMeters: 4000, avgHeartRate: 150, maxHeartRate: 172)],
            today: ActivityTotals(steps: 1200, calories: 50_000, distanceMeters: 800), days: 7, syncedAt: at(16, 10)
        )
    }

    func testWeekSleepAndSteps() {
        let s = HealthSummary.make(history: week(), period: .week, profile: profile, now: now, calendar: cal)
        XCTAssertEqual(s.days.count, 7)
        XCTAssertEqual(s.days.map(\.steps), [9000, 7000, 0, 8500, 12000, 5000, 1200])
        XCTAssertEqual(s.averageSteps, 8300) // bỏ hôm nay và ngày 0 bước
        XCTAssertEqual(s.daysGoalMet, 3)
        XCTAssertEqual(s.nights.count, 7)

        let bad = s.days[3].sleep! // đêm 13/10
        XCTAssertEqual(bad.asleepMinutes, 365)
        XCTAssertEqual(bad.wakeUps, 3)
        XCTAssertEqual(bad.bedtimeDeviation, 112)
        XCTAssertEqual(HealthFindings.lateMinutes(bad), 90)
        XCTAssertEqual(HealthFindings.nightCodes(bad), [
            "sleep.short", "sleep.deep_low", "sleep.light_abnormal", "sleep.rem_low", "sleep.late", "sleep.wake_many",
        ])
        XCTAssertEqual(bad.score, 59)
        XCTAssertEqual(HealthFindings.scoreLabel(bad.score), "Kém")
        XCTAssertEqual(s.days[0].sleep!.score, 100)
        XCTAssertEqual(s.days.compactMap { $0.sleep?.bedtimeDeviation }, [3, 112, 44, 45, 23])

        let f = HealthFindings.evaluate(s)
        XCTAssertEqual(f.map(\.code), [
            "steps.goal_met", "hr.normal", "sleep.short", "sleep.deep_low", "sleep.light_abnormal", "sleep.late",
            "sleep.irregular", "sleep.score", "stress.normal", "workout.who_below", "bmi.normal",
        ])
        XCTAssertEqual(f.first { $0.code == "sleep.short" }?.values, ["nights": 3, "of": 7])
        XCTAssertEqual(f.first { $0.code == "sleep.irregular" }?.values["avgDeviationMin"], 45.4)
        XCTAssertEqual(s.workouts.first?.zone, .aerobic)
        XCTAssertEqual(s.restingHeartRate, 55)

        let json = HealthReportPrompt.userJSON(s, findings: f)
        XCTAssertTrue(json.contains(#""from":"2026-10-10""#))
        XCTAssertTrue(json.contains(#"{"bed":"00:30","date":"2026-10-13","deepPct":13.7,"remPct":8.2,"score":59,"sleepMin":365,"steps":8500,"wake":"07:00","wakeUps":3}"#))
        XCTAssertTrue(json.contains(#""zone":"aerobic""#))
        XCTAssertTrue(json.contains(#""avgSteps":8300"#))
    }

    func testDaySleepFindings() {
        let s = HealthSummary.make(history: week(), period: .day, profile: profile, now: now, calendar: cal)
        let n = s.today!.sleep!
        XCTAssertEqual(n.asleepMinutes, 410)
        XCTAssertEqual(n.wakeUps, 1)
        XCTAssertEqual(n.score, 91)
        XCTAssertEqual(s.today!.restingHeartRate, 55)
        let f = HealthFindings.evaluate(s).filter { $0.area == "sleep" }
        XCTAssertEqual(f.map(\.code), ["sleep.short", "sleep.deep_low", "sleep.light_abnormal", "sleep.late", "sleep.score"])
        XCTAssertEqual(f.last?.severity, .ok)
        XCTAssertTrue(HealthReportPrompt.userJSON(s, findings: f).contains(#""bed":"23:30""#))
    }

    func testBloodPressureCategories() {
        func code(_ s: Double, _ d: Double) -> String { HealthFindings.bloodPressureCategory(systolic: s, diastolic: d).0 }
        XCTAssertEqual(code(115, 75), "bp.normal")
        XCTAssertEqual(code(122, 72), "bp.elevated")
        XCTAssertEqual(code(125, 82), "bp.stage1")
        XCTAssertEqual(code(135, 70), "bp.stage1")
        XCTAssertEqual(code(142, 85), "bp.stage2")
        XCTAssertEqual(code(185, 100), "bp.crisis")
        XCTAssertEqual(code(88, 58), "bp.low")
        XCTAssertEqual(HealthFindings.bloodPressureCategory(systolic: 132, diastolic: 70).1, .warn)
    }

    func testSpo2AndHeartRules() {
        var h = y25Day()
        h.series[.spo2] = [HistoryPoint(timestamp: at(16, 2), value: 93, extra: ["min": 88]), HistoryPoint(timestamp: at(16, 3), value: 95)]
        h.series[.heartRate] = [HistoryPoint(timestamp: at(16, 2), value: 38), HistoryPoint(timestamp: at(16, 3), value: 70)]
        let f = HealthFindings.evaluate(HealthSummary.make(history: h, period: .day, profile: profile, now: now, calendar: cal))
        XCTAssertEqual(f.first { $0.area == "spo2" }?.code, "spo2.low")
        XCTAssertEqual(f.first { $0.area == "spo2" }?.values["below90"], 1)
        XCTAssertEqual(f.first { $0.area == "heart" }?.code, "hr.low")
        XCTAssertEqual(HealthFindings.worst(f, area: "spo2"), .warn)
        XCTAssertEqual(HeartRateZone.of(95, maxHeartRate: 190), .warmUp)
        XCTAssertEqual(HeartRateZone.of(175, maxHeartRate: 190), .extreme)
        XCTAssertEqual(HeartRateZone.of(80, maxHeartRate: 190), .smooth)
    }

    // MARK: - Đọc câu trả lời LLM

    func testParseFencedJSONAndOverrideStatus() {
        let f = [HealthFinding("bp.stage1", .warn), HealthFinding("steps.goal_met", .ok)]
        let answer = """
        <think>nháp</think>
        ```json
        {"title":"Ngày ổn định","summary":"Bạn vận động tốt.","sections":[
          {"key":"bp","status":"ok","text":"Huyết áp hơi cao, nên đi khám."},
          {"key":"activity","status":"warn","text":"Đạt mục tiêu bước."},
          {"key":"sleep","status":"notice","text":""}],
         "tips":["Đi bộ 30 phút","Ngủ trước 23h"],"disclaimer":""}
        ```
        """
        let r = HealthReportPrompt.parse(answer, findings: f, period: .day, now: now)
        XCTAssertFalse(r.plainText)
        XCTAssertEqual(r.title, "Ngày ổn định")
        XCTAssertEqual(r.sections.map(\.key), ["bp", "activity"])
        XCTAssertEqual(r.sections.map(\.status), [.warn, .ok]) // theo findings, không theo LLM
        XCTAssertEqual(r.tips, ["Đi bộ 30 phút", "Ngủ trước 23h"])
        XCTAssertEqual(r.disclaimer, HealthReportPrompt.defaultDisclaimer)
        XCTAssertTrue(r.text.contains("[warn] Huyết áp: Huyết áp hơi cao"))
    }

    func testParsePlainTextFallback() {
        let r = HealthReportPrompt.parse("Hôm nay bạn đi ít, hãy đi bộ thêm.", findings: [], period: .week, now: now)
        XCTAssertTrue(r.plainText)
        XCTAssertEqual(r.title, "Báo cáo sức khoẻ 7 ngày")
        XCTAssertEqual(r.summary, "Hôm nay bạn đi ít, hãy đi bộ thêm.")
        XCTAssertTrue(r.sections.isEmpty)
    }

    func testResponseContent() {
        let ok = Data(#"{"choices":[{"message":{"role":"assistant","content":" {\"title\":\"A\"} "}}]}"#.utf8)
        XCTAssertEqual(HealthReportPrompt.content(fromResponse: ok), #"{"title":"A"}"#)
        let thinking = Data(#"{"choices":[{"message":{"content":null,"reasoning_content":"x"}}]}"#.utf8)
        XCTAssertEqual(HealthReportPrompt.content(fromResponse: thinking), "x")
        XCTAssertNil(HealthReportPrompt.content(fromResponse: Data("error code: 1010".utf8)))
    }

    // MARK: - Cấu hình và lỗi

    func testConfigParseHidesKey() {
        let env = """
        # máy chủ AI
        LLM_API_BASE=https://llm.example.net/v1/
        export LLM_MODEL="Qwen/Qwen3.6-35B-A3B-FP8"
        LLM_API_KEY='mtt_secret'
        """
        let c = HealthLLMConfig.parse(env: env)!
        XCTAssertEqual(c.baseURL.absoluteString, "https://llm.example.net/v1")
        XCTAssertEqual(c.model, "Qwen/Qwen3.6-35B-A3B-FP8")
        XCTAssertEqual(c.apiKey, "mtt_secret")
        XCTAssertFalse(c.description.contains("mtt_secret"))
        XCTAssertNil(HealthLLMConfig.parse(env: "LLM_API_BASE=https://x/v1"))

        let r = HealthReportClient(config: c).urlRequest(body: Data("{}".utf8))
        XCTAssertEqual(r.url?.absoluteString, "https://llm.example.net/v1/chat/completions")
        XCTAssertEqual(r.value(forHTTPHeaderField: "X-API-Key"), "mtt_secret")
        XCTAssertTrue(r.value(forHTTPHeaderField: "User-Agent")!.hasPrefix("Mozilla/5.0"))
        XCTAssertEqual(r.timeoutInterval, 90)
    }

    func testErrorMapping() {
        XCTAssertEqual(HealthReportError.from(status: 502, body: ""), .restarting)
        XCTAssertEqual(HealthReportError.from(status: 502, body: "").errorDescription, "Máy chủ AI đang khởi động lại, thử lại sau vài phút")
        XCTAssertEqual(HealthReportError.from(status: 403, body: "error code: 1010"), .blocked)
        XCTAssertEqual(HealthReportError.from(status: 401, body: ""), .unauthorized)
        XCTAssertEqual(HealthReportError.from(status: 524, body: ""), .timeout)
        XCTAssertEqual(HealthReportError.from(status: 500, body: ""), .http(500))
        XCTAssertEqual(HealthReportError.notConfigured.errorDescription, "Chưa cấu hình máy chủ AI")
    }

    func testJSONWriter() {
        XCTAssertEqual(HealthJSON.encode(["b": 1.25, "a": [true, "x\"y\n"], "c": 3.0, "d": "Nữ"] as [String: Any]),
                       #"{"a":[true,"x\"y\n"],"b":1.3,"c":3,"d":"Nữ"}"#)
    }
}
