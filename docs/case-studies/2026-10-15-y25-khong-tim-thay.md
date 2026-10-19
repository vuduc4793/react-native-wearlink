# Case study: Y25 "lúc thấy lúc không" (14–15/10/2026)

> Viết cho người và AI sau đọc lại. Mục đích: hiểu vì sao thiết bị đeo BLE "biến mất", cách khoanh vùng,
> và các lỗi thật đã sửa. Phần nào chưa chứng minh được ghi **(chưa chắc)**.

## 1. Triệu chứng

- Y25 (đồng hồ GloryFit/UTE) có lúc quét thấy, phần lớn thời gian **không quảng bá**, kể cả sau khi reset gốc.
- HT43 (cùng hãng, cùng nền tảng) **luôn ổn**.
- Nhẫn R09 và vòng DS500 (QRing) cũng lúc được lúc không.
- App iOS chỉ nối được HT43. DS500 nối được nhưng hiện "Chưa rõ loại" và không đo được nhịp tim.

## 2. Kiến thức nền cần nhớ

| Sự thật BLE | Hệ quả khi chẩn đoán |
|---|---|
| Thiết bị BLE đeo tay chỉ cho **một** máy trung tâm kết nối; **đang kết nối thì ngừng quảng bá** | "Không thấy trong scan" ≠ hỏng. Thường là **có máy khác đang giữ** |
| App có chế độ "giữ kết nối" (Android `DeviceManager` cũ, app chính chủ, iOS pending connect) sẽ **nối lại ngay** khi thiết bị vừa quảng bá | Thiết bị chỉ hiện chớp nhoáng vài giây rồi mất: dấu hiệu có máy "phục sẵn" |
| iOS có thể giữ kết nối **ở cấp hệ thống** (đã ghép đôi để nhận thông báo/gọi), không cần app chạy | Dùng `retrieveConnectedPeripherals(withServices:)` để biết; thiết bị kiểu này không quảng bá |
| Y25 **yêu cầu iOS ghép đôi** (popup "Yêu cầu ghép đôi Bluetooth") | Bấm huỷ popup ⇒ kết nối treo ở "đang kết nối" tới khi hết giờ |
| Mỗi đồng hồ/nhẫn quảng bá với nhịp khác nhau: HT43 dày, Y25/DS500 thưa | Code không được giả định "thấy trong 20 s gần nhất" mới nối được |

## 3. Cách khoanh vùng đã dùng (dùng lại được)

1. **Quét từ máy thứ ba** (Mac mini, không phải điện thoại đang dùng): `python3 -I tools/ble_scan.py timeline 60`
   ghi mốc thời gian mỗi lần thấy từng thiết bị. `ute` để bắt cả gói không tên (theo dịch vụ 0x55xx hoặc MAC 78:02:B7).
2. **Loại trừ từng máy trung tâm**: tắt hẳn Bluetooth của một máy (Cài đặt, không phải Control Center trên iPhone),
   quét lại 30–60 s. Thiết bị hiện lại ⇒ máy đó đang giữ. Đã dùng để chứng minh Android giữ R09.
3. **Hỏi iOS đang giữ gì** ở cấp hệ thống: app chạy `retrieveConnectedPeripherals` với dịch vụ của từng driver
   (GloryFit `55FF` + `55F0`, QRing `FEE7` + `6E40FFF0` + `DE5BF728`). Thiết bị trả về có `rssi=0`.
4. **Đọc trạng thái đã lưu của app**, không đoán:
   - Android: `adb shell run-as com.smartwear.lab cat shared_prefs/smartwear_devices.xml`
   - iOS: `xcrun devicectl device copy from … --domain-type appDataContainer --domain-identifier com.smartwear.lab --source Library/Preferences/com.smartwear.lab.plist`
5. **Log chi tiết từng gói**: iOS chạy app với `-autoConnect … -verboseLog YES` (xem `apps/ios/README.md`), Android `adb logcat -s SmartWear`.
6. **Mỗi lỗi sửa đều có test trượt với code cũ, đạt với code mới** (đã làm cho từng mục ở §4).

## 4. Nguyên nhân tìm được và cách sửa

