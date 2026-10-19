import CoreBluetooth
import Foundation
import SmartWearCore

public struct QRingError: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Thông tin đọc được trong lúc bắt tay.
public struct QRingDeviceInfo: Sendable, Equatable {
    /// 2A27, rỗng nếu đọc lỗi (đọc sau bắt tay, không chặn kết nối).
    public let hardwareRevision: String
    /// 2A26, rỗng nếu đọc lỗi.
    public let firmwareRevision: String
    /// MAC giải từ System ID 180A/2A23 (`b7:b6:b5:b2:b1:b0`), nil nếu không đọc được.
    public let systemIdMac: String?
    /// Phản hồi thô của lệnh 0x01 SetTime: bảng khả năng (sdks/qring/docs/01-connection.md §4.2).
    public let timeCapabilities: [UInt8]
    /// Phản hồi thô của lệnh 0x3C DeviceSupport.
    public let supportCapabilities: [UInt8]

    public var qringCapabilities: QRingCapabilities {
        QRingCapabilities(timeCaps: timeCapabilities, supportCaps: supportCapabilities)
    }

    /// Khả năng chuẩn hoá để UI sinh chức năng theo thiết bị.
    public var capabilities: Set<Capability> { qringCapabilities.toCapabilities() }
}

public struct QRingBattery: Sendable, Equatable {
    public let level: Int
    public let charging: Bool
}

/// Client cho một thiết bị QRing (bản iOS của `QRingClient` Android). Một request/response tại một
/// thời điểm; các gói ring tự gửi (không khớp request nào) được phát cho các `subscribe`.
@MainActor
public final class QRingClient {
    public nonisolated static let cmdSetTime: UInt8 = 0x01
    public nonisolated static let cmdBattery: UInt8 = 0x03
    public nonisolated static let cmdPhoneInfo: UInt8 = 0x04
    public nonisolated static let cmdPackageLength: UInt8 = 0x2F
    public nonisolated static let cmdDeviceSupport: UInt8 = 0x3C
    public nonisolated static let cmdStartMeasure: UInt8 = 0x69
    public nonisolated static let cmdStopMeasure: UInt8 = 0x6A
    public nonisolated static let cmdDeviceNotify: UInt8 = 0x73

    public let gatt: GattConnection
    public private(set) var deviceInfo: QRingDeviceInfo?
    /// Thời gian gửi lệnh → phản hồi đầu tiên của lệnh gần nhất.
    public var onLatency: ((Date) -> Void)?
    public var onDisconnected: ((Error?) -> Void)? {
        get { gatt.onDisconnected }
        set { gatt.onDisconnected = newValue }
    }

    private let requestLock = AsyncLock()
    private var waiters: [UInt8: OneShot<Packet>] = [:]
    private var bigDataWaiters: [UInt8: OneShot<BigDataFrame>] = [:]
    /// Lệnh có phản hồi nhiều gói đang gom (lịch sử), theo mã lệnh.
    private var collectors: [UInt8: PacketCollector] = [:]
    private var subscribers: [UUID: (Packet) -> Void] = [:]
    private var bigDataChunkSize = 20
    private lazy var assembler = BigDataAssembler { [weak self] in self?.onBigDataFrame($0) }

    public init(id: UUID, central: BleCentral? = nil) {
        gatt = GattConnection(id: id, central: central)
        gatt.onNotification = { [weak self] uuid, data in self?.onNotification(uuid, data) }
    }

    public var state: ConnectionState { gatt.state }

