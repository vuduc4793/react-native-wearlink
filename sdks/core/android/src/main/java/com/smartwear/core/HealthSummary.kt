package com.smartwear.core

import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import kotlin.math.abs
import kotlin.math.roundToInt

// Báo cáo sức khoẻ AI, bước 1 (docs/research/mi-fitness-features.md §2.9): điện thoại tự tổng hợp số liệu từ
// [DeviceHistory], tất định, không cần mạng. Bước 2 là [HealthFindings] (luật), bước 3 là [HealthReportPrompt] (LLM
// chỉ viết chữ). Bản Swift: `HealthSummary.swift`, cùng tên trường và cùng cách tính.

/** Hồ sơ người dùng do app truyền vào (lấy từ cài đặt thiết bị `profile.*`, `goal.steps`). Trường nào chưa biết thì null. */
data class HealthProfile(
    val age: Int? = null,
    /** true = nam, false = nữ. */
    val male: Boolean? = null,
    val heightCm: Int? = null,
    val weightKg: Double? = null,
    /** Mục tiêu bước mỗi ngày (mặc định 6000 như Mi Fitness). */
    val stepGoal: Int = 6000,
    /** Loại thiết bị để lời nhắc đúng ("nhẫn", "đồng hồ", "vòng tay"). */
    val device: String? = null,
) {
    /** Nhịp tim tối đa = 220 − tuổi, chưa biết tuổi thì coi là 25 (như Mi Fitness `getMaxHrOrDefault`). */
    val maxHeartRate: Int get() = 220 - (age ?: 25)

    /** BMI = cân nặng / chiều cao² (m). null nếu thiếu số. */
    val bmi: Double?
        get() {
            val h = heightCm ?: return null
            val w = weightKg ?: return null
            if (h <= 0 || w <= 0) return null
            val m = h / 100.0
            return w / (m * m)
        }
}

/** Kỳ báo cáo: hôm nay, hoặc 7 ngày gần nhất (tính cả hôm nay). */
enum class HealthPeriod(val key: String, val days: Int, val title: String) {
    DAY("day", 1, "Hôm nay"),
    WEEK("week", 7, "7 ngày"),
}

/** Trung bình / thấp nhất / cao nhất của một chuỗi. */
data class HealthStat(val avg: Double, val min: Double, val max: Double, val count: Int) {
    companion object {
        /** [values] rỗng thì null; [lows] (vd SpO2 thấp nhất trong giờ) nếu có thì dùng để tính `min`. */
        fun of(values: List<Double>, lows: List<Double>? = null): HealthStat? {
            if (values.isEmpty()) return null
            val low = (if (lows.isNullOrEmpty()) values else lows).min()
            return HealthStat(values.sum() / values.size, minOf(low, values.min()), values.max(), values.size)
        }
    }
}

/** Huyết áp trong kỳ (mmHg): trung bình, lần đo mới nhất, cao nhất. */
data class BloodPressureStat(
    val avgSystolic: Double,
    val avgDiastolic: Double,
    val latestSystolic: Int,
    val latestDiastolic: Int,
    val maxSystolic: Int,
    val maxDiastolic: Int,
    val count: Int,
) {
    companion object {
        /** Điểm `BLOOD_PRESSURE`: value = tâm thu, extra "diastolic" = tâm trương. Bỏ điểm 0. */
        fun of(points: List<HistoryPoint>): BloodPressureStat? {
            val p = points.filter { it.value > 0 && (it.extra["diastolic"] ?: 0.0) > 0 }.sortedBy { it.timestamp }
            val last = p.lastOrNull() ?: return null
            val sys = p.map { it.value }
            val dia = p.map { it.extra["diastolic"] ?: 0.0 }
            return BloodPressureStat(
                sys.sum() / p.size, dia.sum() / p.size, last.value.roundToInt(), (last.extra["diastolic"] ?: 0.0).roundToInt(),
                sys.max().roundToInt(), dia.max().roundToInt(), p.size,
            )
        }
    }
}

