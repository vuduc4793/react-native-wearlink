# 01 — Giao thức BLE Veepoo (G Band / VPG Band) cho vòng tay PALREDIL GE54

> Ngày: 19/10/2026. **Chỉ đọc mã + viết tài liệu.** Chưa kết nối GE54. Tên quảng bá của GE54 chưa biết.
> Nguồn: APK G Band 2.3.12 (`com.vpgband.app`, versionCode 374, minSdk 26), decompile bằng jadx, và IPA VPG Band 1.5.4 (`HFit.app`).
> SDK giao thức là **Veepoo** (`com.veepoo.protocol`). Phần lớn lớp bị obfuscate, nhưng jadx giữ lại chú thích `compiled from: X.java`, nên vẫn biết tên gốc của từng lớp (bảng §1.2).
> Phần không đọc thẳng từ mã được đánh dấu **(suy luận)**.

**Viết tắt đường dẫn**

| Viết tắt | Đường dẫn |
|---|---|
| `S/` | `sdks/veepoo/research/android-gplusband-2.3.12/jadx-out/sources/` |
| `R/` | `sdks/veepoo/research/android-gplusband-2.3.12/jadx-out/resources/` |
| `VOM` | `S/com/veepoo/protocol/VPOperateManager.java` (API công khai của SDK, 5701 dòng) |
| `VBC` | `S/com/veepoo/device/VPBleCenter.java` (lớp bọc Kotlin của app, 5764 dòng) |
| `P` | `S/mf/a.java` (VPProfile: UUID + các lệnh dựng sẵn) |
| `PU` | `S/mf/b.java` (VPProfileUtil: bảng opcode → tên thao tác) |
| `SP` | `S/com/veepoo/protocol/shareprence/VpSpGetUtil.java` (các cờ `isSupportXxx`) |

Tài liệu tính năng app và kế hoạch triển khai: `02-features.md`.

---

## 0. Tóm tắt nhanh

| Hạng mục | Giá trị |
|---|---|
| Nhận diện khi quét | **Android G Band**: AD **Manufacturer Specific (0xFF)** bắt đầu **`F8 F8`**, tên không rỗng. **iOS**: quét theo service 16-bit `FFFF`/`FEE7`/`0001`/`180D`. Manufacturer data: `F8 F8` + **MAC LE (6 byte)** + **device number LE16** (§2) |
| Service chính | `F0080001-0451-4000-B000-000000000000` |
| Ghi lệnh | `F0080003-…` (write **có** phản hồi) |
| Nhận | `F0080002-…` (notify) |
| Kênh mặt đồng hồ / file | Service `F0030001-…`: ghi điều khiển vào `F0030002`, khối dữ liệu vào `F0030003` (write không phản hồi), notify trên `F0030002` |
| Frame | `[opcode][tham số…]`, thường 20 byte, có lệnh chỉ 2–4 byte. **Không header, không length, không checksum chung, không mã hóa** |
| Toàn vẹn dữ liệu | CRC-16/MODBUS chỉ có trong một số payload: báo thức, danh bạ, thời tiết, file mặt đồng hồ, khối 5 phút `DF`, CRC buổi tập |
| MTU | App xin `requestMtu(248)` ngay sau khi kết nối. Payload hữu dụng = `min(MTU, 248) − 5` |
| Bonding | Không cần cho kênh dữ liệu. JieLi có thêm bước xác thực RCSP trên `AE00`, nhưng chỉ cần cho mặt đồng hồ và OTA JieLi |
| Bắt tay | connect → MTU 248 → (500 ms) bật notify `F0080002` → **`A1` mật khẩu `"0000"` kèm giờ + múi giờ** → thiết bị tự đẩy `A7`×5 (bảng tính năng), `AD`×1–2 (thông báo), `B8`×1–2 (cài đặt) → `A0` pin → chuỗi đọc cài đặt → đồng bộ lịch sử |
| Họ chip | Byte `cpuType` (gói `A7` số 3, byte 16): 0 = Nordic/Goodix, 1 = **JieLi**, 2 = Actions, 3/4 = **ZK (Bluetrum)**, 5 = Nordic 54L (OTA bằng McuMgr) |

---

## 1. Vendor, SDK, bản đồ lớp

### 1.1 Thành phần chính

| Thành phần | File |
|---|---|
| API công khai (mọi lệnh) | `VOM` |
| Lớp gốc của mọi thao tác; đường ghi BLE | `S/com/veepoo/protocol/e.java` (VPOperateAbstract). Ghi lệnh ở `:217-233`, kênh UI ở `:235-275` |
| Nhận notify, tra tên thao tác | `S/com/veepoo/protocol/r.java:30-80` → `VOM.callBackData` (`VOM:1663`). Các thao tác thường được đưa qua `S/com/veepoo/protocol/g.java:197-484`, lấy handler từ factory `S/com/veepoo/protocol/f.java:50-121` |
| Bảng opcode → tên | `PU:22-63` |
| UUID, lệnh dựng sẵn | `P:140-200` |
| Thao tác từng lệnh | `S/jf/*.java` (khoảng 100 lớp, tên gốc ở §1.2) |
| Cờ tính năng đã lưu | `SP` (đọc), `S/com/veepoo/protocol/shareprence/VpSpSaveUtil.java` (ghi) |
| Lớp BLE nền | `S/com/inuker/bluetooth/library/*` (BluetoothKit đã sửa, có thêm `jieli/`, `bluetrum/`) |
| Luồng app: kết nối, đọc cài đặt, đồng bộ | `VBC`, `S/com/veepoo/home/other/services/VpBluetoothService.java`, `S/com/veepoo/home/other/ble/BleReadManager1*.java` |
| Bảng giải nghĩa từng byte `A7` (màn debug, tiếng Trung) | `S/com/veepoo/home/profile/viewModel/a.java:12` (tên), `:15` (giá trị) |

### 1.2 Lớp `jf/*` → tên gốc (các lớp hay dùng)

| Lớp | Tên gốc | Opcode |
|---|---|---|
| `jf/v1` | PwdComfirmOperater | `A1` |
| `jf/y` | DeviceFunctionOperate | `A7` (thiết bị đẩy) |
| `jf/d2` | SocialMsgOperater | `AD` (bật/tắt từng app), `C2` (nội dung) |
| `jf/t` | CustomOprate | `B8` |
| `jf/f` | BatteryOperater (case 0) / long seat (1) / đổi mật khẩu (2) | `A0` / `E1` / `A1` |
| `jf/s2` | TimeSettingOprate | `A5` |
| `jf/t1` | PersonInfoOperater | `A3` |
| `jf/w0` | LanguageOperate (+ disconnect, reset, clear) | `F4`, `AF`, `FF 55`, `F1 80` |
| `jf/u0` | HeartOperater | `D0` |
| `jf/d` / `jf/c` / `jf/s` | BPOperater / BPFunctionOperater / CuffBpDetectOperate | `90` / `92` / `90 xx 05` |
| `jf/f2` | Spo2hDetectOperate (0) / báo thức cũ (1) | `80` / `AB` |
| `jf/o2` / `jf/n2` | TemptureDetectOperater / TemperatureOprate | `87` / `88` |
| `jf/h`, `u1`, `v0`, `c1`, `g0`, `h0` | BloodGlucose / Pressure / HrvDetect / MetDetect / EmotionDetect / FatigueDetect | `89 01..0A` |
| `jf/l2` | SportOperater | `A8`, `82` (case 1), `AE` (case 2) |
| `jf/q1` / `jf/p1` + `jf/k0` | OriginOperate / Origin3Oprate + FiveMinuteHandler | `D1` / `DF` |
| `jf/c2` + `kf/b`, `kf/c` | SleepOperate + NormalSleepParse, PrecisionSleepParse | `E0` |
| `jf/g2`, `jf/q0` | Spo2hOriginOperate, HRVOriginOperate | `D2`, `D9` |
| `jf/z` | DeviceManualDetectOpt | `DE` |
| `jf/k2`, `jf/j2`, `jf/h2` | SportModelSportOperater, SportModelOriginOprate, SportControlOpt | `D3`/`D5`, `D4`, `DA` |
| `jf/o0`, `jf/y1` | GpsLatLonOperater, SafetyProtectionGNSSSOS | `8F` |
| `jf/e1`, `jf/q2` | MultiAlarmOprate, TextAlarmOprate | `B9` |
| `jf/a0` | DrinkOperate (0) / lật cổ tay (1) / SOS (2) | `D7` / `AA` / `B7` |
| `jf/z1`, `jf/b2`, `jf/a2` | ScreenLight, ScreenLightTime, ScreenStyle | `B1`, `B4`, `C7` |
| `jf/j0`, `jf/l`, `jf/f1` + `jf/u` | FindPhoneOrDevice, Camera, MusicOparate + CustomProtocolDataOprate | `B5`, `B6`, `99` |
| `jf/p`, `jf/u2` + `lf/a`, `jf/x2` | ContactOperater72, WeatherOparate, WorldClockOpt | `72`, `C8`, `BE` |
| `jf/v2`, `jf/r`, `jf/x1`, `jf/e` | WomenOperater, CountDown, Rename, BTOperateBD | `85`, `B2`, `84`, `BD` |
| `jf/t2` + `util/UiUpdateUtil` | UiOprate | `50` + kênh `F0030001` |

### 1.3 Thư viện theo họ chip (OTA / mặt đồng hồ)

| Thư viện | Dùng cho |
|---|---|
| `com.jieli.*` (`jl_rcsp`, `jl_bt_ota`) + `libjl_auth.so`, `libjl_fatfs.so`, `libjl_bmp_convert.so`, `libjl_crc.so` | Chip JieLi: xác thực RCSP, mặt đồng hồ (file trên flash), OTA |
| `com.inuker.bluetooth.library.bluetrum.*` (ABOta) + `libabpartool.so` (nén ảnh "PAR") | Chip ZK568X/569X (Bluetrum): OTA qua `F003/F031/F032`, ảnh mặt đồng hồ dạng PAR |
| `S/p001if/b.java` McuMgrOtaManager (SMP `8D53DC1D-…`) | Nordic thế hệ mới (`cpuType` 5) |
| `com.goodix` / HUITOP (service `A6ED0401-…`) | OTA Goodix kiểu cũ. Bản này có hàm bị R8 cắt thành `throw null` (`S/j8/e.java:55-120`) |
| `vpno/nordicsemi/android/dfu` | Có trong APK nhưng **không dùng**: manifest không khai báo `DfuService`. UUID `1530`/`FE59` chỉ dùng để nhận diện |

---

## 2. Nhận diện thiết bị khi quét (discovery)

### 2.1 Bộ lọc của G Band (bản app người dùng đang dùng)

Luồng: `AddDeviceViewModel` → `VBC.startScanDevice` (`VBC:5125-5200`). App quét **không có ScanFilter**: `new ScanFilter(null,…)` ở `VBC:5162`, scan mode 2 (low latency), report delay 100 ms. Mỗi kết quả đi qua `VBC.handleSearchResult` (`VBC:1393-1418`):

1. Bỏ nếu `getName()` là chuỗi `"NULL"` (`VBC:1394`).
2. **Giữ nếu `VpBleByteUtil.isBeyondVpV2(scanRecord)`** (`S/com/veepoo/protocol/util/VpBleByteUtil.java:386-412`). Hàm này duyệt các AD structure. Nếu có AD **type `0xFF` (Manufacturer Specific Data)** với 2 byte đầu dữ liệu là **`F8 F8`** thì nhận.
3. Màn "Thêm thiết bị" bỏ thêm các thiết bị có **tên rỗng** (`S/com/veepoo/home/device/viewModel/AddDeviceViewModel.java:191`), rồi sắp theo RSSI.

Không lọc theo tên, không lọc theo service UUID, không có danh mục model. Ảnh thiết bị trong app chỉ chọn theo hình màn hình (`S/com/veepoo/home/device/widget/NoPreDeviceView.java:173-193`). App không có ghép đôi bằng mã QR: QR trong app chỉ dùng cho tính năng chia sẻ sức khoẻ gia đình.

`F8 F8` nằm đúng vị trí Company ID (little-endian) ⇒ Company ID = **`0xF8F8`**. Đây không phải ID Bluetooth SIG cấp, Veepoo tự đặt **(suy luận)**. Phần sau `F8 F8` không được app Android đọc. Trên iOS (không thấy MAC), SDK có thể đọc MAC từ đây: xem §2.3.

