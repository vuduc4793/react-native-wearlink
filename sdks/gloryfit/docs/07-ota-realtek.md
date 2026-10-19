# 07 — OTA firmware Realtek (UTE/RTL8773E) cho Y25 & HT43: tự dựng và nạp image được không?

> Phạm vi: **chỉ phân tích code + byte**. Không kết nối BLE, không adb, không flash, không gửi gì tới thiết bị.
> Nguồn: app GloryFitPro 1.9.0.2 (`research/xapk-pro/jadx-out/sources`) + GloryFit cũ (`research/jadx-out/sources`), SDK DFU Realtek (`com/realsil/sdk/dfu/…`).
> Số dòng file Realtek trích dưới đây lấy từ cây **xapk-pro** (GloryFitPro). Cây `jadx-out` cũ là **cùng một SDK** (cùng UUID, cùng opcode, cùng hằng), chỉ khác số dòng do decompiler.
> Phần nào không đọc thẳng từ byte/code thì ghi **(suy luận)**. Đọc kèm `05-firmware-analysis.md` (bố cục image) và `04-firmware.md` (cách lấy file).

---

## 0. Kết luận nhanh (verdict)

| Câu hỏi | Trả lời |
|---|---|
| Tự dựng **công cụ OTA** (client DFU) để nạp image không? | **Được.** Toàn bộ giao thức GATT DFU của Realtek đọc được từ SDK: UUID, opcode, buffer-check, CRC16, AES đường truyền (khoá có sẵn trong app). Mục 1 + 6 là đặc tả đủ để tự viết client. |
| Tự dựng **image firmware hợp lệ "chính chủ"** không? | **Không.** Image App phải có **chữ ký ECDSA P-256** bằng khoá bí mật của UTE (xem `05`). App **không** chứa khoá ký; nó chỉ chuyển 4 byte hash khoá từ image cho đồng hồ. Khi `specVersion ≥ 6`, client gửi lệnh **CHECK_PUB_KEYS (0x12)**; đồng hồ so hash khoá với khoá tin cậy của chính nó và trả lỗi `ERROR_DFU_PUB_KEYS_CONFLICT (285)` nếu khác. Kể cả qua được bước đó, ROM/secure boot vẫn kiểm chữ ký. |
| Có chế độ nhận image **không ký** (debug/tắt secure boot) từ phía app không? | **Không.** Không có cờ "accept unsigned/bypass/secureBoot" nào ở phía điện thoại. Các cờ tắt được (`setVersionCheckEnabled(false)`, `icCheck`, `sectionSizeCheck`, `ignoreException`) chỉ nới **kiểm tra cục bộ trên điện thoại**, không ảnh hưởng việc đồng hồ kiểm chữ ký. |
| `UTE_OTA_SECRET_KEY` là gì? | **Khoá AES-256 mã hoá payload đường truyền** của DFU (transport), **không** phải khoá ký/giải mã image. 32 byte cứng trong app (giống hệt `mSecretkey` của GloryFit cũ). Không phải rào cản. |
| Image Y25 có bị ký bằng khoá mặc định công khai của Realtek không? | **Không.** Đã tải SDK công khai `rtkconnectivity/RTL87x3E-Common-SDK` và đối chiếu (mục 4). Khoá mặc định Realtek là **RSA-2048** (`default_rsa_key.pem`), hash khoá mặc định = `d3e58130…` — **khác thuật toán và khác hash** với khoá Y25 (ECDSA P-256, hash `985b8ac4`). SDK **không** kèm khoá ECDSA mẫu. Tìm toàn SDK: **không** có 65 byte khoá Y25 cũng không có chuỗi `985b8ac4`. ⇒ **khoá riêng của UTE**, không phải khoá mặc định. |
| OTA hỏng có brick không? có bank dự phòng không? | Realtek DFU có **cơ chế silent/dual-bank + background copy + buffer-check resume**: image mới ghi vào vùng không hoạt động / temp buffer, chỉ kích hoạt sau khi nhận đủ và xác thực ⇒ bank đang chạy **không bị đụng** khi truyền dở/ bị từ chối. Mức rủi ro brick **thấp** nếu dùng đúng silent mode và image gốc đã ký. |
| Verdict tổng | Viết được **tool DFU**; **không** nạp được image tự dựng (thiếu khoá ký). Việc hữu ích + an toàn: dùng tool đó **nạp lại chính image gốc đã ký** (`RB370L73AC_V001205.bin`) để kiểm chứng tool trước, rồi dừng. |

---

## 1. Luồng OTA của app Pro cho watch Realtek (RTL8773E / "Bee3" / RK8773)

### 1.1 Cách app quyết định platform

- `BleUpdatePresenter` chọn nhánh theo `DevicePlatform`: `isZKPlatform()` → ZK, `isRKPlatform()` → **Realtek (RK)**, `isJLPlatform()` → Jieli, còn lại → Actions (`BleUpdatePresenter.java:64-77`).
- `isRKPlatform()` = `getDevicePlatform()==2 || isJXRkPlatform() || isZKPlatform()` (`config/DevicePlatform.java:23-24`). Giá trị `getDevicePlatform()` lấy từ `SPDao.getSearchConnectDevicePlatform()`, đặt lúc quét/kết nối từ `UteScanDevice.getDevicePlatform()` (`SearchDeviceActivity.java:218`, `DeviceFragment.java:922`).
- Riêng nhận diện **RTL8773**: bit năng lực thiết bị `DeviceMode.isHasFunction_13(131072)` → `isRKPlatform8773()` (`com/yc/utesdk/ble/open/DevicePlatform.java`). Tức platform do **bit feature đồng hồ báo về**, không đoán từ tên.
- Nhánh RK gọi `RkOtaUtil` → **Realtek `GattDfuAdapter`** (GATT, không phải SPP).

### 1.2 Cấu hình DFU phía app (`RkOtaUtil.startOta`, `RkOtaUtil.java:55-74`)

