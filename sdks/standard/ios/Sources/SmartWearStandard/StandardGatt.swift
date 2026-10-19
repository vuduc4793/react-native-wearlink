import CoreBluetooth
import Foundation
import SmartWearCore

/// UUID các dịch vụ Bluetooth SIG chuẩn mà driver `standard` dùng.
public enum StandardGatt {
    public static let batteryService = CBUUID(string: "180F")
    public static let batteryLevel = CBUUID(string: "2A19")

    public static let deviceInfoService = CBUUID(string: "180A")
    public static let modelNumber = CBUUID(string: "2A24")
    public static let manufacturerName = CBUUID(string: "2A29")
    public static let firmwareRevision = CBUUID(string: "2A26")
    public static let hardwareRevision = CBUUID(string: "2A27")
    public static let softwareRevision = CBUUID(string: "2A28")
    public static let serialNumber = CBUUID(string: "2A25")

    public static let heartRateService = CBUUID(string: "180D")
    public static let heartRateMeasurement = CBUUID(string: "2A37")
    public static let bodySensorLocation = CBUUID(string: "2A38")

    public static let humanInterfaceDevice = CBUUID(string: "1812")
}

/// Giải mã characteristic 2A37 Heart Rate Measurement.
/// Byte 0 là flags: bit0 = 1 ⇒ HR là UInt16 LE, ngược lại UInt8; bit1-2 trạng thái tiếp xúc;
/// bit3 có Energy Expended (UInt16); bit4 có RR-Interval (UInt16, đơn vị 1/1024 s).
public struct HeartRateMeasurement: Sendable, Equatable {
    public let bpm: Int
    /// nil = thiết bị không hỗ trợ phát hiện tiếp xúc.
    public let sensorContact: Bool?
    public let energyExpended: Int?
    /// RR-interval, mili giây.
    public let rrIntervalsMs: [Double]

    public static func parse(_ data: Data) -> HeartRateMeasurement? {
        let b = [UInt8](data)
        guard b.count >= 2 else { return nil }
        let flags = b[0]
        var i = 1
        let bpm: Int
        if flags & 0x01 != 0 {
            guard b.count >= 3 else { return nil }
            bpm = Int(b[1]) | (Int(b[2]) << 8)
            i = 3
        } else {
            bpm = Int(b[1])
            i = 2
        }
        let contactSupported = flags & 0x04 != 0
        let contact: Bool? = contactSupported ? (flags & 0x02 != 0) : nil
        var energy: Int?
        if flags & 0x08 != 0, b.count >= i + 2 {
            energy = Int(b[i]) | (Int(b[i + 1]) << 8)
            i += 2
        }
        var rr: [Double] = []
        if flags & 0x10 != 0 {
            while b.count >= i + 2 {
                rr.append(Double(Int(b[i]) | (Int(b[i + 1]) << 8)) * 1000 / 1024)
                i += 2
            }
        }
        return HeartRateMeasurement(bpm: bpm, sensorContact: contact, energyExpended: energy, rrIntervalsMs: rr)
    }
}

/// Body Sensor Location (2A38).
public func bodySensorLocationName(_ v: UInt8) -> String {
    switch v {
    case 0: return "Khác"
    case 1: return "Ngực"
    case 2: return "Cổ tay"
    case 3: return "Ngón tay"
    case 4: return "Bàn tay"
    case 5: return "Dái tai"
    case 6: return "Bàn chân"
    default: return "Mã \(v)"
    }
}