> Lỗi nhỏ trong mã: vòng lặp dừng khi gặp AD có length = 0 hoặc khi còn ≤ 2 byte. Một AD `0xFF` dài đúng 2 byte ở cuối gói có thể bị bỏ sót. Không ảnh hưởng thực tế.

### 2.2 Các bộ lọc khác có trong SDK (không phải đường G Band dùng)

| Hàm | Luật | Dùng ở đâu |
|---|---|---|
| `VpBleByteUtil.isBeyondVp` (`:356-384`; bản sao `S/com/veepoo/home/other/utils/BaseUtil.java:679-710`) | AD **type `0x03`** (danh sách đầy đủ UUID 16-bit) có UUID đầu tiên là **`0xFFFF`**, **`0x180D`** (Heart Rate), **`0xFEE7`** hoặc **`0x0001`**. So byte thô `FF FF`, `0D 18`, `E7 FE`, `01 00` | API quét cũ của SDK `VOM.startScanDevice` (`VOM:650-670`, `:758-765`), `VOM.isVPDevice` (`VOM:2762-2775`) |
| `isBrandDevice` (`VpBleByteUtil.java:414-441`) | AD `0xFF` bắt đầu bằng **`F9 F9`** = thiết bị "thương hiệu riêng" | `BaseUtil.isShowDevice` = `isBeyondVp && !isBrandDevice` (`BaseUtil.java:747-749`), tức để **ẩn** thiết bị `F9F9` khỏi app Veepoo chung **(suy luận về mục đích)** |
| `BluetoothLESearcher` (`S/com/inuker/bluetooth/library/search/le/BluetoothLESearcher.java:54-57,164`) | Có dựng ScanFilter theo service `FEE7` và `0000ffff-…-00805f9bfffb` | Thư viện BluetoothKit; G Band không dùng đường này |
| Quét lại theo MAC | `VBC.startScanDevice(cb, mac, timeout)` (`VBC:5401-5490`): ScanFilter theo địa chỉ, vẫn qua `isBeyondVpV2` | Kết nối lại thiết bị đã lưu |
| Tìm thiết bị đang ở chế độ DFU | Sau lệnh `A2`, app quét **MAC + 1** (byte cuối cộng 1) (`S/jf/m1.java`) | OTA Nordic/Goodix |

### 2.3 iOS (VPG Band 1.5.4)

**Nguồn và cách phân tích**

- SDK Veepoo iOS (module Swift/ObjC `VeepooBleSDK`, version string `2.2.49.15`) được **link tĩnh** vào binary `HFit`.
- Gốc bundle: `sdks/veepoo/research/ios-vpgband-1.5.4/unzipped/Payload/HFit.app/`.
- Địa chỉ dưới đây là địa chỉ VM trong binary `HFit` (arm64, đã strip symbol, còn metadata ObjC). Phân tích tĩnh bằng `otool`, không chạy binary.

**Quét**

- `-[VPBleCentralManage startScanDevice]` @`0x10104029c` gọi `scanForPeripheralsWithServices:@[FFFF, FEE7, 0001, 180D]`.
- iOS chỉ trả về thiết bị quảng bá **một trong các service 16-bit này**, tức cùng danh sách với `isBeyondVp` của Android. Thực tế thiết bị Veepoo nào chạy được với app iOS thì phải quảng bá `FEE7` (WeChat) hoặc `180D` **(suy luận)**.
- Trước khi quét, `obtainIphoneBles` @`0x10104342c` gọi `retrieveConnectedPeripheralsWithServices:@[F0020001-…]`. Nhờ vậy vẫn thấy đồng hồ đã nối với iPhone (đã bond cho ANCS) dù nó không còn quảng bá.

**Lọc** (`centralManager:didDiscoverPeripheral:…` @`0x101041434`)

- RSSI phải < 0 và ≥ `rrisLimit`.
- Bỏ thiết bị nếu không lấy được `deviceAddress`.
- Chỉ khi bật cờ `manufacturerIDFilter` (mặc định NO) mới bắt buộc `manufacturerID == "f8f8"`.

**MAC và device number từ manufacturer data** (`-[VPPeripheralModel getPeripherAddressWithAdvertisementData:]` @`0x100ff2fc4`)

Yêu cầu manufacturer data ≥ 8 byte.

| Byte | Nội dung |
|---|---|
| 0–1 | `F8 F8` (hoặc `F8 F9`, `F9 F9` …) = `manufacturerID` |
| 2–7 | **MAC, little-endian** (byte 7 là octet đầu của MAC). Với `F8 F9`: MAC ở byte 6–11 |
| 8–9 | **Device number, LE16** (khi độ dài > 9) |

- Lưu ý: trong phản hồi `A1`, device number là **BE16**. Cần kiểm trên GE54 xem hai giá trị có khớp không.
- Nếu không có manufacturer data, SDK dùng MAC đã cache theo `CBPeripheral.identifier` trong NSUserDefaults.

**Kết nối**

- `innerConnectDevice:` @`0x101040bc8` bật NotifyOnConnection/Disconnection/Notification.
- Thêm `CBConnectPeripheralOptionEnableTransportBridgingKey = YES` khi `isAutoConnectBT`, để tự nối BT classic cho cuộc gọi.

### 2.4 Cách tìm GE54 trong một lần quét thô (khuyến nghị)

1. Quét **không filter**, ghi lại toàn bộ scan record (Android: `ScanRecord.getBytes()`; iOS: `CBAdvertisementDataManufacturerDataKey`).
2. Ứng viên mạnh nhất: có AD `0xFF` mà dữ liệu bắt đầu `F8 F8` (Android `getManufacturerSpecificData(0xF8F8)` ≠ null). Đây là đúng luật G Band.
   - Kiểm thêm: byte 2–7 đảo ngược phải bằng MAC thấy trên Android.
   - Byte 8–9 (LE) = device number.
3. Ứng viên phụ: `F8 F9` / `F9 F9` (bản thương hiệu riêng), hoặc danh sách UUID 16-bit chứa `FEE7` / `180D` / `FFFF` / `0001`. Danh sách UUID này cũng là điều kiện để app iOS thấy thiết bị.
4. Xác nhận sau khi kết nối: có service `F0080001-0451-4000-B000-000000000000`. Có thêm `AE00` ⇒ chip JieLi; có `F003` ⇒ ZK/Bluetrum.
5. Sau `A1`: byte 4–5 của phản hồi là **device number** (BE16). Đây là mã model nội bộ Veepoo, dùng khi tra OTA và mặt đồng hồ. Cần ghi lại cho GE54.
6. Nếu không thấy thiết bị: kiểm tra xem điện thoại khác có đang giữ kết nối không (xem memory "BLE device contention").

### 2.5 Ghi chú khác từ IPA

**Framework đi kèm** (`HFit.app/Frameworks/`)

| Framework | Version | Họ chip / dùng cho |
|---|---|---|
| `JLDialUnit` | 1.0 | JieLi (stack RCSP `JL_*` link tĩnh vào binary) |
| `ABParTool` | 1.0 | Bluetrum (ảnh PAR) |
| `GRDFUSDK` | 0.1.0 | Goodix |
| `iOSDFULibrary` | 4.11.1 | Nordic |
| `iOSMcuManagerLibrary` | 1.7.0 | Nordic/Zephyr SMP |

**OTA** (`VPDFUOperation`): `nordicDFUStart…`, `hdDFUStart…` (Goodix), `jl_otaFuncWithFilePath:`, `zk_otaFuncWithFilePath:` (Bluetrum qua `F003/F031/F032`).

**UUID dùng để phát hiện chế độ DFU** (`+[VPBleHelper vphDFUPlatformWithPeripheral:]` @`0x101011efc`)

- Nordic cũ `00001531/1532-1212-EFDE-1523-785FEABCD123`
- Nordic secure `8EC90001/8EC90002-F315-4F60-9FB8-838830DAEA50`
- Goodix `A6ED0402-…`
- JieLi `AE01`
- ZK `F032`

**Ghi lệnh**

- Ghi `F0080003` bằng `writeValue:type:0` (có phản hồi).
- Kênh UI ghi `F0030003` bằng `type:1`.
- Ngay sau khi ghi `A1`, iOS bật notify `F0020002`. Android chỉ bật khi đo ECG/PPG.

**Lệnh chỉ thấy trong iOS (chưa có parser Android tương ứng)**

| Lệnh | Mô tả |
|---|---|
| `BC 01 00…` (20 byte) | `veepooSDKSendPairedWithIphoneCommand` @`0x101028428`. Yêu cầu đồng hồ chủ động ghép đôi/bond với iPhone, để đồng hồ đọc được ANCS |
| `CE 03` | Đọc/đặt kiểu rung (`veepooSDK_read/setMotorVibrationType:`) |

**Trạng thái xác nhận**: các lệnh `A1`, `A5`, `AD`, `BC`, `B5`, `B6`, logic quét và MAC đã được disassemble tay. Các opcode khác trong danh sách selector iOS chỉ là quét giá trị tức thời **(suy luận độ tin cao)**.

---

## 3. GATT

### 3.1 Service và characteristic

UUID ở `P:140-157`. Các UUID kiểu `F00x000y-0451-4000-B000-000000000000` dùng base riêng của Veepoo, không phải base SIG.

| Service | Characteristic | Thuộc tính / dùng cho | Nguồn |
|---|---|---|---|
| `F0080001-…` (chính) | `F0080003-…` | **Ghi lệnh**, write có phản hồi | `e.java:227` |
| | `F0080002-…` | **Notify** mọi phản hồi | `S/com/veepoo/protocol/j.java:24` |
| `F0030001-…` (UI / file lớn) | `F0030002-…` | Ghi gói điều khiển "DOOG" (có phản hồi) + notify trạng thái | `e.java:251`, `VOM:4100-4102` |
| | `F0030003-…` | Ghi khối dữ liệu (không phản hồi) | `e.java:273` |
| `F0020001-…` | `F0020002-…` | Notify dạng sóng ECG/PPG thô, dữ liệu máy đo HA có vòng bít. Chỉ bật khi cần | `VOM:4003, 4154-4160, 4727`; `S/jf/x0.java:77` |
| `0000AE00-…` (JieLi RCSP) | `AE01` ghi / `AE02` notify | Xác thực, mặt đồng hồ, OTA JieLi | `S/df/a.java:10-16`, `VOM:847-867, 2929` |
| `0000F003-…` (ZK/Bluetrum) | `F032` ghi không phản hồi / `F031` notify | OTA Bluetrum | `S/of/d.java:105`, `VOM:4768-4806` |
| `00001530-1212-EFDE-1523-785FEABCD123`, `FE59` | — | Nordic DFU, chỉ để nhận diện chế độ DFU | `VpBleByteUtil.java:447-460` |
| `A6ED0401-D344-460A-8075-B9E8EC90D71B` | `0402` notify, `0403` data, `0404` control | Goodix/HUITOP OTA | `VpBleByteUtil.java:240-286` |
| `8D53DC1D-1DB7-4CD3-868B-8A527460AA84` | `DA2E7828-FBCE-4E01-AE9E-261174997C48` | McuMgr SMP (Nordic 54L) | `S/wg/a.java:10-13` |

BR/EDR (gọi điện, audio): `df/a.java:29-31` có `111E` (HFP), `110B` (A2DP sink), `1101` (SPP).

### 3.2 Framing

- Byte 0 = opcode. Bảng opcode → tên ở `PU:22-63`, tóm tắt ở §6.
- `A1` là trường hợp đặc biệt: tên thao tác chọn theo byte 3 (`0,1,6` → xác nhận mật khẩu, `2,3` → đổi mật khẩu) (`PU:67-86`).
- `e.send()` ghi **nguyên mảng** vào `F0080003` (`e.java:217-233`). Mảng dựng sẵn ngắn (2–4 byte) được gửi đúng độ dài, không đệm tới 20.
- Khi đang OTA JieLi, mọi lệnh trừ `A0`/`A1` bị chặn (`e.java:224-231`).
- **Không checksum chung, không mã hóa.** Không có `javax.crypto`/AES trong `jf/`, `com/veepoo/protocol/`, `mf/`. MD5 chỉ dùng kiểm file OTA (`S/com/veepoo/protocol/util/a.java:295-320`).
- **Phản hồi nhiều gói**, ba kiểu:
  - Chỉ số gói ở **byte cuối [19]**: `A7` = 1..5, `B8` = 0/1, `AD` = nibble cao 0x00/0x10.
  - Bộ đếm `[1..2]` LE gói hiện tại, `[3..4]` LE tổng: `D1`, `D2`, `D9`, `D4`.
  - `[1]` = số gói còn lại, đếm lùi tới 0: `E0`.
