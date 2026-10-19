import SmartWearCore
import XCTest
@testable import SmartWearVeepoo

final class VeepooHistoryTests: XCTestCase {
    let cal = T.calendar
    let now = T.date(2026, 10, 19, 15, 0)

    // MARK: Bước hôm nay

    func testCurrentSteps() {
        XCTAssertEqual(1234, VeepooHistory.parseCurrentSteps(T.hex("A8 000004D2 00")))
        XCTAssertEqual(0, VeepooHistory.parseCurrentSteps(T.hex("A8 FFFFFFFF 00")))
        XCTAssertNil(VeepooHistory.parseCurrentSteps(T.hex("A8 000004D2 01")))
        XCTAssertNil(VeepooHistory.parseCurrentSteps(T.hex("A8 0000")))
        let t = VeepooHistory.parseSportModelSteps(T.pad(T.hex("D8 00 D2040000 E8030000 7B000000")))
        XCTAssertEqual(ActivityTotals(steps: 1234, calories: 12300, distanceMeters: 1000), t)
    }

    func testEstimate() {
        XCTAssertEqual(0.789, VeepooHistory.stepLength(heightCm: 170))
        XCTAssertEqual(0.72, VeepooHistory.stepLength(heightCm: 155))  // 155×13/28 = 71,96 cm
        XCTAssertEqual(0.714, VeepooHistory.stepLength(heightCm: 150))
        XCTAssertEqual(0.814, VeepooHistory.stepLength(heightCm: 180))
        let e = VeepooHistory.estimate(steps: 300, heightCm: 170)
        XCTAssertEqual(237, e.distanceMeters)
        XCTAssertEqual(15500, e.calories)
    }

    // MARK: D1

    func testD1Normal() throws {
        let p = T.hex("D1 0100 0300 00 00 13 0E 05 012C 0010 48 78 50 000000")
        let r = try XCTUnwrap(VeepooHistory.parseD1(p, sportLayout: false, heightCm: 170, now: now, calendar: cal))
        XCTAssertEqual(T.date(2026, 10, 19, 14, 5), r.time)
        XCTAssertEqual(300, r.steps)
        XCTAssertEqual([72], r.heartRates)
        XCTAssertEqual(120, r.systolic)
        XCTAssertEqual(80, r.diastolic)
        XCTAssertEqual(237, r.distanceMeters)
        XCTAssertEqual(15500, r.calories)
        XCTAssertFalse(VeepooHistory.isD1End(p))
        // Hôm qua (byte 5 = 1) phải khớp ngày 18; ngày lệch thì bỏ.
        XCTAssertNotNil(VeepooHistory.parseD1(T.hex("D1 0100 0300 01 00 12 0E 05 012C 0010 00 00 00 000000"), sportLayout: false, now: now, calendar: cal))
        XCTAssertNil(VeepooHistory.parseD1(T.hex("D1 0100 0300 00 00 12 0E 05 012C 0010 48 78 50 000000"), sportLayout: false, now: now, calendar: cal))
        XCTAssertTrue(VeepooHistory.isD1End(T.hex("D1 0300 0300")))
        XCTAssertTrue(VeepooHistory.isD1End(T.hex("D1 0000 0000")))
        XCTAssertEqual([0xD1, 0x01, 0x00, 0x02], VeepooHistory.d1Request(day: 2))
    }

    func testD1SportLayout() throws {
        let p = T.hex("D1 0200 0300 2E 007B 00C8 012C 0010 48 00 00 01 00 0A")  // 0x2E = 1×32 + 14 ⇒ hôm qua 14:10
        let r = try XCTUnwrap(VeepooHistory.parseD1(p, sportLayout: true, now: now, calendar: cal))
        XCTAssertEqual(T.date(2026, 10, 18, 14, 10), r.time)
        XCTAssertEqual(300, r.steps)
        XCTAssertEqual(12300, r.calories)
        XCTAssertEqual(200, r.distanceMeters)
        XCTAssertEqual([72], r.heartRates)
        XCTAssertEqual(1, r.wear)
        XCTAssertNil(r.systolic)
    }

    // MARK: DF

