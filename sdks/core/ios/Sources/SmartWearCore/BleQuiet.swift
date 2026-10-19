import Foundation

/// Giữ sóng BLE yên khi đang truyền file lớn (mặt đồng hồ), bản iOS của `BleQuiet` Android:
/// `WearableDevice.updateRSSI` (DeviceManager gọi định kỳ) bỏ qua và `DeviceManager` hoãn các lần thử nối lại
/// cho đến khi hết `hold`. Trên Android một lần đọc RSSI chậm làm luồng ghi đứng vài giây và đồng hồ HT43 huỷ
/// nhận (`26 03 01`).
@MainActor
public enum BleQuiet {
    private static var holders = 0

    /// Đang có ai giữ (đang truyền file lớn).
    public static var active: Bool { holders > 0 }

    public static func hold<T>(_ body: () async throws -> T) async rethrows -> T {
        holders += 1
        defer { holders -= 1 }
        return try await body()
    }

    /// Chờ tới khi không còn ai giữ. Dừng sớm nếu Task bị huỷ.
    public static func awaitIdle(poll: TimeInterval = 0.25) async {
        while active, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(poll * 1_000_000_000))
        }
    }
}
