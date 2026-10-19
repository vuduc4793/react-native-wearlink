# COROS PACE 3 — đồng hồ GPS (Bluetooth chuẩn)

> Cập nhật 19/10/2026. Nguồn: code `sdks/standard` (Android + iOS), `sdks/core`, `sdks/react-native/src`, `apps/android`,
> `apps/ios`; ghi nhận trên máy thật `sdks/qring/docs/devices.md:70` (13/10/2026), `sdks/qring/docs/qwatch-pro.md:8`,
> `docs/architecture.md:40-63`, `design/spec.md:34`; test nhận diện `StandardTests.swift:34`, `QRingMatchTests.swift:28`,
> `GloryFitMatchTests.swift:40`. Không kết nối thiết bị khi viết tài liệu này.
>
> COROS dùng app và giao thức **riêng của hãng** (không công khai, không phải oudmon/QRing: `qwatch-pro.md:8`). SDK chỉ
> nói chuyện với đồng hồ qua **dịch vụ Bluetooth SIG chuẩn** (driver `standard`): pin 180F, Device Information 180A, Heart
> Rate 180D (chỉ gửi số khi bật **Heart Rate Broadcast** trên đồng hồ). Mọi tính năng khác của đồng hồ (lịch sử, bài tập,
> cài đặt, thông báo…) phần cứng có nhưng **không tới được** bằng GATT chuẩn.

**Đường dẫn viết tắt**

| Viết tắt | Đường dẫn đầy đủ |
|---|---|
| `StandardDriver.kt` | `sdks/standard/android/src/main/java/com/smartwear/standard/StandardDriver.kt` |
| `StandardDriver.swift` | `sdks/standard/ios/Sources/SmartWearStandard/StandardDriver.swift` |
| `StandardGatt.swift` | `sdks/standard/ios/Sources/SmartWearStandard/StandardGatt.swift` |
| `StandardTests.swift` | `sdks/standard/ios/Tests/SmartWearStandardTests/StandardTests.swift` |
| `WearableDevice.kt` / `DeviceManager.kt` / `GattConnection.kt` | `sdks/core/android/src/main/java/com/smartwear/core/…` |
| `WearableDevice.swift` / `DeviceManager.swift` / `GattConnection.swift` | `sdks/core/ios/Sources/SmartWearCore/…` |
| `index.ts` / `types.ts` | `sdks/react-native/src/…` |
| `SmartWearModule.kt` | `sdks/react-native/android/src/main/java/com/smartwear/rn/SmartWearModule.kt` |
| `SmartWearImpl.swift` | `sdks/react-native/ios/SmartWearImpl.swift` |
| `DeviceDetail.kt` / `Screens.kt` / `NearbyPrompt.kt` / `ControlsSection.kt` | `apps/android/src/main/java/com/smartwear/lab/ui/…` |
| `DeviceDetailView.swift` / `NearbyPrompt.swift` / `DevicesTab.swift` | `apps/ios/SmartWearLab/…` |
| `devices.md` | `sdks/qring/docs/devices.md` |
| `SmartWearApp.kt` / `AppState.swift` | `apps/android/src/main/java/com/smartwear/lab/SmartWearApp.kt` / `apps/ios/SmartWearLab/AppState.swift` |
| `QRingMatchTests.swift` / `GloryFitMatchTests.swift` | `sdks/qring/ios/Tests/SmartWearQRingTests/…` / `sdks/gloryfit/ios/Tests/SmartWearGloryFitTests/…` |

## A. Nhận dạng

