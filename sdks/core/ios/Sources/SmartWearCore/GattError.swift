import CoreBluetooth
import Foundation

public enum GattError: LocalizedError, Equatable, Sendable {
    case bluetoothUnavailable(String)
    case peripheralNotFound
    case notConnected
    case disconnected
    case timeout(String)
    case serviceNotFound(String)
    case characteristicNotFound(String)
    case operationFailed(String, String?)
    /// Lỗi CoreBluetooth/ATT có mã (giữ mã để chẩn đoán), vd ("Kết nối", CBError 14).
    case ble(String, BleErrorCode)

    public var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable(let s): return "Bluetooth không sẵn sàng (\(s))"
        case .peripheralNotFound: return "Không tìm thấy thiết bị, hãy quét lại"
        case .notConnected: return "Chưa kết nối"
        case .disconnected: return "Đã ngắt kết nối"
        case .timeout(let what): return what.isEmpty ? "Hết thời gian chờ" : "Hết thời gian chờ \(what)"
        case .serviceNotFound(let s): return "Không có service \(s)"
        case .characteristicNotFound(let c): return "Không tìm thấy characteristic \(c)"
        case .operationFailed(let op, let reason): return "\(op) thất bại" + (reason.map { ": \($0)" } ?? "")
        case .ble(let op, let code): return "\(op) thất bại: \(code.message.isEmpty ? code.meaning : code.message)"
        }
    }
}

public extension GattError {
    /// Bọc lỗi iOS: giữ mã CB/ATT nếu có, GattError giữ nguyên, còn lại thành `operationFailed`.
    static func wrap(_ op: String, _ error: Error?) -> GattError {
        if let g = error as? GattError { return g }
        if let code = BleErrorCode(error) { return .ble(op, code) }
        return .operationFailed(op, error?.localizedDescription)
    }
}

public extension CBUUID {
    /// "2A19", hoặc 8 ký tự đầu với UUID 128 bit ("6E400003").
    var short: String {
        let s = uuidString
        return s.count > 8 ? String(s.prefix(8)) : s
    }
}

public enum BluetoothState: String, Sendable {
    case unknown, resetting, unsupported, unauthorized, poweredOff, poweredOn

    init(_ s: CBManagerState) {
        switch s {
        case .resetting: self = .resetting
        case .unsupported: self = .unsupported
        case .unauthorized: self = .unauthorized
        case .poweredOff: self = .poweredOff
        case .poweredOn: self = .poweredOn
        default: self = .unknown
        }
    }
}
