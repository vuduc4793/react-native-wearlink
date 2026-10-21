package com.smartwear.veepoo

import com.smartwear.core.Capability
import com.smartwear.core.Reading
import com.smartwear.core.ReadingStatus
import com.smartwear.veepoo.Veepoo.op
import com.smartwear.veepoo.Veepoo.u

/**
 * Parser gói đo trực tiếp (§6.2). Mỗi hàm trả về một parser có trạng thái (đếm số giá trị hợp lệ) cho một lần đo:
 * gói → (Reading, kết thúc?) hoặc null nếu bỏ qua.
 */
object VeepooMeasure {

    /** Số giá trị nhịp tim hợp lệ liên tiếp trước khi coi là xong (vòng tay đo liên tục tới khi app gửi `D0 00`). */
    const val HR_SAMPLES = 6

    /**
     * Nhịp tim `D0 bpm … [5] trạng thái máy` (`jf/u0.java:43-59`): `[5]` ∉ {0,2,3} = máy bận; bpm 1/2 = đeo sai;
     * 30–210 hợp lệ. Lấy giá trị thứ [HR_SAMPLES] (vài giá trị đầu chưa ổn định).
     */
    fun heartRate(samples: Int = HR_SAMPLES): (ByteArray) -> Pair<Reading, Boolean>? {
        var valid = 0
        return parser@{ p ->
            if (p.op != 0xD0 || p.size < 2) return@parser null
            val bpm = u(p, 1)
            val machine = if (p.size >= 6) u(p, 5) else 0
            val c = Capability.HEART_RATE
            when {
                machine != 0 && machine != 2 && machine != 3 -> Reading(c, ReadingStatus.ERROR, errorCode = machine, note = "Vòng tay đang bận đo việc khác") to true
                // GE54 đang sạc: `D0 01 00 00 FD …` (byte 4 = FD, như mã 253 "đang sạc" của huyết áp).
                p.size >= 5 && u(p, 4) == 0xFD -> Reading(c, ReadingStatus.ERROR, errorCode = 0xFD, note = "Vòng tay đang sạc") to true
                bpm == 1 || bpm == 2 -> Reading(c, ReadingStatus.NOT_WORN) to true
                bpm in 30..210 -> {
                    valid++
                    Reading(c, if (valid >= samples) ReadingStatus.OK else ReadingStatus.MEASURING, value = bpm.toDouble()) to (valid >= samples)
                }
                else -> Reading(c, ReadingStatus.MEASURING) to false
            }
        }
    }

    /** Kết quả một gói `D0` của luồng nhịp tim liên tục ([heartRateSample]). */
    sealed class StreamPacket {
        data class Sample(val sample: com.smartwear.core.HeartRateSample) : StreamPacket()

        /** Vòng tay bận đo việc khác / đang sạc: luồng phải dừng. */
        data class Failed(val message: String) : StreamPacket()
    }

    /**
     * Một gói `D0` khi đo liên tục (cùng bố cục [heartRate], không đếm mẫu): 30–210 ⇒ mẫu có nhịp tim, bpm 1/2 ⇒ chưa đeo
     * (`bpm` null, `contact` false), giá trị khác (0 lúc đang khởi động cảm biến) ⇒ null (bỏ qua).
     */
    fun heartRateSample(p: ByteArray, timestamp: Long = System.currentTimeMillis()): StreamPacket? {
        if (p.op != 0xD0 || p.size < 2) return null
        val bpm = u(p, 1)
        val machine = if (p.size >= 6) u(p, 5) else 0
        return when {
            machine != 0 && machine != 2 && machine != 3 -> StreamPacket.Failed("Vòng tay đang bận đo việc khác ($machine)")
            p.size >= 5 && u(p, 4) == 0xFD -> StreamPacket.Failed("Vòng tay đang sạc")
            bpm == 1 || bpm == 2 -> StreamPacket.Sample(com.smartwear.core.HeartRateSample(null, contact = false, timestamp = timestamp))
            bpm in 30..210 -> StreamPacket.Sample(com.smartwear.core.HeartRateSample(bpm, contact = true, timestamp = timestamp))
            else -> null
        }
    }

