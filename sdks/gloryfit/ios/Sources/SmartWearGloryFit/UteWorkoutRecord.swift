import Foundation
import SmartWearCore

/// Phần chi tiết của bản ghi bài tập `FD FA` (gói số ≥ 2): vùng nhịp tim, sải bước, chuỗi mẫu (HR, pace/tốc độ, nhịp bước,
/// toạ độ GPS). Bản Swift của `UteWorkoutRecord.kt`; bố cục và bảng kiểu mẫu xem ở đó
/// (nguồn `BluetoothLeService.java:7340-7556`, `MultipleSportsModesUtils.java:146-213` của app GloryFit).
enum UteWorkoutRecord {
    /// Có F7 `0x80`: gói 2, 3 là gói tổng hợp, mẫu bắt đầu từ gói 4.
    static func firstSampleSeq(hasDetail: Bool) -> Int { hasDetail ? 4 : 2 }

    /// Khoảng mẫu (giây) ở byte 17 của gói 1 (`bleTimeInterval`; > 220 thì trừ 220).
    static func intervalSeconds(_ seq1: [UInt8]) -> Int? {
        guard seq1.count >= 18 else { return nil }
        let v = Ute.u(seq1, 17)
        let s = v > 220 ? v - 220 : v
        return s > 0 ? s : nil
    }

    /// Số byte mỗi mẫu theo kiểu; nil = kiểu chưa biết.
    static func sampleSize(_ format: Int) -> Int? {
        switch format {
        case 0: 1
        case 1, 3, 5: 12
        case 2, 4, 6, 7: 4
        default: nil
        }
    }

    /// Giải mã dữ liệu mẫu đã nối theo `format`. Kiểu lạ ⇒ rỗng. Mẫu không có gì (HR 0, không toạ độ) bị bỏ.
    static func samples(_ format: Int, _ data: [UInt8], start: Date, intervalSeconds: Int) -> [WorkoutSample] {
        guard let size = sampleSize(format) else { return [] }
        var out: [WorkoutSample] = []
        for i in 0..<(data.count / size) {
            let o = i * size
            let t = start.addingTimeInterval(TimeInterval(i * intervalSeconds))
            func b(_ k: Int) -> Int { Ute.u(data, o + k) }
            let hr: Int? = (1...254).contains(b(0)) ? b(0) : nil
            func coord(_ k: Int) -> Double { Double(s32(data, o + k)) / 1_000_000 }
            var s: WorkoutSample?
            switch format {
            case 0:
                s = (41...199).contains(b(0)) ? WorkoutSample(time: t, heartRate: b(0)) : nil
            case 1, 5:
                s = withCoords(WorkoutSample(time: t, heartRate: hr, paceSecondsPerKm: pace(b(1), b(2)), cadence: positive(b(3))),
                               coord(4), coord(8))
            case 2, 6:
                s = WorkoutSample(time: t, heartRate: hr, paceSecondsPerKm: pace(b(1), b(2)), cadence: positive(b(3)))
            case 3:
                s = withCoords(WorkoutSample(time: t, heartRate: hr, speedKmh: speed(b(1), b(2))), coord(4), coord(8))
            case 4:
                s = WorkoutSample(time: t, heartRate: hr, speedKmh: speed(b(1), b(2)))
            case 7:
                s = WorkoutSample(time: t, heartRate: hr, cadence: positive(b(1)))
            default:
                s = nil
            }
            if let s, !isEmpty(s) { out.append(s) }
        }
        return out
    }

    /// Gắn phần chi tiết vào bài `w`: `detail` là các gói số ≥ 2 theo thứ tự nhận. Gói nhảy số (gói `FD` khác lẫn vào) bị bỏ.
    static func withDetail(_ w: Workout, _ detail: [[UInt8]], interval: Int?, hasDetail: Bool) -> Workout {
        var out = w
        out.sampleIntervalSeconds = interval
        var format = 0
        var next = firstSampleSeq(hasDetail: hasDetail)
        var data: [UInt8] = []
        for p in detail where p.count >= 3 {
            let seq = Ute.be16(p, 1)
            if hasDetail, seq == 2 {
                if p.count >= 20 {
                    out.heartRateZoneSeconds = [3, 6, 9, 12, 15].map { Ute.be24(p, $0) }
                    out.avgStrideCm = positive(Ute.u(p, 18))
                    out.maxStrideCm = positive(Ute.u(p, 19))
                }
            } else if hasDetail, seq == 3 {
                if p.count >= 9 {
                    out.minStrideCm = positive(Ute.u(p, 3))
                    format = Ute.u(p, 8)
                }
            } else if seq == next {
                data += p[3...]
                next += 1
            }
        }
        guard !data.isEmpty, let interval else { return out }
        out.samples = samples(format, data, start: w.start, intervalSeconds: interval)
        return out
    }

    private static func positive(_ v: Int) -> Int? { v > 0 ? v : nil }
    private static func pace(_ min: Int, _ sec: Int) -> Int? { positive(min * 60 + sec) }
    private static func speed(_ whole: Int, _ hundredths: Int) -> Double? {
        let v = Double(whole) + Double(hundredths) / 100
        return v > 0 ? v : nil
    }

    /// Toạ độ (0, 0) hoặc ngoài khoảng = chưa bắt được GPS ở mẫu đó.
    private static func withCoords(_ s: WorkoutSample, _ lat: Double, _ lon: Double) -> WorkoutSample {
        guard !(lat == 0 && lon == 0), (-90...90).contains(lat), (-180...180).contains(lon) else { return s }
        var s = s
        s.latitude = lat
        s.longitude = lon
        return s
    }

    private static func isEmpty(_ s: WorkoutSample) -> Bool {
        s.heartRate == nil && s.paceSecondsPerKm == nil && s.speedKmh == nil && s.cadence == nil && s.latitude == nil
    }

    private static func s32(_ p: [UInt8], _ i: Int) -> Int32 {
        Int32(bitPattern: (UInt32(p[i]) << 24) | (UInt32(p[i + 1]) << 16) | (UInt32(p[i + 2]) << 8) | UInt32(p[i + 3]))
    }
}
