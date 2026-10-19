# Xiaomi Smart Band 11 — vòng tay (Xiaomi wear V2)

> Cập nhật 19/10/2026. Nguồn: `sdks/xiaomi/docs/01-protocol.md` (dịch ngược Mi Fitness + đo thật 16/10/2026 §7),
> `sdks/xiaomi/tools/probe_v2.py`, `sdks/xiaomi/tools/bind_v2.py`, `docs/research/mi-fitness-features.md` §9 (bảng
> (loại, lệnh) protobuf của các mục cài đặt Mi Fitness 9.8.348). Không kết nối thiết bị khi viết tài liệu này.
>
> **Chưa có driver.** Mọi ô Kotlin / Swift / core / RN / lab là "chưa có (chưa có driver)". Cột "Thiết bị có?" và "Lệnh"
> lấy từ tài liệu giao thức. Cặp `(loại, lệnh)` = `WearPacket` field 1 `type` / field 2 `id` (`01-protocol.md:223-235`);
> các cặp lấy từ `mi-fitness-features.md` §9 được ghi là **suy từ cách dùng, chưa chắc** (`mi-fitness-features.md:603`).
>
> **Bind cần server Xiaomi.** Band 11 bản quốc tế trả `verifyMode = 1` (PSK) ⇒ không ghép cục bộ (ECDH) được; phải ghép
> bằng Mi Fitness (hoặc API tài khoản Xiaomi), lấy `encryptKey`, rồi nhập bằng `bind_v2.py import` (`01-protocol.md:279-286`).

**Đường dẫn viết tắt**

| Viết tắt | Đường dẫn đầy đủ |
|---|---|
| `01-protocol.md` | `sdks/xiaomi/docs/01-protocol.md` |
| `probe_v2.py` / `bind_v2.py` | `sdks/xiaomi/tools/probe_v2.py` / `sdks/xiaomi/tools/bind_v2.py` |
| `mi-fitness-features.md` | `docs/research/mi-fitness-features.md` |
| `StandardDriver.kt` / `StandardDriver.swift` | `sdks/standard/android/src/main/java/com/smartwear/standard/StandardDriver.kt` / `sdks/standard/ios/Sources/SmartWearStandard/StandardDriver.swift` |
| `NearbyPrompt.kt` / `NearbyPrompt.swift` | `apps/android/src/main/java/com/smartwear/lab/ui/NearbyPrompt.kt` / `apps/ios/SmartWearLab/NearbyPrompt.swift` |
| `index.ts` | `sdks/react-native/src/index.ts` |

Ký hiệu cột "Thiết bị có?": **có** = đo thật hoặc có lệnh rõ trong Mi Fitness cho nhóm thiết bị này; **có?** = Mi Fitness có
màn/lệnh nhưng chưa biết Band 11 có bật capability không (kiểm bằng `deviceCapability` sau auth, §B); `n/a` kèm bằng chứng.

## A. Nhận dạng

| Mục | Giá trị |
|---|---|
| Tên quảng bá | `Xiaomi Smart Band 11 9330` (4 ký tự cuối = 2 byte cuối MAC) (`01-protocol.md:269`) |
| MAC | `74:FB:17:AC:93:30` (`01-protocol.md:271`) |
| Chip | ? — không có trong tài liệu. Kiểm: FCC ID của Band 11 hoặc PnP ID (DIS `2A50`) |
| Firmware | chưa đọc (cần auth, lệnh `(2,2)` field 2). Phiên bản giao thức char `0x0050` = `03 02 12` ⇒ 3.2.18 (`01-protocol.md:272,275`) |
| Phần cứng | chưa đọc (`(2,2)` field 3 "chưa rõ", `01-protocol.md:246`) |
| Mã model | `miwear.watch.q66gl` (getBindInfo `m50` field 4, 16/10/2026, `01-protocol.md:280`); sn `81238/…`; did có sẵn |
| Nhận diện khi quét | Service data AD 0x16 UUID `FE95` (MiBeacon): `17 59 17 88 12 30 93 AC 17 FB 74` ⇒ frame control `0x5917` (version 5, auth mode 2, có MAC; bit 8 registered), **productId 34839 (`0x8817`)**, MAC đảo ngược (`01-protocol.md:269-271`). Bỏ qua beacon mở khoá `FDAB` (`01-protocol.md:51`) |
| GATT | `FE95`: chỉ `0x0050` (read), `0x005E` (notify), `0x005F` (write) ⇒ **V2/SAR**. Thêm `FDAB` (0001–0004), Battery `180F` (đọc **không cần auth**), DIS (chỉ PnP ID), HR `180D` (chỉ phát khi bật "phát nhịp tim"), `3802`, `FD2D`, `cc353442-…` (`01-protocol.md:272-274`) |
| App chính hãng | Mi Fitness (Android `com.mi.health`, `01-protocol.md:285`), bản dịch ngược 9.8.348 quốc tế (`mi-fitness-features.md:1-6`) |
| Research app (checklist bước 1) | jadx `mifit.apk` 9.8.348 (`mi-fitness-features.md:6`) **không nằm trong repo** (không có `sdks/xiaomi/research/`). Cần đặt lại APK + IPA Mi Fitness vào `sdks/xiaomi/research/<nền tảng>-mifitness-<phiên bản>/` (gitignored) |
| Driver | **chưa có**. Công cụ thử trên Mac: `probe_v2.py` (START + getBindInfo, không ghép), `bind_v2.py` (`bind` ECDH cục bộ — Band 11 từ chối; `import <MAC>` nhập `encryptKey`; `auth` xác thực + đọc pin/thông tin) (`bind_v2.py:1-10,225`) |
| Bind | **Cần server Xiaomi** (PSK, `PSKWearBinderV2`: `applyBind` → `verifyBind` → `confirmBind`, `01-protocol.md:184,279-283`). Người dùng reset band 16/10/2026; sau reset `getBindInfo` = verifyMode 1, oobMode 3 |

