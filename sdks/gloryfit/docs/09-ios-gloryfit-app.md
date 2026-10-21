# 09 — App GloryFit iOS 1.6.28 (UTESmartBandApi): kết nối, nhịp tim, mặt đồng hồ, AGPS, OTA

> Nguồn: IPA đã giải mã `research/ios/gloryfit-1.6.28/Payload/GF.app` (bundle `vv.GloryFit.ute`, build 1.6.28.11).
> Chỉ phân tích tĩnh: `otool -ov/-tV`, `nm`, `strings`, `xcrun dyld_info`, script Python tự viết để gán chuỗi/selector/ivar
> cho lệnh `adrp+add`. Không chạy app, không kết nối thiết bị.
> - `UTESmartBandApi.framework` (SDK của UTE, ObjC, build **-O0**, còn tên hàm) ⇒ địa chỉ dạng `0x13c6e4` là offset trong file này.
> - `GF` (app, đã strip): địa chỉ dạng `0x100584488`; tên method lấy từ metadata ObjC.
> Phần không đọc thẳng từ mã được ghi **(suy luận)**.

---

## 0. Tóm tắt (việc cần sửa trong SDK của mình)

| # | Phát hiện | Việc nên làm |
|---|---|---|
| 1 | iOS **không quét để nối lại**: lưu `identifier`, gọi `retrievePeripheralsWithIdentifiers:` rồi `connectPeripheral:` (lệnh chờ của iOS không có timeout, bộ điều khiển BLE tự bắt gói quảng bá dù thưa). Nối lại ngay khi mất kết nối và khi Bluetooth bật. | Android: thiết bị đã biết thì dùng `connectGatt(autoConnect = true)` (chờ nền, không timeout 40 s), không phụ thuộc quét. Y25 quảng bá thưa sẽ vẫn được nối |
| 2 | Quét: `scanForPeripheralsWithServices:nil`, `AllowDuplicates = YES`, lọc phần mềm theo **UUID dịch vụ trong quảng bá** (13 UUID, bảng §1.2) và RSSI ≥ −75. Màn tìm thiết bị còn gọi `retrieveConnectedPeripheralsWithServices:` với `55FF` và `55F0` | Thêm `0x5554, 0x4544, 0x4231, 0x424C, 0x4F4F, 0x3455` vào `Ute.ADVERTISED`. iOS port: `systemServices = [55FF, 55F0]` |
| 3 | HT43 và Y25 đều có cờ **`isHas24HourHRM`** (33F1 byte 15 bit 6). Với cờ này SDK iOS **từ chối** cả `D6 01` lẫn `E5 11` ("Device Heart rate is automatic detection, Does not support manual via App"). Lệnh đo tay mới `startSingleHRMMeasurement` (`E5 11`) chỉ chạy khi có `isHasHRMTimedMeasurement` (34F1 byte 8 bit 7), hai máy **không** có | Không coi `E5 11` là cách đo chính trên HT43. Lấy nhịp tim từ HR 24 h: `F7 01` (bật), `F7 09 01 00 0A` (chu kỳ, phút BE), nghe `F7 03` (đo định kỳ) và **`F7 0B YYYY MM DD hh mm bpm`** (người dùng đo tay trên đồng hồ). SpO2 `34 11` vẫn được phép |
| 4 | Mặt đồng hồ: gói `27` ghi **không phản hồi** lên `34F1`; một NSTimer 20 ms, mỗi lần gửi tối đa **10 gói**; dừng ở ranh giới 4 KB đến khi có `26 03 04` (**không** có timeout 5 s); `26 03 03 HHLL` ⇒ chờ **0,6 s** rồi gửi lại từ gói HHLL; xong ⇒ chờ 0,5 s ⇒ `26 03 00` | Bản Android đang ghi có phản hồi. Có thể chuyển sang không phản hồi + nhịp 10 gói/20 ms để nhanh hơn. Đổi xử lý `26 03 03` sang “chờ 600 ms rồi gửi lại từ chỉ số” |
| 5 | AGPS (`01 E9 AC 03 01 st`): st = 2 ⇒ app tải ephemeris từ `getAgpsFile`, rồi gửi `01 E9 AB 03 01 03`. st = 1 ⇒ app gửi file bằng các gói `01 E9 AB 04 …` (khối 4 KB, ACK `01 E9 AC 04 01 st`). Truy vấn thông tin: `01 E9 AA 01` | Cài §4. Muốn làm tối thiểu thì trả lời đúng chuỗi trên; chỉ “im lặng” thì đồng hồ tiếp tục xin mỗi 60 s |
| 6 | OTA: SDK iOS có thêm app key mặc định (`4f819c88…` cho Realtek, `06808eae…`, `f0b520cd…`, `e2b9c738…`) và app GF có `12b0cb43…`, `53c101af…`. **Đã hỏi 15 lần: không có firmware HT43** (§5) | Không có gì mới để tải |

---

## 1. Kết nối trên iOS

### 1.1 CBCentralManager