    static let dfBlock = T.hex("B1 04 0A 13 0E 05" + "B2 0A 012C 0010 00C8 007B 00 01" + "B4 05 48 4A 00 4C 01" + "B8 02 78 50"
                               + "B9 05 62 61 00 63 60" + "C3 04 6E01 6D01")

    static func dfPackets(_ block: [UInt8], crc: Int? = nil) -> [[UInt8]] {
        let c = crc ?? Veepoo.crc16(block)
        let header = T.pad([0xDF, 0x01, 0x00, 0x00, 0x01, 0x00, 0x03, 0x00, 0x00, 0x00, UInt8(block.count), UInt8(c & 0xFF), UInt8(c >> 8), 20])
        var out = [header]
        for i in 0..<3 {
            let body = Array(block[min(i * 16, block.count)..<min(i * 16 + 16, block.count)])
            out.append(T.pad([0xDF, 0x01, 0x00, UInt8(i + 1)] + body))
        }
        out.append(T.pad([0xDF, 0xFF, 0xFF]))
        return out
    }

    func testDfBlocksAndTlv() throws {
        XCTAssertEqual(42, Self.dfBlock.count)
        let packets = Self.dfPackets(Self.dfBlock)
        XCTAssertTrue(VeepooHistory.isDfEnd(packets.last!))
        let blocks = VeepooHistory.assembleDf(packets, protocol5: false)
        XCTAssertEqual([Self.dfBlock], blocks.map(\.payload))
        XCTAssertTrue(blocks[0].crcOk)
        let r = try XCTUnwrap(VeepooHistory.parseFiveMinute(blocks[0].payload, readDate: T.date(2026, 10, 19), calendar: cal))
        XCTAssertEqual(T.date(2026, 10, 19, 14, 5), r.time)  // B1 = tháng 10, ngày 19, 14:05
        XCTAssertEqual(300, r.steps)
        XCTAssertEqual(200, r.distanceMeters)
        XCTAssertEqual(12300, r.calories)
        XCTAssertEqual([72, 74, 0, 76, 1], r.heartRates)
        XCTAssertEqual(120, r.systolic)
        XCTAssertEqual(80, r.diastolic)
        XCTAssertEqual([98, 97, 0, 99, 96], r.spo2)
        XCTAssertEqual(36.5, r.temperature)
        // Sai CRC ⇒ khối bị đánh dấu.
        XCTAssertFalse(VeepooHistory.assembleDf(Self.dfPackets(Self.dfBlock, crc: 0x1234), protocol5: false)[0].crcOk)
        XCTAssertEqual(T.pad([0xDF, 0x01, 0x00, 0x01]), VeepooHistory.dfRequest(day: 1))
    }

    func testSeries() {
        let a = VeepooHistory.FiveMinute(time: T.date(2026, 10, 19, 14, 5), steps: 300, distanceMeters: 237, calories: 15500,
                                         heartRates: [72, 0, 74], systolic: 120, diastolic: 80, spo2: [98, 50], stress: 30,
                                         temperature: 36.5, hrv: [40, 0])
        let b = VeepooHistory.FiveMinute(time: T.date(2026, 10, 19, 14, 0), steps: 10)
        let s = VeepooHistory.series([a, b, a])
        XCTAssertEqual([10, 300], s[.steps]?.map(\.value))
        XCTAssertEqual(15500, s[.steps]?.last?.extra["calories"])
        XCTAssertEqual(237, s[.steps]?.last?.extra["distance"])
        // Nhịp tim theo phút: phút 0 và phút 2.
        XCTAssertEqual([72, 74], s[.heartRate]?.map(\.value))
        XCTAssertEqual(T.date(2026, 10, 19, 14, 7), s[.heartRate]?.last?.timestamp)
        XCTAssertEqual(80, s[.bloodPressure]?.first?.extra["diastolic"])
        XCTAssertEqual([98], s[.spo2]?.map(\.value))
        XCTAssertEqual([36.5], s[.temperature]?.map(\.value))
        XCTAssertEqual([30], s[.stress]?.map(\.value))
        XCTAssertEqual([40], s[.hrv]?.map(\.value))
        let today = VeepooHistory.todayTotals(s, now: T.date(2026, 10, 19, 15), calendar: cal)
        XCTAssertEqual(ActivityTotals(steps: 310, calories: 15500, distanceMeters: 237), today)
        XCTAssertNil(VeepooHistory.todayTotals(s, now: T.date(2026, 10, 20, 15), calendar: cal))
    }