| Thiết lập | Giá trị | Dòng |
|---|---|---|
| `setOtaWorkMode(getPriorityWorkMode(16))` | **16 = OTA_MODE_SILENT_FUNCTION** (nền/dual-bank) | `RkOtaUtil.java:65` |
| `setVersionCheckEnabled(false)` | tắt so version phía phone | `:66` |
| `setBatteryCheckEnabled(true)` + ngưỡng 30% | | `:67-68` |
| `setSecretKey(UTE_OTA_SECRET_KEY)` | khoá AES-256 đường truyền | `:69` |
| `startOtaProcedure(otaDeviceInfo, cfg)` | khởi động | `:71` |

GloryFit cũ tương đương ở `FirmwareActivity.startOtaProcess8762C` (`:1155-1191`): cũng `setSecretKey(mSecretkey)`, `setVersionCheckEnabled(false)`, `setOtaWorkMode(16 silent / 0 normal)`. **Không** có lệnh UTE riêng để "vào chế độ OTA": dịch vụ DFU/OTA GATT luôn hiện; bước "enter OTA mode" nằm trong chính SDK Realtek (ghi `{0x01}` vào FFD1 ở normal mode; silent mode thì bỏ qua bước này).

### 1.3 UUID GATT (đọc thẳng từ `m/o.java`, `s/j.java`)

| Vai trò | UUID | Hằng |
|---|---|---|
| OTA service (vào OTA mode) | `0000d0ff-3c17-d293-8e48-14fe2e4da212` | `m/o.java:9` |
| **DFU service** | `00006287-3c17-d293-8e48-14fe2e4da212` | `m/o.java:11` |
| **DFU data** (write no response, type 1) | `00006387-3c17-d293-8e48-14fe2e4da212` | `m/o.java:12` |
| **DFU control point** (write + notify) | `00006487-3c17-d293-8e48-14fe2e4da212` | `m/o.java:13` |
| Enter-OTA-mode char (trên D0FF) | `0000ffd1-0000-1000-8000-00805f9b34fb` | `s/j.java:7` |
| Device MAC char | `0000ffd2-…` | `s/j.java:8` |
| Device info char (`parseX0010`) | `0000fff1-…` | `s/j.java:9` |
| Protocol type char (0xFFF3, chọn lớp xử lý) | `0000fff3-…` | `m/o.java:10` |
| CCCD | `0x2902` | `m/o.java:7` |
| Image version chars | `0xFFE0..0xFFEF` | `s/h.java` |
| Image section size chars | `0xFFF4..0xFFF6` | `s/h.java` |
| OTA-mode advertise (spec ≥ 5) | `020002fd-3c17-d293-8e48-14fe2e4da212` | `s/h.java:889` |
| Manufacturer ID Realtek (lọc quảng bá) | `93` (0x5D) | `DfuConstants.java:31` |

Lớp xử lý DFU chọn theo `protocolType` đọc từ FFF3 (`utils/a.java:78-99`): `0x10`→gói `s`, `0x14`→`p`, `0x15`→`q`, `0x12`→`n`, `0x13`→`o`, còn lại→`r` (legacy). Mục 1.4–1.5 và 6 mô tả nhánh `s` (0x0010). **Y25 thật (FW RB370L73ACV001205) báo `0x0014`** ⇒ nhánh `p`, khác ở vài opcode: xem §8.2.

### 1.4 Chuỗi opcode (byte đầu trên control point 0x6487)

| Hex | Tên | Payload | Dòng (xapk-pro) |
|---|---|---|---|
| — | enter OTA mode | ghi `{0x01}` vào **FFD1** (không phải control point) | `s/j.java`, `m/e.java` |
| `0x01` | START_DFU | `[01] + 16/32 B` = ctrl header image + mode byte; **AES nếu bật** | `s/h.java:520-542` |
| `0x02` | RECEIVE_FW_IMAGE | `[02, imageId LE16, offset LE32]`, không chờ đáp | `s/h.java` |
| `0x03` | VALIDATE_FW_IMAGE | `[03, imageId LE16, flag]` (flag=1 ở image cuối) | `s/h.java:740-746` |
| `0x04` | ACTIVE_IMAGE_RESET | `[04]`, hoặc `[04,01]` để qua image kế | `s/h.java:12-14, 723-725` |
| `0x05` | RESET_SYSTEM | `[05]` khi abort/lỗi | `s/h.java:441-442` |
| `0x06` | REPORT_TARGET_IMAGE_INFO | `[06, imageId LE16]` → trả offset resume | `s/h.java:657-659` |
| `0x07` | CONNECTION_PARAMETER_UPDATE | `[07, min,max,latency,timeout]` LE16 | `m/e.java` |
| `0x08` | (notify) remote busy | `payload[0]==1` bận | `s/h.java:896-911` |
| `0x09` | ENABLE_BUFFER_CHECK_MODE | `[09]` → trả `maxBufferCheckSize` | `s/h.java:60-61` |
| `0x0A` | REPORT_BUFFER_CRC | `[0A, len LE16, crc16 LE16]` | `s/h.java:554-556` |
| `0x0C` | CopyImageReq (dual-bank) | `[0C, imageId LE16]` | `s/h.java:619-624` |
| `0x0F` | CheckSha256Req (dual-bank skip/copy) | so sha256 image vs bank | `s/h.java:458-469` |
| `0x12` | **CheckPubKeyHashReq** | `[12, n, n×(imageId LE16 + 4B hash)]`, spec ≥ 6 | `s/h.java:16-51` |
| `0x13` | ReportImageNumberCmd | `[13, imageId LE16, idx, count]` | `m/m.java` |

**Thứ tự silent mode 16** (nhánh `s/g`): kết nối + discover → đọc FFF1/FFD2/FFE0/FFF4 → **0x12 (nếu spec≥6)** → **0x0F (nếu bank-enabled, spec≥4)** → requestMTU 256 → 0x09 (nếu device bật buffer-check) → 0x06 → 0x13 (nếu hỗ trợ) → **0x01 START_DFU** (nếu offset resume=0) → **0x02 RECEIVE_FW** → stream dữ liệu (buffer-check hoặc plain) → **0x03 VALIDATE** → **0x04 ACTIVE+RESET**. (Normal mode 0 thêm bước ghi `{0x01}` vào FFD1 + reboot + reconnect, và gửi 0x07.)

