package com.smartwear.core

import android.graphics.Bitmap
import android.graphics.RectF

/** Thông số màn hình đồng hồ để dựng mặt đồng hồ. */
data class WatchFaceSpec(val width: Int, val height: Int, val round: Boolean, val maxBytes: Long)

enum class TimePosition { TOP, CENTER, BOTTOM }

/**
 * Thành phần phụ bật/tắt được. [verified] = đã kiểm chứng hiển thị trên thiết bị thật (Y25, 13/10/2026):
 * các thành phần trong template chính thức, cùng giây/nhịp tim/kcal/quãng đường (ngoài template).
 */
enum class Complication(val label: String, val verified: Boolean) {
    WEEKDAY("Thứ", true),
    DATE("Ngày/tháng", true),
    BATTERY("Pin", true),
    BLUETOOTH("Bluetooth", true),
    STEPS("Bước chân", true),
    STEP_PROGRESS("Tiến độ bước", true),
    SECONDS("Giây", true),
    HEART_RATE("Nhịp tim", true),
    CALORIES("Kcal", true),
    DISTANCE("Quãng đường", true),
}

/** Mọi khối đặt được trên mặt đồng hồ (kéo thả trong trình chỉnh). */
enum class WatchWidget(val label: String) {
    IMAGE("Ảnh"),
    TIME("Giờ"),
    SECONDS("Giây"),
    AMPM("AM/PM"),
    WEEKDAY("Thứ"),
    DATE("Ngày/tháng"),
    BATTERY("Pin"),
    BLUETOOTH("Bluetooth"),
    STEPS("Bước chân"),
    HEART_RATE("Nhịp tim"),
    CALORIES("Kcal"),
    DISTANCE("Quãng đường"),
    STEP_PROGRESS("Tiến độ bước"),
}

/** Vị trí một khối: tâm theo tỉ lệ chiều rộng/cao màn hình (0–1) và hệ số phóng to. */
data class WidgetPlacement(val cx: Float, val cy: Float, val scale: Float = 1f)

/** Mọi tuỳ chỉnh mặt đồng hồ. */
data class WatchFaceStyle(
    /** Màu chữ chính (giờ/phút). ARGB. */
    val textColor: Int = 0xFFFFFFFF.toInt(),
    /** Màu nhấn cho chữ phụ, biểu tượng, thanh tiến độ. */
    val accentColor: Int = 0xFFFFB04A.toInt(),
    /** Màu nền phía sau ảnh. */
    val backgroundColor: Int = 0xFF0E0F12.toInt(),
    /** Bố cục tự động: vị trí khối chữ. Bị bỏ qua cho các khối đã có trong [placements]. */
    val timePosition: TimePosition = TimePosition.BOTTOM,
    /** Kích thước ảnh so với cạnh màn hình (0.3–1.0). 1.0 = ảnh phủ kín màn. */
    val imageScale: Float = 1f,
    /** Chiều cao chữ số giờ so với cạnh màn hình (0.12–0.24) khi scale = 1. */
    val timeSize: Float = 0.17f,
    /** Nền tối mờ phía sau chữ để dễ đọc khi chữ đè lên ảnh. */
    val scrim: Boolean = true,
    /** Hiển thị 12 giờ (kèm AM/PM). */
    val hour12: Boolean = false,
    val complications: Set<Complication> = setOf(Complication.WEEKDAY, Complication.DATE, Complication.BATTERY, Complication.STEPS),
    /** Vị trí do người dùng kéo thả. Khối không có trong map dùng bố cục tự động. */
    val placements: Map<WatchWidget, WidgetPlacement> = emptyMap(),
) {
    /** Các khối đang bật. */
    val widgets: Set<WatchWidget>
        get() = buildSet {
            if (imageScale < 0.99f) add(WatchWidget.IMAGE)
            add(WatchWidget.TIME)
            if (hour12) add(WatchWidget.AMPM)
            complications.forEach { add(WatchWidget.valueOf(it.name)) }
        }
}

/**
 * Thông tin mặt đồng hồ của thiết bị: kích thước màn, tròn/vuông, dung lượng file tối đa, mã mặt đang hiện (riêng của hãng),
 * số khe chứa mặt cài thêm, mặt đang hiện có phải mặt tuỳ chỉnh do app gửi không.
 */