    func testHrv5() {
        // Như `hrv5` Android: RR xen kẽ 90/80 ⇒ |Δ| = 10 ⇒ 100.
        let b7 = [UInt8(0)] + (1...50).map { UInt8($0 % 2 == 0 ? 80 : 90) }
        XCTAssertEqual([100, 100, 100, 100, 100], VeepooHistory.hrv5(b7))
    }

    func testDateNear() {
        XCTAssertEqual(T.date(2025, 12, 31, 23, 10), VeepooHistory.dateNear(T.date(2026, 1, 1), month: 12, day: 31, hour: 23, minute: 10, calendar: cal))
        XCTAssertEqual(T.date(2026, 10, 18, 23, 0), VeepooHistory.dateNear(T.date(2026, 10, 19), month: 10, day: 18, hour: 23, minute: 0, calendar: cal))
        XCTAssertNil(VeepooHistory.dateNear(T.date(2026, 10, 19), month: 0, day: 1, hour: 0, minute: 0, calendar: cal))
    }

    // MARK: Ngủ

    /// Bản ghi ngủ thường 96 byte: 18/10 23:00 → 19/10 06:00 (84 điểm × 5 phút), 20 mức sâu, 64 nông, 20 bit 1 đầu.
    static func normalRecord(wake: (Int, Int)? = nil) -> [UInt8] {
        var r = [UInt8](repeating: 0, count: 96)
        r[1] = 10; r[2] = 18; r[3] = 23; r[4] = 0
        r[5] = 10; r[6] = 19; r[7] = 6; r[8] = 0
        r[9] = 20; r[10] = 64; r[11] = 4
        r[12] = 0xFF; r[13] = 0xFF; r[14] = 0xF0
        r[43] = 84
        if let (s, e) = wake {
            r[55] = 1; r[45] = UInt8(s); r[57] = UInt8(e)
        }
        return r
    }

    static func sleepPackets(_ data: [UInt8], records: Int, day: Int) -> [[UInt8]] {
        let n = (data.count + 15) / 16
        return (0..<n).map { i in
            let body = Array(data[(i * 16)..<min(i * 16 + 16, data.count)])
            return T.pad([0xE0, UInt8(n - 1 - i), UInt8(records), UInt8(day)] + body)
        }
    }

    func testNormalSleep() throws {
        let packets = Self.sleepPackets(Self.normalRecord(), records: 1, day: 0)
        XCTAssertEqual(6, packets.count)
        XCTAssertTrue(VeepooHistory.isSleepEnd(packets.last!))
        XCTAssertFalse(VeepooHistory.isSleepEnd(packets[0]))
        let s = VeepooHistory.parseNormalSleep(packets, day: 0, now: now, calendar: cal)
        XCTAssertEqual(1, s.count)
        let x = try XCTUnwrap(s.first)
        XCTAssertEqual(T.date(2026, 10, 18, 23, 0), x.start)
        XCTAssertEqual(T.date(2026, 10, 19, 6, 0), x.end)
        XCTAssertEqual(100, x.minutes(.deep))  // bit 1 khớp số mức sâu ⇒ 1 = sâu
        XCTAssertEqual(320, x.minutes(.light))
        XCTAssertEqual(420, x.asleepMinutes)
        XCTAssertEqual([0xE0, 0x02], VeepooHistory.sleepRequest(day: 2))
    }

