import Foundation
import SmartWearCore

/// Bài tập đa môn thể thao (`FD FA`), bản Swift của phần bài tập trong `Ute.kt` Android.
/// Nguồn: `BluetoothLeService.dealWithSportMode`, `MultipleSportsModesUtils` (app GloryFit Android).
extension Ute {
    /// Yêu cầu đồng bộ bài tập: `FD FA` + 6 byte mốc (0 = từ đầu) (`WriteCommandToBLE.syncMultipleSportsModes`).
    public static let workoutSync: [UInt8] = [0xFD, 0xFA, 0, 0, 0, 0, 0, 0]

    /// Gói đầu `FD FA … nn nn` (10 byte): số bài tập sẽ gửi, byte 8–9 BE.
    public static func workoutCount(_ p: [UInt8]) -> Int? {
        p.count == 10 && p[0] == 0xFD && p[1] == 0xFA ? be16(p, 8) : nil
    }

    /// `FD FD`: hết một bài tập.
    public static func isWorkoutEnd(_ p: [UInt8]) -> Bool { (2...3).contains(p.count) && p[0] == 0xFD && p[1] == 0xFD }

    /// Giải mã các gói bài tập. Mỗi bài:
    /// - gói số 0: `FD 00 00 type rateCnt(2) YYYY MM DD hh mm ss` + kết thúc. `endIsTimestamp` (F5 `0x040000`):
    ///   byte 17–19 là thời gian tập hiệu quả (giây); không thì 13–19 là ngày giờ kết thúc.
    /// - gói số 1: bước (u24 @3), kcal (@8), quãng đường km = b10 + b11/100, HR tb/max/min (@12–14), pace (@15–16).
    /// - gói số ≥ 2: vùng / chuỗi nhịp tim (chưa dùng). `FD FD` kết thúc bài.
    public static func parseWorkouts(_ packets: [[UInt8]], calendar: Calendar = .current, endIsTimestamp: Bool) -> [Workout] {
        var out: [Workout] = []
        var cur: Workout?
        func flush() { if let c = cur { out.append(c) }; cur = nil }
        func positive(_ v: Int) -> Int? { v > 0 ? v : nil }
        for p in packets {
            guard !p.isEmpty, p[0] == 0xFD, workoutCount(p) == nil else { continue }
            if isWorkoutEnd(p) { flush(); continue }
            guard p.count >= 13 else { continue }
            switch be16(p, 1) {
            case 0:
                flush()
                let type = u(p, 3)
                guard let start = calendar.date(from: DateComponents(
                    year: be16(p, 6), month: u(p, 8), day: u(p, 9), hour: u(p, 10), minute: u(p, 11), second: u(p, 12)
                )) else { continue }
                var active = 0
                var end = start
                if p.count >= 20 {
                    if endIsTimestamp {
                        active = be24(p, 17)
                        end = start.addingTimeInterval(TimeInterval(active))
                    } else if let e = calendar.date(from: DateComponents(
                        year: be16(p, 13), month: u(p, 15), day: u(p, 16), hour: u(p, 17), minute: u(p, 18), second: u(p, 19)
                    )) {
                        end = e
                        active = max(0, Int(e.timeIntervalSince(start)))
                    }
                }
                cur = Workout(type: type, name: sportName(type), start: start, end: end, activeSeconds: active)
            case 1:
                guard var w = cur else { continue }
                let km = Double(u(p, 10)) + Double(u(p, 11)) / 100
                w.steps = positive(be24(p, 3))
                w.calories = positive(be16(p, 8))
                w.distanceMeters = positive(Int(km * 1000))
                w.avgHeartRate = positive(u(p, 12))
                w.maxHeartRate = positive(u(p, 13))
                w.minHeartRate = positive(u(p, 14))
                if p.count >= 17 { w.paceSecondsPerKm = positive(u(p, 15) * 60 + u(p, 16)) }
                cur = w
            default:
                break
            }
        }
        flush()
        return out.sorted { $0.start > $1.start }
    }

    /// Tên môn theo mã (`SportsMode.MULTIPLE_SPORTS_MODE_*` của SDK UTE).
    public static func sportName(_ type: Int) -> String { sportNames[type] ?? "Môn thể thao #\(type)" }

    static let sportNames: [Int: String] = [
        1: "Chạy bộ", 2: "Đạp xe", 3: "Nhảy dây", 4: "Bơi", 5: "Cầu lông", 6: "Bóng bàn", 7: "Quần vợt",
        8: "Leo núi", 9: "Đi bộ", 10: "Bóng rổ", 11: "Bóng đá", 12: "Bóng chày", 13: "Bóng chuyền",
        14: "Cricket", 15: "Bóng bầu dục", 16: "Khúc côn cầu", 17: "Nhảy", 18: "Đạp xe trong nhà", 19: "Yoga",
        20: "Gập bụng", 21: "Máy chạy bộ", 22: "Thể dục dụng cụ", 23: "Chèo thuyền", 24: "Bật nhảy",
        25: "Tập tự do", 26: "Đi bộ trong nhà", 27: "Chạy trong nhà", 28: "Tập sức mạnh", 29: "Tập bậc thang",
        30: "Cưỡi ngựa", 31: "Máy elip", 32: "Thái cực quyền", 33: "Đá cầu", 34: "Quyền anh",
        35: "Đi bộ ngoài trời", 36: "Chạy địa hình", 37: "Trượt tuyết", 39: "Taekwondo", 41: "Máy chèo",
        43: "Đi bộ đường dài", 46: "Karate", 49: "Pilates", 75: "Golf", 81: "Trượt băng", 96: "Pickleball",
        97: "HIIT", 108: "Hít xà", 109: "Chống đẩy", 110: "Plank", 115: "Marathon", 134: "Đạp xe trong nhà",
        151: "Ba môn phối hợp", 155: "Cử tạ", 166: "Chạy trong nhà", 167: "Tập luyện chung",
    ]
}
