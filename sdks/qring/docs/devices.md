# Thiết bị đã kiểm chứng với SDK qring

Các thiết bị dưới đây đã kết nối thật bằng `QRingClient` (Android, Redmi Note 7 Pro / Android 16).
Cùng giao thức QRing (service `6e40fff0`), nên dùng chung SDK `:qring`.

| Thiết bị | Tên BLE | MAC | HW (2A27) | FW (2A26) | Ngày thử |
|---|---|---|---|---|---|
| Colmi **R09** (nhẫn) | `R09_8404` | `30:32:43:31:84:04` | `RT09_V3.1` | `RT09_3.10.22_260420` | 2026-10-13 |
| **HS500A** (vòng tay, người dùng đang đeo) | `DS500_4E00` | `32:35:45:37:4E:00` | `HS500A_V1.0` | `HS500A_1.00.05_260725` | 2026-10-13 |

> HS500A được kết nối **ngoài ý muốn** khi app demo chọn thiết bị đầu danh sách quét. Người dùng xác nhận
> đây nhiều khả năng là một trong các thiết bị dự án cần hỗ trợ. Cần hỏi lại tên/loại sản phẩm.

## Quảng bá (advertisement)

| Thiết bị | Service UUID | Manufacturer data |
|---|---|---|
| R09 | `FEE7` | company `0x1234`: `FE E7` + MAC 6 byte (`FE E7 30 32 43 31 84 04`) |
| HS500A | (chưa ghi lại) | (chưa ghi lại) |

`FEE7` một mình **không** đủ để lọc: đồng hồ COROS PACE 3 cũng phát `FEE7`.

## Bảng khả năng đọc được

Giải mã theo [01-connection.md §4.2](01-connection.md).

**R09**
- SetTime (0x01) rsp: `01 00 00 02 00 00 00 00 01 00 20 00 00 30`
  → nhiệt độ, SpO2, **newSleepProtocol** (sleep qua big-data 0x27), appMeasure, stress, HRV.
- DeviceSupport (0x3C) rsp: `00 AC 27 00 …`
  → p1 = `AC`: appRevision, **blePair**, gesture; p2 = `27`: ringMusic, ringVideo, ringEbook, ringGame (điều khiển bằng chạm/cử chỉ).
- Notify `0x2F` (kích thước gói big-data): `0x14` (20) ở lần kết nối đầu, `0xF4` (244) ở các lần sau (suy luận: do Android tự thương lượng MTU).

**HS500A**
- SetTime (0x01) rsp: `00 00 01 16 00 00 00 00 01 00 20 00 00 30`
  → menstruation, SpO2, huyết áp, oneKeyCheck, newSleepProtocol, appMeasure, stress, HRV. **Không** báo nhiệt độ.
- DeviceSupport (0x3C) rsp: `00 40 00 A0 00 00 08 30 …`
  → p1 = `40`: **deviceNoScreen**; p3 = `A0`: notification, aiAnalyze; p6 = `08`: loverSpace; p7 = `30`: realTimeHrRemind, friends.
- Notify `0x2F`: `0xF4` (244).

## Hành vi thực tế khác tài liệu (kiểm chứng trên R09)

- Lệnh `0x04` (phone info) **có** phản hồi `04 00 …` (tài liệu: không có).
- Đo nhịp tim (`0x69 01 00`):
  - Ring gửi gói `0x69` mỗi ~0,5 s. Khi chưa có kết quả, byte 6..7 (LE16) chứa một giá trị thô dao động
    ~0x0289–0x0319 (suy luận: tín hiệu PPG thô).
  - Khoảng 25 s sau start mới có giá trị (byte 3 = bpm). Ring tự dừng gửi khoảng 5 s sau giá trị đầu tiên, không có gói kết thúc.
  - Chưa đeo: sau ~3,5 s trả `errCode = 1` rồi dừng.
- Keep-alive `1E 03` bị ring trả lỗi `9E EE`, cả trong lúc đang đo → firmware này không dùng lệnh đó.
- Notify `73 0C 13`: dataType 12 (pin thay đổi), byte kế tiếp = 0x13 = 19 % (xác nhận suy luận "[1] = % pin").

## Kết quả đo thật trên R09 (2026-10-13, nhẫn đang đeo)