## B. Bảng cờ tính năng (đọc thật)

**Chưa đọc được.** Bảng cờ của Xiaomi wear là `deviceCapability` / `deviceCapabilityV2` (uint32) trả về ở bước auth
`(1,27)` (`e50` field 2/3, `01-protocol.md:219`), cộng danh sách `Feature` mà Mi Fitness dùng để hiện dòng ở tab Thiết bị
(`mi-fitness-features.md:600`). Cả hai cần **auth**, mà auth cần khoá bind từ server Xiaomi (§A). `bind_v2.py auth` in
sẵn hai giá trị này (`bind_v2.py:202`) khi đã `import` khoá.

Đọc được không cần auth (16/10/2026, Mac mini, `probe_v2.py`):

| Mục | Giá trị |
|---|---|
| Char `0x0050` (version) | `03 02 12` ⇒ V2, giao thức 3.2.18 |
| START_RSP | `02 | 01 0300 030212 | 02 0200 0080 | 03 0200 0300 | 04 0200 7017` ⇒ version 3.2.18, MPS `0x8000`, cửa sổ 3, timeout 6000 ms |
| getBindInfo `(1,17)` khi đang bind | Account field 3 = **error 9** (không có trong mã Mi Fitness) |
| getBindInfo `(1,17)` sau reset | `m50`: verifyMode **1 (PSK)**, oobMode 3, model `miwear.watch.q66gl`, mac `74:fb:17:ac:93:30` |
| Battery `180F/2A19` | 65 % |

**Đếm đối chiếu:** 0 cờ bật đọc được (chưa auth) ↔ 38 hàng "có" + 20 hàng "có?" + 10 hàng "?" ở §D (ngoài nhóm Kết nối/Tích hợp; 7 hàng n/a) —
chênh hoàn toàn vì các hàng lấy từ màn/lệnh của Mi Fitness cho cả họ thiết bị, chưa đối chiếu với `deviceCapability` của
Band 11. Làm lại phép đếm ngay khi auth được.

## C. Hành vi kết nối

