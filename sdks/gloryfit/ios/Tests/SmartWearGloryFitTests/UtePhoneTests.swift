import XCTest
import SmartWearCore
@testable import SmartWearGloryFit

/// Lệnh điện thoại ↔ đồng hồ mới (kế hoạch 2026-10-19 §3): nhạc, bài tập + GPS điện thoại + danh sách môn, khe mặt
/// đồng hồ, phím tắt, trạng thái dữ liệu, xoá, nút. Gói mẫu dựng theo mã app GloryFit / GloryFitPro (chưa có gói thật).
final class UtePhoneTests: XCTestCase {
    private func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02X", $0) }.joined(separator: " ") }

    private let y25 = Ute.Features(groups: [1: 0x4BA0CC, 2: 0x00547C, 3: 0x00D921, 4: 0x75EEDF, 5: 0x200962], maxPacketLength: 244)

    // MARK: Nhạc

    func testMusicCommands() {
        XCTAssertEqual(.playPause, UteMusic.parseCommand([0xD1, 0x07]))
        XCTAssertEqual(.next, UteMusic.parseCommand([0xD1, 0x08]))
        XCTAssertEqual(.previous, UteMusic.parseCommand([0xD1, 0x09]))
        XCTAssertEqual(.volumeUp, UteMusic.parseCommand([0xD1, 0x0D]))
        XCTAssertEqual(.volumeDown, UteMusic.parseCommand([0xD1, 0x0E, 0x32]))
        XCTAssertNil(UteMusic.parseCommand([0xD1, 0x0A]))
        XCTAssertNil(UteMusic.parseCommand([0xC4, 0x07]))
        XCTAssertNil(UteMusic.parseCommand([0xD1]))
    }

    func testSongPackets() {
        let p = UteMusic.songPackets(playing: true, title: "Hello", artist: "Sơn Tùng")
        XCTAssertEqual(p.map(hex), [
            "3A 01 02 FF FF FF FF FF FF FF FF FF FF",
            "3A 06 05 48 65 6C 6C 6F",
            "3A 04 00 0A 53 C6 A1 6E 20 54 C3 B9 6E 67",
        ])
        XCTAssertEqual(0x2B, UteMusic.checksum(p))
        XCTAssertEqual(["3A 01 01 FF FF FF FF FF FF FF FF FF FF"], UteMusic.songPackets(playing: false, title: nil, artist: "").map(hex))
        XCTAssertEqual("3A FA", hex(UteMusic.songEnd))
    }

    func testSongTitleCutsAtCharacterBoundary() {
        // "ồ" = 3 byte UTF-8: 52 byte chỉ chứa trọn 17 ký tự (51 byte), không cắt đôi ký tự thứ 18.
        let p = UteMusic.songPackets(playing: true, title: String(repeating: "ồ", count: 30), artist: nil)
        XCTAssertEqual(51, Int(p[1][2]))
        XCTAssertEqual(54, p[1].count)
        XCTAssertEqual(String(repeating: "ồ", count: 17), String(decoding: p[1][3...], as: UTF8.self))
    }

    func testPlayStateAndVolume() {
        XCTAssertEqual("D1 0C 01", hex(UteMusic.playState(true)))
        XCTAssertEqual("D1 0C 02", hex(UteMusic.playState(false)))
        XCTAssertEqual("D1 0D 64", hex(UteMusic.volume(150, up: true)))
        XCTAssertEqual("D1 0E 00", hex(UteMusic.volume(-3, up: false)))
        XCTAssertTrue(UteMusic.control(Ute.Features(groups: [5: 0x000001])))
        XCTAssertTrue(UteMusic.songInfo(Ute.Features(groups: [5: 0x001000])))
        XCTAssertFalse(UteMusic.songInfo(y25))
    }

    // MARK: Bài tập

    func testWorkoutControlCommands() {
        XCTAssertEqual("FD 11 01 01", hex(UteSport.start(1)))
        XCTAssertEqual("FD 00 09 01", hex(UteSport.stop(9)))
        XCTAssertEqual("FD AA", hex(UteSport.query))
        // 3725 s = 1 giờ 2 phút 5 giây.
        XCTAssertEqual("FD 22 01 01 01 02 05", hex(UteSport.pause(1, elapsed: 3725)))
        XCTAssertEqual("FD 33 01 01 00 00 00", hex(UteSport.resume(1, elapsed: -4)))
        XCTAssertTrue(UteSport.control(Ute.Features(groups: [5: 0x000002])))
        XCTAssertTrue(UteSport.sportList(Ute.Features(groups: [6: 0x002000])))
        XCTAssertTrue(UteSport.phoneGps(Ute.Features(groups: [7: 0x000080])))
    }

