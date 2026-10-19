import Foundation
import SmartWearCore

/// Mặt đồng hồ Veepoo gốc (03-watchface-ota §1; chip Nordic/…, `bigDataTranType` = 2): điều khiển bằng opcode `50` trên
/// F0080003, dữ liệu qua kênh UI F0030001 ("DOOG"). Chip JieLi / ZK cần thư viện native: không hỗ trợ.
public enum VeepooWatchFace {
    /// Loại dữ liệu (`EUIFromType`): 1 mặt chợ (server), 2 mặt ảnh tuỳ chỉnh.
    public static let typeServer: UInt8 = 1
    public static let typeCustom: UInt8 = 2

    /// `50 02 type` + 0 (20 byte): đọc thông tin vùng nhớ (`jf/t2.java:253-261`).
    public static func infoRead(_ type: UInt8) -> [UInt8] { Veepoo.padded(20, [0x50, 0x02, type]) }

    /// Thông tin mặt chợ (`UIDataServer`, `t2.java:134-141`), số LE.
    public struct ServerInfo: Equatable, Sendable {
        public let address: Int
        public let maxLength: Int
        public let binDataType: Int
        public let dialShape: Int
        /// CRC của mặt đang cài.
        public let crcId: Int
        public let index: Int
    }

    /// `50 02 01 01 addr(4) max(4) binType(2) shape(2) crc(2) … idx`. nil nếu không phải / thiết bị báo lỗi (byte 3 ≠ 1).
    public static func parseServerInfo(_ p: [UInt8]) -> ServerInfo? {
        guard p.count >= 20, p[0] == 0x50, p[1] == 0x02, p[2] == typeServer, p[3] == 1 else { return nil }
        return ServerInfo(address: Veepoo.le32(p, 4), maxLength: Veepoo.le32(p, 8), binDataType: Veepoo.le16(p, 12),
                          dialShape: Veepoo.le16(p, 14), crcId: Veepoo.le16(p, 16), index: Int(p[19]))
    }

    /// Thông tin mặt tuỳ chỉnh (`UIDataCustom`, `t2.java:37-52`): địa chỉ LE32, dung lượng LE24, `EWatchUIType` (kích thước màn).
    public struct CustomInfo: Equatable, Sendable {
        public let address: Int
        public let maxLength: Int
        public let uiType: Int
    }

    public static func parseCustomInfo(_ p: [UInt8]) -> CustomInfo? {
        guard p.count >= 20, p[0] == 0x50, p[1] == 0x02 || p[1] == 0x03, p[2] == typeCustom, p[3] == 1 else { return nil }
        return CustomInfo(address: Veepoo.le32(p, 4), maxLength: Veepoo.le24(p, 8), uiType: Int(p[11]))
    }

    /// Kích thước màn theo `EWatchUIType` (tên enum gốc, chỉ các kiểu Veepoo gốc 1–18).
    public static func screen(uiType: Int) -> (width: Int, height: Int, round: Bool)? {
        let table: [Int: (Int, Int, Bool)] = [
            1: (240, 240, true), 2: (240, 240, false), 3: (240, 280, false), 4: (240, 280, false), 5: (240, 240, true),
            6: (240, 295, false), 7: (240, 295, false), 8: (360, 360, true), 9: (240, 280, false), 10: (80, 160, false),
            12: (135, 240, false), 13: (172, 320, false), 14: (167, 240, false), 15: (240, 284, false), 16: (240, 286, false),
            17: (320, 380, false), 18: (200, 320, false),
        ]
        return table[uiType].map { (width: $0.0, height: $0.1, round: $0.2) }
    }

    /// Đệm `FF` cho đủ bội 4 và tính CRC-16/MODBUS của file đã đệm (`UiUpdateUtil.java:488-496, 614-753`).
    public static func prepare(_ file: [UInt8]) -> (data: [UInt8], crc: Int) {
        let pad = (4 - file.count % 4) % 4
        let data = file + [UInt8](repeating: 0xFF, count: pad)
        return (data, Veepoo.crc16(data))
    }

    /// `50 01 01 addr LE32 len LE32 binType LE16 crc LE16 01 00…` (20 byte, `t2.java:236-243`): vào chế độ nhận mặt chợ.
    /// ← `50 01 01 01` = sẵn sàng.
    public static func updateModeServer(address: Int, length: Int, binDataType: Int, crc: Int) -> [UInt8] {
        var p: [UInt8] = [0x50, 0x01, typeServer]
        p += le32(address) + le32(length)
        p += [Veepoo.byte(binDataType), Veepoo.byte(binDataType >> 8), Veepoo.byte(crc), Veepoo.byte(crc >> 8), 0x01]
        return Veepoo.padded(20, p)
    }