- **Payload lớn từ app gửi xuống** (danh bạ, đồng hồ thế giới, thời tiết, nhạc, `B3` mới): TLV được cắt thành từng gói `[op][sub][idx][total]` + 16 byte.
- **CRC-16/MODBUS**: bảng đa thức phản xạ `0xA001`, init `0xFFFF`, `crc = (crc>>8) ^ T[(crc^b)&0xFF]`, không XOR cuối (`S/com/veepoo/protocol/util/a.java:22, 133-142`).

### 3.3 MTU

- `VOM:828-832`: MTU mặc định 23.
- `VOM:843`: `changeMTU(248)` ngay khi kết nối, song song với việc hẹn bật notify sau 500 ms.
- Callback `VOM:897-925`: MTU hiệu dụng = `min(đã thương lượng, 248) − 5`, lưu bằng `saveMTUValue`, giới hạn 20…512.
- Kênh UI dùng khối dữ liệu đúng bằng MTU hiệu dụng (247 → 242 byte).
- Không gọi `requestConnectionPriority`, không đổi PHY.

---

## 4. Kết nối và bắt tay

### 4.1 Trình tự (Android, G Band)

| # | Bước | Nguồn |
|---|---|---|
| 1 | `connectGatt(autoConnect=false, TRANSPORT_LE)`. Timeout kết nối 10 s, discover 5 s, không thử lại | `VOM:5137-5139`; `S/com/inuker/bluetooth/library/connect/BleConnectWorker.java:405` |
| 2 | Discover xong: kiểm `isOadModel` (có `1530`/`FE59`/`A6ED0401` ⇒ đang ở bootloader), `getCPUPlatform` (Goodix nếu có `A6ED0401`, ngoài ra Nordic), có `AE00`+`AE02` ⇒ cờ JieLi | `VOM:836-867` |
| 3 | `requestMtu(248)` | `VOM:843, 2329-2331` |
| 4 | Sau **500 ms**: bật notify `F0080001/F0080002` | `VOM:842`, `j.java:24` |
| 5 | Notify bật được ⇒ gửi **`A1`** (xác nhận mật khẩu). Nếu bật thất bại ⇒ ngắt, lỗi 919 | `VBC:1355-1364` |
| 6 | Phản hồi `A1`. `CHECK_FAIL` ⇒ gửi `AF 00`, lỗi 920. Các trạng thái khác coi là thành công | `VBC:5513-5538` |
| 7 | Ngay sau `A1`, thiết bị **tự đẩy** `A7` (5 gói tính năng), `AD` (1–2 gói hỗ trợ thông báo), `B8` (1–2 gói cài đặt). Không có lệnh đọc `A7`. Listener cho 3 loại này chỉ được gắn trong `confirmDevicePwd` | `VOM:5250-5255`; `g.java:197-276` |
| 8 | Thành công ⇒ `UiUpdateUtil.init` (MTU 247 + notify `F0030002`), lưu thiết bị | `VBC:5528-5537`; `S/com/veepoo/protocol/util/UiUpdateUtil.java:551-565` |
| 9 | Nếu là JieLi: xác thực RCSP (§4.5). Kết quả **không chặn** các bước sau | `VpBluetoothService.java:738-762` |
| 10 | `A0 00` đọc pin | `VpBluetoothService.java:766-769` |
| 11 | Chuỗi đọc/ghi cài đặt `BleReadManager1.g()` (§4.4) | `BleReadManager1.java:233-251` |
| 12 | Đồng bộ lịch sử `BleReadManager1.h()`. Thêm vòng hỏi bước chân `A8`/`D8` mỗi 5 s khi app ở màn chính | `VpBluetoothService.java:357-375` |

Ngắt kết nối: gửi `AF 00`, 500 ms sau mới gọi GATT disconnect (`VOM:2568-2572`).

### 4.2 `A1` xác nhận mật khẩu + đồng bộ giờ

Yêu cầu: 20 byte (`S/jf/v1.java:99-128`, overload 7 tham số `:163-171`).

| Byte | Nội dung |
|---|---|
| 0 | `A1` |
| 1–2 | Mật khẩu: chuỗi **thập phân** → số nguyên, gửi 2 byte LE. SDK từ chối mật khẩu dài hơn 4 ký tự (`VOM:5244, 5267`) |
| 3 | `00` = kiểm tra |
| 4–5 | Năm, **BE** |
| 6–10 | Tháng, ngày, giờ, phút, giây |
| 11 | is24h (0/1) |
| 12 | Android: `01` cố định. iOS: `!showPair` (mặc định showPair = YES ⇒ `00`). Có lẽ `00` = yêu cầu đồng hồ hiện ghép đôi/bond, `01` = không **(suy luận)** |
| 13 | Lệch múi giờ theo **đơn vị 15 phút**, có dấu (`TimeZone.getOffset/1000/60/15`; iOS `secondsFromGMT/900`) |
| 14 | Cờ "hiện xác nhận kết nối trên đồng hồ" (Android chỉ có ở overload 7 tham số; iOS luôn có, mặc định 1, chờ 12 s) |
| 15–19 | `00` |

- G Band **luôn gửi `"0000"` và is24h = false** (`VBC:1320`).
- Giờ được đồng bộ ngay trong `A1` mỗi lần kết nối. Chế độ 24h đặt sau, bằng `B8`.
- Ví dụ 2026-10-19 14:05:30, GMT+7: `A1 00 00 00 07 EA 0A 13 0E 05 1E 00 01 1C 00 00 00 00 00 00`. Byte 14 = 0 khi dùng overload 6 tham số **(suy luận: dựng tay từ code)**.
- Đổi mật khẩu: `A1 lo hi 01 …` (13 byte) (`S/jf/f.java:106-123`).

Phản hồi: cần ≥ 20 byte, nếu ngắn hơn thì trạng thái là UNKNOW (`S/jf/v1.java:28-92`).

| Byte | Ý nghĩa |
|---|---|
| 1–2 | Mật khẩu (bỏ qua) |
| 3 | Trạng thái: 0 CHECK_FAIL, 1 CHECK_SUCCESS, 2 SETTING_FAIL, 3 SETTING_SUCCESS, 4 READ_FAIL, 5 READ_SUCCESS, 6 CHECK_AND_TIME_SUCCESS |
| 4–5 | **Device number** (BE16): mã model Veepoo |
| 6–8 | Phiên bản firmware, in hex `"%02X.%02X.%02X"` |
| 9 | Byte thứ 4 của "test version" (`a.b.c.d`). Dùng khi tra OTA và mặt đồng hồ |
| 10 | Có dữ liệu uống rượu (0/1) |
| 11 | Lật cổ tay sáng màn ban đêm: **0 = có/tắt, 1 = có/bật, 2 = không hỗ trợ** (khác quy ước các byte khác) |
| 12–17 | **MAC, little-endian** (byte 17 là octet đầu). Android không parse. iOS lấy làm `deviceAddress` (`-[VPPeripheralModel setPropertyValueWithPasswordData:]` @`0x100ff2ddc`). Đây là cách lấy MAC thật trên iOS |
| 18 | Tìm điện thoại: 0 không hỗ trợ, 1 bật, 2 tắt |
| 19 | Phát hiện đeo: 0 không hỗ trợ, 1 bật, 2 tắt |

**Hẹn giờ**

- Timeout chờ phản hồi `A1`: 4000 ms, message 10086, gọi `IPwdCheckTimeoutListener` (`VOM:1099-1104, 5110-5116`).
- Nếu bật "xác nhận kết nối": chờ người dùng bấm trên đồng hồ tối đa 12 s (tối thiểu 10 s), message 9876 (`VOM:369, 633, 3948-3954`).

**Kiểm tra bản quyền phía app** (`r.java:47-74`, `S/com/veepoo/protocol/util/n.java:76-110`): khi điện thoại không có mạng mà có cache "update info" từ server hết hạn, SDK tự ngắt kết nối. Device number 2501 được bỏ qua. Đây là logic bản quyền của app, driver của mình **không cần**.

### 4.3 Bảng tính năng `A7` (thiết bị đẩy 5 gói)

- Framing: 20 byte, `[0] = A7`, `[19]` = số gói 1..5.
- Parser: `S/jf/y.java:39-493`. Bảng tên/giá trị gốc (tiếng Trung, khớp parser từng byte): `S/com/veepoo/home/profile/viewModel/a.java:12, :15`.
- Lưu bằng `VpSpSaveUtil.saveDeviceFunctionA7` (`VpSpSaveUtil.java:182-309`).
- Quy ước chung: 0 = không có, khác 0 = có, trừ chỗ ghi riêng.

**Gói 1** (`y.java:55-226`)

| Byte | Trường | Giá trị / tác dụng |
|---|---|---|
| 1 | Huyết áp | 0 không; 1 có (hiệu chuẩn mặc định); 2 tự đánh giá; 3 bơm hơi không ADC; 4 có (đọc qua `DE`); 5 bơm hơi có ADC |
| 2 | Uống rượu | 1 thuật toán cũ, 2 thuật toán ADC mới |
| 3 | Nhắc ngồi lâu | 1 = `E1`; 2 = nhắc sức khoẻ `E7` (loại trừ `E1`) |
| 4 | Loại da | 0 = 1–2 mức; 2 = 4 mức (khi đó `B8` byte 11 mang mức da) |
| 5 | WeChat Sport | 1 có; 2 = JieLi tương thích (liên quan ghép BR/EDR) |
| 6 | Camera | 1 mở trang chụp ảnh; 2 thường trú (iOS HID) |
| 7 | Mệt mỏi | khác 0 = có |
| 8 | Loại SpO2 | 01 không hiệu chuẩn, 02 có hiệu chuẩn, 03 ADC ±, 04 ngưng thở (`86`), 05 KH, 06 SpO2 thật, 07 mô phỏng, 08 nhẫn không công tắc, 09 = 07 (`DE`), E0, FD, FE. Hỗ trợ khi thuộc {1–9, FD, FE, E0} (`y.java:137-168`) |
| 9 | Số gói thông báo tối đa | 0 = 4 gói |
| 10 | Cảnh báo nhịp tim | 1 = có (`AC`) |
| 11 | Cài đặt lật cổ tay | 0 kiểu cũ, 1 có (`AA` đầy đủ), 2 không |
| 12 | Sức khoẻ phụ nữ | 0 không; 1/3 có; 2 chỉ khi ngôn ngữ zh/en |
| 13 | Độ sáng màn | số mức; 1 = có (`B1`) |
| 14 | Cờ lệnh `C3` | (không parse) |
| 15 | Độ chính xác quãng đường | 0 = 1 chữ số thập phân, 1 = 3 chữ số |
| 16 | HA cao cấp (angio) | |
| 17 | Kiểu báo thức | 0 = cũ 3 báo thức (`AB`); 1–4 = `B9` nhiều báo thức (tối đa 20); 5/6/7 = báo thức có chữ; FE = không có báo thức |
| 18 | Nhịp tim | **0 = có**, 1 = không, 2–8 = biến thể cảm biến |

**Gói 2** (`y.java:227-320`)

| Byte | Trường | Giá trị / tác dụng |
|---|---|---|
| 1 | Đếm ngược | 1 = có (`B2`) |
| 2 | **watchDay** | Số ngày dữ liệu đọc được; 0 = 3 ngày |
| 3 | Số gói ghi chú thông báo | `contactMsgLength` |
| 4 | HID | |
| 5 | Chế độ thể thao | Số buổi tập lưu được (`sportModelDay`); khác 0 = có |
| 6 | Số kiểu UI dựng sẵn | `COUNT_SCREEN_STYLE_TYPE` (`C7`) |
| 7 | Nhịp thở | 1 vòng SpO2, 2 ECG |
| 8 | Kiểu HRV | 0 không; 3/4/6/7/8 = cả ngày; 7/8 = đo từ app (`89 07`) |
| 9 | Kiểu thời tiết | 1 công ty, 2 cố định (gói đơn giản), 3 hôm nay + mai, 4 hiện tại, 6 UV, 7 không reverse geocoding |
| 10 | **originProtocolVersion** | 0 = 5 phút `D1`; 3 hoặc 5 = `DF` TLV; 4/5 = layout "sport model" |
| 11 | Cờ "A5 hoàn thiện" | (không parse) |
| 12 | Thời gian sáng màn | 1 = có (`B4`) |
| 13 | **sleepTag** | 0 ngủ cũ; 1 ngủ chính xác; 2 không có ngủ; 3 KH; 4/5 ZK; 6 nhẫn. Khác 0 ⇒ parser chính xác `kf/c` |
| 14 | Cờ xoá dữ liệu | 0 `F2 01` kiểu cũ, 1 `F2 01-04`, 2 reset G-series (không parse) |
| 15 | Kiểu ECG | 0 không … 7 đa đạo trình … 0E |
| 16 | Kiểu thể thao | `MULTSPORTMODEL_TYPE`; hỗ trợ khi thuộc {1,3,4,5,E0–E7,E9–EC}; 4/5/6 = đồng hồ GPS |
| 17 | Tiết kiệm pin | (`03`) |
| 18 | Loại TP | (không parse) |

