# 02 — Mặt đồng hồ / hình nền (custom watch face) trên Y25 (UTE / GloryFit)

> Nguồn: APK GloryFit `com.yc.gloryfit` 4.0.12, decompile bằng jadx (`research/jadx-out/sources/`).
> Mọi trích dẫn `file:dòng` tính từ `com/yc/pedometer/` (trừ khi ghi rõ khác).
> Một số hàm jadx dịch sai ("Code decompiled incorrectly"). Các hàm đó đã được đối chiếu lại bằng bytecode
> (`jadx -m fallback --single-class …`, xuất ra scratchpad, không sửa repo).
> Phần không đọc thẳng từ code được đánh dấu **(suy luận)**. Chưa gửi lệnh nào trong tài liệu này tới đồng hồ thật.

---

## 0. Kết luận nhanh

| Câu hỏi | Trả lời |
|---|---|
| Y25 có đổi được hình nền không? | **Có**, qua tính năng *mặt đồng hồ tùy chỉnh* (UI app: "Watch face → Custom" / `dial_custom`). Ảnh người dùng chọn trở thành **lớp nền (element type 17)** của một mặt đồng hồ dựng từ template; giờ, ngày, bước… được vẽ đè lên |
| Bit quyết định | **F3 `0x000100`** (`isSupportFunction_Third(256)`). Y25: F3 = `0xFED921`, `0xFED921 & 0x100 = 0x100` ⇒ **bật** |
| F2 `0x400000` (gate ở `WatchCenterFragment.java:235`) | **Không phải** gate hỗ trợ. Bit này chỉ quyết định app có gọi `requestMtu(247)` trước khi vào kho mặt đồng hồ hay không (cũng dùng ở Danh bạ, SOS). Y25 không bật bit này, nhưng driver đã xin MTU 247 lúc kết nối nên không ảnh hưởng |
| Nhánh nền tảng | Y25 **không** phải JX/Actions (F7 `0x8000` = 0, F13 = 0; tên không bắt đầu "AT"), **không** phải ZK (F13 `0x080000` = 0), **không** phải JieLi AC707 (F13 `0x040000` = 0) ⇒ dùng **luồng UTE chung**: lệnh `26 xx` + gói dữ liệu `27 xx xx` |
| Lấy độ phân giải ở đâu? | Từ **đồng hồ**: lệnh `26 01` (app gửi tự động mỗi lần kết nối khi F3 `0x100` bật). Không phụ thuộc chuỗi model/firmware |
| Có cần server không? | App GloryFit: **có**, trừ khi màn hình 240×240 (2 template có sẵn trong APK). Driver của ta: **không bắt buộc**. Định dạng file `.bin` và giao thức truyền đều đọc được đầy đủ ⇒ làm **hoàn toàn offline** được (tự dựng template) |
| Định dạng ảnh | RGB565, **big-endian** (byte cao trước). Nén RLE riêng của UTE khi `compatibleLevel ≥ 2` |
| Toàn vẹn | CRC-32 chuẩn (IEEE, như `java.util.zip.CRC32`) trên toàn bộ phần sau header 24 byte. Đồng hồ trả `26 03 01` nếu sai |
| Độ tin cậy | Gate và byte giao thức: **cao**. Chi tiết nén: **cao** (đã đối chiếu bytecode). Việc firmware chấp nhận template tối giản và việc tự hiển thị sau khi tải: **trung bình (suy luận)**. Độ phân giải Y25: **chưa biết**, phải gửi `26 01` |

---

## 1. Các cổng (gate) và đánh giá theo giá trị thật của Y25

Giá trị thật (đọc 2026-10-13): F7=`0x0888`, F6=`0x6C2A01`, F5=`0x243943`, F4=`0x756EDF`, F3=`0xFED921`,
F2=`0x005D78`, F1=`0x5BA0DC`; maxLen=244, F13=0, F12=0, F11=0, F10=`0x050000`, F9=`0x400200`, F8=`0x000420`.
Phép kiểm tra luôn là `(Fn & mask) == mask` (`column/GetFunctionList.java:10-105`).

