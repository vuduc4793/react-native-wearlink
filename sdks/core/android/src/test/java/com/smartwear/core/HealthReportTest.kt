package com.smartwear.core

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDateTime
import java.time.ZoneId

/**
 * Báo cáo sức khoẻ AI: tổng hợp, luật, prompt, đọc kết quả. Cùng dữ liệu mẫu với `HealthReportTests` iOS
 * (Y25 sáng 16/10/2026: 28 bước, HR 79–88, SpO2 98, HA 122/72 và 121/73, chưa có giấc ngủ).
 */
class HealthReportTest {
    private val zone = ZoneId.of("Asia/Ho_Chi_Minh")
    private fun at(day: Int, h: Int, m: Int = 0) = LocalDateTime.of(2026, 10, day, h, m).atZone(zone).toInstant().toEpochMilli()

    private fun night(day: Int, h: Int, m: Int, segs: List<Pair<SleepStage, Int>>): SleepSession {
        var t = at(day, h, m)
        val out = segs.map { (stage, minutes) -> SleepSegment(t, minutes, stage).also { t += minutes * 60_000L } }
        return SleepSession(at(day, h, m), t, out)
    }

    private val profile = HealthProfile(age = 30, male = true, heightCm = 170, weightKg = 65.0, stepGoal = 8000)
    private val now get() = at(16, 10, 30)

    /** Y25 đo thật sáng 16/10: một khung bước theo giờ 28 bước, nhịp tim 79–88, SpO2 98, huyết áp 2 lần. */
    private fun y25Day() = DeviceHistory(
        series = mapOf(
            Capability.STEPS to listOf(HistoryPoint(at(16, 9), 28.0, mapOf("calories" to 1100.0, "distance" to 19.0))),
            Capability.HEART_RATE to listOf(79.0, 83.0, 88.0, 81.0, 84.0).mapIndexed { i, v -> HistoryPoint(at(16, 8, 0) + i * 30 * 60_000L, v) },
            Capability.SPO2 to listOf(HistoryPoint(at(16, 9), 98.0, mapOf("min" to 98.0))),
            Capability.BLOOD_PRESSURE to listOf(
                HistoryPoint(at(16, 8, 30), 122.0, mapOf("diastolic" to 72.0)),
                HistoryPoint(at(16, 9, 45), 121.0, mapOf("diastolic" to 73.0)),
            ),
        ),
        today = ActivityTotals(28, 1100, 19), days = 1, syncedAt = at(16, 10, 25),
    )

    private val y25Json =
        """{"activity":{"distanceM":19,"kcal":1,"steps":28},"asOf":"10:30","bp":{"avgDia":72.5,"avgSys":121.5,"latest":"121/73","n":2},"date":"2026-10-16","findings":[{"code":"steps.below_goal","sev":"notice","v":{"goal":8000,"pct":0.4,"steps":28}},{"code":"hr.normal","sev":"ok","v":{"avg":83,"max":88,"min":79}},{"code":"spo2.normal","sev":"ok","v":{"avg":98,"below90":0,"min":98}},{"code":"bp.elevated","sev":"notice","v":{"avgDia":72.5,"avgSys":121.5,"maxDia":73,"maxSys":122,"n":2}},{"code":"sleep.no_data","sev":"notice"},{"code":"bmi.normal","sev":"ok","v":{"bmi":22.5}}],"heart":{"avg":83,"max":88,"min":79,"n":5},"period":"day","profile":{"age":30,"bmi":22.5,"heightCm":170,"hrMax":190,"sex":"nam","stepGoal":8000,"weightKg":65},"spo2":{"avg":98,"below90":0,"max":98,"min":98,"n":1}}"""