    /**
     * SpO2 `80 chức-năng máy giá-trị đang-hiệu-chuẩn tiến-độ …` (`jf/f2.java:126-189`). Máy: 10 pin yếu, 11 xong, 12 không đeo;
     * byte 3 = %; byte 4 = 1/2 ⇒ đang hiệu chuẩn (byte 5 = tiến độ). Gói 20 byte có byte 6 = 6 ⇒ byte 7 = nhịp tim kèm theo.
     * Giá trị 1 = không đeo. Xong khi có [samples] giá trị 70–100 không trong lúc hiệu chuẩn, hoặc máy báo 11.
     */
    fun spo2(samples: Int = 3): (ByteArray) -> Pair<Reading, Boolean>? {
        var valid = 0
        var lastValue: Int? = null
        return parser@{ p ->
            if (p.op != 0x80 || p.size < 4) return@parser null
            val c = Capability.SPO2
            val machine = u(p, 2)
            val value = u(p, 3)
            val calibrating = p.size >= 5 && (u(p, 4) == 1 || u(p, 4) == 2)
            when {
                machine == 12 || value == 1 -> Reading(c, ReadingStatus.NOT_WORN) to true
                machine == 10 -> Reading(c, ReadingStatus.ERROR, errorCode = 10, note = "Pin yếu") to true
                machine == 1 || machine == 2 || machine == 5 -> Reading(c, ReadingStatus.ERROR, errorCode = machine, note = "Vòng tay đang bận đo việc khác") to true
                value in 70..100 && !calibrating -> {
                    valid++
                    lastValue = value
                    val done = valid >= samples || machine == 11
                    Reading(c, if (done) ReadingStatus.OK else ReadingStatus.MEASURING, value = value.toDouble()) to done
                }
                machine == 11 -> (lastValue?.let { Reading(c, ReadingStatus.OK, value = it.toDouble()) } ?: Reading(c, ReadingStatus.ERROR, errorCode = 11)) to true
                else -> Reading(c, ReadingStatus.MEASURING) to false
            }
        }
    }

    /**
     * Huyết áp `90 tâm-thu tâm-trương tiến-độ trạng-thái có-tiến-độ` (`jf/d.java:114-171`). Trạng thái 1,2,4,5,255 bận;
     * 254 pin yếu; 253 đang sạc; 252 không đeo. Xong khi tiến độ ≥ 100 và có giá trị.
     */
    fun bloodPressure(): (ByteArray) -> Pair<Reading, Boolean>? = parser@{ p ->
        if (p.op != 0x90 || p.size < 5) return@parser null
        val c = Capability.BLOOD_PRESSURE
        val sys = u(p, 1)
        val dia = u(p, 2)
        val progress = u(p, 3)
        when (val st = u(p, 4)) {
            252 -> Reading(c, ReadingStatus.NOT_WORN) to true
            253 -> Reading(c, ReadingStatus.ERROR, errorCode = st, note = "Vòng tay đang sạc") to true
            254 -> Reading(c, ReadingStatus.ERROR, errorCode = st, note = "Pin yếu") to true
            1, 2, 4, 5, 255 -> Reading(c, ReadingStatus.ERROR, errorCode = st, note = "Vòng tay đang bận đo việc khác") to true
            else -> if (progress >= 100 && sys > 0 && dia > 0) {
                Reading(c, ReadingStatus.OK, systolic = sys, diastolic = dia) to true
            } else {
                Reading(c, ReadingStatus.MEASURING) to false
            }
        }
    }

    /**
     * Nhiệt độ `87 01 thao-tác máy tiến-độ tLo tHi bLo bHi` (`jf/o2.java:18-34`; xử lý trong app `home/viewModel/a0.java:62-117`):
     * thao tác (byte 2) 0 = lỗi, 2 = đã dừng; máy (byte 3) **0 hoặc 7 = đang đo bình thường**, 1–6 bận, 8 pin yếu, khác = không hợp lệ;
     * byte 5–6 LE ÷10 = nhiệt độ cơ thể, 7–8 = nhiệt độ nền (da). Xong khi tiến độ ≥ 100.
     * GE54 (19/10/2026, đang đeo): `87 01 01 07 00 72 01 69 01` = đang đo, 37,0 °C / nền 36,1 °C.
     */
    fun temperature(): (ByteArray) -> Pair<Reading, Boolean>? = parser@{ p ->
        if (p.op != 0x87 || p.size < 9) return@parser null
        val c = Capability.TEMPERATURE
        val operation = u(p, 2)
        val machine = u(p, 3)
        val progress = u(p, 4)
        val t = Veepoo.le16(p, 5) / 10.0
        when {
            operation == 0 -> Reading(c, ReadingStatus.ERROR, errorCode = 0, note = "Đo nhiệt độ không hợp lệ") to true
            operation == 2 -> Reading(c, ReadingStatus.ERROR, errorCode = 2, note = "Vòng tay đã dừng đo") to true
            machine in 1..6 -> Reading(c, ReadingStatus.ERROR, errorCode = machine, note = "Vòng tay đang bận đo việc khác") to true
            machine == 8 -> Reading(c, ReadingStatus.ERROR, errorCode = machine, note = "Pin yếu") to true
            machine != 0 && machine != 7 -> Reading(c, ReadingStatus.ERROR, errorCode = machine) to true
            progress >= 100 && t > 0 -> Reading(c, ReadingStatus.OK, value = t) to true
            else -> Reading(c, ReadingStatus.MEASURING, value = t.takeIf { it > 0 }) to false
        }
    }

