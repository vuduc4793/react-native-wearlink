import CoreBluetooth
import XCTest
@testable import SmartWearCore

/// Bộ đệm vòng, mã lỗi CoreBluetooth → giải thích, heuristic "chờ ghép đôi", dòng thời gian trong DeviceManager.
@MainActor
final class DiagnosticsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 10_000)
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "smartwear.diag.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        FakeLab.scripts = [:]
        FakeLab.created = [:]
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    // MARK: - Bộ đệm vòng

    func testRingBufferKeepsNewestInOrder() {
        var r = RingBuffer<Int>(capacity: 3)
        XCTAssertTrue(r.isEmpty)
        XCTAssertNil(r.last)
        r.append(1)
        r.append(2)
        XCTAssertEqual([1, 2], r.elements)
        XCTAssertEqual(2, r.last)
        for i in 3...5 { r.append(i) }
        XCTAssertEqual([3, 4, 5], r.elements)
        XCTAssertEqual(3, r.count)
        XCTAssertEqual(5, r.last)
        r.append(6)
        XCTAssertEqual([4, 5, 6], r.elements)
        XCTAssertEqual(6, r.last)
        r.removeAll()
        XCTAssertEqual([], r.elements)
        r.append(7)
        XCTAssertEqual([7], r.elements)

        var one = RingBuffer<String>(capacity: 0)
        XCTAssertEqual(1, one.capacity, "dung lượng tối thiểu 1")
        one.append("a")
        one.append("b")
        XCTAssertEqual(["b"], one.elements)
    }

    func testDeviceTimelineIsCappedAndMirroredToGlobalLog() {
        let m = makeManager(FakeCentral())
        let d = FakeDevice(id: UUID(), driverId: "fake", name: "FAKE R09", kind: .ring)
        m.adopt(d)
        for i in 0..<250 { d.logEvent(.handshake, "#\(i)") }
        XCTAssertEqual(WearableDevice.timelineLimit, d.timeline.count)
        XCTAssertEqual("#50", d.timeline.elements.first?.message)
        XCTAssertEqual("#249", d.timeline.elements.last?.message)
        XCTAssertEqual(250, m.events.count)
        for i in 250..<700 { d.logEvent(.handshake, "#\(i)") }
        XCTAssertEqual(DeviceManager.globalLogLimit, m.events.count)
        XCTAssertEqual(d.id, m.events.last?.deviceId)
    }

    // MARK: - Mã lỗi

    func testBleErrorCodeFromCoreBluetoothErrors() {
        // Hằng số khớp CBError.Code / CBATTError.Code của SDK Apple.
        XCTAssertEqual(CBError.Code.peerRemovedPairingInformation.rawValue, BleErrorCode.cbPeerRemovedPairingInformation)
        XCTAssertEqual(CBError.Code.encryptionTimedOut.rawValue, BleErrorCode.cbEncryptionTimedOut)
        XCTAssertEqual(CBError.Code.connectionTimeout.rawValue, BleErrorCode.cbConnectionTimeout)
        XCTAssertEqual(CBError.Code.peripheralDisconnected.rawValue, BleErrorCode.cbPeripheralDisconnected)
        XCTAssertEqual(CBError.Code.connectionLimitReached.rawValue, BleErrorCode.cbConnectionLimitReached)
        XCTAssertEqual(CBATTError.Code.insufficientAuthentication.rawValue, BleErrorCode.attInsufficientAuthentication)
        XCTAssertEqual(CBATTError.Code.insufficientEncryption.rawValue, BleErrorCode.attInsufficientEncryption)

        let cb14 = BleErrorCode(cbError(.peerRemovedPairingInformation))
        XCTAssertEqual(.core, cb14?.domain)
        XCTAssertEqual(14, cb14?.code)
        XCTAssertEqual("CBError 14", cb14?.label)
        XCTAssertTrue(cb14?.isEncryptionRelated == true)
        let att = BleErrorCode(attError(.insufficientEncryption))
        XCTAssertEqual("CBATTError 0x0F", att?.label)
        XCTAssertTrue(att?.isEncryptionRelated == true)
        XCTAssertFalse(BleErrorCode(cbError(.peripheralDisconnected))!.isEncryptionRelated)
        XCTAssertFalse(BleErrorCode(cbError(.connectionTimeout))!.isEncryptionRelated, "tuỳ pha, xét riêng")
        XCTAssertNil(BleErrorCode(NSError(domain: NSPOSIXErrorDomain, code: 1)))
        XCTAssertNil(BleErrorCode(nil))
        XCTAssertNil(BleErrorCode(GattError.timeout("x")))
    }

    func testGattErrorWrapKeepsCodeAndMessage() {
        let ns = NSError(domain: CBErrorDomain, code: 14, userInfo: [NSLocalizedDescriptionKey: "Peer removed pairing information"])
        let wrapped = GattError.wrap("Kết nối", ns)
        XCTAssertEqual(14, BleErrorCode(wrapped)?.code)
        XCTAssertEqual("Kết nối thất bại: Peer removed pairing information", wrapped.localizedDescription)
        XCTAssertEqual(GattError.disconnected, GattError.wrap("Kết nối", GattError.disconnected))
        XCTAssertEqual(
            GattError.operationFailed("Kết nối", "boom"),
            GattError.wrap("Kết nối", NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"]))
        )
    }

    // MARK: - Lỗi → giải thích

    func testPairingErrorsExplainForgetDevice() {
        for (error, phase) in [
            (cbError(.peerRemovedPairingInformation) as Error, ConnectPhase.link),
            (cbError(.encryptionTimedOut), .discovery),
            (cbError(.connectionTimeout), .discovery),
            (GattError.wrap("Bật notify 33F1", attError(.insufficientAuthentication)), .setup),
            (GattError.wrap("Đọc 2A19", attError(.insufficientEncryption)), .setup),
        ] {
            let d = explain(error, phase: phase)
            XCTAssertEqual(.pairing, d.category, "\(error)")
            XCTAssertTrue(d.detail.contains("Đồng hồ yêu cầu ghép đôi nhưng bị huỷ hoặc mất khoá ghép đôi"))
            XCTAssertEqual("iPhone: Cài đặt → Bluetooth → Quên Y25, rồi bấm Thử lại", d.action)
        }
    }

    func testLinkLossExplanations() {
        let lostTimeout = explain(cbError(.connectionTimeout), phase: .ready, lost: true)
        XCTAssertEqual(.linkLost, lostTimeout.category, "đang dùng mà hết giờ = mất sóng, không phải ghép đôi")
        XCTAssertEqual(.peerDisconnected, explain(cbError(.peripheralDisconnected), phase: .ready, lost: true).category)
        XCTAssertEqual(.linkLost, explain(nil, phase: .ready, lost: true).category)
    }

    func testLinkTimeoutDependsOnAdverts() {
        let timeout = GattError.timeout("kết nối (40 s), thiết bị không quảng bá hoặc đang nối với máy khác")
        let silent = explain(timeout, phase: .link)
        XCTAssertEqual(.notAdvertising, silent.category)
        XCTAssertEqual("Thiết bị không quảng bá: có thể đang nối với máy khác hoặc đang ngủ", silent.detail)
        XCTAssertTrue(silent.action.contains("Mở màn hình thiết bị / tắt Bluetooth máy khác"))

        // Thấy quảng bá ngay trước khi bấm kết nối mà link vẫn treo → popup ghép đôi bị bỏ qua.
        let advertising = explain(timeout, phase: .link, lastAdvert: t0.addingTimeInterval(-5))
        XCTAssertEqual(.advertisingNoLink, advertising.category)
        XCTAssertEqual("Có quảng bá nhưng không nối được — thường do popup ghép đôi bị bỏ qua", advertising.detail)
        // Quảng bá trong lúc chờ cũng tính.
        XCTAssertEqual(.advertisingNoLink, explain(timeout, phase: .link, lastAdvert: t0.addingTimeInterval(20)).category)
        // Quảng bá cũ (5 phút trước) không tính.
        XCTAssertEqual(.notAdvertising, explain(timeout, phase: .link, lastAdvert: t0.addingTimeInterval(-300)).category)
        // Không quảng bá nhưng iOS đang giữ (app hãng trên chính iPhone này).
        XCTAssertEqual(.heldBySystem, explain(timeout, phase: .link, held: true).category)
    }

    func testOtherExplanations() {
        XCTAssertEqual(.notifyTimeout, explain(GattError.timeout("bật notify 6E400003"), phase: .setup).category)
        XCTAssertEqual(.unknownToSystem, explain(GattError.peripheralNotFound, phase: .idle).category)
        XCTAssertEqual(.bluetoothOff, explain(GattError.bluetoothUnavailable("poweredOff"), phase: .idle).category)
        XCTAssertEqual(.bluetoothOff, explain(GattError.timeout("x"), phase: .link, bluetooth: .poweredOff).category)
        XCTAssertEqual(.wrongDriver, explain(GattError.serviceNotFound("55FF"), phase: .setup).category)
        XCTAssertEqual(.pairingPending, explain(GattError.timeout("khám phá service (20 s)"), phase: .discovery).category)
        XCTAssertEqual(.limitReached, explain(cbError(.connectionLimitReached), phase: .link).category)
        XCTAssertEqual(.handshake, explain(GattError.operationFailed("A3", "sai phản hồi"), phase: .setup).category)
        XCTAssertEqual(.generic, explain(GattError.operationFailed("X", nil), phase: .idle).category)
        let line = explain(cbError(.peerRemovedPairingInformation), phase: .link).line
        XCTAssertTrue(line.hasPrefix("Cần ghép đôi lại — ") && line.contains(" → iPhone: Cài đặt"))
    }

    // MARK: - Heuristic chờ ghép đôi

    func testPairingPendingHeuristic() {
        func pending(
            _ phase: ConnectPhase, stuck: TimeInterval?, advert: TimeInterval?, codes: [BleErrorCode] = []
        ) -> Bool {
            // `advert`: giây so với lúc bắt đầu chờ (âm = trước đó).
            let since = stuck.map { t0.addingTimeInterval(-$0) }
            return ConnectionDiagnostics.pairingLikelyPending(
                phase: phase, phaseSince: since, lastAdvert: advert.map { (since ?? t0).addingTimeInterval($0) },
                recentCodes: codes, now: t0, stuckAfter: 10
            )
        }
        let encryption = BleErrorCode(domain: .att, code: BleErrorCode.attInsufficientEncryption)
        XCTAssertTrue(pending(.link, stuck: 12, advert: -2), "treo 12 s, thấy quảng bá lúc bắt đầu")
        XCTAssertTrue(pending(.link, stuck: 30, advert: 3), "quảng bá trong lúc chờ")
        XCTAssertTrue(pending(.discovery, stuck: 15, advert: -1))
        XCTAssertFalse(pending(.link, stuck: 5, advert: -2), "chưa đủ lâu")
        XCTAssertFalse(pending(.link, stuck: 60, advert: nil), "không quảng bá = không phải ghép đôi")
        XCTAssertFalse(pending(.link, stuck: 60, advert: -120), "quảng bá quá cũ")
        XCTAssertTrue(pending(.setup, stuck: 1, advert: nil, codes: [encryption]), "lỗi mã hoá khi bắt tay")
        XCTAssertFalse(pending(.setup, stuck: 60, advert: -1), "pha bắt tay có timeout riêng")
        XCTAssertFalse(pending(.idle, stuck: 60, advert: -1, codes: [encryption]))
        XCTAssertFalse(pending(.ready, stuck: 60, advert: -1, codes: [encryption]))
        XCTAssertFalse(pending(.link, stuck: 1, advert: nil, codes: [BleErrorCode(domain: .core, code: 7)]))
    }

    func testLiveDiagnosis() {
        func live(_ stuck: TimeInterval, advert: TimeInterval?) -> Diagnosis? {
            let since = t0.addingTimeInterval(-stuck)
            return ConnectionDiagnostics.live(
                phase: .link, phaseSince: since, lastAdvert: advert.map { since.addingTimeInterval($0) }, recentCodes: [],
                now: t0, deviceName: "Y25", stuckAfter: 10
            )
        }
        XCTAssertNil(live(3, advert: -1))
        XCTAssertEqual(.pairingPending, live(12, advert: -1)?.category)
        XCTAssertTrue(live(12, advert: -1)?.action.contains("Quên Y25") == true)
        XCTAssertEqual(.notAdvertising, live(12, advert: nil)?.category)
    }

    // MARK: - DeviceManager

    func testTimelineRecordsAttemptFailureReconnectAndReady() async {
        let central = FakeCentral()
        let m = makeManager(central)
        let id = discover(m, central)
        FakeLab.scripts[id] = [false, true]
        await m.connect([id])
        let d = FakeLab.created[id]!
        await waitUntil { d.isConnected }
        let tl = d.timeline.elements
        let kinds = tl.map(\.kind)
        XCTAssertEqual(.sighting, kinds.first)
        XCTAssertTrue(tl.contains { $0.kind == .attempt && $0.message.hasPrefix("Người dùng bấm kết nối") })
        XCTAssertTrue(tl.contains { $0.kind == .failure && $0.level == .error && $0.message.contains("bật notify") })
        XCTAssertTrue(tl.contains { $0.kind == .diagnosis && $0.message.hasPrefix("Không bật được notify") })
        XCTAssertTrue(tl.contains { $0.kind == .reconnect && $0.message.hasPrefix("Hẹn tự nối lại sau") })
        XCTAssertTrue(tl.contains { $0.kind == .attempt && $0.message.hasPrefix("Tự nối lại lần 2") })
        XCTAssertEqual(.ready, kinds.last)
        XCTAssertNil(d.diagnosis, "đã nối lại được thì không còn vấn đề")
        XCTAssertNotNil(d.lastFailure, "vẫn giữ lỗi cũ để xem lại")
        // Nhật ký chung có đủ sự kiện của thiết bị.
        XCTAssertTrue(Set(tl.map(\.id)).isSubset(of: Set(m.events.elements.map(\.id))))

        // Lỗi cũ hơn lần sẵn sàng không còn là chẩn đoán sau khi người dùng ngắt.
        m.disconnect(d)
        XCTAssertNil(m.diagnosis(for: d))
        XCTAssertTrue(d.timeline.elements.contains { $0.kind == .user && $0.message.contains("ngắt") })
    }

    func testConnectFailureExplainedAndReported() async {
        let central = FakeCentral()
        let m = makeManager(central)
        let id = discover(m, central, name: "FAKE Y25")
        let d = m.add(id) as! FakeDevice
        d.script = [false]
        d.phaseDuringConnect = .link
        d.failure = GattError.wrap("Kết nối", cbError(.peerRemovedPairingInformation))
        var reported: [(ConnectionFailure, Diagnosis)] = []
        m.onConnectFailed = { _, f, diag in reported.append((f, diag)) }
        let error = await m.connect([id], keep: false)[id] ?? nil
        XCTAssertNotNil(error)
        XCTAssertEqual(1, reported.count)
        XCTAssertTrue(reported.first?.0.interactive == true)
        XCTAssertEqual(.link, reported.first?.0.phase)
        XCTAssertEqual(.pairing, reported.first?.1.category)
        XCTAssertEqual(.pairing, d.diagnosis?.category)
        XCTAssertEqual(14, d.lastFailure?.code?.code)
        XCTAssertEqual(.idle, d.phase)
        XCTAssertEqual(.pairing, m.diagnosis(for: d)?.category)
        XCTAssertTrue(d.timeline.elements.contains { $0.kind == .failure && $0.code?.code == 14 })

        let report = m.diagnosticsReport(for: d, header: ["App: SmartWear Lab 0.1.0 (1)"])
        XCTAssertTrue(report.contains("App: SmartWear Lab 0.1.0 (1)"))
        XCTAssertTrue(report.contains("Thiết bị: FAKE Y25 · driver fake"))
        XCTAssertTrue(report.contains("Giải thích: Cần ghép đôi lại"))
        XCTAssertTrue(report.contains("[CBError 14: thiết bị đã xoá khoá ghép đôi]"))
        XCTAssertTrue(report.contains("--- Dòng thời gian"))
        XCTAssertTrue(report.contains("Giữ kết nối: không"))
    }

    /// Y25: iOS hỏi ghép đôi, người dùng huỷ → kết nối treo ở pha link trong khi đồng hồ vẫn quảng bá.
    func testPairingPendingDetectedWhileStuckInLinkPhase() async {
        let central = FakeCentral()
        let m = makeManager(central)
        m.pairingStuckAfter = 0.05
        let id = discover(m, central, name: "FAKE Y25")
        let d = m.add(id) as! FakeDevice
        d.phaseDuringConnect = .link
        d.connectDelay = 30
        let task = Task { await m.connect([id], keep: false) }
        await waitUntil { d.state == .connecting }
        m.refreshDiagnostics()
        XCTAssertNil(d.diagnosis, "chưa đủ lâu")
        try? await Task.sleep(nanoseconds: 100_000_000)
        m.refreshDiagnostics()
        XCTAssertEqual(.pairingPending, d.diagnosis?.category)
        XCTAssertTrue(d.timeline.elements.contains { $0.kind == .diagnosis && $0.message.hasPrefix("Có thể đang chờ ghép đôi") })
        let logged = d.timeline.elements.filter { $0.kind == .diagnosis }.count
        m.refreshDiagnostics()
        XCTAssertEqual(logged, d.timeline.elements.filter { $0.kind == .diagnosis }.count, "không ghi lặp mỗi giây")
        task.cancel()
        _ = await task.value
        XCTAssertEqual(.disconnected, d.state)
    }

    func testSightingsThrottledAndHeldBySystem() {
        let central = FakeCentral()
        let m = makeManager(central)
        let id = discover(m, central, name: "FAKE Y25")
        let d = m.add(id)!
        m.startScan(duration: nil)
        for i in 0..<50 { central.scanHandler?(ScannedDevice(id: id, name: "FAKE Y25", rssi: -60 - i % 5)) }
        m.stopScan()
        XCTAssertEqual(1, d.timeline.elements.filter { $0.kind == .sighting }.count)
        XCTAssertNotNil(d.lastAdvert)
        XCTAssertFalse(d.lastAdvert!.systemConnected)

        XCTAssertFalse(m.isHeldBySystem(id))
        central.systemConnected = [ScannedDevice(id: id, name: "FAKE Y25", rssi: 0, systemConnected: true)]
        XCTAssertTrue(m.isHeldBySystem(id))
        XCTAssertTrue(m.context(d, now: Date()).heldBySystem)
    }

    func testUserActionsAndDriverCorrectionLogged() async {
        let id = UUID()
        KnownDeviceStore(defaults: defaults).save([KnownDevice(id: id, driverId: "standard", name: "FAKE DS500")])
        let central = FakeCentral()
        let m = makeManager(central)
        m.startScan(duration: nil)
        central.scanHandler?(ScannedDevice(id: id, name: "FAKE DS500", rssi: -60))
        m.stopScan()
        XCTAssertTrue(m.events.elements.contains { $0.kind == .driver && $0.deviceId == id && $0.message.contains("standard") })

        let d = m.add(id)!
        m.setKeepConnected(true, for: d)
        await waitUntil { d.isConnected }
        m.setKeepConnected(false, for: d)
        m.remove(d)
        let users = d.timeline.elements.filter { $0.kind == .user }.map(\.message)
        XCTAssertEqual(["Bật giữ kết nối", "Tắt giữ kết nối", "Quên thiết bị (bỏ khỏi danh sách đã lưu)"], users)
        XCTAssertEqual(3, m.events.elements.filter { $0.kind == .user }.count)
    }

    // MARK: - Tiện ích

    private func makeManager(_ central: FakeCentral) -> DeviceManager {
        let m = DeviceManager(
            registry: DeviceRegistry(drivers: [FakeDriver()]), central: central, store: KnownDeviceStore(defaults: defaults)
        )
        m.backoff = [0.01]
        m.reconnectDelay = 0.01
        return m
    }

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

    private func cbError(_ code: CBError.Code) -> NSError {
        NSError(domain: CBErrorDomain, code: code.rawValue, userInfo: [NSLocalizedDescriptionKey: "CB \(code.rawValue)"])
    }

    private func attError(_ code: CBATTError.Code) -> NSError {
        NSError(domain: CBATTErrorDomain, code: code.rawValue, userInfo: [NSLocalizedDescriptionKey: "ATT \(code.rawValue)"])
    }

    /// Giải thích lỗi cho thiết bị "Y25"; lần thử bắt đầu lúc `t0`, lỗi sau đó 40 s.
    private func explain(
        _ error: Error?, phase: ConnectPhase, lost: Bool = false, lastAdvert: Date? = nil, held: Bool = false,
        bluetooth: BluetoothState = .poweredOn
    ) -> Diagnosis {
        let f = ConnectionFailure(
            error: error, phase: phase, time: t0.addingTimeInterval(40), lostAfterConnected: lost, attemptStartedAt: t0
        )
        let ctx = DiagnosisContext(
            deviceName: "Y25", now: t0.addingTimeInterval(40), lastAdvert: lastAdvert, heldBySystem: held, bluetooth: bluetooth
        )
        return ConnectionDiagnostics.explain(f, ctx)
    }
}
