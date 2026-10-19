import Foundation
import SmartWearCore

/// Phần của `QRingClient` mà bắt tay cần, tách ra để kiểm thử thứ tự lệnh bằng transport giả.
@MainActor
protocol QRingHandshakeTransport: AnyObject {
    /// Gửi lệnh 16 byte, chờ phản hồi cùng mã lệnh (ném lỗi khi hết giờ / ring trả cờ lỗi).
    func request(_ packet: Packet, timeout: TimeInterval) async throws -> Packet
    /// Chờ giữa các lần thử lại (ném lỗi khi task bị huỷ).
    func pause(_ seconds: TimeInterval) async throws
}

/// Bắt tay theo thứ tự app QRing iOS 1.3.1 (`QIFDeviceManager initBandBasicSettingSuccess:fail:`,
/// sdks/qring/docs/ios-qring-app.md §3):
/// 1. `04 01 <iOS major> <mã model iPhone>`, chờ phản hồi `04`; hết giờ / lỗi thì vẫn đi tiếp.
/// 2. `01` SetTime (BCD yyMMddHHmmss + mã ngôn ngữ), thử tối đa 3 lần cách 1 s. Phản hồi = bảng khả năng.
/// 3. `3C` DeviceSupport, thử tối đa 3 lần cách 1 s.
enum QRingHandshake {
    static let phoneInfoTimeout: TimeInterval = 3
    static let attempts = 3
    static let retryDelay: TimeInterval = 1

    struct Result {
        let time: Packet
        let support: Packet
        /// Ring có trả lời lệnh 0x04 không (chỉ để ghi log).
        let phoneInfoAcked: Bool
    }

    /// `setTime` được gọi lại ở mỗi lần thử để giờ gửi đi luôn mới.
    static func run(
        _ t: QRingHandshakeTransport, phoneInfo: Packet, setTime: () -> Packet, requestTimeout: TimeInterval = 5
    ) async throws -> Result {
        var acked = false
        do {
            _ = try await t.request(phoneInfo, timeout: phoneInfoTimeout)
            acked = true
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            SmartWearLog.w("QRing: lệnh 0x04 không có phản hồi, vẫn tiếp tục: \(error.localizedDescription)")
        }
        let time = try await retrying(t, "SetTime 0x01") { try await t.request(setTime(), timeout: requestTimeout) }
        let support = try await retrying(t, "DeviceSupport 0x3C") {
            try await t.request(Packet.of(QRingClient.cmdDeviceSupport), timeout: requestTimeout)
        }
        return Result(time: time, support: support, phoneInfoAcked: acked)
    }

    /// Thử `body` tối đa `attempts` lần, cách nhau `retryDelay`. Mất kết nối / huỷ thì dừng ngay.
    static func retrying<R>(
        _ t: QRingHandshakeTransport, _ what: String, _ body: () async throws -> R
    ) async throws -> R {
        var attempt = 1
        while true {
            do {
                return try await body()
            } catch {
                if error is CancellationError || attempt >= attempts { throw error }
                if let e = error as? GattError, e == .notConnected || e == .disconnected { throw error }
                SmartWearLog.w("QRing: \(what) lỗi lần \(attempt): \(error.localizedDescription), thử lại sau \(retryDelay) s")
                try await t.pause(retryDelay)
                attempt += 1
            }
        }
    }

    // MARK: - Lệnh 0x04 bản iOS

    /// `04 01 <iOS major> <mã model iPhone|00>` (`QIFBleSetANCSFlagCmd`, format "0401%02lX%02lX").
    /// Byte 1 = 01 báo điện thoại là iOS (Android gửi 02 kèm chuỗi model).
    static func phoneInfoPacket(osMajor: Int, machine: String) -> Packet {
        Packet.of(QRingClient.cmdPhoneInfo, 0x01, UInt8(clamping: osMajor), iPhoneModelIndex(machine))
    }

    /// `04 02 0A <model ASCII ≤ 12 byte>`: dạng Android (doc 01-connection §4.2), không bật ANCS/ghép đôi iOS.
    static func neutralPhoneInfoPacket(machine: String) -> Packet {
        Packet.of(QRingClient.cmdPhoneInfo, payload: [0x02, 0x0A] + Array(machine.utf8.prefix(12)))
    }

