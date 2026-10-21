import Foundation

/// Một điểm dữ liệu lịch sử (bản iOS của `HistoryPoint` Android; Android dùng epoch ms, iOS dùng `Date`).
public struct HistoryPoint: Sendable, Equatable, Codable {
    public var timestamp: Date
    public var value: Double
    /// Giá trị phụ, ví dụ SpO2 thấp nhất trong giờ ("min"), calo (cal) / quãng đường (m) của một khung bước
    /// ("calories"/"distance"), tâm trương của huyết áp ("diastolic").
    public var extra: [String: Double]

    public init(timestamp: Date, value: Double, extra: [String: Double] = [:]) {
        self.timestamp = timestamp
        self.value = value
        self.extra = extra
    }
}

/// Giai đoạn ngủ, `rawValue` trùng tên enum Android.
public enum SleepStage: String, Sendable, Codable, CaseIterable {
    case light = "LIGHT"
    case deep = "DEEP"
    case rem = "REM"
    case awake = "AWAKE"
    case unknown = "UNKNOWN"
}

public struct SleepSegment: Sendable, Equatable, Codable {
    public var start: Date
    public var minutes: Int
    public var stage: SleepStage

    public init(start: Date, minutes: Int, stage: SleepStage) {
        self.start = start
        self.minutes = minutes
        self.stage = stage
    }

    public var end: Date { start.addingTimeInterval(TimeInterval(minutes * 60)) }
}

/// Một phiên ngủ.
public struct SleepSession: Sendable, Equatable, Codable {
    public var start: Date
    public var end: Date
    public var segments: [SleepSegment]
    /// Ngủ trưa / giấc ngắn ban ngày (QRing: khung big-data 0x3E).
    public var nap: Bool

    public init(start: Date, end: Date, segments: [SleepSegment], nap: Bool = false) {
        self.start = start
        self.end = end
        self.segments = segments
        self.nap = nap
    }

    public func minutes(_ stage: SleepStage) -> Int {
        segments.filter { $0.stage == stage }.reduce(0) { $0 + $1.minutes }
    }

    /// Tổng thời gian ngủ, không tính lúc thức.
    public var asleepMinutes: Int {
        segments.filter { $0.stage != .awake && $0.stage != .unknown }.reduce(0) { $0 + $1.minutes }
    }
}

/// Tổng hoạt động trong ngày theo thiết bị báo. `calories` tính bằng cal (như Android, UI chia 1000 ra kcal).
/// Một bài tập ghi trên thiết bị (chạy, đạp xe, yoga…). `activeSeconds` là thời gian tập hiệu quả (trừ tạm dừng).
/// Trường nào thiết bị không đo thì nil. Bản Swift của `Workout` Android.
public struct Workout: Sendable, Equatable, Codable, Identifiable {
    public var type: Int
    public var name: String
    public var start: Date
    public var end: Date
    public var activeSeconds: Int
    public var steps: Int?
    public var calories: Int?
    public var distanceMeters: Int?
    public var avgHeartRate: Int?
    public var maxHeartRate: Int?
    public var minHeartRate: Int?
    /// Pace trung bình, giây cho mỗi km.
    public var paceSecondsPerKm: Int?
    /// Chuỗi mẫu theo thời gian (nhịp tim, pace/tốc độ, nhịp bước, toạ độ GPS nếu đồng hồ có GPS). Rỗng = thiết bị không gửi.
    public var samples: [WorkoutSample]
    /// Khoảng cách giữa hai mẫu (giây) do thiết bị báo.
    public var sampleIntervalSeconds: Int?
    /// Thời gian ở 5 vùng nhịp tim (giây): khởi động, đốt mỡ, sức bền ưa khí, sức bền kỵ khí, tối đa.
    public var heartRateZoneSeconds: [Int]?
    /// Sải bước trung bình / lớn nhất / nhỏ nhất (cm, theo app hãng; chưa đối chiếu thực địa).
    public var avgStrideCm: Int?
    public var maxStrideCm: Int?
    public var minStrideCm: Int?

    public var id: Date { start }

    /// Đường đi GPS: các mẫu có toạ độ, theo thời gian. Rỗng = thiết bị không có GPS hoặc bài không ghi GPS.
    public var track: [WorkoutSample] { samples.filter { $0.latitude != nil && $0.longitude != nil } }

    public init(
        type: Int, name: String, start: Date, end: Date, activeSeconds: Int, steps: Int? = nil, calories: Int? = nil,
        distanceMeters: Int? = nil, avgHeartRate: Int? = nil, maxHeartRate: Int? = nil, minHeartRate: Int? = nil,
        paceSecondsPerKm: Int? = nil, samples: [WorkoutSample] = [], sampleIntervalSeconds: Int? = nil,
        heartRateZoneSeconds: [Int]? = nil, avgStrideCm: Int? = nil, maxStrideCm: Int? = nil, minStrideCm: Int? = nil
    ) {
        self.type = type; self.name = name; self.start = start; self.end = end; self.activeSeconds = activeSeconds
        self.steps = steps; self.calories = calories; self.distanceMeters = distanceMeters
        self.avgHeartRate = avgHeartRate; self.maxHeartRate = maxHeartRate; self.minHeartRate = minHeartRate
        self.paceSecondsPerKm = paceSecondsPerKm
        self.samples = samples; self.sampleIntervalSeconds = sampleIntervalSeconds
        self.heartRateZoneSeconds = heartRateZoneSeconds
        self.avgStrideCm = avgStrideCm; self.maxStrideCm = maxStrideCm; self.minStrideCm = minStrideCm
    }

