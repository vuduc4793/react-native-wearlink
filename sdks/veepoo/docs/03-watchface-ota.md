# 03 — Mặt đồng hồ và cập nhật firmware (Veepoo, G Band 2.3.12)

> 19/10/2026. **Chỉ đọc mã đã dịch ngược**, chưa thử trên GE54. "CONFIRMED" = đọc thẳng trong mã; "INFERRED" = suy luận.
> Đường dẫn tương đối `S/` = `sdks/veepoo/research/android-gplusband-2.3.12/jadx-out/sources/` (gói `com/veepoo/protocol`
> và các gói đã làm rối tên). Bổ sung cho `01-protocol.md` §6 (opcode 0x50, 0xA2, 0xC7).
>
> **Không làm được bằng Java/Kotlin thuần** (chỉ có thư viện native): nén ảnh `ParTool.rawToPar` (`libabpartool.so`, mặt đồng
> hồ chip ZK/Bluetrum và đẩy ảnh), và 4 thư viện JieLi `libjl_auth.so` (xác thực RCSP), `libjl_bmp_convert.so`,
> `libjl_fatfs.so`, `libjl_crc.so`. Mặt đồng hồ dạng Veepoo gốc (RGB565, mục 1) thì làm được thuần.
> Bản build này: vài hàm tải firmware Goodix bị bộ thu gọn mã xoá thành `throw null` (`j8/e.java:55-120`); AGPS luôn gửi mốc
> thời gian 0 (app không gọi `setAGPSTimeStamp`).

## 0. Chọn tính năng theo bảng `A7` (CONFIRMED)

Gói `A7` trang 3 (`byte[19]==3`, `jf/y.java:321-362`):

| Byte | Trường |
|---|---|
| 1 | `bigDataTranType` |
| 2 | nibble cao `watchUiServerCount`, nibble thấp `watchUiCustomCount` |
| 9 | có AGPS (≠0) |
| 16 | `cpuType`: 0 Veepoo cũ, 1 JieLi, 3/4 ZK (Bluetrum; 4 = ZK569X), 5 Nordic mới (McuMgr) (`VpSpGetUtil.java:359-365, 806-812`) |

Trang 2 (`byte[19]==2`) byte 6 = số kiểu màn hình (`jf/y.java:259`). App mở mặt đồng hồ chợ khi `bigTranType==2 && watchuiServer>0`,
mặt tuỳ chỉnh khi `bigTranType==2 && watchuiCustom>0`, AGPS khi `bigTranType==2 && agps` (`util/UiUpdateUtil.java:567-577`).

## 1. Mặt đồng hồ Veepoo gốc: truyền "big data" (CONFIRMED)

- **Điều khiển:** opcode **0x50** ghi F0080003 (có phản hồi), trả về ở F0080002 (`mf/b.java:53`; định tuyến `g.java:409-422`:
  `byte1==2/3` → thông tin, `byte1==1` → thao tác).
- **Dữ liệu:** service UI F0030001: gói điều khiển "DOOG" (`44 4F 4F 47`) ghi **F0030002** có phản hồi; khối dữ liệu thô ghi
  **F0030003** không phản hồi; thiết bị báo trạng thái bằng notify **F0030002** (`VPOperateManager.java:4100-4102`, UUID `mf/a.java:149-151`).
- Loại (`EUIFromType`): 0 DEFAULT, 1 SERVER, 2 CUSTOM, 6 IMAGE_PUSH, 0xA1 A_GPS, 0xA2–0xA5 G15 (QR, hồ sơ, theme 1, theme 2).

### 1a. Đọc thông tin: `50 02 <type> 00…` (20 B, `jf/t2.java:253-261`)

Trả `50 02 <type> <1=ok> …`, số nhiều byte là little-endian (`t2.java:98-185`).