| Mục | Giá trị |
|---|---|
| Tên quảng bá | `COROS PACE 3 8E1086` (`design/spec.md:34`, test `StandardTests.swift:35`) |
| MAC | `F7:AF:2F:22:09:90` (`docs/architecture.md:63`); 2 bit cao `11` ⇒ địa chỉ static random |
| Chip | ? — không có trong tài liệu. Kiểm: ảnh FCC ID của PACE 3 hoặc OUI/PnP ID (180A 2A50) đọc bằng lab |
| Mã model (DIS 2A24) | `COROS W331` (`devices.md:70`, 13/10/2026) |
| Phần cứng (DIS 2A27) | `W31BV77075` (`devices.md:70`) |
| Phần mềm / firmware | SW (2A28) `V 3.0510.0` (`devices.md:70`); FW 2A26 chưa ghi lại — xem ở "Chi tiết kỹ thuật" của lab |
| Service / dữ liệu quảng bá nhận diện | Quảng bá `180F`, `180A`, `FEE7` (dữ liệu dùng trong test `StandardTests.swift:36`). `FEE7` trùng QRing ⇒ **không** lọc QRing bằng FEE7 đơn thuần (`docs/architecture.md:53`, `sdks/qring/android/src/main/java/com/smartwear/qring/QRing.kt:39-44`, `QRingMatchTests.swift:28`). GATT có thêm `180D` (`devices.md:70`) |
| App chính hãng | COROS (Android + iOS) — gói và phiên bản chưa ghi; kiểm `adb shell pm list packages | grep -i coros` trên điện thoại đã cài |
| Research app (checklist bước 1) | **chưa có**: repo không có APK/IPA COROS (`find` 19/10 không thấy). Lấy APK từ APKPure/điện thoại (`adb shell pm path`), IPA qua máy đã cài, đặt vào `sdks/standard/research/<nền tảng>-coros-<phiên bản>/` (gitignored). Chỉ cần nếu muốn làm giao thức riêng COROS |
| Driver | `standard` (`StandardDriver.kt:32`, `StandardDriver.swift:7`); đứng cuối registry: `SmartWearApp.kt:23`, `AppState.swift:76`, RN `SmartWearModule.kt:579`, `SmartWearImpl.swift:23` |

## B. Bảng cờ tính năng (đọc thật)

GATT chuẩn **không có bảng cờ của hãng**. "Cờ" ở đây là các service chuẩn đồng hồ có; driver suy capability từ chúng
(`StandardDriver.kt:116-131`, `StandardDriver.swift:72`).

| Service / characteristic | Có? | Đọc thật (13/10/2026, `devices.md:70`) | Driver dùng |
|---|---|---|---|
| Battery `180F` / `2A19` (read + notify) | có | pin 42 % | `refreshBattery` + notify (`StandardDriver.kt:133-151`, `StandardDriver.swift:74-105`) |
| Device Information `180A` (`2A24/2A27/2A28`, `2A26/2A29` ?) | có | `COROS W331`, `W31BV77075`, `V 3.0510.0` | đọc lúc kết nối (`StandardDriver.kt:105-126`, `StandardDriver.swift:178-200`) |
| Heart Rate `180D` / `2A37` | có service; **chỉ gửi gói khi bật HR Broadcast** | không có gói `2A37` khi chưa bật | capability `HEART_RATE` khi có 180D (`StandardDriver.kt:129-131`) |
| `2A38` Body Sensor Location | ? | chưa đọc | iOS đọc nếu có (`StandardDriver.swift:194-197`) |
| `FEE7` (vendor, quảng bá) | có | — | không dùng (giao thức riêng COROS) |

Hex thô của danh sách service chưa lưu; iOS ghi vào `info.extra["Service"]` (`StandardDriver.swift:198`), Android vào
`"Dịch vụ chuẩn"` (`StandardDriver.kt:116-120`) — chụp lại khi đo lần tới.

**Đếm đối chiếu:** 3 service chuẩn bật (180F, 180A, 180D; FEE7 là kênh riêng không tính) ↔ 6 hàng "có" ở §D ngoài nhóm
Kết nối/Tích hợp (pin, firmware, phần cứng, mã model, RSSI, nhịp tim) — chênh vì 180A phủ 3 hàng (firmware/phần cứng/
model), RSSI đo ở phía điện thoại (không phải cờ), còn hàng "Bài tập · số liệu thời gian thực" dùng lại 180D (trùng nghĩa
với nhịp tim, không đếm). 68 hàng còn lại là "riêng COROS"/`?`/`n/a`.

