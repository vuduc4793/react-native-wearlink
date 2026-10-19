# 05 — Phân tích firmware Y25 `RB370L73AC_V001205.bin`: có thay được mặt đồng hồ mặc định không?

> File: `research/firmware/RB370L73AC_V001205.bin`, 1 683 828 byte (`0x19B174`), SHA-256 `7d477c2d…3e55` (cách lấy file: xem `04-firmware.md`).
> Phương pháp: chỉ đọc file, không chạy, không kết nối mạng. Dùng script Python (`python3 -I`) để tách header, tính lại CRC/SHA-256 và kiểm
> tra chữ ký ECDSA. Đối chiếu với SDK DFU Realtek trong app GloryFit (`research/jadx-out/sources/com/realsil/sdk/dfu/…`).
> Không có trình disassembler ARM nên phần ý nghĩa của mã chỉ suy ra từ dữ liệu và bảng con trỏ. Phần nào không đọc thẳng từ byte hoặc từ code
> app thì ghi **(suy luận)**.
> Mọi offset dưới đây tính **từ đầu file** (trừ khi ghi "offset trong image" = file − `0x200`).

---

## 0. Kết luận nhanh

| Câu hỏi | Trả lời |
|---|---|
| File này là gì? | Một image Realtek **"App"** duy nhất (image id `0x2793`), có MP header 512 byte ở đầu. **Không** phải gói nhiều image con. |
| Có mã hoá không? | **Không** (cờ `enc` = 0, mã ARM Thumb đọc được) |
| Toàn vẹn | **CRC-16/ARC + SHA-256 + chữ ký ECDSA P-256**. Đã tính lại cả ba: **đều khớp** |
| Có ký số thật không? | **Có.** Chữ ký ECDSA P-256 ở `0x210` xác minh đúng bằng khoá công khai ở `0x3A0`. MP header còn chứa 4 byte hash khoá (`0x1D`), và giao thức DFU có lệnh `CHECK_PUB_KEYS` để đồng hồ so khoá. Không có khoá bí mật của UTE ⇒ **không tạo được image App hợp lệ "chính chủ"** |
| Secure boot có bật không? | **Không xác định được từ file** (phụ thuộc eFuse). Có dấu hiệu đồng hồ biết khoá tin cậy (lệnh `CHECK_PUB_KEYS`), nên phải coi như **có kiểm tra chữ ký** **(suy luận)** |
| Mặt đồng hồ mặc định nằm đâu? | **Không nằm trong file này.** Firmware chỉ chứa **con trỏ tuyệt đối** tới ảnh trong vùng flash `0x02694000–0x03000000` (~9,4 MB, flash ánh xạ bộ nhớ). Có một bảng **6 mặt đồng hồ dựng sẵn** 466 × 466 ở `0x1841D4` (mã mặt kiểu kho UTE: 19032001, 19031001, 18974001, 18973001, 11506001, 11494001) |
| Vùng "entropy thấp" 1,12–1,57 MB | Là **bảng chuỗi UTF-16 đa ngôn ngữ** (Anh, Nhật, Ba Lan, Việt…) và bảng số thực của thuật toán. **Không có ảnh** (đã thử giải mã RGB565 và RLE của UTE: chỉ ra nhiễu) |
| Tự làm công cụ đóng gói Realtek được không? | **Định dạng thì làm được** (mục 5 mô tả đủ từng byte). **Ký thì không**: thiếu khoá bí mật. Thêm nữa, tài nguyên giao diện không có trong file và không đọc ngược được từ đồng hồ qua BLE |
| Khuyến nghị | **Không** sửa firmware. Dùng **mặt đồng hồ tuỳ chỉnh** (đã chạy được trên Y25, xem `02-watchface.md`). Mặt này được lưu lại và hiển thị như mặc định cho tới khi khôi phục cài đặt gốc. Muốn có mặt mặc định thật thì nhờ UTE/nhà máy làm |
| Độ tin cậy | Bố cục header, CRC/SHA/chữ ký: **cao** (đã kiểm tra lại bằng tính toán). Vị trí tài nguyên và bảng 6 mặt dựng sẵn: **trung bình–cao**. Bản đồ flash chi tiết, secure boot, đường OTA tài nguyên: **thấp–trung bình (suy luận)** |

---

## 1. Bố cục tổng thể

