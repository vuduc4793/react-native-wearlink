import Foundation
import SmartWearCore

/// Bảng tính năng `A7` (thiết bị tự đẩy 5 gói ngay sau `A1`, `[19]` = số trang 1..5), parser `jf/y.java:39-493`, bảng tên /
/// giá trị gốc `home/profile/viewModel/a.java:12,15` (bản Swift của `VeepooFeatures.kt`). Giữ nguyên byte thô, đọc từng cờ
/// qua thuộc tính. Quy ước: 0 = không có, khác 0 = có, trừ chỗ ghi riêng. Trang thiếu ⇒ coi mọi byte là 0.
public struct VeepooFeatures: Equatable, Sendable {
    public let pages: [Int: [UInt8]]

    public init(pages: [Int: [UInt8]] = [:]) { self.pages = pages }

    /// Gom các gói `A7` (≥ 20 byte) theo số trang ở byte 19; gói sau đè gói trước cùng trang.
    public init(packets: [[UInt8]]) {
        var p: [Int: [UInt8]] = [:]
        for x in packets where x.count >= 20 && x[0] == 0xA7 { p[Int(x[19])] = x }
        self.init(pages: p)
    }

    /// Byte `index` (1..18) của trang `page` (1..5).
    public func b(_ page: Int, _ index: Int) -> Int { pages[page].map { index < $0.count ? Int($0[index]) : 0 } ?? 0 }

    public var complete: Bool { (1...5).allSatisfy { pages[$0] != nil } }

    // Trang 1

    /// 0 không; 1 có; 2 tự đánh giá; 3 bơm hơi không ADC; 4 có (đọc qua `DE`); 5 bơm hơi có ADC.
    public var bpType: Int { b(1, 1) }
    public var bloodPressure: Bool { bpType != 0 }
    /// 1 = nhắc ngồi lâu `E1`; 2 = nhắc sức khoẻ `E7` (loại trừ `E1`).
    public var sedentaryType: Int { b(1, 3) }
    public var longSeat: Bool { sedentaryType == 1 }
    public var healthRemind: Bool { sedentaryType == 2 }
    public var skinType: Int { b(1, 4) }
    /// 1 mở trang chụp ảnh; 2 thường trú (HID iOS).
    public var camera: Bool { b(1, 6) == 1 || b(1, 6) == 2 }
    public var spo2Type: Int { b(1, 8) }
    public var spo2: Bool { (1...9).contains(spo2Type) || spo2Type == 0xFD || spo2Type == 0xFE || spo2Type == 0xE0 }
    /// Số gói nội dung thông báo tối đa; 0 = 4 gói (`getAllLength`).
    public var messagePackets: Int { b(1, 9) == 0 ? 4 : b(1, 9) }
    public var heartRateAlarm: Bool { b(1, 10) == 1 }
    /// 0 kiểu cũ (`AA` dựng sẵn), 1 có `AA` đầy đủ, 2 không có nâng tay.
    public var wristTurnType: Int { b(1, 11) }
    public var womenTag: Int { b(1, 12) }
    /// Số mức độ sáng; khác 0 = có `B1`.
    public var brightness: Bool { b(1, 13) != 0 }
    /// 0 = 3 báo thức cũ `AB`; 1–4 = `B9` nhiều báo thức; 5/6/7 = báo thức có chữ; FE = không có báo thức.
    public var alarmType: Int { b(1, 17) }
    public var multiAlarm: Bool { (1...4).contains(alarmType) }
    public var textAlarm: Bool { (5...7).contains(alarmType) }
    public var legacyAlarm: Bool { alarmType == 0 }
    /// Byte 18: **0 = có nhịp tim**, 1 = không, 2–8 = biến thể cảm biến.
    public var heartRate: Bool { b(1, 18) != 1 }

    // Trang 2

