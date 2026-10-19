import SmartWearCore
import XCTest
@testable import SmartWearVeepoo

/// Gói thật của GE54 (19/10/2026, Redmi Note 7 Pro), cùng vector với `VeepooTest.kt` Android.
final class VeepooGe54Tests: XCTestCase {
    func testPasswordCheckMatchesCapture() throws {
        // Gói app Android gửi lúc 18:41:51 GMT+7, 24h (byte 12 = 01 như Android; iOS mặc định gửi 00 để xin bond ANCS).
        let p = try Veepoo.passwordCheck(now: T.date(2026, 10, 19, 18, 41, 51), is24h: true, timeZone: T.tz, calendar: T.calendar)
        XCTAssertEqual(T.hex("A1 00 00 00 07 EA 0A 13 12 29 33 01 01 1C 00 00 00 00 00 00"), p)
        let ios = try Veepoo.passwordCheck(now: T.date(2026, 10, 19, 18, 41, 51), is24h: true, timeZone: T.tz, calendar: T.calendar,
                                           requestPairing: true)
        XCTAssertEqual(0x00, ios[12])
    }

    func testPasswordReply() throws {
        let r = try XCTUnwrap(Veepoo.parsePasswordReply(T.hex("A1 00 00 06 17 5C 00 95 01 00 00 01 45 1D E3 8F F4 9C 00 00")))
        XCTAssertEqual(.checkAndTimeSuccess, r.status)
        XCTAssertTrue(Veepoo.passwordAccepted(r))
        XCTAssertEqual(5980, r.deviceNumber)
        XCTAssertEqual("00.95.01", r.firmware)
        XCTAssertEqual("00.95.01.00", r.testVersion)
        XCTAssertEqual("9C:F4:8F:E3:1D:45", r.mac)
        XCTAssertEqual(1, r.nightWrist)
        XCTAssertEqual(0, r.findPhone)
        XCTAssertFalse(Veepoo.passwordAccepted(try XCTUnwrap(Veepoo.parsePasswordReply(T.hex("A1 00 00 00 17 5C 00 95 01 00 00 01 45 1D E3 8F F4 9C 00 00")))))
        XCTAssertNil(Veepoo.parsePasswordReply(T.hex("A1 00 00 06")))
    }

    func testBattery() throws {
        let charging = try XCTUnwrap(Veepoo.parseBattery(T.hex("A0 01 00 00 55 01 55 01 00 00 00 00 00 00 00 00 00 00 00 00")))
        XCTAssertEqual(85, charging.percent)
        XCTAssertTrue(charging.charging)
        let unplugged = try XCTUnwrap(Veepoo.parseBattery(T.hex("A0 00 00 00 56 01 56 01 00 00 00 00 00 00 00 00 00 00 00 00")))
        XCTAssertEqual(86, unplugged.percent)
        XCTAssertFalse(unplugged.charging)
        XCTAssertEqual(75, Veepoo.parseBattery(T.hex("A0 00 00 00 03 00 00 01"))?.percent)
        XCTAssertNil(Veepoo.parseBattery(T.hex("A0 00 00 00 00 01 50 01")))
        XCTAssertEqual(T.pad(T.hex("A5 07 EA 0A 13 12 29 33 02")), Veepoo.setTime(T.date(2026, 10, 19, 18, 41, 51), is24h: true, calendar: T.calendar))
    }

    static let pages = [
        "A7 01 00 02 02 02 01 00 06 14 01 02 00 00 00 01 00 06 03 01",
        "A7 00 03 04 00 03 00 00 03 00 05 01 00 01 02 0B 05 00 01 02",
        "A7 02 00 01 00 00 01 05 01 00 00 00 01 00 00 04 01 02 02 03",
        "A7 02 01 00 00 00 00 00 00 00 00 00 00 01 00 00 00 00 00 04",
        "A7 00 00 00 01 00 00 01 01 00 00 00 00 00 00 00 00 00 00 05",
    ].map(T.hex)

