package com.smartwear.gloryfit

import com.smartwear.core.ControlValue
import com.smartwear.core.DeviceControl
import com.smartwear.core.DeviceControl.Kind
import java.time.LocalDate

/**
 * Cài đặt đồng hồ UTE. Đồng hồ không cho đọc lại phần lớn cài đặt (app GloryFit cũng chỉ lưu cục bộ rồi ghi xuống),
 * nên SDK lưu theo thiết bị dưới dạng khoá → số nguyên và gửi lệnh khi người dùng đổi.
 * Khung giờ lưu 2 khoá `<id>.from` / `<id>.to` (phút trong ngày).
 *
 * Định dạng lệnh lấy từ `WriteCommandToBLE` (GloryFit 4.0.12) và SDK Realtek trong GloryFitPro 1.9 (`uterkif.uterkthis`),
 * cờ tính năng theo docs/feature-matrix.md.
 */
class UteSettings(val values: Map<String, Int> = emptyMap()) {
    operator fun get(key: String): Int = values[key] ?: DEFAULTS[key] ?: 0
    fun on(key: String) = this[key] != 0

    /** Ngày bắt đầu kỳ kinh gần nhất (mặc định hôm nay). */
    fun periodStart(today: LocalDate): LocalDate = values["period.start"]?.let { LocalDate.ofEpochDay(it.toLong()) } ?: today

    /** "Cách đây n ngày" được lưu thành ngày tuyệt đối (`period.start`, epoch day) để không trôi theo thời gian. */
    fun with(id: String, value: ControlValue, today: LocalDate = LocalDate.now()): UteSettings = UteSettings(
        values + when (value) {
            is ControlValue.Bool -> mapOf(id to if (value.on) 1 else 0)
            is ControlValue.Number ->
                if (id == "period.daysAgo") mapOf("period.start" to (today.toEpochDay() - value.value).toInt()) else mapOf(id to value.value)
            is ControlValue.TimeRange -> mapOf("$id.from" to value.fromMinute, "$id.to" to value.toMinute)
        },
    )

    /** "k=v;k=v" để lưu SharedPreferences / UserDefaults. */
    fun encode(): String = values.entries.sortedBy { it.key }.joinToString(";") { "${it.key}=${it.value}" }

    companion object {
        fun decode(s: String?): UteSettings = UteSettings(
            s.orEmpty().split(';').mapNotNull { e ->
                val k = e.substringBefore('=', "")
                e.substringAfter('=', "").toIntOrNull()?.takeIf { k.isNotEmpty() }?.let { k to it }
            }.toMap(),
        )

        val DEFAULTS = mapOf(
            "profile.height" to 170, "profile.weight" to 65, "profile.age" to 30, "profile.gender" to 0,
            "display.raise" to 1, "display.screenOff" to 5,
            "unit.hour12" to 0, "unit.fahrenheit" to 0,
            "goal.steps" to 8000, "goal.calories" to 300, "goal.distance" to 3,
            "hr24.enabled" to 1, "hr24.interval" to 5,
            "hrHigh.enabled" to 0, "hrHigh.value" to 160, "hrLow.enabled" to 0, "hrLow.value" to 45,
            "spo2Auto.enabled" to 0, "spo2Auto.interval" to 60,
            "spo2Range.enabled" to 0, "spo2Range.range.from" to 22 * 60, "spo2Range.range.to" to 7 * 60,
            "hr24Range.enabled" to 0, "hr24Range.range.from" to 0, "hr24Range.range.to" to 23 * 60 + 59,
            "raiseRange.enabled" to 0, "raiseRange.range.from" to 8 * 60, "raiseRange.range.to" to 22 * 60,
            "sedentary.enabled" to 0, "sedentary.interval" to 60, "sedentary.range.from" to 9 * 60,
            "sedentary.range.to" to 18 * 60, "sedentary.lunch" to 1,
            "drink.enabled" to 0, "drink.interval" to 60, "drink.range.from" to 8 * 60, "drink.range.to" to 20 * 60,
            "dnd.scheduled" to 0, "dnd.range.from" to 22 * 60, "dnd.range.to" to 7 * 60,
            "dnd.messages" to 1, "dnd.vibration" to 1, "dnd.endCall" to 0,
            "findPhone.enabled" to 1, "language" to 0,
            "period.enabled" to 0, "period.duration" to 5, "period.cycle" to 28,
        )

        /** Ngôn ngữ đồng hồ (`BandLanguagePage.BAND_LANGUAGE_*`); mục 0 = giữ nguyên. */
        val LANGUAGES = listOf(
            "Giữ nguyên" to 0, "Tiếng Việt" to 99, "English" to 2, "中文" to 1, "日本語" to 4, "한국어" to 3,
            "Français" to 7, "Deutsch" to 5, "Español" to 6, "Italiano" to 8, "ไทย" to 21,
        )
    }
}

