# App QRing iOS 1.3.1: tầng BLE (phân tích tĩnh)

> Nguồn: `sdks/qring/research/ios/qring-1.3.1/Payload/QcRing.app/QcRing` (`com.qcwx.qcring.app`, arm64).
> Chỉ phân tích tĩnh: `otool -ov` (metadata ObjC), `otool -tV` (disassembly) cộng script giải `objc_msgSend$sel`
> stub, `__cfstring` và `__cstring`. Không chạy app, không kết nối thiết bị.
> Địa chỉ `0x1000…` là địa chỉ ảo trong binary. Phần **(suy luận)** là kết luận gián tiếp, chưa đọc thẳng từ code.

## 0. Tóm tắt

- SDK BLE được biên dịch **thẳng vào binary chính**. Không có framework riêng (`Frameworks/` chỉ chứa thư viện UI/mạng).
  Có 2 tầng:
  - Tầng ObjC, build ở chế độ -O0 nên dễ đọc: `OdmBleCentralManager` (central),
    `QIFBleDefaultPeripheral`/`QIFBlePeripheral` (GATT), `QIFBlePeripheralContainer`, `QIFBleCmdBase` cùng khoảng 90 lớp
    `QIF*Cmd` (mỗi lệnh một lớp), `OdmBandCmdCreator` (facade), `QIFDeviceManager` (chuỗi khởi tạo),
    `OdmBandNotifyCenter` (gói ring tự gửi), `QCMeasureCmdManager` (đo).
  - Tầng app Swift: `QIFDeviceBindViewController` (quét/bind), `QIFTabHomeViewModel` (nối lại và đồng bộ),
    `QIFLogicForAppDelegate` (ObjC, nối lại khi app quay về foreground).
- Giao thức **giống Android**: frame 16 byte, checksum = tổng & 0xFF, cùng UUID, big-data `BC`.
  Khác biệt chính so với SDK iOS của mình:
  1. Bật notify kiểu **"bắn rồi quên"**, cho **mọi** characteristic có thuộc tính Notify, ngay trong
     `didDiscoverCharacteristicsFor`. App **không chờ** `didUpdateNotificationState` và lỗi chỉ được ghi log.
  2. Lệnh **0x04 bản iOS là `04 01 <iOS major> <mã model iPhone>`**, gửi **đầu tiên** (trước SetTime) và chờ phản hồi `04`.
  3. Không đọc 2A27/2A26 trước handshake. Phải đến bước "5.x" của luồng đồng bộ mới đọc 2A23/2A26/2A27.

## 1. Quét / kết nối (`OdmBleCentralManager`)

