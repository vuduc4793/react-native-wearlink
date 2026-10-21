import CoreBluetooth
import Foundation
import SmartWearCore

public struct GloryFitError: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Giao thức UTE (app GloryFit), xem sdks/gloryfit/docs/01-protocol.md (bản iOS của `Ute.kt`).
/// Gói = opcode + tham số, số nhiều byte big-endian, không checksum mỗi gói.
public enum Ute {
    public static let service = CBUUID(string: "55FF")
    public static let write = CBUUID(string: "33F1")
    public static let notify = CBUUID(string: "33F2")
    /// Service "BLE5" (gói lớn): ghi 34F1 (đọc ra độ dài gói tối đa + nhóm tính năng 8..13), notify 34F2.
    public static let service5 = CBUUID(string: "56FF")
    public static let write5 = CBUUID(string: "34F1")
    public static let notify5 = CBUUID(string: "34F2")

    /// UUID 16-bit dịch vụ trong gói quảng bá mà app GloryFit lọc (iOS `setFilerServersArray:`, doc 09 §1.2):
    /// dải 0x55xx cũ và `5554, 4544, 4231, 424C, 4F4F, 3455`.
    public static let advertised = [
        "55FF", "5533", "55F0", "5536", "5534", "553C", "5555",
        "5554", "4544", "4231", "424C", "4F4F", "3455",
    ].map { CBUUID(string: $0) }

    /// Tiền tố tên dự phòng khi quảng bá không có UUID 0x55xx (Y25_6E1B, HT43(ID-2750)).
    public static let namePrefixes = ["Y25", "HT43"]

