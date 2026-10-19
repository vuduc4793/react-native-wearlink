import Foundation
import SmartWearCore

/// Báo thức có chữ `B9` (A7 gói 1 byte 17 = 5/6/7, GE54 = 6, tối đa 10), theo `jf/q2.java` (TextAlarmOprate):
/// mỗi báo thức là TLV `A1 L { B1 08 id bật lặp giờ phút yy mm dd, B2 n nhãn-UTF-8 }`; CRC-16/MODBUS (LE) trên TLV **mọi báo thức
/// của danh sách sau thay đổi** theo thứ tự danh sách. Ghi: `B9 op total idx A0 02 crcLo crcHi` + TLV báo thức (op 02 thêm/sửa,
/// 01 xoá), đọc: `B9 03 00 00 A0 02 crc`. Phản hồi: `B9 op total idx A0 03 trạng-thái crcLo crcHi …`.
/// Lặp: bit0 = Thứ Hai … bit6 = Chủ Nhật (trùng `Alarm.repeatDays`); không lặp thì gửi ngày lần đổ chuông tới.
public enum VeepooAlarm {
    public static let maxCount = 10
    /// Nhãn tối đa 30 byte UTF-8 như Android (SDK gốc cho 60, `VPOperateManager.java:1619`; Android chọn 30 cho chắc với vòng tay).
    public static let maxLabelBytes = 30

    public static let opDelete: UInt8 = 0x01
    public static let opSet: UInt8 = 0x02
    public static let opRead: UInt8 = 0x03

    /// Ngày đổ chuông lần tới của báo thức không lặp (hôm nay nếu giờ còn ở phía trước, không thì ngày mai).
    public static func nextDate(hour: Int, minute: Int, now: Date, calendar: Calendar = .current) -> DateComponents {
        let today = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
        let day = today > now ? today : (calendar.date(byAdding: .day, value: 1, to: today) ?? today)
        return calendar.dateComponents([.year, .month, .day], from: day)
    }

    /// TLV một báo thức (`q2.java:114-158`). `date` chỉ dùng khi không lặp. `rawDate` (3 byte yy mm dd đọc từ vòng tay) được giữ
    /// nguyên nếu có, để CRC danh sách khớp đúng như vòng tay tính (GE54 thật: `30 00 00` cho báo thức không lặp).
    public static func tlv(_ a: Alarm, date: DateComponents? = nil, rawDate: [UInt8]? = nil) -> [UInt8] {
        let label = Veepoo.utf8Prefix(a.label ?? "", max: maxLabelBytes)
        let repeatDays = a.repeatDays & 0x7F
        var yy: UInt8 = 0, mm: UInt8 = 0, dd: UInt8 = 0
        if let r = rawDate, r.count == 3 {
            (yy, mm, dd) = (r[0], r[1], r[2])
        } else if repeatDays == 0, let d = date, let y = d.year, let m = d.month, let day = d.day {
            yy = Veepoo.byte(y - 2000)
            mm = Veepoo.byte(m)
            dd = Veepoo.byte(day)
        }
        let body: [UInt8] = [0xB1, 0x08, Veepoo.byte(a.id), a.enabled ? 1 : 0, Veepoo.byte(repeatDays), Veepoo.byte(a.hour),
                             Veepoo.byte(a.minute), yy, mm, dd, 0xB2, Veepoo.byte(label.count)] + label
        return [0xA1, Veepoo.byte(body.count)] + body
    }

    /// CRC-16/MODBUS trên TLV các báo thức (rỗng ⇒ 0).
    public static func crc(_ tlvs: [[UInt8]]) -> Int {
        let all = tlvs.flatMap { $0 }
        return all.isEmpty ? 0 : Veepoo.crc16(all)
    }