    func testNormalSleepWakeSegmentAndYearRollover() throws {
        let x = try XCTUnwrap(VeepooHistory.parseNormalSleepRecord(Self.normalRecord(wake: (30, 33)), readDate: T.date(2026, 10, 19), calendar: cal))
        XCTAssertEqual([.deep, .light, .awake, .light], x.segments.map(\.stage))
        XCTAssertEqual([100, 50, 15, 255], x.segments.map(\.minutes))
        // Đọc ngày 2/1 ra ngủ tháng 12 ⇒ năm trước.
        var r = Self.normalRecord()
        r[1] = 12; r[2] = 31; r[5] = 1; r[6] = 1
        let y = try XCTUnwrap(VeepooHistory.parseNormalSleepRecord(r, readDate: T.date(2027, 1, 2), calendar: cal))
        XCTAssertEqual(T.date(2026, 12, 31, 23, 0), y.start)
        XCTAssertNil(y.end < y.start ? y : nil)
        // Chất lượng 255 ⇒ bỏ.
        var bad = Self.normalRecord()
        bad[11] = 255
        XCTAssertNil(VeepooHistory.parseNormalSleepRecord(bad, readDate: T.date(2026, 10, 19), calendar: cal))
    }

    /// Khối ngủ chính xác: `A3` 36 byte (23:00 → 23:08, tổng 8 phút, accurateType ở byte cuối) + `A5` đường ngủ.
    static func preciseBlock(accurateType: UInt8, curve: [UInt8], points: Int) -> [UInt8] {
        var a3 = [UInt8](repeating: 0, count: 36)
        a3[0] = 10; a3[1] = 18; a3[2] = 23; a3[3] = 0
        a3[4] = 10; a3[5] = 18; a3[6] = 23; a3[7] = 8
        a3[15] = 3; a3[25] = UInt8(points); a3[35] = accurateType
        return [0xA2, 0x02, 0x00, 0x00, 0xA3, 0x24] + a3 + [0xA5, UInt8(points & 0xFF), UInt8(points >> 8)] + curve
    }

    func testPreciseSleepTwoBit() throws {
        // Điểm: 0 0 1 1 | 2 2 3 1 ⇒ sâu 2, nông 2, REM 2, thức 1, nông 1.
        let block = Self.preciseBlock(accurateType: 2, curve: [0x05, 0xAD], points: 8)
        let data = [0xA1, UInt8(block.count + 3), 0x00] + block  // độ dài LE16 (GE54)
        let s = VeepooHistory.parsePreciseSleep(Self.sleepPackets(data, records: 1, day: 0), day: 0, now: now, calendar: cal)
        let x = try XCTUnwrap(s.first)
        XCTAssertEqual(T.date(2026, 10, 18, 23, 0), x.start)
        XCTAssertEqual([.deep, .light, .rem, .awake, .light], x.segments.map(\.stage))
        XCTAssertEqual([2, 2, 2, 1, 1], x.segments.map(\.minutes))
        XCTAssertEqual(T.date(2026, 10, 18, 23, 4), x.segments[2].start)
    }

    func testPreciseSleepWords() throws {
        // 16 bit / điểm, giai đoạn ở bit 15..13: sâu, REM, thức dậy (4), nông. Độ dài `A5` = số byte.
        let curve = T.hex("0000 4000 8000 2000")
        let block = Self.preciseBlock(accurateType: 1, curve: curve, points: curve.count)
        let x = try XCTUnwrap(VeepooHistory.parsePreciseRecord(block, readDate: T.date(2026, 10, 19), calendar: cal))
        XCTAssertEqual([0, 2, 4, 1], x.line)  // tổng 8 phút nhưng chỉ có 4 điểm
        XCTAssertEqual(3, x.quality)
        XCTAssertEqual(1, x.accurateType)
        XCTAssertEqual(60, x.pointSeconds)
        XCTAssertEqual([.deep, .rem, .awake, .light], x.session.segments.map(\.stage))
    }

    // MARK: GE54 thật (vector vàng dùng chung với `VeepooHistoryTest.kt`)

    func testGe54StepsToday() {
        let t = VeepooHistory.parseSportModelSteps(T.hex("D8 00 16 00 00 00 12 00 00 00 09 00 00 00 00 00 00 00 00 00"))
        XCTAssertEqual(22, t?.steps)
        XCTAssertEqual(18, t?.distanceMeters)
        XCTAssertEqual(900, t?.calories)  // 0,9 kcal = 900 cal (Android: 0 kcal)
    }

