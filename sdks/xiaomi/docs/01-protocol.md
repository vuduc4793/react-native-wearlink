# Xiaomi Wear protocol (Mi Band 8/9/10/11 class) — reverse từ Mi Fitness

Nguồn: jadx output của Mi Fitness. Mọi path dưới đây tương đối với thư mục `sources/`.
Mục đích: interoperability với Xiaomi Smart Band 11 của chính user. "chưa chắc" = chưa xác nhận trên thiết bị thật.

---

## 1. Kết nối vật lý: BLE GATT / SPP

### 1.1 GATT UUID

Base UUID `0000xxxx-0000-1000-8000-00805f9b34fb` (`defpackage/kch.a(int)`), hằng trong `defpackage/i73`:

| Hằng `i73` | 16-bit | Vai trò |
|---|---|---|
| `f17780a` (`MI_WEAR_SERVICE_UUID`) | **0xFE95** | Service chính |
| `f17781b` | 0x0050 | **Version char** (read): 3 byte `b0.b1.b2` → chọn V1/V2 |
| `c` | **0x0051** | Proto **RX / notify** (V1) |
| `d` | **0x0052** | Proto **TX / write** (V1) |
| `e` | 0x0053 | Fitness channel (type 102), write+notify cùng char |
| `f` | 0x0054 | Voice (type 103) |
| `g` | 0x0055 | Mass data (type 104) |
| `h` | 0x0056 | OTA RX/notify (type 105) |
| `i` | 0x0057 | OTA TX/write (type 105) |
| `l` | 0x005A | Sensor capture (type 107) |
| `f17783m` (`..._SAR_NOTIFY`) | **0x005E** | V2 (SAR) notify |
| `n` (`..._SAR_WRITE`) | **0x005F** | V2 (SAR) write |

- V1: `transport/queue/BleTaskQueueV1.initChannels()` (khi `getVersion()!=0`; version 0 thì UUID lấy từ `DeviceInfo.PrivateUUID` do server cấp). Kênh proto = `defpackage/hl7(svc, tx=0x52, rx=0x51)`.
- V2: `transport/queue/BleTaskQueueV2` (static init): service FE95, write 0x5F, notify 0x5E.
- CCCD chuẩn `00002902-...`. App xin MTU 512 nếu `DeviceExtKt.isSupportLargeMtu(model)` (mặc định true trừ `mijia.watch.band01/v1`).

### 1.2 Chọn transport

| Bước | Class/method | Điều kiện |
|---|---|---|
| BLE hay SPP | `com/xiaomi/wearable/core/server/ApiCallFactory.createApiCall` | `pd_type` ∈ {2 BLE_WATCH, 3 BLE_BAND, 4 ECG} hoặc `isLocalBindMode()` → BLE (`defpackage/ex1`); {6 DUAL_WATCH, 7 DUAL_BAND} → SPP (`defpackage/d0g`) |
| BLE V1 hay V2 | `defpackage/ex1.newTaskQueue()` | `versionName` (từ char 0x0050) bắt đầu "0" → `BleTaskQueueV1`, ngược lại `BleTaskQueueV2` |
| SPP V1 hay V2 | `defpackage/d0g.newTaskQueue()` | versionName bắt đầu "2"/"3" → `SppTaskQueueV2`, ngược lại V1 |

- `protocol version` (int) = `b0<<16 | b1<<8 | b2` của char 0x0050 (`defpackage/pn1`, `defpackage/zzh`). Version ≠ 0 ⇒ type 101 được mã hoá. Version > 1 ⇒ bật single-frame + multi-resend ở V1.
- Lưu ý: BLE manager thường `defpackage/pn1.getVersionName()` luôn trả `"0.0.0"` → trên điện thoại không phải MIUI **luôn V1** (0x51/0x52). MIUI system proxy (`defpackage/zzh`) dùng versionName thật → có thể V2. Band 11 dùng V1 hay V2 khi đi qua app thường: **chưa chắc** — đọc char 0x0050 để biết. Gadgetbridge chạy Band 8/9 qua 0x51/0x52 (V1).
- SPP UUID: `00001101-0000-1000-8000-00805F9B34FB` (`com/xiaomi/wearable/spp/a.SPP_UUID`, `SystemClient` dùng `createRfcommSocketToServiceRecord`). Band (pd_type 3) gần như chắc là BLE; SPP chỉ cho DUAL devices (chưa chắc cho Band 11 vì pd_type đến từ server).