| Mục | Giá trị | Bằng chứng |
|---|---|---|
| Khởi tạo | `[[CBCentralManager alloc] initWithDelegate:self queue:dispatch_queue_create("UTESDK.QueueBluetooth", NULL)]`, **không có options** | `-[UTESmartBandClient mgr]` `0x13bb54–0x13bb84` |
| Restore identifier / state restoration | **Không dùng.** Chuỗi `centralManager:willRestoreState:` chỉ có trong danh sách giao thức, không có hàm cài đặt. App GF cũng không có `CBCentralManagerOptionRestoreIdentifierKey` | grep cả hai binary |
| `ShowPowerAlert` | Không | như trên |
| Background mode | `UIBackgroundModes = [bluetooth-central, bluetooth-peripheral]` | `Info.plist` |

### 1.2 Quét

App GF cấu hình SDK trong `-[BlueToothManager initClientManager]` (`0x1005842c8`):

| Lệnh | Giá trị |
|---|---|
| `setUTESDKKey:` | `dcd05f241b65ec7b6af0bbe6f05145c2` |
| `setFilerServersArray:` | 8 nhóm: `[5554,4544,4231,55FF]`, `[5533]`, `[424C,4F4F]`, `[55F0]`, `[5534,3455]`, `[5536]`, `[5555]`, `[553C]` |
| `setIsScanRepeat:` | YES ⇒ `CBCentralManagerScanOptionAllowDuplicatesKey = YES` |
| `setFilerRSSI:` | −75 |
| `setIsEnableTransportBridgingKey:` | YES |
| `setFirmwareTest:` | YES (ảnh hưởng OTA, §5) |
| `setDebugUTELog:` / `setLogType:` | YES / 2 |

`-[UTESmartBandClient startScanDevices]` (`0x1ffad4`):

| Nhánh | Lệnh quét |
|---|---|
| `isScanAllDevice` | `scanForPeripheralsWithServices:nil` |
| Có `filerServers` (danh sách phẳng) | `scanForPeripheralsWithServices:[CBUUID…]` |
| Có `filerServersArray` (**GF dùng nhánh này**) | `scanForPeripheralsWithServices:nil`, lọc trong `didDiscoverPeripheral` |
| Mặc định | `scanForPeripheralsWithServices:@[5554, 55FF]` |

Lọc trong `centralManager:didDiscoverPeripheral:…` (`0x1434bc`): lấy `kCBAdvDataServiceUUIDs` thành chuỗi; thiết bị đạt nếu **bất kỳ** UUID nào trong 8 nhóm có trong quảng bá (`_block_invoke_2` `0x145034`: `containsObject:` ⇒ dừng). RSSI phải ≥ `filerRSSI`. `553C` trong quảng bá ⇒ `isHas553CUUID`. Manufacturer data ≥ 8 byte: bỏ 6 byte đầu, nếu ≥ 10 byte thì đọc phiên bản (`findDeviceVersionData:`). Manufacturer data bắt đầu `0808` ⇒ `isSwitchHeart` (`didConnectPeripheral` `0x1456f0`).

So với Android: GloryFit Android tìm chuỗi hex `54 55 44 45 31 42 FF 55` (= UUID `5554, 4544, 4231, 55FF`) và `4C 42 4F 4F` (= `424C, 4F4F`). iOS xác nhận chúng là **UUID dịch vụ 16 bit trong AD**, không phải chuỗi tuỳ ý. **`Ute.ADVERTISED` hiện thiếu `5554, 4544, 4231, 424C, 4F4F, 3455`.**

### 1.3 Thiết bị hệ thống đã giữ kết nối

`-[LBSearchBandViewController getANCSBindDevice]` (`0x100530a7c`) gọi `retrieveConnectedDeviceWithServers:@[@"55FF"]` rồi `@[@"55F0"]`. SDK chuyển thành `retrieveConnectedPeripheralsWithServices:` (`0x21af34`). Mục đích là thấy đồng hồ đang được iOS giữ kết nối (ghép đôi ANCS, BT Classic gọi điện) nên **không quảng bá**.
**(suy luận)** Y25/HT43 có `isHasBluetooth3` (33F1 byte 2 bit 2). Khi điện thoại giữ liên kết Classic/LE, đồng hồ ngừng hoặc giảm quảng bá; điều này khớp ghi chép ở 01-protocol §10 ("không thấy quảng bá khi GloryFit giữ kết nối").

### 1.4 Kết nối và nối lại

| Bước | Mã |
|---|---|
| `connectUTEModelDevices:` | `NSUUID initWithUUIDString:identifier` ⇒ `retrievePeripheralsWithIdentifiers:@[uuid]` ⇒ `connectPeripherals:` (`0x2014c4`). **Không quét** |
| Options của `connectPeripheral:options:` | `NotifyOnConnection`, `NotifyOnDisconnection`, `NotifyOnNotification`, `RequiresANCS` (theo mặt nạ `deviceAlertType`, GF không đặt) + `CBConnectPeripheralOptionEnableTransportBridgingKey = YES` (`0x13c84c–0x13cc20`) |
| Timeout kết nối | **Không có** (iOS chờ đến khi thấy gói quảng bá) |
| `didConnectPeripheral` | `discoverServices:` ngay, không có khoảng chờ 800 ms như Android (`0x145a4c`) |
| Mất kết nối | SDK chỉ tự gọi lại `connectPeripherals:` khi đang đổi tính năng (`isChangeFeature`, `0x1467ec`). App GF gọi `connectUTEModelDevices:` với UUID đã lưu trong `uteManagerDevicesSate:` / `uteManagerBluetoothState:` (`0x1005884a0`, `0x100588640`) và `connectDeviceShowStatusBar:` (`0x10058ed98`). Có chặn "0,3 s không nối lặp" |

