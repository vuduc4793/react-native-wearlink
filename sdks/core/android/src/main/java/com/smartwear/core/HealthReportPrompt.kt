package com.smartwear.core

import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

/** Một mục của báo cáo ([key] là một trong [HealthFindings.areas]). */
data class HealthReportSection(val key: String, val status: HealthSeverity, val text: String) {
    val title: String get() = HealthFindings.areaTitle(key)
}

/** Báo cáo LLM viết xong (đã chuẩn hoá). [plainText] = model không trả JSON, [summary] là nguyên văn. */
data class HealthReport(
    val title: String,
    val summary: String,
    val sections: List<HealthReportSection> = emptyList(),
    val tips: List<String> = emptyList(),
    val disclaimer: String = HealthReportPrompt.DEFAULT_DISCLAIMER,
    val plainText: Boolean = false,
    val period: HealthPeriod = HealthPeriod.DAY,
    val generatedAt: Long = System.currentTimeMillis(),
) {
    /** Bản chữ thuần (log). */
    val text: String
        get() = (listOf(title, summary) + sections.map { "[${it.status.key}] ${it.title}: ${it.text}" } + tips.map { "• $it" } + disclaimer)
            .filter { it.isNotEmpty() }.joinToString("\n")
}

/**
 * Báo cáo sức khoẻ AI, bước 3: dựng yêu cầu chat cho LLM (OpenAI-compatible) và đọc kết quả.
 * Tin nhắn người dùng CHỈ chứa số liệu + phát hiện dạng JSON gọn (không id / tên thiết bị); LLM chỉ diễn đạt,
 * mức độ (`status`) của từng mục luôn lấy lại từ [HealthFindings] chứ không tin LLM. Trùng từng ký tự với bản Swift.
 */
object HealthReportPrompt {
    const val DEFAULT_DISCLAIMER =
        "Báo cáo do AI viết từ số liệu của thiết bị đeo, chỉ để tham khảo, không thay cho chẩn đoán của bác sĩ."

    val SYSTEM: String = listOf(
        "Bạn là trợ lý sức khoẻ của ứng dụng SmartWear. Từ dữ liệu JSON (số liệu của thiết bị đeo và các phát hiện " +
            "\"findings\" ứng dụng đã tính sẵn), viết một báo cáo ngắn, thân thiện bằng tiếng Việt, xưng \"bạn\".",
        "Quy tắc:",
        "- Chỉ dùng số trong dữ liệu, không bịa số, không tự đặt ngưỡng khác. Mức độ của mỗi mục lấy theo \"sev\" của findings " +
            "thuộc mục đó (ok = tốt, notice = cần chú ý, warn = đáng lo).",
        "- Đây không phải chẩn đoán y khoa: không gọi tên bệnh, không nói về thuốc. Finding mức warn về huyết áp (bp.*) hoặc " +
            "SpO2 (spo2.*) thì khuyên đi khám bác sĩ. Huyết áp và SpO2 đo bằng đồng hồ chỉ là ước lượng.",
        "- Ngày cuối của kỳ là hôm nay, mới tính tới giờ \"asOf\": đừng chê số bước thấp của hôm nay, chỉ động viên.",
        "- Mục không có dữ liệu thì bỏ qua; riêng sleep.no_data thì nhắc đeo thiết bị khi ngủ. Gọi thiết bị đúng loại theo profile.device (nhẫn, đồng hồ, vòng tay) nếu có.",
        "- Mã finding: steps (bước so với mục tiêu), hr (nhịp tim), spo2, bp (phân loại AHA: elevated = hơi cao, stage1/stage2 = " +
            "tăng huyết áp độ 1/2), sleep (short/long = ngắn/dài, deep/rem/light = tỉ lệ giai đoạn, late = ngủ sau 23:00, " +
            "wake_many = thức ≥3 lần, irregular = giờ ngủ thất thường, score = điểm ngủ 0–100), stress, workout, bmi.",
        "- Đơn vị: phút (Min), nhịp/phút, mmHg, kcal, mét (M). \"pct\"/\"Pct\" là phần trăm thang 0–100 (0.4 nghĩa là 0,4%, " +
            "không phải 40%); Pct của giấc ngủ là % trên thời gian ngủ. \"avg\" là trung bình, \"latest\" là lần đo mới nhất.",
        "- Mỗi \"text\" 1–2 câu. \"tips\" 2–4 lời khuyên cụ thể, ngắn. \"summary\" 2–3 câu.",
        "Chỉ trả về MỘT đối tượng JSON, không thêm chữ nào khác:",
        "{\"title\": string, \"summary\": string, \"sections\": [{\"key\": \"activity|heart|spo2|bp|sleep|stress|workout|body\", " +
            "\"status\": \"ok|notice|warn\", \"text\": string}], \"tips\": [string], \"disclaimer\": string}",
    ).joinToString("\n")