    private enum CodingKeys: String, CodingKey {
        case type, name, start, end, activeSeconds, steps, calories, distanceMeters, avgHeartRate, maxHeartRate, minHeartRate
        case paceSecondsPerKm, samples, sampleIntervalSeconds, heartRateZoneSeconds, avgStrideCm, maxStrideCm, minStrideCm
    }

    /// Đọc được cả bản lưu cũ chưa có `samples`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            type: try c.decode(Int.self, forKey: .type), name: try c.decode(String.self, forKey: .name),
            start: try c.decode(Date.self, forKey: .start), end: try c.decode(Date.self, forKey: .end),
            activeSeconds: try c.decode(Int.self, forKey: .activeSeconds),
            steps: try c.decodeIfPresent(Int.self, forKey: .steps), calories: try c.decodeIfPresent(Int.self, forKey: .calories),
            distanceMeters: try c.decodeIfPresent(Int.self, forKey: .distanceMeters),
            avgHeartRate: try c.decodeIfPresent(Int.self, forKey: .avgHeartRate),
            maxHeartRate: try c.decodeIfPresent(Int.self, forKey: .maxHeartRate),
            minHeartRate: try c.decodeIfPresent(Int.self, forKey: .minHeartRate),
            paceSecondsPerKm: try c.decodeIfPresent(Int.self, forKey: .paceSecondsPerKm),
            samples: try c.decodeIfPresent([WorkoutSample].self, forKey: .samples) ?? [],
            sampleIntervalSeconds: try c.decodeIfPresent(Int.self, forKey: .sampleIntervalSeconds),
            heartRateZoneSeconds: try c.decodeIfPresent([Int].self, forKey: .heartRateZoneSeconds),
            avgStrideCm: try c.decodeIfPresent(Int.self, forKey: .avgStrideCm),
            maxStrideCm: try c.decodeIfPresent(Int.self, forKey: .maxStrideCm),
            minStrideCm: try c.decodeIfPresent(Int.self, forKey: .minStrideCm)
        )
    }
}

/// Một mẫu trong bài tập. Trường nào thiết bị không gửi thì nil. `paceSecondsPerKm` cho môn đi/chạy, `speedKmh` cho đạp xe.
public struct WorkoutSample: Sendable, Equatable, Codable {
    public var time: Date
    public var heartRate: Int?
    public var paceSecondsPerKm: Int?
    public var speedKmh: Double?
    /// Nhịp bước (bước/phút) hoặc nhịp đạp.
    public var cadence: Int?
    public var latitude: Double?
    public var longitude: Double?

    public init(
        time: Date, heartRate: Int? = nil, paceSecondsPerKm: Int? = nil, speedKmh: Double? = nil, cadence: Int? = nil,
        latitude: Double? = nil, longitude: Double? = nil
    ) {
        self.time = time; self.heartRate = heartRate; self.paceSecondsPerKm = paceSecondsPerKm; self.speedKmh = speedKmh
        self.cadence = cadence; self.latitude = latitude; self.longitude = longitude
    }
}

public struct ActivityTotals: Sendable, Equatable, Codable {
    public var steps: Int
    public var calories: Int
    public var distanceMeters: Int
    public var activeMinutes: Int?

    public init(steps: Int, calories: Int, distanceMeters: Int, activeMinutes: Int? = nil) {
        self.steps = steps
        self.calories = calories
        self.distanceMeters = distanceMeters
        self.activeMinutes = activeMinutes
    }
}

/// Dữ liệu lịch sử của một thiết bị sau khi đồng bộ.
/// `series` gồm các chuỗi theo thời gian: STEPS (mỗi khung, extra "calories"/"distance"),
/// HEART_RATE, HRV, STRESS, SPO2 (extra "min"), TEMPERATURE, BLOOD_PRESSURE (value = tâm thu, extra "diastolic").
public struct DeviceHistory: Sendable, Equatable, Codable {
    public var series: [Capability: [HistoryPoint]]
    public var sleep: [SleepSession]
    /// Bài tập ghi trên thiết bị, mới nhất trước. Lưu tuỳ chọn để lịch sử đã lưu từ bản cũ vẫn đọc được.
    public var workouts: [Workout] {
        get { storedWorkouts ?? [] }
        set { storedWorkouts = newValue }
    }
    private var storedWorkouts: [Workout]?
    public var today: ActivityTotals?
    public var days: Int
    public var syncedAt: Date
    /// Các bước đồng bộ lỗi (không làm hỏng các bước khác).
    public var errors: [String]

