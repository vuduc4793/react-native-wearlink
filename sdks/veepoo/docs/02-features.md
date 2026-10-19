# 02 — Tính năng app G Band / VPG Band và kế hoạch làm driver Veepoo (GE54)

> Ngày: 19/10/2026. Chỉ đọc mã, chưa kết nối GE54.
> Ký hiệu đường dẫn giống `01-protocol.md`: `S/` = `sdks/veepoo/research/android-gplusband-2.3.12/jadx-out/sources/`, `R/` = `…/jadx-out/resources/`.
> Opcode và layout byte nằm ở `01-protocol.md` §6. Tài liệu này trả lời hai câu hỏi: app chính hãng có **những màn nào**, mỗi màn bật/tắt theo **cờ nào**, và **làm gì trước**.

---

## 1. Khung app G Band 2.3.12

- Một Activity chính `com.veepoo.home.main.ui.MainActivity`, điều hướng bằng Navigation (`R/res/navigation/main_navigation.xml`, 159 fragment).
- 3 tab dưới: **Health / Device / Profile** (`R/res/menu/home_menu.xml`).
- Chỉ có một file chuỗi tiếng Anh `R/res/values/strings.xml` (khoảng 2700 khoá `ani_*`). Không có bản tiếng Việt.

**Service và quyền** (`R/AndroidManifest.xml`)

| Thành phần | Dòng | Dùng cho |
|---|---|---|
| `SocialMsgCollectService` (NotificationListenerService) | 245-254 | Chuyển tiếp thông báo app |
| `VpBluetoothService` (foreground) | 272-277 | Giữ BLE. Đăng ký động `PhoneStateReceiver` cho cuộc gọi (`S/com/veepoo/home/other/services/VpBluetoothService.java:859-865`) |
| `VpMusicOptService` | 278-281 | Điều khiển nhạc qua `MediaSessionManager` |
| `LocationService2d` | 255-258 | GPS bài tập, bảo vệ an toàn |
| `READ_PHONE_STATE`, `READ_CALL_LOG`, `READ_CONTACTS`, `ANSWER_PHONE_CALLS` | 36-45 | Báo cuộc gọi kèm tên, từ chối cuộc gọi, đồng bộ danh bạ |
| `CAMERA` | 24 | Chụp ảnh từ xa |
| `QUERY_ALL_PACKAGES` | 96 | Chọn app "khác" để nhận thông báo |
| Quyền Health Connect | 58-66 | Ghi dữ liệu sức khoẻ |

Không có quyền gửi SMS: SMS chỉ được phản chiếu từ thông báo của app nhắn tin.

---

## 2. Tab Health (màn chính)

**Thẻ trên màn chính** (`S/com/veepoo/home/home/ui/HomeNewFragment.java:2524-2581`)

- Luôn hiện: Ngủ, Nhịp tim, Hoạt động hằng ngày, Bài tập.
- Các thẻ khác hiện theo danh sách "tính năng đã dùng". Danh sách này suy ra từ cờ thiết bị trong `S/he/b.java:17-64`.

| Thẻ | Cờ (`SP` = `VpSpGetUtil`) | Nguồn cờ trong `A7` |
|---|---|---|
| Huyết áp | `isSupportBp` | gói 1 byte 1 |
| SpO2 | `isSupportSpo2h` | gói 1 byte 8 |
| Nhiệt độ | `isSupportReadTempture` | gói 3 byte 7 |
| Đường huyết | `isSupportBloodGlucoseDetect` | gói 3 byte 15 |
| HRV | `isSupportHRV` | gói 2 byte 8 |
| ECG / ECG đa đạo trình | `isSupportECG` / `isSupportEcgMultiLead` | gói 2 byte 15 |
| Thành phần cơ thể, thành phần máu | `isSupportBodyComponent`, `isSupportBloodComponent` | gói 4 byte 2, 1 |
| MET, Stress, GSR | `isSupportMet`, `isSupportStress`, `isSupportGSR` | gói 3 byte 17–18, gói 5 byte 2 |
| Health Glance (kiểm tra nhanh) | `isSupportMiniCheckup` | gói 4 byte 18 |
| Chu kỳ (phụ nữ) | người dùng không phải nam | gói 1 byte 12 |

