# Mặt đồng hồ UTE / GloryFit: danh sách element

Tài liệu tra cứu từng thành phần (element) của mặt đồng hồ tuỳ chỉnh trên đồng hồ dùng app GloryFit (SDK UTE), ví dụ **Y25**
(Realtek RTL8773, màn tròn 466 × 466). Định dạng file và giao thức truyền: xem [02-watchface.md](02-watchface.md).

Nguồn:
- Mã type: `com/yc/pedometer/onlinedial/ConfigType.java` (app GloryFit 4.0.12).
- Số ảnh, thứ tự ảnh, kích thước, vị trí mẫu: bộ template trong APK `assets/DialCustom/dial_1_circle_240x240` và
  `dial_2_square_240x240` (thiết kế cho màn 240 × 240).
- Kiểm chứng: gửi mặt đồng hồ thật lên Y25 (ngày 13/10/2026).

## 1. Quy tắc chung

- Mỗi element có `type` (u16), kích thước `w × h`, vị trí `(x, y)` trên màn hình, và **n ảnh cùng kích thước** (n = `animationCnt`).
  Firmware chọn ảnh theo giá trị cần hiển thị.
- Pixel RGB565 big-endian. Pixel `(0,0,0)` có thể bị coi là trong suốt, nên đổi màu gần đen thành `(17,9,17)`.
- Ảnh của element **vẽ sẵn trên đúng phần nền phía sau nó** (không có kênh alpha).
- Nén RLE khi `compatibleLevel ≥ 2` (Y25 = 2), **trừ** type 1–3, 35–46, 52–70.
- Element có dữ liệu giống hệt element trước được phép trỏ chung địa chỉ (tiết kiệm dung lượng).

### Bộ chữ số chuẩn (14 ảnh)

Dùng cho mọi element chữ số (giờ, phút, ngày, bước…). Thứ tự ảnh:

| Ảnh | 0 | 1 | 2 | 3–12 | 13 |
|---|---|---|---|---|---|
| Ký tự | `-` | `.` | `/` | `0` … `9` | `:` |

**Chữ số d nằm ở ảnh d + 3** theo template chính thức. Ví dụ hiển thị "7" thì firmware lấy ảnh 10.
Đã kiểm chứng trên Y25 ngày 13/10/2026: bản gửi theo thứ tự template hiển thị đúng giờ và ngày.

## 2. Element có trong template chính thức (chắc chắn được firmware hỗ trợ)

Kích thước và vị trí là của template 240 × 240. Với màn khác, SDK tự tính lại theo tỉ lệ.

