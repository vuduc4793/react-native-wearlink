import CoreBluetooth
import Foundation
import SmartWearCore

/// Lệnh hệ thống lẻ (doc 10 §2.1, §2.5, §2.6, §2.7, §2.8): nút đồng hồ, phím tắt nhanh, trạng thái dữ liệu, đồng bộ từ
/// mốc thời gian, xoá danh bạ, xoá dữ liệu, khe mặt đồng hồ. Viết tắt `T` = `P/uterkif/uterkthis.java`.
public enum UteSystem {
    // MARK: Nút đồng hồ `D1 xx` (Pro `uterkfor/uterkchar.java:139-170`)

    /// `D1 01` đổi màn (`PRESS_SWITCH_SCREEN_BUTTON`), `D1 04` / `D1 06` giữ phím 2 / 3 (`LONG_PRESS_BUTTON_SECOND/THIRD`),
    /// `D1 05` nút SOS (`PRESS_SOS_BUTTON`, Y25 không có SOS). Hằng: `com/yc/utesdk/listener/SimpleCallbackListener.java`.
    public static func parseButton(_ p: [UInt8]) -> DeviceEvent? {
        guard p.count >= 2, p[0] == 0xD1 else { return nil }
        switch p[1] {
        case 0x01: return .switchScreenButton
        case 0x04: return .longPressButton2
        case 0x05: return .sosButton
        case 0x06: return .longPressButton3
        default: return nil
        }
    }

    /// `D1 02`: người dùng bấm từ chối cuộc gọi trên đồng hồ (`uterkchar.java:150-152` → `onCallRemindStatus(1004)`).
    public static func isRejectCall(_ p: [UInt8]) -> Bool { p.count >= 2 && p[0] == 0xD1 && p[1] == 0x02 }

    /// `isHasHangup` (33F1 b17.6 = F1 `0x400000`): đồng hồ có nút từ chối cuộc gọi.
    public static func hangup(_ f: Ute.Features) -> Bool { f.has(1, 0x400000) }

    // MARK: Phím tắt nhanh `BE 01/02` (33F1, chỉ đọc)

    /// `isHasShortcutButton` (33F1 b8.0 = F4 `0x10000`).
    public static func shortcuts(_ f: Ute.Features) -> Bool { f.has(4, 0x010000) }
    public static let shortcutSupportRead: [UInt8] = [0xBE, 0x01]
    public static let shortcutStatusRead: [UInt8] = [0xBE, 0x02]

    /// Phím tắt trên đồng hồ (`ShortcutUtils.SUPPORT_LIST_*`).
    public enum Shortcut: Int, CaseIterable, Sendable {
        case setTime = 0x002000
        case hour24 = 0x004000
        case findBand = 0x010000
        case raiseHand = 0x020000
        case sedentary = 0x040000
        case doNotDisturb = 0x080000
        case antiLost = 0x100000
        case smsRemind = 0x200000
        case heartRate24h = 0x400000
        case screenOffTime = 0x800000

        public var title: String {
            switch self {
            case .setTime: "Đặt giờ trên đồng hồ"
            case .hour24: "Định dạng 24 giờ"
            case .findBand: "Tìm đồng hồ"
            case .raiseHand: "Nâng tay sáng màn hình"
            case .sedentary: "Nhắc vận động"
            case .doNotDisturb: "Không làm phiền"
            case .antiLost: "Chống thất lạc"
            case .smsRemind: "Báo tin nhắn"
            case .heartRate24h: "Đo nhịp tim tự động"
            case .screenOffTime: "Thời gian sáng màn hình"
            }
        }
    }

    /// `BE 01|02` + 18 byte: 3 byte đầu (BE) là mặt nạ (`ShortcutUtils.saveShortcutSupList` / `queryShortcutStatus`
    /// đọc 6 ký tự hex đầu của 36). nil nếu không phải gói `BE sub` 20 byte.
    public static func parseShortcutMask(_ p: [UInt8], sub: UInt8) -> Int? {
        guard p.count == 20, p[0] == 0xBE, p[1] == sub else { return nil }
        return Ute.be24(p, 2)
    }