    func testFeatures() {
        let f = VeepooFeatures(packets: Self.pages)
        XCTAssertTrue(f.complete)
        XCTAssertTrue(f.bloodPressure)
        XCTAssertTrue(f.healthRemind)
        XCTAssertFalse(f.longSeat)
        XCTAssertTrue(f.camera)
        XCTAssertEqual(6, f.spo2Type)
        XCTAssertTrue(f.spo2)
        XCTAssertEqual(20, f.messagePackets)
        XCTAssertEqual(2, f.wristTurnType)
        XCTAssertFalse(f.brightness)
        XCTAssertEqual(6, f.alarmType)
        XCTAssertTrue(f.textAlarm)
        XCTAssertTrue(f.heartRate)
        XCTAssertEqual(3, f.watchDays)
        XCTAssertEqual(4, f.contactMsgLength)
        XCTAssertEqual(3, f.sportModelSlots)
        XCTAssertEqual(0, f.screenStyleCount)
        XCTAssertFalse(f.weather)
        XCTAssertEqual(5, f.originProtocolVersion)
        XCTAssertTrue(f.usesDf)
        XCTAssertEqual(1, f.sleepTag)
        XCTAssertTrue(f.preciseSleep)
        XCTAssertEqual(2, f.bigDataTranType)
        XCTAssertEqual(0, f.watchUiServerCount)
        XCTAssertFalse(f.contacts)
        XCTAssertEqual(1, f.musicType)
        XCTAssertEqual(5, f.temperatureType)
        XCTAssertTrue(f.findDeviceByPhone)
        XCTAssertEqual(1, f.cpuType)
        XCTAssertTrue(f.stress)
        XCTAssertTrue(f.met)
        XCTAssertTrue(f.sportControl)
        XCTAssertEqual(1, f.screenShape)
        XCTAssertFalse(f.nativeWatchFace)
        XCTAssertEqual(5, f.multiSportType)  // buổi tập dạng TLV: chưa đọc
        XCTAssertTrue(f.capabilities().contains(.sleep))
        XCTAssertFalse(f.capabilities().contains(.menstruation))
    }

    func testMessageSwitches() {
        let m = VeepooMessageSwitches(
            page0: T.hex("AD 02 01 01 01 01 00 01 01 00 01 01 01 01 01 01 01 00 00 01"),
            page1: T.hex("AD 02 01 01 01 01 00 01 00 00 00 00 00 00 00 00 00 00 00 10")
        )
        XCTAssertEqual(1, m.status(0))
        XCTAssertEqual(1, m.status(1))
        XCTAssertEqual(0, m.status(4))
        XCTAssertEqual(1, m.status(17))
        XCTAssertEqual(1, m.status(23))
        XCTAssertEqual(0, m.status(24))  // Zalo không hỗ trợ trên GE54
        let w = m.writePackets { $0 != 9 }  // tắt WhatsApp
        XCTAssertEqual(2, w.count)
        XCTAssertEqual(T.hex("AD 01 01 01 01 01 00 01 01 00 01 02 01 01 01 01 01 00 00 01"), w[0])
        XCTAssertEqual(T.hex("AD 01 01 01 01 01 00 01 00 00 00 00 00 00 00 00 00 00 00 10"), w[1])
    }

    func testCustomSettings() throws {
        let c = VeepooCustomSettings(
            page0: T.hex("B8 02 01 01 01 01 00 00 00 00 02 02 01 00 00 00 01 00 00 00"),
            page1: T.hex("B8 02 00 00 01 01 00 01 00 01 01 01 01 01 00 00 00 00 00 01")
        )
        XCTAssertTrue(c.metric)
        XCTAssertTrue(c.is24h)
        XCTAssertTrue(c.isOn(0, VeepooCustomSettings.autoHr))
        XCTAssertEqual(2, c.value(0, VeepooCustomSettings.spo2Low))
        XCTAssertTrue(c.isOn(1, VeepooCustomSettings.autoTemperature))
        XCTAssertTrue(c.isOn(1, VeepooCustomSettings.autoStress))
        XCTAssertEqual(T.hex("B8 01 01 02 01 01 00 00 00 00 02 02 01 00 00 00 01 00 00 00"), c.write(0, VeepooCustomSettings.hour, 2))
        XCTAssertEqual(T.hex("B8 01 00 00 01 01 00 01 00 01 01 01 01 01 00 00 00 00 00 01"), c.write(1, VeepooCustomSettings.autoStress, 1))
        XCTAssertFalse(c.with(0, VeepooCustomSettings.hour, 2).is24h)
        // Cài đặt hiện cho GE54 (id như Android): không nâng tay / độ sáng / ngôn ngữ (không màn); nhắc E7 đọc từ vòng tay;
        // cảnh báo nhịp tim AC; tắt máy (không màn).
        let state = VeepooDeviceState(
            reminds: [1: VeepooRemind(type: 1, fromMinute: 480, toMinute: 1080, interval: 60, on: true),
                      2: VeepooRemind(type: 2, fromMinute: 480, toMinute: 1320, interval: 30, on: true)],
            heartAlarm: VeepooControls.parseHeartAlarm(T.hex("AC 64 37 01 02 01"))
        )
        let controls = VeepooControls.controls(VeepooFeatures(packets: Self.pages), c, VeepooMessageSwitches(page0: nil, page1: nil),
                                               VeepooSettings(), state)
        let ids = controls.map(\.id)
        for id in ["remind.sedentary.enabled", "remind.sedentary.interval", "remind.sedentary.range", "remind.drink.enabled", "auto.hr",
                   "auto.temperature", "auto.glucose", "auto.stress", "auto.bloodComponent", "auto.hrv", "auto.ppg", "alert.spo2Low",
                   "unit.hour24", "unit.system", "unit.temperature", "hrAlarm.enabled", "hrAlarm.high", "hrAlarm.low", "find.start",
                   "device.read", "device.powerOff", "data.reset"] {
            XCTAssertTrue(ids.contains(id), id)
        }
        for id in ["display.raise", "display.brightness", "sedentary.enabled", "language", "notify.pair", "remind.longView.enabled",
                   "hr24.enabled", "unit.hour12"] {
            XCTAssertFalse(ids.contains(id), id)
        }
        XCTAssertEqual(.timeRange(from: 480, to: 1320), controls.first { $0.id == "remind.drink.range" }?.value)
        XCTAssertEqual(.number(100), controls.first { $0.id == "hrAlarm.high" }?.value)
        XCTAssertEqual(.number(55), controls.first { $0.id == "hrAlarm.low" }?.value)
        XCTAssertNotNil(controls.first { $0.id == "device.powerOff" }?.confirm)
    }

