# 02 — Giao thức lệnh 16 byte (đo real-time & cài đặt)

> Nguồn: APK QRing đã decompile bằng jadx (`sdks/qring/research/jadx-out/sources`). SDK của hãng nằm ở `com/oudmon/ble`, app nằm ở `com/qcwireless/smart`.
> Phạm vi tài liệu này: khung lệnh/phản hồi 16 byte, các lệnh đo real-time và cài đặt, các thông báo chủ động từ thiết bị.
> **Không** bao gồm đồng bộ lịch sử/large-data (sleep, steps detail, HR history, `LargeDataHandler`…) — xem tài liệu khác.
>
> Quy ước:
> - Ghi chú **(suy luận)** = suy ra từ ngữ cảnh/tên biến, không đọc trực tiếp trong code.
> - Viết tắt đường dẫn trích dẫn:
>   - `C/` = `com/oudmon/ble/base/communication/`
>   - `B/` = `com/oudmon/ble/base/bluetooth/`
>   - `APP/` = `com/qcwireless/smart/`
> - `pkt[i]` = byte thứ i của gói 16 byte (0..15). `p[i]` = byte thứ i của **payload** mà lớp `*Rsp.acceptData()` nhận, tức `p[i] = pkt[i+1]` (xem §1.5).

---

## 1. Tầng vận chuyển và khung gói

### 1.1 GATT

| Mục | Giá trị | Trích dẫn |
|---|---|---|
| Service | `6e40fff0-b5a3-f393-e0a9-e50e24dcca9e` | `C/Constants.java:103` |
| Write (phone → ring) | `6e400002-b5a3-f393-e0a9-e50e24dcca9e` | `C/Constants.java:105` |
| Notify (ring → phone) | `6e400003-b5a3-f393-e0a9-e50e24dcca9e` (`UUID_READ`) | `C/Constants.java:104` |
| Bật notify | `EnableNotifyRequest(UUID_SERVICE, UUID_READ)` ngay sau khi discover service; nếu sau 4 s chưa có callback thì thử lại | `B/BleOperateManager.java:247-258, 322-334, 90-106` |
| Kiểu ghi | `WRITE_TYPE_DEFAULT` (có response, `setWriteType(2)`); `LocalWriteRequest` dùng constructor mặc định `noRsp=false` | `request/WriteRequest.java:12-16, 28` |
| FW / HW version | Đọc Device Information Service `0x180A`: char `0x2A26` (Firmware Revision), `0x2A27` (Hardware Revision). Không đi qua giao thức 16 byte | `C/CommandHandle.java:65-71`, `C/Constants.java:107-109`, `B/BleOperateManager.java:139-142` |
| Hàng đợi | Mọi request được tuần tự hoá trên một `HandlerThread`, chờ callback GATT (timeout 5 s) trước khi gửi lệnh tiếp | `B/BleOperateManager.java:337-380` |
| Kênh phụ | Serial port service `de5bf728-…` (Jieli/RTK SPP, nhạc/âm thanh) — ngoài phạm vi | `C/Constants.java:111-113` |

Lưu ý: SDK chỉ cho phép ghi khi cờ `ready=true` (`B/BleOperateManager.java:345`), cờ này được bật sau khi đọc xong FW/HW version (app gọi `setReady`). Thiết bị thật không cần điều này — chỉ là logic phía app.

### 1.2 Khung 16 byte

`Constants.CMD_DATA_LENGTH = 16` (`C/Constants.java:114`).

| Byte | Ý nghĩa |
|---|---|
| `pkt[0]` | Command id (`key`). Ở phản hồi, bit 7 (`0x80`) là cờ lỗi (`FLAG_MASK_ERROR = 128`, `C/Constants.java:115`) |
| `pkt[1..14]` | Payload (`subData`), tối đa 14 byte, phần thừa đệm `0x00` |
| `pkt[15]` | Checksum |

Cả request lẫn response đều đúng 16 byte. Gói nhận được có độ dài khác 16 hoặc sai checksum sẽ bị bỏ qua im lặng (`B/QCBluetoothCallbackReceiver.java:19`).

### 1.3 Checksum (đọc trực tiếp)

```java
// C/req/BaseReqCmd.java:15-21  (gửi)
private void addCRC(byte[] bArr) {
    int i = 0;
    for (int i2 = 0; i2 < bArr.length - 1; i2++) i += bArr[i2];
    bArr[bArr.length - 1] = (byte) (i & 255);
}
// B/QCDataParser.java:16-22  (nhận)
public static boolean checkCrc(byte[] bArr) {
    int i = 0;
    for (int i2 = 0; i2 < bArr.length - 1; i2++) i += bArr[i2];
    return bArr[bArr.length - 1] == ((byte) (i & 255));
}
```

→ `pkt[15] = (pkt[0] + pkt[1] + … + pkt[14]) mod 256`. Cộng byte có dấu rồi `& 0xFF` cho kết quả giống hệt cộng không dấu mod 256. Đây **không** phải CRC thật mà là tổng 8 bit.

### 1.4 Xây request

```java
// C/req/BaseReqCmd.java:23-32
public byte[] getData() {
    byte[] bArr = new byte[16];
    bArr[0] = this.key;
    byte[] subData = getSubData();
    if (subData != null) System.arraycopy(subData, 0, bArr, 1, subData.length);
    addCRC(bArr);
    return bArr;
}
```

Các lớp cơ sở:

| Lớp | Hành vi | Trích dẫn |
|---|---|---|
| `BaseReqCmd(byte key)` | Lớp trừu tượng; lớp con cài `getSubData()` | `C/req/BaseReqCmd.java` |
| `MixtureReq` | `getSubData()` trả về trường `subData` (thường là `{action, …}`) | `C/req/MixtureReq.java` |
| `SimpleKeyReq(byte)` | Không có payload — gói chỉ có cmd + checksum. App dùng cho cmd `3` (battery), `13`, `38` (đọc sedentary), `72` | `C/req/SimpleKeyReq.java` |

Gửi: `CommandHandle.executeReqCmd(req, callback)` lưu `LocalWriteRequest` vào map với khoá `pkt[0] & ~0x80` rồi ghi xuống characteristic (`C/CommandHandle.java:43-55`). `executeReqCmdNoCallback` chỉ ghi, không đăng ký callback (`:57-63`).

Cảnh báo: payload dài hơn 14 byte sẽ ném `ArrayIndexOutOfBoundsException` trong `System.arraycopy` (ví dụ `MusicSwitchReq.getNewWriteInstance` với tên bài hát dài hơn 11 byte). Riêng payload dài đúng 15 byte (`BindAncsReq` với tên model 13 byte) thì byte cuối bị checksum ghi đè.

### 1.5 Nhận và phân phối phản hồi

Luồng xử lý (`B/QCBluetoothCallbackReceiver.java:18-23`):

1. Kiểm tra `len == 16` và checksum.
2. `QCDataParser.parserAndDispatchReqData(pkt)` (`B/QCDataParser.java:46-72`):
   - `key = pkt[0] & ~0x80`.
   - Tìm `LocalWriteRequest` đang chờ với `key`. Nếu có callback thì `BeanFactory.createBean(key)` tạo lớp Rsp tương ứng.
   - Gọi `rsp.acceptData(Arrays.copyOfRange(pkt, 1, 15))`. **Payload truyền vào là `pkt[1..14]` (14 byte), đã bỏ cmd và checksum.** Mọi chỉ số `bArr[i]` trong các lớp `*Rsp` đều ứng với `pkt[i+1]`.
   - Nếu `acceptData` trả `true` thì đây là phản hồi nhiều gói: đối tượng Rsp được giữ trong `tempRspDataSparseArray` để ghép gói tiếp theo. Trả `false` thì gói đã xong, gọi `callback.onDataResponse(rsp)`.
   - **Entry trong map không bị xoá sau khi phản hồi** (chỉ xoá khi mất kết nối `B/BleOperateManager.java:236`, hoặc bị request mới cùng key ghi đè). Vì vậy mọi gói cùng cmd đến sau (ví dụ chuỗi gói `0x69` khi đo nhịp tim) vẫn được đưa vào callback cũ.
3. Nếu bước 2 không xử lý được thì chuyển sang `parserAndDispatchNotifyData(notifySparseArray, pkt)` (`B/QCDataParser.java:24-44`) với các listener chủ động đăng ký theo cmd.

Listener notify mặc định (`B/BleOperateManager.java:110-114`):

| cmd | Listener | Ghi chú |
|---|---|---|
| 29 `0x1D` | `MusicCommandListener` | Ring điều khiển nhạc trên điện thoại |
| 2 `0x02` | `InnerCameraNotifyListener` | Nút chụp ảnh |
| 47 `0x2F` | `PackageLengthListener` | MTU/độ dài gói large-data |
| 115 `0x73` | `DeviceNotifyListener` | Thông báo đa năng từ thiết bị (§5) |
| 120 `0x78` | `DeviceSportNotifyListener` | Trạng thái thể thao |

App đăng ký thêm qua `addNotifyListener`: `34` (find phone, `APP/QCApplication.java:400`), `105` (one-key check), `-223` (= `0xA1`, xem §1.6).

`BeanFactory.createBean` (`B/BeanFactory.java:51-165`) chỉ ánh xạ các cmd sau thành lớp Rsp:
`1, 2, 3, 5, 6, 10, 12, 13, 17, 20, 21, 22, 25, 26, 29, 30, 31, 33, 34, 38, 40, 44, 47, 50, 54, 55, 56, 57, 58, 59, 60, 67, 68, 72, 82, 97, 105, 114, 115, 119, 120→DeviceNotifyRsp, 122, 123, -223(0xA1)`.
Các cmd khác (ví dụ 4, 9, 18, 23, 27, 28, 36, 41, 42, 48, 106, 117, 118) **không có mapping**: SDK không parse phản hồi và callback không bao giờ được gọi. Layout phản hồi ghi trong tài liệu này cho các cmd đó lấy từ lớp Rsp tương ứng (vốn tồn tại nhưng không được nối) **(suy luận)**.

