import Foundation
import SmartWearCore

/// Điện thoại ↔ vòng tay (01-protocol §6.7): tìm vòng tay / tìm điện thoại `B5`, chụp ảnh từ xa `B6`, nhạc `99` (và kiểu cũ
/// `01`), danh bạ `72`. Hàm thuần để kiểm thử bằng vector byte.
public enum VeepooPhone {

    // MARK: - Tìm vòng tay / tìm điện thoại (B5)

    /// `B5 0A` bắt đầu rung tìm vòng tay, `B5 0B` dừng (`jf/j0.java:65-80`). ← `B5 0A/0B st`: 0 không hỗ trợ, 1 đang tìm,
    /// 2 đã thấy, 3 không thấy.
    public static let findDeviceStart = Veepoo.padded(20, [0xB5, 0x0A])
    public static let findDeviceStop = Veepoo.padded(20, [0xB5, 0x0B])
    /// `B5 02`: điện thoại thôi đổ chuông (`stopFindCYPhone`, `jf/j0.java:84-91`).
    public static let findPhoneStop = Veepoo.padded(20, [0xB5, 0x02])

    /// Vòng tay yêu cầu tìm điện thoại: `B5 00 …` (dài > 2 byte, `g.java:336-358`). true = đổ chuông.
    public static func isFindPhone(_ p: [UInt8]) -> Bool { p.count > 2 && p[0] == 0xB5 && p[1] == 0x00 }

    // MARK: - Chụp ảnh từ xa (B6)

    /// `B6 01` vào màn chụp, `B6 00` thoát (`mf/a.java` P/Q).
    public static func camera(_ open: Bool) -> [UInt8] { [0xB6, open ? 0x01 : 0x00] }

    /// ← `B6 ok mode [x]` (`jf/l.java:56-69`): mode 2 + ok 1 = bấm chụp; mode 1 + ok 1 + byte 3 = 1 = người dùng mở màn chụp
    /// trên vòng tay; mode 0 + ok 1 = đã đóng. `B6 01 01 00` là vòng tay xác nhận lệnh mở của app (không phải sự kiện).
    public static func parseCamera(_ p: [UInt8]) -> RemoteCameraEvent? {
        guard p.count >= 3, p[0] == 0xB6, p[1] == 1 else { return nil }
        switch p[2] {
        case 2: return .shutter
        case 1: return p.count > 3 && p[3] == 1 ? .opened : nil
        case 0: return .closed
        default: return nil
        }
    }

    // MARK: - Nhạc (99 / 01)

    /// Trạng thái phát trong `99 01` (`A3`): 1 đang phát, 2 dừng.
    static func playState(_ playing: Bool) -> UInt8 { playing ? 1 : 2 }

    /// `99 01 idx total` + 16 byte của TLV `F0 len {A0 album, A1 tên bài, A2 ca sĩ, A3 01 trạng thái, A4 01 âm lượng}`
    /// (`jf/f1.java:20-125`; độ dài `F0` 1 byte). Chuỗi rỗng thì bỏ tag. Tên bài / ca sĩ cắt 60 byte UTF-8 để TLV < 256 byte.
    /// Âm lượng gửi theo % (thang của vòng tay chưa rõ).
    public static func musicPackets(_ s: MusicState, album: String? = nil) -> [[UInt8]] {
        func text(_ tag: UInt8, _ v: String?) -> [UInt8] {
            guard let v, !v.isEmpty else { return [] }
            let b = Veepoo.utf8Prefix(v, max: 60)
            return [tag, Veepoo.byte(b.count)] + b
        }
        var body = text(0xA0, album) + text(0xA1, s.title) + text(0xA2, s.artist) + [0xA3, 0x01, playState(s.playing)]
        if let v = s.volumePercent { body += [0xA4, 0x01, Veepoo.byte(min(max(v, 0), 100))] }
        return Veepoo.chunked([0xF0, Veepoo.byte(body.count)] + body, op: 0x99, sub: 0x01)
    }

    /// `99 01` chỉ có âm lượng (`changeMusicLevel`, `f1.java:59-79`).
    public static func volumePackets(_ percent: Int) -> [[UInt8]] {
        let body: [UInt8] = [0xA4, 0x01, Veepoo.byte(min(max(percent, 0), 100))]
        return Veepoo.chunked([0xF0, Veepoo.byte(body.count)] + body, op: 0x99, sub: 0x01)
    }