| # | Tên | type | Thư mục template | Số ảnh | Ý nghĩa từng ảnh | Kích thước mẫu | Vị trí mẫu | Trạng thái trên Y25 |
|---|---|---|---|---|---|---|---|---|
| 1 | Ảnh xem trước | 10 | `preview` | 1 (+ khung) | Ảnh thu nhỏ của mặt đồng hồ trong danh sách | 240 × 240 | 0, 0 | Đã gửi, OK |
| 2 | Nền | 17 | `background` | 1 | Ảnh nền người dùng | 240 × 240 | 0, 0 | **Đã kiểm chứng** |
| 3 | Giờ hàng chục | 57 | `timehour1` | 14 | Bộ chữ số chuẩn | 32 × 45 | 51, 45 | **Đã kiểm chứng** |
| 4 | Giờ hàng đơn vị | 58 | `timehour2` | 14 | Bộ chữ số chuẩn | 32 × 45 | 83, 45 | **Đã kiểm chứng** |
| 5 | Dấu `:` giờ–phút | 7 | `hour2min` | 1 | `:` | 32 × 45 | 104, 45 | Hiển thị được |
| 6 | Phút hàng chục | 59 | `timemin1` | 14 | Bộ chữ số chuẩn | 32 × 45 | 125, 45 | **Đã kiểm chứng** |
| 7 | Phút hàng đơn vị | 60 | `timemin2` | 14 | Bộ chữ số chuẩn | 32 × 45 | 157, 45 | **Đã kiểm chứng** |
| 8 | AM/PM | 16 | `ampm` | 4 | 0 `上午` (sáng, TQ) · 1 `下午` (chiều, TQ) · 2 `AM` · 3 `PM` | 20 × 10 | 190, 80 | **Đã kiểm chứng** |
| 9 | Tháng hàng chục | 63 | `timemonth1` | 14 | Bộ chữ số chuẩn | 9 × 13 | 77, 101 | **Đã kiểm chứng** |
| 10 | Tháng hàng đơn vị | 64 | `timemonth2` | 14 | Bộ chữ số chuẩn | 9 × 13 | 86, 101 | **Đã kiểm chứng** |
| 11 | Dấu `/` tháng–ngày | 14 | `day2month` | 1 | `/` | 9 × 13 | 95, 101 | Hiển thị được |
| 12 | Ngày hàng chục | 65 | `timeday1` | 14 | Bộ chữ số chuẩn | 9 × 13 | 104, 101 | **Đã kiểm chứng** |
| 13 | Ngày hàng đơn vị | 66 | `timeday2` | 14 | Bộ chữ số chuẩn | 9 × 13 | 113, 101 | **Đã kiểm chứng** |
| 14 | Thứ trong tuần | 15 | `week` | 14 | 0–6: CN → T7 (bản chữ Hán `周日…周六`) · 7–13: CN → T7 (bản tiếng Anh `SUN…SAT`). Firmware chọn nửa nào theo ngôn ngữ đồng hồ | 32 × 14 | 123, 100 | **Đã kiểm chứng** |
| 15 | Pin | 8 | `battery` | 5 | Mức 0 (rỗng) → 4 (đầy) | 20 × 9 | 122, 15 | **Đã kiểm chứng** |
| 16 | Bluetooth | 9 | `iconbluetooth` | 2 | 0 đã kết nối · 1 mất kết nối | 15 × 7 | 102, 16 | **Đã kiểm chứng** |
| 17 | Biểu tượng bước | 24 | `iconstep` | 1 | Hình bàn chân | 13 × 15 | 89, 182 | **Đã kiểm chứng** |
| 18–22 | Số bước (5 chữ số) | 38, 39, 40, 41, 42 | `stepnum1` … `stepnum5` | 14 mỗi vị trí | Bộ chữ số chuẩn; `stepnum1` là chữ số trái nhất | 9 × 13 | 107/116/125/134/143, 184 | **Đã kiểm chứng** |
| 23 | Thanh tiến độ bước | 32 | `stepproccess` | 11 | Mức 0 % → 100 %, mỗi mức 10 % | 100 × 4 | 70, 205 | **Đã kiểm chứng** |

Ghi chú: tên file config có hậu tố `_2` (ví dụ `config_9x13_77x101_2.txt` của tháng) chưa rõ ý nghĩa. Có thể là căn lề hoặc một biến thể (suy luận).

## 3. Element firmware có định nghĩa nhưng template không dùng (thử nghiệm)

Có trong `ConfigType.java`. SDK đã dựng 4 nhóm đầu (giây, nhịp tim, kcal, quãng đường), gửi lên Y25 ngày 13/10/2026,
và **đồng hồ hiển thị đủ cả 4**: firmware vẽ được element ngoài template.