/**
 * Giá trị đọc từ đồng hồ lúc kết nối (không lưu, không gửi): ngôn ngữ đang dùng (`AF AA`), phím tắt nhanh hỗ trợ / đang bật
 * (`BE 01` / `BE 02`). Null = chưa đọc / đồng hồ không có.
 */
data class UteReadState(val language: Int? = null, val shortcutSupport: Int? = null, val shortcutStatus: Int? = null)

/** Cờ tính năng → mục cài đặt, và mục cài đặt → gói lệnh. */
object UteControls {
    // Nhóm hiển thị
    const val DEVICE = "Thiết bị"
    const val HEALTH = "Theo dõi sức khoẻ"
    const val REMINDERS = "Nhắc nhở"
    const val GOALS = "Mục tiêu hằng ngày"
    const val PROFILE = "Hồ sơ cá nhân"
    const val CYCLE = "Chu kỳ kinh nguyệt"
    const val SHORTCUTS = "Phím tắt trên đồng hồ"
    const val DATA = "Dữ liệu trên đồng hồ"

    private fun Ute.Features.raiseToWake() = has(1, 0x000040)
    private fun Ute.Features.hrHighAlert() = has(1, 0x000080)
    private fun Ute.Features.hrLowAlert() = has(4, 0x000800)
    private fun Ute.Features.dnd() = has(1, 0x000008)
    private fun Ute.Features.sedentary() = has(1, 0x010000)
    private fun Ute.Features.sedentaryRange() = has(2, 0x000010)
    private fun Ute.Features.findPhone() = has(2, 0x000020)
    private fun Ute.Features.drink() = has(5, 0x080000)
    private fun Ute.Features.goals() = has(5, 0x200000)
    private fun Ute.Features.tempUnit() = has(3, 0x001000)
    private fun Ute.Features.period() = has(3, 0x008000)
    /** GloryFitPro (RK) chỉ cần F5 `0x40` (`RkSupportUtils.isSupOxygenSetting`); F9 `0x1000` là điều kiện của SDK cũ. */
    internal fun Ute.Features.spo2Auto() = has(9, 0x001000) || has(5, 0x000040)
    private fun Ute.Features.language() = has(2, 0x000008) || has(3, 0x004000) || has(4, 0x100000)
    /** F3 `0x20` (`isHasReadLanguage`, 33F1 b13.5): đọc được ngôn ngữ đang dùng bằng `AF AA`. */
    fun Ute.Features.readLanguage() = has(3, 0x000020)
    /** F4 `0x10000` (`isHasShortcutButton`, 33F1 b8.0): đọc được phím tắt nhanh `BE 01/02`. */
    fun Ute.Features.shortcuts() = has(4, 0x010000)

    /** Phím tắt nhanh trên đồng hồ (`P/com/yc/gloryfitpro/utils/ShortcutUtils.java:8-17`), bit trong 3 byte đầu của `BE 01/02`. */
    data class Shortcut(val key: String, val title: String, val mask: Int)