| Mục | Hành vi |
|---|---|
| Quảng bá | MiBeacon `FE95` + tên. Liên tục hay từng đợt: **chưa đo**, đo bằng `python3 -I tools/ble_scan.py raw 60` (`timeline` không lọc Xiaomi) |
| Bind / ghép đôi | `(1,17)` getBindInfo → verifyMode 1 ⇒ **chỉ bind qua server Xiaomi** (Mi Fitness / API tài khoản Xiaomi). App không tự bind được vì bí mật của band chỉ server có (`01-protocol.md:279-283`). Band đang bind thì từ chối bind mới (error 9). Đường thực tế: bind bằng Mi Fitness → lấy `encryptKey` từ log `XiaomiFit*.log` (Android `/sdcard/Android/data/com.mi.health/files/log/`) hoặc sandbox iOS `MHWCahe/*/VirtualDevice_registerList/manifest.sqlite` → `bind_v2.py import <MAC>` (`01-protocol.md:284-286`) |
| Auth mỗi lần nối | `(1,26)` → `(1,27)` (plaintext, L2 opcode 1), sinh `decKey/encKey/IV` bằng HKDF `"miwear-auth"` (`01-protocol.md:139-150,209-221`). Sau đó lệnh đi L2 opcode 2 (AES-128-CTR, key = IV = appKey/deviceKey, `01-protocol.md:160`) |
| Dùng chung với Mi Fitness | Nhập cùng khoá thì lab và Mi Fitness cùng auth được; nhưng **một máy trung tâm**: chưa đo. Kiểm: để Mi Fitness nối, quét từ Mac xem band còn quảng bá không |
| Nối lại | chưa có driver. Mi Fitness cache khoá phiên để nối lại không auth lại (`01-protocol.md:150`) |
| Kiểu ghi | `0x005F`: **ghi không phản hồi** (`bind_v2.py:107`, `probe_v2.py:84,94,106`), chia khung theo MTU−3; bên nhận ACK khung L1 (type 1) cộng dồn sau 500 ms (`01-protocol.md:109`). `0x005E`: notify |
| MTU | Mi Fitness xin 512 (`01-protocol.md:31`); lớp SAR: MPS thiết bị `0x8000`, cửa sổ 3, timeout 6000 ms (START_RSP 16/10) |
| HR chuẩn | `180D` có, chỉ phát khi bật "phát nhịp tim" trên band (`01-protocol.md:274`) — dùng được bằng driver `standard` mà không cần bind (§E) |

## D. Bảng tính năng

Mọi ô Kotlin / Swift / Core-RN / UI lab: **chưa có (chưa có driver)** trừ khi ghi khác. "Thử thật" chỉ có các mục §B.

