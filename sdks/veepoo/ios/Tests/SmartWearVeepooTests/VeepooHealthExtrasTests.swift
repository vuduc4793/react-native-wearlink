import SmartWearCore
import XCTest
@testable import SmartWearVeepoo

/// Tính năng G Band còn thiếu (ge54.md §F): thành phần máu, MET, thành phần cơ thể, HRV/đường huyết trong lịch sử, hiệu chuẩn,
/// nhắc sức khoẻ `E7` 8 loại, cảnh báo `AC`, báo thức có chữ `B9`, tắt máy, bài tập TLV kiểu 5.
final class VeepooHealthExtrasTests: XCTestCase {
    private let cal = T.calendar

    // MARK: Bảng tính năng GE54

    func testGe54Capabilities() {
        let f = VeepooFeatures(packets: VeepooGe54Tests.pages)
        let caps = f.capabilities()
        for c: Capability in [.met, .uricAcid, .bloodLipids, .bodyComposition, .hrv, .bloodSugar] { XCTAssertTrue(caps.contains(c), c.rawValue) }
        XCTAssertFalse(caps.contains(.ecg))  // như Android: không báo ECG khi không đo được
        XCTAssertTrue(f.bloodComponent)
        XCTAssertTrue(f.bodyComponent)
        XCTAssertFalse(f.metByApp)  // MET kiểu 2: chỉ lịch sử
        XCTAssertTrue(f.glucoseMultiCalibration)
        XCTAssertFalse(f.glucoseSingleCalibration)
        XCTAssertTrue(f.textAlarm)
        XCTAssertTrue(f.screenless)
        XCTAssertFalse(f.hasScreen)
        XCTAssertTrue(f.tlvWorkout)
    }

    // MARK: Đo trực tiếp

    func testBloodComponentLive() {
        XCTAssertEqual(T.pad(T.hex("8A 01 01 01")), VeepooMeasure.bloodComponentStart(privateMode: true))
        XCTAssertEqual(T.pad(T.hex("8A 01 02 00")), VeepooMeasure.bloodComponentStop)
        // UA 1033 ÷10, TC 469 ÷100, TG 150, HDL 130, LDL 280.
        let done = T.pad(T.hex("8A 01 01 00 64 09 04 D5 01 96 00 82 00 18 01"))
        let ua = VeepooMeasure.bloodComponent(.uricAcid)
        let m = ua(T.pad(T.hex("8A 01 01 00 32 09 04 D5 01 96 00 82 00 18 01")))?.0
        XCTAssertEqual(.measuring, m?.status)
        XCTAssertEqual("TOUCH_SENSOR", m?.note)
        XCTAssertEqual(50, m?.extra["progress"])
        XCTAssertNil(m?.value)
        let r = try? XCTUnwrap(ua(done))
        XCTAssertEqual(.ok, r?.0.status)
        XCTAssertEqual(true, r?.1)
        XCTAssertEqual(103.3, r?.0.value ?? 0, accuracy: 0.001)
        XCTAssertEqual("µmol/L", r?.0.unit)
        XCTAssertEqual(5, r?.0.extra.count)  // đủ 5 chỉ số như Android
        let lipids = VeepooMeasure.bloodComponent(.bloodLipids)(done)
        XCTAssertEqual(4.69, lipids?.0.value ?? 0, accuracy: 0.001)
        XCTAssertEqual(Set(VeepooMeasure.lipidKeys + ["uricAcid"]), Set(lipids?.0.extra.keys.map { $0 } ?? []))
        XCTAssertEqual(1.5, lipids?.0.extra["triglycerides"] ?? 0, accuracy: 0.001)
        XCTAssertEqual(1.3, lipids?.0.extra["hdl"] ?? 0, accuracy: 0.001)
        XCTAssertEqual(2.8, lipids?.0.extra["ldl"] ?? 0, accuracy: 0.001)
        XCTAssertEqual(.notWorn, ua(T.pad(T.hex("8A 01 01 04")))?.0.status)
        XCTAssertEqual("TOUCH_SENSOR", ua(T.pad(T.hex("8A 01 01 04")))?.0.note)
        XCTAssertEqual(.error, ua(T.pad(T.hex("8A 01 01 01")))?.0.status)
        XCTAssertEqual(.error, ua(T.pad(T.hex("8A 01 01 00 64")))?.0.status)  // 100 % mà toàn 0
        XCTAssertEqual(2, ua(T.pad(T.hex("8A 01 01 02")))?.0.errorCode)
        XCTAssertEqual(.error, ua(T.pad(T.hex("8A 01 02 00")))?.0.status)
        XCTAssertNil(ua(T.pad(T.hex("8A 02 02 01"))))  // gói hiệu chuẩn không phải gói đo
    }

