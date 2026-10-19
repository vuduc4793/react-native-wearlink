import Foundation
import SmartWearCore

/// Khung "big data" trên service de5bf728 (ghi de5bf72a, notify de5bf729):
/// `BC  cmd  len(LE16)  crc16(LE16)  payload…`, CRC là CRC-16/MODBUS của payload.
/// Khi gửi, cả khung được cắt thành các đoạn bằng kích thước gói (mặc định 20), chỉ đoạn đầu có `BC`.
/// Xem sdks/qring/docs/01-connection.md §5.
public struct BigDataFrame: Sendable, Equatable {
    public static let magic: UInt8 = 0xBC
    public static let headerSize = 6

    public let command: UInt8
    public let payload: [UInt8]

    public init(command: UInt8, payload: [UInt8]) {
        self.command = command
        self.payload = payload
    }

    public func encode() -> [UInt8] {
        let crc = payload.isEmpty ? 0xFFFF : BigDataFrame.crc16Modbus(payload)
        let len = payload.count
        return [
            BigDataFrame.magic, command,
            UInt8(len & 0xFF), UInt8((len >> 8) & 0xFF),
            UInt8(crc & 0xFF), UInt8((crc >> 8) & 0xFF),
        ] + payload
    }

    /// Cắt khung thành các đoạn `chunkSize` byte để ghi lần lượt.
    public func chunks(_ chunkSize: Int) -> [[UInt8]] {
        let data = encode()
        return stride(from: 0, to: data.count, by: chunkSize).map { Array(data[$0..<min($0 + chunkSize, data.count)]) }
    }

    public static func crc16Modbus(_ data: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for b in data {
            crc ^= UInt16(b)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1
            }
        }
        return crc
    }
}

/// Ghép các notify trên de5bf729 thành khung hoàn chỉnh. Gọi từ một luồng (MainActor).
/// Khác SDK gốc: kiểm tra CRC, sai thì cảnh báo (chưa bỏ khung, chờ xác minh trên nhẫn thật như Android).
public final class BigDataAssembler {
    private let onFrame: (BigDataFrame) -> Void
    private var buffer: [UInt8] = []
    private var expected = -1

    public init(onFrame: @escaping (BigDataFrame) -> Void) { self.onFrame = onFrame }

    public func feed(_ chunk: [UInt8]) {
        if expected < 0 {
            guard chunk.count >= BigDataFrame.headerSize, chunk[0] == BigDataFrame.magic else { return }
            expected = BigDataFrame.headerSize + (Int(chunk[2]) | (Int(chunk[3]) << 8))
            buffer = chunk
        } else {
            buffer += chunk
        }
        if buffer.count >= expected {
            let frame = Array(buffer.prefix(expected))
            reset()
            emit(frame)
        }
    }

    public func reset() {
        buffer = []
        expected = -1
    }

    private func emit(_ raw: [UInt8]) {
        let payload = Array(raw[BigDataFrame.headerSize...])
        let crc = UInt16(raw[4]) | (UInt16(raw[5]) << 8)
        let expectedCrc = payload.isEmpty ? 0xFFFF : BigDataFrame.crc16Modbus(payload)
        if crc != expectedCrc {
            SmartWearLog.w(String(format: "Big-data cmd=0x%02X sai CRC: %04X != %04X", raw[1], crc, expectedCrc))
        }
        onFrame(BigDataFrame(command: raw[1], payload: payload))
    }
}
