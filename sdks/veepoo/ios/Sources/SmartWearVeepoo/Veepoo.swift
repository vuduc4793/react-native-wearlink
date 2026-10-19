import CoreBluetooth
import Foundation
import SmartWearCore

public struct VeepooError: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Hằng số, nhận diện khi quét và các gói bắt tay của giao thức Veepoo (app G Band / VPG Band, SDK `com.veepoo.protocol`),
/// bản Swift của `Veepoo.kt`. Tài liệu: `sdks/veepoo/docs/01-protocol.md`. Frame = `[opcode][tham số…]`, không header /
/// length / checksum chung; mọi lệnh ghi lên `write` (có phản hồi), mọi phản hồi về `notify`.
public enum Veepoo {
    public static let service = CBUUID(string: "F0080001-0451-4000-B000-000000000000")
    public static let notify = CBUUID(string: "F0080002-0451-4000-B000-000000000000")
    public static let write = CBUUID(string: "F0080003-0451-4000-B000-000000000000")

    /// Kênh file lớn (mặt đồng hồ "DOOG"): ghi điều khiển + notify trên `uiControl`, khối dữ liệu lên `uiData` (không phản hồi).
    public static let uiService = CBUUID(string: "F0030001-0451-4000-B000-000000000000")
    public static let uiControl = CBUUID(string: "F0030002-0451-4000-B000-000000000000")
    public static let uiData = CBUUID(string: "F0030003-0451-4000-B000-000000000000")

    /// Service sóng ECG/PPG. App iOS gốc hỏi `retrieveConnectedPeripherals([F0020001])` để thấy vòng tay đã được iPhone
    /// giữ kết nối (sau khi bond cho ANCS) dù không còn quảng bá (01-protocol §2.3).
    public static let waveService = CBUUID(string: "F0020001-0451-4000-B000-000000000000")

    /// JieLi RCSP / ZK Bluetrum: chỉ để nhận diện họ chip (mặt đồng hồ / OTA cần thư viện native, không làm).
    public static let jieliService = CBUUID(string: "AE00")
    public static let zkService = CBUUID(string: "F003")

    /// UUID 16-bit app iOS gốc quét (`scanForPeripheralsWithServices:@[FFFF, FEE7, 0001, 180D]`). Không dùng để nhận
    /// diện vì nhiều thiết bị khác cũng phát (R09 QRing phát FEE7, máy đo nhịp tim phát 180D).
    public static let scanServices = ["FFFF", "FEE7", "0001", "180D"].map { CBUUID(string: $0) }

    /// Company id trong manufacturer data (LE): `F8 F8` (G Band), `F8 F9` (= 0xF9F8) / `F9 F9` (bản thương hiệu riêng).
    public static let companyVeepoo: UInt16 = 0xF8F8
    public static let companyVeepooAlt: UInt16 = 0xF9F8
    public static let companyBrand: UInt16 = 0xF9F9
    public static let companies = [companyVeepoo, companyVeepooAlt, companyBrand]

    /// Model đã biết để nhận khi iOS đang giữ kết nối hệ thống (không có quảng bá, không có manufacturer data).
    public static let knownModels = ["GE54"]

    /// Mật khẩu mặc định (G Band luôn gửi "0000").
    public static let defaultPassword = "0000"

    public static func u(_ p: [UInt8], _ i: Int) -> Int { i < p.count ? Int(p[i]) : 0 }
    public static func le16(_ p: [UInt8], _ i: Int) -> Int { u(p, i) | (u(p, i + 1) << 8) }
    public static func be16(_ p: [UInt8], _ i: Int) -> Int { (u(p, i) << 8) | u(p, i + 1) }
    public static func le24(_ p: [UInt8], _ i: Int) -> Int { le16(p, i) | (u(p, i + 2) << 16) }
    public static func le32(_ p: [UInt8], _ i: Int) -> Int { le16(p, i) | (le16(p, i + 2) << 16) }
    public static func be32(_ p: [UInt8], _ i: Int) -> Int { (be16(p, i) << 16) | be16(p, i + 2) }

    static func byte(_ v: Int) -> UInt8 { UInt8(truncatingIfNeeded: v) }

