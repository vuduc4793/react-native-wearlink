# Kế hoạch: đưa toàn bộ tính năng GloryFit / GloryFitPro thành API của SDK + thư viện React Native (19/10/2026)

Nguồn: re-audit `sdks/gloryfit/docs/10-y25-feature-audit.md` §2 theo code ngày 19/10 và báo cáo khoảng trống thư viện RN
(tóm tắt ở §4 cuối file). Thiết bị thử: Y25 (`78:02:B7:03:6E:1B`) + HT43, Redmi Note 7 Pro (adb trên MacBook).

## 1. Nguyên tắc

- Tính năng điện thoại ↔ đồng hồ (thông báo, cuộc gọi, nhạc, SMS, danh bạ, gọi BT, bài tập, mặt đồng hồ, OTA) lên **core**
  dưới dạng interface/capability; driver GloryFit cài đặt. App (lab, RN) chỉ nói chuyện với interface, không ép kiểu
  `GloryFitDevice`. Hãng thứ hai chỉ cần cài interface.
- Mỗi interface có cờ `supportsXxx` (đọc từ bảng bit), mặc định "không hỗ trợ, không làm gì" như `RemoteCameraDevice`.
- Kotlin: interface + `Flow`/`StateFlow`. Swift: phương thức `open` trên `WearableDevice` + callback `onXxx` (kiểu
  `onRemoteCamera`), hoặc protocol nếu đã có tiền lệ. Tên trùng nhau giữa hai bên (bảng §2).
- Cài đặt / hành động lẻ (đọc ngôn ngữ, khung giờ đo, phím tắt, xoá dữ liệu, xoá danh bạ) đi qua `ConfigurableDevice`
  (control id / action id), không thêm interface.
- Phần "dán" hệ điều hành Android (NotificationListenerService, nghe trạng thái cuộc gọi, MediaSession, gửi SMS,
  foreground service giữ kết nối) chuyển từ `apps/android` (`PhoneBridge.kt`, `WatchNotificationListener.kt`,
  `ConnectionService.kt`) vào **`sdks/core/android` gói `com.smartwear.core.phone`**, chạy được không cần JS/UI, để lab
  và RN dùng chung. iOS: ANCS/HFP do hệ thống lo, chỉ cần trạng thái + hướng dẫn.
- KHÔNG đổi firmware. OTA chỉ bọc engine DFU hiện có cho **image chính hãng đã ký**, giữ mọi kiểm tra (đúng model, image
  hợp lệ), không nạp thật khi phát triển.

## 2. Interface mới (core)

| Interface (Kotlin) / nhóm API (Swift) | Thành phần | Nguồn GloryFit hiện có |
|---|---|---|
| `NotificationDisplay` | `supportsNotifications`, `notificationApps(): List<NotificationApp>` (key, tên, gói, có icon trên đồng hồ), `sendNotification(appKey, title, text): Boolean`, `sendSms(sender, text)`, `inQuietHours()`. iOS: `ancsAuthorized` (ANCS), không gửi | `sendAppNotification`, `sendSmsNotification`, `UteNotify` |
| `CallDisplay` | `supportsIncomingCall`, `supportsRejectCall`, `incomingCall(name, number)`, `callEnded()`, `rejectCallRequests: Flow<Unit>` / `onRejectCall` | `incomingCall`, `callEnded`, `rejectCallRequests` |
| `MusicRemote` | `supportsMusicControl`, `supportsTrackInfo`, `musicCommands: Flow<MusicCommand>` / `onMusicCommand` (PLAY_PAUSE, NEXT, PREVIOUS, VOLUME_UP, VOLUME_DOWN), `setMusicState(MusicState)` (playing, title, artist, volumePercent, durationSec, positionSec), `setMusicVolume(percent)` | `UteMusic` (Android). **iOS: thêm vào SDK** (`D1 07/08/09/0D/0E`, `3A`) |
| `SmsQuickReply` | `supportsSmsReply`, `smsReply: StateFlow<SmsReplyConfig>`, `setSmsReply(enabled, templates)`, `smsReplyRequests: Flow<SmsReplyRequest(number, text)>`, `sendSmsReplyResult(ok)` | `UteSmsReply` |
| `ContactsSync` | `maxContacts`, `syncContacts(list, progress)`, `clearContacts()` (`37 BA`) | `syncContacts` |
| `CallAudioLink` | `callAudioState()` (paired, enabled), `pairCallAudio()` (Android createBond; iOS ném lỗi "vào Cài đặt"), `setCallAudio(on)` | `callBluetoothState`, `pairCallBluetooth`, `setCallBluetooth` |
| `WatchFaceManager` (gộp `WatchFaceCustomizable` hiện có) | `watchFaceInfo()` (kích thước, tròn, maxBytes, id hiện tại, số khe), `installWatchFace(bytes, progress)`, `watchFaceSlots()` (`26 05`), `deleteWatchFaceSlot(n)` (`26 08`); Android giữ `renderWatchFace`/`setWatchFace` | `queryDialParams`, `installWatchFaceFile` |
| `WorkoutRemote` | `supportsWorkoutControl`, `sportTypes()` / `setSportList()` (`FD 48`), `startWorkout(type)`, `pauseWorkout()`, `resumeWorkout()`, `stopWorkout()` (`FD 11/22/33/00`), `workoutEvents: Flow<WorkoutEvent>` (trạng thái + realtime 14 B `FD 04`…), `locationRequests` (`FD 01 AA type`) + `sendLocation(lat, lon, altitude, speed, accuracy)` (`FD 02` [34]) | **Chưa có cả hai bên** — doc 10 §2.4 |
| `FirmwareUpdatable` (Android) | `checkFirmware(bytes): FirmwareCheck` (model, phiên bản, hợp lệ), `updateFirmware(bytes, options, progress)`, `cancelFirmwareUpdate()`, `firmwareUpdating: StateFlow<Boolean>` | `ota/RealtekDfuClient`, `RealtekImage`, lab `OtaCommands` |
| `DeviceEvents` | `deviceEvents: Flow<DeviceEvent>` cho nút/sự kiện lẻ của đồng hồ (`D1 01/04/06`…) | chưa parse |

