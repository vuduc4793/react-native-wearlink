# 01 — Giao thức BLE GloryFit (UTE / Youte SDK) cho Y25_6E1B

> Nguồn: APK GloryFit `com.yc.gloryfit` 4.0.12 (versionCode 279), decompile bằng jadx.
> Mọi trích dẫn `file:dòng` tính từ gốc `sdks/gloryfit/research/jadx-out/sources/`.
> Phần không đọc trực tiếp từ code được đánh dấu **(suy luận)**.
> Chưa kiểm chứng trên thiết bị thật; phiên chính đang test trên Android.

---

## 0. Tóm tắt nhanh

| Hạng mục | Giá trị |
|---|---|
| Vendor SDK | **UTE** (Shenzhen Youte; tiền tố log/khóa `UTE8`), namespace `com.yc.pedometer.**` (nhúng thẳng vào app, không obfuscate) |
| Có phải giao thức QRing/oudmon không? | **Không.** APK không có `com.oudmon` (0 chuỗi trong cả 8 file dex), không có service `6e40fff0`, frame không cố định 16 byte, không có checksum cộng |
| Service chính (BLE4) | `000055ff-0000-1000-8000-00805f9b34fb` |
| Write lệnh | `000033f1-…` (đồng thời là characteristic **READ** trả về bảng tính năng 20 byte) |
| Notify phản hồi | `000033f2-…` |
| Service "BLE5" (gói lớn) | `000056ff-…`: write `000034f1-…` (READ: 2 byte độ dài gói tối đa + bảng tính năng 8..13), notify `000034f2-…` |
| Frame | `[opcode 1 byte][tham số…]`, độ dài thay đổi (≤ 20 byte, hoặc ≤ MTU-3 nếu thiết bị hỗ trợ). **Không header, không length, không checksum, không mã hóa** |
| Kiểm tra toàn vẹn | Chỉ ở một số luồng lịch sử: XOR 1 byte trong gói kết thúc `[op] FD [xor]` (ví dụ ngủ `B3`, SpO2 `34 FA`) |
| Kết thúc luồng nhiều gói | Gói `[op] FD …` (ví dụ `B2 FD`, `B3 FD xx`, `E6 FD`, `F7 FD`) |
| MTU | App xin `requestMtu(247)`; độ dài gói hữu dụng = `min(MTU-3, giá trị 2 byte đầu đọc từ 34f1)` |
| Bonding | **Không** bắt buộc cho kênh dữ liệu. Chỉ `createBond()` khi gói quảng bá chứa `18 12` (HID) hoặc cho kênh BT Classic (gọi điện "BT3") |
| Bind/xác thực | Tùy bit tính năng: (a) **mã 4 số** hiện trên đồng hồ (`D5 02` → người dùng nhập → `D5 01` + 4 byte XOR "UTE8"), hoặc (b) **Account ID** (`33 02` + id 4 byte BE → đồng hồ hỏi xác nhận → `33 04 01`), hoặc (c) không cần gì |
| Handshake | connect → (800 ms) discover → (200 ms) bật CCCD 33f2/34f2… → đọc 33f1/34f1 → MTU 247 → bind → `A3` giờ → `A1` firmware → `A9` user info → `A2` pin → sync `B2/B3/E6|F7/…` |
| SoC / cảm biến (in trên vỏ) | Realtek **RTL8773EWE-VP**, cảm biến nhịp tim Vcare **VC30F-S** |

---

## 1. Vendor / SDK

### 1.1 Gói và lớp chính

| Thành phần | File |
|---|---|
| Service BLE (GATT callback, parser phản hồi, state machine) | `com/yc/pedometer/sdk/BluetoothLeService.java` (10 490 dòng) |
| Đóng gói lệnh | `com/yc/pedometer/sdk/WriteCommandToBLE.java` |
| Hàng đợi ghi (33f1 / 34f1) | `com/yc/pedometer/utils/NotifyUtils.java:203-277` |
| Giải mã dữ liệu bước/ngủ/nhịp tim | `com/yc/pedometer/sdk/DataProcessing.java` |
| UUID | `com/yc/pedometer/utils/UUIDUtils.java:8-38` |
| Bảng tính năng | `com/yc/pedometer/column/GetFunctionList.java` |
| Danh sách lệnh lúc kết nối/đồng bộ | `com/yc/pedometer/utils/SyncParameterUtils.java:263-460` |
| Nền tảng chip | `com/yc/pedometer/ble/DevicePlatform.java` |

Dấu hiệu UTE: khóa XOR là chuỗi ASCII `"UTE8"` (`WriteCommandToBLE.java:1866`), các lớp `UTESQLOperate`,
`UteBleReconnectController`, `UteListenerManager`. Package `com.ute.camera` chỉ là module camera.

### 1.2 Thư viện chip đi kèm (OTA, không thuộc giao thức dữ liệu)

| Thư viện | Dùng cho |
|---|---|
| `com.realsil.sdk.dfu` / `com.realsil.sdk.bbpro`, `libRtkAesJni.so` | OTA Realtek (8762C/8763E/8773). Bật khi thiết bị có service `0000d0ff-3c17-d293-8e48-14fe2e4da212` ⇒ `isRKPlatform=true` (`BluetoothLeService.java:3415-3417`); service OTA im lặng `00006287-3c17-…` (`:3419`) |
| `no.nordicsemi.android.dfu`, SUOTA `fef5` | OTA Nordic / Dialog |
| `com.jieli.*`, `com.actions.ibluz`, `com.bluetrum.fota` | Chip JieLi / Actions / Bluetrum |
| FRK (`02f00000-…-fe00`) | Chip "富瑞坤" (nhẫn) |

### 1.3 Có chung gì với QRing (oudmon)?

Không chung mã, không chung UUID, không chung khung gói. Điểm trùng duy nhất là **tên** "Y25" có trong
danh sách tiền tố quét của QRing (`sdks/qring/docs/01-connection.md` §1.2). ⇒ Driver phải phân biệt bằng
**service UUID sau khi kết nối** (55FF/56FF ⇒ UTE/GloryFit; 6E40FFF0 ⇒ QRing), không chỉ bằng tên.

### 1.4 Phần riêng cho RTL8773 / VC30F (thiết bị Y25_6E1B)