### 1.6 Cờ lỗi `0x80`: hành vi thực tế

- `BaseRspCmd.status` **không bao giờ được set** ở bất kỳ đâu trong SDK (grep `setStatus` / `.status =` không có kết quả trong `com/oudmon/ble` ngoài định nghĩa), nên `getStatus()` luôn trả `0`. App kiểm tra `getStatus()==0` nhưng điều kiện này luôn đúng.
- Khoá được tính bằng `pkt[0] & (~128)` trên **byte có dấu đã sign-extend thành int**. Hệ quả (theo ngữ nghĩa Java, đọc trực tiếp từ `B/QCDataParser.java:25,48`, `C/CommandHandle.java:48`):
  - cmd `< 0x80`: khoá = cmd. Bình thường.
  - Byte `≥ 0x80` cho khoá âm: `0x83` → `0xFFFFFF83 & 0xFFFFFF7F = 0xFFFFFF03 = -253`. Vì vậy **phản hồi lỗi `0x80|cmd` không khớp với request `cmd` và bị bỏ qua im lặng**; phía app chỉ thấy timeout.
  - Lệnh có id `≥ 0x80` vẫn hoạt động vì request dùng cùng phép tính: `0xA1` → khoá `-223`. Đây chính là `case -223` trong `BeanFactory` và `addNotifyListener(-223, …)` trong app. Tương tự `0xFF` (factory reset) → `-129`, `0xC9` → `-183`, `0xCA` → `-182`.
- Khuyến nghị cho SDK mới: tính `key = pkt[0] & 0x7F`, `isError = (pkt[0] & 0x80) != 0` trên giá trị **không dấu**, và trả lỗi về cho request đang chờ (cách SDK gốc đáng lẽ phải làm) **(suy luận)**.

### 1.7 Thứ tự byte (endianness): không thống nhất

| Helper | Thứ tự | Dùng ở |
|---|---|---|
| `ByteUtil.bytesToInt(byte[])` (`C/utils/ByteUtil.java:122-136`) | **Little-endian** | `TargetSettingRsp`, `SetTimeRsp` width/height, `DeviceAvatarRsp`, notify 115 type 56 |
| `DataTransferUtils.intToBytes/shortToBytes` (`qc_utils/bytes/DataTransferUtils.java:52-58`), `DataParseUtils.intToByteArray`, `ByteUtil.intToByte(i,4)` | **Little-endian** | `TargetSettingReq`, `WeatherForecastReq`, `PhoneGpsReq` |
| `BLEDataFormatUtils.bytes2Int` (`C/utils/BLEDataFormatUtils.java:9-16`) | **Big-endian** | notify 115 type 18 (bước chân real-time), `TodaySportDataRsp` |
| `decimalToBCD` / `BCDToDecimal` (`C/utils/BLEDataFormatUtils.java:5-7, 18-20`) | BCD | Set time, alarm, sedentary |

---

## 2. Mẫu sub-command (byte action)

Phần lớn lệnh cài đặt (`MixtureReq`) dùng `pkt[1]` làm **action**:

| `pkt[1]` | Ý nghĩa | Hằng số |
|---|---|---|
| `0x01` | Đọc (READ) | `MixtureRsp.ACTION_READ=1`, `HrvSettingReq.ACTION_READ=1` |
| `0x02` | Ghi (WRITE) | `ACTION_WRITE=2` |
| `0x03` | Xoá (DELETE), hoặc "ring read" với cmd 5 | `ACTION_DELETE=3`, `ACTION_RING_READ=3` |
| `0x04` | Ghi mở rộng (cmd 5 dạng ring) | `PalmScreenReq` 7 tham số |

Nguồn: `C/rsp/MixtureRsp.java:5-8`.

`MixtureRsp.acceptData` (`C/rsp/MixtureRsp.java:12-19`): lưu `action = p[0]`; **chỉ khi `action == 1` hoặc `3` mới gọi `readSubData`**. Phản hồi của lệnh ghi (`p[0]=2`) chỉ là ACK, không mang dữ liệu.

Bool trong lệnh cài đặt có hai kiểu mã hoá, tuỳ lệnh:
- Kiểu A: `1 = bật`, `2 = tắt` (cmd 5, 6, 9, 18, 22, 25, 28, 41). Riêng cmd 10 dùng `0/1` (xem §4.7).
- Kiểu B: `1 = bật`, `0 = tắt` (cmd 12, 44, 48, 54, 56, 58, 118).

Các ngoại lệ không theo mẫu action:
- cmd 117 (dial index), 118 (battery saving): `0 = đọc`, `1 = ghi`.
- cmd 58 (sugar/lipids/temperature): `pkt[1] = type`, `pkt[2] = action`.
- cmd 82 / 123 (Muslim): `pkt[1..2]` là cặp `(action, sub-type)`.
- cmd 105 / 106 / 30 / 2 / 80 / 1 / 4 / 3: không có byte action.

---

## 3. Bảng tổng hợp lệnh

Cột "BF" cho biết cmd có được ánh xạ trong `BeanFactory` hay không (✓ = SDK parse phản hồi).

