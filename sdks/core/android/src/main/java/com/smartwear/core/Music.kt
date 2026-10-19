package com.smartwear.core

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow

/** Nút nhạc người dùng bấm trên thiết bị. */
enum class MusicCommand { PLAY_PAUSE, NEXT, PREVIOUS, VOLUME_UP, VOLUME_DOWN }

/**
 * Trạng thái trình phát trên điện thoại để hiện lên thiết bị. Trường null = không đổi / không biết.
 * [durationSec]/[positionSec]: tổng thời lượng / vị trí đang phát (giây).
 */
data class MusicState(
    val playing: Boolean,
    val title: String? = null,
    val artist: String? = null,
    val volumePercent: Int? = null,
    val durationSec: Int? = null,
    val positionSec: Int? = null,
)

/**
 * Thiết bị điều khiển nhạc của điện thoại (phát/tạm dừng, chuyển bài, âm lượng) và hiện bài đang phát.
 * Mặc định: không hỗ trợ, không làm gì.
 */
interface MusicRemote {
    /** Thiết bị có màn điều khiển nhạc điện thoại. */
    val supportsMusicControl: Boolean get() = false

    /** Thiết bị hiện được tên bài / ca sĩ. */
    val supportsTrackInfo: Boolean get() = false

    /** Lệnh nhạc từ thiết bị; app điều khiển trình phát và âm lượng điện thoại. */
    val musicCommands: Flow<MusicCommand> get() = emptyFlow()

    /** Gửi trạng thái trình phát (và bài đang phát nếu thiết bị hỗ trợ). */
    suspend fun setMusicState(state: MusicState) {}

    /** Gửi âm lượng nhạc hiện tại của điện thoại (0–100). */
    suspend fun setMusicVolume(percent: Int) {}
}