    /// Kết nối và bắt tay theo app QRing iOS (sdks/qring/docs/ios-qring-app.md §2–3):
    /// notify 6e400003 + de5bf729 liên tiếp, không chờ callback → `04 01 <iOS> <model>` (lỗi vẫn đi tiếp)
    /// → 0x01 SetTime → 0x3C (mỗi lệnh thử 3 lần cách 1 s) → đọc 2A27/2A26/2A23 (lỗi chỉ ghi log).
    public func connect() async throws -> QRingDeviceInfo {
        try await gatt.connect()
        do {
            // Bắn rồi quên như app gốc: phản hồi 04/01 đầu tiên chính là xác nhận notify đã chạy.
            try await gatt.setNotify(QRing.service, QRing.notify, wait: false)
            if gatt.hasCharacteristic(QRing.bigDataService, QRing.bigDataNotify) {
                try await gatt.setNotify(QRing.bigDataService, QRing.bigDataNotify, wait: false)
            }
            let hs = try await QRingHandshake.run(
                self, phoneInfo: Self.phoneInfoPacket(), setTime: { Self.setTimePacket(Date()) }
            )
            gatt.noteStep("0x04 \(hs.phoneInfoAcked ? "có" : "không có") phản hồi, SetTime 0x01 OK, DeviceSupport 0x3C OK")
            if !gatt.isNotifyConfirmed(QRing.notify) {
                SmartWearLog.w("QRing: notify 6E400003 chưa được xác nhận")
                gatt.noteStep("Notify 6E400003 chưa được xác nhận (vẫn đi tiếp)", level: .warning)
            }
            let hw = await readStringQuietly(QRing.hardwareRevision)
            let fw = await readStringQuietly(QRing.firmwareRevision)
            let mac = await readSystemIdMac()
            guard gatt.state == .connected else { throw GattError.disconnected }
            let info = QRingDeviceInfo(
                hardwareRevision: hw, firmwareRevision: fw, systemIdMac: mac,
                timeCapabilities: hs.time.payload, supportCapabilities: hs.support.payload
            )
            deviceInfo = info
            SmartWearLog.i("QRing \(gatt.id) sẵn sàng: hw=\(hw) fw=\(fw) mac=\(mac ?? "?") 0x04=\(hs.phoneInfoAcked ? "có" : "không") phản hồi")
            return info
        } catch {
            disconnect()
            throw error
        }
    }

    public func disconnect() {
        gatt.disconnect()
        let error = QRingError("Đã ngắt kết nối")
        for w in waiters.values { w.fail(error) }
        for w in bigDataWaiters.values { w.fail(error) }
        for c in collectors.values { c.close(error) }
        assembler.reset()
    }

    public func battery() async throws -> QRingBattery {
        let p = try await request(Packet.of(Self.cmdBattery))
        return QRingBattery(level: p.u8(0), charging: p.u8(1) == 1)
    }

    /// Đăng ký nhận gói ring tự gửi. Trả về token để huỷ.
    public func subscribe(_ handler: @escaping (Packet) -> Void) -> UUID {
        let token = UUID()
        subscribers[token] = handler
        return token
    }

    public func unsubscribe(_ token: UUID) { subscribers[token] = nil }