**Áp dụng:** Android `GattConnection.connect` đang `connectGatt(…, autoConnect = false, …)` với timeout 40 s rồi lùi dần (backoff). Với thiết bị đã ghép, `autoConnect = true` cho kết quả tương đương iOS: controller tự nối khi bắt được một gói quảng bá, kể cả khi Y25 chỉ quảng bá thưa. Vẫn giữ `autoConnect = false` cho lần ghép đầu (nhanh hơn).

### 1.5 GATT trên iOS (`peripheral:didDiscoverCharacteristicsForService:error:` `0x14772c`)

| Characteristic | Việc SDK làm |
|---|---|
| `34F2` | Bật notify. Nếu đã thấy `34F1` thì ghi ngay `01 A5 AA 0C` (không phản hồi) để đọc "device prepare info" (phiên bản + địa chỉ, dùng cho OTA Realtek; phản hồi qua `transform01A5_AA0C:per:`) |
| `34F1` | Kênh ghi lớn (`cbBlueTooth5WriteRead`) |
| `33F3` | **Mới so với tài liệu Android**: `cbNewWriteRead`, đọc ra "data status" (`receiveDeviceDataStatus:`, cờ `isHasDataStatus`, HT43/Y25 có) |
| `33F4` | **Mới**: bật notify |
| `33F1` / `33F2` | Ghi lệnh / bật notify |
| Cuối cùng | `readValueForCharacteristic:` cho `34F1` rồi `33F1` (`0x14a33c`) |

Kiểu ghi: lệnh `33F1` **có phản hồi** (`writeValue:…type:0`, `0x13e174`). Dữ liệu `34F1` (gói `27`, `01 E9`, `01 E3`…) **không phản hồi** (`type:1`, `UTEDeviceCommonTool sendDataToPeripheral:` `0x5a854`; gói `27` `0x1f2fe4`).

Đặt giờ (`syncBTtime` → `getNowTimeWithData:isDecimals:` `0x74dd4`): `A3 YYYY MM DD hh mm ss TZ` với **TZ = giờ lệch GMT (1 byte có dấu)**, thêm 1 byte (phút lệch / 36, đơn vị 1/100 giờ) nếu có `isHasAccurateTimeZone`. Bản Android của mình gửi 8 byte (thiếu TZ).

---

## 2. Nhịp tim, SpO2 trên HT43

### 2.1 Bảng tính năng theo SDK iOS (giải mã bằng `checkBleFunction:` `0x26fda4` và `checkBleFunction34F1:` `0x278e14`)

Byte tính theo vị trí trong 20 byte đọc được (byte 0 là byte đầu).

| Cờ | Vị trí | HT43 | Y25 | Hệ quả |
|---|---|---|---|---|
| `isHasHRM` | 33F1 b17.3 | 1 | 1 | |
| `isHas24HourHRM` | 33F1 b15.6 | **1** | **1** | Chặn `D6 01`, `E5 11` |
| `isHasHRMautoSwitch` (tĩnh/động) | 33F1 b14.3 | 0 | 0 | |
| `isHasHRMTimedMeasurement` | 34F1 b8.7 | **0** | **0** | Chặn `startSingleHRMMeasurement` |
| `isHasHRMAndBloodOxygenAuto` | 34F1 b10.0 | 0 | 0 | Chặn `setHRMAutoInterval:` |
| `isHasBloodOxygen` | 33F1 b7.6 | 1 | 1 | `34 11` được phép |
| `isHasBlood` | 33F1 b17.4 | 0 | 1 | |
| `isHasSportGPS` | 33F1 b1.7 | 1 | 1 | |
| `isHasGPS` / `isHasAGPS` (kiểu cũ) | 33F1 b16.1 / b8.1 | 0 / 0 | 0 / 0 | |
| `isHasRYAGPS` | 34F1 b14.6 | **1** | **1** | Luồng AGPS `01 E9` (§4) |
| `isHasAccountID` / mật khẩu / `isHasUserID` | 34F1 b9.3 / 33F1 b19.0 / 33F1 b7.2 | 0 | 0 | Không cần bind |
| `isHasDataStatus` | 33F1 b9.5 | 1 | 1 | Đọc `33F3` |
| Loại chip | 33F1 b0.3 "8762Cx" | 1 | 1 | Đi đường OTA Realtek |