    public static func u(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) }
    public static func be16(_ b: [UInt8], _ i: Int) -> Int { (Int(b[i]) << 8) | Int(b[i + 1]) }
    static func be24(_ b: [UInt8], _ i: Int) -> Int { (Int(b[i]) << 16) | (Int(b[i + 1]) << 8) | Int(b[i + 2]) }
    static func be32(_ b: [UInt8], _ i: Int) -> Int {
        (Int(b[i]) << 24) | (Int(b[i + 1]) << 16) | (Int(b[i + 2]) << 8) | Int(b[i + 3])
    }

    /// Thiết bị quét được có phải UTE không: quảng bá UUID 0x55xx hoặc tên thuộc `namePrefixes`.
    public static func matches(_ device: ScannedDevice) -> Bool {
        let name = device.name ?? ""
        return device.serviceUuids.contains { advertised.contains($0) } || namePrefixes.contains { name.hasPrefix($0) }
    }

    /// "Y25_6E1B" → "Y25"; tên rỗng → "Thiết bị GloryFit" (như `match` Android).
    public static func model(fromName name: String?) -> String {
        let m = (name ?? "").split(separator: "_", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return m.isEmpty ? "Thiết bị GloryFit" : m
    }

    // MARK: - Lệnh

    /// Gói đặt giờ: `A3 YYYY MM DD hh mm ss` (giờ địa phương theo `calendar`; 8 byte, Y25/HT43 đã phản hồi, doc 01 §10).
    /// `tzHours` khác nil thì thêm 1 byte giờ lệch GMT có dấu như SDK iOS gốc (doc 09 §1.5); chưa kiểm chứng trên đồng hồ.
    public static func setTime(_ date: Date, calendar: Calendar = .current, tzHours: Int? = nil) -> [UInt8] {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = c.year ?? 2000
        let base: [UInt8] = [
            0xA3, UInt8((year >> 8) & 0xFF), UInt8(year & 0xFF),
            UInt8(c.month ?? 1), UInt8(c.day ?? 1), UInt8(c.hour ?? 0), UInt8(c.minute ?? 0), UInt8(c.second ?? 0),
        ]
        return tzHours.map { base + [byte($0)] } ?? base
    }

    /// Giờ lệch GMT, phần giờ nguyên (chia nguyên như ObjC, suy luận; múi lẻ 30 phút bị cắt).
    public static func tzHours(_ timeZone: TimeZone, at date: Date) -> Int { timeZone.secondsFromGMT(for: date) / 3600 }

    /// Bật đo nhịp tim 24h (`F7 01`, tắt là `F7 02`).
    public static let hr24Enable: [UInt8] = [0xF7, 0x01]

    /// Chu kỳ đo HR 24h: `F7 09 en mmH mmL` (phút, BE). App iOS chỉ dùng 5..1440 phút, nhỏ nhất 5 (doc 09 §2.2).
    public static func heartRate24hInterval(minutes: Int, enable: Bool = true) -> [UInt8] {
        let m = min(max(minutes, 5), 1440)
        return [0xF7, 0x09, enable ? 1 : 0, byte(m >> 8), byte(m)]
    }

    /// Hỏi trạng thái đo nhịp tim: `E5 AA` → `E5 AA 11` (đang đo) / `E5 AA FF` (doc 09 §2.2).
    public static let hrStatus: [UInt8] = [0xE5, 0xAA]

    /// Kết quả `E5 AA`: true = đang đo, false = không đo, nil = không phải gói này.
    public static func parseHeartRateStatus(_ p: [UInt8]) -> Bool? {
        guard p.count >= 3, p[0] == 0xE5, p[1] == 0xAA else { return nil }
        return p[2] == 0x11
    }

    /// Mã 4 số người dùng thấy trên đồng hồ: mỗi chữ số (ASCII) XOR với "UTE8".
    public static func pairingCode(_ code: String) throws -> [UInt8] {
        let digits = Array(code.utf8)
        guard digits.count == 4, digits.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else {
            throw GloryFitError("Mã phải gồm 4 chữ số")
        }
        let key = Array("UTE8".utf8)
        return [0xD5, 0x01] + (0..<4).map { digits[$0] ^ key[$0] }
    }

    /// `A9` + 18 byte thông tin người dùng (doc §5.2). Mặc định: 170 cm, 65 kg, tắt màn 5 s,
    /// mục tiêu 8000 bước, nâng tay sáng màn, tắt báo HR cao, 30 tuổi, nam, ngôn ngữ khác TQ, °C.
    public static func userInfo(
        heightCm: Int = 170, weightKg: Int = 65, screenOffSec: Int = 5, stepGoal: Int = 8000,
        raiseToWake: Bool = true, age: Int = 30, male: Bool = true,
        hrHighAlert: Int? = nil, hrLowAlert: Int? = nil, fahrenheit: Bool = false
    ) -> [UInt8] {
        // Byte 11: ngưỡng báo nhịp tim cao (FF = tắt), 18: ngưỡng thấp (0 = tắt), 17: 1 = °C, 2 = °F (doc 01 §5.2).
        [
            0xA9, 0x00, byte(heightCm), 0x00, byte(weightKg), byte(screenOffSec),
            byte(stepGoal >> 24), byte(stepGoal >> 16), byte(stepGoal >> 8), byte(stepGoal),
            raiseToWake ? 1 : 0, byte(hrHighAlert ?? 0xFF), 0x00, byte(age), male ? 1 : 2,
            0x00, 0x02, fahrenheit ? 2 : 1, byte(hrLowAlert ?? 0),
        ]
    }

    public static func accountId(_ id: Int) -> [UInt8] {
        [0x33, 0x02, byte(id >> 24), byte(id >> 16), byte(id >> 8), byte(id)]
    }

    static func byte(_ v: Int) -> UInt8 { UInt8(truncatingIfNeeded: v) }

    // MARK: - Bảng tính năng

    /// Bảng tính năng đọc từ 33F1 (F1..F7) và 34F1 (độ dài gói + F8..F13).
    public struct Features: Sendable, Equatable {
        public let groups: [Int: Int]
        public let maxPacketLength: Int?

        public init(groups: [Int: Int] = [:], maxPacketLength: Int? = nil) {
            self.groups = groups
            self.maxPacketLength = maxPacketLength
        }

        public func has(_ group: Int, _ mask: Int) -> Bool { (groups[group] ?? 0) & mask == mask }

        public var usesPairingCode: Bool { has(1, 0x000001) }
        public var usesAccountId: Bool { has(10, 0x080000) }
        /// `isHas24HourHRM` (33F1 byte 15 bit 6).
        public var heartRate24h: Bool { has(2, 0x004000) }
        /// `isHasHRMTimedMeasurement` (34F1 byte 8 bit 7): SDK iOS chỉ cho đo tay `E5 11` khi có cờ này.
        public var heartRateTimedMeasurement: Bool { has(11, 0x800000) }
        /// Đồng hồ HR 24h không hỗ trợ đo theo lệnh app (Y25, HT43): app GloryFit iOS không gửi `D6 01`/`E5 11`,
        /// nhịp tim lấy từ `F7 03` (đo định kỳ) và `F7 0B` (đo trên đồng hồ), doc 09 §2.
        public var heartRateByPush: Bool { heartRate24h && !heartRateTimedMeasurement }
        public var sleepHourlyFormat: Bool { has(1, 0x000400) }

        public func capabilities() -> Set<Capability> {
            var s: Set<Capability> = [.steps]
            if has(1, 0x080000) { s.insert(.heartRate) }
            if has(1, 0x100000) || has(5, 0x100000) || has(7, 0x000010) { s.insert(.bloodPressure) }
            if has(5, 0x000040) { s.insert(.spo2) }
            if has(5, 0x000008) { s.insert(.temperature) }
            if has(6, 0x000020) { s.insert(.stress) }
            if has(11, 0x000020) { s.insert(.hrv) }
            if has(3, 0x002000) { s.insert(.ecg) }
            if has(8, 0x020000) { s.insert(.bloodSugar) }
            if !has(4, 0x008000) { s.insert(.sleep) }
            if has(3, 0x008000) { s.insert(.menstruation) }
            return s
        }

        /// `33F1`: byte 0..1 = F7 (16 bit), rồi F6, F5, F4, F3, F2, F1 (24 bit mỗi nhóm).
        /// `34F1`: byte 0..1 = độ dài gói tối đa, rồi F13, F12, F11, F10, F9, F8.
        public static func parse(main: [UInt8]?, ble5: [UInt8]?) -> Features {
            var g: [Int: Int] = [:]
            if let main, main.count >= 20 {
                g[7] = be16(main, 0)
                for (k, group) in [6, 5, 4, 3, 2, 1].enumerated() { g[group] = be24(main, 2 + k * 3) }
            }
            var maxLen: Int?
            if let ble5, ble5.count >= 20 {
                let v = be16(ble5, 0)
                maxLen = v > 0 ? v : nil
                for (k, group) in [13, 12, 11, 10, 9, 8].enumerated() { g[group] = be24(ble5, 2 + k * 3) }
            }
            return Features(groups: g, maxPacketLength: maxLen)
        }
    }

    // MARK: - Mặt đồng hồ

    /// Thông số mặt đồng hồ trả về từ `26 01` (sdks/gloryfit/docs/02-watchface.md §2).
    public struct DialParams: Sendable, Equatable {
        public let currentId: Int
        public let width: Int
        public let height: Int
        public let screenType: Int
        public let maxSize: Int
        public let level: Int
        public let slots: Int
        public let corner: Int
    }

    /// Mã mặt đang hiển thị khi là mặt tuỳ chỉnh (kiểm chứng trên Y25); `FF FF FF FF` = chưa có.
    public static let customFaceId = 0xFFFF_FFFE

    public static func parseDialParams(_ p: [UInt8]) -> DialParams? {
        guard p.count >= 15, p[0] == 0x26, p[1] == 0x01 else { return nil }
        return DialParams(
            currentId: be32(p, 2), width: be16(p, 6), height: be16(p, 8), screenType: u(p, 10), maxSize: be32(p, 11),
            level: p.count > 15 ? u(p, 15) : 0, slots: p.count > 16 && p[16] > 0 ? u(p, 16) : 1,
            corner: p.count > 17 ? u(p, 17) : 0
        )
    }

    // MARK: - Khung gói

    /// Gói kết thúc một luồng lịch sử: `[op] FD …` (SpO2: `34 FA FD crc`).
    public static func isEnd(_ op: UInt8, _ p: [UInt8]) -> Bool {
        guard let first = p.first, first == op else { return false }
        if op == 0x34 { return p.count >= 3 && p[1] == 0xFA && p[2] == 0xFD }
        return p.count >= 2 && p[1] == 0xFD
    }

    /// Nhịp tim đồng hồ tự đẩy: `F7 03 YYYY MM DD hh mm rr` (đo định kỳ chế độ 24h) hoặc
    /// `F7 0B YYYY MM DD hh mm rr` (người dùng đo trên đồng hồ, doc 09 §2.2).
    public static func parsePushedHeartRate(_ p: [UInt8], calendar: Calendar = .current) -> Reading? {
        guard p.count >= 9, p[0] == 0xF7, p[1] == 0x03 || p[1] == 0x0B else { return nil }
        let bpm = u(p, 8)
        guard (30...220).contains(bpm) else { return nil }
        let ts = date(calendar, be16(p, 2), u(p, 4), u(p, 5), u(p, 6), u(p, 7)) ?? Date()
        return Reading(capability: .heartRate, status: .ok, value: Double(bpm), unit: "bpm", timestamp: ts)
    }

    /// Nhịp tim tức thời `E5 fin st rr` (đang đo hoặc kết quả), nil nếu chưa có giá trị hợp lệ.
    public static func parseLiveHeartRate(_ p: [UInt8]) -> Reading? {
        guard p.count >= 4, p[0] == 0xE5, p[2] == 0 else { return nil }
        let bpm = u(p, 3)
        guard (30...220).contains(bpm) else { return nil }
        return Reading(capability: .heartRate, status: .ok, value: Double(bpm), unit: "bpm")
    }

    /// Mẫu của luồng nhịp tim liên tục, như `parseHeartRateStream` Android: `E5 fin st rr` với st = 0 và rr 30–220 ⇒ nhịp tim;
    /// st ≠ 0 ⇒ chưa đeo (`bpm` nil, `contact` false); rr = 0 ⇒ nil. `F7 03`/`F7 0B` cũng là một mẫu, giờ là lúc nhận.
    public static func parseHeartRateStream(_ p: [UInt8], timestamp: Date = Date()) -> HeartRateSample? {
        if p.count >= 9, p[0] == 0xF7, p[1] == 0x03 || p[1] == 0x0B {
            let bpm = u(p, 8)
            return (30...220).contains(bpm) ? HeartRateSample(bpm: bpm, contact: true, timestamp: timestamp) : nil
        }
        guard p.count >= 4, p[0] == 0xE5 else { return nil }
        if p[2] != 0 { return HeartRateSample(bpm: nil, contact: false, timestamp: timestamp) }
        let bpm = u(p, 3)
        return (30...220).contains(bpm) ? HeartRateSample(bpm: bpm, contact: true, timestamp: timestamp) : nil
    }

    /// Ngày giờ địa phương; nil nếu không hợp lệ.
    static func date(_ calendar: Calendar, _ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date? {
        guard (1...12).contains(mo), (1...31).contains(d) else { return nil }
        guard let day = calendar.date(from: DateComponents(year: y, month: mo, day: d)) else { return nil }
        return calendar.date(byAdding: .minute, value: h * 60 + mi, to: day)
    }

    // Lịch sử (B2/EB bước, B3/31/EC ngủ, E6/F7 nhịp tim, 34 SpO2, C8 huyết áp): xem UteHistory.swift.
}

extension Ute {
    /// `AF AA` (20 byte) → ngôn ngữ hiện tại (byte 2) + 5 mặt nạ hỗ trợ: m1 = byte 17–19, m2 = 14–16, m3 = 11–13,
    /// m4 = 8–10, m5 = 5–7 (GloryFitPro `uterkfor.uterkclass`: 6 ký tự hex cuối là m1…).
    static func parseLanguages(_ p: [UInt8]) -> (current: Int, masks: [Int])? {
        guard p.count == 20, p[0] == 0xAF, p[1] == 0xAA else { return nil }
        // Tách thành be24 để Swift 6.3 không quá thời gian suy kiểu.
        let masks = [17, 14, 11, 8, 5].map { be24(p, $0) }
        return (Int(p[2]), masks)
    }
}