    /// GE54 thật 19/10/2026 21:26, chế độ thường `8A 01 01 00` (cùng vector với Android `bloodComponentGe54Capture`).
    func testBloodComponentGe54Capture() throws {
        XCTAssertEqual(T.pad(T.hex("8A 01 01 00")), VeepooMeasure.bloodComponentStart(privateMode: false))
        let packets = GE54Fixtures.bloodGeneral.map { T.hex($0) }
        XCTAssertEqual(19, packets.count)
        let parse = VeepooMeasure.bloodComponent(.bloodLipids)
        let out = try packets.map { try XCTUnwrap(parse($0)) }
        for (r, done) in out.dropLast() {
            XCTAssertEqual(.measuring, r.status); XCTAssertEqual("TOUCH_SENSOR", r.note); XCTAssertNil(r.value); XCTAssertFalse(done)
        }
        XCTAssertEqual([0, 6, 6, 12], out.prefix(4).map { $0.0.extra["progress"] ?? -1 })
        let (r, done) = try XCTUnwrap(out.last)
        XCTAssertTrue(done)
        XCTAssertEqual(.ok, r.status)
        XCTAssertEqual(4.27, r.value ?? 0, accuracy: 1e-9)
        XCTAssertEqual(215.3, r.extra["uricAcid"] ?? 0, accuracy: 1e-9)
        XCTAssertEqual(1.02, r.extra["triglycerides"] ?? 0, accuracy: 1e-9)
        XCTAssertEqual(1.04, r.extra["hdl"] ?? 0, accuracy: 1e-9)
        XCTAssertEqual(2.68, r.extra["ldl"] ?? 0, accuracy: 1e-9)
        XCTAssertEqual(5, r.extra.count)
        XCTAssertEqual(215.3, VeepooMeasure.bloodComponent(.uricAcid)(packets[18])?.0.value ?? 0, accuracy: 1e-9)
        // Chế độ riêng (hiệu chuẩn 15/12/10/15 đang lưu) bám hiệu chuẩn — driver không dùng nữa.
        XCTAssertEqual(15.58, parse(T.pad(T.hex("8A 01 01 00 64 CE 05 16 06 CA 04 EB 03 49 06")))?.0.value ?? 0, accuracy: 1e-9)
    }

    func testGlucoseLiveAndHrvRr() {
        // Vector Android `liveGlucoseAndBlood`.
        XCTAssertEqual(T.hex("89 01 01 01"), VeepooMeasure.glucoseStart(privateMode: true))
        XCTAssertEqual(T.hex("89 01 02 00"), VeepooMeasure.glucoseStop(privateMode: false))
        let g = VeepooMeasure.bloodGlucose()
        XCTAssertEqual(.measuring, g(T.pad(T.hex("89 01 01 00 32 00 00")))?.0.status)
        let r = g(T.pad(T.hex("89 01 01 00 64 1A 03")))
        XCTAssertEqual(true, r?.1)
        XCTAssertEqual(7.94, r?.0.value ?? 0, accuracy: 1e-9)
        XCTAssertEqual(.notWorn, g(T.pad(T.hex("89 01 01 04")))?.0.status)
        XCTAssertNil(g(T.pad(T.hex("89 06 01 00 64 15"))))
        // HRV kèm RR (vector Android `dfBloodMetHrv`): 10 RR đầu 80…89 ⇒ extra rr0 = 800 ms.
        var rec = VeepooHistory.FiveMinute(time: T.date(2026, 10, 19, 8, 0), met: 1.3, hrv: [59, 0, 0, 0, 0])
        rec.rr = (0..<50).map { $0 < 10 ? 80 + $0 : 0 }
        let s = VeepooHistory.series([rec])
        XCTAssertEqual(1.3, s[.met]?.first?.value ?? 0, accuracy: 1e-9)
        XCTAssertEqual(10, s[.hrv]?.first?.extra.count)
        XCTAssertEqual(800, s[.hrv]?.first?.extra["rr0"])
        // Nhắc thật GE54: nhìn xa 09:00–18:00 / 30 phút / bật; tập thể dục 120 phút.
        XCTAssertEqual(VeepooRemind(type: 3, fromMinute: 540, toMinute: 1080, interval: 30, on: true),
                       VeepooControls.parseRemind(T.pad(T.hex("E7 02 01 03 09 00 12 00 1E 01 01 01"))))
        XCTAssertEqual(T.pad(T.hex("E7 01 08 09 00 12 00 3C 00")),
                       VeepooControls.remindWrite(VeepooRemind(type: 8, fromMinute: 540, toMinute: 1080, interval: 60, on: false)))
    }