    @Test fun y25DaySummary() {
        val s = HealthSummary.make(y25Day(), HealthPeriod.DAY, profile, now, zone)
        assertEquals(1, s.days.size)
        val d = s.today!!
        assertEquals(28, d.steps)
        assertEquals(1, d.calories)
        assertEquals(19, d.distanceMeters)
        assertEquals(HealthStat(83.0, 79.0, 88.0, 5), s.heartRate)
        assertNull(s.restingHeartRate)
        assertEquals(98.0, s.spo2!!.avg, 0.0)
        val bp = s.bloodPressure!!
        assertEquals(121.5, bp.avgSystolic, 0.0)
        assertEquals(72.5, bp.avgDiastolic, 0.0)
        assertEquals("121/73", "${bp.latestSystolic}/${bp.latestDiastolic}")
        assertNull(d.sleep)
        assertEquals(190, profile.maxHeartRate)
        assertEquals(22.49, profile.bmi!!, 0.01)
    }

    @Test fun y25DayFindingsAndPrompt() {
        val s = HealthSummary.make(y25Day(), HealthPeriod.DAY, profile, now, zone)
        val f = HealthFindings.evaluate(s)
        assertEquals(listOf("steps.below_goal", "hr.normal", "spo2.normal", "bp.elevated", "sleep.no_data", "bmi.normal"), f.map { it.code })
        assertEquals(
            listOf(HealthSeverity.NOTICE, HealthSeverity.OK, HealthSeverity.OK, HealthSeverity.NOTICE, HealthSeverity.NOTICE, HealthSeverity.OK),
            f.map { it.severity },
        )
        assertEquals(HealthSeverity.NOTICE, HealthFindings.worst(f, "bp"))
        assertNull(HealthFindings.worst(f, "stress"))
        // Chuỗi JSON gửi LLM trùng từng ký tự với bản Swift.
        assertEquals(y25Json, HealthReportPrompt.userJson(s, f))

        val body = JSONObject(HealthReportPrompt.requestBody("Qwen/Qwen3.6-35B-A3B-FP8", s, f))
        assertEquals("Qwen/Qwen3.6-35B-A3B-FP8", body.getString("model"))
        assertFalse(body.getJSONObject("chat_template_kwargs").getBoolean("enable_thinking"))
        val msgs = body.getJSONArray("messages")
        assertEquals("system", msgs.getJSONObject(0).getString("role"))
        assertEquals(HealthReportPrompt.SYSTEM, msgs.getJSONObject(0).getString("content"))
        assertEquals(y25Json, msgs.getJSONObject(1).getString("content"))
        assertTrue(HealthReportPrompt.SYSTEM.contains("bác sĩ"))
    }

    @Test fun staleDeviceTotalsIgnored() {
        val base = y25Day()
        val h = base.copy(
            today = ActivityTotals(9999, 400_000, 7000), syncedAt = at(15, 21),
            series = base.series + (Capability.STEPS to base.series[Capability.STEPS]!! +
                HistoryPoint(at(16, 10), 100.0, mapOf("calories" to 3000.0, "distance" to 70.0))),
        )
        val d = HealthSummary.make(h, HealthPeriod.DAY, profile, now, zone).today!!
        assertEquals(128, d.steps)
        assertEquals(4, d.calories)
        assertEquals(89, d.distanceMeters)
    }

    // Tuần có giấc ngủ