```
0x000000 ─ 0x0001FF   MP header (TLV, 512 B)                       ← chỉ dùng cho công cụ/DFU, không ghi vào flash (suy luận)
0x000200 ─ 0x00032F   Auth header (304 B = AUTH_HEADER_BUF_SIZE)   ← chữ ký + SHA-256
0x000330 ─ 0x00033B   Ctrl header (12 B)                           ← CRC16, ic_type, flag, image id, payload_len
0x00033C ─ 0x0005FF   Phần còn lại của image header (UUID, địa chỉ, magic, version, khoá công khai)
0x000600 ─ 0x19B173   Payload = mã + dữ liệu App, nạp/chạy XIP tại 0x0209C400
   0x000600 ─ ~0x118000   mã ARM Thumb (entropy ≈ 7,0)
   ~0x118000 ─ 0x188000   chuỗi UTF-16 đa ngôn ngữ, bảng hằng, bảng con trỏ (entropy 4–6)
   0x188000 ─ 0x19B173    toàn 0 (vẫn thuộc payload, nằm trong vùng được băm/ký)
```

Image (từ `0x200`) dài `0x19AF74` = 1 683 316 byte = header `0x400` + payload `0x19AB74`. Khớp với cả MP header lẫn ctrl header.

Ảnh tổng quan entropy: `research/firmware/extracted/fw_entropy_map.png`.

### 1.1 MP header (`0x000`–`0x1FF`)

Dạng TLV: `[id u16 LE][len u8][value]`. Parser trong app: `com/realsil/sdk/dfu/image/stream/BaseBinInputStream.java` (hàm `e()`).

| Offset | id | len | Giá trị | Ý nghĩa (theo app) |
|---|---|---|---|---|
| `0x000` | `0x01` | 2 | `00 03` → `0x0300` | binId |
| `0x005` | `0x02` | 4 | `1` | binVersion |
| `0x00C` | `0x03` | 32 | `"RTL8763E"` | partNumber (họ chip) |
| `0x02F` | `0x04` | 4 | `0x0019AF74` | mpDataLength = độ dài image (không tính MP header) |
| `0x036` | `0x11` | 1 | `2` | otaVersion |
| `0x03A` | `0x12` | 2 | `0x2793` | **imageId = App** (bảng `BinIndicator`: `com/realsil/sdk/dfu/image/b.java:20`) |
| `0x03F` | `0x14` | 4 | `0x0019AF74` | mpImageSize |
| `0x046` | `0x15` | 1 | `0` | secureVersion (chống hạ cấp) = 0 |
| `0x04A` | `0x16` | 4 | `0x96A01040` | imageVersion, định dạng `L_4_8_9_11` ⇒ **0.4.1.1205** (khớp `V001205`) |
| `0x051` | `0x1B` | 4 | `0x110` | vị trí SHA-256 trong image (file `0x310`) |
| `0x058` | `0x1C` | 4 | `0x0209C000` | địa chỉ flash của image (app không đọc trường này, tên do suy luận) |
| `0x05F` | `0x1D` | 4 | `98 5B 8A C4` | **pubKeyHash** = 4 byte **cuối** của SHA-256(khoá công khai 65 B). **Đã kiểm chứng: khớp** |
| `0x066` | `0xFE` | 1 | `1` | kết thúc/đánh dấu (suy luận) |
| `0x069`–`0x1FF` | | | `00` | đệm |

MP header **không có checksum riêng**.

### 1.2 Auth header (`0x200`–`0x32F`, 304 byte)

| Offset file | Offset image | Độ dài | Nội dung |
|---|---|---|---|
| `0x200` | `0x000` | 16 | `FF ×16` (dành riêng) |
| `0x210` | `0x010` | 256 | Vùng chữ ký. Dùng 64 byte đầu = **ECDSA P-256 `r‖s` (big-endian)**, còn lại `00` |
| `0x310` | `0x110` | 32 | **SHA-256** |

### 1.3 Ctrl header (`0x330`–`0x33B`) — dạng `[crc16][ic][secver][flag][id][len]` (parser `com/realsil/sdk/dfu/h/e.java`)

