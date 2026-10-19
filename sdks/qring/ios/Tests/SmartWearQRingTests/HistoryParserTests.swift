import SmartWearCore
import XCTest
@testable import SmartWearQRing

/// Port của sdks/qring/android/src/test/.../protocol/HistoryParserTest.kt (cùng vector hex, đã chạy thật trên R09/DS500).
/// Ví dụ hex lấy từ sdks/qring/docs/03-history-sync.md, múi giờ Việt Nam (UTC+7).
final class HistoryParserTests: XCTestCase {
    private let zone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
    private lazy var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c
    }()
    /// "Bây giờ" cố định ở tương lai để không điểm nào bị coi là tương lai.
    private lazy var parser = HistoryParser(calendar: calendar, now: { Date(timeIntervalSince1970: 2_000_000_000) })

    private func hex(_ s: String) -> [UInt8] { s.split(separator: " ").map { UInt8($0, radix: 16)! } }
    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date { calendar.date(from: DateComponents(year: y, month: m, day: d))! }
    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: mi))!
    }

    func testStepsRequest() {
        XCTAssertEqual(hex("43 00 0F 00 5F 01 00 00 00 00 00 00 00 00 00 B2"), parser.stepsRequest(0).bytes)
        XCTAssertEqual(hex("43 01 0F 00 5F 01 00 00 00 00 00 00 00 00 00 B3"), parser.stepsRequest(1).bytes)
    }

    func testStepsSlotsAndCompletion() {
        let header = Packet.of(0x43, 0xF0, 0x05, 0x01)
        let slot = Packet.of(0x43, 0x26, 0x10, 0x12, 0x20, 0x00, 0x05, 0x23, 0x00, 0xF4, 0x01, 0x72, 0x01)
        let last = Packet.of(0x43, 0x26, 0x10, 0x12, 0x21, 0x04, 0x05, 0x01, 0x00, 0x0A, 0x00, 0x05, 0x00)
        XCTAssertFalse(parser.stepsComplete([header, slot]))
        XCTAssertTrue(parser.stepsComplete([header, slot, last]))

        let points = parser.parseSteps([header, slot, last])
        XCTAssertEqual(2, points.count)
        XCTAssertEqual(at(2026, 10, 12, 8, 0), points[0].timestamp)
        XCTAssertEqual(500, points[0].value)
        XCTAssertEqual(350, points[0].extra["calories"]) // 0x23 = 35 × 10 (calorieNewProtocol)
        XCTAssertEqual(370, points[0].extra["distance"])
        XCTAssertEqual(at(2026, 10, 12, 8, 15), points[1].timestamp)
    }

    func testStepsNoData() {
        let none = [Packet.of(0x43, 0xFF)]
        XCTAssertTrue(parser.stepsComplete(none))
        XCTAssertTrue(parser.parseSteps(none).isEmpty)
        XCTAssertFalse(parser.stepsComplete([]))
    }

    func testTodayTotalsBigEndian() {
        let p = Packet.of(0x48, 0x00, 0x0B, 0xB8, 0, 0, 0, 0x01, 0x86, 0xA0, 0x00, 0x07, 0xD0, 0x00, 0x2D)
        let t = parser.parseTodayTotals(p)
        XCTAssertEqual(3000, t.steps)
        XCTAssertEqual(100_000, t.calories)
        XCTAssertEqual(2000, t.distanceMeters)
        XCTAssertEqual(45, t.activeMinutes)
    }

    func testHeartRateRequestUsesLocalWallClock() {
        XCTAssertEqual(
            hex("15 80 74 CD 6A 00 00 00 00 00 00 00 00 00 00 40"),
            parser.heartRateRequest(at(2026, 10, 13, 15, 42)).bytes
        )
    }

    func testHeartRateSeries() {
        let header = Packet.of(0x15, 0x00, 0x03, 0x05)
        let first = Packet.of(0x15, 0x01, 0x80, 0x74, 0xCD, 0x6A, 0, 0, 0, 0, 0, 0x3C, 0x3E, 0x40, 0x3B)
        let second = Packet.of(0x15, 0x02, 0x3A, 0x3A, 0x3A, 0x3A, 0x3A, 0x3A, 0x3A, 0x3A, 0x3A, 0x3A, 0x3A, 0x3A, 0x3A)
        XCTAssertFalse(parser.heartRateComplete([header, first]))
        XCTAssertTrue(parser.heartRateComplete([header, first, second]))

        let points = parser.parseHeartRate([header, first, second], day: day(2026, 10, 12))
        XCTAssertEqual(at(2026, 10, 12, 0, 25), points.first?.timestamp)
        XCTAssertEqual(60, points.first?.value)
        XCTAssertEqual(4 + 13, points.count)
        XCTAssertEqual(at(2026, 10, 12, 0, 45), points[4].timestamp) // giá trị thứ 9 (gói 2) = 00:45
        XCTAssertEqual(58, points[4].value)
    }

    func testFuturePointsDropped() {
        let header = Packet.of(0x15, 0x00, 0x02, 0x05)
        let first = Packet.of(0x15, 0x01, 0, 0, 0, 0, 0x3C, 0x3E, 0x40)
        let early = HistoryParser(calendar: calendar, now: { self.at(2026, 10, 12, 0, 6) })
        XCTAssertEqual(2, early.parseHeartRate([header, first], day: day(2026, 10, 12)).count) // 00:00 và 00:05
    }

    func testHrvSeries() {
        let header = Packet.of(0x39, 0x00, 0x02, 0x1E)
        let first = Packet.of(0x39, 0x01, 0x01, 0x2A, 0x30, 0x2D)
        let points = parser.parseDaily([header, first], day: day(2026, 10, 12))
        XCTAssertTrue(parser.dailyComplete([header, first]))
        XCTAssertEqual([42, 48, 45], points.map(\.value))
        XCTAssertEqual(at(2026, 10, 12, 0, 30), points[1].timestamp)
    }

    func testSleepNewProtocolCrossesMidnight() {
        let payload = hex("01 00 16 64 05 A4 01 02 3C 03 5A 02 3C 04 1E 02 5A 03 3C 04 28 05 0A 02 28")
        XCTAssertEqual(0xFF91, BigDataFrame.crc16Modbus(payload))

        let sessions = parser.parseSleep(payload, today: day(2026, 10, 13))
        XCTAssertEqual(1, sessions.count)
        let s = sessions[0]
        XCTAssertEqual(at(2026, 10, 13, 7, 0), s.end)
        XCTAssertEqual(at(2026, 10, 12, 23, 0), s.start)
        XCTAssertEqual(9, s.segments.count)
        XCTAssertEqual(.light, s.segments[0].stage)
        XCTAssertEqual(60 + 60 + 90 + 40, s.minutes(.light))
        XCTAssertEqual(150, s.minutes(.deep))
        XCTAssertEqual(70, s.minutes(.rem))
        XCTAssertEqual(10, s.minutes(.awake))
        XCTAssertEqual(470, s.asleepMinutes)
        XCTAssertFalse(s.nap)
    }

    /// Khung 0x3E thật đọc từ DS500 ngày 2026-10-13.
    func testNapFrameFromDs500() {
        let payload = hex("02 06 08 FE 02 27 03 02 1F 02 0A 05 08 F5 02 26 03 02 17 02 1A")
        let naps = parser.parseSleep(payload, today: day(2026, 10, 13), nap: true)
        XCTAssertEqual(2, naps.count)
        XCTAssertTrue(naps[0].nap)
        XCTAssertEqual(at(2026, 10, 7, 13, 27), naps[0].end)
        XCTAssertEqual(at(2026, 10, 7, 12, 46), naps[0].start)
        XCTAssertEqual(41, naps[0].minutes(.light))
        XCTAssertEqual(49, naps[1].asleepMinutes)
    }

    func testSleepTruncatedPayload() {
        XCTAssertTrue(parser.parseSleep([], today: day(2026, 10, 13)).isEmpty)
        XCTAssertTrue(parser.parseSleep(hex("02 00 16 64"), today: day(2026, 10, 13)).isEmpty)
    }

    func testTemperaturePage() {
        let page = parser.parseIntervalPage(hex("00 1E 01 00 3C 0E 4E 0E 00 00"), twoByteValues: true)!
        XCTAssertEqual(30, page.interval)
        XCTAssertEqual([36.44, 36.62, 0.0], page.values)
        let points = parser.intervalPoints([page], today: day(2026, 10, 12))
        XCTAssertEqual(2, points.count)
        XCTAssertEqual(at(2026, 10, 12, 0, 30), points[1].timestamp)
    }

    func testSpo2HourlyPairs() {
        var record = [UInt8](repeating: 0, count: 49)
        record[0] = 1 // hôm qua
        record[1] = 98; record[2] = 95 // 00h
        record[3] = 97; record[4] = 94 // 01h
        let points = parser.parseSpo2(record, today: day(2026, 10, 13))
        XCTAssertEqual(2, points.count)
        XCTAssertEqual(at(2026, 10, 12, 1, 0), points[1].timestamp)
        XCTAssertEqual(97, points[1].value)
        XCTAssertEqual(94, points[1].extra["min"])
    }

    func testSleepAndSpo2Requests() {
        XCTAssertEqual(hex("BC 27 02 00") , Array(parser.sleepRequest().encode().prefix(4)))
        XCTAssertEqual([0xFF, 0x01], parser.sleepRequest().payload)
        XCTAssertEqual([0xFF], parser.spo2Request().payload)
        XCTAssertEqual(0x2A, parser.spo2Request().command)
    }

    /// Ví dụ 03-history-sync.md §5.5: `14 08 EC CD 6A 4E 78` = 2026-10-13 08:30 giờ địa phương, DBP 78, SBP 120.
    func testBloodPressureManualRecords() {
        XCTAssertEqual(hex("14 00 00 00 00 00 32 00 00 00 00 00 00 00 00 46"), parser.bloodPressureRequest().bytes)
        let record = Packet.parse(hex("14 08 EC CD 6A 4E 78 00 00 00 00 00 00 00 00 05"))!
        let end = Packet.of(0x14, 0xFF, 0xFF, 0xFF, 0xFF)
        XCTAssertFalse(parser.bloodPressureComplete([record]))
        XCTAssertTrue(parser.bloodPressureComplete([record, end]))
        let points = parser.parseBloodPressure([record, end])
        XCTAssertEqual(1, points.count)
        XCTAssertEqual(at(2026, 10, 13, 8, 30), points[0].timestamp)
        XCTAssertEqual(120, points[0].value)
        XCTAssertEqual(78, points[0].extra["diastolic"])
    }
}
