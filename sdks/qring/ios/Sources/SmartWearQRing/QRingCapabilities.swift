import Foundation
import SmartWearCore

/// Giải mã hai bảng khả năng QRing: phản hồi SetTime (0x01) và DeviceSupport (0x3C).
/// Tham số là 14 byte payload (byte 1..14 của gói), nên `t(i)` khớp với ký hiệu `p[i]` trong
/// sdks/qring/docs/01-connection.md §4.2 và 02-commands.md §4.4.
public struct QRingCapabilities: Sendable, Equatable {
    public let timeCaps: [UInt8]
    public let supportCaps: [UInt8]

    public init(timeCaps: [UInt8], supportCaps: [UInt8]) {
        self.timeCaps = timeCaps
        self.supportCaps = supportCaps
    }

    private func t(_ i: Int) -> Int { i < timeCaps.count ? Int(timeCaps[i]) : 0 }
    private func s(_ i: Int) -> Int { i < supportCaps.count ? Int(supportCaps[i]) : 0 }
    private func bit(_ v: Int, _ b: Int) -> Bool { (v >> b) & 1 == 1 }

    public var temperature: Bool { t(0) == 1 }
    public var menstruation: Bool { t(2) == 1 }
    public var spo2: Bool { bit(t(3), 1) }
    public var bloodPressure: Bool { bit(t(3), 2) }
    public var oneKeyCheck: Bool { bit(t(3), 4) }
    /// Giấc ngủ qua big-data 0x27 thay vì lệnh 16 byte 0x44.
    public var newSleepProtocol: Bool { t(8) == 1 }
    public var appMeasure: Bool { bit(t(10), 5) }
    public var bloodSugar: Bool { bit(t(11), 7) }
    public var stress: Bool { bit(t(13), 4) }
    public var hrv: Bool { bit(t(13), 5) }

    public var touch: Bool { bit(s(1), 0) }
    public var blePair: Bool { bit(s(1), 3) }
    public var noScreen: Bool { bit(s(1), 6) }
    public var gesture: Bool { bit(s(1), 7) }
    public var ecg: Bool { bit(s(9), 1) }

    /// Tập khả năng chuẩn. Nhịp tim, bước chân và giấc ngủ không có bit riêng: mọi thiết bị QRing
    /// đều có (suy luận từ app QRing, đã đo được nhịp tim trên R09).
    public func toCapabilities() -> Set<Capability> {
        var c: Set<Capability> = [.heartRate, .steps, .sleep]
        if spo2 { c.insert(.spo2) }
        if temperature { c.insert(.temperature) }
        if bloodPressure { c.insert(.bloodPressure) }
        if stress { c.insert(.stress) }
        if hrv { c.insert(.hrv) }
        if bloodSugar { c.insert(.bloodSugar) }
        if ecg { c.insert(.ecg) }
        if menstruation { c.insert(.menstruation) }
        if gesture { c.insert(.gesture) }
        return c
    }

    /// Các cờ đã giải mã, để hiển thị trong "Chi tiết kỹ thuật".
    public var flags: [(name: String, on: Bool)] {
        [
            ("temperature", temperature), ("menstruation", menstruation), ("spo2", spo2),
            ("bloodPressure", bloodPressure), ("oneKeyCheck", oneKeyCheck), ("newSleepProtocol", newSleepProtocol),
            ("appMeasure", appMeasure), ("bloodSugar", bloodSugar), ("stress", stress), ("hrv", hrv),
            ("touch", touch), ("blePair", blePair), ("noScreen", noScreen), ("gesture", gesture), ("ecg", ecg),
        ]
    }
}

public extension Capability {
    /// Phép đo thủ công tương ứng, nil nếu capability đó không đo trực tiếp được.
    var measurementType: MeasurementType? {
        switch self {
        case .heartRate: return .heartRate
        case .spo2: return .spo2
        case .temperature: return .temperature
        case .bloodPressure: return .bloodPressure
        case .stress: return .stress
        case .hrv: return .hrv
        default: return nil
        }
    }
}
