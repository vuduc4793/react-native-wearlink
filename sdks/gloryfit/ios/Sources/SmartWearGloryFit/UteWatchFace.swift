import Foundation

/// Đóng gói file mặt đồng hồ UTE (`.bin`), xem sdks/gloryfit/docs/02-watchface.md §4 (bản iOS của `UteWatchFace.kt`).
/// `[header 24 B][bảng element N × 24 B][00 00][ảnh element 1][element 2]…`, số nhiều byte little-endian,
/// pixel RGB565 big-endian, nén RLE khi `level ≥ 2` (trừ các type kim / chữ số).
public enum UteWatchFace {

    // Type element (onlinedial/ConfigType.java).
    public static let typePreview = 10
    public static let typeBackground = 17
    public static let typeHourTens = 57
    public static let typeHourUnits = 58
    public static let typeMinuteTens = 59
    public static let typeMinuteUnits = 60
    public static let typeColon = 7
    public static let typeBattery = 8
    public static let typeMonthTens = 63
    public static let typeMonthUnits = 64
    public static let typeDayTens = 65
    public static let typeDayUnits = 66
    public static let typeDateSeparator = 14
    public static let typeWeek = 15
    public static let typeAmPm = 16
    public static let typeBluetooth = 9
    public static let typeStepIcon = 24
    public static let typeStepDigits = [38, 39, 40, 41, 42]
    public static let typeStepProgress = 32
    // Firmware có định nghĩa (ConfigType.java) nhưng template của hãng không dùng: thử nghiệm.
    public static let typeSecondTens = 61
    public static let typeSecondUnits = 62
    public static let typeHeartIcon = 18
    public static let typeHeartDigits = [35, 36, 37]
    public static let typeKcalIcon = 29
    public static let typeKcalDigits = [43, 44, 45, 46]
    public static let typeDistanceIcon = 51
    public static let typeDistanceDigits = [52, 53, 54, 55, 56]

    /// Một element: `frames` là các ảnh ARGB cùng kích thước `w`×`h` (ví dụ 14 ảnh chữ số).
    public struct Element: Sendable {
        public let type: Int
        public let x: Int
        public let y: Int
        public let w: Int
        public let h: Int
        public let frames: [[UInt32]]

        public init(type: Int, x: Int, y: Int, w: Int, h: Int, frames: [[UInt32]]) throws {
            guard !frames.isEmpty, frames.allSatisfy({ $0.count == w * h }) else {
                throw GloryFitError("Element \(type): kích thước ảnh không khớp \(w)x\(h)")
            }
            self.type = type
            self.x = x
            self.y = y
            self.w = w
            self.h = h
            self.frames = frames
        }
    }

    private static func noCompress(_ type: Int) -> Bool {
        (1...3).contains(type) || (35...46).contains(type) || (52...70).contains(type)
    }