/** Một đêm ngủ đã tổng hợp. Tỉ lệ sâu/nông/REM tính trên thời gian ngủ (không gồm lúc thức), như Mi Fitness. */
data class HealthNight(
    /** Lúc bắt đầu ngủ (đầu đoạn ngủ đầu tiên) và lúc dậy (cuối đoạn ngủ cuối), epoch ms. */
    val bedtime: Long,
    val wakeTime: Long,
    val asleepMinutes: Int,
    val deepMinutes: Int,
    val lightMinutes: Int,
    val remMinutes: Int,
    val awakeMinutes: Int,
    /** Số lần thức giữa giấc (không tính đoạn thức ở đầu / cuối phiên). */
    val wakeUps: Int,
    /** Phút trong ngày của giờ ngủ, tính từ 12:00 trưa (23:00 = 660) để không bị gãy qua nửa đêm. */
    val bedtimeFromNoon: Int,
    /** Lệch giờ ngủ (phút) so với trung bình các đêm trước trong 7 ngày; null nếu chưa đủ 2 đêm để so. */
    val bedtimeDeviation: Int? = null,
) {
    val deepPct: Double get() = pct(deepMinutes)
    val lightPct: Double get() = pct(lightMinutes)
    val remPct: Double get() = pct(remMinutes)

    /** Thức trên tổng thời gian nằm (ngủ + thức). */
    val awakePct: Double
        get() = if (asleepMinutes + awakeMinutes > 0) awakeMinutes * 100.0 / (asleepMinutes + awakeMinutes) else 0.0

    /** Điểm ngủ tự tính (xem [HealthFindings.sleepScore]). */
    val score: Int get() = HealthFindings.sleepScore(this)

    private fun pct(m: Int) = if (asleepMinutes > 0) m * 100.0 / asleepMinutes else 0.0

    companion object {
        private fun sleeping(s: SleepStage) = s != SleepStage.AWAKE && s != SleepStage.UNKNOWN

        fun of(s: SleepSession, zone: ZoneId, priorBedtimes: List<Int> = emptyList()): HealthNight {
            val segs = s.segments.sortedBy { it.start }
            val asleep = segs.filter { sleeping(it.stage) }
            val bed = asleep.firstOrNull()?.start ?: s.start
            val wake = asleep.lastOrNull()?.let { it.start + it.minutes * 60_000L } ?: s.end
            // Số lần thức: số cụm đoạn AWAKE liền nhau nằm giữa hai đoạn ngủ.
            var wakeUps = 0
            val first = segs.indexOfFirst { sleeping(it.stage) }
            val last = segs.indexOfLast { sleeping(it.stage) }
            if (first in 0 until last) {
                var inAwake = false
                for (seg in segs.subList(first, last + 1)) {
                    if (seg.stage == SleepStage.AWAKE) {
                        if (!inAwake) wakeUps++
                        inAwake = true
                    } else if (seg.stage != SleepStage.UNKNOWN) {
                        inAwake = false
                    }
                }
            }
            val fromNoon = minutesFromNoon(bed, zone)
            val deviation = if (priorBedtimes.size >= 2) {
                Math.round(abs(fromNoon - priorBedtimes.sum().toDouble() / priorBedtimes.size)).toInt()
            } else null
            return HealthNight(
                bed, wake, s.asleepMinutes, s.minutes(SleepStage.DEEP), s.minutes(SleepStage.LIGHT), s.minutes(SleepStage.REM),
                s.minutes(SleepStage.AWAKE), wakeUps, fromNoon, deviation,
            )
        }

        fun minutesFromNoon(ms: Long, zone: ZoneId): Int {
            val t = Instant.ofEpochMilli(ms).atZone(zone)
            return (t.hour * 60 + t.minute + 720) % 1440
        }
    }
}

/**
 * Vùng nhịp tim theo % nhịp tối đa (Mi Fitness `HrZone`): ≥50 khởi động, >60 đốt mỡ, >70 hiếu khí, >80 kỵ khí,
 * >90 cực hạn, dưới 50 là nhẹ nhàng.
 */
enum class HeartRateZone(val key: String) {
    SMOOTH("smooth"), WARM_UP("warm_up"), FAT_BURN("fat_burn"), AEROBIC("aerobic"), ANAEROBIC("anaerobic"), EXTREME("extreme");

    companion object {
        fun of(bpm: Int, maxHeartRate: Int): HeartRateZone {
            val pct = bpm * 100.0 / maxOf(maxHeartRate, 1)
            return when {
                pct > 90 -> EXTREME
                pct > 80 -> ANAEROBIC
                pct > 70 -> AEROBIC
                pct > 60 -> FAT_BURN
                pct >= 50 -> WARM_UP
                else -> SMOOTH
            }
        }
    }
}