    /// Gói `size` byte bắt đầu bằng `head`, còn lại 0.
    public static func padded(_ size: Int, _ head: [UInt8]) -> [UInt8] {
        head.count >= size ? Array(head.prefix(size)) : head + [UInt8](repeating: 0, count: size - head.count)
    }

    // MARK: - Nhận diện khi quét (§2)

    /// Thông tin đọc từ manufacturer data. `mac` theo thứ tự thường. `advertNumber` = LE16 ở byte 6–7 của payload (cái SDK
    /// iOS gốc gọi là "device number"); `deviceNumber` = LE16 ở byte 11–12 (trên GE54 trùng device number của `A1`);
    /// `firmware` = byte 8–9 ("95.01", trùng phần cuối firmware trong `A1`). Hai trường sau chỉ kiểm chứng trên GE54
    /// (Android, 19/10/2026).
    public struct Advert: Equatable, Sendable {
        public let company: UInt16
        public let mac: String?
        public let advertNumber: Int?
        public let deviceNumber: Int?
        public let firmware: String?
    }

    /// Đọc manufacturer data Veepoo. `data` là phần SAU company id (như `ScannedDevice.manufacturerData`).
    /// `F8 F8`: byte 0–5 = MAC đảo (LE). `F8 F9`: MAC ở byte 4–9 (SDK iOS gốc).
    /// GE54 (đo 19/10/2026): `45 1D E3 8F F4 9C A1 00 95 01 00 5C 17 53 FF 2F 00 30 10` ⇒ MAC `9C:F4:8F:E3:1D:45`, byte 6–7
    /// `A1 00` (161, KHÔNG phải device number), byte 8–10 `95 01 00` (firmware), byte 11–12 `5C 17` = 5980 = device number
    /// trong `A1` (BE16 `17 5C`).
    public static func parseAdvert(company: UInt16, _ data: [UInt8]) -> Advert {
        let macAt = company == companyVeepooAlt ? 4 : 0
        let mac = data.count >= macAt + 6
            ? (macAt..<(macAt + 6)).reversed().map { String(format: "%02X", data[$0]) }.joined(separator: ":") : nil
        let main = company == companyVeepoo
        return Advert(
            company: company, mac: mac,
            advertNumber: main && data.count >= 8 ? le16(data, 6) : nil,
            deviceNumber: main && data.count >= 13 ? le16(data, 11) : nil,
            firmware: main && data.count >= 11 ? String(format: "%02X.%02X", data[8], data[9]) : nil
        )
    }

    /// Tên quảng bá đã bỏ ký tự rác ở cuối (GE54 phát "GE54" + 2 byte không phải chữ), như `cleanName` Android.
    public static func cleanName(_ name: String?) -> String {
        String((name ?? "").prefix { ($0.isASCII && ($0.asciiValue ?? 0) >= 0x20 && ($0.asciiValue ?? 0) <= 0x7E) || $0.isLetter || $0.isNumber })
            .trimmingCharacters(in: .whitespaces)
    }

    /// Manufacturer data Veepoo của một kết quả quét (nil nếu không phải Veepoo).
    public static func advert(_ device: ScannedDevice) -> Advert? {
        for c in companies {
            if let d = device.manufacturerData[c] { return parseAdvert(company: c, [UInt8](d)) }
        }
        return nil
    }

    /// Thiết bị quét được có phải Veepoo không. Như G Band: có manufacturer data `F8F8` (hoặc `F8F9`/`F9F9`) và tên không
    /// rỗng / khác "NULL" (`VBC:1394`, `AddDeviceViewModel.java:191`). Thiết bị iOS đang giữ kết nối hệ thống (không có quảng
    /// bá) thì nhận theo service Veepoo đã biết hoặc tên model đã biết (`knownModels`).
    public static func matches(_ device: ScannedDevice) -> Bool {
        let name = cleanName(device.name)
        if advert(device) != nil { return !name.isEmpty && name != "NULL" }
        guard device.systemConnected else { return false }
        if device.serviceUuids.contains(service) || device.serviceUuids.contains(waveService) { return true }
        return knownModels.contains { name.uppercased().hasPrefix($0) }
    }

