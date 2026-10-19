import SmartWearCore
import XCTest
@testable import SmartWearGloryFit

/// Hàng đợi gói dùng cho request / truyền mặt đồng hồ (thay `Channel` Android).
@MainActor
final class PacketChannelTests: XCTestCase {
    func testBufferedThenWaiting() async throws {
        let c = PacketChannel()
        c.send([0x26, 0x02])
        let first = try await c.receive(timeout: 1)
        XCTAssertEqual([0x26, 0x02], first)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            c.send([0x26, 0x03, 0x04])
        }
        let second = try await c.receive(timeout: 2)
        XCTAssertEqual([0x26, 0x03, 0x04], second)
    }

    func testTimeoutReturnsNilAndLatePacketKept() async throws {
        let c = PacketChannel()
        let none = try await c.receive(timeout: 0.05)
        XCTAssertNil(none)
        c.send([0xA2, 0x2D])
        XCTAssertEqual([0xA2, 0x2D], c.tryReceive())
        XCTAssertNil(c.tryReceive())
    }

    func testFilterDropsNonMatching() async throws {
        let c = PacketChannel()
        c.send([0x26, 0x02])
        c.send([0x26, 0x03, 0x04])
        let p = try await c.receive(timeout: 1, where: { $0.count >= 2 && $0[1] == 0x03 })
        XCTAssertEqual([0x26, 0x03, 0x04], p)
        XCTAssertNil(c.tryReceive())
    }

    func testCloseFailsWaiter() async {
        let c = PacketChannel()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            c.close(GattError.disconnected)
        }
        do {
            _ = try await c.receive(timeout: 5)
            XCTFail("phải ném lỗi")
        } catch {
            XCTAssertEqual(GattError.disconnected, error as? GattError)
        }
    }
}