| Hạng mục | Giá trị (bằng chứng) |
|---|---|
| Tùy chọn khi tạo `CBCentralManager` | `ShowPowerAlert=@YES`, `RestoreIdentifier=@"QCWXBluetoothRestore"`, queue = main; dictionary còn có key thừa `CBConnectPeripheralOptionNotifyOnConnectionKey=@YES` (vô nghĩa với central). `-[OdmBleCentralManager init]` @`0x10000a98c` |
| `UIBackgroundModes` | `bluetooth-central`, `fetch`, `remote-notification` (Info.plist) |
| Quét | `scanForPeripheralsWithServices:nil options:{AllowDuplicates=@NO}`, tức **không lọc service** (`scanWithServices:` @`0x10000adcc`, `mov x2,#0` @`0x10000b59c`) |
| Trước khi quét | `retrieveConnectedPeripheralsWithServices:` với danh sách service truyền vào, đưa vào kết quả với RSSI 0. App truyền `["FEE7", "6E40FFF0-B5A3-F393-E0A9-E50E24DCCA9E", "DE5BF728-D711-4E47-AF26-65E3012A5DC7"]` (@`0x100ee9d08`). Danh sách này được lưu vào `NSUserDefaults["ODMLASTSCANSERVICES"]` |
| Lọc trong lúc quét | Tầng central không lọc. Màn bind lọc tên theo cấu hình server `Cache_DeviceScanConfig_All` (`contains`/`hasPrefix`). Khi hiển thị thì bỏ tiền tố `O_` / `Q_` |
| MAC lấy từ adv | `macFromAdvertisementData:` đọc `kCBAdvDataManufacturerData`: dài **≥10 thì lấy byte [4..9]**, đúng 8 thì [2..7], đúng 6 thì [0..5], định dạng `%02x:…`, cache bản UPPERCASE theo `identifier`. Nếu không có thì thử từng value của `kCBAdvDataServiceData`. (R09: `34 12 FE E7 30 32 43 31 84 04`, MAC = `30:32:43:31:84:04`) |
| Loại thiết bị | UUID 16-bit đầu tiên trong `kCBAdvDataServiceUUIDs`: `FEE7`, `FE00`, `FE01` dẫn tới `setDeviceType:` (giống Android) |
| Tùy chọn connect | `{NotifyOnDisconnection=@YES, EnableTransportBridging=@YES}` (`connect:` @`0x10000b938`). **Không** dùng `EnableAutoReconnect` (iOS 17), không dùng `RequiresANCS` |
| Trước khi connect | Nếu `peripheral.state == .connecting` thì `cancelPeripheralConnection` rồi mới `connectPeripheral` lại |
| Timeout | Quét ở màn bind: 10 s. Connect ở màn bind: 8 s (`connectTimeOut`). `connectDeviceName:…` (DFU): mặc định 6 s. CoreBluetooth không tự hết giờ |
| Lưu thiết bị | `ODMLASTBLEIDENTIFIER` = `identifier.UUIDString` (lưu trong `didConnect`) |
| Lấy lại peripheral | `lastPeripheral`: dùng `retrievePeripheralsWithIdentifiers:[ODMLASTBLEIDENTIFIER]`. Nếu không có thì `retrieveConnectedPeripheralsWithServices:(ODMLASTSCANSERVICES)` và so `identifier` (@`0x10000f624`) |
| State restoration | `willRestoreState`: duyệt `CBCentralManagerRestoredStatePeripheralsKey`, peripheral nào trùng `ODMLASTBLEIDENTIFIER` thì gán vào ivar. Hàm này không tự connect |
| Delegate có cài | `didUpdateANCSAuthorizationForPeripheral:` (chỉ ghi log), `connectionEventDidOccur` (khai báo nhưng không gọi `registerForConnectionEvents`) |

### Nối lại

| Cơ chế | Chi tiết |
|---|---|
| `startReconnectSuc:faile:` (@`0x100010300`) | Điều kiện: central `.poweredOn` (5) và không đang `isConnecting`. Gọi `connectCurrentPeripheral` **ngay**, rồi đặt `NSTimer` **lặp mỗi 4,0 s** (`fmov d0,#4.0`, `repeats:YES`, `NSRunLoopCommonModes`) gọi lại `connectCurrentPeripheral`, nghĩa là `connect:lastPeripheral` (cancel nếu đang connecting rồi connect lại). **Không có giới hạn số lần hay thời gian**. Timer dừng ở `didConnect` (`stopReConnectTimer`) hoặc khi người dùng ngắt |
| Ai gọi | `QIFTabHomeViewModel` khi mất kết nối ("0.+++++开始重连", @`0x10097dfa0`, có nhánh `asyncAfter 1.5 s`) và `-[QIFLogicForAppDelegate autoReconnectBleDevice]` ở `applicationDidBecomeActive` (nếu app vừa về từ nền và đã bind) |
| `didDisconnect` | Tầng central không tự nối lại. Nó báo delegate rồi xóa session |
| `didFailToConnect` | Ghi log, báo delegate, `isConnecting=NO` |

## 2. Thiết lập GATT sau khi connect

