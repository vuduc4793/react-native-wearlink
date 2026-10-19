# Bổ sung spec — vòng 2: "sang như Apple"

Đọc `spec.md` trước (nội dung, dữ liệu thật, màn A–D, kích thước 1760×1000, khung 393×851 dark vẫn giữ nguyên). File này **ghi đè** phần cảm giác thị giác.

## Phản hồi của người dùng về vòng 1

Vòng 1 có 3 bản: Editorial Brutalism, WHOOP và Teenage Engineering. Người dùng nói: **"làm cho sang như Apple được không? nhìn không high-end tí nào."**

Lý do vòng 1 trông rẻ (rút ra để tránh):
- Màn chính nhồi chi tiết kỹ thuật như MAC, hex, FW, nhãn mono in hoa nhỏ, nên nhìn giống công cụ debug.
- Quá nhiều viền, khung, đường kẻ, ô nhỏ.
- Chữ to nhỏ lộn xộn, nhiều cụm chữ cùng tranh sự chú ý, không có một điểm nhấn rõ.
- Màu bão hoà nhiều chỗ.

## Nguyên tắc cho vòng 2 (chung cho cả 3 hướng)

- **Phân cấp tiết lộ**: màn chính chỉ có tên thiết bị, trạng thái, pin và một chỉ số lớn nhất. MAC, FW, HW, RSSI, hex, gói/s… nằm trong mục **"Chi tiết kỹ thuật"** mở ra được, hoặc trong màn Khả thi. Không bỏ thông tin, chỉ đẩy xuống tầng dưới.
- **Một điểm nhấn mỗi màn**: một con số/hình lớn, phần còn lại lùi xuống.
- Khoảng trắng rộng, lưới 8pt, góc bo liên tục (squircle, `border-radius` lớn), độ sâu nhờ vật liệu/độ mờ/bóng mềm thay cho viền.
- Typography kiểu SF: chữ số lớn, đậm vừa, chữ thân 15–17px. **SF Pro không được phép dùng trên Android**, nên dùng font thay thế hợp lệ, ví dụ "Inter" (ưu tiên Inter Display / Inter Tight cho số lớn) hoặc "Geist". Ghi rõ font thay thế. Font mono chỉ dùng trong mục chi tiết kỹ thuật.
- Màu: nền đen thật / xám than, chữ trắng và các mức xám hệ thống. Mỗi loại chỉ số một sắc độ tiết chế giống màu hệ thống Apple (đỏ nhịp tim, xanh SpO2, cam nhiệt độ…). Màu nhận diện thiết bị nhẹ nhàng.
- Chuyển động tinh tế khi đo: vòng/nhịp mượt, không nhấp nháy.
- Vẫn bắt buộc: chức năng sinh theo capability (R09 có nhiệt độ, HS500A có huyết áp, COROS chưa hỗ trợ), dữ liệu thật, số chưa đo ghi "chưa đo", A–D bấm được, đo giả lập mỗi 0,5 s, chọn nhiều để kết nối song song, "Đo đồng loạt", giới hạn ~7 kết nối.
- Đây là app **Android** mang thẩm mỹ Apple: không vẽ thanh trạng thái iOS / Dynamic Island. Dùng khung `android_frame.jsx`.
- Không emoji, không gradient tím, không vẽ sản phẩm bằng SVG (ảnh sản phẩm dùng placeholder trung thực, có thể là một hình tròn/viên nhẫn trừu tượng bằng CSS gradient tối giản, ghi chú là placeholder).
- Trước khi làm, dùng WebSearch kiểm tra ngôn ngữ thiết kế Apple hiện hành (tháng 10/2026) cho hướng của mình, không dựa vào trí nhớ.
