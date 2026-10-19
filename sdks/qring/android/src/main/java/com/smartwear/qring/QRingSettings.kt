package com.smartwear.qring

import com.smartwear.core.ControlValue
import com.smartwear.core.DeviceControl
import com.smartwear.core.DeviceControl.Kind
import com.smartwear.qring.protocol.Packet

/**
 * Cài đặt QRing (sdks/qring/docs/02-commands.md §4.6–4.11). Khác UTE, phần lớn mục đọc lại được từ thiết bị
 * (`xx 01`), nên driver đọc khi kết nối rồi ghi đúng các byte không đổi (ngưỡng, cờ…) như đã đọc.
 * Giá trị lưu dạng khoá → số nguyên; khung giờ là `<id>.from` / `<id>.to` (phút trong ngày).
 */
object QRingSettings {
    const val DEVICE = "Thiết bị"
    const val HEALTH = "Theo dõi sức khoẻ"
    const val REMINDERS = "Nhắc nhở"
    const val GOALS = "Mục tiêu hằng ngày"
    const val PROFILE = "Hồ sơ cá nhân"

    val DEFAULTS = mapOf(
        "hrAuto.enabled" to 1, "hrAuto.interval" to 30, "hrAuto.start" to 5,
        "spo2Auto.enabled" to 0, "stressAuto.enabled" to 0, "hrvAuto.enabled" to 0, "hrvAuto.code" to 30,
        "tempAuto.enabled" to 0, "tempAuto.interval" to 30, "tempAuto.start" to 5, "tempAuto.remind" to 10,
        "goal.steps" to 8000, "goal.calories" to 300, "goal.distance" to 5, "goal.exercise" to 30, "goal.sleep" to 480,
        "profile.hour12" to 0, "profile.imperial" to 0, "profile.gender" to 0, "profile.age" to 30,
        "profile.height" to 170, "profile.weight" to 65, "profile.warn" to 0, "profile.open" to 0,
        "dnd.enabled" to 0, "dnd.range.from" to 22 * 60, "dnd.range.to" to 7 * 60,
        "display.raise" to 1, "display.left" to 1,
        "sedentary.enabled" to 0, "sedentary.interval" to 60, "sedentary.range.from" to 9 * 60, "sedentary.range.to" to 18 * 60,
    )

    fun value(v: Map<String, Int>, key: String) = v[key] ?: DEFAULTS[key] ?: 0

    /**
     * Lệnh đọc cài đặt, phản hồi đưa vào [parse]. [ring]: nhẫn (không màn hình, không có DND / nâng tay / nhắc ngồi).
     * R09 không bật cờ `noScreen`, nên driver truyền theo loại thiết bị.
     */
    fun reads(caps: QRingCapabilities, ring: Boolean): List<Packet> = buildList {
        add(Packet.of(0x16, 1))
        if (caps.spo2) add(Packet.of(0x2C, 1))
        if (caps.stress) add(Packet.of(0x36, 1))
        if (caps.hrv) add(Packet.of(0x38, 1, 0, 0, 0, 0, 0, 0))
        if (caps.temperature) add(Packet.of(0x3A, 3, 1))
        add(Packet.of(0x21, 1))
        add(Packet.of(0x0A, 1))
        if (!ring) {
            add(Packet.of(0x06, 1))
            add(Packet.of(0x05, 1))
            add(Packet.of(0x26))
        }
    }

    private fun le(p: IntArray, i: Int, n: Int) = (0 until n).sumOf { p[i + it] shl (8 * it) }
    private fun fromBcd(v: Int) = (v shr 4) * 10 + (v and 0x0F)
    private fun bcd(v: Int) = ((v / 10) shl 4) or (v % 10)

