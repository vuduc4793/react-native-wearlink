package com.smartwear.core

import kotlin.math.abs
import kotlin.math.sign

/** Mức độ của một phát hiện; cũng là màu trạng thái của mục trong báo cáo. Thứ tự = mức nặng tăng dần. */
enum class HealthSeverity(val key: String) {
    OK("ok"), NOTICE("notice"), WARN("warn");

    companion object {
        fun of(s: String): HealthSeverity = when (s.lowercase()) {
            "ok", "good", "normal", "tốt" -> OK
            "warn", "warning", "bad", "alert" -> WARN
            else -> NOTICE
        }
    }
}

/** Một phát hiện có mã ổn định (vd `sleep.short`, `bp.stage1`), mức độ và số liệu kèm theo. LLM chỉ diễn đạt lại. */
data class HealthFinding(val code: String, val severity: HealthSeverity, val values: Map<String, Double> = emptyMap()) {
    /** Mục báo cáo chứa phát hiện này (`activity`, `heart`, `spo2`, `bp`, `sleep`, `stress`, `workout`, `body`). */
    val area: String get() = HealthFindings.area(code)
}

/**
 * Báo cáo sức khoẻ AI, bước 2: lớp luật sinh phát hiện có mã từ [HealthSummary] (docs/research/mi-fitness-features.md).
 * Ngưỡng giống hệt bản Swift `HealthFindings`:
 * - Giấc ngủ (Mi Fitness `SleepInterpretationExtKt`, §2.3): ≤420 phút ngắn, >540 dài; sâu ngoài 20–60%; REM (nếu có)
 *   ngoài 10–30%; nông ngoài 20–60% (có REM) hoặc 60–80% (không REM); lên giường sau 23:00 là muộn; thức ≥3 lần.
 * - Điểm ngủ: công thức TỰ THIẾT KẾ của SmartWear (§5.1), không phải thuật toán đóng của Xiaomi; xem [sleepScore].
 * - Nhịp tim (§5.2): TB >100 nhanh, thấp nhất <40, nghỉ >80 hoặc <50; vùng tim theo 220 − tuổi.
 * - SpO2 (§5.3): <90% thấp (cảnh báo); TB <95% hơi thấp.
 * - Huyết áp: phân loại AHA/ACC 2017 (bình thường <120/<80, tăng 120–129/<80, độ 1 130–139 hoặc 80–89,
 *   độ 2 ≥140 hoặc ≥90, khủng hoảng >180 hoặc >120); thấp ≤90/≤60.
 * - Stress (nhánh Xiaomi): ≤50 bình thường, 51–80 vừa, >80 cao.
 * - Bước: so với mục tiêu; tuần: TB ngày đủ (bỏ hôm nay). Bài tập tuần: WHO ≥150 phút.
 * - BMI (Mi Fitness `WeightEvaluationHelper`): <18.5 gầy, ≥24 thừa cân, ≥28 béo phì.
 */
object HealthFindings {
    val areas = listOf("activity", "heart", "spo2", "bp", "sleep", "stress", "workout", "body")

    fun area(code: String): String = when (val p = code.substringBefore('.')) {
        "steps" -> "activity"
        "hr" -> "heart"
        "bmi" -> "body"
        else -> p
    }

    /** Tên mục tiếng Việt cho UI. */
    fun areaTitle(area: String): String = when (area) {
        "activity" -> "Vận động"
        "heart" -> "Nhịp tim"
        "spo2" -> "SpO2"
        "bp" -> "Huyết áp"
        "sleep" -> "Giấc ngủ"
        "stress" -> "Căng thẳng"
        "workout" -> "Bài tập"
        "body" -> "Cơ thể"
        else -> area
    }

    /** Mức nặng nhất của các phát hiện thuộc [area] (null nếu không có). */
    fun worst(findings: List<HealthFinding>, area: String): HealthSeverity? =
        findings.filter { it.area == area }.maxOfOrNull { it.severity }

