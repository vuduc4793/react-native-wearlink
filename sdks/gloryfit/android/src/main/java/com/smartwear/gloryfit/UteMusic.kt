package com.smartwear.gloryfit

import com.smartwear.core.MusicCommand

/**
 * Điều khiển nhạc điện thoại từ đồng hồ và đẩy bài đang phát lên đồng hồ (doc 10 §2.6). Viết tắt như [UteNotify]:
 * `T` = `uterkif/uterkthis.java` (GloryFitPro 1.9.0.2), `W` = `WriteCommandToBLE.java` (GloryFit 4.0.12).
 *
 * Đồng hồ → app (`P/uterkfor/uterkchar.java:137-215`): `D1 07` phát/tạm dừng, `D1 08` bài sau, `D1 09` bài trước,
 * `D1 0D` / `D1 0E` tăng / giảm âm lượng. App → đồng hồ: `3A …` tên bài (F5 `0x1000`), `D1 0C` trạng thái phát
 * (đồng hồ không có F5 `0x1000`, `W:3644-3649`), `D1 0D/0E pct` âm lượng (`T:3968-3979`).
 */
object UteMusic {

    /** F5 `0x1` (`IS_SUPPORT_MUSIC_CONTROL`): đồng hồ có màn điều khiển nhạc điện thoại. */
    fun control(f: Ute.Features) = f.has(5, 0x000001)

    /** F5 `0x1000` (`IS_SUPPORT_MUSIC_CONTENT_DISPLAY`): đồng hồ hiện tên bài (`MusicControl.onMetadataChanged`, `W`). */
    fun songInfo(f: Ute.Features) = f.has(5, 0x001000)

    /**
     * Lệnh nhạc từ đồng hồ (`uterkchar.uterkfor`, mọi độ dài gói như bản gốc): 7 → phát/tạm dừng, 8 → bài sau,
     * 9 → bài trước, 0x0D → tăng âm lượng, 0x0E → giảm (`ServicePresenter.setResponseMusicControlRk`).
     */
    fun parseCommand(p: ByteArray): MusicCommand? {
        if (p.size < 2 || Ute.u(p, 0) != 0xD1) return null
        return when (Ute.u(p, 1)) {
            0x07 -> MusicCommand.PLAY_PAUSE
            0x08 -> MusicCommand.NEXT
            0x09 -> MusicCommand.PREVIOUS
            0x0D -> MusicCommand.VOLUME_UP
            0x0E -> MusicCommand.VOLUME_DOWN
            else -> null
        }
    }

    /**
     * Bài đang phát, như `T:4589-4699` (`setSongInformationToDevice`), gửi lên 34F1, cách nhau 100 ms:
     * - `3A 01 st mode vol total(4) cur(4)` (13 byte) nếu có ít nhất một trường; st: đang phát `02`, dừng `01`;
     *   trường null = `FF` (`MusicPushInfo.STATUS_NO_CHANGE`); mode 0 tuần tự / 1 ngẫu nhiên / 2 một bài;
     * - `3A 06 len <tên bài UTF-8, cắt 52 byte>` nếu có tên;
     * - `3A 04 00 len <ca sĩ UTF-8, cắt 52 byte>` nếu có ca sĩ.
     * Gói `3A FA` gửi sau cùng ([SONG_END]); đồng hồ trả `3A FA xx` với xx = [checksum] các gói trên.
     */
    fun songPackets(
        playing: Boolean?, title: String?, artist: String? = null,
        volumePercent: Int? = null, mode: Int? = null, totalTime: Int? = null, currentTime: Int? = null,
    ): List<ByteArray> = buildList {
        if (playing != null || mode != null || volumePercent != null || totalTime != null || currentTime != null) {
            val none: Byte = -1
            fun be32(v: Int?) = if (v == null) ByteArray(4) { none } else ByteArray(4) { (v shr (24 - 8 * it)).toByte() }
            val status: Byte = when (playing) { true -> 0x02; false -> 0x01; null -> none }
            add(
                byteArrayOf(
                    0x3A, 0x01, status,
                    if (mode != null && mode in 0..2) mode.toByte() else none,
                    volumePercent?.toByte() ?: none,
                ) + be32(totalTime) + be32(currentTime),
            )
        }
        if (!title.isNullOrEmpty()) {
            val b = title.toByteArray(Charsets.UTF_8).let { it.copyOf(minOf(it.size, 52)) }
            add(byteArrayOf(0x3A, 0x06, b.size.toByte()) + b)
        }
        if (!artist.isNullOrEmpty()) {
            val b = artist.toByteArray(Charsets.UTF_8).let { it.copyOf(minOf(it.size, 52)) }
            add(byteArrayOf(0x3A, 0x04, 0x00, b.size.toByte()) + b)
        }
    }

    /** `3A FA`: kết thúc gói tên bài (`T:4692-4698`). */
    val SONG_END = byteArrayOf(0x3A, 0xFA.toByte())

    /** XOR mọi byte của các gói tên bài (biến `K` trong `T`), đồng hồ đối chiếu trong `3A FA xx` (`uterkchar.java:70-89`). */
    fun checksum(packets: List<ByteArray>): Int = packets.fold(0) { acc, p -> p.fold(acc) { a, b -> a xor (b.toInt() and 0xFF) } }

    /** `D1 0C 01` đang phát / `D1 0C 02` dừng (`W:3644-3649` `controlBandMusic`; `T:3001-3011`). */
    fun playState(playing: Boolean) = byteArrayOf(0xD1.toByte(), 0x0C, if (playing) 0x01 else 0x02)

    /**
     * Âm lượng điện thoại lên đồng hồ: `D1 0D pct` khi tăng (hoặc bằng), `D1 0E pct` khi giảm (`T:3968-3979`,
     * `SearchDeviceModelImpl.java:225-230`).
     */
    fun volume(percent: Int, up: Boolean) = byteArrayOf(0xD1.toByte(), if (up) 0x0D else 0x0E, percent.coerceIn(0, 100).toByte())

    /**
     * Âm lượng thang 15 như `ServicePresenter.getCurrentVolume` (`getMaxVolume()` = 15) rồi ra phần trăm
     * `min(cur·100/15, 100)` (`SearchDeviceModelImpl.java:227`). jadx in phép chia `stream / max` không ép kiểu (sẽ chỉ ra 0
     * hoặc 15); ở đây chia số thực, đúng ý định của bản gốc.
     */
    fun volumePercent(streamVolume: Int, streamMax: Int): Int = com.smartwear.core.phone.PhoneText.volumePercent(streamVolume, streamMax)
}