| Nhóm | Tính năng | Thiết bị có? | Lệnh | Kotlin | Swift | Core / RN API | UI lab A/i | Thử thật (giá trị, ngày) |
|---|---|---|---|---|---|---|---|---|
| Kết nối | Nhận diện khi quét | có | tên `Xiaomi Smart Band 11` + MiBeacon `FE95` productId 34839 | chưa có (chưa có driver) | chưa có (chưa có driver) | `DeviceDriver.match` (sẽ cài) | chưa có | có, 16/10/2026 (`01-protocol.md:269`) |
| Kết nối | Kết nối | có | GATT, notify `0x5E`, START_REQ L1 type 2 | chưa có (chưa có driver) | chưa có (chưa có driver) | `WearableDevice.connect`; RN `SmartWear.connect` | chưa có | có (Mac, `probe_v2.py`), 16/10/2026 |
| Kết nối | Bind / mật khẩu / ghép đôi | có — **PSK qua server Xiaomi** | `(1,17)` → server `applyBind/verifyBind/confirmBind`; nhập khoá `bind_v2.py import` | chưa có (chưa có driver) | chưa có (chưa có driver) | `pairingPrompt` không đủ (cần khoá ngoài); RN chưa có API nhập khoá | chưa có | verifyMode 1, oobMode 3, 16/10/2026 |
| Kết nối | Tự nối lại (lệnh chờ) | ? | auth `(1,26/27)` mỗi lần nối | chưa có (chưa có driver) | chưa có (chưa có driver) | `DeviceManager.setKeepConnected`; RN `setKeepConnected` | chưa có | chưa — kiểm khi có driver |
| Kết nối | Kiểu quảng bá | ? | MiBeacon `FE95` | n/a | n/a | n/a | n/a | chưa — `tools/ble_scan.py raw 60` |
| Kết nối | MTU | có (512 theo Mi Fitness) | `requestMtu(512)`; SAR MPS `0x8000` | chưa có (chưa có driver) | chưa có (chưa có driver) | n/a | n/a | MPS/cửa sổ/timeout đọc 16/10/2026 |
| Kết nối | Kiểu ghi | có | `0x5F` không phản hồi | chưa có (chưa có driver) | chưa có (chưa có driver) | n/a | n/a | có (Mac), 16/10/2026 |
| Thông tin | Pin | có | `(2,1)` System `jgg` field 1; hoặc `180F/2A19` không cần auth | chưa có (driver `standard` đọc được 180F: `StandardDriver.kt:147`) | chưa có (`StandardDriver.swift:100`) | `battery`; RN `Device.battery`, `refreshBattery` | chưa có | 65 % (180F), 16/10/2026 |
| Thông tin | Đang sạc | có | `(2,1)` field 2 chargeStatus (1 = sạc), field 3 trạng thái đầy | chưa có (chưa có driver) | chưa có (chưa có driver) | iOS `charging`; RN `Device.charging` | chưa có | chưa |
| Thông tin | Firmware | có | `(2,2)` System `ggg` field 2 | chưa có (chưa có driver) | chưa có (chưa có driver) | `info.firmware`; RN `Device.firmware` | chưa có | chưa (cần auth) |
| Thông tin | Phần cứng | ? | `(2,2)` field 3 (chưa rõ nghĩa) | chưa có (chưa có driver) | chưa có (chưa có driver) | `info.hardware`; RN `Device.hardware` | chưa có | chưa — đọc bằng `bind_v2.py auth` |
| Thông tin | Mã model | có | `(1,17)` `m50` field 4; `(2,2)` field 4 | chưa có (chưa có driver) | chưa có (chưa có driver) | `info.model`; RN `Device.model` | chưa có | `miwear.watch.q66gl`, 16/10/2026 |
| Thông tin | Bảng cờ tính năng | có | `(1,27)` `e50` field 2/3 deviceCapability/V2 | chưa có (chưa có driver) | chưa có (chưa có driver) | `capabilities`; RN `Device.capabilities`, `Device.features` | chưa có | chưa (cần auth) |
| Thông tin | RSSI | có (phía điện thoại) | quét / `readRemoteRssi` | chưa có (chưa có driver) | chưa có (chưa có driver) | `refreshRssi`; RN `Device.rssi` | chưa có | chưa |
| Đo tay | Nhịp tim | có | `(8,45)` bắt đầu, `(8,46)` dừng, đẩy `(8,47)` Fitness field 39 → field 4; hoặc `180D/2A37` khi bật phát nhịp tim | chưa có (driver `standard`: `StandardDriver.kt:159`) | chưa có (`StandardDriver.swift:107`) | `measure(HEART_RATE)`; RN `SmartWear.measure(id,'HEART_RATE')` | chưa có | chưa |
| Đo tay | SpO2 | có? | lệnh đo tay chưa biết; cài đặt `(8,8)/(8,9)` | chưa có (chưa có driver) | chưa có (chưa có driver) | `measure(SPO2)` | chưa có | chưa — tìm lệnh trong `com/xiaomi/fitness/devicesettings/bluttooth/healthmonitor/spo2` |
| Đo tay | Huyết áp | n/a: vòng không có cảm biến HA (bảng cài đặt thiết bị Mi Fitness §9 không có mục HA, `mi-fitness-features.md:618-650`) | — | n/a | n/a | n/a | n/a | chưa |
| Đo tay | Nhiệt độ | ? | chưa thấy lệnh | chưa có (chưa có driver) | chưa có (chưa có driver) | `measure(TEMPERATURE)` | chưa có | chưa — kiểm `deviceCapability` + màn Mi Fitness |
| Đo tay | Stress | có? | đo tay chưa biết; cài đặt `(8,14)/(8,15)` | chưa có (chưa có driver) | chưa có (chưa có driver) | `measure(STRESS)` | chưa có | chưa |
| Đo tay | HRV | ? | chưa thấy lệnh | chưa có (chưa có driver) | chưa có (chưa có driver) | `measure(HRV)` | chưa có | chưa — kiểm màn Mi Fitness |
| Đo tay | ECG | n/a: ECG là `pd_type 4` riêng (`01-protocol.md:37`), Band là `pd_type 3` | — | n/a | n/a | n/a | n/a | chưa |
| Đo tay | Đường huyết | n/a: Mi Fitness lấy đường huyết từ cảm biến CGM riêng (`mi-fitness-features.md:660`) | — | n/a | n/a | n/a | n/a | chưa |
| Đo tay | Nhịp thở | có? | "chất lượng thở khi ngủ" trong `(8,10)/(8,11)` | chưa có (chưa có driver) | chưa có (chưa có driver) | n/a (không có `Capability`) | chưa có | chưa |
| Đo tay | MET/khác | có? | bản ghi phút: energy, activityType, intensity (`mi-fitness-features.md:104`) | chưa có (chưa có driver) | chưa có (chưa có driver) | n/a | chưa có | chưa |
| Đo tự động | HR 24h + chu kỳ | có | `(8,10)/(8,11)` chu kỳ | chưa có (chưa có driver) | chưa có (chưa có driver) | `ConfigurableDevice` control; RN `setControl` | chưa có | chưa |
| Đo tự động | SpO2 tự động | có | `(8,8)/(8,9)`: tắt / khi ngủ / cả ngày, 10 hoặc 30 phút | chưa có (chưa có driver) | chưa có (chưa có driver) | control; RN `setControl` | chưa có | chưa |
| Đo tự động | Huyết áp tự động | n/a: không có HA | — | n/a | n/a | n/a | n/a | chưa |
| Đo tự động | Nhiệt độ tự động | ? | chưa thấy | chưa có (chưa có driver) | chưa có (chưa có driver) | control | chưa có | chưa — kiểm `deviceCapability` |
| Đo tự động | Khung giờ đo | có? | SpO2 "khi ngủ" `(8,8)`; stress "cả ngày" `(8,14)` | chưa có (chưa có driver) | chưa có (chưa có driver) | control `timeRange` | chưa có | chưa |
| Đo tự động | Cảnh báo cao/thấp | có | HR cao/thấp/khi tập `(8,10)/(8,11)`; SpO2 80/85/90 % `(8,8)/(8,9)` | chưa có (chưa có driver) | chưa có (chưa có driver) | control | chưa có | chưa |
| Lịch sử | Bước theo giờ/ngày | có | đồng bộ `SyncEngine`/`BleDataHandler`, kênh FITNESS (type 102, L2 ch 5); lệnh cụ thể chưa đọc | chưa có (chưa có driver) | chưa có (chưa có driver) | `syncHistory`; RN `SmartWear.syncHistory`, `getHistory` | chưa có | chưa |
| Lịch sử | Quãng đường/kcal | có | như trên (`ParsedDailyRecord` distance, calories) | chưa có (chưa có driver) | chưa có (chưa có driver) | `DeviceHistory.today`, `series` | chưa có | chưa |
| Lịch sử | Ngủ (giai đoạn, REM, ngủ trưa) | có | như trên (`NightSleepReport`, giai đoạn) | chưa có (chưa có driver) | chưa có (chưa có driver) | `SleepSession`; RN `DeviceHistory.sleep` | chưa có | chưa |
| Lịch sử | HR | có | như trên (bản ghi phút `hr`) | chưa có (chưa có driver) | chưa có (chưa có driver) | `series.HEART_RATE` | chưa có | chưa |
| Lịch sử | SpO2 | có? | như trên | chưa có (chưa có driver) | chưa có (chưa có driver) | `series.SPO2` | chưa có | chưa |
| Lịch sử | HA | n/a: không có HA | — | n/a | n/a | n/a | n/a | chưa |
| Lịch sử | Nhiệt độ | ? | chưa thấy | chưa có (chưa có driver) | chưa có (chưa có driver) | `series.TEMPERATURE` | chưa có | chưa — kiểm `deviceCapability` |
| Lịch sử | Stress/HRV | có (stress) | bản ghi phút `stress` | chưa có (chưa có driver) | chưa có (chưa có driver) | `series.STRESS` / `HRV` | chưa có | chưa |
| Lịch sử | Bài tập | có | parser `parser/sport/*`; trạng thái `(8,29)` | chưa có (chưa có driver) | chưa có (chưa có driver) | `DeviceHistory.workouts` | chưa có | chưa |
| Lịch sử | Chu kỳ phụ nữ | có? | Mi Fitness có thẻ kinh nguyệt (`H/curse/*`, `mi-fitness-features.md:436`); lệnh band chưa biết | chưa có (chưa có driver) | chưa có (chưa có driver) | `Capability.MENSTRUATION` | chưa có | chưa |
| Lịch sử | Đồng bộ từ mốc thời gian | có? | Mi Fitness đồng bộ theo watermark/thời gian (`mi-fitness-features.md:583`); phía BLE chưa đọc | chưa có (chưa có driver) | chưa có (chưa có driver) | `syncHistory(days)` | chưa có | chưa |
| Bài tập | Bắt đầu/tạm dừng/dừng từ điện thoại | có? | trạng thái bài tập `(8,29)`; lệnh điều khiển chưa đọc | chưa có (chưa có driver) | chưa có (chưa có driver) | `WorkoutRemote`; RN `startWorkout/pauseWorkout/resumeWorkout/stopWorkout` | chưa có | chưa |
| Bài tập | Số liệu thời gian thực | có | đẩy `(8,47)` field 39 (field 4 = HR, field 1..6 khác chưa chắc) | chưa có (chưa có driver) | chưa có (chưa có driver) | `workoutEvents`; RN `onWorkoutEvent` | chưa có | chưa |
| Bài tập | GPS điện thoại | có | Mi Fitness tập dùng GPS điện thoại (`SportService`); vị trí `(16,2)` | chưa có (chưa có driver) | chưa có (chưa có driver) | `locationRequests`/`sendLocation`; RN `onLocationRequest`, `sendLocation` | chưa có | chưa |
| Bài tập | Danh sách môn | có | thứ tự môn `(2,27)`–`(2,41)` (chưa chắc) | chưa có (chưa có driver) | chưa có (chưa có driver) | `sportTypes/setSportList`; RN `getSportTypes`, `setSportList` | chưa có | chưa |
| Bài tập | AGPS | ? | file `agps/get_online_file` + `(16,2)` (`mi-fitness-features.md:649`) | chưa có (chưa có driver) | chưa có (chưa có driver) | n/a (chưa có interface) | chưa có | chưa — Band 11 có GNSS không: kiểm `deviceCapability` |
| Điện thoại | Thông báo app (Android) | có | `(7,0)/(7,1)`; icon `(7,15)` | chưa có (chưa có driver) | chưa có (chưa có driver) | `NotificationDisplay`; RN `sendNotification`, `setPhoneLinkConfig` | chưa có | chưa |
| Điện thoại | ANCS (iOS) | ? | ANCS sau khi ghép hệ thống | n/a | chưa có (chưa có driver) | RN `features.ancsAuthorized` | chưa có | chưa — kiểm Band 11 + Mi Fitness iOS |
| Điện thoại | SMS | có | qua thông báo `(7,x)` | chưa có (chưa có driver) | chưa có (chưa có driver) | `sendSms`; RN `sendSms` | chưa có | chưa |
| Điện thoại | Cuộc gọi đến | có | `(7,9)` | chưa có (chưa có driver) | chưa có (chưa có driver) | `CallDisplay`; RN `notifyIncomingCall/notifyCallEnded` | chưa có | chưa |
| Điện thoại | Từ chối/tắt tiếng | có? | thuộc `notify/callnotify` | chưa có (chưa có driver) | chưa có (chưa có driver) | `rejectCallRequests`; RN `onRejectCall` | chưa có | chưa |
| Điện thoại | Trả lời SMS nhanh | có? | `(7,12)`, 1–10 câu | chưa có (chưa có driver) | chưa có (chưa có driver) | `SmsQuickReply`; RN `setSmsReply`, `onSmsReplyRequest` | chưa có | chưa |
| Điện thoại | Danh bạ | có? | `(21,4)/(21,5)/(21,7)` | chưa có (chưa có driver) | chưa có (chưa có driver) | `ContactsSync`; RN `syncContacts`, `clearContacts` | chưa có | chưa |
| Điện thoại | Gọi qua Bluetooth (HFP) | n/a: vòng không có loa/mic gọi | — | n/a | n/a | RN `features.callAudio=false` | n/a | chưa |
| Điện thoại | SOS | ? | `(21,0)/(21,1)` (SOS, phát hiện ngã) | chưa có (chưa có driver) | chưa có (chưa có driver) | `DeviceEvents.SOS_BUTTON` | chưa có | chưa — kiểm `deviceCapability` |
| Điều khiển | Nhạc (lệnh + tên bài) | có | `(18,1)`–`(18,13)` | chưa có (chưa có driver) | chưa có (chưa có driver) | `MusicRemote`; RN `onMusicCommand`, `setMusicState` | chưa có | chưa |
| Điều khiển | Camera từ xa | có? | `(2,7)/(2,8)` (qua BT HID) | chưa có (chưa có driver) | chưa có (chưa có driver) | `RemoteCameraDevice`; RN `setRemoteCamera`, `onRemoteCamera` | chưa có | chưa |
| Điều khiển | Tìm thiết bị | có | `(2,18)` | chưa có (chưa có driver) | chưa có (chưa có driver) | action `ConfigurableDevice.runAction`; RN `runAction` | chưa có | chưa |
| Điều khiển | Thiết bị tìm điện thoại | có | `(2,17)` | chưa có (chưa có driver) | chưa có (chưa có driver) | `findPhoneRequests`; RN `onFindPhone`, `setPhoneRinging` | chưa có | chưa |
| Điều khiển | Nút/sự kiện thiết bị | có | System đẩy subtype 79 (`DeviceBasicStatusDataHandler`, `01-protocol.md:251`) | chưa có (chưa có driver) | chưa có (chưa có driver) | `DeviceEvents`; RN `onDeviceEvent` | chưa có | chưa |
| Cài đặt | Giờ/múi giờ | có | System type 2, lệnh chưa đọc | chưa có (chưa có driver) | chưa có (chưa có driver) | tự gửi khi nối | chưa có | chưa |
| Cài đặt | 12/24h | có? | chưa đọc | chưa có (chưa có driver) | chưa có (chưa có driver) | control | chưa có | chưa |
| Cài đặt | Đơn vị | có? | chưa đọc (thời tiết có °C/℉ `(10,x)`) | chưa có (chưa có driver) | chưa có (chưa có driver) | control | chưa có | chưa |
| Cài đặt | Ngôn ngữ | có | `(2,6)` | chưa có (chưa có driver) | chưa có (chưa có driver) | control `language` | chưa có | chưa |
| Cài đặt | Hồ sơ cơ thể | có | chưa đọc (cần cho kcal) | chưa có (chưa có driver) | chưa có (chưa có driver) | control | chưa có | chưa |
| Cài đặt | Mục tiêu | có | `(8,35)/(8,36)` | chưa có (chưa có driver) | chưa có (chưa có driver) | control | chưa có | chưa |
| Cài đặt | Nâng tay sáng màn | có | `(2,24)/(2,25)` cả ngày / theo giờ, độ nhạy | chưa có (chưa có driver) | chưa có (chưa có driver) | control | chưa có | chưa |
| Cài đặt | Thời gian/độ sáng màn | có? | AOD / chế độ đêm `(2,65)/(2,66)`; độ sáng chưa đọc | chưa có (chưa có driver) | chưa có (chưa có driver) | control | chưa có | chưa |
| Cài đặt | Không làm phiền | có | `(2,14)/(2,15)` | chưa có (chưa có driver) | chưa có (chưa có driver) | control | chưa có | chưa |
| Cài đặt | Nhắc ngồi lâu | có | `(8,12)/(8,13)` giờ làm việc, nghỉ trưa | chưa có (chưa có driver) | chưa có (chưa có driver) | control | chưa có | chưa |
| Cài đặt | Nhắc uống nước | ? | chưa thấy trong Mi Fitness §9 | n/a | n/a | n/a | n/a | chưa — kiểm màn Mi Fitness |
| Cài đặt | Báo thức | có | `(17,0)/(17,5)/(17,4)`, tối đa 10, báo thức thông minh | chưa có (chưa có driver) | chưa có (chưa có driver) | control / action | chưa có | chưa |
| Cài đặt | Chu kỳ phụ nữ | có? | lệnh band chưa biết | chưa có (chưa có driver) | chưa có (chưa có driver) | control | chưa có | chưa |
| Cài đặt | Phím tắt/menu | có? | widget/ứng dụng/phím tắt `(2,27)`–`(2,41)`, `(2,51)/(2,52)` | chưa có (chưa có driver) | chưa có (chưa có driver) | control | chưa có | chưa |
| Cài đặt | Đồng hồ thế giới | có? | `(17,10)` | chưa có (chưa có driver) | chưa có (chưa có driver) | control | chưa có | chưa |
| Hiển thị | Thời tiết | có | `(10,5)`–`(10,10)`, tối đa 4 thành phố | chưa có (chưa có driver) | chưa có (chưa có driver) | `WeatherDisplay.setWeather`; RN `setWeather` | chưa có | chưa |
| Hiển thị | Mặt đồng hồ (chợ / ảnh / khe) | có | `(4,0)`–`(4,11)`; chợ Xiaomi qua server; ảnh `FaceBlePhotoFragment` | chưa có (chưa có driver) | chưa có (chưa có driver) | `WatchFaceManager`; RN `getWatchFaceInfo`, `installWatchFace`, `getWatchFaceSlots` | chưa có | chưa |
| Hiển thị | Kiểu màn hình | có? | AOD `(2,65)/(2,66)` | chưa có (chưa có driver) | chưa có (chưa có driver) | control | chưa có | chưa |
| Hệ thống | Cập nhật firmware (chính hãng) | có | `(2,4)/(2,5)` + kênh OTA (type 105, L2 ch 6); bản từ `healthapp/device/latest_ver` (server) | chưa có (chưa có driver) | chưa có (chưa có driver) | `FirmwareUpdatable`; RN `checkFirmware`, `updateFirmware` | chưa có | chưa |
| Hệ thống | Khôi phục gốc / xoá dữ liệu | có (trên band; người dùng đã reset 16/10) | lệnh BLE chưa đọc | chưa có (chưa có driver) | chưa có (chưa có driver) | action có `confirm` | chưa có | reset trên band 16/10/2026 (không qua SDK) |
| Hệ thống | Đổi tên Bluetooth | n/a: không thấy trong Mi Fitness §9 | — | n/a | n/a | n/a | n/a | chưa |
| Hệ thống | Tắt máy/khởi động lại | ? | chưa thấy | n/a | n/a | n/a | n/a | chưa — kiểm Mi Fitness |
| Tích hợp | Interface core | chưa có — sẽ cài `WearableDevice` + `ConfigurableDevice` + interface điện thoại | — | chưa có (chưa có driver) | chưa có (chưa có driver) | — | — | — |
| Tích hợp | API React Native | chưa có — cần thêm API nhập khoá bind (ví dụ `submitPairingCode` mở rộng hoặc hàm mới) | — | chưa có | chưa có | `index.ts` chưa có hàm nhập khoá | — | — |
| Tích hợp | UI lab Android | chưa có | — | chưa có | — | — | chưa có | — |
| Tích hợp | UI lab iOS | chưa có | — | — | chưa có | — | chưa có | — |
| Tích hợp | Popup 3D "ở gần" | n/a: không có mô hình 3D, không có dòng trong `NearbyPrompt.kt:78-83` / `NearbyPrompt.swift:26-31` | — | n/a | n/a | — | n/a | — |
| Tích hợp | Tài liệu | có: `01-protocol.md`, `mi-fitness-features.md` §9, file này | — | — | — | — | — | — |

