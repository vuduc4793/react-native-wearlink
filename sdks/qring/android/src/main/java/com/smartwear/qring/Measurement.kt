package com.smartwear.qring

import com.smartwear.qring.protocol.Packet

/**
 * Loại phép đo thủ công (lệnh 0x69 start / 0x6A stop). [sub] là byte thứ 2 của lệnh start,
 * app QRing gửi 0x25 cho mọi loại từ SpO2 trở đi. Xem sdks/qring/docs/02-commands.md §4.5.
 */
enum class MeasurementType(val code: Int, internal val sub: Int) {
    HEART_RATE(1, 0x00),
    BLOOD_PRESSURE(2, 0x00),
    SPO2(3, 0x25),
    STRESS(8, 0x25),
    HRV(10, 0x25),
    TEMPERATURE(11, 0x25);

    companion object {
        fun fromCode(code: Int): MeasurementType? = entries.firstOrNull { it.code == code }
    }
}

enum class MeasurementStatus {
    /** Ring đang đo, chưa có giá trị. */
    MEASURING,

    /** Có giá trị hợp lệ. */
    OK,

    /** Ring báo chưa đeo (errCode 1). */
    NOT_WORN,

    /** Ring trả mã lỗi khác hoặc cờ lỗi 0x80. */
    ERROR,
}

/**
 * Một gói kết quả trong lúc đo.
 * - HEART_RATE: bpm. SPO2: %. STRESS: điểm. HRV: ms (suy luận). TEMPERATURE: °C.
 * - BLOOD_PRESSURE: [value] là null, xem [systolic]/[diastolic] (mmHg).
 */
data class MeasurementReading(
    val type: MeasurementType,
    val status: MeasurementStatus,
    val value: Double?,
    val systolic: Int? = null,
    val diastolic: Int? = null,
    val errorCode: Int = 0,
) {
    internal companion object {
        /** Giải mã gói 0x69: `[type, errCode, value, sbp, dbp]`. */
        fun parse(type: MeasurementType, p: Packet): MeasurementReading {
            if (p.isError) return MeasurementReading(type, MeasurementStatus.ERROR, null, errorCode = -1)
            val err = p.u8(1)
            val raw = p.u8(2)
            val sbp = p.u8(3)
            val dbp = p.u8(4)
            val hasValue = if (type == MeasurementType.BLOOD_PRESSURE) sbp > 0 && dbp > 0 else raw > 0
            val status = when {
                err == 1 -> MeasurementStatus.NOT_WORN
                err == 0 && hasValue -> MeasurementStatus.OK
                err == 0 || err == 2 -> MeasurementStatus.MEASURING
                else -> MeasurementStatus.ERROR
            }
            val value = when {
                status != MeasurementStatus.OK || type == MeasurementType.BLOOD_PRESSURE -> null
                type == MeasurementType.TEMPERATURE -> raw / 10.0 + 20
                else -> raw.toDouble()
            }
            return MeasurementReading(
                type = type,
                status = status,
                value = value,
                systolic = sbp.takeIf { type == MeasurementType.BLOOD_PRESSURE && it > 0 },
                diastolic = dbp.takeIf { type == MeasurementType.BLOOD_PRESSURE && it > 0 },
                errorCode = err,
            )
        }
    }
}