    public var countDown: Bool { b(2, 1) == 1 }
    /// Số ngày lịch sử đọc được; 0 = 3 ngày.
    public var watchDays: Int { b(2, 2) == 0 ? 3 : b(2, 2) }
    /// Số gói tên người gửi trong thông báo (`contactMsgLength`).
    public var contactMsgLength: Int { b(2, 3) }
    /// Số buổi tập lưu được (`sportModelDay`); khác 0 = có chế độ thể thao.
    public var sportModelSlots: Int { b(2, 5) }
    public var sportModel: Bool { sportModelSlots != 0 }
    /// Số kiểu màn dựng sẵn (`C7`).
    public var screenStyleCount: Int { b(2, 6) }
    public var hrvType: Int { b(2, 8) }
    public var hrv: Bool { hrvType != 0 && hrvType != 5 }
    /// HRV đo được từ app (`89 07`): kiểu 7/8.
    public var hrvByApp: Bool { hrvType == 7 || hrvType == 8 }
    public var weatherType: Int { b(2, 9) }
    public var weather: Bool { weatherType != 0 }
    /// 0 = 5 phút `D1`; 3 hoặc 5 = `DF` TLV; 4/5 = layout "sport model".
    public var originProtocolVersion: Int { b(2, 10) }
    public var usesDf: Bool { originProtocolVersion == 3 || originProtocolVersion == 5 }
    /// `isParseSportModel` (`VpSpGetUtil.java:391-395`): có chế độ thể thao hoặc originProtocolVersion 4/5 ⇒ `D8` thay `A8`
    /// và layout "sport model" của `D1`.
    public var parseSportModel: Bool { sportModel || originProtocolVersion == 4 || originProtocolVersion == 5 }
    public var screenOnTime: Bool { b(2, 12) != 0 }
    /// 0 ngủ cũ; 1 ngủ chính xác; 2 không có ngủ; 3 KH; 4/5 ZK; 6 nhẫn. Khác 0 ⇒ parser chính xác.
    public var sleepTag: Int { b(2, 13) }
    public var sleep: Bool { sleepTag != 2 }
    public var preciseSleep: Bool { sleepTag != 0 }
    public var ecg: Bool { b(2, 15) != 0 }
    /// `MULTSPORTMODEL_TYPE`; 4/5/6 = buổi tập dạng TLV (`parseTlvWorkout`, GE54 = 5).
    public var multiSportType: Int { b(2, 16) }
    public var tlvWorkout: Bool { [4, 5, 6].contains(multiSportType) }

    // Trang 3

    /// Cách truyền file lớn; mặt đồng hồ Veepoo gốc cần = 2.
    public var bigDataTranType: Int { b(3, 1) }
    public var watchUiServerCount: Int { (b(3, 2) >> 4) & 0x0F }
    public var watchUiCustomCount: Int { b(3, 2) & 0x0F }
    /// 0 không; 1 có (10); 2 có + SOS (10); 3 có + SOS (20).
    public var contactType: Int { b(3, 4) }
    public var contacts: Bool { contactType != 0 }
    public var maxContacts: Int { contactType == 3 ? 20 : contactType != 0 ? 10 : 0 }
    /// `musicType`; 1 = giao thức `99` mới (có tên bài), khác = kiểu cũ (`01 01 01 xx`).
    public var musicType: Int { b(3, 6) }
    /// 1 đo tay; 2 tay + tự động (`88`); 4 da; 5/6 ZK (lịch sử qua `DF` tag C3).
    public var temperatureType: Int { b(3, 7) }
    public var temperature: Bool { temperatureType != 0 }
    public var findDeviceByPhone: Bool { b(3, 8) != 0 }
    public var agps: Bool { b(3, 9) != 0 }
    public var bloodGlucoseType: Int { b(3, 15) }
    public var bloodGlucose: Bool { bloodGlucoseType != 0 && bloodGlucoseType != 3 }
    /// Hiệu chuẩn đường huyết nhiều điểm `89 03` (kiểu 4/5/7/8/9, GE54 = 4, `y.java:381-387`).
    public var glucoseMultiCalibration: Bool { [4, 5, 7, 8, 9].contains(bloodGlucoseType) }
    /// Hiệu chuẩn đường huyết một điểm `89 02` (kiểu 2/3/6).
    public var glucoseSingleCalibration: Bool { [2, 3, 6].contains(bloodGlucoseType) }
    /// 0 Nordic/Goodix, 1 JieLi AC7013, 2 Actions, 3 ZK568X, 4 ZK569X, 5 Nordic 54L.
    public var cpuType: Int { b(3, 16) }
    public var met: Bool { b(3, 17) == 2 || b(3, 17) == 3 }
    /// MET đo được từ app (`89 08`) chỉ khi kiểu 3 (`isSupportMetAppDetect`); GE54 = 2 ⇒ MET chỉ có trong lịch sử `DF` tag `BF`.
    public var metByApp: Bool { b(3, 17) == 3 }
    public var stress: Bool { b(3, 18) == 2 || b(3, 18) == 3 }

    // Trang 4

    /// Thành phần máu (acid uric + mỡ máu, `8A`): 0 không; khác 0 có (GE54 = 2).
    public var bloodComponentType: Int { b(4, 1) }
    public var bloodComponent: Bool { bloodComponentType != 0 }
    /// Thành phần cơ thể (đo nhanh `93 04`): khác 0 có (GE54 = 1).
    public var bodyComponent: Bool { b(4, 2) != 0 }
    public var worldClock: Bool { b(4, 3) == 1 }
    /// 1 = đo tự động kiểu mới `B3`; 0 = công tắc trong `B8`.
    public var autoMeasureB3: Bool { b(4, 12) == 1 }
    public var sportControl: Bool { b(4, 13) != 0 }