    func testWorkoutStatePackets() {
        XCTAssertEqual(.state(.paused, sportType: 1, byDevice: true), UteSport.parseState([0xFD, 0x04, 0x01, 0x22]))
        XCTAssertEqual(.state(.started, sportType: 2, byDevice: true), UteSport.parseState([0xFD, 0x04, 0x02, 0x11]))
        XCTAssertEqual(.state(.resumed, sportType: 2, byDevice: true), UteSport.parseState([0xFD, 0x04, 0x02, 0x33]))
        XCTAssertEqual(.state(.stopped, sportType: 2, byDevice: true), UteSport.parseState([0xFD, 0x04, 0x02, 0x00]))
        XCTAssertEqual(.state(.started, sportType: 1, byDevice: false), UteSport.parseState([0xFD, 0x11, 0x01, 0x01]))
        XCTAssertEqual(.state(.stopped, sportType: 1, byDevice: false), UteSport.parseState([0xFD, 0x00, 0x01, 0x01]))
        XCTAssertEqual(.state(.paused, sportType: 1, byDevice: false),
                       UteSport.parseState([0xFD, 0x22, 0x01, 0x01, 0, 1, 2, 0, 0, 0, 0, 0, 0]))
        XCTAssertNil(UteSport.parseState([0xFD, 0x04, 0x01, 0x55]))
        XCTAssertNil(UteSport.parseState([0xFD, 0xAA, 0x11, 0x01]))
        XCTAssertNil(UteSport.parseState([0xFD, 0x01, 0xAA, 0x01]))
        XCTAssertNil(UteSport.parseState([0xFD, 0x11, 0x01]))
        XCTAssertEqual(UteSport.parseQuery([0xFD, 0xAA, 0x11, 0x01])?.state, .started)
        XCTAssertEqual(UteSport.parseQuery([0xFD, 0xAA, 0x22, 0x05])?.sportType, 5)
        XCTAssertNil(UteSport.parseQuery([0xFD, 0xAA, 0x77, 0x05]))
    }

    func testWorkoutRealtime() {
        let p: [UInt8] = [0xFD, 0x01, 0x82, 0x00, 0x2D, 0x06, 0x1E, 0x00, 0x0B, 0xB8, 0x00, 0x00, 0x02, 0x37]
        XCTAssertEqual(
            WorkoutRealtime(sportType: 1, heartRate: 130, calories: 45, paceSecondsPerKm: 390, steps: 3000, count: 0, distanceMeters: 2550),
            UteSport.parseRealtime(p)
        )
        var noHr = p
        noHr[2] = 0
        XCTAssertNil(UteSport.parseRealtime(noHr)?.heartRate)
        XCTAssertNil(UteSport.parseRealtime(Array(p.prefix(13))))
    }

    func testLocationRequestAndPacket() {
        XCTAssertEqual(LocationRequest(start: true, sportType: 1), UteSport.parseLocationRequest([0xFD, 0x01, 0xAA, 0x01]))
        XCTAssertEqual(LocationRequest(start: false), UteSport.parseLocationRequest([0xFD, 0x01, 0x55]))
        XCTAssertNil(UteSport.parseLocationRequest([0xFD, 0x01, 0x01]))
        XCTAssertEqual("FD 01 01", hex(UteSport.locationStatus(true)))
        XCTAssertEqual(
            "FD 02 01 40 DE 9F 06 4E 74 11 00 FA 00 00 00 03 00 00 00 78",
            hex(UteSport.location(latitude: 21.028511, longitude: 105.804817, speed: 2.5, pointMeters: 3, totalMeters: 120))
        )
        // Kinh độ âm: bù hai.
        XCTAssertEqual([0xFF, 0xFE, 0x0D, 0xF4], Array(UteSport.location(latitude: 0, longitude: -0.1275, speed: 0, pointMeters: 0, totalMeters: 0)[6..<10]))
        XCTAssertEqual(111.19, UteSport.distanceMeters(21, 105, 21.001, 105), accuracy: 0.05)
    }