    func testGe54DfBlocks() throws {
        let packets = GE54Fixtures.dfDay0Head.map(T.hex)
        let h = try XCTUnwrap(VeepooHistory.parseDfHeader(packets[0]))
        XCTAssertEqual(1, h.block)
        XCTAssertEqual(33, h.totalBlocks)
        XCTAssertEqual(2, h.packets)
        XCTAssertEqual(0xEF, h.validBytes)
        XCTAssertEqual(0x20B9, h.crc)
        XCTAssertEqual(0xCD, h.packetLength)
        let blocks = VeepooHistory.assembleDf(packets)
        XCTAssertEqual(2, blocks.count)
        XCTAssertTrue(blocks.allSatisfy(\.crcOk))
        let day = T.date(2026, 10, 19)
        let first = try XCTUnwrap(VeepooHistory.parseFiveMinute(blocks[0].payload, readDate: day, calendar: cal))
        XCTAssertEqual(T.date(2026, 10, 19, 15, 45), first.time)
        XCTAssertEqual(22, first.steps)
        XCTAssertEqual(18, first.distanceMeters)
        XCTAssertEqual(900, first.calories)  // kcal×10 = 9
        let second = try XCTUnwrap(VeepooHistory.parseFiveMinute(blocks[1].payload, readDate: day, calendar: cal))
        XCTAssertEqual(T.date(2026, 10, 19, 15, 50), second.time)
        XCTAssertEqual([63, 0, 0, 0, 0], second.heartRates)
        XCTAssertEqual(117, second.systolic)
        XCTAssertEqual(90, second.diastolic)
        XCTAssertEqual(0x13, second.stress)
        XCTAssertEqual(36.7, try XCTUnwrap(second.temperature), accuracy: 0.001)  // C3 62 01 6F 01: nền 35,4, cơ thể 36,7
        let series = VeepooHistory.series([first, second])
        XCTAssertEqual(2, series[.steps]?.count)
        XCTAssertEqual(90, series[.bloodPressure]?.first?.extra["diastolic"])
        XCTAssertEqual([63], series[.heartRate]?.map(\.value))
        // Hỏng một byte dữ liệu khối 1 ⇒ chỉ khối 1 sai CRC.
        var bad = packets
        bad[1][20] = 0x7F
        let b = VeepooHistory.assembleDf(bad)
        XCTAssertFalse(b[0].crcOk)
        XCTAssertTrue(b[1].crcOk)
    }

    func testGe54PreciseSleepDay2() throws {
        let packets = GE54Fixtures.e0Day2.map(T.hex)
        XCTAssertTrue(VeepooHistory.isSleepEnd(packets.last!))
        let nights = VeepooHistory.parsePrecise(VeepooHistory.sleepPayload(packets), readDate: T.date(2026, 10, 17), calendar: cal)
        XCTAssertEqual(1, nights.count)
        let n = nights[0]
        XCTAssertEqual(T.date(2026, 10, 17, 0, 36), n.start)
        XCTAssertEqual(T.date(2026, 10, 17, 6, 24), n.end)
        XCTAssertEqual(348, n.totalMinutes)
        XCTAssertEqual(52, n.deepMinutes)
        XCTAssertEqual(224, n.lightMinutes)
        XCTAssertEqual(2, n.quality)
        XCTAssertEqual(1, n.accurateType)
        XCTAssertEqual(60, n.pointSeconds)
        XCTAssertEqual(348, n.line.count)
        XCTAssertEqual(52, n.line.filter { $0 == 0 }.count)
        XCTAssertEqual(224, n.line.filter { $0 == 1 }.count)
        let session = n.session
        XCTAssertEqual(52, session.minutes(.deep))
        XCTAssertEqual(224, session.minutes(.light))
        XCTAssertGreaterThan(session.minutes(.rem), 0)
        XCTAssertEqual(348, session.segments.reduce(0) { $0 + $1.minutes })
        // Qua đường gói (ngày -2 tính từ 19/10).
        let viaPackets = VeepooHistory.parsePreciseSleep(packets, day: 2, now: now, calendar: cal)
        XCTAssertEqual([session], viaPackets)
    }