| Offset | Trường | Giá trị |
|---|---|---|
| `0x330` | crc16 (u16 LE) | `0xCA7B` |
| `0x332` | ic_type | `0x11` (app có nhánh riêng cho ic 17: SHA ở offset 272 = `0x110`, `BaseBinInputStream.a()`) |
| `0x333` | secure_version | `0` |
| `0x334` | ctrl_flag (u16 LE) | `0x0101` ⇒ bit0 `xip`=1, bit1 `enc`=**0** (không mã hoá), bit8 `not_obsolete`=1. Bit `integrity_check_en_in_boot` (bit 9 theo bố cục Bee2) = 0 **(suy luận, bố cục bit lấy từ SDK Bee2 công khai)** |
| `0x336` | image_id | `0x2793` (App) |
| `0x338` | payload_len (u32 LE) | `0x0019AB74` |

### 1.4 Phần còn lại của image header (`0x33C`–`0x5FF`)

| Offset | Giá trị | Ý nghĩa |
|---|---|---|
| `0x33C` | `98 76 46 A1 9A 69 EE 11 A4 2F 6D 75 07 09 EB 1E` | UUID |
| `0x34C` | `0x0209C400` | exe_base (địa chỉ chạy, XIP) |
| `0x350` | `0x0209C400` | load_base |
| `0x354` | `0` | load_len |
| `0x358` | `0x0209C000` | địa chỉ header image trong flash |
| `0x360` | `0x5A5A12A5` | **magic pattern** của image Realtek |
| `0x374`–`0x384` | `0x0209C400, 0x0020A800, 0x00028000, 0x0000C000, 0x00004000` | thông số bố cục bộ nhớ/vùng app (chưa rõ từng trường, suy luận) |
| `0x390` | `40 10 A0 96 B2 36 00 85` | version (`0x96A01040`) + 4 byte có thể là git hash (suy luận) |
| `0x3A0` | 65 byte bắt đầu `04 B1 8F A9…` kết thúc `…ED E7 B9` | **Khoá công khai ECDSA P-256** dạng không nén (`04‖X‖Y`). Đã kiểm tra: điểm nằm trên đường cong P-256 |
| `0x3E1`–`0x5FF` | `00` | |

### 1.5 Kiểm tra lại checksum và chữ ký (đã tính, không phỏng đoán)

| Trường | Thuật toán | Dữ liệu được tính | Kết quả |
|---|---|---|---|
| crc16 `0x330` | **CRC-16/ARC** (đa thức phản chiếu `0xA001`, init 0, không xor cuối) | file `0x332` → hết file | `0xCA7B` — **KHỚP** (thử cả XMODEM, CCITT-FALSE, MODBUS, KERMIT: không khớp) |
| SHA-256 `0x310` | SHA-256 | file `0x330` → hết file (ctrl header + header + payload, **gồm cả crc16**) | `85EBDF6E…556E1BED` — **KHỚP** |
| Chữ ký `0x210` | **ECDSA P-256**, e = SHA-256(file `0x310` → hết file), `r‖s` big-endian | khoá ở `0x3A0` | **XÁC MINH ĐÚNG** (tự cài P-256 bằng Python, đã thử mọi tổ hợp; chỉ đúng tổ hợp này) |
| pubKeyHash MP `0x1D` | 4 byte cuối SHA-256(65 byte khoá) | `0x3A0`–`0x3E0` | `98 5B 8A C4` — **KHỚP** |
| (thử thêm) CRC-32 / tổng byte | | | Không trường nào khớp ⇒ không có CRC-32 |

Thứ tự tính khi đóng gói (suy ra từ phạm vi): **CRC16 → SHA-256 → chữ ký** (SHA bao gồm crc16, chữ ký bao gồm SHA).

---

## 2. Bảo vệ toàn vẹn: chỉ checksum hay chữ ký thật?

**Có chữ ký mật mã thật**, không chỉ checksum:

1. Image mang chữ ký ECDSA P-256 hợp lệ và khoá công khai. Ai cũng tính lại được CRC16 và SHA-256, nhưng **chữ ký thì chỉ tạo được khi có khoá bí mật** của UTE/Realtek.
2. MP header có `pubKeyHash`. SDK DFU (`com/realsil/sdk/dfu/s/h.java:47-79`, `x/n.java:784`) gửi lệnh **`OPCODE_DFU_CHECK_PUB_KEYS` (0x12)** gồm `imageId + 4 byte hash khoá` khi `specVersion ≥ 6`. Đồng hồ trả khác `1` thì báo lỗi `ERROR_DFU_PUB_KEYS_CONFLICT`. Như vậy **đồng hồ biết hash của khoá được tin cậy** và từ chối image ký bằng khoá khác **(suy luận về hành vi phía đồng hồ, dựa trên giao thức)**.
3. Có `secure_version` (chống hạ cấp). Hiện bằng 0, nên chưa có chặn hạ cấp theo số này.
4. Lớp truyền DFU có thể mã hoá AES. App đặt `DfuConfig.setSecretKey(...)` bằng khoá 32 byte cứng trong `com/yc/pedometer/FirmwareActivity.java:381` (`DeviceInfo.isAesEncryptEnabled`, chế độ `AES_MODE_16_FIRST/16_N`). Đây là **mã hoá đường truyền, không phải chữ ký**. Khoá có sẵn trong app nên không phải rào cản.

Bằng chứng **chống** "secure boot bắt buộc":
- Cờ `integrity_check_en_in_boot` có vẻ = 0 (suy luận theo bố cục Bee2).
- Trên chip Realtek, việc ROM kiểm chữ ký lúc khởi động phụ thuộc **eFuse** (bit bật secure boot + hash khoá). File OTA không cho biết eFuse của Y25. Tài liệu công khai `UM002 Secure Enabled` của Realtek xác nhận: bootloader so **public key trong image với hash khoá trong eFuse**, rồi **verify chữ ký**; mỗi khách hàng một khoá riêng burn vào eFuse ⇒ image sửa đổi/ký khoá khác không chạy được (xem `07-ota-realtek.md` §4.3).

⇒ **Kết luận:** ở bước DFU đồng hồ so hash khoá (`CHECK_PUB_KEYS`); ở bước boot, secure bootloader so public key với hash eFuse rồi verify chữ ký. Một image App sửa đổi phải được **ký lại** bằng khoá bí mật của UTE. **Giả thuyết "khoá mặc định Realtek" đã bị bác**: SDK công khai `RTL87x3E-Common-SDK` chỉ kèm khoá **RSA-2048** mặc định (hash `d3e58130…`), khác thuật toán và khác hash `985b8ac4` của Y25 (ECDSA P-256); SDK không kèm khoá ECDSA mẫu; quét SDK không thấy khoá/hash Y25. ⇒ khoá là **riêng của UTE**. Chi tiết + bằng chứng: `07-ota-realtek.md` §4.

---

## 3. Tài nguyên giao diện (ảnh, font, mặt đồng hồ dựng sẵn) nằm ở đâu?

### 3.1 Không có trong file OTA

- Vùng entropy thấp `0x118000–0x188000` là **chuỗi UTF-16LE đa ngôn ngữ** (nối liền, không căn chẵn, nên có đoạn trông như BE), ví dụ "Menstrual Period" ở `0x128000`, tiếng Nhật ở `0x130000`, tiếng Ba Lan ở `0x158000`, tiếng Việt ở `0x170000`. Phần còn lại là bảng số thực và bảng con trỏ (`0x180000`). `0x188000` → hết file toàn 0.
- Thử giải mã ra ảnh để đối chứng âm tính:
  - `extracted/rgb565be_0x130000_w466.png` và `extracted/rgb565le_0x158000_w466.png`: RGB565 rộng 466, chỉ ra **nhiễu**.
  - Quét RLE của UTE (`u32 len + bảng offset dòng bắt đầu bằng H*4`): chỉ có các dương tính giả là bảng chỉ mục nhỏ (H ≤ 67).
  - Quét header file mặt đồng hồ UTE: không có `FE FF FF FF` kèm W/H.
  - Một ảnh toàn màn RGB565 = 434 312 byte, trong khi cả vùng dữ liệu chỉ ~450 KB và toàn là chữ.
- Firmware dùng bộ GUI của Realtek (HoneyGUI): có tên hàm `gui_dc_info_register`, `gui_filepath_transforming`, `draw_img_cache`, `hal_imdc_decompress_rect`, `hw_acc_imdc_decode`, bộ cấp phát TLSF (khoảng `0x121140`–`0x121760`). Ảnh có thể được nén IMDC bằng phần cứng **(suy luận)**.

### 3.2 Firmware trỏ thẳng tới ảnh trong flash ngoài vùng App