| Phần cứng | Đường code liên quan |
|---|---|
| Realtek RTL8773 | Bit `function13 & 0x020000` ⇒ `isRKPlatform8773()` (`ble/DevicePlatform.java:28-30`), `getDevicePlatformType()=5` (`:69-70`) — chỉ dùng để chọn kho mặt đồng hồ trên server (`watchface/WatchFaceModelImpl.java:156,181,195,231`, `onlinedial/PostUtil.java:48,152`). Giao thức dữ liệu **không đổi** theo chip. OTA đi đường Realtek DFU (`BluetoothLeService.java:6268-6313`, `startOtaProcess8762C`). Nếu quảng bá chứa `36 55` app đánh dấu `needPair8763E` và nhờ hệ thống ghép đôi (`ble/SearchDeviceActivity.java:170`, `:504-508`) **(suy luận: dành cho dòng Realtek 876x/877x có BT Classic)** |
| Vcare VC30F | Thuật toán HR/SpO2 chạy **trên đồng hồ** — APK không có thư viện Vcare (.so hay Java). Tên cảm biến chỉ xuất hiện qua lệnh `44 0F` (query sensor type, `mood/MoodCommandUtil.java:93-95`); phản hồi `44 0F [mood][pressure][fatigue][len][ASCII tên cảm biến]` (`BluetoothLeService.java:9306-9317`); mặc định `"VC32"` (`utils/SPUtil.java:3075-3076`). Tên này được gửi lên server để kích hoạt thuật toán stress/mood/huyết áp (`mood/MoodHttpPostUtils.java:64`, `bpprotocol/el/net/ElBpHttpPostUtils.java:190`) |

---

## 2. Quét và nhận diện

### 2.1 Bộ lọc của app (`ble/SearchDeviceActivity.java:149-178`)

- `BluetoothAdapter.startLeScan` không filter phần cứng; lọc trong callback:
  - `|rssi| ≤ 90`, tên ≠ null và dài ≥ 2.
  - **Không có danh sách tiền tố tên** (không có "Y25" hay prefix nào trong code GloryFit).
  - Chuỗi hex (cách nhau bởi dấu cách) của **toàn bộ gói quảng bá thô** phải chứa một trong:
    `"33 55"`, `"F0 55"`, `"36 55"`, `"34 55"`, `"3C 55"`, `"55 55"`, `"54 55 44 45 31 42 FF 55"`,
    `"4C 42 4F 4F"` ("LBOO"), hoặc tên bắt đầu `"AT"` (`:162-165`).
  - **(suy luận)** các cặp `xx 55` là UUID 16-bit little-endian `0x5533, 0x55F0, 0x5536, 0x5534, 0x553C, 0x5555`
    trong AD "Service UUID" — cùng dải `0x55xx` với service GATT `0x55FF`.
- Cờ phụ từ quảng bá (`:167-171`):

| Mẫu trong adv | Ý nghĩa |
|---|---|
| `55 55` hoặc tên `AT…` | `devicePlatform = 1` (JX/Actions); ngược lại `2` (RK = Realtek) |
| `18 12` | `needPair` — thiết bị có HID ⇒ app gọi `createBond()` (`:497-499`, `:782-791`) |
| `36 55` | `needPair8763E` (Realtek 8763E) |
| `3C 55` | dự án "YaMei" (server riêng) |
| `22 22` hoặc `4C 42 4F 4F` | `custom` |
| `09 FF 08 08` | Manufacturer data, hỗ trợ đo HR "động/tĩnh" |

### 2.2 Đề xuất cho driver `gloryfit` (suy luận)

`match(scanned)`: tên bắt đầu `Y25`/khác **và** adv chứa UUID 16-bit dải `0x55xx`
(`0x5533/0x55F0/0x5536/0x5534/0x553C/0x5555`) hoặc service `0x55FF`. Nếu adv không đủ, trả "có thể",
rồi khẳng định sau discover: có service `55FF` (hoặc `56FF`) ⇒ UTE; có `6E40FFF0` ⇒ để cho driver `qring`.
Cần chụp adv thật của Y25_6E1B (nRF Connect) để chốt.

---

## 3. GATT, MTU, bonding, handshake

### 3.1 Bảng UUID (`utils/UUIDUtils.java:8-38`)

| Tên trong code | UUID | Vai trò |
|---|---|---|
| `SIMPLE_SERVICE_UUID` | `000055ff-0000-1000-8000-00805f9b34fb` | Service lệnh chính |
| `ONLY_WRITE_UUID` (= `PASS_WORD_CHARACTERISTIC_UUID`) | `000033f1-…` | Write lệnh; **Read** = bảng tính năng 1..7 |
| `ONLY_READ_UUID` | `000033f2-…` | Notify phản hồi |
| `SIMPLE_SERVICE_UUID_5` | `000056ff-…` | Service "BLE5" |
| `ONLY_WRITE_UUID_5` | `000034f1-…` | Write gói lớn; **Read** = độ dài gói tối đa + tính năng 8..13 |
| `ONLY_READ_UUID_5` | `000034f2-…` | Notify gói lớn |
| `ALIPAY_SERVICE_UUID` | `000057ff-…` (write `35f1`, notify `35f2`) | Alipay |
| `BP_SERVICE_UUID` | `0000fff0-…` / `fff6` | Vòng huyết áp đặc chế (`deviceType=1`) |
| `OTA_SERVICE_UUID` | `0000d0ff-3c17-d293-8e48-14fe2e4da212` | OTA Realtek; đọc patch version ở `0000ffd3-…` |
| `SPOTA_SERVICE_UUID` | `0000fef5-…` | OTA Dialog |
| `WECHAT_PAY_AUTH_*` | `00003802-…` / `00004a02-…` | WeChat Pay |
| `0000fee7-…` | — | Có ⇒ hỗ trợ WeChat (`BluetoothLeService.java:3409-3411`) |

App **không** dùng Battery `180F/2A19` hay Heart Rate `180D/2A37` chuẩn cho luồng chính (hằng số có khai báo
nhưng không được gọi ngoài danh sách CCCD — `BluetoothLeService.java:3458`).

### 3.2 Ghi lệnh

- `writeChara(bytes)` → `NotifyUtils.writeCharaBle4` → handler nền → `writeChara4`: lấy `55ff/33f1`,
  `setValue`, `writeCharacteristic` (`utils/NotifyUtils.java:203-246`). Không gọi `setWriteType` ⇒ dùng kiểu
  ghi mặc định của characteristic **(suy luận: Write With Response)**.