    private fun week(): DeviceHistory {
        val normal = listOf(SleepStage.LIGHT to 120, SleepStage.DEEP to 100, SleepStage.REM to 90, SleepStage.LIGHT to 140)
        val sleeps = listOf(
            night(9, 22, 30, normal),
            night(10, 22, 45, normal),
            night(11, 22, 40, normal),
            // Ngủ 00:30: ngắn, ít ngủ sâu, ít REM, nhiều nông, thức 3 lần.
            night(
                13, 0, 30,
                listOf(
                    SleepStage.LIGHT to 60, SleepStage.DEEP to 50, SleepStage.AWAKE to 10, SleepStage.LIGHT to 100, SleepStage.AWAKE to 5,
                    SleepStage.REM to 30, SleepStage.AWAKE to 10, SleepStage.LIGHT to 125,
                ),
            ),
            night(13, 23, 50, listOf(SleepStage.LIGHT to 150, SleepStage.DEEP to 90, SleepStage.REM to 80, SleepStage.LIGHT to 80)),
            night(14, 22, 30, normal),
            night(15, 23, 30, listOf(SleepStage.LIGHT to 120, SleepStage.DEEP to 60, SleepStage.AWAKE to 5, SleepStage.REM to 70, SleepStage.LIGHT to 160)),
        )
        val steps = listOf(10 to 9000, 11 to 7000, 13 to 8500, 14 to 12000, 15 to 5000).map { (day, n) ->
            HistoryPoint(at(day, 12), n.toDouble(), mapOf("calories" to n * 40.0, "distance" to n * 0.7))
        } + HistoryPoint(at(16, 9), 1200.0)
        val hr = listOf(Triple(16, 1, 58.0), Triple(16, 3, 55.0), Triple(16, 5, 60.0), Triple(16, 9, 80.0), Triple(14, 18, 150.0))
            .map { HistoryPoint(at(it.first, it.second), it.third) }
        return DeviceHistory(
            series = mapOf(Capability.STEPS to steps, Capability.HEART_RATE to hr, Capability.STRESS to listOf(HistoryPoint(at(15, 10), 35.0))),
            sleep = sleeps,
            workouts = listOf(
                Workout(1, "Chạy bộ", at(14, 18), at(14, 18, 32), 1800, calories = 250, distanceMeters = 4000, avgHeartRate = 150, maxHeartRate = 172),
            ),
            today = ActivityTotals(1200, 50_000, 800), days = 7, syncedAt = at(16, 10),
        )
    }