    /// Loại vật lý đoán theo tên (chỉ để hiển thị). GE54 là vòng tay.
    public static func guessKind(_ name: String?) -> DeviceKind {
        let n = (name ?? "").uppercased()
        if n.contains("RING") { return .ring }
        if n.contains("WATCH") { return .watch }
        return .band
    }

    // MARK: - A1: xác nhận mật khẩu + đặt giờ (§4.2)

    /// `A1 pwLo pwHi 00 yearHi yearLo M D h m s is24h pair tz15 confirm 00…` (20 byte, `jf/v1.java:99-128`).
    /// Mật khẩu là chuỗi thập phân ≤ 4 ký tự, gửi LE16. Múi giờ tính bằng 15 phút, có dấu.
    /// Byte 12: Android luôn `01`; app iOS gốc gửi `!showPair` (mặc định showPair = YES ⇒ `00`) để vòng tay yêu cầu bond
    /// với iPhone (đọc ANCS). `requestPairing` = true ⇒ `00` (suy luận, Q9 chưa kiểm trên GE54).
    /// `confirmOnDevice` = byte 14 (overload 7 tham số): vòng tay hiện hộp xác nhận kết nối; G Band mặc định 0.
    public static func passwordCheck(
        password: String = defaultPassword, now: Date, is24h: Bool, timeZone: TimeZone = .current,
        calendar: Calendar = .current, requestPairing: Bool = false, confirmOnDevice: Bool = false
    ) throws -> [UInt8] {
        guard (1...4).contains(password.count), password.allSatisfy(\.isASCII), password.allSatisfy(\.isNumber),
              let pw = Int(password) else { throw VeepooError("Mật khẩu Veepoo là 1–4 chữ số") }
        var cal = calendar
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        let year = c.year ?? 2000
        let offset15 = timeZone.secondsFromGMT(for: now) / 900
        return padded(20, [
            0xA1, byte(pw), byte(pw >> 8), 0x00,
            byte(year >> 8), byte(year), byte(c.month ?? 1), byte(c.day ?? 1), byte(c.hour ?? 0), byte(c.minute ?? 0), byte(c.second ?? 0),
            is24h ? 1 : 0, requestPairing ? 0 : 1, byte(offset15), confirmOnDevice ? 1 : 0,
        ])
    }

    public enum PasswordStatus: Int, Sendable {
        case checkFail = 0, checkSuccess, settingFail, settingSuccess, readFail, readSuccess, checkAndTimeSuccess, unknown
    }

    /// Phản hồi `A1` (≥ 20 byte, `jf/v1.java:28-92`). `deviceNumber` BE16 ở byte 4–5, firmware hex ở byte 6–8 (+9 bản test),
    /// MAC LE ở byte 12–17 (app iOS gốc lấy làm `deviceAddress`: cách lấy MAC thật trên iOS). Trạng thái chức năng:
    /// 0 không hỗ trợ / 1 bật / 2 tắt — riêng `nightWrist` (byte 11) là 0 = tắt, 1 = bật, 2 = không hỗ trợ.
    public struct PasswordReply: Equatable, Sendable {
        public let status: PasswordStatus
        public let deviceNumber: Int
        public let firmware: String
        public let testVersion: String
        public let hasDrinkData: Bool
        public let nightWrist: Int
        public let mac: String
        public let findPhone: Int
        public let wearDetect: Int
    }

    public static func parsePasswordReply(_ p: [UInt8]) -> PasswordReply? {
        guard p.count >= 20, p[0] == 0xA1 else { return nil }
        let fw = String(format: "%02X.%02X.%02X", p[6], p[7], p[8])
        return PasswordReply(
            status: PasswordStatus(rawValue: Int(p[3])) ?? .unknown,
            deviceNumber: be16(p, 4),
            firmware: fw,
            testVersion: fw + String(format: ".%02X", p[9]),
            hasDrinkData: p[10] == 1,
            nightWrist: Int(p[11]),
            mac: (12...17).reversed().map { String(format: "%02X", p[$0]) }.joined(separator: ":"),
            findPhone: Int(p[18]),
            wearDetect: Int(p[19])
        )
    }

