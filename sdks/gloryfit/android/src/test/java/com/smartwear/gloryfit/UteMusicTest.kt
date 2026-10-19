package com.smartwear.gloryfit

import com.smartwear.core.MusicCommand
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Byte đối chiếu với `uterkthis.java:4589-4699` (`3A`), `:3968-3979` (`D1 0D/0E`), `WriteCommandToBLE.controlBandMusic`. */
class UteMusicTest {
    private fun hex(s: String) = s.split(" ").map { it.toInt(16).toByte() }.toByteArray()
    private fun hexOf(b: ByteArray) = b.joinToString(" ") { "%02X".format(it) }

    private val y25 = Ute.Features.parse(hex("08 88 6C 2A 01 24 39 43 75 6E DF FE D9 21 00 5D 78 5B A0 DC"), null)

    @Test fun y25HasMusicBits() {
        assertTrue(UteMusic.control(y25))
        assertTrue(UteMusic.songInfo(y25))
    }

    @Test fun watchCommands() {
        assertEquals(MusicCommand.PLAY_PAUSE, UteMusic.parseCommand(hex("D1 07")))
        assertEquals(MusicCommand.NEXT, UteMusic.parseCommand(hex("D1 08")))
        assertEquals(MusicCommand.PREVIOUS, UteMusic.parseCommand(hex("D1 09")))
        assertEquals(MusicCommand.VOLUME_UP, UteMusic.parseCommand(hex("D1 0D")))
        assertEquals(MusicCommand.VOLUME_DOWN, UteMusic.parseCommand(hex("D1 0E")))
        // `D1 0C` là đồng hồ xác nhận trạng thái app gửi; `D1 0A` là tìm điện thoại; `D1 03` là chụp ảnh.
        assertNull(UteMusic.parseCommand(hex("D1 0C")))
        assertNull(UteMusic.parseCommand(hex("D1 0A")))
        assertNull(UteMusic.parseCommand(hex("D1 03")))
        assertNull(UteMusic.parseCommand(hex("C4 07")))
    }

    @Test fun songPacketsLikePro() {
        // Pro chỉ gửi trạng thái + tên bài: đang phát = 02, các trường khác FF.
        val packets = UteMusic.songPackets(playing = true, title = "Hello")
        assertEquals(listOf("3A 01 02 FF FF FF FF FF FF FF FF FF FF", "3A 06 05 48 65 6C 6C 6F"), packets.map(::hexOf))
        // XOR: 3A^01^02 (10 byte FF triệt tiêu) = 39; 3A^06^05^48^65^6C^6C^6F = 7B; 39^7B = 42.
        assertEquals(0x42, UteMusic.checksum(packets))
        assertEquals("3A FA", hexOf(UteMusic.SONG_END))
        assertEquals("3A 01 01 FF FF FF FF FF FF FF FF FF FF", hexOf(UteMusic.songPackets(playing = false, title = null).single()))
    }

    @Test fun allFieldsAndArtist() {
        val packets = UteMusic.songPackets(true, "A", "AB", volumePercent = 50, mode = 1, totalTime = 0x00010203, currentTime = 5)
        assertEquals("3A 01 02 01 32 00 01 02 03 00 00 00 05", hexOf(packets[0]))
        assertEquals("3A 04 00 02 41 42", hexOf(packets[2]))
    }

    @Test fun titleIsCutAt52Bytes() {
        val p = UteMusic.songPackets(true, "x".repeat(80)).last()
        assertEquals(55, p.size)
        assertEquals(52, p[2].toInt())
    }

    @Test fun playStateAndVolume() {
        assertEquals("D1 0C 01", hexOf(UteMusic.playState(true)))
        assertEquals("D1 0C 02", hexOf(UteMusic.playState(false)))
        assertEquals("D1 0D 3C", hexOf(UteMusic.volume(60, up = true)))
        assertEquals("D1 0E 28", hexOf(UteMusic.volume(40, up = false)))
    }

    @Test fun volumeScale15() {
        assertEquals(100, UteMusic.volumePercent(15, 15))
        assertEquals(0, UteMusic.volumePercent(0, 15))
        assertEquals(53, UteMusic.volumePercent(8, 15))
        assertEquals(46, UteMusic.volumePercent(12, 25))
        assertEquals(0, UteMusic.volumePercent(3, 0))
    }
}