### 1.3 Nhận diện khi scan

Không có Band 11 hardcode trong app — danh sách sản phẩm (`com/xiaomi/fitness/device/manager/bean/Product.java`: `blt_name`→`bltNamePrefix`, `pd_id`→`productId`, `model`, `pd_type`, `privateUUID`, `groupId`) tải từ server. Model string duy nhất thấy trong code: `miwear.watch.n66cn`, `miwear.watch.n66nfc`, `miwear.watch.m66`. Tên quảng bá / `pd_id` của Band 11: **chưa chắc** → bắt từ scan thật.

`com/xiaomi/fitness/device/manager/ui/scan/ScanManager.searchBleByNamePrefixOrMiBeacon` chạy 3 recognizer:

1. `recognize/NameRecognizer`: `name.startsWith(bltNamePrefix)`. Loại bỏ "unlock beacon" = service data (AD 0x16) UUID **0xFDAB** (`isUnlockBeacon`) — 0xFDAB là beacon mở khoá điện thoại, không phải quảng bá pairing.
2. `recognize/BeaconRecognizer`: MiBeacon trong service data AD 0x16, UUID **0xFE95** (u16 LE đầu). Layout (LE, `beacon/PacketReader`):

| Offset | Nội dung |
|---|---|
| 0 | frame ctrl lo: bit2 bondNew, bit3 encrypted, bit4 withMac, bit5 withCapability, bit6 withEvent, bit7 withMesh |
| 1 | frame ctrl hi: bit0 registered, bit1 bindingCfm, bit2-3 authMode, bit4-7 version |
| 2-3 | **productId** u16 LE (map sang `pd_id`) |
| 4 | frameCounter |
| tiếp | [withMac] 6 byte MAC đảo ngược; [withCapability] 1 byte (bit0 connectable, bit1 centralable, bit2 encryptable, bit3-4 bindable, bit5 ioCap); event/mic/mesh... |

   Có `checkRegistered`: bỏ gói `registered && !bondNew`.
3. `recognize/LocalBeaconRecognizer`: như trên nhưng chấp nhận tất cả.

---

## 2. Framing

### 2.1 Packet type (logic channel) — `com/xiaomi/miot/core/extensions/WearPacket`

| type | tên | ghi chú |
|---|---|---|
| **100** | AUTH | plaintext, dùng cho bind/auth (dataType 2) |
| **101** | PROTO | protobuf thường; **mã hoá** nếu version ≠ 0 |
| 102 | FITNESS | 103 VOICE, 104 MASS, 105 OTA, 106 VERSION, 107 CAPTURE, 108 NET_PROXY, 109 INFO, 111 CAMERA, 112 LYRA, 113 RESEARCH |

`WearApiCall.unauthCall(...)` → `call(getVersion()==0 ? 101 : 100, data, needResponse, cb, timeout)`. Tham số thứ 3 của `call(100, bytes, true, …)` là `needResponse`, **không** phải cờ mã hoá. Sau auth, lệnh thường đi type 101 (mã hoá).

### 2.2 BLE V1 (`defpackage/ro2`, `d38`, `hl7`; khả năng cao là đường của Band 11)

Tất cả little-endian. MTU mặc định 23 (`ro2.d`).