    func testSportListRead() {
        let packets: [[UInt8]] = [
            [0xFD, 0x48, 0xAA, 0x00, 0x01, 0x01, 0x01, 0x02, 0x00, 0x00, 0x09, 0x01, 0x02],
            [0xFD, 0x48, 0xAA, 0x01, 0x00, 0x00, 0x00, 0x05, 0x01, 0x03],
            [0xFD, 0x48, 0xAA, 0xFD, 0x7C, 0x00, 0x04, 0x00, 0x14],
        ]
        XCTAssertTrue(UteSport.isSportListEnd(packets[2]))
        let list = UteSport.parseSportList(packets)
        XCTAssertEqual(list.sports.map(\.type), [1, 2, 9, 5])
        XCTAssertEqual(list.sports.map(\.shown), [true, false, true, true])
        XCTAssertEqual(list.sports.map(\.position), [1, 0, 2, 3])
        XCTAssertEqual(list.sports[0].name, "Chạy ngoài trời")
        XCTAssertEqual(list.sports[0].nameEn, "Outdoor run")
        XCTAssertEqual(list.minShown, 4)
        XCTAssertEqual(list.maxShown, 20)
    }

    func testSportListWrite() {
        let sports = [
            SportType(type: 1, name: "", shown: true, position: 1), SportType(type: 2, name: "", shown: false, position: 0),
            SportType(type: 9, name: "", shown: true, position: 2), SportType(type: 5, name: "", shown: true, position: 3),
        ]
        XCTAssertEqual(UteSport.sportListPackets(sports, packetLength: 9).map(hex), [
            "FD 48 00 01 01 01 02 00 00",
            "FD 48 01 09 01 02 05 01 03",
            "FD 48 FD 0F",
        ])
        XCTAssertEqual(UteSport.sportListPackets(sports, packetLength: 244).count, 2)
        XCTAssertEqual(UteSport.sportListPackets([], packetLength: 20).map(hex), ["FD 48 FD 00"])
    }

    func testSportCatalog() {
        XCTAssertEqual(UteSportCatalog.names.count, 245)
        XCTAssertEqual(Set(UteSportCatalog.names.keys), Set(1...245))
        XCTAssertEqual(Ute.sportName(5), "Cầu lông")
        XCTAssertEqual(Ute.sportNameEn(5), "Badminton")
        XCTAssertEqual(Ute.sportName(246), "Môn thể thao #246")
        XCTAssertNil(Ute.sportNameEn(0))
    }

    func testSportListNormalize() throws {
        let sports = [
            SportType(type: 1, name: "", shown: true, position: 2), SportType(type: 2, name: "", shown: false, position: 5),
            SportType(type: 9, name: "", shown: true, position: 1), SportType(type: 5, name: "", shown: true, position: 0),
        ]
        let out = try UteSport.normalizeSportList(sports, limits: 1...4)
        XCTAssertEqual(out.map(\.position), [2, 0, 1, 3])
        XCTAssertThrowsError(try UteSport.normalizeSportList(sports, limits: 4...50))
        XCTAssertThrowsError(try UteSport.normalizeSportList(sports, limits: 1...2))
        XCTAssertThrowsError(try UteSport.normalizeSportList(sports + [SportType(type: 1, name: "", shown: false, position: 0)], limits: nil))
    }

    /// Như `UteWorkoutTest.sportListWriteMatchesGloryFit` (Kotlin): dựng lại GloryFit `sendSportManagementListsSection`
    /// (`WriteCommandToBLE.java:4840-4944`) và so từng byte với maxLen 244 và 100.
    func testSportListWriteMatchesGloryFit() throws {
        let supported = Array(1...50)
        let selected = [35, 1, 9, 2]
        func gloryFit(_ maxLen: Int) -> [String] {
            let per = (maxLen - 2) / 3
            var crc: UInt8 = 0
            var out: [String] = []
            for (seq, start) in stride(from: 0, to: supported.count, by: per).enumerated() {
                var p: [UInt8] = [0xFD, 0x48, UInt8(seq)]
                for id in supported[start..<min(supported.count, start + per)] {
                    if let i = selected.firstIndex(of: id) { p += [UInt8(id), 1, UInt8(i + 1)] } else { p += [UInt8(id), 0, 0] }
                }
                for b in p[2...] { crc ^= b }
                out.append(hex(p))
            }
            return out + [hex([0xFD, 0x48, 0xFD, crc])]
        }
        let sports = supported.map { id in
            SportType(type: id, name: "", shown: selected.contains(id), position: (selected.firstIndex(of: id) ?? -1) + 1)
        }
        for len in [244, 100] {
            let ours = UteSport.sportListPackets(try UteSport.normalizeSportList(sports, limits: 4...50), packetLength: len).map(hex)
            XCTAssertEqual(ours, gloryFit(len), "maxLen \(len)")
        }
    }

