package com.smartwear.gloryfit

/** Nút gỡ lỗi (truyền mặt đồng hồ, đặt giờ), đặt từ app thử nghiệm qua adb. Mặc định không đổi hành vi. */
object GloryFitDebug {
    /** Ghi log thời gian từng khối 4 KB và mọi gói `26 …` nhận giữa khối. */
    @Volatile var trace: Boolean = false
    /** Ép độ dài gói `27` (gồm 3 byte đầu); null = theo bảng tính năng và MTU. */
    @Volatile var packetLength: Int? = null
    /** Nghỉ sau mỗi gói (ms); 0 = nhịp như app gốc (20 ms mỗi 10 gói). */
    @Volatile var packetDelayMs: Long = 0
    /** Tắt lần gửi lại tự động khi đồng hồ huỷ giữa chừng. */
    @Volatile var noRetry: Boolean = false
    /** Gửi `A3` 9 byte (thêm giờ lệch GMT như SDK iOS, doc 09 §1.5). Chưa kiểm chứng trên Y25/HT43 nên mặc định tắt. */
    @Volatile var timeZoneByte: Boolean = false
    /**
     * Đồng bộ lịch sử từ mốc thời gian (`[op] FA YYYY MM DD HH mm`, F4 `0x2000`) thay vì lấy hết. Byte đã đối chiếu mã app
     * nhưng chưa kiểm hết trên Y25 nên mặc định tắt (giống bản iOS: có hàm dựng, chưa nối vào syncHistory).
     */
    @Volatile var syncSince: Boolean = false
    /**
     * Trạng thái trả lời khi đồng hồ hỏi AGPS (`01 E9 AC 03 01 02`) mà app chưa đặt file: 5 = không hỗ trợ (mặc định, để đồng hồ
     * thôi hỏi mỗi 60 s; **chưa kiểm trên máy**), 1 = đang chuẩn bị (app GloryFitPro gửi khi chưa có file), null = không trả lời.
     */
    @Volatile var agpsNoFileStatus: Int? = UteAgps.STATUS_NOT_SUPPORT
}
