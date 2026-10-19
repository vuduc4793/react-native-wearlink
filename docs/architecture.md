# Kiến trúc SmartWear SDK (Android + iOS)

Mục tiêu: một app/SDK điều khiển **nhiều thiết bị đeo, nhiều loại, cùng lúc**. Mỗi loại thiết bị là một
**driver** (SDK riêng) dựng trên lớp BLE chung. Giao diện sinh hoàn toàn từ **capability** của từng
thiết bị, nên thêm loại mới không cần sửa UI. Android (Kotlin) và iOS (Swift) dùng **cùng mô hình
và cùng tên khái niệm** để sau này bọc thành React Native module với một API JS duy nhất.

```
sdks/
  core/      android/  ios/   BLE chung: scanner, GATT queue, mô hình thiết bị, DeviceManager
  qring/     android/  ios/   driver QRing (Colmi R0x/R1x, HS500A…) + docs/ + research/
  standard/  android/  ios/   driver Bluetooth SIG chuẩn: Battery 180F, Device Info 180A, Heart Rate 180D
apps/
  android/   app SmartWear Lab (Compose)
  ios/       app SmartWear Lab (SwiftUI)
```

## Mô hình chung (tên giữ nguyên trên cả hai nền tảng)

| Khái niệm | Ý nghĩa |
|---|---|
| `Capability` | Enum chuẩn: `HEART_RATE, SPO2, TEMPERATURE, BLOOD_PRESSURE, STRESS, HRV, BLOOD_SUGAR, ECG, STEPS, SLEEP, MENSTRUATION, GESTURE` |
| `ConnectionState` | `DISCONNECTED, CONNECTING, CONNECTED, DISCONNECTING` |
| `ScannedDevice` | Kết quả quét: id (Android: MAC; iOS: UUID của CoreBluetooth), name, rssi, serviceUuids, manufacturerData |
| `DeviceDriver` | Một loại thiết bị: `id` ("qring", "standard"), `displayName`, `match(scanned) -> DriverMatch?` (model đoán được, có hỗ trợ hay không), `create(scanned) -> WearableDevice` |
| `DeviceRegistry` | Danh sách driver theo thứ tự ưu tiên; phân loại kết quả quét (driver cụ thể trước, `standard` sau cùng) |
| `WearableDevice` | Một thiết bị đang quản lý. Thuộc tính quan sát được: `state`, `info` (`DeviceInfo`), `battery`, `capabilities`, `latest` (map Capability → Reading), `stats` (`LinkStats`), `log` (dòng gói tin thô). Hành động: `connect()`, `disconnect()`, `measure(capability) -> stream<Reading>`, `refreshBattery()` |
| `DeviceInfo` | `model`, `hardware`, `firmware`, `extra: [String: String]` (chi tiết kỹ thuật riêng của driver, ví dụ bảng bit QRing, MAC trong manufacturer data) |
| `Reading` | `capability`, `status` (`MEASURING, OK, NOT_WORN, ERROR`), `value` (Double?), `systolic`/`diastolic` (huyết áp), `unit`, `timestamp` |
| `LinkStats` | `rssi`, `packetsReceived`, `packetsPerSecond` (đo thật, cửa sổ trượt 5 s), `errors`, `lastLatencyMs` (thời gian request → phản hồi đầu tiên) |
| `DeviceManager` | Quét (luồng kết quả đã phân loại), giữ danh sách thiết bị, kết nối **song song** nhiều thiết bị, giới hạn mềm `maxConnections = 7`, "đo đồng loạt" một capability trên mọi thiết bị hỗ trợ |

### Hai driver hiện có

**QRing** (`sdks/qring`): giao thức đã giải mã trong `sdks/qring/docs/` (01-connection, 02-commands,
03-history-sync, devices.md với hành vi đã kiểm chứng trên R09 thật). Nhận diện: tên bắt đầu bằng
tiền tố QRing **hoặc** manufacturer data company `0x1234` với payload `FE E7` + MAC 6 byte. Capability
từ phản hồi SetTime (0x01) + DeviceSupport (0x3C). Code Android tham chiếu:
`sdks/qring/android/src/main/java/com/smartwear/qring/` (Packet, BigDataFrame, QRingClient, Measurement,
QRingCapabilities).

**Standard** (`sdks/standard`): thiết bị hỗ trợ dịch vụ Bluetooth SIG chuẩn. Nhận diện: quảng bá
`180D` (Heart Rate) hoặc `180F` (Battery) và không khớp driver cụ thể nào. Sau khi kết nối:
- Battery `180F/2A19`: đọc + notify (% pin).
- Device Information `180A`: `2A24` model, `2A29` hãng, `2A26` FW, `2A27` HW, `2A28` SW.
- Heart Rate `180D/2A37` (nếu có): notify; byte 0 là flags, bit 0 = 1 ⇒ HR là UInt16 LE, ngược lại UInt8.
  Capability `HEART_RATE` chỉ có khi thiết bị thật sự có service 180D.

## Quy tắc

- Mọi thao tác GATT tuần tự trên một thiết bị (chờ callback), nhưng **song song giữa các thiết bị**.
- Có timeout cho mọi request (SDK gốc QRing không có).
- Không lọc thiết bị chỉ bằng `FEE7` (đồng hồ COROS cũng phát FEE7).
- iOS ẩn MAC: dùng UUID CoreBluetooth làm id. Với QRing, lấy MAC thật từ manufacturer data để hiển thị và đối chiếu.
- Dữ liệu chưa đo được thì hiển thị "chưa đo", không bịa số.

## Thiết bị test

| Thiết bị | Driver | Id |
|---|---|---|
| Colmi R09 (nhẫn) | qring | MAC `30:32:43:31:84:04` |
| HS500A | qring | MAC `32:35:45:37:4E:00` |
| COROS PACE 3 (đồng hồ) | standard (pin + device info; HR chỉ khi đồng hồ bật chế độ phát nhịp tim) | MAC `F7:AF:2F:22:09:90` |

Build: Android và iOS đều build trên MacBook Pro (`ssh ducvu@cs-macbook-pro`). Android dùng điện thoại
Redmi (adb). iOS dùng iPhone thật đã ghép đôi (máy ảo iOS không có Bluetooth).
