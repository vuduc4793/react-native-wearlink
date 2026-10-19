import Foundation
import SmartWearCore

/// Loại phép đo thủ công (lệnh 0x69 start / 0x6A stop). `sub` là byte thứ 2 của lệnh start,
/// app QRing gửi 0x25 cho mọi loại từ SpO2 trở đi. Xem sdks/qring/docs/02-commands.md §4.5.
public enum MeasurementType: String, CaseIterable, Sendable {
    case heartRate = "HEART_RATE"
    case bloodPressure = "BLOOD_PRESSURE"
    case spo2 = "SPO2"
    case stress = "STRESS"
    case hrv = "HRV"
    case temperature = "TEMPERATURE"

    public var code: UInt8 {
        switch self {
        case .heartRate: return 1
        case .bloodPressure: return 2
        case .spo2: return 3
        case .stress: return 8
        case .hrv: return 10
        case .temperature: return 11
        }
    }

    var sub: UInt8 {
        switch self {
        case .heartRate, .bloodPressure: return 0x00
        default: return 0x25
        }
    }

    public static func fromCode(_ code: UInt8) -> MeasurementType? { allCases.first { $0.code == code } }

    /// Lệnh dừng `6A <type> [giá trị cuối]` như app QRing (Android `StopHeartRateReq`, iOS
    /// `QIFCloseHealthDetectionSwitchCmd`): BP kèm SBP, DBP; loại khác kèm 1 byte giá trị thô; chưa có kết quả thì 0.
    public func stopPacket(last: MeasurementReading?) -> Packet {
        guard let last, last.status == .ok else { return Packet.of(QRingClient.cmdStopMeasure, code) }
        if self == .bloodPressure {
            return Packet.of(QRingClient.cmdStopMeasure, code, UInt8(clamping: last.systolic ?? 0), UInt8(clamping: last.diastolic ?? 0))
        }
        guard let v = last.value else { return Packet.of(QRingClient.cmdStopMeasure, code) }
        // Nhiệt độ: byte thô = (°C - 20) × 10, ngược với `MeasurementReading.parse`.
        let raw = self == .temperature ? ((v - 20) * 10).rounded() : v.rounded()
        return Packet.of(QRingClient.cmdStopMeasure, code, UInt8(clamping: Int(raw)))
    }

    public var capability: Capability {
        switch self {
        case .heartRate: return .heartRate
        case .bloodPressure: return .bloodPressure
        case .spo2: return .spo2
        case .stress: return .stress
        case .hrv: return .hrv
        case .temperature: return .temperature
        }
    }

    /// Đơn vị. HEART_RATE: bpm. SPO2: %. STRESS: điểm. HRV: ms (suy luận). TEMPERATURE: °C. BP: mmHg.
    public var unit: String {
        switch self {
        case .heartRate: return "bpm"
        case .bloodPressure: return "mmHg"
        case .spo2: return "%"
        case .stress: return "điểm"
        case .hrv: return "ms"
        case .temperature: return "°C"
        }
    }
}

public enum MeasurementStatus: String, Sendable {
    /// Ring đang đo, chưa có giá trị.
    case measuring = "MEASURING"
    /// Có giá trị hợp lệ.
    case ok = "OK"
    /// Ring báo chưa đeo (errCode 1).
    case notWorn = "NOT_WORN"
    /// Ring trả mã lỗi khác hoặc cờ lỗi 0x80.
    case error = "ERROR"
}

/// Một gói kết quả trong lúc đo. BLOOD_PRESSURE: `value` là nil, xem `systolic`/`diastolic` (mmHg).
public struct MeasurementReading: Sendable, Equatable, CustomStringConvertible {
    public let type: MeasurementType
    public let status: MeasurementStatus
    public let value: Double?
    public var systolic: Int?
    public var diastolic: Int?
    public var errorCode: Int = 0
    /// Byte 6..7 (LE16) của gói: tín hiệu PPG thô khi chưa có kết quả (sdks/qring/docs/devices.md).
    public var rawSignal: Int?

    /// Giải mã gói 0x69: `[type, errCode, value, sbp, dbp, raw LE16]`.
    public static func parse(_ type: MeasurementType, _ p: Packet) -> MeasurementReading {
        if p.isError { return MeasurementReading(type: type, status: .error, value: nil, errorCode: -1) }
        let err = p.u8(1)
        let raw = p.u8(2)
        let sbp = p.u8(3)
        let dbp = p.u8(4)
        let signal = p.u8(5) | (p.u8(6) << 8)
        let hasValue = type == .bloodPressure ? sbp > 0 && dbp > 0 : raw > 0
        let status: MeasurementStatus
        if err == 1 {
            status = .notWorn
        } else if err == 0 && hasValue {
            status = .ok
        } else if err == 0 || err == 2 {
            status = .measuring
        } else {
            status = .error
        }
        let value: Double?
        if status != .ok || type == .bloodPressure {
            value = nil
        } else if type == .temperature {
            value = Double(raw) / 10.0 + 20
        } else {
            value = Double(raw)
        }
        return MeasurementReading(
            type: type, status: status, value: value,
            systolic: type == .bloodPressure && sbp > 0 ? sbp : nil,
            diastolic: type == .bloodPressure && dbp > 0 ? dbp : nil,
            errorCode: err,
            rawSignal: signal > 0 ? signal : nil
        )
    }

    public var description: String {
        var s = "\(type.rawValue) \(status.rawValue)"
        if let value { s += " \(value) \(type.unit)" }
        if let systolic, let diastolic { s += " \(systolic)/\(diastolic) mmHg" }
        if errorCode != 0 { s += " err=\(errorCode)" }
        return s
    }

    /// Chuyển sang `Reading` chung.
    public var reading: Reading {
        let st: ReadingStatus
        switch status {
        case .measuring: st = .measuring
        case .ok: st = .ok
        case .notWorn: st = .notWorn
        case .error: st = .error
        }
        return Reading(
            capability: type.capability, status: st, value: value, systolic: systolic, diastolic: diastolic,
            unit: type.unit, signal: rawSignal.map(Double.init), errorCode: errorCode == 0 ? nil : errorCode
        )
    }
}
