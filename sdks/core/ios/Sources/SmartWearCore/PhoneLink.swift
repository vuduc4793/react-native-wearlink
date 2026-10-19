import Foundation

// Kiểu dữ liệu chung cho các tính năng điện thoại ↔ đồng hồ (kế hoạch docs/plans/2026-10-19-full-feature-api.md §2):
// nhạc, danh bạ, gọi điện Bluetooth, mặt đồng hồ, bài tập từ điện thoại, sự kiện nút. Phương thức nằm trên
// `WearableDevice` (mặc định "không hỗ trợ, không làm gì"), driver override. Giá trị `rawValue` của các enum trùng tên
// hằng bên Kotlin (`MusicCommand.PLAY_PAUSE`…) để lớp React Native dùng chung chuỗi.

// MARK: - Nhạc (MusicRemote)

/// Lệnh nhạc người dùng bấm trên thiết bị. App điều khiển trình phát (iOS: chỉ trình phát của chính app, xem
/// `WearableDevice.onMusicCommand`).
public enum MusicCommand: String, CaseIterable, Sendable {
    case playPause = "PLAY_PAUSE"
    case next = "NEXT"
    case previous = "PREVIOUS"
    case volumeUp = "VOLUME_UP"
    case volumeDown = "VOLUME_DOWN"
}

/// Trạng thái trình phát gửi lên thiết bị. Trường nil = không đổi / không có.
public struct MusicState: Equatable, Sendable {
    public var playing: Bool
    public var title: String?
    public var artist: String?
    /// Âm lượng 0–100.
    public var volumePercent: Int?
    public var durationSec: Int?
    public var positionSec: Int?

    public init(
        playing: Bool, title: String? = nil, artist: String? = nil, volumePercent: Int? = nil,
        durationSec: Int? = nil, positionSec: Int? = nil
    ) {
        self.playing = playing
        self.title = title
        self.artist = artist
        self.volumePercent = volumePercent
        self.durationSec = durationSec
        self.positionSec = positionSec
    }
}

// MARK: - Danh bạ (ContactsSync)

/// Một liên hệ ghi lên thiết bị (tên + số).
public struct Contact: Equatable, Sendable {
    public var name: String
    public var phone: String
    public init(name: String, phone: String) {
        self.name = name
        self.phone = phone
    }
}

// MARK: - Gọi điện qua Bluetooth cổ điển (CallAudioLink)

/// Kênh gọi điện Bluetooth cổ điển (HFP) của thiết bị.
public struct CallAudioState: Equatable, Sendable {
    /// Tên Bluetooth cổ điển của thiết bị (người dùng thấy trong Cài đặt > Bluetooth).
    public var name: String
    /// MAC kênh cổ điển, "AA:BB:…".
    public var address: String
    /// Kênh gọi đang bật trên thiết bị.
    public var enabled: Bool
    /// Đã ghép đôi với điện thoại.
    public var paired: Bool
    /// Đang kết nối với điện thoại.
    public var connected: Bool

    public init(name: String = "", address: String = "", enabled: Bool, paired: Bool, connected: Bool = false) {
        self.name = name
        self.address = address
        self.enabled = enabled
        self.paired = paired
        self.connected = connected
    }
}

/// iOS không cho app tự ghép đôi Bluetooth cổ điển: người dùng phải vào Cài đặt > Bluetooth.
public struct CallAudioPairingError: LocalizedError, Equatable, Sendable {
    /// Tên cần chọn trong Cài đặt > Bluetooth (nếu biết).
    public let deviceName: String?
    public init(deviceName: String?) { self.deviceName = deviceName }
    public var errorDescription: String? {
        "iOS không cho app ghép đôi Bluetooth cổ điển: mở Cài đặt > Bluetooth và chọn \(deviceName.map { "\"\($0)\"" } ?? "thiết bị")"
    }
}

// MARK: - Mặt đồng hồ (WatchFaceManager)