## E. Câu hỏi mở / việc còn lại

**Câu hỏi mở**
1. **Bind qua server Xiaomi**: người dùng muốn (a) bind bằng Mi Fitness rồi trích `encryptKey` (dùng chung band với Mi
   Fitness), hay (b) SDK gọi API tài khoản Xiaomi (`applyBind`/`verifyBind`/`confirmBind`) bằng tài khoản của người dùng?
   (b) cần đăng nhập Xiaomi + điều khoản hãng; (a) chỉ hợp cho thử nghiệm. Chưa quyết thì không làm driver được.
2. Sau reset 16/10, band hiện đã bind lại với Mi Fitness chưa (beacon bit 8 registered)? Kiểm: `probe_v2.py`.
3. `deviceCapability` / `deviceCapabilityV2` của Band 11 là gì ⇒ các hàng "có?" / "?" ở §D. Kiểm: `bind_v2.py auth` sau `import`.
4. Band 11 quảng bá `180F`/`180D` không (nếu có, driver `standard` Android nhận luôn: `StandardDriver.kt:36-41`)? Kiểm:
   `tools/ble_scan.py raw 30`.
5. Lệnh BLE của đồng bộ lịch sử (kênh FITNESS / FILE_FITNESS) và đo tay SpO2/stress: chưa đọc trong `SyncEngine`,
   `BleDataHandler`, `parser/{daily,sport}` — cần jadx Mi Fitness (không nằm trong repo).