| # | Nguyên nhân | Bằng chứng | Sửa |
|---|---|---|---|
| 1 | **App Android giữ cả 5 thiết bị** (Y25, DS500, R09, GPS 103, HT43) với cờ giữ kết nối, tự nối lại mỗi khi chúng vừa quảng bá | `smartwear_devices.xml` có 5 dòng, cờ `1`. Tắt Bluetooth Android ⇒ R09 hiện lại | Xoá danh sách (theo yêu cầu người dùng). **Quy tắc: mỗi thiết bị chỉ để MỘT máy giữ kết nối** |
| 2 | **App iOS bỏ qua thiết bị trong im lặng**: mục quét bị xoá sau 20 s không thấy quảng bá; `DeviceManager.connect` gọi `add(id)` trả nil ⇒ không nối, không lỗi, không lưu | Log "Thấy Y25" nhưng "Kết nối song song" chỉ nối HT43; danh sách lưu chỉ có HT43 | Bộ nhớ `seen` giữ mọi thiết bị đã quét thấy trong phiên; id không còn thông tin thì **báo lỗi** "hãy quét lại". Test `testSparseAdvertiserStillConnectsAfterPrune` |
| 3 | **App iOS không có "giữ kết nối"**: quét 40 s, không thấy là thôi, rớt không nối lại | So với `DeviceManager.kt` Android | Lưu thiết bị (`KnownDeviceStore`), nối lại bằng `retrievePeripherals(withIdentifiers:)` + pending connect không giới hạn, backoff 2/5/10/30/60 s (QRing 2/4 s như app chính chủ), `bluetooth-central` nền. Sau sửa: HT43/R09/DS500 tự nối lại trong ~20–40 ms mỗi lần mở app |
| 4 | **DS500 bị driver Bluetooth chuẩn nhận nhầm**: khi iOS đang giữ kết nối, thiết bị đến từ `retrieveConnected` không có tên/quảng bá đủ để driver QRing nhận; driver chuẩn (thấy 180A) nhận thay và **được lưu lại** | Log `driver=standard kind=unknown capabilities=[]` | QRing nhận theo dịch vụ GATT riêng (`6E40FFF0`, `DE5BF728`) và tên `DS500`; `DeviceManager.correctDriver` sửa bản ghi đã lưu sai. Log sau sửa: `DS500_4E00: đổi driver standard → qring`, đo nhịp tim 77 bpm |
| 5 | **Y25 yêu cầu iOS ghép đôi**; người dùng lỡ huỷ popup ⇒ kết nối treo tới hết 40 s | Popup "kết nối" hiện đúng lúc app nối Y25; log "Hết thời gian chờ kết nối (40 s)" dù vừa thấy quảng bá -56 dBm | Bấm **Ghép đôi**; nếu lỡ huỷ: iPhone → Cài đặt → Bluetooth → Quên Y25 → thử lại. Màn **Chẩn đoán** trong app iOS sẽ nhận ra và hướng dẫn |
| 6 | **R09 lỗi "Hết thời gian chờ bật notify"** trên iOS khi sóng yếu | App QRing chính chủ bật notify không chờ, không bao giờ fail (docs `sdks/qring/docs/ios-qring-app.md`) | Bật notify kiểu không chặn cho QRing, thứ tự bắt tay `04 01 …` như app iOS chính chủ |
| 7 | **HT43 không đo nhịp tim theo lệnh** (`D6 01`/`E5 11` không trả lời) | Cờ `isHas24HourHRM`: app GloryFit chính chủ không bao giờ gửi lệnh đo thủ công cho loại này (doc 09 §2) | Bật đo 24 h `F7 01` + chu kỳ `F7 09 01 00 05`, nhận `F7 03`/`F7 0B` đẩy về |

## 5. Điều gì cuối cùng làm Y25 hiện lại

Theo thứ tự thời gian ngày 15/10: xoá danh sách giữ kết nối trên Android (nguyên nhân 1), sửa lỗi iOS bỏ qua thiết bị
(nguyên nhân 2), thêm giữ kết nối iOS (3), người dùng reset/khởi động lại Y25. Sau đó iPhone thấy Y25 (-56 dBm) và
**popup ghép đôi hiện ra** (nguyên nhân 5).

**(chưa chắc)** Những quãng Y25 im lặng rất lâu ngay cả khi Android đã tắt Bluetooth chưa được giải thích trọn vẹn.
Giả thuyết còn mở: trạng thái ghép đôi dở dang giữa Y25 và một iPhone (đồng hồ chờ máy đã ghép thay vì quảng bá
cho máy mới), hoặc chế độ tiết kiệm pin của firmware. Lần sau gặp lại: chụp màn hình Y25, kiểm tra Cài đặt → Bluetooth
trên mọi iPhone, chạy `ble_scan.py ute` ngay sau khi khởi động lại đồng hồ.

## 5b. Kết luận sau test end-to-end (chiều 15/10/2026)