    // Trang 5

    /// 1 không màn, 2 nhẫn, 3 vuông, 4 tròn.
    public var screenShape: Int { b(5, 4) }
    /// Vòng tay không màn hình (GE54).
    public var screenless: Bool { screenShape == 1 }
    /// Có màn hình (đã đọc bảng A7 và không phải kiểu "không màn"), như điều kiện hiện ngôn ngữ của Android.
    public var hasScreen: Bool { !screenless && !pages.isEmpty }

    /// Có mặt đồng hồ Veepoo gốc (chợ / ảnh tuỳ chỉnh) qua kênh `50` + DOOG (`UiUpdateUtil.java:567-577`). Chip JieLi / ZK
    /// dùng đường riêng cần thư viện native: không hỗ trợ.
    public var nativeWatchFace: Bool {
        bigDataTranType == 2 && (watchUiServerCount > 0 || watchUiCustomCount > 0) && ![1, 3, 4].contains(cpuType)
    }

    public var cpuName: String {
        switch cpuType {
        case 0: "Nordic/Goodix"
        case 1: "JieLi AC7013"
        case 2: "Actions"
        case 3: "ZK568X (Bluetrum)"
        case 4: "ZK569X (Bluetrum)"
        case 5: "Nordic 54L"
        default: "không rõ (\(cpuType))"
        }
    }

    /// Capability chuẩn hoá.
    public func capabilities() -> Set<Capability> {
        var s: Set<Capability> = [.steps]
        if heartRate { s.insert(.heartRate) }
        if spo2 { s.insert(.spo2) }
        if bloodPressure { s.insert(.bloodPressure) }
        if temperature { s.insert(.temperature) }
        if stress { s.insert(.stress) }
        if hrv { s.insert(.hrv) }
        if bloodGlucose { s.insert(.bloodSugar) }
        // ECG (A7 gói 2 byte 15) có cờ trên GE54 nhưng driver không đo / đọc ECG (sóng qua F0020002) ⇒ không báo, như Android.
        if met { s.insert(.met) }
        if bloodComponent {
            s.insert(.uricAcid)
            s.insert(.bloodLipids)
        }
        if bodyComponent { s.insert(.bodyComposition) }
        if sleep { s.insert(.sleep) }
        if womenTag != 0 { s.insert(.menstruation) }
        return s
    }

    /// Mỗi byte khác 0 kèm tên (để log / "Chi tiết kỹ thuật"); byte 0 bỏ qua.
    public func describe() -> String {
        (1...5).map { page in
            let names = Self.names[page - 1]
            let items = names.indices.compactMap { i -> String? in
                let v = b(page, i + 1)
                return v == 0 ? nil : "\(names[i])=" + String(format: "%02X", v)
            }
            return "A7.\(page): " + items.joined(separator: ", ")
        }.joined(separator: "; ")
    }

    /// Tên từng byte 1..18 (trang 5: 1..13) theo bảng debug của app (`profile/viewModel/a.java:12`), như Android.
    static let names: [[String]] = [
        ["huyết áp", "rượu", "ngồi lâu/nhắc", "loại da", "WeChat", "camera", "mệt mỏi", "SpO2", "số gói tin", "cảnh báo HR",
         "nâng tay", "phụ nữ", "độ sáng", "C3", "độ chính xác q.đường", "HA cao cấp", "báo thức", "nhịp tim(0=có)"],
        ["đếm ngược", "số ngày", "gói tên tin", "HID", "thể thao", "kiểu UI", "nhịp thở", "HRV", "thời tiết", "originProtocol",
         "A5 hoàn thiện", "sáng màn", "sleepTag", "xoá dữ liệu", "ECG", "kiểu thể thao", "tiết kiệm pin", "TP"],
        ["bigDataTranType", "mặt server/tuỳ chỉnh", "lão hoá", "danh bạ", "hướng dẫn", "nhạc", "nhiệt độ", "tìm vòng tay",
         "AGPS", "GPS", "địa từ", "ẩn mật khẩu", "mic", "quảng bá", "đường huyết", "cpuType", "MET", "stress"],
        ["thành phần máu", "thành phần cơ thể", "đồng hồ thế giới", "cảnh báo nhiệt độ", "ví", "danh thiếp", "trò chơi", "AI hỏi đáp",
         "AI mặt đồng hồ", "mục tiêu q.đường/kcal", "mặt video", "đo tự động B3", "điều khiển thể thao DA", "album", "4G",
         "danh thiếp điện tử", "đánh giá sức khoẻ", "mini checkup"],
        ["đẩy chữ/ảnh", "GSR", "an toàn SOS", "kiểu màn", "khí áp", "IC cảm ứng", "giao thức sản xuất mới", "PTT",
         "trạng thái thể thao", "sự kiện nhắc", "cảm xúc", "lọt sáng", "đèn sức khoẻ"],
    ]
}