**Trang chi tiết** (`S/com/veepoo/home/home/ui/*`)

- Mỗi chỉ số thường có: Đo, Thống kê (ngày/tuần/tháng), Tất cả dữ liệu, Giới thiệu.
- HR: vùng nhịp tim, dữ liệu tự động / đo tay.
- HA: mức, bất thường, hiệu chuẩn.
- SpO2: OSAHS / ngưng thở.
- Ngủ: chi tiết giai đoạn.
- HRV: biểu đồ Lorenz.
- ECG: báo cáo, PTT.
- Phụ nữ: cài đặt chu kỳ, dự đoán, mang thai.

**Bài tập**

- Chọn môn, chạy GPS trên điện thoại (bản đồ AMap/Google), đồng bộ buổi tập từ đồng hồ (`D4`).
- Bắt đầu buổi tập trên đồng hồ từ app (`DA`, cờ `isSupportAppOpenSport`).
- Strava, WeChat WeRun.

**Phần chạy trên server, không thuộc giao thức thiết bị**

- Phân tích AI (gọi LLM qua DashScope; khoá API viết cứng trong `S/com/veepoo/home/home/aiAnalysis/d.java:25-31`).
- Chia sẻ sức khoẻ gia đình / "Care" (`S/com/veepoo/care/*`).
- Bảo vệ an toàn (chia sẻ vị trí, SOS).

---

## 3. Tab Device

Nguồn: `S/com/veepoo/home/device/ui/DeviceFragment.java`, layout `R/res/layout/fragment_device.xml`.

### 3.1 Lưới "Functions"

Dựng ở `DeviceFragment.u()` `:1371-1419`. Nhãn ở `S/ud/e.java:41-85`. Điều hướng ở `S/com/veepoo/home/device/ui/k0.java:37-85`.

| Mục | Hiện khi | Lệnh |
|---|---|---|
| Watch Face | chỉ có kiểu UI dựng sẵn (`watchuiServer == 0 && screenStyle != 0`) | `C7` |
| Find Device | `isSupportFindDeviceByPhone` | `B5 0A/0B` |
| Camera | `isSupportCamera` | `B6` |
| Phone Call | `isSupportBTFunction \|\| isSupportContactFunction` | `BD`, `72` |
| Notifications | thiết bị đã gửi gói `AD` khi bắt tay (`S/com/veepoo/device/VPBleCenter.java:1295-1300`) | `AD`, `C2`, `C1` |
| Alarm | `isSupportMultiAlarm \|\| isSupportTextAlarm` | `B9` (hoặc `AB`) |
| Timer | **không bao giờ hiện** (kết quả kiểm tra bị bỏ, `:1390`) | `B2` |
| Weather | `isSupportWeather` | `C8` |
| World Clock | `isSupportWorldClock` | `BE` |
| GPS Ephemeris (AGPS) | `isSupoortAGPS` | `50` type `A1` |
| AI / Health assessment / 4G | các cờ AI, 4G | ngoài phạm vi |

### 3.2 Các mục cài đặt

