# 01 — Tầng kết nối / transport (QRing / Yawell / Colmi ring)

> Nguồn: APK QRing 1.0.1.180, decompile bằng jadx.
> Mọi trích dẫn `file:dòng` đều tính từ gốc
> `sdks/qring/research/jadx-out/sources/` (ví dụ `com/oudmon/ble/base/bluetooth/BleBaseControl.java:708`).
> Vendor SDK: `com/oudmon/ble/**`. Code app gọi SDK: `com/qcwireless/smart/**`.
> Một số lớp app bị obfuscate và nằm lẫn trong namespace `com/realsil/sdk/bbpro/**`
> (ví dụ click handler `com/realsil/sdk/bbpro/la/n.java`).
> Phần nào là suy luận (không đọc trực tiếp từ code) được đánh dấu **(suy luận)**.

---

## 0. Tóm tắt nhanh

| Hạng mục | Giá trị |
|---|---|
| GATT service chính | `6e40fff0-b5a3-f393-e0a9-e50e24dcca9e` |
| Write (lệnh 16 byte) | `6e400002-…` — **Write With Response** (`WRITE_TYPE_DEFAULT`=2) |
| Notify (phản hồi 16 byte) | `6e400003-…` |
| Service "serial port" (big data) | `de5bf728-d711-4e47-af26-65e3012a5dc7` |
| Write big data | `de5bf72a-…` — **Write Without Response** (`WRITE_TYPE_NO_RESPONSE`=1) |
| Notify big data | `de5bf729-…` |
| Device Info | `180A` → đọc `2A27` (HW rev) rồi `2A26` (FW rev) |
| connectGatt | `autoConnect=false`, `transport=TRANSPORT_LE (2)` |
| MTU | **Không gọi `requestMtu`** trong SDK/app; độ dài gói big-data mặc định 20, ring có thể báo qua notify `0x2F` |
| Connection priority | **Không gọi** `requestConnectionPriority` |
| Bond | Không bắt buộc. Chỉ `createBond()` nếu ring báo `supportBlePair` (CMD 0x3C) |
| Frame 16 byte | `[cmd][14 byte payload][checksum = sum(byte0..14) & 0xFF]` |
| Frame big data | `BC [cmd] [len LE16] [CRC16/MODBUS LE16] [payload…]`, cắt thành chunk ≥20 byte |
| Handshake app | CCCD 6e400003 → đọc 2A27/2A26 → (ready) → CCCD de5bf729 → 0x03 → 0x01 SetTime → 0x04 → 0x3C → các lệnh đọc cài đặt |

---

## 1. Scan / phát hiện thiết bị

### 1.1 Scanner của SDK

- Chỉ có 1 implementation: `BluetoothScannerImplLollipop` (API 21+), tạo qua
  `BleScannerCompat.getScanner()` (`com/oudmon/ble/base/scan/BleScannerCompat.java:13-21`).
- `ScanSettings` phụ thuộc foreground/background
  (`com/oudmon/ble/base/scan/BluetoothScannerImplLollipop.java:68-82`):
  - **Foreground**: không filter, `SCAN_MODE_LOW_LATENCY` (2).
  - **Background**: filter `ServiceUuid = 0000fee7-0000-1000-8000-00805f9b34fb`,
    `SCAN_MODE_LOW_POWER` (0), `MATCH_MODE_AGGRESSIVE` (1),
    `CALLBACK_TYPE_ALL_MATCHES` (1). ⇒ Ring quảng bá service UUID 16-bit `FEE7`
    (UUID của WeChat/AirSync) **(suy luận: ít nhất một phần dòng ring có FEE7 trong adv)**.
- Timeout scan: 12 000 ms (`BleScannerHelper.java:29`, `:147`, `:165`).
- `scanTheDevice(ctx, mac, cb)` (`BleScannerHelper.java:151-220`) dùng cho reconnect:
  so khớp **MAC** (`equalsIgnoreCase`) ở `onLeScan`/`onBatchScanResults`; khi
  scan dừng, nếu MAC có trong danh sách system-bonded cũng coi là "tìm thấy"
  (`:202-216`).

### 1.2 Lọc theo tên (prefix)

Có **ba** danh sách prefix:

1. **Danh sách app dùng để hiện thiết bị trong màn Bind** — lưu ở pref
   `com.qc.app_scan_config`, có thể được **server cập nhật** (`MainActivity$deviceScanConfig$1.java:40-58`,
   `DeviceBindViewModel.java:257-267`). Giá trị mặc định hard-code:
   - `QCApplication.java:150`:
     `R01,R02,R03,VK-5098,MERLIN,Hello Ring,RING1,boAtring,R04,R05,R06,R11,DS1314,DS520,DS12`
   - `QCApplication.java:368` (lúc khởi tạo app): như trên + `H59`.
   - `DeviceBindActivity.java:404`: như trên + `Y25`, `H59`.
   - `DeviceBindActivity.java:416` (chế độ "scan band"): `Y25,H59,DS1314,DS520,DS12`.
   - Luôn được thêm: `DS1314, DS520, DS12` (`DeviceBindViewModel.java:50`, `:286`)
     và `H59` (`QJavaApplication.java:72`).
   - Fallback nếu pref rỗng: `O_` (`QJavaApplication.java:54`, `:66`).

   Cách so khớp (`DeviceBindViewModel.java:68-128`): duyệt từng tiền tố của
   tên (`name[0..i]`), nếu tiền tố đó **trùng chính xác** một khóa trong map
   ⇒ chấp nhận. Tức là "tên bắt đầu bằng một prefix trong danh sách".
   Không có ngưỡng RSSI; danh sách chỉ được **sắp xếp giảm dần theo RSSI**
   (`DeviceBindActivity$setupViews$2$1$invoke$$inlined$sortByDescending$1.java:13-17`).
   Thiết bị đã bond trong hệ thống và khớp prefix cũng được thêm với RSSI giả 90
   (`DeviceBindViewModel$addSystemBondedDevice$bondDevices$1.java:70`).

2. **`BleScannerHelper.filterResult()`** (`BleScannerHelper.java:27`, `:35-57`) — chỉ
   dùng trong `removeSystemBle()` để quyết định gỡ bond:
   - trả 2: tên bắt đầu `O_` / `o_` hoặc một prefix trong `setScanFilter(list)`.
   - trả 3: `Q_`, `q_`, `R3L`, `QC`, `qc`, `Wa`.
   - trả 1: `sFILTER_PREFIX = {T80, T90, T91, T93, T95, TW68, S9, C60, C66, C67, C68, C80, C86, C88, C96, wxb_w4}`.