    /// Phím tắt đồng hồ có (`support`) và đang bật (`status`).
    public struct Shortcuts: Equatable, Sendable {
        public var support: Int
        public var status: Int
        public init(support: Int, status: Int) {
            self.support = support
            self.status = status
        }
        public var available: [Shortcut] { Shortcut.allCases.filter { support & $0.rawValue != 0 } }
        public func on(_ s: Shortcut) -> Bool { status & s.rawValue != 0 }
    }

    // MARK: Trạng thái dữ liệu `33F3` (chỉ SDK iOS gốc)

    /// Characteristic đọc trạng thái dữ liệu (`-[UTESmartBandClient readDeviceDataStatus:]`, doc 09 §1.6).
    public static let dataStatusCharacteristic = CBUUID(string: "33F3")
    /// `isHasDataStatus` (33F1 b9.5 = F4 `0x2000`).
    public static func dataStatusSupported(_ f: Ute.Features) -> Bool { f.has(4, 0x002000) }

    /// Kết quả đọc `33F3`. Ý nghĩa bit lấy từ `receiveDeviceDataStatus:` (doc 10 §2.1): byte cuối bit0 GPS, 1 bước,
    /// 2 ngủ, 3 bơi, 4 nhảy dây, 5 HA, 6 HR, 7 xe đạp; byte áp chót bit0 bóng, 1 HR thể thao, 2 HR 24h, 3 body fat.
    /// "Bit = có dữ liệu chưa đồng bộ" là **suy luận**, chưa đọc trên Y25 (doc 10 §4 V2).
    public struct DataStatus: Equatable, Sendable {
        public var raw: [UInt8]
        var last: UInt8 { raw.last ?? 0 }
        var second: UInt8 { raw.count >= 2 ? raw[raw.count - 2] : 0 }
        public var gps: Bool { last & 0x01 != 0 }
        public var steps: Bool { last & 0x02 != 0 }
        public var sleep: Bool { last & 0x04 != 0 }
        public var swim: Bool { last & 0x08 != 0 }
        public var skipRope: Bool { last & 0x10 != 0 }
        public var bloodPressure: Bool { last & 0x20 != 0 }
        public var heartRate: Bool { last & 0x40 != 0 }
        public var bicycle: Bool { last & 0x80 != 0 }
        public var ball: Bool { second & 0x01 != 0 }
        public var sportHeartRate: Bool { second & 0x02 != 0 }
        public var heartRate24h: Bool { second & 0x04 != 0 }
        public var bodyFat: Bool { second & 0x08 != 0 }
        public init(raw: [UInt8]) { self.raw = raw }
    }

    // MARK: Đồng bộ từ mốc thời gian

    /// `[op] FA YYYY MM DD HH mm` (`O/utils/SyncDateUtils.java:123-170`, khi có F4 `0x2000`): chỉ lấy bản ghi từ mốc.
    /// Chưa dùng trong `syncHistory` (chưa kiểm trên Y25, doc 10 §4 V2/V4).
    public static func syncFrom(_ op: UInt8, _ date: Date, calendar: Calendar = .current) -> [UInt8] {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let y = c.year ?? 2000
        return [op, 0xFA, UInt8(truncatingIfNeeded: y >> 8), UInt8(truncatingIfNeeded: y),
                UInt8(c.month ?? 1), UInt8(c.day ?? 1), UInt8(c.hour ?? 0), UInt8(c.minute ?? 0)]
    }

    // MARK: Xoá