    private fun fmt(pattern: String, zone: ZoneId) = DateTimeFormatter.ofPattern(pattern, Locale.ROOT).withZone(zone)
    private fun DateTimeFormatter.at(ms: Long) = format(Instant.ofEpochMilli(ms))

    /** Nội dung tin nhắn người dùng: JSON gọn, khoá sắp xếp (giống hệt bản Swift). */
    fun userJson(s: HealthSummary, findings: List<HealthFinding>): String {
        val hm = fmt("HH:mm", s.zone)
        val ymd = fmt("yyyy-MM-dd", s.zone)
        val r1 = HealthFindings::round1
        val root = mutableMapOf<String, Any?>(
            "period" to s.period.key,
            "date" to ymd.at(s.generatedAt),
            "asOf" to hm.at(s.generatedAt),
        )
        if (s.period == HealthPeriod.WEEK) s.days.firstOrNull()?.let { root["from"] = ymd.at(it.date) }

        val p = s.profile
        root["profile"] = mapOf(
            "stepGoal" to p.stepGoal, "hrMax" to p.maxHeartRate, "age" to p.age, "sex" to p.male?.let { if (it) "nam" else "nữ" },
            "heightCm" to p.heightCm, "weightKg" to p.weightKg?.let(r1), "bmi" to p.bmi?.let(r1), "device" to p.device,
        )

        val d = s.today
        if (s.period == HealthPeriod.DAY && d != null) {
            root["activity"] = mapOf("steps" to d.steps, "kcal" to d.calories, "distanceM" to d.distanceMeters, "activeMin" to d.activeMinutes)
            d.sleep?.let { root["sleep"] = night(it, hm) }
            if (d.napMinutes > 0) root["napMin"] = d.napMinutes
        } else {
            root["activity"] = mapOf(
                "totalSteps" to s.totalSteps, "avgSteps" to s.averageSteps, "daysGoalMet" to s.daysGoalMet, "daysCounted" to s.stepDays.size,
            )
            if (s.nights.isNotEmpty()) {
                root["sleep"] = mapOf("nights" to s.nights.size, "avgMin" to (s.averageSleepMinutes ?: 0), "avgScore" to (s.averageSleepScore ?: 0))
            }
            root["days"] = s.days.map { day ->
                val o = mutableMapOf<String, Any?>("date" to ymd.at(day.date), "steps" to day.steps)
                if (!day.hasData) o["noData"] = true
                o["hrAvg"] = day.heartRate?.let { r1(it.avg) }
                o["restingHr"] = day.restingHeartRate
                day.sleep?.let { n ->
                    o["sleepMin"] = n.asleepMinutes
                    o["score"] = n.score
                    o["bed"] = hm.at(n.bedtime)
                    o["wake"] = hm.at(n.wakeTime)
                    o["deepPct"] = r1(n.deepPct)
                    if (n.remMinutes > 0) o["remPct"] = r1(n.remPct)
                    o["wakeUps"] = n.wakeUps
                }
                if (day.napMinutes > 0) o["napMin"] = day.napMinutes
                o
            }
        }
        s.heartRate?.let { root["heart"] = stat(it) + ("resting" to s.restingHeartRate) }
        s.spo2?.let { root["spo2"] = stat(it) + ("below90" to s.spo2Below90) }
        s.bloodPressure?.let { bp ->
            root["bp"] = mapOf(
                "avgSys" to r1(bp.avgSystolic), "avgDia" to r1(bp.avgDiastolic), "latest" to "${bp.latestSystolic}/${bp.latestDiastolic}", "n" to bp.count,
            )
        }
        s.stress?.let { root["stress"] = stat(it) }
        s.hrv?.let { root["hrv"] = stat(it) }
        if (s.workouts.isNotEmpty()) {
            val time = fmt(if (s.period == HealthPeriod.DAY) "HH:mm" else "yyyy-MM-dd HH:mm", s.zone)
            root["workouts"] = s.workouts.map { w ->
                mapOf(
                    "name" to w.name, "start" to time.at(w.start), "min" to w.minutes, "kcal" to w.calories, "distanceM" to w.distanceMeters,
                    "avgHr" to w.avgHeartRate, "maxHr" to w.maxHeartRate, "zone" to w.zone?.key,
                )
            }
        }
        root["findings"] = findings.map { f ->
            mapOf("code" to f.code, "sev" to f.severity.key, "v" to f.values.takeIf { it.isNotEmpty() })
        }
        return HealthJson.encode(root)
    }