    fun evaluate(s: HealthSummary): List<HealthFinding> {
        val out = mutableListOf<HealthFinding>()
        val week = s.period == HealthPeriod.WEEK

        // Vận động
        val goal = s.profile.stepGoal.toDouble()
        if (week) {
            val avg = s.averageSteps.toDouble()
            out += HealthFinding(
                if (avg >= goal) "steps.goal_met" else "steps.below_goal", if (avg >= goal) HealthSeverity.OK else HealthSeverity.NOTICE,
                mapOf("avg" to avg, "goal" to goal, "daysMet" to s.daysGoalMet.toDouble(), "days" to s.stepDays.size.toDouble()),
            )
        } else {
            s.today?.let { d ->
                val steps = d.steps.toDouble()
                out += HealthFinding(
                    if (steps >= goal) "steps.goal_met" else "steps.below_goal",
                    if (steps >= goal) HealthSeverity.OK else HealthSeverity.NOTICE,
                    mapOf("steps" to steps, "goal" to goal, "pct" to round1(steps * 100 / maxOf(goal, 1.0))),
                )
            }
        }

        // Nhịp tim
        s.heartRate?.let { hr ->
            val v = mutableMapOf("avg" to round1(hr.avg), "min" to hr.min, "max" to hr.max)
            s.restingHeartRate?.let { v["resting"] = it.toDouble() }
            val before = out.size
            if (hr.min < 40) out += HealthFinding("hr.low", HealthSeverity.WARN, v)
            if (hr.avg > 100) out += HealthFinding("hr.avg_high", HealthSeverity.NOTICE, v)
            s.restingHeartRate?.let { r ->
                if (r > 80) out += HealthFinding("hr.resting_high", HealthSeverity.NOTICE, v)
                if (r < 50) out += HealthFinding("hr.resting_low", HealthSeverity.NOTICE, v)
            }
            if (out.size == before) out += HealthFinding("hr.normal", HealthSeverity.OK, v)
        }

        // SpO2
        s.spo2?.let { o ->
            val v = mapOf("avg" to round1(o.avg), "min" to o.min, "below90" to s.spo2Below90.toDouble())
            out += when {
                o.min < 90 -> HealthFinding("spo2.low", HealthSeverity.WARN, v)
                o.avg < 95 -> HealthFinding("spo2.borderline", HealthSeverity.NOTICE, v)
                else -> HealthFinding("spo2.normal", HealthSeverity.OK, v)
            }
        }

        // Huyết áp
        s.bloodPressure?.let { bp ->
            val v = mapOf(
                "avgSys" to round1(bp.avgSystolic), "avgDia" to round1(bp.avgDiastolic), "maxSys" to bp.maxSystolic.toDouble(),
                "maxDia" to bp.maxDiastolic.toDouble(), "n" to bp.count.toDouble(),
            )
            val (code, sev) = bloodPressureCategory(bp.avgSystolic, bp.avgDiastolic)
            out += if (bp.maxSystolic > 180 || bp.maxDiastolic > 120) HealthFinding("bp.crisis", HealthSeverity.WARN, v) else HealthFinding(code, sev, v)
        }

        // Giấc ngủ
        out += sleepFindings(s)

        // Căng thẳng
        s.stress?.let { st ->
            val v = mapOf("avg" to round1(st.avg), "max" to st.max)
            out += when {
                st.avg > 80 -> HealthFinding("stress.high", HealthSeverity.NOTICE, v)
                st.avg > 50 -> HealthFinding("stress.moderate", HealthSeverity.NOTICE, v)
                else -> HealthFinding("stress.normal", HealthSeverity.OK, v)
            }
        }

        // Bài tập
        val minutes = s.workouts.sumOf { it.minutes }.toDouble()
        if (week) {
            out += HealthFinding(
                if (minutes >= 150) "workout.who_met" else "workout.who_below", if (minutes >= 150) HealthSeverity.OK else HealthSeverity.NOTICE,
                mapOf("minutes" to minutes, "count" to s.workouts.size.toDouble(), "target" to 150.0),
            )
        } else if (s.workouts.isNotEmpty()) {
            out += HealthFinding("workout.done", HealthSeverity.OK, mapOf("minutes" to minutes, "count" to s.workouts.size.toDouble()))
        }

        // Cơ thể
        s.profile.bmi?.let { bmi ->
            val v = mapOf("bmi" to round1(bmi))
            out += when {
                bmi < 18.5 -> HealthFinding("bmi.under", HealthSeverity.NOTICE, v)
                bmi >= 28 -> HealthFinding("bmi.obese", HealthSeverity.NOTICE, v)
                bmi >= 24 -> HealthFinding("bmi.over", HealthSeverity.NOTICE, v)
                else -> HealthFinding("bmi.normal", HealthSeverity.OK, v)
            }
        }
        return out
    }

