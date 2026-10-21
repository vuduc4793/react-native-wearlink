import Foundation
import SmartWearCore

/// AGPS của đồng hồ Realtek có GNSS (HT43, có thể cả Y25), lệnh `01 E9` trên 34F1/34F2. Cùng bố cục với `UteAgps.kt`
/// (GloryFitPro 1.9.0.2 `uterkif/uterkcase.java`; GloryFit iOS doc 09 §4). SDK không gọi server: file dữ liệu vệ tinh do app tự lấy.
///
/// - Đồng hồ hỏi `01 E9 AC 03 01 op` (2 = đã có file chưa, 1 = muốn nhận file); `01 E9 AC 01 xx 01` = xin vị trí điện thoại.
/// - Trạng thái `01 E9 AB 03 01 st` (1 chuẩn bị, 3 đã có file, 4 lỗi, 5 không hỗ trợ).
/// - Vị trí `01 E9 AB 02 0C ts lat lon` (giây Unix, toạ độ × 10⁷, big-endian).
/// - Thông tin `01 E9 AA 01` → `01 E9 AA 01 seq data…` … `01 E9 AA 01 FD crc`, TLV 1 = interval, 2 = version, 3 = file `;`.
/// - Còn hợp lệ: `56 FD` (33F1) → `56 FD st`.
/// - File: `01 E9 AB 04 idxHi idxLo <L-6 byte>`, mỗi 4 KB chờ `01 E9 AC 04 01 07`, cuối `01 E9 AB 04 FD FD xor`, kết quả `AC 04 01 01`.
public enum UteAgps {
    /// `isHasFunction_9(0x400000)` = 34F1 b14.6.
    public static func supported(_ f: Ute.Features) -> Bool { f.has(9, 0x400000) }

    public static let statusPrepare = 1
    public static let statusDone = 3
    public static let statusFail = 4
    public static let statusNotSupport = 5

    public static let transferOk = 1
    public static let transferCancelled = 3
    public static let transferCrc = 4
    public static let transferTooLarge = 5
    public static let transferResend = 6
    public static let transferContinue = 7

    public static let maxFiles = 16
    public static let maxFileBytes = 256 * 1024
    public static let maxTotalBytes = 512 * 1024
    public static let sectorBytes = 4096
    /// Vị trí điện thoại cũ hơn chừng này (giây) không gửi nữa.
    public static let positionMaxAge: TimeInterval = 6 * 3600
    /// Đồng hồ hỏi mỗi phút: gửi lại vị trí tối đa mỗi chừng này (giây).
    public static let positionResend: TimeInterval = 600

    public static let info: [UInt8] = [0x01, 0xE9, 0xAA, 0x01]
    public static let ephemerisState: [UInt8] = [0x56, 0xFD]

    public static func status(_ st: Int) -> [UInt8] { [0x01, 0xE9, 0xAB, 0x03, 0x01, UInt8(st & 0xFF)] }

    public static func position(timestamp: Int64, latitude: Double, longitude: Double) throws -> [UInt8] {
        guard (-90...90).contains(latitude), (-180...180).contains(longitude) else { throw GloryFitError("Toạ độ không hợp lệ") }
        return [0x01, 0xE9, 0xAB, 0x02, 0x0C] + be32(Int32(truncatingIfNeeded: timestamp))
            + be32(Int32(latitude * 1e7)) + be32(Int32(longitude * 1e7))
    }

    public static func dataPacket(_ index: Int, _ chunk: ArraySlice<UInt8>) -> [UInt8] {
        [0x01, 0xE9, 0xAB, 0x04, UInt8((index >> 8) & 0xFF), UInt8(index & 0xFF)] + chunk
    }

    public static func endPacket(_ xor: Int) -> [UInt8] { [0x01, 0xE9, 0xAB, 0x04, 0xFD, 0xFD, UInt8(xor & 0xFF)] }

    private static func isE9(_ p: [UInt8], _ a: UInt8, _ b: UInt8) -> Bool {
        p.count >= 4 && p[0] == 0x01 && p[1] == 0xE9 && p[2] == a && p[3] == b
    }

    /// Đồng hồ hỏi AGPS; nil nếu không phải gói hỏi.
    public static func parseRequest(_ p: [UInt8]) -> AgpsRequestType? {
        if isE9(p, 0xAC, 0x03), p.count >= 6 {
            switch p[5] {
            case 1: return .download
            case 2: return .status
            default: return nil
            }
        }
        if isE9(p, 0xAC, 0x01), p.count >= 6, p[5] == 1 { return .position }
        return nil
    }

