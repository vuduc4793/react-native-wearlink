package com.smartwear.veepoo

import com.smartwear.core.ControlValue
import com.smartwear.core.DeviceControl
import com.smartwear.core.DeviceControl.Kind
import com.smartwear.veepoo.Veepoo.op
import com.smartwear.veepoo.Veepoo.u

/**
 * Cài đặt Veepoo dạng [DeviceControl]. Khác GloryFit, vòng tay Veepoo **đọc lại được** cài đặt: `B8` (công tắc/đơn vị, thiết bị đẩy lúc
 * bắt tay), `E7` (nhắc sức khoẻ), `AC` (cảnh báo nhịp tim), nên giá trị hiển thị lấy từ thiết bị, không lưu cục bộ.
 * Chỉ hiện mục mà thiết bị báo hỗ trợ (byte `B8` ≠ 0, cờ `A7`).
 */
object VeepooControls {
    const val DEVICE = "Thiết bị"
    const val HEALTH = "Theo dõi tự động"
    const val REMINDERS = "Nhắc nhở"
    const val ALERTS = "Cảnh báo"
    const val CALIBRATION = "Hiệu chuẩn"
    const val PROFILE = "Hồ sơ cá nhân"
    const val GOALS = "Mục tiêu hằng ngày"
    const val SYSTEM = "Hệ thống"

    /** Một công tắc trong `B8`: [page]/[index] theo §5.2. */
    data class B8Toggle(val id: String, val group: String, val title: String, val page: Int, val index: Int)

    val B8_TOGGLES = listOf(
        B8Toggle("auto.hr", HEALTH, "Đo nhịp tim tự động (5 phút)", 0, VeepooCustomSettings.AUTO_HR),
        B8Toggle("auto.bp", HEALTH, "Đo huyết áp tự động", 0, VeepooCustomSettings.AUTO_BP),
        B8Toggle("auto.hrv", HEALTH, "Đo HRV tự động", 0, VeepooCustomSettings.AUTO_HRV),
        B8Toggle("auto.temperature", HEALTH, "Đo nhiệt độ tự động", 1, VeepooCustomSettings.AUTO_TEMPERATURE),
        B8Toggle("auto.glucose", HEALTH, "Đo đường huyết tự động", 1, VeepooCustomSettings.AUTO_GLUCOSE),
        B8Toggle("auto.met", HEALTH, "Đo MET tự động", 1, VeepooCustomSettings.AUTO_MET),
        B8Toggle("auto.stress", HEALTH, "Đo stress tự động", 1, VeepooCustomSettings.AUTO_STRESS),
        B8Toggle("auto.bloodComponent", HEALTH, "Đo thành phần máu tự động", 1, 11),
        B8Toggle("auto.ppg", HEALTH, "PPG", 0, VeepooCustomSettings.PPG),
        B8Toggle("alert.spo2Low", ALERTS, "Nhắc SpO2 thấp", 0, VeepooCustomSettings.SPO2_LOW),
        B8Toggle("alert.disconnect", ALERTS, "Nhắc khi mất kết nối", 0, VeepooCustomSettings.DISCONNECT_REMIND),
        B8Toggle("alert.sportEnd", ALERTS, "Nhắc hết buổi tập", 0, VeepooCustomSettings.SPORT_REMIND),
        B8Toggle("alert.fall", ALERTS, "Phát hiện ngã", 1, 14),
        B8Toggle("alert.hrTrend", ALERTS, "Xu hướng nhịp tim bất thường", 1, 15),
        B8Toggle("device.findPhoneUi", DEVICE, "Màn tìm điện thoại", 0, VeepooCustomSettings.FIND_PHONE_UI),
        B8Toggle("device.stopwatch", DEVICE, "Bấm giờ", 0, VeepooCustomSettings.STOPWATCH),
        B8Toggle("device.musicControl", DEVICE, "Điều khiển nhạc", 0, VeepooCustomSettings.MUSIC_CONTROL),
        B8Toggle("device.autoAnswer", DEVICE, "Tự trả lời cuộc gọi", 0, VeepooCustomSettings.AUTO_ANSWER),
        B8Toggle("device.sos", DEVICE, "SOS", 0, VeepooCustomSettings.SOS),
        B8Toggle("device.longPressLock", DEVICE, "Giữ lâu để khoá màn", 1, VeepooCustomSettings.LONG_PRESS_LOCK),
        B8Toggle("device.messageScreenOn", DEVICE, "Sáng màn khi có tin nhắn", 1, VeepooCustomSettings.MESSAGE_SCREEN_ON),
        B8Toggle("device.powerSound", DEVICE, "Âm bật/tắt nguồn", 1, VeepooCustomSettings.POWER_SOUND),
        B8Toggle("device.measureSound", DEVICE, "Âm khi đo", 1, VeepooCustomSettings.MEASURE_SOUND),
    )