| Frame | Byte layout |
|---|---|
| Data | `seq u16 LE (1..N)` + chunk (chunk ≤ MTU−5) |
| CMD (`fd2`) | `00 00 00 <dataType> <frameCount u16 LE>` |
| ACK (`b0`) | `00 00 01 <status> [missing seq u16…]` — status 0 = xong/OK, 1 = READY, 5 = resend các seq liệt kê |
| SINGLE_CMD (`a4f`) | `00 00 02 <dataType> <payload>` (chỉ khi version>1 và len ≤ MTU−7) |
| SINGLE_ACK (`y3f`) | `00 00 03 <status>` (0 OK, 2 → lỗi −3) |

- `dataType`: **0 = plaintext, 1 = encrypted (AES-CCM), 2 = auth/plain (type 100)** (`BleTaskQueueV1.getDataType`). RX trên kênh proto: dataType 2 → type 100, khác → type 101.
- Gửi: CMD → chờ ACK status 1 → gửi seq 1..N → chờ ACK 0 (≤30 s) hoặc ACK 5 (resend).
- Nhận: thiết bị gửi CMD → app trả ACK 1 → gom frame (thiếu thì ACK 5) → ACK 0. Single: SINGLE_CMD → SINGLE_ACK 0.
- Có CRC32 tuỳ chọn nhưng `BleTaskQueueV1` tạo channel với `false` → **không CRC** trên BLE V1.

### 2.3 V2 / SAR (BLE 0x5E/0x5F hoặc SPP V2) — `transport/TransportV2`, `layerl0/1/2`

**L1 header** (`layerl1/L1Packet`, 8 byte LE):

| Offset | Size | Field |
|---|---|---|
| 0 | 2 | magic **A5 A5** (`TransportL1.L1_HEADER_MAGIC = -23131`) |
| 2 | 1 | `(frx<<4) | type` — type 0 NAK, 1 ACK, 2 CMD, 3 DATA |
| 3 | 1 | seq u8 |
| 4 | 2 | payload length u16 |
| 6 | 2 | CRC16 của payload (CRC-16/ARC: poly 0xA001 reflected, init 0, không xor-out; =0 nếu không payload) |

- CMD (`CMDPacket`): payload `[cmd u8][TLV…]`, cmd 1 START_REQ, 2 START_RSP, 3 STOP_REQ, 4 STOP_RSP. TLV `type u8, len u16 LE, value`. App gửi: `01 0300 010000` (version 1.0.0), `02 0200 00FC` (MPS 64512), `03 0200 2000` (TX window 32), `04 0200 1027` (timeout 10000 ms). Gửi START_REQ ngay sau khi bật notify (`BleTaskQueueV2.enableNotifications → sendStartRequest`).
- DATA: TX window 32, retransmit 10 s; bên nhận ACK cộng dồn sau 500 ms (ngay lập tức cho L2 channel 1 và 8).
- L0: BLE chunk = MTU−3; SPP chunk 16394. Nhận: dò magic, kiểm CRC.

**L2** (`layerl2/L2Packet`, payload của 1 DATA frame): `[channel u8][opCode u8][payload]`.
- Channel: 1 PB (type 100/101), 2 MASS, 3 MASS_VOICE, 4 FILE_SENSOR, 5 FILE_FITNESS, 6 OTA, 7 NETWORK, 8 LYRA, 9 RESEARCH.
- OpCode: 1 WRITE (plain), **2 WRITE_ENC (mã hoá)**, 3 READ. Channel 1 + opcode 2 → type 101; opcode 1 → type 100.

### 2.4 SPP V1 (`com/xiaomi/wearable/spp/b.java`, `transport/TransportV1`)

`BA DC FE` | header u16 LE (bit0-3 channel, bit14 needResponse, bit15 flag) | len u16 LE (= payload+3) | opCode u8 | opCodeSN u8 | dataType u8 | payload | `EF`.
Channel gửi: 100/101→2, 102→3, 103→4, 104→5, 105→7, 106→0. Nhận: 0→106, 1/2→101, 3→102, 4→103, 5→104, 6/7→105, 10→107, 11→113. Nếu gói đến có needResponse, app trả gói rỗng cùng channel/SN, opCode+1.

