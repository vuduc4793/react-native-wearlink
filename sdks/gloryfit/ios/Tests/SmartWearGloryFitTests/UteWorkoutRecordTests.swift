import XCTest
import SmartWearCore
@testable import SmartWearGloryFit

/// Cùng dữ liệu với `UteWorkoutRecordTest` Android (dựng theo `BluetoothLeService.java:7340-7556`; chưa có gói thật có GPS).
final class UteWorkoutRecordTests: XCTestCase {
    private func b(_ hex: String) -> [UInt8] { hex.split(separator: " ").map { UInt8($0, radix: 16)! } }
    private func s32(_ v: Int) -> [UInt8] { let u = UInt32(bitPattern: Int32(v)); return [UInt8(u >> 24), UInt8((u >> 16) & 0xFF), UInt8((u >> 8) & 0xFF), UInt8(u & 0xFF)] }
    private func pkt(_ seq: Int, _ payload: ArraySlice<UInt8>) -> [UInt8] { [0xFD, UInt8(seq >> 8), UInt8(seq & 0xFF)] + payload }
    private func fmt1(_ hr: UInt8, _ min: UInt8, _ sec: UInt8, _ cad: UInt8, _ lat: Double, _ lon: Double) -> [UInt8] {
        [hr, min, sec, cad] + s32(Int((lat * 1e6).rounded())) + s32(Int((lon * 1e6).rounded()))
    }

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        return c
    }

    private lazy var seq0 = b("FD 00 00 01 00 05 07 EA 0A 0F 08 1E 00 00 00 00 00 00 07 08")
    private lazy var seq1 = b("FD 00 01 00 0B B8 00 00 00 96 02 32 8C A5 5A 06 1E 05 00 00")
    private lazy var seq2 = b("FD 00 02 00 00 3C 00 02 58 00 03 84 00 00 F0 00 00 00 5F 78")
    private lazy var seq3 = b("FD 00 03 46 05 0A 07 05 01 00 00 00 00 00 00 00 00 00 00 00")

    func testFullRecordWithGpsTrack() {
        let data = fmt1(130, 6, 30, 160, 21.028511, 105.804817) + fmt1(0, 0, 0, 0, 0, 0) + fmt1(142, 6, 5, 168, -33.856784, 151.215297)
        let packets = [
            b("FD FA 00 00 00 00 00 00 00 01"), seq0, seq1, seq2, seq3,
            pkt(4, data[0..<17]), b("FD 01 AA 01"), pkt(5, data[17..<34]), pkt(6, data[34..<36]),
            b("FD FD"),
        ]
        let list = Ute.parseWorkouts(packets, calendar: calendar, endIsTimestamp: true, hasDetail: true)
        XCTAssertEqual(list.count, 1)
        let w = list[0]
        XCTAssertEqual(w.steps, 3000)
        XCTAssertEqual(w.sampleIntervalSeconds, 5)
        XCTAssertEqual(w.heartRateZoneSeconds, [60, 600, 900, 240, 0])
        XCTAssertEqual(w.avgStrideCm, 95)
        XCTAssertEqual(w.maxStrideCm, 120)
        XCTAssertEqual(w.minStrideCm, 70)
        XCTAssertEqual(w.samples.count, 2)
        let a = w.samples[0]
        XCTAssertEqual(a.time, calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 8, minute: 30)))
        XCTAssertEqual(a.heartRate, 130)
        XCTAssertEqual(a.paceSecondsPerKm, 390)
        XCTAssertEqual(a.cadence, 160)
        XCTAssertEqual(a.latitude!, 21.028511, accuracy: 1e-6)
        XCTAssertEqual(a.longitude!, 105.804817, accuracy: 1e-6)
        XCTAssertEqual(w.samples[1].time.timeIntervalSince(a.time), 10)
        XCTAssertEqual(w.samples[1].latitude!, -33.856784, accuracy: 1e-6)
        XCTAssertEqual(w.track.count, 2)
    }

    func testWithoutDetailFlagPayloadIsHeartRate() {
        let w = Ute.parseWorkouts([seq0, seq1, b("FD 00 02 50 00 FF 64"), b("FD FD")], calendar: calendar, endIsTimestamp: true)[0]
        XCTAssertEqual(w.samples.map(\.heartRate), [80, 100])
        XCTAssertEqual(w.samples.map { $0.time.timeIntervalSince(w.start) }, [0, 15])
        XCTAssertNil(w.heartRateZoneSeconds)
        XCTAssertTrue(w.track.isEmpty)
    }

    func testOtherFormats() {
        let t0 = Date(timeIntervalSince1970: 1000)
        let f3 = UteWorkoutRecord.samples(3, [120, 25, 50, 0] + s32(10_500_000) + s32(106_700_000), start: t0, intervalSeconds: 2)
        XCTAssertEqual(f3[0].speedKmh!, 25.5, accuracy: 1e-9)
        XCTAssertEqual(f3[0].latitude!, 10.5, accuracy: 1e-9)
        XCTAssertEqual(UteWorkoutRecord.samples(5, [150, 5, 20, 170] + s32(1) + s32(2), start: t0, intervalSeconds: 1)[0].paceSecondsPerKm, 320)
        XCTAssertEqual(UteWorkoutRecord.samples(6, [100, 6, 40, 150], start: t0, intervalSeconds: 1)[0].paceSecondsPerKm, 400)
        XCTAssertEqual(UteWorkoutRecord.samples(4, [110, 18, 5, 0], start: t0, intervalSeconds: 1)[0].speedKmh!, 18.05, accuracy: 1e-9)
        XCTAssertEqual(UteWorkoutRecord.samples(7, [120, 88, 0, 0], start: t0, intervalSeconds: 1)[0].cadence, 88)
        XCTAssertTrue(UteWorkoutRecord.samples(9, [UInt8](repeating: 0, count: 24), start: t0, intervalSeconds: 1).isEmpty)
        XCTAssertEqual(UteWorkoutRecord.samples(1, [UInt8](repeating: 100, count: 12) + [0, 0, 0, 0, 0], start: t0, intervalSeconds: 1).count, 1)
    }

    func testIntervalOver220() {
        var p = seq1
        p[17] = 225
        XCTAssertEqual(UteWorkoutRecord.intervalSeconds(p), 5)
        p[17] = 0
        XCTAssertNil(UteWorkoutRecord.intervalSeconds(p))
    }

    /// Bản lưu cũ (chưa có `samples`) vẫn đọc được.
    func testDecodesLegacyWorkoutJson() throws {
        let json = #"{"type":1,"name":"Chạy bộ","start":0,"end":60,"activeSeconds":60,"steps":10}"#
        let w = try JSONDecoder().decode(Workout.self, from: Data(json.utf8))
        XCTAssertEqual(w.steps, 10)
        XCTAssertTrue(w.samples.isEmpty)
    }
}
