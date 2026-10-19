import Foundation
@testable import SmartWearVeepoo

/// Hỗ trợ kiểm thử: hex → byte, lịch cố định GMT+7.
enum T {
    static func hex(_ s: String) -> [UInt8] {
        let clean = s.replacingOccurrences(of: " ", with: "")
        return stride(from: 0, to: clean.count, by: 2).map {
            let a = clean.index(clean.startIndex, offsetBy: $0)
            return UInt8(clean[a..<clean.index(a, offsetBy: 2)], radix: 16)!
        }
    }

    static let tz = TimeZone(secondsFromGMT: 7 * 3600)!
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = tz
        return c
    }()

    static func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }

    static func pad(_ b: [UInt8], _ n: Int = 20) -> [UInt8] { b + [UInt8](repeating: 0, count: max(0, n - b.count)) }
}