## C. Hành vi kết nối

| Mục | Hành vi |
|---|---|
| Quảng bá | Thấy được khi quét (13/10, 15/10). Liên tục hay từng đợt: **chưa đo**. Đo bằng `python3 -I tools/ble_scan.py raw 60` (chế độ `timeline` chỉ lọc Y25/HT43/R09/DS500/GPS 103: `tools/ble_scan.py:16`) |
| Nhận diện | Android: quảng bá có `180D` hoặc `180F` và có tên (`StandardDriver.kt:36-41`). iOS: thêm `systemConnected` (đang nối sẵn với hệ thống), loại HID 1812, đoán loại `watch` từ tên "coros"/"pace" (`StandardDriver.swift:15-37`) |
| Bind / mật khẩu / ghép đôi | Không cần: đọc pin/DIS không ghép đôi (13/10). 2A37 có cần mã hoá không: ? — kiểm khi bật HR Broadcast (nếu cần, Android/iOS sẽ hiện hộp thoại ghép hệ thống) |
| Nối lại | Android: `StandardDevice` **không** cài `reconnect()` nên dùng mặc định `reconnect() = connect()` (`WearableDevice.kt:96`) ⇒ `gatt.connect()` trực tiếp, `autoConnect=false` (`GattConnection.kt:81`); `DeviceManager` thử lại ở nền (`DeviceManager.kt:235-247`). Không có lệnh chờ (pending autoConnect) như Y25. iOS: `connect` CoreBluetooth vốn là lệnh chờ, `retrievePeripherals` khi mở app (`DeviceManager.swift:423`) |
| Kiểu ghi | Driver **không ghi characteristic nào**; chỉ ghi CCCD bật notify `2A19`, `2A37` (`StandardDriver.kt:135,164`, `StandardDriver.swift:77,134`) |
| MTU | Không xin: Android giữ 23 (`GattConnection.kt:62`); iOS tự thương lượng (`GattConnection.swift:143`). Gói HR ≤ 20 byte nên đủ |
| Giới hạn máy trung tâm | ? — chưa thử khi app COROS đang giữ kết nối. Kiểm: mở app COROS trên điện thoại A, quét bằng lab trên điện thoại B (`tools/ble_scan.py raw`) |
| HR Broadcast | Bật trên đồng hồ (menu cài đặt/khi tập) thì đồng hồ mới gửi `2A37`. iOS dừng đo sau 12 s không có gói, báo "bật chế độ phát nhịp tim trên thiết bị" (`StandardDriver.swift:45,141-151`); Android không có hạn chờ (`StandardDriver.kt:159-173`) |

## D. Bảng tính năng

"GATT chuẩn" = làm được bằng driver `standard`. "Riêng COROS" = phần cứng/app chính hãng có nhưng chỉ qua giao thức riêng
(không công khai) ⇒ SDK không làm được. Mục ghi "(theo spec hãng)" chưa đối chiếu với app COROS trên máy thật (checklist bước 4).

