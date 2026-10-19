package com.smartwear.veepoo

import com.smartwear.core.Capability
import com.smartwear.core.toHex

/**
 * Bảng tính năng `A7` (thiết bị tự đẩy 5 gói ngay sau `A1`, `[19]` = số trang 1..5), parser `jf/y.java:39-493`,
 * bảng tên/giá trị gốc `home/profile/viewModel/a.java:12,15`. Giữ nguyên byte thô, đọc từng cờ qua thuộc tính.
 * Quy ước: 0 = không có, khác 0 = có, trừ chỗ ghi riêng. Trang thiếu ⇒ coi mọi byte là 0.
 */
class VeepooFeatures(val pages: Map<Int, ByteArray>) {

    /** Byte [index] (1..18) của trang [page] (1..5). */
    fun b(page: Int, index: Int): Int = pages[page]?.let { if (index < it.size) it[index].toInt() and 0xFF else 0 } ?: 0

    val complete: Boolean get() = (1..5).all { it in pages }

    // ----- Trang 1 -----
    /** 0 không; 1 có; 2 tự đánh giá; 3 bơm hơi không ADC; 4 có (đọc qua `DE`); 5 bơm hơi có ADC. */
    val bpType get() = b(1, 1)
    val bloodPressure get() = bpType != 0
    /** 1 = nhắc ngồi lâu `E1`; 2 = nhắc sức khoẻ `E7` (loại trừ `E1`). */
    val sedentaryType get() = b(1, 3)
    val longSeat get() = sedentaryType == 1
    val healthRemind get() = sedentaryType == 2
    val skinType get() = b(1, 4)
    /** 1 mở trang chụp ảnh; 2 thường trú (HID iOS). */
    val camera get() = b(1, 6) == 1 || b(1, 6) == 2
    val spo2Type get() = b(1, 8)
    val spo2 get() = spo2Type in 1..9 || spo2Type == 0xFD || spo2Type == 0xFE || spo2Type == 0xE0
    /** Số gói nội dung thông báo tối đa; 0 = 4 gói (`getAllLength`). */
    val messagePackets get() = b(1, 9).let { if (it == 0) 4 else it }
    val heartRateAlarm get() = b(1, 10) == 1
    /** 0 kiểu cũ (`AA` dựng sẵn), 1 có `AA` đầy đủ, 2 không có nâng tay. */
    val wristTurnType get() = b(1, 11)
    val womenTag get() = b(1, 12)
    /** Số mức độ sáng; 1 = có `B1`. */
    val brightness get() = b(1, 13) == 1
    /** 0 = 1 chữ số thập phân quãng đường, 1 = 3 chữ số. */
    val preciseDistance get() = b(1, 15) == 1
    /** 0 = 3 báo thức cũ `AB`; 1–4 = `B9` nhiều báo thức; 5/6/7 = báo thức có chữ; FE = không có báo thức. */
    val alarmType get() = b(1, 17)
    val multiAlarm get() = alarmType in 1..4
    val textAlarm get() = alarmType in 5..7
    val legacyAlarm get() = alarmType == 0
    /** Byte 18: **0 = có nhịp tim**, 1 = không, 2–8 = biến thể cảm biến. */
    val heartRate get() = b(1, 18) != 1

    // ----- Trang 2 -----
    val countDown get() = b(2, 1) == 1
    /** Số ngày lịch sử đọc được; 0 = 3 ngày. */
    val watchDays get() = b(2, 2).let { if (it == 0) 3 else it }
    /** Số gói tên người gửi trong thông báo (`contactMsgLength`); 0 = tên ≤ 12 byte trong gói đầu. */
    val contactMsgLength get() = b(2, 3)
    /** Số buổi tập lưu được (`sportModelDay`); khác 0 = có chế độ thể thao. */
    val sportModelSlots get() = b(2, 5)
    val sportModel get() = sportModelSlots != 0
    /** Số kiểu màn dựng sẵn (`C7`). */
    val screenStyleCount get() = b(2, 6)
    val breath get() = b(2, 7) != 0
    val hrvType get() = b(2, 8)
    val hrv get() = hrvType != 0 && hrvType != 5
    val weatherType get() = b(2, 9)
    val weather get() = weatherType != 0
    /** 0 = 5 phút `D1`; 3 hoặc 5 = `DF` TLV; 4/5 = layout "sport model". */
    val originProtocolVersion get() = b(2, 10)
    val usesDf get() = originProtocolVersion == 3 || originProtocolVersion == 5
    val screenOnTime get() = b(2, 12) != 0
    /** 0 ngủ cũ; 1 ngủ chính xác; 2 không có ngủ; 3 KH; 4/5 ZK; 6 nhẫn. Khác 0 ⇒ parser chính xác. */
    val sleepTag get() = b(2, 13)
    val sleep get() = sleepTag != 2
    val preciseSleep get() = sleepTag != 0
    val ecg get() = b(2, 15) != 0
    val multiSportType get() = b(2, 16)

