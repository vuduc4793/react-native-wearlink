import Foundation

/// Thiết bị có GPS riêng hỏi điện thoại về AGPS (dữ liệu hỗ trợ bắt vệ tinh). Cùng nghĩa với `AgpsRequestType` Android.
public enum AgpsRequestType: String, Sendable {
    /// Hỏi điện thoại đã có file dữ liệu vệ tinh chưa. Đồng hồ hết dữ liệu thì hỏi định kỳ (HT43: mỗi 60 s).
    case status = "STATUS"
    /// Thiết bị sẵn sàng nhận file (sau khi điện thoại báo đã có file).
    case download = "DOWNLOAD"
    /// Thiết bị xin vị trí điện thoại.
    case position = "POSITION"
}

/// Một lần thiết bị hỏi AGPS. `handled` = driver đã tự trả lời bằng file / vị trí app đặt sẵn.
public struct AgpsRequest: Sendable, Equatable {
    public var type: AgpsRequestType
    public var handled: Bool

    public init(type: AgpsRequestType, handled: Bool) {
        self.type = type
        self.handled = handled
    }
}

/// Thông tin AGPS thiết bị báo. `files` = tên file thiết bị cần (gửi đúng tên này); `version` = mã nền tảng GNSS;
/// `interval` = giá trị chu kỳ thiết bị báo (đơn vị chưa rõ); `ephemerisValid` = còn dữ liệu vệ tinh hợp lệ, nil = không hỏi được.
public struct AgpsInfo: Sendable, Equatable {
    public var files: [String]
    public var version: Int?
    public var interval: Int?
    public var ephemerisValid: Bool?

    public init(files: [String], version: Int?, interval: Int?, ephemerisValid: Bool?) {
        self.files = files
        self.version = version
        self.interval = interval
        self.ephemerisValid = ephemerisValid
    }
}

/// Một file dữ liệu vệ tinh. `name` lấy từ `AgpsInfo.files`. Nội dung do app tự lấy từ nguồn được phép, SDK chỉ chuyển.
public struct AgpsFile: Sendable, Equatable {
    public var name: String
    public var data: Data

    public init(name: String, data: Data) {
        self.name = name
        self.data = data
    }
}