| # | Điều kiện | Ở đâu | Tác dụng | Y25 | Kết quả |
|---|---|---|---|---|---|
| G1 | F4 `0x008000` (tai nghe) | `fragment/FragmentSmartPlay.java:735-743` | Nếu bật thì ẩn mục "Dial setting" | `0x756EDF & 0x8000 = 0` | Không phải tai nghe ⇒ tiếp tục |
| G2 | **F3 `0x000100`** | `fragment/FragmentSmartPlay.java:817-821` | Hiện mục `rl_dial_setting` (mở `WatchFaceActivity`, `:627-628`) | `0xFED921 & 0x100 = 0x100` | **Hiện** |
| G3 | **F3 `0x000100`** và không JX | `utils/SyncParameterUtils.java:312-318` | Mỗi lần kết nối, thêm lệnh 75 = `26 01` (đọc cấu hình mặt đồng hồ, `sdk/WriteCommandToBLE.java:2166-2169`, `:2649-2650`) | Bật, không JX | App **tự gửi `26 01`** |
| G4 | `isJXPlatform()` = platform quét được = 1 **hoặc** F7 `0x8000` **hoặc** F13 `0x010000` | `ble/DevicePlatform.java:32-46`; platform=1 khi adv chứa `55 55` hoặc tên bắt đầu `AT` (`ScanConnectProcess.java:194`, `:218`; `ble/SearchDeviceActivity.java:510`) | JX ⇒ dùng `ImageWatchFaceActivity` + `ActsDialCommandUtil` (giao thức khác hẳn) | F7, F13 = 0; tên `Y25(…)`; chip Realtek | **Không JX (suy luận cho phần adv)**: chưa chụp adv thô của Y25. Nếu adv chứa UUID `0x5555` thì app sẽ đi nhánh JX. Realtek nên gần như chắc là `2` (RK) |
| G5 | `isZKPlatform()` = F13 `0x080000` **và** `supportImageWatchFace` (byte 18 của phản hồi `26 01`) | `watchface/ui/WatchFaceActivity.java:28-37` | Nếu đúng: tab "Image watch face" (luồng ZK `26 0A`/`26 0B`). Nếu sai: tab **"Custom" (`WatchFaceCustomFragment`)** | F13 = 0 | **Tab Custom** |
| G6 | Không JX ⇒ `CustomWatchFaceActivity` | `watchface/ui/WatchFaceCustomFragment.java:72-77` | Màn chọn ảnh + màu chữ + "Sync" | — | Dùng luồng UTE chung |
| G7 | `isJLPlatformAC707()` = F13 `0x040000` | `onlinedial/acts/WatchFaceUtil.java:71-91` | JL ⇒ đóng gói khác (`…JL`) | F13 = 0 | Dùng `PicUtils.dealWithWatchFaceCustomData` (đóng gói chung) |
| G8 | Có template cho `type` + `dpi` | `watchface/ui/WatchFaceCustomFragment.java:81-110` (asset nội bộ chỉ có `240*240`, type 1 vuông / 2 tròn); còn lại tải từ server (`:82`, `:121-170`) | Không có template thì danh sách trống, người dùng không tùy chỉnh được trong app | Chưa biết độ phân giải | **Phụ thuộc** `26 01` + server (chỉ với app GloryFit) |
| G9 | F10 `0x000004` (AI watch face) | `fragment/FragmentSmartPlay.java:892-896` | Hiện mục "AI watch" (cũng dẫn tới đổi nền) | `0x050000 & 4 = 0` | Ẩn. Không ảnh hưởng tab Custom |
| G10 | F2 `0x400000` | `onlinedial/WatchCenterFragment.java:235-241`, `ContactsSelectActivity.java:206`, `SosCallActivity.java:112` | Chỉ để gọi `requestPhoneMtu()` (MTU 247, `sdk/WriteCommandToBLE.java:5315-5320`) | `0x005D78 & 0x400000 = 0` | Không liên quan việc hỗ trợ |

Không có gate nào dựa vào chuỗi model/firmware trong `onlinedial/` hay `watchface/` (đã grep `contains/startsWith/equals`).
Chuỗi firmware chỉ dùng làm tham số `btname` khi hỏi server (mục 6).

**Ghi chú về F13 / RTL8773:** `01-protocol.md` §1.4 giả định bit F13 `0x020000` (RTL8773). Y25 thật có **F13 = 0**, nên
`isRKPlatform8773()` = false và `getDevicePlatformType()` = 0 (`ble/DevicePlatform.java:56-73`). Giá trị này chỉ được gửi
lên server làm tham số `platform` cho kho mặt đồng hồ (`onlinedial/PostUtil.java:46-63`). Giao thức BLE không đổi.

---

## 2. Lệnh truy vấn: `26 01` (cấu hình mặt đồng hồ)

- App → đồng hồ (ghi `33F1`): `26 01` (`sdk/WriteCommandToBLE.java:2166-2169`).
- Đồng hồ → app: gói bắt đầu `26 01` (có thể về `33F2` hoặc `34F2`; cả hai parser đều chuyển opcode `0x26` vào
  `dealWithOnlineDial`, `sdk/BluetoothLeService.java:4447-4449`, `:4723-4724`, `:6891-6900`).
- Giải mã ở `onlinedial/OnlineDialUtil.java:95-127`, `:160-214`:

| Byte | Trường | Mã hóa | Ghi chú |
|---|---|---|---|
| 0..1 | `26 01` | | |
| 2..5 | `dialNumber`: id mặt đồng hồ online đang hiển thị | u32 BE | `FF FF FF FF` = không có mặt online nào đang hiện (`:160-164`). **(suy luận)** `FF FF FF FE` (= -2) là mặt tùy chỉnh/ảnh (khớp hằng `IMAGE_WATCH_FACE_BLE_ID = "-2"`, `OnlineDialUtil.java:49`) |
| 6..7 | Chiều rộng màn hình (px) | u16 BE | |
| 8..9 | Chiều cao (px) | u16 BE | |
| 10 | `screenType` | u8 | 1 = vuông, 2 = tròn, 3 = chữ nhật (`onlinedial/acts/WatchFaceUtil.java:24-26`) |
| 11..14 | `maxDataSize`: dung lượng tối đa của file mặt đồng hồ | u32 BE | Đồng hồ trả `26 03 02` nếu vượt |
| 15 | `compatibleLevel` | u8 (0 nếu gói ngắn hơn) | ≥ 2 ⇒ **nén RLE** ảnh (mục 4.4) |
| 16 | `watchFaceCount`: số khe mặt online | u8 (mặc định 1) | > 1 ⇒ app dùng luồng chọn khe `26 06`/`26 09`/`26 0D` khi cài từ kho |
| 17 | `cornerAngle`: bán kính bo góc màn hình | u8 | Dùng để bo góc ảnh nền (`CustomWatchFaceActivity.java:414-415`) |
| 18 | `supportImageWatchFace` | u8 > 0 | Chỉ dùng cho nền tảng ZK (G5). Nếu > 0 app gửi thêm `26 0A` |