### 1.5 MTU / kích thước gói

| Thông số | Giá trị | Dòng |
|---|---|---|
| MTU yêu cầu | `requestMtu(256)`, chờ 15s | `m/e.java`, `GattConfig.MAX_MTU_SIZE=256` |
| MAX_PACKET_SIZE mặc định | **20 B** (nếu không bật MtuUpdate; app không bật) | `BaseDfuTask` |
| Buffer-check size `r` | mặc định **256**, lấy từ đáp 0x09 / `DeviceInfo.maxBufferCheckSize` | `s/h.java:366`, `DeviceInfo.java:115` |
| Buffer-check packet `s` | **16** (`MAX_BUFFER_CHECK_PACKET_SIZE`) | `DfuConstants.java:33` |
| Gói đầu | 12 byte header image + dữ liệu | `s/h.java:835-841` |
| CRC buffer | CRC16 kiểu XOR 16-bit LE, byte-swap | `j/c.java` |
| Validate timeout | 30 s, hoặc `(MB+1)*4000+5000` nếu >1 MB | `j/c.java` |

---

## 2. Phía phone kiểm gì / phía watch kiểm gì

### 2.1 Phía phone (chỉ pre-flight + chuyển tiếp)

- Parse header image (MP/ctrl header, imageId, icType, version, pubKeyHash) qua `FirmwareLoaderX.loadImageBinInfo` + `BaseBinInputStream`.
- `icCheck`, `sectionSizeCheck`, `versionCheck` — **kiểm tra cục bộ**, tắt được (`RkOtaUtil` dùng `versionCheckEnabled(false)`).
- **Không tự xác minh chữ ký.** Phone chỉ đọc 4 byte `pubKeyHash` từ header image (`BaseBinInputStream.getPubKeyHash()`, trả field đã parse) rồi **chuyển cho đồng hồ** qua 0x12.

### 2.2 Phía watch (bắt buộc, nằm ngoài tầm với)

- **CHECK_PUB_KEYS (0x12)**: với mỗi image, phone gửi `imageId + 4B hash`; đồng hồ so với **hash khoá tin cậy của chính nó**; `response[0] != 1` ⇒ `ERROR_DFU_PUB_KEYS_CONFLICT (285)`, hủy DFU (`s/h.java:19-51`, giá trị opcode 18/0x12 ở `s/b.java`; chỉ chạy khi `specVersion ≥ 6`, `s/h.java:19`).
- **Chữ ký ECDSA P-256 + SHA-256 + CRC16** trong image (xem `05-firmware-analysis.md` §1.5): kiểm lúc nạp/boot. ROM Realtek kiểm chữ ký lúc khởi động phụ thuộc eFuse — **không đọc được từ file OTA** **(suy luận)**.
- `secureVersion` (chống hạ cấp): Y25 hiện = 0 (`05` §1.1), nên chưa chặn theo số này.

### 2.3 Có mode nhận image không ký không?

**Không có ở phía app.** Grep toàn gói DFU không có `secureBoot/bypass/unsigned/skipSign/acceptUnsign`. Chỉ có `ignoreException` (`LoadParams`) và vài cờ `*CheckEnabled` — đều là kiểm tra cục bộ trên phone. Việc nhận/từ chối image là **trên đồng hồ**; tắt kiểm tra phía phone **không** làm image không ký lọt qua **(suy luận về phía watch, dựa trên giao thức + sự tồn tại của 0x12 và chữ ký trong image)**.

---

## 3. Vai trò `UTE_OTA_SECRET_KEY` và mã hoá AES

- Khai báo: `com/yc/utesdk/ota/UteOtaUtils.java:5` (và bản sao `com/yc/nadalsdk/utils/open/UteOtaUtils.java:5`), 32 byte. **Giống hệt** `mSecretkey` của GloryFit cũ (`FirmwareActivity.java:381`).
- Dùng đúng một chỗ: `RkOtaUtil.java:69` → `DfuConfig.setSecretKey(...)`.
- Bản chất: **AES-256 mã hoá payload DFU đường truyền** (confidentiality), không đụng tới chữ ký/tính hợp lệ của image.
  - `AesJni.MODE_AES_256 = 3`, nạp lib native `RtkAesJni`; init `aesInit(3, key)` (`AesJni.java`, `BaseDfuTask`). Chỉ có `aes_encrypt(16B in → 16B out)`, **không IV** truyền từ Java ⇒ áp theo từng block 16 byte (ECB-style phía Java; nếu có chaining thì nằm trong native) **(suy luận về chế độ)**.
  - Áp lên: header START_DFU (0x01) và từng block 16 byte dữ liệu firmware, đều **chỉ khi** `getOtaDeviceInfo().isAesEncryptEnabled()` (cờ do đồng hồ báo qua FFF1).
  - Chế độ: `AES_MODE_16_FIRST=0` (chỉ mã block đầu) / `AES_MODE_16_N=1` (mã mọi block đủ 16B) — `DeviceInfo.java:5-6`. Đuôi <16B để nguyên.
  - Hằng: `AES_SECRET_KEY_LENGTH=32`, `AES_ENCRYPTION_SIZE=16` (`DfuConstants.java:5-6`).
- ⇒ Khoá này **không** là rào cản (ta có nó). Nó **không** giúp dựng image hợp lệ.

---

## 4. Nguồn gốc khoá công khai (0x3A0) — đối chiếu SDK công khai của Realtek

**Nguồn đã kiểm:** SDK công khai `rtkconnectivity/RTL87x3E-Common-SDK` (GitHub, clone về scratchpad, chỉ đọc) + tài liệu bảo mật `UM002 Secure Enabled` (`realmcu.com/img/ipd/en_638247791881070184.pdf`). Tài liệu docs online (`docs.realmcu.com/sdk/rtl87x3e/common`) cần đăng nhập.

### 4.1 SDK này phủ chip nào