    func testMeasure() {
        let hr = VeepooMeasure.heartRate(samples: 2)
        XCTAssertEqual(.measuring, hr(T.pad(T.hex("D0")))?.0.status)
        XCTAssertEqual(false, hr(T.pad(T.hex("D0 4D")))?.1)
        let done = hr(T.pad(T.hex("D0 4C")))
        XCTAssertEqual(.ok, done?.0.status)
        XCTAssertEqual(76, done?.0.value)
        XCTAssertEqual(.notWorn, VeepooMeasure.heartRate()(T.pad(T.hex("D0 01")))?.0.status)
        let charging = VeepooMeasure.heartRate()(T.pad(T.hex("D0 01 00 00 FD")))
        XCTAssertEqual(.error, charging?.0.status)
        XCTAssertEqual(0xFD, charging?.0.errorCode)

        let spo2 = VeepooMeasure.spo2(samples: 3)
        XCTAssertEqual(.measuring, spo2(T.pad(T.hex("80 01 00 00 00 64")))?.0.status)
        XCTAssertEqual(false, spo2(T.pad(T.hex("80 01 00 63 00 64")))?.1)
        XCTAssertEqual(false, spo2(T.pad(T.hex("80 01 00 63 00 64")))?.1)
        XCTAssertEqual(99, spo2(T.pad(T.hex("80 01 00 63 00 64")))?.0.value)

        let bp = VeepooMeasure.bloodPressure()
        XCTAssertEqual(.measuring, bp(T.pad(T.hex("90 00 00 28 00 01")))?.0.status)
        let r = bp(T.pad(T.hex("90 77 56 64 00 01")))
        XCTAssertEqual(119, r?.0.systolic)
        XCTAssertEqual(86, r?.0.diastolic)
        XCTAssertEqual(253, bp(T.pad(T.hex("90 00 00 00 FD 01")))?.0.errorCode)

        let temp = VeepooMeasure.temperature()
        XCTAssertEqual(.measuring, temp(T.pad(T.hex("87 01 01")))?.0.status)
        let p = T.pad(T.hex("87 01 01 07 00 72 01 69 01"))
        let mid = temp(p)
        XCTAssertEqual(.measuring, mid?.0.status)  // máy 7 = vẫn đang đo
        XCTAssertEqual(false, mid?.1)
        XCTAssertEqual(37.0, mid?.0.value)
        XCTAssertEqual(36.1, VeepooMeasure.temperatureBase(p))
        XCTAssertEqual(.ok, temp(T.pad(T.hex("87 01 01 07 64 72 01 69 01")))?.0.status)
        XCTAssertEqual(.error, temp(T.hex("87 01 01 08 00 00 00 00 00"))?.0.status)
        XCTAssertEqual(true, temp(T.hex("87 01 02 00 00 00 00 00 00"))?.1)

        let stress = VeepooMeasure.stress()
        XCTAssertEqual(.measuring, stress(T.pad(T.hex("89 06 01 00 30")))?.0.status)
        XCTAssertEqual(21, stress(T.pad(T.hex("89 06 01 00 64 15")))?.0.value)
        XCTAssertEqual(.notWorn, stress(T.hex("89 06 01 04 00 00"))?.0.status)
        XCTAssertNotNil(stress(T.hex("89 06 02 00 00 00")))
    }
}
