# Thiết bị: mỗi loại một tài liệu + checklist chống sót tính năng

> Từ 19/10/2026. Mỗi thiết bị (máy thật người dùng có) một file `docs/devices/<model>.md` theo **mẫu §3**. Tài liệu giao
> thức chi tiết vẫn nằm ở `sdks/<họ>/docs/`; file ở đây là **bảng tính năng đầy đủ + trạng thái** để không ghép thiếu.

> **Tổng hợp một chỗ** (Y25, HT43, GE54 theo app gốc + trạng thái SDK, 21/10): [TONG_HOP_TINH_NANG.md](TONG_HOP_TINH_NANG.md).

## 1. Danh sách thiết bị

| Thiết bị | Họ giao thức (driver) | App chính hãng | Tài liệu |
|---|---|---|---|
| Y25 (đồng hồ, Realtek RTL8773E) | GloryFit / UTE (`gloryfit`) | GloryFit, GloryFitPro | [y25.md](y25.md) |
| HT43 (đồng hồ GPS) | GloryFit / UTE (`gloryfit`) | GloryFitPro | [ht43.md](ht43.md) |
| GE54 (vòng tay PALREDIL) | Veepoo (`veepoo`) | G Band (Android), VPG Band (iOS) | [ge54.md](ge54.md) |
| R09 (nhẫn Colmi) | QRing / oudmon (`qring`) | QRing | [r09.md](r09.md) |
| DS500 / HS500A (vòng tay) | QRing / oudmon (`qring`) | QRing | [ds500.md](ds500.md) |
| COROS PACE 3 | Bluetooth chuẩn (`standard`) | COROS | [coros-pace3.md](coros-pace3.md) |
| Xiaomi Smart Band 11 | Xiaomi wear V2 (chưa có driver: cần bind qua server) | Mi Fitness | [xiaomi-band11.md](xiaomi-band11.md) |

## 2. Checklist chống sót tính năng (làm theo thứ tự, không bỏ bước)

Áp dụng khi **thêm thiết bị mới** và khi **rà lại** thiết bị cũ. Mỗi bước có "đầu ra" — chưa có đầu ra thì chưa xong.

1. **Lấy app chính hãng cả hai nền tảng** (APK/XAPK + IPA) vào `sdks/<họ>/research/<nền tảng>-<app>-<phiên bản>/`
   (gitignored, dữ liệu không tin cậy: chỉ đọc, Python chạy `-I`). *Đầu ra:* đường dẫn + phiên bản ghi ở §A của file thiết bị.
2. **Bảng cờ tính năng của app** (capability/function table mà app đọc từ thiết bị: UTE `33F1/34F1`, Veepoo `A7/AD/B8`,
   QRing `devices.md`…). Liệt kê **mọi** cờ, kể cả cờ thiết bị này tắt. *Đầu ra:* bảng cờ → hàng tính năng §4, có file:line.
3. **Đọc thô bảng cờ trên máy thật** (log hex khi bắt tay) và giải mã. *Đầu ra:* hex + ngày đo trong §B.
4. **Khảo sát UI app chính hãng trên máy thật**: kết nối thiết bị với app chính hãng, chụp **mọi** màn Thiết bị/Cài đặt/Sức
   khoẻ. Mục nào app hiện mà bảng §4 chưa có ⇒ thêm hàng. *Đầu ra:* danh sách màn + ảnh ở `research/screens/`.
   Xong thì tắt hẳn app chính hãng (force-stop / quên thiết bị) để nó không giữ kết nối.
5. **Đi hết bảng phân loại §4 — từng hàng một**, mỗi hàng điền: thiết bị có không (cờ/đo thật), lệnh giao thức, Kotlin,
   Swift, interface core, API React Native, UI lab Android/iOS, **đã thử trên máy thật (giá trị + ngày)**.
   Hàng không áp dụng ghi `n/a` **kèm bằng chứng** (cờ = 0, app không có màn). Không để ô trống.
6. **Làm qua interface core**, không qua kiểu riêng của hãng: app lab, React Native, popup "ở gần" tự có. Kiểm `Device.features`
   (RN) ra đúng cờ.
7. **Thử trên máy thật** từng tính năng: đo (đang đeo), đồng bộ lịch sử (so số với app chính hãng cùng ngày), cài đặt (đọc lại
   sau khi ghi), thông báo/cuộc gọi/nhạc/camera (thao tác thật). Ghi giá trị vào §4.