- Khóa "busy" 3 s: chỉ ghi gói kế khi đã có `onCharacteristicWrite` (`NotifyUtils.java:231`).
- Mỗi lệnh có timeout phản hồi 3 s (`utils/CommandTimeOut.java:14`), app đi tuần tự từng lệnh.
- Kênh BLE5: `writeCharaBle5` → `56ff/34f1` (`NotifyUtils.java:248-277`).

### 3.3 Trình tự kết nối (trích từ code)

| Bước | Hành động | Trích dẫn |
|---|---|---|
| 1 | `connectGatt(ctx, autoConnect=false, cb, TRANSPORT_LE=2)`; timeout tổng 40 s | `BluetoothLeService.java:2924`, `:2936-2938` |
| 2 | `STATE_CONNECTED` → chờ **800 ms** → `discoverServices()` (thử lại tối đa 3 lần) | `:423`, `:9580-9600`, `:1356-1369` |
| 3 | Discover OK → chờ **200 ms** → `displayGattServices()` | `:552`, `:1349-1354` |
| 4 | Lập danh sách theo thứ tự characteristic tìm thấy: CCCD `33f2` (1), CCCD `34f2` (2), CCCD SUOTA (3), CCCD `fff6` (4), CCCD `35f2` (5), CCCD FRK (6), CCCD WeChat (7), **READ `33f1`** (11), **READ `34f1`** (12) | `:3374-3440`, `:9399-9497` |
| 5 | Khi còn 1 mục cuối, chèn `21` = `requestMtu(247)` (thử lại tới 5 lần nếu độ dài ≤ 20) | `:9505-9515`, `:9497` |
| 6 | Đọc `33f1` (20 byte) ⇒ tính năng 1..7; đọc `34f1` ⇒ 2 byte đầu = độ dài gói tối đa (BE), còn lại tính năng 8..13 | `:608-700` |
| 7 | `onMtuChanged(mtu)`: nếu `mtu-3 <` độ dài đang lưu (hoặc chưa có) thì lưu `mtu-3` | `:826-846` |
| 8 | Hết danh sách ⇒ `mSyncTimeRunnable()` = **quyết định bind** | `:9532`, `:5221-5252` |
| 9 | Bind xong ⇒ message `1006` "CONNECT_ALL_SUCCESS": state = CONNECTED, nạp danh sách `[0 = A3 giờ, (151 = 44 0F nếu có cảm biến mood), (159 = A1 01 DSP), 1 = A1 firmware]` | `:1371-1384`, `utils/SyncParameterUtils.java:263-294` |
| 10 | Phản hồi `A1` ⇒ `addBeginVersionCommandIndex()`: `BB` (push?), … `A9` user info, `A2` pin, `B2 FA` bước, `B3 FA` ngủ, `E6 FA`/`F7 FA` nhịp tim, `C8 FA` HA, nhiệt độ, SpO2… (theo bit tính năng) | `BluetoothLeService.java:3560-3584`, `SyncParameterUtils.java:296-460`, `WriteCommandToBLE.java:2390-2440` |

### 3.4 Bind / xác thực ("đang chờ app kết nối")

`mSyncTimeRunnable` (`BluetoothLeService.java:5221-5252`):

```
if (function1 & 0x000001)                    // hỗ trợ mật khẩu
    if (lastPassword == "1234") requestCaptcha()   // D5 02  (lần đầu)
    else                         sendSecretKey()    // D5 01 + 4 byte
else if (tên chứa "A221" && function5 & 0x000004) sendAccountIdSuperCmd()  // 33 01
else if (function10 & 0x080000)              sendAccountId()               // 33 02 + id
else                                         → 1006 (đã kết nối, không bind)
```

**(a) Mã 4 số trên màn hình đồng hồ** (`WriteCommandToBLE.java:1860-1891`, phản hồi `BluetoothLeService.java:3886-3955`):

| Hướng | Gói | Ý nghĩa |
|---|---|---|
| App → | `D5 02` | Xin mã (đồng hồ hiện 4 số) **(suy luận về việc hiển thị)** |
| ← Dev | `D5 02` | Yêu cầu app mở bàn phím nhập mã (`PassWordActivity_KeyBorad`) |
| App → | `D5 01 k0 k1 k2 k3` | `k_i = ASCII(digit_i) XOR "UTE8"[i]` (`PassWordActivity_KeyBorad.java:224-226`) |
| ← Dev | `D5 01` | Đúng ⇒ sau 500 ms coi như kết nối thành công |
| ← Dev | `D5 03` | Hết thời gian ghép mã |
| ← Dev | `D5 04` | (callback 42 — chưa rõ) |
| ← Dev | `D5 FF` | Sai mã ⇒ mở lại bàn phím |

Mã đã nhập được lưu và lần sau gửi thẳng `D5 01 …` (không hỏi lại).

**(b) Account ID** (`WriteCommandToBLE.java:3629-3642`, phản hồi `BluetoothLeService.java:4464-4510`):

| Hướng | Gói | Ý nghĩa |
|---|---|---|
| App → | `33 02 id3 id2 id1 id0` | id 32-bit **big-endian**; lần đầu random 1..99 999 999, lưu lại |
| ← Dev | `33 04 01` | Đã xác thực ⇒ tiếp tục (`1006`) |
| ← Dev | `33 04 02` | Đồng hồ ghi nhận id mới ⇒ app lưu id, chờ tiếp |
| ← Dev | `33 04 03` | Đồng hồ đang reset; yêu cầu **xác nhận trên đồng hồ** |
| ← Dev | `33 04 04` | Yêu cầu **xác nhận trên đồng hồ** (UI: `SearchDeviceActivity.java:243-246`) |
| ← Dev | `33 04 05` | Người dùng từ chối trên đồng hồ ⇒ hủy, không tự kết nối lại |
| App → | `33 01` | Biến thể "super cmd" (chỉ tên chứa A221); hết 3 s không trả lời vẫn tiếp tục (`:2457-2460`) |

**(suy luận)** Màn "waiting for app connection" của Y25 nhiều khả năng ứng với (b): đồng hồ chờ `33 02 <id>`,
rồi hiện hộp xác nhận (330404) và gửi `33 04 01` khi người dùng bấm đồng ý. Nếu sau khi đọc `33f1`
bit `function1 & 1` bật thì là luồng (a). Cần đọc 20 byte `33f1` thật để biết chắc.