    /** Nhiệt độ nền (da) trong gói `87` (byte 7–8 LE ÷10), null nếu không có. */
    fun temperatureBase(p: ByteArray): Double? = if (p.op == 0x87 && p.size >= 9) Veepoo.le16(p, 7).takeIf { it > 0 }?.let { it / 10.0 } else null

    /**
     * Stress `89 06 01 ack tiến-độ giá-trị` (`jf/u1.java:16-70`): ack 0 OK, 1/3 bận, 2 pin yếu, 4 không đeo. Xong khi tiến độ 100
     * và giá trị > 0. `89 06 02` = đã dừng.
     */
    fun stress(): (ByteArray) -> Pair<Reading, Boolean>? = parser@{ p ->
        if (p.op != 0x89 || p.size < 4 || u(p, 1) != 0x06) return@parser null
        val c = Capability.STRESS
        if (u(p, 2) == 2) return@parser Reading(c, ReadingStatus.ERROR, errorCode = 0, note = "Vòng tay đã dừng đo") to true
        if (u(p, 2) != 1) return@parser null
        when (val ack = u(p, 3)) {
            0 -> {
                val progress = if (p.size > 4) u(p, 4) else 0
                val value = if (p.size > 5) u(p, 5) else 0
                if (progress >= 100 && value > 0) Reading(c, ReadingStatus.OK, value = value.toDouble()) to true
                else Reading(c, ReadingStatus.MEASURING) to false
            }
            4 -> Reading(c, ReadingStatus.NOT_WORN) to true
            else -> Reading(c, ReadingStatus.ERROR, errorCode = ack) to true
        }
    }

    /**
     * MET `89 08 01 ack tiến-độ MET×10` (`jf/c1.java`): ack 0 OK, 1/3 bận, 2 pin yếu, 4 không đeo; `89 08 02` = đã dừng. Xong khi tiến độ ≥ 100.
     */
    fun met(): (ByteArray) -> Pair<Reading, Boolean>? = parser@{ p ->
        if (p.op != 0x89 || p.size < 4 || u(p, 1) != 0x08) return@parser null
        val c = Capability.MET
        if (u(p, 2) == 2) return@parser Reading(c, ReadingStatus.ERROR, errorCode = 0, note = "Vòng tay đã dừng đo") to true
        if (u(p, 2) != 1) return@parser null
        when (val ack = u(p, 3)) {
            0 -> {
                val progress = if (p.size > 4) u(p, 4) else 0
                val v = if (p.size > 5) u(p, 5) / 10.0 else 0.0
                if (progress >= 100 && v > 0) Reading(c, ReadingStatus.OK, value = v) to true else Reading(c, ReadingStatus.MEASURING) to false
            }
            4 -> Reading(c, ReadingStatus.NOT_WORN) to true
            2 -> Reading(c, ReadingStatus.ERROR, errorCode = ack, note = "Pin yếu") to true
            else -> Reading(c, ReadingStatus.ERROR, errorCode = ack, note = "Vòng tay đang bận đo việc khác") to true
        }
    }