Bổ sung cho `WearableDevice` (cả hai bên): sự kiện số đo do đồng hồ tự đẩy (đã có `latest`), `HistoryPoint.extra`
giữ nguyên tới app (huyết áp tâm trương).

## 3. Lệnh giao thức còn thiếu (GloryFit, cả Kotlin + Swift trừ khi ghi)

- Điều khiển bài tập + GPS điện thoại + danh sách môn (`FD 11/00/22/33/44/AA`, `FD 04`, `FD 01/02`, `FD 48`) → `WorkoutRemote`.
- Khe mặt đồng hồ `26 05` / `26 08` → `WatchFaceManager`.
- Đọc ngôn ngữ `AF AA` (Android; iOS đã có) → control `language`.
- Khung giờ SpO2 tự động `34 04`, HR 24h `F7 0F`, lịch nâng tay sáng màn `69 AB 01 05…` → controls.
- Đọc phím tắt `BE 01/02` → control chỉ đọc.
- Trạng thái dữ liệu `33F3` + đồng bộ từ mốc thời gian `[op] FA YYYY MM DD HH mm` → `syncHistory` nhanh hơn.
- Xoá danh bạ `37 BA`; xoá dữ liệu `AD` (action, app phải xác nhận).
- Nút đồng hồ `D1 01/04/06` → `DeviceEvents`.
- iOS: điều khiển nhạc (`D1 07/08/09/0D/0E` vào, `3A`/`D1 0C/0D/0E` ra); `D7` bit 3 (từ chối cuộc gọi) như Android.
- Gói bài tập ≥ 2 (vùng nhịp tim) nếu đọc được từ mã app.

## 4. Thư viện React Native

Sửa lỗi đang có: huyết áp tâm trương / `extra` mất trong lịch sử; số đo đồng hồ tự đẩy không tới JS; `start()` Android
gọi lại chạy trùng vòng lặp và không nối lại khi được cấp quyền sau; `startScan(0)` khác nhau hai nền tảng;
`connect(keep=false)` GloryFit Android có thể treo; thiếu foreground service Android.

Đưa ra JS (đủ hai nền tảng, nền tảng không có thì `supportsXxx=false` / reject `unsupported`): mọi interface §2,
`refreshBattery`, `getHistory` (cache), `onScanState` (quét, lỗi, Bluetooth bật/tắt), `Device.hardware/info/charging/
linkStatus`, camera từ xa, cấu hình chuyển tiếp thông báo/cuộc gọi/nhạc/SMS (chạy native), mặt đồng hồ (thông tin,
cài file, khe, Android: dựng từ ảnh), OTA (Android), `requestPermissions()` + `openNotificationAccessSettings()`.
README + `example/App.tsx` cập nhật; `tsc --noEmit` sạch; build example Android.

## 5. Thứ tự làm

1. Android: core interfaces + gói `phone` + GloryFit cài đặt + lệnh còn thiếu + lab chuyển sang dùng core. Test đơn vị;
   thử trên Redmi + Y25 những gì làm được bằng adb.
2. iOS (song song với 1): cùng interface + lệnh còn thiếu; `swift build`/`swift test`; không có iPhone để thử.
3. RN (sau 1 + 2).
4. Cập nhật doc 10 §2, `docs/feature-matrix.md`.