| Nhóm | Tính năng | Thiết bị có? | Lệnh | Kotlin | Swift | Core / RN API | UI lab A/i | Thử thật (giá trị, ngày) |
|---|---|---|---|---|---|---|---|---|
| Kết nối | Nhận diện khi quét | có (180F trong quảng bá) | quảng bá `180F/180A/FEE7` | `StandardDriver.kt:36` | `StandardDriver.swift:15` | `DeviceDriver.match`; RN `SmartWear.startScan`, `onDiscovered` (`index.ts:40,66`) | Thêm (quét) A/i | có, quét thấy 13/10/2026 (`devices.md:70`) |
| Kết nối | Kết nối | có | GATT connect + discover | `StandardDriver.kt:97` | `StandardDriver.swift:60` | `WearableDevice.connect`; RN `SmartWear.connect` (`index.ts:44`) | nút Kết nối `DeviceDetail.kt:202` / `DeviceDetailView.swift` (Giữ kết nối) | có, 13/10/2026 |
| Kết nối | Bind / mật khẩu / ghép đôi | n/a: đọc được không cần ghép (13/10) | — | n/a | n/a | `pairingPrompt` luôn null; RN `Device.pairingPrompt` | n/a | chưa (2A37 khi Broadcast: ?) |
| Kết nối | Tự nối lại (lệnh chờ) | có (thiết bị); SDK Android chưa dùng lệnh chờ | autoConnect | `WearableDevice.kt:96` (mặc định = connect) | `DeviceManager.swift:423` | `DeviceManager.setKeepConnected`; RN `SmartWear.connect(id, keep)`, `setKeepConnected` (`index.ts:44,47`) | Giữ kết nối A/i | chưa |
| Kết nối | Kiểu quảng bá | ? chưa đo nhịp | — | n/a | n/a | n/a | n/a | chưa — đo `tools/ble_scan.py raw 60` |
| Kết nối | MTU | 23 mặc định (Android) | không xin MTU | `GattConnection.kt:62` | `GattConnection.swift:143` | n/a | Chi tiết kỹ thuật | chưa |
| Kết nối | Kiểu ghi | chỉ ghi CCCD | CCCD 2902 | `StandardDriver.kt:135,164` | `StandardDriver.swift:77,134` | n/a | n/a | chưa |
| Thông tin | Pin | có (GATT chuẩn) | `180F/2A19` read + notify | `StandardDriver.kt:147` | `StandardDriver.swift:100` | `WearableDevice.battery/refreshBattery` (`WearableDevice.kt:62,104`); RN `Device.battery`, `SmartWear.refreshBattery` (`index.ts:80`) | "Cập nhật pin" `DeviceDetail.kt:199` / "Pin & thông tin" `DeviceDetailView.swift:238` | 42 %, 13/10/2026 (`devices.md:70`) |
| Thông tin | Đang sạc | n/a: 180F chỉ có mức pin, không có 2A1A | — | n/a | n/a | RN `Device.charging` = null (`types.ts:36`) | n/a | chưa |
| Thông tin | Firmware | có (DIS) | `180A/2A26`, `2A28` | `StandardDriver.kt:111-113` | `StandardDriver.swift:190-192` | `info.firmware`; RN `Device.firmware` | `DeviceDetail.kt:260` / `DeviceDetailView.swift:262` | SW `V 3.0510.0`, 13/10/2026 |
| Thông tin | Phần cứng | có (DIS) | `180A/2A27` | `StandardDriver.kt:112` | `StandardDriver.swift:191` | `info.hardware`; RN `Device.hardware` | `DeviceDetail.kt:259` / `DeviceDetailView.swift:263` | `W31BV77075`, 13/10/2026 |
| Thông tin | Mã model | có (DIS) | `180A/2A24` + `2A29` | `StandardDriver.kt:109-122` | `StandardDriver.swift:188-189` | `info.model`; RN `Device.model` | màn thiết bị A/i | `COROS W331`, 13/10/2026 |
| Thông tin | Bảng cờ tính năng | n/a: GATT chuẩn không có bảng cờ; thay bằng danh sách service (§B) | discover services | `StandardDriver.kt:116-120` | `StandardDriver.swift:198` | `info.extra`; RN `Device.capabilities` | Chi tiết kỹ thuật A/i | chưa lưu hex |
| Thông tin | RSSI | có (đo phía điện thoại) | `readRemoteRssi` | `StandardDriver.kt:154` | `WearableDevice.swift:505` | `refreshRssi`, `stats`; RN `Device.rssi` | `DeviceDetail.kt:267` / Chi tiết kỹ thuật | chưa ghi |
| Đo tay | Nhịp tim | có, **chỉ khi bật HR Broadcast** | notify `180D/2A37` | `StandardDriver.kt:159` | `StandardDriver.swift:107` | `measure(HEART_RATE)`; RN `SmartWear.measure(id,'HEART_RATE')`, `onReading` (`index.ts:50,68`) | ô đo `DeviceDetail.kt:134` / "Phép đo" `DeviceDetailView.swift:172`; Đo đồng loạt `Screens.kt:160` | không có gói khi chưa bật Broadcast, 13/10/2026; có Broadcast: chưa |
| Đo tay | SpO2 | riêng COROS (theo spec hãng); GATT chuẩn: n/a (không có PLX 1822 trong danh sách service) | — | n/a | n/a | `Capability.SPO2` không bật | n/a | chưa |
| Đo tay | Huyết áp | n/a: PACE 3 không có HA; không có 1810 | — | n/a | n/a | n/a | n/a | chưa |
| Đo tay | Nhiệt độ | ? riêng COROS (cảm biến nhiệt môi trường theo spec); GATT: n/a (không có 1809) | — | n/a | n/a | n/a | n/a | chưa — kiểm màn app COROS |
| Đo tay | Stress | ? riêng COROS; GATT: n/a | — | n/a | n/a | n/a | n/a | chưa — kiểm app COROS |
| Đo tay | HRV | riêng COROS (HRV ban đêm, theo spec hãng); GATT: RR-interval trong 2A37 nếu đồng hồ gửi | 2A37 bit4 RR | chưa có | `StandardGatt.swift:57-62` (chỉ ghi chú RR) | n/a (`Capability.HRV` không bật) | ghi chú RR trong số đo iOS | chưa |
| Đo tay | ECG | n/a: không có cảm biến ECG | — | n/a | n/a | n/a | n/a | chưa |
| Đo tay | Đường huyết | n/a: không có | — | n/a | n/a | n/a | n/a | chưa |
| Đo tay | Nhịp thở | ? riêng COROS | — | n/a | n/a | n/a | n/a | chưa — kiểm app COROS |
| Đo tay | MET/khác | n/a qua GATT; Energy Expended 2A37 bit3 nếu đồng hồ gửi | 2A37 bit3 | chưa có | `StandardGatt.swift:53-56` (parse, chưa dùng) | n/a | n/a | chưa |
| Đo tự động | HR 24h + chu kỳ | riêng COROS | — | n/a | n/a | n/a | n/a | chưa |
| Đo tự động | SpO2 tự động | riêng COROS (theo spec hãng) | — | n/a | n/a | n/a | n/a | chưa |
| Đo tự động | Huyết áp tự động | n/a: không có HA | — | n/a | n/a | n/a | n/a | chưa |
| Đo tự động | Nhiệt độ tự động | ? riêng COROS | — | n/a | n/a | n/a | n/a | chưa |
| Đo tự động | Khung giờ đo | ? riêng COROS | — | n/a | n/a | n/a | n/a | chưa |
| Đo tự động | Cảnh báo cao/thấp | riêng COROS (theo spec hãng) | — | n/a | n/a | n/a | n/a | chưa |
| Lịch sử | Bước theo giờ/ngày | riêng COROS; GATT: n/a (không có 183E/RSC) | — | n/a | n/a | `supportsHistory=false`; RN `Device.supportsHistory` | n/a (A: không có mục Lịch sử) | chưa |
| Lịch sử | Quãng đường/kcal | riêng COROS | — | n/a | n/a | n/a | n/a | chưa |
| Lịch sử | Ngủ (giai đoạn, REM, ngủ trưa) | riêng COROS | — | n/a | n/a | n/a | n/a | chưa |
| Lịch sử | HR | riêng COROS | — | n/a | n/a | n/a | n/a | chưa |
| Lịch sử | SpO2 | riêng COROS | — | n/a | n/a | n/a | n/a | chưa |
| Lịch sử | HA | n/a: không có HA | — | n/a | n/a | n/a | n/a | chưa |
| Lịch sử | Nhiệt độ | ? riêng COROS | — | n/a | n/a | n/a | n/a | chưa |
| Lịch sử | Stress/HRV | riêng COROS (HRV) | — | n/a | n/a | n/a | n/a | chưa |
| Lịch sử | Bài tập | riêng COROS (file FIT qua app/cloud COROS) | — | n/a | n/a | n/a | n/a | chưa |
| Lịch sử | Chu kỳ phụ nữ | ? riêng COROS | — | n/a | n/a | n/a | n/a | chưa |
| Lịch sử | Đồng bộ từ mốc thời gian | n/a: không có lịch sử qua GATT | — | n/a | n/a | n/a | n/a | chưa |
| Bài tập | Bắt đầu/tạm dừng/dừng từ điện thoại | riêng COROS | — | n/a | n/a | `WorkoutRemote` không cài; RN `features.workoutControl=false` | n/a | chưa |
| Bài tập | Số liệu thời gian thực | HR qua 180D khi Broadcast (đồng hồ thường bật khi tập) | 2A37 | `StandardDriver.kt:159` | `StandardDriver.swift:107` | `measure(HEART_RATE)`; RN `onReading` | ô đo nhịp tim | chưa |
| Bài tập | GPS điện thoại | n/a: đồng hồ có GPS riêng | — | n/a | n/a | RN `features.phoneLocation=false` | n/a | chưa |
| Bài tập | Danh sách môn | riêng COROS | — | n/a | n/a | RN `features.sportList=false` | n/a | chưa |
| Bài tập | AGPS | riêng COROS (app tải vệ tinh) | — | n/a | n/a | n/a | n/a | chưa |
| Điện thoại | Thông báo app (Android) | riêng COROS (theo spec hãng) | — | n/a | n/a | `NotificationDisplay` không cài; RN `features.notifications=false` | n/a | chưa |
| Điện thoại | ANCS (iOS) | ? — thông báo iPhone có thể đi qua ANCS nếu đồng hồ ghép hệ thống | ANCS | n/a | n/a | RN `features.ancsAuthorized` = null | n/a | chưa — kiểm ghép trong Cài đặt iOS |
| Điện thoại | SMS | riêng COROS | — | n/a | n/a | n/a | n/a | chưa |
| Điện thoại | Cuộc gọi đến | riêng COROS | — | n/a | n/a | RN `features.incomingCall=false` | n/a | chưa |
| Điện thoại | Từ chối/tắt tiếng | ? riêng COROS | — | n/a | n/a | RN `features.rejectCall=false` | n/a | chưa |
| Điện thoại | Trả lời SMS nhanh | n/a: không thấy trên PACE 3 (theo spec hãng) | — | n/a | n/a | RN `features.smsReply=false` | n/a | chưa |
| Điện thoại | Danh bạ | n/a: không có | — | n/a | n/a | RN `features.maxContacts=0` | n/a | chưa |
| Điện thoại | Gọi qua Bluetooth (HFP) | n/a: không có loa/mic | — | n/a | n/a | RN `features.callAudio=false` | n/a | chưa |
| Điện thoại | SOS | ? riêng COROS | — | n/a | n/a | n/a | n/a | chưa |
| Điều khiển | Nhạc (lệnh + tên bài) | ? riêng COROS | — | n/a | n/a | RN `features.musicControl=false` | n/a | chưa |
| Điều khiển | Camera từ xa | n/a: không thấy trong spec | — | n/a | n/a | RN `features.remoteCamera=false` | n/a | chưa |
| Điều khiển | Tìm thiết bị | riêng COROS (app "tìm đồng hồ", theo spec); GATT: n/a (không có Immediate Alert 1802) | — | n/a | n/a | n/a | n/a | chưa |
| Điều khiển | Thiết bị tìm điện thoại | ? riêng COROS | — | n/a | n/a | RN `onFindPhone` không phát | n/a | chưa |
| Điều khiển | Nút/sự kiện thiết bị | n/a qua GATT | — | n/a | n/a | RN `onDeviceEvent` không phát | n/a | chưa |
| Cài đặt | Giờ/múi giờ | riêng COROS (app đặt); GATT: n/a (không có CTS 1805 trong danh sách) | — | n/a | n/a | n/a | n/a | chưa |
| Cài đặt | 12/24h | riêng COROS | — | n/a | n/a | n/a | n/a | chưa |
| Cài đặt | Đơn vị | riêng COROS | — | n/a | n/a | n/a | n/a | chưa |
| Cài đặt | Ngôn ngữ | riêng COROS | — | n/a | n/a | n/a | n/a | chưa |
| Cài đặt | Hồ sơ cơ thể | riêng COROS | — | n/a | n/a | n/a | n/a | chưa |
| Cài đặt | Mục tiêu | riêng COROS | — | n/a | n/a | n/a | n/a | chưa |
| Cài đặt | Nâng tay sáng màn | riêng COROS | — | n/a | n/a | n/a | n/a | chưa |
| Cài đặt | Thời gian/độ sáng màn | riêng COROS | — | n/a | n/a | n/a | n/a | chưa |
| Cài đặt | Không làm phiền | riêng COROS | — | n/a | n/a | n/a | n/a | chưa |
| Cài đặt | Nhắc ngồi lâu | ? riêng COROS | — | n/a | n/a | n/a | n/a | chưa |
| Cài đặt | Nhắc uống nước | ? riêng COROS | — | n/a | n/a | n/a | n/a | chưa |
| Cài đặt | Báo thức | riêng COROS (đặt trên đồng hồ) | — | n/a | n/a | n/a | n/a | chưa |
| Cài đặt | Chu kỳ phụ nữ | ? riêng COROS | — | n/a | n/a | n/a | n/a | chưa |
| Cài đặt | Phím tắt/menu | riêng COROS | — | n/a | n/a | `ConfigurableDevice` không cài; RN `Device.controlCount=0`, `getControls` rỗng | `ControlsSection` ẩn | chưa |
| Cài đặt | Đồng hồ thế giới | ? riêng COROS | — | n/a | n/a | n/a | n/a | chưa |
| Hiển thị | Thời tiết | ? riêng COROS | — | n/a | n/a | `WeatherDisplay` không cài; RN `Device.supportsWeather=false` | n/a | chưa |
| Hiển thị | Mặt đồng hồ (chợ / ảnh / khe) | riêng COROS (app COROS) | — | n/a | n/a | RN `features.watchFace/watchFaceSlots/customWatchFace=false` | n/a | chưa |
| Hiển thị | Kiểu màn hình | riêng COROS | — | n/a | n/a | n/a | n/a | chưa |
| Hệ thống | Cập nhật firmware (chính hãng) | riêng COROS (app COROS) | — | n/a | n/a | RN `features.firmwareUpdate=false` | n/a | chưa |
| Hệ thống | Khôi phục gốc / xoá dữ liệu | riêng COROS (trên đồng hồ) | — | n/a | n/a | n/a | n/a | chưa |
| Hệ thống | Đổi tên Bluetooth | n/a: không có | — | n/a | n/a | n/a | n/a | chưa |
| Hệ thống | Tắt máy/khởi động lại | trên đồng hồ; qua BLE: n/a | — | n/a | n/a | n/a | n/a | chưa |
| Tích hợp | Interface core | có: `WearableDevice` (pin, info, measure HR, RSSI); không cài interface điện thoại nào | — | `StandardDriver.kt:78` | `StandardDriver.swift:42` | `WearableDevice` | — | — |
| Tích hợp | API React Native | có: `connect`, `measure`, `refreshBattery`, `Device.features` toàn `false` | — | `SmartWearModule.kt:444-463` | `SmartWearImpl.swift:517-522` | `index.ts`, `types.ts:152-183` | — | chưa thử RN |
| Tích hợp | UI lab Android | có: ô đo HR, pin, thông tin, chi tiết kỹ thuật | — | `DeviceDetail.kt:134,151,199,240` | — | — | A | 13/10/2026 (pin, DIS) |
| Tích hợp | UI lab iOS | có: "Phép đo", "Pin & thông tin" | — | — | `DeviceDetailView.swift:172,238` | — | i | chưa ghi (`scripts/ios.sh:10` có ví dụ `-autoConnect …,COROS -measure HEART_RATE`, chưa lưu kết quả) |
| Tích hợp | Popup 3D "ở gần" | n/a: chưa có mô hình 3D (`apps/shared/watch3d/` không có `coros`) | — | `NearbyPrompt.kt:78-83` | `NearbyPrompt.swift:26-31` | — | n/a | chưa |
| Tích hợp | Tài liệu | file này + `docs/architecture.md:40-48,63` | — | — | — | — | — | — |