Ví dụ **(giả định, chưa đo)** cho màn vuông 240×240, không có mặt online, tối đa 1 MB, level 0, 1 khe, không bo góc:
`26 01 FF FF FF FF 00 F0 00 F0 01 00 10 00 00 00 01 00 00`

Lệnh `26 01` chỉ đọc nên an toàn. Đây là bước đầu tiên nên chạy trên Y25 để biết độ phân giải.

Các lệnh `26 xx` khác (để tham khảo, `sdk/WriteCommandToBLE.java:2166-2244`, phản hồi `BluetoothLeService.java:6891-7019`):

| Lệnh | Ý nghĩa | Phản hồi |
|---|---|---|
| `26 02` | Chuẩn bị nhận file mặt đồng hồ | `26 02` ⇒ bắt đầu gửi dữ liệu |
| `26 03 00` | Báo đã gửi xong | `26 03 00` OK, `26 03 01` sai CRC, `26 03 02` file quá lớn |
| (đồng hồ tự gửi) | | `26 03 03 HH LL` gửi lại từ gói số `HHLL`; `26 03 04` đã xử lý xong một khối 4 KB, gửi tiếp |
| `26 06 idx` | Chọn khe sẽ ghi (nhiều khe) | `26 06` |
| `26 09` | Liệt kê khe: nhiều gói `26 09 n …` (mỗi mục 5 byte: `idx` + id u32 BE), kết thúc `26 09 FD` | |
| `26 0C n idx…` | Xóa mặt online ở các khe | `26 0C …` |
| `26 0D idx id(4, BE)` | Chuyển sang mặt online đã có trên đồng hồ | `26 0D 00` OK |
| `26 0A` / `26 0B …` | Mặt "ảnh" của nền tảng ZK (`OnlineDialUtil.java:142-158`, `WriteCommandToBLE.java:2225-2244`) | Không áp dụng cho Y25 |

---

## 3. Luồng trong app (nhánh không JX, `CustomWatchFaceActivity`)

1. Kết nối ⇒ `26 01` ⇒ lưu W, H, type, maxSize, level, góc (`OnlineDialUtil.java:105-122`).
2. Người dùng chọn template (asset 240×240 hoặc zip tải từ server), chọn ảnh (thư viện/camera), cắt **đúng W×H**
   (`CustomWatchFaceActivity.java:342-346`, kiểm tra kích thước `:325-329`), chọn màu chữ.
3. Ảnh được bo tròn (type 2) hoặc bo góc theo `cornerAngle` (`:410-418`), rồi ghép vào template
   (`PicUtils.changeWatchFaceBackgroundAndColor`, `onlinedial/PicUtils.java:403-428`).
4. Bấm "Sync" ⇒ dựng file nhị phân (`PicUtils.dealWithWatchFaceCustomData`, `:946-972` ⇒ `watchFaceBeansToData`, `:850-944`).
5. Gửi `26 02` (`CustomWatchFaceActivity.java:396-402`). Đồng hồ trả `26 02` ⇒ `onlineDialStatus(1)` ⇒
   `PicUtils.syncCustomDialData()` (`:392-401`) ⇒ `WriteCommandToBLE.sendOnlineDialData(bin)` (`sdk/WriteCommandToBLE.java:2280-2291`).
6. Gửi lần lượt các gói `27 seq …` lên `34F1` (mục 5). Cuối cùng gửi `26 03 00` và chờ kết quả.
7. Nhận `26 03 00` ⇒ "thành công". **Không có lệnh "kích hoạt" riêng** trong nhánh này
   (`WatchCenterFragment.java:130-137` chỉ gọi thêm lệnh với JX). **(suy luận)** Đồng hồ tự chuyển sang mặt vừa nhận.

Mặt đồng hồ tải từ kho (`WatchTransferDialog`) dùng **đúng giao thức truyền này**. File `.bin` từ server được gửi nguyên
văn (`onlinedial/WatchTransferDialog.java:369-416`).

---

## 4. Định dạng file mặt đồng hồ (`.bin`)

### 4.1 Template (đầu vào)

Thư mục template (asset `DialCustom/dial_2_square_240x240`, `dial_1_circle_240x240`, hoặc zip từ server). Mỗi thư mục con là một
**element**, tên thư mục ⇒ `type` (`onlinedial/ConfigType.java:112-251`). Trong thư mục có các ảnh PNG (sắp theo số: `00.png`, `01.png`…)
và **một** file `config_<W>x<H>_<X>x<Y>[_…].txt`. File config rỗng, thông tin nằm trong tên
(`PicUtils.java:484-520`).