data class WatchFaceInfo(
    val width: Int,
    val height: Int,
    val round: Boolean,
    val maxBytes: Long,
    val currentId: Long,
    val slotCount: Int,
    val customActive: Boolean,
)

/** Một khe trên thiết bị: [index] = số thứ tự khe (dùng cho [WatchFaceManager.deleteWatchFaceSlot]), [faceId] = mã mặt trong khe. */
data class WatchFaceSlot(val index: Int, val faceId: Long)

/**
 * Quản lý mặt đồng hồ: đọc thông tin, cài file mặt dựng sẵn, xem / xoá khe. Mặc định: không hỗ trợ.
 * Dựng mặt từ ảnh (chỉ Android) nằm ở [WatchFaceCustomizable].
 */
interface WatchFaceManager {
    /** Có mặt đồng hồ đọc / cài được ([watchFaceInfo], [installWatchFace]). */
    val supportsWatchFace: Boolean get() = false

    /** Xem / xoá được khe mặt đồng hồ ([watchFaceSlots], [deleteWatchFaceSlot]). */
    val supportsWatchFaceSlots: Boolean get() = false

    suspend fun watchFaceInfo(): WatchFaceInfo = throw UnsupportedOperationException("Thiết bị không có mặt đồng hồ")

    /** Cài một file mặt đồng hồ đúng định dạng của thiết bị (kiểm tra trước khi gửi). [progress] từ 0 đến 1. */
    suspend fun installWatchFace(file: ByteArray, progress: (Float) -> Unit = {}): Unit =
        throw UnsupportedOperationException("Thiết bị không cài được mặt đồng hồ")

    /** Các khe đang có mặt đồng hồ. */
    suspend fun watchFaceSlots(): List<WatchFaceSlot> = emptyList()

    /** Xoá mặt trong khe [index]; ném lỗi nếu thiết bị báo không xoá được. */
    suspend fun deleteWatchFaceSlot(index: Int): Unit = throw UnsupportedOperationException("Thiết bị không xoá được khe mặt đồng hồ")
}

/** Thiết bị cho phép đặt mặt đồng hồ tuỳ chỉnh (ảnh nền + giờ + thành phần phụ). */
interface WatchFaceCustomizable : WatchFaceManager {
    suspend fun watchFaceSpec(): WatchFaceSpec

    /** Ảnh xem trước đúng như sẽ hiện trên đồng hồ (dựng tại chỗ, không gửi gì). Bỏ qua khối [exclude] nếu có. */
    fun renderWatchFace(image: Bitmap, spec: WatchFaceSpec, style: WatchFaceStyle, exclude: WatchWidget? = null): Bitmap

    /** Khung (pixel trên màn hình đồng hồ) của từng khối đang bật, dùng cho kéo thả. */
    fun watchFaceLayout(image: Bitmap, spec: WatchFaceSpec, style: WatchFaceStyle): Map<WatchWidget, RectF>

    /** Ảnh riêng của một khối trên nền trong suốt, để hiển thị khi đang kéo. */
    fun renderWidget(image: Bitmap, spec: WatchFaceSpec, style: WatchFaceStyle, widget: WatchWidget): Bitmap

    /** Dung lượng file mặt đồng hồ (byte) để so với giới hạn của thiết bị. */
    fun watchFaceSize(image: Bitmap, spec: WatchFaceSpec, style: WatchFaceStyle): Int

    /** Thiết bị có đang hiển thị mặt đồng hồ tuỳ chỉnh (do app gửi) không. False nếu vừa reset hoặc đã chuyển sang mặt khác. */
    suspend fun isCustomWatchFaceActive(): Boolean

    /** Dựng và gửi mặt đồng hồ lên thiết bị. [progress] từ 0 đến 1. Trả về style thực sự đã gửi (có thể thu nhỏ chữ để vừa dung lượng). */
    suspend fun setWatchFace(image: Bitmap, style: WatchFaceStyle, progress: (Float) -> Unit = {}): WatchFaceStyle
}