    // ----- Trang 3 -----
    /** Cách truyền file lớn; mặt đồng hồ Veepoo gốc cần = 2. */
    val bigDataTranType get() = b(3, 1)
    val watchUiServerCount get() = (b(3, 2) shr 4) and 0x0F
    val watchUiCustomCount get() = b(3, 2) and 0x0F
    /** 0 không; 1 có (10); 2 có + SOS (10); 3 có + SOS (20). */
    val contactType get() = b(3, 4)
    val contacts get() = contactType != 0
    val maxContacts get() = if (contactType == 3) 20 else if (contactType != 0) 10 else 0
    /** `musicType`; 1 = giao thức `99` mới. */
    val musicType get() = b(3, 6)
    /** 1 đo tay; 2 tay + tự động (`88`); 4 da; 5/6 ZK (lịch sử qua `DF` tag C3). */
    val temperatureType get() = b(3, 7)
    val temperature get() = temperatureType != 0
    val findDeviceByPhone get() = b(3, 8) != 0
    val agps get() = b(3, 9) != 0
    val bloodGlucoseType get() = b(3, 15)
    val bloodGlucose get() = bloodGlucoseType != 0 && bloodGlucoseType != 3
    /** Hiệu chuẩn đường huyết một điểm `89 02` (type 2, 3, 6) / nhiều điểm theo bữa `89 03` (type 4, 5, 7, 8, 9) (`jf/y.java:364-386`). */
    val glucoseCalibrationSingle get() = bloodGlucoseType in setOf(2, 3, 6)
    val glucoseCalibrationMulti get() = bloodGlucoseType in setOf(4, 5, 7, 8, 9)
    /** 0 Nordic/Goodix, 1 JieLi AC7013, 2 Actions, 3 ZK568X, 4 ZK569X, 5 Nordic 54L. */
    val cpuType get() = b(3, 16)
    val met get() = b(3, 17) == 2 || b(3, 17) == 3
    /** Đo MET tại chỗ `89 08` chỉ khi MET type = 3 (GE54 type 2 không trả lời `89 08 01`, đo 19/10/2026). */
    val metLive get() = b(3, 17) == 3
    val stress get() = b(3, 18) == 2 || b(3, 18) == 3

    // ----- Trang 4 -----
    /** Thành phần máu (acid uric + mỡ máu, `8A`); 2 = có hiệu chuẩn một điểm (`jf/y.java:425-445`). */
    val bloodComponentType get() = b(4, 1)
    val bloodComponent get() = bloodComponentType != 0
    val bloodComponentCalibration get() = bloodComponentType == 2
    /** Thành phần cơ thể đo nhanh `93 04`. */
    val bodyComposition get() = b(4, 2) == 1
    val worldClock get() = b(4, 3) == 1
    /** 1 = đo tự động kiểu mới `B3`; 0 = công tắc trong `B8`. */
    val autoMeasureB3 get() = b(4, 12) == 1
    val sportControl get() = b(4, 13) != 0

    // ----- Trang 5 -----
    /** 1 không màn, 2 nhẫn, 3 vuông, 4 tròn. */
    val screenShape get() = b(5, 4)

    /** Có mặt đồng hồ Veepoo gốc (chợ / ảnh tuỳ chỉnh) qua kênh `50` + DOOG (`UiUpdateUtil.java:567-577`). */
    val nativeWatchFace get() = bigDataTranType == 2 && (watchUiServerCount > 0 || watchUiCustomCount > 0)

    val cpuName: String
        get() = when (cpuType) {
            0 -> "Nordic/Goodix"
            1 -> "JieLi AC7013"
            2 -> "Actions"
            3 -> "ZK568X (Bluetrum)"
            4 -> "ZK569X (Bluetrum)"
            5 -> "Nordic 54L"
            else -> "không rõ ($cpuType)"
        }

