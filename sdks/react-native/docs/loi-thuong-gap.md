# Lỗi thường gặp khi dùng react-native-wearlink

Mỗi mục: **triệu chứng** → nguyên nhân → cách sửa. Phần lớn lấy từ lỗi đã gặp thật trong lúc làm thư viện (case study ở `docs/case-studies/`).
Không thấy lỗi của bạn ở đây thì [báo lỗi](bao-loi.md).

## A. Build và cài đặt

| Triệu chứng | Nguyên nhân | Sửa |
|---|---|---|
| iOS: `No such module 'SmartWearCore'` (hoặc `SmartWearVeepoo`…) | Podfile thiếu pod SDK | Thêm đủ **5** pod trỏ tới `node_modules/react-native-wearlink/vendor/sdks` ([hướng dẫn §3](huong-dan-su-dung.md#ios)), chạy lại `pod install` |
| iOS: `pod install` báo pod yêu cầu iOS 17 / `module has a minimum deployment target of iOS 17` | Đang dùng bản 0.1.0 (cần iOS 17) | Nâng lên 0.1.1 trở lên (cần iOS 15.1). `platform :ios` và Deployment Target của app ≥ 15.1 |
| iOS: app crash ngay khi quét | Thiếu `NSBluetoothAlwaysUsageDescription` trong `Info.plist` | Thêm khoá đó. `NSBluetoothPeripheralUsageDescription` là khoá cũ, không đủ |
| `TurboModuleRegistry.getEnforcing(...): 'SmartWear' could not be found` | App chưa bật kiến trúc mới, hoặc chưa build lại native sau khi cài | Android: `newArchEnabled=true` trong `gradle.properties`. iOS: `RCT_NEW_ARCH_ENABLED=1 pod install`. Rồi build lại app (không chỉ reload JS) |
| Android: `minSdkVersion 24 cannot be smaller than version 26` | App để minSdk dưới 26 | `minSdkVersion = 26` (hoặc cao hơn) trong `android/build.gradle` |
| Android: lỗi Kotlin / JVM target | JDK hoặc Kotlin cũ | JDK 17, Kotlin 2.x (`kotlinVersion` trong `android/build.gradle` của app) |
| Google Play: app không cài được trên máy không có BLE | Bản 0.1.0–0.1.1 khai báo `bluetooth_le` `required="true"` | Nâng 0.1.2 (`required="false"`) |
| Google Play hỏi giải trình `READ_PHONE_STATE` / truy cập thông báo dù app không dùng | Bản 0.1.0–0.1.1 tự gộp các mục này vào manifest app | Nâng 0.1.2. Bản này chỉ gộp Bluetooth + giữ kết nối; app dùng cầu nối điện thoại thì tự khai báo ([hướng dẫn §3](huong-dan-su-dung.md#android)) |
| Mở app crash `'SmartWear' could not be found` sau khi cập nhật JS qua OTA | JS mới có thư viện, binary cũ chưa có native | Từ 0.1.2: kiểm `SmartWear.isAvailable` trước khi gọi. Ship thư viện lần đầu bằng bản build mới, không qua OTA |
| Sửa code trong `node_modules/react-native-wearlink` mà không thấy đổi | Android dùng `vendor/sdks`, iOS dùng pod đã cài | Đừng sửa trong `node_modules`. [Báo lỗi](bao-loi.md) để sửa ở thư viện rồi nâng phiên bản |

## B. Quyền và khởi động

| Triệu chứng | Nguyên nhân | Sửa |
|---|---|---|
| Android: mở lại app không tự nối thiết bị cũ | `start()` gọi **trước** khi có quyền `BLUETOOTH_CONNECT` | Xin quyền trước, rồi `start()`. Người dùng cấp quyền muộn thì gọi `start()` lại |
| Quét không ra gì, không báo lỗi | Chưa cấp quyền, Bluetooth tắt, hoặc (Android 11 trở xuống) tắt Vị trí | Nghe `onScanState`: `bluetooth: 'off' \| 'unauthorized'`, `error`. Hiện hướng dẫn cho người dùng |
| Android 13+: không thấy thông báo "đang giữ kết nối", kết nối rớt khi app ở nền lâu | Chưa có quyền `POST_NOTIFICATIONS` hoặc tắt foreground service | Xin `POST_NOTIFICATIONS`. Không gọi `setForegroundService(false)` nếu cần giữ kết nối nền |
| Android: bật chuyển cuộc gọi / SMS nhưng không có gì lên thiết bị | Thiếu quyền khai báo trong manifest app, hoặc chưa cấp quyền đọc thông báo | Khai báo trong manifest app phần mình dùng (từ 0.1.2 gồm cả `READ_PHONE_STATE` và dịch vụ `PhoneNotificationListener`, mẫu ở [hướng dẫn §3](huong-dan-su-dung.md#android)) rồi xin lúc chạy. `hasNotificationAccess()` false thì gọi `openNotificationAccessSettings()` |
| Sự kiện đến 2–3 lần, hoặc màn đã đóng vẫn nhận sự kiện | Đăng ký `on…` trong render, hoặc quên `remove()` | Đăng ký trong `useEffect`, trả về hàm `subs.forEach(s => s.remove())` |
| Màn A nhận số đo của thiết bị B | Luồng sự kiện chung cho mọi thiết bị | Lọc `r.deviceId === id` |

## C. Tìm thấy và kết nối

| Triệu chứng | Nguyên nhân | Sửa |
|---|---|---|
| Thiết bị không hiện khi quét | **App khác đang giữ kết nối** (GloryFit, G Band, app lab, điện thoại khác). Thiết bị BLE đang kết nối thường thôi quảng bá | Tắt app chính hãng trên mọi điện thoại hoặc huỷ ghép thiết bị ở đó. Một thiết bị chỉ nên do một app giữ |
| Y25 không hiện / hiện vài giây rồi mất | Y25 **chưa ghép đôi** chỉ quảng bá khoảng 4–6 s sau mỗi lần sáng màn | Bấm cho Y25 sáng màn rồi quét. Lần kết nối đầu bấm **Ghép nối** ở hộp thoại Android. Ghép xong Y25 tự nối lại sau 2–6 s |
| Y25: người dùng bấm Huỷ ở hộp thoại ghép đôi | Không có bond nên lần sau khó nối lại | Hiện hướng dẫn rồi kết nối lại. Hộp thoại hiện lại một lần mỗi phiên |
| `connect` bị từ chối mã `timeout` | Chưa nối được trong 40 s. **Thư viện vẫn thử tiếp ở nền** (giữ kết nối) | Đừng báo "thất bại". Hiện "Đang chờ thiết bị, hãy để gần và bấm sáng màn". Nghe `onDevicesChanged` để biết lúc `CONNECTED` |
| `connect` bị từ chối mã `not_found` | `id` chưa có trong kết quả quét hoặc danh sách đã lưu | Quét trước rồi mới `connect`. Đừng dùng `id` lấy từ máy khác (Android là MAC, iOS là UUID riêng từng iPhone) |
| Đã `disconnect` rồi mở lại app vẫn không nối | Đúng thiết kế: `disconnect` = thôi giữ kết nối | Gọi `connect(id)` lại khi người dùng muốn |
| Hai điện thoại cùng nối một thiết bị, chập chờn | Hai bên giành nhau | Chỉ một điện thoại giữ kết nối |
| Android quét lâu (hơn 30 phút) thì không còn thấy gì | Android hạ cấp lượt quét không lọc sau 30 phút | Từ 0.1.0 thư viện tự mở lượt quét mới mỗi 25 phút. Nếu vẫn gặp thì [báo lỗi](bao-loi.md) |

## D. Đo

| Triệu chứng | Nguyên nhân | Sửa |
|---|---|---|
| Gọi `measure` mà không có gì | `id` sai / chưa `CONNECTED`, hoặc chỉ số không có trong `device.measurable`. `measure` không trả lỗi | Kiểm `device.state === 'CONNECTED'` và `measurable.includes(cap)` trước khi gọi |
| `NOT_WORN` | Đeo lỏng hoặc đeo ngược cảm biến | Đeo sát, cảm biến chạm da, ngồi yên |
| GE54 acid uric / mỡ máu / thành phần cơ thể: `NOT_WORN` hoặc `ERROR` kèm `note: 'TOUCH_SENSOR'` | Không chạm cảm biến / điện cực bằng tay kia suốt lúc đo | Khi `MEASURING` + `TOUCH_SENSOR` hiện "Đặt ngón tay lên cảm biến", rồi đo lại |
| GE54 mỡ máu cao bất thường (gấp khoảng 10 lần) | Mã cũ trong repo (trước 20/10/2026) dùng chế độ đo hiệu chuẩn | Dùng gói npm 0.1.0 trở lên (luôn đo chế độ thường) |
| GE54 thành phần cơ thể sai lệch nhiều | Hồ sơ (chiều cao, cân nặng, tuổi, giới) chưa đúng | Đặt `profile.*` qua `setControl` trước khi đo |
| GE54 nhiệt độ đợi lâu | Bình thường: vòng đo khoảng 1 phút, trong lúc đó `MEASURING` | Hiện tiến độ, đừng huỷ sớm |
| Huyết áp lệch hẳn so với máy đo | Có thể đã bị ghi hiệu chuẩn | Xem control hiệu chuẩn trong `getControls`. Chỉ người dùng tự đặt, app không tự ghi |
| Số đo của lần trước vẫn chạy khi rời màn | Không gọi `stopMeasure` | Gọi `stopMeasure` khi unmount |
| Muốn nhịp tim liên tục khi chạy nhưng `measure` chỉ trả một giá trị | `measure` là đo một lần | Dùng `startHeartRateStream` + `onHeartRate` (từ 0.1.3, [hướng dẫn §7](huong-dan-su-dung.md#nhịp-tim-liên-tục-khi-chạy-từ-013)) |
| `startHeartRateStream` lỗi `unsupported` | Thiết bị đang kết nối nhưng không có nhịp tim liên tục (R09, thiết bị chuẩn không có 0x180D) | Kiểm `features.heartRateStream` trước |
| `onHeartRate` có mẫu `connected: false` | Mất kết nối giữa buổi | Đánh dấu khoảng trống nhịp tim. Thư viện tự nối lại và mở lại luồng, không cần gọi lại |
| Y25: nhịp tim khi chạy thưa (khoảng 25 s một giá trị) | Y25 chỉ đo theo lệnh từng lần | Bình thường với Y25. Cần ~1 giá trị/giây thì dùng dây đo nhịp tim chuẩn |
| Android: quét thấy Y25 nhưng không thấy HT43 (iOS thấy) | Bản ≤ 0.1.6 trên Android chỉ nhận UTE qua UUID quảng bá hoặc tên `Y25`; HT43 quảng bá không kèm UUID thì bị bỏ | Nâng 0.1.7 (nhận thêm tên `HT43` như iOS) |
| Android 12+: app mất vị trí chính xác (GPS) sau khi thêm thư viện, `dumpsys package` không có `ACCESS_FINE_LOCATION` | Bản ≤ 0.1.5 khai `ACCESS_FINE_LOCATION` kèm `maxSdkVersion="30"`, Gradle giữ giới hạn này khi gộp manifest | Nâng 0.1.6, app tự khai `ACCESS_FINE_LOCATION` không có `maxSdkVersion`. Bản cũ: thêm `tools:remove="android:maxSdkVersion"` vào dòng quyền của app |
| Android: hai thông báo thường trực lúc chạy (dịch vụ vị trí của app + giữ kết nối của thư viện) | Mỗi bên một foreground service | Trong lúc dịch vụ của app chạy, gọi `setForegroundService(false)`; xong buổi chạy gọi lại `true` nếu cần giữ kết nối nền |

## E. Lịch sử và số liệu

| Triệu chứng | Nguyên nhân | Sửa |
|---|---|---|
| `today.calories` = 0 hoặc nhỏ gấp 1000 lần (Y25) | Mã cũ trong repo (trước 20/10/2026) chia đơn vị hai lần | Dùng gói npm 0.1.0 trở lên. `today.calories` là **kcal** (số nguyên, làm tròn xuống) |
| Tự nhân / chia calo thêm lần nữa | Hiểu nhầm đơn vị | `today.calories` và `workouts[].calories` đã là kcal, đừng đổi đơn vị |
| `syncHistory` trả về nhưng thiếu một loại dữ liệu | Một bước lỗi, xem `h.errors` | Hiện phần đã có. Đồng bộ lại sau. Lỗi lặp lại thì báo kèm `h.errors` |
| GE54 không có dữ liệu cũ hơn 3 ngày | Vòng chỉ giữ 3 ngày | Đồng bộ ít nhất mỗi 2 ngày và lưu ở app / server |
| Đồng bộ chậm, UI đơ | `await syncHistory` trên luồng UI chặn render | Hiện `onSyncProgress`, không chặn màn hình |
| Không thấy "100+ chế độ tập" như app GloryFit | Đó là danh mục tên của app (GloryFitPro 245 môn). Y25 chỉ giữ 50 môn | `getSportTypes` = môn đồng hồ giữ; `getSportCatalog` = danh mục để tra tên. Chỉ bật/tắt, xếp thứ tự được bằng `setSportList` (từ 0.1.5, [hướng dẫn §9](huong-dan-su-dung.md#môn-tập-hiện-trên-đồng-hồ-y25-ht43)) |
| `setSportList` báo lỗi "Số môn hiện … ngoài giới hạn" | Số môn `shown` ngoài `getSportListLimits` (Y25: 4..50) | Giữ trong giới hạn. Truyền đủ mọi môn của `getSportTypes`, không chỉ môn hiện |
| Giờ dữ liệu lệch | Đổi múi giờ / giờ điện thoại sau khi đo | Thời gian là ms theo giờ điện thoại lúc đồng bộ. Đừng cộng múi giờ thêm |

## F. Tính năng điện thoại

| Triệu chứng | Nguyên nhân | Sửa |
|---|---|---|
| iOS: thông báo app không lên thiết bị | iOS dùng ANCS, cần ghép đôi hệ thống. App không tự gửi được | Người dùng ghép đôi (bấm **Ghép đôi** khi iOS hỏi). `features.ancsAuthorized` cho biết trạng thái |
| Y25 iOS: gọi điện qua đồng hồ không có tiếng | iOS không cho app tự ghép kênh gọi | Hướng dẫn người dùng vào Cài đặt → Bluetooth → chọn đồng hồ → Ghép đôi |
| `getCallBluetoothState` báo `paired: false` mà vẫn gọi được | Cờ Y25 báo về không đáng tin | Đừng chặn tính năng theo cờ này |
| Y25 báo thức: `getAlarms` lỗi `unsupported` | Y25 chỉ cho đặt báo thức trên đồng hồ | Ẩn mục báo thức khi `features.alarms === false` |
| Tìm điện thoại: điện thoại không kêu | Thư viện chỉ báo sự kiện | App tự phát chuông trong `onFindPhone`, gọi `setPhoneRinging(id, false)` khi người dùng tắt |
| Màn "đang tìm điện thoại" trên đồng hồ không tắt | App không báo lại | `setPhoneRinging(id, false)` |
| Hành động xoá dữ liệu / khôi phục gốc chạy không hỏi | App bỏ qua `control.confirm` | Luôn hiện hộp thoại khi `confirm` khác null |

## F2. AGPS (đồng hồ có GPS riêng)

| Triệu chứng | Nguyên nhân | Sửa |
|---|---|---|
| Chạy ngoài trời, đồng hồ (HT43) tìm GPS rất lâu | Hết dữ liệu vệ tinh (AGPS) | Gọi `sendAgpsPosition` với vị trí điện thoại; có file AGPS hợp lệ thì `uploadAgpsFiles` / `setAgpsFiles` |
| `uploadAgpsFiles` lỗi `bad_value` (Android) / `failed` (iOS) "Tên file AGPS không hợp lệ", "quá … KB" | Tên không phải ASCII, file rỗng hoặc quá giới hạn | Tên lấy từ `getAgpsStatus().files`; mỗi file ≤ 256 KB, tổng ≤ 512 KB |
| `uploadAgpsFiles` lỗi "Đồng hồ báo sai CRC" / "huỷ nhận" | File không đúng định dạng đồng hồ cần, hoặc mất kết nối giữa chừng | Kiểm nguồn file đúng `version` của đồng hồ; để điện thoại gần, gửi lại |
| Thư viện không tự tải file AGPS | Đúng thiết kế: thư viện không gọi mạng | App tự lấy file từ nguồn được phép |

## G. Firmware

| Triệu chứng | Nguyên nhân | Sửa |
|---|---|---|
| `checkFirmware` báo `valid: false` | Sai model / file hỏng / không phải image chính hãng | Chỉ dùng file chính hãng đúng model. Đọc `reason` |
| Nạp dở thì đứt | Rời xa thiết bị, app bị tắt, máy ngủ | Giữ app mở, máy cạnh thiết bị, cắm sạc thiết bị. Nạp lại từ đầu |