### 3.5 Bonding

Không cần cho kênh dữ liệu. `createBond()` chỉ khi adv có `18 12` (`SearchDeviceActivity.java:497-499`, `:782-791`)
hoặc cho BT Classic gọi điện khi `function6 & 0x040000` (`MainActivity.java:215-230`, `:925-940`, transport BR/EDR=1).

---

## 4. Khung gói

### 4.1 Lệnh và phản hồi

- Gói = `opcode` + tham số; phản hồi bắt đầu bằng **cùng opcode**. Parser so khớp 1 byte (hoặc 2 byte) đầu
  dưới dạng hex string (`BluetoothLeService.java:3494-4607` cho `33f2`, `:4612-4732` cho `34f2`).
- **Không có checksum mỗi gói**, không mã hóa. Số nhiều byte đều **big-endian** (năm, số bước, id…).
- Năm luôn là 2 byte BE: 2026 = `07 EA`. Mẹo của firmware: vì byte cao năm 2000–2047 là `0x07`,
  các bản ghi `F7 07 …` (nhịp tim 24h) trùng với "F707" mà parser dùng (`:3758`).

### 4.2 Luồng nhiều gói (đồng bộ lịch sử)

- Gửi `[op] FA` (hoặc `[op] FA YYYY MM DD HH mm` nếu `function4 & 0x002000` — "sync từ mốc thời gian",
  `utils/SyncDateUtils.java:123-170`).
- Thiết bị trả nhiều bản ghi `[op] …`, kết thúc `[op] FD [crc?]`. Mỗi gói độc lập, **không cần ghép**.
- XOR kiểm tra (chỉ vài loại):
  - Ngủ `B3`: `crc ^= b7 ^ b8` mỗi bản ghi (định dạng thường, `DataProcessing.java:830`) hoặc
    `crc ^= b1^…^b13` (định dạng 14 byte "gộp theo giờ", `:791`); gói kết thúc `B3 FD crc`, so `bArr[2]`
    (`:359-390`). Sai ⇒ app gửi lại `B3 FA`.
  - SpO2 `34 FA`: `crc ^= b[i]` với `i ≥ 2` mọi bản ghi (`BluetoothLeService.java:8308`); kết thúc `34 FA FD crc`
    (`:8282-8300`).
- Bộ đếm bản ghi trùng: app bỏ qua gói giống hệt gói trước (`CRC_LAST_CHECK`).

### 4.3 Gửi dữ liệu dài (app → thiết bị)

`[op][seq][≤ (L-2) byte]` …, kết thúc `[op] FD`, với `L = 20` hoặc độ dài tối đa đã thương lượng nếu
`function10 & 0x040000` (ví dụ tin nhắn `C5`, `WriteCommandToBLE.java:1200-1249`, `:1338-1344`).

---

## 5. Lệnh

### 5.1 Bảng lệnh chính

| Chức năng | App → thiết bị | Phản hồi | Trích dẫn |
|---|---|---|---|
| Đặt giờ | `A3 YYYY MM DD hh mm ss` (8 B) | `A3 …` | `WriteCommandToBLE.java:467-478`; `BluetoothLeService.java:3549-3558` |
| Firmware | `A1` | `A1` + ASCII phiên bản (ví dụ "xxxV1.2…") | `:822-825`; `DataProcessing.java:326-337` |
| Phiên bản DSP | `A1 01` | `A1 01` + ASCII | `:827-830`; `BluetoothLeService.java:3561-3567` |
| Pin | `A2` | `A2 pp` (pp = %, kẹp ≤ 100) | `:832-836`; `DataProcessing.java:285-287` |
| Trạng thái bước/ngủ | `AA` | `AA 10` = đang đếm bước, `AA 02` = ngủ | `:818-820`; `DataProcessing.java:262-283` |
| User info / cài đặt | `A9` + 18 byte (xem 5.2) | `A9 …` | `:480-541` |
| Nhịp tim tức thời bắt đầu | `E5 11` | `E5 11` (ack), sau đó `E5 st vv rr` | `:1048-1060`; `DataProcessing.java:1277-1461` |
| Nhịp tim tức thời dừng | `E5 00` | `E5 FD` = thiết bị tự kết thúc | như trên |
| Bật/tắt HR 24h | `F7 01` / `F7 02` | `F7 01`/`F7 02` | `:1924-1935` |
| Chu kỳ đo HR tự động | `F7 09 en mmH mmL`; khung giờ `F7 0F en h1 m1 h2 m2` | | `:706-736` |
| HR 24h đẩy realtime | (thiết bị tự gửi) `F7 03 YYYY MM DD hh mm rr` | | `DataProcessing.java:1502-1539` |
| HR 24h max/min/avg | (thiết bị) `F7 04 … [8]=max [9]=min [10]=avg` | | `DataProcessing.java:1541-1569` |
| HR đo trên đồng hồ | (thiết bị) `F7 0B YYYY MM DD hh mm rr` | | SDK iOS `receiveDeviceHeartDataManual:` (doc 09 §2.2) |
| Trạng thái đo HR | `E5 AA` | `E5 AA 11` (đang đo) / `E5 AA FF` | SDK iOS `readHRMStatus:` (doc 09 §2.2) |
| **Y25 (HR 24h) đo theo lệnh** | `F7 02` (tạm tắt 24h), `D6 01`, `E5 11`, chờ ~25 s, `E5 00`, rồi `F7 01` + `F7 09 01 00 05` | Khi 24h bật, `E5 11` bị **treo** (không ack) tới lúc tắt 24h. Sau `F7 02`: `E5 11` ack ngay; `E5 00` → **`E5 00 00 rr`** (kết quả). Không gửi `E5 00` thì đèn đo chạy mãi. `E5 AA` luôn trả `11` | kiểm chứng 16/10/2026 (`E5 00 00 52` = 82 bpm) |
| SpO2 bắt đầu / dừng | `34 11` / `34 00` | `34 11` (ack), `34 11 st vv` (đang đo), `34 00 st vv` (kết quả) | `:3753-3761`; `BluetoothLeService.java:8171-8230` |
| SpO2 trạng thái | `34 AA` | | `:3778-3781` |
| Huyết áp bắt đầu / dừng | `C7 11` / `C7 00` | `C7 fin st sys dia` | `:1481-1493`; `DataProcessing.java:1737-1830` |
| Nhiệt độ hiện tại | `24 01` | `24 01 YYYY MM DD hh mm ss TT TT` (TT = °C×100 BE; `FF FF` = không có) | `:3671-3673`; `BluetoothLeService.java:7949-7977`; `temperature/TemperatureUtil.java:159-215` |
| HRV bắt đầu / dừng / trạng thái | `5C 10` / `5C 11` / `5C 12` | | `:5528-5541` |
| Cảm biến mood (tên chip HR) | `44 0F` | `44 0F m p f len ASCII…` | `mood/MoodCommandUtil.java:93-95` |
| Tìm đồng hồ | `AB 00 00 00 01 xx 07 01` | | `:790-793` |
| Tắt máy / khởi động lại | `E8 11` / `E8 12` | | `:5543-5549` |