    /// Đo thủ công và phát từng gói kết quả. Luồng kết thúc khi: ring báo chưa đeo / lỗi (ring tự dừng
    /// đo, đã kiểm chứng trên R09), ring im lặng quá `idleTimeout` (ring không có gói kết thúc, R09 im
    /// ~5 s sau giá trị đầu), hoặc người dùng dừng lặp. Khi kết thúc, SDK tự gửi lệnh stop 0x6A kèm giá trị cuối.
    /// Không dùng keep-alive 1E 03 như app gốc vì firmware R09 trả lỗi 9E cho lệnh đó.
    public func measure(_ type: MeasurementType, idleTimeout: TimeInterval = 5) -> AsyncThrowingStream<MeasurementReading, Error> {
        AsyncThrowingStream { continuation in
            let lastPacketAt = Box(Date())
            let started = Date()
            let gotFirst = Box(false)
            let lastOk = Box<MeasurementReading?>(nil)
            let token = subscribe { [weak self] p in
                guard p.command == Self.cmdStartMeasure, p.isError || p.u8(0) == Int(type.code) else { return }
                lastPacketAt.value = Date()
                if !gotFirst.value {
                    gotFirst.value = true
                    self?.onLatency?(started)
                }
                let reading = MeasurementReading.parse(type, p)
                if reading.status == .ok { lastOk.value = reading }
                continuation.yield(reading)
                if reading.status == .notWorn || reading.status == .error { continuation.finish() }
            }
            let watchdog = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if Date().timeIntervalSince(lastPacketAt.value) > idleTimeout {
                        continuation.finish()
                        return
                    }
                }
            }
            let starter = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await self.sendNoResponse(Packet.of(Self.cmdStartMeasure, type.code, type.sub))
                    lastPacketAt.value = Date()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    watchdog.cancel()
                    starter.cancel()
                    guard let self else { return }
                    self.unsubscribe(token)
                    if self.state == .connected {
                        try? await self.sendNoResponse(type.stopPacket(last: lastOk.value))
                    }
                }
            }
        }
    }

    /// Đo và trả về kết quả hợp lệ đầu tiên. Ném lỗi nếu chưa đeo, ring báo lỗi hoặc hết giờ.
    public func measureOnce(_ type: MeasurementType, timeout: TimeInterval = 60) async throws -> MeasurementReading {
        let stream = measure(type)
        let result = try await withTimeout(timeout, "đo \(type.rawValue)") { () async throws -> MeasurementReading? in
            for try await r in stream where r.status != .measuring { return r }
            return nil
        }
        guard let result else { throw QRingError("Ring ngừng gửi trước khi có kết quả \(type.rawValue)") }
        if result.status == .notWorn { throw QRingError("Chưa đeo") }
        if result.status == .error { throw QRingError("Ring báo lỗi khi đo \(type.rawValue) (mã \(result.errorCode))") }
        return result
    }

    /// Đặt giờ ring theo giờ địa phương của điện thoại. Phản hồi là bảng khả năng của ring.
    public func setTime(_ now: Date = Date()) async throws -> Packet {
        try await request(Self.setTimePacket(now))
    }

    static func setTimePacket(_ now: Date) -> Packet {
        QRingHandshake.setTimePacket(now, language: languageCode())
    }

    /// Gửi một lệnh 16 byte và chờ phản hồi cùng mã lệnh. Ném lỗi khi hết giờ hoặc ring trả cờ lỗi.
    public func request(_ packet: Packet, timeout: TimeInterval = 5) async throws -> Packet {
        try await requestLock.withLock {
            let waiter = OneShot<Packet>()
            waiters[packet.command] = waiter
            defer { if waiters[packet.command] === waiter { waiters[packet.command] = nil } }
            let started = Date()
            try await write(packet)
            let rsp = try await waiter.wait(timeout: timeout) {
                QRingError(String(format: "Không nhận được phản hồi lệnh 0x%02X", packet.command))
            }
            onLatency?(started)
            if rsp.isError { throw QRingError(String(format: "Ring báo lỗi cho lệnh 0x%02X: %@", packet.command, rsp.description)) }
            return rsp
        }
    }

    /// Gửi lệnh không chờ phản hồi.
    public func sendNoResponse(_ packet: Packet) async throws {
        try await requestLock.withLock { try await write(packet) }
    }

    /// Gửi khung big-data và chờ khung phản hồi cùng mã lệnh.
    public func requestBigData(_ frame: BigDataFrame, timeout: TimeInterval = 10) async throws -> BigDataFrame {
        try await requestLock.withLock {
            let waiter = OneShot<BigDataFrame>()
            bigDataWaiters[frame.command] = waiter
            defer { if bigDataWaiters[frame.command] === waiter { bigDataWaiters[frame.command] = nil } }
            try await writeBigData(frame)
            return try await waiter.wait(timeout: timeout) {
                QRingError(String(format: "Không nhận được phản hồi big-data 0x%02X", frame.command))
            }
        }
    }

    /// Gửi một lệnh có phản hồi nhiều gói (dữ liệu lịch sử) và gom các gói cùng mã lệnh cho đến khi `isComplete`
    /// trả về true. Ring ngừng gửi quá `idleTimeout` thì trả về phần đã nhận (có thể rỗng): SDK gốc không có
    /// timeout, còn ở đây không bao giờ treo. Ring trả cờ lỗi thì ném lỗi.
    public func requestStream(
        _ packet: Packet, idleTimeout: TimeInterval = 4, isComplete: @escaping ([Packet]) -> Bool
    ) async throws -> [Packet] {
        try await requestLock.withLock {
            let collector = PacketCollector()
            collectors[packet.command] = collector
            defer { if collectors[packet.command] === collector { collectors[packet.command] = nil } }
            let started = Date()
            try await write(packet)
            var received: [Packet] = []
            while let next = try await collector.receive(timeout: idleTimeout) {
                if received.isEmpty { onLatency?(started) }
                if next.isError { throw QRingError(String(format: "Ring báo lỗi cho lệnh 0x%02X", packet.command)) }
                received.append(next)
                if isComplete(received) { break }
            }
            if received.isEmpty { SmartWearLog.w(String(format: "QRing: lệnh 0x%02X không có gói nào trong %.0f s", packet.command, idleTimeout)) }
            return received
        }
    }

    /// Gửi một khung big-data và chờ các khung phản hồi có mã trong `expect` (vd giấc ngủ 0x27 kéo theo ngủ trưa
    /// 0x3E). Trả về những khung đã nhận khi đủ hoặc hết `timeout` (khung thiếu thì không có trong kết quả).
    public func requestBigDataMulti(_ frame: BigDataFrame, expect: Set<UInt8>, timeout: TimeInterval = 10) async throws -> [UInt8: BigDataFrame] {
        try await requestLock.withLock {
            let pending = Dictionary(uniqueKeysWithValues: expect.map { ($0, OneShot<BigDataFrame>()) })
            for (cmd, w) in pending { bigDataWaiters[cmd] = w }
            defer { for (cmd, w) in pending where bigDataWaiters[cmd] === w { bigDataWaiters[cmd] = nil } }
            try await writeBigData(frame)
            let deadline = Date().addingTimeInterval(timeout)
            var result: [UInt8: BigDataFrame] = [:]
            for (cmd, w) in pending.sorted(by: { $0.key < $1.key }) {
                do {
                    result[cmd] = try await w.wait(timeout: max(deadline.timeIntervalSinceNow, 0.01)) { BigDataTimeout() }
                } catch is BigDataTimeout {
                    SmartWearLog.d(String(format: "Big-data 0x%02X: không có khung trong %.0f s", cmd, timeout))
                }
            }
            return result
        }
    }

    private struct BigDataTimeout: Error {}

    /// Cắt khung theo độ dài gói ring báo (`2F`) và độ dài ghi tối đa của iOS, chỉ đoạn đầu có `BC`.
    private func writeBigData(_ frame: BigDataFrame) async throws {
        let size = min(bigDataChunkSize, gatt.maximumWriteLength(withResponse: false))
        for chunk in frame.chunks(max(size, 20)) {
            try await gatt.write(QRing.bigDataService, QRing.bigDataWrite, Data(chunk), withResponse: false)
        }
    }

    private func write(_ packet: Packet) async throws {
        try await gatt.write(QRing.service, QRing.write, packet.data, withResponse: true)
    }

    /// Đọc chuỗi 180A sau bắt tay. Lỗi / không có characteristic thì trả rỗng, không làm hỏng kết nối.
    private func readStringQuietly(_ characteristic: CBUUID) async -> String {
        guard gatt.hasCharacteristic(QRing.deviceInfo, characteristic) else { return "" }
        do {
            let data = try await gatt.read(QRing.deviceInfo, characteristic)
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        } catch {
            SmartWearLog.w("QRing: đọc \(characteristic.short) lỗi (bỏ qua): \(error.localizedDescription)")
            return ""
        }
    }

    /// iOS ẩn MAC: đọc System ID 2A23 như app gốc (bước 5.0). Lỗi thì nil.
    private func readSystemIdMac() async -> String? {
        guard gatt.hasCharacteristic(QRing.deviceInfo, QRing.systemId) else { return nil }
        do {
            return QRingHandshake.macFromSystemId(try await gatt.read(QRing.deviceInfo, QRing.systemId))
        } catch {
            SmartWearLog.w("QRing: đọc 2A23 lỗi (bỏ qua): \(error.localizedDescription)")
            return nil
        }
    }

    private func onNotification(_ uuid: CBUUID, _ value: Data) {
        switch uuid {
        case QRing.notify:
            guard let p = Packet.parse(value) else {
                SmartWearLog.w("Bỏ gói 16 byte không hợp lệ (\(value.count) byte)")
                return
            }
            if p.command == Self.cmdPackageLength { bigDataChunkSize = max(p.u8(0), 20) }
            if let collector = collectors[p.command] {
                collector.send(p)
                return
            }
            if let waiter = waiters[p.command], !waiter.isCompleted {
                waiter.succeed(p)
            } else {
                for handler in subscribers.values { handler(p) }
            }
        case QRing.bigDataNotify:
            assembler.feed([UInt8](value))
        default:
            break
        }
    }

    private func onBigDataFrame(_ frame: BigDataFrame) {
        if let waiter = bigDataWaiters[frame.command] {
            waiter.succeed(frame)
        } else {
            SmartWearLog.d(String(format: "Big-data 0x%02X không có ai chờ (%d byte)", frame.command, frame.payload.count))
        }
    }

    /// Lệnh 0x04. Mặc định gửi dạng "không phải iOS" `04 02 0A <model>` (như bản Android): nhẫn/vòng KHÔNG
    /// xin ghép đôi ANCS với iOS. Bản iOS chính chủ gửi `04 01 <iOS major> <mã model>` (ios-qring-app.md §3): nhẫn
    /// nhận thông báo iPhone nhưng bị iOS ghép đôi cấp hệ thống, giữ kết nối mãi, app không nhả được, máy khác
    /// không nối được (kiểm chứng 15/10/2026). Bật `QRingDriver.iosNotifications` khi cần thông báo.
    static func phoneInfoPacket() -> Packet {
        if QRingDriver.iosNotifications {
            return QRingHandshake.phoneInfoPacket(
                osMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
                machine: QRingHandshake.currentMachine()
            )
        }
        return QRingHandshake.neutralPhoneInfoPacket(machine: QRingHandshake.currentMachine())
    }

    /// Mã ngôn ngữ của lệnh SetTime (SetTimeReq.java:34-64; bảng iOS có thêm ms 27 … fa 34).
    nonisolated static func languageCode(_ preferred: String? = Locale.preferredLanguages.first) -> UInt8 {
        let lang = String((preferred ?? "en").prefix { $0 != "-" && $0 != "_" }).lowercased()
        let table: [String: UInt8] = [
            "zh": 0, "en": 1, "el": 3, "fr": 4, "de": 5, "it": 6, "es": 7, "nl": 8, "pt": 9,
            "ru": 10, "tr": 11, "ja": 12, "ko": 13, "pl": 14, "ro": 15, "ar": 16, "th": 17,
            "vi": 18, "in": 19, "id": 19, "hi": 20, "cs": 21, "sk": 22, "hu": 23, "iw": 24,
            "he": 24, "hr": 25, "sl": 26, "ms": 27, "uk": 28, "lt": 29, "lv": 30, "et": 31, "da": 32,
            "sv": 33, "fa": 34, "ur": 35,
        ]
        return table[lang] ?? 1
    }
}

extension QRingClient: QRingHandshakeTransport {
    func pause(_ seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

/// Hàng đợi gói của một lệnh nhiều gói (giống `Channel(UNLIMITED)` Android), một người nhận, trên MainActor.
@MainActor
final class PacketCollector {
    private var buffer: [Packet] = []
    private var waiting: OneShot<Packet>?
    private var closed: Error?

    private struct Idle: Error {}

    func send(_ p: Packet) {
        // Shot đã xong (vừa hết giờ) thì giữ gói lại, không làm rơi.
        if let w = waiting, !w.isCompleted {
            waiting = nil
            w.succeed(p)
        } else {
            buffer.append(p)
        }
    }

    func close(_ error: Error) {
        closed = error
        waiting?.fail(error)
        waiting = nil
    }

    /// Gói kế tiếp, nil nếu im lặng quá `timeout` giây.
    func receive(timeout: TimeInterval) async throws -> Packet? {
        if !buffer.isEmpty { return buffer.removeFirst() }
        if let closed { throw closed }
        let shot = OneShot<Packet>()
        waiting = shot
        defer { if waiting === shot { waiting = nil } }
        do {
            return try await shot.wait(timeout: timeout) { Idle() }
        } catch is Idle {
            return nil
        }
    }
}
