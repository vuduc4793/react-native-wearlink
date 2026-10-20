# Báo lỗi react-native-wearlink

Gặp lỗi thì **đừng sửa trong `node_modules`, đừng patch-package**. Báo lại để sửa ở SDK (Kotlin/Swift dùng chung) rồi phát hành bản mới.
Sửa tạm ở app sẽ mất khi nâng phiên bản, và lỗi đó sẽ còn ở các app khác.

Trước khi báo, xem [Lỗi thường gặp](loi-thuong-gap.md).

## Gửi ở đâu

GitHub Issues: https://github.com/vuduc4793/react-native-wearlink/issues

## Cần có trong báo lỗi

Thiếu thông tin nào thì phải hỏi lại, nên gửi đủ ngay từ đầu:

1. **Phiên bản:** `react-native-wearlink` (trong `package.json` của app), React Native, Android/iOS và phiên bản hệ điều hành, model điện thoại.
2. **Thiết bị đeo:** model (Y25, GE54…), `device.firmware`, `device.driver`.
3. **Các bước làm lại lỗi**, đánh số. Ghi rõ người dùng đang đeo hay không, có chạm cảm biến không, app ở nền hay ở trước.
4. **Kết quả mong đợi** và **kết quả thực tế**. Có số liệu thì so với app chính hãng (GloryFit, G Band).
5. **Đoạn code gọi thư viện** liên quan: hàm nào, tham số gì, nghe sự kiện nào.
6. **Log**, càng sát thời điểm lỗi càng tốt:
   - Android: `adb logcat -v time | grep -iE "SmartWear|GloryFit|Veepoo|BluetoothGatt|ReactNativeJS"`.
   - iOS: console Xcode, lọc `SmartWear`.
   - JS: giá trị `onReading` / `onDevicesChanged` / lỗi Promise (`code`, `message`).
   - Nếu có: kết quả `selfTest` của app mẫu (các dòng `SWTEST …`).
7. **Thời điểm** xảy ra lỗi (giờ:phút), để so với log.

Đừng gửi khoá API, token, số điện thoại hay danh bạ thật trong log. Thay bằng `***`.

## Sau khi báo

- Lỗi được tái hiện bằng app lab hoặc test, sửa trong SDK, thêm test, rồi phát hành bản vá (`0.1.x`).
- Nâng phiên bản ở app: `npm install react-native-wearlink@latest`. Trên iOS chạy lại `pod install`, trên Android build lại.
