# Spec thiết kế — SmartWear Lab (app demo đa thiết bị)

> Đầu vào chung cho 3 hướng thiết kế. Mọi bản prototype dùng **cùng nội dung thật** dưới đây, chỉ khác cách thiết kế.

## 1. Sản phẩm là gì

**SmartWear Lab** là app Android nội bộ (hiện là `samples/android` trong repo `smart-wear-sdk`). Mục đích là **đánh giá tính khả thi** của bộ SDK tự viết để kết nối nhiều thiết bị đeo thông minh. Mỗi loại thiết bị có một SDK riêng (`sdks/<loại>/android`), dựng trên lớp BLE chung `sdks/core`. Sau này chính các SDK này sẽ được bọc vào một app React Native của người dùng, nên app demo đồng thời là **bản mẫu tương tác** cho app thật.

Người dùng là chủ dự án (kỹ thuật + sản phẩm). Họ ngồi bàn làm việc, một điện thoại Android cắm cáp, xung quanh **nhiều thiết bị cùng lúc** (nhẫn, vòng tay, đồng hồ…; hiện có 2 thiết bị thật và sẽ thêm nhiều nữa).

## 2. Ba nhu cầu cốt lõi (bắt buộc thể hiện)

1. **Kết nối nhiều thiết bị cùng lúc.** Quét → thấy thiết bị nhóm theo loại SDK (QRing, chưa hỗ trợ…) → chọn nhiều cái → kết nối song song. Thấy rõ trạng thái từng cái: đang quét / đang kết nối / đã kết nối / mất kết nối / lỗi.
2. **Chạm vào từng thiết bị để xem độc lập.** Mỗi thiết bị có màn chi tiết riêng: thông tin phần cứng, pin, các phép đo **chỉ hiện những gì thiết bị hỗ trợ** (đọc từ bảng khả năng), luồng đo trực tiếp, log gói tin thô (hex).
3. **Đánh giá khả thi.** Có chỗ nhìn tổng thể "kết nối song song có ổn không": số thiết bị đang nối, RSSI, số gói/giây, lỗi/timeout, độ trễ phản hồi, và nút **"Đo đồng loạt"** (cùng phép đo trên mọi thiết bị hỗ trợ). Lưu ý Android thường giới hạn ~7 kết nối GATT đồng thời; nên có chỗ hiển thị giới hạn này.

**Giao diện phải tự thích ứng theo khả năng thiết bị**: nút/ô chức năng sinh ra từ capability của từng thiết bị, không phải màn hình cố định cho một loại. Thiết bị loại mới chỉ cần khai báo capability là có giao diện.

## 3. Màn hình (prototype cần có, mỗi màn bấm được)

- **A. Tổng quan / Fleet**: danh sách thiết bị đã lưu và đang kết nối, mỗi thiết bị một "thẻ" sống (trạng thái, pin, RSSI, chỉ số gần nhất, phép đo đang chạy). Hành động nhanh: kết nối/ngắt, đo đồng loạt.
- **B. Quét & thêm**: kết quả quét nhóm theo loại SDK; chọn nhiều; thiết bị không hỗ trợ hiện mờ kèm lý do.
- **C. Chi tiết thiết bị** (độc lập cho từng cái): header thiết bị; lưới chức năng theo capability; vùng đo trực tiếp (giá trị lớn + chuỗi gói 0,5 s); log gói tin hex; nút đồng bộ lịch sử (ghi "sắp có").
- **D. Bảng khả thi / giám sát song song**: ma trận thiết bị × chỉ số (RSSI, gói/s, lỗi, độ trễ), giới hạn kết nối.

Chuyển giữa các thiết bị phải nhanh (ví dụ tab/thanh chuyển thiết bị, hoặc vuốt) mà vẫn biết các thiết bị khác đang ra sao.

## 4. Dữ liệu THẬT (dùng đúng, không bịa thêm số)