    /// Trạng thái coi là đăng nhập thành công (G Band: mọi trạng thái trừ CHECK_FAIL, `VBC:5513-5538`).
    public static func passwordAccepted(_ r: PasswordReply) -> Bool { r.status != .checkFail && r.status != .unknown }

    /// `BC 01 00…` (20 byte): yêu cầu vòng tay chủ động ghép đôi / bond với iPhone để đọc ANCS
    /// (`veepooSDKSendPairedWithIphoneCommand` @`0x101028428`, chỉ có trong SDK iOS).
    public static let pairWithPhone = padded(20, [0xBC, 0x01])

    /// `AF 00`: báo ngắt kết nối (app gốc gửi trước khi đóng GATT 500 ms).
    public static let disconnectCommand: [UInt8] = [0xAF, 0x00]

    // MARK: - A0: pin (§6.1)

    public static let batteryRead: [UInt8] = [0xA0, 0x00]

    /// `A0 powerModel bat state level(0–4) hasPercent percent low` (`jf/f.java:168-199`). `percent`: byte 6 nếu byte 5 = 1,
    /// không thì vạch × 25. Vạch = 0 ⇒ SDK gốc không điền gì ⇒ nil.
    public struct Battery: Equatable, Sendable {
        public let percent: Int
        public let level: Int
        public let charging: Bool
        public let low: Bool
        public let exactPercent: Bool
    }

    public static func parseBattery(_ p: [UInt8]) -> Battery? {
        guard p.count >= 8, p[0] == 0xA0 else { return nil }
        let level = Int(p[4])
        guard level != 0 else { return nil }
        let exact = p[5] == 1
        return Battery(
            percent: min(max(exact ? Int(p[6]) : level * 25, 0), 100), level: min(level, 4),
            charging: p[1] == 1, low: p[7] == 2, exactPercent: exact
        )
    }

    // MARK: - A5: đặt giờ (§6.6)

    /// `A5 yearHi yearLo M D h m s mode` (mode 1 = 12h, 2 = 24h) (`jf/s2.java:53-97`).
    public static func setTime(_ now: Date, is24h: Bool, calendar: Calendar = .current) -> [UInt8] {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        let year = c.year ?? 2000
        return padded(20, [
            0xA5, byte(year >> 8), byte(year), byte(c.month ?? 1), byte(c.day ?? 1), byte(c.hour ?? 0), byte(c.minute ?? 0),
            byte(c.second ?? 0), is24h ? 2 : 1,
        ])
    }

    // MARK: - CRC-16/MODBUS (§3.2)

    /// CRC-16/MODBUS: đa thức phản xạ 0xA001, khởi 0xFFFF, không XOR cuối (`util/a.java:22, 133-142`).
    public static func crc16<C: Collection>(_ data: C) -> Int where C.Element == UInt8 {
        var crc = 0xFFFF
        for b in data {
            crc ^= Int(b)
            for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1 }
        }
        return crc & 0xFFFF
    }

    /// Cắt payload thành các gói `[op][sub][idx][total]` + 16 byte (nhạc `99 01`, danh bạ `72 01`), idx từ 1.
    /// Thời tiết đặt ngược thứ tự (`C8 04 total idx`), xem `VeepooWeather`.
    static func chunked(_ payload: [UInt8], op: UInt8, sub: UInt8, totalFirst: Bool = false) -> [[UInt8]] {
        let total = max(1, (payload.count + 15) / 16)
        return (1...total).map { i in
            let from = (i - 1) * 16
            let body = Array(payload[min(from, payload.count)..<min(from + 16, payload.count)])
            let head: [UInt8] = totalFirst ? [op, sub, byte(total), byte(i)] : [op, sub, byte(i), byte(total)]
            return padded(20, head + body)
        }
    }

    /// Cắt chuỗi UTF-8 tối đa `max` byte, không cắt giữa ký tự.
    static func utf8Prefix(_ s: String, max: Int) -> [UInt8] {
        var out: [UInt8] = []
        for ch in s {
            let b = Array(String(ch).utf8)
            if out.count + b.count > max { break }
            out += b
        }
        return out
    }
}