    /// Mã model theo `+[OdmCmdHelper iPhoneDeviceType]`. Model không có trong bảng (iPhone 6 Plus,
    /// iPhone 16 trở đi, iPad, Mac, simulator) → 0.
    static func iPhoneModelIndex(_ machine: String) -> UInt8 { iPhoneModels[machine] ?? 0 }

    /// utsname machine id → mã model của app QRing iOS.
    static let iPhoneModels: [String: UInt8] = [
        "iPhone5,1": 1, "iPhone5,2": 1,                     // 5
        "iPhone5,3": 2, "iPhone5,4": 2,                     // 5c
        "iPhone6,1": 3, "iPhone6,2": 3,                     // 5s
        "iPhone7,2": 4,                                     // 6 (6 Plus = iPhone7,1 không có trong bảng)
        "iPhone8,1": 5,                                     // 6S
        "iPhone8,2": 6,                                     // 6S Plus
        "iPhone8,4": 7,                                     // SE
        "iPhone9,1": 8, "iPhone9,3": 8,                     // 7
        "iPhone9,2": 9, "iPhone9,4": 9,                     // 7 Plus
        "iPhone10,1": 10, "iPhone10,4": 10,                 // 8
        "iPhone10,2": 11, "iPhone10,5": 11,                 // 8 Plus
        "iPhone10,3": 12, "iPhone10,6": 12,                 // X
        "iPhone11,2": 13,                                   // XS
        "iPhone11,4": 14, "iPhone11,6": 14,                 // XS Max
        "iPhone11,8": 15,                                   // XR
        "iPhone12,1": 16,                                   // 11
        "iPhone12,3": 17,                                   // 11 Pro
        "iPhone12,5": 18,                                   // 11 Pro Max
        "iPhone12,8": 19,                                   // SE 2
        "iPhone13,2": 20,                                   // 12
        "iPhone13,1": 21,                                   // 12 mini
        "iPhone13,3": 22,                                   // 12 Pro
        "iPhone13,4": 23,                                   // 12 Pro Max
        "iPhone14,4": 24,                                   // 13 mini
        "iPhone14,5": 25,                                   // 13
        "iPhone14,2": 26,                                   // 13 Pro
        "iPhone14,3": 27,                                   // 13 Pro Max
        "iPhone14,6": 28,                                   // SE (3rd)
        "iPhone14,7": 29,                                   // 14
        "iPhone14,8": 30,                                   // 14 Plus
        "iPhone15,2": 31,                                   // 14 Pro
        "iPhone15,3": 32,                                   // 14 Pro Max
        "iPhone15,4": 33,                                   // 15
        "iPhone15,5": 34,                                   // 15 Plus
        "iPhone16,1": 35,                                   // 15 Pro
        "iPhone16,2": 36,                                   // 15 Pro Max
    ]

    /// utsname().machine của máy đang chạy. Simulator trả "arm64"/"x86_64" nên lấy model giả lập nếu có.
    static func currentMachine() -> String {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return sim }
        var sys = utsname()
        uname(&sys)
        return withUnsafeBytes(of: &sys.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    // MARK: - SetTime

    /// `01 yy MM dd HH mm ss <ngôn ngữ>` (BCD, giờ địa phương, cộng 1 s như app).
    static func setTimePacket(_ now: Date, language: UInt8, calendar: Calendar = Calendar(identifier: .gregorian)) -> Packet {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now.addingTimeInterval(1))
        return Packet.of(
            QRingClient.cmdSetTime,
            bcd(c.year! % 100), bcd(c.month!), bcd(c.day!), bcd(c.hour!), bcd(c.minute!), bcd(c.second!),
            language
        )
    }

    static func bcd(_ v: Int) -> UInt8 { UInt8(((v / 10) << 4) | (v % 10)) }

    // MARK: - 180A/2A23 System ID

    /// MAC từ System ID 8 byte (2A23): `b7:b6:b5:b2:b1:b0` như app QRing iOS (bước 5.0). Sai độ dài → nil.
    static func macFromSystemId(_ data: Data) -> String? {
        let b = [UInt8](data)
        guard b.count == 8 else { return nil }
        let mac = [b[7], b[6], b[5], b[2], b[1], b[0]]
        guard mac.contains(where: { $0 != 0 }) else { return nil }
        return mac.map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}
