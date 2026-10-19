package com.smartwear.qring

import com.smartwear.core.Capability

/**
 * Giải mã hai bảng khả năng QRing: phản hồi SetTime (0x01) và DeviceSupport (0x3C).
 * Tham số là 14 byte payload (byte 1..14 của gói), nên `p[i]` khớp với ký hiệu trong
 * sdks/qring/docs/01-connection.md §4.2 và 02-commands.md §4.4.
 */
class QRingCapabilities(timeCaps: ByteArray, supportCaps: ByteArray) {
    private val t = timeCaps
    private val s = supportCaps

    private fun t(i: Int) = t.getOrNull(i)?.toInt()?.and(0xFF) ?: 0
    private fun s(i: Int) = s.getOrNull(i)?.toInt()?.and(0xFF) ?: 0
    private fun bit(v: Int, b: Int) = v shr b and 1 == 1

    val temperature get() = t(0) == 1
    val menstruation get() = t(2) == 1
    val spo2 get() = bit(t(3), 1)
    val bloodPressure get() = bit(t(3), 2)
    val oneKeyCheck get() = bit(t(3), 4)

    /** Giấc ngủ qua big-data 0x27 thay vì lệnh 16 byte 0x44. */
    val newSleepProtocol get() = t(8) == 1
    val appMeasure get() = bit(t(10), 5)
    val bloodSugar get() = bit(t(11), 7)
    val stress get() = bit(t(13), 4)
    val hrv get() = bit(t(13), 5)

    val touch get() = bit(s(1), 0)
    val blePair get() = bit(s(1), 3)
    val noScreen get() = bit(s(1), 6)
    val gesture get() = bit(s(1), 7)
    val ecg get() = bit(s(9), 1)

    /**
     * Tập khả năng chuẩn. Nhịp tim, bước chân và giấc ngủ không có bit riêng: mọi thiết bị QRing
     * đều có (suy luận từ app QRing, đã đo được nhịp tim trên R09).
     */
    fun toCapabilities(): Set<Capability> = buildSet {
        add(Capability.HEART_RATE)
        add(Capability.STEPS)
        add(Capability.SLEEP)
        if (spo2) add(Capability.SPO2)
        if (temperature) add(Capability.TEMPERATURE)
        if (bloodPressure) add(Capability.BLOOD_PRESSURE)
        if (stress) add(Capability.STRESS)
        if (hrv) add(Capability.HRV)
        if (bloodSugar) add(Capability.BLOOD_SUGAR)
        if (ecg) add(Capability.ECG)
        if (menstruation) add(Capability.MENSTRUATION)
        if (gesture) add(Capability.GESTURE)
    }
}

/** Phép đo thủ công tương ứng với một khả năng, null nếu khả năng đó không đo trực tiếp được. */
fun Capability.measurementType(): MeasurementType? = when (this) {
    Capability.HEART_RATE -> MeasurementType.HEART_RATE
    Capability.SPO2 -> MeasurementType.SPO2
    Capability.TEMPERATURE -> MeasurementType.TEMPERATURE
    Capability.BLOOD_PRESSURE -> MeasurementType.BLOOD_PRESSURE
    Capability.STRESS -> MeasurementType.STRESS
    Capability.HRV -> MeasurementType.HRV
    else -> null
}
