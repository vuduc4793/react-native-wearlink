package com.smartwear.gloryfit

import com.smartwear.core.LocationRequest
import com.smartwear.core.SportType
import com.smartwear.core.WorkoutData
import com.smartwear.core.WorkoutEvent
import com.smartwear.core.WorkoutState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Byte đối chiếu `uterkthis.java:3681-4000` (FD 11/00/22/33/44), `:4517-4528` (FD 02), `:927-1005` (FD 48), `BluetoothLeService.dealWithSportMode`. */
class UteWorkoutTest {
    private fun hex(s: String) = s.split(" ").map { it.toInt(16).toByte() }.toByteArray()
    private fun hexOf(b: ByteArray) = b.joinToString(" ") { "%02X".format(it) }

    private val y25 = Ute.Features.parse(
        hex("08 88 6C 2A 01 24 39 43 75 6E DF FE D9 21 00 5D 78 5B A0 DC"),
        hex("00 F4 00 00 00 00 00 00 00 00 00 05 00 00 40 02 00 00 04 20"),
    )

    @Test fun y25Bits() {
        assertTrue(UteWorkout.control(y25))
        assertTrue(UteWorkout.sportList(y25))
        assertTrue(UteWorkout.sportGps(y25))
        assertFalse(UteWorkout.dataWithSteps(y25))
    }

    @Test fun startStopQuery() {
        assertEquals("FD 11 01 01", hexOf(UteWorkout.start(1)))
        assertEquals("FD 11 09 01", hexOf(UteWorkout.start(9, interval = 0))) // intv ngoài 1..255 ⇒ 1
        assertEquals("FD 00 01 01", hexOf(UteWorkout.stop(1)))
        assertEquals("FD AA", hexOf(UteWorkout.QUERY))
    }

    @Test fun pauseResumeWatchMode() {
        // 1 giờ 2 phút 3 giây = 3723 s, 7 byte khi đồng hồ tự đo.
        assertEquals("FD 22 01 01 01 02 03", hexOf(UteWorkout.control(UteWorkout.OP_PAUSE, 1, 1, 3723, null, withSteps = false)))
        assertEquals("FD 33 01 01 00 00 2D", hexOf(UteWorkout.control(UteWorkout.OP_RESUME, 1, 1, 45, null, withSteps = false)))
    }

    @Test fun phoneGpsData() {
        // 300 kcal, 5 234 m ⇒ 5.23 km, pace 5'30" = 330 s.
        val d = WorkoutData(durationSec = 1800, calories = 300, distanceMeters = 5234, paceSecondsPerKm = 330, steps = 0x012345)
        assertEquals("FD 44 01 01 00 1E 00 01 2C 05 17 05 1E", hexOf(UteWorkout.control(UteWorkout.OP_DATA, 1, 1, 1800, d, withSteps = false)))
        assertEquals("FD 44 01 01 00 1E 00 01 2C 05 17 05 1E 01 23 45", hexOf(UteWorkout.control(UteWorkout.OP_DATA, 1, 1, 1800, d, withSteps = true)))
        // Pace > 99:59 ⇒ 0:00 như bản gốc.
        val slow = d.copy(paceSecondsPerKm = 6000)
        assertEquals("00 00", hexOf(UteWorkout.control(UteWorkout.OP_DATA, 1, 1, 1800, slow, false).copyOfRange(11, 13)))
    }

    @Test fun location() {
        assertEquals("FD 01 01", hexOf(UteWorkout.locationStatus(true)))
        assertEquals("FD 01 55", hexOf(UteWorkout.LOCATION_STOP))
        // 21.028511, 105.804817; 2.5 m/s ⇒ 250; điểm 12 m, tổng 1 000 m.
        val p = UteWorkout.location(21.028511, 105.804817, 2.5, 12, 1000)
        assertEquals(20, p.size)
        assertEquals("FD 02 01 40 DE 9F 06 4E 74 11 00 FA 00 00 00 0C 00 00 03 E8", hexOf(p))
        // Kinh/vĩ độ âm: số có dấu.
        assertEquals("FF F0 BD C0", hexOf(UteWorkout.location(-1.0, 0.0, null, 0, 0).copyOfRange(2, 6)))
        assertEquals(111_195.0, UteWorkout.distanceMeters(0.0, 0.0, 1.0, 0.0), 1.0)
    }