    @Test fun weekSleepAndSteps() {
        val s = HealthSummary.make(week(), HealthPeriod.WEEK, profile, now, zone)
        assertEquals(7, s.days.size)
        assertEquals(listOf(9000, 7000, 0, 8500, 12000, 5000, 1200), s.days.map { it.steps })
        assertEquals(8300, s.averageSteps) // bỏ hôm nay và ngày 0 bước
        assertEquals(3, s.daysGoalMet)
        assertEquals(7, s.nights.size)

        val bad = s.days[3].sleep!! // đêm 13/10
        assertEquals(365, bad.asleepMinutes)
        assertEquals(3, bad.wakeUps)
        assertEquals(112, bad.bedtimeDeviation)
        assertEquals(90, HealthFindings.lateMinutes(bad))
        assertEquals(
            listOf("sleep.short", "sleep.deep_low", "sleep.light_abnormal", "sleep.rem_low", "sleep.late", "sleep.wake_many"),
            HealthFindings.nightCodes(bad),
        )
        assertEquals(59, bad.score)
        assertEquals("Kém", HealthFindings.scoreLabel(bad.score))
        assertEquals(100, s.days[0].sleep!!.score)
        assertEquals(listOf(3, 112, 44, 45, 23), s.days.mapNotNull { it.sleep?.bedtimeDeviation })

        val f = HealthFindings.evaluate(s)
        assertEquals(
            listOf(
                "steps.goal_met", "hr.normal", "sleep.short", "sleep.deep_low", "sleep.light_abnormal", "sleep.late",
                "sleep.irregular", "sleep.score", "stress.normal", "workout.who_below", "bmi.normal",
            ),
            f.map { it.code },
        )
        assertEquals(mapOf("nights" to 3.0, "of" to 7.0), f.first { it.code == "sleep.short" }.values)
        assertEquals(45.4, f.first { it.code == "sleep.irregular" }.values["avgDeviationMin"]!!, 0.0)
        assertEquals(HeartRateZone.AEROBIC, s.workouts.first().zone)
        assertEquals(55, s.restingHeartRate)

        val json = HealthReportPrompt.userJson(s, f)
        assertTrue(json.contains(""""from":"2026-10-10""""))
        assertTrue(
            json.contains(
                """{"bed":"00:30","date":"2026-10-13","deepPct":13.7,"remPct":8.2,"score":59,"sleepMin":365,"steps":8500,"wake":"07:00","wakeUps":3}""",
            ),
        )
        assertTrue(json.contains(""""zone":"aerobic""""))
        assertTrue(json.contains(""""avgSteps":8300"""))
    }

    @Test fun daySleepFindings() {
        val s = HealthSummary.make(week(), HealthPeriod.DAY, profile, now, zone)
        val n = s.today!!.sleep!!
        assertEquals(410, n.asleepMinutes)
        assertEquals(1, n.wakeUps)
        assertEquals(91, n.score)
        assertEquals(55, s.today!!.restingHeartRate)
        val f = HealthFindings.evaluate(s).filter { it.area == "sleep" }
        assertEquals(listOf("sleep.short", "sleep.deep_low", "sleep.light_abnormal", "sleep.late", "sleep.score"), f.map { it.code })
        assertEquals(HealthSeverity.OK, f.last().severity)
        assertTrue(HealthReportPrompt.userJson(s, f).contains(""""bed":"23:30""""))
    }

    @Test fun bloodPressureCategories() {
        fun code(s: Double, d: Double) = HealthFindings.bloodPressureCategory(s, d).first
        assertEquals("bp.normal", code(115.0, 75.0))
        assertEquals("bp.elevated", code(122.0, 72.0))
        assertEquals("bp.stage1", code(125.0, 82.0))
        assertEquals("bp.stage1", code(135.0, 70.0))
        assertEquals("bp.stage2", code(142.0, 85.0))
        assertEquals("bp.crisis", code(185.0, 100.0))
        assertEquals("bp.low", code(88.0, 58.0))
        assertEquals(HealthSeverity.WARN, HealthFindings.bloodPressureCategory(132.0, 70.0).second)
    }

    @Test fun spo2AndHeartRules() {
        val base = y25Day()
        val h = base.copy(
            series = base.series + mapOf(
                Capability.SPO2 to listOf(HistoryPoint(at(16, 2), 93.0, mapOf("min" to 88.0)), HistoryPoint(at(16, 3), 95.0)),
                Capability.HEART_RATE to listOf(HistoryPoint(at(16, 2), 38.0), HistoryPoint(at(16, 3), 70.0)),
            ),
        )
        val f = HealthFindings.evaluate(HealthSummary.make(h, HealthPeriod.DAY, profile, now, zone))
        assertEquals("spo2.low", f.first { it.area == "spo2" }.code)
        assertEquals(1.0, f.first { it.area == "spo2" }.values["below90"]!!, 0.0)
        assertEquals("hr.low", f.first { it.area == "heart" }.code)
        assertEquals(HealthSeverity.WARN, HealthFindings.worst(f, "spo2"))
        assertEquals(HeartRateZone.WARM_UP, HeartRateZone.of(95, 190))
        assertEquals(HeartRateZone.EXTREME, HeartRateZone.of(175, 190))
        assertEquals(HeartRateZone.SMOOTH, HeartRateZone.of(80, 190))
    }

    // Đọc câu trả lời LLM

    @Test fun parseFencedJsonAndOverrideStatus() {
        val f = listOf(HealthFinding("bp.stage1", HealthSeverity.WARN), HealthFinding("steps.goal_met", HealthSeverity.OK))
        val answer = """
            <think>nháp</think>
            ```json
            {"title":"Ngày ổn định","summary":"Bạn vận động tốt.","sections":[
              {"key":"bp","status":"ok","text":"Huyết áp hơi cao, nên đi khám."},
              {"key":"activity","status":"warn","text":"Đạt mục tiêu bước."},
              {"key":"sleep","status":"notice","text":""}],
             "tips":["Đi bộ 30 phút","Ngủ trước 23h"],"disclaimer":""}
            ```
        """.trimIndent()
        val r = HealthReportPrompt.parse(answer, f, HealthPeriod.DAY, now)
        assertFalse(r.plainText)
        assertEquals("Ngày ổn định", r.title)
        assertEquals(listOf("bp", "activity"), r.sections.map { it.key })
        assertEquals(listOf(HealthSeverity.WARN, HealthSeverity.OK), r.sections.map { it.status }) // theo findings, không theo LLM
        assertEquals(listOf("Đi bộ 30 phút", "Ngủ trước 23h"), r.tips)
        assertEquals(HealthReportPrompt.DEFAULT_DISCLAIMER, r.disclaimer)
        assertTrue(r.text.contains("[warn] Huyết áp: Huyết áp hơi cao"))
    }

    @Test fun parsePlainTextFallback() {
        val r = HealthReportPrompt.parse("Hôm nay bạn đi ít, hãy đi bộ thêm.", emptyList(), HealthPeriod.WEEK, now)
        assertTrue(r.plainText)
        assertEquals("Báo cáo sức khoẻ 7 ngày", r.title)
        assertEquals("Hôm nay bạn đi ít, hãy đi bộ thêm.", r.summary)
        assertTrue(r.sections.isEmpty())
    }

    @Test fun responseContent() {
        assertEquals(
            """{"title":"A"}""",
            HealthReportPrompt.contentFromResponse("""{"choices":[{"message":{"role":"assistant","content":" {\"title\":\"A\"} "}}]}"""),
        )
        assertEquals("x", HealthReportPrompt.contentFromResponse("""{"choices":[{"message":{"content":null,"reasoning_content":"x"}}]}"""))
        assertNull(HealthReportPrompt.contentFromResponse("error code: 1010"))
    }

    // Cấu hình và lỗi

    @Test fun configParseHidesKey() {
        val env = """
            # máy chủ AI
            LLM_API_BASE=https://llm.example.net/v1/
            export LLM_MODEL="Qwen/Qwen3.6-35B-A3B-FP8"
            LLM_API_KEY='mtt_secret'
        """.trimIndent()
        val c = HealthLLMConfig.parseEnv(env)!!
        assertEquals("https://llm.example.net/v1", c.baseUrl)
        assertEquals("Qwen/Qwen3.6-35B-A3B-FP8", c.model)
        assertEquals("mtt_secret", c.apiKey)
        assertFalse(c.toString().contains("mtt_secret"))
        assertNull(HealthLLMConfig.parseEnv("LLM_API_BASE=https://x/v1"))
        assertTrue(HealthReportClient.USER_AGENT.startsWith("Mozilla/5.0"))
    }

    @Test fun errorMapping() {
        assertEquals(HealthReportError.Restarting, HealthReportError.from(502, ""))
        assertEquals("Máy chủ AI đang khởi động lại, thử lại sau vài phút", HealthReportError.from(502, "").message)
        assertEquals(HealthReportError.Blocked, HealthReportError.from(403, "error code: 1010"))
        assertEquals(HealthReportError.Unauthorized, HealthReportError.from(401, ""))
        assertEquals(HealthReportError.Timeout, HealthReportError.from(524, ""))
        assertEquals(500, (HealthReportError.from(500, "") as HealthReportError.Http).code)
        assertEquals("Chưa cấu hình máy chủ AI", HealthReportError.NotConfigured.message)
    }

    @Test fun jsonWriter() {
        assertEquals(
            """{"a":[true,"x\"y\n"],"b":1.3,"c":3,"d":"Nữ"}""",
            HealthJson.encode(mapOf("b" to 1.25, "a" to listOf(true, "x\"y\n"), "c" to 3.0, "d" to "Nữ", "e" to null)),
        )
    }
}