    /** Phân loại huyết áp AHA/ACC 2017 (+ huyết áp thấp ≤90/≤60). Mức WARN thì báo cáo khuyên gặp bác sĩ. */
    fun bloodPressureCategory(systolic: Double, diastolic: Double): Pair<String, HealthSeverity> = when {
        systolic > 180 || diastolic > 120 -> "bp.crisis" to HealthSeverity.WARN
        systolic >= 140 || diastolic >= 90 -> "bp.stage2" to HealthSeverity.WARN
        systolic >= 130 || diastolic >= 80 -> "bp.stage1" to HealthSeverity.WARN
        systolic >= 120 -> "bp.elevated" to HealthSeverity.NOTICE
        systolic <= 90 || diastolic <= 60 -> "bp.low" to HealthSeverity.NOTICE
        else -> "bp.normal" to HealthSeverity.OK
    }

    /** Mã luật của một đêm (Mi Fitness §2.3), không gồm `sleep.normal`. */
    fun nightCodes(n: HealthNight): List<String> {
        val c = mutableListOf<String>()
        if (n.asleepMinutes <= 420) c += "sleep.short"
        if (n.asleepMinutes > 540) c += "sleep.long"
        if (n.deepPct < 20) c += "sleep.deep_low"
        if (n.deepPct > 60) c += "sleep.deep_high"
        val hasRem = n.remMinutes > 0
        if (if (hasRem) n.lightPct < 20 || n.lightPct > 60 else n.lightPct < 60 || n.lightPct > 80) c += "sleep.light_abnormal"
        if (hasRem && n.remPct < 10) c += "sleep.rem_low"
        if (hasRem && n.remPct > 30) c += "sleep.rem_high"
        if (lateMinutes(n) > 0) c += "sleep.late"
        if (n.wakeUps >= 3) c += "sleep.wake_many"
        return c
    }

    /** Số phút lên giường sau 23:00 (Mi Fitness: giờ ngủ trong [23:00, 09:00] là muộn); 0 nếu không muộn. */
    fun lateMinutes(n: HealthNight): Int = if (n.bedtimeFromNoon in 661..1260) n.bedtimeFromNoon - 660 else 0

    /**
     * Điểm ngủ 0–100, công thức của SmartWear (không phải của Xiaomi): 100 trừ dần
     * - thời lượng ngoài 7–9 giờ: ngắn trừ (420 − phút) / 8, dài trừ (phút − 540) / 6, tối đa 30;
     * - % sâu ngoài 20–60: trừ số điểm % lệch, tối đa 15;
     * - % REM ngoài 10–30 (chỉ khi thiết bị có REM): như trên, tối đa 15;
     * - thức ≥3 lần: trừ 5 cho mỗi lần từ lần thứ 3, tối đa 15;
     * - ngủ sau 23:00: trừ 1 cho mỗi 15 phút muộn, tối đa 10;
     * - lệch giờ ngủ so với TB 7 ngày >30 phút: trừ (lệch − 30) / 4, tối đa 15.
     */
    fun sleepScore(n: HealthNight): Int {
        if (n.asleepMinutes <= 0) return 0
        val d = n.asleepMinutes.toDouble()
        var p = 0.0
        if (d < 420) p += minOf(30.0, (420 - d) / 8)
        if (d > 540) p += minOf(30.0, (d - 540) / 6)
        p += minOf(15.0, outside(n.deepPct, 20.0, 60.0))
        if (n.remMinutes > 0) p += minOf(15.0, outside(n.remPct, 10.0, 30.0))
        if (n.wakeUps >= 3) p += minOf(15.0, (n.wakeUps - 2) * 5.0)
        p += minOf(10.0, lateMinutes(n) / 15.0)
        n.bedtimeDeviation?.let { if (it > 30) p += minOf(15.0, (it - 30) / 4.0) }
        return Math.round(100 - p).toInt().coerceIn(0, 100)
    }

