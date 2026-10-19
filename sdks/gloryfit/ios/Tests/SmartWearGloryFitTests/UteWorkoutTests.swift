import XCTest
@testable import SmartWearGloryFit

/// Cùng dữ liệu mẫu với `UteTest.parsesWorkout` Android.
final class UteWorkoutTests: XCTestCase {
    private func b(_ hex: String) -> [UInt8] { hex.split(separator: " ").map { UInt8($0, radix: 16)! } }

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        return c
    }

    func testParsesWorkout() {
        let packets = [
            b("FD FA 00 00 00 00 00 00 00 01"),
            // gói 0: chạy bộ, 15/10/2026 08:30:00, tập hiệu quả 1800 s
            b("FD 00 00 01 00 05 07 EA 0A 0F 08 1E 00 00 00 00 00 00 07 08"),
            // gói 1: 3000 bước, 150 kcal, 2,50 km, HR 140/165/90, pace 6'30"
            b("FD 00 01 00 0B B8 00 00 00 96 02 32 8C A5 5A 06 1E 00 00 00"),
            b("FD 00 05 50 51 52 53 54 55 56 57 58 59 5A 5B 5C 5D 5E 5F 60"),
            b("FD FD"),
        ]
        let list = Ute.parseWorkouts(packets, calendar: calendar, endIsTimestamp: true)
        XCTAssertEqual(list.count, 1)
        let w = list[0]
        XCTAssertEqual(w.type, 1)
        XCTAssertEqual(w.name, "Chạy bộ")
        XCTAssertEqual(w.start, calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 8, minute: 30)))
        XCTAssertEqual(w.activeSeconds, 1800)
        XCTAssertEqual(w.end, w.start.addingTimeInterval(1800))
        XCTAssertEqual(w.steps, 3000)
        XCTAssertEqual(w.calories, 150)
        XCTAssertEqual(w.distanceMeters, 2500)
        XCTAssertEqual(w.avgHeartRate, 140)
        XCTAssertEqual(w.maxHeartRate, 165)
        XCTAssertEqual(w.paceSecondsPerKm, 390)
        XCTAssertEqual(Ute.workoutCount(packets[0]), 1)
    }

    func testNoWorkoutsWhenCountZero() {
        let zero = b("FD FA 00 00 00 00 00 00 00 00")
        XCTAssertEqual(Ute.workoutCount(zero), 0)
        XCTAssertTrue(Ute.parseWorkouts([zero], calendar: calendar, endIsTimestamp: true).isEmpty)
    }

    func testUnknownSportName() {
        XCTAssertEqual(Ute.sportName(250), "Môn thể thao #250")
    }
}