    @Test fun parseWatchPackets() {
        assertEquals(UteWorkout.Parsed.Event(WorkoutEvent.State(WorkoutState.STARTED, 1, byDevice = false)), UteWorkout.parse(hex("FD 11 01 01")))
        assertEquals(UteWorkout.Parsed.Event(WorkoutEvent.State(WorkoutState.STOPPED, 1, byDevice = false)), UteWorkout.parse(hex("FD 00 01 01")))
        assertEquals(UteWorkout.Parsed.Event(WorkoutEvent.State(WorkoutState.PAUSED, 2, byDevice = true)), UteWorkout.parse(hex("FD 04 02 22")))
        assertEquals(UteWorkout.Parsed.Event(WorkoutEvent.State(WorkoutState.RESUMED, 2, byDevice = true)), UteWorkout.parse(hex("FD 04 02 33")))
        // `FD AA st type`
        assertEquals(UteWorkout.Parsed.Event(WorkoutEvent.State(WorkoutState.PAUSED, 9, byDevice = false)), UteWorkout.parse(hex("FD AA 22 09")))
        assertEquals(UteWorkout.Parsed.Location(LocationRequest(true, 1)), UteWorkout.parse(hex("FD 01 AA 01")))
        assertEquals(UteWorkout.Parsed.Location(LocationRequest(false, null)), UteWorkout.parse(hex("FD 01 55")))
        assertEquals(UteWorkout.Parsed.Ack(0x02), UteWorkout.parse(hex("FD 02")))
        // Luồng đồng bộ / danh sách môn / gói khác không phải sự kiện.
        assertNull(UteWorkout.parse(hex("FD FD")))
        assertNull(UteWorkout.parse(hex("FD 48 FD 00")))
        assertNull(UteWorkout.parse(hex("D1 02")))
    }

    @Test fun parseRealtime() {
        // Chạy bộ: HR 120, 85 kcal, pace 6'05", 4 660 bước, 0 lần, 3.27 km.
        val e = UteWorkout.parse(hex("FD 01 78 00 55 06 05 00 12 34 00 00 03 1B")) as UteWorkout.Parsed.Event
        assertEquals(WorkoutEvent.Realtime(1, 120, 85, 365, 0x1234, 0, 3270), e.event)
        assertNull((UteWorkout.parse(hex("FD 01 00 00 00 00 00 00 00 00 00 00 00 00")) as UteWorkout.Parsed.Event).let { (it.event as WorkoutEvent.Realtime).heartRate })
    }

    @Test fun sportListRead() {
        assertEquals("FD 48 AA", hexOf(UteWorkout.QUERY_SPORTS))
        val list = UteWorkout.parseSportList(
            listOf(
                hex("FD 48 AA 00 01 01 00 02 00 01 00 00 00"),
                hex("FD 48 AA 01 09 01 01"),
                hex("FD 48 AA FD 00 00 04 00 0A"),
            ),
        )!!
        assertEquals(listOf(SportType(1, "Chạy bộ", true, 0), SportType(2, "Đạp xe", false, 1), SportType(9, "Đi bộ", true, 1)), list.sports)
        assertEquals(4, list.minShown)
        assertEquals(10, list.maxShown)
        assertNull(UteWorkout.parseSportList(emptyList()))
    }

    @Test fun sportListWrite() {
        val sports = listOf(SportType(1, "", true, 0), SportType(2, "", true, 1), SportType(9, "", false, 0))
        // 20 byte/gói ⇒ (20 − 3) / 3 = 5 môn/gói ⇒ một gói + gói kết thúc.
        val packets = UteWorkout.sportListPackets(sports, 20)
        assertEquals(listOf("FD 48 00 01 01 00 02 01 01 09 00 00", "FD 48 FD 0B"), packets.map(::hexOf))
        // Gói nhỏ: 2 môn/gói, seq tăng; xor gồm byte seq.
        val small = UteWorkout.sportListPackets(sports, 9)
        assertEquals(listOf("FD 48 00 01 01 00 02 01 01", "FD 48 01 09 00 00", "FD 48 FD 0A"), small.map(::hexOf))
        assertTrue(UteWorkout.sportListPackets(emptyList(), 20).isEmpty())
    }
}