    public init(
        series: [Capability: [HistoryPoint]] = [:], sleep: [SleepSession] = [], workouts: [Workout] = [],
        today: ActivityTotals? = nil, days: Int = 0, syncedAt: Date = Date(), errors: [String] = []
    ) {
        self.series = series
        self.sleep = sleep
        self.storedWorkouts = workouts
        self.today = today
        self.days = days
        self.syncedAt = syncedAt
        self.errors = errors
    }

    /// Chuỗi đã sắp theo thời gian, bỏ điểm trùng mốc (giữ điểm đầu), như `distinctBy { timestamp }` Android.
    public static func normalized(_ points: [HistoryPoint]) -> [HistoryPoint] {
        var seen = Set<Date>()
        return points.filter { seen.insert($0.timestamp).inserted }.sorted { $0.timestamp < $1.timestamp }
    }

    /// Các điểm của `capability` trong [from, to).
    public func points(_ capability: Capability, from: Date, to: Date) -> [HistoryPoint] {
        (series[capability] ?? []).filter { $0.timestamp >= from && $0.timestamp < to }
    }

    /// Tóm tắt một dòng (AutoTest, log): "STEPS=96 HEART_RATE=288 ngủ=2 lỗi=0".
    public var summary: String {
        let parts = Capability.allCases.compactMap { c in series[c].map { "\(c.rawValue)=\($0.count)" } }
        return (parts + ["ngủ=\(sleep.count)", "lỗi=\(errors.count)"]).joined(separator: " ")
    }
}

/// Tiến độ đồng bộ: đang làm bước `step` (thứ `done`, đếm từ 0) trên tổng `total` bước.
public struct SyncProgress: Sendable, Equatable {
    public var step: String
    public var done: Int
    public var total: Int

    public init(step: String, done: Int, total: Int) {
        self.step = step
        self.done = done
        self.total = total
    }

    /// 0…1, tính cả bước đang chạy (như thanh tiến độ Android `(done + 1) / total`).
    public var fraction: Double { Double(done + 1) / Double(max(total, 1)) }
}

/// Một bước đồng bộ độc lập: lỗi được ghi vào `DeviceHistory.errors`, các bước khác vẫn chạy (như `Step` Android).
public struct HistoryStep {
    public let label: String
    public let run: @MainActor () async throws -> Void

    public init(_ label: String, _ run: @escaping @MainActor () async throws -> Void) {
        self.label = label
        self.run = run
    }

    /// Chạy lần lượt, báo tiến độ trước mỗi bước, trả về lỗi dạng "nhãn: thông điệp".
    @MainActor
    public static func runAll(_ steps: [HistoryStep], progress: (SyncProgress) -> Void) async -> [String] {
        var errors: [String] = []
        for (i, step) in steps.enumerated() {
            progress(SyncProgress(step: step.label, done: i, total: steps.count))
            do {
                try await step.run()
            } catch is CancellationError {
                errors.append("\(step.label): đã huỷ")
                break
            } catch {
                errors.append("\(step.label): \(error.localizedDescription)")
            }
        }
        return errors
    }
}

/// Lưu lịch sử đồng bộ gần nhất của từng thiết bị (JSON trong thư mục `directory`) và mốc đồng bộ cuối
/// (UserDefaults), để mở lại app vẫn thấy dữ liệu và "đồng bộ lúc …". Kiểm thử thì tiêm thư mục + suite riêng.
public struct HistoryStore: @unchecked Sendable {
    public let directory: URL
    public let defaults: UserDefaults
    public let key: String

    public init(directory: URL? = nil, defaults: UserDefaults = .standard, key: String = "smartwear.history.lastSynced") {
        self.directory = directory ?? HistoryStore.defaultDirectory
        self.defaults = defaults
        self.key = key
    }

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("SmartWear/history", isDirectory: true)
    }

    private func file(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }

    /// Mốc đồng bộ thành công gần nhất (nil = chưa đồng bộ lần nào).
    public func lastSynced(_ id: UUID) -> Date? {
        (defaults.dictionary(forKey: key)?[id.uuidString] as? Double).map { Date(timeIntervalSince1970: $0) }
    }

    public func load(_ id: UUID) -> DeviceHistory? {
        guard let data = try? Data(contentsOf: file(id)) else { return nil }
        return try? JSONDecoder().decode(DeviceHistory.self, from: data)
    }

    public func save(_ history: DeviceHistory, for id: UUID) {
        var all = defaults.dictionary(forKey: key) ?? [:]
        all[id.uuidString] = history.syncedAt.timeIntervalSince1970
        defaults.set(all, forKey: key)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(history).write(to: file(id), options: .atomic)
        } catch {
            SmartWearLog.w("Lưu lịch sử \(id.uuidString) lỗi: \(error.localizedDescription)")
        }
    }

    public func remove(_ id: UUID) {
        var all = defaults.dictionary(forKey: key) ?? [:]
        all[id.uuidString] = nil
        defaults.set(all, forKey: key)
        try? FileManager.default.removeItem(at: file(id))
    }
}
