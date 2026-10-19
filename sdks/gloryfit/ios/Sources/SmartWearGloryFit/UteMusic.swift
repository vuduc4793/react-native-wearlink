import Foundation
import SmartWearCore

/// Điều khiển nhạc điện thoại từ đồng hồ và đẩy bài đang phát lên đồng hồ (doc 10 §2.6), bản Swift của `UteMusic.kt`.
/// Viết tắt: `T` = `uterkif/uterkthis.java` (GloryFitPro 1.9.0.2), `W` = `WriteCommandToBLE.java` (GloryFit 4.0.12).
///
/// Đồng hồ → app (`P/uterkfor/uterkchar.java:137-215`): `D1 07` phát/tạm dừng, `D1 08` bài sau, `D1 09` bài trước,
/// `D1 0D` / `D1 0E` tăng / giảm âm lượng. App → đồng hồ: `3A …` tên bài (F5 `0x1000`), `D1 0C` trạng thái phát
/// (đồng hồ không có F5 `0x1000`, `W:3644-3649`), `D1 0D/0E pct` âm lượng (`T:3968-3979`).
public enum UteMusic {
    /// F5 `0x1` (`IS_SUPPORT_MUSIC_CONTROL`): đồng hồ có màn điều khiển nhạc điện thoại.
    public static func control(_ f: Ute.Features) -> Bool { f.has(5, 0x000001) }

    /// F5 `0x1000` (`IS_SUPPORT_MUSIC_CONTENT_DISPLAY`): đồng hồ hiện tên bài (`MusicControl.onMetadataChanged`, `W`).
    public static func songInfo(_ f: Ute.Features) -> Bool { f.has(5, 0x001000) }

    /// Lệnh nhạc từ đồng hồ (`uterkchar`, mọi độ dài gói như bản gốc).
    public static func parseCommand(_ p: [UInt8]) -> MusicCommand? {
        guard p.count >= 2, p[0] == 0xD1 else { return nil }
        switch p[1] {
        case 0x07: return .playPause
        case 0x08: return .next
        case 0x09: return .previous
        case 0x0D: return .volumeUp
        case 0x0E: return .volumeDown
        default: return nil
        }
    }

    /// Độ dài tối đa (byte UTF-8) của tên bài / ca sĩ (`T:4642-4683`).
    static let textLimit = 52

    /// Cắt chuỗi UTF-8 tối đa `limit` byte, không cắt giữa một ký tự (bản gốc cắt thẳng byte, có thể vỡ ký tự cuối).
    static func utf8Prefix(_ s: String, _ limit: Int) -> [UInt8] {
        var out: [UInt8] = []
        for ch in s {
            let b = Array(String(ch).utf8)
            if out.count + b.count > limit { break }
            out += b
        }
        return out
    }

    /// Bài đang phát, như `T:4589-4699` (`setSongInformationToDevice`), gửi lên 34F1 cách nhau 100 ms:
    /// - `3A 01 st FF FF FFFFFFFF FFFFFFFF` (13 byte); st: đang phát `02`, dừng `01` (`MUSIC_STATUS_PLAY` = 1 → `02`).
    ///   Chế độ phát, âm lượng, tổng thời gian, vị trí để `FF` (`STATUS_NO_CHANGE`): cả GloryFit lẫn GloryFitPro đều
    ///   chỉ gửi -1 cho các trường này (`SearchDeviceModelImpl.java:235-238`, `MusicControl` cũ), chưa rõ đơn vị;
    /// - `3A 06 len <tên bài UTF-8 ≤ 52 byte>` nếu có tên;
    /// - `3A 04 00 len <ca sĩ UTF-8 ≤ 52 byte>` nếu có ca sĩ.
    /// Gói `3A FA` (`songEnd`) gửi sau cùng; đồng hồ trả `3A FA xx` với xx = `checksum` các gói trên.
    public static func songPackets(playing: Bool, title: String?, artist: String?) -> [[UInt8]] {
        var out: [[UInt8]] = [[0x3A, 0x01, playing ? 0x02 : 0x01, 0xFF, 0xFF] + [UInt8](repeating: 0xFF, count: 8)]
        if let title, !title.isEmpty {
            let b = utf8Prefix(title, textLimit)
            out.append([0x3A, 0x06, UInt8(b.count)] + b)
        }
        if let artist, !artist.isEmpty {
            let b = utf8Prefix(artist, textLimit)
            out.append([0x3A, 0x04, 0x00, UInt8(b.count)] + b)
        }
        return out
    }

    /// `3A FA`: kết thúc gói tên bài (`T:4692-4698`).
    public static let songEnd: [UInt8] = [0x3A, 0xFA]

    /// XOR mọi byte của các gói tên bài (biến `K` trong `T`), đồng hồ đối chiếu trong `3A FA xx`.
    public static func checksum(_ packets: [[UInt8]]) -> UInt8 { packets.reduce(0) { acc, p in p.reduce(acc, ^) } }

    /// `D1 0C 01` đang phát / `D1 0C 02` dừng (`W:3644-3649` `controlBandMusic`; `T:3001-3011`).
    public static func playState(_ playing: Bool) -> [UInt8] { [0xD1, 0x0C, playing ? 0x01 : 0x02] }

    /// Âm lượng điện thoại lên đồng hồ: `D1 0D pct` khi tăng (hoặc bằng), `D1 0E pct` khi giảm (`T:3968-3979`).
    public static func volume(_ percent: Int, up: Bool) -> [UInt8] {
        [0xD1, up ? 0x0D : 0x0E, UInt8(min(max(percent, 0), 100))]
    }
}