Flash được ánh xạ vào bộ nhớ tại `0x02000000`. App nằm ở `0x0209C000–0x02236F74`. Trong mã có **hơn 4 000 hằng 32-bit** trỏ vào `0x0224xxxx–0x02Fxxxxx`, phần lớn gom thành bảng (ví dụ 95 bảng ≥ 4 con trỏ liên tiếp, giá trị chủ yếu `0x0287xxxx–0x02CBxxxx`). Đa số con trỏ chỉ chẵn 2 byte, khớp với dữ liệu ảnh 16-bit đặt nối nhau. Như vậy **địa chỉ ảnh được "đóng cứng" vào mã App lúc biên dịch**.

Bản đồ flash suy ra (flash 16 MB, `0x02000000–0x03000000`) **(suy luận, trừ dòng có ghi "đọc thẳng")**:

| Vùng | Địa chỉ | Kích thước | Bằng chứng |
|---|---|---|---|
| Cấu hình / OTA header hệ thống | `0x02002000`, `0x02004000`, `0x02007000` | | Hằng trong mã DFU (`0x501C4`) |
| UPPER_STACK | `0x02016000` | `0x3F000` | **Đọc thẳng**: bảng phân vùng `0x1190A8` (tên ở `0x181F18`) |
| **App (file này)** | `0x0209C000` (mã từ `0x0209C400`) | `0x19AF74` | **Đọc thẳng**: MP header + image header |
| VP (giọng nói/âm báo) | `0x022A0000` | `0x32000` | **Đọc thẳng**: bảng phân vùng `0x1190DC` |
| FTL | `0x022D2000` | `0x8000` | **Đọc thẳng**: bảng phân vùng `0x119074` |
| Dữ liệu UTE (LittleFS? ) | `0x02496000` / `0x02498000` … | ~1 MB | Hằng dùng nhiều lần |
| Vùng 1 MB chưa rõ (có thể là khe mặt đồng hồ tuỳ chỉnh/online) | `0x02594000–0x02694000` | 1 MB | Bảng `0x11AB88` = {`0x02594000`, `0x02DFF000`, `0x02EFF000`} |
| **Tài nguyên GUI** (ảnh, font, mặt dựng sẵn) | **`0x02694000–0x03000000`** | **`0x96C000` (~9,4 MB)** | Mã DFU (`0x501B0`) có ngay cạnh nhau: magic `0x5A5A12A5`, `0x02694000`, `0x0096C000`. Mọi con trỏ ảnh/mặt đồng hồ đều rơi vào vùng này |

### 3.3 Bảng mặt đồng hồ dựng sẵn (`0x1841D4`, 6 mục × 40 byte)

Mỗi mục: `[fn][dial_id u32][0][w u16=466][h u16=466][1][địa chỉ tài nguyên][fn][0][0]` (tên trường là suy luận; 466 × 466 và địa chỉ đọc thẳng).

| # | Offset | dial_id (hex) | dial_id (thập phân) | Địa chỉ tài nguyên | Khoảng cách tới mục kế (byte) |
|---|---|---|---|---|---|
| 1 | `0x1841D4` | `0x012267C1` | **19032001** | `0x0286E6A4` | — |
| 2 | `0x1841FC` | `0x012263D9` | **19031001** | `0x02813BCE` | 371 414 |
| 3 | `0x184224` | `0x01218531` | **18974001** | `0x027C7214` | 313 786 |
| 4 | `0x18424C` | `0x01218149` | **18973001** | `0x02776610` | 330 756 |
| 5 | `0x184274` | `0x80AF9151` | 11506001 + bit 31 | `0x026F90B2` | 513 374 |
| 6 | `0x18429C` | `0x80AF6271` | 11494001 + bit 31 | `0x026E64EC` | 76 742 |

- `dial_id` có dạng giống mã mặt đồng hồ trong kho của UTE (`…001`). Đây chính là `dialNumber` mà lệnh `26 01` trả về (u32 BE, `02-watchface.md` §2) **(suy luận)**. **Cách kiểm chứng an toàn:** để đồng hồ hiện mặt mặc định rồi gửi `26 01` (chỉ đọc). Byte 2..5 nên là `01 22 67 C1` hoặc một mã khác trong bảng trên.
- Mỗi mặt chiếm khoảng 75–510 KB, hợp với một gói mặt đồng hồ 466 × 466 đã nén. Rất có thể đó là file `.bin` mặt đồng hồ UTE (như `02-watchface.md` §4) được ghi sẵn vào vùng tài nguyên **(suy luận, không kiểm chứng được nếu không có bản dump flash)**.
- Bảng khác ở `0x11B8F8`: `d2 01 d2 01` (466 × 466) rồi chuỗi con trỏ `0x028DEAA6, 0x028DECD6, 0x028DEF34…`, cách nhau 0x230–0x7BE byte. Có thể là bộ chữ số/biểu tượng của một mặt **(suy luận)**.