3. Mảng `f` trong `DeviceBindViewModel.java:157` (trùng `sFILTER_PREFIX`, không thấy dùng).

**Danh sách đầy đủ mọi prefix gặp trong code**: `R01, R02, R03, R04, R05, R06, R11,
VK-5098, MERLIN, Hello Ring, RING1, boAtring, Y25, H59, DS1314, DS520, DS12, O_, o_,
Q_, q_, R3L, QC, qc, Wa, T80, T90, T91, T93, T95, TW68, S9, C60, C66, C67, C68, C80,
C86, C88, C96, wxb_w4`. (Server có thể bổ sung thêm khi chạy.)

### 1.3 Service UUID trong advertisement → "typeDevice"

`DeviceBindViewModel.java:77-115` lấy `scanRecord.getServiceUuids()`, lấy 16 bit
`(msb >> 32) & 0xFFFF` dạng hex và so chuỗi:

| UUID 16-bit trong adv | typeDevice | Ý nghĩa khi bind (`com/realsil/sdk/bbpro/la/n.java:703-733`) |
|---|---|---|
| `FEE7` hoặc `FE00` | 1 **(suy luận — vòng lặp bị jadx dịch sai)** | `deviceNoScreen = true` (ring không màn hình) |
| `FE01` | 3 | `bodyTag = true` |
| `FE02` | 4 | `earStud = true` (khuyên tai) |
| (không khớp) | 0 | — |
| — | 5 | `smartCard = true` (không thấy nguồn gán từ adv) |

Không đọc manufacturer data; không parse MAC từ adv (MAC lấy từ
`BluetoothDevice.getAddress()`). Lớp `ScanRecord` của SDK chỉ là bản copy parser
Android, `onParsedData` của app để trống (`DeviceBindViewModel.java:131-132`).

### 1.4 Bind (người dùng chọn thiết bị)

`com/realsil/sdk/bbpro/la/n.java:682-740`: lưu MAC/tên vào `UserConfig`, đặt
timeout UI 10 s, rồi `BleOperateManager.connectDirectly(mac)` ⇒
`BleBaseControl.connect(mac)`.

---

## 2. Luồng kết nối GATT

### 2.1 `BleBaseControl.connect()` (`com/oudmon/ble/base/bluetooth/BleBaseControl.java:670-728`)

1. Bỏ qua nếu BT tắt / MAC rỗng / đang connecting hoặc đã connected.
2. Đặt **watchdog 40 s** (`mTimeoutRunnable`, `:687-688`): nếu không có bất kỳ
   `onConnectionStateChange` nào ⇒ `disconnectDevice` + broadcast `BLE_NO_CALLBACK` (`:76-88`).
3. Dừng scan, tăng `mGattGeneration` (bảo vệ callback cũ).
4. `remoteDevice.connectGatt(ctx, false, callback, 2)` (`:708`)
   ⇒ **autoConnect = false, TRANSPORT_LE**. Không chỉ định PHY.

### 2.2 `onConnectionStateChange` (`BleBaseControl.java:174-276`)

- `status != 0` hoặc `newState == DISCONNECTED` ⇒ gỡ gatt khỏi map và
  `scheduleGattClose` (sau 500 ms gọi `BluetoothGatt.refresh()` qua reflection
  rồi `close()`, `:557-619`, `:861-876`).
- Mọi callback đều hủy watchdog 40 s / discovery timeout và **xóa hàng đợi
  big-data** `BleThreadManager.clean()` (`:205-207`).
- **status ≠ 0 (lỗi GATT, vd 133)** (`:208-223`): nếu `rtkBindTag == false` thì
  **gọi `removeBond()`** (reflection, `:907-929`) — tức là SDK chủ động *gỡ bond*
  khi lỗi trước khi nhận được phản hồi SetTime (xem 7.2). `failCount++`, sau
  **2000 ms** gọi `reconnectDevice()` (`:107-120`).
- **DISCONNECTED (status 0)** (`:224-235`): `reconnectDevice()` ngay.
- **CONNECTED** (`:238-272`):
  1. `waitFor(500 ms)` (`:240`).
  2. `discoverServices()`; nếu `false` thì chờ 1000 ms thử lại 1 lần, vẫn lỗi ⇒ disconnect (`:242-256`).
  3. Discovery timeout **40 s** (`:244`, runnable `:69-75`).
  4. Đặt `mIsConnected = true`, reset `count`/`failCount`, broadcast `BLE_GATT_CONNECTED` (`:257-271`).
     (Lưu ý: "connected" được set **trước** khi discovery xong.)

### 2.3 `onServicesDiscovered` (`BleBaseControl.java:311-328`)

Lỗi ⇒ disconnect. OK ⇒ log toàn bộ service, gọi
`BleOperateManager.bleServiceDiscovered()` (`com/oudmon/ble/base/bluetooth/BleOperateManager.java:247-258`):

| Thời điểm (sau discovery) | Hành động |
|---|---|
| t = 0 | `enableUUID()` — bật notify **6e400003** (CCCD = `01 00`) (`:322-334`). Nếu callback chưa xóa, sau 4 s chạy lại (`runnableEnable`, `:90-106`). |
| t = 500 ms | `runCommonCmd()`: **Read 2A27 (HW rev)**, rồi **Read 2A26 (FW rev)** (`:139-142`). |
| t = 1000 ms, 1500 ms | Lặp lại `runCommonCmd()` (retry; bị hủy khi `setReady`) (`:256-257`, `:505-506`). |

Khi app nhận `onCharacteristicRead(2A27)` ⇒ `BleOperateManager.setReady(true)`
(`com/qcwireless/smart/ui/base/receiver/MyBluetoothReceiver.java:268-280`).
`setReady` (`BleOperateManager.java:505-520`) đặt cờ `ready` và **2500 ms sau**
broadcast `BLE_SERVICE_DISCOVERED` ⇒ app bắt đầu handshake (mục 4).