Trình tự (`didConnectPeripheral` @`0x10000e198`, sau đó `QIFBleDefaultPeripheral`):

| Bước | Hành động | Bằng chứng |
|---|---|---|
| 1 | `stopReConnectTimer`, lưu identifier, tạo session (lớp `"QIFBlePeripheral"` do `registeClassForPeripheral:` trả về) | @`0x10000e5b0`, @`0x100eed1dc` |
| 2 | `startRetrivePeripheral`: `discoverServices:nil` (nếu `state != .connected` thì bỏ) | @`0x1000c185c` |
| 3 | `didDiscoverServices`: `discoverCharacteristics:nil forService:` **cho mọi service, cùng lúc** | @`0x1000c27a8` |
| 4 | `didDiscoverCharacteristicsForService`: với **mỗi** characteristic có `properties & 0x10` (Notify) thì `setNotifyValue:YES` **ngay, không chờ callback**. Mọi characteristic được thêm vào `contentedCharacteristic` | @`0x1000c2b64`–`0x1000c2b90` |
| 5 | Khi số service đã khám phá characteristic bằng `services.count` thì `setIsFree:YES`, post `OdmNotify_RetrieveFinish`, gọi delegate `retrieveFinish:`. **Từ lúc này mới cho gửi lệnh** | @`0x1000c2c9c` |
| 6 | `didUpdateNotificationState` lỗi: chỉ `NSLog("(测试用, 记得删除)(%@)通道通知数据失败…")`, **không retry, không ngắt** | @`0x1000c357c` |

- Thứ tự bật notify bằng đúng thứ tự service/characteristic iOS trả về. Gồm `6e400003` và `de5bf729`, cùng
  mọi characteristic notify khác nếu có. Các lệnh `setNotifyValue` được gửi liên tiếp, không xếp hàng.
- MTU: không gọi `maximumWriteValueLength(for:)`. Chunk big-data = biến toàn cục, mặc định 20, được cập nhật bằng
  byte[1] của notify `0x2F` (`OdmBandNotifyCenter dealNotify:` @`0x100029a64`) và reset về 20 khi ngắt.
- Kiểu ghi: lệnh 16 byte lên `6e400002` dùng `.withResponse` (`writeValue:…type:0`). Big-data/DFU lên `de5bf72a` dùng
  `.withoutResponse` (`writeDataToDFUChannel:withResponse:NO`). Characteristic được tìm theo UUID chữ thường trong
  toàn bộ danh sách, không phân biệt service.
- Không có delay cố định giữa các bước. Gửi lệnh được điều phối bằng cờ `isFree`: mỗi lúc chỉ một `QIFBleCmdBase`,
  và lệnh chỉ chạy khi `peripheral.state == .connected` (`-[QIFBleCmdBase start]` @`0x10005cfac`).

### So với `QRingClient` / `GattConnection` của mình

| | App QRing iOS | SDK mình | Hệ quả |
|---|---|---|---|
| Bật notify | Fire-and-forget, cho mọi char notify, ngay khi khám phá xong từng service | `setNotify(6e400003)` **chờ** `didUpdateNotificationState` tối đa 5 s, timeout thì `disconnect()` | Lỗi "Hết thời gian chờ bật notify" trên R09 (-89 dBm) là do mình coi đây là lỗi chết. App gốc không bao giờ fail ở bước này |
| Lệnh đầu tiên | `04 01 …` (ANCS/iOS) ngay sau RetrieveFinish | Đọc 2A27, 2A26, bật de5bf729, rồi `01` SetTime, rồi `04 02 0A <model>` (bản Android) | Ring được báo nhầm là Android **(suy luận: có thể làm ring chọn đường thông báo Android, bỏ ANCS)** |
| Đọc 180A | Muộn (bước 5.0: 2A23 lấy MAC, 5.1: 2A26/2A27) | Trước mọi lệnh, mỗi bước chờ 5 s | Thêm 2 round-trip dễ timeout khi sóng yếu |
| Timeout discovery | Không có | 20 s | Ổn |
| Nối lại | Connect ngay, rồi cancel+connect mỗi 4 s, vô hạn | Chờ 2 s, rồi pending connect không timeout, lỗi thì lùi 2/5/10/30/60 s | Sau 1 lỗi notify, mình có thể chờ tới 60 s |