| Thiết bị | Loại SDK | BLE name | MAC | HW / FW | Khả năng |
|---|---|---|---|---|---|
| Colmi R09 (nhẫn) | QRing | `R09_8404` | `30:32:43:31:84:04` | `RT09_V3.1` / `RT09_3.10.22_260420` | Nhịp tim, SpO2, Nhiệt độ, Stress, HRV, giấc ngủ (giao thức mới), cử chỉ chạm |
| HS500A (chưa rõ loại) | QRing | (chưa ghi) | `32:35:45:37:4E:00` | `HS500A_V1.0` / `HS500A_1.00.05_260725` | Nhịp tim, SpO2, Huyết áp, Stress, HRV, chu kỳ kinh nguyệt, không màn hình, **không nhiệt độ** |
| COROS PACE 3 (đồng hồ) | Chưa hỗ trợ | `COROS PACE 3 8E1086` | `F7:AF:2F:22:09:90` | — | Quét thấy (phát FEE7) nhưng chưa có SDK |

Kết quả đo thật hôm nay (R09, đang đeo): **Nhịp tim 79–82 bpm** (~25 s), **SpO2 97–99 %** (~26 s), **Nhiệt độ 36,6 °C** (~26 s). Pin 23 % → 19 %, không sạc. RSSI −70 đến −82 dBm. HS500A: đo nhịp tim báo **"Chưa đeo"**. Gói mẫu: `69 01 00 4F 00 00 FA 02 00 00 00 00 00 00 00 B5` (HR 79), `6A 0B A6 …` (stop nhiệt độ 36,6), notify `73 0C 13` (pin 19 %). Ring gửi gói đo mỗi ~0,5 s.

Chỉ số chưa có số thật (gói/s, độ trễ, số lỗi khi nhiều thiết bị) → hiển thị nhãn rõ là "chưa đo"/"—" hoặc ghi chú "số minh hoạ" ở một chỗ, **không** giả làm số thật.

## 5. Định dạng & kích thước (bắt buộc thống nhất)

- **Android app prototype**, ngôn ngữ giao diện **tiếng Việt**.
- Điện thoại mục tiêu: Redmi Note 7 Pro, 393 × 851 dp, **đang bật dark mode** (giao diện phải đẹp ở nền tối; có thể có thêm light nhưng dark là chính).
- File: **1 file HTML độc lập** (inline React được phép, mở bằng file:// chạy được), đặt các màn A–D **cạnh nhau** trên canvas, mỗi màn trong khung điện thoại 393×851 và **tương tác được** (chạm thẻ → chi tiết, đổi tab, bắt đầu đo giả lập phát gói mỗi 0,5 s với số thật ở trên, v.v.).
- Canvas chụp màn hình: **1760 × 1000 px**.
- Nếu dùng khung thiết bị, dùng `~/.claude/skills/huashu-design/assets/android_frame.jsx` (đọc trước), không tự vẽ bezel.

## 6. Ràng buộc

- Chữ thân ≥ 14 px, nhãn ≥ 12 px, tương phản ≥ 4.5:1. Dark mode là chính.
- Không emoji làm icon, không gradient tím, không thẻ bo góc kèm viền màu bên trái, không vẽ SVG hình sản phẩm/người. Ảnh sản phẩm thiết bị: dùng **placeholder trung thực** (ô xám ghi "ảnh R09") vì chưa có ảnh chính thức. Tên thương hiệu thiết bị chỉ hiển thị dạng chữ (app nội bộ cho kỹ sư; logo hãng chưa có, ghi rõ là placeholder nếu cần).
- Font: tránh Inter/Roboto làm display trừ khi phong cách yêu cầu; dùng Google Fonts qua `<link>` được.
- Mỗi thiết bị nên có **màu nhận diện riêng** để phân biệt khi nhiều thiết bị cùng chạy (nhưng tiết chế).

## 7. Mô-típ thị giác gợi ý (từ nội dung)

Tín hiệu và nhịp: mỗi thiết bị là một "kênh" phát gói đều đặn 0,5 s, như một dải nhịp/xung, hoặc như các kênh trên một bàn mixer/máy đo. Chuỗi hex là chất liệu thật của sản phẩm. Hãy tìm form từ đó thay vì dashboard chung chung.

## 8. Ảnh

Ảnh **không** bắt buộc cho nội dung (công cụ kỹ thuật); ảnh sản phẩm dùng placeholder trung thực.