> **Quan trọng**: trước khi `ready = true`, mọi `WriteRequest` (cả 6e400002 lẫn
> de5bf72a) bị `execute()` từ chối (`BleOperateManager.java:345-347`). Read và
> enable-notify không bị chặn. Đây là ràng buộc *phía SDK*, không phải của ring
> **(suy luận: ring không yêu cầu đọc 2A27 trước khi nhận lệnh)**.

### 2.4 Thứ tự bật notification

1. `6e400003` (service 6e40fff0) — SDK, ngay sau discovery.
2. `de5bf729` (service de5bf728) — app gọi `LargeDataHandler.initEnable()` trong
   `onServiceDiscovered` (`MyBluetoothReceiver.java:298`;
   `com/oudmon/ble/base/communication/LargeDataHandler.java:83-92`, `:587-590`).
   Nếu `writeDescriptor` trả `false` thì tự retry (`:85-91`).

`EnableNotifyRequest` (`com/oudmon/ble/base/request/EnableNotifyRequest.java:28-60`):
`setCharacteristicNotification(true)` rồi ghi CCCD `0x2902` = `01 00`
(`ENABLE_NOTIFICATION_VALUE`). Không dùng indication. Không bật notify cho 180A.

### 2.5 MTU / connection priority / PHY

- `grep requestMtu / requestConnectionPriority / setPreferredPhy` trong
  `com/oudmon` và `com/qcwireless`: **không có**. `onMtuChanged` chỉ log (`BleBaseControl.java:298-301`).
- Chỉ thư viện OTA Realtek (`com/realsil/sdk/core/bluetooth/connection/le/BluetoothGattClientImpl.java:363`)
  gọi `requestMtu(256)` trên kết nối OTA riêng của nó.
- Kích thước chunk big-data lấy từ `JPackageManager.getLength()` = `max(mLength, 20)`,
  mặc định 20 (`com/oudmon/ble/base/communication/JPackageManager.java:6`, `:25-31`).
  Giá trị chỉ thay đổi khi ring gửi notify **CMD 0x2F (47)** trên kênh 16 byte:
  `PackageLengthListener` đặt `length = max(payload[0], 20)`
  (`com/oudmon/ble/base/communication/responseImpl/PackageLengthListener.java:12-16`,
  `com/oudmon/ble/base/communication/rsp/PackageLengthRsp.java:8-11`,
  đăng ký ở `BleOperateManager.java:112`). App không bao giờ gửi request 0x2F
  ⇒ ring tự đẩy **(suy luận: khi ring biết ATT MTU)**.
  Lưu ý payload[0] chỉ 1 byte ⇒ tối đa 255.

  Khuyến nghị cho app bên thứ ba **(suy luận)**: tự `requestMtu(…)` (vd 247) sau
  khi connect, rồi chunk theo `min(ATT_MTU-3, giá trị 0x2F nếu có)`; nếu không
  chắc chắn thì dùng 20 byte như SDK.

### 2.6 Reconnect

Tham số: `maxReconnect = 10`, `maxFail = 6` (`BleBaseControl.java:60-61`).

- `reconnectDevice()` (`:505-536`): dừng nếu `isNeedReconnect=false`, BT tắt,
  hoặc `failCount ≥ 6`; nếu đang scan thì thôi; còn lại gọi `doConnectClone()`.
- `doConnectClone()` (`:421-452`): **foreground** ⇒ scan tìm MAC (12 s) rồi
  connect sau 200 ms; **background** ⇒ `doConnect()`.
- `doConnect()` (`:384-418`): nếu `count % 3 == 0` ⇒ **connect trực tiếp** sau
  1000 ms; ngược lại scan-rồi-connect. Không thấy ⇒ `count++` và lặp.
- `mReconnectRunnable` (`:89-102`): dừng khi `count ≥ 10`.
- Mức app:
  - `WorkThread` (`com/qcwireless/smart/ui/base/thread/WorkThread.java:37-73`):
    khi mất kết nối, ngủ `N` giây (N tăng dần 1 mỗi vòng, tối đa 120) rồi
    `connectWithScan(mac)`; vượt 120 thì mỗi 300 s thử một lần.
  - Về foreground: gửi 0x03 (pin) nếu đang nối, nếu không thì `connectDirectly`
    (`com/qcwireless/smart/base/lifecycle/QcLifeCycle.java:60-90`).
  - `ACL_DISCONNECTED` của MAC đã bind ⇒ hẹn reconnect sau 22 s
    (`com/qcwireless/smart/ui/base/receiver/BluetoothReceiver.java:512-531`).
  - `KEY_MISSING` (mất khóa bond) ⇒ tạm ngừng tự động re-pair/reconnect với MAC đó (`BluetoothReceiver.java:490-510`).

Ngắt chủ động / unbind: `BleOperateManager.unBindDevice()` = `setNeedConnect(false)`
+ `disconnect()` + xóa MAC (`BleOperateManager.java:531-535`).

### 2.7 Bond / pairing

- **Không bond khi connect**. `connectGatt` không có `createBond` trước.
- `BleBaseControl.bleCreateBond()` (`:632-645`): chỉ `createBond()` nếu
  bondState = NONE (10) và MAC chưa nằm trong `getBondedDevices()`. App gọi
  hàm này **chỉ khi** CMD 0x3C trả `supportBlePair` (byte1 bit3)
  (`DeviceCmdInit$initDeviceSetting$1.java:377-416`).
- Gỡ bond tự động khi lỗi GATT trước khi có `rtkBindTag` (mục 2.2).
- Bond classic BT cho đồng hồ có nhạc (mục 6): `createBondBlueTooth()` (`:749-768`)
  hoặc `createBond(device, 1)` qua reflection (transport BR/EDR, dùng cho JieLi)
  (`:731-746`, `BleOperateManager.java:297-299`).

---

## 3. Hàng đợi ghi (write queue) và khớp phản hồi

### 3.1 Hàng đợi GATT chung — `BleOperateManager.execute()` (`BleOperateManager.java:337-380`)

- `BleOperateManager` là một `HandlerThread` ⇒ **một luồng worker tuần tự**.
- Mỗi request (`WriteRequest`, `ReadRequest`, `EnableNotifyRequest`, `ReadRssiRequest`)
  được `post` vào worker; worker gọi API GATT rồi **block** trên `mLock` cho tới
  khi có callback: `onCharacteristicWrite`, `onCharacteristicRead`,
  `onDescriptorWrite/Read`, `onReadRemoteRssi`, hoặc disconnect ⇒ `notifyLock()`
  (`:190-215`, `:230-239`, `:430-451`).
  ⇒ **Pacing = một thao tác GATT tại một thời điểm, chờ callback**. Không có
  `sleep` cố định giữa các gói.