---

## 3. Crypto

### 3.1 `defpackage/dse`

| Hàm | Ý nghĩa chính xác |
|---|---|
| `i(info, ikm, salt)` | **HKDF-SHA256** (RFC 5869, `defpackage/fi8`): extract `PRK = HMAC(salt, ikm)` (salt rỗng → 32 byte 0), expand với `info = str.getBytes()`, **L = 64 byte** |
| `d(key, nonce, pt)` / `e(key, nonce, pt, aad)` | Encrypt **AES-128-CCM**, tag **4 byte (32 bit)**, nonce 12 byte, AAD tuỳ chọn (`k0(key, 32, nonce, aad)`, `zc2` = CCM, `o1` = AES engine). Output `ciphertext || tag4` |
| `a(key, nonce, ct)` / `b(key, nonce, ct, aad)` | Decrypt tương ứng (4 byte cuối = tag) |
| `j()` | Keypair EC **secp256r1** (P-256) |
| `l(pub)` | Encode public key: uncompressed point bỏ byte `04` → **64 byte X‖Y** |
| `m(pub, priv)` | ECDH → shared secret (32 byte, X-coordinate) |
| `k(n)` | n byte random (`SecureRandom`) |

`defpackage/iz7.a(key, data)` = **HMAC-SHA256** (32 byte).

### 3.2 Khoá phiên sau auth (`WearAuthV2.k`)

`okm = HKDF("miwear-auth", ikm = authKey(16, từ bind), salt = appRandom16 ‖ deviceRandom16)`:

| okm byte | Tên trong `CipherApiCall` | Dùng cho |
|---|---|---|
| 0..15 | `mDeviceKey` (decKey) | giải mã dữ liệu từ device; HMAC kiểm chữ ký device |
| 16..31 | `mAppKey` (encKey) | mã hoá dữ liệu gửi device; HMAC chữ ký app |
| 32..35 | `mDeviceIV` | nonce RX |
| 36..39 | `mAppIV` | nonce TX |

`CipherApiCall.updateKeys(deviceKey, appKey, deviceIV, appIV)` chỉ gán 4 giá trị này rồi cache (`defpackage/e71`) để reconnect không cần auth lại.

### 3.3 Mã hoá từng gói

**V1** (`CipherApiCall.encryptData/decryptData`, AES-CCM tag 4):
- Nonce 12 byte LE = `IV(4) ‖ 00 00 00 00 ‖ counter(4)`.
- Type 101: TX tăng `hk3` app counter trước khi gửi (`hk3.a()`), counter(4) = `low u16 LE ‖ high u16 LE`; gói gửi = `counterLow u16 LE ‖ ciphertext‖tag`. Các type khác (104/105): counter = 0, không prefix.
- RX type 101: 2 byte đầu = device counter low (LE), kiểm đơn điệu (`hk3.f`; biểu thức jadx `((b0)|(b1))<<8` nhiều khả năng là `b0 | b1<<8` — chưa chắc), nonce = `deviceIV ‖ 0 ‖ deviceCounter(4)`.
- Counter reset về 0 khi mở kênh mới qua `zzh` (`hk3.e()`); ở `pn1` giữ theo cache (chưa chắc).

**V2** (`encryptDataV2/decryptDataV2`, `defpackage/q0`): **AES-128/CTR/NoPadding, key = IV = appKey** (TX) / deviceKey (RX). Không tag, không counter. Đánh dấu bằng L2 opCode 2.

---

## 4. Bind & auth

### 4.1 Ai chọn binder nào