### 3.4 Đường cập nhật tài nguyên (UI)

- App có API `getBtUIVersionUpdate` (`com/yc/server/yc_sdk/Agent.java:400-460`). Khi có bản UI mới thì `rkUpdateType = 3` và gói UI được gửi bằng **cùng cơ chế Realtek DFU** (`FirmwareActivity.java:1082-1088`, `startOtaProcess8762C`).
- App chỉ hỏi phiên bản UI khi bit F5 `0x400000` bật (`Updates.java:352`). **Y25 không bật bit này**, và server chưa từng phát gói UI cho model này. Như vậy chưa có mẫu file gói tài nguyên nào để học định dạng.
- Mã DFU trong firmware có tham chiếu tới vùng `0x02694000` (magic + kích thước). Có thể bộ DFU **ghi được** image tài nguyên vào đó, nhưng cũng có thể chỉ để kiểm tra/bảo vệ vùng này **(suy luận)**.

---

## 4. Đánh giá khả thi: "thay mặt đồng hồ mặc định"

### 4.1 Cách A — Sửa image App rồi OTA (ví dụ đổi mặt mặc định sang mặt tuỳ chỉnh)

Công cụ cần làm:
1. Dịch ngược (disassemble) mã ARM, tìm chỗ chọn mặt mặc định khi khởi động/khôi phục gốc, rồi vá vài byte. Việc này **khó**: không có ký hiệu (symbol), và địa chỉ ảnh đóng cứng khắp nơi.
2. Đóng gói lại theo mục 5: sửa `payload_len`, CRC-16/ARC, SHA-256, **chữ ký ECDSA**, khoá công khai, MP header (`0x04`, `0x14`, `0x1D`, `0x16`).
3. Truyền bằng Realtek GATT DFU (giao thức có trong `com/realsil/sdk/dfu`, khoá AES đường truyền lấy từ app).

**Chặn ở bước 2:** chữ ký phải dùng khoá bí mật của UTE. Ký bằng khoá của ta thì `pubKeyHash` khác và rất có thể bị đồng hồ từ chối.
- Nếu bị từ chối ngay ở DFU thì không có gì được kích hoạt, ít rủi ro.
- Nếu được nhận (secure boot tắt và DFU không so khoá) nhưng bản vá lỗi, App có thể treo. Khi đó không còn lệnh "vào chế độ OTA" từ App, có thể **brick** và phải cứu bằng UART/MP Tool của Realtek. Bản OTA gốc đã ký (file này) chỉ cứu được nếu đồng hồ còn vào được chế độ DFU.

⇒ **Không khả thi một cách an toàn.** Ngay cả khi làm được, nó cũng **không** thay được *ảnh* của mặt dựng sẵn, vì ảnh nằm ở vùng tài nguyên.

### 4.2 Cách B — Thay vùng tài nguyên (`0x02694000–0x03000000`)

Công cụ cần làm:
1. Có **toàn bộ** image tài nguyên gốc (~9,4 MB). File OTA không chứa nó, server không phát cho Y25, và giao thức BLE không có lệnh đọc flash.
2. Giữ **đúng từng địa chỉ** của mọi ảnh khác, vì App trỏ cứng vào chúng. Chỉ thay được ảnh mới cùng kích thước hoặc nhỏ hơn, đúng chỗ cũ.
3. Đóng gói thành image Realtek (header như mục 1, image id của vùng dữ liệu/tài nguyên, chưa biết) **và ký**. Gặp lại vấn đề chữ ký.

⇒ **Không khả thi** nếu không có bản dump flash và khoá ký. Muốn dump flash thì phải mở máy, dùng UART/SWD. Việc này nằm ngoài phạm vi và có rủi ro.

