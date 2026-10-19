import SmartWearCore
import XCTest
@testable import SmartWearVeepoo

final class VeepooPhoneTests: XCTestCase {
    func testFindAndCamera() {
        XCTAssertEqual(T.pad([0xB5, 0x0A]), VeepooPhone.findDeviceStart)
        XCTAssertEqual(T.pad([0xB5, 0x0B]), VeepooPhone.findDeviceStop)
        XCTAssertEqual(T.pad([0xB5, 0x02]), VeepooPhone.findPhoneStop)
        XCTAssertTrue(VeepooPhone.isFindPhone(T.pad([0xB5, 0x00])))
        XCTAssertFalse(VeepooPhone.isFindPhone([0xB5, 0x00]))
        XCTAssertFalse(VeepooPhone.isFindPhone(T.pad([0xB5, 0x0A, 0x01])))
        XCTAssertEqual([0xB6, 0x01], VeepooPhone.camera(true))
        XCTAssertEqual([0xB6, 0x00], VeepooPhone.camera(false))
        XCTAssertEqual(.shutter, VeepooPhone.parseCamera(T.hex("B6 01 02 00")))
        XCTAssertEqual(.opened, VeepooPhone.parseCamera(T.hex("B6 01 01 01")))
        XCTAssertNil(VeepooPhone.parseCamera(T.hex("B6 01 01 00")))  // xác nhận lệnh mở của app
        XCTAssertEqual(.closed, VeepooPhone.parseCamera(T.hex("B6 01 00 00")))
        XCTAssertNil(VeepooPhone.parseCamera(T.hex("B6 00 02 00")))  // không chụp được
    }

    func testMusic() {
        let p = VeepooPhone.musicPackets(MusicState(playing: true, title: "Hi", artist: nil))
        XCTAssertEqual([T.pad(T.hex("99 01 01 01 F0 07 A1 02 48 69 A3 01 01"))], p)
        let q = VeepooPhone.musicPackets(MusicState(playing: false, title: String(repeating: "a", count: 20), artist: "B", volumePercent: 150))
        XCTAssertEqual(3, q.count)  // F0 len + A1 20 + A2 1 + A3 + A4 = 2 + 22 + 3 + 3 + 3 = 33 byte
        XCTAssertEqual([0x99, 0x01, 0x01, 0x03, 0xF0, 31], Array(q[0].prefix(6)))
        // A4 01 64 nằm ở byte 30–32 của TLV: cuối gói 2 + đầu gói 3 (âm lượng kẹp 100).
        XCTAssertEqual([0xA4, 0x01], Array(q[1][18...19]))
        XCTAssertEqual(T.pad([0x99, 0x01, 0x03, 0x03, 100]), q[2])
        XCTAssertEqual(T.pad(T.hex("99 01 01 01 F0 03 A4 01 32")), VeepooPhone.volumePackets(50)[0])

        XCTAssertEqual(.playPause, VeepooPhone.parseMusicCommand(T.pad([0x99, 0x02, 0x01])))
        XCTAssertEqual(.playPause, VeepooPhone.parseMusicCommand(T.pad([0x99, 0x02, 0x02])))
        XCTAssertEqual(.previous, VeepooPhone.parseMusicCommand(T.pad([0x99, 0x02, 0x03])))
        XCTAssertEqual(.next, VeepooPhone.parseMusicCommand(T.pad([0x99, 0x02, 0x04])))
        XCTAssertEqual(.volumeUp, VeepooPhone.parseMusicCommand(T.pad([0x99, 0x03, 0x05])))
        XCTAssertEqual(.volumeDown, VeepooPhone.parseMusicCommand(T.pad([0x99, 0x03, 0x06])))
        XCTAssertNil(VeepooPhone.parseMusicCommand([0x99, 0x02, 0x04]))  // gói ngắn
        XCTAssertEqual(.next, VeepooPhone.parseMusicCommand([0x01, 0x01, 0x01, 0x01]))
        XCTAssertEqual(.previous, VeepooPhone.parseMusicCommand([0x01, 0x01, 0x01, 0x04]))
        XCTAssertEqual(.playPause, VeepooPhone.parseMusicCommand([0x01, 0x01, 0x01, 0x02]))
    }