| Loại | Byte → trường |
|---|---|
| SERVER (`UIDataServer`, `:134-141`) | 4-7 địa chỉ nhận (u32); 8-11 dung lượng tối đa (u32); 12-13 `binDataType` (gửi server là "binProtocol"); 14-15 `deviceDialShape`; 16-17 `imgCrcId` (CRC mặt đang cài); 19 `packageIndex` |
| CUSTOM (`UIDataCustom`, `:37-52`) | 4-7 địa chỉ; 8-10 dung lượng (u24); 11 `EWatchUIType`; 12: bit7-5 `isDefaultUI`, bit4-0 `timePosition`; 13: nibble cao `upTimeType`, thấp `downTimeType`; 14-16 màu RGB888; 17-18 crc; 19 index |
| A_GPS (`:153-167`) | 4-7 địa chỉ; 8-11 dung lượng; 12-13 crc; 14 `validDay`; 15-16 `validMinute`; 19 index |
| G15 (`:169-176`) | 4-7 địa chỉ; 8-11 dung lượng; 12-13 crc; 19 index |
| IMAGE_PUSH (`:178-184`) | 4-7 dung lượng; 8-9 cao; 10-11 rộng; 12-13 bo góc; địa chỉ luôn 0 |

`EWatchUIType`: 1 ROUND_240_240, 2 RECT_240_240, 3 RECT_240_280, …; 48-90 và 123-132 JieLi; 91-124 ZK. Vị trí 1-7 = giữa-trên … phải-dưới;
thành phần 0 không, 1-2 ngày, 3 bước, 4 ngủ, 5 nhịp tim, 6 kcal, 7 quãng đường, 8 BT/pin.

### 1b. Đặt bố cục mặt tuỳ chỉnh

`50 03 02 [(isDefault<<5)|timePos] [(upType<<4)|downType] [màu LE24] 0…` (`t2.java:270-289`); trả về như đọc CUSTOM với `byte1=3`.
Màn tròn: màu chọn được ánh xạ qua `list_color_round_app` → `list_color_round_watch` (`EditPhotoFaceViewModel.java:265-282`).

### 1c. Trình tự tải (`util/UiUpdateUtil.java`)

1. MTU 247 ⇒ khối = MTU − 5, kẹp 20…512 (247 ⇒ 242 B) (`VPOperateManager.java:897-930`); bật notify F0030002 (`:551-565`).
2. Đọc file, đệm `0xFF` cho đủ bội 4 (trừ AGPS), tính **CRC-16/MODBUS** (bảng 0xA001 phản xạ, khởi 0xFFFF, không XOR cuối,
   `util/a.java:22, 133-142`); trùng CRC thiết bị báo ⇒ dừng `APP_CRC_SAME_DEVICE_CRC` (`:614-753`, đệm `:488-496`).
3. Đọc pin `A0`; pin yếu ⇒ dừng (`util/u.java:29-37`).
4. Vào chế độ cập nhật trên F0080003: `50 01 <type> [địa chỉ LE32] [độ dài LE32] …` (`t2.java:188-250`).
   SERVER: byte 11-12 `binDataType` LE16, 13-14 `imgCrcId` LE16, 15 = 01. A_GPS: 11-14 mốc thời gian LE32. Loại khác: còn lại 0.
   Trả `50 01 <type> <1=ok>` (`t2.java:120-131`).
5. Bắt đầu: ghi `44 4F 4F 47 05 00` lên F0030002 (AGPS: `… 05 01`) (`t2.java:298-301`).
6. Thiết bị báo `05 …` ⇒ app gửi xoá `44 4F 4F 47 01 [địa chỉ LE32] [độ dài LE32]` (13 B) (`UiUpdateUtil.java:810-819`).
7. Tiến độ xoá: `01 01 <tổng>` bắt đầu, `01 02 <n>` tiến độ, `01 03` xong ⇒ gửi dữ liệu (`:821-858`).
8. Khối thô (MTU−5 byte, không header) lên F0030003, khối sau gửi khi có write callback (`:364-396`); hết thì `44 4F 4F 47 02` đệm 20 B.
9. Thiết bị báo `02` ⇒ app gửi `44 4F 4F 47 03 [crc16 dạng LE32]` đệm 20 B (`t2.java:61-74`).
10. Thiết bị báo `03 crcLo crcHi` ⇒ khớp là xong, không thì `CHECK_CRC_FAIL`. Báo `00` = `FILE_LENGTH_NOT_4_POWER`.
    Notify kênh này có `byte1==0xD0` = ghi âm AI `[x, D0, seq LE16, len LE16, dữ liệu]` (`:771-808`).

### 1d. Mặt đồng hồ chợ (server)

- Danh sách: `GET https://www.vphband.com:9001/api/system/getthemes?dialShape=&binProtocol=&maxLength=&deviceNumber=&deviceVersion=&appType=<gói>&appVersion=`
  (`UiServerHttpUtil.java:39-53`) → JSON `TUiTheme {available, binProtocol, crc, dialShape, fileLenght, fileUrl, name, previewUrl}`.