    /** Thân yêu cầu `POST {base}/chat/completions`. Tắt chế độ suy nghĩ của Qwen3 (nếu không nó ăn hết `max_tokens`). */
    fun requestBody(model: String, summary: HealthSummary, findings: List<HealthFinding>, maxTokens: Int = 900): String =
        HealthJson.encode(
            mapOf(
                "model" to model,
                "messages" to listOf(
                    mapOf("role" to "system", "content" to SYSTEM),
                    mapOf("role" to "user", "content" to userJson(summary, findings)),
                ),
                "temperature" to 0.3,
                "max_tokens" to maxTokens,
                "response_format" to mapOf("type" to "json_object"),
                "chat_template_kwargs" to mapOf("enable_thinking" to false),
            ),
        )

    /** Lấy chữ trả lời từ JSON `chat/completions` (`content`, dự phòng `reasoning_content`). null nếu không đọc được. */
    fun contentFromResponse(body: String): String? = runCatching {
        val msg = JSONObject(body).getJSONArray("choices").getJSONObject(0).getJSONObject("message")
        val text = (msg.opt("content") as? String)?.takeIf { it.isNotEmpty() } ?: msg.opt("reasoning_content") as? String
        text?.trim()
    }.getOrNull()

    /**
     * Đọc câu trả lời thành báo cáo: bỏ `<think>…</think>` và rào ```json, lấy đối tượng JSON ngoài cùng; không đọc
     * được thì trả bản chữ thuần. `status` mỗi mục được ghi đè bằng mức nặng nhất của findings cùng mục.
     */
    fun parse(content: String, findings: List<HealthFinding>, period: HealthPeriod, now: Long = System.currentTimeMillis()): HealthReport {
        val fallbackTitle = if (period == HealthPeriod.DAY) "Báo cáo sức khoẻ hôm nay" else "Báo cáo sức khoẻ 7 ngày"
        var text = content
        text.indexOf("</think>").takeIf { it >= 0 }?.let { text = text.substring(it + "</think>".length) }
        text = text.split("\n").filterNot { it.trim().startsWith("```") }.joinToString("\n").trim()
        val open = text.indexOf('{')
        val close = text.lastIndexOf('}')
        val obj = (if (open in 0 until close) runCatching { JSONObject(text.substring(open, close + 1)) }.getOrNull() else null)
            ?: return HealthReport(fallbackTitle, text, plainText = true, period = period, generatedAt = now)
        fun str(v: Any?) = (v as? String)?.trim().orEmpty()
        val sections = (obj.opt("sections") as? JSONArray)?.let { arr ->
            (0 until arr.length()).mapNotNull { i ->
                val o = arr.opt(i) as? JSONObject ?: return@mapNotNull null
                val key = str(o.opt("key") ?: o.opt("metric")).lowercase()
                val body = str(o.opt("text") ?: o.opt("insight"))
                if (key.isEmpty() || body.isEmpty()) return@mapNotNull null
                HealthReportSection(key, HealthFindings.worst(findings, key) ?: HealthSeverity.of(str(o.opt("status"))), body)
            }
        }.orEmpty()
        val tips = when (val t = obj.opt("tips")) {
            is JSONArray -> (0 until t.length()).map { str(t.opt(it)) }.filter { it.isNotEmpty() }
            else -> listOf(str(t)).filter { it.isNotEmpty() }
        }
        val title = str(obj.opt("title"))
        val disclaimer = str(obj.opt("disclaimer"))
        return HealthReport(
            title.ifEmpty { fallbackTitle }, str(obj.opt("summary")), sections, tips, disclaimer.ifEmpty { DEFAULT_DISCLAIMER },
            period = period, generatedAt = now,
        )
    }