| Thư mục | type | Ảnh | Ví dụ config (vuông 240) |
|---|---|---|---|
| `preview` | 10 | `1.png` + `preview_bg.png` + `scalepreview_<w>_<h>_<r>.txt` | `config_240x240_0x0` |
| `background` | **17** | `1.png` (**thay bằng ảnh người dùng**) | `config_240x240_0x0` |
| `timehour1` / `timehour2` | 57 / 58 | 14 ảnh `00..13` (chữ số giờ hàng chục / đơn vị) | `config_32x45_51x45` / `_83x45` |
| `timemin1` / `timemin2` | 59 / 60 | 14 ảnh | `_125x45` / `_157x45` |
| `hour2min` | 7 | dấu ":" | `config_32x45_104x45` |
| `timemonth1/2`, `timeday1/2`, `day2month` | 63/64, 65/66, 14 | | |
| `week` | 15 | 14 ảnh | |
| `ampm` | 16 | 4 ảnh | |
| `battery` | 8 | 5 mức | |
| `iconbluetooth` | 9 | 2 ảnh | |
| `iconstep`, `stepnum1..5`, `stepproccess` | 24, 38..42, 32 | | |

**(suy luận)** Trong 14 ảnh chữ số, `00..09` là số 0-9, `10..13` là ký tự phụ.

### 4.2 Chuyển ảnh sang byte (RGB565 big-endian)

`Rgb.RGB888ToRGB565` (`onlinedial/Rgb.java:62-64`):

```
rgb565 = ((c & 0xFF0000) >> 19) << 11 | ((c & 0x00FF00) >> 10) << 5 | (c & 0xFF) >> 3
byte[2i] = rgb565 >> 8 ; byte[2i+1] = rgb565 & 0xFF      // BIG-ENDIAN (Rgb.java:66-79, 286-385)
```

(`WatchFaceUtil.bmpToRgb565Byte` ghi little-endian nhưng chỉ dùng ở luồng ZK, không dùng ở đây.)

- **Nền (type 17)**: `antiAliasingBg(bg, x, y)` (`Rgb.java:330-385`). Thực chất là chuyển thẳng `W×H` pixel. Pixel bán trong suốt
  được trộn với màu đen. Nếu kết quả ≤ (16,8,16) thì đổi thành (17,9,17).
- **Chữ số/biểu tượng**: `antiAliasingDefault(bg, glyph, x, y, fontColor)` (`Rgb.java:286-328`). Pixel nào **khác đen thì
  tô bằng màu chữ đã chọn**. Pixel bán trong suốt được trộn với pixel nền tại `(x+i, y+j)`. Kết quả gần đen được đẩy thành (17,9,17).
  **(suy luận)** Firmware coi `0x0000` (đen tuyệt đối) là **màu trong suốt**, nên app tránh sinh ra màu đen thật ở viền chữ.
- **Preview (type 10)**: ảnh ghép (nền + chữ) thu về `scalepreview` (vd 174×174), đặt giữa `preview_bg.png` 240×240,
  rồi `bmpToRgb565Byte` (`PicUtils.java:757-758`, `Rgb.java:166-245`). Đây là ảnh thu nhỏ hiện trong danh sách mặt trên đồng hồ **(suy luận)**.

### 4.3 Bố cục file

`PicUtils.watchFaceBeansToData` (`onlinedial/PicUtils.java:850-944`). Các element được **sắp tăng dần theo type**
(`CustomWatchFaceDataBean.compareTo`, `watchface/custom/CustomWatchFaceDataBean.java:126-128`). Mọi số nhiều byte là **little-endian**.

```
[Header 24 B][Bảng element N × 24 B][00 00][Dữ liệu ảnh element 1][element 2]…
```

**Header (24 byte)**

| Offset | Giá trị | Nguồn |
|---|---|---|
| 0..3 | `FE FF FF FF` | `:919-925`. **(suy luận)** = id u32 LE `0xFFFFFFFE` (-2) = "mặt tùy chỉnh". File từ kho có thể mang id thật ở đây |
| 4..7 | `len` = độ dài phần sau header (bảng + 2 + ảnh), u32 LE | `:928-931` |
| 8..11 | CRC-32 của đúng phần đó, u32 LE | `:917`, `:932-935` |
| 12..13 | Rộng màn hình (từ `26 01`), u16 LE | `:936-937` |
| 14..15 | Cao màn hình, u16 LE | |
| 16 | `PicUtils.screenType` = **0** (trường không bao giờ được gán, khác `dialScreenType`) | `:34`, `:938` |
| 17 | `hasBg` = 1 | `:38`, `:939` |
| 18 | `FF` | `:940` |
| 19 | `compatibleLevel` (từ `26 01`) | `:941` |
| 20..23 | `FF FF FF FF` | `:942` |

**Mỗi mục trong bảng element (24 byte)** (`:886-905`):

| Offset | Trường |
|---|---|
| 0..1 | `type` u16 LE |
| 2..3 | `picWidth` u16 LE (từ config) |
| 4..7 | `startAddress` u32 LE, **tính từ đầu file** (gồm header). Mục đầu tiên = `(N+1)*24 + 2` (`:864`) |
| 8..9 | `picHeight` u16 LE |
| 10..11 | `x` u16 LE |
| 12..13 | `y` u16 LE |
| 14..15 | `animationTime` u16 LE = 0 |
| 16 | `animationCnt` = số ảnh trong element (vd 14 chữ số) |
| 17..23 | `00` |