(34F1 dựng lại từ 08-hardware §3.2: HT43 `00 F4 00 00 00 00 00 00 00 00 00 05 00 00 40 00 00 00 04 00`.)

### 2.2 Đường đi của lệnh đo

| API SDK | Lệnh | Điều kiện | Mã |
|---|---|---|---|
| `setUTEOption:` 0x10 (HeartDetectingStart) | `E5 11` (`sendExternalMsgToPeripheral:`) | `isHasHRM` **và không** `isHas24HourHRM` | `0x20bdc4–0x20bfac` |
| 0x11 (Stop) | `E5 00` | như trên | `0x20c1bc–0x20c1a4` |
| 0x13 / 0x12 (Static / Dynamic) | `D6 01` / `D6 02` | như trên | `0x20c26c`, `0x20c3a0` |
| `startSingleHRMMeasurement` / `stop…` | `E5 11` / `E5 00` | `isHasHRMTimedMeasurement` | `0x235238`, `0x235c4c` |
| `readHRMStatus:` | `E5 AA` ⇒ `E5 AA 11` (đang đo) / `E5 AA FF` | không | `0x234738` |
| `setHRM24Auto:time:` | `F7 09 en mmH mmL` | không | `0x216a18` |
| `setUTEHRMTimedMeasurement:time:` | `F7 09` + chu kỳ `0005/000a/001e/003c/0078/00b4/00f0/0168/05a0/02d0/01e0` | `isHasHRMTimedMeasurement` | `0x236760` |
| `…Duration:startTime:endTime:` | `F7 0F …` | như trên | `0x236e3c` |
| `setUTEHeartAuto:time:` | `D6 10 …` | không | `0x216be4` |
| `setUTEOption:` 0x2E (SpO2) | `34 11` / `34 00` | `isHasBloodOxygen` | `0x20c8dc` |

Gói đồng hồ tự gửi về nhịp tim (bảng tiền tố của `peripheral:didUpdateValueForCharacteristic:error:`):

| Tiền tố | Hàm | Định dạng |
|---|---|---|
| `F7 03` | `receiveTenMinLaterHRMData:` | `F7 03 YYYY MM DD hh mm bpm` (đo định kỳ) |
| `F7 04` | `receiveMaxMinAverageHRMData:` | max/min/avg |
| **`F7 0B`** | `receiveDeviceHeartDataManual:` (`0x1ef7e8`) | `F7 0B YYYY MM DD hh mm bpm`: **người dùng đo trên đồng hồ** |
| `F7 05`, `F7 07` / `F7 08` | `receiveDeviceRHRMData:` / `transformRHRHistory:` | nhịp tim nghỉ |
| `F7 09`, `F7 0F`, `F7 10`, `F7 11` | phản hồi cài đặt | |
| `E5 11 00 …` | kết quả `E5 11` | |

**Kết luận cho HT43 (suy luận dựa trên mã):** firmware dòng "24h HRM" của UTE không hứa hỗ trợ đo theo lệnh từ app. Y25 vẫn trả lời `E5 11` (đã kiểm chứng), HT43 thì không. Chính app GloryFit iOS cũng **không** gửi `E5 11` hay `D6 01` cho hai máy này. Cách chắc chắn: bật HR 24 h (`F7 01`), đặt chu kỳ ngắn `F7 09 01 00 05` (5 phút, cần kiểm chứng giá trị nhỏ nhất), nghe `F7 03` và `F7 0B`. `live(HEART_RATE)` trên HT43 nên chạy song song `E5 11` (nếu có trả lời) và phát giá trị từ `F7 03`/`F7 0B`. Không tìm thấy lệnh đo HR nào qua kênh `01 xx` (RY) trong SDK.

---

## 3. Mặt đồng hồ (`sendUTEDisplayDataToDevice:process:success:failure:` `0x257500`)

App GF chọn đường RY (`01 E3`, `RYDialMgr uploadWatchFace:`) chỉ khi `isATSDevices`/`is3085sDevices` (`DialDownLoadManager startToSyncWithModel:` `0x100482890`). Realtek (Y25/HT43) đi đường `26/27` như Android.