`st` = 0 ⇒ giá trị hợp lệ; `fin` (byte 1) = 0 ⇒ phép đo đã xong, 0x11 ⇒ đang đo
(`DataProcessing.java:1451-1461`, `:1815-1830`).

Khi `function2 & 0x004000` (HR 24h), kết quả đo tay đến dưới dạng `E5 00 00 rr` (4 byte, `DataProcessing.java:1403-1424`).

### 5.2 `A9` — thông tin người dùng (19 byte, `WriteCommandToBLE.java:480-541`)

| Byte | Nội dung |
|---|---|
| 0 | `A9` |
| 1 | `00` |
| 2 | Chiều cao cm nếu `function2&0x1000` hoặc `function3&0x40` hoặc `function3&0x2000`; ngược lại độ dài bước = `cao×0.418` |
| 3 | Phần thập phân cân nặng ×100 (chỉ khi `function3&0x40`), ngược lại 0 |
| 4 | Cân nặng kg (nguyên) |
| 5 | Thời gian tắt màn hình (s) |
| 6..9 | Mục tiêu bước, uint32 BE |
| 10 | Nâng tay sáng màn (1/0) |
| 11 | Ngưỡng báo HR cao (`FF` = tắt) |
| 12 | Hỗ trợ ngủ bằng HR (1/0) |
| 13 | Tuổi |
| 14 | Giới tính: 1 = nam, 2 = nữ **(suy luận: `getPersonageGender()==true` là nam)** |
| 15 | 0 |
| 16 | Ngôn ngữ 1 = TQ, 2 = khác |
| 17 | Đơn vị nhiệt: 1 = °C, 2 = °F |
| 18 | Ngưỡng báo HR thấp (0 = tắt) |

### 5.3 Đồng bộ lịch sử

| Loại | Lệnh | Bản ghi | Kết thúc | Trích dẫn |
|---|---|---|---|---|
| Bước (theo giờ) | `B2 FA` (hoặc `EB 02 FA` trên kênh 34f1 nếu `function8&0x20`) | `B2 YYYY MM DD HH sH sL [+ mở rộng chạy/đi nếu function1&0x100]` | `B2 FD` | `WriteCommandToBLE.java:576-592`; `DataProcessing.java:243-260`, `:845-…` |
| Bước CyWee (theo giờ) | `EB 02 FA` (34f1) | `EB 02 YYYY MM DD HH sH sL dH dL c c c` (m; kcal×1000 do đồng hồ tính, app lấy round1(raw/1000), **không** tính lại từ bước/hồ sơ như đường `B2`); realtime `EB 01` cùng định dạng | `EB 02 FD xx` | `SWAlgorithmUtil.java:35-49`; `DataProcessing.java:637-757`, `:1061-1205` |
| Bước realtime (thiết bị tự đẩy) | — | `B1 YYYY MM DD HH sH sL …` | — | `BluetoothLeService.java:3507-3514`; `DataProcessing.java:448-` |
| Ngủ | `B3 FA` / `B3 FA YYYY MM DD HH mm` | thường: `B3 YYYY MM DD hh mm rH rL` (r = "roll count"); gộp giờ (14 B, `function1&0x400`): `B3 YYYY MM DD hh (m,r)×4` (`FF FF` = trống) | `B3 FD crc` | `:594-616`; `DataProcessing.java:759-843` |
| Ngủ (thuật toán trên đồng hồ, `function4&0x40000`) | `31 01` | `31 01 YYYY MM DD … [6]=số đoạn` + `32 <raw…>` | `31 02` | `BluetoothLeService.java:7640-7681` |
| Nhịp tim (từng lần đo) | `E6 FA` (+ mốc) | `E6 YYYY MM DD hh mm rr` | `E6 FD` | `:623-641`; `DataProcessing.java:1473-1483` |
| Nhịp tim 24h (10 phút/ô) | `F7 FA` (+ mốc) | `F7 YYYY MM DD HH v0…v11`: ô `i` (byte 6..17) ở phút `HH×60 − (17−i)×10`; HH=0 ⇒ 24h hôm trước; chỉ nhận 40<v<200 | `F7 FD` | `:1937-1955`; `DataProcessing.java:1485-1500` |
| Huyết áp | `C8 FA` (+ mốc) | `C8 YYYY MM DD hh mm sys dia` | `C8 FD` | `:770-788`; `DataProcessing.java:1733-1735` |
| SpO2 | `34 FA` | `34 FA YYYY MM DD HH xx v0…v11`: ô `i` (byte 8+i) ở phút `HH×60 − (11−i)×10`, `FF` = trống, giá trị kẹp 70..100 | `34 FA FD crc` | `:3783-3787`; `BluetoothLeService.java:8282-8330`; `oxygen/OxygenUtil.java:34-78` |
| Nhiệt độ | `24 FA` | `24 FA …` các ô (°C×100 BE) | `24 FD` | `:3666-3669`; `BluetoothLeService.java:7990-8015` |

Thứ tự app đồng bộ: `B2` → `B3` (chỉ khi đang giờ ngủ hoặc chưa sync lần nào) → `F7` nếu HR 24h, ngược lại `E6`
→ `C8` → bơi/nhảy dây/đạp xe/GPS… → nhiệt độ → SpO2 (`SyncParameterUtils.java:346-404`).

