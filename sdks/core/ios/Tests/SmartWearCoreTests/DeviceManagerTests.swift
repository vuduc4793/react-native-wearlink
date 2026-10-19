import CoreBluetooth
import XCTest
@testable import SmartWearCore

/// Central giả: không đụng CoreBluetooth thật.
@MainActor
final class FakeCentral: BleCentralProviding {
    var state: BluetoothState = .poweredOn {
        didSet { onStateChange?(state) }
    }
    var onStateChange: ((BluetoothState) -> Void)?
    var scanHandler: ((ScannedDevice) -> Void)?
    /// Id iOS "còn nhớ" (nil = nhớ hết).
    var knownIds: Set<UUID>?
    /// Thiết bị iOS đang giữ kết nối (app khác trên iPhone).
    var systemConnected: [ScannedDevice] = []

    func activate() {}
    func startScan(_ handler: @escaping (ScannedDevice) -> Void) { scanHandler = handler }
    func stopScan() { scanHandler = nil }
    func retrieveConnected(services: [CBUUID]) -> [ScannedDevice] { systemConnected }
    private(set) var released: [UUID] = []
    var restoredIds: Set<UUID> = []
    func release(_ ids: [UUID]) { released += ids }
    func retrieveKnown(_ ids: [UUID]) -> Set<UUID> { knownIds.map { $0.intersection(ids) } ?? Set(ids) }
}

/// Thiết bị giả: mỗi lần `connect` lấy kết quả kế tiếp trong `script` (hết thì dùng phần tử cuối).
@MainActor
final class FakeDevice: WearableDevice {
    var script: [Bool] = [true]
    var connectDelay: TimeInterval = 0
    /// Pha giả lập trong lúc chờ (vd `.link` = treo chờ nối link như CoreBluetooth).
    var phaseDuringConnect: ConnectPhase?
    /// Lỗi ném ra khi kịch bản là `false` (mặc định: hết giờ bật notify).
    var failure: Error = GattError.timeout("bật notify 6E400003")
    private(set) var attempts = 0

    override func connect() async throws {
        guard state == .disconnected else { return }
        let ok = script.isEmpty ? true : script[min(attempts, script.count - 1)]
        attempts += 1
        state = .connecting
        lastError = nil
        if let p = phaseDuringConnect { setPhase(p) }
        do {
            if connectDelay > 0 { try await Task.sleep(nanoseconds: UInt64(connectDelay * 1_000_000_000)) }
        } catch {
            state = .disconnected
            throw error
        }
        guard ok else {
            state = .disconnected
            // Lỗi tạm đã gặp trên R09 ở -89 dBm.
            lastError = failure.localizedDescription
            throw failure
        }
        markConnected()
    }

    override func disconnect() {
        if state != .disconnected { state = .disconnecting }
        state = .disconnected
    }

    /// Mất kết nối ngoài ý muốn (link rớt).
    func drop() { state = .disconnected }
}

/// Kịch bản theo id, cho driver giả tạo thiết bị (kể cả khi khôi phục từ danh sách đã lưu).
@MainActor
enum FakeLab {
    static var scripts: [UUID: [Bool]] = [:]
    static var created: [UUID: FakeDevice] = [:]
}

struct FakeDriver: DeviceDriver {
    let id = "fake"
    let displayName = "Fake"

    func match(_ scanned: ScannedDevice) -> DriverMatch? {
        guard scanned.name?.hasPrefix("FAKE") == true else { return nil }
        return DriverMatch(driverId: id, model: scanned.name, kind: .ring, mac: "AA:BB")
    }

    @MainActor
    func create(_ scanned: ScannedDevice, match: DriverMatch) -> WearableDevice {
        let d = FakeDevice(id: scanned.id, driverId: id, name: scanned.name ?? "?", kind: match.kind, mac: match.mac)
        d.script = FakeLab.scripts[scanned.id] ?? [true]
        FakeLab.created[scanned.id] = d
        return d
    }
}

/// Driver giả có lịch nối lại riêng (như QRing 2/4/4… s), tên bắt đầu bằng "FAST".
struct FastDriver: DeviceDriver {
    let id = "fast"
    let displayName = "Fast"
    var reconnectBackoff: [TimeInterval]? { [0.01] }