    /** Capability chuẩn hoá. */
    fun capabilities(): Set<Capability> = buildSet {
        if (heartRate) add(Capability.HEART_RATE)
        if (spo2) add(Capability.SPO2)
        if (bloodPressure) add(Capability.BLOOD_PRESSURE)
        if (temperature) add(Capability.TEMPERATURE)
        if (stress) add(Capability.STRESS)
        if (hrv) add(Capability.HRV)
        if (bloodGlucose) add(Capability.BLOOD_SUGAR)
        if (met) add(Capability.MET)
        if (bloodComponent) { add(Capability.URIC_ACID); add(Capability.BLOOD_LIPIDS) }
        if (bodyComposition) add(Capability.BODY_COMPOSITION)
        // ECG (A7 gói 2 byte 15) có trên GE54 nhưng driver chưa đo/đọc ECG (sóng qua F0020002) ⇒ không báo capability.
        add(Capability.STEPS)
        if (sleep) add(Capability.SLEEP)
        if (womenTag != 0) add(Capability.MENSTRUATION)
    }

    /** Mỗi byte khác 0 kèm tên (để log/"Chi tiết kỹ thuật"); byte 0 bỏ qua. */
    fun describe(): String = (1..5).joinToString("; ") { page ->
        val names = NAMES[page - 1]
        "A7.$page: " + names.indices.mapNotNull { i ->
            val v = b(page, i + 1)
            if (v == 0) null else "${names[i]}=%02X".format(v)
        }.joinToString(", ")
    }

    companion object {
        /** Tên từng byte 1..18 (trang 5: 1..13) theo bảng debug của app (`profile/viewModel/a.java:12`). */
        val NAMES = listOf(
            listOf("huyết áp", "rượu", "ngồi lâu/nhắc", "loại da", "WeChat", "camera", "mệt mỏi", "SpO2", "số gói tin", "cảnh báo HR",
                "nâng tay", "phụ nữ", "độ sáng", "C3", "độ chính xác q.đường", "HA cao cấp", "báo thức", "nhịp tim(0=có)"),
            listOf("đếm ngược", "số ngày", "gói tên tin", "HID", "thể thao", "kiểu UI", "nhịp thở", "HRV", "thời tiết", "originProtocol",
                "A5 hoàn thiện", "sáng màn", "sleepTag", "xoá dữ liệu", "ECG", "kiểu thể thao", "tiết kiệm pin", "TP"),
            listOf("bigDataTranType", "mặt server/tuỳ chỉnh", "lão hoá", "danh bạ", "hướng dẫn", "nhạc", "nhiệt độ", "tìm vòng tay",
                "AGPS", "GPS", "địa từ", "ẩn mật khẩu", "mic", "quảng bá", "đường huyết", "cpuType", "MET", "stress"),
            listOf("thành phần máu", "thành phần cơ thể", "đồng hồ thế giới", "cảnh báo nhiệt độ", "ví", "danh thiếp", "trò chơi", "AI hỏi đáp",
                "AI mặt đồng hồ", "mục tiêu q.đường/kcal", "mặt video", "đo tự động B3", "điều khiển thể thao DA", "album", "4G", "danh thiếp điện tử",
                "đánh giá sức khoẻ", "mini checkup"),
            listOf("đẩy chữ/ảnh", "GSR", "an toàn SOS", "kiểu màn", "khí áp", "IC cảm ứng", "giao thức sản xuất mới", "PTT", "trạng thái thể thao",
                "sự kiện nhắc", "cảm xúc", "lọt sáng", "đèn sức khoẻ"),
        )
    }
}

/**
 * Bảng `AD` (thiết bị đẩy sau `A1`, đọc lại bằng `AD 02`): trạng thái thông báo từng app, 0 = không hỗ trợ, 1 = bật, 2 = tắt.
 * Gói 0 (`[19]` nibble cao 0): byte 2..18 = appType 0..16, **byte 19 = "khác" (17)**. Gói 1 (`[19]` = 0x10): byte 2..14 = appType 18..30
 * (`jf/d2.java:465-557`). Riêng điện thoại (byte 2 gói 0) 0 cũng coi là tắt.
 */
class VeepooMessageSwitches(val page0: ByteArray?, val page1: ByteArray?) {

    /** Trạng thái của appType [type] (0..30): 0 không hỗ trợ, 1 bật, 2 tắt. */
    fun status(type: Int): Int = when (type) {
        in 0..16 -> page0?.getOrNull(type + 2)?.toInt()?.and(0xFF) ?: 0
        17 -> page0?.getOrNull(19)?.toInt()?.and(0x0F) ?: 0
        in 18..30 -> page1?.getOrNull(type - 16)?.toInt()?.and(0xFF) ?: 0
        else -> 0
    }