Phân loại ngủ từ "roll count" do app làm (`column/SleepDataProcessingStrategy.java:137-170`): `≤ 3` ⇒ ngủ sâu,
`≤ 40` ⇒ ngủ nông, lớn hơn ⇒ thức **(rút gọn; thuật toán đầy đủ có thêm điều kiện giờ và chuỗi liên tiếp)**.

---

## 6. Bảng tính năng (capability flags)

### 6.1 Cách đọc

Đọc `33f1` (20 byte). Mỗi nhóm là **số 24-bit big-endian**; byte 0..1 là nhóm 7 (16-bit)
(`BluetoothLeService.java:611-644`):

| Byte của `33f1` | 0..1 | 2..4 | 5..7 | 8..10 | 11..13 | 14..16 | 17..19 |
|---|---|---|---|---|---|---|---|
| Nhóm | F7 | F6 | F5 | F4 | F3 | F2 | F1 |

Đọc `34f1` (20 byte): byte 0..1 = độ dài gói tối đa (BE); rồi 6 nhóm 24-bit (`:666-700`):

| Byte của `34f1` | 0..1 | 2..4 | 5..7 | 8..10 | 11..13 | 14..16 | 17..19 |
|---|---|---|---|---|---|---|---|
| Nhóm | maxLen | F13 | F12 | F11 | F10 | F9 | F8 |

Kiểm tra: `(Fn & mask) == mask` (`column/GetFunctionList.java`).

### 6.2 Bit đã xác định từ cách dùng

| Nhóm & mask | Ý nghĩa | Trích dẫn |
|---|---|---|
| F1 `0x000001` | Bind bằng mật khẩu/mã 4 số | `BluetoothLeService.java:5224` |
| F1 `0x000010` / `0x004000` | Bơi / nhảy dây | `SyncParameterUtils.java:371-375` |
| F1 `0x000100` | Bước tách chạy/đi | `BluetoothLeService.java:643` |
| F1 `0x000400` | Ngủ định dạng 14 byte "gộp giờ" | `BluetoothLeService.java:642` |
| F1 `0x080000` | **Nhịp tim** | `SyncParameterUtils.java:713-717` |
| F1 `0x100000` | **Huyết áp** | `SyncParameterUtils.java:678-684` |
| F1 `0x200000` | UV | `SyncParameterUtils.java:431-432` |
| F2 `0x004000` | **HR 24h** (dùng `F7`, `E5 00 00 rr`) | `BluetoothLeService.java:3704` |
| F2 `0x000020` | Tìm điện thoại | `BluetoothLeService.java:3654` |
| F2 `0x000100` | Đạp xe | `SyncParameterUtils.java:377` |
| F3 `0x000001` | Đa môn thể thao | `SyncParameterUtils.java:364` |
| F3 `0x000040` | Cân/thành phần cơ thể | `fragment/FragmentHomePage.java:2474` |
| F3 `0x002000` | **ECG** | `FragmentHomePage.java:2505` |
| F4 `0x002000` | Đồng bộ lịch sử theo mốc thời gian | `utils/SyncDateUtils.java:123-130` |
| F4 `0x008000` | Tai nghe (không có ngủ) | `FragmentHomePage.java:2484` |
| F4 `0x040000` | Ngủ do thuật toán trên đồng hồ (`31 01`) | `WriteCommandToBLE.java:601` |
| F5 `0x000004` | Account ID (biến thể A221) | `BluetoothLeService.java:5225` |
| F5 `0x000008` | **Nhiệt độ** | `FragmentHomePage.java:2510` |
| F5 `0x000040` | **SpO2** | `FragmentHomePage.java:2495` |
| F5 `0x100000` | Huyết áp Changsang | `FragmentHomePage.java:2469` |
| F6 `0x000020` | **Stress / mệt mỏi / cảm xúc** | `FragmentHomePage.java:2515` |
| F6 `0x040000` | BT Classic (gọi điện) | `SyncParameterUtils.java:303` |
| F7 `0x000010` | Module huyết áp ElBp | `GetFunctionList.java:108-110` |
| F7 `0x002000` | Có phiên bản DSP (`A1 01`) | `SyncParameterUtils.java:285` |
| F8 `0x000020` | Bước qua kênh BLE5 `EB 02 FA` + ngủ `EC 01` | `WriteCommandToBLE.java:587`, `SyncParameterUtils.java:350` |
| F8 `0x020000` | **Đường huyết** | `FragmentHomePage.java:2500` |
| F10 `0x040000` | Gói dài dùng `maxLen` thay vì 20 | `WriteCommandToBLE.java:1208` |
| F10 `0x080000` | **Account ID** (`33 02`) | `BluetoothLeService.java:5226` |
| F11 `0x000020` | **HRV** | `FragmentHomePage.java:2528` |
| F13 `0x010000`/`0x020000`/`0x040000`/`0x080000`/`0x100000` | ATS3085S / **RTL8773** / JieLi AC707 / ZK / nhẫn FRK | `ble/DevicePlatform.java:28-50` |

### 6.3 Ánh xạ sang `Capability` của SDK

| Capability | Điều kiện |
|---|---|
| `HEART_RATE` | F1 `0x080000` (hoặc tên firmware chứa MH/RH/UH) |
| `BLOOD_PRESSURE` | F1 `0x100000` hoặc F5 `0x100000` hoặc F7 `0x10` |
| `SPO2` | F5 `0x40` |
| `TEMPERATURE` | F5 `0x08` |
| `STRESS` | F6 `0x20` |
| `HRV` | F11 `0x20` |
| `ECG` | F3 `0x2000` |
| `BLOOD_SUGAR` | F8 `0x020000` |
| `STEPS` | luôn có |
| `SLEEP` | khi **không** có F4 `0x8000` |

---

## 7. Ví dụ hex

Không có checksum mỗi gói nên chỉ cần ghép đúng byte. Các XOR bên dưới đã tính lại bằng script.