    val SHORTCUT_LIST = listOf(
        Shortcut("time", "Chỉnh giờ trên đồng hồ", 0x002000),
        Shortcut("hour24", "Định dạng 24 giờ", 0x004000),
        Shortcut("findWatch", "Tìm đồng hồ", 0x010000),
        Shortcut("raise", "Nâng tay sáng màn", 0x020000),
        Shortcut("sedentary", "Nhắc vận động", 0x040000),
        Shortcut("dnd", "Không làm phiền", 0x080000),
        Shortcut("antiLost", "Chống thất lạc", 0x100000),
        Shortcut("sms", "Báo tin nhắn", 0x200000),
        Shortcut("hr24", "Nhịp tim 24 giờ", 0x400000),
        Shortcut("screenOff", "Thời gian sáng màn", 0x800000),
    )

    /** `AF AA`: hỏi ngôn ngữ đang dùng + 5 mặt nạ ngôn ngữ hiển thị được (`T:1745-1748`). */
    val LANGUAGE_QUERY = byteArrayOf(0xAF.toByte(), 0xAA.toByte())

    /** `AF AA lang …`: byte 2 = mã ngôn ngữ đang dùng (`BAND_LANGUAGE_*`, cùng mã với `AF AB n`) (`P/uterkfor/uterkclass.java:71-104`). */
    fun parseLanguage(p: ByteArray): Int? =
        if (p.size >= 3 && Ute.u(p, 0) == 0xAF && Ute.u(p, 1) == 0xAA) Ute.u(p, 2) else null

    /**
     * Gói `AF AA` 20 byte: 5 mặt nạ 24 bit ngôn ngữ hiển thị được, byte 17..19 = mặt nạ 1, 14..16 = 2 … 5..7 = 5 (cùng cách đọc
     * với `DB AA`, `uterkclass.java:76-97`). Bit → ngôn ngữ (`DeviceLanguageType.IS_DISPLAY_BAND_LANGUAGE_*`) chưa ghép được
     * nhóm nên chỉ trả mặt nạ thô.
     */
    fun parseLanguageMasks(p: ByteArray): IntArray? {
        if (p.size != 20 || parseLanguage(p) == null) return null
        fun be24(i: Int) = (Ute.u(p, i) shl 16) or (Ute.u(p, i + 1) shl 8) or Ute.u(p, i + 2)
        return intArrayOf(be24(17), be24(14), be24(11), be24(8), be24(5))
    }

    /** `BE 01`: phím tắt đồng hồ có; `BE 02`: phím tắt đang bật (`T` `k()` và hàm cùng loại, 33F1). */
    val SHORTCUT_SUPPORT = byteArrayOf(0xBE.toByte(), 0x01)
    val SHORTCUT_STATUS = byteArrayOf(0xBE.toByte(), 0x02)

    /**
     * `BE 01/02 <18 byte>` (`uterkclass.java:46-61`): mặt nạ = 3 byte đầu phần dữ liệu (byte 2..4), như
     * `ShortcutUtils.saveShortcutSupList` / `queryShortcutStatus` (chỉ nhận đúng 18 byte dữ liệu). [sub] = 1 hoặc 2.
     */
    fun parseShortcuts(p: ByteArray, sub: Int): Int? {
        if (p.size != 20 || Ute.u(p, 0) != 0xBE || Ute.u(p, 1) != sub) return null
        return (Ute.u(p, 2) shl 16) or (Ute.u(p, 3) shl 8) or Ute.u(p, 4)
    }