- README: *"Firmware SDK for RTL87x3E series"*, trang tài liệu ghi *"RTL8763E Series"*. `Kconfig` chỉ có `SOC_SERIES_RTL8763E` (+ `_V2`). ⇒ repo phủ **RTL8763E / RTL87x3E** (và tham chiếu RTL87x3D, RTL87x3G). Đây là dòng SoC tai nghe/audio (image App tên `rws_*.bin`, có DSP/ANC).
- Y25/HT43 là **RTL8773E** (8773 ≠ 8763) — **không** nằm trong repo này; nhưng cùng họ "Bee" nên **định dạng image, secure boot, eFuse, bộ công cụ về cơ bản giống nhau** **(suy luận, dựa trên việc cùng bố cục header + cùng chuỗi lệnh DFU)**.
- ⇒ Nói "SDK chỉ cấp theo NDA" là **không chính xác với RTL8763E**: SDK + bộ công cụ đóng gói/ký của họ hàng này **công khai**. Riêng SDK đúng cho RTL8773E thì repo này không có.

### 4.2 Khoá ký: mặc định là RSA, Y25 là ECDSA

- Khoá ở `0x3A0` (65 byte `04‖X‖Y`, ECDSA P-256): `04b18fa982894962587bb791df7cdd202fb09f98acafc42e873864a2209c3b6ff46444a8dda0c1526139b8825f38eabeb74f6e0ae80b0725754e1c144164ede7b9`; SHA-256[-4:]=`985b8ac4`, **khớp** pubKeyHash MP header (đã kiểm ở `05`).
- Khoá **mặc định** của SDK (`tool/Gadgets/default_rsa_key.pem`, `rtk_rsa.pem`) là **RSA-2048**, không phải ECDSA. File hash mặc định `default_rsa_key_hash.bin` = `d3e58130d78decc7c05aebf09ac8a9165f02704b935cfbe567fdca0e60341196807f` (34 byte) — **khác hoàn toàn** `985b8ac4`.
- Script dựng (`board/evb/.../dual_bank_after_build.bat`) cho thấy công cụ hỗ trợ **cả hai**: `prepend_header /ecdsa <ecdsa_key.pem>` hoặc `/rsa <rtk_rsa.pem>`, chọn theo IC. **`ecdsa_key.pem` được tham chiếu nhưng KHÔNG có trong repo** — SDK công khai chỉ kèm khoá RSA, **không** kèm khoá ECDSA mẫu.
- **Đối chứng âm tính:** quét toàn bộ SDK tìm 65 byte khoá Y25 và chuỗi `985b8ac4` → **0 kết quả**. App GloryFitPro cũng không nhúng khoá ký (chỉ chuyển 4 byte hash từ chính image, `s/h.java:30-34`).
- ⇒ **Không thể re-sign để kiểm** (thiếu khoá bí mật ECDSA; khoá RSA mặc định khác thuật toán và khác hash). Image Y25 ký bằng **khoá riêng của UTE**, không phải khoá mặc định Realtek.

### 4.3 Secure boot & eFuse (tài liệu UM002, cho RTL87x3E/D — dùng RSA)

Trích nguyên văn (lược dịch):
- *"the RSA public key hash should be burned into the eFuse of the IC, and all important images … need to be signed before downloading"*. Bootloader làm **2 bước**: (1) *"check RSA public key in the image with the RSA public key hash in the eFuse"*; (2) *"verify the RSA signature in the image"*.
- *"If user A and user B generate RSA key separately, the RSA key will be different and private. If user A wants to modify the images to run on the device of … user B, user A doesn't have the RSA key of user B, so the modified images can't run on the device of user B."* ⇒ đúng mô hình: **mỗi khách hàng một khoá riêng, khoá đó khoá cứng vào eFuse từng con chip**.
- EVB của Realtek đã nạp sẵn **khoá mặc định** (nên image ký bằng khoá mặc định **chỉ chạy trên EVB**); IC MP bán ra nạp khoá riêng của khách. Y25 là sản phẩm MP ⇒ eFuse giữ hash khoá **của UTE** (`985b8ac4…`) **(suy luận: trạng thái eFuse không đọc được offline, nhưng sản phẩm thương mại đã bật secure boot)**.
- Tối ưu tốc độ: lần boot đầu verify RSA/chữ ký, sau đó lưu **CMAC** để các lần sau kiểm nhanh. AES CBC mã hoá ram-code gắn theo partnumber IC (khoá do RTK giữ) — **khác** khoá AES đường truyền của UTE ở mục 3.
- Y25 dùng **ECDSA P-256** thay cho RSA-2048, nhưng **cơ chế eFuse + 2 bước kiểm là một** (trường chữ ký 256 byte chỉ dùng 64 byte đầu — xem `05` §1.2). Tài liệu công khai chỉ mô tả bản RSA; phần ECDSA của RTL8773E **(suy luận)**.

### 4.4 Hệ quả

Nếu tự ký bằng khoá của ta ⇒ public key trong image khác ⇒ bootloader **fail bước (1)** (hash eFuse không khớp) và DFU **fail 0x12** (CHECK_PUB_KEYS, spec≥6) trước đó. Khoá mặc định Realtek cũng vô dụng (hash khác + sai thuật toán). **Không có đường vòng hợp lệ** nếu secure boot đã bật. Chỉ chạy được image tự ký khi: có khoá bí mật của UTE (không có được), **hoặc** gặp IC **chưa** burn hash eFuse (non-secure) — Y25 gần như chắc chắn đã secure.

---

## 5. Khôi phục khi OTA hỏng: có bank dự phòng không?

Realtek DFU hỗ trợ **silent + dual-bank/background-copy + buffer-check resume** (chống brick):