1. `com/xiaomi/fit/device/bind/BluetoothDeviceBinder.onConnected(version)`: version 0 → `defpackage/ix1` (legacy); khác → `WearBinderV2("", false, device)`. ⇒ **`o` (OOB string) luôn = ""** trên đường này.
2. `WearBinderV2.h()` gửi **getBindInfo**: type 1 / subtype **17**, Account field 11 `x60 {1: bool checkDynamicCode=false, 2: bytes MD5(userId) raw 16 byte}` qua `unauthCall` (type 100).
3. Response Account field 12 `m50`:

| m50 field | Kiểu | Ý nghĩa |
|---|---|---|
| 1 | enum | **verifyMode**: 1 = PSK (qua server Xiaomi), 2 = local ECDH |
| 2 | string | sn |
| 3 | string | mac |
| 4 | string | model |
| 5 | enum 0..3 | **oobMode** (= `p`) |
| 6 | bytes | (PSK dùng) |
| 7 | string | did |

   - Account field 3 (error) = 1 → "device have bound".
   - verifyMode 2 và oobMode ∈ {2, 3} → **`LocalWearBinderV2`**; oobMode khác → lỗi 1006 "oob mode not support".
   - verifyMode 1 → `PSKWearBinderV2` (cần server: `applyBind`, server pubkey/sign/random, `showOOB` để user nhập mã).
   ⇒ Lựa chọn **do thiết bị quyết định** qua getBindInfo, không phải region/setting.
4. `p == 3` → `showButtonConfirmDialog()` ngay sau khi gửi subtype 18 = user bấm xác nhận trên band. `p == 2`: không có dialog (chưa chắc ý nghĩa — có thể "no confirm").

### 4.2 Local bind (`LocalWearBinderV2`), tất cả qua `unauthCall` (type 100, plaintext)

- `WearBinderV2.f` = nonce cố định **`10 11 12 13 14 15 16 17 18 19 1A 1B`** (12 byte).
- `LocalBindTool.generateAppDeviceId(mac, userId)` = `MD5(mac.toUpperCase() + userId)` → **hex lowercase 32 ký tự**.
- `o` = OOB string (nối vào input HMAC nếu không rỗng; trên đường `WearBinderV2` luôn ""). `p` = oobMode từ m50.

| Bước | type/sub | Account field → message | Nội dung |
|---|---|---|---|
| App → | 1 / **18** | 17 `s50` | 1: string appDeviceId, 2: bytes appPubKey (64 byte X‖Y) |
| ← Device | 1 / 18 | 18 `y50` | 1: bytes devicePubKey (64 byte), 2: bytes deviceRandom (16), 3: bytes deviceSign |
| | | | App: `shared = ECDH`; kiểm `HMAC(shared, deviceRandom [‖o]) == deviceSign` (sai → error 7) |
| | | | `okm = HKDF("miwear-bind", ikm=shared, salt = appRandom16 ‖ deviceRandom16)` |
| App → | 1 / **19** | 19 `p50` | 1: bytes appRandom (16), 2: bytes `HMAC(shared, appRandom [‖o])` |
| ← Device | 1 / 19 | 20 `v50` | 1: bool confirmed (error 6 = device cancelled) |
| App → | 1 / **25** | 29 `u60` | 1: bytes `AES-CCM(key=okm[16..32], nonce=WearBinderV2.f, pt=b60, aad="bind-data")` |
| ← Device | 1 / 25 | 3 (error) | không có error hoặc error 0 = thành công |

- `b60 {1: string userId, 2: g70 companion}`; `g70`/`h70 {1: enum osType (0 = Android; 0/1/2/15 hợp lệ), 2: float SDK_INT, 3: string Build.MODEL, 4: uint32 appCapability, 5: string region, 6: string}`.
- Chia okm: `[0..16]` j (không dùng), `[16..32]` l (khoá bind-data), `[32..36]` n, `[36..40]` m (không dùng thấy), **`[40..56]` i = appToken = authKey mới** → `onLocalBindSuccess(model, did, mac, sn, appDeviceId, appToken)`; sau đó `recordToServer` (best-effort, không bắt buộc cho bind local).
- Lỗi: `s(subtype, err)` gửi lại cùng subtype với Account field 3 = errorCode.