| Mục | Nội dung | Cờ / lệnh |
|---|---|---|
| Health & Monitor | Nhắc ngồi lâu; HR tự động; HRV; cảnh báo HR cao; HA tự động + hiệu chuẩn; SpO2 cả ngày + cảnh báo thấp; đường huyết; nhiệt độ; stress; MET; phát hiện ngã; "giấc ngủ khoa học" | `B8` hoặc `B3` (khi A7 gói 4 byte 12 = 1), `E1`, `AC`, `91`. Cờ: `S/com/veepoo/home/device/viewModel/HealthMonitorViewModel.java:303-326` |
| Health reminders | Ngồi lâu, **uống nước**, nhìn xa, thể thao, uống thuốc, đọc sách, ra ngoài, rửa tay | `E7` (`isSupportHealthRemind`) |
| General (màn hình) | Thời gian sáng màn; độ sáng; lật cổ tay sáng màn (khung giờ + độ nhạy); âm bật/tắt nguồn; âm đo | `B4`, `B1`, `AA`, `B8` gói 1. Cờ: `S/com/veepoo/home/device/ui/ScreenDisplayFragment.java:89-106` |
| System | Ngôn ngữ, 12/24h, Reset, tắt máy (chỉ thiết bị không màn), khôi phục cài đặt gốc | `F4`, `B8`, `FF 55 01 73 40`, `F1 80`, `F2 04`. Nguồn: `S/com/veepoo/home/device/ui/OtherSettingFragment.java:217-349` |
| Phone Call | Bật/tắt báo cuộc gọi, cuộc gọi Bluetooth, danh bạ, liên hệ SOS | `C2` type 0, `BD`, `72` |
| Notifications | Công tắc tổng + công tắc từng app. App chỉ hiện nếu thiết bị báo hỗ trợ trong `AD`. Có thêm "Other apps" | `AD` + `C2`. Nguồn: `S/com/veepoo/home/device/viewModel/NotificationSettingsViewModel.java:122-198` |
| Alarm | Danh sách báo thức + thêm/sửa (tối đa 20 hoặc 10 có chữ) | `B9` |
| Weather | Đơn vị, vị trí, đồng bộ | `C8` |
| Watch faces | Chợ mặt đồng hồ (server), quản lý, mặt ảnh tuỳ chỉnh | `50` + DOOG; JieLi RCSP |
| About | MAC, phiên bản TP/firmware, kiểm tra cập nhật (OTA), ngắt kết nối, quên thiết bị | `FC`, `A1`, OTA (`01-protocol` §6.9) |

**Không có trong UI** dù giao thức có thể hỗ trợ:

- **Không làm phiền (DND)**: không có trang và không có lệnh.
- Đếm ngược.

**Chạy nền** (không có màn riêng)

- Điều khiển nhạc: `VpMusicOptService` đọc metadata qua `MediaSessionManager`, nhận phím từ đồng hồ (`99 02/03`) rồi `dispatchMediaKeyEvent`.
- Vòng tay tìm điện thoại: ← `B5 00` ⇒ `MainActivity.java:534-582` phát chuông và rung.
- Từ chối cuộc gọi: ← `C1 02` ⇒ `PhoneCallUtil.rejectCall`.

---

## 4. Thông báo trên Android: package → appType

Luồng:

1. `SocialMsgCollectService.onNotificationPosted` (`S/com/veepoo/home/device/service/SocialMsgCollectService.java:152-310`) lấy title, text và bigText.
2. Thông báo được lọc trùng (WhatsApp trong vòng 200 ms, cache theo `(pkg, id)`).
3. Thread `S/com/veepoo/device/f.java` đổi package thành appType rồi gửi `C2` (`:673-704`).
4. Một app chỉ được gửi khi có đủ cờ thiết bị `IS_MSG_SUPPORT_X` (từ `AD`) **và** công tắc người dùng `IS_MSG_OPEN_X`.
5. Nếu thiếu, app rơi về type 17 "Other", với điều kiện thiết bị hỗ trợ Other và người dùng đã bật.

Tên người gửi cắt ở 12 ký tự. Emoji được thay bằng chữ.

| appType | Package (`S/com/veepoo/device/constant/MsgNotificationConstants.java:9-50`) |
|---|---|
| 0 | Cuộc gọi: `PhoneStateReceiver` lúc RINGING tra tên qua `ContactsContract.PhoneLookup` (`S/com/veepoo/home/device/receiver/PhoneStateReceiver.java:100-169`) |
| 1 | SMS: `com.android.mms`, Google Messages, Samsung, OnePlus… |
| 2 / 3 | WeChat / QQ |
| 5 / 23 | Facebook `com.facebook.katana` / Messenger `com.facebook.orca` |
| 9 / 10 / 11 | WhatsApp / LINE / Instagram |
| 14 / 19 | Gmail / Telegram |
| **24** | **Zalo `com.zing.zalo`** |
| 18 / 25 / 21 | TikTok / Viber / KakaoTalk |
| 17 | App khác do người dùng chọn |

Bảng đầy đủ 0–30: `01-protocol.md` §6.7.