    func testMetLive() {
        XCTAssertEqual(T.pad(T.hex("89 08 01")), VeepooMeasure.metStart)
        let met = VeepooMeasure.met()
        XCTAssertEqual(.measuring, met(T.pad(T.hex("89 08 01 00 30 00")))?.0.status)
        let r = met(T.pad(T.hex("89 08 01 00 64 0B")))
        XCTAssertEqual(.ok, r?.0.status)
        XCTAssertEqual(1.1, r?.0.value ?? 0, accuracy: 0.001)
        XCTAssertEqual(.notWorn, met(T.pad(T.hex("89 08 01 04")))?.0.status)
        XCTAssertNil(met(T.pad(T.hex("89 06 01 00 64 15"))))  // gói stress
    }

    func testBodyCompositionLive() {
        XCTAssertEqual(T.pad(T.hex("93 04 01")), VeepooMeasure.bodyCompositionStart)
        // 14 chỉ số × 10: BMI 22,5; mỡ 18,3 %; … BMR 1550,0 kcal.
        let values = [225, 183, 120, 530, 750, 500, 150, 400, 550, 420, 30, 170, 110, 15500]
        let payload: [UInt8] = [0xA0, 28] + Self.le16s(values)
        let p1: [UInt8] = [0x93, 0x04, 0x01, 0x01, 0x01, 0x03] + Array(payload[0..<14])
        let p2: [UInt8] = [0x93, 0x04, 0x01, 0x01, 0x02, 0x03] + Array(payload[14..<28])
        let p3: [UInt8] = T.pad([0x93, 0x04, 0x01, 0x01, 0x03, 0x03] + Array(payload[28...]))
        let parse = VeepooMeasure.bodyComposition()
        XCTAssertEqual(.measuring, parse(T.pad(T.hex("93 04 01 00 32 00")))?.0.status)
        XCTAssertEqual(false, parse(p1)?.1)
        XCTAssertEqual(false, parse(p2)?.1)
        let r = parse(p3)
        XCTAssertEqual(true, r?.1)
        XCTAssertEqual(.ok, r?.0.status)
        XCTAssertEqual(18.3, r?.0.value ?? 0, accuracy: 0.001)
        XCTAssertEqual(14, r?.0.extra.count)
        XCTAssertEqual(22.5, r?.0.extra["bmi"] ?? 0, accuracy: 0.001)
        XCTAssertEqual(1550, r?.0.extra["basalMetabolicRate"] ?? 0, accuracy: 0.001)
        // Cảnh báo tiếp xúc 4 gói liền ⇒ dừng.
        let warn = VeepooMeasure.bodyComposition()
        XCTAssertNil(warn(T.pad(T.hex("93 04 01 00 0A 00")))?.0.note)
        for _ in 0..<3 {
            let r = warn(T.pad(T.hex("93 04 01 00 10 01")))
            XCTAssertEqual(false, r?.1); XCTAssertEqual("TOUCH_SENSOR", r?.0.note); XCTAssertEqual(16, r?.0.extra["progress"])
        }
        let stop = warn(T.pad(T.hex("93 04 01 00 16 01")))
        XCTAssertEqual(true, stop?.1); XCTAssertEqual(.notWorn, stop?.0.status); XCTAssertEqual("TOUCH_SENSOR", stop?.0.note)
        let again = VeepooMeasure.bodyComposition()
        for _ in 0..<3 { _ = again(T.pad(T.hex("93 04 01 00 10 01"))) }
        XCTAssertNil(again(T.pad(T.hex("93 04 01 00 12 00")))?.0.note)
        XCTAssertEqual(false, again(T.pad(T.hex("93 04 01 00 14 01")))?.1)
        XCTAssertEqual(4, VeepooMeasure.bodyComposition()(T.pad(T.hex("93 04 01 04")))?.0.errorCode)
    }

    // MARK: Lịch sử