| Mục đích | Hex |
|---|---|
| Đặt giờ 2026-10-13 16:30:05 | `A3 07 EA 0A 0D 10 1E 05` |
| Xin mã 4 số | `D5 02` |
| Gửi mã "1234" | `D5 01 64 66 76 0C` (`'1'^'U'=64, '2'^'T'=66, '3'^'E'=76, '4'^'8'=0C`) |
| Account ID 12 345 678 | `33 02 00 BC 61 4E` → chờ `33 04 01` |
| Pin | gửi `A2` → nhận ví dụ `A2 4B` = 75 % |
| Firmware | gửi `A1` → nhận `A1` + ASCII |
| User info (170 cm, 65 kg, tắt màn 5 s, 8000 bước, nâng tay bật, HR cao tắt, 30 tuổi, nam, EN, °C) | `A9 00 AA 00 41 05 00 00 1F 40 01 FF 00 1E 01 00 02 01 00` |
| HR: bắt đầu | `E5 11` → `E5 11` (ack) → `E5 11 00 48` (đang đo, 72) → `E5 00 00 48` (xong, 72) |
| HR: dừng | `E5 00` |
| SpO2: bắt đầu | `34 11` → `34 11` → `34 11 00 61` → `34 00 00 62` (98 %) |
| Nhiệt độ | `24 01` → `24 01 07 EA 0A 0D 10 1E 05 0E 6B` = 36,91 °C |
| Sync bước | `B2 FA` → `B2 07 EA 0A 0D 08 03 E8` (13/10/2026 8h: 1000 bước) … `B2 FD` |
| Sync ngủ | `B3 FA` → `B3 07 EA 0A 0D 17 1E 00 05` (23:30, roll 5) → `B3 07 EA 0A 0E 01 00 00 2A` (01:00, roll 42) → `B3 FD 2F` (`(00^05)^(00^2A)=2F`) |
| Sync HR | `E6 FA` → `E6 07 EA 0A 0D 0E 1E 48` (14:30 = 72) … `E6 FD` |
| Sync HR 24h | `F7 FA` → `F7 07 EA 0A 0D 0F 46 48 4A …` (12 ô từ 13:10 tới 15:00) … `F7 FD` |
| Sync HR từ mốc 12/10/2026 00:00 | `E6 FA 07 EA 0A 0C 00 00` |
| Sync SpO2 | `34 FA` → `34 FA 07 EA 0A 0D 0F 00 62 63 61 62 FF FF FF FF FF FF FF FF` → `34 FA FD E7` (XOR byte 2..19 = `E7`) |

---

## 8. Pseudo-code: connect + bind + pin + HR

```kotlin
val SVC   = uuid16(0x55FF); val WR = uuid16(0x33F1); val NT = uuid16(0x33F2)
val SVC5  = uuid16(0x56FF); val WR5 = uuid16(0x34F1); val NT5 = uuid16(0x34F2)

suspend fun connectGloryFit(dev): Session {
    gatt = dev.connectGatt(autoConnect = false, transport = LE)       // chờ STATE_CONNECTED
    delay(800); gatt.discoverServices()                                // thử lại ≤3 lần
    require(gatt.has(SVC))                                             // không có ⇒ không phải UTE
    delay(200)
    enableNotify(NT)                                                   // CCCD 01 00
    if (gatt.has(SVC5)) enableNotify(NT5)
    val f = parseFeatures(read(WR))                                    // 20 B ⇒ F1..F7
    var maxLen = 20
    if (gatt.has(SVC5)) { val b = read(WR5); maxLen = (b[0] shl 8) or b[1]; f += parseFeatures5(b) }
    val mtu = requestMtu(247); maxLen = min(maxLen.takeIf{it>0} ?: 244, mtu - 3)

    // ---- bind ----
    when {
        f.F1 has 0x000001 -> {                                         // mã 4 số
            if (savedCode == null) {
                send(byteArrayOf(0xD5, 0x02))
                expect(0xD5)                                            // D5 02: đồng hồ hiện mã
                savedCode = ui.askUserFor4Digits()
            }
            val k = "UTE8".toByteArray()
            send(byteArrayOf(0xD5, 0x01) + savedCode.mapIndexed { i, c -> c.code xor k[i] })
            when (expect(0xD5)[1]) { 0x01 -> ok; 0x03 -> timeout; 0xFF -> { savedCode = null; retry } }
        }
        f.F10 has 0x080000 -> {                                        // account id
            val id = savedId ?: Random.nextInt(1, 99_999_999).also { savedId = it }
            send(byteArrayOf(0x33, 0x02) + id.toBigEndian4())
            loop { val r = expect(0x33, sub = 0x04, timeout = 60.s)
                   when (r[2]) { 1 -> break                             // đã xác thực
                                 2 -> persist(id)                       // chờ tiếp
                                 3, 4 -> ui.show("Xác nhận trên đồng hồ")
                                 5 -> fail("Người dùng từ chối") } }
        }
        else -> Unit
    }

    // ---- handshake tối thiểu ----
    send(A3 + year.toBE2() + month + day + hour + min + sec); expect(0xA3)
    send(byteArrayOf(0xA1)); firmware = ascii(expect(0xA1).drop(1))
    send(A9 + userInfo18())                    ; expect(0xA9)
    return session
}

suspend fun battery(): Int { send(byteArrayOf(0xA2)); return min(expect(0xA2)[1].u8, 100) }

fun measureHeartRate(): Flow<Reading> = flow {
    send(byteArrayOf(0xE5, 0x11))
    notifications(NT).filter { it[0] == 0xE5 }.collect { p ->
        when {
            p.size == 2 && p[1] == 0x11 -> emit(Reading(HEART_RATE, MEASURING))
            p.size == 2 && p[1] == 0xFD -> { emit(Reading(HEART_RATE, ERROR)); stop() }
            p.size >= 4 -> {
                val valid = p[2] == 0; val bpm = p[3].u8; val done = p[1] == 0
                if (valid && bpm > 0) emit(Reading(HEART_RATE, if (done) OK else MEASURING, bpm))
                if (done) stop()
            }
        }
    }
}.onCompletion { send(byteArrayOf(0xE5, 0x00)) }                       // luôn dừng đo
```

Lưu ý triển khai: ghi tuần tự (chờ `onCharacteristicWrite`), timeout 3 s mỗi lệnh, mọi gói gửi ≤ `maxLen`.

---

## 9. Độ tin cậy và việc cần kiểm chứng trên Y25_6E1B

| Mục | Độ tin cậy |
|---|---|
| Vendor UTE, không phải QRing | Cao (đọc trực tiếp) |
| UUID 55FF/33F1/33F2, 56FF/34F1/34F2 | Cao |
| Khung gói opcode-first, không checksum | Cao |
| Luồng bind D5 / 33 | Cao về byte; **chưa biết Y25 dùng luồng nào** — phụ thuộc bit F1 `0x1` / F10 `0x80000` |
| Layout lịch sử B2/B3/E6/F7/34 | Cao (từ parser); ví dụ giá trị là giả định |
| Mẫu quảng bá `xx 55` = UUID 16-bit | Trung bình (suy luận) |