    static func le32(_ v: Int) -> [UInt8] { [Veepoo.byte(v), Veepoo.byte(v >> 8), Veepoo.byte(v >> 16), Veepoo.byte(v >> 24)] }

    /// "DOOG" (`44 4F 4F 47`) — gói điều khiển ghi lên F0030002.
    public static let doog: [UInt8] = [0x44, 0x4F, 0x4F, 0x47]
    /// `DOOG 05 00`: bắt đầu (`t2.java:298-301`; AGPS là `05 01`).
    public static let doogStart: [UInt8] = doog + [0x05, 0x00]
    /// `DOOG 01 addr LE32 len LE32` (13 byte): xoá vùng nhớ (`t2.java:292-295`).
    public static func doogErase(address: Int, length: Int) -> [UInt8] { doog + [0x01] + le32(address) + le32(length) }
    /// `DOOG 02` + 0 (20 byte): gửi xong dữ liệu.
    public static let doogEnd = Veepoo.padded(20, doog + [0x02])
    /// `DOOG 03 crc LE32` + 0 (20 byte): kiểm CRC (`t2.java:61-74`).
    public static func doogCheck(crc: Int) -> [UInt8] { Veepoo.padded(20, doog + [0x03] + le32(crc)) }

    /// Notify F0030002 trong lúc tải (`UiUpdateUtil.java:771-858`).
    public enum Event: Equatable, Sendable {
        /// `00`: độ dài file không phải bội 4.
        case lengthNotMultipleOf4
        /// `05 …`: sẵn sàng ⇒ gửi lệnh xoá.
        case ready
        /// `01 01 n` bắt đầu xoá (n bước), `01 02 i` tiến độ, `01 03` xoá xong ⇒ gửi dữ liệu.
        case eraseStarted(Int)
        case eraseProgress(Int)
        case eraseDone
        /// `02`: nhận đủ dữ liệu ⇒ gửi kiểm CRC.
        case received
        /// `03 crcLo crcHi`: CRC vòng tay tính.
        case crc(Int)
    }

    public static func parseEvent(_ p: [UInt8]) -> Event? {
        guard let op = p.first else { return nil }
        // `x D0 …` là ghi âm AI, không thuộc luồng mặt đồng hồ.
        if p.count >= 6, p[1] == 0xD0 { return nil }
        switch op {
        case 0x00: return .lengthNotMultipleOf4
        case 0x05: return .ready
        case 0x01 where p.count > 2 && p[1] == 1: return .eraseStarted(Int(p[2]))
        case 0x01 where p.count > 2 && p[1] == 2: return .eraseProgress(Int(p[2]))
        case 0x01 where p.count > 2 && p[1] == 3: return .eraseDone
        case 0x01 where p.count == 2 && p[1] == 3: return .eraseDone
        case 0x02: return .received
        case 0x03 where p.count >= 3: return .crc(Veepoo.le16(p, 1))
        default: return nil
        }
    }

    /// `C7 01 index from` (index từ 1; from 0 mặc định / 1 chợ / 2 tuỳ chỉnh): chọn mặt (`jf/a2.java`). Sau khi cài mặt chợ,
    /// G Band kích hoạt bằng `C7 01 01 01` (`FaceGalleryFragment.java:109`).
    public static func select(index: Int, from: Int) -> [UInt8] { Veepoo.padded(20, [0xC7, 0x01, Veepoo.byte(index), Veepoo.byte(from)]) }
    public static let styleRead = Veepoo.padded(20, [0xC7, 0x02])

    /// ← `C7 <1|2> <1=ok> <index> <from>` (≥ 5 byte).
    public static func parseStyle(_ p: [UInt8]) -> (index: Int, from: Int)? {
        guard p.count >= 5, p[0] == 0xC7, p[1] == 1 || p[1] == 2, p[2] == 1 else { return nil }
        return (Int(p[3]), Int(p[4]))
    }

    /// Khối dữ liệu lên F0030003: MTU − 5 byte như app gốc (247 ⇒ 242), kẹp 20…242. iOS báo độ dài ghi tối đa = MTU − 3.
    public static func chunkSize(maxWriteLength: Int) -> Int { min(max(maxWriteLength - 2, 20), 242) }
}