| Cơ chế | Bằng chứng |
|---|---|
| Work mode silent (mặc định) | `OTA_MODE_SILENT_FUNCTION=16`, `_EXTEND_FLASH=17`, `_NO_TEMP=18`, `_DUALBANK_FORCE_TEMP=19`, `_RWS=21` (`DfuConstants.java:38-44`); `getPriorityWorkMode(16)` mặc định |
| Năng lực bank của đồng hồ | `DeviceInfo.isBankEnabled()`, `isCopyImageEnabled()` (bit3 feature FFF1); `BANK_INFO_0/1`, `BANK_INFO_NOT_SUPPORTED=15` (`DfuConstants.java:7-9`) |
| Quyết định skip/copy/push | `s/h.java:79-100` (`I()`): so SHA-256 image mới với bank inactive/active → skip(1)/copy(2); vòng `K()` (`:106-171`) nếu validate lỗi thì **tự chuyển sang push full** thay vì hỏng |
| Cờ bank trong header image | `activeCompareVersionFlag`, `inactiveVersionCompFlag` (`BaseBinInputStream`) |
| Resume dở dang | 0x06 trả `updateOffset`; buffer-check (0x0A) báo offset kế ⇒ gửi tiếp từ chỗ dừng, không phải làm lại |

**Xác nhận từ SDK công khai:** script `dual_bank_after_build.bat` dựng image cho **bank0 và bank1** riêng, địa chỉ lấy từ `flash_map.h` (`BANK0_APP_ADDR`, `BANK1_APP_ADDR`) ⇒ **dual-bank A/B thật** (hai khe App ở hai địa chỉ flash). Bảng image (UM002 §2.2) còn có loại **"OTA Header Image"** riêng (quản lý bank/active). Mỗi image qua `prepend_header` → SHA256 + CRC16 + chữ ký + MP header (đúng định dạng Y25).

**Diễn giải (suy luận):** trên đồng hồ bật bank (spec≥4/5), image mới ghi vào vùng **không hoạt động / temp buffer**, chỉ kích hoạt (0x04) sau khi nhận đủ + xác thực; bank đang chạy không bị đụng khi truyền dở hoặc bị từ chối ⇒ **không brick**. Lưu ý từ `05`: bản đồ flash Y25 **không** thấy chỗ cho bank App thứ hai 1,6 MB cạnh `0x0209C000`, nên Y25 nhiều khả năng dùng **temp buffer copy** chứ không giữ 2 bản App song song **(suy luận, cần dump flash để chắc)**. Rủi ro brick thực sự chỉ cao khi image **tự sửa đã qua được mọi kiểm tra** rồi App vá lỗi treo — nhưng kịch bản đó bị chặn từ trước bởi chữ ký.

---

## 6. Đặc tả tối thiểu cho "OTA tool" tự dựng

Một client DFU GATT Realtek cần:

1. **Kết nối + discover**: service `6287`, char control `6487` (write+notify, bật CCCD 2902), data `6387` (write-no-response).
2. **Đọc năng lực**: FFF1 (`parseX0010`) → `icType`, `specVersion`, cờ bufferCheck/AES/AES-mode/bank/reportImageNumber, `otaTempBufferSize`, bank active, MTU. FFD2 (MAC), FFE0 (version), FFF4 (section size).
3. **AES**: nếu đồng hồ báo `aesEnable`, mã hoá AES-256 (khoá `UTE_OTA_SECRET_KEY`) theo mode 0/1 cho header START_DFU và từng block 16 byte dữ liệu.
4. **Chuỗi lệnh** (silent): `0x12` (spec≥6, gửi `imageId+4B hash` từ image) → `0x0F` (nếu bank) → MTU 256 → `0x09` (nếu bật) → `0x06` → `0x13` → `0x01` → `0x02` → stream (buffer-check `r`/`s` + `0x0A` CRC16, hoặc plain 20B) → `0x03` (flag=1 image cuối) → `0x04`.
5. **Parse đáp**: frame `[0x10][reqOpcode][status…]`, status 1 = OK; 0x0A status 5/6 = CRC sai → gửi lại; mã lỗi quan trọng: 285 (pubkey conflict), 275 (buffer retry max), 280 (enter OTA fail), 288 (copy fail), 767 (no response).
6. **Đóng gói image**: xem `05` §5 (CRC16/ARC → SHA-256 → ECDSA → MP header). **Bước ký không làm được** (thiếu khoá bí mật).

---

## 7. Kế hoạch thử an toàn (nếu vẫn muốn làm tool)

> Mục tiêu: xác nhận **tool DFU** hoạt động mà **không** mạo hiểm image lạ. Luôn pin ≥ 50%, giữ BLE gần, có sẵn phương án cứu (UART/MP Tool Realtek — cần mở máy).

1. **Chỉ đọc trước:** kết nối, discover, đọc FFF1 → ghi lại `specVersion`, `icType`, cờ `aesEnable`/`bank`/`bufferCheck`, `maxBufferCheckSize`, MTU, bank active. (Chưa gửi lệnh ghi nào.)
2. **Dry-run parse:** nạp `RB370L73AC_V001205.bin`, parse header, kiểm lại CRC16/SHA-256/chữ ký bằng tool của ta (phải khớp `05`). Dựng đúng payload các lệnh 0x12/0x06/0x01 **nhưng chưa gửi**; đối chiếu log với SDK.
3. **Nạp lại CHÍNH image gốc đã ký** bằng tool của ta, **silent mode 16**, AES theo cờ đồng hồ. Đây là image hợp lệ nên qua được 0x12 và chữ ký; nếu tool đúng, OTA thành công và máy vẫn chạy bản cũ/giống hệt ⇒ **đã validate tool** mà không đổi hành vi.
4. **Dừng lại ở đây cho image sửa đổi.** Mọi image tự dựng sẽ fail 0x12/ chữ ký; nếu (giả thuyết) lọt được thì rủi ro treo App là thật. Không khuyến nghị.
5. Nhu cầu đổi mặt đồng hồ mặc định / tài nguyên: dùng **mặt tuỳ chỉnh qua giao thức UTE** (đã chạy, `02-watchface.md`) hoặc nhờ UTE/nhà máy (xem `05` §4, `04` §3).

---

## 8. Bản Android (SmartWear Lab)

### 8.1 Kết nối, lệnh adb