    /// Gói ghi (op 02 thêm/sửa, 01 xoá) cho TLV `item` với CRC `crc` của danh sách sau thay đổi. `mtu` = số byte tối đa một gói:
    /// ≥ 82 ⇒ một gói đúng độ dài; nhỏ hơn ⇒ cắt phần `A0 02 crc + TLV` thành khúc `mtu − 4` byte, mỗi gói `B9 op total idx` + khúc,
    /// đệm 0 cho đủ `mtu` (`q2.java:639-697`).
    public static func writePackets(op: UInt8, item: [UInt8], crc: Int, mtu: Int = 20) -> [[UInt8]] {
        let payload: [UInt8] = [0xA0, 0x02, Veepoo.byte(crc), Veepoo.byte(crc >> 8)] + item
        if mtu >= 82 { return [[0xB9, op, 0x01, 0x01] + payload] }
        let size = max(mtu, 20)
        let chunk = size - 4
        let total = (payload.count + chunk - 1) / chunk
        return (0..<total).map { i in
            let part = Array(payload[(i * chunk)..<min((i + 1) * chunk, payload.count)])
            return Veepoo.padded(size, [0xB9, op, Veepoo.byte(total), Veepoo.byte(i + 1)] + part)
        }
    }

    /// Gói đọc `B9 03 00 00 A0 02 crc` (20 byte). CRC = danh sách app đang giữ; gửi 0 để vòng tay luôn trả danh sách.
    public static func readRequest(cachedCrc: Int = 0) -> [UInt8] {
        Veepoo.padded(20, [0xB9, opRead, 0x00, 0x00, 0xA0, 0x02, Veepoo.byte(cachedCrc), Veepoo.byte(cachedCrc >> 8)])
    }

    /// Gói cuối của một phản hồi nhiều gói: idx ≥ total.
    public static func isLast(_ p: [UInt8]) -> Bool { p.count >= 4 && p[0] == 0xB9 && p[3] >= p[2] }

    /// Đầu phản hồi `A0 03 trạng-thái crcLo crcHi` ở byte 4–8 của gói đầu: (ok, crc). nil nếu không đúng dạng.
    public static func parseAck(_ p: [UInt8]) -> (ok: Bool, crc: Int)? {
        guard p.count >= 9, p[0] == 0xB9, p[4] == 0xA0, p[5] == 0x03 else { return nil }
        return (p[6] == 1, Veepoo.le16(p, 7))
    }

    /// Danh sách báo thức từ các gói đọc `B9 03 …` (`q2.java:164-246`, `:528-544`): bỏ 4 byte đầu mỗi gói, ghép, bỏ khối
    /// `A0 03 …`, rồi đọc lần lượt các `A1 L …` tới byte khác `A1`.
    public static func parseList(_ packets: [[UInt8]]) -> [Alarm] { parseEntries(packets).map(\.alarm) }

    /// Như `parseList`, kèm 3 byte ngày thô (yy mm dd) vòng tay lưu, để tính lại CRC đúng như vòng tay.
    public static func parseEntries(_ packets: [[UInt8]]) -> [(alarm: Alarm, rawDate: [UInt8])] {
        let ps = packets.filter { $0.count > 4 && $0[0] == 0xB9 }.sorted { $0[3] < $1[3] }
        let b = ps.flatMap { $0[4...] }
        guard b.count >= 2, b[0] == 0xA0 else { return [] }
        var i = Int(b[1]) + 2
        var out: [(alarm: Alarm, rawDate: [UInt8])] = []
        while i + 2 <= b.count, b[i] == 0xA1 {
            let len = Int(b[i + 1])
            guard i + 2 + len <= b.count else { break }
            let v = Array(b[(i + 2)..<(i + 2 + len)])
            if let a = parseItem(v) {
                out.append((a, Array(v[7...9])))
            }
            i += 2 + len
        }
        return out
    }

    /// Thân `B1 08 id bật lặp giờ phút yy mm dd B2 n nhãn` của một báo thức.
    public static func parseItem(_ v: [UInt8]) -> Alarm? {
        guard v.count >= 10, v[0] == 0xB1, v[1] == 0x08 else { return nil }
        var label: String?
        if v.count >= 12, v[10] == 0xB2 {
            let n = Int(v[11])
            if n > 0, 12 + n <= v.count { label = String(decoding: v[12..<(12 + n)], as: UTF8.self) }
        }
        let repeatDays = v[4] > 0x7F ? 0 : Int(v[4])
        return Alarm(id: Int(v[2]), hour: Int(v[5]), minute: Int(v[6]), repeatDays: repeatDays, enabled: v[3] == 1, label: label)
    }

    /// Id trống đầu tiên trong 1…10 (`Alarm2Util.java:45`); nil = đầy.
    public static func freeId(_ list: [Alarm]) -> Int? {
        let used = Set(list.map(\.id))
        return (1...maxCount).first { !used.contains($0) }
    }
}