**Gói 3** (`y.java:321-394`)

| Byte | Trường | Giá trị / tác dụng |
|---|---|---|
| 1 | bigDataTranType | Cách truyền file lớn. Mặt đồng hồ và AGPS cần **= 2** (`UiUpdateUtil.java:567-577`) |
| 2 | Mặt đồng hồ | **Nibble cao = số mặt server, nibble thấp = số mặt tuỳ chỉnh** |
| 4 | Danh bạ | 0 không; 1 có (10); 2 có + SOS (10); 3 có + SOS (20) |
| 6 | Nhạc | `musicType`; 1 = giao thức `99` mới |
| 7 | Nhiệt độ | 1 đo tay; 2 tay + tự động (`88`); 4 da; 5/6 = ZK (lịch sử chỉ qua `DF` tag C3) |
| 8 | Tìm thiết bị từ điện thoại | (`B5 0A/0B`) |
| 9 | AGPS | 1 HuaDa, 2 hãng khác |
| 10–14 | GPS, địa từ, ẩn đặt lại mật khẩu, test mic, gói quảng bá | (không parse) |
| 15 | Đường huyết | 1 có; 2/6 + hiệu chuẩn; 3 chỉ hiệu chuẩn; 4/5/7/8/9 hiệu chuẩn nhiều điểm |
| 16 | **cpuType** | 0 Nordic/Goodix, 1 JieLi AC7013, 2 Actions, 3 ZK568X, 4 ZK569X, 5 Nordic 54L |
| 17 | MET | 2/3 = có |
| 18 | Stress | 2/3 = có |

**Gói 4** (`y.java:395-453`)

| Byte | Trường |
|---|---|
| 1 | Thành phần máu (`8A`) |
| 2 | Thành phần cơ thể (`93 04`) |
| 3 | Đồng hồ thế giới (`BE`) |
| 4 | Cảnh báo nhiệt độ (`AC` loại 2) |
| 5 | Ví (`BB 02`) |
| 6 | Danh thiếp (`BB 02`) |
| 7 | Trò chơi (`BF`) |
| 8 | AI hỏi đáp |
| 9 | AI mặt đồng hồ |
| 10 | Mục tiêu quãng đường/kcal |
| 11 | Mặt đồng hồ video |
| 12 | **Đo tự động: 1 = dùng `B3`, 0 = dùng `B8`** |
| 13 | Điều khiển thể thao `DA` |
| 14 | Album ảnh |
| 15 | 4G |
| 17 | Đánh giá sức khoẻ (bitmask) |
| 18 | Mini checkup (`93 09`) |

**Gói 5** (`y.java:454-489`)

| Byte | Trường |
|---|---|
| 1 | Đẩy chữ/ảnh (`83`) |
| 2 | GSR (`93 0A`) |
| 3 | An toàn / SOS GNSS (`8F 08/09`) |
| 4 | **Kiểu màn: 1 không màn, 2 nhẫn, 3 vuông, 4 tròn** |
| 5–13 | Khí áp kế, loại IC cảm ứng, giao thức sản xuất mới, PTT, trạng thái thể thao, sự kiện nhắc, cảm xúc, (test lọt sáng), đèn sức khoẻ `E9` |

Cờ suy ra: "thiết bị không màn" = số mặt server = 0, số mặt tuỳ chỉnh = 0 **và** số kiểu UI = 0 (`S/com/veepoo/common/ext/DeviceExtKt.java:150-152`). Đối với vòng tay GE54, gói 5 byte 4 cho biết hình màn.

### 4.4 Chuỗi đọc/ghi sau kết nối của G Band

Nguồn: `S/com/veepoo/home/other/ble/BleReadManager1$startDeviceSetting$1.java`. Bỏ qua toàn bộ nếu ECG đa đạo trình (`ecgType == 7`).

| # | Lệnh | Điều kiện |
|---|---|---|
| 1 | `FC 00` thông tin sản xuất (phiên bản TP) | luôn |
| 2 | Ghi `B8` (đơn vị, 24h theo điện thoại, loại da…) dựa trên `B8` vừa nhận | nếu đã nhận `B8` |
| 3 | `50 02 02` / `50 02 01` đọc thông tin mặt tuỳ chỉnh / server | `watchuiServer > 0` |
| 4 | `A3` thông tin người dùng | luôn |
| 5 | `F4` ngôn ngữ | luôn |
| 6 | `C7 02` kiểu màn hiện tại | không có mặt server, hoặc có mặt tuỳ chỉnh |
| 7 | `B8 02` đọc cài đặt | luôn |
| 8 | Báo thức (`B9` có chữ hoặc nhiều báo thức) | theo cờ báo thức |
| 9–12 | `B4`, `AA`, `B1`, `E1 00 00 00 00 00 02` | theo cờ |
| 13 | Cảnh báo nhịp tim `AC` | `isSupportHeartwaring` |
| 14 | `B3 00 01 …` SpO2 ban đêm | có SpO2, không có đo tự động mới |
| 15–21 | Danh bạ `72`, thời tiết `C8`, BT `BD 02`, hiệu chuẩn đường huyết `89 03`, điều khiển thể thao `DA`, đo tự động `B3 02`, phụ nữ `85 05` | theo cờ |
| 22 | Danh sách mặt đồng hồ JieLi | JieLi + đã qua xác thực RCSP |

Timeout mỗi lệnh 5–30 s. Sau đó đồng bộ lịch sử, xem §6.4.

### 4.5 JieLi: xác thực RCSP (chỉ cho mặt đồng hồ/OTA JieLi)

- Kích hoạt: `VpBluetoothService.connectSuccess` → `VBC.startJLDeviceAuth` (`VBC:5069-5074, 5713-5759`).
- Chuẩn bị: bật notify `AE02`, chờ 1 s, MTU 247.
- Các bước, trên `AE01`/`AE02` (`S/com/jieli/jl_rcsp/impl/RcspAuth.java:184-325`):
  1. App gửi `FE DC BA C0 06 00 02 00 01 EF`.
  2. 500 ms sau, app gửi thử thách `00` + 16 byte ngẫu nhiên.
  3. Thiết bị trả `01` + 16 byte.
  4. App so với `getEncryptedAuthData(random)` (native `libjl_auth.so`), khớp thì gửi `02 'p' 'a' 's' 's'`.
  5. Thiết bị gửi thử thách `00` + 16, app trả lời.
  6. Thiết bị gửi `02 pass`.
- Thuật toán mã hoá nằm trong `.so`, không có bản Java.
- Thất bại thì app vẫn chạy tiếp với `setJlAuthPass(false)` (`VpBluetoothService.java:683-693`). Lệnh Veepoo **không cần** bước này.

---

## 5. Bảng `AD` (hỗ trợ thông báo) và `B8` (cài đặt tuỳ chỉnh)

Quy ước byte trạng thái: **0 = không hỗ trợ, 1 = bật, 2 = tắt** (`S/jf/d2.java:84-86`, `S/jf/t.java:58-74`).

### 5.1 `AD`: bật/tắt thông báo theo app

Đọc: `AD 02` (`P:166`). Thiết bị cũng tự đẩy sau `A1`. Parser `S/jf/d2.java:465-557`.

**Gói 0** (`[19]` nibble cao = 0)

| Byte | App |
|---|---|
| 2 | phone |
| 3 | SMS |
| 4 | WeChat |
| 5 | QQ |
| 6 | Sina |
| 7 | Facebook |
| 8 | Twitter |
| 9 | Flickr |
| 10 | LinkedIn |
| 11 | WhatsApp |
| 12 | Line |
| 13 | Instagram |
| 14 | Snapchat |
| 15 | Skype |
| 16 | Gmail |
| 17 | DingTalk |
| 18 | WeCom |
| 19 | other |

**Gói 1** (`[19] = 0x10`)

| Byte | App |
|---|---|
| 2 | TikTok |
| 3 | Telegram |
| 4 | Connected2me |
| 5 | KakaoTalk |
| 6 | ShieldPolice |
| 7 | Messenger |
| 8 | Zalo |
| 9 | Viber |
| 10 | appCustom |
| 11 | VK |
| 12 | Max |
| 13 | OK |
| 14 | VK Messenger |

Ghi: `AD 01` + cùng thứ tự từ byte 2. Gói 2 là `AD 01 <13 byte> 00 00 00 00 10`, chỉ gửi nếu có app nào ở gói 1 được hỗ trợ (`d2.java:440-462`).

### 5.2 `B8`: cài đặt tuỳ chỉnh

Đọc: `B8 02`. Ghi: `S/jf/t.java:83-152`. Phản hồi cùng offset, `[1]` = 2 (đọc) / 1 (ghi), `[19]` = số gói (`:194-419`).

**Gói 0** (`[19] = 00`)

| Byte | Trường |
|---|---|
| 1 | `01` (ghi) |
| 2 | Đơn vị: 1 metric, 2 imperial |
| 3 | Giờ: **1 = 24h, 2 = 12h** |
| 4 | HR tự động (5 phút); ép 0 nếu không hỗ trợ |
| 5 | HA tự động; ép 0 nếu không hỗ trợ |
| 6 | Nhắc hết buổi tập |
| 7 | Đọc kết quả HA/HR bằng giọng nói |
| 8 | Giao diện tìm điện thoại |
| 9 | Bấm giờ |
| 10 | Nhắc SpO2 thấp |
| 11 | Phát hiện đeo / mức da |
| 12 | HRV tự động |
| 13 | Tự trả lời cuộc gọi |
| 14 | Nhắc mất kết nối |
| 15 | SOS |
| 16 | PPG |
| 18 | Điều khiển nhạc |

**Gói 1** (`[19] = 01`, chỉ gửi nếu có ít nhất một trường được hỗ trợ)

| Byte | Trường |
|---|---|
| 2 | Bấm lâu để khoá màn |
| 3 | Tin nhắn làm sáng màn |
| 4 | Nhiệt độ tự động |
| 5 | Đơn vị nhiệt độ: 1 °C, 2 °F |
| 6 | ECG luôn bật |
| 7 | Đo đường huyết |
| 8 | MET |
| 9 | Stress |
| 10 | Đơn vị đường huyết: 1 mmol/L, 2 mg/dL |
| 11 | Thành phần máu |
| 12 | Đơn vị acid uric |
| 13 | Đơn vị mỡ máu |
| 14 | Phát hiện ngã |
| 15 | Xu hướng nhịp tim bất thường |
| 16 | Đơn vị GSR |
| 17 | Âm bật/tắt nguồn |
| 18 | Âm khi đo tay |

Driver nên đọc `B8`, giữ nguyên các byte không đổi, rồi ghi lại: bản sao của mọi byte 0 (không hỗ trợ) phải giữ 0.

---

## 6. Danh mục lệnh

Ký hiệu: **C** = xác nhận từ mã, **S** = suy luận. "→" = app gửi, "←" = thiết bị gửi. Mọi lệnh ghi vào `F0080003`, nhận trên `F0080002`, trừ chỗ ghi riêng.

### 6.0 Bảng opcode (từ `PU:22-63`)

