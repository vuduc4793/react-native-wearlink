package com.smartwear.core

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow

/**
 * Một môn thể thao trên thiết bị: [type] = mã môn của hãng, [name] tiếng Việt, [nameEn] tiếng Anh (null = không có),
 * [shown] = đang hiện trong danh sách, [position] = thứ tự hiện (1..n; môn ẩn = 0).
 */
data class SportType(val type: Int, val name: String, val shown: Boolean, val position: Int, val nameEn: String? = null)

/** Một môn trong danh mục của hãng ([WorkoutRemote.sportCatalog]). */
data class SportName(val type: Int, val name: String, val nameEn: String)

enum class WorkoutState { STARTED, PAUSED, RESUMED, STOPPED }

/** Sự kiện bài tập từ thiết bị. */
sealed class WorkoutEvent {
    /**
     * Bài tập đổi trạng thái. [byDevice] = người dùng thao tác trên thiết bị; false = thiết bị xác nhận lệnh của app.
     */
    data class State(val state: WorkoutState, val sportType: Int, val byDevice: Boolean) : WorkoutEvent()

    /**
     * Số liệu tức thời trong lúc tập. [heartRate] null = chưa đo được; [paceSecondsPerKm] = tốc độ trung bình (giây/km,
     * 0 = chưa có); [count] = số lần (nhảy dây, sải bơi…).
     */
    data class Realtime(
        val sportType: Int,
        val heartRate: Int?,
        val calories: Int,
        val paceSecondsPerKm: Int,
        val steps: Int,
        val count: Int,
        val distanceMeters: Int,
    ) : WorkoutEvent()
}

/** Thiết bị xin ([start] = true) hoặc thôi xin vị trí của điện thoại cho bài tập ngoài trời [sportType]. */
data class LocationRequest(val start: Boolean, val sportType: Int? = null)

/** Số liệu bài tập do điện thoại tính (khi điện thoại theo dõi GPS) gửi lên thiết bị. */
data class WorkoutData(
    val durationSec: Int,
    val calories: Int,
    val distanceMeters: Int,
    val paceSecondsPerKm: Int,
    val steps: Int? = null,
)

/**
 * Điều khiển bài tập từ điện thoại, số liệu tức thời, GPS điện thoại và danh sách môn. Mặc định: không hỗ trợ (hàm điều khiển
 * ném [UnsupportedOperationException]).
 */
interface WorkoutRemote {
    val supportsWorkoutControl: Boolean get() = false
    val supportsSportList: Boolean get() = false

    /** Thiết bị có thể xin vị trí điện thoại khi tập ngoài trời ([locationRequests]). */
    val supportsPhoneLocation: Boolean get() = false

    /** Danh sách môn đang có trên thiết bị. */
    suspend fun sportTypes(): List<SportType> = throw UnsupportedOperationException("Thiết bị không có danh sách môn")

    /**
     * Số môn được hiện tối thiểu / tối đa (đọc cùng [sportTypes]). null = chưa đọc [sportTypes] hoặc thiết bị không giới hạn.
     */
    val sportListLimits: IntRange? get() = null

    /**
     * Danh mục mọi môn hãng biết (mã → tên), để đặt tên bài tập và giải thích "100+ môn" của app hãng. Thiết bị chỉ giữ một phần
     * ([sportTypes]); không thêm được môn ngoài danh sách đó.
     */
    val sportCatalog: List<SportName> get() = emptyList()

    /** Ghi danh sách môn hiện trên thiết bị (thứ tự theo [SportType.position]); ném lỗi nếu thiết bị không xác nhận. */
    suspend fun setSportList(sports: List<SportType>): Unit = throw UnsupportedOperationException("Thiết bị không có danh sách môn")

    suspend fun startWorkout(sportType: Int): Unit = throw UnsupportedOperationException("Thiết bị không điều khiển bài tập được")
    suspend fun pauseWorkout(): Unit = throw UnsupportedOperationException("Thiết bị không điều khiển bài tập được")
    suspend fun resumeWorkout(): Unit = throw UnsupportedOperationException("Thiết bị không điều khiển bài tập được")
    suspend fun stopWorkout(): Unit = throw UnsupportedOperationException("Thiết bị không điều khiển bài tập được")

    /** Trạng thái + số liệu tức thời. */
    val workoutEvents: Flow<WorkoutEvent> get() = emptyFlow()

    /** Thiết bị xin / thôi xin vị trí điện thoại (bài tập ngoài trời). App lấy vị trí rồi gọi [sendLocation] định kỳ. */
    val locationRequests: Flow<LocationRequest> get() = emptyFlow()

    /**
     * Gửi một điểm vị trí của điện thoại. [speed] m/s. Driver tự tính quãng đường từ điểm trước và cộng dồn. [altitude],
     * [accuracy] để thiết bị nào cần thì dùng (GloryFit bỏ qua).
     */
    suspend fun sendLocation(latitude: Double, longitude: Double, altitude: Double? = null, speed: Double? = null, accuracy: Double? = null) {}

    /** Gửi số liệu bài tập do điện thoại tính (chế độ GPS điện thoại). */
    suspend fun sendWorkoutData(data: WorkoutData) {}
}