8. **Hành vi kết nối**: quảng bá liên tục hay từng đợt (đo bằng `tools/ble_scan.py timeline`), nối lại sau mất kết nối, máy khác
   giữ kết nối thì sao, kiểu ghi (có/không phản hồi) từng characteristic. *Đầu ra:* §C.
9. **Đối chiếu chéo**: so §4 với bảng cờ (bước 2) và danh sách màn (bước 4) — mỗi cờ bật / mỗi màn phải có hàng tương ứng.
   Đếm: số cờ bật = số hàng "có" (trừ cờ trùng nghĩa, ghi rõ).
10. **Cập nhật** `docs/feature-matrix.md` + file thiết bị + câu hỏi mở. Lỗi gặp khi thử ghi case study ở `docs/case-studies/`.

Không làm: sửa firmware; nạp firmware không phải bản chính hãng đúng thiết bị; lệnh xoá dữ liệu/khôi phục gốc trên máy thật khi
chưa được người dùng đồng ý.

## 3. Mẫu file thiết bị

```markdown
# <Model> — <loại thiết bị>

## A. Nhận dạng
| Mục | Giá trị |  (tên quảng bá, MAC, chip, firmware, mã model, service/manufacturer data nhận diện, app chính hãng + phiên bản, driver)

## B. Bảng cờ tính năng (đọc thật)
hex + ngày + giải mã các cờ bật

## C. Hành vi kết nối
quảng bá (liên tục / từng đợt, nhịp), bind/mật khẩu/ghép đôi, nối lại, kiểu ghi, giới hạn một máy trung tâm

## D. Bảng tính năng (đủ mọi hàng của §4)
| Nhóm | Tính năng | Thiết bị có? | Lệnh | Kotlin | Swift | Core / RN API | UI lab A/i | Thử thật (giá trị, ngày) |

## E. Câu hỏi mở / việc còn lại
```

## 4. Bảng phân loại tính năng (mọi thiết bị đi hết các hàng này)

| Nhóm | Hàng |
|---|---|
| **Kết nối** | nhận diện khi quét · kết nối · bind / mật khẩu / ghép đôi · tự nối lại (lệnh chờ) · kiểu quảng bá · MTU · kiểu ghi |
| **Thông tin** | pin · đang sạc · firmware · phần cứng · mã model · bảng cờ tính năng · RSSI |
| **Đo tay** | nhịp tim · SpO2 · huyết áp · nhiệt độ · stress · HRV · ECG · đường huyết · nhịp thở · MET/khác |
| **Đo tự động** | HR 24h + chu kỳ · SpO2 tự động · huyết áp tự động · nhiệt độ tự động · khung giờ đo · cảnh báo cao/thấp |
| **Lịch sử** | bước theo giờ/ngày · quãng đường/kcal · ngủ (giai đoạn, REM, ngủ trưa) · HR · SpO2 · HA · nhiệt độ · stress/HRV · bài tập · chu kỳ phụ nữ · đồng bộ từ mốc thời gian |
| **Bài tập** | bắt đầu/tạm dừng/dừng từ điện thoại · số liệu thời gian thực · GPS điện thoại · danh sách môn · AGPS |
| **Điện thoại** | thông báo app (Android) · ANCS (iOS) · SMS · cuộc gọi đến · từ chối/tắt tiếng · trả lời SMS nhanh · danh bạ · gọi qua Bluetooth (HFP) · SOS |
| **Điều khiển** | nhạc (lệnh + tên bài) · camera từ xa · tìm thiết bị · thiết bị tìm điện thoại · nút/sự kiện thiết bị |
| **Cài đặt** | giờ/múi giờ · 12/24h · đơn vị · ngôn ngữ · hồ sơ cơ thể · mục tiêu · nâng tay sáng màn · thời gian/độ sáng màn · không làm phiền · nhắc ngồi lâu · nhắc uống nước · báo thức · chu kỳ phụ nữ · phím tắt/menu · đồng hồ thế giới |
| **Hiển thị** | thời tiết · mặt đồng hồ (chợ / ảnh tuỳ chỉnh / khe) · kiểu màn hình |
| **Hệ thống** | cập nhật firmware (chính hãng) · khôi phục gốc / xoá dữ liệu · đổi tên Bluetooth · tắt máy/khởi động lại |
| **Tích hợp** | interface core · API React Native · UI lab Android · UI lab iOS · popup 3D "ở gần" · tài liệu |