    /** Nhắc sức khoẻ `E7` (type: 1 ngồi lâu, 2 uống nước, 3 nhìn xa, 4 vận động, 5 uống thuốc, 6 đọc sách, 7 ra ngoài, 8 rửa tay). */
    data class Remind(val type: Int, val fromMinute: Int, val toMinute: Int, val interval: Int, val on: Boolean)

    val REMIND_TYPES = listOf(
        1 to "Nhắc vận động (ngồi lâu)", 2 to "Nhắc uống nước", 3 to "Nhắc nhìn xa", 4 to "Nhắc tập thể dục", 5 to "Nhắc uống thuốc",
        6 to "Nhắc đọc sách", 7 to "Nhắc ra ngoài", 8 to "Nhắc rửa tay",
    )

    /** type `E7` → kind trong id control `remind.<kind>.enabled|interval|range` (cùng tên trên iOS). */
    val REMIND_KEYS = mapOf(1 to "sedentary", 2 to "drink", 3 to "longView", 4 to "exercise", 5 to "medication", 6 to "book", 7 to "travel", 8 to "handWash")

    /**
     * type `E7` của một id control: `remind.<kind>.<trường>`; nhận cả id cũ `sedentary.*` / `drink.*` (trước 19/10/2026). Null nếu không phải.
     */
    fun remindTypeOf(id: String): Int? {
        val kind = if (id.startsWith("remind.")) id.removePrefix("remind.").substringBefore('.') else id.substringBefore('.').takeIf { it == "sedentary" || it == "drink" }
        return REMIND_KEYS.entries.firstOrNull { it.value == kind }?.key
    }

    /** `E7 02 type` (20 byte) đọc một loại nhắc (`jf/t0.java:120-131`). */
    fun remindRead(type: Int) = Veepoo.padded(20, 0xE7, 0x02, type)

    /** `E7 01 type sh sm eh em interval status` (20 byte, `jf/t0.java:133-152`); status 1 bật / 0 tắt. */
    fun remindWrite(r: Remind) = Veepoo.padded(
        20, 0xE7, 0x01, r.type, r.fromMinute / 60, r.fromMinute % 60, r.toMinute / 60, r.toMinute % 60, r.interval.coerceIn(1, 255), if (r.on) 1 else 0,
    )

    /**
     * Phản hồi `E7 02 ok type sh sm eh em interval status idx total` (đọc) / `E7 01 ok …` (ghi) (`jf/t0.java:24-78`).
     * ok = 0 ⇒ lỗi; `E7 00` = không hỗ trợ.
     */
    fun parseRemind(p: ByteArray): Remind? {
        if (p.op != 0xE7 || p.size < 10 || (u(p, 1) != 1 && u(p, 1) != 2) || u(p, 2) != 1) return null
        return Remind(u(p, 3), u(p, 4) * 60 + u(p, 5), u(p, 6) * 60 + u(p, 7), u(p, 8), u(p, 9) == 1)
    }

    /** Cảnh báo nhịp tim kiểu cũ (`jf/r0.java`): ghi `AC cao thấp bật` (4 byte), đọc `AC 00 00 02`. */
    data class HeartAlarm(val high: Int, val low: Int, val on: Boolean)

    val HEART_ALARM_READ = Veepoo.bytes(0xAC, 0x00, 0x00, 0x02)
    fun heartAlarmWrite(a: HeartAlarm) = Veepoo.bytes(0xAC, a.high.coerceIn(60, 220), a.low.coerceIn(30, 120), if (a.on) 1 else 0)