| Mục | iOS (UTESmartBandApi) | Android của mình (02 §5) |
|---|---|---|
| Mở phiên | `26 02`, đặt timer 3,0 s; không có phản hồi ⇒ lỗi 31 "Device Dial did not receive init data" (`0x1f2514`) | Chờ `26 02` 5 s |
| Độ dài gói `L` | `sendMaxLenght` = 2 byte đầu của `34F1` (244); **không** so với MTU (`0x14e10c`) | `min(maxLen, MTU-3)` |
| Gói | `27 seqHi seqLo` + `L-3` byte (`"%04x"`, `0x1f2e78`) | giống |
| Kiểu ghi | **Không phản hồi**, lên `34F1` (`sendDataToPeripheral:withCharacteristic:response:NO`, `0x1f2fe4`) | Có phản hồi nếu characteristic hỗ trợ |
| Nhịp | NSTimer lặp **0,02 s** (`0x25ba54`, hằng `0.02`); mỗi lần chạy gửi tối đa **10 gói** (`0x1f25a4`). Khoảng 500 gói/s | 1 gói/lần ghi, chờ callback, nghỉ 20 ms mỗi 10 gói |
| Chờ ghi flash | Trước mỗi gói: `(sendDialCount × (L-3)) / 4096` khác lần trước ⇒ timer `fireDate = distantFuture` (dừng) (`0x1f25d4–0x1f26c0`) | Giống phép tính |
| Tiếp tục | `26 03 04` ⇒ `fireDate = distantPast` ("Device received dial send data contunie", `0x17b3ec`). **Không có timeout 5 s** | Hết 5 s vẫn gửi tiếp; 3 khối không có `26 03 04` ⇒ lỗi |
| Mất gói | `26 03 03 HH LL` ⇒ `sendDialCount = HHLL`, dừng, `dispatch_after` **0,6 s** rồi chạy lại (`0x17b01c`, `0x23c34600` ns) | Chậm lại 100 ms/gói |
| Kết thúc | Gói cuối ⇒ dừng timer ⇒ `dispatch_after` **0,5 s** ⇒ `26 03 00` (`0x1f27b0`, `0x1f2a7c`) | Giống (500 ms) |
| Kết quả | `26 03 00` OK, `26 03 01` sai CRC, `26 03 02` quá lớn | Giống |
| Huỷ | `stopUTEDisplayDataToDevice` gửi `26 03 00` | |

Ghi chú: sau khi HT43 đã chạy tốt (02 §5 bước 9), chưa cần đổi. Nếu muốn nhanh như iOS: ghi không phản hồi, chờ `onCharacteristicWrite` (Android vẫn có callback cho write-no-response) hoặc 10 gói/20 ms, bỏ fallback 5 s và chỉ chờ `26 03 04` (giữ timeout lớn, ví dụ 15 s, để không treo).

---

## 4. AGPS (`isHasRYAGPS`, lệnh `01 E9`)

Mọi gói `01 E9` đi qua kênh `34F1` (ghi không phản hồi) / `34F2`. Bộ giải mã: `-[UTEDeviceCommonTool funcDevice01E9:]` (`0x5e018`) và `-[UTERYAGPSReceive funcDeviceAGPS01E9:]` (`0x6643c`).

### 4.1 Bảng lệnh

| Hướng | Gói | Ý nghĩa | Mã |
|---|---|---|---|
| ← Dev | `01 E9 AC 03 01 st` | Đồng hồ báo trạng thái AGPS ⇒ `onNotifyAGPS(st)`. HT43 gửi `st = 02` mỗi 60 s | `0x5e420–0x5e45c` |
| ← Dev | `01 E9 AC 01 xx en` | Đồng hồ xin vị trí GPS điện thoại (msgId `0x1802`, `enable = byte 5`) | `0x5e28c` |
| ← Dev | `01 E9 AB 01 FD` | Đồng hồ đã nhận tham số GPS của app | `0x5e0f0` |
| App → | `01 E9 AA 01` | Hỏi thông tin AGPS | `sendAGPSInfoBlock:` `0x62ed8` |
| ← Dev | `01 E9 AA 01 00` (bắt đầu) … `01 E9 AA 01 <seq> <data>` … `01 E9 AA 01 FD crc` | Trả thông tin, nhiều gói; dữ liệu lấy từ byte 5; `crc` = XOR mọi byte các gói (`crcData:preCrc:`) | `0x5e470–0x5ec40` |
| | Dữ liệu (TLV `tag,len,value`) | tag 1 = `interval` (số nguyên BE); tag 2 = `version` (số nguyên BE, dùng làm `gpsPlatform`); tag 3 = `fileList` ASCII, các tên ngăn bởi `;` | `0x5e8a0–0x5eb48` |
| App → | `01 E9 AB 03 01 st` | Báo trạng thái file. App GF gửi `st = 03` sau khi tải xong ("31.3") | `sendAGPSFileStatus:Block:` `0x631a4`; GF `0x10058588c` |
| ← Dev | `01 E9 AB 03 …` | Xác nhận trạng thái | `0x5e1e4` |
| App → | `01 E9 AB 04 idxHi idxLo <≤ L-6 byte>` | Gói dữ liệu file; `idx` tăng liên tục qua các khối | `sendMultiDataToDevice:…` `0x5b7cc–0x5b818` |
| App → | `01 E9 AB 04 FD FD x` | Chỉ sau **gói cuối** (nghỉ 500 ms); `x` = XOR mọi byte của **mọi** gói `AB 04` đã gửi trong lần truyền, tính cả 6 byte đầu gói (GloryFitPro Android `uterkif/uterkcase.java:225-309`, biến `f4496uterkfor` chỉ đặt lại khi bắt đầu truyền) | `0x5bb9c–0x5bbd8` |
| ← Dev | `01 E9 AC 04 01 st` | `st = 07`: gửi khối 4 KB tiếp; `01`: xong, thành công; `04`: thất bại; `06 HH LL`: mất gói, gửi lại từ `HHLL` | `0x66488–0x66730`, `0x64660–0x647c4` |