    /**
     * Đường huyết `89 01 thao-tác trạng-thái tiến-độ giá-trị(LE16)` (`jf/h.java` handler): thao tác 0 = không hỗ trợ, 2 = đã dừng;
     * trạng thái 0/1 = đang đo bình thường, 2 pin yếu, 3 bận, 4 đeo sai; giá trị 13 bit thấp ÷100 = mmol/L (3 bit cao = mức rủi ro).
     * Xong khi tiến độ ≥ 100 và có giá trị.
     */
    fun bloodGlucose(): (ByteArray) -> Pair<Reading, Boolean>? = parser@{ p ->
        if (p.op != 0x89 || p.size < 4 || u(p, 1) != 0x01) return@parser null
        val c = Capability.BLOOD_SUGAR
        when (u(p, 2)) {
            0 -> return@parser Reading(c, ReadingStatus.ERROR, errorCode = 0, note = "Vòng tay không hỗ trợ đo đường huyết") to true
            2 -> return@parser Reading(c, ReadingStatus.ERROR, errorCode = 0, note = "Vòng tay đã dừng đo") to true
            1 -> Unit
            else -> return@parser null
        }
        when (val st = u(p, 3)) {
            0, 1 -> {
                val progress = if (p.size > 4) u(p, 4) else 0
                val v = if (p.size >= 7) (Veepoo.le16(p, 5) and 0x1FFF) / 100.0 else 0.0
                if (progress >= 100 && v > 0) Reading(c, ReadingStatus.OK, value = v) to true
                else Reading(c, ReadingStatus.MEASURING) to false
            }
            2 -> Reading(c, ReadingStatus.ERROR, errorCode = st, note = "Pin yếu") to true
            3 -> Reading(c, ReadingStatus.ERROR, errorCode = st, note = "Vòng tay đang bận đo việc khác") to true
            4 -> Reading(c, ReadingStatus.NOT_WORN) to true
            else -> Reading(c, ReadingStatus.ERROR, errorCode = st) to true
        }
    }

    /**
     * Thành phần máu `8A 01 01 trạng-thái tiến-độ uric TCHO TAG HDL LDL 00×5` (`jf/g.java:125-176`, `a()` :53-66). Trạng thái
     * (`EBloodComponentDetectState`): 0 = bình thường (byte 4 = tiến độ %, byte 5..14 = ước lượng đang chạy), 1 = đang đo việc khác,
     * 2 pin yếu, 3 bận, 4 đeo/tiếp xúc không đạt; `8A 01 02` = đã dừng. Kết quả = gói tiến độ 100 (G Band `onDetectComplete`).
     * Giao thức KHÔNG có cờ "có ngón tay" hay "đo thật / ước lượng" (byte 15..19 luôn 0 trên GE54), nên suốt phép đo phát
     * `MEASURING` + `note` [Reading.NOTE_TOUCH_SENSOR] + `extra["progress"]` để app nhắc đặt ngón tay lên cảm biến.
     * [capability] URIC_ACID (giá trị acid uric μmol/L) hoặc BLOOD_LIPIDS (cholesterol toàn phần mmol/L); cả 5 chỉ số trong `extra`.
     * GE54 19/10/2026 (`8A 01 01 00`): `8A 01 01 00 64 69 08 AB 01 66 00 68 00 0C 01` = 215,3 μmol/L; 4,27 / 1,02 / 1,04 / 2,68 mmol/L.
     */
    fun bloodComponent(capability: Capability): (ByteArray) -> Pair<Reading, Boolean>? = parser@{ p ->
        if (p.op != 0x8A || p.size < 4 || u(p, 1) != 0x01) return@parser null
        if (u(p, 2) == 2) return@parser Reading(capability, ReadingStatus.ERROR, errorCode = 0, note = "Vòng tay đã dừng đo") to true
        if (u(p, 2) != 1) return@parser null
        when (val st = u(p, 3)) {
            0 -> {
                val progress = if (p.size > 4) u(p, 4) else 0
                val v = VeepooHealth.BloodValues.parseLive(p, 5)
                when {
                    progress < 100 -> touching(capability, progress) to false
                    v != null && v.nonZero -> {
                        val extra = v.extra()
                        val main = if (capability == Capability.URIC_ACID) extra.getValue("uricAcid") else extra.getValue("totalCholesterol")
                        Reading(capability, ReadingStatus.OK, value = main, extra = extra) to true
                    }
                    else -> Reading(capability, ReadingStatus.ERROR, errorCode = -2, note = Reading.NOTE_TOUCH_SENSOR) to true
                }
            }
            2 -> Reading(capability, ReadingStatus.ERROR, errorCode = st, note = "Pin yếu") to true
            1, 3 -> Reading(capability, ReadingStatus.ERROR, errorCode = st, note = "Vòng tay đang bận đo việc khác") to true
            4 -> Reading(capability, ReadingStatus.NOT_WORN, errorCode = st, note = Reading.NOTE_TOUCH_SENSOR) to true
            else -> Reading(capability, ReadingStatus.ERROR, errorCode = st, note = "Đo không hợp lệ") to true
        }
    }