### 4.1 iOS (VPG Band 1.5.4, phân tích tĩnh IPA)

App iOS không chuyển tiếp nội dung thông báo; đồng hồ đọc thẳng **ANCS** của iPhone.

- Không có API đẩy nội dung thông báo lên đồng hồ.
- App không cài `didUpdateANCSAuthorizationForPeripheral` và không dùng `RequiresANCS`. Chuỗi UI chỉ ghi "It will be pushed to device when your phone receives a notification".
- Việc bond do **đồng hồ** khởi xướng: byte `!showPair` trong `A1` (byte 12) và lệnh `BC 01` (`veepooSDKSendPairedWithIphoneCommand` @`0x101028428`).
- iOS chỉ còn **công tắc theo app** qua `AD 01`.
- Cuộc gọi trên iOS cũng đi qua ANCS. Gọi điện Bluetooth dùng `CBConnectPeripheralOptionEnableTransportBridgingKey` + `BD 01`.

Hệ quả cho driver Swift: không cần dựng `C2`. Chỉ cần:

1. Gửi `A1` với showPair, hoặc gửi `BC 01`, để đồng hồ yêu cầu bond.
2. Hướng dẫn người dùng chấp nhận ghép đôi và bật "Chia sẻ thông báo hệ thống" trong cài đặt Bluetooth của iOS.
3. Quản lý công tắc từng app bằng `AD`.

Cần thử trên GE54 (Q9).

---

## 5. Danh sách tính năng cần có cho app companion của mình

Đánh dấu: ★ = cốt lõi; ◇ = có nếu GE54 bật cờ; ✕ = bỏ qua (phụ thuộc server/AI/4G).

| Nhóm | Tính năng | Lệnh | Mức |
|---|---|---|---|
| Kết nối | Quét `F8F8`, kết nối, MTU, `A1` "0000" + giờ, nhận `A7`/`AD`/`B8`, kết nối lại theo MAC | `A1`, `A7`, `AD`, `B8`, `AF` | ★ |
| Thiết bị | Pin, firmware / device number, đổi tên, khôi phục cài đặt gốc, tắt máy | `A0`, `A1`, `FC`, `84`, `FF 55`, `F1 80`, `F2` | ★ |
| Đo tay | HR, HA, SpO2, (nhiệt độ, stress, HRV) | `D0`, `90`, `80`, (`87`, `89 06/07`) | ★ / ◇ |
| Đo tự động | HR/HA/SpO2/HRV 24h | `B8` hoặc `B3` | ★ |
| Hoạt động | Bước hôm nay (cứ vài giây hỏi một lần), dữ liệu 5 phút (bước, HR, HA), quãng đường/kcal (tính từ chiều cao nếu thiết bị không gửi) | `A8`/`D8`, `D1`/`DF` | ★ |
| Ngủ | Giai đoạn ngủ, chất lượng, giờ ngủ/dậy | `E0` + parser thường/chính xác | ★ |
| Lịch sử khác | SpO2 / HRV / nhiệt độ theo ngày, kết quả đo lưu trên máy | `D2`, `D9`, `88`, `DE` | ◇ |
| Thể thao | Đọc buổi tập, điều khiển buổi tập | `D3`, `D4`, `DA` | ◇ |
| Thông báo | Cuộc gọi (tên/số, gác máy, từ chối), SMS, app (Zalo, Messenger, WhatsApp…), bật/tắt theo app | `C2`, `C1`, `AD` | ★ |
| Điều khiển | Tìm vòng tay, vòng tay tìm điện thoại, chụp ảnh từ xa, nhạc | `B5`, `B6`, `99` / `01` | ★ / ◇ |
| Cài đặt | Giờ, 12/24h, đơn vị, ngôn ngữ (vi = 10), hồ sơ + mục tiêu, nâng tay sáng màn, độ sáng, thời gian sáng màn, nhắc ngồi lâu, nhắc uống nước, báo thức, cảnh báo HR | `A5`, `B8`, `F4`, `A3`, `AA`, `B1`, `B4`, `E1`/`E7`, `B9`/`AB`, `AC` | ★ |
| Thời tiết | 7 ngày + theo giờ | `C8` | ◇ |
| Danh bạ, đồng hồ thế giới, phụ nữ | | `72`, `BE`, `85` | ◇ |
| Mặt đồng hồ | Chọn kiểu dựng sẵn; mặt ảnh tuỳ chỉnh (RGB565); tải mặt từ chợ | `C7`; `50` + DOOG | ◇ (sau) |
| OTA | Theo chip | `01-protocol` §6.9 | ✕ giai đoạn đầu |
| AI, 4G, Care, ECG đa đạo trình, thành phần máu/cơ thể | | | ✕ |