## E. Câu hỏi mở / việc còn lại

**Câu hỏi mở**
1. Khi bật HR Broadcast, 2A37 có cần ghép đôi/mã hoá không, nhịp gửi bao nhiêu, có cờ tiếp xúc da và RR-interval không?
   Kiểm: bật Broadcast trên đồng hồ → lab "Đo nhịp tim", xem log gói.
2. Quảng bá liên tục hay từng đợt; khi app COROS đang nối thì đồng hồ có còn quảng bá/nhận máy thứ hai không?
   Kiểm: `tools/ble_scan.py raw 60` lúc có và không có app COROS.
3. FW 2A26 / hãng 2A29 có trả không? Đọc lại màn "Chi tiết kỹ thuật".
4. Đồng hồ có 1805 (Current Time), 1802 (Immediate Alert), 1822 (PLX), RSC/CSC không (danh sách service đủ)? Nếu có thì
   thêm được đặt giờ / tìm đồng hồ / SpO2 qua GATT chuẩn.

**Việc còn lại (theo giá trị cho người dùng)**
1. **Thử nhịp tim thật với HR Broadcast** (Android + iOS) và ghi giá trị + ngày vào §D. Đây là tính năng đo duy nhất SDK có
   với PACE 3.
2. **Android: nối lại bằng lệnh chờ** — `StandardDevice` cài `reconnect()` với `gatt.connect(autoConnect = true)` như driver
   khác, để đồng hồ tự nối khi quay lại tầm (hiện chỉ thử lại trực tiếp: `WearableDevice.kt:96`).
3. **Android: hạn chờ khi không có gói 2A37** + thông báo "bật Heart Rate Broadcast" như iOS (`StandardDriver.swift:141-151`);
   hiện Android chờ vô hạn ở trạng thái MEASURING.
4. Dùng RR-interval (2A37 bit 4) cho `HRV` khi đang Broadcast (iOS đã parse, Android chưa), ghi chú rõ là HRV ngắn hạn.
5. Đo nhịp quảng bá + hành vi một máy trung tâm (§C) và lưu danh sách service thô vào §B.
6. Muốn lịch sử / bài tập / cài đặt: chỉ có đường giao thức riêng COROS (lấy APK/IPA vào `sdks/standard/research/`, dịch
   ngược) hoặc API cloud COROS (cần tài khoản + điều khoản hãng). Chưa làm, cần người dùng quyết định.
7. Mô hình 3D `coros` cho popup "ở gần" (ưu tiên thấp).
