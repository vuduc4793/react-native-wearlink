import Foundation

/// Lớp "Cài đặt & điều khiển" chung (bản Swift của `Controls.kt`): mỗi tính năng không phải phép đo (tìm đồng hồ,
/// nhắc vận động, không làm phiền, mục tiêu, đo tự động…) là một `DeviceControl`. Driver dựng danh sách theo bảng
/// tính năng của chính thiết bị và giữ lệnh thật; app chỉ vẽ theo `kind`, nên thêm tính năng không cần sửa giao diện.
public struct DeviceControl: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable { case action, toggle, number, timeRange, choice }

    /// Khoá ổn định, vd "sedentary.enabled".
    public let id: String
    /// Nhóm hiển thị, vd "Nhắc nhở".
    public let group: String
    public let title: String
    public let kind: Kind
    public var value: ControlValue?
    public var detail: String?
    /// `.number`: khoảng và bước.
    public var min = 0
    public var max = 0
    public var step = 1
    public var unit = ""
    /// `.choice`: nhãn các lựa chọn (giá trị là chỉ số).
    public var options: [String] = []
    /// Khoá khi mục cha đang tắt (vd chu kỳ nhắc khi đang tắt nhắc).
    public var enabled = true
    /// `.action` nguy hiểm (xoá dữ liệu, xoá danh bạ): câu hỏi app phải cho người dùng xác nhận trước khi `runAction`.
    public var confirm: String?

    public init(
        _ id: String, group: String, title: String, kind: Kind, value: ControlValue? = nil, detail: String? = nil,
        min: Int = 0, max: Int = 0, step: Int = 1, unit: String = "", options: [String] = [], enabled: Bool = true,
        confirm: String? = nil
    ) {
        self.id = id
        self.group = group
        self.title = title
        self.kind = kind
        self.value = value
        self.detail = detail
        self.min = min
        self.max = max
        self.step = step
        self.unit = unit
        self.options = options
        self.enabled = enabled
        self.confirm = confirm
    }
}

public enum ControlValue: Equatable, Sendable {
    case bool(Bool)
    case number(Int)
    /// Khung giờ, phút tính từ 0:00.
    case timeRange(from: Int, to: Int)
}

/// Thiết bị có cài đặt / điều khiển. Danh sách mục nằm ở `WearableDevice.controls` (quan sát được, SwiftUI tự vẽ lại),
/// yêu cầu tìm điện thoại báo qua `WearableDevice.onFindPhone`.
@MainActor
public protocol ConfigurableDevice: AnyObject {
    /// Đổi một mục (lưu lại và gửi xuống thiết bị ngay nếu đang kết nối).
    func setControl(_ id: String, _ value: ControlValue) async throws
    /// Chạy một hành động (vd "find.start").
    func runAction(_ id: String) async throws
}

/// Một báo thức trên thiết bị (cùng hình dạng với `Alarm` Android). `id` do thiết bị/driver cấp; `id < 0` = báo thức mới
/// (dùng với `WearableDevice.setAlarm`). `repeatDays`: bit0 = Thứ Hai … bit6 = Chủ Nhật, 0 = một lần. `label` nil = không nhãn.
public struct Alarm: Equatable, Hashable, Sendable, Identifiable, Codable {
    public var id: Int
    public var hour: Int
    public var minute: Int
    public var repeatDays: Int
    public var enabled: Bool
    public var label: String?

    public init(id: Int = -1, hour: Int, minute: Int, repeatDays: Int = 0, enabled: Bool = true, label: String? = nil) {
        self.id = id
        self.hour = hour
        self.minute = minute
        self.repeatDays = repeatDays
        self.enabled = enabled
        self.label = label
    }

    /// Bit cho từng ngày trong `repeatDays`.
    public static let monday = 1, tuesday = 2, wednesday = 4, thursday = 8, friday = 16, saturday = 32, sunday = 64
    public static let everyDay = 0x7F
    public static let weekdays = 0x1F
}

/// Phút trong ngày → "hh:mm".
public func formatMinuteOfDay(_ m: Int) -> String { String(format: "%02d:%02d", (m / 60) % 24, m % 60) }