- Cài: tải `fileUrl`, gửi nguyên file với loại SERVER (`DialManageViewModel.java:194-300`); rồi kích hoạt `C7 01 01 01` (`FaceGalleryFragment.java:109`).

### 1e. Mặt ảnh tuỳ chỉnh (`customui/WatchUIType.java:725-731`, `util/b.java:12-79`)

Hai ảnh nối nhau, **RGB565 big-endian, không nén**, mỗi ảnh đệm `0xFF` đủ bội 4: ảnh lớn (nền toàn màn) + ảnh nhỏ (khung `smallW×smallH`,
ảnh vẽ cỡ `content` tại (`broad`,`broad`), khung viền vẽ đè). Tải bằng loại CUSTOM sau khi đọc CUSTOM. Chọn "nền mặc định" = `C7 01 01 02`.

| Kiểu | Lớn | Nhỏ | Nội dung | Viền |
|---|---|---|---|---|
| Rect240280 | 240×280 | 172×198 | 152×178 | 10 |
| Round240 | 240×240 | 144×144 | 128×128 | 8 |
| Rect240240 | 240×240 | 188×188 | 174×174 | 7 |
| Round360 | 360×360 | 216×216 | 192×192 | 12 |
| Rect320380 | 320×380 | 230×268 | 202×240 | 14 |
| Rect80160 | 80×160 | 64×120 | 56×112 | 4 |

Chip ZK: `[LE32 len+4][PAR(lớn)][LE32 len+4][PAR(nhỏ)]`, PAR = `ParTool.rawToPar` (native, định dạng nén chưa rõ) (`WatchUIType.java:687-723`).

### 1f. Kiểu màn hình `C7` (`jf/a2.java`)

Đặt `C7 01 <index từ 1> <0 mặc định|1 server|2 tuỳ chỉnh> 0…`; đọc `C7 02 0…`. Trả (≥ 9 B) `C7 <1|2> <1=ok> <index> <loại>` + 7 id LE16
(byte 5-18). Nhiều gói: `C7 03 <stt> <tổng> …`.

### 1g. Đẩy ảnh/chữ `0x83`, G15, AGPS, mặt AI (tóm tắt)

- `83 01 01 A0 01 00 <0 chữ|1 ảnh>` bắt đầu, `83 01 01 A1 01 00 01` dừng; ảnh tải qua 0x50/DOOG loại 6 (`jf/r2.java`, `protocol/u.java`). G Band không dùng.
- G15 QR: TLV `A0 01 qrType A1 len nội dung A2 len tên A3 len nhóm A4 len số`, chia khung `BB 01 <mtu−2 B>` (`jf/n0.java:46-124`).
- AGPS: file `.pgl` từ `starcourse.location.io/…` (Trung Quốc: `rx-networks.cn`), tải loại A1, không đệm (`GpsEphemerisHelper.java:95-195`).
- Mặt AI: `E8 01 01 B4 07 00 <err> <len LE32> <crc LE16>`, thiết bị xin dữ liệu `B5/B6`, xong `B7` (`operate/AIFunctionOpt.java:555-725`).

## 2. Mặt đồng hồ chip JieLi (RCSP)

- Nhận diện: `cpuType==1` hoặc service AE00 có AE01 (ghi có phản hồi, khúc min(MTU,247)−5) / AE02 (notify) (`BleConnectWorker.java:364-381`).
- Khung RCSP: `FE DC BA | cờ (bit7 lệnh, bit6 cần trả lời) | opcode | len BE16 | thân | EF` (`ParseHelper.java:190-261`).
- **Xác thực** (`RcspAuth.java`): `FE DC BA C0 06 00 02 00 01 EF`, rồi thách đố 16 byte qua lại — mã hoá trong `libjl_auth.so` (INFERRED: thuật toán E1 của JieLi).
- File mặt: opcode 0x1A (ghi/đọc flash, thêm/xoá file, đặt mặt hiện tại, nền tuỳ chỉnh, kiểm CRC, dung lượng trống) (`CommandBuilder.java:121-195`);
  hai backend FatFs (hệ file chạy trên điện thoại, native) và Rcsp (thiết bị tự quản, truyền file lớn 0x21→0x27→0x1B, thiết bị kéo bằng 0x1D, xong 0x1C).
  CRC16 đa thức 0x1021, khởi 0 (INFERRED: XMODEM).
