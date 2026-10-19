package com.smartwear.veepoo

import com.smartwear.veepoo.Veepoo.op
import com.smartwear.veepoo.Veepoo.u

/**
 * Thành phần máu (`8A`), thành phần cơ thể (`93 04`), hiệu chuẩn (HA `91`, đường huyết `89 02`/`89 03`, thành phần máu `8A 02`),
 * hồ sơ người dùng `A3` và lệnh hệ thống (`F2 04` tắt máy, `FF 55` khôi phục gốc) — chỉ dựng/đọc gói, driver gửi.
 * Nguồn: `jf/g.java` (BloodComponentOperate), `jf/k.java` (BodyComponentDetectOperate), `jf/h.java` (BloodGlucose),
 * `jf/i0.java:43-58, 129-137, 172-190, 280-372` (BP setting), `jf/t1.java` (A3), `jf/w0.java:305-314`, `VOM:2954-2970`.
 */
object VeepooHealth {

    // ---------- Thành phần máu ----------

    /**
     * Một bộ chỉ số máu ở dạng thô như trên dây: acid uric ×10 (μmol/L), cholesterol toàn phần / triglycerid / HDL / LDL ×100 (mmol/L).
     * GE54 (19/10/2026, hiệu chuẩn đang lưu): `84 03 DC 05 B0 04 E8 03 DC 05` = 90,0 μmol/L; 15,00 / 12,00 / 10,00 / 15,00 mmol/L.
     */
    data class BloodValues(val uricAcid10: Int, val cholesterol100: Int, val triglycerides100: Int, val hdl100: Int, val ldl100: Int) {
        val nonZero get() = uricAcid10 != 0 || cholesterol100 != 0 || triglycerides100 != 0 || hdl100 != 0 || ldl100 != 0

        /** Khoá dùng chung ở `Reading.extra` / `HistoryPoint.extra` (μmol/L, mmol/L). */
        fun extra(): Map<String, Double> = linkedMapOf(
            "uricAcid" to uricAcid10 / 10.0,
            "totalCholesterol" to cholesterol100 / 100.0,
            "triglycerides" to triglycerides100 / 100.0,
            "hdl" to hdl100 / 100.0,
            "ldl" to ldl100 / 100.0,
        )

        /** Thứ tự trên dây khi đo / hiệu chuẩn: uric, TCHO, TAG, HDL, LDL (LE16). */
        fun bytes(): IntArray = intArrayOf(uricAcid10, cholesterol100, triglycerides100, hdl100, ldl100)
            .flatMap { listOf(it and 0xFF, (it shr 8) and 0xFF) }.toIntArray()

        companion object {
            /** Uric, TCHO, TAG, HDL, LDL (LE16) từ byte [at] (`g.a(5, …)`). */
            fun parseLive(p: ByteArray, at: Int): BloodValues? {
                if (p.size < at + 10) return null
                return BloodValues(Veepoo.le16(p, at), Veepoo.le16(p, at + 2), Veepoo.le16(p, at + 4), Veepoo.le16(p, at + 6), Veepoo.le16(p, at + 8))
            }

            /** Tag `C2` của `DF` (10 byte): TCHO, TAG, HDL, LDL, **rồi** uric (LE16, `p1.java:545-553`). Toàn 0 ⇒ null. */
            fun parseDf(b: ByteArray): BloodValues? {
                if (b.size < 10 || b.all { it.toInt() == 0 }) return null
                return BloodValues(Veepoo.le16(b, 8), Veepoo.le16(b, 0), Veepoo.le16(b, 2), Veepoo.le16(b, 4), Veepoo.le16(b, 6)).takeIf { it.nonZero }
            }
        }
    }

    /**
     * `8A 01 01 cal` bắt đầu đo (`jf/g.java:224-233`; cal = 1: chế độ riêng, kết quả bám giá trị hiệu chuẩn `8A 02`, như ô "chế độ
     * riêng" G Band — mặc định G Band là chế độ thường, `BloodComponentDetectFragment.onResume`); `8A 01 02 00` dừng. Driver luôn gửi 0.
     */
    fun bloodComponentStart(calibrated: Boolean) = Veepoo.padded(20, 0x8A, 0x01, 0x01, if (calibrated) 1 else 0)
    val BLOOD_COMPONENT_STOP = Veepoo.padded(20, 0x8A, 0x01, 0x02, 0x00)

    /** Hiệu chuẩn thành phần máu ([values] null = vòng tay chưa trả lời). */
    data class BloodCalibration(val enabled: Boolean, val values: BloodValues)

    val BLOOD_CALIBRATION_READ = Veepoo.padded(20, 0x8A, 0x02, 0x02)

    /** `8A 02 01 bật uric TCHO TAG HDL LDL` (LE16, `g.settingBloodComponentCalibration`). */
    fun bloodCalibrationWrite(c: BloodCalibration) = Veepoo.padded(20, 0x8A, 0x02, 0x01, if (c.enabled) 1 else 0, *c.values.bytes())