- Timeout chờ: `postDelayed(runnable, OUTPUT_PERIOD_FAST)` = **5000 ms**
  (`:348`; hằng số `com/google/android/gms/location/DeviceOrientationRequest.java:23`).
  **(suy luận)** runnable này được post vào *chính* worker đang block nên thực tế
  không chạy được khi đang chờ; chỉ disconnect mới giải phóng.
- Characteristic được cache theo UUID sau lần tìm đầu (`BleBaseControl.java:794-804`);
  cache xóa khi connect lại (`:238`).

### 3.2 Kiểu ghi

`WriteRequest.execute()` (`com/oudmon/ble/base/request/WriteRequest.java:28`):
`setWriteType(noRsp ? 1 : 2)`.

| Kênh | Tạo bởi | Kiểu ghi |
|---|---|---|
| `6e400002` (lệnh 16 byte) | `CommandHandle.getWriteRequest` → `new LocalWriteRequest` (`com/oudmon/ble/base/communication/CommandHandle.java:33-37`) | **With response** (2) |
| `de5bf72a` (big data / DFU / file) | `WriteRequest.getNoRspInstance` (`LargeDataHandler.java:250-255`, `BleConsumer.java:37-41`, `DfuHandle.java:106-110`) | **Without response** (1) |

Kể cả write-without-response vẫn chờ `onCharacteristicWrite` (Android vẫn gọi
callback) trước khi gửi gói kế ⇒ flow-control tự nhiên.

### 3.3 Frame lệnh 16 byte (`BaseReqCmd`)

`com/oudmon/ble/base/communication/req/BaseReqCmd.java:15-32`:

```
byte[16]:
  [0]      = cmd (key)
  [1..14]  = subData (tối đa 14 byte, phần thừa là 0x00)
  [15]     = checksum = (Σ byte[0..14]) & 0xFF
```

Phản hồi từ ring cùng định dạng, kiểm tra `QCDataParser.checkCrc`
(`com/oudmon/ble/base/bluetooth/QCDataParser.java:16-22`).
Bit 7 của `byte[0]` là **cờ lỗi** (`Constants.FLAG_MASK_ERROR = 0x80`,
`com/oudmon/ble/base/communication/Constants.java:115`): key dùng để tra =
`byte[0] & 0x7F`.

### 3.4 Khớp phản hồi với request

- `CommandHandle.executeReqCmd(req, cb)` (`CommandHandle.java:43-55`): lưu
  `LocalWriteRequest` vào `ConcurrentHashMap<Integer cmd, LocalWriteRequest>` với
  key = `cmd & 0x7F`. **Không có sequence id** — request mới cùng cmd ghi đè cũ;
  entry **không bị xóa** sau khi có phản hồi (chỉ xóa khi disconnect, `BleOperateManager.java:235-237`).
- Đường nhận (`com/oudmon/ble/base/bluetooth/QCBluetoothCallbackReceiver.java:18-23`):
  chỉ xử lý gói **đúng 16 byte** và checksum đúng (không kiểm UUID nguồn) →
  1. `parserAndDispatchReqData` (`QCDataParser.java:46-72`): nếu cmd có trong map
     request ⇒ `BeanFactory.createBean(cmd)` (`com/oudmon/ble/base/bluetooth/BeanFactory.java:51-165`)
     ⇒ `acceptData(byte[1..14])`. Nếu `acceptData` trả `true` ⇒ phản hồi nhiều gói,
     giữ lại chờ gói sau (`tempRspDataSparseArray`); `false` ⇒ gọi callback.
  2. Nếu không khớp ⇒ `parserAndDispatchNotifyData` (`QCDataParser.java:24-44`)
     cho các notify chủ động từ ring đã đăng ký (`BleOperateManager.java:110-114`):
     `0x02` camera, `0x1D` music, `0x2F` package length, `0x73` device notify,
     `0x78` sport notify.
- **Không có timeout phản hồi** ở tầng lệnh: nếu ring không trả lời, callback
  không bao giờ được gọi.
- `executeReqCmdNoCallback` (`CommandHandle.java:57-63`) — không đăng ký map.

### 3.5 Hàng đợi big-data — `BleThreadManager` / `BleConsumer`

- `LinkedBlockingDeque(20)` (`com/oudmon/ble/base/bluetooth/queue/BleThreadManager.java:13`);
  `addData` chỉ khi đang connected (`:42-52`), xóa khi trạng thái kết nối đổi (`BleBaseControl.java:207`).
- `BleConsumer` (thread riêng, `com/oudmon/ble/base/bluetooth/queue/BleConsumer.java:43-62`):
  lấy 1 `BleDataBean(data, subLength)`, cắt `data` thành các đoạn `subLength`
  byte và `execute()` từng đoạn (write-no-response lên `de5bf72a`). Các đoạn sau
  đó đi chung hàng đợi worker GATT ở 3.1. (Vòng lặp trong bản jadx bị dịch sai
  thành vòng vô hạn; ý đồ là `for (i=0; i*sub < len; i++)` **(suy luận)**.)

---

## 4. Handshake sau khi kết nối (trace từ app)

### 4.1 Trình tự thực tế của app QRing