/// Bảng `AD` (thiết bị đẩy sau `A1`, đọc lại bằng `AD 02`): trạng thái thông báo từng app, 0 = không hỗ trợ, 1 = bật, 2 = tắt
/// (bản Swift của `VeepooMessageSwitches.kt`). Gói 0 (`[19]` nibble cao 0): byte 2..18 = appType 0..16, **byte 19 = "khác"
/// (17)**. Gói 1 (`[19]` = 0x10): byte 2..14 = appType 18..30 (`jf/d2.java:465-557`). Riêng điện thoại (byte 2 gói 0) 0 cũng
/// coi là tắt. Trên iOS nội dung thông báo do vòng tay đọc qua ANCS; app chỉ bật/tắt từng app bằng `AD 01` (§6.7).
public struct VeepooMessageSwitches: Equatable, Sendable {
    public let page0: [UInt8]?
    public let page1: [UInt8]?

    public init(page0: [UInt8]?, page1: [UInt8]?) {
        self.page0 = page0
        self.page1 = page1
    }

    /// Gom các gói `AD` (≥ 20 byte) theo nibble cao của byte 19.
    public init(packets: [[UInt8]]) {
        let ad = packets.filter { $0.count >= 20 && $0[0] == 0xAD }
        self.init(page0: ad.last { $0[19] >> 4 == 0 }, page1: ad.last { $0[19] >> 4 == 1 })
    }

    public static let read: [UInt8] = [0xAD, 0x02]

    /// Trạng thái của appType `type` (0..30): 0 không hỗ trợ, 1 bật, 2 tắt.
    public func status(_ type: Int) -> Int {
        switch type {
        case 0...16: page0.map { Veepoo.u($0, type + 2) } ?? 0
        case 17: page0.map { Veepoo.u($0, 19) & 0x0F } ?? 0
        case 18...30: page1.map { Veepoo.u($0, type - 16) } ?? 0
        default: 0
        }
    }

    public func supported(_ type: Int) -> Bool { status(type) != 0 || (type == 0 && page0 != nil) }
    public func isOn(_ type: Int) -> Bool { status(type) == 1 }
    public var any: Bool { page0 != nil }

    /// appType được hỗ trợ, theo thứ tự.
    public var supportedTypes: [Int] { (0...30).filter(supported) }

    /// Gói ghi `AD 01 …` bật/tắt từng app (`on` theo appType). Giữ 0 cho app thiết bị không hỗ trợ. Gói 1 chỉ gửi nếu có app
    /// nào ở gói 1 được hỗ trợ (`d2.java:440-462`).
    public func writePackets(_ on: (Int) -> Bool) -> [[UInt8]] {
        func st(_ t: Int) -> UInt8 { !supported(t) ? 0 : on(t) ? 1 : 2 }
        var p0 = [UInt8](repeating: 0, count: 20)
        p0[0] = 0xAD
        p0[1] = 0x01
        for t in 0...16 { p0[t + 2] = st(t) }
        p0[19] = st(17)
        var out = [p0]
        if (18...30).contains(where: supported) {
            var p1 = [UInt8](repeating: 0, count: 20)
            p1[0] = 0xAD
            p1[1] = 0x01
            for t in 18...30 { p1[t - 16] = st(t) }
            p1[19] = 0x10
            out.append(p1)
        }
        return out
    }

    /// Bản sao sau khi đổi một app (để giữ đồng bộ với vòng tay mà không cần đọc lại).
    public func with(_ type: Int, on: Bool) -> VeepooMessageSwitches {
        let packets = writePackets { $0 == type ? on : isOn($0) }
        return VeepooMessageSwitches(page0: packets.first, page1: packets.count > 1 ? packets[1] : page1)
    }