Sau bảng là **2 byte `00 00`** (`:883`, mảng khởi tạo `new byte[2]`), rồi dữ liệu ảnh của từng element nối liền
(nhiều ảnh trong một element cũng nối liền). Nếu hai element có dữ liệu giống hệt nhau thì element sau trỏ `startAddress` vào element
trước và không chép lại dữ liệu (`:854-881`). Bước tối ưu này có thể bỏ.

### 4.4 Nén (chỉ khi `compatibleLevel ≥ 2`)

`dealWithWatchFaceCustomData`: `z = compatibleLevel >= 2` (`PicUtils.java:947`). Bytecode xác nhận: **chỉ khi `z` true**
mới nén (`if (r31 == 0) goto L229`). Bản Java của `defaultSDPathPicToBeans` (`:556-566`) bị jadx đảo điều kiện, **không tin bản đó**.
Không nén các type `1..3` (kim), `35..46`, `52..70` (gồm cả chữ số giờ/phút 57-60). Mọi type khác (gồm **nền 17**, preview 10,
ngày, bước…) được nén.

Mỗi ảnh nén độc lập (`Rgb.picDataCompress`, `onlinedial/Rgb.java:405-485`; header giả `30 10 Wbe Hbe 01 1B` chỉ để truyền W/H,
`:487-489`, **không** xuất hiện ở đầu ra):

```
out = u32LE(len(rowTable + rows)) + rowTable + rows
rowTable = H × u32LE(offset dòng), offset tính từ đầu rowTable; dòng 0 bắt đầu ở H*4
mỗi dòng = chuỗi block: [n][count][c1_hi c1_lo]…[cn_hi cn_lo]
          = n màu liên tiếp, mỗi màu lặp `count` lần (count ≤ 255, n ≤ 255)
```

Thuật toán từng dòng (dịch đúng theo bytecode):

```
pending=[]; prevCount=0; start=0; i=0; count=0
while i < W:
    if px[start]==px[i] and count != 255:
        count++; i++
        if i != W: continue
    color = px[start]
    if prevCount == 0:                                   block = [1, count, color]
    elif prevCount == count and pending[0] < 255:        block = pending + color; block[0] += 1
    else: rows += pending;                               block = [1, count, color]
    if i == W: rows += block; rowTable += u32LE(offset); offset += (byte của dòng)
    prevCount = count; pending = block; count = 0; start = i
```

Ví dụ một dòng 240 px gồm 100 px đen rồi 140 px trắng: `01 64 00 00 01 8C FF FF`.
Ba pixel khác màu A, B, C liên tiếp (mỗi pixel 1 lần): `03 01 A_hi A_lo B_hi B_lo C_hi C_lo`.

### 4.5 CRC

`Rgb.uteDataCrc32(0, data)` (`Rgb.java:157-164`), bảng `crc32_tab[1] = 0x77073096`. Đây là CRC-32/ISO-HDLC chuẩn
(init `0xFFFFFFFF`, đa thức phản chiếu `0xEDB88320`, xor cuối). Trong Kotlin: `java.util.zip.CRC32`.
Kiểm tra: `"123456789"` ⇒ `0xCBF43926`.

---

## 5. Giao thức truyền

`sdk/WriteCommandToBLE.java:2280-2383` (+ handler `:171-186`, timeout `onlinedial/OnlineDialTimeOut.java:15`, `:37-44`).

1. `L = maxcommunicationLength` = `min(maxLen ở 34F1, MTU-3)` (`BluetoothLeService.java:666-700`, `:826-846`).
   Y25: maxLen 244, MTU 247 ⇒ **L = 244** ⇒ mỗi gói chở **241 byte** dữ liệu.
2. App → `33F1`: `26 02`. Chờ `26 02`.
3. Gói dữ liệu, **ghi vào `34F1`** (`writeCharaBle5Gps`, `:311-313`):
   `27 seq_hi seq_lo <tối đa L-3 byte>`. `seq` đếm từ 0, u16 **BE**. Gói cuối có thể ngắn hơn.
4. Nhịp gửi: mỗi lần chờ `onCharacteristicWrite` (khóa busy). Cứ mỗi 10 gói (`seq % 10 == 0`, `seq > 0`) nghỉ thêm 20 ms.
5. **Chờ xử lý flash**: sau gói `seq` (không phải gói cuối), nếu `((seq+1)*241) / 4096` khác giá trị lần trước thì **dừng chờ `26 03 04`**.
   Hết 5 s mà không có thì vẫn gửi tiếp. Với L = 244: dừng sau seq 16, 33, 50, 67, …