    /// ARGB → RGB565 big-endian. Pixel gần đen được đẩy thành (17,9,17) như app GloryFit, vì firmware
    /// (suy luận) coi 0x0000 là màu trong suốt.
    public static func rgb565(_ argb: [UInt32]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: argb.count * 2)
        for i in argb.indices {
            var r = Int((argb[i] >> 16) & 0xFF)
            var g = Int((argb[i] >> 8) & 0xFF)
            var b = Int(argb[i] & 0xFF)
            if r <= 16, g <= 8, b <= 16 { r = 17; g = 9; b = 17 }
            let v = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
            out[2 * i] = UInt8((v >> 8) & 0xFF)
            out[2 * i + 1] = UInt8(v & 0xFF)
        }
        return out
    }

    /// RLE của UTE (Rgb.picDataCompress): `u32 len + bảng offset H dòng + các dòng [n][count][màu…]`.
    public static func rle(_ px: [UInt8], w: Int, h: Int) -> [UInt8] {
        var table: [UInt8] = []
        var rows: [UInt8] = []
        var offset = h * 4
        for r in 0..<h {
            let base = r * w * 2
            func same(_ a: Int, _ c: Int) -> Bool {
                px[base + 2 * a] == px[base + 2 * c] && px[base + 2 * a + 1] == px[base + 2 * c + 1]
            }
            var pending: [UInt8] = []
            var prev = 0
            var rowBytes = 0
            var start = 0
            var i = 0
            var count = 0
            while i < w {
                if same(start, i), count != 255 {
                    count += 1
                    i += 1
                    if i != w { continue }
                }
                let hi = px[base + 2 * start]
                let lo = px[base + 2 * start + 1]
                var block: [UInt8]
                if prev == 0 {
                    block = [1, UInt8(count), hi, lo]
                } else if prev == count, pending[0] < 255 {
                    block = pending + [hi, lo]
                    block[0] += 1
                } else {
                    rows += pending
                    rowBytes += pending.count
                    block = [1, UInt8(count), hi, lo]
                }
                if i == w {
                    rows += block
                    rowBytes += block.count
                    table += le32(offset)
                    offset += rowBytes
                }
                prev = count
                pending = block
                count = 0
                start = i
            }
        }
        let body = table + rows
        return le32(body.count) + body
    }

    public static func build(width: Int, height: Int, level: Int, elements: [Element]) -> [UInt8] {
        // Sắp ổn định theo type như sortedBy của Kotlin.
        let sorted = elements.enumerated().sorted { ($0.element.type, $0.offset) < ($1.element.type, $1.offset) }.map(\.element)
        let blobs: [[UInt8]] = sorted.map { e in
            var out: [UInt8] = []
            for frame in e.frames {
                let px = rgb565(frame)
                out += level >= 2 && !noCompress(e.type) ? rle(px, w: e.w, h: e.h) : px
            }
            return out
        }
        // Element có dữ liệu giống hệt element trước thì trỏ chung địa chỉ, không chép lại (PicUtils.java:854-881).
        var addresses = [Int](repeating: 0, count: sorted.count)
        var unique: [[UInt8]] = []
        var address = (sorted.count + 1) * 24 + 2
        for k in sorted.indices {
            if let previous = (0..<k).first(where: { blobs[$0] == blobs[k] }) {
                addresses[k] = addresses[previous]
            } else {
                addresses[k] = address
                address += blobs[k].count
                unique.append(blobs[k])
            }
        }
        var payload: [UInt8] = []
        for (k, e) in sorted.enumerated() {
            payload += le16(e.type) + le16(e.w) + le32(addresses[k]) + le16(e.h)
            payload += le16(e.x) + le16(e.y) + le16(0)
            payload.append(UInt8(truncatingIfNeeded: e.frames.count))
            payload += [UInt8](repeating: 0, count: 7)
        }
        payload += [0, 0]
        for blob in unique { payload += blob }
        var header = [UInt8](repeating: 0xFF, count: 24)
        header[0] = 0xFE
        header.replaceSubrange(4..<8, with: le32(payload.count))
        header.replaceSubrange(8..<12, with: le32(Int(crc32(payload))))
        header.replaceSubrange(12..<14, with: le16(width))
        header.replaceSubrange(14..<16, with: le16(height))
        header[16] = 0
        header[17] = 1
        header[19] = UInt8(truncatingIfNeeded: level)
        return header + payload
    }

    // MARK: - Kiểm tra file dựng sẵn

    /// Kiểm tra một file `.bin` trước khi cài (như `installWatchFaceFile` Android): độ dài, kích thước màn,
    /// độ dài và CRC-32 trong header, dung lượng tối đa, file nén RLE trên đồng hồ không hỗ trợ nén.
    public static func validate(_ bin: [UInt8], width: Int, height: Int, maxBytes: Int, level: Int) throws {
        guard bin.count >= 24 else { throw GloryFitError("File mặt đồng hồ quá ngắn") }
        let w = le16(bin, 12), h = le16(bin, 14)
        if w != width || h != height { throw GloryFitError("File \(w)×\(h), màn đồng hồ \(width)×\(height)") }
        if le32(bin, 4) != bin.count - 24 { throw GloryFitError("Độ dài trong header không khớp file") }
        if UInt32(le32(bin, 8)) != crc32(bin[24...]) { throw GloryFitError("CRC-32 trong header không khớp file") }
        if bin.count > maxBytes {
            throw GloryFitError("Mặt đồng hồ \(bin.count / 1024) KB vượt giới hạn \(maxBytes / 1024) KB")
        }
        if bin[19] >= 2, level < 2 { throw GloryFitError("File nén RLE nhưng đồng hồ không hỗ trợ nén") }
    }

    // MARK: - CRC-32 (zlib / java.util.zip.CRC32)

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func crc32<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in bytes { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    // MARK: - Little-endian

    static func le16(_ v: Int) -> [UInt8] { [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8)] }

    static func le32(_ v: Int) -> [UInt8] {
        [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8),
         UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 24)]
    }

    static func le16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) | (Int(b[i + 1]) << 8) }

    static func le32(_ b: [UInt8], _ i: Int) -> Int {
        Int(b[i]) | (Int(b[i + 1]) << 8) | (Int(b[i + 2]) << 16) | (Int(b[i + 3]) << 24)
    }
}
