import SmartWearCore
import XCTest
@testable import SmartWearVeepoo

final class VeepooSettingsTests: XCTestCase {
    func testCommandBuilders() {
        let s = VeepooSettings()
        XCTAssertEqual(T.pad(T.hex("A3 AA 41 1E 01 1F40 01E0")), VeepooControls.userInfo(s))
        XCTAssertEqual(T.pad(T.hex("A3 A0 37 19 00 2710 01A4")), VeepooControls.userInfo(VeepooSettings([
            "profile.height": 160, "profile.weight": 55, "profile.age": 25, "profile.gender": 1, "goal.steps": 10000, "goal.sleep": 7,
        ])))
        // Bảng ngôn ngữ như Android (`VeepooControls.LANGUAGES`): chỉ số 0 = tiếng Việt.
        XCTAssertEqual(T.pad(T.hex("F4 0A 0A 00 01")), VeepooControls.language(0))  // tiếng Việt = 10
        XCTAssertEqual(T.pad(T.hex("F4 01 01 00 00")), VeepooControls.language(2))  // tiếng Trung: flag 0
        XCTAssertNil(VeepooControls.language(99))
        XCTAssertEqual(T.hex("AA 01 08 00 16 00"), VeepooControls.raiseToWake(s))  // như gói dựng sẵn `mf/a.java:160`
        XCTAssertEqual(T.pad(T.hex("B1 01 16 00 07 00 04 04 00")), VeepooControls.brightness(4))
        XCTAssertEqual(T.pad(T.hex("B4 01 0A")), VeepooControls.screenOn(seconds: 10))
        XCTAssertEqual(T.hex("E1 09 00 12 00 3C 00"), VeepooControls.sedentary(s))
        XCTAssertEqual(T.pad(T.hex("E7 01 02 08 00 14 00 3C 01")),
                       VeepooControls.remindWrite(VeepooRemind(type: 2, fromMinute: 480, toMinute: 1200, interval: 60, on: true)))
        XCTAssertEqual(T.pad(T.hex("E7 02 05")), VeepooControls.remindRead(5))
        XCTAssertEqual(T.pad(T.hex("FF 55 01 73 40")), VeepooControls.factoryReset)
        XCTAssertEqual(T.pad(T.hex("F2 04")), VeepooControls.powerOff)
        XCTAssertEqual(T.hex("AC 96 2D 01"), VeepooControls.heartAlarmWrite(VeepooHeartAlarm(high: 150, low: 45, on: true)))
        XCTAssertEqual(T.hex("AC DC 1E 00"), VeepooControls.heartAlarmWrite(VeepooHeartAlarm(high: 250, low: 10, on: false)))  // kẹp ngưỡng
        XCTAssertEqual(T.hex("AC 00 00 02"), VeepooControls.heartAlarmRead)
    }

    func testCommandsGatedByFeatures() {
        let f = VeepooFeaturesTests.sample
        let s = VeepooSettings()
        XCTAssertEqual([VeepooControls.userInfo(s)], VeepooControls.commands("goal.steps", f, s))
        XCTAssertEqual([VeepooControls.sedentary(s)], VeepooControls.commands("sedentary.interval", f, s))
        XCTAssertTrue(VeepooControls.commands("remind.drink.enabled", f, s).isEmpty)  // E7 đọc/ghi thẳng vòng tay
        XCTAssertEqual([VeepooControls.raiseToWake(s)], VeepooControls.commands("display.raise.range", f, s))
        XCTAssertTrue(VeepooControls.commands("language", f, s).isEmpty)
    }

    func testEncodeDecode() {
        let s = VeepooSettings().with("goal.steps", .number(12000)).with("sedentary.range", .timeRange(from: 480, to: 1080))
        XCTAssertEqual("goal.steps=12000;sedentary.range.from=480;sedentary.range.to=1080", s.encode())
        XCTAssertEqual(s, VeepooSettings.decode(s.encode()))
        XCTAssertEqual(170, VeepooSettings.decode(nil)["profile.height"])
    }

    func testControls() {
        let f = VeepooFeaturesTests.sample
        let b8 = VeepooCustomSettings(packets: [T.hex("B8 02 01 01 01 00 02 01 01 02 01 01 02 00 01 00 00 05 01 00")])
        var p0 = [UInt8](repeating: 0, count: 20)
        p0[0] = 0xAD; p0[2] = 1; p0[3] = 2
        let ad = VeepooMessageSwitches(page0: p0, page1: nil)
        let c = VeepooControls.controls(f, b8, ad, VeepooSettings())
        let ids = c.map(\.id)
        for id in ["find.start", "find.stop", "device.read", "unit.hour24", "unit.system", "language", "auto.hr", "alert.spo2Low",
                   "sedentary.enabled", "display.raise", "display.brightness", "display.screenOn", "profile.height", "goal.sleep",
                   "notify.pair", "notify.0", "notify.1", "data.reset", "device.findPhoneUi", "device.musicControl"] {
            XCTAssertTrue(ids.contains(id), id)
        }
        // Không hỗ trợ: HA tự động (byte 5 = 0), °F (chưa có trang 1), nhắc E7 (mẫu dùng E1), tắt máy (có màn).
        for id in ["auto.bp", "unit.temperature", "remind.drink.enabled", "drink.enabled", "notify.2", "device.powerOff"] {
            XCTAssertFalse(ids.contains(id), id)
        }
        XCTAssertEqual(.bool(true), c.first { $0.id == "unit.hour24" }?.value)
        XCTAssertEqual(.number(0), c.first { $0.id == "unit.system" }?.value)
        XCTAssertEqual(.bool(true), c.first { $0.id == "auto.hr" }?.value)
        XCTAssertEqual(.bool(false), c.first { $0.id == "notify.1" }?.value)
        XCTAssertEqual(5, c.first { $0.id == "display.brightness" }?.max)
        XCTAssertNotNil(c.first { $0.id == "data.reset" }?.confirm)
        XCTAssertEqual(4, VeepooControls.customToggle("auto.hr")?.index)
        // Ghi B8 theo id Android.
        XCTAssertEqual(0, VeepooControls.b8Change("unit.hour24", .bool(false)).map { $0.page })
        XCTAssertEqual(2, VeepooControls.b8Change("unit.hour24", .bool(false))?.value)
        XCTAssertEqual(2, VeepooControls.b8Change("unit.system", .number(1))?.value)
        XCTAssertEqual(1, VeepooControls.b8Change("unit.temperature", .number(0))?.value)
        XCTAssertEqual(11, VeepooControls.b8Change("auto.bloodComponent", .bool(true))?.index)
        XCTAssertNil(VeepooControls.b8Change("hr24.enabled", .bool(true)))
    }
}