Port của `firmware-flasher/flasher.py` trong `sdks/gloryfit/android/.../ota/`: `RealtekImage.load()` (kiểm như `Image`,
thêm ghim khoá `985B8AC4`), `RealtekDfu` (máy trạng thái thuần JVM, test ở `RealtekDfuTest`), `RealtekDfuClient` (GATT).

**Kết nối:** DFU mở một client GATT **riêng** tới cùng địa chỉ và **giữ nguyên** kết nối UTE của driver, đúng như GloryFitPro
(`RkOtaUtil.rkConnectDevice()` chỉ gọi khi `UteBleClient.isConnected()`, rồi `GattDfuAdapter` tự `connectGatt`). Android ghép
nhiều client trên một liên kết; notify 6487 chỉ tới client đã bật CCCD; không nhả kết nối driver nên `DeviceManager` không
nối lại giành liên kết giữa chừng. Client DFU đóng không gọi `refresh()` (sẽ làm stack khám phá lại service của client UTE).
Trong lúc nạp giữ `BleQuiet` (ngừng đọc RSSI định kỳ). Sau `0x04` đồng hồ khởi động lại, driver tự nối lại.

Lệnh adb (log: `adb logcat -s SmartWear:V | grep OTA`), file đặt ở `/sdcard/Android/data/com.smartwear.lab/files/`:
`--es action otaCheck --es file <path>` · `--es connect <MAC> --es action otaProbe` ·
`--es connect <MAC> --es action ota --es file <path>` · `--es action otaCancel` (xem `MainActivity.autoRun`).

### 8.2 Protocol 0x0014: Y25 thật (đọc 19/10/2026)

Probe chỉ đọc trên Android (`otaProbe`), Y25 FW `RB370L73ACV001205`, MAC `78:02:B7:03:6E:1B`:

```
GATT d0ff…: ffd1(writeNoRsp) ffd2 ffd3 ffd4 fff1 ffe0 ffe1 fff3 fff4 fff5 ; 6287: 6387(writeNoRsp) 6487(write|notify)
fff3 = 14 00                                   -> protocolType 0x0014
fff1 = 11 02 1d 00 ad 01 00 f7 00 01 00 00 00
ffd2 = 78 02 b7 03 6e 1b 78 02 b7 03 6e 1b
ffe0 = 00 0b 8f 27 00 70 0e 00 90 27 01 00 00 00 93 27 40 10 a0 96 … fe ff 00 00 00 00   ffe1 = (rỗng)
fff4 = 0a 90 27 01 00 00 00 93 27 00 b0 1a 00 … fe ff 00 c0 96 00                        fff5 = (rỗng)
2a19 = 0x64 (100%)
```

Đường code SDK cho protocol 20 (cây `research/xapk-pro/jadx-out/sources/com/realsil/sdk/dfu/`; các method jadx không dịch được đã dịch
lại bằng `jadx --show-bad-code` vào `research/xapk-pro/jadx-dfu/sources/com/realsil/sdk/dfu/p/{c,d}.java`):

| Vai trò | Lớp | Dòng |
|---|---|---|
| Chọn lớp đọc thông tin theo FFF3 = 20 | `p.a` | `utils/a.java:87-88` |
| Đọc FFF1 → `parseX0014`, FFE0…FFEF → `appendImageVersionBytes`, FFF4…FFF6 → `appendImageSectionSizeBytes` | `p.a` | `p/a.java:36-51` |
| Giải FFF1 | `p.b` | `p/b.java:10-81`, gán vào `DeviceInfo.parseX0014` `model/DeviceInfo.java:687-716` |
| Chọn task DFU (work mode 16 ⇒ silent) | `p.f` (kế thừa `p.d` → `m.e`) | `j/a.java:10-11` |
| Nạp/kiểm image | `p.c.loadImageBinInfo` | `image/FirmwareLoaderX.java:13`, `jadx-dfu/.../p/c.java:106-299` |

#### FFF1 (`p/b.java:10-81`)

| Byte | Giá trị | Ý nghĩa |
|---|---|---|
| 0 | `11` | icType 0x11 (= ic trong ctrl header file) |
| 1 | `02` | specVersion 2 (`& 0x0F`) |
| 2 | `1d` = 0001 1101 | b0 **buffer-check bật**; b1 **AES tắt**; b2 AES mode 1 (không dùng); b3 updateImageFlag 1; b4 LE normal mode có; b5 NAND không; b6 nén không; b7 version dài không |
| 3 | `00` | rwsMode 0 (không RWS), bit 2-3 = 0 |
| 4-5 | `ad 01` | temp buffer 429 × 4096 = **1 757 184 B** (đơn vị 4 KB: `p/f.java:173`) |
| 6 | `00` | bank normal: không ⇒ `imageVersionIndicator` 3, `updateBankIndicator` 0, `isBankEnabled` false |
| 7-8 | `f7 00` | MTU 247 |
| 9 | `01` | bank boot: có, active 0, update 1 (`BankInfo.java:30-50`) |
| 10-12 | `00 00 00` | chỉ đọc khi spec ≥ 4 (bỏ qua) |

⇒ `updateMechanism` = 3 (all-in-one qua temp buffer, `k/c.java:104-116`). FFD2 (`parseDeviceMacV2`): MAC `78:02:B7:03:6E:1B` + bản sao
6 byte (trường "RWS bdaddr", ở đây trùng MAC).

#### FFE0 / FFF4: phiên bản + section từng image

Cách ghép (`model/DeviceInfo.java:128-140`): byte đầu mỗi characteristic version = 0 ⇒ ACTIVE, ≠ 0 ⇒ INACTIVE, phần còn lại nối lại;
giá trị rỗng (FFE1) bỏ qua. Danh sách = `[n] + n × (imageId LE16 + version LE32)`; riêng 0x2790 đọc **big-endian**; 8 byte nếu cờ version
dài (`model/ImageVersionInfoParser.java:48-106`). FFF4+FFF5 nối nguyên = `[n] + n × (imageId LE16 + size LE32)`. SDK giữ version ở
`int` có dấu rồi gán vào `long` nên 0x96A01040 hiện là `FFFFFFFF96A01040` trong log SDK (vô hại vì version check tắt).