## 3. Handshake / lệnh đầu tiên

Chuỗi `QIFDeviceManager initBandBasicSettingSuccess:fail:` (@`0x10002e6b4`), gọi từ luồng đồng bộ
"0 准备进入同步流程" của `QIFTabHomeViewModel` sau khi kết nối:

| # | Log | Lệnh (frame 16 byte, checksum ở byte 15) | Retry |
|---|---|---|---|
| init.1 | `准备同步 ANCS` | **`04 01 VV MM`**, chờ phản hồi đủ 16 byte với `byte0 == 0x04` (`QIFBleSetANCSFlagCmd` @`0x1000b784c`, format `"0401%02lX%02lX"`) | không |
| init.2 | `准备同步时间` | `01` + `yyMMddHHmmss` (chuỗi số, tức BCD) + mã ngôn ngữ (`"01%@%02lX"`), phản hồi là bảng khả năng | 3 lần, cách 1 s |
| init.2.1 | `准备同步配置` | `3C` (`QIFGetDeviceFeatureConfig`, `"3c"`) | 3 lần, cách 1 s |
| (tiếp) | | `0A 01 00 00` đọc time format, rồi `0A 02 …` ghi 24h/đơn vị/giới tính/tuổi/cao/nặng/BP/HR alarm (init.3 `个人信息`) | 3 lần, cách 1 s |
| init.4 | `准备同步 健康目标` | `21 …` mục tiêu | |
| 5.0 | `获取设备MAC地址` | **Đọc 180A/2A23** (System ID 8 byte), MAC = `b7:b6:b5:b2:b1:b0` | |
| 5.1 | `获取设硬件软件版本号` | Đọc 2A26, 2A27 | |
| 6.0 | `获取设备电量` | `03 01` (Android gửi `03 00`) | |
| 9.0 | `获取设备缺失文件` | danh sách file cần tải | |

Ghi chú: thất bại ở init.1 vẫn chạy tiếp init.2 **(suy luận: block thành công/thất bại đều gọi bước sau)**. Lệnh nào
lỗi thì tạm dừng 1 s (`dispatch_after 1e9 ns`) rồi thử lại, tối đa 3 lần.

### 0x04 bản iOS (câu trả lời cho mục "mã iOS chưa rõ")

```
[0]=04  [1]=01 (iOS; Android=02)  [2]=iOS major version (UIDevice.systemVersion.intValue, hex)
[3]=mã model iPhone (bảng dưới; model không có trong bảng thì 00)  [4..14]=00  [15]=checksum
```
Ví dụ: iOS 18, iPhone 15 Pro (mã 35 = 0x23) gửi `04 01 12 23 00 00 00 00 00 00 00 00 00 00 00 3A`.
iPhone 6 Plus không có trong bảng thứ hai nên cũng ra `00`.
iPhone mới hơn bảng (iPhone 16/17…) thì byte [3] = `00`.

Bảng `+[OdmCmdHelper iPhoneDeviceType]` (@`0x1000e6abc`). `uname().machine` được đổi sang tên marketing rồi sang mã:

| Mã | Model | Mã | Model | Mã | Model |
|---|---|---|---|---|---|
| 0 | iPhone (không rõ / không có trong bảng) | 13 | XS | 26 | 13 Pro |
| 1 | 5 | 14 | XS Max | 27 | 13 Pro Max |
| 2 | 5c | 15 | XR | 28 | SE (3rd) |
| 3 | 5s | 16 | 11 | 29 | 14 |
| 4 | 6 | 17 | 11 Pro | 30 | 14 Plus |
| 5 | 6S | 18 | 11 Pro Max | 31 | 14 Pro |
| 6 | 6S Plus | 19 | SE 2 | 32 | 14 Pro Max |
| 7 | SE | 20 | 12 | 33 | 15 |
| 8 | 7 | 21 | 12 Mini | 34 | 15 Plus |
| 9 | 7 Plus | 22 | 12 Pro | 35 | 15 Pro |
| 10 | 8 | 23 | 12 Pro Max | 36 | 15 Pro Max |
| 11 | 8 Plus | 24 | 13 mini |  |  |
| 12 | X | 25 | 13 |  |  |

(Bảng machine-id → tên: `iPhone10,3/10,6`→X, `iPhone11,2`→XS, … `iPhone16,1`→15 Pro, `iPhone16,2`→15 Pro Max.)

### Mã ngôn ngữ của SetTime (iOS)

`zh-Hans 0, en 1, zh-Hant 2, el 3, fr 4, de 5, it 6, es 7, nl 8, pt-PT 9, ru 10, tr 11, ja 12, ko 13, pl 14, ro 15,
ar 16, th 17, vi 18, id 19, hi 20, cs 21, sk 22, hu 23, he 24, hr 25, sl 26, ms 27, uk 28, lt 29, lv 30, et 31, da 32,
sv 33, fa 34, ur 35` (`getLanguageType` @`0x10007f528`). Bảng iOS có thêm 27–34 so với Android.

### Bind / "thuộc về" một điện thoại

| Lệnh | Bytes | Ghi chú |
|---|---|---|
| `QIFBindAlertCmd` (`alertBindingSuccess`) | `10 00…00 10` | CMD 0x10 = `CMD_BIND_SUCCESS` (Android có khai báo nhưng không gửi). Chờ phản hồi `byte0 == 0x10`. Gửi sau khi bind (`QIFTabHomeViewModel` @`0x1009814f8`) |
| `QIFRegisterDeviceCmd` | `2D 01` hoặc `31 01` (tùy cờ) | `LogicForDevice` gọi, có vẻ liên quan cử chỉ/chạm **(suy luận)** |
| `QIFGetPhoneBindNameCmd` | big-data `BC 2E …` | Trả `mac` (6 byte đầu) và `name`: MAC/tên Bluetooth classic (giống Android 0x2E) |
| ANCS | `04 01 …` | Báo ring rằng điện thoại là iOS. **(suy luận)** Ring có thể dùng ANCS, mà ANCS cần mã hóa/bond, nên iOS có thể hiện hộp thoại ghép đôi. App không tự gọi pairing và không dùng `RequiresANCS` |
| Server | `GET /v1/device/app/lock?uid&mac` (`SXNetworkServerApi getDeviceLockApp`) | Khóa phía server, không thấy được gọi. Không phải cơ chế BLE |

Không thấy token/khóa phía BLE nào khiến ring từ chối central khác. Ring "bị giữ" vì thiết bị BLE chỉ nhận **một**
kết nối và **ngừng quảng bá** khi đang nối **(suy luận, khớp quan sát DS500)**. Trên cùng một iPhone,
`retrieveConnectedPeripherals(withServices:[FEE7, 6E40FFF0, DE5BF728])` lấy được ring dù app khác đang giữ link
(iOS chia sẻ link ở mức hệ thống).

## 4. Đo