    fun supported(type: Int) = status(type) != 0 || (type == 0 && page0 != null)

    val any: Boolean get() = page0 != null

    /**
     * Gói ghi `AD 01 …` bật/tắt từng app ([on] theo appType). Giữ 0 cho app thiết bị không hỗ trợ. Gói 1 chỉ gửi nếu có app nào
     * ở gói 1 được hỗ trợ (`d2.java:440-462`).
     */
    fun writePackets(on: (Int) -> Boolean): List<ByteArray> {
        fun st(type: Int) = if (!supported(type)) 0 else if (on(type)) 1 else 2
        val p0 = ByteArray(20).also { p ->
            p[0] = 0xAD.toByte(); p[1] = 0x01
            for (t in 0..16) p[t + 2] = st(t).toByte()
            p[19] = st(17).toByte()
        }
        val out = mutableListOf(p0)
        if ((18..30).any { supported(it) }) {
            out += ByteArray(20).also { p ->
                p[0] = 0xAD.toByte(); p[1] = 0x01
                for (t in 18..30) p[t - 16] = st(t).toByte()
                p[19] = 0x10
            }
        }
        return out
    }

    override fun toString(): String = "AD0=${page0?.toHex()} AD1=${page1?.toHex()}"
}

/**
 * Bảng `B8` (cài đặt tuỳ chỉnh): 2 gói `[19]` = 0/1, `[1]` = 2 (đọc) / 1 (ghi). Byte trạng thái 0 = không hỗ trợ, 1 = bật, 2 = tắt;
 * ngoại lệ: đơn vị (byte 2: 1 metric / 2 imperial), giờ (byte 3: **1 = 24h, 2 = 12h**), °C/°F (gói 1 byte 5). Ghi lại = gói đã
 * đọc, đổi đúng byte cần đổi, `[1]` = 1 (`jf/t.java:83-152`).
 */
class VeepooCustomSettings(val page0: ByteArray?, val page1: ByteArray?) {

    fun get(page: Int, index: Int): Int = (if (page == 0) page0 else page1)?.getOrNull(index)?.toInt()?.and(0xFF) ?: 0

    fun supported(page: Int, index: Int) = get(page, index) != 0
    fun on(page: Int, index: Int) = get(page, index) == 1

    val metric get() = get(0, 2) != 2
    val is24h get() = get(0, 3) != 2

    /** Bản ghi: [page] byte [index] = [value]. Null nếu chưa đọc được gói đó. */
    fun write(page: Int, index: Int, value: Int): ByteArray? {
        val src = (if (page == 0) page0 else page1) ?: return null
        if (src.size < 20) return null
        return src.copyOf(20).also {
            it[0] = 0xB8.toByte()
            it[1] = 0x01
            it[index] = value.toByte()
            it[19] = page.toByte()
            // Gói 0: byte 17 không dùng (app gốc để 0).
            if (page == 0) it[17] = 0
        }
    }

    /** Cập nhật bản sao sau khi ghi thành công. */
    fun with(page: Int, index: Int, value: Int): VeepooCustomSettings {
        fun upd(src: ByteArray?) = src?.copyOf()?.also { it[index] = value.toByte() }
        return if (page == 0) VeepooCustomSettings(upd(page0), page1) else VeepooCustomSettings(page0, upd(page1))
    }

    override fun toString(): String = "B8.0=${page0?.toHex()} B8.1=${page1?.toHex()}"

    companion object {
        val READ = Veepoo.bytes(0xB8, 0x02)

        // Vị trí byte (gói 0)
        const val UNITS = 2
        const val HOUR = 3
        const val AUTO_HR = 4
        const val AUTO_BP = 5
        const val SPORT_REMIND = 6
        const val FIND_PHONE_UI = 8
        const val STOPWATCH = 9
        const val SPO2_LOW = 10
        const val WEAR_DETECT = 11
        const val AUTO_HRV = 12
        const val AUTO_ANSWER = 13
        const val DISCONNECT_REMIND = 14
        const val SOS = 15
        const val PPG = 16
        const val MUSIC_CONTROL = 18

        // Gói 1
        const val LONG_PRESS_LOCK = 2
        const val MESSAGE_SCREEN_ON = 3
        const val AUTO_TEMPERATURE = 4
        const val TEMPERATURE_UNIT = 5
        const val AUTO_GLUCOSE = 7
        const val AUTO_MET = 8
        const val AUTO_STRESS = 9
        const val POWER_SOUND = 17
        const val MEASURE_SOUND = 18
    }
}