    /** `MEASURING` nhắc đặt ngón tay lên cảm biến, kèm tiến độ 0–100. */
    fun touching(capability: Capability, progress: Int = 0) =
        Reading(capability, ReadingStatus.MEASURING, note = Reading.NOTE_TOUCH_SENSOR,
            extra = mapOf(Reading.EXTRA_PROGRESS to progress.coerceIn(0, 100).toDouble()))

    /** Số gói thành phần cơ thể liền nhau báo "chưa chạm điện cực" trước khi dừng (G Band: 4, `home/viewModel/x.java:68-85`). */
    const val BODY_LEAD_OFF_LIMIT = 4

    /**
     * Thành phần cơ thể `93 04 01 trạng-thái a b …` (`jf/k.java`): trạng thái 0 = đang đo (a = tiến độ), 1 = gói kết quả a/b (thứ tự/tổng,
     * dữ liệu byte 6..19), 2 thất bại, 3 bận, 4 pin yếu; `93 04 02` = đã dừng. Giá trị chính = % mỡ cơ thể, đủ 14 chỉ số trong `extra`
     * ([VeepooHealth.BODY_KEYS]). Vòng tay tính từ hồ sơ `A3` + cảm biến điện cực: khi đang đo byte 5 = 1 ⇒ chưa chạm điện cực
     * (`onDetecting(progress, leadOff)`, `jf/k.java:70-77`) ⇒ `MEASURING` + [Reading.NOTE_TOUCH_SENSOR]; [BODY_LEAD_OFF_LIMIT] gói liền
     * ⇒ `NOT_WORN` + [Reading.NOTE_TOUCH_SENSOR] và dừng, như G Band ("Ensure your finger is on the electrode").
     * GE54 19/10 (không chạm): `93 04 01 00 xx 01` 0→0x64 rồi `93 04 01 02 64 01` = thất bại.
     */
    fun bodyComposition(): (ByteArray) -> Pair<Reading, Boolean>? {
        val parts = mutableListOf<ByteArray>()
        var leadOff = 0
        return parser@{ p ->
            if (p.op != 0x93 || p.size < 3 || u(p, 1) != 0x04) return@parser null
            val c = Capability.BODY_COMPOSITION
            if (u(p, 2) == 2) return@parser Reading(c, ReadingStatus.ERROR, errorCode = 0, note = "Vòng tay đã dừng đo") to true
            if (u(p, 2) != 1 || p.size < 6) return@parser null
            when (val st = u(p, 3)) {
                0 -> {
                    val progress = u(p, 4)
                    leadOff = if (u(p, 5) == 1) leadOff + 1 else 0
                    when {
                        leadOff >= BODY_LEAD_OFF_LIMIT -> Reading(c, ReadingStatus.NOT_WORN, note = Reading.NOTE_TOUCH_SENSOR) to true
                        leadOff > 0 -> touching(c, progress) to false
                        else -> Reading(c, ReadingStatus.MEASURING, extra = mapOf(Reading.EXTRA_PROGRESS to progress.coerceIn(0, 100).toDouble())) to false
                    }
                }
                1 -> {
                    if (u(p, 4) == 1) parts.clear()
                    parts += p
                    if (u(p, 4) < u(p, 5)) return@parser Reading(c, ReadingStatus.MEASURING) to false
                    val extra = VeepooHealth.parseBody(parts)
                    if (extra == null) Reading(c, ReadingStatus.ERROR, errorCode = -2, note = "Gói kết quả không hợp lệ") to true
                    else Reading(c, ReadingStatus.OK, value = extra.getValue("bodyFatRate"), extra = extra) to true
                }
                2 -> Reading(c, ReadingStatus.ERROR, errorCode = st, note = "Đo thất bại, không có kết quả") to true
                3 -> Reading(c, ReadingStatus.ERROR, errorCode = st, note = "Vòng tay đang bận đo việc khác") to true
                4 -> Reading(c, ReadingStatus.ERROR, errorCode = st, note = "Pin yếu") to true
                else -> Reading(c, ReadingStatus.ERROR, errorCode = st) to true
            }
        }
    }
}