    func testContacts() {
        let r = VeepooPhone.contactRecord(id: 1, name: "An", phone: "0901", sos: nil)
        XCTAssertEqual(T.hex("A0 10 00 A1 01 01 A2 02 41 6E A3 04 30 39 30 31"), r)
        XCTAssertEqual([T.hex("72 01 01 01") + r], VeepooPhone.contactPackets(id: 1, name: "An", phone: "0901", sos: nil))
        let s = VeepooPhone.contactRecord(id: 2, name: "", phone: "1", sos: false)
        XCTAssertEqual(T.hex("A0 0C 00 A1 01 02 A3 01 31 A4 01 00"), s)
        // Tên cắt 20 byte UTF-8, số 22 byte.
        let long = VeepooPhone.contactRecord(id: 3, name: String(repeating: "Đ", count: 15), phone: String(repeating: "9", count: 30), sos: nil)
        XCTAssertEqual(20, Int(long[7]))
        XCTAssertEqual(22, Int(long[8 + 20 + 1]))
        XCTAssertEqual(T.pad([0x72, 0x04, 0x05]), VeepooPhone.contactDelete(id: 5))
        XCTAssertEqual(true, VeepooPhone.isContactSaved(T.pad([0x72, 0x01, 0x01])))
        XCTAssertEqual(false, VeepooPhone.isContactSaved(T.pad([0x72, 0x01, 0x00])))
        XCTAssertNil(VeepooPhone.isContactSaved(T.pad([0x72, 0x02, 0x01])))
        XCTAssertEqual("+84901234567", VeepooPhone.cleanPhone("+84 90-123 (4567)"))
    }

    func testWeather() throws {
        let f = WeatherForecast(city: "Hà Nội", currentC: -3, humidity: 80, uvIndex: 2, days: [
            WeatherDay(condition: .lightRain, highC: 30, lowC: 24),
            WeatherDay(condition: .sunny, highC: 32, lowC: 0),
        ])
        let now = T.date(2026, 10, 19, 14, 5)
        let p = VeepooWeather.payload(f, now: now, calendar: T.calendar)
        XCTAssertEqual(0xF0, p[0])
        XCTAssertEqual(p.count - 3, Veepoo.le16(p, 1))
        // A1 02 crc của phần còn lại.
        XCTAssertEqual([0xA1, 0x02], Array(p[3...4]))
        let rest = Array(p[7...])
        XCTAssertEqual(Veepoo.crc16(rest), Veepoo.le16(p, 5))
        // A2 thành phố đã bỏ dấu.
        XCTAssertEqual([0xA2, 6] + Array("Ha Noi".utf8), Array(rest[0..<8]))
        XCTAssertEqual(T.hex("A3 01 00 A4 05 1A 0A 13 0E 05"), Array(rest[8..<18]))
        // A5: khối giờ hiện tại, nhiệt độ âm ⇒ dấu 0.
        XCTAssertEqual(0xA5, rest[18])
        let hours = Array(rest[21..<(21 + Veepoo.le16(rest, 19))])
        XCTAssertEqual(0xB0, hours[0])
        XCTAssertEqual(T.hex("B1 05 1A 0A 13 0E 05 B2 02 01 1B B3 02 00 03 B4 01 02 B5 01 21"), Array(hours[2..<23]))
        // A6: 2 ngày, ngày 1 mưa nhỏ (33), 30/24 °C.
        let a6At = 21 + hours.count
        XCTAssertEqual(0xA6, rest[a6At])
        let days = Array(rest[(a6At + 3)...])
        XCTAssertEqual(Veepoo.le16(rest, a6At + 1), days.count)
        XCTAssertEqual(T.hex("C1 03 1A 0A 13 C2 04 01 56 01 4B C3 04 01 1E 01 18 C4 01 02 C5 01 21 C6 01 21"), Array(days[2..<28]))
        // Ngày 2: thấp 0 °C ⇒ dấu 0, trị 0.
        let day2 = Array(days[(2 + Int(days[1]))...])
        XCTAssertEqual(T.hex("C0"), [day2[0]])
        XCTAssertEqual(T.hex("C3 04 01 20 00 00"), Array(day2[13..<19]))

        let packets = VeepooWeather.packets(f, now: now, calendar: T.calendar)
        XCTAssertEqual((p.count + 15) / 16, packets.count)
        XCTAssertEqual([0xC8, 0x04, UInt8(packets.count), 0x01], Array(packets[0].prefix(4)))
        XCTAssertEqual(Array(p.prefix(16)), Array(packets[0][4...]))
        XCTAssertEqual(T.pad([0xC8, 0x03, 0x01, 0x00]), VeepooWeather.status(enabled: true))
        XCTAssertEqual(1, VeepooWeather.code(.sunny))
        XCTAssertEqual(113, VeepooWeather.code(.fog))
    }
}