```
GATT CONNECTED
 └─ +500 ms  discoverServices()
onServicesDiscovered (SDK, BleOperateManager.bleServiceDiscovered)
 ├─ t0       CCCD 6e400003 := 01 00
 ├─ +500 ms  READ 180A/2A27 (HW revision, ASCII)   ┐ lặp ở +1000, +1500 ms
 └─ +500 ms  READ 180A/2A26 (FW revision, ASCII)   ┘ đến khi setReady
onCharacteristicRead(2A27)  (app MyBluetoothReceiver:268-280)
 └─ setReady(true)  →  +2500 ms broadcast BLE_SERVICE_DISCOVERED
App onServiceDiscovered (MyBluetoothReceiver.java:288-319)
 ├─ CCCD de5bf729 := 01 00                (LargeDataHandler.initEnable)
 ├─ READ 2A27
 ├─ CMD 0x03  pin                         (SimpleKeyReq 3)
 ├─ READ 2A26
 └─ DeviceCmdInit.a()  (DeviceCmdInit.java:90-92 → DeviceCmdInit$initDeviceSetting$1.java)
     ├─ 0x01 SetTime(now + 1 s)            :146   → SetTimeRsp (capabilities)
     ├─ 0x04 BindAncs / phone OS (no cb)   :425
     ├─ 0x3C DeviceSupport (đọc)           :427   → DeviceSupportFunctionRsp
     ├─ 0x61 đọc message-push              :706
     ├─ 0x03 pin                           :707
     ├─ 0x16 HR setting đọc                :708
     ├─ 0x38 HRV setting đọc               :709
     ├─ 0x06 DND đọc                       :710
     ├─ 0x3B touch control đọc (01 01)     :711
     ├─ 0x36 stress setting đọc            :712
     ├─ 0x2C SpO2 setting đọc              :713
     ├─ 0x0C BP setting đọc                :714
     ├─ 0x05 palm-screen (ring: 03)        :715
     ├─ 0x19 degree switch đọc             :716
     ├─ 0x3A sugar/lipids đọc (03 01)      :717
     ├─ 0x21 target đọc                    :719
     └─ EventBus BluetoothSyncEvent → bắt đầu sync dữ liệu (:998-1000)
Sau khi nhận 0x3C:  0x0A TimeFormat đọc (:335); nếu supportBlePair → createBond (:377-416)
Sau khi nhận 0x01:  setRtkBindTag(true) (DeviceCmdInit$init$1$1.java:300)
```

Ghi chú:
- **CMD 16 (`CMD_BIND_SUCCESS`) và CMD 0x93 (`CMD_MSG_GET_HW_AND_FW_VERSION`, -109)
  được khai báo trong `Constants.java:12`, `:61` nhưng không được app/SDK gửi**
  (grep không thấy). Phiên bản FW/HW lấy từ 180A (2A26/2A27).
- `CMD_SET_PHONE_OS = 4` (`Constants.java:88`) chính là `BindAncsReq`.
- Toàn bộ lệnh trên chỉ chạy nếu `DeviceSetting` lấy từ DB khác null
  (`DeviceCmdInit$initDeviceSetting$1.java:131-133`).

### 4.2 Byte layout các lệnh handshake

Tất cả là frame 16 byte gửi lên **6e400002** (write with response). Ví dụ hex
được tính lại theo đúng công thức ở 3.3.

**CMD 0x01 — SetTime** (`com/oudmon/ble/base/communication/req/SetTimeReq.java:89-104`, `:66-71`)

```
[0]=01
[1]=BCD(year % 2000) [2]=BCD(month 1-12) [3]=BCD(day)
[4]=BCD(hour 0-23)   [5]=BCD(minute)     [6]=BCD(second)
[7]=language        (bảng :34-64: zh_CN=0, en=1, zh_HK/TW=2, el=3, fr=4, de=5,
                     it=6, es=7, nl=8, pt=9, ru=10, tr=11, ja=12, ko=13, pl=14,
                     ro=15, ar=16, th=17, vi=18, in=19, hi=20, cs=21, sk=22,
                     hu=23, iw=24, hr=25, sl=26, ur=35; mặc định 1)
[8..14]=00  [15]=checksum
```
Giờ là **giờ địa phương** của điện thoại; app gửi `now + 1 s` (`SetTimeReq(1)`).
Ví dụ 2025-01-15 10:30:45, tiếng Anh:
```
01 25 01 15 10 30 45 01 00 00 00 00 00 00 00 C2
```

**Phản hồi 0x01 — SetTimeRsp = bảng khả năng** (`com/oudmon/ble/base/communication/rsp/SetTimeRsp.java:48-96`).
`p[i]` = byte `i+1` của frame:

| p[] | Ý nghĩa |
|---|---|
| p0 | ==1: supportTemperature |
| p1 | ==1: supportPlate (watch face) |
| p2 | ==1: supportMenstruation |
| p3 | bit0 customWallpaper, bit1 bloodOxygen, bit2 bloodPressure, bit3 feature, bit4 oneKeyCheck, bit5 weather, bit6 **=0** ⇒ supportWeChat, bit7 avatar |
| p4..p5 | width (LE16) |
| p6..p7 | height (LE16) |
| p8 | ==1: newSleepProtocol (sleep qua big-data 0x27) |
| p9 | maxWatchFace |
| p10 | bit0 contact, bit1 lyrics, bit2 album, bit3 GPS, bit4 JieLiMusic, bit5 appMeasure, bit6 manualBloodOxygen, bit7 YaWei |
| p11 | bit0 manualHeart, bit1 eCard, bit2 location, bit4 music, bit5 **rtkMcu**, bit6 ebook, bit7 bloodSugar |
| p12 | maxContacts = p12*10 (0 ⇒ 20) |
| p13 | bit0 record, bit1 bpSetting, bit2 4G, bit3 navPicture, bit4 pressure, bit5 HRV |

**CMD 0x04 — BindAncs / Phone OS** (`com/oudmon/ble/base/communication/req/BindAncsReq.java:12-50`)

```
[0]=04 [1]=02 (Android — suy luận: 02 = Android)
[2]=OS code: SDK 28→09, SDK 26/27→08, còn lại (kể cả 29+) →0A
[3..]=Build.MODEL UTF-8 (cắt còn 13 byte; byte thứ 13 bị checksum đè ⇒ thực tế ≤12 ký tự)
[15]=checksum
```
Ví dụ model "Pixel 7": `04 02 0A 50 69 78 65 6C 20 37 00 00 00 00 00 69`.
Gửi bằng `executeReqCmdNoCallback` (không chờ phản hồi; BeanFactory cũng không có bean cho 0x04).

**CMD 0x3C — DeviceSupport (đọc)** (`req/DeviceSupportReq.java:5-11`): payload rỗng.
```
3C 00 00 00 00 00 00 00 00 00 00 00 00 00 00 3C
```
Phản hồi `DeviceSupportFunctionRsp.acceptData` (`com/oudmon/ble/base/communication/rsp/DeviceSupportFunctionRsp.java:70-154`),
`p[i]` = byte frame `i+1` (p0 bỏ qua):

