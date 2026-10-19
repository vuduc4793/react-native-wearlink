package com.smartwear.core

/**
 * Khả năng chuẩn hoá, dùng chung cho mọi loại thiết bị. Mỗi SDK thiết bị tự dịch bảng khả năng
 * riêng của nó sang tập này, để UI (và lớp React Native) sinh chức năng theo thiết bị mà không cần
 * biết giao thức.
 */
enum class Capability {
    HEART_RATE,
    SPO2,
    TEMPERATURE,
    BLOOD_PRESSURE,
    STRESS,
    HRV,
    BLOOD_SUGAR,
    ECG,
    STEPS,
    SLEEP,
    MENSTRUATION,
    GESTURE,
    /** Chỉ số trao đổi chất (MET), vd vòng tay Veepoo lưu mỗi 5 phút. */
    MET,
    /** Acid uric (μmol/L). */
    URIC_ACID,
    /** Mỡ máu (mmol/L): giá trị chính là cholesterol toàn phần, `extra` có `totalCholesterol`, `triglycerides`, `hdl`, `ldl`. */
    BLOOD_LIPIDS,
    /** Thành phần cơ thể (đo nhanh trên thiết bị): giá trị chính là % mỡ, chi tiết trong `extra`. */
    BODY_COMPOSITION,
}