---

## 6. Kế hoạch triển khai (Kotlin trước, rồi Swift)

Thư mục đề xuất: `sdks/veepoo/{android,ios}`, theo khuôn của `sdks/gloryfit`. Mỗi bước có tiêu chí "xong" để kiểm trên GE54 thật.

| Bước | Việc | Xong khi |
|---|---|---|
| **P0. Dò thiết bị** | Màn quét thô trong app lab: log hex mọi scan record, đánh dấu ứng viên `F8 F8` / `F8 F9` / `F9 F9` / `FEE7` / `180D`. Giải MAC (byte 2–7 LE) và device number (byte 8–9 LE). Driver iOS: quét theo service `FFFF`/`FEE7`/`0001`/`180D` + `retrieveConnectedPeripherals(F0020001)` | Tìm thấy GE54 và ghi lại tên, payload mfr (`01-protocol` Q1) |
| **P1. Bắt tay** | `VeepooDriver`: connect → MTU 248 → notify `F0080002` (sau 500 ms) → `A1` "0000" + giờ + múi giờ → gom `A7` ×5, `AD`, `B8` → parse thành `VeepooCapabilities`. Hàng đợi ghi tuần tự, chờ write callback. Timeout `A1` 4 s | Log đủ `A1`/`A7`/`AD`/`B8`. Biết device number, `cpuType`, originProtocolVersion, sleepTag (Q2, Q3, Q5) |
| **P2. Cơ bản** | Pin `A0`; ngắt `AF`; giờ `A5`; hồ sơ `A3`; ngôn ngữ `F4`; `B8` (12/24h, đơn vị, HR tự động); ghi log mọi notify chưa biết | Đổi 24h/ngôn ngữ thấy ngay trên vòng tay |
| **P3. Đo tay** | HR `D0`, HA `90`, SpO2 `80` (luồng start/stream/stop, xử lý trạng thái bận / không đeo) | Số đo khớp với app G Band ±2 |
| **P4. Đồng bộ** | Bước `A8`/`D8`; ngủ `E0` (+ parser `kf/b` hoặc `kf/c` tuỳ sleepTag); 5 phút `D1` hoặc `DF` (kèm kiểm CRC); lưu vị trí gói để đọc tiếp | Tổng bước / ngủ ngày hôm qua khớp với app G Band (Q4) |
| **P5. Thông báo** | Android: NotificationListener → `C2` (map package → appType, cắt 14 byte/gói, UTF-8 đúng ranh giới ký tự). Cuộc gọi: `PhoneStateReceiver` → `C2` type 0, `C1 00 00 00` khi gác máy, nhận `C1 02` ⇒ từ chối. Công tắc theo app `AD`. iOS: bond (`A1` showPair / `BC 01`) + ANCS + `AD` (§4.1) | Zalo / Messenger / cuộc gọi hiện trên vòng tay |
| **P6. Điều khiển** | Tìm vòng tay `B5 0A/0B`; vòng tay tìm điện thoại (← `B5 00`); chụp ảnh `B6`; nhạc `99` (hoặc `01` kiểu cũ) | Thao tác từ vòng tay điều khiển được điện thoại |
| **P7. Cài đặt** | Nâng tay `AA`, độ sáng `B1`, thời gian sáng `B4`, ngồi lâu `E1` / nhắc `E7`, báo thức `B9` (CRC-16/MODBUS) / `AB`, cảnh báo HR `AC`, đo tự động `B3` nếu có | Mọi mục đọc lại được đúng giá trị vừa ghi |
| **P8. Mở rộng** | Thời tiết `C8`, danh bạ `72`, bài tập `D3`/`D4`/`DA`, lịch sử `D2`/`D9`/`88`/`DE`, phụ nữ `85`, đồng hồ thế giới `BE` | Theo cờ GE54 |
| **P9. Mặt đồng hồ / OTA** | `C7` trước. Sau đó `50` + DOOG nếu `bigDataTranType` = 2 và chip không phải JieLi/ZK. JieLi/ZK cần thư viện native: để sau | Tuỳ chip GE54 |