| p[] | bit → cờ |
|---|---|
| p1 | b0 touch, b1 muslim, b2 appRevision, **b3 blePair**, b6 **deviceNoScreen**, b7 gesture |
| p2 | b0 ringMusic, b1 ringVideo, b2 ringEbook, b3 ringCamera, b4 ringPhoneCall, b5 ringGame, b6 heart |
| p3 | b0 skinTemperature, b2 longSit, b3 drink, b4 noSingleTemperature, b5 notification, b7 aiAnalyze |
| p4 | b3 ringGestureDND, b4 tpSleep, b5 rt11, b7 resumeServices |
| p5 | ≠0 ⇒ onlyTouch; b0..b6 phiên bản "Touch" của music/video/ebook/camera/phoneCall/game/heart, b7 muslim(Touch) |
| p6 | b2 unSupportTakePhoto, b3 loverSpace, b4 worship, b5 newPraise, b6 alarm, b7 doNotDisturb |
| p7 | b0 ultraviolet, b1 callReminder, b2 realTimeOxygen, b3 realTimeHr, b4 realTimeHrRemind, b5 friends, b6 loverInteract, b7 tempIntervalModify |
| p8 | b0 noScreenBand24Hour, b5 bodyTag, b6 tempReminder, b7 intervalTemp |
| p9 | b1 ECG, b2 tempBoth, b3 breathTraining, b4 audio, b5 meetingRecord, b6 bodyBattery, b7 **wifiImport** |
| p10 | b0 audioCoding, b3 opusAudio |

**CMD 0x03 — Battery** (`SimpleKeyReq(3)`): `03 00 … 00 03`.
Phản hồi (`rsp/BatteryRsp.java:9-13`): p0 = % pin, p1 == 1 ⇒ đang sạc.
Ví dụ 85 %: `03 55 00 00 00 00 00 00 00 00 00 00 00 00 00 58`.

**Các lệnh đọc cài đặt** (subData `01` = đọc; `02` = ghi):

| CMD | Lớp | Frame |
|---|---|---|
| 0x61 | `SetMessagePushReq` | `61 00…00 61` |
| 0x0A | `TimeFormatReq.getReadInstance` | `0A 01 00…00 0B` |
| 0x16 | `HeartRateSettingReq` | `16 01 00…00 17` |
| 0x38 | `HrvSettingReq` | `38 01 00…00 39` |
| 0x06 | `DndReq` | `06 01 00…00 07` |
| 0x3B | `TouchControlReq(false)` | `3B 01 01 00…00 3D` |
| 0x36 | `PressureSettingReq` | `36 01 00…00 37` |
| 0x2C | `BloodOxygenSettingReq` | `2C 01 00…00 2D` |
| 0x0C | `BpSettingReq` | `0C 01 00…00 0D` |
| 0x05 | `PalmScreenReq.getRingReadInstance` | `05 03 00…00 08` |
| 0x19 | `DegreeSwitchReq` | `19 01 00…00 1A` |
| 0x3A | `SugarLipidsSettingReq(3)` | `3A 03 01 00…00 3E` |
| 0x21 | `TargetSettingReq` | `21 01 00…00 22` |

(Chi tiết từng lệnh thuộc tài liệu command, không thuộc phạm vi tầng transport.)

### 4.3 Pseudo-code tối thiểu cho app bên thứ ba

```kotlin
val SVC      = UUID("6e40fff0-b5a3-f393-e0a9-e50e24dcca9e")
val WRITE    = UUID("6e400002-b5a3-f393-e0a9-e50e24dcca9e")
val NOTIFY   = UUID("6e400003-b5a3-f393-e0a9-e50e24dcca9e")
val BIG_SVC  = UUID("de5bf728-d711-4e47-af26-65e3012a5dc7")
val BIG_NTF  = UUID("de5bf729-d711-4e47-af26-65e3012a5dc7")
val BIG_WR   = UUID("de5bf72a-d711-4e47-af26-65e3012a5dc7")
val CCCD     = UUID("00002902-0000-1000-8000-00805f9b34fb")

fun frame(cmd: Int, sub: ByteArray = byteArrayOf()): ByteArray {
    val b = ByteArray(16); b[0] = cmd.toByte()
    sub.copyInto(b, 1, 0, minOf(sub.size, 14))
    b[15] = (b.take(15).sumOf { it.toInt() and 0xFF } and 0xFF).toByte()
    return b
}
fun bcd(v: Int) = (((v / 10) shl 4) or (v % 10)).toByte()

// 1. Scan: lọc tên theo prefix (R01..R11, RING1, …) hoặc theo MAC đã lưu.
// 2. Kết nối
gatt = device.connectGatt(ctx, /*autoConnect*/ false, cb, BluetoothDevice.TRANSPORT_LE)
// set watchdog 40 s; nếu hết hạn → disconnect + close

// 3. onConnectionStateChange(CONNECTED, status=0):
delay(500); gatt.discoverServices()      // watchdog discovery 40 s
//    status != 0 (vd 133) → close(), chờ ~2 s rồi thử lại (tối đa ~10 lần)

// 4. onServicesDiscovered → chạy tuần tự qua 1 hàng đợi GATT (chờ callback từng bước):
q.enableNotify(SVC, NOTIFY)                         // CCCD 01 00
q.requestMtu(247)          // (tùy chọn – SDK gốc KHÔNG làm; suy luận là an toàn)
q.read(0x180A, 0x2A27)                              // HW revision (chuỗi ASCII)
q.read(0x180A, 0x2A26)                              // FW revision
q.enableNotify(BIG_SVC, BIG_NTF)                    // nếu cần big-data

// 5. Handshake (write WITH response lên WRITE, chờ onCharacteristicWrite giữa các gói)
val t = Calendar.getInstance().apply { add(Calendar.SECOND, 1) }
q.write(WRITE, frame(0x01, byteArrayOf(
    bcd(t[YEAR] % 2000), bcd(t[MONTH] + 1), bcd(t[DAY_OF_MONTH]),
    bcd(t[HOUR_OF_DAY]), bcd(t[MINUTE]), bcd(t[SECOND]), /*lang en*/ 1)))
q.write(WRITE, frame(0x04, byteArrayOf(2, 10) + "MyPhone".toByteArray()))
q.write(WRITE, frame(0x3C))     // đọc capability
q.write(WRITE, frame(0x03))     // pin

// 6. onCharacteristicChanged:
//   uuid == NOTIFY && value.size == 16 && checksum ok:
//       key = value[0] & 0x7F ; isError = (value[0] & 0x80) != 0
//       route theo key (0x01 → SetTimeRsp capability, 0x3C → DeviceSupport, 0x03 → battery,
//       0x2F → packetLen = max(value[1] & 0xFF, 20), 0x73/0x78/0x02/0x1D → notify chủ động)
//   uuid == BIG_NTF  → bộ ghép gói big-data (mục 5)

// 7. Nếu DeviceSupport p1 bit3 (blePair) = 1 và chưa bond → device.createBond()
```