6. `26 03 03 HH LL` ⇒ gửi lại bắt đầu từ gói `HHLL`. Bị yêu cầu gửi lại hơn 2 lần ⇒ chậm lại 100 ms/gói (`BluetoothLeService.java:6937-6946`).
7. Sau gói cuối: chờ 500 ms ⇒ `26 03 00` (`:2176-2179`).
8. Kết quả: `26 03 00` OK, `26 03 01` sai CRC, `26 03 02` quá lớn.
9. `26 03 01`/`02` có thể đến **giữa chừng** (đồng hồ huỷ nhận, màn đồng bộ trên đồng hồ tắt). App gốc dừng ngay (`stopOnlineDialData`).
   **Nguyên nhân trên HT43 (14/10/2026, đã sửa):** luồng ghi bị đứng ~5 s giữa một khối. Đồng hồ coi như hết khối, tự gửi `26 03 04`
   rồi `26 03 01`. Chỗ đứng là lệnh đọc RSSI định kỳ (3 s/lần) đi chung hàng đợi GATT với gói `27`; callback RSSI đến muộn/không đến
   nên hàng đợi chờ hết 5 s. Y25 chịu được khoảng đứng này (chỉ chậm đi), HT43 thì huỷ.
   Sửa: không đọc RSSI khi đang truyền (`BleQuiet.active`), RSSI chờ tối đa 1 s. Sau khi sửa: HT43 nhận 168 KB trong 29 s, 1 MB trong 2 phút 45 s.
   Bật `GloryFitDebug.trace` để ghi thời gian từng khối (adb: `--ez faceTrace true`).
   Driver: dừng ngay, gửi lại từ đầu một lần với nhịp 100 ms/gói; trong lúc truyền, `BleQuiet` hoãn mọi lần nối lại thiết bị khác.
   Ba khối liền không có `26 03 04` ⇒ coi như đồng hồ đã bỏ phiên, báo lỗi (trước đây gửi mù tiếp, mỗi khối chờ 5 s).

Không có ACK cho từng gói. Không có checksum trong từng gói. Toàn vẹn chỉ dựa vào CRC trong header.

---

## 6. Phụ thuộc server

| Mục đích | Endpoint | Tham số | Bắt buộc với driver của ta? |
|---|---|---|---|
| Template tùy chỉnh (zip: thư mục element như 4.1) | `POST https://www.ute-tech.com.cn/ci-yc/index.php/api/client/getWatchZips` (`net/NetServiceApi.java:58-59`; bản cũ `onlinedial/PostUtil.java:30`, `:73-90`) | `appkey`, `btname`, `type`, `dpi` ("WxH"), `angle`, `debug`. Bản mới mã hóa RSA cả body (`watchface/WatchFaceModelImpl.java:403-416`) | Không. Tự dựng template |
| Kho mặt đồng hồ (`.bin` dựng sẵn) | `…/api/client/getWatchs`, `…/getWatchsByBleId` (`WatchCenterFragment.java:277`, `:453`) | thêm `platform` (= 0 với Y25), `compatible`, `shape`, `maxCapacity`, `mac` | Không (trừ khi muốn mặt có sẵn) |

`btname` = chuỗi firmware `A1` cắt trước chữ `V` đầu tiên (`utils/BLEVersionUtils.java:19-25`).
Y25: `RB370L73ACV001205` ⇒ **`RB370L73AC`**. Server chọn template theo `btname` + `dpi`. Đây là chỗ duy nhất phụ thuộc model.

**Offline hoàn toàn được**: độ phân giải lấy từ `26 01`. Định dạng `.bin`, nén, CRC và giao thức truyền đều nằm trong app,
không cần khóa hay chữ ký từ server. Không nên phân phối lại các PNG template của GloryFit (bản quyền); nên tự vẽ bộ chữ số.

---

## 7. Kế hoạch cài đặt cho driver Kotlin (`sdks/gloryfit`)

### 7.1 Bước kiểm chứng (theo thứ tự, trên Y25 thật)

1. Gửi `26 01`, ghi lại toàn bộ phản hồi ⇒ W, H, type, maxSize, level, khe, góc. Lệnh này chỉ đọc.
2. Dựng file thử có **nền + giờ/phút** (vd nền đỏ đơn sắc), kiểm `len ≤ maxSize`.
3. Tải lên. Ghi lại mọi gói `26 03 xx`. Xem đồng hồ có tự chuyển sang mặt mới không **(suy luận: có)**.
4. Nếu đồng hồ từ chối template tối giản, bổ sung dần element (preview 10, ngày, pin…) theo bộ 240×240 của app.

### 7.2 Mã (phác thảo)

`Ute.kt`: thêm parser `26 01`.

```kotlin
data class DialParams(val currentId: Long, val width: Int, val height: Int, val screenType: Int,
                      val maxSize: Long, val level: Int, val slots: Int, val corner: Int, val imageFace: Boolean)

fun parseDialParams(p: ByteArray): DialParams? {
    if (p.size < 15 || u(p, 0) != 0x26 || u(p, 1) != 0x01) return null
    fun be32(i: Int) = (u(p, i).toLong() shl 24) or (u(p, i + 1).toLong() shl 16) or (u(p, i + 2).toLong() shl 8) or u(p, i + 3).toLong()
    return DialParams(be32(2), be16(p, 6), be16(p, 8), u(p, 10), be32(11),
        if (p.size > 15) u(p, 15) else 0, if (p.size > 16 && u(p, 16) > 0) u(p, 16) else 1,
        if (p.size > 17) u(p, 17) else 0, p.size > 18 && u(p, 18) > 0)
}
```

`UteWatchFace.kt` (file mới): RGB565, RLE, đóng gói.