`L` = `maxBluetooth5DataLength` (244). Khối = 4096 byte dữ liệu (`0x64a04`). Nếu `L ≤ 20` thì nghỉ 50 ms mỗi gói (`usleep(50000)` `0x5bae8`), ngược lại gửi liên tục.

### 4.2 Nội dung gửi (`sendAGPSFileDataToBLE:block:` `0x63bf0`, `prepareSendData:block:` `0x63520`)

```
payload = u16be(len(desc)) || desc || u32be(len(data)) || data
desc    = Σ_i [ u8(len(name_i)) || ASCII(name_i) || u32be(len(file_i)) ]
data    = file_1 || file_2 || …
```
Tên file lấy từ `fileList` của đồng hồ (hoặc `filename` của server). File đọc từ `Documents/apgsFile/<filename>`.

### 4.3 Server

`POST https://www.ute-tech.com.cn/ci-yc/index.php/api/client/getAgpsFile`, form `content=<JSON>` (`-[ServerDataTool getAGPSFileBlock:failure:]` `0x100567018`; SDK có bản tương tự `getUTEServerAGPSFile:` `0x654e4`):

```json
{"appkey":"dcd05f241b65ec7b6af0bbe6f05145c2","btname":"RH370L73ACC","package":"com.ute.weather",
 "country":"VN","constellation":"1,5","gpsPlatform":"<version từ tag 2>"}
```
`btname` = chuỗi firmware cắt trước `V` (hoặc `bleProductName`). `constellation` = `"6"` nếu mã quốc gia chứa `CN`, ngược lại `"1,5"`.
Phản hồi (khớp `AgpsFileResult` của GloryFitPro Android): `{flag, msg, defaultConstellation, defaultType, datas:[{id, filename, url, constellation, timestamp, type}]}`. App tải từng `url` (`downUrl:name:` / `downLoadAGPS:fileName:`). Lần này **chưa gọi** API AGPS (ngoài phạm vi cho phép).

### 4.4 Luồng của app GF (block `onNotifyAGPS` `0x100584e78`)

| `st` | App làm |
|---|---|
| 2 | `getAGPSFile`: gọi server, tải file, rồi `01 E9 AB 03 01 03` |
| 1 | Nếu đã có `agpsFileNameArray` và file trong `apgsFile/` ⇒ `sendAGPSFileDataToBLE` (gói `AB 04`). Nếu chưa ⇒ `01 E9 AA 01` để lấy `fileList`/`version`, lưu lại, rồi gọi server |

**(suy luận)** Vòng đầy đủ: đồng hồ `AC 03 01 02` ⇒ app (`AA 01` nếu chưa biết `version`), tải ⇒ `AB 03 01 03` ⇒ đồng hồ `AC 03 01 01` ⇒ app gửi file ⇒ `AC 04 01 01`.

### 4.5 Đối chiếu GloryFitPro Android và cài trong SDK (21/10/2026)

GloryFitPro 1.9.0.2 (`uterkif/uterkcase.java`, router `uterkdo/uterkbyte.java:466-471`) khớp bảng trên và bổ sung:
- Vị trí `01 E9 AB 02 0C ts(4) lat(4) lon(4)`: giây Unix, toạ độ × 10⁷, big-endian (`:361-367`); đồng hồ xác nhận `01 E9 AB 02`.
- Trạng thái file `AB 03 01 st` theo `EphemerisStatus`: 1 chuẩn bị, 2 đang gửi, 3 đã có file, 4 lỗi, 5 không hỗ trợ. Khi đồng hồ hỏi
  (`AC 03 01 02`) app trả 3 nếu đủ file, ngược lại 1 rồi hỏi `AA 01` và tải (`ServicePresenter.responseEphemerisRequired`).
- `AC 04 01 st`: 1 xong, 3 huỷ, 4 sai CRC, 5 file quá lớn, 6 gửi lại từ gói `HHLL` (byte 6–7), 7 gửi tiếp khối sau.
- Còn dữ liệu hợp lệ: `56 FD` (33F1) → `56 FD st`, st 1 = hợp lệ (`:75-78`, `:210-217`).
- Tên file trong mô tả bỏ phần mở rộng (`:318-322`).

SDK (`UteAgps.kt` / `UteAgps.swift`, interface `AgpsSupport`) cài toàn bộ phần Bluetooth, **không gọi server**: app tự lấy file dữ liệu vệ tinh
từ nguồn được phép. Chưa có file thì SDK gửi vị trí điện thoại (nếu app đã đưa) và trả `AB 03 01 05` (không hỗ trợ, để đồng hồ thôi hỏi;
**chưa kiểm trên máy**, đổi bằng `GloryFitDebug.agpsNoFileStatus`).

---

## 5. OTA / firmware

### 5.1 Cách SDK iOS hỏi firmware (`checkFirmwareVersionFromServer` `0x26b380`, `+[VVCardBLETool getCheckTestFirmwarePostString:…]` `0x734c8`)