    /// `isHasContactDel` (34F1 b18.2 = F8 `0x400`): xoá hết danh bạ.
    public static func contactsClearSupported(_ f: Ute.Features) -> Bool { f.has(8, 0x000400) }
    /// `37 BA` (34F1) → đồng hồ trả `37 BA` (`T:1158-1161`; parser `uterkfinal.java:365-369` → `onContactsSyncStatus(4)`).
    public static let clearContacts: [UInt8] = [0x37, 0xBA]
    /// `AD` (33F1): xoá dữ liệu / khôi phục gốc (`T:1286`, Pro `MainDeviceModelImpl.java:96-97`). Không có gói trả lời:
    /// Pro báo xong theo write callback (`uterktry.java:688-689`).
    public static let factoryReset: [UInt8] = [0xAD]

    // MARK: Khe mặt đồng hồ `26 05 / 26 08 / 26 09` (33F1)

    /// `isHasSwitchDialOnline` (33F1 b12.0 = F3 `0x100`): cài / quản lý mặt đồng hồ online.
    public static func watchFaceOnline(_ f: Ute.Features) -> Bool { f.has(3, 0x000100) }

    /// `26 09`: hỏi mọi khe (GloryFitPro `queryAllWatchFaceInfo`, dùng trước khi xoá: `UteBleConnectionRkImpl.java:2144-2147`).
    /// Đồng hồ trả `26 09 seq <bản ghi>` …, kết thúc `26 09 FD` (`watchface/close/uterkelse.java:127-140`).
    public static let watchFaceSlotsRead: [UInt8] = [0x26, 0x09]
    /// `26 05 n`: hỏi khe `n` (`queryWhichWatchFaceInfo`, app không gọi; ý nghĩa `n` chưa rõ). Trả `26 05 <bản ghi>`.
    public static func watchFaceSlotRead(_ n: Int) -> [UInt8] { [0x26, 0x05, UInt8(truncatingIfNeeded: n)] }
    /// `26 08 n`: xoá khe `n` (= `displayIndex` đọc từ `26 09`) → `26 08 n max state` (`T:3260-3263`, `uterkelse.java:113-127`).
    public static func watchFaceSlotDelete(_ n: Int) -> [UInt8] { [0x26, 0x08, UInt8(truncatingIfNeeded: n)] }

    /// Bản ghi 5 byte `[displayIndex][id u32 BE]` (`uterkelse.uterkdo(byte[])`).
    public static func parseSlotRecords(_ data: [UInt8]) -> [WatchFaceSlot] {
        stride(from: 0, to: data.count - 4, by: 5).map { i in
            WatchFaceSlot(index: Int(data[i]), faceId: Ute.be32(data, i + 1))
        }
    }

    /// Ghép luồng `26 09 seq …` (bỏ 3 byte đầu mỗi gói; seq 0 bắt đầu lại) hoặc một gói `26 05 …` (bỏ 2 byte đầu).
    public static func parseSlots(_ packets: [[UInt8]]) -> [WatchFaceSlot] {
        var data: [UInt8] = []
        for p in packets where p.count >= 2 && p[0] == 0x26 {
            if p[1] == 0x05 { data += p.dropFirst(2) }
            if p[1] == 0x09, p.count >= 3, p[2] != 0xFD {
                if p[2] == 0 { data = [] }
                data += p.dropFirst(3)
            }
        }
        return parseSlotRecords(data)
    }

    /// Kết quả xoá khe `26 08 n max state`: state `01` xoá được (`DELETE_WATCH_FACE_SUCCESS`), `00` lỗi, khác = không
    /// có mặt để xoá (`NO_WATCH_FACE_CAN_DELETE`). jadx rã luồng nhánh này, ánh xạ trên theo tên hằng (**suy luận**).
    public enum SlotDeleteResult: Equatable, Sendable { case deleted, failed, nothingToDelete }

    public static func parseSlotDelete(_ p: [UInt8]) -> SlotDeleteResult? {
        guard p.count >= 5, p[0] == 0x26, p[1] == 0x08 else { return nil }
        switch p[4] {
        case 0x01: return .deleted
        case 0x00: return .failed
        default: return .nothingToDelete
        }
    }
}