    /** Phản hồi `AC cao thấp ok thao-tác bật` (`r0.java:120-135`): ok = 1 thành công, 0x10 = không hỗ trợ. */
    fun parseHeartAlarm(p: ByteArray): HeartAlarm? {
        if (p.op != 0xAC || p.size < 6 || u(p, 3) != 1) return null
        return HeartAlarm(u(p, 1), u(p, 2), u(p, 5) == 1)
    }

    /** Ngôn ngữ `F4 code code2 00 flag` (`jf/w0.java:317-730`); code2 = code, flag 0 với zh, 1 với ngôn ngữ khác. */
    val LANGUAGES = listOf("Tiếng Việt" to 10, "English" to 2, "中文" to 1, "日本語" to 3, "한국어" to 4, "Deutsch" to 5, "Русский" to 6,
        "Español" to 7, "Italiano" to 8, "Français" to 9, "Português" to 11, "ไทย" to 13)

    fun language(code: Int) = Veepoo.bytes(0xF4, code, code, 0x00, if (code == 1) 0 else 1)

    /** Dựng danh sách mục theo thiết bị. */
    /** Cài đặt đọc từ vòng tay / lưu cục bộ dùng để dựng các nhóm Hiệu chuẩn, Hồ sơ, Mục tiêu. */
    data class Extra(
        val bp: VeepooHealth.BpCalibration? = null,
        val glucose: VeepooHealth.GlucoseCalibration? = null,
        val blood: VeepooHealth.BloodCalibration? = null,
        val profile: VeepooHealth.Profile? = null,
    )