    func testWorkoutClock() {
        let t0 = Date(timeIntervalSince1970: 1000)
        var c = WorkoutClock(sportType: 1, started: t0)
        c.pause(at: t0.addingTimeInterval(60))
        c.pause(at: t0.addingTimeInterval(70)) // tạm dừng lần nữa không đổi mốc
        c.resume(at: t0.addingTimeInterval(90))
        XCTAssertEqual(120, c.elapsed(at: t0.addingTimeInterval(150)))
        c.pause(at: t0.addingTimeInterval(200))
        XCTAssertEqual(170, c.elapsed(at: t0.addingTimeInterval(260)))
    }

    // MARK: Hệ thống

    func testButtonsAndRejectCall() {
        XCTAssertEqual(.switchScreenButton, UteSystem.parseButton([0xD1, 0x01]))
        XCTAssertEqual(.longPressButton2, UteSystem.parseButton([0xD1, 0x04]))
        XCTAssertEqual(.sosButton, UteSystem.parseButton([0xD1, 0x05]))
        XCTAssertEqual(.longPressButton3, UteSystem.parseButton([0xD1, 0x06]))
        XCTAssertNil(UteSystem.parseButton([0xD1, 0x07]))
        XCTAssertNil(UteSystem.parseButton([0xD1, 0x02]))
        XCTAssertTrue(UteSystem.isRejectCall([0xD1, 0x02]))
        XCTAssertFalse(UteSystem.isRejectCall([0xD1, 0x03]))
        XCTAssertTrue(UteSystem.hangup(y25))
    }

    func testShortcuts() {
        let support: [UInt8] = [0xBE, 0x01, 0x6B, 0x60, 0x00] + [UInt8](repeating: 0, count: 15)
        let status: [UInt8] = [0xBE, 0x02, 0x02, 0x00, 0x00] + [UInt8](repeating: 0, count: 15)
        XCTAssertEqual(0x6B6000, UteSystem.parseShortcutMask(support, sub: 0x01))
        XCTAssertNil(UteSystem.parseShortcutMask(support, sub: 0x02))
        XCTAssertNil(UteSystem.parseShortcutMask(Array(support.prefix(10)), sub: 0x01))
        let s = UteSystem.Shortcuts(support: 0x6B6000, status: UteSystem.parseShortcutMask(status, sub: 0x02)!)
        XCTAssertEqual(s.available, [.setTime, .hour24, .findBand, .raiseHand, .doNotDisturb, .smsRemind, .heartRate24h])
        XCTAssertTrue(s.on(.raiseHand))
        XCTAssertFalse(s.on(.doNotDisturb))
        XCTAssertEqual("BE 01", hex(UteSystem.shortcutSupportRead))
        XCTAssertTrue(UteSystem.shortcuts(y25))
    }