    fun controls(f: Ute.Features, s: UteSettings, today: LocalDate = LocalDate.now(), read: UteReadState = UteReadState()): List<DeviceControl> = buildList {
        fun toggle(id: String, group: String, title: String, detail: String? = null, enabled: Boolean = true) =
            add(DeviceControl(id, group, title, Kind.TOGGLE, ControlValue.Bool(s.on(id)), detail, enabled = enabled))
        fun number(id: String, group: String, title: String, min: Int, max: Int, step: Int, unit: String, enabled: Boolean = true) =
            add(DeviceControl(id, group, title, Kind.NUMBER, ControlValue.Number(s[id]), min = min, max = max, step = step, unit = unit, enabled = enabled))
        fun range(id: String, group: String, title: String, enabled: Boolean = true) =
            add(DeviceControl(id, group, title, Kind.TIME_RANGE, ControlValue.TimeRange(s["$id.from"], s["$id.to"]), enabled = enabled))
        fun choice(id: String, group: String, title: String, options: List<String>, detail: String? = null) =
            add(DeviceControl(id, group, title, Kind.CHOICE, ControlValue.Number(s[id]), detail, options = options))

        add(DeviceControl("find.start", DEVICE, "Tìm đồng hồ", Kind.ACTION, detail = "Đồng hồ rung để bạn tìm"))
        if (f.findPhone()) toggle("findPhone.enabled", DEVICE, "Tìm điện thoại từ đồng hồ", "Điện thoại đổ chuông khi bấm trên đồng hồ")
        if (f.raiseToWake()) {
            toggle("display.raise", DEVICE, "Nâng tay sáng màn hình")
            // `69 AB 01 05` chỉ có trong SDK (GloryFitPro không gọi cho đồng hồ Realtek), chưa kiểm trên Y25.
            toggle("raiseRange.enabled", DEVICE, "Nâng tay sáng màn theo khung giờ", "Chưa kiểm trên Y25", enabled = s.on("display.raise"))
            range("raiseRange.range", DEVICE, "Khung giờ nâng tay sáng màn", enabled = s.on("display.raise") && s.on("raiseRange.enabled"))
        }
        number("display.screenOff", DEVICE, "Thời gian sáng màn hình", 5, 30, 5, "giây")
        toggle("unit.hour12", DEVICE, "Định dạng 12 giờ")
        if (f.tempUnit()) toggle("unit.fahrenheit", DEVICE, "Nhiệt độ theo °F")
        if (f.language()) {
            val current = read.language?.let { code -> UteSettings.LANGUAGES.firstOrNull { it.second == code }?.first ?: "mã $code" }
            choice("language", DEVICE, "Ngôn ngữ đồng hồ", UteSettings.LANGUAGES.map { it.first }, current?.let { "Đồng hồ đang dùng: $it" })
        }

        if (f.heartRate24h) {
            toggle("hr24.enabled", HEALTH, "Đo nhịp tim tự động", "Đồng hồ tự đo theo chu kỳ, cả khi app tắt")
            number("hr24.interval", HEALTH, "Chu kỳ đo nhịp tim", 5, 60, 5, "phút", enabled = s.on("hr24.enabled"))
            toggle("hr24Range.enabled", HEALTH, "Đo nhịp tim tự động theo khung giờ", enabled = s.on("hr24.enabled"))
            range("hr24Range.range", HEALTH, "Khung giờ đo nhịp tim", enabled = s.on("hr24.enabled") && s.on("hr24Range.enabled"))
        }
        if (f.hrHighAlert()) {
            toggle("hrHigh.enabled", HEALTH, "Cảnh báo nhịp tim cao")
            number("hrHigh.value", HEALTH, "Ngưỡng nhịp tim cao", 100, 200, 5, "bpm", enabled = s.on("hrHigh.enabled"))
        }
        if (f.hrLowAlert()) {
            toggle("hrLow.enabled", HEALTH, "Cảnh báo nhịp tim thấp")
            number("hrLow.value", HEALTH, "Ngưỡng nhịp tim thấp", 30, 60, 5, "bpm", enabled = s.on("hrLow.enabled"))
        }
        if (f.spo2Auto()) {
            toggle("spo2Auto.enabled", HEALTH, "Đo SpO2 tự động")
            number("spo2Auto.interval", HEALTH, "Chu kỳ đo SpO2", 10, 240, 10, "phút", enabled = s.on("spo2Auto.enabled"))
            toggle("spo2Range.enabled", HEALTH, "Đo SpO2 tự động theo khung giờ", enabled = s.on("spo2Auto.enabled"))
            range("spo2Range.range", HEALTH, "Khung giờ đo SpO2", enabled = s.on("spo2Auto.enabled") && s.on("spo2Range.enabled"))
        }

        if (f.sedentary()) {
            val on = s.on("sedentary.enabled")
            toggle("sedentary.enabled", REMINDERS, "Nhắc vận động", "Rung khi ngồi lâu")
            number("sedentary.interval", REMINDERS, "Nhắc sau khi ngồi", 30, 180, 15, "phút", enabled = on)
            if (f.sedentaryRange()) {
                range("sedentary.range", REMINDERS, "Khung giờ nhắc vận động", enabled = on)
                toggle("sedentary.lunch", REMINDERS, "Không nhắc giờ nghỉ trưa (12:00–14:00)", enabled = on)
            }
        }
        if (f.drink()) {
            val on = s.on("drink.enabled")
            toggle("drink.enabled", REMINDERS, "Nhắc uống nước")
            number("drink.interval", REMINDERS, "Nhắc mỗi", 30, 240, 15, "phút", enabled = on)
            range("drink.range", REMINDERS, "Khung giờ nhắc uống nước", enabled = on)
        }
        if (f.dnd()) {
            toggle("dnd.scheduled", REMINDERS, "Không làm phiền theo giờ")
            range("dnd.range", REMINDERS, "Khung giờ không làm phiền", enabled = s.on("dnd.scheduled"))
            toggle("dnd.messages", REMINDERS, "Khi không làm phiền: chặn thông báo")
            toggle("dnd.vibration", REMINDERS, "Khi không làm phiền: tắt rung")
        }

        number("goal.steps", GOALS, "Bước chân", 1000, 50_000, 500, "bước")
        if (f.goals()) {
            number("goal.calories", GOALS, "Calo", 50, 3000, 50, "kcal")
            number("goal.distance", GOALS, "Quãng đường", 1, 42, 1, "km")
        }

        choice("profile.gender", PROFILE, "Giới tính", listOf("Nam", "Nữ"))
        number("profile.age", PROFILE, "Tuổi", 5, 100, 1, "tuổi")
        number("profile.height", PROFILE, "Chiều cao", 100, 230, 1, "cm")
        number("profile.weight", PROFILE, "Cân nặng", 20, 200, 1, "kg")

        // Phím tắt nhanh: chỉ đọc (đồng hồ không có lệnh ghi); GloryFitPro ẩn cài đặt trùng phím tắt (`RkSupportUtils.java:226-266`).
        read.shortcutSupport?.let { support ->
            for (k in SHORTCUT_LIST) if (support and k.mask == k.mask) add(
                DeviceControl(
                    "shortcut.${k.mask}", SHORTCUTS, k.title, Kind.TOGGLE,
                    ControlValue.Bool(read.shortcutStatus?.let { it and k.mask == k.mask } ?: false),
                    "Chỉ đọc — đổi bằng phím tắt trên đồng hồ", enabled = false,
                ),
            )
        }

        if (f.readLanguage() || f.shortcuts()) {
            add(DeviceControl("device.read", DATA, "Đọc lại cài đặt từ đồng hồ", Kind.ACTION, detail = "Ngôn ngữ, phím tắt nhanh"))
        }
        if (UteContacts.clearSupported(f)) add(
            DeviceControl(
                "contacts.clear", DATA, "Xoá toàn bộ danh bạ trên đồng hồ", Kind.ACTION,
                confirm = "Xoá toàn bộ danh bạ đã gửi lên đồng hồ? Không hoàn tác được.",
            ),
        )
        add(
            DeviceControl(
                "data.reset", DATA, "Xoá dữ liệu đồng hồ", Kind.ACTION, detail = "Khôi phục cài đặt gốc, xoá dữ liệu sức khoẻ trên đồng hồ",
                confirm = "Xoá toàn bộ dữ liệu và cài đặt trên đồng hồ (khôi phục gốc)? Dữ liệu chưa đồng bộ sẽ mất, không hoàn tác được.",
            ),
        )

        if (f.period()) {
            val on = s.on("period.enabled")
            toggle("period.enabled", CYCLE, "Theo dõi chu kỳ trên đồng hồ")
            val daysAgo = (today.toEpochDay() - s.periodStart(today).toEpochDay()).toInt().coerceAtLeast(0)
            add(DeviceControl("period.daysAgo", CYCLE, "Kỳ gần nhất bắt đầu cách đây", Kind.NUMBER, ControlValue.Number(daysAgo), min = 0, max = 60, unit = "ngày", enabled = on))
            number("period.duration", CYCLE, "Số ngày hành kinh", 2, 15, 1, "ngày", enabled = on)
            number("period.cycle", CYCLE, "Độ dài chu kỳ", 15, 60, 1, "ngày", enabled = on)
        }
    }