extension VeepooDevice {
    /// Số byte tối đa một gói `B9` (app gốc: ATT MTU − 5; iOS báo MTU − 3 cho ghi không phản hồi).
    private var alarmMtu: Int { max(20, gatt.maximumWriteLength(withResponse: false) - 2) }

    /// Cài đặt của `alarms()` (override phải nằm trong thân lớp).
    func readTextAlarms() async throws -> [Alarm] {
        guard state == .connected else { throw VeepooError("Vòng tay chưa kết nối") }
        guard supportsAlarms else { throw VeepooError("Vòng tay không có báo thức có chữ") }
        let packets = try await collect(VeepooAlarm.readRequest(), idle: 2, end: VeepooAlarm.isLast) {
            $0.count >= 4 && $0[0] == 0xB9 && $0[1] == VeepooAlarm.opRead
        }
        SmartWearLog.i("[\(name)] B9 03 ← \(packets.map(\.hex).joined(separator: " | "))")
        guard let first = packets.first, VeepooAlarm.parseAck(first) != nil else { throw VeepooError("Vòng tay không trả danh sách báo thức") }
        let entries = VeepooAlarm.parseEntries(packets)
        alarmDates = Dictionary(entries.map { ($0.alarm.id, $0.rawDate) }, uniquingKeysWith: { a, _ in a })
        return entries.map(\.alarm)
    }

    func writeTextAlarm(_ alarm: Alarm) async throws {
        guard state == .connected else { throw VeepooError("Vòng tay chưa kết nối") }
        guard supportsAlarms else { throw VeepooError("Vòng tay không có báo thức có chữ") }
        guard (0...23).contains(alarm.hour), (0...59).contains(alarm.minute) else { throw VeepooError("Giờ báo thức không hợp lệ") }
        var list = try await readTextAlarms()
        var a = alarm
        if let i = list.firstIndex(where: { $0.id == alarm.id }), alarm.id >= 0 {
            list[i] = a
        } else {
            guard let id = VeepooAlarm.freeId(list) else { throw VeepooError("Vòng tay đã đủ \(VeepooAlarm.maxCount) báo thức") }
            a.id = id
            list.append(a)
        }
        try await sendAlarm(op: VeepooAlarm.opSet, item: a, list: list)
    }

    func deleteTextAlarm(_ id: Int) async throws {
        guard state == .connected else { throw VeepooError("Vòng tay chưa kết nối") }
        guard supportsAlarms else { throw VeepooError("Vòng tay không có báo thức có chữ") }
        var list = try await readTextAlarms()
        guard let i = list.firstIndex(where: { $0.id == id }) else { throw VeepooError("Không có báo thức \(id)") }
        let removed = list.remove(at: i)
        try await sendAlarm(op: VeepooAlarm.opDelete, item: removed, list: list)
    }

    /// Gửi gói ghi với CRC của `list` (danh sách sau thay đổi) và chờ `B9 op … A0 03 st crc` (st = 1 ⇒ thành công).
    private func sendAlarm(op: UInt8, item: Alarm, list: [Alarm]) async throws {
        let now = Date()
        // Báo thức không đổi giữ ngày vòng tay đã lưu (CRC phải khớp danh sách trên vòng tay); báo thức đang ghi lấy ngày tới.
        func tlv(_ a: Alarm) -> [UInt8] {
            let raw = a.id != item.id ? alarmDates[a.id] : nil
            return VeepooAlarm.tlv(a, date: VeepooAlarm.nextDate(hour: a.hour, minute: a.minute, now: now), rawDate: raw)
        }
        let crc = VeepooAlarm.crc(list.map(tlv))
        let packets = VeepooAlarm.writePackets(op: op, item: tlv(item), crc: crc, mtu: alarmMtu)
        let rsp = try await sendAndWait(packets, timeout: 4) { $0.count >= 9 && $0[0] == 0xB9 && $0[1] == op && $0[4] == 0xA0 }
        guard let rsp, let ack = VeepooAlarm.parseAck(rsp) else { throw VeepooError("Vòng tay không xác nhận báo thức") }
        guard ack.ok else { throw VeepooError("Vòng tay từ chối báo thức: \(rsp.hex)") }
        if ack.crc != crc { SmartWearLog.w("[\(name)] CRC báo thức vòng tay \(ack.crc) ≠ app \(crc)") }
    }
}