| Dec | Hex | Hằng (`Constants`) | Lớp Req | Lớp Rsp | BF | Mục đích |
|---|---|---|---|---|---|---|
| 1 | 01 | CMD_SET_DEVICE_TIME | `SetTimeReq` | `SetTimeRsp` | ✓ | Đặt giờ + ngôn ngữ; phản hồi chứa cờ tính năng |
| 2 | 02 | CMD_TAKING_PICTURE | `CameraReq` | `CameraNotifyRsp` | ✓ | Camera / chụp ảnh từ xa |
| 3 | 03 | CMD_GET_DEVICE_ELECTRICITY_VALUE | `SimpleKeyReq(3)` | `BatteryRsp` | ✓ | Pin |
| 4 | 04 | CMD_SET_PHONE_OS | `BindAncsReq` | — | ✗ | Khai báo OS/model điện thoại |
| 5 | 05 | CMD_FANWAN / Intell_time | `PalmScreenReq` | `PalmScreenRsp` | ✓ | Nâng tay sáng màn hình / cài đặt màn hình ring |
| 6 | 06 | CMD_MUTE | `DndReq` | `DndRsp` | ✓ | Không làm phiền |
| 7 | 07 | CMD_GET_STEP_TOTAL_SOMEDAY | `ReadTotalSportDataReq` | `TotalSportDataRsp` | ✗ | (lịch sử, ngoài phạm vi) |
| 8 | 08 | CMD_RE_BOOT | `SimpleKeyPowerOffReq` | — | ✗ | Tắt nguồn / reboot |
| 9 | 09 | CMD_INTELL | `IntellReq` | `IntellRsp` | ✗ | "Intell" (bật/tắt + độ trễ giây) — chức năng chưa rõ |
| 10 | 0A | CMD_GET_TIME_SETTING | `TimeFormatReq` | `TimeFormatRsp` | ✓ | 12/24h, đơn vị, hồ sơ người dùng |
| 12 | 0C | CMD_BP_TIMING_MONITOR_SWITCH | `BpSettingReq` | `BpSettingRsp` | ✓ | Đo huyết áp tự động |
| 13 | 0D | CMD_BP_TIMING_MONITOR_DATA | `SimpleKeyReq(13)` | `BpDataRsp` | ✓ | Dữ liệu BP tự động (nhiều gói) |
| 14 | 0E | CMD_BP_TIMING_MONITOR_CONFIRM | `BpReadConformReq` | — | ✗ | Xác nhận đã đọc BP (`0x00` OK / `0xFF` lỗi) |
| 15 | 0F | TO_OTA | — | — | — | Chuyển sang OTA (không có lớp) |
| 16 | 10 | CMD_BIND_SUCCESS | — | — | — | Không có lớp Req |
| 17 | 11 | CMD_PHONE_NOTIFY | — | `PhoneNotifyRsp` | ✓ | Ring báo người dùng từ chối cuộc gọi |
| 18 | 12 | CMD_DISPLAY_CLOCK | `DisplayClockReq` | `DisplayClockRsp` | ✗ | Hiển thị đồng hồ |
| 19–21, 67, 68, 72… | | | `Read*Req` | | | Lịch sử: ngoài phạm vi |
| 22 | 16 | CMD_HR_TIMING_MONITOR_SWITCH | `HeartRateSettingReq` | `HeartRateSettingRsp` | ✓ | Đo HR tự động |
| 23 | 17 | CMD_GET_PERSONALIZATION_SETTING | `ReadPersonalizationSettingReq` | `ReadPersonalizationSettingRsp` | ✗ | Cá nhân hoá (clock/power on/off) |
| 25 | 19 | CMD_GET_DEGREE_SWITCH | `DegreeSwitchReq` | `DegreeSwitchRsp` | ✓ | Thời tiết bật/tắt + °C/°F |
| 26 | 1A | CMD_SEND_WEATHER_FORECAST | `WeatherForecastReq` | `WeatherForecastRsp` | ✓ | Gửi dự báo thời tiết |
| 27 | 1B | CMD_GET_BRIGHTNESS | `BrightnessSettingsReq` | `BrightnessSettingsRsp` | ✗ | Độ sáng |
| 28 | 1C | CMD_GET_MUSIC_SWITCH | `MusicSwitchReq` | `MusicSwitchRsp` | ✗ | Bật điều khiển nhạc / trạng thái bài hát |
| 29 | 1D | CMD_MUSIC_COMMAND | — | `MusicCommandRsp` | ✓ | Ring gửi lệnh nhạc |
| 30 | 1E | CMD_REAL_TIME_HEART_RATE | `RealTimeHeartRate` | `RealTimeHeartRateRsp` | ✓ | Điều khiển/keep-alive HR real-time |
| 31 | 1F | CMD_DISPLAY_TIME | `DisplayTimeReq` | `DisplayTimeRsp` | ✓ | Thời gian sáng màn hình / AOD |
| 33 | 21 | CMD_TARGET_SETTING | `TargetSettingReq` | `TargetSettingRsp` | ✓ | Mục tiêu |
| 34 | 22 | CMD_FIND_THE_PHONE | — | `FindPhoneRsp` | ✓ | Ring tìm điện thoại |
| 35 | 23 | CMD_SET_ALARM_CLOCK | `SetAlarmReq` | — | ✗ | Đặt báo thức |
| 36 | 24 | CMD_GET_ALARM_CLOCK | `ReadAlarmReq` | (`ReadAlarmRsp`) | ✗ | Đọc báo thức |
| 37 | 25 | CMD_SET_SIT_LONG | `SetSitLongReq` | — | ✗ | Nhắc ngồi lâu |
| 38 | 26 | CMD_GET_SIT_LONG | `SimpleKeyReq(38)` | `ReadSitLongRsp` | ✓ | Đọc nhắc ngồi lâu |
| 39 | 27 | CMD_SET_DRINK_TIME | `SetDrinkAlarmReq` | — | ✗ | Nhắc uống nước |
| 40 | 28 | CMD_GET_DRINK_TIME | `ReadDrinkAlarmReq` | `ReadAlarmRsp` | ✓ | Đọc nhắc uống nước |
| 41 | 29 | CMD_ORIENTATION | `DisplayOrientationReq` | `DisplayOrientationRsp` | ✗ | Hướng màn hình |
| 42 | 2A | CMD_DISPLAY_STYLE | `DisplayStyleReq` | `DisplayStyleRsp` | ✗ | Kiểu hiển thị |
| 43 | 2B | CMD_MENSTRUATION | `MenstruationReq` | (`MenstruationDataRsp`) | ✗ | Chu kỳ kinh nguyệt |
| 44 | 2C | CMD_AUTO_BLOOD_OXYGEN | `BloodOxygenSettingReq` | `BloodOxygenSettingRsp` | ✓ | SpO2 tự động |
| 45 | 2D | CMD_BlackList_LOCATION | `BlackListReq` | — | ✗ | `{1}` — chưa rõ |
| 47 | 2F | CMD_PACKAGE_LENGTH | — | `PackageLengthRsp` | ✓ | Độ dài gói large-data |
| 48 | 30 | CMD_AGPS_SWITCH | `AgpsReq` | `AgpsRsp` | ✗ | AGPS |
| 50 | 32 | CMD_DEVICE_AVATAR | `DeviceAvatarReq` | `DeviceAvatarRsp` | ✓ | Kích thước ảnh avatar |
| 54 | 36 | CMD_PRESSURE_SETTING | `PressureSettingReq` | `PressureSettingRsp` | ✓ | Đo stress tự động |
| 55 | 37 | CMD_PRESSURE | `PressureReq` | `PressureRsp` | ✓ | Lịch sử stress (ngoài phạm vi) |
| 56 | 38 | CMD_HRV_ENABLE | `HrvSettingReq` | `HRVSettingRsp` | ✓ | Đo HRV tự động |
| 57 | 39 | CMD_HRV | `HRVReq` | `HRVRsp` | ✓ | Lịch sử HRV (ngoài phạm vi) |
| 58 | 3A | CMD_DEVICE_SUGAR_LIPIDS | `SugarLipidsSettingReq` | `BloodSugarLipidsSettingRsp` | ✓ | Đường huyết/lipid/**nhiệt độ** tự động |
| 59 | 3B | CMD_DEVICE_TOUCH | `TouchControlReq` | `TouchControlResp` | ✓ | Chạm/cử chỉ |
| 60 | 3C | CMD_DEVICE_FUNCTION_SUPPORT | `DeviceSupportReq` | `DeviceSupportFunctionRsp` | ✓ | Bitmap tính năng |
| 80 | 50 | CMD_ANTI_LOST_RATE | `FindDeviceReq` | — | ✗ | Tìm ring (rung) |
| 81 | 51 | CMD_NOTIFICATION_EVENT_NOTIFY | `NotificationEventNotifyReq` | — | ✗ | Sự kiện rung/đèn |
| 82 | 52 | CMD_MUSLIM_REMIND | `MuslimRemindReq` | `MuslimRemindRsp` | ✓ | (Muslim) |
| 96 | 60 | CMD_SET_ANCS_ON_OFF | `SetANCSReq` | — | ✗ | Bật mọi loại thông báo (`FF 9F`) |
| 97 | 61 | CMD_GET_ANCS_ON_OFF | `SetMessagePushReq` | `ReadMessagePushRsp` | ✓ | Đọc bitmap loại thông báo hỗ trợ |
| 105 | 69 | CMD_START_HEART_RATE | `StartHeartRateReq` | `StartHeartRateRsp` | ✓ | Bắt đầu đo thủ công |
| 106 | 6A | CMD_STOP_HEART_RATE | `StopHeartRateReq` | (`StopHeartRateRsp`) | ✗ | Dừng đo |
| 114 | 72 | CMD_PUSH_MSG / CMD_MSG_NOTIFY | `PushMsgUintReq` | `SimpleStatusRsp` | ✓ | Đẩy nội dung thông báo |
| 115 | 73 | CMD_DEVICE_NOTIFY | — | `DeviceNotifyRsp` | ✓ | Thông báo chủ động (§5) |
| 116 | 74 | CMD_PHONE_GPS | `PhoneGpsReq` | (`AppGpsRsp`) | ✗ | GPS điện thoại cho chế độ thể thao |
| 117 | 75 | CMD_DEVICE_DIAL_INDEX | `DialIndexReq` | `DialIndexRsp` | ✗ | Mặt đồng hồ đang dùng |
| 118 | 76 | CMD_DEVICE_BATTERY_SAVING | `BatterySavingReq` | `BatterySavingRsp` | ✗ | Tiết kiệm pin |
| 119 | 77 | CMD_PHONE_SPORT | `PhoneSportReq` | `AppSportRsp` | ✓ | Thể thao do điện thoại điều khiển |
| 120 | 78 | CMD_PHONE_SPORT_N0TIFY | — | `DeviceNotifyRsp` | ✓ | Ring báo trạng thái thể thao |
| 122 | 7A | CMD_MUSLIM_DATA | `MuslimReq` | `MuslimRsp` | ✓ | (Muslim, nhiều gói) |
| 123 | 7B | CMD_MUSLIM_GOAL_DATA | `MuslimTargetReq` | `MuslimTargetRsp` | ✓ | (Muslim) |
| 126 | 7E | CMD_STILL_TIME | `PhoneStillTime` | — | ✗ | Phản hồi cho notify 115/62 |
| 161 | A1 | CMD_DEVICE_REVISION | `AppRevisionReq` | `AppRevisionResp` | ✓ (-223) | Hiệu chỉnh đeo (wearing calibration) |
| 147 | 93 | CMD_MSG_GET_HW_AND_FW_VERSION | — | — | — | Có hằng nhưng không có lớp nào dùng |
| 201/202 | C9/CA | CMD_TEST_OPEN/CLOSE | `TestReq`/`TestReqClose` | `TestResp` | ✗ | Chế độ test nhà máy (6 giá trị u16 LE) |
| 255 | FF | CMD_RE_STORE | `RestoreKeyReq(-1)` | — | ✗ | Khôi phục cài đặt gốc |

Các hằng khác có trong `Constants` nhưng không có lớp sử dụng: `CMD_CALIBRATION_RATE=32`, `CMD_BP_*`, `CMD_GPS_ONLINE=84`, `CMD_QUERY_DATA_DISTRIBUTION=70`, `CMD_HEALTH_ECG_*=108..112`, `CMD_TUNE_TIME_DIRECT=115/INVERSE=116` (trùng id với 115/116).

---

## 4. Chi tiết từng lệnh

### 4.1 Pin — cmd 3 (`0x03`)

- Req: `SimpleKeyReq((byte)3)`, không payload: `03 00…00 03`.
- Rsp `BatteryRsp` (`C/rsp/BatteryRsp.java:9-12`):

| p | pkt | Trường | Ghi chú |
|---|---|---|---|
| 0 | 1 | `batteryValue` | % (0–100), byte có dấu (đủ cho 0–100) |
| 1 | 2 | `charging` | `1` = đang sạc |

App gửi lệnh này khi init và khi nhận notify 115 type 12 (`APP/ui/home/healthy/HealthyFragment.java:926-928`).

### 4.2 Đặt giờ — cmd 1 (`0x01`)

Req `SetTimeReq` (`C/req/SetTimeReq.java:19-31, 66-70, 89-104`):

| pkt | Trường | Mã hoá |
|---|---|---|
| 1 | Năm % 2000 | BCD (2026 → `0x26`) |
| 2 | Tháng 1–12 | BCD |
| 3 | Ngày | BCD |
| 4 | Giờ 0–23 | BCD |
| 5 | Phút | BCD |
| 6 | Giây | BCD |
| 7 | Ngôn ngữ | xem bảng dưới |

- Giờ gửi là **giờ địa phương** của điện thoại (`Calendar.getInstance()`). **Không có trường múi giờ.** Grep `TimeZone`/`getRawOffset` trong SDK chỉ thấy ở parser lịch sử, không thấy ở lệnh đặt giờ.
- App dùng `new SetTimeReq(1)` (cộng thêm 1 giây để bù độ trễ) ngay khi kết nối (`APP/ui/base/watch/DeviceCmdInit$initDeviceSetting$1.java:146`).
- 12/24h **không** nằm ở lệnh này mà ở cmd 10 (§4.8).

Mã ngôn ngữ (`SetTimeReq.java:33-63`). Locale không có trong bảng được gán mặc định `1` (en):

| Mã | Locale | Mã | Locale | Mã | Locale |
|---|---|---|---|---|---|
| 0 | zh_CN | 10 | ru | 20 | hi |
| 1 | en | 11 | tr | 21 | cs |
| 2 | zh_HK / zh_TW | 12 | ja | 22 | sk |
| 3 | el | 13 | ko | 23 | hu |
| 4 | fr | 14 | pl | 24 | iw (he) |
| 5 | de | 15 | ro | 25 | hr |
| 6 | it | 16 | ar | 26 | sl |
| 7 | es | 17 | th | 35 | ur |
| 8 | nl | 18 | **vi** | | |
| 9 | pt | 19 | in (id) | | |

Rsp `SetTimeRsp` là **bitmap tính năng/màn hình** (`C/rsp/SetTimeRsp.java:48-95`):

| p | pkt | Bit / giá trị | Trường |
|---|---|---|---|
| 0 | 1 | `==1` | `mSupportTemperature` |
| 1 | 2 | `==1` | `mSupportPlate` (mặt đồng hồ) |
| 2 | 3 | `==1` | `mSupportMenstruation` |
| 3 | 4 | b0 `0x01` | `mSupportCustomWallpaper` |
| | | b1 `0x02` | `mSupportBloodOxygen` |
| | | b2 `0x04` | `mSupportBloodPressure` |
| | | b3 `0x08` | `mSupportFeature` |
| | | b4 `0x10` | `mSupportOneKeyCheck` |
| | | b5 `0x20` | `mSupportWeather` |
| | | b6 `0x40` | `mSupportWeChat` — **logic đảo: bit = 0 nghĩa là hỗ trợ** |
| | | b7 `0x80` | `mSupportAvatar` |
| 4–5 | 5–6 | u16 LE | `width` (px màn hình) |
| 6–7 | 7–8 | u16 LE | `height` |
| 8 | 9 | `==1` | `mNewSleepProtocol` |
| 9 | 10 | số | `mMaxWatchFace` |
| 10 | 11 | b0 | `mSupportContact` |
| | | b1 | `mSupportLyrics` |
| | | b2 | `mSupportAlbum` |
| | | b3 | `mSupportGPS` |
| | | b4 | `mSupportJieLiMusic` |
| | | b5 | `mSupportAppMeasure` |
| | | b6 | `mSupportManualBloodOxygen` |
| | | b7 | `mYaWeiSupport` |
| 11 | 12 | b0 | `mSupportManualHeart` |
| | | b1 | `mSupportECard` |
| | | b2 | `mSupportLocation` |
| | | b3 | (không dùng) |
| | | b4 | `mMusicSupport` |
| | | b5 | `rtkMcu` (chip Realtek) |
| | | b6 | `mEbookSupport` |
| | | b7 | `mSupportBloodSugar` |
| 12 | 13 | n | `mMaxContacts = n==0 ? 20 : n*10` |
| 13 | 14 | b0 | `mSupportRecord` |
| | | b1 | `bpSettingSupport` |
| | | b2 | `mSupport4G` |
| | | b3 | `mSupportNavPicture` |
| | | b4 | `mSupportPressure` |
| | | b5 | `mSupportHrv` |

### 4.3 Khai báo OS điện thoại / "bind" — cmd 4 (`0x04`) và ANCS 96/97

`BindAncsReq` (`C/req/BindAncsReq.java:13-49`), được gửi không kèm callback ngay sau set time:

| pkt | Giá trị |
|---|---|
| 1 | `0x02` = Android (iOS có lẽ là `0x01` **(suy luận)**) |
| 2 | Mã phiên bản: `10` nếu SDK_INT==29 *hoặc mọi giá trị khác không nằm trong 26–28*; `9` nếu 28; `8` nếu 26/27 |
| 3..15 | `Build.MODEL` dạng UTF-8, cắt còn 13 byte nếu dài ≥ 14 |

Không có phản hồi được parse. `CMD_BIND_SUCCESS = 16` có trong `Constants` nhưng không lớp nào dùng. Việc "bind" trong app thực chất là lưu MAC + `bleCreateBond()` (bond hệ thống) khi `DeviceSupportFunctionRsp.supportBlePair` bật (`DeviceCmdInit$initDeviceSetting$1.java:~415`).

- cmd 96 `SetANCSReq`: payload `FF 9F` (`C/req/SetANCSReq.java:11`) — bật tất cả các loại thông báo **(suy luận: bitmask u16 LE `0x9FFF`)**.
- cmd 97 `SetMessagePushReq` (không payload) → `ReadMessagePushRsp` (`C/rsp/ReadMessagePushRsp.java:12-15`): `deviceSupport1 = u32 LE @p[2]`, `deviceSupport2 = u32 LE @p[4]`, `deviceSupport3 = u32 LE @p[6]` (các vùng đọc chồng lấn nhau, đúng như code gốc).

### 4.4 Bitmap tính năng — cmd 60 (`0x3C`)

Req: `DeviceSupportReq.getReadInstance()` → `3C 00…00 3C` (`subData = null`).
Rsp `DeviceSupportFunctionRsp` (`C/rsp/DeviceSupportFunctionRsp.java:70-153`). `p[0]` không được đọc.

| p (pkt) | Bit | Mask | Trường | Ý nghĩa |
|---|---|---|---|---|
| p1 (pkt2) | 0 | 0x01 | `supportTouch` | Có cài đặt chạm |
| | 1 | 0x02 | `supportMoslin` | Tính năng Muslim |
| | 2 | 0x04 | `supportAPPRevision` | Hiệu chỉnh đeo (cmd 0xA1) |
| | 3 | 0x08 | `supportBlePair` | Cần bond BLE hệ thống |
| | 4,5 | | — | không dùng |
| | 6 | 0x40 | `deviceNoScreen` | Thiết bị không màn hình (ring) |
| | 7 | 0x80 | `supportGesture` | Cử chỉ |
| p2 (pkt3) | 0 | 0x01 | `supportRingMusic` | Chạm → điều khiển nhạc |
| | 1 | 0x02 | `supportRingVideo` | → lướt video ngắn |
| | 2 | 0x04 | `supportRingEbook` | → lật trang ebook |
| | 3 | 0x08 | `supportRingCamera` | → chụp ảnh |
| | 4 | 0x10 | `supportRingPhoneCall` | → cuộc gọi |
| | 5 | 0x20 | `supportRingGame` | → game |
| | 6 | 0x40 | `supportHeart` | → đo nhịp tim |
| | 7 | | — | không dùng |
| p3 (pkt4) | 0 | 0x01 | `supportSkinTemperature` | Nhiệt độ da |
| | 1 | | — | không dùng |
| | 2 | 0x04 | `supportLongSit` | Nhắc ngồi lâu |
| | 3 | 0x08 | `supportDrink` | Nhắc uống nước |
| | 4 | 0x10 | `supportNoSingleTemperature` | Không hỗ trợ đo nhiệt độ đơn lẻ |
| | 5 | 0x20 | `supportNotification` | Thông báo |
| | 6 | | — | không dùng |
| | 7 | 0x80 | `supportAiAnalyze` | AI phân tích |
| p4 (pkt5) | 0–2 | | — | không dùng |
| | 3 | 0x08 | `supportRingGestureDND` | DND bằng cử chỉ |
| | 4 | 0x10 | `tpSleep` | Touch-panel sleep (cmd 59 mode 2) |
| | 5 | 0x20 | `supportRt11` | |
| | 6 | | — | không dùng |
| | 7 | 0x80 | `resumeServices` | |
| p5 (pkt6) | ≠0 | | `onlyTouch = (p5 != 0)` | Nếu ≠0 thì các bit dưới đây được dùng: |
| | 0 | 0x01 | `supportRingMusicTouch` | |
| | 1 | 0x02 | `supportRingVideoTouch` | |
| | 2 | 0x04 | `supportRingEbookTouch` | |
| | 3 | 0x08 | `supportRingCameraTouch` | |
| | 4 | 0x10 | `supportRingPhoneCallTouch` | |
| | 5 | 0x20 | `supportRingGameTouch` | |
| | 6 | 0x40 | `supportHeartTouch` | |
| | 7 | 0x80 | `supportMoslinTouch` **và ghi đè `supportMoslin`** | |
| p6 (pkt7) | 0,1 | | — | không dùng |
| | 2 | 0x04 | `unSupportTakePhoto` | |
| | 3 | 0x08 | `supportLoverSpace` | |
| | 4 | 0x10 | `supportWorship` | |
| | 5 | 0x20 | `supportNewPraise` | |
| | 6 | 0x40 | `supportAlarm` | |
| | 7 | 0x80 | `supportDoNotDisturb` | |
| p7 (pkt8) | 0 | 0x01 | `supportUltraviolet` | |
| | 1 | 0x02 | `supportCallReminder` | |
| | 2 | 0x04 | `supportRealTimeOxygen` | |
| | 3 | 0x08 | `supportRealTimeHr` | |
| | 4 | 0x10 | `supportRealTimeHrRemind` | |
| | 5 | 0x20 | `supportFriends` | |
| | 6 | 0x40 | `supportLoverInteract` | |
| | 7 | 0x80 | `supportTempIntervalModify` | |
| p8 (pkt9) | 0 | 0x01 | `supportNoScreenBand24Hour` | |
| | 1–4 | | — | không dùng |
| | 5 | 0x20 | `bodyTag` | |
| | 6 | 0x40 | `supportTempReminder` | |
| | 7 | 0x80 | `supportIntervalTemp` | |
| p9 (pkt10) | 0 | | — | không dùng |
| | 1 | 0x02 | `supportEcg` | |
| | 2 | 0x04 | `supportTempBoth` | |
| | 3 | 0x08 | `supportBreathTraining` | |
| | 4 | 0x10 | `supportAudio` | |
| | 5 | 0x20 | `supportMeetingRecord` | |
| | 6 | 0x40 | `supportBodyBattery` | |
| | 7 | 0x80 | `supportWifiImport` | |
| p10 (pkt11) | 0 | 0x01 | `supportAudioCoding` | |
| | 3 | 0x08 | `isOpusAudio` | |

Các trường `earStud`, `smartCard` được khai báo nhưng không được parse.

### 4.5 Đo thủ công / real-time — cmd 105 / 106 / 30

#### 4.5.1 Start — cmd 105 (`0x69`), `StartHeartRateReq`

Payload: `pkt[1] = type`, `pkt[2] = sub` (`C/req/StartHeartRateReq.java:27, 46`).

| type | Hằng | `getSimpleReq` sub | App dùng ở |
|---|---|---|---|
| 1 | TYPE_HEARTRATE | `0x00` | `HeartActivity` |
| 2 | TYPE_BLOODPRESSURE | `0x00` | `BloodPressureActivity` |
| 3 | TYPE_BLOODOXYGEN | `0x25` | `BloodOxygenActivity` |
| 4 | TYPE_FATIGUE | `0x25` | — |
| 5 | TYPE_HEALTHCHECK (one-key) | `0x25` | `OneKeyCheckActivity` |
| 6 | TYPE_REALTIMEHEARTRATE | `sub` = action (1 start / 2 pause / 3 continue / 4 stop) | không dùng (`getRealtimeHeartRate`) |
| 7 | TYPE_ECG | — | |
| 8 | TYPE_PRESSURE (stress) | `0x25` | `DayPressureFragment` |
| 9 | TYPE_BLOOD_SUGAR | `0x25` | `BloodSugarActivity` |
| 10 | TYPE_HRV | `0x25` | `HrvActivity` |
| 11 | TYPE_BODY_TEMPERATURE | `0x25` | `Temperature*Activity` |
| 16 | ACTION_ECG | `1` start / `4` stop (`getEcgReqStartAndStop`) | |

`getSimpleReq(b)`: `sub = (b < 3) ? 0 : decimalToBCD(25) = 0x25` (`StartHeartRateReq.java:41`). Ý nghĩa của `0x25` chưa rõ: có thể là thời lượng đo 25 s mã BCD **(suy luận)**.
Hằng action (`StartHeartRateReq.java:7-11`): `ACTION_START=1, ACTION_PAUSE=2, ACTION_CONTINUE=3, ACTION_STOP=4, ACTION_ECG=16`.

Rsp `StartHeartRateRsp` (`C/rsp/StartHeartRateRsp.java:12-28`). Ring **gửi nhiều gói `0x69` liên tiếp** trong lúc đo, tất cả đều vào cùng callback (§1.5):

| p | pkt | Trường | Ghi chú |
|---|---|---|---|
| 0 | 1 | `type` | Lặp lại type của request |
| 1 | 2 | `errCode` | `0` = OK / đang đo; `1` = **không đeo** (app hiện "wearing detection"); `2` = app coi như chưa xong, tiếp tục chờ (`HeartActivity.java:1231, 1357`). Giá trị khác là lỗi |
| 2 | 3 | `value` | u8. Ý nghĩa theo type, bảng dưới |
| 3 | 4 | `sbp` | u8 — huyết áp tâm thu (type 2) |
| 4 | 5 | `dbp` | u8 — huyết áp tâm trương (type 2) |

Giải mã `value` (đọc trực tiếp từ app):

| type | Đơn vị / công thức | Trích dẫn |
|---|---|---|
| 1 HR | bpm | `APP/ui/home/heart/HeartActivity.java:1203-1207` |
| 2 BP | dùng `sbp`/`dbp` (mmHg) | `APP/ui/home/bp/BloodPressureActivity.java:898+` |
| 3 SpO2 | % | `APP/ui/home/bloodoxgen/BloodOxygenActivity.java:1152+` |
| 8 Stress | điểm 0–100 **(suy luận về thang)** | `APP/ui/home/pressure/day/DayPressureFragment.java:976+` |
| 9 Đường huyết | `value / 10` (mmol/L) | `APP/ui/home/bloodsugar/BloodSugarActivity.java:1025+` |
| 10 HRV | ms **(suy luận về đơn vị)** | `APP/ui/home/heart/HrvActivity.java:1055+` |
| 11 Nhiệt độ | **°C = value / 10 + 20** (ví dụ `0x9A`=154 → 35.4 °C) | `APP/ui/home/temperature/TemperatureBodyActivity.java:1171` |

App coi phép đo đã xong khi nhận gói đầu tiên có `errCode==0 && type==T && value>0`.

#### 4.5.2 Stop — cmd 106 (`0x6A`), `StopHeartRateReq`

Payload 3 byte `{type, b2, b3}` (`C/req/StopHeartRateReq.java:8-9`):

| Factory | pkt1 | pkt2 | pkt3 |
|---|---|---|---|
| `stopHeartRate(v)` | 1 | v (app gửi `0` hoặc **giá trị HR cuối cùng**, `HeartActivity.java:325`) | 0 |
| `stopBloodPressure(s,d)` | 2 | s | d |
| `stopBloodOxygen(v)` | 3 | v | 0 |
| `stopFatigue(v)` | 4 | v | 0 |
| `stopHealthCheck()` | 5 | 0 | 0 |
| `stopEcg(i)` | 7 | i | 0 |
| `stopPressure(v)` | 8 | v | 0 |
| `stopBloodSugar(v)` | 9 | v | 0 |
| `stopHrv(v)` | 10 | v | 0 |
| `stopTemperatureCheck()` | 11 | 0 | 0 |

Phản hồi không có mapping trong BeanFactory. Lớp `StopHeartRateRsp` có cùng layout với Start (`type, errCode, value, sbp, dbp`).

#### 4.5.3 Real-time HR — cmd 30 (`0x1E`), `RealTimeHeartRate`

- Payload: `{type}` (1 byte) (`C/req/RealTimeHeartRate.java:11-12`).
- App gửi `1E 03` (= `ACTION_CONTINUE`, **(suy luận)** theo hằng của cmd 105) **mỗi 20 s** trong lúc đo nhịp tim, dùng làm keep-alive để ring không tự ngắt (`HeartActivity.java:255-257`; chu kỳ `DeviceOrientationRequest.OUTPUT_PERIOD_DEFAULT = 20000`).
- Rsp `RealTimeHeartRateRsp`: `heart = p[0]` (bpm) (`C/rsp/RealTimeHeartRateRsp.java:8-10`).
- Ring cũng có thể chủ động đẩy giá trị HR/SpO2 qua notify 115 type 55/64 (§5).

#### 4.5.4 Luồng điển hình (HR)

```
phone → 69 01 00 …                          start HR
ring  → 69 01 00 00 … (errCode 0, value 0)  đang đo
ring  → 69 01 01 00 …                        (nếu không đeo → errCode 1)
phone → 1E 03 …   (mỗi 20 s)                 keep-alive
ring  → 69 01 00 48 …                        HR = 72 bpm → xong
phone → 6A 01 48 00 …                        stop (kèm giá trị cuối)
```

### 4.6 Cài đặt đo tự động

#### cmd 22 (`0x16`) — Nhịp tim tự động

- Đọc: `16 01`.
- Ghi (`C/req/HeartRateSettingReq.java:23-26`): `{2, enable?1:2, interval, start, tooLow, tooHigh, tooSwitch}`. App gọi `getWriteInstance(hrDetection, hrInterval, hrStart, hrTooLow, hrTooHigh, hrTooSwitch)`.
- Rsp `HeartRateSettingRsp` (`C/rsp/HeartRateSettingRsp.java:45-76`), chỉ khi `p[0]=1`:

| p | Trường | Ghi chú |
|---|---|---|
| 1 | `isEnable` | `==1` |
| 2 | `heartInterval` | phút |
| 3 | `startInterval` | `0` → mặc định 5 |
| 4 | `tooLowReminder` | bpm, ngưỡng nhắc HR thấp (nếu >0) |
| 5 | `tooHighReminder` | bpm, ngưỡng nhắc HR cao |
| 6 | `mainSwitch` | bật/tắt nhắc HR thấp/cao |
| 7 | `maxInterval` | mặc định 60 |

#### cmd 44 (`0x2C`) — SpO2 tự động

- Đọc `2C 01`. Ghi `{2, en?1:0}` hoặc `{2, en?1:0, interval}` (`C/req/BloodOxygenSettingReq.java:22-30`).
- Rsp: `p1` = enable, `p2` = interval (`C/rsp/BloodOxygenSettingRsp.java:17-19`).

#### cmd 56 (`0x38`) — HRV tự động

- Đọc: `{1,0,0,0,0,0,0}`.
- Ghi: `{2, en?1:0, 0x0A, intervalCode, 0, 0, 0}`, với `intervalCode = (min==60) ? 96 (0x60) : min` (`C/req/HrvSettingReq.java:18-33`). `0x0A` = cờ "hỗ trợ khoảng 10 phút". Việc 60 → `0x60` trông giống BCD(60) **(suy luận)**.
- Rsp `HRVSettingRsp` (`C/rsp/HRVSettingRsp.java:12-41`): `p1` enable, `p2==10` → `supportInterval`, `p3` interval (`0` hoặc `96` → 60).

#### cmd 54 (`0x36`) — Stress tự động

- Đọc `36 01`; ghi `{2, en?1:0}` (`C/req/PressureSettingReq.java:5-21`). Rsp: `p1==1` (`C/rsp/PressureSettingRsp.java:12-13`).

#### cmd 58 (`0x3A`) — Đường huyết / lipid / **nhiệt độ** tự động

Byte đầu là **type**, không phải action. App chỉ dùng `type = 3` = nhiệt độ cơ thể (`APP/…/DeviceCmdInit$initDeviceSetting$1.java:717`). Các type khác (1/2 = đường huyết/lipid?) là **(suy luận)**.

- Đọc: `{type, 1}`.
- Ghi dạng ngắn: `{type, 2, en?1:0, value_lo, value_hi}` (u16 LE).
- Ghi dạng nhiệt độ (`C/req/SugarLipidsSettingReq.java:29-32`):

| pkt | Trường |
|---|---|
| 1 | type (=3) |
| 2 | 2 (write) |
| 3 | enable 1/0 |
| 4 | `tempInterval` (phút, mặc định 30) |
| 5 | `tempStart` (mặc định 5) |
| 6 | `tempRemindInterval` (mặc định 10) |
| 7 | cờ: b0 low, b1 middle, b2 high, b3 custom |
| 8 | ngưỡng custom: `byte = temp*10 - 200` (38.5 °C → 185) |

- Rsp `BloodSugarLipidsSettingRsp` (`C/rsp/BloodSugarLipidsSettingRsp.java:65-82`): layout giống request (`p0` type, `p1` action, `p2` enable, `p3..p7`); `customTemp = (p7 + 200)/10`.
  Lưu ý: `MixtureRsp` chỉ gọi `readSubData` khi `p0 ∈ {1,3}`, mà ở đây `p0` lại là type, nên chỉ type 1 và 3 được parse.

#### cmd 12 (`0x0C`) — Huyết áp tự động

Ghi `{2, en?1:0, startH, startM, endH, endM, interval}` (raw, không BCD) (`C/req/BpSettingReq.java:20-23`). Rsp có cùng layout (`C/rsp/BpSettingRsp.java:24-27`).

### 4.7 Hồ sơ người dùng & định dạng — cmd 10 (`0x0A`)

`TimeFormatReq` (`C/req/TimeFormatReq.java:18-52`). Đọc: `0A 01`. Ghi đầy đủ:

| pkt | Trường | Mã hoá |
|---|---|---|
| 1 | 2 (write) | |
| 2 | 12/24h | **`0` = 24h**, `1` = 12h |
| 3 | Đơn vị | `0` = metric (`isMetric = p2==0`), `1` = imperial |
| 4 | Giới tính | app gửi `user.gender - 1` (0/1; giá trị nào là nam là **(suy luận)**) |
| 5 | Tuổi | năm |
| 6 | Chiều cao | cm (u8) |
| 7 | Cân nặng | kg (u8) |
| 8 | SBP tham chiếu | app luôn gửi 120 |
| 9 | DBP tham chiếu | app luôn gửi 90 |
| 10 | `warmingHeart` | ngưỡng cảnh báo HR (bpm) |
| 11 | `open` | công tắc (cảnh báo HR?) **(suy luận)** |

Dạng ngắn `getWriteInstance(is24, b)`: `{2, is24?0:1, b}`.
Rsp `TimeFormatRsp` (`C/rsp/TimeFormatRsp.java:27-37`) có cùng thứ tự từ `p1` đến `p10`.

### 4.8 Mục tiêu — cmd 33 (`0x21`)

`TargetSettingReq` (`C/req/TargetSettingReq.java:27-32, 57-64`). Đọc `21 01`. Ghi:

| pkt | Trường | Mã hoá |
|---|---|---|
| 1 | 2 | |
| 2–4 | Bước chân | u24 **LE** |
| 5–7 | Calo | u24 LE (đơn vị chưa rõ: cal hay kcal **(suy luận)**) |
| 8–10 | Quãng đường | u24 LE (m **(suy luận)**) |
| 11–12 | Phút vận động | u16 LE (chỉ dạng 5 tham số) |
| 13–14 | Phút ngủ | u16 LE |

Rsp `TargetSettingRsp` dùng cùng offset (`C/rsp/TargetSettingRsp.java:35-40`).

### 4.9 Tìm thiết bị / tìm điện thoại / nguồn / reset / hiệu chỉnh

| Lệnh | Gói | Ghi chú / trích dẫn |
|---|---|---|
| Tìm ring (cmd 80) | `50 55 AA` | `C/req/FindDeviceReq.java:8-13` (`0x55`, `0xAA` là magic). Ring rung |
| Ring tìm điện thoại (cmd 34, ring→phone) | `22 <s>` | `FindPhoneRsp.openOrClose = p0` (`C/rsp/FindPhoneRsp.java:11-12`). `1` = phát chuông lặp (app tự dừng sau 10 s), `2` = dừng (`com/realsil/sdk/bbpro/f8/a.java:64-100`) |
| Tắt nguồn (cmd 8) | `08 01` | `SimpleKeyPowerOffReq` (`C/req/SimpleKeyPowerOffReq.java:6-7`). Hằng tên `CMD_RE_BOOT`; giá trị khác `1` có thể là reboot **(suy luận)** |
| Factory reset (cmd 0xFF) | `FF 66 66` | `RestoreKeyReq((byte)-1)`, magic `0x66 0x66` (`C/req/RestoreKeyReq.java:13`; `Mmi.AU_MMI_SWITCH_NEXT_VOICE_PROMPT_LANGUAGE = 102`) |
| Hiệu chỉnh đeo (cmd 0xA1) | `A1 <mode>` | `AppRevisionReq.getWriteInstance(i)`. App gửi `6` để bắt đầu, `2` để hiệu chỉnh lại/huỷ (`APP/ui/device/touch/a.java:87,105`). Rsp `AppRevisionResp`: `dataType = p0`, `result = p9` (`1` = thành công); app chờ cả `dataType 1` và `2` báo `result==1` (`RevisionActivity.java:125-137`). Timeout 120 s. Không chạy khi đang sạc |

### 4.10 Báo thức, nhắc uống nước, nhắc ngồi lâu

**Báo thức — cmd 35 (set) / 36 (read)**: `SetAlarmReq` (`C/req/SetAlarmReq.java:20`):

| pkt | Trường |
|---|---|
| 1 | index 0–4 |
| 2 | enable (0–2; app gửi 1/0) |
| 3 | giờ (BCD) |
| 4 | phút (BCD) |
| 5–11 | 7 byte, mỗi byte là `0/1` cho một ngày: `bit0..bit6` của `weekMask` |

Đọc: `24 <index>`. Phản hồi cmd 36 không có mapping. Lớp `ReadAlarmRsp` (`C/rsp/ReadAlarmRsp.java:11-17`) có layout `p0` index, `p1` enable, `p2` giờ BCD, `p3` phút BCD, `p4..p10` ngày.
Thứ tự ngày của bit0 (CN hay T2?) **(suy luận: chưa xác định)**.

**Nhắc uống nước — cmd 39 / 40**: layout giống hệt báo thức, index 0–7 (`C/req/SetDrinkAlarmReq.java:19`). Đọc `28 <idx>` → `ReadAlarmRsp` (có mapping).

**Nhắc ngồi lâu — cmd 37 / 38** (`C/req/SetSitLongReq.java:18`):

| pkt | Trường |
|---|---|
| 1–2 | giờ / phút bắt đầu (BCD) |
| 3–4 | giờ / phút kết thúc (BCD) |
| 5 | weekMask (bit0..6, bit = 1 là bật) |
| 6 | chu kỳ phút: 30/60/90 (giá trị khác bị ép về 60) |

Đọc: `SimpleKeyReq(38)` → `ReadSitLongRsp` có cùng layout (`C/rsp/ReadSitLongRsp.java:13-17`).

### 4.11 Màn hình, DND và các cài đặt khác

| cmd | Đọc | Ghi | Rsp (`p` sau action) | Trích dẫn |
|---|---|---|---|---|
| 6 DND | `06 01` | `{2, en?1:2, sH, sM, eH, eM}` (raw) | `p1==1` en, `p2..p5` giờ, `p6==1` manualDND | `DndReq.java:22`, `DndRsp.java:24-27` |
| 5 Nâng tay sáng màn | `05 01`; ring: `05 03` | `{2, en?1:2, (left?1:2) \| (needPalm?4:0)}`; ring: `{4, en?1:2, left?1:2, screenLight, maxLight, dnd?2:1, sH, sM, eH, eM}` | read: `p1` en, `p2&1` left, `p2&4` needPalm; ring-read (`p0=3`): `p1` en, `p2` left, `p3` sáng, `p4` maxLight, `p5!=1` → dnd, `p6*60+p7` start, `p8*60+p9` end | `PalmScreenReq.java:22-35`, `PalmScreenRsp.java:50-67` |
| 31 Thời gian sáng màn | `1F 01`; xoá `1F 03` | `{2, displayTime, displayType, alpha, 0, total, curr}`; dạng mới thêm `, 5, 30, 5, open?2:1` | `p1` time, `p2` type, `p3` alpha, `p4!=0` custom, `p5` total, `p6` type, `p7` min, `p8` max, `p9` step, `p10` alwaysOn, `p11` supportAlwaysOn | `DisplayTimeReq.java:39,62`, `DisplayTimeRsp.java:62-73` |
| 27 Độ sáng | `1B 01` | `{2, level}` | `p1` level | `BrightnessSettingsReq.java:10,23` |
| 18 Đồng hồ | `12 01` | `{2, en?1:2}` | `p1==1` | `DisplayClockReq.java:20` |
| 41 Hướng | `29 01` | `{2, portrait?1:2, portrait?0:(left?1:2)}` | `p1==1` portrait, `p2==1` left | `DisplayOrientationReq.java:20` |
| 42 Kiểu | `2A 01` | `{2, idx}` | `p1` | `DisplayStyleReq.java:20` |
| 117 Mặt đồng hồ | `75 00` | `{1, idx}` | `p1` idx | `DialIndexReq.java:7,20` |
| 118 Tiết kiệm pin | `76 00` | `{1, en?1:0}` | `p1==1` | `BatterySavingReq.java:7,20` |
| 25 Thời tiết/°C | `19 01` | `{2, en?1:2, celsius?1:2}` | `p1==1` en, `p2==1` °C | `DegreeSwitchReq.java:25` |
| 26 Dự báo thời tiết | — | `{idx, ts u32 LE, weatherType, min°, max°, humidity, umbrella?1:2}` | `isSuccess = p0==26` | `WeatherForecastReq.java:62-70` |
| 9 Intell | `09 01` | `{2, en?1:2, delaySec}` | `p1` en, `p2` delay | `IntellReq.java:23` |
| 48 AGPS | `30 01` | `{2, en?1:0}` | `p1==1` | `AgpsReq.java:21` |
| 50 Avatar | `32` | — | `p0` screenType, `p1..2` w u16 LE, `p3..4` h u16 LE | `DeviceAvatarRsp.java:13-17` |
| 23 Cá nhân hoá | `17 01 02 03` | — | `p0` clock, `p1` powerOn, `p2` powerOff | `ReadPersonalizationSettingRsp.java:12-16` |

### 4.12 Chạm / cử chỉ — cmd 59 (`0x3B`)

`TouchControlReq` (`C/req/TouchControlReq.java:7-53`):

| Hàm | Payload |
|---|---|
| `getReadInstance(true)` (chạm) | `{1, 0}` |
| `getReadInstance(false)` (cử chỉ) | `{1, 1}` |
| `getReadTouchInstance()` | `{1, 2}` |
| `getWriteInstance(app, true, s, x)` (chạm) | `{2, 0, app, x}` |
| `getWriteInstance(app, false, s, x)` (cử chỉ) | `{2, 1, app, s}` (s = strength) |
| `getWriteTpSleepInstance(a, b)` | `{2, 2, a, b}` |

Rsp `TouchControlResp` (`C/rsp/TouchControlResp.java:13-27`), khi `p0 == 1`: `p1==0` → mode chạm (`p3` sleepTime, `p4==1` touchSleep); ngược lại là mode cử chỉ (`p3` strength). `p2` = appType.

Giá trị **appType** (map từ UI, `APP/ui/device/touch/a.java:192-295`):

| appType | Chức năng |
|---|---|
| 0 | Tắt |
| 1 | Nhạc |
| 2 | Video ngắn |
| 3 | Muslim (đếm tasbih) |
| 4 | Ebook |
| 5 | Camera |
| 8 | Đo nhịp tim |
| 10 | Tương tác người yêu (lover) |

### 4.13 Camera — cmd 2 (`0x02`)

- phone → ring `CameraReq` (`C/req/CameraReq.java:5-21`): `{action}`, với `4` = vào UI camera, `5` = giữ màn hình sáng (app gửi lặp lại trong lúc ở UI camera **(suy luận)**), `6` = thoát.
- ring → phone `CameraNotifyRsp` (`C/rsp/CameraNotifyRsp.java:5-13`): `p0`: `1` = vào UI camera, **`2` = chụp ảnh**, `3` = kết thúc.

### 4.14 Nhạc — cmd 28 / 29

- cmd 28 `MusicSwitchReq` (`C/req/MusicSwitchReq.java:10-62`): đọc `{1}`; bật/tắt `{2, en?1:2}`. Trạng thái bài hát: `{playing?0:1, progress, volume%, name UTF-8…}`, tên tối đa 11 byte (app gửi tên rỗng).
- cmd 29 ring → phone `MusicCommandRsp.action = p0` (`C/rsp/MusicCommandRsp.java:10-11`), xử lý trong `C/responseImpl/MusicCommandListener.java:39-52`:

| p0 | Hành động |
|---|---|
| 1 | Play/Pause (KEYCODE 85 + 79) |
| 2 | Bài trước (88) |
| 3 | Bài sau (87) |
| 4 | Tăng âm lượng |
| 5 | Giảm âm lượng |

Sau mỗi lệnh, nếu nhạc đang phát thì app gửi lại trạng thái qua cmd 28.

### 4.15 Đẩy thông báo — cmd 114 (`0x72`) và cmd 17

`PushMsgUintReq(type, total, index, data)` (`C/req/PushMsgUintReq.java:17-24`):

| pkt | Trường |
|---|---|
| 1 | Loại: 0 chuông gọi, 1 SMS, 2 QQ, 3 WeChat, 4 phone action, 5 Facebook, 6 WhatsApp, 7 Twitter, 8 Skype, 9 Line |
| 2 | Tổng số gói |
| 3 | Chỉ số gói (bắt đầu từ 1) |
| 4–14 | 11 byte UTF-8 (gói cuối đệm 0) |

App cắt chuỗi còn 256 ký tự rồi chia thành các mảnh 11 byte, mỗi mảnh gửi trong một lệnh (`APP/ui/device/push/utils/MessagePushUtil.java:216-245`). Phản hồi `SimpleStatusRsp` không mang dữ liệu.

cmd 17 ring → phone `PhoneNotifyRsp.action = p0`; `1` = **từ chối cuộc gọi** (`C/rsp/PhoneNotifyRsp.java:8-18`).

### 4.16 Sự kiện thông báo — cmd 81 (`0x51`, phone → ring)

`NotificationEventNotifyReq` (`C/req/NotificationEventNotifyReq.java:5-53`):
- Dạng đơn giản: `{event}`. Event: 0 none, 1 double-click button, 2 pairing, 3 miss you, 4 love you, 5 need you, 6 sad, 7 love letter. App gửi `{1}` khi nhận push Firebase (`APP/ui/device/push/service/MyFirebaseMessagingService.java:66`).
- Dạng custom: `{8 (light) | 9 (vibration), a, b, c, duration(1..127), e}`. Hằng: `LIGHT_STOP=1, LIGHT_GREEN=2, LIGHT_RED=3`; `VIBRATION_STOP=1, VIBRATION_START=2`. Ý nghĩa chính xác của `a, b, c, e` **(suy luận: kiểu đèn/rung, số lần, chu kỳ)**.

Không thấy chiều ring → phone cho cmd 81 trong SDK: không có Rsp và không có listener.

### 4.17 Thể thao điều khiển từ điện thoại

- cmd 119 `PhoneSportReq.getSportStatus(status, sportType)` → `{status, sportType}`. Rsp `AppSportRsp`: `p0` gpsStatus; nếu `p0==6` thì `timeStamp = u32 LE @p2`; `addStepType = u32 LE @p6` (`C/rsp/AppSportRsp.java:13-25`).
- cmd 116 `PhoneGpsReq`: `{status, 0}` hoặc `{5, 0, distance u32 LE, calorie u32 LE}` (`C/req/PhoneGpsReq.java:15,31`).
- cmd 120 ring → phone (notify): `DeviceNotifyRsp`; app đọc `p0`, `p1` (trạng thái và loại thể thao **(suy luận)**) (`HealthyFragment.java:1312-1313`).
- cmd 126 `PhoneStillTime(z, i)`: `{2, z?1:0, i_lo, i_hi}`, gửi để trả lời notify 115 type 62 (`C/req/PhoneStillTime.java:9-18`).

---

## 5. Thông báo chủ động ring → phone

### 5.1 cmd 115 (`0x73`) — `DeviceNotifyRsp`

`dataType = p0 = pkt[1]`; `loadData = p[0..13]`, nên `loadData[k] = pkt[k+1]` (`C/rsp/DeviceNotifyRsp.java:9-12`). `DeviceNotifyListener` phát cho mọi listener app đã đăng ký; khoá của các listener này là ID nội bộ của app, **không phải** dataType (`C/responseImpl/DeviceNotifyListener.java:25-38`).

Bảng dataType (xử lý chính ở `APP/ui/home/healthy/HealthyFragment.java:469-1215`):

| dataType | Ý nghĩa | Payload (`loadData`) | Dòng |
|---|---|---|---|
| 1 | Có dữ liệu HR mới → đồng bộ HR hôm nay | — | 483 |
| 2 | Có dữ liệu huyết áp mới | — | 517 |
| 3 | Có dữ liệu SpO2 mới | — | 521 |
| 4 | Có dữ liệu bước chân chi tiết mới | — | 525 |
| 5 | Có dữ liệu nhiệt độ mới | — | 529 |
| 7 | Có bản ghi thể thao mới | — | 533 |
| 9 | Ring yêu cầu app đồng bộ (`DeviceToAppSyncEvent`) | — | 540, 1214 |
| 11 | (bỏ qua) | — | 924 |
| 12 | Pin/sạc thay đổi → app gửi lại cmd 3 | `[2] > 0` = đang sạc (`RevisionActivity.java:76-81`); `[1]` = % pin **(suy luận)** | 926 |
| 13 | Có dữ liệu đường huyết mới | — | 991 |
| 16 | Mục tiêu đổi trên ring → app đọc cmd 33 | — | 996 |
| 17 | Trạng thái đeo | `[2]` = wear | 1056 |
| 18 | **Bước chân real-time** | `[1..3]` steps u24 **BE**, `[4..6]` calories u24 BE, `[7..9]` distance u24 BE | 1060; `HealthyFragment.h()` 1742 |
| 37 | Đếm tán (Muslim praise) | `[1..4]` u32 BE | 541 |
| 39 | Nhiệt độ mới | — | 915 |
| 41 | Dữ liệu game của ring | — | 919 |
| 43 | Có HRV mới | — | 1066 |
| 44 | Có stress mới | — | 1069 |
| 45 | Sự kiện phím/cử chỉ | `[1]`: 1 vuốt xuống, 2 vuốt lên, 3 chạm, 4 nhấn giữ | 1072 |
| 48 | Double-click (lover) | — | 1098 |
| 49 | Cảnh báo HR cao | `[1]` = bpm | 1107 |
| 50 | Nhắc uống nước | — | 1112 |
| 51 | Nhắc vận động (ngồi lâu) | — | 1115 |
| 52 | Báo thức kêu | — | 1118 |
| 55 | **Giá trị HR do ring đo** | `[1]` = bpm | 1125 |
| 56 | Số lần tán (custom praise) | `[2..3]` u16 LE | 1135 |
| 57 | Nhắc chu kỳ kinh nguyệt | `[1]` 1 = kinh nguyệt / khác = rụng trứng; `[2]` = số ngày | 1140 |
| 58 | Cảnh báo HR thấp/cao | `[1]`: 1 thấp, 2 cao | 1143 |
| 61 | **Cảnh báo nhiệt độ cao** | `[1..2]` u16 LE / 10 = °C | 1155 |
| 62 | G-sensor đứng yên → app trả lời cmd 126 | — | 1158 |
| 63 | ECG | `[1]` | 1185 |
| 64 | **Giá trị SpO2 do ring đo** | `[1]` = % | 1190 |

### 5.2 Các notify khác

| cmd | Nội dung | § |
|---|---|---|
| 2 | Camera (1 vào, 2 chụp, 3 thoát) | 4.13 |
| 17 | Từ chối cuộc gọi | 4.15 |
| 29 | Điều khiển nhạc | 4.14 |
| 34 | Tìm điện thoại (1 bắt đầu, 2 dừng) | 4.9 |
| 47 | `PackageLengthRsp.mData = p0` → độ dài gói large-data = `max(p0, 20)` | `C/responseImpl/PackageLengthListener.java:12-15` |
| 105 | Chuỗi kết quả đo (cũng đến qua callback của request) | 4.5 |
| 120 | Trạng thái thể thao | 4.17 |

---

## 6. Ví dụ hex (checksum đã tính)

Mọi gói đều 16 byte; checksum = tổng 15 byte đầu mod 256.

**Đọc pin**
```
→ 03 00 00 00 00 00 00 00 00 00 00 00 00 00 00 03
← 03 55 01 00 00 00 00 00 00 00 00 00 00 00 00 59
   │  │  └ p1 = 01 → đang sạc
   │  └ p0 = 0x55 = 85 %
   └ cmd 3 (bit7 = 0 → không lỗi);  checksum 03+55+01 = 0x59 ✓
```

**Đặt giờ** 2026-10-13 14:30:45, ngôn ngữ en (1)
```
→ 01 26 10 13 14 30 45 01 00 00 00 00 00 00 00 D4
      YY MM DD hh mm ss lang      (BCD)
```
(0x01+0x26+0x10+0x13+0x14+0x30+0x45+0x01 = 0xD4)

**Bắt đầu đo nhịp tim**
```
→ 69 01 00 00 00 00 00 00 00 00 00 00 00 00 00 6A
```

**Keep-alive real-time HR** (mỗi 20 s)
```
→ 1E 03 00 00 00 00 00 00 00 00 00 00 00 00 00 21
```

**Phản hồi đo HR** (giải mã)
```
← 69 01 00 48 00 00 00 00 00 00 00 00 00 00 00 B2
      │  │  └ value = 0x48 = 72 bpm
      │  └ errCode = 0 (OK)
      └ type = 1 (HR)
← 69 01 01 00 … 6B   → errCode 1 = không đeo
```

**Dừng đo nhịp tim**
```
→ 6A 01 00 00 00 00 00 00 00 00 00 00 00 00 00 6B   (stopHeartRate(0))
→ 6A 01 48 00 00 00 00 00 00 00 00 00 00 00 00 B3   (kèm giá trị cuối 72)
```

**Các lệnh khác**

| Mục đích | Gói |
|---|---|
| Đọc bitmap tính năng | `3C 00 00 00 00 00 00 00 00 00 00 00 00 00 00 3C` |
| Start SpO2 | `69 03 25 00 00 00 00 00 00 00 00 00 00 00 00 91` |
| Stop SpO2 | `6A 03 00 00 00 00 00 00 00 00 00 00 00 00 00 6D` |
| Start nhiệt độ | `69 0B 25 00 00 00 00 00 00 00 00 00 00 00 00 99` |
| Stop nhiệt độ | `6A 0B 00 00 00 00 00 00 00 00 00 00 00 00 00 75` |
| Start HRV | `69 0A 25 00 00 00 00 00 00 00 00 00 00 00 00 98` |
| Start stress | `69 08 25 00 00 00 00 00 00 00 00 00 00 00 00 96` |
| Start huyết áp | `69 02 00 00 00 00 00 00 00 00 00 00 00 00 00 6B` |
| Đọc cài đặt HR tự động | `16 01 00 00 00 00 00 00 00 00 00 00 00 00 00 17` |
| HR tự động: bật, 30 phút, start 5, thấp 40, cao 150, switch 1 | `16 02 01 1E 05 28 96 01 00 00 00 00 00 00 00 FB` |
| SpO2 tự động bật | `2C 02 01 00 00 00 00 00 00 00 00 00 00 00 00 2F` |
| HRV tự động bật, 30 phút | `38 02 01 0A 1E 00 00 00 00 00 00 00 00 00 00 63` |
| Stress tự động bật | `36 02 01 00 00 00 00 00 00 00 00 00 00 00 00 39` |
| Hồ sơ: 24h, metric, gender 0, 30 tuổi, 175 cm, 70 kg, 120/90 | `0A 02 00 00 00 1E AF 46 78 5A 00 00 00 00 00 F1` |
| Mục tiêu 8000 bước, 500 cal, 5000 m | `21 02 40 1F 00 F4 01 00 88 13 00 00 00 00 00 12` |
| Tìm ring | `50 55 AA 00 00 00 00 00 00 00 00 00 00 00 00 4F` |
| Tắt nguồn | `08 01 00 00 00 00 00 00 00 00 00 00 00 00 00 09` |
| Factory reset | `FF 66 66 00 00 00 00 00 00 00 00 00 00 00 00 CB` |
| Khai báo Android 10, model "Pixel 7" | `04 02 0A 50 69 78 65 6C 20 37 00 00 00 00 00 69` |
| Push SMS "Hello" (1/1) | `72 01 01 01 48 65 6C 6C 6F 00 00 00 00 00 00 69` |
| ← Notify bước chân 3000 / 140 cal / 2000 m | `73 12 00 0B B8 00 00 8C 00 07 D0 00 00 00 00 AB` |
| ← Notify sốt 38.5 °C (`0x0181` = 385) | `73 3D 81 01 00 00 00 00 00 00 00 00 00 00 00 32` |
| ← Ring bấm chụp ảnh | `02 02 00 00 00 00 00 00 00 00 00 00 00 00 00 04` |
| ← Ring tìm điện thoại | `22 01 00 00 00 00 00 00 00 00 00 00 00 00 00 23` |
| ← Phản hồi lỗi cho cmd 3 (SDK gốc bỏ qua, §1.6) | `83 00 00 00 00 00 00 00 00 00 00 00 00 00 00 83` |

---

## 7. Trình tự khởi tạo của app sau khi kết nối

Nguồn: `APP/ui/base/watch/DeviceCmdInit$initDeviceSetting$1.java:146-719`, `B/BleOperateManager.java:247-258`.

1. Discover service → bật notify `6e400003` → đọc DIS `2A27` (HW) và `2A26` (FW).
2. `SetTimeReq(1)` (cmd 1) → nhận `SetTimeRsp` (cờ tính năng/màn hình).
3. `BindAncsReq` (cmd 4, không callback).
4. `DeviceSupportReq` (cmd 60) → nếu `supportBlePair` thì `bleCreateBond()`.
5. `TimeFormatReq` đọc/ghi (cmd 10).
6. Đọc hàng loạt: `SetMessagePushReq` (97), pin (3), HR setting (22), HRV setting (56), DND (6), Touch (59, `{1,1}`), Pressure setting (54), SpO2 setting (44), BP setting (12), PalmScreen ring-read (`05 03`), Degree (25), Temperature setting (`3A 03 01`), Target (33).

---

## 8. Ghi chú cho SDK tự viết

- Giữ map "request đang chờ" theo `cmd & 0x7F`. Coi `0x80|cmd` là lỗi của request đó. Cho phép một request nhận **nhiều** gói phản hồi (cmd 105, 13, 55, 57, 122…), với điều kiện kết thúc riêng cho từng lệnh.
- Tách listener notify (2, 17, 29, 34, 47, 115, 120) khỏi luồng request/response. Lưu ý cmd 105 vừa là phản hồi vừa đến liên tục như một luồng.
- Tuần tự hoá việc ghi: chờ write-callback trước khi gửi lệnh tiếp, giống SDK gốc.
- Khi giải mã, kiểm tra endianness theo từng trường (§1.7) và BCD (§4.2, §4.10).
- Không giả định ring hỗ trợ một lệnh trước khi đọc cmd 60 và cờ trong phản hồi cmd 1.