### 4.3 Auth thường (`WearAuthV2`, mỗi lần kết nối)

Input: `userId`, `token` (= appToken), `appDeviceId` (`o` của WearAuthV2), `oob` (`n`) — từ `BleConnection` → `defpackage/yzh` → `defpackage/wzh`.

| Bước | type/sub | Account field → message | Nội dung |
|---|---|---|---|
| App → | 1 / **26** | 30 `b50` | 1: bytes appRandom (16), 2: string appDeviceId, 3: bool (oob không rỗng) |
| ← Device | 1 / 26 | 31 `h50` | 1: bytes deviceRandom, 2: bytes deviceSign. Error 4 = "device not bound" |
| | | | Kiểm `HMAC(decKey, deviceRandom ‖ appRandom [‖oob]) == deviceSign` |
| App → | 1 / **27** | 32 `y40` | 1: bytes `HMAC(encKey, appRandom ‖ deviceRandom)`, 2: bytes `AES-CCM(encKey, nonce = appIV‖0^8, h70)` |
| ← Device | 1 / 27 | 33 `e50` | 1: bool success, 2: uint32 deviceCapability, 3: uint32 deviceCapabilityV2 |

Sau bước 27 thành công → `updateKeys(decKey, encKey, decIV, encIV)`.

### 4.4 Protobuf top-level `WearPacket` (`defpackage/t1i`; `defpackage/u1i` là bản rút gọn chỉ có auth, cùng field number)

| Field | Kiểu | Ý nghĩa |
|---|---|---|
| 1 | enum | **type** (hợp lệ: 0,1,2,4,5,7..23) |
| 2 | uint32 | **id / subtype** |
| 3 | msg `u40` | Account (type 1) |
| 4 | msg `hhg` | System (type 2) |
| 6,7,9..25 | msg | payload oneof; quy tắc quan sát: **field = type + 2** (type 1 → field 3) |
| 10 | msg `wn6` | Fitness (type 8) |
| 100 | int32 | error code (oneof) |

Account `u40` oneof: 1 bool, 2 string, **3 int32 errorCode**, 4..16 (msg khác), 11 `x60`, 12 `m50`, 17 `s50`, 18 `y50`, 19 `p50`, 20 `v50`, 29 `u60`, 30 `b50`/`a50`, 31 `h50`/`g50`, 32 `y40`/`x40`, 33 `e50`/`d50`, 34..36 khác.

---

## 5. Lệnh tối thiểu sau auth (type 101, mã hoá)

Request chỉ set field 1 + 2, không payload.

| Lệnh | type / sub | Nguồn | Response |
|---|---|---|---|
| **Battery** | 2 / **1** | `com/xiaomi/fitness/device/contact/syncer/BatterySyncer.syncData` | System(4) → field 2 `jgg` → field 1: `{1: uint32 level, 2: enum chargeStatus (1 = charging), 3: {1: state (3 = full), 2: timestamp s}}` |
| **Device info** | 2 / **2** | `com/xiaomi/fit/device/model/BluetoothDeviceModel.readWatchInfo` | System(4) → field 3 `ggg`: `{1: serialNumber, 2: firmwareVersion, 3: string (chưa rõ), 4: model}` |
| **HR realtime start** | 8 / **45** | `com/xiaomi/fitness/sport/extension/DeviceModelExtKt.startDeviceHr` | — |
| **HR realtime stop** | 8 / **46** | `...DeviceModelExtKt.stopDeviceHr` | — |
| HR push | 8 / **47** (device → app) | `.../DistanceHeaderViewHolder$DataHandlerImpl.handlePacket` | Fitness(10) → field 39 `dn6`: field **4 = heart rate** (field 1..6 varint; còn lại chưa chắc: steps/calories/...) |

