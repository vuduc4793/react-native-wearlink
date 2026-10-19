# Hướng thiết kế đã chọn

## Vòng 1 (2026-10-13), người dùng loại cả 3

- `design-demos/roulette-editorial-brutalism.png`: vòng quay #1, Editorial Brutalism
- `design-demos/reference-benchmark.png`: app tham chiếu WHOOP
- `design-demos/designer-pick.png`: phong cách Teenage Engineering

Người dùng: "làm cho sang như apple được không? nhìn không highend tí nào."

## Vòng 2 (trong ngữ cảnh Apple, spec bổ sung `spec-apple.md`)

- `design-demos/apple-health.png`: Apple Health / Fitness
- `design-demos/apple-findmy.png`: Find My (trường tín hiệu + sheet thiết bị)
- `design-demos/apple-liquid-glass.png`: Liquid Glass

**Lựa chọn của người dùng (nguyên văn):** "kết hợp Find My với Liquid Glass, làm luôn, và lưu ý . mỗi thiết bị có những tính năng khác nhau, nên là hãy làm để có thể xem độc lập từng thiết bị với đầy đủ tính năng, nghiên cứu luôn cho ios nhé. đừng chỉ làm 1 loại thiết bị."

## Diễn giải để thực thi

- **Cấu trúc lấy từ Find My:** nửa trên là "trường tín hiệu" (mỗi thiết bị là một quả cầu, thiết bị gần tâm nghĩa là RSSI mạnh, quả cầu nhịp theo gói tin). Nửa dưới là sheet kéo được: danh sách thiết bị → chạm vào → sheet riêng của thiết bị. Tab: Thiết bị / Thêm / Khả thi.
- **Chất liệu lấy từ Liquid Glass:** mỗi thiết bị có màu nhận diện, tạo thành vùng màu chuyển động chậm phía sau. Kính mờ (blur + highlight viền) chỉ dùng cho thanh điều hướng, nút, chip chuyển thiết bị và sheet. Mỗi màn có một con số lớn.
- **Màn chi tiết là màn độc lập, đầy đủ tính năng cho từng thiết bị:** sinh hoàn toàn từ capability và tính năng của driver (đo, cài đặt, sự kiện, chi tiết kỹ thuật), không có màn cố định cho một loại.
- **Nhiều loại thiết bị:** kiến trúc driver theo loại. Hiện có QRing (R09, HS500A) và Bluetooth chuẩn (Battery/Device Info/Heart Rate, ví dụ COROS).
- **Nền tảng:** làm cả Android (Kotlin) và iOS (Swift).