---

## 5. Service thứ hai `de5bf728` — kênh "serial port" / big data

### 5.1 Khi nào dùng

- Kênh 16 byte (6e40fff0) dùng cho lệnh/cài đặt ngắn và phần lớn sync dữ liệu
  cổ điển (step/HR/sleep cũ…).
- Kênh `de5bf728` dùng khi payload > 14 byte hoặc có cấu trúc dài. Các lớp dùng
  nó (grep `BleThreadManager|SERIAL_PORT`):
  - `LargeDataHandler` (`com/oudmon/ble/base/communication/LargeDataHandler.java:52-76`):

    | cmd | dec | Tính năng |
    |---|---|---|
    | 0x20 | 32 | Location (ring yêu cầu vị trí / app ghi vị trí) |
    | 0x27 | 39 | **Sleep giao thức mới** |
    | 0x28 | 40 | Danh sách HR đo tay |
    | 0x29 | 41 | Danh bạ (mới, nhiều gói ~950 byte) |
    | 0x2A | 42 | SpO2 |
    | 0x2C | 44 | Báo thức (mới) |
    | 0x2D | 45 | Danh bạ |
    | 0x2E | 46 | **MAC + tên Bluetooth classic** |
    | 0x2F | 47 | E-card / QR |
    | 0x3A | 58 | Custom watch face |
    | 0x3E | 62 | Sleep + ngủ trưa |
    | 0x47 | 71 | Đường huyết |
    | 0x48 | 72 | GPS navigation |
    | 0x49 | 73 | SpO2 đo tay |
    | 0x4A | 74 | Nickname/avatar thiết bị |
    | 0x5F | 95 | SpO2 theo chu kỳ |
    | 0x75 | 117 | HR theo chu kỳ |
    | 0x76 | 118 | Liên hệ khẩn cấp |
    | 0x77 | 119 | Nhiệt độ theo chu kỳ |
    | 0x78 | 120 | ECG đo đơn |
    | 0x91 | -111 | WiFi record transfer (ghi âm qua WiFi) |
  - File/firmware: `DfuHandle` (OTA non-Realtek, cmd 1..5), `FileHandle`,
    `EbookHandle`, `AlbumHandle`, `AvatarHandle`, `RecordHandle(V2)`,
    `TemperatureHandle`, `SportPlusHandle` (0x41/0x43), `BleMusicHandle`
    (cmd 0x31/0x32/0x33/0x80/0x81…).

### 5.2 Framing (`LargeDataHandler.addHeader`, `LargeDataHandler.java:186-199`; giống hệt ở `BleConsumer.java:22-35`, `DfuHandle.java:61-74`)

```
offset  size  value
0       1     0xBC                     (magic, -68)
1       1     cmd
2       2     len  = payload.length    (little-endian, DataTransferUtils.shortToBytes)
4       2     crc  = CRC16(payload)    (little-endian)
6       len   payload
```
- Payload rỗng ⇒ `len = 00 00`, `crc = FF FF`.
- CRC16 (`com/oudmon/ble/base/communication/utils/CRC16.java:7-19`): init `0xFFFF`,
  poly reflected `0xA001`, không XOR-out ⇒ **CRC-16/MODBUS** (check "123456789" = `0x4B37`).
- Little-endian: `com/oudmon/qc_utils/bytes/DataTransferUtils.java:56-58`.

Ví dụ:
```
Đọc báo thức (0x2C, payload 01):           BC 2C 01 00 7E 80 01
Sync sleep mới hôm nay (0x27, 00 01):       BC 27 02 00 C0 70 00 01
Đọc MAC classic BT (0x2E, payload 00):      BC 2E 01 00 BF 40 00
DFU start (cmd 1, payload rỗng):            BC 01 00 00 FF FF
```

### 5.3 Chunking / gửi

- Toàn bộ frame (header + payload) được cắt thành đoạn `JPackageManager.getLength()`
  byte (≥20) và ghi tuần tự **without response** lên `de5bf72a`
  (`BleConsumer.java:43-62`, `DfuHandle.java:134-142`). Không có header riêng cho
  từng chunk; chỉ chunk đầu có `BC`.
- Một số lệnh nhiều phần dùng sub-index trong payload (vd danh bạ `0x29`:
  `[tổng gói+1, index, …]`, `LargeDataHandler.java:764-813`; DFU: mỗi "big packet"
  1024 byte có `index LE16` đầu payload, `DfuHandle.java:117-131`).

### 5.4 Nhận / ghép gói (`com/oudmon/ble/base/bluetooth/LargeDataParser.java:33-69`)

```
on notify(uuid == de5bf729, data):
  if data.len >= 6 && data[0]==0xBC && !đang_ghép:
      dataLength = LE16(data[2..3])
      if data.len - 6 < dataLength: buf = data; đang_ghép = true; return
      dispatch(data)
  else:
      buf += data
      if buf.len - 6 == dataLength: dispatch(buf); đang_ghép = false; buf = []
dispatch(frame): handler = respMap[frame[1]] → handler.parseData(cmd, frame)  (frame đầy đủ, payload từ offset 6)
```
- Parser này **không kiểm CRC** khi nhận (chỉ `DfuHandle.checkTheData` có kiểm,
  `DfuHandle.java:77-90`).
- Điều kiện kết thúc là `== dataLength` (không `>=`), nên nếu lệch byte sẽ kẹt
  tới khi gặp lại gói bắt đầu bằng `BC` hợp lệ **(suy luận)**.
- Handler đăng ký theo cmd trong `respMap`; xóa khi disconnect
  (`QCBluetoothCallbackBigDataCloneReceiver.java:11-16`).
- Kênh 16 byte và kênh big-data đều đi qua cùng broadcast `BLE_CHARACTERISTIC_CHANGED`;
  receiver 16 byte chỉ xét gói đúng 16 byte (không kiểm UUID), receiver big-data
  lọc theo UUID `de5bf729`.