    fun controls(
        f: VeepooFeatures,
        b8: VeepooCustomSettings,
        reminds: Map<Int, Remind>,
        heartAlarm: HeartAlarm?,
        language: Int?,
        extra: Extra = Extra(),
    ): List<DeviceControl> = buildList {
        add(DeviceControl("find.start", DEVICE, "Tìm vòng tay (rung)", Kind.ACTION, enabled = f.findDeviceByPhone))
        add(DeviceControl("device.read", DEVICE, "Đọc lại cài đặt từ vòng tay", Kind.ACTION))
        if (b8.supported(0, VeepooCustomSettings.HOUR)) add(DeviceControl("unit.hour24", DEVICE, "Định dạng 24 giờ", Kind.TOGGLE, ControlValue.Bool(b8.is24h)))
        if (b8.supported(0, VeepooCustomSettings.UNITS)) add(
            DeviceControl("unit.system", DEVICE, "Đơn vị", Kind.CHOICE, ControlValue.Number(if (b8.metric) 0 else 1), options = listOf("Mét (km, kg)", "Anh (dặm, lb)")),
        )
        if (b8.supported(1, VeepooCustomSettings.TEMPERATURE_UNIT)) add(
            DeviceControl("unit.temperature", DEVICE, "Đơn vị nhiệt độ", Kind.CHOICE,
                ControlValue.Number(if (b8.get(1, VeepooCustomSettings.TEMPERATURE_UNIT) == 2) 1 else 0), options = listOf("°C", "°F")),
        )
        // Vòng tay không màn (A7 gói 5 byte 4 = 1, như GE54) không có chữ để đổi ngôn ngữ.
        if (f.screenShape != 1 && f.pages.isNotEmpty()) add(
            DeviceControl("language", DEVICE, "Ngôn ngữ", Kind.CHOICE,
                ControlValue.Number(LANGUAGES.indexOfFirst { it.second == language }.coerceAtLeast(0)), options = LANGUAGES.map { it.first }),
        )
        for (t in B8_TOGGLES) {
            if (!b8.supported(t.page, t.index)) continue
            add(DeviceControl(t.id, t.group, t.title, Kind.TOGGLE, ControlValue.Bool(b8.on(t.page, t.index))))
        }
        if (f.healthRemind) for ((type, title) in REMIND_TYPES) {
            val key = "remind." + REMIND_KEYS.getValue(type)
            val r = reminds[type] ?: continue
            add(DeviceControl("$key.enabled", REMINDERS, title, Kind.TOGGLE, ControlValue.Bool(r.on)))
            add(DeviceControl("$key.interval", REMINDERS, "Chu kỳ nhắc", Kind.NUMBER, ControlValue.Number(r.interval), min = 15, max = 240, step = 15, unit = "phút", enabled = r.on))
            add(DeviceControl("$key.range", REMINDERS, "Khung giờ nhắc", Kind.TIME_RANGE, ControlValue.TimeRange(r.fromMinute, r.toMinute), enabled = r.on))
        }
        if (f.heartRateAlarm && heartAlarm != null) {
            add(DeviceControl("hrAlarm.enabled", ALERTS, "Cảnh báo nhịp tim", Kind.TOGGLE, ControlValue.Bool(heartAlarm.on)))
            add(DeviceControl("hrAlarm.high", ALERTS, "Ngưỡng cao", Kind.NUMBER, ControlValue.Number(heartAlarm.high), min = 100, max = 200, step = 5, unit = "bpm", enabled = heartAlarm.on))
            add(DeviceControl("hrAlarm.low", ALERTS, "Ngưỡng thấp", Kind.NUMBER, ControlValue.Number(heartAlarm.low), min = 30, max = 70, step = 5, unit = "bpm", enabled = heartAlarm.on))
        }
        addAll(calibrationControls(f, extra))
        extra.profile?.let { p ->
            add(DeviceControl("profile.height", PROFILE, "Chiều cao", Kind.NUMBER, ControlValue.Number(p.heightCm), min = 100, max = 230, unit = "cm"))
            add(DeviceControl("profile.weight", PROFILE, "Cân nặng", Kind.NUMBER, ControlValue.Number(p.weightKg), min = 20, max = 200, unit = "kg"))
            add(DeviceControl("profile.age", PROFILE, "Tuổi", Kind.NUMBER, ControlValue.Number(p.age), min = 5, max = 100, unit = "tuổi"))
            add(DeviceControl("profile.gender", PROFILE, "Giới tính", Kind.CHOICE, ControlValue.Number(if (p.female) 1 else 0), options = listOf("Nam", "Nữ")))
            add(DeviceControl("goal.steps", GOALS, "Mục tiêu bước", Kind.NUMBER, ControlValue.Number(p.stepGoal), min = 1000, max = 50000, step = 500, unit = "bước"))
            add(DeviceControl("goal.sleep", GOALS, "Mục tiêu ngủ", Kind.NUMBER, ControlValue.Number(p.sleepMinutes / 60), min = 4, max = 12, unit = "giờ"))
        }
        // G Band chỉ hiện "Power off" cho thiết bị không màn (A7 gói 5 byte 4 = 1), như iOS.
        if (f.screenShape == 1) add(DeviceControl("device.powerOff", SYSTEM, "Tắt vòng tay", Kind.ACTION,
            confirm = "Tắt nguồn vòng tay? Muốn bật lại phải cắm sạc hoặc giữ nút trên vòng tay."))
        add(DeviceControl("data.reset", SYSTEM, "Khôi phục cài đặt gốc", Kind.ACTION,
            confirm = "Khôi phục cài đặt gốc? Vòng tay xoá toàn bộ dữ liệu và cài đặt, không hoàn tác được."))
    }

