package com.smartwear.lab

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory

/**
 * Thư viện mặt đồng hồ dựng sẵn (file `.bin` định dạng UTE, màn tròn 466 × 466) trong `assets/watchfaces/<id>.bin`,
 * ảnh xem trước `<id>.png`. [DEFAULT_ID] được tự cài khi thiết bị chưa có thiết kế nào.
 */
object WatchFaceLibrary {

    data class Preset(
        val id: String,
        val name: String,
        val note: String,
        /** Dùng element chưa kiểm chứng trên thiết bị thật (kim xoay). */
        val experimental: Boolean = false,
    )

    const val DEFAULT_ID = "peacock-3d"

    val presets = listOf(
        Preset("peacock-3d", "Peacock 3D", "Nền 3D phủ kín · giờ, ngày, bước, nhịp tim, pin"),
        Preset("peacock-atelier", "Peacock Atelier", "Kim giờ/phút/giây trên nền đồng · bước, nhịp tim, pin"),
        Preset("ben10", "Ben 10 Biến hình", "Thử nghiệm · nhân vật đổi mỗi giây, vòng trong xoay · giờ, pin"),
    )

    fun find(id: String?): Preset? = presets.firstOrNull { it.id == id }

    /** Màn hình của file trong thư viện; thiết bị khác kích thước thì không dùng được thư viện. */
    const val WIDTH = 466
    const val HEIGHT = 466

    fun bin(context: Context, id: String): ByteArray = context.assets.open("watchfaces/$id.bin").use { it.readBytes() }

    fun preview(context: Context, id: String): Bitmap? =
        runCatching { context.assets.open("watchfaces/$id.png").use(BitmapFactory::decodeStream) }.getOrNull()
}