    /**
     * Gói lệnh cần gửi khi mục [id] đổi (đã áp vào [s]). [today] dùng cho chu kỳ kinh nguyệt.
     * Mục không cần lệnh (hoặc không hỗ trợ) trả về danh sách rỗng.
     */
    fun commands(id: String, f: Ute.Features, s: UteSettings, today: LocalDate = LocalDate.now()): List<ByteArray> {
        val key = id.substringBefore('.')
        return when {
            key in setOf("profile", "display", "hrHigh", "hrLow") || id == "unit.fahrenheit" -> listOf(userInfo(s))
            id == "goal.steps" -> listOf(userInfo(s)) + if (f.goals()) listOf(target(4, s["goal.steps"], 4)) else emptyList()
            id == "goal.calories" -> listOf(target(3, s["goal.calories"], 2))
            id == "goal.distance" -> listOf(target(5, s["goal.distance"] * 1000, 4))
            id == "unit.hour12" -> listOf(units(s))
            key == "hr24" -> heartRate24h(s)
            key == "spo2Auto" -> listOf(byteArrayOf(0x34, 0x03, b(s["spo2Auto.enabled"]), b(s["spo2Auto.interval"] shr 8), b(s["spo2Auto.interval"])))
            key == "spo2Range" -> listOf(window(0x34, 0x04, "spo2Range", s))
            key == "hr24Range" -> listOf(window(0xF7, 0x0F, "hr24Range", s))
            key == "raiseRange" -> listOf(raiseRange(s))
            key == "sedentary" -> listOf(reminder(0xD3, "sedentary", s, f.sedentaryRange()))
            key == "drink" -> listOf(reminder(0xD4, "drink", s, true))
            key == "dnd" -> listOf(dnd(s))
            key == "findPhone" -> listOf(byteArrayOf(0xD1.toByte(), 0x0A, b(s["findPhone.enabled"])))
            key == "language" -> UteSettings.LANGUAGES.getOrNull(s["language"])?.second?.takeIf { it > 0 }
                ?.let { listOf(byteArrayOf(0xAF.toByte(), 0xAB.toByte(), b(it))) } ?: emptyList()
            key == "period" -> listOf(period(s, today))
            else -> emptyList()
        }
    }