| imageId | Tên (bảng `image/b.java:12-25`, `c.java:28`, `f.java:18`; bảng nào áp cho ic 0x11 chưa chắc) | Version active | Section (byte) |
|---|---|---|---|
| 0x278F | Boot Patch | 0x000E7000 | — |
| 0x2790 | OTA Header (BE) | 0x01000000 | 1 |
| **0x2793** | **App** | **0x96A01040** | **1 748 992** (0x1AB000) |
| 0x2794 | DSP System | 0x0100011E | 131 072 |
| 0x2795 | DSP App | 0x0100011E | 204 800 |
| 0x2796 | App Config | 0 | 8 192 |
| 0x2797 | DSP Config | 0x00683D11 | 20 480 |
| 0x2798 | Ext Image 0 | 0 | 204 800 |
| 0x279C | Sys Patch | 0x000EF000 | 106 496 |
| 0x279D | Stack Patch | 0x0002F000 | 180 224 |
| 0xFFFE | User Data 1 | 0 | 9 879 552 |

Không có danh sách INACTIVE (không dual-bank App).

#### Chuỗi lệnh 0x0014 (silent, cấu hình của GloryFitPro)

Cấu hình: `RkOtaUtil.startOta` (`RkOtaUtil.java:60-71`) chỉ đặt work mode 16, `setVersionCheckEnabled(false)`, battery ≥ 30%, khoá AES;
còn lại là mặc định `DfuConfig` (`model/DfuConfig.java:719-754`): icCheck + sectionSizeCheck bật (`f = 7`), **breakpoint resume tắt**
(`j = false`), tự kích hoạt (`h = true`), không chờ ACK lệnh kích hoạt (`k = false`), notification timeout 10 s, buffer-check MTU
cơ chế V2 (`DfuBufferCheckConfig.java:30`). App không đặt thêm gì riêng cho thiết bị này.

Byte thật cho `RB370L73AC_V001205.bin` (image 0x2793) trên Y25 này:

| # | Lệnh (control 6487) | Đáp mong đợi | SDK |
|---|---|---|---|
| 0 | bật CCCD 6487, `requestMtu(256)` | — | `m/e.java:199-219` (`C()`) |
| 1 | `09` ENABLE_BUFFER_CHECK (vì FFF1 b0) | `10 09 01 <maxBuf LE16>` | `p/d.java:37-69`, `m/h.java:42-47` |
| 2 | `06 93 27` REPORT_TARGET_IMAGE_INFO | `10 06 01 <ver LE16> <offset LE32>` (7 B) hoặc `… <ver LE32> <offset LE32> <bufOff LE16>` (11 B) | `p/d.java:382-395`, `t/d.java:19-45` |
| — | offset resume bị đặt về 0 (resume tắt) | | `m/e.java:187-193` (`A()`) |
| 3 | `12 93 27 01 01` **ReportImageNumber** (opcode 0x12 ở protocol 20!), không chờ đáp | — | `m/e.java:221-227`, `m/m.java:37-47` |
| 4 | `01 7b ca 11 00 01 01 93 27 74 ab 19 00 00 00 00 00` START_DFU (ctrl 12 B + 4 B 0; AES tắt) | `10 01 01` | `p/d.java:186-209` |
| 5 | `02 93 27 00 00 00 00` RECEIVE_FW_IMAGE offset 0, không chờ đáp | — | `p/d.java:397-405`, `m/e.java:535-541`, `m/n.java:37-42` |
| 6 | Data 6387: khối `maxBuf` B (mặc định 256), chia gói **MTU−3 làm tròn 16** (MTU 247 ⇒ 240 + 16); sau mỗi khối `0a <len LE16> <crc LE16>` | `10 0a 01 <offset LE32>`; 5/6 = CRC sai, gửi lại (tối đa 3) | `jadx-dfu/.../p/d.java:463-556`, `p/d.java:311-338`; cỡ gói `m/d.java:128-130` + `j/c.java:28-67` |
| 7 | `03 93 27 01` VALIDATE (flag 1 = image cuối) | `10 03 01` | `p/f.java:141-143`, `m/q.java:40-59`, `p/d.java:444-458` |
| 8 | `04 00` ACTIVE_IMAGE_RESET (chỉ sau VALIDATE OK) | không chờ | `p/d.java:31-33` (`E()`), `p/d.java:258-309` |

Khác 0x0010: **không có CHECK_PUB_KEYS** (0x12 ở đây là ReportImageNumber 5 byte, gửi luôn khi spec ≥ 1); không có `0x0F`; đáp `0x06` 7 hoặc
11 byte; resume luôn bỏ; `0x04` có thêm byte `00`. Khoá ký vẫn do đồng hồ kiểm (chữ ký trong image, lúc VALIDATE/boot), chỉ là không có
bước so hash trước. Bản 0x0010 của SDK (`s/h`) cũng bỏ resume (`s/h.java:249`) và cũng dùng gói MTU−3; bản Kotlin 0x0010 giữ hành vi
flasher.py (gói 16 B, resume) như trước, không đổi.

#### File `RB370L73AC_V001205.bin` có hợp lệ cho đồng hồ này?

Đường single image `p/c.loadImageBinInfo` (`jadx-dfu/.../p/c.java:224-299`):

| Kiểm | File | Thiết bị | Kết quả |
|---|---|---|---|
| binId hỗ trợ single (`LoadParams.java:579-605`) | 0x0300 (App, 768) | spec 2, boot bank có | OK (chỉ chặn binId 0x0A01) |
| NAND/NOR (`BaseBinInputStream.java:134-145`) | không TLV 0x21 ⇒ NOR | NAND = không | OK |
| icCheck (`BinInfo.java:26-34`) | ic 0x11 | ic 0x11 | OK |
| sectionSizeCheck (`c/f.java:10-29`) | wire 1 683 316 B | 0x2793: 1 748 992 B | SDK **bỏ qua** cho ic 0x11 (chỉ 4/6/7/8/10/13); ta vẫn kiểm: OK |
| temp buffer (`p/f.java:173`) | 1 683 316 B | 1 757 184 B | OK |
| `c/d.a` (`c/d.java:5-9`) | | ic 0x11 ∉ {5,9,12} | OK |
| versionCheck | 0x96A01040 (TLV 0x16) | active 0x2793 = 0x96A01040 | **cùng phiên bản**; app tắt version check (`RkOtaUtil.java:66` → `k/b.java:153`) ⇒ không chặn |