| Phép đo | Thời gian tới kết quả | Kết quả | Gói mẫu |
|---|---|---|---|
| Nhịp tim (`69 01 00`) | ~25 s | 79–82 bpm | `69 01 00 4F 00 00 FA 02 …` (byte 3 = 0x4F = 79) |
| SpO2 (`69 03 25`) | ~26 s | 97–99 % | `69 03 00 63 01 …` (byte 3 = 0x63 = 99) |
| Nhiệt độ (`69 0B 25`) | ~26 s | 36,6 °C | `69 0B 00 A6 00 00 B3 02 …` (0xA6 = 166 → 166/10 + 20) |

- Sau khi có kết quả, ring gửi thêm ~10 gói trong ~5 s rồi im lặng, không có gói kết thúc → SDK kết thúc flow sau 5 s im lặng.
- Lệnh stop `6A <type>` có phản hồi: `6A 03 61` (SpO2 97 %), `6A 0B A6` (36,6 °C), tức byte 2 = giá trị cuối.
- Trong lúc kết nối, ring tự gửi `73 01` (HR mới), `73 04` (bước chân mới), `73 27 A5` (nhiệt độ mới) — khớp bảng dataType trong 02-commands.md §5.1.
- Sau khi app bị force-stop, có lúc nhẫn không quảng bá lại trong ~20 s đầu.

## HS500A / DS500 và đo nhiều thiết bị (2026-10-13, app SmartWear Lab mới)

- Tên BLE của HS500A là **`DS500_4E00`**: tiền tố `DS`, cùng nhóm "band" (`DS12`, `DS520`, `DS1314`) trong app QRing. Pin 64 %.
- Thiết bị phát sóng thưa và ngừng phát khi đang có kết nối. Đã gặp `GATT status 147` (connection timeout) và `CONNECTION_ACCEPT_TIMEOUT` khi điện thoại khác còn giữ kết nối. Sau khi nhả, kết nối thành công ở **lần thử thứ 2**; DeviceManager tự thử lại tối đa 3 lần.
- Nhịp tim đo được: 78 bpm (đo riêng), sau đó **84 bpm cùng lúc với R09 (84 bpm)** khi "Đo đồng loạt", 2 thiết bị QRing kết nối song song trên một điện thoại Android.
- COROS PACE 3 (driver `standard`): `COROS W331`, HW `W31BV77075`, SW `V 3.0510.0`, pin 42 %, có service 180D, nhưng không gửi 2A37 nếu chưa bật Heart Rate Broadcast.

## Đồng bộ lịch sử: kiểm chứng trên thiết bị thật (2026-10-13)

Đồng bộ 7 ngày, chạy song song R09 + DS500, mất khoảng 12 giây:

| | Bước (khung 15') | Nhịp tim | HRV | Stress | SpO2 | Giấc ngủ |
|---|---|---|---|---|---|---|
| DS500 | 46 | 482 | 39 | 81 | 11 | 0 đêm, 2 giấc trưa |
| R09 | 3 | 4 | 2 | 4 | 2 | 0 |

- DS500 hôm qua (12/10): 3.246 bước, 124 kcal, 2,06 km; nhịp tim 115 điểm, trung bình 84, thấp 45, cao 112.
- **Khác tài liệu 03 §3.2:** khung ngủ trưa `0x3E` có **cùng định dạng với `0x27`** (daysAgo, recLen, start LE, end LE, cặp giai đoạn/phút), không phải cặp `(flag, phút)`. Mẫu thật: `02 06 08 FE 02 27 03 02 1F 02 0A 05 08 F5 02 26 03 02 17 02 1A` là 2 giấc trưa 12:46–13:27 và 12:37–13:26. Ring gửi `0x3E` trước `0x27` khi nhận request `BC 27 [FF 01]`.
- Giấc chính `0x27` trả `00` (0 ngày) trên cả hai thiết bị: chưa có đêm nào được ghi.
- Nhiệt độ `0x77 [day, 0]` trên R09 trả payload 1 byte `00`, tức chưa có dữ liệu.
- SpO2 `0x2A`: bản ghi 49 byte, cặp cao/thấp theo giờ, thường bằng nhau (ví dụ `61 61` = 97 %).