    private fun b(v: Int) = v.toByte()

    /** `A9`: hồ sơ, mục tiêu bước, màn hình, ngưỡng nhịp tim, đơn vị nhiệt. */
    fun userInfo(s: UteSettings) = Ute.userInfo(
        heightCm = s["profile.height"], weightKg = s["profile.weight"], screenOffSec = s["display.screenOff"],
        stepGoal = s["goal.steps"], raiseToWake = s.on("display.raise"), age = s["profile.age"], male = s["profile.gender"] == 0,
        hrHighAlert = if (s.on("hrHigh.enabled")) s["hrHigh.value"] else null,
        hrLowAlert = if (s.on("hrLow.enabled")) s["hrLow.value"] else null,
        fahrenheit = s.on("unit.fahrenheit"),
    )

    /** `A0 unit hour`: unit 1 = mét, hour 1 = 24 giờ, 2 = 12 giờ (`setDeviceUnitHourFormat`). */
    fun units(s: UteSettings) = byteArrayOf(0xA0.toByte(), 0x01, if (s.on("unit.hour12")) 0x02 else 0x01)

    /** `F7 01` + `F7 09 01 mm` khi bật, `F7 02` khi tắt. */
    fun heartRate24h(s: UteSettings): List<ByteArray> =
        if (s.on("hr24.enabled")) listOf(Ute.HR24_ENABLE, Ute.heartRate24hInterval(s["hr24.interval"]))
        else listOf(byteArrayOf(0xF7.toByte(), 0x02))

