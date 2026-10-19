# 10 — Audit toàn bộ tính năng Y25 (GloryFit / UTE) so với SDK của mình

> Ngày: 16/10/2026. **Chỉ đọc mã + viết tài liệu.** Không sửa code, không kết nối đồng hồ.
> Thiết bị: `Y25(ID-6E1B)`, Realtek RTL8773EWE, firmware `RB370L73ACV001205`, AMOLED tròn 466 × 466.
> Mục tiêu: liệt kê **mọi** thứ Y25 làm được (theo bảng bit + mã app GloryFit), so với những gì SDK
> (`sdks/gloryfit`) và app lab đang có, rồi xếp backlog để "all in" Y25.
>
> Phần nào không đọc thẳng từ mã hay byte thì ghi **(suy luận)**. Bổ sung cho `01-protocol.md`, `09-ios-gloryfit-app.md`
> và `docs/feature-matrix.md`. Lệnh đã có ở các tài liệu đó chỉ nhắc lại ngắn.

**Viết tắt đường dẫn** (gốc `sdks/gloryfit/research/`):

| Viết tắt | Đường dẫn |
|---|---|
| `O/` | `jadx-out/sources/com/yc/pedometer/` (GloryFit 4.0.12, tên lớp đọc được) |
| `W` / `B` / `DP` | `O/sdk/WriteCommandToBLE.java` / `O/sdk/BluetoothLeService.java` / `O/sdk/DataProcessing.java` |
| `P/` | `xapk-pro/jadx-out/sources/` (GloryFitPro 1.9.0.2) |
| `T` | `P/uterkif/uterkthis.java` (lớp dựng lệnh của SDK mới `com.yc.utesdk`). `uterkgoto()` ghi 33F1, `uterklong()` ghi 34F1 |
| Parser Pro | 33F2: `P/uterkdo/uterkbyte.java:9-330`; 34F2: `:330-525`; ack qua write callback: `P/uterkdo/uterktry.java:641-695` |
| `RkSU` | `P/com/yc/gloryfitpro/config/RkSupportUtils.java` (các hàm `isSupXxx` mà app Pro dùng cho nhánh Realtek "RK") |
| iOS SDK | `ios/gloryfit-1.6.28/Payload/GF.app/Frameworks/UTESmartBandApi.framework/UTESmartBandApi` |

SDK của mình (gốc `sdks/gloryfit/`): `AD` = `android/.../gloryfit/GloryFitDriver.kt`, `AU` = `Ute.kt`, `AS` = `UteSettings.kt`,
`AC` = `UteContacts.kt`, `AW` = `UteWeather.kt`, `AF` = `UteWatchFace.kt`, `AR` = `WatchFaceRenderer.kt`, `AO` = `ota/RealtekImage.kt`;
`ID` = `ios/Sources/SmartWearGloryFit/GloryFitDriver.swift`, `IU` = `Ute.swift`, `IS` = `UteSettings.swift`, `IH` = `UteHistory.swift`,
`IGH` = `GloryFitHistory.swift`, `IW` = `UteWorkout.swift`, `IC` = `UteContacts.swift`, `IWe` = `UteWeather.swift`, `IF` = `UteWatchFace.swift`.
App: `apps/android/src/main/java/com/smartwear/lab/ui/*.kt`, `apps/ios/SmartWearLab/*.swift`.
Số dòng trong SDK của mình có thể lệch vài dòng: một phiên khác vừa thêm `setPhoneRinging` vào hai driver.

**Kênh:** `[33]` = ghi `55FF/33F1`, nhận `33F2`; `[34]` = ghi `56FF/34F1` (không phản hồi), nhận `34F2`.

---

## 0. Tóm tắt

### 0.1 Y25 làm được gì

SDK UTE định nghĩa **247 bit** tính năng (bảng §1.4), gồm cả bit loại chip và một bit chưa có tên. Y25 bật **78 bit** (72 trong `33F1`, 6 trong `34F1`).
Gom lại, Y25 có:

| Nhóm | Y25 có (theo bit + mã app) | Y25 **không** có (bit = 0) |
|---|---|---|
| Đo sức khoẻ | Nhịp tim (đo tay + HR 24h), SpO2 (đo tay + tự động), huyết áp (PPG), ngủ do đồng hồ tính (sâu/nông/thức/**REM**, ngủ rải rác/ngủ trưa – CyWee), bước/calo/quãng đường (CyWee), kinh nguyệt | Nhiệt độ, stress/mood, HRV, ECG, đường huyết, nhịp thở, nhịp tim nghỉ (`34F1 b19.1`), PAI, thành phần cơ thể |
| Thể thao | ~25 môn, **điều khiển bài tập từ điện thoại** (`F5 0x2` = `IS_SUPPORT_SPORT_CONTROL`), tạm dừng, môn tự do, danh sách môn tuỳ chỉnh (`FD 48`), GPS khi tập (`isHasSportGPS`), **AGPS** (`isHasRYAGPS`), kiểu bơi CyWee, thời gian tập hiệu quả, mục tiêu hoạt động | Mục tiêu theo bài tập (`isHasSportTargetHRM`), độ cao, tự nhận diện môn, 100+ môn |
| Thông báo, gọi | Thông báo app (danh sách icon động `DB AA`, tin dài 240 byte, UCS-2), tên người gửi SMS (`C6`), **từ chối cuộc gọi trên đồng hồ**, **gọi điện Bluetooth Classic** (HFP, kèm Siri/Google Assistant), danh bạ (70 mục, tên 20 ký tự, xoá hết), **trả lời SMS nhanh** (Android) | SOS, tắt tiếng cuộc gọi (chưa rõ bit) |
| Điều khiển | **Điều khiển nhạc điện thoại** (`F5 0x1`, bit không tên `b7.0`) + **tên bài hát** (`F5 0x1000`), **chụp ảnh từ xa** (`C4`, không cần bit), tìm đồng hồ, đồng hồ tìm điện thoại | Chống thất lạc, nhắc mất Bluetooth |
| Cài đặt | Không làm phiền, nhắc ngồi lâu (+ khung giờ), báo thức **chỉ đặt trên đồng hồ**, nâng tay sáng màn, thời gian sáng màn (qua `A9`), ngôn ngữ (đọc danh sách + đặt), 12/24h, °C/°F, mục tiêu bước/kcal/km, cảnh báo HR cao/thấp, thời tiết 7 ngày + độ ẩm/UV, phím tắt nhanh (chỉ **đọc** trạng thái `BE`), đổi tên Bluetooth (bit có, chưa thấy lệnh) | Nhắc uống nước, rửa tay, múi giờ/đồng hồ thế giới, tiết kiệm pin, sắp xếp menu, lịch, cầu nguyện, đo tự động HR + SpO2 kiểu mới |
| Mặt đồng hồ | Mặt tuỳ chỉnh `26/27` (đã làm), mặt online (`isHasSwitchDialOnline`), quản lý khe `26 05/26 08` | Đổi mặt cài sẵn (`59`), widget (`49`), mặt video |
| Hệ thống | OTA Realtek (DFU, image ký ECDSA), đọc trạng thái dữ liệu `33F3`, chế độ nhà máy | Nâng cấp UI riêng, khởi động lại/tắt máy từ app, 4G, NFC, Alipay/WeChat Pay, mã QR / 收款码, AI/ChatGPT, dịch AI, ghi âm, nhạc trên đồng hồ, sách điện tử, ảnh, trò chơi |

**GPS:** bảng bit nói **có** (`isHasSportGPS` `b1.7`, `isHasRYAGPS` `34F1 b14.6`). Firmware Y25 có driver GNSS ICOE CC1165W (08-hardware §1). Người dùng nói Y25 **không có GPS**. Hai điều này chưa khớp, cần kiểm trên đồng hồ (§4, mục V3). Dù chip có hay không, app vẫn có đường **GPS từ điện thoại**: đồng hồ xin vị trí bằng `FD 01 AA type`, app gửi `FD 02 lat lon …` (§2.5).

### 0.2 SDK của mình so với Y25

| Trạng thái | Số dòng ở §2 | Ví dụ |
|---|---|---|
| ✅ Đã làm | 33 (4 dòng còn phần nhỏ chưa làm) | Bắt tay, pin, firmware, HR (đẩy + đo), SpO2, HA, HR 24h + chu kỳ, lịch sử HR/SpO2, bài tập (đồng bộ), danh bạ, trạng thái gọi BT, tìm đồng hồ/điện thoại, DND, nhắc ngồi, ngôn ngữ, đơn vị, hồ sơ, mục tiêu, cảnh báo HR, kinh nguyệt, thời tiết, mặt đồng hồ tuỳ chỉnh |
| 🟡 Một phần | 8 | Lịch sử Android (thiếu CyWee/`31 01`/HA), HA lịch sử (chỉ iOS), mặt đồng hồ iOS (chỉ cài `.bin`), OTA (chỉ đọc image), múi giờ trong `A3` (sau cờ debug), thông báo iOS (ANCS có sẵn nhưng app không hướng dẫn) |
| ❌ Chưa có | 24 | **Thông báo Android**, **báo cuộc gọi + từ chối**, **điều khiển nhạc**, **chụp ảnh từ xa**, **điều khiển bài tập + GPS điện thoại**, AGPS, trả lời SMS nhanh, danh sách môn, khe mặt đồng hồ, trạng thái dữ liệu `33F3`, phím tắt nhanh, xoá dữ liệu, DFU |

Còn 32 dòng n/a (Y25 tắt bit hoặc nền tảng không cho). Top gap: xem §3.

---

## 1. Bảng bit tính năng

### 1.1 Cách đọc và giá trị Y25

- `33F1` (đọc 20 byte): nhóm Android F7 = byte 0..1 (16 bit), F6 = 2..4, F5 = 5..7, F4 = 8..10, F3 = 11..13, F2 = 14..16, F1 = 17..19, mỗi nhóm **big-endian**.
  `34F1`: byte 0..1 = độ dài gói tối đa, F13 = 2..4, F12 = 5..7, F11 = 8..10, F10 = 11..13, F9 = 14..16, F8 = 17..19 (01-protocol §6.1).
- Ký hiệu `33F1 b17.3` = byte 17 bit 3 = F1 `0x080000`.

| | Giá trị | Nguồn |
|---|---|---|
| Y25 `33F1` | `08 88 6C 2A 01 24 39 43 75 6E DF FE D9 21 00 5D 78 5B A0 DC` | Đọc từ đồng hồ thật (01-protocol §10) |
| Y25 `34F1` | `00 F4 00 00 00 00 00 00 00 00 00 05 00 00 40 02 00 00 04 20` | **Dựng lại** từ các nhóm F8 = `0x000420`, F9 = `0x400200`, F10 = `0x050000` đọc trên đồng hồ (08-hardware §3.2). Test iOS đang dùng chuỗi này (`ios/Tests/.../UteHistoryTests.swift:23`). **Chưa có bản log thô của 20 byte**: cần đọc lại (§4, V1) |
| HT43 `33F1` / `34F1` | `… 4B A1 DC` / `00 F4 00 00 00 00 00 00 00 00 00 05 00 00 40 00 00 00 04 00` | 01-protocol §11 |

Khác nhau Y25 ↔ HT43: Y25 có huyết áp (`b17.4`), CyWee (`34F1 b19.5`), kiểu bơi (`34F1 b15.1`); HT43 có bước tách chạy/đi (`b18.0`).

### 1.2 Cách dựng bảng

- **Tên và mô tả**: giải mã toàn bộ `-[UTESmartBandClient checkBleFunction:]` (`0x26fda4`) và `checkBleFunction34F1:` (`0x278e14`) trong SDK iOS. Mỗi bit gồm `ldrb` → `tbz` → setter `setIsHasXxx:` + chuỗi log `"Function - Device Support … (isHasXxx)"`. Script tự viết (chỉ đọc file, `otool -tV` + đọc `__cfstring`) cho 147 bit `33F1` và 91 bit `34F1`.
- **Cột Android**: mọi lời gọi `DeviceMode.isHasFunction_N(mask)` trong GloryFitPro (`P/`, chỉ SDK RK `com.yc.utesdk`, bỏ `DeviceModeJX` của nền tảng JX) và `GetFunctionList.isSupportFunction_X(mask)` trong GloryFit cũ (`O/`). Ghi hàm đầu tiên dùng bit đó.
- Một bit Y25 bật nhưng **không bên nào đặt tên**: `33F1 b18.7` (F1 `0x008000`).
- Bit "loại chip" `b0.x` / `34F1 b2.x` chỉ để chọn đường OTA/kho mặt.

### 1.3 Gán nhóm cho các hằng `IS_SUPPORT_*` "chưa rõ nhóm"

`P/com/yc/utesdk/ble/open/DeviceMode.java` chỉ có giá trị hằng, không có nhóm. Nhiều hằng không có lời gọi nào trong app Android nên không biết thuộc F mấy.
Ghép **giá trị hằng** với **vị trí bit có tên trong SDK iOS** thì khớp 1–1. Kết quả dưới đây là **suy luận**, nhưng mọi dòng đều khớp cả tên lẫn giá trị:

| Hằng Android | Giá trị | Bit iOS cùng giá trị | Nhóm | Y25 |
|---|---|---|---|---|
| `IS_SUPPORT_SPORT_CONTROL` | 2 | `isHasSportPause` `b7.1` | F5 `0x000002` | **✓** |
| `IS_SUPPORT_MUSIC_CONTROL` | 1 | (iOS không tên) `b7.0`; app cũ `controlBandMusic` | F5 `0x000001` | **✓** |
| `IS_SUPPORT_MUSIC_CONTENT_DISPLAY` | 4096 | (không tên) `b6.4`; app cũ `MusicControl.onMetadataChanged` | F5 `0x001000` | **✓** |
| `IS_SUPPORT_BLUETOOTH_DISCONNECT_REMINDER` | 128 | `isHasDeviceBluetoothReminder` `34F1 b19.7` | F8 `0x000080` | – |
| `IS_SUPPORT_ON_SCREEN_DURATION` | 32 | `isHasHandLightCtl` `34F1 b16.5` | F9 `0x000020` | – |
| `IS_SUPPORT_LOCAL_WATCH_FACE` | 16 | `isHasModifyLocalDial` `34F1 b19.4` | F8 `0x000010` | – |
| `IS_SUPPORT_NOTIFY_WATCH_FACE_INDEX` | 512 | `isHasNotifyDial` `34F1 b12.1` | F10 `0x000200` | – |
| `IS_SUPPORT_DEVICE_POWER_SAVING_MODE` | 65536 | `isHasPowerSave` `b14.0` | F2 `0x010000` | – |
| `IS_SUPPORT_CALENDAR_REMINDER` | 64 | `isHasNewScheduleReminder` `34F1 b10.6` | F11 `0x000040` | – |
| `IS_SUPPORT_PRAYER` | 16384 | `isHasPray` `34F1 b15.6` | F9 `0x004000` | – |
| `IS_SUPPORT_QR_CODE_DISPLAY` | 1 | `isHasModifyQRCode` `34F1 b16.0` | F9 `0x000001` | – |
| `IS_SUPPORT_MULTI_QR_CODE` (收款码) | 4194304 | `isHasMultipleQRCodes` `34F1 b8.6` | F11 `0x400000` | – |
| `IS_SUPPORT_DEVICE_MUSIC_FILE` | 16384 | `isHasLocalMusicGroup` `34F1 b9.6` | F11 `0x004000` | – |
| `IS_SUPPORT_AUDIO_RECORDING_SYNC` | 4 | `isHasSyncRecordingFile` `34F1 b10.2` | F11 `0x000004` | – |
| `IS_SUPPORT_4G_MODULE` | 131072 | `isHas4G` `34F1 b14.1` | F9 `0x020000` | – |
| `IS_SUPPORT_HEALTH_LAB` | 262144 | `isHasHealthLab` `34F1 b8.2` | F11 `0x040000` | – |
| `IS_SUPPORT_WEATHER_CODE_EXPAND` | 16384 | `isHasWeatherTypeMore` `34F1 b18.6` | F8 `0x004000` | – |
| `IS_SUPPORT_SLEEP_ALARM_CLOCK` | 128 | `isHasSleepSensationAndAlarm` `34F1 b10.7` | F11 `0x000080` | – |
| `IS_SUPPORT_SOS_CALL_CONTACTS_SWITCH` | 64 | `isHasControlEmergencyPhone` `34F1 b19.6` | F8 `0x000040` | – |
| `IS_SUPPORT_MODIFY_MAX_HEART_RATE` | 4 | `isHasModifyMaxHRM` `34F1 b19.2` | F8 `0x000004` | – |
| `IS_SUPPORT_OXYGEN_MIN_WARNING` | 256 | `isHasBloodOxygenAlarm` `34F1 b9.0` | F11 `0x000100` | – |
| `IS_SUPPORT_SPORTS_TARGET_SET` | 32768 | `isHasSportTargetHRM` `b3.7` | F6 `0x008000` | – |
| `IS_SUPPORT_BREATHE` (nhịp thở, **không** phải bài tập thở) | 16384 | `isHasRespiration` `b6.6` | F5 `0x004000` | – |
| `IS_SUPPORT_HR_SCHEDULED_TEST` | 8388608 | `isHasHRMTimedMeasurement` `34F1 b8.7` | F11 `0x800000` | – |

Còn chưa gán được (không có tên iOS cùng giá trị ở vị trí hợp lý): `MUTE_CALL_MODES` (64), `CUSTOMIZE_WIDGET` (16384), `HONOR_ACCOUNT` (2048),
`APP_CONTROL_MUSIC_SWITCH` (2), `PAI` (4), `ACTICITY_TIME` (64), `APP_SET_KEY` (8). Có thể chúng nằm ở `34F1` F12/F13, nhóm mà SDK iOS 1.6.28 chưa đọc.
Trên Y25, F12 = F13 = 0 nên dù thế nào các tính năng này cũng **tắt**.

### 1.4 Bảng đầy đủ (247 bit)

Cột "Mô tả gốc" là chuỗi log trong SDK iOS (giữ tiếng Anh). Cột "Android dùng ở": `Pro` = GloryFitPro, `cũ` = GloryFit 4.0.12, kèm `file:dòng` của lời gọi đầu tiên.
**✓** in đậm = Y25 bật.

| Bit | Android | Tên SDK iOS | Mô tả gốc (SDK iOS) | Android dùng ở | Y25 | HT43 |
|---|---|---|---|---|---|---|
| `33F1 b19.0` | `F1 0x000001` |  | password.Please enter your password | cũ `BluetoothLeService.mSyncTimeRunnable` (BluetoothLeService.java:5224) | – | – |
| `33F1 b19.1` | `F1 0x000002` | `isHasWeather` | a weather function for 2 days | Pro `setFutureWeathertoBle` (uterkthis.java:4867); cũ `GetWeather.parshJson` (GetWeather.java:705) | – | – |
| `33F1 b19.2` | `F1 0x000004` |  | a full font | Pro SDK (uterkthis.java:3515); cũ `BluetoothLeService.onReceive` (BluetoothLeService.java:1499) | **✓** | ✓ |
| `33F1 b19.3` | `F1 0x000008` | `isHasSilence` | a do not disturb | Pro `isSupNotDisturb` (RkSupportUtils.java:248); cũ `SyncParameterUtils.addBeginVersionCommandIndex` (SyncParameterUtils.java:434) | **✓** | ✓ |
| `33F1 b19.4` | `F1 0x000010` | `isHasSwim` | a swimming | cũ `SportModeSupList.setSportSupList` (SportModeSupList.java:45) | **✓** | ✓ |
| `33F1 b19.5` | `F1 0x000020` | `isHasOrientation` | screen horizontal and vertical screen switching | cũ `GeneralSettingActivity.isSupportFunction` (GeneralSettingActivity.java:174) | – | – |
| `33F1 b19.6` | `F1 0x000040` | `isHasHandLight` | a hand-up bright screen | Pro `isSupBrightScreenSetting` (RkSupportUtils.java:146); cũ `FragmentSmartPlay.isSupportFunction` (FragmentSmartPlay.java:795) | **✓** | ✓ |
| `33F1 b19.7` | `F1 0x000080` | `isHasMaxHeartAlert` | a heart rate maximum alarm | Pro `isSupMaxHeartAlarm` (RkSupportUtils.java:446); cũ `RateMonitorActivity.isSupportHightestRate` (RateMonitorActivity.java:411) | **✓** | ✓ |
| `33F1 b18.0` | `F1 0x000100` | `isHasWalkRun` | walking and running | Pro SDK (uterkbyte.java:47); cũ `GoogleSportMapActivity.onCreate` (TrainingPlanActivity.java:403) | – | ✓ |
| `33F1 b18.1` | `F1 0x000200` | `isHasSleepAux` | sleep assist | cũ `GeneralSettingActivity.isSupportHrSleepAssist` (GeneralSettingActivity.java:227) | – | – |
| `33F1 b18.2` | `F1 0x000400` |  |  | cũ `BluetoothLeService.onCharacteristicRead` (BluetoothLeService.java:642) | – | – |
| `33F1 b18.3` | `F1 0x000800` | `isHasSwitchHand` | a dial and left , right hand switching |  | – | – |
| `33F1 b18.4` | `F1 0x001000` | `isHasIbeacon` | ibeacon |  | – | – |
| `33F1 b18.5` | `F1 0x002000` | `isHasWeatherSeven` | the ability to display weather within 7 days | Pro `setFutureWeathertoBle` (uterkthis.java:4864); cũ `GetWeather.parshJson` (GetWeather.java:697) | **✓** | ✓ |
| `33F1 b18.6` | `F1 0x004000` | `isHasSkip` | a skipping | cũ `SportModeSupList.setSportSupList` (SportModeSupList.java:42) | – | – |
| `33F1 b18.7` | `F1 0x008000` |  | (không có tên trong SDK iOS lẫn Android) |  | **✓** | ✓ |
| `33F1 b17.0` | `F1 0x010000` | `isHasRemindSit` | a sedentary reminder | cũ `SyncParameterUtils.addBeginVersionCommandIndex` (SyncParameterUtils.java:405) | **✓** | ✓ |
| `33F1 b17.1` | `F1 0x020000` | `isHasMulClock` | multiple alarms |  | **✓** | ✓ |
| `33F1 b17.2` | `F1 0x040000` | `isHasRemindTask` | a task reminder | cũ `FragmentSmartPlay.isSupportFunction` (FragmentSmartPlay.java:812) | – | – |
| `33F1 b17.3` | `F1 0x080000` | `isHasHRM` | heart rate | cũ `SyncParameterUtils.isSupportHeartRateFunction` (SyncParameterUtils.java:715) | **✓** | ✓ |
| `33F1 b17.4` | `F1 0x100000` | `isHasBlood` | a blood pressure | Pro `isSupBp` (RkSupportUtils.java:52); cũ `SyncParameterUtils.isSupportBloodPressureFunction` (SyncParameterUtils.java:681) | **✓** | – |
| `33F1 b17.5` | `F1 0x200000` | `isHasUV` | UV | cũ `SyncParameterUtils.addBeginVersionCommandIndex` (SyncParameterUtils.java:431) | – | – |
| `33F1 b17.6` | `F1 0x400000` | `isHasHangup` | an incoming call rejection feature | cũ `CallRemindActivity.callRemindStatus` (CallRemindActivity.java:194) | **✓** | ✓ |
| `33F1 b17.7` | `F1 0x800000` | `isHasControlMusic` | the control of phone music players |  | – | – |
| `33F1 b16.0` | `F2 0x000001` | `isHasAgeSex` | set parameters such as age, gender, etc | Pro SDK (uterkthis.java:5080) | – | – |
| `33F1 b16.1` | `F2 0x000002` | `isHasGPS` | GPS capability | cũ `SyncParameterUtils.addBeginVersionCommandIndex` (SyncParameterUtils.java:384) | – | – |
| `33F1 b16.2` | `F2 0x000004` | `isHasSmartLost` | intelligent anti-lost | Pro SDK (uterkthis.java:3813) | – | – |
| `33F1 b16.3` | `F2 0x000008` | `isHasMultiLanguage` | multi-language settings | Pro `isSupLanguage` (RkSupportUtils.java:216); cũ `GeneralSettingActivity.isSupportFunction` (GeneralSettingActivity.java:187) | **✓** | ✓ |
| `33F1 b16.4` | `F2 0x000010` | `isHasSitRemindDuration` | a setting for the sedentary reminder period | Pro `isSupSitLunchNotDisturb` (uterkthis.java:4428); cũ `SitReminderActivity.onCreate` (SitReminderActivity.java:142) | **✓** | ✓ |
| `33F1 b16.5` | `F2 0x000020` | `isHasFindiPhone` | device to find phone | Pro `isSupDeviceFindPhone` (RkSupportUtils.java:604); cũ `GeneralSettingActivity.isSupportFunction` (GeneralSettingActivity.java:169) | **✓** | ✓ |
| `33F1 b16.6` | `F2 0x000040` | `isHasSocialNotification` | software push |  | **✓** | ✓ |
| `33F1 b16.7` | `F2 0x000080` | `isHasCustomSleep` | the ability to modify sleep data |  | – | – |
| `33F1 b15.0` | `F2 0x000100` | `isHasBicycle` | a record cycling | cũ `GoogleSportMapActivity.onCreate` (SyncParameterUtils.java:377) | **✓** | ✓ |
| `33F1 b15.1` | `F2 0x000200` | `isHasTableTennis` | table tennis | cũ `SportModeSupList.setSportSupList` (SportModeSupList.java:51) | – | – |
| `33F1 b15.2` | `F2 0x000400` | `isHasBadminton` | badminton | cũ `SportModeSupList.setSportSupList` (SportModeSupList.java:48) | **✓** | ✓ |
| `33F1 b15.3` | `F2 0x000800` | `isHasTennis` | tennis | cũ `SportModeSupList.setSportSupList` (SportModeSupList.java:54) | **✓** | ✓ |
| `33F1 b15.4` | `F2 0x001000` | `isHasNewCalculate` | New calculated distance and calories | Pro `calculateCalories` (uterkthis.java:3751); cũ `PersonageActivity.setStepLenAndWeightToBLE` (PersonageActivity.java:767) | **✓** | ✓ |
| `33F1 b15.5` | `F2 0x002000` | `isHasBarometric` | Air pressure detection |  | – | – |
| `33F1 b15.6` | `F2 0x004000` | `isHas24HourHRM` | 24-hour test heart rate | Pro `isSup24HrFun` (uterkint.java:78); cũ `SyncParameterUtils.addBeginVersionCommandIndex` (RateDetailsActivity.java:392) | **✓** | ✓ |
| `33F1 b15.7` | `F2 0x008000` | `isHasCustomDeviceUI` | Support customized device interface | cũ `GeneralSettingActivity.isSupportFunction` (GeneralSettingActivity.java:179) | – | – |
| `33F1 b14.0` | `F2 0x010000` | `isHasPowerSave` | Power-Saving mode |  | – | – |
| `33F1 b14.1` | `F2 0x020000` | `isHasCalibrateHRM` | Heart rate calibration | cũ `RateMonitorActivity.isSupportHightestRate` (RateMonitorActivity.java:449) | – | – |
| `33F1 b14.2` | `F2 0x040000` | `isHasCalibrateRaiseHand` | Raise the hand to brighten the screen calibration | cũ `TurnWristActivity.onCreate` (TurnWristActivity.java:83) | – | – |
| `33F1 b14.3` | `F2 0x080000` | `isHasHRMautoSwitch` | Heart rate static and dynamic automatic switching |  | – | – |
| `33F1 b14.4` | `F2 0x100000` | `isHasHeadset` | Headphone call |  | – | – |
| `33F1 b14.5` | `F2 0x200000` | `isHasVoiceBroadcast` | Voice broadcast button |  | – | – |
| `33F1 b14.6` | `F2 0x400000` | `isHasAliQR` | Ali QR | cũ `ThirdPartyProgramActivity.isSupportFunction` (ThirdPartyProgramActivity.java:97) | – | – |
| `33F1 b14.7` | `F2 0x800000` | `isHasSOS` | SOS | Pro `isSupLanguage` (RkSupportUtils.java:216) | – | – |
| `33F1 b13.0` | `F3 0x000001` | `isHasSportHRM` | sport heart rate detection | cũ `HistoryFragment.convert` (StringUtil.java:59) | **✓** | ✓ |
| `33F1 b13.1` | `F3 0x000002` | `IshasForagroundBackCMD` | Front and back interval automatic rate adjustment |  | – | – |
| `33F1 b13.2` | `F3 0x000004` | `ishasCustomID` | Device identification name display |  | – | – |
| `33F1 b13.3` | `F3 0x000008` | `isHasShutdown` | App control device shutdown |  | – | – |
| `33F1 b13.4` | `F3 0x000010` | `ishasGsensor` | deviceg-sensor |  | – | – |
| `33F1 b13.5` | `F3 0x000020` | `isHasReadLanguage` | Read the current device for that language | cũ `SyncParameterUtils.addBeginVersionCommandIndex` (SyncParameterUtils.java:452) | **✓** | ✓ |
| `33F1 b13.6` | `F3 0x000040` | `isHasBodyFat` | BodyFat | Pro SDK (uterkthis.java:3759); cũ `WriteCommandToBLE.sendStepLenAndWeightToBLE` (SyncParameterUtils.java:387) | – | – |
| `33F1 b12.0` | `F3 0x000100` | `isHasSwitchDialOnline` | Dial can be changed online | Pro `isSupDial` (RkSupportUtils.java:186); cũ `SyncParameterUtils.addBeginVersionCommandIndex` (SyncParameterUtils.java:312) | **✓** | ✓ |
| `33F1 b12.1` | `F3 0x000200` | `isHasDeviceBgChange` | Change the background image of the device |  | – | – |
| `33F1 b12.2` | `F3 0x000400` | `isHasSwitchCH_EN` | built-in Chinese and English characters and can be switched directly | Pro SDK (uterkthis.java:3821); cũ `GeneralSettingActivity.isSupportFunction` (GeneralSettingActivity.java:186) | – | – |
| `33F1 b12.3` | `F3 0x000800` | `isHasSocialNotification2` | On the basis of the isHasSocialNotification support more social app to remind | Pro `appRemindDisplayRk` (AppRemindPresenter.java:33); cũ `StatusbarMsgNotificationListener.run` (AppRemindActivity.java:56) | **✓** | ✓ |
| `33F1 b12.4` | `F3 0x001000` | `isHasSwitchTempUnit` | a temperature switching function | Pro SDK (uterkthis.java:3829) | **✓** | ✓ |
| `33F1 b12.5` | `F3 0x002000` | `isHasECG` | a ECG function | cũ `SyncParameterUtils.addBeginVersionCommandIndex` (SyncParameterUtils.java:390) | – | – |
| `33F1 b12.6` | `F3 0x004000` | `isHasMoreLanguage` | modify the language of more interfaces | cũ `FragmentHomePage.OnResultForBandLanguage` (FragmentHomePage.java:2157) | **✓** | ✓ |
| `33F1 b12.7` | `F3 0x008000` | `isHasMenstruationReminder` | Menstruation Remind | Pro `isSupPhysiologicalFun` (RkSupportUtils.java:104); cũ `SyncParameterUtils.addBeginVersionCommandIndex` (SyncParameterUtils.java:446) | **✓** | ✓ |
| `33F1 b11.0` | `F3 0x010000` |  |  | cũ `BluetoothLeService.onReceive` (GBUtils.java:208) | – | – |
| `33F1 b11.1` | `F3 0x020000` | `isHasMountaineering` | Mountaineering | cũ `SportModeSupList.setSportSupList` (SportModeSupList.java:57) | **✓** | ✓ |
| `33F1 b11.2` | `F3 0x040000` | `isHasTramp` | Tramp | cũ `GoogleSportMapActivity.onCreate` (GoogleSportMapActivity.java:395) | **✓** | ✓ |
| `33F1 b11.3` | `F3 0x080000` | `isHasBasketball` | Basketball | cũ `SportModeSupList.setSportSupList` (SportModeSupList.java:60) | **✓** | ✓ |
| `33F1 b11.4` | `F3 0x100000` | `IsHasFactoryMode` | Factory Mode |  | **✓** | ✓ |
| `33F1 b11.5` | `F3 0x200000` | `isHasSoccer_USA` | Soccer_USA | cũ `SportModeSupList.setSportSupList` (SportModeSupList.java:63) | **✓** | ✓ |
| `33F1 b11.6` | `F3 0x400000` | `isHasBaseball` | Baseball | cũ `SportModeSupList.setSportSupList` (SportModeSupList.java:66) | **✓** | ✓ |
| `33F1 b11.7` | `F3 0x800000` | `isHasVolleyball` | Volleyball | cũ `SportModeSupList.setSportSupList` (SportModeSupList.java:69) | **✓** | ✓ |
| `33F1 b10.0` | `F4 0x000001` | `isHasTreadmill` | Treadmill | cũ `SportModeSupList.setSportSupList` (SportModeSupList.java:93) | **✓** | ✓ |
| `33F1 b10.1` | `F4 0x000002` | `isHasSit_Ups` | Sit_Ups | cũ `SportModeSupList.setSportSupList` (SportModeSupList.java:90) | **✓** | ✓ |
| `33F1 b10.2` | `F4 0x000004` | `isHasCricket` | Cricket | cũ `SportModeSupList.setSportSupList` (SportModeSupList.java:72) | **✓** | ✓ |
| `33F1 b10.3` | `F4 0x000008` | `isHasFootball_USA` | Football_USA | cũ `SportModeSupList.setSportSupList` (SportModeSupList.java:75) | **✓** | ✓ |
| `33F1 b10.4` | `F4 0x000010` | `isHasHockey` | Hockey | cũ `SportModeSupList.setSportSupList` (SportModeSupList.java:78) | **✓** | ✓ |
| `33F1 b10.5` | `F4 0x000020` | `isHasDance` | Dance | cũ `SportModeSupList.setSportSupList` (SportModeSupList.java:81) | – | – |
| `33F1 b10.6` | `F4 0x000040` | `isHasSpinningCycling` | SpinningCycling | cũ `SportModeSupList.setSportSupList` (SportModeSupList.java:84) | **✓** | ✓ |
| `33F1 b10.7` | `F4 0x000080` | `isHasYoga` | Yoga | cũ `SportModeSupList.setSportSupList` (SportModeSupList.java:87) | **✓** | ✓ |
| `33F1 b9.0` | `F4 0x000100` | `isHasGymnastics` | Gymnastics | cũ `SportModeSupList.setSportSupList` (SportModeSupList.java:96) | – | – |
| `33F1 b9.1` | `F4 0x000200` | `isHasBoating` | Boating | cũ `SportModeSupList.setSportSupList` (SportModeSupList.java:99) | **✓** | ✓ |
| `33F1 b9.2` | `F4 0x000400` | `isHasJumping_Jacks` | Jumping_Jacks | cũ `SportModeSupList.setSportSupList` (SportModeSupList.java:102) | **✓** | ✓ |
| `33F1 b9.3` | `F4 0x000800` | `isHasMinHeartAlert` | Min Heart Alert | Pro `isSupMinHeartAlarm` (uterkthis.java:3837); cũ `RateMonitorActivity.isSupportHightestRate` (RateMonitorActivity.java:430) | **✓** | ✓ |
| `33F1 b9.4` | `F4 0x001000` | `isHasBloodAutoTest` | Blood Auto Test | cũ `FragmentSmartPlay.isSupportFunction` (FragmentSmartPlay.java:882) | – | – |
| `33F1 b9.5` | `F4 0x002000` | `isHasDataStatus` | Read Data Status | Pro SDK (uterkthis.java:3051); cũ `SyncDateUtils.setLastSyncDate` (SyncDateUtils.java:65) | **✓** | ✓ |
| `33F1 b9.6` | `F4 0x004000` | `isHasModifyBluetoothName` | modify Name Of Bluetooth |  | **✓** | ✓ |
| `33F1 b9.7` | `F4 0x008000` | `isHasHeadsetHRM` | Headset HRM | cũ `FragmentHomePage.updateHomeConnectStatus` (Rate24HourSetting.java:489) | – | – |
| `33F1 b8.0` | `F4 0x010000` | `isHasShortcutButton` | Device Shortcut Button | Pro `isSupScreenTimeSetting` (RkSupportUtils.java:230); cũ `SmsRemindActivity.smsSwitchStatus` (SmsRemindActivity.java:121) | **✓** | ✓ |
| `33F1 b8.1` | `F4 0x020000` | `isHasAGPS` | Device AGPS data |  | – | – |
| `33F1 b8.2` | `F4 0x040000` | `isHasResolveSleep` | Device Resolved Sleep | Pro SDK (uterkint.java:72); cũ `WriteCommandToBLE.syncAllSleepData` (WriteCommandToBLE.java:601) | **✓** | ✓ |
| `33F1 b8.3` | `F4 0x080000` | `isHasHRMValueMaxMin` | Device HRM Value Max/Min/Average | cũ `RateDetailsActivity.calculationStatusPercentRate24` (RateDetailsActivity.java:580) | – | – |
| `33F1 b8.4` | `F4 0x100000` | `isHasLanguageSwitchDirectly` | Device Language-Switch-Directly | cũ `WriteCommandToBLE.initBandLanguageArray` (WriteCommandToBLE.java:3396) | **✓** | ✓ |
| `33F1 b8.5` | `F4 0x200000` | `isHasFreeSport` | Device FreeSport | cũ `SportModeSupList.setSportSupList` (SportModeSupList.java:105) | **✓** | ✓ |
| `33F1 b8.6` | `F4 0x400000` | `isHasAddAllDataDisplay` | Device Add-All-Data-Display | Pro `isSupStepCount` (RkSupportUtils.java:172); cũ `HealthAnalysisUtil.getStep` (HealthAnalysisUtil.java:173) | **✓** | ✓ |
| `33F1 b8.7` | `F4 0x800000` | `isHasMoreLanguage51` | multi-language settings | cũ `FragmentHomePage.OnResultForBandLanguage` (FragmentHomePage.java:2159) | – | – |
| `33F1 b7.0` | `F5 0x000001` |  |  | cũ `BluetoothLeService.onReceive` (BluetoothLeService.java:1715) | **✓** | ✓ |
| `33F1 b7.1` | `F5 0x000002` | `isHasSportPause` | Pause exercise | cũ `SportTargetSetActivity.startMapSport` (SportTargetSetActivity.java:325) | **✓** | ✓ |
| `33F1 b7.2` | `F5 0x000004` | `isHasUserID` | connect require a userid | Pro SDK (uterkif.java:73); cũ `BluetoothLeService.mSyncTimeRunnable` (BluetoothLeService.java:3597) | – | – |
| `33F1 b7.3` | `F5 0x000008` | `isHasBodyTemperature` | Body Temperature | Pro `isSupTemperatureFun` (RkSupportUtils.java:81); cũ `SyncParameterUtils.addBeginVersionCommandIndex` (SyncParameterUtils.java:394) | – | – |
| `33F1 b7.4` | `F5 0x000010` | `isHasBodyTemperatureFunction2` | Body Temperature function2 |  | – | – |
| `33F1 b7.5` | `F5 0x000020` | `isHasCalibrateBodyTemperature` | Body Temperature Calibrate |  | – | – |
| `33F1 b7.6` | `F5 0x000040` | `isHasBloodOxygen` | Blood Oxygen | Pro `isSupOxygenFun` (RkSupportUtils.java:48); cũ `SyncParameterUtils.addBeginVersionCommandIndex` (SyncParameterUtils.java:400) | **✓** | ✓ |
| `33F1 b7.7` | `F5 0x000080` | `isECG_BLE` | ECG algorithm | Pro `EcgAlgoAnalysis` (EcgAlgoAnalysis.java:23); cũ `EcgAlgoAnalysis.?` (EcgAlgoAnalysis.java:32) | – | – |
| `33F1 b6.0` | `F5 0x000100` | `isHasReadSupportLanguage` | Read Support Languages | cũ `WriteCommandToBLE.initBandLanguageArray` (BandLanguageSettingActivity.java:102) | **✓** | ✓ |
| `33F1 b6.3` | `F5 0x000800` | `isHasIconANCS` | Read Which app icons are built into the device | Pro `appRemindDisplayRk` (AppRemindPresenter.java:32); cũ `StatusbarMsgNotificationListener.onNotificationPosted` (AppRemindActivity.java:55) | **✓** | ✓ |
| `33F1 b6.4` | `F5 0x001000` |  |  | cũ `MusicControl.onMetadataChanged` (MusicControl.java:92) | **✓** | ✓ |
| `33F1 b6.5` | `F5 0x002000` | `isHasContact` | Contact | Pro `isSupContacts` (RkSupportUtils.java:195); cũ `BtCallActivity.onResume` (BtCallActivity.java:41) | **✓** | ✓ |
| `33F1 b6.6` | `F5 0x004000` | `isHasRespiration` | respiration rate |  | – | – |
| `33F1 b5.0` | `F5 0x010000` | `isHasControl_WearCheck` | control Wear Check | cũ `SyncParameterUtils.addBeginVersionCommandIndex` (SyncParameterUtils.java:449) | – | – |
| `33F1 b5.1` | `F5 0x020000` | `isHasCustomDataBluetooth5` | Device Custom data supports Bluetooth 5.0 | Pro SDK (uterkthis.java:5096) | – | – |
| `33F1 b5.2` | `F5 0x040000` | `isHasSportValidTime` | Sport Valid Time Analysis | Pro SDK (uterkgoto.java:208); cũ `MultipleSportsModesUtils.endDateTime` (MultipleSportsModesUtils.java:67) | **✓** | ✓ |
| `33F1 b5.3` | `F5 0x080000` | `isHasDrinkWaterReminder` | Drink Water Reminder | cũ `SyncParameterUtils.addBeginVersionCommandIndex` (SyncParameterUtils.java:408) | – | – |
| `33F1 b5.4` | `F5 0x100000` | `isHasBloodCalibrate` | blood pressure calibration | Pro `isSupCsBp` (RkSupportUtils.java:63); cũ `BpElDetailsActivity.onResume` (BpElDetailsActivity.java:609) | – | – |
| `33F1 b5.5` | `F5 0x200000` | `isHasActivityGoal` | more goal reminders | Pro `isSupRkGoldSetting` (RkSupportUtils.java:355); cũ `GoalActivity.initView` (GoalActivity.java:70) | **✓** | ✓ |
| `33F1 b5.6` | `F5 0x400000` | `isHasFirmwareUI` | firmware UI version upgrade | cũ `Updates.onUIVersionUpdate` (Updates.java:352) | – | – |
| `33F1 b5.7` | `F5 0x800000` |  |  |  | – | – |
| `33F1 b4.0` | `F6 0x000001` | `isHasLocalAlarmClock` | set an alarm on the device | Pro `isSupAlarmClock` (RkSupportUtils.java:266); cũ `SyncParameterUtils.addAlarmCommand` (SyncParameterUtils.java:765) | **✓** | ✓ |
| `33F1 b4.1` | `F6 0x000002` | `isHasMoreSportType` | hundreds of sports |  | – | – |
| `33F1 b4.2` | `F6 0x000004` | `isHasHandWashing` | hand washing reminder | cũ `SyncParameterUtils.addBeginVersionCommandIndex` (SyncParameterUtils.java:411) | – | – |
| `33F1 b4.3` | `F6 0x000008` | `isHasMeetingReminder` | meeting reminder |  | – | – |
| `33F1 b4.4` | `F6 0x000010` | `isHasTimeZone` | time zone setting | cũ `SyncParameterUtils.addBeginVersionCommandIndex` (SyncParameterUtils.java:474) | – | – |
| `33F1 b4.5` | `F6 0x000020` | `IsHasMPF` |  | Pro `isSupMoodPressureFun` (RkSupportUtils.java:85); cũ `SyncParameterUtils.connectCommandIndex` (SyncParameterUtils.java:282) | – | – |
| `33F1 b4.7` | `F6 0x000080` | `isHasCustomWeatherCity` | custom weather city name | Pro `setFutureWeathertoBle` (uterkthis.java:4864); cũ `FragmentHomePage.onWeChatPayAuthState` (FragmentHomePage.java:2059) | – | – |
| `33F1 b3.0` | `F6 0x000100` | `isHasClockShow` | clock Show or Hidden | Pro SDK (uterkthis.java:4739); cũ `WriteCommandToBLE.sendToSetAlarmCommand` (WriteCommandToBLE.java:845) | – | – |
| `33F1 b3.1` | `F6 0x000200` |  | sms reply | Pro `isSupSmsReply` (uterkfinal.java:572); cũ `SyncParameterUtils.addBeginVersionCommandIndex` (SyncParameterUtils.java:477) | **✓** | ✓ |
| `33F1 b3.2` | `F6 0x000400` | `isHasBloodMoreFeatures` | Blood More Features | cũ `SyncParameterUtils.addBeginVersionCommandIndex` (SyncParameterUtils.java:332) | – | – |
| `33F1 b3.3` | `F6 0x000800` | `isHasWeatherHumidityUV` | Humidity and UV | Pro `setFutureWeathertoBle` (uterkthis.java:2164); cũ `WriteCommandToBLE.syncWeatherToBLESecondSectionForXiaoYang` (WriteCommandToBLE.java:1675) | **✓** | ✓ |
| `33F1 b3.4` | `F6 0x001000` | `isHasReboot` | reboot |  | – | – |
| `33F1 b3.5` | `F6 0x002000` | `isHasCustomSportIconList` | custom Sport Icon List | Pro `isSupSportList` (RkSupportUtils.java:179); cũ `ChannelActivity.onFinish` (StringUtil.java:56) | **✓** | ✓ |
| `33F1 b3.6` | `F6 0x004000` | `isHasCustomMenuIconList` | custom Menu Icon List |  | – | – |
| `33F1 b3.7` | `F6 0x008000` | `isHasSportTargetHRM` | set Sport Target HRM Alert |  | – | – |
| `33F1 b2.0` | `F6 0x010000` | `isHasCustomSiestaTimeNoDisturb` | custom siesta time (do not disturb) | Pro `isSupSitLunchNotDisturbTime` (uterkthis.java:4429) | – | – |
| `33F1 b2.1` | `F6 0x020000` | `isHasClockTitle` | Clock Title | Pro `isSupAlarmClock` (RkSupportUtils.java:266); cũ `RB303JDUtil.doUnbindRB303JD` (RB303JDUtil.java:33) | – | – |
| `33F1 b2.2` | `F6 0x040000` | `isHasBluetooth3` | BT3.0 | Pro `isSupBtCall` (RkSupportUtils.java:239); cũ `FragmentSmartPlay.isSupportFunction` (SyncParameterUtils.java:303) | **✓** | ✓ |
| `33F1 b2.3` | `F6 0x080000` | `isHasContactMax20` | Device Maximum length of contact name is 20 | Pro SDK (uterkthis.java:616); cũ `ContactsSelectActivity.handleMessage` (ContactsSelectActivity.java:126) | **✓** | ✓ |
| `33F1 b2.4` | `F6 0x100000` | `isHasBTAddressModify` | modify Bluetooth Address |  | – | – |
| `33F1 b2.5` | `F6 0x200000` | `isHasLocalLanguage` | change the language. No need to connect the app | cũ `BluetoothLeService.isBandLanguageSameToAPP` (BluetoothLeService.java:5736) | **✓** | ✓ |
| `33F1 b2.6` | `F6 0x400000` |  |  | Pro SDK (uterkthis.java:3529); cũ `GBUtils.hexStringToBytess` (GBUtils.java:209) | **✓** | ✓ |
| `33F1 b1.0` | `F7 0x000001` | `isHasScheduleReminder` | Schedule Reminder |  | – | – |
| `33F1 b1.1` | `F7 0x000002` | `isHasSOSContacts` | SOS Contacts | Pro `isSupSos` (RkSupportUtils.java:205); cũ `SyncParameterUtils.addBeginVersionCommandIndex` (SyncParameterUtils.java:481) | – | – |
| `33F1 b1.2` | `F7 0x000004` | `isHasReadDialLocation` | reading dial information |  | – | – |
| `33F1 b1.3` | `F7 0x000008` | `isHasSleepREM` | sleep type REM | Pro `isSupSleepRemFun` (RkSupportUtils.java:42); cũ `FragmentSleepDetailsDay.isSupportSleepRem` (FragmentSleepDetailsDay.java:353) | **✓** | ✓ |
| `33F1 b1.4` | `F7 0x000010` | `isHasBloodHengAi` | blood type : Heng ai | Pro `isSupElBp` (RkSupportUtils.java:68) | – | – |
| `33F1 b1.5` | `F7 0x000020` | `isHasSportRecognizeAuto` | Sport Automatic Recognition |  | – | – |
| `33F1 b1.6` | `F7 0x000040` | `isHasSportTimeGoal` | more sport time reminders |  | – | – |
| `33F1 b1.7` | `F7 0x000080` | `isHasSportGPS` | sport GPS | cũ `BluetoothLeService.dealWithSportMode` (BluetoothLeService.java:7340) | **✓** | ✓ |
| `33F1 b0.0` | `F7 0x000100` |  | DA |  | – | – |
| `33F1 b0.1` | `F7 0x000200` |  | RT | cũ `GBUtils.hexStringToBytess` (GBUtils.java:208) | – | – |
| `33F1 b0.2` | `F7 0x000400` |  | NR | cũ `BluetoothLeService.onReceive` (FirmwareActivity.java:295) | – | – |
| `33F1 b0.3` | `F7 0x000800` | `Is8762Cx` | 8762Cx | Pro SDK (uterkfinal.java:486); cũ `BluetoothLeService.datePacketOperate` (GBUtils.java:208) | **✓** | ✓ |
| `33F1 b0.4` | `F7 0x001000` |  | SYD |  | – | – |
| `33F1 b0.5` | `F7 0x002000` |  |  | Pro SDK (uterkfinal.java:486); cũ `FirmwareActivity.onReceive` (MainActivity.java:198) | – | – |
| `33F1 b0.6` | `F7 0x004000` |  | ACx |  | – | – |
| `33F1 b0.7` | `F7 0x008000` |  | ATx | Pro `isJXPlatformATS3085L` (DevicePlatform.java:28); cũ `DevicePlatform.isJXPlatformATS3085L` (DevicePlatform.java:41) | – | – |
| `34F1 b19.0` | `F8 0x000001` | `isHasTimeZone10` | 10 time zones | Pro SDK (uterkthis.java:1021) | – | – |
| `34F1 b19.1` | `F8 0x000002` | `isHasRHRM` | Resting Heart Rate | Pro `isSupRestHeartRate` (RkSupportUtils.java:282) | – | – |
| `34F1 b19.2` | `F8 0x000004` | `isHasModifyMaxHRM` | Modify the maximum heart rate value |  | – | – |
| `34F1 b19.4` | `F8 0x000010` | `isHasModifyLocalDial` | Modify local dial |  | – | – |
| `34F1 b19.5` | `F8 0x000020` | `isHasSleepSporadic` | Sporadic Sleep | Pro `isSupCywee` (uterkthis.java:2884); cũ `GoogleSportMapActivity.onCreate` (SleepDetailsActivity.java:120) | **✓** | – |
| `34F1 b19.6` | `F8 0x000040` | `isHasControlEmergencyPhone` | opening and closing the emergency telephone |  | – | – |
| `34F1 b19.7` | `F8 0x000080` | `isHasDeviceBluetoothReminder` | Device interface supports Bluetooth status reminder |  | – | – |
| `34F1 b18.0` | `F8 0x000100` | `isHasWeather24Hours` | Weather in the next 24 hours | Pro `setFutureWeathertoBle` (uterkfinal.java:264) | – | – |
| `34F1 b18.1` | `F8 0x000200` | `isHasHRM5mins` | Heart rate is one value in 5 minutes | Pro SDK (uterksuper.java:129); cũ `BluetoothLeService.dealwithElHRV` (BluetoothLeService.java:10468) | – | – |
| `34F1 b18.2` | `F8 0x000400` | `isHasContactDel` | Deleting all contacts |  | **✓** | ✓ |
| `34F1 b18.4` | `F8 0x001000` | `isChangsang_ECG` | Changsang ECG | Pro SDK (uterknew.java:30); cũ `EcgUtil.AnalysisBleEcgRealTimeData` (EcgUtil.java:445) | – | – |
| `34F1 b18.5` | `F8 0x002000` | `isHasClockType` | Clock Type | Pro `setDeviceAlarmClock` (uterkthis.java:3606) | – | – |
| `34F1 b18.6` | `F8 0x004000` | `isHasWeatherTypeMore` | more weather type |  | – | – |
| `34F1 b18.7` | `F8 0x008000` |  | Special Calories Calculation | Pro `calculateCalories` (uterkthis.java:57); cũ `PedometerUtils.calculateCalories` (PedometerUtils.java:97) | – | – |
| `34F1 b17.1` | `F8 0x020000` | `isHasBloodGlucose` | Blood Glucose | cũ `SyncParameterUtils.addBeginVersionCommandIndex` (SyncParameterUtils.java:465) | – | – |
| `34F1 b17.2` | `F8 0x040000` | `isHasHRVTest` | HRV Test |  | – | – |
| `34F1 b17.6` | `F8 0x400000` | `isHasLocalMP` | Local MPF | cũ `SyncParameterUtils.addBeginVersionCommandIndex` (SyncParameterUtils.java:461) | – | – |
| `34F1 b17.7` | `F8 0x800000` |  | sending userid QRCode | Pro SDK (UteBleConnectionRkImpl.java:545) | – | – |
| `34F1 b16.0` | `F9 0x000001` | `isHasModifyQRCode` | modify QRCode content |  | – | – |
| `34F1 b16.2` | `F9 0x000004` | `isHasWeightDecimals` | decimals of body weight | Pro SDK (uterkthis.java:3759) | – | – |
| `34F1 b16.3` | `F9 0x000008` | `isHasAliPay` | ali pay | cũ `SyncParameterUtils.addBeginVersionCommandIndex` (SyncParameterUtils.java:487) | – | – |
| `34F1 b16.4` | `F9 0x000010` | `isHas24HourHRMCtl` | device hrm control interval time |  | – | – |
| `34F1 b16.5` | `F9 0x000020` | `isHasHandLightCtl` | Bright screen duration control |  | – | – |
| `34F1 b16.7` | `F9 0x000080` | `isHasSOSCtl` | App control sos |  | – | – |
| `34F1 b15.0` | `F9 0x000100` | `isHasMenstruationCtr` | female physiological to show or hide |  | – | – |
| `34F1 b15.1` | `F9 0x000200` | `isHasSwimCategory` | swim category | Pro SDK (uterkthis.java:2789); cũ `SyncParameterUtils.addBeginVersionCommandIndex` (SyncParameterUtils.java:367) | **✓** | – |
| `34F1 b15.2` | `F9 0x000400` | `isHasBloodTestMorningRemind` | Reminder for automatic morning blood pressure testing | cũ `BpSettingActivity.onCreate` (BpSettingActivity.java:69) | – | – |
| `34F1 b15.3` | `F9 0x000800` | `isHasOffScreenDisplay` | Off Screen Display Time |  | – | – |
| `34F1 b15.4` | `F9 0x001000` | `isHasCustomTimeSaveData` | Customize time to save data | Pro `isSupOxygenInterval` (uterkthis.java:2875) | – | – |
| `34F1 b15.5` | `F9 0x002000` | `isHasBloodTestRangeTime` | automatic blood pressure testing within a time range |  | – | – |
| `34F1 b15.6` | `F9 0x004000` | `isHasPray` | function Pray |  | – | – |
| `34F1 b15.7` | `F9 0x008000` | `isHasBloodGlucoseAlgorithm1` | Blood Glucose Algorithm 1 |  | – | – |
| `34F1 b14.0` | `F9 0x010000` | `isSportExtendedUpload` | Sport Extended Upload | cũ `BluetoothLeService.dealWithSportMode` (BluetoothLeService.java:7364) | – | – |
| `34F1 b14.1` | `F9 0x020000` | `isHas4G` | 4G |  | – | – |
| `34F1 b14.2` | `F9 0x040000` | `isHasPressure5mins` | MPF is one value in 5 minutes | Pro SDK (uterkfloat.java:910) | – | – |
| `34F1 b14.3` | `F9 0x080000` |  | ble 4.0 upload data |  | – | – |
| `34F1 b14.5` | `F9 0x200000` | `isHasRYChatGPT` | RY platform ChatGPT | Pro `isSupChatGpt` (RkSupportUtils.java:374); cũ `RkSupportUtils.isSupChatGpt` (RkSupportUtils.java:53) | – | – |
| `34F1 b14.6` | `F9 0x400000` | `isHasRYAGPS` | RY platform AGPS | Pro `isSupEphemerisService` (RkSupportUtils.java:294); cũ `SyncParameterUtils.addBeginVersionCommandIndex` (SyncParameterUtils.java:490) | **✓** | ✓ |
| `34F1 b14.7` | `F9 0x800000` |  | sport data ble 4.0 |  | – | – |
| `34F1 b13.0` | `F10 0x000001` | `IsHasLMCalories` | sport LM calories calculation strategies | cũ `GoogleSportMapActivity.countCalories` (GoogleSportMapActivity.java:1555) | – | – |
| `34F1 b13.1` | `F10 0x000002` | `isHasWechatPay` | sport Wechat pay | cũ `SyncParameterUtils.addBeginVersionCommandIndex` (SyncParameterUtils.java:494) | – | – |
| `34F1 b13.2` | `F10 0x000004` | `isHasAiWatch` | sport Ai Watch | Pro `isSupJxAIWatch` (RkSupportUtils.java:313); cũ `RkSupportUtils.isSupJxAIWatch` (RkSupportUtils.java:32) | – | – |
| `34F1 b13.3` | `F10 0x000008` | `isHasOfflineVoice` | offline Voice | cũ `SyncParameterUtils.addBeginVersionCommandIndex` (SyncParameterUtils.java:343) | – | – |
| `34F1 b13.4` | `F10 0x000010` | `isHasAiIntelligentAgent` | Ai Intelligent Agent | cũ `RkSupportUtils.isSupJxAIAgent` (RkSupportUtils.java:44) | – | – |
| `34F1 b13.5` | `F10 0x000020` | `isHasAiTranslate` | Ai Translate | Pro `isSupTranslate` (RkSupportUtils.java:400); cũ `RkSupportUtils.isSupTranslate` (RkSupportUtils.java:65) | – | – |
| `34F1 b13.6` | `F10 0x000040` | `isHasAiModelSwitch` | Ai Model Switch | cũ `RkSupportUtils.isSupLargeMode` (RkSupportUtils.java:74) | – | – |
| `34F1 b13.7` | `F10 0x000080` | `isHasHealthReport` | health report | cũ `FragmentMine.updateSupportFunction` (FragmentMine.java:333) | – | – |
| `34F1 b12.0` | `F10 0x000100` | `isHasReadParam` | read param |  | – | – |
| `34F1 b12.1` | `F10 0x000200` | `isHasNotifyDial` | notify dial(index) change |  | – | – |
| `34F1 b12.2` | `F10 0x000400` | `isHasChargerStatus` | read charger status | Pro SDK (uterkbyte.java:40) | – | – |
| `34F1 b12.3` | `F10 0x000800` | `isHasReadTarget` | read device target |  | – | – |
| `34F1 b12.5` | `F10 0x002000` | `isHasReadMenstrul` | read device Menstrul param |  | – | – |
| `34F1 b12.6` | `F10 0x004000` | `isHasSportAltitude` | Altitude during exercise |  | – | – |
| `34F1 b12.7` | `F10 0x008000` | `isHasRefinableParam` | refinable param |  | – | – |
| `34F1 b11.0` | `F10 0x010000` | `isHasALLCalories` | The calories of device are included in all sports and activities | cũ `FragmentHomePage.onReceive` (FragmentHomePage.java:795) | **✓** | ✓ |
| `34F1 b11.2` | `F10 0x040000` |  |  | cũ `WriteCommandToBLE.sendTextSectionKey` (WriteCommandToBLE.java:1208) | **✓** | ✓ |
| `34F1 b11.3` | `F10 0x080000` | `isHasUserID` | connect require a userid | cũ `BluetoothLeService.mSyncTimeRunnable` (BluetoothLeService.java:5226) | – | – |
| `34F1 b11.4` | `F10 0x100000` | `isHasAITextMax1000` | The maximum word count for AI Q&A replies on devices is 1000 | Pro SDK (uterkif.java:505); cũ `ChatGPTProcessing.getContentData` (ChatGPTProcessing.java:440) | – | – |
| `34F1 b11.5` | `F10 0x200000` | `isHasSleepGoal` | This device supports reading and setting sleep targets |  | – | – |
| `34F1 b11.6` | `F10 0x400000` | `isHasSleepGoal` | The time zone for synchronizing time on this device supports decimals |  | – | – |
| `34F1 b11.7` | `F10 0x800000` | `isHasMenstrualSwitch` | This device supports setseparate reminder switch for female menstrual cycle stat |  | – | – |
| `34F1 b10.0` | `F11 0x000001` | `isHasHRMAndBloodOxygenAuto` | This device support automatic heart rate and blood oxygen measurement informatio |  | – | – |
| `34F1 b10.1` | `F11 0x000002` | `isHasFoodPlan` | This device support  dietary planning function | cũ `FragmentMine.updateSupportFunction` (FragmentMine.java:338) | – | – |
| `34F1 b10.2` | `F11 0x000004` | `isHasSyncRecordingFile` | This device support  synchronous recording file function |  | – | – |
| `34F1 b10.4` | `F11 0x000010` | `isHasSupportDistance` | This device supports distance for riding and rowing machines | Pro SDK (uterkthis.java:3683) | – | – |
| `34F1 b10.5` | `F11 0x000020` | `isHasLocalHRV` | This device supports local HRV | cũ `SyncParameterUtils.addBeginVersionCommandIndex` (SyncParameterUtils.java:468) | – | – |
| `34F1 b10.6` | `F11 0x000040` | `isHasNewScheduleReminder` | This device supports new schedule reminders |  | – | – |
| `34F1 b10.7` | `F11 0x000080` | `isHasSleepSensationAndAlarm` | This device supports sleep wake up sensation and sleep alarm clock | Pro SDK (uterknative.java:43) | – | – |
| `34F1 b9.0` | `F11 0x000100` | `isHasBloodOxygenAlarm` | The device supports blood oxygen warning |  | – | – |
| `34F1 b9.1` | `F11 0x000200` | `isHasPressureAlarm` | The device supports pressure warning |  | – | – |
| `34F1 b9.2` | `F11 0x000400` | `isHasCycleRemind` | The device supports the cycle setting of sedentary reminder, drinking water remi | Pro SDK (uterkthis.java:4430) | – | – |
| `34F1 b9.3` | `F11 0x000800` | `isHasAccountID` | The device supports sending account IDs | Pro SDK (uterkif.java:74) | – | – |
| `34F1 b9.4` | `F11 0x001000` | `isHasRYNotification` | The device supports separate control of the current App information push functio |  | – | – |
| `34F1 b9.5` | `F11 0x002000` | `isHasBodyMind` | The device support physical and mental homeostasis |  | – | – |
| `34F1 b9.6` | `F11 0x004000` | `isHasLocalMusicGroup` | The device support local music playlist list categorization |  | – | – |
| `34F1 b9.7` | `F11 0x008000` | `isHasLocalMusicTransfer` | The device support music transfer function from APP to BLE |  | – | – |
| `34F1 b8.0` | `F11 0x010000` | `isHasReadAIMaxLimitInfo` | The device support read AI limit info |  | – | – |
| `34F1 b8.1` | `F11 0x020000` | `isHasAIRecordRealTime` | The device support AI record real time |  | – | – |
| `34F1 b8.2` | `F11 0x040000` | `isHasHealthLab` | The device support health lab |  | – | – |
| `34F1 b8.3` | `F11 0x080000` | `isHasNoScreenFunction` | The device support no screen function | Pro `isSupNoScreen` (RkSupportUtils.java:462); cũ `Physiological.init` (Physiological.java:142) | – | – |
| `34F1 b8.4` | `F11 0x100000` | `isHasNoScreenTakePhotos` | The device support no screen take photos | Pro `isSupNoScreenTakePhoto` (RkSupportUtils.java:469); cũ `GeneralSettingActivity.isSupportFunction` (GeneralSettingActivity.java:199) | – | – |
| `34F1 b8.5` | `F11 0x200000` | `isHasMergeSleepSporadic` | The device support merge sleep sporadic | cũ `FragmentSleepDetailsDay.doSwAlgSleep` (FragmentSleepDetailsDay.java:378) | – | – |
| `34F1 b8.6` | `F11 0x400000` | `isHasMultipleQRCodes` | The device support multiple QR codes |  | – | – |
| `34F1 b8.7` | `F11 0x800000` | `isHasHRMTimedMeasurement` | The device support HRM timed measurement | cũ `Rate24HourSetting.isSupportHrScheduledTest` (Rate24HourSetting.java:309) | – | – |
| `34F1 b7.0` | `F12 0x000001` | `isHasBloodGlucoseTimedMeasurement` | The device support blood glucose timed measurement |  | – | – |
| `34F1 b7.1` | `F12 0x000002` | `isHasBloodTimedMeasurement` | The device support blood timed measurement | cũ `SyncParameterUtils.addBeginVersionCommandIndex` (SyncParameterUtils.java:497) | – | – |
| `34F1 b6.5` | `F12 0x002000` |  |  | Pro `isSupHideTakePhoto` (RkSupportUtils.java:477) | – | – |
| `34F1 b2.0` | `F13 0x010000` |  | ATS3085s | Pro `isJXPlatformATS3085S` (DevicePlatform.java:32); cũ `DevicePlatform.isJXPlatformATS3085S` (DevicePlatform.java:45) | – | – |
| `34F1 b2.1` | `F13 0x020000` | `Is8773` | RTL8773ewe | Pro `isRKPlatform8773` (DevicePlatform.java:36); cũ `DevicePlatform.isRKPlatform8773` (DevicePlatform.java:29) | – | – |
| `34F1 b2.2` | `F13 0x040000` |  | AC707 | Pro `isJLPlatformAC707` (DevicePlatform.java:20); cũ `DevicePlatform.isJLPlatformAC707` (DevicePlatform.java:53) | – | – |
| `34F1 b2.3` | `F13 0x080000` |  | d20000 / DeivceType AB569X | Pro `isZKPlatform` (DevicePlatform.java:40); cũ `DevicePlatform.isZKPlatform` (DevicePlatform.java:37) | – | – |
| `34F1 b2.4` | `F13 0x100000` |  | RingFR | Pro SDK (uterkthis.java:3121); cũ `DevicePlatform.isFRKPlatformRing` (DevicePlatform.java:49) | – | – |
| `34F1 b2.5` | `F13 0x200000` |  | Ring | Pro SDK (uterkthis.java:3121) | – | – |

---

## 2. Từng tính năng: lệnh, app GloryFit làm gì, SDK của mình

Ký hiệu trạng thái: ✅ đã làm (ghi `file:hàm`), 🟡 một phần, ❌ chưa có, n/a = Y25 không hỗ trợ (bit = 0) hoặc nền tảng không cho.
"A/i" = Android/iOS. "UI" = có màn trong app lab.

### 2.1 Kết nối, hệ thống

| Tính năng | Y25 | Lệnh | GloryFit làm gì | SDK của mình | TT |
|---|---|---|---|---|---|
| Kết nối, đọc bảng bit, MTU | luôn có | 55FF/56FF, đọc 33F1 + 34F1, MTU 247 | `B:3374-3440`, `B:608-700` | A `AD:openLink`; i `ID:connect` | ✅ |
| Bind mã 4 số / account ID | không cần (`b19.0`=0, `34F1 b11.3`=0) | `D5 01/02`, `33 02` | `B:5221-5252` | A `AD:bindWithCode`, `bindWithAccountId` + `PairingDialog.kt`; i có SDK, chưa UI (`ID:61`) | ✅ (A) / 🟡 (i, không ảnh hưởng Y25) |
| Đặt giờ | luôn có | `A3 YYYY MM DD hh mm ss` [33]; SDK iOS gốc thêm byte múi giờ | Cả hai app Android gửi 8 byte (`W:467-478`, `T:259-265`) | `AU:setTime`, `IU:setTime`; byte múi giờ sau cờ `GloryFitDebug.timeZoneByte` | ✅ (8 byte); 🟡 múi giờ chưa kiểm |
| Firmware / DSP | `A1`; DSP `A1 01` cần F7 `0x2000` (= 0) | `A1` | `B:3561-3567` | A/i đọc lúc kết nối | ✅ |
| Pin | luôn có | `A2` → `A2 pp` | | `AD:refreshBattery`, `ID:refreshBattery` | ✅ |
| Trạng thái sạc | `isHasChargerStatus` `34F1 b12.2` = 0 | – | | – | n/a |
| Trạng thái dữ liệu chưa đồng bộ | `isHasDataStatus` `b9.5` ✓ | **GATT read `33F3`** (chỉ SDK iOS). Byte cuối: bit0 GPS, 1 bước, 2 ngủ, 3 bơi, 4 nhảy dây, 5 HA, 6 HR, 7 xe đạp. Byte áp chót: bit0 bóng, 1 HR thể thao, 2 HR 24h, 3 body fat **(suy luận: bit = có dữ liệu chưa đồng bộ)** | iOS `-[UTESmartBandClient readDeviceDataStatus:]` `0x242808`, `receiveDeviceDataStatus:` `0x1e731c`. Android không đọc | – | ❌ |
| Đồng bộ theo mốc thời gian | `b9.5` (Android gọi là F4 `0x2000` "sync timestamp") | `[op] FA YYYY MM DD HH mm` | `O/utils/SyncDateUtils.java:123-170` | Luôn lấy toàn bộ (`xx FA`) | ❌ |
| Xoá dữ liệu / khôi phục gốc | luôn có | `AD` [33] | Pro `MainDeviceModelImpl.java:96-97`; `T:1286` | – | ❌ |
| Tắt máy / khởi động lại | `isHasShutdown` `b13.3` = 0, `isHasReboot` `b3.4` = 0 | `E8 11/12` | Pro không gọi cho RK | – | n/a |
| Đổi tên Bluetooth | `isHasModifyBluetoothName` `b9.6` ✓ | **Không thấy lệnh** trong cả hai app Android. Có thể chỉ có trong SDK iOS | – | – | ❌ (cần tìm lệnh) |
| OTA firmware | `b0.3` (Realtek) | Realtek GATT DFU, service `d0ff…`, image ký ECDSA (07-ota) | `RkOtaUtil` (silent mode, pin ≥ 30 %) | A `AO:parse/signatureOk` (chỉ đọc + kiểm chữ ký); i – | 🟡 |
| OTA UI | `isHasFirmwareUI` `b5.6` = 0 | `CD 01` | | – | n/a |
| Chế độ nhà máy | `b11.4` ✓ | (không làm) | | – | không nên làm |

### 2.2 Đo sức khoẻ tức thời và tự động

| Tính năng | Y25 | Lệnh | GloryFit làm gì | SDK của mình | TT |
|---|---|---|---|---|---|
| HR đo tay | `b17.3` ✓, nhưng `b15.6` HR 24h ✓ và `34F1 b8.7` = 0 ⇒ SDK iOS gốc **chặn** `E5 11` | Y25 (kiểm 16/10): `F7 02`, `D6 01`, `E5 11`, chờ ~25 s, `E5 00` → `E5 00 00 rr`, rồi `F7 01` + `F7 09` | App iOS không đo tay; Pro đổi `D6` rồi `E5 11` (`DetailsRateModelImpl.java:62-80`) | `AD:heartRateByPush`, `ID:heartRateByPush` | ✅ (đã kiểm trên Y25) |
| HR đẩy từ đồng hồ | ✓ | `F7 03` (định kỳ), `F7 0B` (đo trên đồng hồ), `F7 04` (max/min/avg) | | `AU:parsePushedHeartRate`, `IU` tương ứng | ✅ |
| HR 24h bật/tắt + chu kỳ | `b15.6` ✓ | `F7 01` / `F7 02`; `F7 09 en mmH mmL`; khung giờ `F7 0F` | `Rate24HourSetting` | `AD:configureHeartRate24h` + UI 5–60 phút; iOS giống | ✅ |
| Ô HR 5 phút / mỗi phút | `isHasHRM5mins` `34F1 b18.1` = 0; `F9 0x1000` = 0 | `F7 FA` ô 5 phút; `F7 EA` 1440 ô | `P/uterkfor/uterkbreak.java:48-64, 366-442` | – | n/a |
| HR nghỉ | `isHasRHRM` `34F1 b19.1` = 0 | `F7 05`, `F7 07`, `F7 08` | `MainHomeModelRkImpl.java:790` | – | n/a (thử `F7 05` để chắc) |
| Cảnh báo HR cao/thấp | `b19.7` ✓, `b9.3` ✓ | `A9` byte 11 (cao, `FF` tắt) / byte 18 (thấp, `00` tắt); đọc lại `69 AA 07` (SDK only) | `HeartRateSettingModelImpl` → `A9` | `AS:userInfo` + UI | ✅ |
| HR tối đa, cảnh báo HR khi tập | `34F1 b19.2` = 0; `MULTIPLE_SPORTS_MODES_HEART_RATE` chưa rõ nhóm | `50 05 hr`, `50 01 …` [34] | SDK only | – | n/a |
| Vùng nhịp tim | – | Vùng tính trong app: max = 220 − tuổi, ngưỡng 50/60/70/80/90 % (`P/com/yc/gloryfitpro/utils/heartrate/RateRangeUtil.java:18-42`); thời gian mỗi vùng có trong gói bài tập số 2 | | Gói ≥ 2 "chưa dùng" (`AU:188`, `IW:22`) | 🟡 |
| HR tĩnh/động | `b14.3` = 0 | `D6 01/02`, `D6 10 v` | | `D6 01` gửi trong đo tay | – |
| SpO2 đo tay | `b7.6` ✓ | `34 11` / `34 00` → `34 00 st v` | | `AD:measureImpl`, `ID:measure` + ô đo | ✅ (chưa ghi nhận kiểm trên Y25) |
| SpO2 tự động | `b7.6` ✓; app SDK còn gắn `F9 0x1000` (= 0) | `34 03 en ivH ivL`; khung giờ `34 04 en sH sM eH eM` | Pro gửi lại lúc kết nối (`MainHomeModelRkImpl.java:322`), `OxygenTimePeriodActivity` | `AS:commands` có `34 03`, nhưng **ẩn** theo F9 `0x1000` ⇒ Y25 không hiện | 🟡 (bỏ điều kiện F9, thêm `34 04`; kiểm trên Y25) |
| Cảnh báo SpO2 thấp | `34F1 b9.0` = 0 | `34 06` | | – | n/a |
| Huyết áp đo tay | `b17.4` ✓ | `C7 11` / `C7 00` → `C7 fin st sys dia` | | `AD:measureImpl`, `ID:measure` | ✅ |
| HA tự động / khung giờ | `b9.4` `isHasBloodAutoTest` = 0 | `CE 03`, `CE 04` | | – | n/a |
| HA hiệu chỉnh | `b5.4` = 0 | `3E …` | | – | n/a |
| Nhiệt độ, stress, HRV, ECG, đường huyết, nhịp thở | bit = 0 (§0.1) | `24`, `44`, `5C`, `28`, `5B`, `3B` | | `24 01` có trong SDK (không dùng với Y25) | n/a |
| Bài tập thở (breathing exercise) | Không có bit hay lệnh nào cho bài tập thở. `BreatheInfo` = **nhịp thở** (`3B`), Y25 tắt | – | – | – | n/a (nếu có thì chỉ chạy trên đồng hồ) |

### 2.3 Lịch sử / đồng bộ

| Loại dữ liệu | Y25 | Lệnh đúng cho Y25 | GloryFit làm gì | SDK của mình | TT |
|---|---|---|---|---|---|
| Bước / kcal / quãng đường theo giờ | CyWee `34F1 b19.5` ✓ | **`EB 02 FA`** [34] → `EB 02 YYYY MM DD HH steps(2) dist_m(2) kcal×1000(3)`, kết thúc `EB 02 FD`; đẩy realtime `EB 01` cùng định dạng. Calo do đồng hồ tính; app chỉ lấy round1(raw/1000) kcal mỗi giờ, không tính lại theo bước/hồ sơ (`SWAlgorithmUtil.java:47-49`) | `W:587-591`; `B:9856-9886`; Pro `P/uterkint/uterkgoto.java:9-37` | i: `IH:SyncCommand.stepsCywee` + `parseCyweeSteps`, fallback `B2 FA` (**chưa kiểm**, `IH:81`). A: chỉ `B2 FA` (`AD:syncHistoryImpl`) – Y25 không trả lời `B2 FA` (01 §10) | 🟡 |
| Tổng hôm nay | `b8.6` ✓ (`isSupStepCount`), `34F1 b11.0` ✓ (calo gồm cả bài tập) | Tổng từ `EB 02`/`EB 01` + bài tập | Pro cộng bước/kcal/km bài tập vào tổng ngày (`MainHomePresenter.java:59-80`) | `DeviceHistory.today` để null (GloryFit) | ❌ |
| Mục tiêu (đọc/ghi) | `b5.5` ✓; đọc `34F1 b12.3` = 0 | `3F 04 01 u32` bước, `3F 03 01 u16` kcal, `3F 05 01 u32` mét; các loại 1 đứng, 2 phút tập, 6 hoạt động | Pro gửi 4, 3, 5 lúc kết nối (`MainHomeModelRkImpl.java:473-499`) | `AS:target` + UI | ✅ |
| Ngủ | `b8.2` ✓ (thuật toán trên đồng hồ), CyWee ✓, REM `b1.3` ✓ | Pro: CyWee ⇒ **`EC 01`** → `EC 01 YYYY MM DD cnt` + `EC 02 <đoạn 6 byte [sH sM state ?? durH durL]>` + `EC 03`; state 1 sâu, 2 nông, 3 thức, 4 REM, `FF` = ngăn cách giấc chính / ngủ trưa. Không CyWee ⇒ `31 01`/`32`/`31 02` (cùng định dạng đoạn) | `B:9888-9915`, `B:7640-7681`; Pro `P/uterkfor/uterknative.java:18-464`. Pro **không có parser `B3`** cho RK | i: `IH:.sleepCywee`, `.sleepResolve`, `parseSleepDays` (chưa kiểm). A: chỉ `B3 FA` (sai đường cho Y25) | 🟡 (i) / ❌ (A) |
| Cảm nhận giấc ngủ, báo thức thông minh | `34F1 b10.7` = 0 | `31 AB …` | | – | n/a |
| HR lịch sử | `b15.6` ✓ | `F7 FA` (ô 10 phút) | | `AU:parseHeartRate24h`, `IH` | ✅ (đã kiểm gói thật Y25) |
| SpO2 lịch sử | ✓ | `34 FA` | | `AU:parseSpo2`, `IH:parseSpo2` | ✅ |
| HA lịch sử | `b17.4` ✓ | `C8 FA` → `C8 YYYY MM DD hh mm sys dia` | `W:770-788` | i `IGH` + `IH:parseBloodPressure`; A không đồng bộ | 🟡 |
| Bài tập (đa môn) | `F3 0x1` (`isHasSportHRM` `b13.0`) ✓ | `FD FA [mốc]` → bản ghi `FD 00 00…` (gói 0: môn, thời gian), gói 1 (bước, kcal, km, HR, pace), gói 2 (vùng HR, sải chân; cần F7 `0x80` = 0), gói ≥ 4 chuỗi điểm (HR/pace/lat/lon theo `dataFormatType`), kết thúc `FD FD` | `B:7024-7557`; `O/utils/MultipleSportsModesUtils.java` | `AD:streamWorkouts`, `AU:parseWorkouts`; `ID:workoutStream`, `IW:parseWorkouts`; thẻ bài tập trong `HistorySection` | ✅ (gói ≥ 2 chưa dùng; chưa ghi nhận kiểm trên Y25) |
| Bơi chi tiết CyWee | `34F1 b15.1` ✓ | `4A FA YYYY MM DD HH mm 00` [34] rồi `FD FA`: sải, tần số, SWOLF, số vòng, kiểu bơi | `W:5302-5313`; `B:10274`; `T:2788-2796` | – | ❌ |
| Bơi/nhảy dây/xe đạp kiểu cũ | chỉ khi **không** có F3 `0x1` | `B7/B9/F3/F4 FA` | | – | n/a |
| PAI, thời gian hoạt động, thời gian đứng | nhóm chưa rõ (F12/F13 = 0) | `6E FA`, `58 FA`, `3F 01 02` | SDK only | – | n/a (thử nếu muốn) |

### 2.4 Thể thao, điều khiển bài tập, GPS

| Tính năng | Y25 | Lệnh | GloryFit làm gì | SDK của mình | TT |
|---|---|---|---|---|---|
| Danh sách môn trên đồng hồ | ~25 môn (`b19.4`, `b15.0-3`, `b11.1-7`, `b10.0-7`, `b9.1-2`, `b8.5` môn tự do…) | – | `O/utils/SportModeSupList.java:42-105` | `AU:sportName` (tên môn) | ✅ (chỉ tên) |
| Chọn/sắp xếp môn hiện trên đồng hồ | `isHasCustomSportIconList` `b3.5` ✓ (`isSupSportList`) | đọc `FD 48 AA`; ghi `FD 48 seq [type disp pos]…` → `FD 48 FD crc` | `W:4826-4945`; `T:935-1005`; màn quản lý môn (`UteBleConnectionRkImpl.java:1777-1790`) | – | ❌ |
| **Bắt đầu/dừng bài tập từ điện thoại** | `F5 0x2` ✓ | `FD 11 type intv` bắt đầu; `FD 00` dừng; `FD 22`/`FD 33` tạm dừng/tiếp; `FD 44 type intv h m s kcal(2) km pace…` app đẩy số liệu; `FD AA` hỏi. Đồng hồ: `FD 04 type st` (đồng hồ tự bắt đầu/dừng), realtime 14 byte `FD type HR kcal pace steps count km` | `W:3484-3576`; `B:7027-7189`; Pro `UteBleConnectionRkImpl.java:1982-1998`, `WorkoutRealTimeDataReport` (`:1733-1752`) | – | ❌ |
| **GPS từ điện thoại khi tập** | `isHasSportGPS` `b1.7` ✓ | Đồng hồ → `FD 01 AA type` (xin app bật định vị), `FD 01 55` (dừng). App → `FD 01 01/00` (trạng thái định vị), `FD 02 lat×1e6(4) lon×1e6(4) speed×100(2) pointDist(4) totalDist(4)` [34] | `B:7046-7056, 7215-7236`; `T:1467-1478, 4517-4528`. App lưu track trên điện thoại, vẽ bản đồ | – | ❌ |
| AGPS (ephemeris) | `isHasRYAGPS` `34F1 b14.6` ✓ | `01 E9 AB 02 0C ts lat lon` (vị trí điện thoại, mỗi lần kết nối), `01 E9 AA 01` (thông tin), server `getAgpsFile`, `01 E9 AB 03 01 03`, file `01 E9 AB 04 …`; đồng hồ `01 E9 AC 03 01 st` | 09 §4; `P/uterkif/uterkcase.java:361-367`; `MainHomeModelRkImpl.java:1017-1040` | – | ❌ |
| Mục tiêu bài tập, độ cao | `b3.7` = 0, `34F1 b12.6` = 0 | `50 02/03/04` | | – | n/a |
| GPS kiểu cũ | `b16.1` = 0 | `47 73`, `47 FA` | | – | n/a |

### 2.5 Thông báo và cuộc gọi

| Tính năng | Y25 | Lệnh | GloryFit làm gì | SDK của mình | TT |
|---|---|---|---|---|---|
| **Thông báo app (Android)** | `b16.6` ✓, `b12.3` ✓, `isHasIconANCS` `b6.3` ✓, UCS-2 `b19.2` ✓, 240 byte F6 `0x400000` ✓ | Nội dung `[type][len][text UCS-2BE]` chia `C5 seq <18 B>` … `C5 FD` [33]; đồng hồ `C5 seq` (gửi tiếp), `C5 FD tt` (xong), `C5 FF` (gửi lại). Loại: 0 gọi, 2 WeChat, 3 SMS, 4 khác, 5 Facebook, 7 WhatsApp, 9 Messenger, 11 Line, 13 Instagram, 24 Telegram, 27 Zalo, 19 Gmail, 69 TikTok … (đủ ở `P/com/yc/gloryfitpro/config/RemindType.java:47-226`) | `NotificationListenerService` (`P/com/yc/gloryfitpro/services/StatusbarMsgNotificationListener.java:150-298`) → `appRemind(type,text)`; `T:3509-3535`; `W:1136-1249` | A `AU…`: `UteNotify.payload/sections`, `AD:sendAppNotification/push/sendSections`; app `WatchNotificationListener` (bộ lọc Pro) → `PhoneBridge.onAppNotification` (nội dung theo `NotificationPresenter.sendMessage`, giải mã lại bằng `jadx --show-bad-code`) | 🟡 (A, 16/10: code + unit test, **chưa thử trên điện thoại/đồng hồ**) |
| Danh sách icon đồng hồ hiển thị được | `b6.3` ✓ | `DB AA` [33] lúc kết nối → 15 byte cuối = 5 mặt nạ 24 bit `IS_DISPLAY_*` | `T:899`; `P/uterkfor/uterkfinal.java:531-558` | A `UteNotify.parseDisplay`, `AD:openLink` (gửi khi F5 `0x800`) → `remindDisplay`; `PhoneLinkCard` lọc danh sách app như `appRemindDynamicDisplayEn` | 🟡 (A, 16/10: code + unit test, **chưa thử trên điện thoại/đồng hồ**) |
| Tên người gửi SMS | F7 `0x800` ✓ | Sau `C5 FD` loại 3: `C6 seq <tên ≤30 B>` … `C6 FD` | `W:1251-1344`; `T:4701-4729` | A `UteNotify.senderPayload`, `AD:sendSmsNotification` (khi F7 `0x800`/`0x2000`). Lưu ý: jadx của Pro (`uterkfinal.java:486-490`) ghi đè `uterkelse=4` bằng 1 nên có thể Pro không gửi `C6`; làm theo GloryFit cũ (`BluetoothLeService.java:3823`) | 🟡 (A, 16/10: code + unit test, **chưa thử trên điện thoại/đồng hồ**) |
| Bật/tắt từng app | – | Lọc trên điện thoại, không gửi gì | `AppRemindUtils.setAllAppRemindSwitch` | A `PhoneBridge.switches` + `PhoneLinkCard` (công tắc từng app, SMS; mặc định tắt như `SPDao`). Chưa có "app khác" do người dùng thêm | 🟡 (A, 16/10: code + unit test, **chưa thử trên điện thoại/đồng hồ**) |
| Thông báo iOS | ANCS (`isHasIconANCS`) | Đồng hồ đọc ANCS sau khi **ghép đôi hệ thống**; tuỳ chọn connect `RequiresANCS`; đồng hồ hiện icon theo bundle | GF iOS: `uteManagerANCSAuthorization:`, `checkSytemShareANCS:show:` (09 §6) | Ghép đôi BT Classic trong Cài đặt đã làm Siri/gọi chạy (feature-matrix §3.4); app chưa hướng dẫn và chưa kiểm thông báo | 🟡 |
| **Báo cuộc gọi đến (Android)** | ✓ | `C5` loại 0 (tên/số), rồi `45 FA len <số>` [34] (vì có SMS reply); khi nghe/cúp/nhỡ: `C1 04` [33] | `T:3456, 1241-1244`; `SearchDeviceModelImpl.java:127-179` | A `AD:incomingCall/callEnded`; `PhoneBridge.onPhoneState` (= `MainService.phonePushMessage`, không có báo trễ), quyền READ_PHONE_STATE + READ_CALL_LOG + READ_CONTACTS | 🟡 (A, 16/10: code + unit test, **chưa thử trên điện thoại/đồng hồ**) |
| **Từ chối cuộc gọi trên đồng hồ** | `isHasHangup` `b17.6` ✓ | Bật bằng `D7` flags bit 3 (endCall). Đồng hồ gửi `D1 02` ⇒ app `TelecomManager.endCall` | `P/com/yc/gloryfitpro/presenter/main/device/EndCallUtil.java:19-45`; `UteBleConnectionRkImpl.java:706-711` | A `AS:dnd` bit 3 = khoá `dnd.endCall` (test `UteSettingsTest`), `AD:rejectCallRequests`, `PhoneBridge.rejectCall` → `TelecomManager.endCall` (ANSWER_PHONE_CALLS, Android 9+) | 🟡 (A, 16/10: code + unit test, **chưa thử trên điện thoại/đồng hồ**) |
| Gọi điện trên đồng hồ (HFP) | `isHasBluetooth3` `b2.2` ✓ | Trạng thái `38 01 02 00 nonce(4)` → `38 01 name MAC en paired conn`; bật/tắt `38 02 01/00` [34]; ghép `createBond` | `MainHomeModelRkImpl.java:206-215` | `AD:callBluetoothState`, `pairCallBluetooth`; `ID:callBluetoothState` + `CallContactsCard` | ✅ (kiểm trên Y25) |
| Trợ lý giọng nói / Siri | qua HFP | Không có lệnh BLE; nút trên đồng hồ gọi Siri/Google qua HFP | | Chạy được sau khi ghép HFP (feature-matrix §3.4) | ✅ (qua hệ thống) |
| Tắt tiếng cuộc gọi | nhóm chưa rõ | `D1 12 01/02` | SDK only | – | ? (thử) |
| Danh bạ | `b6.5` ✓, tên 20 ký tự `b2.3` ✓, xoá hết `34F1 b18.2` ✓ | `37 FA n`, `37 FB k …`, `37 FC FD`; xoá hết `37 BA` [34] | `T:612-742, 3305-3315` | `AD:syncContacts`, `ID:syncContacts` + UI chọn | ✅ (thiếu `37 BA`) |
| SOS | `b1.1` = 0, `b14.7` = 0 | `37 AC…` | | – | n/a |
| **Trả lời SMS nhanh (Android)** | F6 `0x200` ✓ | Bật `52 01/00`; mẫu `46 FA total idx len <UTF-8 ≤90>` … `46 FD 00`; đồng hồ gửi `52 nLen <số> cLen <text>` ⇒ app gửi SMS, trả `52 FE` / `52 FF` | `W:4723-4797`; `T:1404-1420, 3216-3226`; `SmsReplyModelImpl.java:41-75` | A `UteSmsReply`, `AD:setSmsReply/syncSmsReply` (cũng gửi lại mỗi lần kết nối như `MainHomeModelRkImpl.syncSmsReply`), `smsReplyRequests`, `sendSmsReplyResult`; `PhoneBridge.sendReplySms` (SmsManager, SEND_SMS) | 🟡 (A, 16/10: code + unit test, **chưa thử trên điện thoại/đồng hồ**); iOS n/a |

### 2.6 Nhạc, máy ảnh, tìm thiết bị

| Tính năng | Y25 | Lệnh | GloryFit làm gì | SDK của mình | TT |
|---|---|---|---|---|---|
| **Đồng hồ điều khiển nhạc điện thoại** | F5 `0x1` ✓ | Đồng hồ: `D1 07` play/pause, `D1 08` bài sau, `D1 09` bài trước, `D1 0D`/`D1 0E` tăng/giảm âm lượng. App: `D1 0C 01/02` (đang phát/dừng), `D1 0D vv` (âm lượng %) [33] | `MusicControl.java:212-241` (`dispatchMediaKeyEvent`); Pro `MainService.java:409-416` | A `UteMusic.parseCommand/volume/playState`, `AD:musicCommands/setMusicVolume`; `PhoneBridge.onMusicCommand` (= `ServicePresenter.setResponseMusicControlRk`) | 🟡 (A, 16/10: code + unit test, **chưa thử trên điện thoại/đồng hồ**) |
| Tên bài / nghệ sĩ lên đồng hồ | F5 `0x1000` ✓ | `3A 01 st mode vol total(4) cur(4)`, `3A 06 len <title ≤52>`, `3A 04 00 len <artist ≤52>`, `3A FA` [34] → đồng hồ `3A FA xor` | `MusicControl.java:92-172`; `T:4589-4699` | A `UteMusic.songPackets/checksum`, `AD:setMusicState`; `PhoneBridge` (MediaSessionManager, gửi trạng thái + tên bài như Pro, bỏ trùng như handler message 3) | 🟡 (A, 16/10: code + unit test, **chưa thử trên điện thoại/đồng hồ**) |
| Nhạc lưu trên đồng hồ | `34F1 b9.6/b9.7` = 0 | `01 FD B1 …` | | – | n/a |
| **Chụp ảnh từ xa** | không cần bit (Y25 không bật "ẩn chụp ảnh" F12 `0x2000`) | App: `C4 01` mở / `C4 03` đóng [33]. Đồng hồ: `C4 02` hoặc `D1 03` = chụp; `D1 11` = đồng hồ mở màn chụp (app tự mở camera); `D1 0F` = đóng | `com/ute/camera/CameraActivity.java:819,931`; `T:1575-1591`; `CameraModelImpl.java:18-23` | A core `RemoteCameraDevice`; `AD:remoteCameraEvents` (khoá chụp 4 s như iOS/GloryFit cũ; Pro chỉ 2 s), `setRemoteCamera`; app `RemoteCameraActivity` (CameraX → MediaStore) mở từ nút hoặc khi `D1 11` | 🟡 (A, 16/10: code + unit test, **chưa thử trên điện thoại/đồng hồ**) |
| Tìm đồng hồ | luôn có | `AB 00 00 00 01 02 07 01`; dừng `AB 00 00 00 00 00 00 00` | | `AS:FIND_WATCH`, `IS:findWatch` + nút | ✅ |
| Đồng hồ tìm điện thoại | `b16.5` ✓ | Bật `D1 0A 01/00`; đồng hồ `D1 0A` = đổ chuông, `D1 0A 01 00` = dừng; app báo `D1 0A 01 01/00` | `MainService.java:394-406` | `AD:findPhoneRequests`, `setPhoneRinging`; iOS tương tự + `FindPhoneRinger` | ✅ (`setPhoneRinging` mới thêm, chưa test) |
| Nút trên đồng hồ | – | Đồng hồ gửi `D1 01` (đổi màn), `D1 04`/`D1 06` (giữ phím 2/3) | `P/uterkfor/uterkchar.java:145-169` | – | ❌ (tuỳ chọn) |
| Chống thất lạc / nhắc mất BT | `b16.2` = 0, `34F1 b19.7` = 0 | `5A 01/00` | | – | n/a |

### 2.7 Cài đặt, nhắc nhở

| Tính năng | Y25 | Lệnh | GloryFit làm gì | SDK của mình | TT |
|---|---|---|---|---|---|
| Hồ sơ (cao, nặng, tuổi, giới) | `b16.0` = 0 nhưng `A9` vẫn gửi | `A9` 19 byte (01 §5.2) | | `AS:userInfo` + UI | ✅ |
| Nâng tay sáng màn | `b19.6` ✓ | `A9` byte 10; lịch bật theo giờ `69 AB 01 05 sw fh fm th tm` (SDK only) | | `A9` + công tắc | ✅ (lịch theo giờ ❌, cần thử) |
| Thời gian sáng màn | `A9` byte 5; lệnh riêng `61 01` cần `34F1 b16.5` (= 0) | `A9` | | số giây 5–30 | ✅ |
| Độ sáng màn | Không có lệnh trong cả hai app | – | – | – | n/a (chỉ trên đồng hồ) |
| Ngôn ngữ | `b16.3`, `b12.6`, `b8.4`, `b6.0`, `b13.5` ✓ | Đặt `AF AB n` (1 TQ, 2 EN, 99 VI…); đọc danh sách + ngôn ngữ hiện tại `AF AA` → 5 mặt nạ 24 bit | `T:1745-1748`; `P/uterkfor/uterkclass.java:63-104` | `AS:LANGUAGES` + chọn (đặt); chưa đọc `AF AA` | 🟡 |
| 12/24h, đơn vị | ✓ | `A0 unit hr` | | `AS:units` + công tắc 12h (đơn vị cố định metric) | ✅ (chưa có imperial) |
| °C/°F | `b12.4` ✓ | `A9` byte 17 | | công tắc | ✅ |
| Không làm phiền | `b19.3` ✓ | `D7 flags fh fm th tm en`; flags: bit 3 từ chối cuộc gọi, bit 2 tin, bit 1 rung | `T:4029-4070` | `AS:dnd` + UI | ✅ (thiếu bit 3, xem 2.5) |
| Nhắc ngồi lâu | `b17.0` ✓, `b16.4` ✓ | `D3 en interval 02 03 01 00 fh fm th tm lunch` | | `AS:reminder` + UI | ✅ |
| Nhắc uống nước, rửa tay | `b5.3` = 0, `b4.2` = 0 | `D4`, `41` | | ẩn theo bit | n/a |
| Báo thức | `isHasLocalAlarmClock` `b4.0` ✓, `isHasClockTitle` `b2.1` = 0 ⇒ app **ẩn** báo thức | `AB cyc hh mm …` | Kiểm 15/10: `AB` được nhận nhưng không vào danh sách; `51` không phản hồi | – | n/a (chỉ đặt trên đồng hồ) |
| Lịch, cuộc họp, việc, cầu nguyện | `34F1 b10.6`, `b4.3`, `b17.2`, `34F1 b15.6` = 0 | `6C`, `F8`, `65` | | – | n/a |
| Đồng hồ thế giới / múi giờ | `isHasTimeZone` `b4.4` = 0, `34F1 b19.0` = 0 | `43 FA …` | Pro chỉ hiện cho JX | – | n/a |
| Bấm giờ / hẹn giờ | Không có lệnh | – | – | – | n/a (app trên đồng hồ) |
| Kinh nguyệt | `b12.7` ✓ | `29 en YYYY MM DD period cycle`; đọc `29 FA` / `29 AA` cần `34F1 b12.5` (= 0) | `MenstrualModelImpl.java:44-58` | `AS:period` + UI | ✅ |
| Thời tiết | `b18.5` ✓, `b3.3` ✓ | `CB 01/02/03` [34] (21 byte có độ ẩm/UV); tên thành phố: `C1 01` + 6 byte GB2312 trong `CB 01` | `T:4862-4873` | `AD:setWeather`, `AW:packets`, iOS giống + nút | ✅ (kiểm trên Y25; tên thành phố cần xem lại) |
| Phím tắt nhanh | `isHasShortcutButton` `b8.0` ✓ | Chỉ **đọc**: `BE 01` (danh sách hỗ trợ), `BE 02` (trạng thái). Bit: `0x2000` giờ, `0x4000` 24h, `0x10000` tìm, `0x20000` nâng tay, `0x40000` ngồi lâu, `0x80000` DND, `0x200000` SMS, `0x400000` HR 24h, `0x800000` sáng màn | `P/com/yc/gloryfitpro/utils/ShortcutUtils.java:8-62`. App **ẩn** cài đặt nào mà đồng hồ có phím tắt (`RkSU:226-266`) | – | ❌ |
| Sắp xếp menu / app | `b3.6` = 0, F2 `0x8000` = 0 | `F9 …` | | – | n/a |
| Cường độ rung | Không có lệnh (chỉ byte rung trong báo thức `51`) | – | – | – | n/a |
| Tiết kiệm pin | `b14.0` = 0 | `FA 01 …` | | – | n/a |
| Phát hiện đeo tay, hiệu chỉnh nâng tay | `b5.0` = 0, `b14.2` = 0 | `3D`, `FC` | | – | n/a |

### 2.8 Mặt đồng hồ

| Tính năng | Y25 | Lệnh | GloryFit làm gì | SDK của mình | TT |
|---|---|---|---|---|---|
| Đọc thông số | luôn có | `26 01` | | `AD:queryDialParams`, `ID:queryDialParams` | ✅ |
| Cài mặt `.bin` | `b12.0` ✓ | `26 02`, `27 seq …` [34], `26 03 xx` | 02-watchface §5 | `AD:installWatchFaceFile`, `ID:installWatchFaceFile`; thư viện 2 mặt có UI cả A/i | ✅ |
| Mặt tuỳ chỉnh từ ảnh (renderer) | ✓ | dựng `.bin` (02, 03) | `CustomWatchFaceActivity` | A `AR` + `WatchFaceEditor.kt`; i chưa có (`ID:555`) | ✅ (A) / ❌ (i) |
| Khe đã cài: xem, xoá | `b12.0` ✓ | `26 05 n` → danh sách id; xoá `26 08 n` | `T:2235, 3260` | – | ❌ |
| Kho mặt online UTE | ✓ | server + `26/27` | `research/watchstore` đã giải mã thử | – | ❌ |
| Mặt ảnh RK (`26 0A/0B`) | phụ thuộc byte 18 của `26 01` (Y25 = 0 **(suy luận từ 02 §2)**) | `26 0A`, `26 0B …` | `T:1290, 4926-4935` | – | n/a (kiểm byte 18) |
| Mặt AI | F10 `0x4` = 0 | `01 F0 …` | | – | n/a |
| Đổi giữa mặt cài sẵn / widget | `34F1 b19.4` = 0; widget chưa rõ nhóm | `59 FB idx`, `49 …` | | – | n/a |

### 2.9 Thanh toán, QR, NFC, AI, tệp

Tất cả **tắt** trên Y25. Liệt kê để khỏi tìm lại:

| Tính năng | Bit Y25 | Lệnh (nếu có) | Ghi chú |
|---|---|---|---|
| Mã QR / 收款码 nhiều mã | `34F1 b16.0` = 0, `b8.6` = 0 | `DC 52 …`, `DC 53 AB 01 …` | `P/uterkfor/uterkimport.java:118-376`. App Pro không gọi cho RK |
| Ali QR / Alipay / WeChat Pay | `b14.6` = 0, `34F1 b16.3` = 0, `b13.1` = 0 | service `57FF` (`35F1/35F2`), `3802/4A02` | Chỉ app cũ, cần locale zh_CN |
| NFC, iBeacon, thẻ điện tử | `b18.4` = 0; NFC không có bit RK | – | Firmware có khoá `systemparam/nfcSwitch` nhưng không có phần cứng (08 §1) |
| ChatGPT / AI watch / dịch AI | `34F1 b14.5`, `b13.2`, `b13.5` = 0 | `01 EF …`, `01 F0 …` | |
| Ghi âm, nhạc trên đồng hồ, sách điện tử, ảnh, trò chơi | = 0 hoặc chỉ có trên JX | `01 FD AA/B1 …` | Sách điện tử/ảnh/trò chơi: không có lệnh RK |
| 4G, Honor, health lab, kế hoạch ăn, báo cáo sức khoẻ | = 0 | `67`, `01 E7`, `01 A7`, `01 FC`, `01 F7` | |

---

## 3. Danh sách gap ưu tiên

Công sức: S ≤ 1 ngày, M 2–4 ngày, L ≥ 1 tuần (một người, một nền tảng; "A+i" = làm cả hai).
Thứ tự trong mỗi mức là thứ tự nên làm.

### P0: tính năng cốt lõi của một smartwatch, Y25 hỗ trợ, ta chưa có hoặc đang sai

| # | Việc | Nền tảng | Công | Cần kiểm trên Y25 |
|---|---|---|---|---|
| 1 | **Đồng bộ lịch sử đúng đường cho Y25 trên Android**: `EB 02 FA` (bước/kcal/km), `EC 01` (ngủ + ngủ trưa + REM), fallback `31 01`, `C8 FA` (HA). Port từ `IH`/`IGH` | A | M | Gửi `EB 02 FA` trên 34F1 và `EC 01` trên 33F1: có gói `EB 02 …`/`EC 02 …` không, kết thúc `EB 02 FD`/`EC 03`. Đối chiếu số bước/giấc ngủ với màn hình đồng hồ |
| 2 | **Kiểm đường lịch sử mới trên iOS** (đã code, chưa chạy trên đồng hồ) + tổng hôm nay (bước/kcal/km) cho `DeviceHistory.today` | i (+A) | S | Như #1, và `EB 01` realtime có tự đẩy không |
| 3 | **🟡 A đã code (16/10, chưa thử máy thật): Thông báo app trên Android**: NotificationListener, ánh xạ package → loại (`RemindType.java`), `DB AA` để biết icon, `C5` chia gói 20 byte, `C6` tên người gửi, bật/tắt từng app | A | M | Tin tiếng Việt có dấu (UCS-2), tin 240 byte, icon Zalo (loại 27)/Messenger/Telegram; gói > 20 byte có nhận không (F10 `0x40000`) |
| 4 | **🟡 A đã code (16/10, chưa thử máy thật): Cuộc gọi đến trên Android**: `C5` loại 0 + `45 FA` số, `C1 04` khi kết thúc; **từ chối trên đồng hồ**: bật bit 3 của `D7`, nghe `D1 02` → `TelecomManager.endCall` | A | S–M | `D1 02` có đến khi bấm từ chối không; khi đã ghép HFP thì đồng hồ có tự lo cuộc gọi qua HFP (không cần `C5`) không |
| 5 | **Thông báo + cuộc gọi trên iOS qua ANCS**: hướng dẫn ghép đôi trong Cài đặt, kiểm tra ANCS đã bật (`ancsAuthorized` / `didUpdateANCSAuthorizationForPeripheral`), tuỳ chọn `CBConnectPeripheralOptionRequiresANCS` | i | S | Sau khi ghép: tin nhắn, Zalo, cuộc gọi có hiện; từ chối cuộc gọi trên đồng hồ chạy qua ANCS |
| 6 | **🟡 A đã code (16/10, chưa thử máy thật): Điều khiển nhạc**: nghe `D1 07/08/09/0D/0E`, Android dùng `MediaSessionManager`/`dispatchMediaKeyEvent`; đẩy trạng thái `D1 0C`, âm lượng `D1 0D vv`, tên bài/nghệ sĩ `3A 01/06/04/FA` | A (i: chỉ AVRCP qua HFP/A2DP) | M | Đồng hồ có màn nhạc không; gửi `3A` thì tên bài có hiện; trên iOS khi đã ghép BT Classic thì nút nhạc có điều khiển iPhone qua AVRCP không (không cần app) |

### P1: Y25 hỗ trợ, tăng giá trị rõ

| # | Việc | Nền tảng | Công | Cần kiểm trên Y25 |
|---|---|---|---|---|
| 7 | **🟡 A đã code (16/10, chưa thử máy thật): Chụp ảnh từ xa**: `C4 01/03`, nghe `C4 02`/`D1 03` (chụp), `D1 11`/`D1 0F` (đồng hồ mở/đóng màn chụp); màn camera trong app (CameraX / AVFoundation) | A+i | M | Đồng hồ có mục "camera" không; `C4 01` có mở màn trên đồng hồ không |
| 8 | **Bài tập từ điện thoại + GPS điện thoại**: `FD 11/00/22/33` (bắt đầu/dừng/tạm dừng/tiếp), nghe realtime `FD type HR …` và `FD 04`; trả lời `FD 01 AA` bằng `FD 01 01` + `FD 02 lat lon speed dist` mỗi giây; lưu track, vẽ bản đồ; ghép track vào bản ghi `FD FA` | A+i | L | Môn ngoài trời trên đồng hồ có gửi `FD 01 AA type` không (⇒ đồng hồ cần GPS điện thoại); nếu đồng hồ có GNSS thật thì gói ≥ 4 của `FD FA` có lat/lon |
| 9 | **AGPS**: trả lời `01 E9 AC 03 01 st` (09 §4), gửi vị trí điện thoại `01 E9 AB 02` | A+i | M–L | Y25 có tự gửi `01 E9 AC 03 01 02` mỗi 60 s như HT43 không. Không có thì bỏ. Cần người dùng đồng ý trước khi gọi API `getAgpsFile` của UTE |
| 10 | **SpO2 tự động** cho Y25: bỏ điều kiện F9 `0x1000` trong `AS`/`IS`. Pro bật cài đặt này và gửi lại `34 03` lúc kết nối chỉ với `isSupOxygenSetting` = F5 `0x40` (`HealthMonitorSettingActivity.java:23`, `MainHomeModelRkImpl.java:322`); `isSupOxygenInterval` (F9) không được gọi. Thêm khung giờ `34 04` | A+i | S | `34 03 01 00 3C` có ack; sau 1 giờ `34 FA` có ô mới |
| 11 | **🟡 A đã code (16/10, chưa thử máy thật): Trả lời SMS nhanh**: `52 01`, mẫu `46 FA …`, nghe `52 …` → `SmsManager`, trả `52 FE/FF` | A | M | Đồng hồ hiện mẫu trả lời dưới tin SMS; cần quyền `SEND_SMS` |
| 12 | **Đọc phím tắt nhanh** `BE 01/02` để ẩn cài đặt trùng (như Pro) và đọc ngôn ngữ hiện tại `AF AA` | A+i | S | Gói trả về 20 byte, đối chiếu với các phím tắt trên đồng hồ |
| 13 | **Khe mặt đồng hồ**: xem `26 05`, xoá `26 08`; port renderer mặt tuỳ chỉnh sang iOS (CoreGraphics) | A+i / i | S / L | `26 05 00` trả danh sách id; xoá khe không phải mặt đang dùng |
| 14 | **Trạng thái dữ liệu `33F3`**: đọc trước khi đồng bộ để chỉ lấy loại có dữ liệu mới; thử đồng bộ theo mốc `[op] FA YYYY MM DD HH mm` | A+i | S | Đọc `33F3` trước và sau khi đi bộ vài phút, xem bit 1 (bước) thay đổi |

### P2: hoàn thiện, rủi ro hoặc ít dùng

| # | Việc | Nền tảng | Công | Cần kiểm trên Y25 |
|---|---|---|---|---|
| 15 | Chọn/sắp xếp môn hiển thị `FD 48` | A+i | M | `FD 48 AA` trả danh sách + min/max |
| 16 | Dùng gói bài tập ≥ 2 (vùng HR, chuỗi HR/pace) + vùng HR 220 − tuổi | A+i | M | Chuỗi điểm có trong bản ghi `FD` của Y25 không |
| 17 | Bơi chi tiết CyWee `4A FA` | A+i | S | Cần bơi thật |
| 18 | Xoá dữ liệu `AD` (mục kỹ thuật, có xác nhận); xoá hết danh bạ `37 BA` | A+i | S | Chạy cuối cùng, trên Y25 không còn dữ liệu cần giữ |
| 19 | OTA Realtek DFU (chỉ nạp lại image gốc đã ký, 07-ota) | A (rồi i) | L | Rủi ro brick thấp (silent/dual-bank) nhưng **cần người dùng đồng ý** |
| 20 | Byte múi giờ trong `A3` (giờ lệch, có dấu): kiểm rồi bật mặc định hoặc bỏ | A+i | S | Đặt giờ 9 byte, xem giờ trên đồng hồ khi điện thoại ở múi +7 |
| 21 | Đổi tên Bluetooth: tìm lệnh trong SDK iOS (`isHasModifyBluetoothName`) | – | S (nghiên cứu) | Sau khi có lệnh |
| 22 | Lịch nâng tay theo giờ `69 AB 01 05`, đọc lại `69 AA 07/08` | A+i | S | Có ack không (SDK only, Pro không gọi cho RK) |
| 23 | Tên thành phố thời tiết: kiểm `C1 01` + GB2312 có hiện đúng, nếu không thì gửi 0 | A+i | S | Nhìn màn thời tiết |
| 24 | Thử các lệnh SDK-only không có bit trên Y25: `F7 05` (HR nghỉ), `D1 12` (tắt tiếng), `6E FA` (PAI), `58 FA` | – | S | Chỉ ghi nhận có trả lời hay không |

Không làm: tắt máy/khởi động lại (bit tắt), chế độ nhà máy, báo thức từ app (Y25 không nhận), thanh toán/QR/NFC/AI/4G (bit tắt), trả lời SMS và điều khiển app nhạc khác trên iOS (nền tảng không cho).

---

## 4. Việc cần đọc / chụp trên đồng hồ thật

| # | Việc | Để làm gì |
|---|---|---|
| V1 | Log thô 20 byte đọc từ `34F1` của Y25 (driver đã đọc lúc kết nối, chỉ cần in ra) | Thay chuỗi `34F1` dựng lại ở §1.1 bằng giá trị thật |
| V2 | Đọc `33F3` (và xem `33F4` có notify không) | Ý nghĩa bit trạng thái dữ liệu (P1 #14) |
| V3 | GPS: bắt đầu "chạy ngoài trời" trên đồng hồ khi đang kết nối, ghi mọi gói `FD 01 …` và `01 E9 …`; xem đồng hồ có màn "đang tìm GPS" không | Chốt Y25 có GNSS thật hay cần GPS điện thoại (P1 #8, #9) |
| V4 | Phản hồi của `EB 02 FA`, `EC 01`, `31 01`, `C8 FA`, `FD FA` | P0 #1–2, bài tập |
| V5 | Chụp gói khi bấm nút nhạc, nút chụp ảnh, từ chối cuộc gọi trên đồng hồ (`D1 xx`, `C4 02`) | P0 #4, #6, P1 #7 |
| V6 | `BE 01`, `BE 02`, `AF AA`, `26 05 00`, `69 AA 07`, `69 AA 08` | P1 #12, #13, P2 #22 |
| V7 | Đọc byte 18 của `26 01` | Có mặt ảnh RK `26 0A/0B` hay không |