| Lệnh | iOS | Android (docs/02) |
|---|---|---|
| Bắt đầu | `69 <type>`. Byte tham số chỉ thêm khi type ∈ {2, 4–7, 9} **và** có truyền param (`QIFBleOpenHealthDetectionSwitchCmd` @`0x1000f5cf0`). `QCMeasureCmdManager` gọi bản không param, nên thực tế là `69 01`, `69 03`, `69 08`, `69 0A`, `69 0B` | `69 01 00`, `69 03 25`, … |
| Dừng | `6A <type> [giá trị cuối]`: type 1 có 1 byte (HR), type 2 có 2 byte (SBP, DBP), type 3–4 và 7–11 có 1 byte, còn lại không có (`QIFCloseHealthDetectionSwitchCmd`) | `6A <type>` |
| Mã type | HR 1, BP 2, SpO2 3, buồn ngủ 4, đo một chạm 5, stress 8, đường huyết 9, HRV 10, nhiệt độ 11 (`convertToDetectionType:` @`0x100175d48`) | giống |
| Timeout đo | 30 s (operate type 7: 80 s) (`startToMeasuringWithOperateType:` @`0x100173e24`) | |
| HR thời gian thực | `1E 01` bắt đầu, `1E 03` giữ (keep-alive), `1E 02` kết thúc | giống (R09 trả lỗi với `1E 03`) |
| Kết quả | Gói `69` đi qua `OdmBandNotifyCenter dealNotify:` (các case: `02 03 1E 22 2B 2F 61 69 6C–70 73 74 78 A1 BC`) | |

Phản hồi của lệnh: `receiveData` kiểm `length == 16` và `byte0 == cmd` (`0x69`/`0x6A`). Không thấy kiểm cờ lỗi `0x80`.

## 5. Quảng bá thưa / tiết kiệm pin / tham số kết nối

- Không thấy lệnh đánh thức, lệnh đổi chu kỳ quảng bá hay connection parameter update trong app.
  `QCRMineLowPowerCell`/`lowPowerAlert` chỉ là cảnh báo pin yếu.
- Cách app đối phó với thiết bị quảng bá thưa: (1) pending `connectPeripheral` không timeout, cộng chu kỳ
  cancel/connect mỗi 4 s; (2) `retrieveConnectedPeripherals` theo 3 service; (3) state restoration
  `QCWXBluetoothRestore` cùng `bluetooth-central`.
- `CBConnectPeripheralOptionEnableTransportBridgingKey=YES` chỉ có tác dụng với thiết bị dual-mode (BR/EDR).
  Không ảnh hưởng ring BLE-only **(suy luận)**.

## 6. Việc nên đổi trong SDK iOS của mình

1. **Notify**: sau khi khám phá characteristic, gọi `setNotifyValue(true)` cho `6e400003` và `de5bf729` liên tiếp,
   **không chặn** bằng timeout. Nếu vẫn muốn chờ thì timeout chỉ ghi cảnh báo, không `disconnect()`. Coi việc nhận
   gói notify đầu tiên (vd phản hồi `04`/`01`) là xác nhận notify đã chạy.
2. **0x04 iOS**: gửi `04 01 <iOSMajor> <modelIdx|0>` (không có chuỗi model ASCII) **trước** SetTime, chờ phản hồi `04`
   (timeout không chết).
3. **Thứ tự**: `04`, rồi `01` SetTime (retry 3 lần × 1 s), rồi `3C` (retry 3 lần × 1 s). Đọc 2A27/2A26 (và 2A23 nếu cần
   MAC) **sau** handshake, không chặn connect nếu lỗi.
4. **Connect options**: `[CBConnectPeripheralOptionNotifyOnDisconnectionKey: true]` (tùy chọn thêm
   `EnableTransportBridgingKey: true` cho giống app). Không cần `EnableAutoReconnect`.
5. **Nối lại**: sau khi mất link, connect lại ngay (không chờ 2 s). Nếu lần trước lỗi vì notify/handshake thì không
   lùi tới 60 s, giữ chu kỳ ngắn (~4 s) như app gốc. Trước khi connect, thử `retrieveConnectedPeripherals(withServices:
   [FEE7, 6E40FFF0-…, DE5BF728-…])` ngoài `retrievePeripherals(withIdentifiers:)`.