    /** Giải mã phản hồi đọc [command] (payload 14 byte) thành các giá trị. */
    fun parse(command: Int, p: IntArray): Map<String, Int> = when (command) {
        0x16 -> if (p[0] != 1) emptyMap() else mapOf(
            "hrAuto.enabled" to (if (p[1] == 1) 1 else 0), "hrAuto.interval" to p[2], "hrAuto.start" to (p[3].takeIf { it > 0 } ?: 5),
            "hrAuto.low" to p[4], "hrAuto.high" to p[5], "hrAuto.switch" to p[6],
        )
        0x2C -> mapOf("spo2Auto.enabled" to (if (p[1] == 1) 1 else 0), "spo2Auto.interval" to p[2])
        0x36 -> mapOf("stressAuto.enabled" to (if (p[1] == 1) 1 else 0))
        0x38 -> mapOf("hrvAuto.enabled" to (if (p[1] == 1) 1 else 0), "hrvAuto.code" to (p[3].takeIf { it > 0 } ?: 30))
        0x3A -> if (p[0] != 3) emptyMap() else mapOf(
            "tempAuto.enabled" to (if (p[2] == 1) 1 else 0), "tempAuto.interval" to p[3], "tempAuto.start" to p[4],
            "tempAuto.remind" to p[5], "tempAuto.flags" to p[6], "tempAuto.custom" to p[7],
        )
        0x21 -> mapOf(
            "goal.steps" to le(p, 1, 3), "goal.calories" to le(p, 4, 3) / 1000, "goal.distance" to le(p, 7, 3) / 1000,
            "goal.exercise" to le(p, 10, 2), "goal.sleep" to le(p, 12, 2),
        ).filterValues { it > 0 }
        0x0A -> mapOf(
            "profile.hour12" to p[1], "profile.imperial" to p[2], "profile.gender" to p[3], "profile.age" to p[4],
            "profile.height" to p[5], "profile.weight" to p[6], "profile.warn" to p[9], "profile.open" to p[10],
        ).filter { (k, v) -> v > 0 || k in setOf("profile.hour12", "profile.imperial", "profile.gender", "profile.warn", "profile.open") }
        0x06 -> mapOf(
            "dnd.enabled" to (if (p[1] == 1) 1 else 0), "dnd.range.from" to p[2] * 60 + p[3], "dnd.range.to" to p[4] * 60 + p[5],
        )
        0x05 -> mapOf("display.raise" to (if (p[1] == 1) 1 else 0), "display.left" to (if (p[2] and 1 != 0) 1 else 0))
        0x26 -> mapOf(
            "sedentary.enabled" to (if (p[4] != 0) 1 else 0),
            "sedentary.range.from" to fromBcd(p[0]) * 60 + fromBcd(p[1]), "sedentary.range.to" to fromBcd(p[2]) * 60 + fromBcd(p[3]),
            "sedentary.interval" to (p[5].takeIf { it in setOf(30, 60, 90) } ?: 60),
        )
        else -> emptyMap()
    }

    fun controls(caps: QRingCapabilities, v: Map<String, Int>, ring: Boolean): List<DeviceControl> = buildList {
        fun on(k: String) = value(v, k) != 0
        fun toggle(id: String, group: String, title: String, detail: String? = null, enabled: Boolean = true) =
            add(DeviceControl(id, group, title, Kind.TOGGLE, ControlValue.Bool(on(id)), detail, enabled = enabled))
        fun number(id: String, group: String, title: String, min: Int, max: Int, step: Int, unit: String, enabled: Boolean = true) =
            add(DeviceControl(id, group, title, Kind.NUMBER, ControlValue.Number(value(v, id)), min = min, max = max, step = step, unit = unit, enabled = enabled))
        fun range(id: String, group: String, title: String, enabled: Boolean = true) =
            add(DeviceControl(id, group, title, Kind.TIME_RANGE, ControlValue.TimeRange(value(v, "$id.from"), value(v, "$id.to")), enabled = enabled))

        add(DeviceControl("find.start", DEVICE, if (ring) "Tìm nhẫn" else "Tìm vòng", Kind.ACTION, detail = "Thiết bị rung để bạn tìm"))
        if (!ring) toggle("display.raise", DEVICE, "Nâng tay sáng màn hình")
        toggle("profile.hour12", DEVICE, "Định dạng 12 giờ")
        toggle("profile.imperial", DEVICE, "Đơn vị Anh (dặm, pound)")

        toggle("hrAuto.enabled", HEALTH, "Đo nhịp tim tự động")
        number("hrAuto.interval", HEALTH, "Chu kỳ đo nhịp tim", 5, 60, 5, "phút", enabled = on("hrAuto.enabled"))
        if (caps.spo2) toggle("spo2Auto.enabled", HEALTH, "Đo SpO2 tự động")
        if (caps.stress) toggle("stressAuto.enabled", HEALTH, "Đo căng thẳng tự động")
        if (caps.hrv) toggle("hrvAuto.enabled", HEALTH, "Đo HRV tự động")
        if (caps.temperature) toggle("tempAuto.enabled", HEALTH, "Đo nhiệt độ tự động")

        if (!ring) {
            val sit = on("sedentary.enabled")
            toggle("sedentary.enabled", REMINDERS, "Nhắc vận động", "Rung khi ngồi lâu")
            add(DeviceControl("sedentary.interval", REMINDERS, "Nhắc sau khi ngồi", Kind.CHOICE,
                ControlValue.Number(listOf(30, 60, 90).indexOf(value(v, "sedentary.interval")).coerceAtLeast(0)),
                options = listOf("30 phút", "60 phút", "90 phút"), enabled = sit))
            range("sedentary.range", REMINDERS, "Khung giờ nhắc vận động", enabled = sit)
            toggle("dnd.enabled", REMINDERS, "Không làm phiền theo giờ")
            range("dnd.range", REMINDERS, "Khung giờ không làm phiền", enabled = on("dnd.enabled"))
        }

        number("goal.steps", GOALS, "Bước chân", 1000, 50_000, 500, "bước")
        number("goal.calories", GOALS, "Calo", 50, 3000, 50, "kcal")
        number("goal.distance", GOALS, "Quãng đường", 1, 42, 1, "km")
        number("goal.exercise", GOALS, "Thời gian vận động", 10, 300, 10, "phút")
        number("goal.sleep", GOALS, "Giấc ngủ", 240, 720, 30, "phút")

        add(DeviceControl("profile.gender", PROFILE, "Giới tính", Kind.CHOICE, ControlValue.Number(value(v, "profile.gender")), options = listOf("Nam", "Nữ")))
        number("profile.age", PROFILE, "Tuổi", 5, 100, 1, "tuổi")
        number("profile.height", PROFILE, "Chiều cao", 100, 230, 1, "cm")
        number("profile.weight", PROFILE, "Cân nặng", 20, 200, 1, "kg")
    }