### 4.3 Cách C — Mặt đồng hồ tuỳ chỉnh qua giao thức UTE (đã chạy được) ✅

- Định dạng `.bin` (RGB565 BE, RLE UTE, CRC-32) và giao thức `26 xx` / `27 xx` đã được làm rõ và **đã kiểm chứng trên Y25 ngày 13/10/2026** (`02-watchface.md`, `03-watchface-elements.md`).
- Mặt này nằm ở vùng dữ liệu riêng (có thể là vùng 1 MB `0x02594000`, suy luận), **không** cần ký, không động tới App hay tài nguyên ⇒ **không có nguy cơ brick**.
- Sau khi gửi, đồng hồ hiển thị mặt này và giữ lại qua các lần khởi động lại. Nó chỉ mất khi khôi phục cài đặt gốc (suy luận, nên thử) hoặc khi người dùng chọn mặt khác.
- Nếu `watchFaceCount > 1` (byte 16 của `26 01`) thì có thể giữ nhiều mặt và chuyển qua lại bằng `26 0D`.

### 4.4 Cách D — Nhờ UTE / nhà máy

Đây là cách duy nhất để có mặt **dựng sẵn thật** (xuất hiện sau khi khôi phục gốc, có trong danh sách mặc định). UTE đóng gói lại tài nguyên và App bằng khoá của họ rồi phát qua OTA. Thông tin cần gửi: xem `04-firmware.md` §3.

---

## 5. Đặc tả cho công cụ đóng gói image Realtek (để tham khảo, **không** tự flash)

Áp dụng cho image dạng như file này (ic `0x11`, header `0x400`, auth header `0x130`):

```
out = MP_header(512) + image
image = auth(0x130) + ctrl(12) + rest_hdr(0x400-0x13C) + payload

1. payload      := mã/dữ liệu mới
2. ctrl.payload_len (image+0x138) := len(payload)
3. ctrl.crc16  (image+0x130)      := CRC16_ARC(image[0x132 : end])      # init 0, poly 0xA001 (phản chiếu), không xor cuối
4. sha          (image+0x110)      := SHA256(image[0x130 : end])
5. sig          (image+0x010..0x04F):= ECDSA_P256_sign(priv, SHA256(image[0x110 : end])) → r‖s big-endian;
                                       (image+0x050..0x10F) = 00; (image+0x000..0x00F) = FF
6. pubkey       (image+0x1A0..0x1E0):= 04‖X‖Y (khớp priv)
7. MP header TLV: 0x04 = 0x14 = len(image); 0x16 = version (định dạng L_4_8_9_11);
                  0x1D = SHA256(pubkey65)[-4:]; giữ 0x01,0x02,0x03,0x11,0x12,0x15,0x1B=0x110,0x1C,0xFE
```

Công cụ kiểm chứng ngược (đọc file gốc rồi tính lại bước 3–7) cho kết quả **khớp 100 %** với file chính thức. Như vậy đặc tả này đúng cho **định dạng**. Bước 5 cần khoá bí mật mà ta **không có**.

---

## 6. Việc nên làm tiếp (chỉ thao tác đọc, an toàn)

1. Gửi `26 01` khi đồng hồ đang hiện mặt mặc định. Đối chiếu `dialNumber` với bảng §3.3, đọc `maxDataSize` và `watchFaceCount` để biết khe tuỳ chỉnh.
2. Thử khôi phục cài đặt gốc **sau khi** đã có mặt tuỳ chỉnh, để biết mặt tuỳ chỉnh có bị xoá không.
3. Nếu sau này muốn đi sâu: dùng Ghidra (ARM Cortex-M, base `0x0209C400`, nạp từ file offset `0x600`) để tìm hàm chọn mặt mặc định qua tham chiếu tới bảng `0x1841D4` (VA `0x0221FFD4`). Việc này chỉ phục vụ hiểu biết, vì vẫn vướng chữ ký.

### Phụ lục: tệp sinh ra

- `research/firmware/extracted/fw_entropy_map.png` — bản đồ entropy theo khối 4 KB (đỏ: header, xanh: mã, cam: chuỗi/bảng, xám: đệm 0).
- `research/firmware/extracted/rgb565be_0x130000_w466.png`, `rgb565le_0x158000_w466.png` — thử giải mã ảnh, kết quả là nhiễu (đối chứng âm tính: không có ảnh trong file).
