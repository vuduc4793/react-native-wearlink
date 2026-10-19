import SmartWearCore
import XCTest
@testable import SmartWearGloryFit

/// Lịch sử UTE: vector port từ `UteTest.kt` (01-protocol.md §7) + định dạng `EB 02`, `31/32`, `EC`, `C8` và chọn lệnh
/// theo bit (docs/feature-matrix.md việc 9). Gói `31/32`, `EC`, `EB 02` dựng theo mã giải (chưa có gói thật).
final class UteHistoryTests: XCTestCase {
    private let zone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
    private lazy var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c
    }()

    private func hex(_ s: String) -> [UInt8] { s.split(separator: " ").map { UInt8($0, radix: 16)! } }
    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: mi))!
    }

    // Bảng tính năng thật (01-protocol §10/§11, 08-hardware §3.2): Y25 có CyWee (34F1 b19.5), HT43 không.
    private lazy var y25 = Ute.Features.parse(
        main: hex("08 88 6C 2A 01 24 39 43 75 6E DF FE D9 21 00 5D 78 5B A0 DC"),
        ble5: hex("00 F4 00 00 00 00 00 00 00 00 00 05 00 00 40 02 00 00 04 20")
    )
    private lazy var ht43 = Ute.Features.parse(
        main: hex("08 88 6C 2A 01 24 39 43 75 6E DF FE D9 21 00 5D 78 4B A1 DC"),
        ble5: hex("00 F4 00 00 00 00 00 00 00 00 00 05 00 00 40 00 00 00 04 00")
    )

    // MARK: - Chọn lệnh

    func testFeatureBits() {
        XCTAssertTrue(y25.resolveSleep)
        XCTAssertTrue(y25.cywee)
        XCTAssertTrue(ht43.resolveSleep)
        XCTAssertFalse(ht43.cywee)
        XCTAssertFalse(Ute.Features().resolveSleep)
    }

    func testPlanY25UsesCyweeThenOldFallback() {
        let plan = Ute.SyncPlan(features: y25, capabilities: y25.capabilities())
        XCTAssertEqual([.stepsCywee, .stepsHourly], plan.steps)
        XCTAssertEqual([.sleepCywee, .sleepResolve, .sleepRoll], plan.sleep)
        XCTAssertEqual(.heartRate24h, plan.heartRate)
        XCTAssertEqual(.spo2, plan.spo2)
        XCTAssertEqual(.bloodPressure, plan.bloodPressure)
    }

    func testPlanHt43UsesResolveSleep() {
        let plan = Ute.SyncPlan(features: ht43, capabilities: ht43.capabilities())
        XCTAssertEqual([.stepsHourly], plan.steps)
        XCTAssertEqual([.sleepResolve, .sleepRoll], plan.sleep)
        XCTAssertNil(plan.bloodPressure) // HT43 không có huyết áp
    }

    func testPlanOldWatchKeepsB2B3() {
        let f = Ute.Features(groups: [1: 0x080000, 2: 0x004000])
        let plan = Ute.SyncPlan(features: f, capabilities: f.capabilities())
        XCTAssertEqual([.stepsHourly], plan.steps)
        XCTAssertEqual([.sleepRoll], plan.sleep)
        XCTAssertEqual(.heartRate24h, plan.heartRate)
        let noSleep = Ute.Features(groups: [4: 0x008000])
        XCTAssertEqual([], Ute.SyncPlan(features: noSleep, capabilities: noSleep.capabilities()).sleep)
    }

    func testCommandBytesAndChannels() {
        XCTAssertEqual(hex("B2 FA"), Ute.SyncCommand.stepsHourly.bytes)
        XCTAssertEqual(hex("EB 02 FA"), Ute.SyncCommand.stepsCywee.bytes)
        XCTAssertEqual(hex("31 01"), Ute.SyncCommand.sleepResolve.bytes)
        XCTAssertEqual(hex("EC 01"), Ute.SyncCommand.sleepCywee.bytes)
        XCTAssertEqual(hex("C8 FA"), Ute.SyncCommand.bloodPressure.bytes)
        XCTAssertTrue(Ute.SyncCommand.stepsCywee.usesBle5)
        XCTAssertFalse(Ute.SyncCommand.sleepCywee.usesBle5) // `EC 01` ghi 33F1 (`writeChara`)
        XCTAssertEqual("EB 02 FA", Ute.SyncCommand.stepsCywee.hex)
    }

    func testStreamMatchAndEnd() {
        let eb = Ute.SyncCommand.stepsCywee
        XCTAssertTrue(eb.matches(hex("EB 02 07 EA 0A 0D 08 03 E8")))
        XCTAssertFalse(eb.matches(hex("EB 01 07 EA 0A 0D 08 03 E8"))) // bước realtime
        XCTAssertTrue(eb.isEnd(hex("EB 02 FD 00")))
        XCTAssertFalse(eb.isEnd(hex("EB 02 07 EA")))

        let r = Ute.SyncCommand.sleepResolve
        XCTAssertTrue(r.matches(hex("31 01 07 EA 0A 0E 03")))
        XCTAssertTrue(r.matches(hex("32 17 00 02 00 00 3C")))
        XCTAssertFalse(r.matches(hex("31 AB 01"))) // báo thức ngủ, không phải luồng
        XCTAssertTrue(r.isEnd(hex("31 02")))
        XCTAssertFalse(r.dedupe)

        let ec = Ute.SyncCommand.sleepCywee
        XCTAssertTrue(ec.matches(hex("EC 02 16 1E")))
        XCTAssertTrue(ec.isEnd(hex("EC 03")))
        XCTAssertFalse(ec.isEnd(hex("EC 02 16 1E")))

        XCTAssertTrue(Ute.SyncCommand.spo2.isEnd(hex("34 FA FD E7")))
        XCTAssertTrue(Ute.SyncCommand.bloodPressure.isEnd(hex("C8 FD")))
        XCTAssertTrue(Ute.SyncCommand.heartRate24h.matches(hex("F7 07 EA 0A 0D 12")))
    }

    // MARK: - Bản ghi (port UteTest.kt)

    func testStepsHourly() {
        let points = Ute.parseSteps([hex("B2 07 EA 0A 0D 08 03 E8"), hex("B2 FD")], calendar: cal)
        XCTAssertEqual(1, points.count)
        XCTAssertEqual(at(2026, 10, 13, 8, 0), points[0].timestamp)
        XCTAssertEqual(1000, points[0].value)
    }

    func testCyweeSteps() {
        // `EB 02 YYYY MM DD HH sH sL dH dL c c c`: 1000 bước, 750 m, 40000 cal (40 kcal).
        let points = Ute.parseCyweeSteps(
            [hex("EB 02 07 EA 0A 0D 08 03 E8 02 EE 00 9C 40"), hex("EB 02 00 00 00 00 00 00 05"), hex("EB 02 FD 00")], calendar: cal
        )
        XCTAssertEqual(1, points.count) // năm 0 bị bỏ như app
        XCTAssertEqual(at(2026, 10, 13, 8, 0), points[0].timestamp)
        XCTAssertEqual(1000, points[0].value)
        XCTAssertEqual(750, points[0].extra["distance"])
        XCTAssertEqual(40000, points[0].extra["calories"])
    }

    func testHeartRateSingle() {
        let points = Ute.parseHeartRate([hex("E6 07 EA 0A 0D 0E 1E 48")], calendar: cal)
        XCTAssertEqual(at(2026, 10, 13, 14, 30), points[0].timestamp)
        XCTAssertEqual(72, points[0].value)
    }

    func testHeartRate24hCells() {
        // HH = 15: ô byte 6 ở 15:00 − 110 phút = 13:10, ô byte 17 ở 15:00.
        let p = hex("F7 07 EA 0A 0D 0F 46 48 4A 00 00 00 00 00 00 00 00 50")
        let points = Ute.parseHeartRate24h([p], calendar: cal)
        XCTAssertEqual([70, 72, 74, 80], points.map(\.value))
        XCTAssertEqual(at(2026, 10, 13, 13, 10), points[0].timestamp)
        XCTAssertEqual(at(2026, 10, 13, 15, 0), points[3].timestamp)
    }

    func testHeartRate24hFromY25() {
        // Gói thật (01-protocol §10): HH = 18, ô byte 14 = 17:30 → 83 bpm.
        let points = Ute.parseHeartRate24h([hex("F7 07 EA 0A 0D 12 FF FF FF FF FF FF FF FF 53 FF FF FF")], calendar: cal)
        XCTAssertEqual(1, points.count)
        XCTAssertEqual(at(2026, 10, 13, 17, 30), points[0].timestamp)
        XCTAssertEqual(83, points[0].value)
    }

    func testSpo2Cells() {
        let p = hex("34 FA 07 EA 0A 0D 0F 00 62 63 61 62 FF FF FF FF FF FF FF FF")
        let points = Ute.parseSpo2([p, hex("34 FA FD E7")], calendar: cal)
        XCTAssertEqual([98, 99, 97, 98], points.map(\.value))
        XCTAssertEqual(at(2026, 10, 13, 13, 10), points[0].timestamp) // 15:00 − 11×10 phút
    }

    func testBloodPressure() {
        let points = Ute.parseBloodPressure([hex("C8 07 EA 0A 0D 08 1E 78 4E"), hex("C8 07 EA 0A 0D 09 00 00 00"), hex("C8 FD")], calendar: cal)
        XCTAssertEqual(1, points.count) // 0/0 bị bỏ
        XCTAssertEqual(at(2026, 10, 13, 8, 30), points[0].timestamp)
        XCTAssertEqual(120, points[0].value)
        XCTAssertEqual(78, points[0].extra["diastolic"])
    }

    func testSleepRollCounts() {
        let packets = [
            hex("B3 07 EA 0A 0D 17 1E 00 05"), // 23:30 roll 5 → nông
            hex("B3 07 EA 0A 0E 01 00 00 02"), // 01:00 roll 2 → sâu
            hex("B3 07 EA 0A 0E 03 00 00 2A"), // 03:00 kết thúc (mốc cách nhau ≤ 2 giờ)
            hex("B3 FD 2F"),
        ]
        let sessions = Ute.parseSleep(packets, calendar: cal)
        XCTAssertEqual(1, sessions.count)
        XCTAssertEqual(at(2026, 10, 13, 23, 30), sessions[0].start)
        XCTAssertEqual(at(2026, 10, 14, 3, 0), sessions[0].end)
        XCTAssertEqual(90, sessions[0].minutes(.light))
        XCTAssertEqual(120, sessions[0].minutes(.deep))
    }

    func testSleepHourlyFormat() {
        // 14 byte `B3 YYYY MM DD hh (m, r)×4`, FF FF = ô trống.
        let p = hex("B3 07 EA 0A 0E 01 00 02 1E 05 FF FF FF FF")
        let sessions = Ute.parseSleep([p], calendar: cal, hourlyFormat: true)
        XCTAssertEqual(1, sessions.count)
        XCTAssertEqual(at(2026, 10, 14, 1, 0), sessions[0].start)
        XCTAssertEqual(30, sessions[0].minutes(.deep))
    }

    // MARK: - Ngủ do đồng hồ tính (`31 01` / `EC 01`)

    func testResolveSleepAcrossMidnightAndSplitPackets() {
        // Ngày 2026-10-14: 23:00 nông 60 phút, 00:00 sâu 90, 01:30 thức 10, 01:40 REM 50. Đoạn thứ 3 bị cắt qua 2 gói `32`.
        let packets = [
            hex("31 01 07 EA 0A 0E 04"),
            hex("32 17 00 02 00 00 3C 00 00 01 00 00 5A 01 1E"),
            hex("32 03 00 00 0A 01 28 04 00 00 32"),
        ]
        let days = Ute.sleepDays(packets, cywee: false)
        XCTAssertEqual(1, days.count)
        XCTAssertEqual(4, days[0].sectionCount)
        XCTAssertEqual(4, days[0].declaredCount)
        let sessions = Ute.parseSleepDays(days, calendar: cal)
        XCTAssertEqual(1, sessions.count)
        let s = sessions[0]
        XCTAssertEqual(at(2026, 10, 13, 23, 0), s.start) // từ 20:00 trở đi ⇒ tối hôm trước
        XCTAssertEqual(at(2026, 10, 14, 2, 30), s.end)
        XCTAssertEqual(60, s.minutes(.light))
        XCTAssertEqual(90, s.minutes(.deep))
        XCTAssertEqual(10, s.minutes(.awake))
        XCTAssertEqual(50, s.minutes(.rem))
        XCTAssertEqual(200, s.asleepMinutes)
        XCTAssertFalse(s.nap)
    }

    func testResolveSleepStartingAfterMidnightStaysOnDay() {
        let days = Ute.sleepDays([hex("31 01 07 EA 0A 0E 01"), hex("32 01 0F 01 00 01 2C")], cywee: false)
        let s = Ute.parseSleepDays(days, calendar: cal)
        XCTAssertEqual(at(2026, 10, 14, 1, 15), s[0].start)
        XCTAssertEqual(300, s[0].minutes(.deep))
    }

    func testCyweeSleepSectionsAndNap() {
        // `EC 02` bỏ 2 byte đầu. 22:30 nông 120; đoạn FF = hết phiên; 13:00 REM 30 (ngủ trưa hôm sau).
        let packets = [
            hex("EC 01 07 EA 0A 0E 03"),
            hex("EC 02 16 1E 02 00 00 78 06 1E FF 00 00 00"),
            hex("EC 02 0D 00 04 00 00 1E"),
        ]
        let days = Ute.sleepDays(packets, cywee: true)
        XCTAssertEqual(3, days[0].sectionCount)
        let sessions = Ute.parseSleepDays(days, calendar: cal)
        XCTAssertEqual(2, sessions.count)
        XCTAssertEqual(at(2026, 10, 13, 22, 30), sessions[0].start)
        XCTAssertEqual(at(2026, 10, 14, 0, 30), sessions[0].end)
        XCTAssertEqual(120, sessions[0].minutes(.light))
        XCTAssertFalse(sessions[0].nap)
        XCTAssertEqual(at(2026, 10, 14, 13, 0), sessions[1].start)
        XCTAssertEqual(30, sessions[1].minutes(.rem))
        XCTAssertTrue(sessions[1].nap)
    }

    func testSleepDaysIgnoresDataBeforeStartAndBadSections() {
        // Gói `32` trước `31 01` bị bỏ; đoạn giờ 25 bị bỏ; hai ngày tách riêng.
        let packets = [
            hex("32 17 00 02 00 00 3C"),
            hex("31 01 07 EA 0A 0D 01"),
            hex("32 19 00 02 00 00 3C 02 00 01 00 00 3C"),
            hex("31 01 07 EA 0A 0E 01"),
            hex("32 03 00 02 00 00 1E"),
        ]
        let days = Ute.sleepDays(packets, cywee: false)
        XCTAssertEqual(2, days.count)
        let sessions = Ute.parseSleepDays(days, calendar: cal)
        XCTAssertEqual(2, sessions.count)
        XCTAssertEqual(at(2026, 10, 13, 2, 0), sessions[0].start)
        XCTAssertEqual(at(2026, 10, 14, 3, 0), sessions[1].start)
        XCTAssertEqual(.unknown, Ute.sleepStage(0))
    }

    func testTodayTotalsFromRealY25Packets() {
        // Gói thật Y25 16/10/2026: giờ 15 xong (`EB 02`), giờ 16 đang chạy (`EB 01`).
        let hourly = Ute.parseCyweeSteps([hex("EB 02 07 EA 0A 10 0F 00 1C 00 13 00 07 D6"), hex("EB 02 FD 26")], calendar: cal)
        let now = at(2026, 10, 16, 16, 30)
        let t = Ute.todayTotals(hourly: hourly, current: hex("EB 01 07 EA 0A 10 10 00 0A 00 07 00 03 E8"), calendar: cal, now: now)
        XCTAssertEqual(ActivityTotals(steps: 38, calories: 3000, distanceMeters: 26), t) // 2006 → 2000 cal (0,1 kcal/giờ như app)
        // Giờ đang chạy đã có trong EB 02 thì không cộng lại; hôm qua thì bỏ.
        let same = Ute.todayTotals(hourly: hourly, current: hex("EB 01 07 EA 0A 10 0F 00 1C 00 13 00 07 D6"), calendar: cal, now: now)
        XCTAssertEqual(28, same?.steps)
        XCTAssertNil(Ute.todayTotals(hourly: hourly, current: nil, calendar: cal, now: at(2026, 10, 17, 8, 0)))
    }

    func testCaloriesFollowOfficialAppFormula() {
        // Gói thật Y25 19/10/2026: giờ 19 xong 132 bước / 86 m / 0x00253D = 9533 (kcal×1000); giờ 21 đang chạy chưa có bước.
        // GloryFit/Pro không tính lại từ bước + hồ sơ: kcal = round1(raw / 1000) mỗi giờ (`SWAlgorithmUtil.java:47-49`) ⇒ 9,5 kcal.
        let hourly = Ute.parseCyweeSteps([hex("EB 02 07 EA 0A 13 13 00 84 00 56 00 25 3D"), hex("EB 02 FD 26")], calendar: cal)
        XCTAssertEqual(1, hourly.count)
        XCTAssertEqual(at(2026, 10, 19, 19, 0), hourly[0].timestamp)
        XCTAssertEqual(132, hourly[0].value)
        XCTAssertEqual(86, hourly[0].extra["distance"])
        XCTAssertEqual(9500, hourly[0].extra["calories"])
        let t = Ute.todayTotals(hourly: hourly, current: hex("EB 01 07 EA 0A 13 15 00 00 00 00 00 00 00"), calendar: cal,
                                now: at(2026, 10, 19, 21, 10))
        XCTAssertEqual(ActivityTotals(steps: 132, calories: 9500, distanceMeters: 86), t)
        // Làm tròn nửa lên như `TempratureUtils.roundingToFloat(1, …)`.
        XCTAssertEqual([0, 0, 100, 3400, 3500, 9500], [0, 49, 50, 3449, 3450, 9533].map(Ute.cyweeCalories))
    }
}