```kotlin
object UteWatchFace {
    class Element(val type: Int, val w: Int, val h: Int, val x: Int, val y: Int, val frames: List<ByteArray>) // RGB565 BE
    private val NO_COMPRESS = (1..3) + (35..46) + (52..70)

    fun rgb565be(argb: IntArray): ByteArray = ByteArray(argb.size * 2).also { o ->
        argb.forEachIndexed { i, c ->
            val v = (((c and 0xFF0000) shr 19) shl 11) or (((c and 0xFF00) shr 10) shl 5) or ((c and 0xFF) shr 3)
            o[2 * i] = (v shr 8).toByte(); o[2 * i + 1] = v.toByte()
        }
    }

    fun rle(px: ByteArray, w: Int, h: Int): ByteArray {
        val table = java.io.ByteArrayOutputStream(); val rows = java.io.ByteArrayOutputStream()
        var offset = h * 4
        for (r in 0 until h) {
            val b = r * w * 2
            fun same(a: Int, c: Int) = px[b + 2 * a] == px[b + 2 * c] && px[b + 2 * a + 1] == px[b + 2 * c + 1]
            var pending = ByteArray(0); var prev = 0; var rowLen = 0; var start = 0; var i = 0; var count = 0
            while (i < w) {
                if (same(start, i) && count != 255) { count++; i++; if (i != w) continue }
                val hi = px[b + 2 * start]; val lo = px[b + 2 * start + 1]
                val block = when {
                    prev == 0 -> byteArrayOf(1, count.toByte(), hi, lo)
                    prev == count && (pending[0].toInt() and 0xFF) < 255 ->
                        (pending + byteArrayOf(hi, lo)).also { it[0] = (it[0] + 1).toByte() }
                    else -> { rows.write(pending); rowLen += pending.size; byteArrayOf(1, count.toByte(), hi, lo) }
                }
                if (i == w) { rows.write(block); table.write(le32(offset)); rowLen += block.size; offset += rowLen }
                prev = count; pending = block; count = 0; start = i
            }
        }
        val body = table.toByteArray() + rows.toByteArray()
        return le32(body.size) + body
    }

    fun build(width: Int, height: Int, level: Int, elements: List<Element>): ByteArray {
        val els = elements.sortedBy { it.type }
        val blobs = els.map { e ->
            e.frames.fold(ByteArray(0)) { acc, f -> acc + if (level >= 2 && e.type !in NO_COMPRESS) rle(f, e.w, e.h) else f }
        }
        val table = java.io.ByteArrayOutputStream()
        var addr = (els.size + 1) * 24 + 2
        els.forEachIndexed { k, e ->
            table.write(le16(e.type)); table.write(le16(e.w)); table.write(le32(addr)); table.write(le16(e.h))
            table.write(le16(e.x)); table.write(le16(e.y)); table.write(le16(0)); table.write(e.frames.size); table.write(ByteArray(7))
            addr += blobs[k].size
        }
        val body = table.toByteArray() + ByteArray(2) + blobs.fold(ByteArray(0)) { a, x -> a + x }
        val crc = java.util.zip.CRC32().apply { update(body) }.value.toInt()
        val hdr = ByteArray(24) { 0xFF.toByte() }
        hdr[0] = 0xFE.toByte()
        le32(body.size).copyInto(hdr, 4); le32(crc).copyInto(hdr, 8)
        le16(width).copyInto(hdr, 12); le16(height).copyInto(hdr, 14)
        hdr[16] = 0; hdr[17] = 1; hdr[19] = level.toByte()
        return hdr + body
    }
    private fun le16(v: Int) = byteArrayOf(v.toByte(), (v shr 8).toByte())
    private fun le32(v: Int) = byteArrayOf(v.toByte(), (v shr 8).toByte(), (v shr 16).toByte(), (v shr 24).toByte())
}
```

(Bản thật nên dùng `ByteArrayOutputStream` thay cho phép `+` lặp lại để tránh O(n²) với file vài trăm KB.)

`GloryFitDriver.kt`: thêm `queryDialParams()` và `uploadWatchFace()`. Cơ chế `waiter` hiện tại chỉ giữ một bộ lọc. Khi tải lên, đặt
waiter bắt **mọi** gói opcode `0x26` để nhận được cả `26 03 03` / `26 03 04` không đồng bộ.