---

## 6. SPP / JieLi / Realtek classic BT (`com/oudmon/ble/base/bluetooth/spp`)

- `SerialSocket` (`spp/SerialSocket.java:15`, `:69-73`): RFCOMM
  `createRfcommSocketToServiceRecord(FE010000-1234-5678-ABCD-00805F9B34FB)` —
  UUID SPP của chip **JieLi**. Dùng bởi `SppHandle` (`spp/jieli/SppHandle.java:557-560`)
  cho truyền nhạc/ebook.
- `RtkSppConstants.sppUUID = 6A24EEAB-4B65-4693-986B-3C26C352264F`
  (`spp/RtkSppConstants.java:31`) — SPP của **Realtek** audio (`RtkMusicSpp`, dùng
  `com.realsil` LocalPlayback).
- `BleMusicHandle` (`spp/jieli/BleMusicHandle.java:277-280`, `:355`…) — đường nhạc
  JieLi **qua BLE big-data** (cùng framing `BC`).
- Kích hoạt (app, `com/qcwireless/smart/ui/base/receiver/BluetoothReceiver.java:444-482`, `:533-590`):
  khi Discovery classic tìm thấy MAC classic đã lưu (`UserConfig.c0`, pref
  `Action_Classic_Bluetooth_Mac`; **(suy luận)** lấy từ big-data `0x2E`):
  - `rtkMcu` (SetTimeRsp p11 bit5) ⇒ `connectRtkSPP`.
  - `musicSupport` (p11 bit4) và không JieLi ⇒ `connectRtkSPP`.
  - Không JieLi ⇒ `createBond()`; JieLi (p10 bit4) ⇒ `createBond(device, TRANSPORT_BREDR=1)`;
    bond xong ⇒ `SppHandle.connect()` (JieLi) hoặc `connectRtkSPP`.
- **Liên quan tới ring?** Hầu như không: các cờ này dành cho đồng hồ có loa/nhạc
  nội bộ. Ring không màn hình (deviceNoScreen) **(suy luận)** sẽ trả p10 bit4 = 0,
  p11 bit4/bit5 = 0 ⇒ toàn bộ nhánh SPP không chạy. Ngoại lệ có thể là ring có
  `supportAudio`/`meetingRecord` nhưng các tính năng đó đi qua BLE big-data/WiFi,
  không qua SPP.

---

## 7. Khác biệt giữa model / firmware ảnh hưởng tới kết nối

1. **Kích thước gói big-data** — mặc định 20; ring có thể đẩy `0x2F` để tăng
   (mục 2.5). Không có `requestMtu` ⇒ trên Android cũ ATT MTU=23 nên 20 là an toàn.
2. **`rtkBindTag`** — trước khi app nhận được phản hồi SetTime, mọi lỗi GATT
   (status ≠ 0) khiến SDK `removeBond()` thiết bị (`BleBaseControl.java:211-213`);
   sau phản hồi 0x01, app gọi `setRtkBindTag(true)` (`DeviceCmdInit$init$1$1.java:300`)
   để không gỡ bond nữa. Cờ này không reset khi ngắt kết nối.
3. **`supportBlePair`** (0x3C p1 bit3) ⇒ app tạo bond BLE sau handshake và cảnh báo
   người dùng nếu chưa bond (`DeviceCmdInit$initDeviceSetting$1.java:377-416`).
   Ring không có cờ này: không cần bond.
4. **typeDevice từ adv** (FEE7/FE00/FE01/FE02, mục 1.3) ⇒ deviceNoScreen / bodyTag /
   earStud; cùng các cờ đó cũng được ghi đè từ 0x3C sau khi kết nối.
5. **`newSleepProtocol`** (SetTimeRsp p8) ⇒ sleep đi qua big-data `0x27/0x3E` thay
   vì lệnh 16 byte `0x44` — nghĩa là thiết bị có cờ này **bắt buộc** phải bật notify
   `de5bf729`.
6. **Chip**: `rtkMcu` ⇒ OTA bằng thư viện Realtek (`com/realsil/sdk`, có `requestMtu(256)`);
   ngược lại OTA qua `DfuHandle` trên kênh big-data (cmd 1 start, 2 init
   `[01, size LE32, crc16 LE16, checksum LE16]`, 3 data, 4 check, 5 end;
   `DfuHandle.java:117-146`, `:239-272`).
7. **`supportWifiImport`** (0x3C p9 bit7): ring mở WiFi AP để tải file ghi âm.
   SSID do app tự suy ra = `<phần tên sau '_' (≤20 ký tự)>_<4 ký tự hex cuối của MAC, bỏ ':'>`,
   mật khẩu cố định `12345678` (`MyBluetoothReceiver.java:107-167`, dùng ở
   `com/qcwireless/smart/ui/mt/activity/g.java:208-214`); điều khiển qua big-data `0x91`.
8. **HW revision (2A27)** được app dùng để kiểm tra firmware/watch-face và cấu hình
   (`DeviceConfigEvent`, `MyBluetoothReceiver.java:268-279`) — chuỗi này là cách
   nhận diện model chính xác nhất sau khi kết nối **(suy luận)**.

---

## 8. Ghi chú/bẫy khi tự cài đặt

- Một hàng đợi GATT tuần tự là bắt buộc trên Android (SDK gốc làm vậy); đừng ghi
  liên tiếp khi chưa có `onCharacteristicWrite`.
- Lệnh 16 byte phải luôn đủ 16 byte, padding 0, checksum byte 15.
- Không có cơ chế request-id: nếu gửi hai lệnh cùng cmd liên tiếp, phản hồi chỉ
  phân biệt theo thứ tự đến.
- Nên tự thêm timeout phản hồi (SDK gốc không có), ví dụ 3–5 s **(suy luận)**.
- Sau disconnect: `close()` gatt (SDK đợi 500 ms và gọi `refresh()` qua reflection để
  xóa cache service — hữu ích nếu firmware đổi bảng GATT sau OTA).
- Reconnect: `autoConnect=false` + scan-theo-MAC/kết nối trực tiếp xen kẽ (mỗi lần
  thứ 3 kết nối trực tiếp), tối đa 10 lần, 6 lỗi liên tiếp thì dừng.