| Nhóm | type | Tên trong code | Số ảnh SDK dùng | SDK |
|---|---|---|---|---|
| Giây (2 chữ số) | 61, 62 | `SEC_ARC_NUM1/2` | 14 (bộ chữ số chuẩn) | **Đã kiểm chứng** (Y25, 13/10) |
| Nhịp tim: biểu tượng | 18 | `HEARTPIC` | 1 | **Đã kiểm chứng** (Y25, 13/10) |
| Nhịp tim: 3 chữ số | 35, 36, 37 | `HEART_ARC_NUM1..3` | 14 | **Đã kiểm chứng** (Y25, 13/10) |
| Kcal: biểu tượng | 29 | `KCALPIC` | 1 | **Đã kiểm chứng** (Y25, 13/10) |
| Kcal: 4 chữ số | 43–46 | `KCAL_ARC_NUM1..4` | 14 | **Đã kiểm chứng** (Y25, 13/10) |
| Quãng đường: biểu tượng | 51 | `DISTANCEPIC` | 1 | **Đã kiểm chứng** (Y25, 13/10) |
| Quãng đường: 5 ký tự | 52–56 | `DISTANCE_ARC_NUM1..5` | 14 (có dấu `.`) | **Đã kiểm chứng** (Y25, 13/10) |
| Kim giờ / phút / giây | 1 / 2 / 3 | `SHIZHEN` / `FENZHEN` / `MIAOZHEN` | 1 | **Đã rõ định dạng** (mục 6), chưa gửi thử |
| Năm | 27, 28, 67… | `YEARNUM`, `YEARCON`, `YEAR_ARC_NUM1…` | | Chưa |
| Thời tiết | 20, 21, 22 | `WEATHERPIC`, `WEATHERNUM`, `WEATHER_CPIC` | | Chưa |
| Số pin / % pin | 33, 34 | `BATNUM`, `BATPERCENT` | | Chưa |
| Ngày (dạng số / ảnh) | 13, 50 | `DAYNUM`, `DAYPIC` | | Chưa |
| Tháng (dạng số / ảnh) | 11, 12 | `MONNUM`, `MONPIC` | | Chưa |
| Giờ / phút / giây (dạng số đơn) | 4, 5, 6 | `SHINUM`, `FENNUM`, `MIAONUM` | | Chưa |
| Đơn vị bước / kcal / quãng đường | 26, 31, 48 | `STEPUNITPIC`, `KCALUNITPIC`, `DISTANCEUNIPIC` | | Chưa |
| Số nhịp tim (dạng số) / bpm | 19, 23 | `HEARTNUM`, `HEARTBPMPIC` | | Chưa |
| Số bước (dạng số) | 25 | `STEPNUM` | | Chưa |
| Dấu nối giờ–phút (dạng khác) | 49 | `HOURMINCON` | | Chưa |

## 4. Tuỳ chỉnh SDK hỗ trợ (`WatchFaceStyle`)

| Thuộc tính | Giá trị | Ghi chú |
|---|---|---|
| Ảnh nền | Bitmap bất kỳ | Tự xoá nền đồng màu quanh logo; phủ kín hoặc đặt giữa |
| `imageScale` | 0.3–1.0 | 1.0 = phủ kín màn |
| `backgroundColor` | ARGB | Màu nền phía sau ảnh |
| `textColor` | ARGB | Màu giờ/phút |
| `accentColor` | ARGB | Màu thứ, AM/PM, giây, biểu tượng, thanh tiến độ |
| `timePosition` | Trên / Giữa / Dưới | Vị trí khối chữ |
| `timeSize` | 0.12–0.24 cạnh màn | Tự giảm nếu file vượt dung lượng (Y25: 1 MB) |
| `scrim` | bật/tắt | Lớp tối mờ sau chữ khi chữ đè lên ảnh |
| `hour12` | bật/tắt | Thêm AM/PM và đặt đồng hồ hiển thị 12 giờ (`A0 01 02`) |
| `complications` | Thứ, Ngày, Pin, Bluetooth, Bước, Tiến độ bước, Giây, Nhịp tim, Kcal, Quãng đường | Tất cả đã kiểm chứng trên Y25 |

## 5. Dung lượng tham khảo trên Y25 (466 × 466, nén level 2)

| Cấu hình | Dung lượng | Thời gian gửi |
|---|---|---|
| Logo giữa + giờ + ngày (chữ số dùng chung dữ liệu) | ≈ 211 KB | ≈ 10 s |
| Ảnh phủ kín + mọi thành phần | ≈ 716 KB | ≈ 70 s |

Chữ số giờ/phút không được nén. Khi chữ đè lên ảnh, mỗi vị trí cần bộ ảnh riêng nên file lớn hơn nhiều.

## 6. Giải mã mặt đồng hồ của kho (kim, hiệu ứng 3D/blur)

Ngày 13/10/2026 đã tải 18 mặt đồng hồ 466 × 466 từ kho GloryFit (12 file nặng nhất ≈ 1 MB và 6 mặt kim) và tách từng lớp bằng
`tools/ute_face_decode.py`. Kết quả nằm ở `research/watchstore/decoded/` (gitignored), trang xem: `research/watchstore/decoded.html`.
Cả 18 file giải mã không lỗi bằng đúng định dạng SDK đang ghi (mục 1, `02-watchface.md`).