**Hành vi quảng bá của Y25 (đã đo):** Y25 chỉ phát quảng bá một quãng ngắn ngay sau khi bị ngắt kết nối hoặc vừa
khởi động/được đánh thức, rồi im để tiết kiệm pin. Bằng chứng:
- E2E: ngắt theo ý người dùng rồi nối lại ⇒ nối được sau **3,6 s** (đang trong quãng phát).
- Quên ở cuối E2E, ~1 phút sau mới đặt lệnh nối ⇒ không nối được trong 2 phút (đã qua quãng phát).
- Đặt lệnh nối chờ theo UUID rồi đợi ⇒ nối được sau **255 s**, đúng lúc người dùng thao tác với đồng hồ.

**Hệ quả thiết kế (đã làm trong SDK iOS):**
- KHÔNG dựa vào quét để tìm Y25. Biết thiết bị một lần (UUID CoreBluetooth), sau đó luôn giữ một **lệnh nối chờ
  không giới hạn** (`DeviceManager` giữ kết nối, `connectKnown(id:driverId:name:)`, launch arg `-connectId`).
  Thiết bị hé tín hiệu lúc nào là nối lúc đó, đã nối thì không cần quảng bá nữa.
- Mất kết nối ngoài ý muốn ⇒ đặt lại lệnh nối chờ ngay (đang trong quãng phát nên nối lại nhanh).
- "Quên" thiết bị rồi muốn dùng lại ⇒ phải đánh thức/khởi động lại Y25 để nó phát lại.

**Các nguồn "khoá" thiết bị vào iPhone đã gỡ:**
| Nguồn | Hậu quả | Sửa |
|---|---|---|
| Lệnh QRing `04 01` (cờ iOS/ANCS) | Nhẫn/vòng bị iOS ghép đôi cấp hệ thống, app không nhả được | Mặc định gửi `04 02 0A <model>`; bật lại qua `QRingDriver.iosNotifications` |
| `CBConnectPeripheralOptionEnableTransportBridgingKey` | (suy luận) kéo theo kênh Classic của Y25 ⇒ popup ghép đôi | Mặc định tắt (`BleCentral.transportBridging`) |
| Khôi phục trạng thái iOS (restore identifier) | iOS tiếp tục nối hộ app cả thiết bị đã quên | Bluetooth bật ⇒ huỷ mọi kết nối khôi phục mà thiết bị không còn "giữ" |
| "Quên" chỉ xoá bản ghi | Thiết bị vẫn bị iOS giữ | `DeviceManager.remove`/`releaseAll` gọi `cancelPeripheralConnection`; app kiểm tra lại sau 2,5 s và hướng dẫn xoá trong Cài đặt nếu còn bị giữ (iOS không có API xoá ghép đôi hệ thống) |

**Kết quả E2E iOS (`-e2e YES`):** Y25 ĐẠT (nối lại từ danh sách 23 ms, ngắt→nối lại 3,6 s, quên→iOS nhả), HT43 ĐẠT,
DS500 ĐẠT. R09: mọi bước đạt trừ "quên → iOS nhả" — iOS vẫn giữ R09 ở cấp hệ thống dù đã Quên trong Cài đặt
**(chưa rõ nguyên nhân, đang điều tra)**.

## 6. Checklist khi một thiết bị "không thấy"

1. Màn hình thiết bị báo đang kết nối máy nào không? Có popup ghép đôi nào vừa bị bỏ qua trên điện thoại không?
2. `tools/ble_scan.py timeline 60` từ Mac: thiết bị có quảng bá không, dày hay thưa?
3. Không quảng bá ⇒ tìm máy đang giữ: tắt Bluetooth lần lượt từng điện thoại (Android, mọi iPhone) và quét lại.
4. Kiểm tra danh sách "giữ kết nối" của **mọi** app (Android lab, iOS lab, app chính chủ GloryFit/QRing/GloryFitPro).
   Chỉ để một máy giữ.
5. iPhone: Cài đặt → Bluetooth có thiết bị đó không? Quên nếu ghép đôi hỏng.
6. Vẫn im ⇒ khởi động lại thiết bị, quét trong 1 phút đầu.
7. Có quảng bá nhưng không nối được ⇒ xem màn **Chẩn đoán** / log `-verboseLog YES`: popup ghép đôi, notify timeout, driver sai.

## 7. Tệp liên quan

- Công cụ: `tools/ble_scan.py`
- iOS: `sdks/core/ios/Sources/SmartWearCore/DeviceManager.swift` (`seen`, `correctDriver`, vòng giữ kết nối), `sdks/qring/ios/Sources/SmartWearQRing/QRing.swift` (nhận theo dịch vụ)
- Nghiên cứu app chính chủ: `sdks/gloryfit/docs/09-ios-gloryfit-app.md`, `sdks/qring/docs/ios-qring-app.md`
- Phần cứng, giao thức: `sdks/gloryfit/docs/01-protocol.md` §10–§11, `08-hardware.md`