    func testDataStatusAndSyncFrom() {
        let d = UteSystem.DataStatus(raw: [0x00, 0x06, 0x42])
        XCTAssertTrue(d.steps)
        XCTAssertTrue(d.heartRate)
        XCTAssertFalse(d.sleep)
        XCTAssertTrue(d.sportHeartRate)
        XCTAssertTrue(d.heartRate24h)
        XCTAssertFalse(d.ball)
        XCTAssertFalse(UteSystem.DataStatus(raw: []).steps)
        XCTAssertTrue(UteSystem.dataStatusSupported(y25))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        let date = cal.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 8, minute: 30))!
        XCTAssertEqual("F7 FA 07 EA 0A 13 08 1E", hex(UteSystem.syncFrom(0xF7, date, calendar: cal)))
    }

    func testClearAndReset() {
        XCTAssertEqual("37 BA", hex(UteSystem.clearContacts))
        XCTAssertEqual("AD", hex(UteSystem.factoryReset))
        XCTAssertTrue(UteSystem.contactsClearSupported(Ute.Features(groups: [8: 0x000420])))
        XCTAssertFalse(UteSystem.contactsClearSupported(y25))
    }

    func testWatchFaceSlots() {
        XCTAssertEqual("26 09", hex(UteSystem.watchFaceSlotsRead))
        XCTAssertEqual("26 05 00", hex(UteSystem.watchFaceSlotRead(0)))
        XCTAssertEqual("26 08 02", hex(UteSystem.watchFaceSlotDelete(2)))
        let all = UteSystem.parseSlots([
            [0x26, 0x09, 0x00, 0x01, 0x00, 0x00, 0x00, 0x7B, 0x02, 0xFF, 0xFF, 0xFF, 0xFE],
            [0x26, 0x09, 0x01, 0x03, 0x00, 0x01, 0xE2, 0x40],
            [0x26, 0x09, 0xFD],
        ])
        XCTAssertEqual(all, [WatchFaceSlot(index: 1, faceId: 123), WatchFaceSlot(index: 2, faceId: 0xFFFF_FFFE), WatchFaceSlot(index: 3, faceId: 123_456)])
        XCTAssertEqual(UteSystem.parseSlots([[0x26, 0x05, 0x04, 0x00, 0x00, 0x03, 0xE8]]), [WatchFaceSlot(index: 4, faceId: 1000)])
        XCTAssertEqual(UteSystem.parseSlots([[0x26, 0x05, 0x04, 0x00]]), [])
        XCTAssertEqual(.deleted, UteSystem.parseSlotDelete([0x26, 0x08, 0x02, 0x05, 0x01]))
        XCTAssertEqual(.failed, UteSystem.parseSlotDelete([0x26, 0x08, 0x02, 0x05, 0x00]))
        XCTAssertEqual(.nothingToDelete, UteSystem.parseSlotDelete([0x26, 0x08, 0x02, 0x05, 0x02]))
        XCTAssertNil(UteSystem.parseSlotDelete([0x26, 0x08]))
        XCTAssertTrue(UteSystem.watchFaceOnline(y25))
    }

    // MARK: Cài đặt mới

    func testRejectCallBitInDnd() {
        let s = UteSettings().with("dnd.endCall", .bool(true))
        XCTAssertEqual(UteControls.commands("dnd.endCall", y25, s).map(hex), ["D7 0E 16 00 07 00 00"])
        XCTAssertEqual(UteControls.commands("dnd.messages", y25, UteSettings()).map(hex), ["D7 06 16 00 07 00 00"])
        XCTAssertTrue(UteControls.controls(y25, UteSettings()).contains { $0.id == "dnd.endCall" })
        XCTAssertFalse(UteControls.controls(Ute.Features(groups: [1: 0x000008]), UteSettings()).contains { $0.id == "dnd.endCall" })
    }

    func testTimeWindows() {
        let spo2 = UteSettings().with("spo2Range.enabled", .bool(true))
        XCTAssertEqual(UteControls.commands("spo2Range.enabled", y25, spo2).map(hex), ["34 04 01 16 00 07 00"])
        let hr = UteSettings().with("hr24Range.enabled", .bool(true)).with("hr24Range.range", .timeRange(from: 8 * 60, to: 20 * 60 + 30))
        XCTAssertEqual(UteControls.commands("hr24Range.range", y25, hr).map(hex), ["F7 0F 01 08 00 14 1E"])
        let raise = UteSettings().with("raiseRange.enabled", .bool(true))
        XCTAssertEqual(UteControls.commands("raiseRange.enabled", y25, raise).map(hex), ["69 AB 01 05 01 08 00 16 00"])
        let ids = UteControls.controls(y25, UteSettings()).map(\.id)
        for id in ["spo2Range.enabled", "spo2Range.range", "hr24Range.enabled", "hr24Range.range", "raiseRange.enabled", "raiseRange.range"] {
            XCTAssertTrue(ids.contains(id), id)
        }
    }

    func testShortcutControlsAreReadOnly() {
        let s = UteSettings(["shortcut.support": 0x6B6000, "shortcut.status": 0x020000])
        let sc = UteControls.controls(y25, s).filter { $0.group == UteControls.shortcutGroup }
        XCTAssertEqual(7, sc.count)
        XCTAssertTrue(sc.allSatisfy { !$0.enabled })
        XCTAssertEqual(.bool(true), sc.first { $0.id == "shortcut.\(UteSystem.Shortcut.raiseHand.rawValue)" }?.value)
        XCTAssertTrue(UteControls.readOnly("shortcut.131072"))
        XCTAssertFalse(UteControls.readOnly("dnd.endCall"))
        XCTAssertTrue(UteControls.commands("shortcut.131072", y25, s).isEmpty)
        XCTAssertTrue(UteControls.controls(y25, UteSettings()).allSatisfy { $0.group != UteControls.shortcutGroup })
    }

    func testDangerousActionsNeedConfirmation() {
        let base = UteControls.controls(y25, UteSettings())
        XCTAssertNotNil(base.first { $0.id == "data.reset" }?.confirm)
        XCTAssertNil(base.first { $0.id == "contacts.clear" })
        let withContacts = Ute.Features(groups: [1: 0x4BA0CC, 5: 0x002000, 8: 0x000420])
        let clear = UteControls.controls(withContacts, UteSettings()).first { $0.id == "contacts.clear" }
        XCTAssertEqual(.action, clear?.kind)
        XCTAssertNotNil(clear?.confirm)
        XCTAssertNil(base.first { $0.id == "find.start" }?.confirm)
    }
}