**Việc còn lại (theo giá trị cho người dùng)**
1. **Quyết đường bind (câu hỏi 1)**, lấy khoá, chạy `bind_v2.py auth` để đọc pin/firmware/`deviceCapability` thật — mở khoá mọi
   việc sau.
2. **Thắng nhanh không cần bind**: cho driver `standard` nhận Band 11 (pin `180F` đọc không cần auth = 65 % ngày 16/10; nhịp tim
   `180D` khi bật phát nhịp tim). Cần thêm nhận diện theo tên/MiBeacon nếu band không quảng bá 180F.
3. **Driver `xiaomi` tối thiểu** (Kotlin + Swift): SAR V2 (L1/L2, CRC16, ACK), auth `(1,26/27)`, AES-CTR, pin `(2,1)` + sạc,
   thông tin `(2,2)`, nhịp tim `(8,45/46/47)`; API nhập khoá cho lab + RN.
4. Đồng bộ lịch sử (bước, ngủ, HR, stress, bài tập) — cần đọc thêm Mi Fitness (câu hỏi 5); đặt jadx vào `sdks/xiaomi/research/`.
5. Thông báo / cuộc gọi / nhạc / tìm thiết bị / thời tiết qua interface core sẵn có (`NotificationDisplay`, `CallDisplay`,
   `MusicRemote`, `WeatherDisplay`).
6. Cài đặt (HR 24h, SpO2 tự động, DND, nâng tay, nhắc ngồi, báo thức, mục tiêu) qua `ConfigurableDevice`.
7. Đo hành vi quảng bá / một máy trung tâm khi Mi Fitness cùng giữ khoá (§C); mô hình 3D cho popup "ở gần" (ưu tiên thấp).