| Op | Tên trong SDK | Nhóm | Op | Tên trong SDK | Nhóm |
|---|---|---|---|---|---|
| `01` | auto_callback (nhạc kiểu cũ ←) | điều khiển | `A0` | read_battery | thiết bị |
| `02` | custom_protocol_setting | khác | `A1` | pwd confirm / modify | bắt tay |
| `03` | battery_lowpower | cài đặt | `A2` | oad_cmd (vào DFU) | OTA |
| `50` | function_big_data_tarn | mặt đồng hồ | `A3` | person_info | cài đặt |
| `70` | rr_interval | lịch sử | `A4` | device_number (không dùng) | — |
| `72` | contact | danh bạ | `A5` | sync_time | cài đặt |
| `80` | spo2h_read | đo | `A7` | device_function | bắt tay |
| `81` | fatigue_read | đo | `A8` | read_current_sport | bước |
| `82` | breath_read | đo | `AA` | night_turn (lật cổ tay) | cài đặt |
| `83` | text_image_push | mặt đồng hồ | `AB` | alarm (cũ) | cài đặt |
| `84` | rename | thiết bị | `AC` | health_alarm_interval | cài đặt |
| `85` | women_mense_setting | cài đặt | `AD` | device_msg (thông báo) | thông báo |
| `86` | spo2h_breath_break_remind | cài đặt | `AE` | find_watch_by_phone (cài đặt) | điều khiển |
| `87` | tempture_detect | đo | `AF` | disconnect_watch | thiết bị |
| `88` | tempture_origal | lịch sử | `B1` | screen_light | cài đặt |
| `89` | blood_glucose + HRV/stress/MET/… | đo | `B2` | count_down | cài đặt |
| `8A` | blood_component | đo | `B3` | all_setting / auto measure | cài đặt |
| `8F` | gps_lat_lon (+ SOS, …) | GPS | `B4` | screen_light_time | cài đặt |
| `90` | bp | đo | `B5` | find_phone_by_watch | điều khiển |
| `91` | bp_model_setting | cài đặt | `B6` | take_photo | điều khiển |
| `92` | function_bp | cài đặt | `B7` | sos | điều khiển |
| `93` | ecg_data_app_detect (+ body, GSR…) | đo | `B8` | custom_setting | cài đặt |
| `94` | fun_model_switch | cài đặt | `B9` | multi_alarm | cài đặt |
| `96` | ecg_data_get_id | lịch sử | `BA` | knock_notify | ← |
| `97` | ecg_data_use_id | lịch sử | `BB` | text_transmission | khác |
| `99` | custom_protocol_data (nhạc mới) | điều khiển | `BD` | bt_operate (BR/EDR) | điều khiển |
| `C1` | phone_message (cuộc gọi) | thông báo | `BE` | world_clock | cài đặt |
| `C2` | send_content_to_watch | thông báo | `D0` | heart_read | đo |
| `C7` | screen_style | mặt đồng hồ | `D1` | read_battery_original (5 phút) | lịch sử |
| `C8` | weather | cài đặt | `D2` | spo2h original | lịch sử |
| `D3` | sport_model_crc | thể thao | `D4` | sport_model_origin | thể thao |
| `D5` | sport_model_openclose | thể thao | `D7` | drink (rượu) | lịch sử |
| `D8` | read_current_sport (sport model) | bước | `D9` | hrv_origin | lịch sử |
| `DA` | sport_model_control | thể thao | `DE` | manual_detect (DE) | lịch sử |
| `DF` | origal_df (5 phút TLV) | lịch sử | `E0` | read_battery_sleep (ngủ) | lịch sử |
| `E1` | long_seat | cài đặt | `E2` | check_wear | cài đặt |
| `E7` | health_remind | cài đặt | `E8` | ai | khác |
| `E9` | health_light | cài đặt | `EB` | ppg_test_status | đo |
| `F1` | head_gsensor (+ `F1 80` xoá dữ liệu) | thiết bị | `F2` | device_debug (tắt máy…) | thiết bị |
| `F4` | change_watch_language | cài đặt | `FC` | read_production_info | thiết bị |

Ghi chú: jadx hiển thị một số hằng như `OtaCommandGenerator.CMD_OTA_INFO` (= `A0`), `CMD_GET_INFO` (= `91`). Đó chỉ là trình decompile thay tên hằng Bluetrum có cùng giá trị. Thực chất vẫn là lệnh Veepoo.

### 6.1 Thiết bị, hệ thống

| Lệnh | Yêu cầu → | Phản hồi ← | Nguồn | |
|---|---|---|---|---|
| Pin | `A0 00` (2 byte) | `[1]` powerModel (1 = đang sạc); `[2]` bat thô; `[3]` state; `[4]` mức 0–4 vạch; `[5]` = 1 ⇒ có phần trăm; `[6]` **%**; `[7]` = 2 ⇒ pin yếu. Nếu `[4]` = 0 thì SDK không điền trường nào | `P:163`; `S/jf/f.java:125-129, 168-199` | C |
| Firmware / model | trong phản hồi `A1` (§4.2) | | `S/jf/v1.java:36-38` | C |
| Thông tin sản xuất | `FC 00` | Chỉ nhận khi đủ 20 byte và `[18]` = 2; phiên bản TP = hex `[9]..[14]` | `S/jf/i0.java:78-151` | C |
| Ngắt kết nối | `AF 00` | — | `P:180` | C |
| Đổi tên | `84 type name` (type 1 = tên BLE, 2 = tên BT classic; UTF-8 1–18 byte; ≤ 8 byte nếu `cpuType` 0) | `[1]` type, `[2]` 1 ok | `S/jf/x1.java:21-106`; `VOM:1506-1531` | C |
| Tắt máy / xoá | `F2 cmd`: 1 xoá dữ liệu + tham số + tắt máy, 2 xoá dữ liệu, 3 xoá tham số, 4 tắt máy | `F2 01 cmd` | `S/jf/x.java:25-51`; `VOM:2953-2968` | C |
| Khôi phục cài đặt gốc | `FF 55 01 73 40` + 0 (20 byte) | không parse | `S/jf/w0.java:305-314` | C |
| Xoá dữ liệu | `F1 80` + 0 | không parse | `S/jf/w0.java:278-284` | C |
| Tiết kiệm pin | đọc `03 02 02`; ghi `03 02 01 state notify turnwrist normallight shockdelay shocktime` | `[2]` op, `[3..9]` các trường | `S/jf/a1.java:39-65` | C (ý nghĩa trường: S) |
| Vào DFU | `A2 00 00 01` (4 byte) | không | `P:167`; `S/jf/f.java:30-34` | C |

G Band dùng cả "Reset" và "Restore factory" trong màn "System" (`S/com/veepoo/home/device/viewModel/OtherSettingViewModel.java:37,56`).

### 6.2 Đo trực tiếp

Packet đo thường có cờ "đang đo" phía SDK: gói đến khi chưa bấm đo sẽ bị bỏ.

| Chỉ số | Bắt đầu / dừng | Phản hồi ← | Cờ | Nguồn |
|---|---|---|---|---|
| **Nhịp tim** | `D0 01` + 0 (20 byte) / `D0 00` | Lặp lại: `[1]` bpm (30–210 hợp lệ; 1/2 = đeo sai); `[5]` khác 0/2/3 = máy bận | `isSupportRate` (A7 gói 1 byte 18 = 0) | `S/jf/u0.java:29-59`; `P:168` (C) |
| **Huyết áp** | `90 01 00` (thường) / `90 01 01` (riêng tư); dừng `90 00 00` / `90 00 01` | `[1]` tâm thu, `[2]` tâm trương (mmHg); `[3]` tiến độ %; `[4]`: 1,2,4,5,255 bận / 254 pin yếu / 253 đang sạc / 252 không đeo; `[5]` = 1 ⇒ tiến độ thật | `isSupportBp` | `S/jf/d.java:114-171`; `P:172-175` (C) |
| Chế độ HA | đặt `91 private high low angio`; đọc `91 02 00 00` | `[1]` kết quả, `[2..3]` mmHg, `[4]` riêng tư, `[5]` op | | `S/jf/i0.java:172-372` (C) |
| Công tắc HA | đọc `92 03 55 01 73 40`; đặt `92 01|02 55 01 73 40` | `[6]` 0 không / 1 bật / khác tắt | | `S/jf/c.java:29-60` (C) |
| **SpO2** | `80 01 02` / `80 02 02` | `[1]` trạng thái chức năng; `[2]` trạng thái máy (0 rảnh, 1 HA, 2 HR, 3 tự động, 4 SpO2, 10 pin yếu, 11 xong, 12 không đeo); **`[3]` SpO2 %**; `[4..5]` hiệu chuẩn | không có cờ | `S/jf/f2.java:126-189`; `P:188-189` (C) |
| Nhịp thở | `82 01` / `82 02` (20 byte) | `[3]` tiến độ, `[4]` lần/phút (S) | `isSupportBreath` | `S/jf/l2.java:34-127` |
| Mệt mỏi (cũ) | `81 01` / `81 02` | `[3]` tiến độ, `[4]` giá trị | fatigueType = 1 | `S/jf/i0.java:232-279` |
| **Nhiệt độ** | `87 01 01` / `87 01 02` (20 byte) | `[4]` tiến độ; `[5..6]` LE ÷10 °C; `[7..8]` LE ÷10 °C (nhiệt độ da/nền) | `isSupportCheckTemptureByApp` | `S/jf/o2.java:18-34` (C) |
| Họ `89` | `89 sub 01` / `89 sub 02` (20 byte). sub: 06 stress, 07 HRV, 08 MET, 09 cảm xúc, 0A mệt mỏi mới | `[2]` = 2 ⇒ đã dừng; `[2]` = 1: `[3]` ack (0 OK, 1/3 bận, 2 pin yếu, 4 không đeo), dữ liệu từ `[4]` (stress: `[4]` tiến độ, `[5]` giá trị; HRV: `[4]` giá trị; MET: `[5]`/10) | theo cờ | `VOM:2095-2121`; `S/jf/u1.java`, `v0.java`, `c1.java`, `g0.java`, `h0.java` (C) |
| Đường huyết | `89 01 01 00|01` / `89 01 02 00|01` | `[3]` trạng thái, `[4]` tiến độ, `[5..6]` LE: 13 bit thấp ÷100 = mmol/L, 3 bit cao = mức rủi ro | A7 gói 3 byte 15 | `S/jf/h.java:89-130` (C) |
| Thành phần máu, cơ thể, ECG, PTT, GSR, TCM | `8A 01 …`, `93 04 …`, `93 01 01 z`, `93 0A 01` … | xem nguồn | A7 gói 4–5 | `S/jf/g.java`, `jf/k.java`, `jf/e0.java`, `jf/p0.java`. Dạng sóng ECG qua `F0020002` |
| Phát hiện đeo | `E2 01` / `E2 00` | `[1]` 1 ok, `[2]` trạng thái | `isSupportCheckWear` | `S/jf/m.java:22-47` |

### 6.3 Đo tự động, cảnh báo

| Tính năng | Lệnh | Nguồn |
|---|---|---|
| HR/HA/HRV/nhiệt độ/… tự động (kiểu cũ) | Byte bật/tắt trong `B8` (§5.2) | `S/jf/t.java` |
| Đo tự động kiểu mới (A7 gói 4 byte 12 = 1) | Đọc `B3 02`. Ghi TLV `A0 05 n 23 00 00 00 A1 21 {D0 proto, D1 loại, D2 bật, D3 step, D4, D5 khung hỗ trợ, D6 chu kỳ phút, D7 khung đang dùng, D8 độ nhạy}`, cắt thành `B3 01 idx` + 17 byte. Loại: 0 mạch, 1 HA, 2 đường huyết, 3 stress, 4 SpO2, 5 nhiệt, 6 Lorenz, 7 HRV, 8 thành phần máu, 9 ngã. Parser đọc `D3`/`D6` theo BE, writer ghi LE: **mâu thuẫn, cần đo thật** | `S/jf/b.java:46-277` |
| SpO2 ban đêm (kiểu cũ) | `B3 00 op sh sm eh em open` | `S/jf/a.java:49-98` |
| Cảnh báo HR cao/thấp | Cũ: `AC hi lo open` (4 byte), đọc `AC 00 00 02`. Mới: `AC b1 b2 open type` (type 0 HR, 1 HA, 2 nhiệt độ cao (LE ×10), 3 SpO2 thấp), đọc `AC 00 00 02 type` | `S/jf/r0.java:56-208` |
| Nhắc ngưng thở | `86 01 sh sm eh em FF remind minO2 def open`; đọc `86 02` | `S/jf/e2.java:25-93` |

### 6.4 Lịch sử: bước, 5 phút, ngủ

Thứ tự đồng bộ của G Band (`BleReadManager1$startSyncOriginData$1.java:99-268`):

1. Ngủ `E0` cho từng ngày 0..watchDay−1.
2. 5 phút `D1`/`DF`.
3. Bước hiện tại `A8`/`D8`.
4. Thể thao `D3` → `D4`.
5. Nhiệt độ `88`.
6. ECG, cơ thể, hiệu chuẩn.
7. `DE`.

App lưu vị trí gói cuối cùng theo ngày để đọc tiếp (`S/com/veepoo/device/utils/OriginDataReader.java:983, 1250-1268`).

**Bước chân hôm nay**

