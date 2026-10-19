import Foundation
import SmartWearCore

/// Danh bạ trên đồng hồ (SDK Realtek trong GloryFitPro: `syncContactsToDevice`, `uterkif.uterkthis.g0`), kênh 34F1:
/// - `37 FA n` (số liên hệ) → đồng hồ trả `37 FA n`
/// - các gói `37 FB k` + k bản ghi `37 FB lenSố lenTên số(ASCII) tên(UTF-16BE)`, đệm 0 tới độ dài gói tối đa;
///   đồng hồ trả `37 FB k` cho mỗi gói
/// - `37 FC FD` kết thúc → `37 FC FD`.
/// Có F6 `0x80000` (Y25/HT43) thì tên tối đa 20 ký tự (bản ghi 59 byte) và tối đa 70 liên hệ; không thì 10 ký tự (39 byte).
/// Số tối đa 15 ký tự. Kiểm chứng trên Y25 15/10/2026.
public enum UteContacts {
    /// Liên hệ dùng chung của core (`SmartWearCore.Contact`); giữ tên cũ cho mã đang gọi `UteContacts.Contact`.
    public typealias Contact = SmartWearCore.Contact

    /// `isHasContact` (33F1 b6.5 = F5 `0x2000`).
    public static func supported(_ f: Ute.Features) -> Bool { f.has(5, 0x002000) }
    public static func longNames(_ f: Ute.Features) -> Bool { f.has(6, 0x080000) }
    public static func maxContacts(_ f: Ute.Features) -> Int { longNames(f) ? 70 : 100 }

    /// Số chỉ giữ chữ số, `+`, `*`, `#` (đồng hồ quay số theo chuỗi này).
    public static func cleanPhone(_ s: String) -> String { String(s.filter { $0.isNumber || "+*#".contains($0) }.prefix(15)) }

    static func record(_ c: Contact, maxName: Int) -> [UInt8] {
        let phone = Array(cleanPhone(c.phone).utf8)
        let name = Array(c.name.prefix(maxName)).flatMap { ch -> [UInt8] in
            String(ch).utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
        }
        return [0x37, 0xFB, UInt8(phone.count), UInt8(name.count)] + phone + name
    }

    /// Các gói `37 FB` (chưa gồm `37 FA` và `37 FC FD`).
    public static func segments(_ contacts: [Contact], features f: Ute.Features, packetLength: Int) -> [[UInt8]] {
        let recSize = longNames(f) ? 59 : 39
        let perPacket = max(1, (packetLength - 3) / recSize)
        let list = Array(contacts.prefix(maxContacts(f)))
        return stride(from: 0, to: list.count, by: perPacket).map { start in
            let chunk = list[start..<min(list.count, start + perPacket)]
            var p: [UInt8] = [0x37, 0xFB, UInt8(chunk.count)]
            for c in chunk { p += record(c, maxName: longNames(f) ? 20 : 10) }
            return p + [UInt8](repeating: 0, count: max(0, packetLength - p.count))
        }
    }
}
