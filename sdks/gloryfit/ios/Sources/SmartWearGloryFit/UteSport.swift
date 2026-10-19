import Foundation
import SmartWearCore

/// Điều khiển bài tập từ điện thoại, số liệu realtime, GPS điện thoại và danh sách môn (doc 10 §2.4).
/// Nguồn: GloryFit 4.0.12 `WriteCommandToBLE.java:3484-3576` (`W`), `BluetoothLeService.dealWithSportMode`
/// (`B:7024-7420`), `MultipleSportsModesUtils.java:169-195`, `agps/AGPSCommandUtil.java:222-262`,
/// `sports/util/SportManagementUtil.java:60-111`; GloryFitPro 1.9.0.2 `uterkif/uterkthis.java` (`T`):
/// bắt đầu `T:3986-4000`, dừng `T:2139-2154`, tạm dừng / tiếp / đẩy số liệu `T:3341, 3464, 3537, 3682-3725`,
/// vị trí `T:4517-4528`, trạng thái định vị `T:1467-1478`, danh sách môn `T:360-363, 925-1005, 3374-3381`.
///
/// Kênh: lệnh `FD 11/00/22/33/44/AA` ghi 33F1; `FD 01`, `FD 02`, `FD 48` ghi 34F1. Đồng hồ trả mọi gói `FD` trên
/// 33F2/34F2. Gói `FD` của luồng đồng bộ bài tập (`FD FA`) do `workoutStream` nhận riêng, không qua đây.
public enum UteSport {
    /// F5 `0x2` (`IS_SUPPORT_SPORT_CONTROL` = `isHasSportPause`): bắt đầu / tạm dừng / dừng từ app.
    public static func control(_ f: Ute.Features) -> Bool { f.has(5, 0x000002) }
    /// F6 `0x2000` (`isHasCustomSportIconList`, `RkSupportUtils.isSupSportList`): đọc / ghi danh sách môn `FD 48`.
    public static func sportList(_ f: Ute.Features) -> Bool { f.has(6, 0x002000) }
    /// F7 `0x80` (`isHasSportGPS`): đồng hồ xin vị trí điện thoại khi tập (`BluetoothLeService.dealWithSportMode`).
    public static func phoneGps(_ f: Ute.Features) -> Bool { f.has(7, 0x000080) }
    /// F11 `0x10` (`isHasSupportDistance`): gói tạm dừng / tiếp có thêm 3 byte bước (`T:3683`).
    static func stepsInControl(_ f: Ute.Features) -> Bool { f.has(11, 0x000010) }

    /// Chu kỳ ghi HR của bài tập: GloryFitPro luôn gửi 1 (`UteBleConnectionRkImpl.java:1986` `startSports(type, 1)`).
    static let interval: UInt8 = 1

    // MARK: Lệnh app → đồng hồ (33F1)

    /// `FD 11 type intv`: bắt đầu môn `type`.
    public static func start(_ type: Int) -> [UInt8] { [0xFD, 0x11, UInt8(truncatingIfNeeded: type), interval] }
    /// `FD 00 type intv`: dừng.
    public static func stop(_ type: Int) -> [UInt8] { [0xFD, 0x00, UInt8(truncatingIfNeeded: type), interval] }
    /// `FD AA`: hỏi bài tập đang chạy → `FD AA st type` (`queryCurrentlySportOpened`).
    public static let query: [UInt8] = [0xFD, 0xAA]

    /// `FD 22` (tạm dừng) / `FD 33` (tiếp tục): `FD op type intv hh mm ss` (7 byte, bài tập không do app đo GPS;
    /// bản 13/16 byte kèm kcal, km, pace, bước chỉ dùng khi app tự tính số liệu, chưa làm).
    public static func pause(_ type: Int, elapsed: Int) -> [UInt8] { control(0x22, type, elapsed) }
    public static func resume(_ type: Int, elapsed: Int) -> [UInt8] { control(0x33, type, elapsed) }

    static func control(_ op: UInt8, _ type: Int, _ elapsed: Int) -> [UInt8] {
        let s = max(0, elapsed)
        return [0xFD, op, UInt8(truncatingIfNeeded: type), interval,
                UInt8(truncatingIfNeeded: s / 3600), UInt8(truncatingIfNeeded: s % 3600 / 60), UInt8(truncatingIfNeeded: s % 60)]
    }