### 6.1 Định dạng file của kho

- Địa chỉ dữ liệu trong bảng element tính **từ đầu file** (gồm header 24 byte). Bảng element kết thúc bằng 2 byte 0 rồi đến dữ liệu.
- File mới ghi số element ở byte 20 của header. File cũ (và file SDK dựng) để `FF`; khi đó số element = (địa chỉ element đầu − 26) / 24.
- Byte 0–1 của header khác nhau giữa các file (`FE FF` ở file SDK, giá trị bất kỳ ở file kho). Đồng hồ có vẻ không kiểm tra hai byte này (suy luận).
- Ảnh nén RLE có dạng: u32 độ dài, bảng `h` offset u32 tính từ đầu bảng, rồi các dòng. Giống hệt hàm `rle()` của SDK.

### 6.2 Kim giờ / phút / giây (type 1 / 2 / 3)

| Trường | Ý nghĩa |
|---|---|
| Ảnh | 1 ảnh kim **dựng đứng, chỉ 12 giờ**, không nén (kể cả level 2). Pixel đen `0000` là trong suốt (suy luận: phần ngoài thân kim đều là `0000`) |
| `x, y` | Tâm xoay trên màn hình. Thường là `(233, 233)`; mặt 31410001 đặt `(182, 233)` để kim chạy trong mặt phụ |
| byte 21 (extra[4]) | Gần bằng chiều cao ảnh (`h` hoặc `h − 1`, tối đa 255) |
| byte 22 (extra[5]) | Toạ độ y của tâm xoay **trong ảnh kim** (tính từ đỉnh). Tâm x = `w / 2` |
| byte 23 (extra[6]) | Bằng `w` |

Ví dụ 26575001: kim giờ 34 × 158, extra `9e 98 22` ⇒ cao 158, tâm ở y = 152, rộng 34.
Ảnh kim dài nhất là 255 px (giới hạn 1 byte). Kim giây thường dài 241–255 px.

### 6.3 Hiệu ứng 3D và blur

Không có hiệu ứng nào chạy trên đồng hồ. Bóng đổ, kim loại, chiều sâu, nền mờ đều **vẽ sẵn** vào ảnh nền (type 17) và ảnh kim.
Đồng hồ chỉ ghép lớp và xoay kim. Tự làm được bằng cách dựng sẵn ảnh trong app.

- **Nền động:** type 17 có thể có nhiều frame (16417001 = quả địa cầu 3 frame, 15843001 = 5 frame). Đồng hồ lật frame theo vòng (suy luận).
- **Tiến độ dạng cung:** type 32 (bước), 71, 72 có 11 frame (0–100 %). Type 71/72 không có trong `ConfigType.java`; vị trí
  trong các mặt mẫu cho thấy đó là tiến độ thứ hai/thứ ba (kcal hoặc nhịp tim, suy luận).
- **Chữ số xếp theo cung:** type 35–37 (nhịp tim) và 43–46 (kcal) trong 15843001 mỗi chữ số có góc nghiêng riêng, nên chữ chạy theo vòng tròn.

### 6.4 Nghĩa các type gặp trong kho (đối chiếu `ConfigType.java` + ảnh)

| type | Tên | Ảnh | Ghi chú |
|---|---|---|---|
| 4 / 5 / 6 | `SHINUM` / `FENNUM` / `MIAONUM` | 14 (bộ chữ số chuẩn) | Một element vẽ **cả 2 chữ số** giờ/phút/giây, chữ số thứ hai đặt ngay sau chữ số đầu (suy luận từ vị trí) |
| 11 / 13 | `MONNUM` / `DAYNUM` | 14 | Tháng / ngày, 2 chữ số |
| 19 / 23 | `HEARTNUM` / `HEARTBPMPIC` | 14 / 1–2 | Số nhịp tim, nhãn "BPM" |
| 20 / 21 / 22 | `WEATHERPIC` / `WEATHERNUM` / `WEATHER_CPIC` | 16 hoặc 34 / 14 / 2 | Biểu tượng thời tiết, nhiệt độ, °C/°F |
| 25 / 26 | `STEPNUM` / `STEPUNITPIC` | 14 / 2 | Số bước, nhãn "STEPS" (2 ngôn ngữ) |
| 30 / 31 | `KCALNUM` / `KCALUNITPIC` | 14 / 2 | Số kcal, nhãn |
| 33 / 34 | `BATNUM` / `BATPERCENT` | 14 / 1 | Số pin, dấu % |
| 47 | `DISTANCE_NUM` | 14 | Số quãng đường |
| 71 / 72 | không có trong app | 11 | Cung tiến độ (suy luận) |