final class VeepooWatchFaceTests: XCTestCase {
    func testPrepare() {
        let (d, crc) = VeepooWatchFace.prepare([1, 2, 3, 4, 5])
        XCTAssertEqual([1, 2, 3, 4, 5, 0xFF, 0xFF, 0xFF], d)
        XCTAssertEqual(Veepoo.crc16(d), crc)
        XCTAssertEqual([1, 2, 3, 4], VeepooWatchFace.prepare([1, 2, 3, 4]).data)
    }

    func testCommands() {
        XCTAssertEqual(T.pad([0x50, 0x02, 0x01]), VeepooWatchFace.infoRead(VeepooWatchFace.typeServer))
        XCTAssertEqual(T.hex("50 01 01 00341200 00100000 0201 EFBE 01 00000000"),
                       VeepooWatchFace.updateModeServer(address: 0x123400, length: 0x1000, binDataType: 0x0102, crc: 0xBEEF))
        XCTAssertEqual(T.hex("444F4F47 05 00"), VeepooWatchFace.doogStart)
        XCTAssertEqual(T.hex("444F4F47 01 00341200 00100000"), VeepooWatchFace.doogErase(address: 0x123400, length: 0x1000))
        XCTAssertEqual(T.pad(T.hex("444F4F47 02")), VeepooWatchFace.doogEnd)
        XCTAssertEqual(T.pad(T.hex("444F4F47 03 EFBE0000")), VeepooWatchFace.doogCheck(crc: 0xBEEF))
        XCTAssertEqual(T.pad([0xC7, 0x01, 0x01, 0x01]), VeepooWatchFace.select(index: 1, from: 1))
        XCTAssertEqual(T.pad([0xC7, 0x02]), VeepooWatchFace.styleRead)
        XCTAssertEqual(242, VeepooWatchFace.chunkSize(maxWriteLength: 244))
        XCTAssertEqual(20, VeepooWatchFace.chunkSize(maxWriteLength: 20))
        XCTAssertEqual(182, VeepooWatchFace.chunkSize(maxWriteLength: 184))
    }

    func testParseInfo() throws {
        let s = try XCTUnwrap(VeepooWatchFace.parseServerInfo(T.hex("50 02 01 01 00341200 00000200 0201 0400 EFBE 00 03")))
        XCTAssertEqual(0x123400, s.address)
        XCTAssertEqual(0x20000, s.maxLength)
        XCTAssertEqual(0x0102, s.binDataType)
        XCTAssertEqual(4, s.dialShape)
        XCTAssertEqual(0xBEEF, s.crcId)
        XCTAssertEqual(3, s.index)
        XCTAssertNil(VeepooWatchFace.parseServerInfo(T.hex("50 02 01 00 00341200 00000200 0201 0400 EFBE 00 03")))
        let c = try XCTUnwrap(VeepooWatchFace.parseCustomInfo(T.hex("50 02 02 01 00100000 00C000 03 00 00 FFFFFF 0000 00")))
        XCTAssertEqual(0x1000, c.address)
        XCTAssertEqual(0xC000, c.maxLength)
        XCTAssertEqual(3, c.uiType)
        XCTAssertEqual(240, VeepooWatchFace.screen(uiType: 3)?.width)
        XCTAssertEqual(280, VeepooWatchFace.screen(uiType: 3)?.height)
        XCTAssertEqual(true, VeepooWatchFace.screen(uiType: 1)?.round)
        XCTAssertNil(VeepooWatchFace.screen(uiType: 53))  // JieLi
        XCTAssertEqual(2, VeepooWatchFace.parseStyle(T.hex("C7 02 01 02 01"))?.index)
        XCTAssertNil(VeepooWatchFace.parseStyle(T.hex("C7 02 00 02 01")))
    }

    func testEvents() {
        XCTAssertEqual(.ready, VeepooWatchFace.parseEvent([0x05, 0x01, 0xA1]))
        XCTAssertEqual(.eraseStarted(16), VeepooWatchFace.parseEvent([0x01, 0x01, 0x10]))
        XCTAssertEqual(.eraseProgress(4), VeepooWatchFace.parseEvent([0x01, 0x02, 0x04]))
        XCTAssertEqual(.eraseDone, VeepooWatchFace.parseEvent([0x01, 0x03, 0x00]))
        XCTAssertEqual(.received, VeepooWatchFace.parseEvent([0x02]))
        XCTAssertEqual(.crc(0xBEEF), VeepooWatchFace.parseEvent([0x03, 0xEF, 0xBE]))
        XCTAssertEqual(.lengthNotMultipleOf4, VeepooWatchFace.parseEvent([0x00]))
        XCTAssertNil(VeepooWatchFace.parseEvent([0x01, 0xD0, 0x01, 0x00, 0x00, 0x00]))  // ghi âm AI
    }
}