    /** `3F type en value` (`setTodayTarget`): 4 = bước (u32), 3 = kcal (u16), 5 = mét (u32). */
    fun target(type: Int, value: Int, size: Int): ByteArray =
        byteArrayOf(0x3F, b(type), 0x01) + ByteArray(size) { b(value shr (8 * (size - 1 - it))) }

    /**
     * `D3`/`D4 en interval 02 03 01 00 [fromH fromM toH toM lunch]` (nhắc vận động / uống nước).
     * Phần khung giờ chỉ có khi đồng hồ hỗ trợ (F2 `0x10`); uống nước luôn có.
     */
    fun reminder(op: Int, id: String, s: UteSettings, withRange: Boolean): ByteArray {
        val head = byteArrayOf(b(op), b(s["$id.enabled"]), b(s["$id.interval"]), 0x02, 0x03, 0x01, 0x00)
        if (!withRange) return head
        val from = s["$id.range.from"]
        val to = s["$id.range.to"]
        val lunch = if (op == 0xD3) s["sedentary.lunch"] else 0
        return head + byteArrayOf(b(from / 60), b(from % 60), b(to / 60), b(to % 60), b(lunch))
    }

    /**
     * `D7 mask fromH fromM toH toM timed`: mask = cúp máy·8 + thông báo·4 + rung·2 (SDK Realtek bỏ bit màn hình,
     * `T:4029-4070`). timed = 1: chỉ trong khung giờ. Bit 3 (`dnd.endCall`) = cho phép từ chối cuộc gọi trên đồng hồ
     * (GloryFitPro `CallRemindModelImpl.setEndCallEnable` → `DoNotDisturbInfo.setEndCallSwitch`); app đặt khoá này ở
     * thẻ cuộc gọi, không hiện trong [controls].
     */
    fun dnd(s: UteSettings): ByteArray {
        val mask = (if (s.on("dnd.endCall")) 8 else 0) or (if (s.on("dnd.messages")) 4 else 0) or (if (s.on("dnd.vibration")) 2 else 0)
        val from = s["dnd.range.from"]
        val to = s["dnd.range.to"]
        return byteArrayOf(0xD7.toByte(), b(mask), b(from / 60), b(from % 60), b(to / 60), b(to % 60), b(s["dnd.scheduled"]))
    }

    /**
     * Khung giờ đo tự động `op sub en fromH fromM toH toM`: SpO2 `34 04` (`T:3264-3281` `oxygenTimePeriod`), nhịp tim `F7 0F`
     * (`WriteCommandToBLE.syncRateTimedTestTimePeriod`, `W:720-735`).
     */
    fun window(op: Int, sub: Int, id: String, s: UteSettings): ByteArray {
        val from = s["$id.range.from"]
        val to = s["$id.range.to"]
        return byteArrayOf(b(op), b(sub), b(s["$id.enabled"]), b(from / 60), b(from % 60), b(to / 60), b(to % 60))
    }

    /** Nâng tay sáng màn theo giờ: `69 AB 01 05 sw fromH fromM toH toM` (`P/uterkfor/uterklong.java:109-122` `setBrightScreenParam`). */
    fun raiseRange(s: UteSettings): ByteArray {
        val from = s["raiseRange.range.from"]
        val to = s["raiseRange.range.to"]
        return byteArrayOf(0x69, 0xAB.toByte(), 0x01, 0x05, b(s["raiseRange.enabled"]), b(from / 60), b(from % 60), b(to / 60), b(to % 60))
    }

    /** `29 en YYYY MM DD duration cycle` (`setPhysiologicalPeriod`). */
    fun period(s: UteSettings, today: LocalDate): ByteArray {
        val start = s.periodStart(today)
        return byteArrayOf(
            0x29, b(s["period.enabled"]), b(start.year shr 8), b(start.year), b(start.monthValue), b(start.dayOfMonth),
            b(s["period.duration"]), b(s["period.cycle"]),
        )
    }

    /** `AB 00 00 00 01 02 07 01`: đồng hồ rung để tìm (`findBand(2)`). */
    val FIND_WATCH = byteArrayOf(0xAB.toByte(), 0, 0, 0, 1, 2, 7, 1)
}