    // MARK: Gói đồng hồ → app

    /// Trạng thái bài tập trong gói `FD` dài 4 hoặc 13 byte (`B:7027-7178`):
    /// - `FD 04 type st`: người dùng bấm trên đồng hồ, st `11` bắt đầu / `00` dừng / `22` tạm dừng / `33` tiếp;
    /// - `FD 11 type …`, `FD 00 type …`, `FD 22 type …`, `FD 33 type …`: đồng hồ xác nhận lệnh của app.
    /// `FD AA st type` (trả lời `query`) xem `parseQuery`.
    public static func parseState(_ p: [UInt8]) -> WorkoutEvent? {
        guard p.count == 4 || p.count == 13, p[0] == 0xFD else { return nil }
        let type = Int(p[2])
        switch p[1] {
        case 0x04: return state(p[3]).map { .state($0, sportType: type, byDevice: true) }
        case 0x11: return .state(.started, sportType: type, byDevice: false)
        case 0x00: return .state(.stopped, sportType: type, byDevice: false)
        case 0x22: return .state(.paused, sportType: type, byDevice: false)
        case 0x33: return .state(.resumed, sportType: type, byDevice: false)
        default: return nil
        }
    }

    static func state(_ st: UInt8) -> WorkoutState? {
        switch st {
        case 0x11: .started
        case 0x00: .stopped
        case 0x22: .paused
        case 0x33: .resumed
        default: nil
        }
    }

    /// `FD AA st type` (4 byte): st `11` đang tập, `22` tạm dừng, `00` không tập (`B:7130-7178`). nil = không phải gói này.
    public static func parseQuery(_ p: [UInt8]) -> (state: WorkoutState, sportType: Int)? {
        guard p.count == 4, p[0] == 0xFD, p[1] == 0xAA else { return nil }
        let st: WorkoutState
        switch p[2] {
        case 0x11: st = .started
        case 0x22: st = .paused
        case 0x00: st = .stopped
        default: return nil
        }
        return (st, Int(p[3]))
    }

    /// Số liệu realtime 14 byte `FD type hr kcal(2) paceMin paceSec steps(3) count(2) kmInt kmDec`
    /// (`MultipleSportsModesUtils.*Real`, chỉ khi không đồng bộ). Quãng đường = (kmInt + kmDec/100) km.
    public static func parseRealtime(_ p: [UInt8]) -> WorkoutRealtime? {
        guard p.count == 14, p[0] == 0xFD else { return nil }
        let hr = Int(p[2])
        return WorkoutRealtime(
            sportType: Int(p[1]), heartRate: (41...199).contains(hr) ? hr : nil, calories: Ute.be16(p, 3),
            paceSecondsPerKm: Int(p[5]) * 60 + Int(p[6]), steps: Ute.be24(p, 7), count: Ute.be16(p, 10),
            distanceMeters: Int(p[12]) * 1000 + Int(p[13]) * 10
        )
    }

    /// Đồng hồ xin vị trí: `FD 01 AA type` (4 byte) = bắt đầu; `FD 01 55` (3 byte) = dừng (`B:7046-7056, 7215-7236`).
    public static func parseLocationRequest(_ p: [UInt8]) -> LocationRequest? {
        guard p.count >= 3, p[0] == 0xFD, p[1] == 0x01 else { return nil }
        if p.count == 4, p[2] == 0xAA { return LocationRequest(start: true, sportType: Int(p[3])) }
        if p.count == 3, p[2] == 0x55 { return LocationRequest(start: false) }
        return nil
    }

    // MARK: Vị trí điện thoại (34F1)

    /// `FD 01 01` / `FD 01 00`: điện thoại đã / không định vị được (`AGPSCommandUtil.sendAppLocationStatus`, gửi khi có
    /// điểm đầu tiên).
    public static func locationStatus(_ ok: Bool) -> [UInt8] { [0xFD, 0x01, ok ? 0x01 : 0x00] }