- `A8 00` (2 byte). Phản hồi: **`[1..4]` = bước, uint32 BE**, chỉ hợp lệ khi `[5]` = 0; `FFFFFFFF` = 0. Thiết bị không gửi quãng đường hay kcal. App tự tính từ chiều cao (`S/com/veepoo/protocol/util/SportUtil.java:86-116`). Nguồn: `S/jf/l2.java:74, 149-182` (C).
- Khi `isParseSportModel` (có chế độ thể thao, hoặc originProtocolVersion 4/5): dùng `D8 00`. Phản hồi `[2..5]` bước LE32, `[6..9]` quãng đường m LE32, `[10..13]` kcal ×10 LE32 (`S/jf/i0.java:163, 378-391`; `VOM:3600-3609`) (C).

**Dữ liệu 5 phút, `D1`** (originProtocolVersion ∉ {3,5})

- Yêu cầu 4 byte: `D1 posLo posHi day`. pos bắt đầu từ 1; day 0 = hôm nay (`S/jf/q1.java:153-154`).
- Mỗi gói 20 byte là **một bản ghi 5 phút**. `[1..2]` LE gói hiện tại, `[3..4]` LE tổng. Kết thúc khi hiện tại = tổng, hoặc tổng = 0.

| Byte | Layout thường (`q1.java:216-256`) | Layout "sport model" (`q1.java:171-214`) |
|---|---|---|
| 5 | ngày lệch | `day×32 + giờ` |
| 6–7 | — / `[7]` ngày trong tháng | kcal ×10 BE |
| 8–9 | `[8]` giờ, `[9]` phút | quãng đường m BE |
| 10–11 | **bước BE16** | bước BE16 |
| 12–13 | lượng vận động BE16 | lượng vận động BE16 |
| 14 | **HR bpm** | HR |
| 15–16 | HA cao / thấp | HA cao / thấp |
| 17–19 | — | `[17]` đeo, `[18]` nhiệt, `[19]` phút |

**Dữ liệu 5 phút, `DF`** (originProtocolVersion 3 hoặc 5)

- Yêu cầu 20 byte: `DF posLo posHi day` (`S/jf/p1.java:1199-1206`).
- Mỗi khối là một bản ghi 5 phút, gồm:
  - Gói đầu khối `[3]` = 0: `[4..5]` tổng khối, `[6]` số gói, `[10]` số byte hợp lệ, `[11..12]` **CRC-16/MODBUS**, `[13]` độ dài gói (chỉ khi version 5).
  - Các gói dữ liệu `[3]` = 1..n, payload từ byte 4.
  - Gói kết thúc: `[1] = [2] = FF`.
- Payload là TLV (tag 1 byte, len 1 byte) (`S/jf/p1.java:400-504`; `S/jf/k0.java:73-84`):
  - `B1` giờ:phút
  - `B2` thể thao: bước, vận động, m, kcal ×10, tư thế, đeo (BE16)
  - `B4` HR theo phút ×5
  - `B7` HRV + 50 RR
  - `B8` HA
  - `B9` SpO2 ×5 + ngưng thở…
  - `BE` đường huyết
  - `BF` MET
  - `C1` stress
  - `C2` thành phần máu
  - `C3` nhiệt độ (LE ×10)

**Ngủ, `E0`**

- Yêu cầu 2 byte: `E0 day` (`S/jf/c2.java:56`).
- Gói 20 byte: `[1]` = số gói còn lại (0 = gói cuối), `[2]` số bản ghi, `[3]` ngày, `[4..19]` 16 byte dữ liệu. Ghép phần dữ liệu khi `[1]` = 0 (`VOM:1707-1767`).
- **Parser thường** `kf/b` (A7 gói 2 byte 13 = 0). Mỗi bản ghi 96 byte (`S/kf/b.java:21-158`):

| Byte | Nội dung |
|---|---|
| 1–4 | Giờ ngủ: tháng, ngày, giờ, phút |
| 5–8 | Giờ dậy: tháng, ngày, giờ, phút |
| 9 | Ngủ sâu ×5 phút |
| 10 | Ngủ nông ×5 phút |
| 11 | Chất lượng 1–5 |
| 12–42 | Đường ngủ 248 bit, mỗi bit = 5 phút. Bit 0/1 = nông/sâu **(S)** |
| 43 | Số điểm hợp lệ |
| 45–66 | Các đoạn thức giấc |

- **Parser chính xác** `kf/c` (byte 13 ≠ 0) (`S/kf/c.java:84-409`):
  - Tìm `A1 lenBE16`. Bên trong là TLV: `A2` CRC, `A3` tóm tắt (giờ ngủ/dậy, điểm số, **chất lượng `[15]`**, sâu `[19..20]` LE, nông `[21..22]` LE, tổng `[25..26]` LE, `[35]` accurateType), `A4`/`A7` mất ngủ, **`A5` đường ngủ** (len LE16).
  - `A5`: mỗi từ BE16 có giai đoạn ở bit 15..13. Khi accurateType = 2 thì mỗi điểm là 2 bit, đọc MSB trước.
  - Mã giai đoạn (từ UI): **0 sâu, 1 nông, 2 REM, 3 thức/mất ngủ, 4 thức dậy** (`S/com/veepoo/common/widget/PrecisionSleepView.java:184-251`) (C).
  - Mỗi điểm có lẽ là 1 phút **(S)**: app xuất sang Health Connect 60 s mỗi ký tự.

**Các lịch sử khác**

| Lệnh | Nội dung | Nguồn |
|---|---|---|
| `D2 posLo posHi day` | SpO2 theo phút: `[6]` giờ, `[7]` phút, `[8]` SpO2 %, `[16]` HR, `[18]` nhịp thở… | `S/jf/g2.java:105-150` |
| `D9 posLo posHi day` | HRV: `[8]` giá trị, `[9..18]` 10 RR ×10 ms | `S/jf/q0.java:99-137` |
| `88 01 day posLo posHi` | Nhiệt độ: `[7..10]` M D h m, `[11..12]` LE ×10 °C | `S/jf/n2.java:85-172` |
| `DE 02 ts[LE32] mask[LE32] mask2[LE32]` | Kết quả đo tay đã lưu trên máy (HA, HR, đường huyết, stress, SpO2, nhiệt, MET, HRV, …), TLV `A1 … B0 … C0/C1/C2` | `S/jf/z.java:206-948` |
| `70 day blkLo blkHi` | RR interval thô | `S/jf/w1.java:79-137` |
| `D7` | Bản ghi uống rượu (không phải nhắc uống nước) | `S/jf/a0.java:137-175` |

### 6.5 Thể thao, GPS

| Lệnh | Nội dung | Nguồn |
|---|---|---|
| `D3 01` | CRC LE16 của từng khe buổi tập. App đọc CRC trước, chỉ đọc lại khe có thay đổi | `S/jf/k2.java:51-113` |
| `D4 slot` | Bản ghi buổi tập. Kiểu cổ điển: header 42 byte (giờ bắt đầu/kết thúc, bước, quãng đường, kcal, loại môn) + mỗi phút một gói (HR, bước, kcal, quãng đường). Kiểu GPS (type 4/5/6): TLV `A1`/`A2` có điểm kinh/vĩ độ LE ×1e6 | `S/jf/j2.java:78-614` |
| `D5 op type` | 1 bắt đầu môn (ESportType), 0 dừng, 2 đọc trạng thái | `S/jf/k2.java:31-150` |
| `DA 01 typeLE ctrl` | Điều khiển buổi tập từ app: 1 bắt đầu, 2 tạm dừng, 3 tiếp tục, 4 kết thúc. Thiết bị báo `DA 03` TLV (thời lượng, quãng đường, HR, kcal, pace…) | `S/jf/h2.java:28-208` |
| `8F 01 / 05 / 04` | Gửi vị trí điện thoại (lon/lat ×1e5 LE), GPS hỗ trợ từ app, bật báo vị trí | `S/jf/o0.java:111-231` |
| AGPS | File `.pgl` qua kênh `50`/UI, type `A1` (§6.8) | |

### 6.6 Cài đặt

| Tính năng | Lệnh | Phản hồi / ghi chú | Nguồn |
|---|---|---|---|
| **Giờ** | `A5 yearHi yearLo M D h m s mode` (mode 1 = 12h, 2 = 24h) | `[1]` kết quả. Giờ cũng đã được đặt trong `A1` | `S/jf/s2.java:53-97` |
| **Người dùng** | `A3 cm kg tuổi giới(1 nam/0 nữ) stepHi stepLo sleepHi sleepLo` (mục tiêu bước BE16, mục tiêu ngủ phút BE16) | `[1]` 1 ok | `S/jf/t1.java:47-61` |
| **Ngôn ngữ** | `F4 code code2 00 flag`: 1 zh, 2 en, 3 ja, 4 ko, 5 de, 6 ru, 7 es, 8 it, 9 fr, **10 vi**, 11 pt, 12 zh-TW, 13 th, … 61. code2 = code (zh-TW: code 1, code2 12). flag 0 với zh, 1 với ngôn ngữ khác | `[1]` ok, `[4]` ngôn ngữ hiện tại | `S/jf/w0.java:317-730` |
| **12/24h, đơn vị, °C/°F** | `B8` (§5.2) | | |
| **Nhắc ngồi lâu** | `E1 sh sm eh em ngưỡng open` (7 byte); đọc `E1 00 00 00 00 00 02` | `[1]` 1 ok / 0x10 không hỗ trợ | `S/jf/f.java:49-155`; `P:158` |
| **Nhắc sức khoẻ** (uống nước, đứng dậy…) | `E7 01 type sh sm eh em interval status`; đọc `E7 02 type`. type: 1 ngồi lâu, **2 uống nước**, 3 nhìn xa, 4 thể thao, 5 uống thuốc, 6 đọc sách, 7 ra ngoài, 8 rửa tay | | `S/jf/t0.java:19-141` |
| **Báo thức** cũ | `AB h1 m1 on1 h2 m2 on2 h3 m3 on3 01` (3 báo thức); đọc `AB 00×9 06` | | `S/jf/f2.java:59-228` |
| **Báo thức** nhiều | `B9 op id h m open repeat scene [yrLE M D]` (repeat bit0 = T2 … bit6 = CN); đọc `B9 02 … crcLE` ở `[18..19]` | Mỗi báo thức một gói; CRC-16/MODBUS | `S/jf/e1.java:34-175`; `VOM:1834-1916` |
| Báo thức có chữ | `B9 op total idx` + TLV `A0 02 crc A1 … B1 08 … B2 len utf8` | | `S/jf/q2.java:114-697` |
| **Nâng tay sáng màn** | `AA open sh sm eh em [level]`; dựng sẵn: bật `AA 01 08 00 16 00`, tắt `AA 00 08 00 16 00`, đọc `AA 02 00 00 01 01` | | `S/jf/a0.java:108-240`; `P:160-162` |
| **Độ sáng** | `B1 01 sh sm eh em level other auto`; đọc `B1 02` | `[7]` mức, `[10]` mức tối đa | `S/jf/z1.java:19-60` |
| **Thời gian sáng màn** | `B4 01 giây`; đọc `B4 02` | `[3]` hiện tại, `[4]` khuyến nghị, `[5]` max, `[6]` min | `S/jf/b2.java:19-49` |
| Đếm ngược | `B2 01 id secLE24 mode`; đọc `B2 02` | | `S/jf/r.java:15-90` |
| Đồng hồ thế giới | `BE 01 idx total` + TLV `A0 len A1 01 id A2 01 tz15 A3 n city` | | `S/jf/x2.java:108-419` |
| Sức khoẻ phụ nữ | `85 status yHi yLo M D chu kỳ độ dài …`; đọc `85 05` | | `S/jf/v2.java:86-210` |
| **DND** | **Không có lệnh** DND trong SDK hay app | Có thể dùng khung giờ của `AA`/`B1` thay thế **(S)** | |

### 6.7 Điều khiển, thông báo, dữ liệu

