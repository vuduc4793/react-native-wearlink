import XCTest
@testable import SmartWearCore

/// Thiết bị giả có lịch sử: trả `result` sau các bước tiến độ `steps`; `failure` khác nil thì ném.
@MainActor
final class HistoryFakeDevice: WearableDevice {
    var result = DeviceHistory()
    var steps = ["Bước chân", "Giấc ngủ"]
    var failure: Error?
    var delay: TimeInterval = 0
    private(set) var seenProgress: [SyncProgress] = []
    private(set) var calls = 0

    override var supportsHistory: Bool { true }

    override func syncHistoryImpl(days: Int, progress: @escaping @MainActor (SyncProgress) -> Void) async throws -> DeviceHistory {
        calls += 1
        for (i, s) in steps.enumerated() {
            let p = SyncProgress(step: s, done: i, total: steps.count)
            progress(p)
            seenProgress.append(syncProgress ?? p)
            if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        }
        if let failure { throw failure }
        var r = result
        r.days = days
        return r
    }
}

@MainActor
final class HistoryTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private var dir: URL!

    override func setUp() async throws {
        suite = "smartwear.history.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("swhist-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: dir)
    }

    private func t(_ minutes: Int) -> Date { Date(timeIntervalSince1970: 1_792_000_000 + TimeInterval(minutes * 60)) }

    private func sample() -> DeviceHistory {
        let s = SleepSession(start: t(0), end: t(470), segments: [
            SleepSegment(start: t(0), minutes: 60, stage: .light),
            SleepSegment(start: t(60), minutes: 150, stage: .deep),
            SleepSegment(start: t(210), minutes: 70, stage: .rem),
            SleepSegment(start: t(280), minutes: 10, stage: .awake),
            SleepSegment(start: t(290), minutes: 180, stage: .light),
        ])
        return DeviceHistory(
            series: [
                .steps: [HistoryPoint(timestamp: t(0), value: 500, extra: ["calories": 350, "distance": 370])],
                .heartRate: [HistoryPoint(timestamp: t(5), value: 60), HistoryPoint(timestamp: t(10), value: 62)],
                .bloodPressure: [HistoryPoint(timestamp: t(30), value: 120, extra: ["diastolic": 78])],
            ],
            sleep: [s],
            today: ActivityTotals(steps: 3000, calories: 100_000, distanceMeters: 2000, activeMinutes: 45),
            days: 7, syncedAt: t(600), errors: ["SpO2: hết giờ"]
        )
    }

    // MARK: - Mô hình

    func testSleepSessionTotals() {
        let s = sample().sleep[0]
        XCTAssertEqual(240, s.minutes(.light))
        XCTAssertEqual(150, s.minutes(.deep))
        XCTAssertEqual(70, s.minutes(.rem))
        XCTAssertEqual(10, s.minutes(.awake))
        XCTAssertEqual(460, s.asleepMinutes)
        XCTAssertEqual(t(90), SleepSegment(start: t(60), minutes: 30, stage: .deep).end)
        XCTAssertEqual("LIGHT", SleepStage.light.rawValue)
    }

    func testNormalizedSortsAndDropsDuplicateTimestamps() {
        let pts = [HistoryPoint(timestamp: t(10), value: 2), HistoryPoint(timestamp: t(0), value: 1), HistoryPoint(timestamp: t(10), value: 3)]
        XCTAssertEqual([1, 2], DeviceHistory.normalized(pts).map(\.value))
    }

    func testPointsInRangeAndSummary() {
        let h = sample()
        XCTAssertEqual(1, h.points(.heartRate, from: t(5), to: t(10)).count)
        XCTAssertEqual("HEART_RATE=2 BLOOD_PRESSURE=1 STEPS=1 ngủ=1 lỗi=1", h.summary)
    }

    func testProgressFraction() {
        XCTAssertEqual(0.5, SyncProgress(step: "a", done: 0, total: 2).fraction)
        XCTAssertEqual(1, SyncProgress(step: "a", done: 0, total: 0).fraction)
    }

    func testRunAllKeepsGoingAfterErrors() async {
        var ran: [String] = []
        var progress: [SyncProgress] = []
        let errors = await HistoryStep.runAll([
            HistoryStep("A") { ran.append("A") },
            HistoryStep("B") { throw GattError.timeout("B") },
            HistoryStep("C") { ran.append("C") },
        ]) { progress.append($0) }
        XCTAssertEqual(["A", "C"], ran)
        XCTAssertEqual(1, errors.count)
        XCTAssertTrue(errors[0].hasPrefix("B: "))
        XCTAssertEqual([0, 1, 2], progress.map(\.done))
        XCTAssertEqual(3, progress[0].total)
    }

    // MARK: - WearableDevice

    func testSyncPublishesHistoryAndClearsProgress() async throws {
        let d = HistoryFakeDevice(id: UUID(), driverId: "hist", name: "HIST", kind: .ring)
        d.result = sample()
        XCTAssertNil(d.syncProgress)
        let h = try await d.syncHistory(days: 3)
        XCTAssertEqual(3, h.days)
        XCTAssertEqual(h, d.history)
        XCTAssertEqual(h.syncedAt, d.lastSyncedAt)
        XCTAssertNil(d.syncProgress)
        XCTAssertEqual(["Bước chân", "Giấc ngủ"], d.seenProgress.map(\.step)) // tiến độ đi qua `syncProgress`
        // Lỗi từng bước ghi vào nhật ký gói, đếm lỗi.
        XCTAssertEqual(1, d.stats.errors)
        XCTAssertTrue(d.log.contains { $0.direction == .error && ($0.note ?? "").contains("SpO2") })
    }

    func testSecondSyncWhileSyncingThrows() async throws {
        let d = HistoryFakeDevice(id: UUID(), driverId: "hist", name: "HIST", kind: .ring)
        d.delay = 0.05
        let first = Task { try await d.syncHistory() }
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertNotNil(d.syncProgress)
        do {
            _ = try await d.syncHistory()
            XCTFail("phải ném lỗi khi đang đồng bộ")
        } catch {}
        _ = try await first.value
        XCTAssertEqual(1, d.calls)
    }

    func testFailureLeavesHistoryUntouched() async {
        let d = HistoryFakeDevice(id: UUID(), driverId: "hist", name: "HIST", kind: .ring)
        d.failure = GattError.disconnected
        do {
            _ = try await d.syncHistory()
            XCTFail("phải ném lỗi")
        } catch {}
        XCTAssertNil(d.history)
        XCTAssertNil(d.syncProgress)
    }

    func testBaseDeviceHasNoHistory() async throws {
        let d = WearableDevice(id: UUID(), driverId: "x", name: "X", kind: .unknown)
        XCTAssertFalse(d.supportsHistory)
        let h = try await d.syncHistory()
        XCTAssertEqual(["Thiết bị này không lưu dữ liệu lịch sử"], h.errors)
    }

    // MARK: - HistoryStore + DeviceManager

    func testStoreRoundTrip() {
        let store = HistoryStore(directory: dir, defaults: defaults)
        let id = UUID()
        XCTAssertNil(store.lastSynced(id))
        XCTAssertNil(store.load(id))
        store.save(sample(), for: id)
        XCTAssertEqual(t(600), store.lastSynced(id))
        XCTAssertEqual(sample(), store.load(id))
        store.remove(id)
        XCTAssertNil(store.lastSynced(id))
        XCTAssertNil(store.load(id))
    }

    func testManagerSyncSavesAndRestoresOnNextLaunch() async {
        let store = HistoryStore(directory: dir, defaults: defaults)
        let m = DeviceManager(
            registry: DeviceRegistry(drivers: []), central: FakeCentral(),
            store: KnownDeviceStore(defaults: defaults), historyStore: store
        )
        let id = UUID()
        let d = HistoryFakeDevice(id: id, driverId: "hist", name: "HIST", kind: .ring)
        d.result = sample()
        d.delay = 0.01
        m.adopt(d)
        let task = m.syncHistory(d, days: 2)
        XCTAssertNotNil(task)
        XCTAssertNil(m.syncHistory(d)) // đang đồng bộ: bỏ qua
        let h = await task?.value
        XCTAssertEqual(2, h?.days)
        XCTAssertEqual(1, d.calls)
        XCTAssertEqual(t(600), store.lastSynced(id))

        // Lần mở app sau: thiết bị dựng lại có ngay lịch sử + mốc đồng bộ.
        let m2 = DeviceManager(
            registry: DeviceRegistry(drivers: []), central: FakeCentral(),
            store: KnownDeviceStore(defaults: defaults), historyStore: store
        )
        let again = HistoryFakeDevice(id: id, driverId: "hist", name: "HIST", kind: .ring)
        m2.adopt(again)
        XCTAssertEqual(2, again.history?.days)
        XCTAssertEqual(t(600), again.lastSyncedAt)
        m2.remove(again)
        XCTAssertNil(store.load(id))
    }

    func testManagerSyncFailureSetsLastError() async {
        let m = DeviceManager(
            registry: DeviceRegistry(drivers: []), central: FakeCentral(),
            store: KnownDeviceStore(defaults: defaults), historyStore: HistoryStore(directory: dir, defaults: defaults)
        )
        let d = HistoryFakeDevice(id: UUID(), driverId: "hist", name: "HIST", kind: .ring)
        d.failure = GattError.disconnected
        m.adopt(d)
        let h = await m.syncHistory(d)?.value
        XCTAssertNil(h ?? nil)
        XCTAssertTrue(d.lastError?.hasPrefix("Đồng bộ lỗi") == true)
        XCTAssertFalse(m.isSyncingAny)
    }
}
