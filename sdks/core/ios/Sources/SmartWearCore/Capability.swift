import Foundation

/// Khả năng chuẩn hoá, dùng chung cho mọi loại thiết bị (cùng tên với `com.smartwear.core.Capability`
/// trên Android). Mỗi SDK thiết bị tự dịch bảng khả năng riêng sang tập này để UI (và lớp React Native)
/// sinh chức năng theo thiết bị mà không cần biết giao thức. `rawValue` trùng tên enum Android.
public enum Capability: String, CaseIterable, Sendable, Codable, Hashable {
    case heartRate = "HEART_RATE"
    case spo2 = "SPO2"
    case temperature = "TEMPERATURE"
    case bloodPressure = "BLOOD_PRESSURE"
    case stress = "STRESS"
    case hrv = "HRV"
    case bloodSugar = "BLOOD_SUGAR"
    case ecg = "ECG"
    case steps = "STEPS"
    case sleep = "SLEEP"
    case menstruation = "MENSTRUATION"
    case gesture = "GESTURE"
    /// Chỉ số trao đổi chất (MET), không đơn vị.
    case met = "MET"
    /// Acid uric (µmol/L), thuộc nhóm "thành phần máu".
    case uricAcid = "URIC_ACID"
    /// Mỡ máu (mmol/L): `value` = cholesterol toàn phần, `Reading.extra` / `HistoryPoint.extra` có
    /// "totalCholesterol", "triglycerides", "hdl", "ldl".
    case bloodLipids = "BLOOD_LIPIDS"
    /// Thành phần cơ thể (đo nhanh): `value` = % mỡ, các chỉ số khác trong `extra` (khoá như Android).
    case bodyComposition = "BODY_COMPOSITION"

    /// Nhận cả `HEART_RATE`, `heart_rate`, `heartRate`.
    public init?(name: String) {
        let key = name.replacingOccurrences(of: "_", with: "").lowercased()
        guard let match = Capability.allCases.first(where: {
            $0.rawValue.replacingOccurrences(of: "_", with: "").lowercased() == key
        }) else { return nil }
        self = match
    }
}

public enum ConnectionState: String, Sendable {
    case disconnected = "DISCONNECTED"
    case connecting = "CONNECTING"
    case connected = "CONNECTED"
    case disconnecting = "DISCONNECTING"
}

/// Loại vật lý đoán được từ quảng bá / driver. Chỉ để hiển thị.
public enum DeviceKind: String, Sendable, Codable {
    case ring, watch, band, earbuds, sensor, unknown
}
