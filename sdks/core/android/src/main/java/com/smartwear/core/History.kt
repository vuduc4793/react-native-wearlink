package com.smartwear.core

/** Một điểm dữ liệu lịch sử. [timestamp] là epoch ms (UTC). */
data class HistoryPoint(
    val timestamp: Long,
    val value: Double,
    /** Giá trị phụ, ví dụ SpO2 thấp nhất trong giờ, calo/quãng đường của một khung bước chân. */
    val extra: Map<String, Double> = emptyMap(),
)

enum class SleepStage { LIGHT, DEEP, REM, AWAKE, UNKNOWN }

data class SleepSegment(val start: Long, val minutes: Int, val stage: SleepStage)

/** Một phiên ngủ. [start]/[end] là epoch ms. */
data class SleepSession(
    val start: Long,
    val end: Long,
    val segments: List<SleepSegment>,
    /** Ngủ trưa / giấc ngắn ban ngày (QRing: khung big-data 0x3E). */
    val nap: Boolean = false,
) {
    fun minutes(stage: SleepStage): Int = segments.filter { it.stage == stage }.sumOf { it.minutes }

    /** Tổng thời gian ngủ, không tính lúc thức. */
    val asleepMinutes: Int get() = segments.filter { it.stage != SleepStage.AWAKE && it.stage != SleepStage.UNKNOWN }.sumOf { it.minutes }
}

/** Tổng hoạt động trong ngày theo thiết bị báo. */
/**
 * Một bài tập ghi trên thiết bị (chạy, đạp xe, yoga…). [start]/[end] là epoch ms; [activeSeconds] là thời gian tập
 * hiệu quả (trừ lúc tạm dừng). Trường nào thiết bị không đo thì null.
 */
data class Workout(
    val type: Int,
    val name: String,
    val start: Long,
    val end: Long,
    val activeSeconds: Int,
    val steps: Int? = null,
    val calories: Int? = null,
    val distanceMeters: Int? = null,
    val avgHeartRate: Int? = null,
    val maxHeartRate: Int? = null,
    val minHeartRate: Int? = null,
    /** Pace trung bình, giây cho mỗi km. */
    val paceSecondsPerKm: Int? = null,
)

data class ActivityTotals(val steps: Int, val calories: Int, val distanceMeters: Int, val activeMinutes: Int? = null)

/**
 * Dữ liệu lịch sử của một thiết bị sau khi đồng bộ.
 * [series] gồm các chuỗi theo thời gian: STEPS (mỗi khung, extra "calories"/"distance"),
 * HEART_RATE, HRV, STRESS, SPO2 (extra "min"), TEMPERATURE.
 */
data class DeviceHistory(
    val series: Map<Capability, List<HistoryPoint>> = emptyMap(),
    val sleep: List<SleepSession> = emptyList(),
    /** Bài tập ghi trên thiết bị, mới nhất trước. */
    val workouts: List<Workout> = emptyList(),
    val today: ActivityTotals? = null,
    val days: Int = 0,
    val syncedAt: Long = 0,
    /** Các bước đồng bộ lỗi (không làm hỏng các bước khác). */
    val errors: List<String> = emptyList(),
)

data class SyncProgress(val step: String, val done: Int, val total: Int)