    func testDfBloodComponentGlucoseAndSeries() throws {
        let blocks = VeepooHistory.assembleDf(GE54Fixtures.dfDay0Head.map(T.hex))
        let day = T.date(2026, 10, 19)
        let first = try XCTUnwrap(VeepooHistory.parseFiveMinute(blocks[0].payload, readDate: day, calendar: cal))
        XCTAssertNil(first.bloodComponent)  // C2 toàn 0
        XCTAssertNil(first.glucose)  // BE 00 00
        let second = try XCTUnwrap(VeepooHistory.parseFiveMinute(blocks[1].payload, readDate: day, calendar: cal))
        // C2 0A 21 06 D2 04 EA 03 65 06 09 04: TC/TG/HDL/LDL ÷100 rồi UA ÷10.
        let b = try XCTUnwrap(second.bloodComponent)
        XCTAssertEqual(103.3, b.uricAcid, accuracy: 0.001)
        XCTAssertEqual(15.69, b.totalCholesterol, accuracy: 0.001)
        XCTAssertEqual(12.34, b.triglycerides, accuracy: 0.001)
        XCTAssertEqual(10.02, b.hdl, accuracy: 0.001)
        XCTAssertEqual(16.37, b.ldl, accuracy: 0.001)
        XCTAssertEqual(6.83, try XCTUnwrap(second.glucose), accuracy: 0.001)  // BE AB 02
        let series = VeepooHistory.series([first, second])
        XCTAssertEqual([103.3], series[.uricAcid]?.map(\.value))
        XCTAssertEqual(15.69, series[.bloodLipids]?.first?.value ?? 0, accuracy: 0.001)
        XCTAssertEqual(10.02, series[.bloodLipids]?.first?.extra["hdl"] ?? 0, accuracy: 0.001)
        XCTAssertEqual([6.83], series[.bloodSugar]?.map(\.value))
        XCTAssertNotNil(series[.hrv])
        // MET (BF) ÷10.
        let met = try XCTUnwrap(VeepooHistory.parseFiveMinute([0xB1, 4, 10, 19, 8, 0, 0xBF, 1, 11], readDate: day, calendar: cal))
        XCTAssertEqual(1.1, VeepooHistory.series([met])[.met]?.first?.value ?? 0, accuracy: 0.001)
    }

    func testBodyCompositionRecord() throws {
        XCTAssertEqual(T.pad(T.hex("93 05 01")), VeepooHistory.bodyCompositionIdsRead)
        XCTAssertEqual([3, 0x0102], VeepooHistory.parseBodyCompositionIds(T.pad(T.hex("93 05 01 00 02 03 00 02 01"))))
        XCTAssertNil(VeepooHistory.parseBodyCompositionIds(T.pad(T.hex("93 05 A1"))))
        XCTAssertEqual(T.pad(T.hex("93 06 01 03 00")), VeepooHistory.bodyCompositionRecordRead(id: 3))
        let values = [225, 183, 120, 530, 750, 500, 150, 400, 550, 420, 30, 170, 110, 15500]
        let tail: [UInt8] = [0xA1, 0x07, 26, 10, 19, 8, 30, 0, 45]
        let body: [UInt8] = [0xA0, 28] + Self.le16s(values) + tail
        var packets: [[UInt8]] = []
        for (i, o) in stride(from: 0, to: body.count, by: 15).enumerated() {
            let head: [UInt8] = [0x93, 0x06, 0x01, UInt8(i + 1), 3]
            packets.append(T.pad(head + Array(body[o..<min(o + 15, body.count)])))
        }
        XCTAssertTrue(VeepooHistory.isBodyCompositionRecordEnd(packets[2]))
        let p = try XCTUnwrap(VeepooHistory.parseBodyCompositionRecord(packets, calendar: cal))
        XCTAssertEqual(T.date(2026, 10, 19, 8, 30), p.timestamp)
        XCTAssertEqual(18.3, p.value, accuracy: 0.001)
        XCTAssertEqual(53, p.extra["fatFreeMass"] ?? 0, accuracy: 0.001)
    }

    func testGe54TlvWorkout() throws {
        let packets = GE54Fixtures.d4Slot1.map(T.hex)
        XCTAssertTrue(VeepooHistory.isWorkoutEnd(packets.last!))
        let w = try XCTUnwrap(VeepooHistory.parseTlvWorkout(packets))
        XCTAssertEqual(Date(timeIntervalSince1970: 0x6AD366B4), w.start)
        XCTAssertEqual(Date(timeIntervalSince1970: 0x6AD36C0B), w.end)
        XCTAssertEqual(0x548, w.activeSeconds)  // 1352 s
        XCTAssertEqual(0x0A98, w.steps)
        XCTAssertEqual(0x0909, w.distanceMeters)  // 2313 m
        XCTAssertEqual(0x231A1 / 1000, w.calories)  // kcal
        XCTAssertEqual(150, w.maxHeartRate)
        XCTAssertEqual(122, w.avgHeartRate)
        XCTAssertEqual(83, w.minHeartRate)
        XCTAssertEqual(1, w.type)
        XCTAssertEqual(0x0242, w.paceSecondsPerKm)
        XCTAssertEqual([0xC37B, 0xC0F4, 0xAC2D], VeepooHistory.parseSportCrc(T.hex("D3 01 01 7B C3 F4 C0 2D AC 00 00 00 00 00 00 00 00 00 00 00"), slots: 3))
    }

    // MARK: Hiệu chuẩn

