import Foundation
import SmartWearCore

/// Khung lệnh 16 byte trên kênh 6e400002/6e400003:
/// `[0]=cmd  [1..14]=payload (thiếu thì đệm 0)  [15]=checksum = Σ byte[0..14] & 0xFF`.
/// Bit 7 của byte cmd trong phản hồi là cờ lỗi. Xem sdks/qring/docs/01-connection.md §3.3.
public struct Packet: Sendable, Equatable, CustomStringConvertible {
    public static let size = 16
    public static let errorFlag: UInt8 = 0x80

    public let bytes: [UInt8]

    private init(bytes: [UInt8]) { self.bytes = bytes }

    /// Mã lệnh, đã bỏ cờ lỗi.
    public var command: UInt8 { bytes[0] & 0x7F }

    public var isError: Bool { bytes[0] & Packet.errorFlag != 0 }

    /// 14 byte payload (byte 1..14).
    public var payload: [UInt8] { Array(bytes[1..<15]) }

    /// Byte payload thứ `index` (0..13) dưới dạng số không dấu.
    public func u8(_ index: Int) -> Int { Int(bytes[1 + index]) }

    public var data: Data { Data(bytes) }

    public var description: String { bytes.hex }

    public static func of(_ command: UInt8, _ payload: UInt8...) -> Packet {
        of(command, payload: payload)
    }

    public static func of(_ command: UInt8, payload: [UInt8]) -> Packet {
        precondition(payload.count <= 14, "payload tối đa 14 byte, nhận \(payload.count)")
        var b = [UInt8](repeating: 0, count: size)
        b[0] = command
        for (i, v) in payload.enumerated() { b[1 + i] = v }
        b[15] = checksum(b)
        return Packet(bytes: b)
    }

    /// nil nếu không đúng 16 byte hoặc sai checksum.
    public static func parse(_ raw: [UInt8]) -> Packet? {
        guard raw.count == size, checksum(raw) == raw[15] else { return nil }
        return Packet(bytes: raw)
    }

    public static func parse(_ raw: Data) -> Packet? { parse([UInt8](raw)) }

    public static func checksum(_ b: [UInt8]) -> UInt8 {
        var sum = 0
        for i in 0..<15 { sum += Int(b[i]) }
        return UInt8(sum & 0xFF)
    }
}