Cần chụp trên thiết bị thật: (1) gói quảng bá thô; (2) danh sách service; (3) 20 byte đọc từ `33f1` và `34f1`;
(4) phản hồi `A1` (chuỗi firmware); (5) gói đồng hồ trả về sau `33 02 …` hoặc `D5 02`.

---

## 10. Kiểm chứng trên Y25 thật (2026-10-13, driver `sdks/gloryfit`)

| Mục | Kết quả |
|---|---|
| Tên BLE / MAC | `Y25(ID-6E1B)` / `78:02:B7:03:6E:1B`. Mẫu tên `<model>(ID-<4 hex cuối MAC>)`; app GloryFit hiển thị đúng tên này |
| Quảng bá | Không thấy khi điện thoại có app GloryFit đang giữ kết nối. Sau khi tắt GloryFit, quét thấy ngay (-52 dBm) |
| Firmware (`A1`) | `RB370L73ACV001205` |
| Pin (`A2`) | `A2 5E` = 94 % |
| Bảng tính năng `33F1` | `08 88 6C 2A 01 24 39 43 75 6E DF FE D9 21 00 5D 78 5B A0 DC` (F1 = `0x5BA0DC`, F2 = `0x005D78`, F5 = `0x243943`) |
| Bảng `34F1` | `00 F4 …` maxLen 244; F10 = `0x050000` |
| Bind | F1 bit 0 = 0 và F10 `0x080000` = 0 nên **không cần bind**. Kết nối xong là dùng được |
| Khả năng | Bước, nhịp tim, huyết áp, SpO2, ngủ (không nhiệt độ, stress, HRV) |
| Đặt giờ / đơn vị / user info | `A3 …`, `A0 01 01`, `A9 …`: đồng hồ phản hồi lại cùng opcode (`A9` trả 1 byte) |

**Quan trọng:** trước khi gửi `A0` (đơn vị) và `A9` (thông tin người dùng), đồng hồ **không trả lời `E5 11`**. Sau khi gửi hai lệnh này thì `E5 11` được nhận và trả `E5 11 00 00` (đang đo). Đồng hồ cũng tự đẩy `F7 04 07 EA 0A 0D 11 2A 53 53 53` (thống kê HR trong ngày: 83/83/83). Driver vì thế luôn gửi `A0` + `A9` trong lúc kết nối.

Lịch sử:
- `F7 FA` → `F7 07 EA 0A 0D 12 FF FF FF FF FF FF FF FF 53 FF FF FF` (HH = 18, ô byte 14 = 17:30 → 83 bpm) → kết thúc `F7 FD 54` (có thêm 1 byte sau FD).
- `34 FA` → chỉ `34 FA FD 00` (chưa có SpO2).
- `B2 FA`, `B3 FA` → không có gói nào trong 5 s (đồng hồ mới ghép lần đầu, chưa có dữ liệu).

---

## 11. HT43 (2026-10-14)

| Mục | Kết quả |
|---|---|
| Tên BLE / MAC | `HT43(ID-2750)` / `78:02:B7:05:27:50` |
| Firmware (`A1`) | `RH370L73ACCV000788` (Y25: `RB370L73ACV001205`) |
| Pin (`A2`) | `A2 2D` = 45 % |
| Bảng tính năng `33F1` | `08 88 6C 2A 01 24 39 43 75 6E DF FE D9 21 00 5D 78 4B A1 DC`. Khác Y25 ở F1: `0x4BA1DC` (Y25 `0x5BA0DC`): **không có huyết áp** (`0x100000`), có bước tách chạy/đi (`0x000100`) |
| Bảng `34F1` | Giống Y25 (`00 F4 …`, maxLen 244) |
| Bind | Không cần (giống Y25) |
| `26 01` | `26 01 FF FF FF FF 01 D2 01 D2 00 00 10 00 00 02 01 00 00 00`: giống hệt Y25 (466 × 466, tròn, 1 MB, level 2, 1 khe) |
| Gói tự đẩy | `34F2`: `01 E9 AC 03 01 02` mỗi 60 s. Trong GloryFitPro (`uterkif/uterkcase.java`, lệnh `0x01E9`, mã `0xAC03`) là **đồng hồ xin dữ liệu AGPS (ephemeris)**, giá trị `02`. App GloryFit cũ không có nhánh này |
| Nhịp tim | 33F1 byte 15 bit 6 (`isHas24HourHRM`) = 1 và 34F1 byte 8 bit 7 (`isHasHRMTimedMeasurement`) = 0, giống Y25. SDK iOS chặn `D6 01`/`E5 11` với cờ này; HT43 không trả lời `E5 11`. Driver (Android + iOS) bật `F7 01`, đặt chu kỳ `F7 09 01 00 05` (5 phút) và lấy nhịp tim từ `F7 03` (đo định kỳ) và `F7 0B YYYY MM DD hh mm rr` (đo trên đồng hồ), xem 09-ios-gloryfit-app §2, §8. **Chưa kiểm chứng trên HT43** |
| Cài mặt đồng hồ | **Được** (Peacock 3D 1 MB, 2 phút 45 s). Trước đó luôn bị huỷ `26 03 01` giữa chừng vì luồng ghi đứng ~5 s do đọc RSSI chung hàng đợi GATT; HT43 không chịu khoảng đứng này (02-watchface §5 bước 9) |

GloryFitPro 1.9.0.2 (`com.yc.gloryfitpro`, giải nén ở `research/xapk-pro`) dùng SDK mới `com.yc.utesdk` (kèm `nadalsdk`, `rksdk`, luồng ACTS `01 E3/E4`).
Luồng mặt đồng hồ `26 01/02/03` + gói `27` trong SDK mới **giống hệt** app cũ: cùng khối 4 KB, chờ 5 s, nghỉ 20 ms/10 gói, 100 ms/gói khi
bị gửi lại > 2 lần, gặp `26 03 01/02` thì dừng (`uterkif/uterkthis.java:2371`, `com/yc/utesdk/watchface/close/uterkelse.java`).
Khác biệt đáng kể với HT43 là phần GPS/AGPS (`01 E9 …`), mà đồng hồ này cần.