    func testGe54PreciseSleepDay1() {
        let nights = VeepooHistory.parsePrecise(VeepooHistory.sleepPayload(GE54Fixtures.e0Day1.map(T.hex)), readDate: T.date(2026, 10, 18), calendar: cal)
        XCTAssertEqual(1, nights.count)
        XCTAssertEqual(T.date(2026, 10, 18, 0, 55), nights.first?.start)
        XCTAssertEqual(T.date(2026, 10, 18, 5, 49), nights.first?.end)
        XCTAssertEqual(nights.first?.totalMinutes, nights.first?.line.count)
    }

    func testEmptySleepDay() {
        let p = T.pad([0xE0])
        XCTAssertTrue(VeepooHistory.isSleepEnd(p))
        XCTAssertTrue(VeepooHistory.parsePrecise(VeepooHistory.sleepPayload([p]), readDate: T.date(2026, 10, 19), calendar: cal).isEmpty)
        XCTAssertTrue(VeepooHistory.parseNormalSleep([p], day: 0, now: now, calendar: cal).isEmpty)
    }

    // MARK: Buổi tập

    static func workoutPackets() -> [[UInt8]] {
        var h = [UInt8](repeating: 0, count: 42)
        h[1] = 0xEA; h[2] = 0x07; h[3] = 10; h[4] = 19; h[5] = 7; h[6] = 0; h[7] = 0
        h[8] = 0xEA; h[9] = 0x07; h[10] = 10; h[11] = 19; h[12] = 7; h[13] = 30; h[14] = 0
        h[15] = 0xA0; h[16] = 0x0F  // 4000 bước
        h[19] = 0xB8; h[20] = 0x0B  // 3000 m
        h[23] = 0x40; h[24] = 0x0D; h[25] = 0x03  // 200000 cal
        h[31] = 2; h[33] = 1; h[34] = 60; h[38] = 1
        var out: [[UInt8]] = []
        for i in 0..<3 { out.append([0xD4, UInt8(i + 1), 0, 5, 0, 0] + Array(h[(i * 14)..<(i * 14 + 14)])) }
        out.append(T.pad([0xD4, 4, 0, 5, 0, 0, 120]))
        out.append(T.pad([0xD4, 5, 0, 5, 0, 0, 140]))
        return out
    }

    func testWorkout() throws {
        let packets = Self.workoutPackets()
        XCTAssertTrue(VeepooHistory.isWorkoutEnd(packets.last!))
        XCTAssertFalse(VeepooHistory.isWorkoutEnd(packets[0]))
        let w = try XCTUnwrap(VeepooHistory.parseWorkout(packets, calendar: cal))
        XCTAssertEqual(1, w.type)
        XCTAssertEqual("Chạy ngoài trời", w.name)
        XCTAssertEqual(T.date(2026, 10, 19, 7, 0), w.start)
        XCTAssertEqual(T.date(2026, 10, 19, 7, 30), w.end)
        XCTAssertEqual(1740, w.activeSeconds)
        XCTAssertEqual(4000, w.steps)
        XCTAssertEqual(3000, w.distanceMeters)
        XCTAssertEqual(200, w.calories)  // 200000 cal ⇒ kcal như Android
        XCTAssertEqual(130, w.avgHeartRate)
        XCTAssertEqual(140, w.maxHeartRate)
        XCTAssertEqual(120, w.minHeartRate)
        XCTAssertEqual(580, w.paceSecondsPerKm)
        XCTAssertNil(VeepooHistory.parseWorkout(Array(packets.prefix(2)), calendar: cal))
        XCTAssertEqual(T.pad([0xD4, 0x02]), VeepooHistory.workoutRequest(slot: 2))
    }

    func testSportCrc() {
        XCTAssertEqual([0x1234, 0, 0xFFFF], VeepooHistory.parseSportCrc(T.pad(T.hex("D3 01 00 3412 0000 FFFF")), slots: 3))
        XCTAssertNil(VeepooHistory.parseSportCrc(T.pad(T.hex("D3 00")), slots: 3))
        XCTAssertEqual(T.pad([0xD3, 0x01]), VeepooHistory.sportCrcRead)
    }
}