    /**
     * Nhóm "Hiệu chuẩn" (chỉ hiện mục vòng tay đã trả lời khi đọc): `calibrate.bp.*` (mmHg), `calibrate.glucose.*` (×0,01 mmol/L; nhiều điểm:
     * `<bữa>Before`/`<bữa>After` + khung giờ `<bữa>Time`, bữa ∈ breakfast/lunch/dinner), `calibrate.bloodComponent.*` (acid uric ×0,1 μmol/L,
     * mỡ máu ×0,01 mmol/L). Giá trị là số nguyên đúng như trên dây để ghi lại không mất chữ số.
     */
    fun calibrationControls(f: VeepooFeatures, e: Extra): List<DeviceControl> = buildList {
        val g = CALIBRATION
        if (f.bloodPressure) e.bp?.let { bp ->
            add(DeviceControl("calibrate.bp.enabled", g, "Hiệu chuẩn huyết áp (chế độ riêng)", Kind.TOGGLE, ControlValue.Bool(bp.enabled)))
            add(DeviceControl("calibrate.bp.systolic", g, "Tâm thu gốc", Kind.NUMBER, ControlValue.Number(bp.systolic), min = 80, max = 200, unit = "mmHg", enabled = bp.enabled))
            add(DeviceControl("calibrate.bp.diastolic", g, "Tâm trương gốc", Kind.NUMBER, ControlValue.Number(bp.diastolic), min = 40, max = 130, unit = "mmHg", enabled = bp.enabled))
        }
        val unitGlucose = "×0,01 mmol/L"
        if (f.glucoseCalibrationSingle || f.glucoseCalibrationMulti) e.glucose?.let { gc ->
            add(DeviceControl("calibrate.glucose.enabled", g, "Hiệu chuẩn đường huyết", Kind.TOGGLE, ControlValue.Bool(gc.enabled)))
            if (f.glucoseCalibrationMulti) {
                gc.meals.take(3).forEachIndexed { i, m ->
                    val meal = MEALS[i]
                    val title = MEAL_TITLES[i]
                    add(DeviceControl("calibrate.glucose.${meal}Time", g, "$title: giờ trước / sau ăn", Kind.TIME_RANGE, ControlValue.TimeRange(m.beforeMinute, m.afterMinute), enabled = gc.enabled))
                    add(DeviceControl("calibrate.glucose.${meal}Before", g, "$title: trước ăn", Kind.NUMBER, ControlValue.Number(m.before100), min = 0, max = 3000, step = 10, unit = unitGlucose, enabled = gc.enabled))
                    add(DeviceControl("calibrate.glucose.${meal}After", g, "$title: sau ăn", Kind.NUMBER, ControlValue.Number(m.after100), min = 0, max = 3000, step = 10, unit = unitGlucose, enabled = gc.enabled))
                }
            } else {
                add(DeviceControl("calibrate.glucose.value", g, "Đường huyết gốc", Kind.NUMBER, ControlValue.Number(gc.value100), min = 200, max = 3000, step = 10, unit = unitGlucose, enabled = gc.enabled))
            }
        }
        if (f.bloodComponentCalibration) e.blood?.let { bc ->
            val v = bc.values
            add(DeviceControl("calibrate.bloodComponent.enabled", g, "Hiệu chuẩn thành phần máu", Kind.TOGGLE, ControlValue.Bool(bc.enabled)))
            add(DeviceControl("calibrate.bloodComponent.uricAcid", g, "Acid uric gốc", Kind.NUMBER, ControlValue.Number(v.uricAcid10), min = 0, max = 9000, step = 10, unit = "×0,1 μmol/L", enabled = bc.enabled))
            for ((key, title, value) in listOf(
                Triple("totalCholesterol", "Cholesterol toàn phần gốc", v.cholesterol100), Triple("triglycerides", "Triglycerid gốc", v.triglycerides100),
                Triple("hdl", "HDL gốc", v.hdl100), Triple("ldl", "LDL gốc", v.ldl100),
            )) add(DeviceControl("calibrate.bloodComponent.$key", g, title, Kind.NUMBER, ControlValue.Number(value), min = 0, max = 3000, step = 10, unit = unitGlucose, enabled = bc.enabled))
        }
    }

    val MEALS = listOf("breakfast", "lunch", "dinner")
    private val MEAL_TITLES = listOf("Bữa sáng", "Bữa trưa", "Bữa tối")