6. **MAC trên iOS**: lấy từ manufacturer data (`len ≥ 10` thì byte 4..9) hoặc đọc 180A/2A23 (8 byte, MAC =
   `b7:b6:b5:b2:b1:b0`).
7. Đo: có thể gửi `69 <type>` không kèm byte `25`. Khi dừng gửi `6A <type> <giá trị cuối>` như app iOS (không bắt buộc).

## 7. Đã áp dụng vào SDK (iOS)

Chỉ sửa code và unit test, **chưa thử trên thiết bị**.

| Mục §6 | Trạng thái | Chỗ sửa |
|---|---|---|
| 1. Notify | Đã áp dụng. `GattConnection.setNotify(..., wait: false)` gửi `setNotifyValue` rồi trả về ngay. Callback lỗi hoặc không đến chỉ ghi log. Callback thành công hoặc gói notify đầu tiên được ghi vào `confirmedNotify`. Chỉ QRing dùng đường này; GloryFit/Standard vẫn chờ và lỗi thì fail như cũ | `GattConnection.swift`, `QRingClient.connect` |
| 2–3. Handshake | Đã áp dụng. `04 01 <iOS major> <mã model>` chờ phản hồi 3 s, không có phản hồi vẫn đi tiếp. Sau đó `01` SetTime và `3C`, mỗi lệnh thử tối đa 3 lần cách 1 s (mất kết nối thì dừng ngay). SetTime/3C hỏng cả 3 lần thì kết nối lỗi. Đọc 2A27/2A26/2A23 **sau** handshake, lỗi chỉ ghi log. MAC từ 2A23 được dùng khi quảng bá không có MAC. Bảng machine-id → mã model nằm trong `QRingHandshake.iPhoneModels` | `QRingHandshake.swift`, `QRingClient.swift` |
| 4. Connect options | Đã áp dụng `NotifyOnDisconnection=true`. Không thêm `EnableTransportBridging` vì ring chỉ có BLE | `BleCentral.connect` |
| 5. Nối lại | Lịch lùi dần riêng theo driver qua `DeviceDriver.reconnectBackoff`. QRing dùng `[2, 4]` (tức 2, 4, 4, 4… s). Driver khác vẫn 2/5/10/30/60 s. `systemServices` của QRing = FEE7, 6E40FFF0, DE5BF728. **Chưa đổi**: độ trễ 2 s trước lần nối lại đầu sau khi rớt link (`reconnectDelay`, dùng chung mọi driver) | `Model.swift`, `DeviceManager.swift`, `QRingDriver.swift` |
| 6. MAC iOS | Đã có từ trước (manufacturer data), thêm 2A23 | `QRing.swift`, `QRingHandshake.macFromSystemId` |
| 7. Đo | Dừng: đã đổi sang `6A <type> <giá trị cuối>` (BP gửi SBP, DBP), khớp cả app Android lẫn iOS. Bắt đầu: **giữ** `69 <type> 25`, vì byte `25` đã kiểm chứng trên R09 qua Android, còn bản không có `25` của app iOS chưa thử | `Measurement.swift` (`stopPacket`), `QRingClient.measure` |
| Khác | Bảng ngôn ngữ SetTime thêm ms, uk, lt, lv, et, da, sv, fa (27–34). Loại thiết bị: DS500/DS520/DS12/DS1314/HS500/H59 → band. Sau khi kết nối, 2A27 dùng để chỉnh loại (`HS500A_…` → band, `RT0x_…` → ring) | `QRingClient.languageCode`, `QRing.guessKind`/`kind(fromHardware:)` |

Test: `HandshakeTests` (bytes 0x04, thứ tự và retry bằng transport giả, SetTime BCD, 2A23, stop packet, loại thiết bị),
`CoreTests.testTolerantNotifyCallbackNeverFails`, `DeviceManagerTests.testPerDriverBackoffOverride`.
