import Foundation

/// Một mục của báo cáo (`key` là một trong `HealthFindings.areas`).
public struct HealthReportSection: Sendable, Equatable, Codable {
    public var key: String
    public var status: HealthSeverity
    public var text: String

    public init(key: String, status: HealthSeverity, text: String) {
        self.key = key
        self.status = status
        self.text = text
    }

    public var title: String { HealthFindings.areaTitle(key) }
}

/// Báo cáo LLM viết xong (đã chuẩn hoá). `plainText` = model không trả JSON, `summary` là nguyên văn.
public struct HealthReport: Sendable, Equatable, Codable {
    public var title: String
    public var summary: String
    public var sections: [HealthReportSection]
    public var tips: [String]
    public var disclaimer: String
    public var plainText: Bool
    public var period: HealthPeriod
    public var generatedAt: Date

    public init(
        title: String, summary: String, sections: [HealthReportSection] = [], tips: [String] = [],
        disclaimer: String = HealthReportPrompt.defaultDisclaimer, plainText: Bool = false, period: HealthPeriod = .day,
        generatedAt: Date = Date()
    ) {
        self.title = title
        self.summary = summary
        self.sections = sections
        self.tips = tips
        self.disclaimer = disclaimer
        self.plainText = plainText
        self.period = period
        self.generatedAt = generatedAt
    }