/** Một bài tập trong kỳ (rút gọn từ [Workout]). */
data class HealthWorkout(
    val name: String,
    val start: Long,
    val minutes: Int,
    val calories: Int? = null,
    val distanceMeters: Int? = null,
    val avgHeartRate: Int? = null,
    val maxHeartRate: Int? = null,
    /** Vùng của nhịp tim trung bình. */
    val zone: HeartRateZone? = null,
)

/** Số liệu một ngày (0:00–24:00 giờ địa phương). [date] là epoch ms đầu ngày. */
data class HealthDay(
    val date: Long,
    val steps: Int,
    /** kcal (lịch sử lưu cal, đã chia 1000). */
    val calories: Int,
    val distanceMeters: Int,
    val activeMinutes: Int? = null,
    val heartRate: HealthStat? = null,
    /** Nhịp tim nghỉ ước lượng: TB 10% số đo thấp nhất trong lúc ngủ đêm kết thúc hôm nay; null nếu không có. */
    val restingHeartRate: Int? = null,
    val spo2: HealthStat? = null,
    val bloodPressure: BloodPressureStat? = null,
    /** Giấc ngủ đêm kết thúc trong ngày (giấc dài nhất không phải ngủ trưa). */
    val sleep: HealthNight? = null,
    val napMinutes: Int = 0,
    val workouts: Int = 0,
) {
    val hasData: Boolean
        get() = steps > 0 || heartRate != null || spo2 != null || bloodPressure != null || sleep != null || napMinutes > 0 || workouts > 0
}