### 6.5 Thống kê 18 file (đối chiếu chéo với một phân tích độc lập, 13/10/2026)

- 6 file level 1 (không nén: 1, 10371001, 6172001, 6192001, 6713001, 6719001; nền luôn 434 312 byte = 466 × 466 × 2) và 12 file level 2.
- 9/18 file có đủ ba kim type 1/2/3.
- Dùng chung địa chỉ dữ liệu rất phổ biến: 0–11 element mỗi file, chủ yếu các bộ chữ số cùng font.
- Pin (type 8) có **5 hoặc 11 frame** tuỳ mặt (31410001, 31466001 dùng 11). Y25 mới kiểm chứng loại 5 frame.
- Type 10 (preview) chỉ là ảnh xem trước, đồng hồ không vẽ khi chạy (suy luận). File nặng chưa chắc đẹp hơn: dung lượng chủ yếu nằm ở nền và preview.
- Nền có thể gần như trống (7199001: 14 KB sau nén), khi đó mọi hình nằm ở các element.

## 7. Cài file `.bin` dựng sẵn

`GloryFitDevice.installWatchFaceFile(bin)` kiểm tra kích thước màn, độ dài, CRC-32, giới hạn dung lượng và mức nén, rồi truyền như mặt SDK tự dựng.
App thử: `adb shell am start -n com.smartwear.lab/.MainActivity --es connect <MAC> --es action faceBin --es file <đường dẫn trên máy>`.

| Ngày | File | Dung lượng | Thời gian | Kết quả |
|---|---|---|---|---|
| 13/10/2026 | `peacock-flat-466-level2.bin` (25 element, chữ số bước 38–42) | 461 848 byte | ≈ 45 s | `26 03 00` |
| 13/10/2026 | `peacock-dimensional-466-level2.bin` | 966 878 byte | ≈ 105 s | `26 03 00` |

Lưu ý: mọi mặt tuỳ chỉnh đều báo mã `FFFFFFFE`, nên `WatchFaceStore` không phân biệt được mặt của app với file cài từ ngoài, và sẽ không ghi đè các file này khi kết nối lại.
| 13/10/2026 | `peacock-3d-fullbleed-466-level2.bin` (bộ mặc định của thư viện) | 1 016 710 byte | ≈ 165 s | `26 03 00` |

### 7.1 Thư viện trong app SmartWear Lab

`apps/android/src/main/assets/watchfaces/<id>.bin|png`, danh sách ở `WatchFaceLibrary.kt`, chỉ còn 2 bộ (14/10/2026, theo yêu cầu):
Peacock 3D (`peacock-3d`, **mặc định**) và Peacock Atelier (`peacock-atelier`, từ `peacock-atelier-icons-v2`: kim giờ/phút/giây type 1–3,
bước 38–42, nhịp tim 35–37, pin 8/33/34). Đã cài thành công lên HT43 (585 808 byte, 1 phút 37 s, `26 03 00`); kim xoay chờ xác nhận bằng mắt.
Thiết bị đã lưu một bộ bị bỏ khỏi thư viện thì quay về mặc định. Màn chi tiết thiết bị GloryFit có mục "Thư viện".
Cài một bộ thì bộ đó thành mặt mặc định của thiết bị (`WatchFaceStore.savePreset`). Thiết bị chưa lưu gì thì dùng Peacock 3D.
Khi kết nối, nếu đồng hồ không hiển thị mặt tuỳ chỉnh thì app tự cài lại mặt mặc định (chỉ với màn 466 × 466).
Adb: `--es action facePreset --es preset <id>`.