/// Thông số màn hình + mặt đồng hồ hiện tại.
public struct WatchFaceInfo: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var round: Bool
    /// Dung lượng tối đa của một file mặt đồng hồ (byte).
    public var maxBytes: Int
    /// Mã mặt đang hiển thị (riêng của hãng).
    public var currentId: Int
    /// Số khe mặt đồng hồ cài thêm được.
    public var slotCount: Int
    /// Mặt đang hiển thị là mặt tuỳ chỉnh do app gửi.
    public var customActive: Bool

    public init(width: Int, height: Int, round: Bool, maxBytes: Int, currentId: Int, slotCount: Int, customActive: Bool) {
        self.width = width
        self.height = height
        self.round = round
        self.maxBytes = maxBytes
        self.currentId = currentId
        self.slotCount = slotCount
        self.customActive = customActive
    }
}

/// Một khe mặt đồng hồ đã cài (tải về / tuỳ chỉnh) trên thiết bị.
public struct WatchFaceSlot: Equatable, Sendable, Identifiable {
    /// Số thứ tự khe, dùng cho `deleteWatchFaceSlot`.
    public var index: Int
    /// Mã mặt đồng hồ trong khe (riêng của hãng).
    public var faceId: Int
    public var id: Int { index }
    public init(index: Int, faceId: Int) {
        self.index = index
        self.faceId = faceId
    }
}

// MARK: - Bài tập từ điện thoại (WorkoutRemote)

/// Một môn thể thao thiết bị biết, và có đang hiện trong danh sách môn trên thiết bị không.
public struct SportType: Equatable, Sendable, Identifiable {
    /// Mã môn (riêng của hãng; GloryFit: `SportsMode`).
    public var type: Int
    public var name: String
    /// Đang hiện trên thiết bị.
    public var shown: Bool
    /// Vị trí trong danh sách hiện (thiết bị tự đánh số).
    public var position: Int
    public var id: Int { type }
    public init(type: Int, name: String, shown: Bool, position: Int) {
        self.type = type
        self.name = name
        self.shown = shown
        self.position = position
    }
}

public enum WorkoutState: String, Sendable {
    case started = "STARTED"
    case paused = "PAUSED"
    case resumed = "RESUMED"
    case stopped = "STOPPED"
}

/// Số liệu bài tập thiết bị đẩy trong lúc tập.
public struct WorkoutRealtime: Equatable, Sendable {
    public var sportType: Int
    public var heartRate: Int?
    public var calories: Int
    /// Pace, giây cho mỗi km (0 = chưa có).
    public var paceSecondsPerKm: Int
    public var steps: Int
    /// Số lần (nhảy dây, sải bơi…).
    public var count: Int
    public var distanceMeters: Int

    public init(sportType: Int, heartRate: Int?, calories: Int, paceSecondsPerKm: Int, steps: Int, count: Int, distanceMeters: Int) {
        self.sportType = sportType
        self.heartRate = heartRate
        self.calories = calories
        self.paceSecondsPerKm = paceSecondsPerKm
        self.steps = steps
        self.count = count
        self.distanceMeters = distanceMeters
    }
}

public enum WorkoutEvent: Equatable, Sendable {
    /// Bài tập đổi trạng thái. `byDevice` = người dùng bấm trên thiết bị; false = thiết bị xác nhận lệnh của app.
    case state(WorkoutState, sportType: Int, byDevice: Bool)
    case realtime(WorkoutRealtime)
}

/// Thiết bị xin (hoặc thôi xin) vị trí điện thoại cho bài tập ngoài trời.
public struct LocationRequest: Equatable, Sendable {
    /// true = bắt đầu gửi vị trí (`sendLocation` định kỳ), false = dừng.
    public var start: Bool
    /// Môn đang tập, nếu thiết bị báo.
    public var sportType: Int?
    public init(start: Bool, sportType: Int? = nil) {
        self.start = start
        self.sportType = sportType
    }
}

// MARK: - Sự kiện lẻ (DeviceEvents)

/// Nút / sự kiện lẻ của thiết bị không thuộc nhóm nào khác.
public enum DeviceEvent: String, Sendable {
    /// Bấm nút đổi màn hình.
    case switchScreenButton = "SWITCH_SCREEN_BUTTON"
    /// Giữ phím thứ 2.
    case longPressButton2 = "LONG_PRESS_BUTTON_2"
    /// Giữ phím thứ 3.
    case longPressButton3 = "LONG_PRESS_BUTTON_3"
    /// Bấm nút SOS.
    case sosButton = "SOS_BUTTON"
}