    /** Phản hồi `8A 02 thao-tác(1 ghi / 2 đọc) ok bật giá-trị…`; ok ≠ 1 ⇒ null. */
    fun parseBloodCalibration(p: ByteArray): BloodCalibration? {
        if (p.op != 0x8A || p.size < 15 || u(p, 1) != 2 || u(p, 3) != 1) return null
        return BloodCalibration(u(p, 4) == 1, BloodValues.parseLive(p, 5) ?: return null)
    }

    // ---------- Thành phần cơ thể ----------

    /**
     * Khoá `extra` theo thứ tự 14 giá trị LE16 ÷10 sau `A0 len` (`BodyComponent(int…)`): tên trường SDK trong ngoặc.
     * bmi, bodyFatRate % (bodyFatRate), fatMass kg (fatRate — G Band hiện theo kg), fatFreeMass kg (FFM), muscleRate %, muscleMass kg,
     * subcutaneousFat %, bodyWaterRate % (bodyWater), waterMass kg (waterContent), skeletalMuscleRate %, boneMass kg,
     * proteinRate % (proteinProportion), proteinMass kg, basalMetabolicRate kcal.
     */
    val BODY_KEYS = listOf(
        "bmi", "bodyFatRate", "fatMass", "fatFreeMass", "muscleRate", "muscleMass", "subcutaneousFat", "bodyWaterRate", "waterMass",
        "skeletalMuscleRate", "boneMass", "proteinRate", "proteinMass", "basalMetabolicRate",
    )

    val BODY_START = Veepoo.padded(20, 0x93, 0x04, 0x01)
    val BODY_STOP = Veepoo.padded(20, 0x93, 0x04, 0x02)

    /**
     * Ghép gói kết quả `93 04 01 01 idx total` + 14 byte (byte 6..19 mỗi gói) → khối bắt đầu `A0 len`, rồi 14 giá trị LE16 ÷10
     * ([BODY_KEYS]). Null nếu thiếu gói hoặc không có `A0`.
     */
    fun parseBody(packets: List<ByteArray>): Map<String, Double>? {
        if (packets.isEmpty()) return null
        val buf = java.io.ByteArrayOutputStream()
        for (p in packets) if (p.size > 6) buf.write(p, 6, minOf(p.size, 20) - 6)
        val b = buf.toByteArray()
        if (b.size < 2 + BODY_KEYS.size * 2 || u(b, 0) != 0xA0) return null
        return BODY_KEYS.withIndex().associate { (i, k) -> k to Veepoo.le16(b, 2 + i * 2) / 10.0 }
    }

    // ---------- Hiệu chuẩn huyết áp ----------

    /** Chế độ riêng (đã hiệu chuẩn) [enabled] + giá trị gốc tâm thu/tâm trương. GE54 19/10: bật, 120/87. */
    data class BpCalibration(val enabled: Boolean, val systolic: Int, val diastolic: Int)

    /** `91 02 00 00` (`mf.a.w`). */
    val BP_CALIBRATION_READ = Veepoo.bytes(0x91, 0x02, 0x00, 0x00)

    /**
     * `91 riêng cao thấp angio(0)` (20 byte, `i0.settingDetectBP`). LƯU Ý: gói `91` thiếu byte vẫn bị vòng tay hiểu là "đặt chế độ
     * thường 0/0" (đo 19/10/2026), nên chỉ gửi gói đủ 20 byte này.
     */
    fun bpCalibrationWrite(c: BpCalibration) = Veepoo.padded(20, 0x91, if (c.enabled) 1 else 0, c.systolic and 0xFF, c.diastolic and 0xFF, 0)

    /** Phản hồi `91 kết-quả cao thấp riêng thao-tác` (thao tác 0/1 ghi, 2 đọc); kết quả ≠ 1 ⇒ null. */
    fun parseBpCalibration(p: ByteArray): BpCalibration? {
        if (p.op != 0x91 || p.size < 6 || u(p, 1) != 1) return null
        return BpCalibration(u(p, 4) == 1, u(p, 2), u(p, 3))
    }

    // ---------- Hiệu chuẩn đường huyết ----------

    /** Một bữa: phút trong ngày trước/sau ăn + giá trị ×100 mmol/L. */
    data class Meal(val beforeMinute: Int, val before100: Int, val afterMinute: Int, val after100: Int) {
        fun bytes(): IntArray = intArrayOf(
            beforeMinute / 60, beforeMinute % 60, before100 and 0xFF, (before100 shr 8) and 0xFF,
            afterMinute / 60, afterMinute % 60, after100 and 0xFF, (after100 shr 8) and 0xFF,
        )

        companion object {
            fun parse(b: ByteArray, at: Int) =
                Meal(u(b, at) * 60 + u(b, at + 1), Veepoo.le16(b, at + 2), u(b, at + 4) * 60 + u(b, at + 5), Veepoo.le16(b, at + 6))
        }
    }