    public static func isInfoPacket(_ p: [UInt8]) -> Bool { isE9(p, 0xAA, 0x01) && p.count >= 5 }
    public static func isInfoEnd(_ p: [UInt8]) -> Bool { isInfoPacket(p) && p[4] == 0xFD }
    public static func isPositionAck(_ p: [UInt8]) -> Bool { isE9(p, 0xAB, 0x02) }
    public static func isTransferResult(_ p: [UInt8]) -> Bool { isE9(p, 0xAC, 0x04) && p.count >= 6 }
    public static func transferStatus(_ p: [UInt8]) -> Int { Int(p[5]) }
    /// `01 E9 AC 04 01 06 HH LL`: gửi lại từ gói HHLL.
    public static func resendFrom(_ p: [UInt8]) -> Int? { p.count >= 8 && p[5] == 0x06 ? Ute.be16(p, 6) : nil }

    /// `56 FD st` → còn dữ liệu vệ tinh hợp lệ.
    public static func parseEphemerisState(_ p: [UInt8]) -> Bool? {
        p.count >= 3 && p[0] == 0x56 && p[1] == 0xFD ? p[2] == 1 : nil
    }

    /// Ghép các gói `01 E9 AA 01 seq data` (seq 0 mở đầu, `FD` kết thúc) rồi đọc TLV.
    public static func parseInfo(_ packets: [[UInt8]], ephemerisValid: Bool? = nil) -> AgpsInfo {
        var data: [UInt8] = []
        for p in packets where isInfoPacket(p) && p[4] != 0xFD {
            if p[4] == 0 { data = Array(p[5...]) } else { data += p[5...] }
        }
        var interval: Int?
        var version: Int?
        var files: [String] = []
        var i = 0
        while i + 2 <= data.count {
            let tag = data[i]
            let len = Int(data[i + 1])
            guard i + 2 + len <= data.count else { break }
            let v = Array(data[(i + 2)..<(i + 2 + len)])
            switch tag {
            case 1: interval = beN(v)
            case 2: version = beN(v)
            case 3:
                files = String(decoding: v, as: UTF8.self).split(separator: ";")
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            default: break
            }
            i += 2 + len
        }
        return AgpsInfo(files: files, version: version, interval: interval, ephemerisValid: ephemerisValid)
    }

    /// `u16 len(desc) || desc || u32 tổng || dữ liệu`, desc = mỗi file `u8 len(tên) || tên || u32 cỡ`. Kiểm giới hạn.
    public static func payload(_ files: [AgpsFile]) throws -> [UInt8] {
        guard !files.isEmpty else { throw GloryFitError("Chưa có file AGPS") }
        guard files.count <= maxFiles else { throw GloryFitError("Quá \(maxFiles) file AGPS") }
        var desc: [UInt8] = []
        var total = 0
        for f in files {
            guard !f.data.isEmpty, f.data.count <= maxFileBytes else {
                throw GloryFitError("File AGPS \(f.name) rỗng hoặc quá \(maxFileBytes / 1024) KB")
            }
            let name = Array(try stem(f.name).utf8)
            desc += [UInt8(name.count)] + name + be32(Int32(f.data.count))
            total += f.data.count
        }
        guard total <= maxTotalBytes else { throw GloryFitError("Tổng file AGPS quá \(maxTotalBytes / 1024) KB") }
        var out: [UInt8] = [UInt8((desc.count >> 8) & 0xFF), UInt8(desc.count & 0xFF)] + desc + be32(Int32(total))
        for f in files { out += [UInt8](f.data) }
        return out
    }

    /// Tên trong mô tả: bỏ thư mục và phần mở rộng như app gốc, chỉ ASCII in được, ≤ 64 ký tự.
    public static func stem(_ name: String) throws -> String {
        var s = Substring(name.split(separator: "/", omittingEmptySubsequences: false).last ?? "")
        if let dot = s.lastIndex(of: ".") { s = s[..<dot] }
        guard !s.isEmpty, s.count <= 64, s.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else {
            throw GloryFitError("Tên file AGPS không hợp lệ: \(name)")
        }
        return String(s)
    }

    public static func packets(_ payload: [UInt8], chunk: Int) -> [[UInt8]] {
        stride(from: 0, to: payload.count, by: chunk).enumerated().map { i, from in
            dataPacket(i, payload[from..<min(payload.count, from + chunk)])
        }
    }

    /// XOR mọi byte của mọi gói dữ liệu (cả 6 byte đầu gói).
    public static func xor(_ packets: [[UInt8]]) -> Int { packets.reduce(0) { acc, p in p.reduce(acc) { $0 ^ Int($1) } } }

    private static func beN(_ v: [UInt8]) -> Int? { v.isEmpty || v.count > 4 ? nil : v.reduce(0) { ($0 << 8) | Int($1) } }
    private static func be32(_ v: Int32) -> [UInt8] {
        let u = UInt32(bitPattern: v)
        return [UInt8(u >> 24), UInt8((u >> 16) & 0xFF), UInt8((u >> 8) & 0xFF), UInt8(u & 0xFF)]
    }
}