Nếu bật version check, SDK sẽ coi cùng bản là "không mới hơn" (`k/a.java:162-177`: `compare <= 0` ⇒ −1 ⇒ lỗi 4104), nhưng GloryFitPro
không bật. Trên dây giao thức 20 không có bước so phiên bản nào (đáp `0x06` chỉ báo version để log), nên phía điện thoại **nạp lại cùng
bản được**. Đồng hồ có từ chối cùng bản lúc VALIDATE không thì **chưa biết** (không có code firmware); nếu từ chối, VALIDATE trả status ≠ 1
và ta dừng trước `0x04` ⇒ bank đang chạy không bị kích hoạt đè.

#### Bản Kotlin

- `DfuCapabilities.parse(fff1, 0x14)` = `parseX0014` (nhận spec 1–3; spec ≥ 4 thêm byte nén ở START_DFU, chưa kiểm chứng ⇒ từ chối).
- `DfuImageVersions.parseX0014` giải FFE0…/FFF4… như trên; `RealtekDfuClient.readDevice` log `image: active[…] section[…]`.
- `RealtekDfu.preflightX0014` chạy trước mọi lệnh ghi: ic, NAND, section, temp buffer; báo cùng/khác phiên bản (không chặn).
- `RealtekDfu.upload` rẽ theo `caps.protocol`; `uploadX0014` gửi đúng bảng trên; MTU thương lượng được truyền vào để tính cỡ gói.
- Giữ nguyên mọi chốt an toàn: `RealtekImage.load` (chữ ký ECDSA, ghim khoá `985B8AC4`, chỉ App ic 0x11 id 0x2793), chỉ tên `Y25…`,
  pin ≥ 50%, `0x04` chỉ sau VALIDATE status 1, lỗi/huỷ ⇒ không kích hoạt.
- Chặt hơn SDK (cố ý): `0x09` lỗi/hết giờ ⇒ dừng (SDK chuyển sang không buffer-check); đáp `0x06` khác 7/11 byte ⇒ dừng (SDK coi offset 0);
  VALIDATE chờ 30 s (SDK 10 s); kiểm thêm section/temp buffer.
- Test: `RealtekDfuX0014Test` (22 test): giải đúng byte FFF1/FFD2/FFE0/FFF4 hôm nay, preflight với file thật (cùng bản 0x96A01040,
  section OK), luồng đầy đủ với image thật trên thiết bị giả (byte từng lệnh, 6576 khối CRC, gói 240+16), plain, resume bị bỏ,
  CRC retry, từ chối ở từng bước không bao giờ gửi `0x04`, huỷ giữa chừng, cùng/khác phiên bản cho chuỗi lệnh y hệt.

**Chưa biết / rủi ro:** (1) đồng hồ có nhận lại cùng phiên bản không (chỉ biết khi chạy thật; an toàn nhờ chốt VALIDATE); (2) nhánh gửi lại
khi CRC sai trong `p/d.b` jadx dịch sai (`Removed duplicated region`), bản Kotlin dùng cùng cách với 0x0010 (kiểm offset đồng hồ báo =
offset hiện tại, gửi lại `0x02` rồi khối); (3) đồng hồ có trả đáp cho `0x12` ReportImageNumber không: nếu có thì bị bỏ qua; (4) tên image
theo bảng của dòng chip khác, chỉ để đọc; (5) `0x04 00` làm đồng hồ khởi động lại, cả kết nối UTE lẫn DFU rớt.

---

### Phụ lục: file/dòng chính

- Glue RK OTA: `research/xapk-pro/jadx-out/sources/com/yc/gloryfitpro/utils/RkOtaUtil.java:55-74`
- Presenter chọn platform: `.../presenter/main/device/BleUpdatePresenter.java:64-77`
- Platform RK8773: `.../com/yc/utesdk/ble/open/DevicePlatform.java` (`isHasFunction_13(131072)`)
- Khoá AES: `.../com/yc/utesdk/ota/UteOtaUtils.java:5`; GloryFit cũ `.../com/yc/pedometer/FirmwareActivity.java:381`
- CHECK_PUB_KEYS + opcode + bank: `.../com/realsil/sdk/dfu/s/h.java`, `s/b.java`
- UUID: `.../com/realsil/sdk/dfu/m/o.java`, `s/j.java`
- Hằng DFU: `.../com/realsil/sdk/dfu/DfuConstants.java`
- AES native: `.../com/realsil/sdk/dfu/utils/AesJni.java`, `internal/base/BaseDfuTask.java`

**SDK công khai Realtek (đối chiếu mục 4, chỉ đọc, clone về scratchpad):**
- Repo: `github.com/rtkconnectivity/RTL87x3E-Common-SDK` (phủ RTL8763E/87x3E; không có RTL8773E).
- Khoá mặc định RSA-2048: `tool/Gadgets/default_rsa_key.pem`, `.pub`, hash `default_rsa_key_hash.bin`; `rtk_rsa.pem/.key`. Không có khoá ECDSA mẫu.
- Công cụ: `prepend_header.exe` (SHA256/CRC16/MP header, `/rsa`,`/ecdsa`), `rsa_key_generator.exe`, `resign_tool/…/resign_tool.exe`, `md5.exe`, `gui_package_tool/8773E` (.exe Windows — không chạy được trên mac).
- Script dual-bank: `board/evb/bt_pan_demo/mdk/dual_bank_after_build.bat` (BANK0/BANK1, chọn RSA/ECDSA).
- Tài liệu secure boot/eFuse: `UM002 Secure Enabled` (`realmcu.com/img/ipd/en_638247791881070184.pdf`).