    /** Áp thay đổi của mục [id] vào bảng giá trị. CHOICE chu kỳ nhắc ngồi lưu số phút. */
    fun apply(v: Map<String, Int>, id: String, value: ControlValue): Map<String, Int> = v + when (value) {
        is ControlValue.Bool -> mapOf(id to if (value.on) 1 else 0)
        is ControlValue.Number -> mapOf(id to if (id == "sedentary.interval") listOf(30, 60, 90).getOrElse(value.value) { 60 } else value.value)
        is ControlValue.TimeRange -> mapOf("$id.from" to value.fromMinute, "$id.to" to value.toMinute)
    }

    private fun le(value: Int, n: Int) = IntArray(n) { (value shr (8 * it)) and 0xFF }

    /** Gói ghi cho mục [id] (đã áp vào [v]); null nếu mục không cần lệnh. */
    fun write(id: String, v: Map<String, Int>): Packet? {
        fun g(k: String) = value(v, k)
        return when (id.substringBefore('.')) {
            "find" -> FIND
            "hrAuto" -> Packet.of(0x16, 2, if (g("hrAuto.enabled") != 0) 1 else 2, g("hrAuto.interval"), g("hrAuto.start"),
                g("hrAuto.low"), g("hrAuto.high"), g("hrAuto.switch"))
            "spo2Auto" -> if (g("spo2Auto.interval") > 0) Packet.of(0x2C, 2, g("spo2Auto.enabled"), g("spo2Auto.interval"))
                else Packet.of(0x2C, 2, g("spo2Auto.enabled"))
            "stressAuto" -> Packet.of(0x36, 2, g("stressAuto.enabled"))
            "hrvAuto" -> Packet.of(0x38, 2, g("hrvAuto.enabled"), 0x0A, g("hrvAuto.code"), 0, 0, 0)
            "tempAuto" -> Packet.of(0x3A, 3, 2, g("tempAuto.enabled"), g("tempAuto.interval"), g("tempAuto.start"),
                g("tempAuto.remind"), g("tempAuto.flags"), g("tempAuto.custom"))
            // Calo gửi theo cal, quãng đường theo mét (`GoalSettingViewModel`: ×1000), phút u16 LE.
            "goal" -> Packet.of(0x21, *(intArrayOf(2) + le(g("goal.steps"), 3) + le(g("goal.calories") * 1000, 3) +
                le(g("goal.distance") * 1000, 3) + le(g("goal.exercise"), 2) + le(g("goal.sleep"), 2)))
            "profile" -> Packet.of(0x0A, 2, g("profile.hour12"), g("profile.imperial"), g("profile.gender"), g("profile.age"),
                g("profile.height"), g("profile.weight"), 120, 90, g("profile.warn"), g("profile.open"))
            "dnd" -> Packet.of(0x06, 2, if (g("dnd.enabled") != 0) 1 else 2,
                g("dnd.range.from") / 60, g("dnd.range.from") % 60, g("dnd.range.to") / 60, g("dnd.range.to") % 60)
            "display" -> Packet.of(0x05, 2, if (g("display.raise") != 0) 1 else 2, if (g("display.left") != 0) 1 else 2)
            "sedentary" -> Packet.of(0x25, bcd(g("sedentary.range.from") / 60), bcd(g("sedentary.range.from") % 60),
                bcd(g("sedentary.range.to") / 60), bcd(g("sedentary.range.to") % 60),
                if (g("sedentary.enabled") != 0) 0x7F else 0, g("sedentary.interval"))
            else -> null
        }
    }

    /** `50 55 AA`: thiết bị rung (`FindDeviceReq`). */
    val FIND: Packet = Packet.of(0x50, 0x55, 0xAA)
}