/** Số liệu của cả kỳ, đầu vào của [HealthFindings] và [HealthReportPrompt]. */
data class HealthSummary(
    val period: HealthPeriod,
    val profile: HealthProfile,
    /** Mốc tạo báo cáo (epoch ms); ngày cuối của kỳ là hôm nay và đang diễn ra tới mốc này. */
    val generatedAt: Long,
    val zone: ZoneId,
    /** Cũ → mới; ngày cuối là hôm nay. */
    val days: List<HealthDay>,
    // Gộp mọi điểm trong kỳ:
    val heartRate: HealthStat? = null,
    val restingHeartRate: Int? = null,
    val spo2: HealthStat? = null,
    /** Số lần SpO2 (thấp nhất trong giờ) dưới 90%. */
    val spo2Below90: Int = 0,
    val bloodPressure: BloodPressureStat? = null,
    val stress: HealthStat? = null,
    val hrv: HealthStat? = null,
    val temperature: HealthStat? = null,
    val workouts: List<HealthWorkout> = emptyList(),
) {
    val today: HealthDay? get() = days.lastOrNull()
    val nights: List<HealthNight> get() = days.mapNotNull { it.sleep }
    val totalSteps: Int get() = days.sumOf { it.steps }

    /** Ngày dùng để tính TB bước: bỏ hôm nay (chưa hết ngày) và ngày 0 bước. Kỳ "hôm nay" thì chỉ có hôm nay. */
    val stepDays: List<HealthDay>
        get() {
            val full = days.dropLast(1).filter { it.steps > 0 }
            return full.ifEmpty { days.takeLast(1) }
        }
    val averageSteps: Int get() = stepDays.let { d -> if (d.isEmpty()) 0 else Math.round(d.sumOf { it.steps }.toDouble() / d.size).toInt() }
    val daysGoalMet: Int get() = stepDays.count { it.steps >= profile.stepGoal }
    val averageSleepMinutes: Int?
        get() = nights.takeIf { it.isNotEmpty() }?.let { n -> Math.round(n.sumOf { it.asleepMinutes }.toDouble() / n.size).toInt() }
    val averageSleepScore: Int?
        get() = nights.takeIf { it.isNotEmpty() }?.let { n -> Math.round(n.sumOf { it.score }.toDouble() / n.size).toInt() }

    companion object {
        private const val DAY_MS = 86_400_000L

        /** Tổng hợp [period] từ lịch sử. [now] và [zone] tiêm được để kiểm thử. */
        fun make(
            history: DeviceHistory,
            period: HealthPeriod,
            profile: HealthProfile = HealthProfile(),
            now: Long = System.currentTimeMillis(),
            zone: ZoneId = ZoneId.systemDefault(),
        ): HealthSummary {
            val today = Instant.ofEpochMilli(now).atZone(zone).toLocalDate()
            val firstDate = today.minusDays((period.days - 1).toLong())
            fun startOf(d: LocalDate) = d.atStartOfDay(zone).toInstant().toEpochMilli()
            val first = startOf(firstDate)
            val end = startOf(today.plusDays(1))
            val mains = history.sleep.filter { !it.nap }
            fun points(c: Capability, from: Long, to: Long) = history.series[c].orEmpty().filter { it.timestamp in from until to }

            fun night(s: SleepSession): HealthNight {
                val weekAgo = s.end - 7 * DAY_MS
                val prior = mains.filter { it != s && it.end >= weekAgo && it.end < s.end && it.asleepMinutes > 0 }
                    .map { HealthNight.of(it, zone).bedtimeFromNoon }
                return HealthNight.of(s, zone, prior)
            }

            val syncedDay = Instant.ofEpochMilli(history.syncedAt).atZone(zone).toLocalDate()
            val resting = mutableListOf<Int>()
            val days = (0 until period.days).map { i ->
                val date = firstDate.plusDays(i.toLong())
                val s = startOf(date)
                val e = startOf(date.plusDays(1))
                val slots = points(Capability.STEPS, s, e)
                var steps = slots.sumOf { it.value }.toInt()
                var cal = slots.sumOf { it.extra["calories"] ?: 0.0 }.toInt()
                var dist = slots.sumOf { it.extra["distance"] ?: 0.0 }.toInt()
                var active: Int? = null
                // Tổng thiết bị báo chỉ đúng cho ngày đồng bộ.
                val t = history.today
                if (t != null && syncedDay == date) {
                    steps = t.steps; cal = t.calories; dist = t.distanceMeters; active = t.activeMinutes
                }
                val main = mains.filter { it.end in s until e && it.asleepMinutes > 0 }.maxByOrNull { it.asleepMinutes }
                val naps = history.sleep.filter { it.nap && it.end in s until e }
                    .sumOf { if (it.asleepMinutes > 0) it.asleepMinutes else ((it.end - it.start) / 60_000).toInt() }
                val hr = points(Capability.HEART_RATE, s, e).filter { it.value > 0 }
                var rest: Int? = null
                if (main != null) {
                    val during = hr.filter { it.timestamp in main.start..main.end }.map { it.value }.sorted()
                    if (during.isNotEmpty()) {
                        val low = during.take(maxOf(1, during.size / 10))
                        rest = Math.round(low.sum() / low.size).toInt()
                    }
                }
                rest?.let { resting += it }
                val spo = points(Capability.SPO2, s, e).filter { it.value > 0 }
                HealthDay(
                    date = s, steps = steps, calories = Math.round(cal / 1000.0).toInt(), distanceMeters = dist,
                    activeMinutes = active, heartRate = HealthStat.of(hr.map { it.value }), restingHeartRate = rest,
                    spo2 = HealthStat.of(spo.map { it.value }, spo.map { it.extra["min"] ?: it.value }),
                    bloodPressure = BloodPressureStat.of(points(Capability.BLOOD_PRESSURE, s, e)),
                    sleep = main?.let(::night), napMinutes = naps,
                    workouts = history.workouts.count { it.start in s until e },
                )
            }

            val hr = points(Capability.HEART_RATE, first, end).filter { it.value > 0 }
            val spo = points(Capability.SPO2, first, end).filter { it.value > 0 }
            val spoLows = spo.map { it.extra["min"] ?: it.value }
            fun stat(c: Capability) = HealthStat.of(points(c, first, end).map { it.value }.filter { it > 0 })
            val maxHr = profile.maxHeartRate
            val workouts = history.workouts.filter { it.start in first until end }.sortedBy { it.start }.map { w ->
                HealthWorkout(
                    w.name, w.start, Math.round(w.activeSeconds / 60.0).toInt(), w.calories, w.distanceMeters, w.avgHeartRate,
                    w.maxHeartRate, w.avgHeartRate?.let { HeartRateZone.of(it, maxHr) },
                )
            }
            return HealthSummary(
                period = period, profile = profile, generatedAt = now, zone = zone, days = days,
                heartRate = HealthStat.of(hr.map { it.value }),
                restingHeartRate = if (resting.isEmpty()) null else Math.round(resting.sum().toDouble() / resting.size).toInt(),
                spo2 = HealthStat.of(spo.map { it.value }, spoLows), spo2Below90 = spoLows.count { it < 90 },
                bloodPressure = BloodPressureStat.of(points(Capability.BLOOD_PRESSURE, first, end)),
                stress = stat(Capability.STRESS), hrv = stat(Capability.HRV), temperature = stat(Capability.TEMPERATURE),
                workouts = workouts,
            )
        }
    }
}
