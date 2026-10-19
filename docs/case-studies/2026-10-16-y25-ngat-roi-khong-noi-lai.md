# Y25: bấm "Ngắt" trên app rồi không nối lại được (16/10/2026)

## Triệu chứng
- 16:35:09 người dùng bấm nút ngắt trên app (iOS). Popup "thiết bị ở gần" hiện ngay. Bấm kết nối thì báo lỗi sau
  40 s ("Hết thời gian chờ kết nối… thiết bị không quảng bá"), bấm thử lại vẫn lỗi.
- Y25 lúc đó đã ghép kênh gọi Bluetooth cổ điển (HFP) với iPhone từ 15/10, và chia sẻ thông báo (ANCS).

## Đo được
| Lúc | Thấy gì |
|---|---|
| 16:35:09 | `retrieveConnectedPeripherals` còn trả Y25 (link đang tháo) |
| 16:35:10 | **Một** gói quảng bá, −72 dBm |
| 16:35:10 → 17:11:39 | Không có gói nào: iPhone (quét liên tục) và Mac mini (bleak, 2 lần × 15–25 s) đều không thấy Y25 |
| 17:11:39 | Một gói quảng bá −67 dBm; lệnh nối đang chờ (không giới hạn) vẫn không lên link |

App không gửi lệnh gì cho đồng hồ khi ngắt (chỉ dừng đo + `cancelPeripheralConnection`). App GloryFit Android cũng chỉ
`gatt.disconnect()` rồi quét nối lại.

## Nguyên nhân (đang xác nhận)

> Cập nhật 19/10/2026: đo lại cho thấy Y25 chỉ quảng bá ~4–6 s mỗi lần được đánh thức / vừa mất kết nối rồi im, kể cả
> khi không có máy nào ghép đôi; giả thuyết dưới đây không cần để giải thích. Xem `2026-10-19-y25-android-khong-bao-thiet-bi.md`.
SDK UTE iOS gốc luôn nối với `CBConnectPeripheralOptionEnableTransportBridgingKey = YES` (doc gloryfit 09 §1.4). Ngày 15/10
ta tắt tuỳ chọn này vì popup ghép đôi. Không có bridging, `cancelPeripheralConnection` tháo hẳn link BLE trong khi kênh
cổ điển vẫn nối ⇒ Y25 gần như thôi quảng bá BLE (chỉ phát lẻ tẻ, cách nhau hàng chục phút) ⇒ không nối lại được.

Chưa rõ: gói 17:11:39 có `connectable` không (lúc đó app chưa ghi cờ này).

## Đã sửa
- `GattConnection.transportBridging`; GloryFit bật cho mọi kết nối như SDK gốc (`GloryFitDriver.swift` init).
- Ghi `CBAdvertisementDataIsConnectable` vào dòng thời gian ("cho phép nối" / "KHÔNG cho phép nối").
- Kênh lệnh có `disconnect Tên` / `connect Tên` để tái hiện mà không cần người dùng bấm.

## Còn phải kiểm
Khi Y25 nối lại: `disconnect Y25` rồi `connect Y25` vài lần với bridging bật; xem link có được iOS giữ (nối lại tức thì) không.