    func match(_ scanned: ScannedDevice) -> DriverMatch? {
        guard scanned.name?.hasPrefix("FAST") == true else { return nil }
        return DriverMatch(driverId: id, model: scanned.name, kind: .ring)
    }

    @MainActor
    func create(_ scanned: ScannedDevice, match: DriverMatch) -> WearableDevice {
        let d = FakeDevice(id: scanned.id, driverId: id, name: scanned.name ?? "?", kind: match.kind, mac: nil)
        d.script = FakeLab.scripts[scanned.id] ?? [true]
        FakeLab.created[scanned.id] = d
        return d
    }
}

@MainActor
final class DeviceManagerTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "smartwear.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        FakeLab.scripts = [:]
        FakeLab.created = [:]
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func makeManager(_ central: FakeCentral) -> DeviceManager {
        let m = DeviceManager(
            registry: DeviceRegistry(drivers: [FakeDriver(), FastDriver()]), central: central,
            store: KnownDeviceStore(defaults: defaults)
        )
        // Rút ngắn thời gian để kiểm thử nhanh, giữ đúng thứ tự.
        m.backoff = [0.01, 0.02, 0.03, 0.04, 0.05]
        m.reconnectDelay = 0.01
        return m
    }

    /// Cho manager "quét thấy" một thiết bị giả.
    private func discover(_ m: DeviceManager, _ central: FakeCentral, name: String = "FAKE R09") -> UUID {
        let id = UUID()
        m.startScan(duration: nil)
        central.scanHandler?(ScannedDevice(id: id, name: name, rssi: -60))
        m.stopScan()
        return id
    }

    private func waitUntil(_ timeout: TimeInterval = 2, _ cond: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond(), Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    func testBackoffSequenceMatchesAndroid() {
        XCTAssertEqual([2, 5, 10, 30, 60], DeviceManager.defaultBackoff)
        XCTAssertEqual([2, 5, 10, 30, 60, 60, 60], (0..<7).map { DeviceManager.backoffDelay(attempt: $0) })
        XCTAssertEqual(0, DeviceManager.backoffDelay(attempt: 3, schedule: []))
    }

    func testKnownDeviceStoreRoundTrip() {
        let store = KnownDeviceStore(defaults: defaults)
        XCTAssertEqual([], store.load())
        let list = [
            KnownDevice(id: UUID(), driverId: "gloryfit", name: "Y25", model: "Y25", kind: .watch, keepConnected: true),
            KnownDevice(id: UUID(), driverId: "qring", name: "R09_AC08", kind: .ring, mac: "30:32:AC:08:00:00"),
        ]
        store.save(list)
        XCTAssertEqual(list, KnownDeviceStore(defaults: defaults).load())
    }

    func testRestoreSavedDevicesReconnectsKeptOnesWithoutScan() async {
        let central = FakeCentral()
        let m1 = makeManager(central)
        let kept = discover(m1, central, name: "FAKE Y25")
        let notKept = discover(m1, central, name: "FAKE HT43")
        await m1.connect([kept])
        await m1.connect([notKept], keep: false)
        XCTAssertTrue(m1.isKept(kept))
        XCTAssertFalse(m1.isKept(notKept))

        // Mở app lần sau: dựng lại từ UserDefaults, Bluetooth bật thì chỉ nối cái đang giữ.
        FakeLab.created = [:]
        let central2 = FakeCentral()
        central2.state = .poweredOff
        let m2 = makeManager(central2)
        var connected: [UUID] = []
        m2.onConnected = { connected.append($0.id) }
        m2.start()
        XCTAssertEqual([kept, notKept], m2.devices.map(\.id))
        XCTAssertEqual("FAKE Y25", m2.knownDevices.first?.name)
        XCTAssertEqual(.ring, m2.device(kept)?.kind)
        XCTAssertEqual("AA:BB", m2.device(kept)?.mac)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual([], connected, "Bluetooth tắt thì chưa thử")
        central2.state = .poweredOn
        await waitUntil { connected == [kept] }
        XCTAssertEqual([kept], connected)
        XCTAssertTrue(m2.device(kept)?.isConnected == true)
        XCTAssertEqual(0, FakeLab.created[notKept]?.attempts)
    }

    func testTransientSetupFailureRetriesWithBackoffUntilConnected() async {
        let central = FakeCentral()
        let m = makeManager(central)
        let id = discover(m, central)
        FakeLab.scripts[id] = [false, false, false, true]
        var fired = 0
        m.onConnected = { _ in fired += 1 }
        let results = await m.connect([id])
        XCTAssertNotNil(results[id] ?? nil, "lần bấm đầu lỗi")
        let d = FakeLab.created[id]!
        await waitUntil { d.isConnected }
        XCTAssertTrue(d.isConnected)
        XCTAssertEqual(4, d.attempts)
        XCTAssertEqual(1, fired)
        XCTAssertNil(d.linkStatus)
    }

    func testOnConnectedFiresOnAutomaticReconnect() async {
        let central = FakeCentral()
        let m = makeManager(central)
        let id = discover(m, central)
        var fired: [UUID] = []
        m.onConnected = { fired.append($0.id) }
        await m.connect([id])
        let d = FakeLab.created[id]!
        XCTAssertEqual([id], fired)

        d.drop()
        await waitUntil { fired.count == 2 }
        XCTAssertEqual([id, id], fired)
        XCTAssertTrue(d.isConnected)

        // Lần rớt sau mà lần nối đầu lỗi vẫn tiếp tục thử và vẫn báo.
        let before = d.attempts
        d.script = Array(repeating: true, count: before) + [false, true]
        d.drop()
        await waitUntil { fired.count == 3 }
        XCTAssertEqual(3, fired.count)
        XCTAssertEqual(before + 2, d.attempts)
    }

    func testUserDisconnectStopsLoopAndClearsKeep() async {
        let central = FakeCentral()
        let m = makeManager(central)
        let id = discover(m, central)
        FakeLab.scripts[id] = [false]
        m.backoff = [0.02]
        await m.connect([id])
        let d = FakeLab.created[id]!
        await waitUntil { d.attempts >= 3 }
        XCTAssertTrue(m.isKept(id))

        m.disconnect(d)
        XCTAssertFalse(m.isKept(id))
        XCTAssertFalse(KnownDeviceStore(defaults: defaults).load().first!.keepConnected, "đã lưu cờ bỏ giữ")
        let attempts = d.attempts
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(attempts, d.attempts, "không thử thêm sau khi người dùng ngắt")
        XCTAssertEqual(.disconnected, d.state)
    }

    func testUserDisconnectCancelsPendingConnect() async {
        let central = FakeCentral()
        let m = makeManager(central)
        let id = discover(m, central)
        FakeLab.scripts[id] = [true]
        await m.connect([id])
        let d = FakeLab.created[id]!
        // Lần tự nối lại "treo" như yêu cầu kết nối chờ của CoreBluetooth khi thiết bị không quảng bá.
        d.connectDelay = 30
        d.drop()
        await waitUntil { d.state == .connecting }
        XCTAssertEqual(.connecting, d.state)
        m.disconnect(d)
        await waitUntil { d.state == .disconnected }
        XCTAssertEqual(.disconnected, d.state)
        XCTAssertFalse(m.isKept(id))
    }

    /// Hồi quy 15/10/2026: lần kết nối `keep: false` (vd tự kiểm thử) từng TẮT và lưu cờ giữ kết nối mà người dùng đã
    /// bật cho Y25, nên mất kết nối thì app không nối lại và lần iOS khôi phục kết nối còn bị nhả. `keep: false` chỉ có
    /// nghĩa "không bật giữ"; tắt giữ là việc của `disconnect` / `setKeepConnected(false)`.
    func testConnectWithoutKeepDoesNotClearUserKeep() async {
        let central = FakeCentral()
        let m = makeManager(central)
        let id = discover(m, central)
        var fired = 0
        m.onConnected = { _ in fired += 1 }
        await m.connect([id])
        XCTAssertTrue(m.isKept(id))
        let d = FakeLab.created[id]!
        d.drop()
        try? await Task.sleep(nanoseconds: 100_000_000)
        await m.connect([id], keep: false)
        XCTAssertTrue(m.isKept(id), "keep: false không được tắt cờ giữ người dùng đã bật")
        XCTAssertTrue(KnownDeviceStore(defaults: defaults).load().first { $0.id == id }?.keepConnected ?? false, "cờ đã lưu vẫn bật")
        // Vẫn tự nối lại khi rớt.
        let before = fired
        d.drop()
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertGreaterThan(fired, before)
        XCTAssertTrue(d.isConnected)
    }

    func testNotKeptDeviceIsNotReconnected() async {
        let central = FakeCentral()
        let m = makeManager(central)
        let id = discover(m, central)
        var fired = 0
        m.onConnected = { _ in fired += 1 }
        await m.connect([id], keep: false)
        let d = FakeLab.created[id]!
        d.drop()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(1, fired)
        XCTAssertEqual(1, d.attempts)
        XCTAssertFalse(d.isConnected)
    }

    func testReconnectWaitsForBleQuiet() async {
        let central = FakeCentral()
        let m = makeManager(central)
        let id = discover(m, central)
        await m.connect([id])
        let d = FakeLab.created[id]!
        let release = OneShot<Void>()
        let holder = Task { @MainActor in
            await BleQuiet.hold { try? await release.wait() }
        }
        await waitUntil { BleQuiet.active }
        d.drop()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(1, d.attempts, "đang truyền file lớn thì chưa thử")
        release.succeed(())
        await holder.value
        await waitUntil { d.isConnected }
        XCTAssertEqual(2, d.attempts)
    }

    func testDiagnosis() {
        let t0 = Date(timeIntervalSince1970: 1000)
        func diag(_ waited: TimeInterval?, seen: TimeInterval? = nil, connected: Bool = false, unknown: Bool = false) -> String? {
            DeviceManager.diagnose(
                connected: connected, waitingSince: waited.map { t0.addingTimeInterval(-$0) },
                lastAdvertised: seen.map { t0.addingTimeInterval(-$0) }, unknownToSystem: unknown, now: t0, after: 20
            )
        }
        XCTAssertNil(diag(nil))
        XCTAssertNil(diag(5))
        XCTAssertNil(diag(60, connected: true))
        XCTAssertEqual(DeviceManager.notAdvertisingStatus, diag(25))
        XCTAssertEqual(DeviceManager.notAdvertisingStatus, diag(25, seen: 40))
        XCTAssertEqual(DeviceManager.advertisingStatus, diag(25, seen: 3))
        XCTAssertEqual(DeviceManager.unknownToSystemStatus, diag(1, unknown: true))
    }

    /// Thiết bị quảng bá thưa (Y25, DS500): đã bị ẩn khỏi danh sách quét vì > 20 s không thấy, vẫn phải nối được
    /// và được lưu. Trước đây `connect` bỏ qua trong im lặng.
    func testSparseAdvertiserStillConnectsAfterPrune() async {
        let central = FakeCentral()
        let m = makeManager(central)
        let id = discover(m, central, name: "FAKE Y25")
        m.pruneDiscovered(now: Date().addingTimeInterval(30))
        XCTAssertNil(m.discovered[id])
        let results = await m.connect([id], keep: true)
        XCTAssertNotNil(results[id])
        XCTAssertNil(results[id] ?? nil)
        XCTAssertTrue(m.device(id)?.isConnected == true)
        XCTAssertTrue(m.knownDevices.contains { $0.id == id && $0.keepConnected })
    }

    /// Id chưa từng quét thấy: báo lỗi, không bỏ qua im lặng.
    func testConnectUnknownIdReportsError() async {
        let central = FakeCentral()
        let m = makeManager(central)
        let id = UUID()
        let results = await m.connect([id], keep: false)
        XCTAssertNotNil(results[id] ?? nil)
    }

    /// Bản ghi đã lưu với driver sai (DS500 từng bị driver Bluetooth chuẩn nhận): thấy lại thì sửa driver.
    func testSavedDeviceWithWrongDriverIsCorrected() async {
        let id = UUID()
        KnownDeviceStore(defaults: defaults).save([
            KnownDevice(id: id, driverId: "standard", name: "FAKE DS500", model: nil, kind: .unknown, mac: nil, keepConnected: false),
        ])
        let central = FakeCentral()
        let m = makeManager(central)
        m.startScan(duration: nil)
        central.scanHandler?(ScannedDevice(id: id, name: "FAKE DS500", rssi: -60))
        m.stopScan()
        XCTAssertEqual(m.knownDevices.first { $0.id == id }?.driverId, "fake")
        XCTAssertEqual(KnownDeviceStore(defaults: defaults).load().first { $0.id == id }?.driverId, "fake")
    }

    /// Quên thiết bị phải bảo iOS nhả kết nối, không chỉ xoá bản ghi (không thì máy khác không nối được).
    func testRemoveReleasesSystemConnection() async {
        let central = FakeCentral()
        let m = makeManager(central)
        let id = discover(m, central)
        _ = await m.connect([id], keep: true)
        m.remove(m.device(id)!)
        XCTAssertTrue(central.released.contains(id))
    }

    func testReleaseAllStopsLoopsAndReleasesKnownDevices() async {
        let central = FakeCentral()
        let m = makeManager(central)
        let id = discover(m, central)
        _ = await m.connect([id], keep: true)
        m.releaseAll()
        XCTAssertTrue(central.released.contains(id))
        XCTAssertFalse(m.device(id)?.isConnected ?? true)
        XCTAssertFalse(m.isKept(id), "nhả để máy khác dùng: lần mở app sau không được giành lại")
        XCTAssertTrue(m.knownDevices.contains { $0.id == id }, "vẫn nhớ thiết bị")
    }

    /// Kết nối iOS khôi phục từ lần chạy trước mà thiết bị không còn giữ: huỷ ngay khi Bluetooth bật.
    func testUnwantedRestoredConnectionsAreReleased() async {
        let kept = UUID(), forgotten = UUID()
        KnownDeviceStore(defaults: defaults).save([
            KnownDevice(id: kept, driverId: "fake", name: "FAKE R09", model: nil, kind: .ring, mac: nil, keepConnected: true),
        ])
        let central = FakeCentral()
        central.restoredIds = [kept, forgotten]
        let m = makeManager(central)
        m.start()
        XCTAssertTrue(central.released.contains(forgotten))
        XCTAssertFalse(central.released.contains(kept))
    }

    /// "Thử lại" khi đang có lệnh nối chờ: không huỷ nó (Y25 chỉ phát một quãng ngắn, huỷ là dễ lỡ).
    func testRetryNowDoesNotCancelPendingConnect() async {
        let central = FakeCentral()
        let m = makeManager(central)
        let id = discover(m, central)
        let d = m.add(id) as! FakeDevice
        d.connectDelay = 0.5
        m.setKeepConnected(true, for: d)
        await waitUntil { d.state == .connecting }
        _ = await m.retryNow(d)
        _ = await m.retryNow(d)
        await waitUntil { d.isConnected }
        XCTAssertTrue(d.isConnected)
        XCTAssertEqual(d.attempts, 1, "bấm thử lại không được tạo lần thử mới khi đang chờ")
    }

    /// "Thử lại" trên thiết bị chưa giữ kết nối: bật giữ để app tự thử mãi, và nối ngay.
    func testRetryNowEnablesKeepAndConnects() async {
        let central = FakeCentral()
        let m = makeManager(central)
        let id = discover(m, central)
        let d = m.add(id) as! FakeDevice
        XCTAssertFalse(m.isKept(id))
        _ = await m.retryNow(d)
        await waitUntil { d.isConnected }
        XCTAssertTrue(m.isKept(id))
        XCTAssertTrue(d.isConnected)
    }

    func testRemoveForgetsDevice() async {
        let central = FakeCentral()
        let m = makeManager(central)
        let id = discover(m, central)
        await m.connect([id])
        let d = FakeLab.created[id]!
        m.remove(d)
        XCTAssertNil(m.device(id))
        XCTAssertEqual([], KnownDeviceStore(defaults: defaults).load())
        d.drop()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(1, d.attempts)
    }

    /// Lần tự nối lại đang bắt tay (HT43: link lên sau 45 ms) mà người dùng bấm kết nối: không được huỷ giữa
    /// chừng (trước đây cắt ngang bắt tay GloryFit, để thiết bị "đã kết nối" mà thiếu bảng tính năng/pin).
    func testInteractiveConnectWaitsForInFlightBackgroundAttempt() async {
        let central = FakeCentral()
        let m = makeManager(central)
        let id = discover(m, central)
        var fired = 0
        m.onConnected = { _ in fired += 1 }
        await m.connect([id])
        let d = FakeLab.created[id]!
        XCTAssertEqual(1, fired)
        d.connectDelay = 0.3
        d.drop()
        await waitUntil { d.state == .connecting }
        XCTAssertEqual(2, d.attempts, "lần tự nối lại đang chạy")

        let results = await m.connect([id])
        XCTAssertNil(results[id] ?? nil)
        XCTAssertTrue(d.isConnected)
        XCTAssertEqual(2, d.attempts, "không huỷ, không thử thêm lần nữa")
        XCTAssertEqual(2, fired, "onConnected chỉ một lần cho lần nối lại")
        XCTAssertNil(d.lastFailure, "không có CancellationError hay lỗi nào")
        XCTAssertTrue(d.timeline.elements.contains { $0.message.contains("chờ xong thay vì huỷ") })
    }

    /// Lần tự nối lại đang dở mà lỗi: lần bấm chờ nó xong rồi huỷ vòng (đang ngủ backoff) và tự thử.
    func testInteractiveConnectProceedsWhenInFlightBackgroundAttemptFails() async {
        let central = FakeCentral()
        let m = makeManager(central)
        let id = discover(m, central)
        FakeLab.scripts[id] = [true, false, true]
        var fired = 0
        m.onConnected = { _ in fired += 1 }
        await m.connect([id])
        let d = FakeLab.created[id]!
        m.backoff = [30]
        d.connectDelay = 0.2
        d.drop()
        await waitUntil { d.state == .connecting }
        let results = await m.connect([id])
        XCTAssertNil(results[id] ?? nil)
        XCTAssertTrue(d.isConnected)
        XCTAssertEqual(3, d.attempts, "lần nền lỗi, lần bấm nối được")
        XCTAssertEqual(2, fired)
    }

    /// Vòng chỉ đang chờ link (chưa trao đổi GATT): huỷ ngay để lần bấm có giới hạn thời gian.
    func testInteractiveConnectCancelsLoopWaitingForLink() async {
        let central = FakeCentral()
        let m = makeManager(central)
        m.settleTimeout = 10
        let id = discover(m, central)
        await m.connect([id])
        let d = FakeLab.created[id]!
        d.connectDelay = 30
        d.phaseDuringConnect = .link
        d.drop()
        await waitUntil { d.state == .connecting }
        d.connectDelay = 0
        d.phaseDuringConnect = nil
        let started = Date()
        let results = await m.connect([id])
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "không chờ settleTimeout")
        XCTAssertNil(results[id] ?? nil)
        XCTAssertTrue(d.isConnected)
        XCTAssertEqual(3, d.attempts)
    }

    /// Driver đặt `reconnectBackoff` thì dùng lịch đó thay cho `backoff` chung; driver khác giữ mặc định.
    func testPerDriverBackoffOverride() async {
        let central = FakeCentral()
        let m = makeManager(central)
        m.backoff = [5]
        let fast = discover(m, central, name: "FAST DS500")
        let slow = discover(m, central, name: "FAKE Y25")
        FakeLab.scripts[fast] = [false, false, false, true]
        FakeLab.scripts[slow] = [false, true]
        await m.connect([fast, slow])
        let f = FakeLab.created[fast]!, s = FakeLab.created[slow]!
        XCTAssertEqual([0.01], m.backoffSchedule(for: f))
        XCTAssertEqual([5], m.backoffSchedule(for: s))
        await waitUntil(1) { f.isConnected }
        XCTAssertTrue(f.isConnected, "lịch ngắn của driver: nối được sau vài lần thử nhanh")
        XCTAssertEqual(4, f.attempts)
        XCTAssertEqual(1, s.attempts, "driver không đặt lịch riêng vẫn chờ theo backoff chung (5 s)")
        XCTAssertFalse(s.isConnected)
        m.disconnect(s)
    }
}
