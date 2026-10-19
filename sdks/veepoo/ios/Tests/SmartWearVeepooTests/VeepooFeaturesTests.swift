import SmartWearCore
import XCTest
@testable import SmartWearVeepoo

final class VeepooFeaturesTests: XCTestCase {
    /// Trang A7 `page` với các byte `bytes` (vị trí → giá trị).
    static func page(_ page: Int, _ bytes: [Int: UInt8]) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 20)
        p[0] = 0xA7
        for (i, v) in bytes { p[i] = v }
        p[19] = UInt8(page)
        return p
    }

    /// Vòng tay giả: HA, SpO2 (1), camera, nâng tay đầy đủ, độ sáng 5 mức, nhắc ngồi lâu E1, nhịp tim (byte 18 = 0);
    /// 7 ngày, thể thao 3 khe, HRV 7 (đo từ app), thời tiết 3, DF (origin 3), sáng màn, ngủ chính xác; mặt đồng hồ server 2 /
    /// tuỳ chỉnh 1 qua bigData 2, danh bạ 3 (20 + SOS), nhạc 1, nhiệt độ 1, tìm vòng tay, chip Nordic, stress; màn vuông.
    static let sample = VeepooFeatures(packets: [
        page(1, [1: 1, 3: 1, 6: 1, 8: 1, 11: 1, 13: 5]),
        page(2, [2: 7, 5: 3, 8: 7, 9: 3, 10: 3, 12: 1, 13: 1]),
        page(3, [1: 2, 2: 0x21, 4: 3, 6: 1, 7: 1, 8: 1, 16: 0, 18: 2]),
        page(4, [:]),
        page(5, [4: 3]),
        T.hex("A0 00"),  // gói khác bị bỏ
    ])

    func testA7Flags() {
        let f = Self.sample
        XCTAssertTrue(f.complete)
        XCTAssertTrue(f.bloodPressure)
        XCTAssertTrue(f.longSeat)
        XCTAssertFalse(f.healthRemind)
        XCTAssertTrue(f.camera)
        XCTAssertTrue(f.spo2)
        XCTAssertTrue(f.brightness)
        XCTAssertTrue(f.heartRate)
        XCTAssertEqual(7, f.watchDays)
        XCTAssertEqual(3, f.sportModelSlots)
        XCTAssertTrue(f.hrv)
        XCTAssertTrue(f.hrvByApp)
        XCTAssertTrue(f.weather)
        XCTAssertTrue(f.usesDf)
        XCTAssertTrue(f.parseSportModel)  // có chế độ thể thao
        XCTAssertTrue(f.preciseSleep)
        XCTAssertEqual(2, f.watchUiServerCount)
        XCTAssertEqual(1, f.watchUiCustomCount)
        XCTAssertTrue(f.nativeWatchFace)
        XCTAssertEqual(20, f.maxContacts)
        XCTAssertEqual(1, f.musicType)
        XCTAssertTrue(f.findDeviceByPhone)
        XCTAssertTrue(f.stress)
        XCTAssertEqual(3, f.screenShape)
        XCTAssertEqual([.steps, .heartRate, .spo2, .bloodPressure, .temperature, .stress, .hrv, .sleep], f.capabilities())
        XCTAssertTrue(f.describe().hasPrefix("A7.1: huyết áp=01"))
    }

    func testA7Defaults() {
        let f = VeepooFeatures()
        XCTAssertFalse(f.complete)
        XCTAssertEqual(3, f.watchDays)  // 0 = 3 ngày
        XCTAssertTrue(f.heartRate)  // byte 18 = 0 nghĩa là CÓ nhịp tim
        XCTAssertTrue(f.sleep)
        XCTAssertFalse(f.preciseSleep)
        XCTAssertFalse(f.usesDf)
        XCTAssertEqual([.steps, .heartRate, .sleep], f.capabilities())
        // Không có nhịp tim, không có ngủ, chip JieLi ⇒ không có mặt đồng hồ Veepoo gốc.
        let g = VeepooFeatures(packets: [Self.page(1, [18: 1]), Self.page(2, [13: 2]), Self.page(3, [1: 2, 2: 0x10, 16: 1])])
        XCTAssertFalse(g.heartRate)
        XCTAssertFalse(g.sleep)
        XCTAssertFalse(g.nativeWatchFace)
        XCTAssertEqual("JieLi AC7013", g.cpuName)
    }

    func testMessageSwitches() {
        // Gói 0: phone 1, SMS 2, WeChat 0 …, WhatsApp (9 ⇒ byte 11) 1, "khác" = byte 19 = 2. Gói 1: Messenger (23 ⇒ byte 7) 1,
        // Zalo (24 ⇒ byte 8) 2.
        var p0 = [UInt8](repeating: 0, count: 20)
        p0[0] = 0xAD; p0[1] = 0x02; p0[2] = 1; p0[3] = 2; p0[11] = 1; p0[19] = 2
        var p1 = [UInt8](repeating: 0, count: 20)
        p1[0] = 0xAD; p1[1] = 0x02; p1[7] = 1; p1[8] = 2; p1[19] = 0x10
        let s = VeepooMessageSwitches(packets: [p1, p0])
        XCTAssertEqual(1, s.status(0))
        XCTAssertEqual(2, s.status(1))
        XCTAssertEqual(0, s.status(2))
        XCTAssertEqual(1, s.status(9))
        XCTAssertEqual(2, s.status(17))
        XCTAssertEqual(1, s.status(23))
        XCTAssertEqual(2, s.status(24))
        XCTAssertEqual([0, 1, 9, 17, 23, 24], s.supportedTypes)
        XCTAssertEqual("Zalo", VeepooMessageSwitches.appNames[24])

        // Bật Zalo: gói 0 giữ nguyên trạng thái (byte 1 = 01 ghi), gói 1 byte 8 = 1, byte 19 = 0x10.
        let w = s.with(24, on: true).writePackets(s.with(24, on: true).isOn)
        XCTAssertEqual(2, w.count)
        XCTAssertEqual(T.hex("AD 01 01 02 00 00 00 00 00 00 00 01 00 00 00 00 00 00 00 02"), w[0])
        XCTAssertEqual(T.hex("AD 01 00 00 00 00 00 01 01 00 00 00 00 00 00 00 00 00 00 10"), w[1])
        XCTAssertTrue(s.with(24, on: true).isOn(24))
    }

    func testMessageSwitchesWithoutPage1() {
        var p0 = [UInt8](repeating: 0, count: 20)
        p0[0] = 0xAD; p0[2] = 0
        let s = VeepooMessageSwitches(page0: p0, page1: nil)
        XCTAssertTrue(s.supported(0))  // điện thoại: 0 vẫn coi là có (tắt)
        XCTAssertFalse(s.isOn(0))
        let w = s.writePackets { _ in true }
        XCTAssertEqual(1, w.count)
        XCTAssertEqual(1, w[0][2])
        XCTAssertFalse(VeepooMessageSwitches(page0: nil, page1: nil).any)
    }

    func testCustomSettingsWrite() throws {
        // B8 đọc: metric, 24h, HR tự động bật, HA không hỗ trợ, … byte 17 = 5 (không dùng), trang 0.
        let read = T.hex("B8 02 01 01 01 00 02 01 01 02 01 01 02 00 01 00 00 05 01 00")
        let page1 = T.hex("B8 02 00 01 02 01 00 00 00 02 00 00 00 00 00 00 00 01 01 01")
        let s = VeepooCustomSettings(packets: [read, page1])
        XCTAssertTrue(s.metric)
        XCTAssertTrue(s.is24h)
        XCTAssertTrue(s.isOn(0, VeepooCustomSettings.autoHr))
        XCTAssertFalse(s.supported(0, VeepooCustomSettings.autoBp))
        XCTAssertEqual(1, s.value(1, VeepooCustomSettings.temperatureUnit))
        // Tắt HR tự động: byte 1 = 01 (ghi), byte 4 = 02, byte 17 về 0, các byte khác giữ nguyên.
        let w = try XCTUnwrap(s.write(0, VeepooCustomSettings.autoHr, 2))
        XCTAssertEqual(T.hex("B8 01 01 01 02 00 02 01 01 02 01 01 02 00 01 00 00 00 01 00"), w)
        // Trang 1: byte 19 = 01.
        let w1 = try XCTUnwrap(s.write(1, VeepooCustomSettings.autoStress, 1))
        XCTAssertEqual(T.hex("B8 01 00 01 02 01 00 00 00 01 00 00 00 00 00 00 00 01 01 01"), w1)
        XCTAssertFalse(s.with(0, VeepooCustomSettings.autoHr, 2).isOn(0, VeepooCustomSettings.autoHr))
        XCTAssertNil(VeepooCustomSettings(page0: nil, page1: nil).write(0, 4, 1))
        XCTAssertEqual([0xB8, 0x02], VeepooCustomSettings.read)
    }
}