| Tính năng | Lệnh | Nguồn |
|---|---|---|
| **Tìm vòng tay** (rung) | `B5 0A` bắt đầu, `B5 0B` dừng. ← `B5 0A/0B st`: 0 không hỗ trợ, 1 đang tìm, 2 đã thấy, 3 không thấy | `S/jf/j0.java:65-80` |
| Bật/tắt chức năng tìm | `AE 01` / `AE 00`, đọc `AE 02` | `P:177-179` |
| **Vòng tay tìm điện thoại** | ← `B5 00 …` ⇒ app đổ chuông. `B5 02` dừng | `g.java:336-358`; `S/com/veepoo/home/main/ui/MainActivity.java:534-582` |
| **Chụp ảnh từ xa** | `B6 01` vào, `B6 00` thoát. ← `B6 ok mode`: mode 1 mở, **2 chụp**, 0 đóng | `S/jf/l.java:56-69` |
| **Nhạc** (musicType 1) | → `99 01 idx total` + 16 byte TLV `F0 len {A0 album, A1 tên bài, A2 ca sĩ, A3 01 trạng thái phát, A4 01 âm lượng}`. ← `99 02` 1 phát / 2 dừng / 3 bài trước / 4 bài sau; `99 03` 5 tăng / 6 giảm âm lượng | `S/jf/f1.java:20-125`; `S/jf/u.java:44-91` |
| Nhạc kiểu cũ | ← `01 01 01 01` bài sau, `01 01 01 04` bài trước, `01 01 01 02` phát/dừng | `S/p9/a.java:854-897` |
| **Cuộc gọi** | → nội dung qua `C2` (appType 0). Gác máy / rảnh: `C1 00 00 00`. ← `C1 02` từ chối, `C1 03` im lặng, `C1 04` trả lời | `P:165`; `S/p9/a.java:833-852` |
| **Thông báo app** | Bật/tắt theo app: `AD` (§5.1). Nội dung: `C2 appType len total idx kind` + ≤ 14 byte UTF-8 ở `[6..19]` (kind 1 = tên, 0 = số điện thoại, 2 = nội dung). ← `C2 FF result` | `S/jf/d2.java:88-386`; `g.java:428-433` |
| Bảng appType | 0 phone, 1 SMS, 2 WeChat, 3 QQ, 4 Sina, 5 Facebook, 6 Twitter, 7 Flickr, 8 LinkedIn, 9 WhatsApp, 10 Line, 11 Instagram, 12 Snapchat, 13 Skype, 14 Gmail, 15 DingTalk, 16 WeCom, 17 Other, 18 TikTok, 19 Telegram, 20 Connected2me, 21 KakaoTalk, 22 ShieldPolice, 23 Messenger, **24 Zalo**, 25 Viber, 26 AppCustom, 27 VK, 28 Max, 29 OK, 30 VK Messenger | `S/com/veepoo/protocol/model/enums/ESocailMsg.java:7-38` |
| Danh bạ | TLV `A0 lenLE16 A1 01 id A2 n tên(≤ 20 byte) A3 n số(≤ 22 byte) [A4 01 sos]` → `72 01 idx total` + 16 byte; xoá `72 04 id`; đọc `72 02 crcLE` | `S/jf/p.java:84-404` |
| **Thời tiết** | Trạng thái `C8 03 open unit`; đọc `C8 02`. Dữ liệu đầy đủ: `F0 lenLE16` + TLV (A1 crc, A2 thành phố, A4 giờ cập nhật, A5 theo giờ, A6 theo ngày) → `C8 04 total idx` + 16 byte, cách nhau 50 ms. Kiểu đơn giản (weatherType 2): một gói `C8 01 …` | `S/jf/u2.java:103-415`; `S/lf/a.java` |
| BT classic (gọi điện qua đồng hồ) | Đọc `BD 02`; ghi `BD 01 switch audio x`. ← `[3]` 0 ngắt / 1 nối / 2 đang quảng bá | `S/jf/e.java:120-296` |
| SOS | ← `B7 01 01` / `B7 04` ⇒ app gọi SOS; SDK tự trả `B7 04 01` | `VOM:2303-2309` |

**iOS và ANCS**

- Mã Android không có ANCS.
- Trên iOS, app **không đẩy nội dung thông báo**. Đồng hồ tự đọc ANCS của iPhone sau khi bond.
  - Bond được kích hoạt bởi byte "showPair" trong `A1` và lệnh `BC 01`.
  - App không cài `didUpdateANCSAuthorizationForPeripheral` và không dùng `RequiresANCS`.
- Công tắc theo app trên iOS vẫn là `AD 01`:
  - SDK lấy bản `AD` cuối cùng nhận được, đặt `byte[messageType] = 1/2`, rồi gửi lại.
  - messageType ≥ 0x14 đi vào gói 2, với `byte19 = 0x10`.
  - Nguồn: `-[VPPeripheralBaseManage veepooSDKSettingMessageType:settingState:completeBlock:]` @`0x101023110`.

### 6.8 Mặt đồng hồ

**Veepoo gốc** (Nordic, …, `bigDataTranType` = 2)

- Điều khiển bằng opcode `50` trên `F0080003`; dữ liệu đi trên `F0030001` (`S/jf/t2.java`, `UiUpdateUtil.java`).
- Đọc thông tin: `50 02 type` (type 1 server, 2 tuỳ chỉnh, `A1` AGPS, 6 đẩy ảnh).
  - Phản hồi server: địa chỉ LE32, kích thước tối đa LE32, `binDataType`, hình mặt, CRC mặt đang cài.
  - Phản hồi tuỳ chỉnh: `EWatchUIType` (kích thước màn), vị trí giờ, màu.
- Luồng tải lên:
  1. `50 01 type addrLE32 lenLE32 …`
  2. `44 4F 4F 47 05 00` ("DOOG") vào `F0030002`
  3. ← `05` ⇒ xoá vùng nhớ: `DOOG 01 addr len`
  4. ← `01 01/02/03` (tiến độ xoá, xong)
  5. Khối thô (MTU − 5) vào `F0030003`
  6. `DOOG 02`
  7. ← `02` ⇒ `DOOG 03 crc16LE32`
  8. ← `03 crc` ⇒ xong
- File đệm `FF` tới bội số 4. CRC-16/MODBUS.
- Chọn mặt có sẵn: `C7 01 index from` (from 0 mặc định / 1 server / 2 tuỳ chỉnh); đọc `C7 02`.
- Ảnh mặt tuỳ chỉnh: RGB565 BE không nén (ảnh lớn + ảnh nhỏ).
- Chợ mặt đồng hồ: `GET https://www.vphband.com:9001/api/system/getthemes?dialShape=&binProtocol=&maxLength=&deviceNumber=&deviceVersion=…` (`S/com/veepoo/protocol/util/UiServerHttpUtil.java:39-53`).

**JieLi**

- RCSP trên `AE01`/`AE02`. Frame `FE DC BA flags op lenBE16 body EF`.
- File mặt đồng hồ `/WATCH*`, ảnh nền `/BGP_W000` / `/BGP_W001`.
- Cần xác thực RCSP và các thư viện native (`libjl_fatfs`, `libjl_bmp_convert`).
- Nguồn: `S/com/inuker/bluetooth/library/jieli/dial/*`, `S/com/jieli/jl_rcsp/util/CommandBuilder.java:121-195`.

**ZK/Bluetrum**: ảnh nén "PAR" bằng `libabpartool.so` (định dạng chưa biết) (`S/com/veepoo/protocol/customui/WatchUIType.java:687-723`).

### 6.9 OTA

| Chip (`cpuType`) | Đường OTA | Nguồn |
|---|---|---|
| 1 JieLi | Tải zip từ `https://cn.vpgband.com/api/v1/ota/info?mac=&deviceNumber=&deviceVersion=…`, lấy `*.ufw`, OTA bằng RCSP (`E1`/`E2`/`E3`/`E5`/`E6`/`E7`) | `S/com/inuker/bluetooth/library/jieli/ota/JLOTAHolder.java:267-350` |
| 3/4 ZK (Bluetrum) | Ngay trong firmware thường, không cần vào DFU: service `F003`, ghi `F032` / notify `F031`. Lệnh `CC AA 55 EE 12 19 E4`, `91`, `A0`, `20 seq data`, `90 status`; khối 4096, gói 240 | `S/com/inuker/bluetooth/library/bluetrum/manager/OtaCommandGenerator.java`; `VOM:4767-4806` |
| 5 Nordic 54L | McuMgr/SMP (image 0, slot 1, CONFIRM_ONLY) | `S/com/veepoo/protocol/s.java:31-131` |
| 0 Goodix | `A2 00 00 01` → quét MAC + 1 → service `A6ED0401`. Frame `44 47 cmdLE lenLE payload sumLE` | `S/jf/m1.java`; `S/l8/e.java:158-245` |
| 0 Nordic cũ | Có UUID nhưng không có đường OTA nào được nối | |

Yêu cầu pin ≥ 40% (`OtaUpdateViewModel.java:587-598`).

---

## 7. Câu hỏi mở — đã đo trên GE54 (19/10/2026, driver `sdks/veepoo/android`, Redmi Note 7 Pro)

| # | Câu hỏi | Trả lời |
|---|---|---|
| Q1 | Tên, MAC, quảng bá | ✅ Tên `GE54` **+ 2 byte rác** (Android trả `GE54\uFFFD\uFFFD`; driver cắt ở ký tự không in được). MAC `9C:F4:8F:E3:1D:45`, service `FEE7`, mfr `F8 F8` + `45 1D E3 8F F4 9C A1 00 95 01 00 5C 17 53 FF 2F 00 30 10`. RSSI −46 dBm sát Redmi. |
| Q2 | Device number, firmware, cpuType | ✅ `A1` → `A1 00 00 06 17 5C 00 95 01 00 00 01 45 1D E3 8F F4 9C 00 00`: trạng thái 6 (CHECK_AND_TIME_SUCCESS), **device number 5980** (`17 5C` BE), firmware **00.95.01**, test `.00`, lật cổ tay đêm = 1, MAC LE đúng, tìm điện thoại = 0, phát hiện đeo = 0. **cpuType = 1 (JieLi)**, có service `AE00` + `F0030001`, không có `F003`. MTU thương lượng 247. |
| Q3 | D1/DF, ngủ | ✅ originProtocolVersion = **5 ⇒ `DF`** (gói dài 0xCD = 205 byte), sleepTag = **1 ⇒ ngủ chính xác** (accurateType 1, 60 s/điểm). |
| Q4 | Bit đường ngủ thường | Không áp dụng (GE54 dùng ngủ chính xác). Chưa kiểm. |
| Q5 | Thiết bị tự đẩy A7/AD/B8? | ✅ Có, và **trước** phản hồi `A1`: `A7`×5 → `AD`×2 → `B8`×2 → `A1` (~190 ms sau khi ghi `A1`). Không cần lệnh đọc. |
| Q6 | Endianness `B3` | Không áp dụng (A7 gói 4 byte 12 = 0 ⇒ đo tự động qua `B8`). |
| Q7 | Mật khẩu khác "0000"? | ✅ Không: "0000" được chấp nhận. |
| Q8 | Pin khi `[4]` = 0 | Chưa gặp. Trên GE54 **byte 4 không phải số vạch mà là % (0x55 = 85)**, byte 5 = 1, byte 6 = %, byte 1 = **đang sạc** (1 khi cắm sạc, 0 khi rút; vòng tay tự đẩy `A0 00 …` lúc rút sạc). |
| Q9 | iOS bond/ANCS | Chưa thử (không có iPhone). |
| Q10 | Device number quảng bá = A1? | ❌ **Khác**: byte 6–7 payload `A1 00` = 161 (cái SDK iOS gọi là device number), còn device number thật 5980 nằm ở **byte 11–12 LE** (`5C 17`); byte 8–10 `95 01 00` = byte 7–9 của `A1` (firmware + test). Chỉ kiểm trên GE54. |

### 7.1 Bảng tính năng GE54 (thô)

```
A7.1 01 00 02 02 02 01 00 06 14 01 02 00 00 00 01 00 06 03   HA 1, nhắc sức khoẻ E7, da 4 mức, camera 1, SpO2 06, 20 gói tin,
                                                               cảnh báo HR, KHÔNG nâng tay (02), báo thức chữ 06, HR biến thể 03
A7.2 00 03 04 00 03 00 00 03 00 05 01 00 01 02 0B 05 00 01   3 ngày, tên 4 gói, 3 khe thể thao, 0 kiểu UI, HRV 03 (cả ngày),
                                                               KHÔNG thời tiết, origin 5, sleepTag 1, ECG 0B, thể thao 05 (nhẫn ⇒ D4 TLV)
A7.3 02 00 01 00 00 01 05 01 00 00 00 01 00 00 04 01 02 02   bigData 2, 0 mặt đồng hồ, KHÔNG danh bạ, nhạc 1, nhiệt độ 05 (DF),
                                                               tìm vòng tay 1, đường huyết 04, cpuType 1 JieLi, MET 2, stress 2
A7.4 02 01 00 … 01 (byte 13)                                   thành phần máu 2, cơ thể 1, điều khiển thể thao DA
A7.5 00 00 00 01 00 00 01 01 …                                 kiểu màn 01 = KHÔNG MÀN HÌNH
AD   02 01 01 01 01 00 01 01 00 01 01 01 01 01 01 01 00 00 01 / … 01 01 01 01 00 01 00 … 10   Zalo (24) = 0 ⇒ gửi dạng "khác" (17)
B8   02 01 01 01 01 00 00 00 00 02 02 01 00 00 00 01 00 00 00 / 02 00 00 01 01 00 01 00 01 01 01 01 01 00 … 01
```