    /// Tên app theo appType (`ESocailMsg.java:7-38`).
    public static let appNames: [Int: String] = [
        0: "Cuộc gọi", 1: "Tin nhắn SMS", 2: "WeChat", 3: "QQ", 4: "Sina Weibo", 5: "Facebook", 6: "Twitter", 7: "Flickr",
        8: "LinkedIn", 9: "WhatsApp", 10: "LINE", 11: "Instagram", 12: "Snapchat", 13: "Skype", 14: "Gmail", 15: "DingTalk",
        16: "WeCom", 17: "Ứng dụng khác", 18: "TikTok", 19: "Telegram", 20: "Connected2me", 21: "KakaoTalk", 22: "ShieldPolice",
        23: "Messenger", 24: "Zalo", 25: "Viber", 26: "App tuỳ chỉnh", 27: "VK", 28: "Max", 29: "OK", 30: "VK Messenger",
    ]

    public var description: String { "AD0=\(page0?.hex ?? "-") AD1=\(page1?.hex ?? "-")" }
}

/// Bảng `B8` (cài đặt tuỳ chỉnh): 2 gói `[19]` = 0/1, `[1]` = 2 (đọc) / 1 (ghi) (bản Swift của `VeepooCustomSettings.kt`).
/// Byte trạng thái 0 = không hỗ trợ, 1 = bật, 2 = tắt; ngoại lệ: đơn vị (byte 2: 1 metric / 2 imperial), giờ (byte 3:
/// **1 = 24h, 2 = 12h**), °C/°F (gói 1 byte 5). Ghi lại = gói đã đọc, đổi đúng byte cần đổi, `[1]` = 1 (`jf/t.java:83-152`).
public struct VeepooCustomSettings: Equatable, Sendable {
    public let page0: [UInt8]?
    public let page1: [UInt8]?

    public init(page0: [UInt8]?, page1: [UInt8]?) {
        self.page0 = page0
        self.page1 = page1
    }

    public init(packets: [[UInt8]]) {
        let b8 = packets.filter { $0.count >= 20 && $0[0] == 0xB8 }
        self.init(page0: b8.last { $0[19] == 0 }, page1: b8.last { $0[19] == 1 })
    }

    public static let read: [UInt8] = [0xB8, 0x02]

    public func value(_ page: Int, _ index: Int) -> Int { (page == 0 ? page0 : page1).map { Veepoo.u($0, index) } ?? 0 }
    public func supported(_ page: Int, _ index: Int) -> Bool { value(page, index) != 0 }
    public func isOn(_ page: Int, _ index: Int) -> Bool { value(page, index) == 1 }

    public var metric: Bool { value(0, Self.units) != 2 }
    public var is24h: Bool { value(0, Self.hour) != 2 }

    /// Gói ghi: trang `page` byte `index` = `value`. nil nếu chưa đọc được gói đó.
    public func write(_ page: Int, _ index: Int, _ value: Int) -> [UInt8]? {
        guard let src = page == 0 ? page0 : page1, src.count >= 20 else { return nil }
        var p = Array(src.prefix(20))
        p[0] = 0xB8
        p[1] = 0x01
        p[index] = Veepoo.byte(value)
        p[19] = Veepoo.byte(page)
        // Gói 0: byte 17 không dùng (app gốc để 0).
        if page == 0 { p[17] = 0 }
        return p
    }

    /// Bản sao sau khi ghi thành công.
    public func with(_ page: Int, _ index: Int, _ value: Int) -> VeepooCustomSettings {
        func upd(_ src: [UInt8]?) -> [UInt8]? {
            guard var p = src, index < p.count else { return src }
            p[index] = Veepoo.byte(value)
            return p
        }
        return page == 0 ? VeepooCustomSettings(page0: upd(page0), page1: page1) : VeepooCustomSettings(page0: page0, page1: upd(page1))
    }

    public var description: String { "B8.0=\(page0?.hex ?? "-") B8.1=\(page1?.hex ?? "-")" }

    // Vị trí byte (gói 0)
    public static let units = 2
    public static let hour = 3
    public static let autoHr = 4
    public static let autoBp = 5
    public static let sportRemind = 6
    public static let voiceBpHr = 7
    public static let findPhoneUi = 8
    public static let stopwatch = 9
    public static let spo2Low = 10
    public static let wearDetect = 11
    public static let autoHrv = 12
    public static let autoAnswer = 13
    public static let disconnectRemind = 14
    public static let sos = 15
    public static let ppg = 16
    public static let musicControl = 18

    // Gói 1
    public static let longPressLock = 2
    public static let messageScreenOn = 3
    public static let autoTemperature = 4
    public static let temperatureUnit = 5
    public static let autoGlucose = 7
    public static let autoMet = 8
    public static let autoStress = 9
    public static let autoBloodComponent = 11
    public static let fallDetect = 14
    public static let hrTrend = 15
    public static let powerSound = 17
    public static let measureSound = 18
}