    func testCalibrationPackets() throws {
        let bp = VeepooCalibration.BloodPressure(on: true, systolic: 120, diastolic: 87)
        XCTAssertEqual(T.pad(T.hex("91 01 78 57 00")), VeepooCalibration.bpWrite(bp))  // như Android (angio 0)
        XCTAssertEqual(T.hex("91 02 00 00"), VeepooCalibration.bpRead)
        XCTAssertEqual(bp, VeepooCalibration.parseBp(T.pad(T.hex("91 01 78 57 01 02"))))
        XCTAssertNil(VeepooCalibration.parseBp(T.pad(T.hex("91 00 78 57 01 02"))))

        let blood = VeepooCalibration.BloodComponent(on: true, uricAcid: 1200, totalCholesterol: 450, triglycerides: 0, hdl: 0, ldl: 0)
        XCTAssertEqual(T.pad(T.hex("8A 02 01 01 B0 04 C2 01")), VeepooCalibration.bloodWrite(blood))
        XCTAssertEqual(blood, VeepooCalibration.parseBlood(T.pad(T.hex("8A 02 02 01 01 B0 04 C2 01 00 00 00 00 00 00"))))
        XCTAssertEqual(T.pad(T.hex("8A 02 02")), VeepooCalibration.bloodRead)

        // Đường huyết nhiều điểm: 2 gói ghi, đọc lại ghép gói 1 [0..19] + gói 2 [6..16].
        let meals = [VeepooCalibration.Meal(beforeMinute: 7 * 60, before: 520, afterMinute: 9 * 60 + 30, after: 780),
                     VeepooCalibration.Meal(beforeMinute: 12 * 60, before: 500, afterMinute: 14 * 60, after: 700),
                     VeepooCalibration.Meal(beforeMinute: 18 * 60, before: 510, afterMinute: 20 * 60, after: 720)]
        let g = VeepooCalibration.Glucose(on: true, meals: meals)
        let w = VeepooCalibration.glucoseMultiWrite(g)
        XCTAssertEqual(2, w.count)
        XCTAssertEqual(T.hex("89 03 01 01 02 01 07 00 08 02 09 1E 0C 03 0C 00 F4 01 0E 00"), w[0])
        XCTAssertEqual(T.pad(T.hex("89 03 01 02 02 BC 02 12 00 FE 01 14 00 D0 02")), w[1])
        let body = VeepooCalibration.glucoseBody(g)
        let h1: [UInt8] = [0x89, 0x03, 0x02, 0x01, 0x01, 0x02]
        let h2: [UInt8] = [0x89, 0x03, 0x02, 0x01, 0x02, 0x02]
        let r1 = h1 + Array(body[0..<14])
        let r2 = T.pad(h2 + Array(body[14...]))
        XCTAssertEqual(g, VeepooCalibration.parseGlucoseMulti([r2, r1]))
        XCTAssertEqual(T.hex("89 03 02 01 01"), VeepooCalibration.glucoseMultiRead)
        XCTAssertEqual(T.pad(T.hex("89 02 01 F4 01 01")), VeepooCalibration.glucoseSingleWrite(VeepooCalibration.Glucose(on: true, value: 500)))

        // Đổi mục → bộ mới (đơn vị hiển thị).
        let c = VeepooCalibration()
        XCTAssertEqual(130, c.with("calibrate.bp.systolic", .number(130))?.bp?.systolic)
        XCTAssertEqual(550, c.with("calibrate.glucose.lunchBefore", .number(550))?.glucose?.meals[1].before)
        XCTAssertEqual(8 * 60, c.with("calibrate.glucose.breakfastTime", .timeRange(from: 480, to: 600))?.glucose?.meals[0].beforeMinute)
        XCTAssertEqual(1100, c.with("calibrate.bloodComponent.uricAcid", .number(1100))?.bloodComponent?.uricAcid)
        XCTAssertNil(c.with("auto.hr", .bool(true)))

        // Gói thật GE54 (vector Android `VeepooHealthTest`): thành phần máu đang hiệu chuẩn, HA 120/87, đường huyết nhiều điểm.
        let realBlood = try XCTUnwrap(VeepooCalibration.parseBlood(T.pad(T.hex("8A 02 02 01 01 84 03 DC 05 B0 04 E8 03 DC 05"))))
        XCTAssertEqual(VeepooCalibration.BloodComponent(on: true, uricAcid: 900, totalCholesterol: 1500, triglycerides: 1200, hdl: 1000, ldl: 1500), realBlood)
        XCTAssertEqual(T.hex("8A 02 01 01 84 03 DC 05 B0 04 E8 03 DC 05 00 00 00 00 00 00"), VeepooCalibration.bloodWrite(realBlood))
        XCTAssertNil(VeepooCalibration.parseBlood(T.pad(T.hex("8A 02 02 00 01 84 03 DC 05 B0 04 E8 03 DC 05"))))
        XCTAssertEqual(VeepooCalibration.BloodPressure(on: false, systolic: 0, diastolic: 0), VeepooCalibration.parseBp(T.pad(T.hex("91 01 00 00 00 00"))))
        let gm = try XCTUnwrap(VeepooCalibration.parseGlucoseMulti([T.hex("89 03 02 01 01 02 01 0F 00 8A 02 0F 01 EE 02 00 00 00 00 00"),
                                                                     T.hex("89 03 02 01 02 02 00 00 00 00 00 00 00 00 00 00 00 00 00 00")]))
        XCTAssertTrue(gm.on)
        XCTAssertEqual(VeepooCalibration.Meal(beforeMinute: 900, before: 650, afterMinute: 901, after: 750), gm.meals[0])
        XCTAssertEqual(VeepooCalibration.Meal(beforeMinute: 0, before: 0, afterMinute: 0, after: 0), gm.meals[2])
        XCTAssertEqual([T.hex("89 03 01 01 02 01 0F 00 8A 02 0F 01 EE 02 00 00 00 00 00 00"),
                        T.hex("89 03 01 02 02 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00")], VeepooCalibration.glucoseMultiWrite(gm))
        XCTAssertEqual(VeepooCalibration.Glucose(on: true, value: 650), VeepooCalibration.parseGlucoseSingle(T.pad(T.hex("89 02 02 01 8A 02 01"))))
        XCTAssertNil(c.with("calibrate.bp.foo", .number(1)))
        XCTAssertNil(c.with("calibrate.glucose.brunch.before", .number(1)))
    }

