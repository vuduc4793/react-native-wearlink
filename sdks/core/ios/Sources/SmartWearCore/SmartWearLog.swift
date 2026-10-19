import Foundation
import os

public enum SmartWear {
    public static let version = "0.1.0"
}

/// Log chung của các SDK. `verbose` in từng gói byte gửi/nhận; `echoToStdout` in thêm ra stdout
/// (chế độ tự kiểm thử đọc qua `devicectl --console`).
public enum SmartWearLog {
    nonisolated(unsafe) public static var verbose = false
    nonisolated(unsafe) public static var echoToStdout = false

    private static let logger = Logger(subsystem: "com.smartwear", category: "SmartWear")

    public static func v(_ message: @autoclosure () -> String) {
        guard verbose else { return }
        let m = message()
        logger.debug("\(m, privacy: .public)")
        echo("V", m)
    }

    public static func d(_ message: String) { logger.debug("\(message, privacy: .public)"); echo("D", message) }
    public static func i(_ message: String) { logger.info("\(message, privacy: .public)"); echo("I", message) }
    public static func w(_ message: String) { logger.warning("\(message, privacy: .public)"); echo("W", message) }
    public static func e(_ message: String) { logger.error("\(message, privacy: .public)"); echo("E", message) }

    private static func echo(_ level: String, _ message: String) {
        if echoToStdout { print("\(stamp.string(from: Date())) [SmartWear/\(level)] \(message)") }
    }

    nonisolated(unsafe) private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// Có in ra stdout không (để nơi khác in thêm sự kiện mức info khi theo dõi qua console).
    public static var echoing: Bool { echoToStdout }
}

public extension Sequence where Element == UInt8 {
    var hex: String { map { String(format: "%02X", $0) }.joined(separator: " ") }
}

public extension Data {
    /// "01 02 AB" hoặc "0102ab".
    init?(hex: String) {
        let clean = hex.filter { !$0.isWhitespace }
        guard clean.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        var idx = clean.startIndex
        while idx < clean.endIndex {
            let next = clean.index(idx, offsetBy: 2)
            guard let b = UInt8(clean[idx..<next], radix: 16) else { return nil }
            bytes.append(b)
            idx = next
        }
        self.init(bytes)
    }
}