    /** Áp một control `calibrate.*` lên giá trị hiện tại; null nếu id không thuộc nhóm hiệu chuẩn. Ném lỗi nếu id lạ. */
    fun applyCalibration(id: String, value: ControlValue, e: Extra): Extra? {
        if (!id.startsWith("calibrate.")) return null
        fun num() = (value as ControlValue.Number).value
        fun on() = (value as ControlValue.Bool).on
        val parts = id.split('.')
        return when (parts.getOrNull(1)) {
            "bp" -> {
                val cur = e.bp ?: VeepooHealth.BpCalibration(false, 120, 80)
                e.copy(bp = when (parts.getOrNull(2)) {
                    "enabled" -> cur.copy(enabled = on())
                    "systolic" -> cur.copy(systolic = num())
                    "diastolic" -> cur.copy(diastolic = num())
                    else -> throw IllegalArgumentException("Không có mục $id")
                })
            }
            "glucose" -> {
                val cur = e.glucose ?: VeepooHealth.GlucoseCalibration(false)
                val field = parts.getOrNull(2).orEmpty()
                val meals = (cur.meals + List(3) { VeepooHealth.Meal(0, 0, 0, 0) }).take(3).toMutableList()
                val meal = MEALS.indexOfFirst { field.startsWith(it) }
                e.copy(glucose = when {
                    field == "enabled" -> cur.copy(enabled = on())
                    field == "value" -> cur.copy(value100 = num())
                    meal >= 0 -> {
                        val m = meals[meal]
                        meals[meal] = when (field.removePrefix(MEALS[meal])) {
                            "Time" -> (value as ControlValue.TimeRange).let { m.copy(beforeMinute = it.fromMinute, afterMinute = it.toMinute) }
                            "Before" -> m.copy(before100 = num())
                            "After" -> m.copy(after100 = num())
                            else -> throw IllegalArgumentException("Không có mục $id")
                        }
                        cur.copy(meals = meals)
                    }
                    else -> throw IllegalArgumentException("Không có mục $id")
                })
            }
            "bloodComponent" -> {
                val cur = e.blood ?: VeepooHealth.BloodCalibration(false, VeepooHealth.BloodValues(0, 0, 0, 0, 0))
                val v = cur.values
                e.copy(blood = when (parts.getOrNull(2)) {
                    "enabled" -> cur.copy(enabled = on())
                    "uricAcid" -> cur.copy(values = v.copy(uricAcid10 = num()))
                    "totalCholesterol" -> cur.copy(values = v.copy(cholesterol100 = num()))
                    "triglycerides" -> cur.copy(values = v.copy(triglycerides100 = num()))
                    "hdl" -> cur.copy(values = v.copy(hdl100 = num()))
                    "ldl" -> cur.copy(values = v.copy(ldl100 = num()))
                    else -> throw IllegalArgumentException("Không có mục $id")
                })
            }
            else -> throw IllegalArgumentException("Không có mục $id")
        }
    }

    /** Gói ghi cho phần hiệu chuẩn mà control [id] thuộc về (đọc từ [e] đã áp thay đổi). */
    fun calibrationPackets(id: String, f: VeepooFeatures, e: Extra): List<ByteArray> = when (id.split('.').getOrNull(1)) {
        "bp" -> listOf(VeepooHealth.bpCalibrationWrite(e.bp!!))
        "glucose" -> e.glucose!!.let { if (f.glucoseCalibrationMulti) VeepooHealth.glucoseMultiWrite(it) else listOf(VeepooHealth.glucoseCalibrationWrite(it.value100, it.enabled)) }
        "bloodComponent" -> listOf(VeepooHealth.bloodCalibrationWrite(e.blood!!))
        else -> emptyList()
    }

    /** Áp control `profile.*` / `goal.*` lên hồ sơ; null nếu không thuộc nhóm này. */
    fun applyProfile(id: String, value: ControlValue, p: VeepooHealth.Profile): VeepooHealth.Profile? {
        val n = (value as? ControlValue.Number)?.value ?: return null
        return when (id) {
            "profile.height" -> p.copy(heightCm = n)
            "profile.weight" -> p.copy(weightKg = n)
            "profile.age" -> p.copy(age = n)
            "profile.gender" -> p.copy(female = n == 1)
            "goal.steps" -> p.copy(stepGoal = n)
            "goal.sleep" -> p.copy(sleepMinutes = n * 60)
            else -> null
        }
    }

    /** Gói `B8` cho một control `B8` (giữ nguyên byte khác); null nếu id không thuộc `B8`. Trả cặp (trang, chỉ số, giá trị). */
    fun b8Change(id: String, value: ControlValue): Triple<Int, Int, Int>? {
        B8_TOGGLES.firstOrNull { it.id == id }?.let { t ->
            return Triple(t.page, t.index, if ((value as? ControlValue.Bool)?.on == true) 1 else 2)
        }
        return when (id) {
            "unit.hour24" -> Triple(0, VeepooCustomSettings.HOUR, if ((value as? ControlValue.Bool)?.on == true) 1 else 2)
            "unit.system" -> Triple(0, VeepooCustomSettings.UNITS, if ((value as? ControlValue.Number)?.value == 1) 2 else 1)
            "unit.temperature" -> Triple(1, VeepooCustomSettings.TEMPERATURE_UNIT, if ((value as? ControlValue.Number)?.value == 1) 2 else 1)
            else -> null
        }
    }
}