    // MARK: Nhắc nhở, cảnh báo, hệ thống

    func testRemindAndHeartAlarmParsers() {
        XCTAssertEqual(VeepooRemind(type: 2, fromMinute: 480, toMinute: 1320, interval: 30, on: true),
                       VeepooControls.parseRemind(T.pad(T.hex("E7 02 01 02 08 00 16 00 1E 01 02 08"))))
        XCTAssertNil(VeepooControls.parseRemind(T.pad(T.hex("E7 02 00 02 08 00 16 00 1E 01"))))
        XCTAssertNil(VeepooControls.parseRemind(T.pad(T.hex("E7 00"))))
        XCTAssertTrue(VeepooControls.isLastRemind(T.pad(T.hex("E7 02 01 08 08 00 16 00 1E 01 08 08"))))
        XCTAssertFalse(VeepooControls.isLastRemind(T.pad(T.hex("E7 02 01 02 08 00 16 00 1E 01 02 08"))))
        XCTAssertEqual(T.pad(T.hex("E7 02 00")), VeepooControls.remindRead(0))
        XCTAssertEqual(VeepooHeartAlarm(high: 100, low: 55, on: true), VeepooControls.parseHeartAlarm(T.hex("AC 64 37 01 02 01")))
        XCTAssertNil(VeepooControls.parseHeartAlarm(T.hex("AC 64 37 10 02 01")))  // 0x10 = không hỗ trợ
        XCTAssertEqual(8, VeepooControls.remindKinds.count)
        XCTAssertEqual(["sedentary", "drink", "longView", "exercise", "medication", "book", "travel", "handWash"],
                       VeepooControls.remindKinds.map(\.key))
    }

    @MainActor
    func testRemindTargets() {
        XCTAssertEqual(5, VeepooDevice.remindTarget("remind.medication.enabled")?.type)
        XCTAssertEqual("range", VeepooDevice.remindTarget("remind.handWash.range")?.field)
        XCTAssertEqual(2, VeepooDevice.remindTarget("drink.interval")?.type)  // id cũ vẫn nhận
        XCTAssertNil(VeepooDevice.remindTarget("remind.foo.enabled"))
        XCTAssertNil(VeepooDevice.remindTarget("hrAlarm.high"))
    }

