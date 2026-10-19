import CoreBluetooth
import Foundation
import SmartWearCore

/// Hằng số và bộ lọc quét cho dòng nhẫn chạy app QRing (Colmi R0x/R1x, HS500A, Yawell…).
public enum QRing {
    public static let service = CBUUID(string: "6E40FFF0-B5A3-F393-E0A9-E50E24DCCA9E")
    public static let write = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    public static let notify = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")

    public static let bigDataService = CBUUID(string: "DE5BF728-D711-4E47-AF26-65E3012A5DC7")
    public static let bigDataNotify = CBUUID(string: "DE5BF729-D711-4E47-AF26-65E3012A5DC7")
    public static let bigDataWrite = CBUUID(string: "DE5BF72A-D711-4E47-AF26-65E3012A5DC7")

    public static let deviceInfo = CBUUID(string: "180A")
    public static let firmwareRevision = CBUUID(string: "2A26")
    public static let hardwareRevision = CBUUID(string: "2A27")
    /// System ID 8 byte, MAC = `b7:b6:b5:b2:b1:b0` (app QRing iOS bước 5.0).
    public static let systemId = CBUUID(string: "2A23")

    /// Service 16-bit nhẫn phát khi quảng bá (FEE7). Service 6e40fff0 chỉ thấy sau khi kết nối.
    public static let advertisedService = CBUUID(string: "FEE7")

    /// Tiền tố tên trong app QRing (server có thể bổ sung, nên danh sách này không đủ).
    /// Bỏ "Y25" như bản Android: Y25 của người dùng chạy app GloryFit (driver `gloryfit`), không phải QRing.
    /// Xem sdks/qring/docs/01-connection.md §1.2.
    public static let namePrefixes = [
        "R0", "R1", "RING1", "boAtring", "Hello Ring", "MERLIN", "VK-5098", "H59", "DS1314", "DS520", "DS12", "DS500",
    ]

    /// Manufacturer data nhẫn phát khi quảng bá: company id 0x1234, payload `FE E7` + 6 byte MAC
    /// (R09: `FE E7 30 32 43 31 84 04` ứng với MAC 30:32:43:31:84:04; HS500A: `FE E7 32 35 45 37 4E 00`).
    public static let manufacturerId: UInt16 = 0x1234

    /// Không lọc theo FEE7 đơn thuần vì nhiều thiết bị khác cũng phát UUID này (vd đồng hồ COROS).
    public static func matches(_ device: ScannedDevice) -> Bool {
        let name = device.name ?? ""
        // Thiết bị iOS đang giữ kết nối (lấy qua retrieveConnected) không có dữ liệu quảng bá: nhận theo dịch vụ GATT riêng.
        let ownService = device.serviceUuids.contains(service) || device.serviceUuids.contains(bigDataService)
        return namePrefixes.contains { name.hasPrefix($0) } || macFromAdvertisement(device) != nil || ownService
    }

    /// MAC lấy từ manufacturer data, dùng được trên iOS (nơi CoreBluetooth ẩn MAC).
    public static func macFromAdvertisement(_ device: ScannedDevice) -> String? {
        guard let data = device.manufacturerData[manufacturerId] else { return nil }
        let b = [UInt8](data)
        guard b.count >= 8, b[0] == 0xFE, b[1] == 0xE7 else { return nil }
        return b[2..<8].map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    /// Tiền tố tên vòng tay (band) trong dòng QRing (DS500 của người dùng, HS500A…).
    static let bandPrefixes = ["DS500", "DS520", "DS12", "DS1314", "HS500", "H59"]

    /// Đoán loại vật lý theo tên (chỉ để hiển thị), không phân biệt hoa thường.
    static func guessKind(_ name: String?) -> DeviceKind {
        let n = (name ?? "").uppercased()
        if n.hasPrefix("R0") || n.hasPrefix("R1") || n.contains("RING") { return .ring }
        if bandPrefixes.contains(where: { n.hasPrefix($0) }) { return .band }
        return .unknown
    }

    /// Đoán loại theo chuỗi 2A27 sau khi kết nối ("HS500A_V1.0" → band, "RT09_V3.1" → ring). nil = không rõ.
    static func kind(fromHardware hw: String) -> DeviceKind? {
        let model = (hw.split(separator: "_").first.map(String.init) ?? "").uppercased()
        guard !model.isEmpty else { return nil }
        if model.hasPrefix("RT0") || model.hasPrefix("RT1") { return .ring }
        let k = guessKind(model)
        return k == .unknown ? nil : k
    }
}
