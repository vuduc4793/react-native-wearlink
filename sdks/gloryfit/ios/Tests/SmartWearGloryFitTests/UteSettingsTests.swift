import XCTest
import SmartWearCore
@testable import SmartWearGloryFit

/// Cùng dữ liệu mẫu với `UteSettingsTest` Android.
final class UteSettingsTests: XCTestCase {
    private func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }

    /// Bảng tính năng 33F1 kiểu Y25 (bit theo docs/feature-matrix.md phụ lục A).
    private let y25 = Ute.Features(groups: [1: 0x4BA0CC, 2: 0x00547C, 3: 0x00D921, 4: 0x75EEDF, 5: 0x200962], maxPacketLength: 244)

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        return c
    }
    private var today: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 9))! }

    func testDefaultsMatchLegacyUserInfo() {
        XCTAssertEqual(UteControls.userInfo(UteSettings()), Ute.userInfo())
        XCTAssertEqual(hex(UteControls.units(UteSettings())), "A0 01 01")
    }

    func testEncodeRoundTrip() {
        let s = UteSettings()
            .with("goal.steps", .number(10_000))
            .with("dnd.range", .timeRange(from: 23 * 60, to: 6 * 60 + 30))
            .with("display.raise", .bool(false))
        let back = UteSettings.decode(s.encode())
        XCTAssertEqual(back["goal.steps"], 10_000)
        XCTAssertEqual(back["dnd.range.from"], 23 * 60)
        XCTAssertEqual(back["dnd.range.to"], 390)
        XCTAssertFalse(back.on("display.raise"))
        XCTAssertEqual(back["profile.height"], 170)
    }

    func testProfileAndAlertsGoToA9() {
        let s = UteSettings()
            .with("profile.height", .number(175))
            .with("hrHigh.enabled", .bool(true))
            .with("hrHigh.value", .number(150))
            .with("hrLow.enabled", .bool(true))
            .with("unit.fahrenheit", .bool(true))
            .with("profile.gender", .number(1))
        let cmds = UteControls.commands("profile.height", y25, s)
        XCTAssertEqual(cmds.map(hex), ["A9 00 AF 00 41 05 00 00 1F 40 01 96 00 1E 02 00 02 02 2D"])
    }

    func testReminders() {
        let s = UteSettings().with("sedentary.enabled", .bool(true)).with("sedentary.interval", .number(45))
        XCTAssertEqual(UteControls.commands("sedentary.interval", y25, s).map(hex), ["D3 01 2D 02 03 01 00 09 00 12 00 01"])
        let noRange = Ute.Features(groups: [1: 0x010000])
        XCTAssertEqual(UteControls.commands("sedentary.enabled", noRange, s).map(hex), ["D3 01 2D 02 03 01 00"])
        let dnd = UteSettings().with("dnd.scheduled", .bool(true)).with("dnd.vibration", .bool(false))
        XCTAssertEqual(UteControls.commands("dnd.scheduled", y25, dnd).map(hex), ["D7 04 16 00 07 00 01"])
    }

    func testGoals() {
        let s = UteSettings().with("goal.steps", .number(12_000)).with("goal.distance", .number(5))
        let steps = UteControls.commands("goal.steps", y25, s)
        XCTAssertEqual(steps.count, 2)
        XCTAssertEqual(hex(steps[1]), "3F 04 01 00 00 2E E0")
        XCTAssertEqual(UteControls.commands("goal.calories", y25, s).map(hex), ["3F 03 01 01 2C"])
        XCTAssertEqual(UteControls.commands("goal.distance", y25, s).map(hex), ["3F 05 01 00 00 13 88"])
    }

    func testHeartRateAndMisc() {
        XCTAssertEqual(UteControls.commands("hr24.enabled", y25, UteSettings().with("hr24.enabled", .bool(false))).map(hex), ["F7 02"])
        XCTAssertEqual(UteControls.commands("hr24.interval", y25, UteSettings().with("hr24.interval", .number(10))).map(hex), ["F7 01", "F7 09 01 00 0A"])
        XCTAssertEqual(UteControls.commands("findPhone.enabled", y25, UteSettings().with("findPhone.enabled", .bool(false))).map(hex), ["D1 0A 00"])
        XCTAssertEqual(UteControls.commands("language", y25, UteSettings().with("language", .number(1))).map(hex), ["AF AB 63"])
        XCTAssertTrue(UteControls.commands("language", y25, UteSettings()).isEmpty)
        XCTAssertEqual(UteControls.commands("unit.hour12", y25, UteSettings().with("unit.hour12", .bool(true))).map(hex), ["A0 01 02"])
    }

    func testPeriodStoresAbsoluteDate() {
        let s = UteSettings().with("period.enabled", .bool(true)).with("period.daysAgo", .number(3), today: today, calendar: calendar)
        XCTAssertEqual(UteControls.commands("period.daysAgo", y25, s, today: today, calendar: calendar).map(hex), ["29 01 07 EA 0A 0C 05 1C"])
        // Cùng epoch day với Android (LocalDate 2026-10-12).
        XCTAssertEqual(s.values["period.start"], 20_738)
        let later = calendar.date(byAdding: .day, value: 2, to: today)!
        let c = UteControls.controls(y25, s, today: later, calendar: calendar).first { $0.id == "period.daysAgo" }
        XCTAssertEqual(c?.value, .number(5))
    }

    func testControlsFollowFeatureFlags() {
        let ids = Set(UteControls.controls(y25, UteSettings(), today: today, calendar: calendar).map(\.id))
        for id in ["find.start", "sedentary.range", "dnd.scheduled", "hrLow.enabled", "period.enabled"] { XCTAssertTrue(ids.contains(id), id) }
        XCTAssertFalse(ids.contains("drink.enabled"))
        // Y25 có F5 0x40 ⇒ có SpO2 tự động như GloryFitPro (`RkSupportUtils.isSupOxygenSetting`).
        XCTAssertTrue(ids.contains("spo2Auto.enabled"))
        let bare = Set(UteControls.controls(Ute.Features(), UteSettings()).map(\.id))
        XCTAssertFalse(bare.contains("dnd.scheduled"))
        XCTAssertFalse(bare.contains("hr24.enabled"))
        let interval = UteControls.controls(y25, UteSettings()).first { $0.id == "sedentary.interval" }
        XCTAssertEqual(interval?.enabled, false)
        XCTAssertTrue(y25.capabilities().contains(.menstruation))
    }

    func testFindWatch() {
        XCTAssertEqual(hex(UteControls.findWatch), "AB 00 00 00 01 02 07 01")
    }

    func testWatchLanguagesFromRealY25AfAa() {
        // Gói thật Y25 16/10/2026: đang English (02); hỗ trợ CN EN JA DE ES IT PT PL RU NL + VI (m5 bit 2 = 99).
        let l = Ute.parseLanguages("AF AA 02 00 00 00 00 04 00 00 00 00 00 00 00 00 00 00 71 BB".split(separator: " ").map { UInt8($0, radix: 16)! })!
        XCTAssertEqual(2, l.current)
        let s = UteSettings().withWatchLanguages(current: l.current, masks: l.masks)
        XCTAssertEqual(Set([1, 2, 4, 5, 6, 8, 9, 13, 14, 15, 99]), s.watchLanguages)
        XCTAssertEqual(["Giữ nguyên", "Tiếng Việt", "English", "中文", "日本語", "Deutsch", "Español", "Italiano",
                        "Português", "Polski", "Русский", "Nederlands"], s.languageChoices.map { $0.name })
        XCTAssertEqual(2, s["language"]) // trỏ English
        let vi = s.with("language", ControlValue.number(1))
        XCTAssertEqual(UteControls.commands("language", y25, vi).map(hex), ["AF AB 63"])
    }
}