    /// `FD 02 lat×1e6(4) lon×1e6(4) speed×100(2) pointDist(4) totalDist(4)` (20 byte, số có dấu BE, `T:4517-4528`).
    /// speed m/s; quãng đường mét: pointDist = từ điểm trước, totalDist = cộng dồn. GloryFit cũ gửi mỗi 3 s.
    public static func location(latitude: Double, longitude: Double, speed: Double, pointMeters: Int, totalMeters: Int) -> [UInt8] {
        func be32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (24 - 8 * $0)) } }
        let sp = Int((max(0, speed) * 100).rounded())
        return [0xFD, 0x02] + be32(Int(latitude * 1_000_000)) + be32(Int(longitude * 1_000_000))
            + [UInt8(truncatingIfNeeded: sp >> 8), UInt8(truncatingIfNeeded: sp)] + be32(pointMeters) + be32(totalMeters)
    }

    /// Khoảng cách hai điểm (mét, công thức haversine) để tính pointDist.
    public static func distanceMeters(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6_371_000.0
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180
        let dp = (lat2 - lat1) * .pi / 180, dl = (lon2 - lon1) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * atan2(sqrt(a), sqrt(1 - a))
    }

    // MARK: Danh sách môn `FD 48` (34F1)

    /// `FD 48 AA`: đọc danh sách môn.
    public static let sportListRead: [UInt8] = [0xFD, 0x48, 0xAA]

    /// Kết quả đọc danh sách: các gói `FD 48 AA seq [type hiện vị-trí]…` (seq 0 = gói đầu), kết thúc
    /// `FD 48 AA FD crc minH minL maxH maxL` (9 byte; min/max = số môn hiện ít / nhiều nhất).
    public struct SportList: Equatable, Sendable {
        public var sports: [SportType]
        public var minShown: Int?
        public var maxShown: Int?
    }

    /// Gói kết thúc của luồng đọc danh sách.
    public static func isSportListEnd(_ p: [UInt8]) -> Bool { p.count >= 4 && p[0] == 0xFD && p[1] == 0x48 && p[2] == 0xAA && p[3] == 0xFD }

    /// Ghép các gói `FD 48 AA …` (Pro `uterkshort.uterkdo(byte[], boolean)`; GloryFit `processSportManagementData`
    /// bỏ mã môn 0).
    public static func parseSportList(_ packets: [[UInt8]]) -> SportList {
        var sports: [SportType] = []
        var minShown: Int?, maxShown: Int?
        for p in packets where p.count >= 4 && p[0] == 0xFD && p[1] == 0x48 && p[2] == 0xAA {
            if p[3] == 0xFD {
                if p.count >= 9 { minShown = Ute.be16(p, 5); maxShown = Ute.be16(p, 7) }
                continue
            }
            if p[3] == 0 { sports = [] }
            var i = 4
            while i + 2 < p.count {
                let type = Int(p[i])
                if type > 0 {
                    sports.append(SportType(type: type, name: Ute.sportName(type), shown: p[i + 1] == 1, position: Int(p[i + 2])))
                }
                i += 3
            }
        }
        return SportList(sports: sports, minShown: minShown, maxShown: maxShown)
    }

    /// Ghi danh sách: các gói `FD 48 seq [type hiện vị-trí]…` (mỗi gói tối đa `(packetLength − 3) / 3` môn), rồi
    /// `FD 48 FD xor` với xor = XOR mọi byte từ vị trí 2 (seq + bản ghi) của các gói trước (`T:925-1005`).
    /// Đồng hồ trả `FD 48 FB` sau mỗi gói, `FD 48 FD` khi xong (`B:7277-7300`).
    public static func sportListPackets(_ sports: [SportType], packetLength: Int) -> [[UInt8]] {
        let per = max(1, (packetLength - 3) / 3)
        var out: [[UInt8]] = []
        var xor: UInt8 = 0
        var seq = 0
        for start in stride(from: 0, to: sports.count, by: per) {
            var p: [UInt8] = [0xFD, 0x48, UInt8(truncatingIfNeeded: seq)]
            for s in sports[start..<min(sports.count, start + per)] {
                p += [UInt8(truncatingIfNeeded: s.type), s.shown ? 1 : 0, UInt8(truncatingIfNeeded: s.position)]
            }
            for b in p[2...] { xor ^= b }
            out.append(p)
            seq += 1
        }
        out.append([0xFD, 0x48, 0xFD, xor])
        return out
    }
}