    /// Lệnh nhạc từ vòng tay. `musicType` 1: `99 02` 1 phát / 2 dừng / 3 bài trước / 4 bài sau, `99 03` 5 tăng / 6 giảm âm
    /// lượng (gói ≥ 20 byte, `jf/u.java:44-91`). Kiểu cũ: `01 01 01 01` bài sau, `01 01 01 04` bài trước, `01 01 01 02`
    /// phát/dừng (`p9/a.java:854-897`).
    public static func parseMusicCommand(_ p: [UInt8]) -> MusicCommand? {
        if p.count >= 20, p[0] == 0x99 {
            switch (p[1], p[2]) {
            case (2, 1), (2, 2): return .playPause
            case (2, 3): return .previous
            case (2, 4): return .next
            case (3, 5): return .volumeUp
            case (3, 6): return .volumeDown
            default: return nil
            }
        }
        if p.count >= 4, p[0] == 0x01, p[1] == 0x01, p[2] == 0x01 {
            switch p[3] {
            case 1: return .next
            case 4: return .previous
            case 2: return .playPause
            default: return nil
            }
        }
        return nil
    }

    // MARK: - Danh bạ (72)

    /// Một liên hệ TLV `A0 lenLE16 [A1 01 id] [A2 n tên ≤ 20 byte] [A3 n số ≤ 22 byte] [A4 01 sos]` (độ dài gồm 3 byte đầu),
    /// `jf/p.java:97-145`. `sos` = nil với thiết bị không có liên hệ SOS (A7 trang 3 byte 4 = 1).
    public static func contactRecord(id: Int, name: String, phone: String, sos: Bool?) -> [UInt8] {
        let n = Veepoo.utf8Prefix(name, max: 20)
        let ph = Veepoo.utf8Prefix(phone, max: 22)
        var inner: [UInt8] = [0xA1, 0x01, Veepoo.byte(id)]
        if !n.isEmpty { inner += [0xA2, Veepoo.byte(n.count)] + n }
        if !ph.isEmpty { inner += [0xA3, Veepoo.byte(ph.count)] + ph }
        if let sos { inner += [0xA4, 0x01, sos ? 1 : 0] }
        let size = inner.count + 3
        return [0xA0, Veepoo.byte(size), Veepoo.byte(size >> 8)] + inner
    }

    /// Gói thêm một liên hệ: `72 01 idx total` + 16 byte (`p.java:84-95`). Vòng tay trả `72 01 01 …` khi lưu xong.
    public static func contactPackets(id: Int, name: String, phone: String, sos: Bool?) -> [[UInt8]] {
        Veepoo.chunked(contactRecord(id: id, name: name, phone: phone, sos: sos), op: 0x72, sub: 0x01)
    }

    /// `72 04 id`: xoá liên hệ (`p.java:183-194`).
    public static func contactDelete(id: Int) -> [UInt8] { Veepoo.padded(20, [0x72, 0x04, Veepoo.byte(id)]) }

    /// `72 01 01 …` = lưu thành công (`p.java:349-356`).
    public static func isContactSaved(_ p: [UInt8]) -> Bool? {
        guard p.count >= 3, p[0] == 0x72, p[1] == 0x01 else { return nil }
        return p[2] == 1
    }

    /// Số điện thoại chỉ giữ chữ số và dấu +.
    public static func cleanPhone(_ s: String) -> String { s.filter { $0.isNumber || $0 == "+" } }
}

/// Thời tiết `C8` (01-protocol §6.7, `jf/u2.java:103-353`, `lf/a.java`).
public enum VeepooWeather {
    /// `C8 03 open unit` (unit 0 = °C, 1 = °F): bật hiển thị thời tiết (`settingWeatherStatusInfo`).
    public static func status(enabled: Bool, fahrenheit: Bool = false) -> [UInt8] {
        Veepoo.padded(20, [0xC8, 0x03, enabled ? 1 : 0, fahrenheit ? 1 : 0])
    }

    /// Mã hiện tượng thời tiết của vòng tay (`WeatherStatueChange.changeCode`: mã HeFeng → mã Veepoo). Dải 1 nắng, 5 ít mây,
    /// 9 nhiều mây, 17 mưa rào, 21 dông, 33 mưa nhỏ, 49 mưa to, 73 mưa tuyết, 85 tuyết, 105 bụi cát, 113 sương mù, 136 gió.
    /// "Âm u" (HeFeng 104) không có trong bảng gốc: dùng 9 (suy luận).
    public static func code(_ c: WeatherCondition) -> Int {
        switch c {
        case .sunny: 1
        case .cloudy: 5
        case .overcast: 9
        case .shower: 17
        case .thunderstorm: 21
        case .sleet: 73
        case .lightRain: 33
        case .heavyRain: 49
        case .snow: 85
        case .dust: 105
        case .fog: 113
        case .wind: 136
        }
    }