```kotlin
suspend fun queryDialParams() = Ute.parseDialParams(request(bytes(0x26, 0x01)) { it.op == 0x26 && it.size > 1 && Ute.u(it, 1) == 1 })

suspend fun uploadWatchFace(bin: ByteArray, progress: (Int) -> Unit): Int = lock.withLock {
    val ch = Channel<ByteArray>(Channel.UNLIMITED)
    waiter = Waiter({ it.op == 0x26 }, ch)
    try {
        suspend fun next(sub: Int, ms: Long) = withTimeoutOrNull(ms) {
            var p: ByteArray; do { p = ch.receive() } while (Ute.u(p, 1) != sub); p }
        writeCommand(bytes(0x26, 0x02))
        next(0x02, 5_000) ?: throw GloryFitException("26 02 không có phản hồi")
        val l = minOf(features.maxPacketLength ?: 20, mtu - 3).coerceAtLeast(20)   // Y25: 244
        val n = l - 3
        val total = (bin.size + n - 1) / n
        var seq = 0; var lastSector = 0
        while (seq < total) {
            val from = seq * n; val to = minOf(bin.size, from + n)
            val pkt = byteArrayOf(0x27, (seq shr 8).toByte(), seq.toByte()) + bin.copyOfRange(from, to)
            gatt.write(Ute.SERVICE5, Ute.WRITE5, pkt, withResponse = true)
            progress((seq + 1) * 100 / total)
            ch.tryReceive().getOrNull()?.let { p ->                 // gửi lại do đồng hồ yêu cầu
                if (Ute.u(p, 1) == 3 && Ute.u(p, 2) == 3) { seq = Ute.be16(p, 3); return@let }
            }
            val sector = ((seq + 1) * n) / 4096
            if (seq < total - 1 && sector != lastSector) {
                lastSector = sector
                val r = next(0x03, 5_000)                            // 26 03 04 hoặc 26 03 03 HH LL
                if (r != null && Ute.u(r, 2) == 3) { seq = Ute.be16(r, 3); continue }
            } else if (seq > 0 && seq % 10 == 0) delay(20)
            seq++
        }
        delay(500)
        writeCommand(bytes(0x26, 0x03, 0x00))
        val r = next(0x03, 30_000) ?: throw GloryFitException("Không có kết quả 26 03")
        Ute.u(r, 2)   // 0 OK, 1 sai CRC, 2 quá lớn
    } finally { waiter = null }
}
```

(`mtu` là giá trị trả về từ `onMtuChanged`. Cần lưu lại khi gọi `requestMtu(247)`. Đoạn bắt `26 03 03` ở trên chỉ là phác thảo; bản thật
nên dùng một state machine nhỏ.)

API công khai (vd `setWallpaper(bitmap, fontColor = Color.WHITE)`):
1. `queryDialParams()` (cache theo kết nối).
2. Cắt giữa và scale ảnh về đúng W×H. Bo tròn nếu `screenType == 2`, bo góc `corner` nếu khác 0. Lấy pixel ARGB.
3. Dựng element: 17 (nền), 57-60 (giờ/phút với glyph của ta, đổi màu như `antiAliasingDefault`), 7 (":"), 10 (preview), tùy chọn ngày/pin.
4. `UteWatchFace.build(...)`, kiểm `size ≤ maxSize`, rồi `uploadWatchFace`.
5. Thêm `Capability.WATCH_FACE` khi F3 `0x100` bật, không JX/ZK/JL, và `26 01` trả W, H > 0.
6. Không chạy song song với đồng bộ lịch sử. Dùng chung `lock` như app (app chặn khi `SYNC_CLICK_ENABLE = false`).

### 7.3 Ví dụ byte (màn vuông 240×240, level 0 không nén, 6 element: 10, 17, 57, 58, 59, 60)

- Ảnh: preview 115 200 B, nền 115 200 B, mỗi nhóm chữ số `14 × 32 × 45 × 2` = 40 320 B.
- Địa chỉ: phần dữ liệu bắt đầu ở `(6+1)*24 + 2 = 170`. 10 ⇒ 170, 17 ⇒ 115 370, 57 ⇒ 230 570, 58 ⇒ 270 890,
  59 ⇒ 311 210, 60 ⇒ 351 530. Kết thúc ở 391 850.
- `len` = 144 + 2 + 391 680 = 391 826 = `0x0005FA92`.
- Header: `FE FF FF FF 92 FA 05 00 c0 c1 c2 c3 F0 00 F0 00 00 01 FF 00 FF FF FF FF` (`c0..c3` = CRC32 LE).
- Mục type 57 (giờ hàng chục, 32×45 tại (51,45), 14 ảnh, địa chỉ `0x000384AA`):
  `39 00 20 00 AA 84 03 00 2D 00 33 00 2D 00 00 00 0E 00 00 00 00 00 00 00`.
- Truyền với L = 244: 1 626 gói (1 625 gói đủ 241 B + 1 gói 225 B).
  - Gói đầu: `27 00 00 FE FF FF FF 92 FA 05 00 …` (244 B).
  - Gói cuối: `27 06 59 …` (228 B).
  - Dừng chờ `26 03 04` sau seq 16, 33, 50, … (khoảng 95 lần).
  - Kết thúc: `26 03 00` ⇒ chờ `26 03 00`.
- Thời gian ước tính **(suy luận)**: 15-60 s, tùy khoảng thời gian kết nối và thời gian xóa flash.

---

## 8. Rủi ro / chưa biết

| Mục | Mức |
|---|---|
| Độ phân giải, `maxSize`, `compatibleLevel` của Y25 | Chưa biết. Gửi `26 01` để biết |
| Adv của Y25 có UUID `0x5555` (⇒ app coi là JX) không | Chưa chụp. Realtek nên gần như chắc chắn là RK (suy luận) |
| Firmware có nhận template tối giản (chỉ nền + giờ/phút) không | Suy luận. Thử thực tế, nếu bị từ chối thì thêm element |
| Ý nghĩa ảnh 10..13 trong bộ chữ số, `week` 14 ảnh | Suy luận |
| Tự kích hoạt sau `26 03 00` | Suy luận (app nhánh không JX không gửi lệnh kích hoạt) |
| Rủi ro hỏng máy | Thấp **(suy luận)**: đồng hồ tự kiểm CRC và kích thước, trả `26 03 01`/`02` |