| Mục | Giá trị |
|---|---|
| URL (Realtek, `isRKDevices`) | `https://ute-tech.com.cn/ci-yc/index.php/api/client/getBtVersionUpdate` (không `www`). Bản sao: `https://apsouth.uteasy.com/ci-yc/…/getBtVersionUpdate` (dùng cho bundle `com.techlife.wear`, `ute.realme.com`) |
| URL (FRQ) | `https://www.ute-tech.com.cn/ci-yc/index.php/api/client/getAllBtVersionUpdate` (endpoint mới) |
| Khác | `getPatchlicationUpdate` (bản vá Realtek), `getBtUIVersionUpdate` |
| Body | `content=` + JSON mã hoá RSA (`encryptStr:lenght:rsa:`), `+` ⇒ `%2B` |
| Trường JSON (`UTEInnerGetVersionModel`) | `appkey, btname, versionname ("V%06ld", có thể kèm "_Uxxxx"), versioncode, mac, language (1/2/3), isocode, debug, platform (1; 2 nếu tên bắt đầu "AT"), datas {m3versionname, dspversionname}` |
| `debug` | **−1** khi `firmwareTest = YES`. App GF bật cờ này |
| App key | `getUTEAppKey` (`0x26b29c`): mặc định `iOSNullAppkey`; thẻ ⇒ `06808eae07f1f57ddd9bfeea465b42a6`; Realtek ⇒ `4f819c88e2e8166d8df2a6481898450f`; nếu app gọi `setUTESDKKey:` thì dùng key đó (GF: `dcd05f24…`). `getPatchlicationUpdate` dùng thêm `f0b520cdb42c7103f6683977793ae81c`. `e2b9c738cc9d846aef90639e0e4e9562` có trong bảng chuỗi, không thấy dùng |
| Key khác trong app GF | `12b0cb43454d2cd2f8c0562de71d7157` (gọi `getWatchs` cho `RB08G2C`), `53c101af3f0c6d250fcd7b8c9af51e02` (`ci3/api/btproduct/get_list`, bảng tên BLE ↔ dự án), `126a459c…` (`ci3/user/bindble`, không phải key ci-yc) |

### 5.2 Kết quả hỏi server (15/10/2026, dạng thường `content={json}`, 1 yêu cầu/1,1 s)

| appkey | btname | versionname | debug | Kết quả |
|---|---|---|---|---|
| `4f819c88…`, `06808eae…`, `f0b520cd…`, `e2b9c738…`, `12b0cb43…`, `53c101af…` | `RH370L73ACC` | `V000001` | – | `flag -1` "no new version" (cả 6) |
| như trên | `RB370L73AC` | `V000001` | – | `flag -1` (cả 6) |
| `dcd05f24…` | `RH370L73ACC` | `V000001` | −1 | `flag -1` |
| `4f819c88…` | `RH370L73ACC` | `V000001` | −1 | `flag -1` |
| `dcd05f24…` | `RB370L73AC` | `V000001` | −1 | `flag 1`, `V001205` (2026-09-16), cùng file `1789544413_1645.bin` đã có |

Nhật ký: `research/firmware/api-queries-2026-10-15-ios.jsonl`. **Không có firmware HT43**, không tải gì.

---

## 6. Ghi chú khác

| Mục | Nội dung |
|---|---|
| Bind | Giống Android: `D5 01/02` (mật khẩu), `33 01..05` (account ID). HT43/Y25 không cần |
| ANCS | Có `uteManagerANCSAuthorization:`, `checkSytemShareANCS:show:`, tuỳ chọn `RequiresANCS`. Trên iOS đồng hồ ghép đôi với hệ thống để đọc thông báo ANCS ⇒ hệ thống giữ kết nối (lý do của §1.3) |
| Bảng model | Không có bảng nào nhắc Y25/HT43/RB370/RH370 trong IPA. Có danh sách tiền tố `RH355L73E…`, `RH306L73I…` cho dự án "YM" (`checkISYMDeviceWithVersionName:`). Tên BLE ↔ dự án lấy từ server `ci3/index.php/api/btproduct/get_list` (key `53c101af…`, trường `localname`, `btname`) |
| Firmware chặn | `RB303JDV003810` bị app từ chối kết nối ("请下载新的app") |
| Opcode nhận mới (so với 01-protocol) | `33F3` data status, `F7 0B` HR đo tay, `F7 05/07/08` nhịp tim nghỉ, `01 E3/E4` (RY watch face, ACTS), `01 A5` prepare info, `01 C8`, `01 FC/FD/FE` (OTA/dial RY) |

---

## 7. Đề xuất sửa cụ thể