Khác: device push status System subtype 79 (`DeviceBasicStatusDataHandler`); type 2 sub 14/15 get/set wear mode; type 8 sub 10/11 cài đặt HR monitor, 29 sport status.

---

## 6. Trình tự tối thiểu cho SDK (BLE V1)

1. Scan: name prefix / MiBeacon FE95 service data.
2. Connect GATT, xin MTU 512, đọc 0x0050 (version), bật notify 0x0051 (và 0x0053..).
3. Chưa bind: subtype 17 → 18 → (user bấm trên band nếu oobMode 3) → 19 → 25, tất cả dataType 2. Lưu `appToken` (okm[40..56]).
4. Mỗi lần kết nối: subtype 26 → 27 (dataType 2) → có decKey/encKey/IV.
5. Gửi type 2/1 (battery), 2/2 (info), 8/45 (HR) với dataType 1 (AES-CCM + counter prefix).

Điểm cần xác nhận trên band thật: giá trị char 0x0050, tên quảng bá / productId Band 11, oobMode (2 hay 3), RX counter decode.

---

## 7. Kết quả trên thiết bị thật: Xiaomi Smart Band 11 (16/10/2026, Mac mini, `tools/probe_v2.py`)

- Quảng bá: tên `Xiaomi Smart Band 11 9330`, service data FE95 (MiBeacon) `17 59 17 88 12 30 93 AC 17 FB 74`:
  frame control 0x5917 (version 5, **bit 8 registered = 1** ⇒ đang bind với tài khoản Mi Fitness, auth mode 2, có MAC),
  **productId 34839 (0x8817)**, MAC `74:FB:17:AC:93:30` (4 số cuối trong tên = MAC).
- GATT: FE95 có **chỉ** 0x0050 (read = `03 02 12`), 0x005E, 0x005F ⇒ **V2/SAR** (không có 0x51/0x52 của V1).
  Ngoài ra: FDAB (0x0001..0x0004), Battery 180F (đọc được không cần auth, 65%), DIS (chỉ PnP ID), HR 180D
  (không phát khi chưa bật "phát nhịp tim"), 3802, FD2D, `cc353442-…`.
- V2 chạy đúng như §2.3: START_REQ → START_RSP `02 | 01 0300 030212 | 02 0200 0080 | 03 0200 0300 | 04 0200 7017`
  (device: version 3.2.18, MPS 0x8000, window 3, timeout 6000 ms). DATA được ACK (type 1, cùng seq).
- getBindInfo (1/17) khi band đang bind ⇒ Account field 3 = **error 9** (không có trong code Mi Fitness; khác error 1
  "device have bound"). Kết luận tạm: band đã bind thì không cho bind mới ⇒ cần authKey cũ hoặc reset band.
- Sau khi reset band (beacon bit 8 = 0), getBindInfo trả `m50`: **verifyMode = 1 (PSK)**, oobMode = 3,
  model `miwear.watch.q66gl`, mac `74:fb:17:ac:93:30`, sn `81238/…`, did có sẵn ⇒ Band 11 bản quốc tế **bắt buộc bind qua
  server Xiaomi** (`PSKWearBinderV2`: `applyBind` → server pubkey/sign/random → band; `verifyBind` → device_key, oob_code,
  bind_key; `confirmBind`). Bí mật của band chỉ server Xiaomi có ⇒ app không tự bind được nếu không gọi API Xiaomi
  bằng tài khoản Xiaomi của người dùng.
- Đường thực tế: bind bằng Mi Fitness → lấy `encryptKey` (log `XiaomiFit*.log` trong
  `/sdcard/Android/data/com.mi.health/files/log/` hoặc sandbox iOS `MHWCahe/*/VirtualDevice_registerList/manifest.sqlite`)
  → `tools/bind_v2.py import <MAC>` → `auth` (1/26–27) dùng chung band với Mi Fitness.