    private fun night(n: HealthNight, hm: DateTimeFormatter): Map<String, Any?> {
        val r1 = HealthFindings::round1
        return mapOf(
            "bed" to hm.at(n.bedtime), "wake" to hm.at(n.wakeTime), "asleepMin" to n.asleepMinutes, "deepMin" to n.deepMinutes,
            "lightMin" to n.lightMinutes, "awakeMin" to n.awakeMinutes, "deepPct" to r1(n.deepPct), "lightPct" to r1(n.lightPct),
            "wakeUps" to n.wakeUps, "score" to n.score, "scoreLabel" to HealthFindings.scoreLabel(n.score),
            "remMin" to n.remMinutes.takeIf { it > 0 }, "remPct" to if (n.remMinutes > 0) r1(n.remPct) else null,
            "bedtimeDeviationMin" to n.bedtimeDeviation,
        )
    }

    private fun stat(s: HealthStat): Map<String, Any?> = mapOf(
        "avg" to HealthFindings.round1(s.avg), "min" to HealthFindings.round1(s.min), "max" to HealthFindings.round1(s.max), "n" to s.count,
    )
}

/**
 * Bộ ghi JSON nhỏ, tất định: khoá sắp xếp, bỏ khoá có giá trị null, số nguyên không có ".0", số thực 1 chữ số thập
 * phân, giữ nguyên Unicode. Cùng quy tắc với `HealthJSON` Swift để hai nền tảng gửi cùng một chuỗi.
 */
object HealthJson {
    fun encode(value: Any?): String = StringBuilder().also { write(value, it) }.toString()

    private fun write(value: Any?, out: StringBuilder) {
        when (value) {
            null -> out.append("null")
            is Boolean -> out.append(value)
            is Int, is Long -> out.append(value)
            is Number -> out.append(number(value.toDouble()))
            is String -> string(value, out)
            is Map<*, *> -> {
                out.append('{')
                var first = true
                for (k in value.keys.map { it.toString() }.sorted()) {
                    val v = value[k] ?: continue
                    if (!first) out.append(',')
                    first = false
                    string(k, out)
                    out.append(':')
                    write(v, out)
                }
                out.append('}')
            }
            is Iterable<*> -> {
                out.append('[')
                value.forEachIndexed { i, v ->
                    if (i > 0) out.append(',')
                    write(v, out)
                }
                out.append(']')
            }
            else -> string(value.toString(), out)
        }
    }

    fun number(d: Double): String {
        if (!d.isFinite()) return "null"
        val r = HealthFindings.round1(d)
        return if (r == Math.rint(r) && kotlin.math.abs(r) < 1e15) r.toLong().toString() else String.format(Locale.ROOT, "%.1f", r)
    }

    private fun string(s: String, out: StringBuilder) {
        out.append('"')
        for (c in s) {
            when {
                c == '"' -> out.append("\\\"")
                c == '\\' -> out.append("\\\\")
                c == '\n' -> out.append("\\n")
                c == '\r' -> out.append("\\r")
                c == '\t' -> out.append("\\t")
                c < ' ' -> out.append(String.format(Locale.ROOT, "\\u%04x", c.code))
                else -> out.append(c)
            }
        }
        out.append('"')
    }
}
