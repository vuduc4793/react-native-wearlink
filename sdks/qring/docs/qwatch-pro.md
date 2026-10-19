# QWatch Pro: cùng họ giao thức với QRing

Nguồn: `research/qwatch-pro/` (QWatch Pro 1.0.3.32, package `com.qcwireless.qcwatch`, giải mã bằng jadx ngày 2026-10-13).

## Kết luận

- **Cùng nhà sản xuất và cùng SDK BLE với QRing.** Cả hai app dùng `com.oudmon.ble` (260 file mỗi bên), cùng `com.qcwireless.*`, cùng UUID: service `6e40fff0`, big-data `de5bf728`, quảng bá `FEE7`. Các tài liệu 01–03 trong thư mục này áp dụng được cho thiết bị dùng QWatch Pro.
- **COROS không dùng app này.** Code không hề nhắc đến COROS; lần khớp duy nhất là tên biến bị làm rối `mavcorosnb` trong `com/smartapp/...`. COROS dùng app và giao thức riêng của hãng. Trong SDK này, COROS PACE 3 chạy qua driver `standard` (pin, thông tin thiết bị, nhịp tim chuẩn khi đồng hồ bật chế độ phát nhịp tim).

## Khác biệt giữa SDK QWatch và SDK QRing (theo file trong `com/oudmon`)

| Chỉ có trong QWatch (đồng hồ) | Chỉ có trong QRing (nhẫn) |
|---|---|
| `CMD_DEVICE_CALL_FORWARD = 51` (chuyển cuộc gọi) | `CMD_DEVICE_BATTERY_SAVING = 118` |
| `CMD_DEVICE_THEME = 61`, `CMD_DEVICE_WALLPAPER = 63` | `CMD_DEVICE_DIAL_INDEX = 117` |
| `CMD_LOVER_EVENT = 81` (QRing dùng 81 cho `NOTIFICATION_EVENT_NOTIFY`) | `CMD_PRAISE_V2 = 122` |
| UV: `UltraVioletReq/Rsp`, `UVSettingReq/Rsp` | ECG đo đơn, nhiệt độ theo chu kỳ, SpO2 theo chu kỳ (big-data) |
| Trả lời nhanh SMS (`SmsQuickBean`) | Liên hệ khẩn cấp |

Lưu ý: lệnh **81** mang ý nghĩa khác nhau giữa hai app. Driver cần phân biệt theo loại thiết bị (đồng hồ hay nhẫn) trước khi dùng lệnh này.

## Tiền tố tên mặc định khi quét của QWatch Pro

`G69, O_, o_, MS, Ma, Mi, H5, H1, Ha, HW, Exo, Evoke, P4…P8, PBL, S2, S4, S5, "S ", ST, SW, SE, AFTWS0423S, iHunt, T88, Moi, WT001, N5, E7, GT, FireBoltt 172/188/130/106/138, EW11, RSW007, TS105, Watch, Y15, Ul, ul, Unbound, Duke, "Capri ", TR, i31, GS9, OG, Go, W2, AHA, AMD, ADM, LYCKA, Laleli, Ch, TM05, air, Hello, FT9 MINI` (server có thể cập nhật thêm).

Nhiều tiền tố rất chung chung ("Go", "Ch", "air", "Watch"), nên driver **không** lọc theo danh sách này. Driver nhận diện bằng manufacturer data `0x1234: FE E7 + MAC`, rồi xác nhận lại bằng service `6e40fff0` sau khi kết nối.

## Ghi chú an toàn

Bản APK tải từ APKPure có các package lạ bị làm rối (`com/smartapp/a`, `com/smartapp/b`, các Activity tên ngẫu nhiên) mà bản QRing không có. Chỉ đọc mã, không cài APK này lên máy thật.