    static func signed(_ tag: UInt8, _ v: Int) -> [UInt8] { [tag, 0x02, v > 0 ? 1 : 0, Veepoo.byte(abs(v))] }
    static func range(_ tag: UInt8, _ hi: Int, _ lo: Int) -> [UInt8] {
        [tag, 0x04, hi > 0 ? 1 : 0, Veepoo.byte(abs(hi)), lo > 0 ? 1 : 0, Veepoo.byte(abs(lo))]
    }
    static func time5(_ tag: UInt8, _ d: Date, _ cal: Calendar) -> [UInt8] {
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: d)
        return [tag, 0x05, Veepoo.byte((c.year ?? 2000) - 2000), Veepoo.byte(c.month ?? 1), Veepoo.byte(c.day ?? 1),
                Veepoo.byte(c.hour ?? 0), Veepoo.byte(c.minute ?? 0)]
    }
    static func fahrenheit(_ c: Int) -> Int { Int((Double(c) * 9 / 5 + 32).rounded()) }
    /// Gió (cấp "a-b") và tầm nhìn (m) không có trong `WeatherForecast`: gửi cấp 1–2, 10 km.
    static let wind: [UInt8] = [0x01, 0x02]
    static let visibility = 10_000

    /// TLV đầy đủ (weatherType ≠ 2): `F0 lenLE16 { A1 02 crc, A2 n thành phố, A3 01 nguồn, A4 05 giờ cập nhật,
    /// A5 lenLE16 [B0 len {B1 giờ, B2 °F, B3 °C, B4 UV, B5 hiện tượng, B6 gió, B7 tầm nhìn}],
    /// A6 lenLE16 [C0 len {C1 03 y M D, C2 04 cao/thấp °F, C3 04 cao/thấp °C, C4 UV, C5 ngày, C6 đêm, C7 gió, C8 tầm nhìn}]… }`.
    /// Nhiệt độ: byte dấu (1 = dương, 0 = âm hoặc 0) + trị tuyệt đối. `crc` = CRC-16/MODBUS phần sau `A1` (để vòng tay biết
    /// dữ liệu mới; app gốc lấy từ server).
    public static func payload(_ f: WeatherForecast, now: Date = Date(), calendar: Calendar = .current) -> [UInt8] {
        let city = Veepoo.utf8Prefix(foldAccents(f.city), max: 32)
        var hour: [UInt8] = time5(0xB1, now, calendar) + signed(0xB2, fahrenheit(f.currentC)) + signed(0xB3, f.currentC)
        hour += [0xB4, 0x01, Veepoo.byte(f.uvIndex), 0xB5, 0x01, Veepoo.byte(code(f.days.first?.condition ?? .cloudy))]
        hour += [0xB6, 0x02] + wind + [0xB7, 0x02, Veepoo.byte(visibility), Veepoo.byte(visibility >> 8)]
        let hours: [UInt8] = [0xB0, Veepoo.byte(hour.count)] + hour
        var days: [UInt8] = []
        let today = calendar.startOfDay(for: now)
        for (i, d) in f.days.prefix(7).enumerated() {
            let date = calendar.date(byAdding: .day, value: i, to: today) ?? today
            let c = calendar.dateComponents([.year, .month, .day], from: date)
            var day: [UInt8] = [0xC1, 0x03, Veepoo.byte((c.year ?? 2000) - 2000), Veepoo.byte(c.month ?? 1), Veepoo.byte(c.day ?? 1)]
            day += range(0xC2, fahrenheit(d.highC), fahrenheit(d.lowC)) + range(0xC3, d.highC, d.lowC)
            day += [0xC4, 0x01, Veepoo.byte(i == 0 ? f.uvIndex : 0), 0xC5, 0x01, Veepoo.byte(code(d.condition)),
                    0xC6, 0x01, Veepoo.byte(code(d.condition))]
            day += [0xC7, 0x02] + wind + [0xC8, 0x02, Veepoo.byte(visibility), Veepoo.byte(visibility >> 8)]
            days += [0xC0, Veepoo.byte(day.count)] + day
        }
        var rest: [UInt8] = [0xA2, Veepoo.byte(city.count)] + city + [0xA3, 0x01, 0x00] + time5(0xA4, now, calendar)
        rest += [0xA5, Veepoo.byte(hours.count), Veepoo.byte(hours.count >> 8)] + hours
        rest += [0xA6, Veepoo.byte(days.count), Veepoo.byte(days.count >> 8)] + days
        let crc = Veepoo.crc16(rest)
        let all: [UInt8] = [0xA1, 0x02, Veepoo.byte(crc), Veepoo.byte(crc >> 8)] + rest
        return [0xF0, Veepoo.byte(all.count), Veepoo.byte(all.count >> 8)] + all
    }

    /// Gói gửi: `C8 04 total idx` + 16 byte (lưu ý tổng đứng trước số thứ tự), cách nhau 50 ms (`u2.java:325-352`).
    public static func packets(_ f: WeatherForecast, now: Date = Date(), calendar: Calendar = .current) -> [[UInt8]] {
        Veepoo.chunked(payload(f, now: now, calendar: calendar), op: 0xC8, sub: 0x04, totalFirst: true)
    }
}