    /// Bản chữ thuần (kênh lệnh, log).
    public var text: String {
        var lines = [title, summary]
        for s in sections { lines.append("[\(s.status.rawValue)] \(s.title): \(s.text)") }
        for t in tips { lines.append("• \(t)") }
        lines.append(disclaimer)
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// Báo cáo sức khoẻ AI, bước 3: dựng yêu cầu chat cho LLM (OpenAI-compatible) và đọc kết quả.
/// Tin nhắn người dùng CHỈ chứa số liệu + phát hiện dạng JSON gọn (không id / tên thiết bị); LLM chỉ diễn đạt,
/// mức độ (`status`) của từng mục luôn lấy lại từ `HealthFindings` chứ không tin LLM.
public enum HealthReportPrompt {
    public static let defaultDisclaimer =
        "Báo cáo do AI viết từ số liệu của thiết bị đeo, chỉ để tham khảo, không thay cho chẩn đoán của bác sĩ."

    public static let system = """
    Bạn là trợ lý sức khoẻ của ứng dụng SmartWear. Từ dữ liệu JSON (số liệu của thiết bị đeo và các phát hiện \
    "findings" ứng dụng đã tính sẵn), viết một báo cáo ngắn, thân thiện bằng tiếng Việt, xưng "bạn".
    Quy tắc:
    - Chỉ dùng số trong dữ liệu, không bịa số, không tự đặt ngưỡng khác. Mức độ của mỗi mục lấy theo "sev" của findings \
    thuộc mục đó (ok = tốt, notice = cần chú ý, warn = đáng lo).
    - Đây không phải chẩn đoán y khoa: không gọi tên bệnh, không nói về thuốc. Finding mức warn về huyết áp (bp.*) hoặc \
    SpO2 (spo2.*) thì khuyên đi khám bác sĩ. Huyết áp và SpO2 đo bằng đồng hồ chỉ là ước lượng.
    - Ngày cuối của kỳ là hôm nay, mới tính tới giờ "asOf": đừng chê số bước thấp của hôm nay, chỉ động viên.
    - Mục không có dữ liệu thì bỏ qua; riêng sleep.no_data thì nhắc đeo thiết bị khi ngủ. Gọi thiết bị đúng loại theo profile.device (nhẫn, đồng hồ, vòng tay) nếu có.
    - Mã finding: steps (bước so với mục tiêu), hr (nhịp tim), spo2, bp (phân loại AHA: elevated = hơi cao, stage1/stage2 = \
    tăng huyết áp độ 1/2), sleep (short/long = ngắn/dài, deep/rem/light = tỉ lệ giai đoạn, late = ngủ sau 23:00, \
    wake_many = thức ≥3 lần, irregular = giờ ngủ thất thường, score = điểm ngủ 0–100), stress, workout, bmi.
    - Đơn vị: phút (Min), nhịp/phút, mmHg, kcal, mét (M). "pct"/"Pct" là phần trăm thang 0–100 (0.4 nghĩa là 0,4%, \
    không phải 40%); Pct của giấc ngủ là % trên thời gian ngủ. "avg" là trung bình, "latest" là lần đo mới nhất.
    - Mỗi "text" 1–2 câu. "tips" 2–4 lời khuyên cụ thể, ngắn. "summary" 2–3 câu.
    Chỉ trả về MỘT đối tượng JSON, không thêm chữ nào khác:
    {"title": string, "summary": string, "sections": [{"key": "activity|heart|spo2|bp|sleep|stress|workout|body", \
    "status": "ok|notice|warn", "text": string}], "tips": [string], "disclaimer": string}
    """

    /// Nội dung tin nhắn người dùng: JSON gọn, khoá sắp xếp (giống hệt bản Kotlin).
    public static func userJSON(_ s: HealthSummary, findings: [HealthFinding]) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = s.timeZone
        let hm = fmt("HH:mm", s.timeZone), ymd = fmt("yyyy-MM-dd", s.timeZone)
        var root: [String: Any] = [
            "period": s.period.rawValue,
            "date": ymd.string(from: s.generatedAt),
            "asOf": hm.string(from: s.generatedAt),
        ]
        if s.period == .week, let f = s.days.first { root["from"] = ymd.string(from: f.date) }

        let p = s.profile
        var profile: [String: Any] = ["stepGoal": p.stepGoal, "hrMax": p.maxHeartRate]
        profile["age"] = p.age
        profile["sex"] = p.male.map { $0 ? "nam" : "nữ" }
        profile["heightCm"] = p.heightCm
        profile["weightKg"] = p.weightKg.map(HealthFindings.round1)
        profile["bmi"] = p.bmi.map(HealthFindings.round1)
        profile["device"] = p.device
        root["profile"] = profile

        if s.period == .day, let d = s.today {
            var a: [String: Any] = ["steps": d.steps, "kcal": d.calories, "distanceM": d.distanceMeters]
            a["activeMin"] = d.activeMinutes
            root["activity"] = a
            if let n = d.sleep { root["sleep"] = night(n, hm) }
            if d.napMinutes > 0 { root["napMin"] = d.napMinutes }
        } else {
            root["activity"] = [
                "totalSteps": s.totalSteps, "avgSteps": s.averageSteps, "daysGoalMet": s.daysGoalMet,
                "daysCounted": s.stepDays.count,
            ]
            if !s.nights.isEmpty {
                root["sleep"] = ["nights": s.nights.count, "avgMin": s.averageSleepMinutes ?? 0, "avgScore": s.averageSleepScore ?? 0]
            }
            root["days"] = s.days.map { d -> [String: Any] in
                var o: [String: Any] = ["date": ymd.string(from: d.date), "steps": d.steps]
                if !d.hasData { o["noData"] = true }
                o["hrAvg"] = d.heartRate.map { HealthFindings.round1($0.avg) }
                o["restingHr"] = d.restingHeartRate
                if let n = d.sleep {
                    o["sleepMin"] = n.asleepMinutes
                    o["score"] = n.score
                    o["bed"] = hm.string(from: n.bedtime)
                    o["wake"] = hm.string(from: n.wakeTime)
                    o["deepPct"] = HealthFindings.round1(n.deepPct)
                    if n.remMinutes > 0 { o["remPct"] = HealthFindings.round1(n.remPct) }
                    o["wakeUps"] = n.wakeUps
                }
                if d.napMinutes > 0 { o["napMin"] = d.napMinutes }
                return o
            }
        }
        if let hr = s.heartRate {
            var o = stat(hr)
            o["resting"] = s.restingHeartRate
            root["heart"] = o
        }
        if let o = s.spo2 {
            var v = stat(o)
            v["below90"] = s.spo2Below90
            root["spo2"] = v
        }
        if let bp = s.bloodPressure {
            root["bp"] = [
                "avgSys": HealthFindings.round1(bp.avgSystolic), "avgDia": HealthFindings.round1(bp.avgDiastolic),
                "latest": "\(bp.latestSystolic)/\(bp.latestDiastolic)", "n": bp.count,
            ]
        }
        if let st = s.stress { root["stress"] = stat(st) }
        if let h = s.hrv { root["hrv"] = stat(h) }
        if !s.workouts.isEmpty {
            let when = fmt(s.period == .day ? "HH:mm" : "yyyy-MM-dd HH:mm", s.timeZone)
            root["workouts"] = s.workouts.map { w -> [String: Any] in
                var o: [String: Any] = ["name": w.name, "start": when.string(from: w.start), "min": w.minutes]
                o["kcal"] = w.calories
                o["distanceM"] = w.distanceMeters
                o["avgHr"] = w.avgHeartRate
                o["maxHr"] = w.maxHeartRate
                o["zone"] = w.zone?.rawValue
                return o
            }
        }
        root["findings"] = findings.map { f -> [String: Any] in
            var o: [String: Any] = ["code": f.code, "sev": f.severity.rawValue]
            if !f.values.isEmpty { o["v"] = f.values }
            return o
        }
        return HealthJSON.encode(root)
    }

    /// Thân yêu cầu `POST {base}/chat/completions`. Tắt chế độ suy nghĩ của Qwen3 (nếu không nó ăn hết `max_tokens`).
    public static func requestBody(model: String, summary: HealthSummary, findings: [HealthFinding], maxTokens: Int = 900) -> Data {
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": userJSON(summary, findings: findings)],
            ],
            "temperature": 0.3,
            "max_tokens": maxTokens,
            "response_format": ["type": "json_object"],
            "chat_template_kwargs": ["enable_thinking": false],
        ]
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    }

    /// Lấy chữ trả lời từ JSON `chat/completions` (`content`, dự phòng `reasoning_content`). nil nếu không đọc được.
    public static func content(fromResponse data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msg = (root["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any] else { return nil }
        let text = (msg["content"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? msg["reasoning_content"] as? String
        return text?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Đọc câu trả lời thành báo cáo: bỏ `<think>…</think>` và rào ```json, lấy đối tượng JSON ngoài cùng; không đọc
    /// được thì trả bản chữ thuần. `status` mỗi mục được ghi đè bằng mức nặng nhất của findings cùng mục.
    public static func parse(_ content: String, findings: [HealthFinding], period: HealthPeriod, now: Date = Date()) -> HealthReport {
        let fallbackTitle = period == .day ? "Báo cáo sức khoẻ hôm nay" : "Báo cáo sức khoẻ 7 ngày"
        var text = content
        if let r = text.range(of: "</think>") { text = String(text[r.upperBound...]) }
        text = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close,
              let obj = try? JSONSerialization.jsonObject(with: Data(text[open...close].utf8)) as? [String: Any] else {
            return HealthReport(title: fallbackTitle, summary: text, plainText: true, period: period, generatedAt: now)
        }
        func str(_ v: Any?) -> String { ((v as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        let sections = (obj["sections"] as? [[String: Any]] ?? []).compactMap { o -> HealthReportSection? in
            let key = str(o["key"] ?? o["metric"]).lowercased()
            let body = str(o["text"] ?? o["insight"])
            guard !key.isEmpty, !body.isEmpty else { return nil }
            let status = HealthFindings.worst(findings, area: key) ?? severity(str(o["status"]))
            return HealthReportSection(key: key, status: status, text: body)
        }
        let tips = (obj["tips"] as? [Any])?.map { str($0) }.filter { !$0.isEmpty } ?? [str(obj["tips"])].filter { !$0.isEmpty }
        let title = str(obj["title"]), summary = str(obj["summary"]), disclaimer = str(obj["disclaimer"])
        return HealthReport(
            title: title.isEmpty ? fallbackTitle : title, summary: summary, sections: sections, tips: tips,
            disclaimer: disclaimer.isEmpty ? defaultDisclaimer : disclaimer, period: period, generatedAt: now
        )
    }

    static func severity(_ s: String) -> HealthSeverity {
        switch s.lowercased() {
        case "ok", "good", "normal", "tốt": return .ok
        case "warn", "warning", "bad", "alert": return .warn
        default: return .notice
        }
    }

    private static func night(_ n: HealthNight, _ hm: DateFormatter) -> [String: Any] {
        var o: [String: Any] = [
            "bed": hm.string(from: n.bedtime), "wake": hm.string(from: n.wakeTime), "asleepMin": n.asleepMinutes,
            "deepMin": n.deepMinutes, "lightMin": n.lightMinutes, "awakeMin": n.awakeMinutes,
            "deepPct": HealthFindings.round1(n.deepPct), "lightPct": HealthFindings.round1(n.lightPct),
            "wakeUps": n.wakeUps, "score": n.score, "scoreLabel": HealthFindings.scoreLabel(n.score),
        ]
        if n.remMinutes > 0 {
            o["remMin"] = n.remMinutes
            o["remPct"] = HealthFindings.round1(n.remPct)
        }
        o["bedtimeDeviationMin"] = n.bedtimeDeviation
        return o
    }

    private static func stat(_ s: HealthStat) -> [String: Any] {
        ["avg": HealthFindings.round1(s.avg), "min": HealthFindings.round1(s.min), "max": HealthFindings.round1(s.max), "n": s.count]
    }

    private static func fmt(_ pattern: String, _ tz: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = pattern
        return f
    }
}

/// Bộ ghi JSON nhỏ, tất định: khoá sắp xếp, số nguyên không có ".0", số thực 1 chữ số thập phân, giữ nguyên Unicode.
/// Cùng quy tắc với `HealthJson` Kotlin để hai nền tảng gửi cùng một chuỗi.
public enum HealthJSON {
    public static func encode(_ value: Any?) -> String {
        var out = ""
        write(value, &out)
        return out
    }

    private static func write(_ value: Any?, _ out: inout String) {
        switch value {
        case nil: out += "null"
        case let b as Bool: out += b ? "true" : "false"
        case let i as Int: out += String(i)
        case let d as Double: out += number(d)
        case let s as String: string(s, &out)
        case let m as [String: Any]:
            out += "{"
            var first = true
            for k in m.keys.sorted() {
                guard let v = m[k], !(v is NSNull) else { continue }
                if !first { out += "," }
                first = false
                string(k, &out)
                out += ":"
                write(v, &out)
            }
            out += "}"
        case let m as [String: Double]: write(m as [String: Any], &out)
        case let a as [Any]:
            out += "["
            for (i, v) in a.enumerated() {
                if i > 0 { out += "," }
                write(v, &out)
            }
            out += "]"
        default: string("\(value!)", &out)
        }
    }

    static func number(_ d: Double) -> String {
        guard d.isFinite else { return "null" }
        let r = HealthFindings.round1(d)
        if r == r.rounded(), abs(r) < 1e15 { return String(Int(r)) }
        return String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), r)
    }

    private static func string(_ s: String, _ out: inout String) {
        out += "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where u.value < 0x20: out += String(format: "\\u%04x", u.value)
            default: out.unicodeScalars.append(u)
            }
        }
        out += "\""
    }
}