1. **Android `GattConnection.connect`:** thêm tham số `autoConnect`; `GloryFitDriver` dùng `true` khi nối lại thiết bị đã lưu (bỏ timeout 40 s, chỉ huỷ khi người dùng ngắt). Giữ `false` lúc ghép lần đầu.
2. **`Ute.ADVERTISED` (Android + iOS):** thêm `0x5554, 0x4544, 0x4231, 0x424C, 0x4F4F, 0x3455`. iOS `systemServices = [55FF, 55F0]`.
3. **HT43 HR:** khi có `isHas24HourHRM` (33F1 byte 15 bit 6) và không có 34F1 byte 8 bit 7 ⇒ không dựa vào `E5 11`. Bật `F7 01`, đặt `F7 09 01 00 05` (chưa kiểm chứng giá trị nhỏ nhất), nghe `F7 03` và **`F7 0B`**. `live(HEART_RATE)` báo cả hai nguồn.
4. **`A3`:** thêm byte múi giờ (giờ lệch GMT, có dấu), như iOS.
5. **AGPS:** cài §4 (tối thiểu: `AA 01` ⇒ server ⇒ `AB 03 01 03` ⇒ chờ `AC 03 01 01` ⇒ gửi `AB 04`). Cần kiểm chứng trên HT43 và cần đồng ý trước khi gọi API `getAgpsFile`.
6. **Mặt đồng hồ (tuỳ chọn):** ghi không phản hồi, 10 gói/20 ms; `26 03 03` ⇒ chờ 600 ms rồi gửi lại từ chỉ số.

---

## 8. Đã áp dụng (15/10/2026, chỉ code + unit test, chưa chạy trên đồng hồ)

| # | Việc | Android | iOS | Ghi chú |
|---|---|---|---|---|
| 1 | Nhịp tim đồng hồ HR 24h | `Ute.Features.heartRateByPush` = `heartRate24h` (33F1 b15.6) và không `heartRateTimedMeasurement` (34F1 b8.7). Lúc kết nối gửi `F7 01` + `F7 09 01 00 05`. `measure(HEART_RATE)`: có giá trị đẩy (`F7 03`/`F7 0B`/`E5 … rr`) nhận trong 10 phút ⇒ trả ngay; không thì `MEASURING` kèm ghi chú "Đồng hồ tự đo theo chu kỳ — đo trên đồng hồ để có kết quả ngay", chờ tối đa 6 phút | Giống Android | Vẫn gửi thử `D6 01` + `E5 11` trong lúc chờ vì Y25 đã trả lời lệnh này (doc 01 §10); `E5 00` chỉ gửi khi đồng hồ có trả lời `E5`. Đồng hồ không có cờ ⇒ đường cũ `D6 01`/`E5 11`. 5 phút là chu kỳ nhỏ nhất trong bảng của SDK iOS (§2.2) |
| 1b | `F7 0B` | `Ute.parsePushedHeartRate` nhận cả `F7 03` và `F7 0B` | như Android | Thêm `E5 AA` (`Ute.HR_STATUS` / `hrStatus`, `heartRateMeasuring()`) |
| 2 | `A3` + múi giờ | `Ute.setTime(t, tzHours)` dựng được 9 byte; **mặc định vẫn 8 byte**, bật bằng `GloryFitDebug.timeZoneByte` | như Android | Chưa có bằng chứng firmware Y25/HT43 nhận dạng 9 byte (mới chỉ thấy SDK iOS gửi, 8 byte đã kiểm chứng có phản hồi) |
| 3 | UUID quảng bá | `Ute.ADVERTISED` thêm 6 UUID (13 tất cả) | `Ute.advertised` như Android; `systemServices = [55FF, 55F0]` | |
| 4 | Nối lại bằng `autoConnect` | `GattConnection.connect(autoConnect = true)`: không timeout lúc chờ nối (timeout 40 s chỉ cho bước khám phá service). `WearableDevice.reconnect()` (mặc định = `connect()`), GloryFit dùng `autoConnect = true`. `DeviceManager`: nối lại khi mất kết nối và `reconnectSaved()` dùng `reconnect()`; lần bấm nối đầu dùng `connect()`, lỗi thì các lần sau chuyển sang `reconnect()`. Ngắt / xoá huỷ vòng lặp ⇒ `gatt.disconnect()` + `close()` | – | `DeviceManager.measure` nâng giới hạn từ 150 s lên 400 s cho phép đo chờ `F7 03` |
| 5 | `EnableTransportBridging` | – | `BleCentral.connect` thêm `CBConnectPeripheralOptionEnableTransportBridgingKey = true` (chỉ iOS, macOS không có khoá này) | |
| 6 | `26 03 03 HH LL` | Không đổi (đã tinh chỉnh trên HT43) | Chờ 600 ms rồi gửi lại từ HHLL, bỏ “chậm lại 100 ms/gói”. Giữ dừng khi `26 03 01/02` và lần gửi lại chậm khi bị huỷ | |

Cần kiểm chứng trên đồng hồ: HT43 có gửi `F7 03` mỗi 5 phút sau `F7 09 01 00 05` không (và phản hồi của `F7 01`/`F7 09`); `F7 0B` khi đo trên HT43; Y25 vẫn trả `E5 11` khi đã bật HR 24h; `A3` 9 byte (bật `timeZoneByte`) có phản hồi và giờ đúng; `autoConnect` nối lại Y25 quảng bá thưa và huỷ đúng khi ngắt / tắt Bluetooth; mặt đồng hồ iOS khi đồng hồ yêu cầu gửi lại.
