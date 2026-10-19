import Foundation
import SmartWearCore

/// Hàng đợi gói không giới hạn, một người nhận (giống `Channel(UNLIMITED)` Android), chạy trên MainActor.
@MainActor
final class PacketChannel {
    private var buffer: [[UInt8]] = []
    private var waiting: OneShot<[UInt8]>?
    private var closed: Error?

    private struct Timeout: Error {}

    func send(_ p: [UInt8]) {
        // Shot đã xong (vừa hết giờ) thì giữ gói lại trong buffer, không làm rơi.
        if let w = waiting, !w.isCompleted {
            waiting = nil
            w.succeed(p)
        } else {
            buffer.append(p)
        }
    }

    func tryReceive() -> [UInt8]? { buffer.isEmpty ? nil : buffer.removeFirst() }

    /// Đóng kênh (mất kết nối): lần nhận đang chờ và các lần sau ném `error`.
    func close(_ error: Error) {
        closed = error
        waiting?.fail(error)
        waiting = nil
    }

    /// Gói đầu tiên khớp `match` trong `timeout` giây (gói không khớp bị bỏ), nil nếu hết giờ.
    func receive(timeout: TimeInterval, where match: ([UInt8]) -> Bool = { _ in true }) async throws -> [UInt8]? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let p = tryReceive() {
                if match(p) { return p }
                continue
            }
            if let closed { throw closed }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return nil }
            let shot = OneShot<[UInt8]>()
            waiting = shot
            defer { if waiting === shot { waiting = nil } }
            do {
                let p = try await shot.wait(timeout: remaining) { Timeout() }
                if match(p) { return p }
            } catch is Timeout {
                return nil
            }
        }
    }
}