    func testGe54AllRemindsAndCalibrationControls() {
        let f = VeepooFeatures(packets: VeepooGe54Tests.pages)
        var reminds: [Int: VeepooRemind] = [:]
        for t in 1...8 { reminds[t] = VeepooRemind(type: t, fromMinute: 540, toMinute: 1080, interval: 30 + t * 10, on: t <= 2) }
        let st = VeepooDeviceState(reminds: reminds, calibration: VeepooCalibration(
            bp: .init(on: true, systolic: 120, diastolic: 87),
            glucose: .init(on: true, meals: [.init(beforeMinute: 900, before: 650, afterMinute: 901, after: 750)]),
            bloodComponent: .init(on: false, uricAcid: 900)
        ))
        let b8 = VeepooCustomSettings(page0: T.hex("B8 02 01 01 01 01 00 00 00 00 02 02 01 00 00 00 01 00 00 00"),
                                      page1: T.hex("B8 02 00 00 01 01 00 01 00 01 01 01 01 01 00 00 00 00 00 01"))
        let c = VeepooControls.controls(f, b8, VeepooMessageSwitches(page0: nil, page1: nil), VeepooSettings(), st)
        let ids = Set(c.map(\.id))
        for k in VeepooControls.remindKinds {
            for field in ["enabled", "interval", "range"] { XCTAssertTrue(ids.contains("remind.\(k.key).\(field)"), "\(k.key).\(field)") }
        }
        XCTAssertEqual(.number(110), c.first { $0.id == "remind.handWash.interval" }?.value)
        XCTAssertEqual(.number(650), c.first { $0.id == "calibrate.glucose.breakfastBefore" }?.value)
        XCTAssertEqual(.number(900), c.first { $0.id == "calibrate.bloodComponent.uricAcid" }?.value)
        // Chưa đọc được hiệu chuẩn ⇒ không hiện (như Android).
        let none = VeepooControls.controls(f, b8, VeepooMessageSwitches(page0: nil, page1: nil), VeepooSettings(), VeepooDeviceState())
        XCTAssertFalse(none.contains { $0.id.hasPrefix("calibrate.") })
        XCTAssertEqual(false, c.first { $0.id == "remind.book.interval" }?.enabled)
        for id in ["calibrate.bp.enabled", "calibrate.bp.systolic", "calibrate.bp.diastolic", "calibrate.glucose.enabled",
                   "calibrate.glucose.breakfastTime", "calibrate.glucose.breakfastBefore", "calibrate.glucose.dinnerAfter",
                   "calibrate.bloodComponent.enabled",
                   "calibrate.bloodComponent.uricAcid", "calibrate.bloodComponent.ldl"] {
            XCTAssertTrue(ids.contains(id), id)
        }
        XCTAssertFalse(ids.contains("calibrate.glucose.value"))  // GE54: nhiều điểm
        XCTAssertEqual(.number(87), c.first { $0.id == "calibrate.bp.diastolic" }?.value)
        XCTAssertEqual(.bool(false), c.first { $0.id == "calibrate.bloodComponent.enabled" }?.value)
    }

    // MARK: Báo thức có chữ B9