**Nguyên tắc chung** (rút từ code Veepoo)

- Một lệnh tại một thời điểm, chờ write callback. Mỗi luồng đọc nhiều gói có timeout riêng (`E0` 30 s, `D1` 35 s, `DF` 5 s không có gói).
- Byte trạng thái của cài đặt: 0 = không hỗ trợ, 1 = bật, 2 = tắt. Khi ghi `B8` phải giữ nguyên các byte 0.
- Không cần xác thực JieLi, licence server hay HTTP cho các tính năng P0–P8.
- Ghi log mọi notify chưa biết (opcode + hex) để bổ sung tài liệu sau khi test GE54.

---

## 7. Driver iOS (`sdks/veepoo/ios`, SwiftPM `SmartWearVeepoo`, 19/10/2026)

Bản Swift của driver Kotlin, cùng tên lớp / hàm / layout byte (`Veepoo`, `VeepooFeatures`, `VeepooMessageSwitches`,
`VeepooCustomSettings`, `VeepooMeasure`, `VeepooHistory`). Chưa chạy trên iPhone thật: chỉ biên dịch + kiểm thử đơn vị,
dùng chung vector vàng GE54 với `VeepooTest.kt` / `VeepooHistoryTest.kt` (bản chép ở `GE54Fixtures.swift`).

| Hạng mục | Cách làm trên iOS |
|---|---|
| Nhận diện | Manufacturer data `F8F8` / `F8F9` / `F9F9` + tên sạch (bỏ 2 byte rác của GE54). Không dựa vào `FEE7` / `180D` (R09 và dây đo nhịp tim cũng phát). iOS đang giữ kết nối (đã bond ANCS) ⇒ `retrieveConnectedPeripherals([F0020001, F0080001])`, nhận theo service hoặc tên `GE54` |
| MAC | Không đọc được trên iOS: lấy từ manufacturer data, rồi từ `A1` byte 12–17 |
| Bắt tay | iOS tự thương lượng MTU (không có `requestMtu(248)`); chờ 500 ms → notify `F0080002` → `A1`. Byte 12 của `A1` = `00` như app iOS gốc (showPair) để vòng tay xin bond (`VeepooDebug.requestPairing`, Q9 chưa kiểm) |
| Thông báo, cuộc gọi | Vòng tay đọc ANCS sau khi ghép đôi; app không gửi `C2`/`C1`. Có mục "Yêu cầu ghép đôi" (`BC 01`) và công tắc từng app (`AD 01`), `ancsAuthorized` lấy từ CoreBluetooth |
| Nhạc | iOS chỉ điều khiển được trình phát của chính app: lệnh `99 02/03` báo qua `onMusicCommand`; bài đang phát gửi `99 01` khi `musicType` = 1 |
| Mặt đồng hồ | Chỉ đường Veepoo gốc (`50` + DOOG, chip không phải JieLi/ZK). GE54 là JieLi (`cpuType` 1) ⇒ `supportsWatchFace` = false |
| Lịch sử | `E0` (chính xác: độ dài `A1` **LE16** như Android đo thật), `DF` (TLV, `B1` = tháng/ngày/giờ/phút), `D1` kiểu cũ (chưa kiểm), `D8`/`A8`, `D3`→`D4` kiểu cổ điển. GE54 `multiSportType` = 5 (buổi tập TLV) ⇒ chưa đọc buổi tập |

Khác Android (có chủ ý): `calories` theo **cal** như hợp đồng core iOS (`ActivityTotals`, extra `"calories"`); Android đang để kcal.