    /**
     * Hiệu chuẩn đường huyết: kiểu một điểm ([value100], `89 02`, glucose type 2/3/6) hoặc nhiều điểm ([meals] = sáng, trưa, tối,
     * `89 03`, type 4/5/7/8/9). GE54 19/10: nhiều điểm, bật, bữa sáng 15:00 6,50 / 15:01 7,50, trưa/tối 0.
     */
    data class GlucoseCalibration(val enabled: Boolean, val value100: Int = 0, val meals: List<Meal> = emptyList())

    val GLUCOSE_CALIBRATION_READ = Veepoo.bytes(0x89, 0x02, 0x02, 0x00, 0x00, 0x00)
    val GLUCOSE_MULTI_READ = Veepoo.bytes(0x89, 0x03, 0x02, 0x01, 0x01)

    /** `89 02 01 giá-trị(LE16 ×100) bật` (`h.settingBloodGlucoseAdjustingData`). */
    fun glucoseCalibrationWrite(value100: Int, enabled: Boolean) =
        Veepoo.padded(20, 0x89, 0x02, 0x01, value100 and 0xFF, (value100 shr 8) and 0xFF, if (enabled) 1 else 0)

    /** Phản hồi `89 02 thao-tác ok giá-trị(LE16) bật`. */
    fun parseGlucoseCalibration(p: ByteArray): GlucoseCalibration? {
        if (p.op != 0x89 || p.size < 7 || u(p, 1) != 2 || u(p, 3) != 1) return null
        return GlucoseCalibration(u(p, 6) == 1, value100 = Veepoo.le16(p, 4))
    }

    /**
     * Nhiều điểm: thân 25 byte (bật + 3 bữa × 8) chia 2 gói `89 03 01 idx 02` + 15 byte / + 10 byte (`h.c()`).
     */
    fun glucoseMultiWrite(c: GlucoseCalibration): List<ByteArray> {
        val meals = (c.meals + List(3) { Meal(0, 0, 0, 0) }).take(3)
        val body = intArrayOf(if (c.enabled) 1 else 0) + meals.flatMap { it.bytes().toList() }
        return listOf(
            Veepoo.padded(20, 0x89, 0x03, 0x01, 0x01, 0x02, *body.copyOfRange(0, 15)),
            Veepoo.padded(20, 0x89, 0x03, 0x01, 0x02, 0x02, *body.copyOfRange(15, 25)),
        )
    }

    /** Gói `89 03 thao-tác ok idx total …`: gói 1 byte 6 = bật, 7..19 = 13 byte bữa; gói 2 byte 6..16 = 11 byte còn lại. */
    fun parseGlucoseMulti(p1: ByteArray, p2: ByteArray): GlucoseCalibration? {
        if (p1.op != 0x89 || p2.op != 0x89 || p1.size < 20 || p2.size < 17 || u(p1, 3) != 1 || u(p1, 4) != 1 || u(p2, 4) != 2) return null
        val b = p1.copyOf(20) + p2.copyOfRange(6, 17)
        return GlucoseCalibration(u(b, 6) == 1, meals = listOf(Meal.parse(b, 7), Meal.parse(b, 15), Meal.parse(b, 23)))
    }

    // ---------- Hồ sơ người dùng A3 ----------

    /** Hồ sơ + mục tiêu (G Band gửi mỗi lần kết nối). [female] = giới tính nữ; [sleepMinutes] mục tiêu ngủ. */
    data class Profile(val heightCm: Int = 170, val weightKg: Int = 65, val age: Int = 30, val female: Boolean = false,
                       val stepGoal: Int = 8000, val sleepMinutes: Int = 8 * 60)

    /** `A3 cm kg tuổi giới(1 nam / 0 nữ) bướcBE16 ngủBE16` (20 byte, `jf/t1.java:47-61`); phản hồi `A3 01` = OK. */
    fun profile(p: Profile) = Veepoo.padded(
        20, 0xA3, p.heightCm.coerceIn(0, 255), p.weightKg.coerceIn(0, 255), p.age.coerceIn(0, 255), if (p.female) 0 else 1,
        (p.stepGoal shr 8) and 0xFF, p.stepGoal and 0xFF, (p.sleepMinutes shr 8) and 0xFF, p.sleepMinutes and 0xFF,
    )

    // ---------- Hệ thống (KHÔNG chạy thử trên vòng tay thật) ----------

    /** Tắt máy: `F2 04` + 0 (20 byte, `DebugCmd.CMD4`, `VOM:2954-2970`); vòng tay trả `F2 01 04`. */
    val POWER_OFF = Veepoo.padded(20, 0xF2, 0x04)

    /** Khôi phục cài đặt gốc: `FF 55 01 73 40` + 0 (20 byte, `w0.resetDeviceData`), như iOS `data.reset`. */
    val FACTORY_RESET = Veepoo.padded(20, 0xFF, 0x55, 0x01, 0x73, 0x40)
}