    func testTextAlarmPackets() throws {
        // Ví dụ dựng theo `q2.java` (CRC-16/MODBUS kiểm bằng tay): id 1, bật, T2–T6, 07:30, nhãn "Hi".
        let a = Alarm(id: 1, hour: 7, minute: 30, repeatDays: Alarm.weekdays, enabled: true, label: "Hi")
        let ta = VeepooAlarm.tlv(a, date: DateComponents(year: 2026, month: 10, day: 20))  // có lặp ⇒ bỏ ngày
        XCTAssertEqual(T.hex("A1 0E B1 08 01 01 1F 07 1E 00 00 00 B2 02 48 69"), ta)
        XCTAssertEqual(0x5939, VeepooAlarm.crc([ta]))
        XCTAssertEqual(0, VeepooAlarm.crc([]))
        XCTAssertEqual([T.hex("B9 02 01 01 A0 02 39 59 A1 0E B1 08 01 01 1F 07 1E 00 00 00 B2 02 48 69")],
                       VeepooAlarm.writePackets(op: VeepooAlarm.opSet, item: ta, crc: 0x5939, mtu: 244))
        XCTAssertEqual([T.hex("B9 02 02 01 A0 02 39 59 A1 0E B1 08 01 01 1F 07 1E 00 00 00"), T.pad(T.hex("B9 02 02 02 B2 02 48 69"))],
                       VeepooAlarm.writePackets(op: VeepooAlarm.opSet, item: ta, crc: 0x5939, mtu: 20))
        // Báo thức một lần 2026-10-20 06:00, không nhãn: có ngày.
        let b = Alarm(id: 2, hour: 6, minute: 0, repeatDays: 0, enabled: true, label: nil)
        let tb = VeepooAlarm.tlv(b, date: DateComponents(year: 2026, month: 10, day: 20))
        XCTAssertEqual(T.hex("A1 0C B1 08 02 01 00 06 00 1A 0A 14 B2 00"), tb)
        XCTAssertEqual(0xD52B, VeepooAlarm.crc([tb]))
        XCTAssertEqual(0x7464, VeepooAlarm.crc([ta, tb]))
        XCTAssertEqual(T.pad(T.hex("B9 03 00 00 A0 02 00 00")), VeepooAlarm.readRequest())

        // Đọc: 2 gói (MTU 20), đầu `A0 03 01 crc`.
        let all: [UInt8] = [0xA0, 0x03, 0x01, 0x64, 0x74] + ta + tb
        var packets: [[UInt8]] = []
        for (i, o) in stride(from: 0, to: all.count, by: 16).enumerated() {
            let head: [UInt8] = [0xB9, 0x03, 0x03, UInt8(i + 1)]
            packets.append(T.pad(head + Array(all[o..<min(o + 16, all.count)])))
        }
        XCTAssertEqual(3, packets.count)
        XCTAssertTrue(VeepooAlarm.isLast(packets[2]))
        XCTAssertEqual(true, VeepooAlarm.parseAck(packets[0])?.ok)
        XCTAssertEqual(0x7464, VeepooAlarm.parseAck(packets[0])?.crc)
        let entries = VeepooAlarm.parseEntries(packets.reversed())
        XCTAssertEqual([a, b], entries.map(\.alarm))
        XCTAssertEqual([0, 0, 0], entries[0].rawDate)
        XCTAssertEqual([26, 10, 20], entries[1].rawDate)
        XCTAssertTrue(VeepooAlarm.parseList([T.pad(T.hex("B9 03 01 01 A0 03 01 00 00"))]).isEmpty)  // không có báo thức
        XCTAssertEqual(3, VeepooAlarm.freeId([a, b]))
        XCTAssertNil(VeepooAlarm.freeId((1...10).map { Alarm(id: $0, hour: 0, minute: 0) }))
        // Nhãn dài cắt theo byte UTF-8 (≤ 30, như Android).
        let long = VeepooAlarm.tlv(Alarm(id: 3, hour: 1, minute: 2, label: "Uống thuốc huyết áp buổi sáng nhé"), date: nil)
        XCTAssertLessThanOrEqual(Int(long[13]), 30)
        XCTAssertEqual(Int(long[13]) + 14, long.count)

        // Gói đọc thật GE54 (vector Android `VeepooHealthTest.alarmsGe54`): 13:44, tắt, không lặp, ngày thô 30 00 00, CRC 3C31.
        let real = T.hex("B9 03 01 01 A0 03 01 31 3C A1 0C B1 08 01 00 00 0D 2C 30 00 00 B2 00")
        XCTAssertTrue(VeepooAlarm.isLast(real))
        XCTAssertEqual(0x3C31, VeepooAlarm.parseAck(real)?.crc)
        let e = try XCTUnwrap(VeepooAlarm.parseEntries([real]).first)
        XCTAssertEqual(Alarm(id: 1, hour: 13, minute: 44, repeatDays: 0, enabled: false, label: nil), e.alarm)
        let raw = VeepooAlarm.tlv(e.alarm, date: DateComponents(year: 2026, month: 10, day: 20), rawDate: e.rawDate)
        XCTAssertEqual(T.hex("A1 0C B1 08 01 00 00 0D 2C 30 00 00 B2 00"), raw)
        XCTAssertEqual(0x3C31, VeepooAlarm.crc([raw]))
        // Thêm 07:30 T2–T6 "Test" (id 2) như Android: một gói MTU 244.
        let add = Alarm(id: VeepooAlarm.freeId([e.alarm])!, hour: 7, minute: 30, repeatDays: 0x1F, enabled: true, label: "Test")
        let tAdd = VeepooAlarm.tlv(add)
        let crc = VeepooAlarm.crc([raw, tAdd])
        XCTAssertEqual([T.hex(String(format: "B9 02 01 01 A0 02 %02X %02X A1 10 B1 08 02 01 1F 07 1E 00 00 00 B2 04 54 65 73 74", crc & 0xFF, crc >> 8))],
                       VeepooAlarm.writePackets(op: VeepooAlarm.opSet, item: tAdd, crc: crc, mtu: 244))
        XCTAssertEqual(T.hex("B9 01 01 01 A0 02 31 3C A1 10"), Array(VeepooAlarm.writePackets(op: VeepooAlarm.opDelete, item: tAdd, crc: 0x3C31, mtu: 244)[0].prefix(10)))
    }

    func testNextDate() {
        let now = T.date(2026, 10, 19, 20, 0)
        XCTAssertEqual(19, VeepooAlarm.nextDate(hour: 21, minute: 0, now: now, calendar: cal).day)
        XCTAssertEqual(20, VeepooAlarm.nextDate(hour: 6, minute: 0, now: now, calendar: cal).day)
        XCTAssertEqual(1, VeepooAlarm.nextDate(hour: 6, minute: 0, now: T.date(2026, 12, 31, 22, 0), calendar: cal).month)
    }

    @MainActor
    func testDeviceAlarmFlags() {
        let d = VeepooDevice(scanned: ScannedDevice(id: UUID(), name: "GE54", rssi: -50), match: DriverMatch(driverId: "veepoo", model: "GE54", kind: .band))
        XCTAssertFalse(d.supportsAlarms)  // chưa có bảng A7
        XCTAssertEqual(0, d.maxAlarms)
    }

    static func le16s(_ values: [Int]) -> [UInt8] {
        var out: [UInt8] = []
        for v in values { out += [UInt8(v & 0xFF), UInt8(v >> 8)] }
        return out
    }
}