    /** Nhãn điểm như Mi Fitness: <60 kém, 60–79 trung bình, 80–89 tốt, ≥90 rất tốt. */
    fun scoreLabel(score: Int): String = when {
        score < 60 -> "Kém"
        score < 80 -> "Trung bình"
        score < 90 -> "Tốt"
        else -> "Rất tốt"
    }

    private val allNightCodes = listOf(
        "sleep.short", "sleep.long", "sleep.deep_low", "sleep.deep_high", "sleep.light_abnormal", "sleep.rem_low",
        "sleep.rem_high", "sleep.late", "sleep.wake_many",
    )

    private fun sleepFindings(s: HealthSummary): List<HealthFinding> {
        val nights = s.nights
        if (nights.isEmpty()) return listOf(HealthFinding("sleep.no_data", HealthSeverity.NOTICE))
        val out = mutableListOf<HealthFinding>()
        if (s.period == HealthPeriod.DAY) {
            val n = nights.last()
            val v = mapOf(
                "asleepMin" to n.asleepMinutes.toDouble(), "deepPct" to round1(n.deepPct), "lightPct" to round1(n.lightPct),
                "remPct" to round1(n.remPct), "wakeUps" to n.wakeUps.toDouble(), "lateMin" to lateMinutes(n).toDouble(),
            )
            nightCodes(n).forEach { out += HealthFinding(it, HealthSeverity.NOTICE, v) }
            if (out.isEmpty()) out += HealthFinding("sleep.normal", HealthSeverity.OK, v)
            val score = n.score
            out += HealthFinding("sleep.score", if (score >= 80) HealthSeverity.OK else HealthSeverity.NOTICE, mapOf("score" to score.toDouble()))
        } else {
            // Tuần: luật nào trúng ≥2 đêm (hoặc ≥1 nếu chỉ có 1–2 đêm) thì báo, kèm số đêm.
            val need = if (nights.size < 3) 1 else 2
            val counts = nights.flatMap { nightCodes(it) }.groupingBy { it }.eachCount()
            for (code in allNightCodes) {
                val c = counts[code] ?: 0
                if (c >= need) out += HealthFinding(code, HealthSeverity.NOTICE, mapOf("nights" to c.toDouble(), "of" to nights.size.toDouble()))
            }
            val devs = nights.mapNotNull { it.bedtimeDeviation }
            if (devs.size >= 3 && devs.sum().toDouble() / devs.size > 30) {
                out += HealthFinding("sleep.irregular", HealthSeverity.NOTICE, mapOf("avgDeviationMin" to round1(devs.sum().toDouble() / devs.size)))
            }
            if (out.isEmpty()) out += HealthFinding("sleep.normal", HealthSeverity.OK, mapOf("nights" to nights.size.toDouble()))
            val score = s.averageSleepScore ?: 0
            out += HealthFinding(
                "sleep.score", if (score >= 80) HealthSeverity.OK else HealthSeverity.NOTICE,
                mapOf("score" to score.toDouble(), "nights" to nights.size.toDouble()),
            )
        }
        return out
    }

    private fun outside(v: Double, lo: Double, hi: Double) = if (v < lo) lo - v else if (v > hi) v - hi else 0.0

    /** Làm tròn 1 chữ số thập phân (nửa ra xa 0), giống bản Swift để JSON hai nền tảng trùng nhau. */
    fun round1(v: Double): Double = sign(v) * Math.round(abs(v) * 10) / 10.0
}
