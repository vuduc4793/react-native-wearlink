# Y25 đặt cạnh Redmi mà không báo / không nối được (19/10/2026)

## Triệu chứng
- Y25 đặt sát Redmi Note 7 Pro (Android), app không hiện popup "thiết bị ở gần"; bấm "Kết nối" thì treo ở "Đang kết nối…".
- Người dùng thấy Y25 "kết nối kém" cả trên iOS lẫn Android.

## Đo được
| Lúc | Thấy gì |
|---|---|
| 14:05–14:40 | Redmi (quét liên tục) và Mac mini (bleak) không thấy Y25; dò Bluetooth classic cũng không thấy. Redmi không giữ kết nối nào với Y25 |
| 14:44:15–21 | Mac mini thấy Y25 −50 dBm; Redmi cùng lúc báo "không thấy Y25" |
| 15:07:40–44 | Bấm sáng Y25 ⇒ Redmi (bản đã sửa) nhận 17 gói −47 dBm, popup bật sau 0,6 s; rồi im |
| 15:13:34–38 | Lại một đợt 4,4 s trong lúc app đang nối trực tiếp: không nối được |
| 15:18:35 | App nối kiểu chờ (`autoConnect`) ⇒ nối ngay gói đầu tiên, trước cả khi app quét thấy |

**Hành vi của Y25:** mỗi lần được đánh thức / vừa mất kết nối chỉ quảng bá ~4–6 s (có lần 18 s) rồi im, cả BLE lẫn
classic. HT43 cùng hãng quảng bá liên tục. Khớp với kết luận 15/10 (`2026-10-15-y25-khong-tim-thay.md` §5b). Giả thuyết
HFP/bridging của `2026-10-16-y25-ngat-roi-khong-noi-lai.md` không cần để giải thích.

## Nguyên nhân phía Android (đã sửa)
| # | Lỗi | Bằng chứng | Sửa |
|---|---|---|---|
| 1 | `callbackFlow` bộ đệm 64, `trySend` vứt gói khi tràn. Android gọi `ScanCallback` trên luồng chính; khung UI ~70 ms ⇒ gói dồn rồi xả một lúc | Đếm tại callback: nhận 1 743 / rơi 892 mỗi 10 s | `BleScanner`: `.buffer(Channel.UNLIMITED)` ⇒ rơi 0 |
| 2 | Android hạ lượt quét không lọc quá 30 phút xuống gần như không nhận gói; app vẫn tưởng "quét=bật" | `dumpsys bluetooth_manager`: lượt 14:07:32 "Forced" sau 1 890 s | `DeviceManager.startScan`: mở lượt mới mỗi 25 phút (`SCAN_RESTART_MS`) |
| 3 | Nút "Kết nối" nối trực tiếp (40 s, rồi lùi 2/5/10… s) có lúc lỡ trọn đợt 4 s | 15:13:34–38 không nối; 15:18:35 `autoConnect` nối ngay | `GloryFitDriver.connect()` cũng `autoConnect = true`, chờ không giới hạn như iOS |
| 4 | Popup 3D trống: `AndroidView` gán `WRAP_CONTENT`, WebView dựng trang với viewport cao 0 | CDP: `#stage` 348×0, `matchMedia(min-height:100px)=false` | `Watch3D`: `MATCH_PARENT` |

Kèm theo (cùng ngày): xử lý quét trên luồng nền + cập nhật danh sách ≤2 lần/s/thiết bị, bỏ `blur(80.dp)` (máy đứng
2–5 s/khung), ngưỡng "ở gần" Y25 trên Android −78 dBm.

## Cách dùng / kiểm lại
- Y25 không quảng bá liên tục ⇒ đừng dựa vào quét để nối. Biết thiết bị một lần, sau đó luôn giữ lệnh nối chờ;
  muốn nối ngay thì bấm sáng đồng hồ.
- Ép popup khi đồng hồ đang im: `am start -n com.smartwear.lab/.MainActivity --es action nearbyDemo [--es mac <MAC>]`.
- Log quét rất nhiều (verbose "Bỏ qua…") làm logcat trôi trong vài phút: tăng `adb logcat -G 16M` và ghi ra file khi điều tra.
- Thư viện React Native biên dịch cùng mã Kotlin SDK nên tự có các sửa 1–3.

## Cập nhật tối 19/10: nguyên nhân gốc là **chưa ghép đôi hệ thống** — ghép rồi thì hết

Theo yêu cầu người dùng, ngắt mọi app của mình rồi cho từng app chính hãng nối thiết bị (ảnh ở `sdks/gloryfit/research/screens/`,
`sdks/veepoo/research/screens/`):

| Bước | Quan sát |
|---|---|
| GloryFit 4.0.12 → Y25 | Thấy Y25 ngay, nối LE trực tiếp (`autoConnect=false`) sau ~1 s, rồi **gọi ghép đôi hệ thống**: Android hỏi "Ghép nối với Y25(ID-6E1B)?" ⇒ bond, Redmi nối Y25 **cả BR/EDR lẫn LE** (HFP, A2DP, SPP, 180F) |
| Tắt GloryFit, mở app lab (3 lần, nghỉ 20 s giữa các lần) | Nối Y25 sau **3 s, 6 s, 3 s**, không ai đánh thức đồng hồ (trước đó: không nối được trong 60 s nếu không bấm sáng) |
| Cả BR/EDR lẫn LE đều đã ngắt, chỉ còn bond (2 lần) | Vẫn nối sau **4 s, 5 s**; Android tự nối lại kênh gọi |
| G Band → GE54 | Không ghép đôi trên Android; GE54 quảng bá liên tục nên lúc nào cũng nối ngay — cách của G Band **không** giúp được Y25 |

**Kết luận:** Y25 chưa ghép đôi chỉ quảng bá từng đợt ngắn; đã ghép đôi thì Android nối lại được ngay. App chính hãng luôn ghép đôi
khi bind nên người dùng app chính hãng không gặp lỗi này.

**Sửa (Android):** `GloryFitDriver.bondOnConnect` (mặc định bật): nối xong mà đồng hồ có kênh gọi Bluetooth và chưa bond ⇒
`pairCallBluetooth()` (bật kênh gọi + `createBond`), Android hiện hộp thoại xác nhận một lần mỗi phiên. Sau khi cài: nối lại Y25 sau 2 s.
**iOS:** tương đương là ghép đôi khi iOS hỏi (bridging bật cho GloryFit, case study 16/10) — người dùng phải bấm **Ghép đôi**, không huỷ.