### 7.2 Sửa / bổ sung so với phần trên (đo thật)

- **Ngủ chính xác `A1`**: độ dài container là **LE16** (`A1 24 03` = 804 byte), không phải BE như jadx (`twoByteToUnsignedInt(b0, b1)`). Từ đường ngủ `A5` vẫn **BE16** (`20 00` = nông, `40 00` = REM, `80 00` = thức dậy, `00 00` = sâu); độ dài `A5` LE16 = số **byte** (696 = 348 điểm × 2). Tổng khớp `A3` (sâu 52 + nông 224 + khác 67 ≈ 348 phút).
- **`DF`**: gói đầu `DF blkLo blkHi 00 totLo totHi nPkt day 00 00 valid crcLo crcHi 0xCD`; gói dữ liệu `DF blk(2) idx` + byte 4..204; kết thúc `DF FF FF tot(2)`. Mã `p1.a()` jadx dịch sai, driver dựng lại theo trường header; CRC-16/MODBUS khớp 100 % (561 bản ghi/3 ngày). `B1` = **tháng, ngày, giờ, phút** (`0A 13 0F 2D`).
- **Nhiệt độ `87`**: trạng thái máy (byte 3) **7 = đang đo bình thường** (như 0; app `viewModel/a0.java:78-117`), không phải lỗi; byte 5–6 LE ÷10 = cơ thể, 7–8 = nền. GE54: `87 01 01 07 00 72 01 69 01` = 37,0 / 36,1 °C.
- **Nhịp tim `D0`** lúc đang sạc: `D0 01 00 00 FD …` (byte 4 = FD). Huyết áp lúc sạc: `90 00 00 00 FD` (253).
- **Bài tập `D4`** (kiểu thể thao 5): `D4 cur(2) tot(2)` + dữ liệu; đầu bài `A1 45 B1 0C start(LE32 epoch s) end duration B2 25 bước m cal(LE32, **cal**) số-lần maxHR avgHR minHR pace…`. GE54 có 3 bài (D3 CRC `C37B C0F4 AC2D`).
- **Camera `B6 01`**: vòng tay trả cả `B6 01 01 01` lẫn `B6 01 01 00` cho chính lệnh của app (không phải người dùng mở trên vòng tay).
- `C2` (thông báo) không có phản hồi `C2 FF` trên GE54; `C1 00 00 00` được trả `C1 00 01`.

- **Hiệu chuẩn HA `91`**: đọc `91 02 00 00` → `91 01 78 57 01 02` = kết quả OK, 120/87, chế độ riêng, thao tác 2 (đọc). **Gói `91` ngắn (vd chỉ `91`) bị vòng tay coi là lệnh ghi "chế độ thường 0/0"** (trả `91 01 00 00 00 00`) — chỉ gửi đúng gói đọc 4 byte / gói ghi 20 byte. (19/10 xảy ra một lần do lỗi quoting adb; đã ghi lại `91 01 78 57 00` và đọc lại khớp.)
- **Hiệu chuẩn đường huyết nhiều điểm `89 03`** (glucose type 4): đọc `89 03 02 01 01` → `89 03 02 01 01 02 | 01 | 0F 00 8A 02 0F 01 EE 02 | …` + gói 2 (`89 03 02 01 02 02` + 11 byte) = bật; bữa sáng 15:00 6,50 / 15:01 7,50; trưa, tối 0. Mỗi bữa 8 byte: giờ, phút, LE16 ×100 trước ăn, giờ, phút, LE16 sau ăn.
- **Hiệu chuẩn thành phần máu `8A 02`**: đọc `8A 02 02` → `8A 02 02 01 01 84 03 DC 05 B0 04 E8 03 DC 05` = OK, bật, uric 90,0 μmol/L, TC 15,00, TG 12,00, HDL 10,00, LDL 15,00 mmol/L (thứ tự uric, TC, TG, HDL, LDL; LE16 ÷10 / ÷100).
- **Đo thành phần máu `8A 01 01 01`** (riêng): ~1 gói/s `8A 01 01 00 tiến-độ uric TC TG HDL LDL`, xong ở tiến độ 0x64: `8A 01 01 00 64 CE 05 16 06 CA 04 EB 03 49 06` = 148,6 μmol/L; 15,58 / 12,26 / 10,03 / 16,09 mmol/L — **bám giá trị hiệu chuẩn đang lưu** (15/12/10/15), không phải số đo thật. Dừng `8A 01 02 00` → `8A 01 02 00`.
- **Đo thành phần máu `8A 01 01 00`** (thường, mặc định G Band; 19/10 21:26): echo `8A 01 01 00 00…`, rồi ~1 gói/s tiến độ +6 (06, 06, 0C … 60, 64), mỗi gói mang ước lượng đang chạy; gói 0x64 = kết quả: `8A 01 01 00 64 69 08 AB 01 66 00 68 00 0C 01 00 00 00 00 00` = uric 215,3 μmol/L; TC 4,27 / TG 1,02 / HDL 1,04 / LDL 2,68 mmol/L (~18 s, vector `android/src/test/resources/ge54/8a_blood_general.txt`). Byte 15–19 luôn 0.
  - Trạng thái byte 3 (`EBloodComponentDetectState`, `com/veepoo/protocol/model/enums/EBloodComponentDetectState.java:16-21`): 0 bình thường, 1 đang đo việc khác, 2 pin yếu, 3 bận, 4 "佩戴未通过" (đeo/tiếp xúc không đạt), khác = không rõ. Xử lý `jf/g.java:125-176`: 0 ⇒ `onDetecting(tiến-độ, giá trị)`, tiến độ 100 ⇒ `onDetectComplete`; 1–4 ⇒ `onDetectFailed`.
  - **Không có cờ "có ngón tay" hay "đo thật / ước lượng"** trong gói `8A`. G Band (`home/home/ui/BloodComponentDetectFragment.java:96-139`, `viewModel/h.java:22-55`) chỉ hiện "Wait a moment" → "xx%", không có lời nhắc chạm và không có timeout riêng; lỗi: pin yếu ⇒ "Low Battery", 1/3 ⇒ "Device is busy", còn lại ⇒ "Measurement Invalid". Chế độ riêng là ô người dùng chọn (mặc định thường, `onResume` :541-555) và chỉ cho bật khi đã nhập hiệu chuẩn.
  - Driver (19/10): luôn gửi `8A 01 01 00`; mỗi gói tiến độ < 100 ⇒ `MEASURING`, `note = "TOUCH_SENSOR"`, `extra.progress`; 100 + giá trị ≠ 0 ⇒ `OK`; 100 toàn 0 ⇒ `ERROR` (TOUCH_SENSOR); 4 ⇒ `NOT_WORN` (TOUCH_SENSOR).
- **Thành phần cơ thể — tín hiệu chạm điện cực**: trong gói tiến độ `93 04 01 00 tiến-độ X`, X = 1 ⇒ chưa chạm điện cực (`jf/k.java:70-77` → `onDetecting(progress, X)`); G Band đếm 4 gói liền X = 1 thì dừng và hiện "Ensure your finger is on the electrode" (`home/home/viewModel/x.java:68-85`, `home/home/ui/p.java:544-560`). Driver: X = 1 ⇒ `MEASURING` + `TOUCH_SENSOR`; 4 gói liền ⇒ `NOT_WORN` + `TOUCH_SENSOR`.
- **Đường huyết `89 01`** không có cờ chạm (trạng thái 0–4, `jf/h.java:87-130`); G Band không nhắc chạm.
- **Đo đường huyết `89 01 01 01`** (4 byte, riêng): `89 01 01 00 tiến-độ giá-trị(LE16)`; xong `89 01 01 00 64 35 03` = 8,21 mmol/L (~18 s).
- **Thành phần cơ thể `93 04 01`**: tiến độ `93 04 01 00 xx 01` 0→0x64 trong ~30 s, rồi `93 04 01 02 64 01` = thất bại không kết quả (2/2 lần, người đang đeo). Chưa thấy gói kết quả trạng thái 1.
- **MET `89 08 01`**: không có trả lời (MET type = 2 ⇒ chỉ lịch sử `DF` tag `BF`).
- **`DF` tag `C2`** (10 byte, thành phần máu): TC, TG, HDL, LDL (÷100), uric (÷10), LE16 — thứ tự KHÁC gói đo `8A`. Sync 1 ngày 19/10: 11 bản ghi có `C2`, 19 có `BF`.
- **Nhắc sức khoẻ `E7`** loại 3–8 trả đủ: `E7 02 01 03 09 00 12 00 1E 01` (nhìn xa 09–18, 30′, bật), loại 4 120′, 5 120′, 6/7/8 60′. Ghi `E7 01 03 … 2D 01` (45′) → đọc lại 45 → khôi phục 30.
- **Báo thức có chữ `B9`**: đọc `B9 03 00 00 A0 02 00 00` → `B9 03 01 01 A0 03 01 31 3C A1 0C B1 08 01 00 00 0D 2C 30 00 00 B2 00` (một báo thức id 1, 13:44, tắt, không lặp, ngày thô `30 00 00`, nhãn rỗng; CRC-16/MODBUS của TLV `A1…` = 0x3C31). Thêm `B9 02 01 01 A0 02 01 51` + `A1 12 B1 08 02 01 1F 07 1E 00 00 00 B2 06 "SWTest"` → `B9 02 01 01 A0 03 01 01 51` (OK, CRC = CRC app gửi). Đọc lại: vòng tay đặt báo thức mới **lên đầu** nhưng giữ CRC app gửi (tính theo thứ tự id) ⇒ sắp theo id trước khi kiểm CRC. Xoá `B9 01 01 01 A0 02 31 3C` + TLV id 2 → `B9 01 01 01 A0 03 01 31 3C`; đọc lại trùng từng byte với ban đầu.
- **`A3`** `A3 AA 41 1E 01 1F 40 01 E0` (170 cm, 65 kg, 30 tuổi, nam, 8000 bước, 480 phút) → `A3 01`.
- **Sạc**: vòng tự đẩy `A0` khi cắm/rút; byte 1 = 1 khi cắm (driver đưa ra `WearableDevice.charging`).
- **Mã môn `D4`/`DA`** = `ESportType` của SDK: 1 chạy ngoài trời, 2 đi bộ ngoài trời, 3 chạy trong nhà, 4 đi bộ trong nhà, 5 HIKE, … 11 leo núi, 12 bơi, 15 nhảy dây, 16 yoga (bảng tên Android trước 19/10 lệch).

### 7.3 Đã kiểm / chưa kiểm trên GE54

Đã kiểm (giá trị thật): bắt tay, pin 85–86 %, firmware, SpO2 99 % (`80 01 00 63 00 64`), HA 119/86 (`90 77 56 64`), stress 21, nhiệt độ 37,0 °C,
nhịp tim 75–77 (đo bởi điều phối viên), lịch sử DF 3 ngày (564 bản ghi: bước, HR theo phút, SpO2, HA, stress, HRV, nhiệt độ, đường huyết),
ngủ 2 đêm (17/10 00:36→06:24, 18/10 00:55→05:49), bước hôm nay `D8`, 3 bài tập `D3`/`D4`, `E7` đọc/ghi, `AC` đọc, `B8` ghi (12/24h, khôi phục),
thông báo `C2` (Zalo→khác), SMS, cuộc gọi `C2`+`C1`, tìm vòng tay `B5 0A` (`B5 0A 01`), camera `B6`, nhạc `99 01` (`99 01 01` = OK).

Chưa kiểm (GE54 không hỗ trợ hoặc cần thao tác người dùng): người dùng bấm từ chối cuộc gọi `C1 02`, phím nhạc `99 02/03`, tìm điện thoại `B5 00`,
nút chụp `B6 01 02`, SOS `B7`, `DA` điều khiển bài tập, thời tiết `C8` (A7: không có), danh bạ `72` (không có), ngôn ngữ `F4` (không màn),
mặt đồng hồ `50`+DOOG (JieLi, không màn), `D1`, ngủ thường, bài tập cổ điển, cảnh báo HR ghi `AC`. OTA không làm (chỉ đọc mã).