- Mặt chợ: xoá mặt server cũ, ghi `.bin` thành `"/"+TÊN 8.3 HOA`, đặt hiện tại (`JLWatchHolder.java:83-186`).
- Mặt ảnh: ảnh đúng cỡ màn, `BmpConvert.bitmapConvert` (native), ghi `/BGP_W000` (thu nhỏ) và `/BGP_W001` (lớn), bật nền tuỳ chỉnh.

## 3. Cập nhật firmware theo chip

- **Nguồn:** JieLi / Nordic mới / ZK: `GET https://cn.vpgband.com/api/v1/ota/info?mac=&deviceNumber=&deviceVersion=&lang=&sys=Android`
  → `{version, downloadUrl, md5, size, des, forceUpdate}`, kiểm MD5. Chip khác: `Version/GetVersionForSport…` (app để `isDebug=true` ⇒ host test).
  Cần pin ≥ 40% trừ khi đã ở DFU. `deviceNumber` = byte 4-5 (BE16) của phản hồi `A1`, phiên bản = byte 6.7.8 (+9 bản test).
- **Vào DFU:** `A2 00 00 01` trên F0080003, không đọc phản hồi; chờ 6 s, tìm MAC+1. Nhận nền tảng theo GATT: 00001530…/FE59 Nordic, A6ED0401… Goodix.
- **Nordic cũ/secure:** mã chết (thư viện có nhưng không khai báo `DfuService`).
- **Nordic mới (`cpuType 5`):** McuMgr/SMP (service `8D53DC1D-1DB7-4CD3-868B-8A527460AA84`, char `DA2E7828-FBCE-4E01-AE9E-261174997C48`), image 0 slot 1, CONFIRM_ONLY.
- **Goodix:** service A6ED0401 (0402 notify, 0403 dữ liệu 20 B, 0404 điều khiển); khung `44 47 | cmd LE16 | len LE16 | payload | tổng kiểm LE16`; 0x23/0x24/0x25.
- **ZK (Bluetrum, `cpuType 3/4`):** chạy trong firmware thường, service F003 (notify F031, ghi F032 không phản hồi); `CC AA 55 EE 12 19 E4` nhận diện,
  `91 seq 02 …` thông tin cập nhật, khối `A0 seq [địa chỉ LE32][độ dài LE32]…`, dữ liệu `20 seq …`, trạng thái `90 seq st`
  (00 khối sau, FF xong, FE tiếp tục, FD tạm dừng; 1 cùng firmware, 2 sai khoá, 11 sai CRC). Mặc định khối 4096, gói 240.
  Lưu ý: tên `CMD_OTA_INFO`/`CMD_GET_INFO` xuất hiện ở `mf/a.java`… chỉ là trình dịch ngược gán nhầm tên hằng Bluetrum trùng giá trị.
- **JieLi:** file `.ufw` trong zip; lệnh RCSP 0x03 → 0xE1 → 0xE2 → 0xE3 → thiết bị kéo 0xE5 → 0xE6 → 0xE7 (từng lệnh CONFIRMED, thứ tự INFERRED);
  thiết bị một bank nối lại MAC+1. Trong lúc cập nhật JieLi, mọi lệnh Veepoo khác bị chặn trừ 0xA0/0xA1.

Với dự án: chỉ nạp **firmware chính hãng** của đúng thiết bị (như `FirmwareUpdatable` của GloryFit), không sửa firmware.

## 4. Trạng thái driver Android (`sdks/veepoo/android`, 19/10/2026)

- **Mặt đồng hồ**: chỉ đường Veepoo gốc (`50` + DOOG, `VeepooWatchFace` + `VeepooDevice.installWatchFace`), bật khi `bigDataTranType` = 2,
  có mặt server/tuỳ chỉnh và chip **không** phải JieLi (1) / ZK (3, 4). Chưa kiểm trên thiết bị thật. JieLi (RCSP + `libjl_*`) và ZK (PAR)
  không làm vì cần thư viện native. GE54: JieLi + không màn hình ⇒ `supportsWatchFace = false`.
- **Firmware**: không làm (`FirmwareUpdatable` để mặc định "không hỗ trợ"); không gửi `A2`, không có đường OTA nào trong driver.
