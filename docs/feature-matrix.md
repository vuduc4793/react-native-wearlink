# Ma trận tính năng: Y25, HT43, R09, DS500 (Android và iOS)

> Ngày: 15/10/2026. Chỉ nghiên cứu và viết tài liệu. Không sửa code, không kết nối thiết bị, không ssh.
> Mục tiêu: liệt kê mọi tính năng mà phần cứng/firmware của 4 thiết bị hỗ trợ, so với những gì SDK + app
> Android và iOS đang có, rồi xếp backlog để iOS **bằng Android** trước, sau đó **vượt Android**.
>
> Nguồn:
> - Bảng tính năng GloryFit: giải mã **toàn bộ** `-[UTESmartBandClient checkBleFunction:]` (`0x26fda4`) và
>   `checkBleFunction34F1:` (`0x278e14`) trong `UTESmartBandApi` của app GloryFit iOS 1.6.28 (phụ lục B).
>   Đối chiếu với `DeviceMode`/`RkSupportUtils` (GloryFitPro 1.9.0.2, `research/xapk-pro/jadx-out`) và
>   `GetFunctionList` (GloryFit 4.0.12, `research/jadx-out`). Tài liệu: `sdks/gloryfit/docs/01-protocol.md` §5–6,
>   `08-hardware.md` §3, `09-ios-gloryfit-app.md` §2.1.
> - QRing: `sdks/qring/docs/devices.md`, `02-commands.md` §3–4, `03-history-sync.md`, `ios-qring-app.md`.
> - Code: `sdks/{core,gloryfit,qring}/{android,ios}`, `apps/android/.../ui/*.kt`, `apps/ios/SmartWearLab/*.swift`.
>
> Phần không đọc thẳng từ mã hay dữ liệu được ghi **(suy luận)**.

**Ký hiệu**

| Ký hiệu | Nghĩa |
|---|---|
| ✓ | Có trong SDK và có UI trong app lab |
| SDK | Có trong SDK, app chưa có UI (hoặc chỉ chạy ngầm với giá trị cố định) |
| ½ | Có một phần (ghi rõ ở cột ghi chú) |
| – | Chưa có |
| n/a | Thiết bị không hỗ trợ, hoặc nền tảng không cho làm |
| S / M / L | Công sức làm trên iOS: S ≤ 1 ngày, M 2–4 ngày, L ≥ 1 tuần (một người, ước lượng). Nếu Android đã có thì là công port; nếu chưa thì là công làm mới |

Ký hiệu bit: `33F1 b17.3` = byte 17 (đếm từ 0) bit 3 của 20 byte đọc từ characteristic `33F1`. Cột Android ghi
nhóm và mask theo `Ute.Features` (`F1 0x080000`). Bảng đầy đủ mọi bit đang bật ở phụ lục A.

---

## 0. Kết luận nhanh

1. **Ánh xạ `Features.capabilities()` giống hệt nhau trên Android và iOS.** HT43 hiện `HEART_RATE, SPO2, STEPS, SLEEP`
   trên **cả hai** nền tảng. Bốn giá trị này **đúng** với bảng bit. Ánh xạ chỉ bỏ sót một chỉ số sức khoẻ là
   **`MENSTRUATION`** (`33F1 b12.7`, F3 `0x008000`, bật trên cả Y25 và HT43). Khoảng 70 bit còn lại (HR 24h, cảnh báo
   nhịp tim, ngủ REM, GPS + AGPS, gọi điện, danh bạ, thông báo, thời tiết, báo thức, không làm phiền, nâng tay sáng
   màn, tìm điện thoại, ~20 môn thể thao…) không có giá trị nào trong enum `Capability`, nên không nền tảng nào hiện
   chúng. Chi tiết ở §1.
2. **Android "hiện nhiều hơn" vì có các mục không phụ thuộc capability.** Đó là `Lịch sử` (`supportsHistory = true`,
   đồng bộ 7 ngày), `Mặt đồng hồ` (trình chỉnh + thư viện, do `GloryFitDevice` cài `WatchFaceCustomizable`) và hộp
   thoại ghép nối. iOS **chưa có** lịch sử ở cả core lẫn driver. Mặt đồng hồ trên iOS chỉ tự cài ngầm Peacock 3D,
   không có UI. Vì vậy màn HT43 trên iOS chỉ còn 2 ô đo và 2 dòng "đồng bộ lịch sử · chưa có trong bản này".
3. **Đường đồng bộ lịch sử GloryFit trên Android có thể sai với cả hai đồng hồ** (chưa kiểm chứng, nhưng cần sửa
   trước khi port nguyên xi sang iOS):
   - Cả hai có `isHasResolveSleep` (`33F1 b8.2` = F4 `0x040000`): ngủ do thuật toán trên đồng hồ, lấy bằng
     `31 01` (01-protocol §5.3). SDK mới (`uterkif/uterkint.java:72`) **không** gửi `B3 FA` khi có bit này.
   - Y25 có CyWee (`34F1 b19.5` = F8 `0x000020`): bước qua kênh BLE5 `EB 02 FA`, ngủ `EC 01`
     (`uterkif/uterkthis.java:2884-2902`).
   - Driver Android hiện luôn gửi `B2 FA` và `B3 FA`. Khớp với ghi nhận "`B2 FA`, `B3 FA` không có gói nào" trên Y25
     (01-protocol §10).
4. **Thứ iOS cần để bằng Android** (§4.1):
   - core lịch sử + `syncHistory`;
   - parser lịch sử GloryFit và QRing;
   - màn Lịch sử;
   - thư viện mặt đồng hồ có UI;
   - trình chỉnh mặt đồng hồ + renderer;
   - UI ghép nối.
5. **Thứ cả hai nền tảng đều thiếu dù phần cứng có**: cài đặt người dùng/đơn vị/12-24h, cảnh báo nhịp tim, chu kỳ
   HR 24h, tìm thiết bị, thông báo (trên iOS là ANCS), thời tiết, AGPS cho HT43, lịch sử huyết áp, thể thao/GPS,
   cài đặt đo tự động và cử chỉ của QRing.

---

## 1. Vì sao HT43 chỉ có `HEART_RATE, SPO2, STEPS, SLEEP` trên iOS

`Ute.Features.capabilities()` (`sdks/gloryfit/ios/Sources/SmartWearGloryFit/Ute.swift:141`, bản Android
`Ute.kt:112`) chỉ ánh xạ các bit sang 12 giá trị `Capability`. Đối chiếu từng giá trị với bảng của HT43
(`33F1 = 08 88 6C 2A 01 24 39 43 75 6E DF FE D9 21 00 5D 78 4B A1 DC`,
`34F1 = 00 F4 00 00 00 00 00 00 00 00 00 05 00 00 40 00 00 00 04 00`):

| Capability | Điều kiện trong `capabilities()` | Bit tương ứng trong SDK iOS gốc | HT43 | Y25 | Nhận xét |
|---|---|---|---|---|---|
| `HEART_RATE` | F1 `0x080000` | `33F1 b17.3` `isHasHRM` | 1 | 1 | Đúng |
| `BLOOD_PRESSURE` | F1 `0x100000` ∨ F5 `0x100000` ∨ F7 `0x10` | `b17.4` `isHasBlood` ∨ `b5.4` `isHasBloodCalibrate` ∨ `b1.4` `isHasBloodHengAi` | 0 | 1 | Đúng: HT43 không có huyết áp (mã firmware `RH…`, chữ thứ 2 là `H`) |
| `SPO2` | F5 `0x40` | `b7.6` `isHasBloodOxygen` | 1 | 1 | Đúng |
| `TEMPERATURE` | F5 `0x08` | `b7.3` `isHasBodyTemperature` | 0 | 0 | Đúng |
| `STRESS` | F6 `0x20` | `b4.5` `isHasMPF` (mood/pressure/fatigue) | 0 | 0 | Đúng |
| `HRV` | F11 `0x20` | `34F1 b10.5` `isHasLocalHRV` (SDK iOS còn có `isHasHRVTest` = `34F1 b17.2`) | 0 | 0 | Đúng (cả hai bit đều 0) |
| `ECG` | F3 `0x2000` | `b12.5` `isHasECG` | 0 | 0 | Đúng |
| `BLOOD_SUGAR` | F8 `0x020000` | `34F1 b17.1` `isHasBloodGlucose` | 0 | 0 | Đúng |
| `STEPS` | luôn có | – | 1 | 1 | Đúng |
| `SLEEP` | khi **không** có F4 `0x8000` | `b9.7` `isHasHeadsetHRM` (tai nghe) | 0 ⇒ có ngủ | 0 ⇒ có ngủ | Đúng |
| **`MENSTRUATION`** | **không ánh xạ** | `b12.7` `isHasMenstruationReminder` = F3 `0x008000` (GloryFitPro `isSupPhysiologicalFun`) | **1** | **1** | **Bị bỏ sót.** Enum có sẵn (QRing đã dùng) |
| `GESTURE` | không ánh xạ | không có bit tương đương | – | – | Không áp dụng |

Như vậy ánh xạ không làm rơi chỉ số đo nào ngoài kinh nguyệt. Thứ "biến mất" là mọi tính năng **không phải phép đo**.
`Capability` chỉ mô tả chỉ số sức khoẻ, nên không có chỗ cho các bit sau (đều bật trên HT43):

| Nhóm | Bit đang bật trên HT43 (tên theo SDK iOS gốc) |
|---|---|
| Nhịp tim nâng cao | `isHas24HourHRM` b15.6, `isHasMaxHeartAlert` b19.7, `isHasMinHeartAlert` b9.3, `isHasSportHRM` b13.0 |
| Ngủ, bước | `isHasSleepREM` b1.3, `isHasResolveSleep` b8.2 (ngủ tính trên đồng hồ), `isHasWalkRun` b18.0 (bước tách chạy/đi, chỉ HT43), `isHasActivityGoal` b5.5, `isHasALLCalories` 34F1 b11.0, `isHasNewCalculate` b15.4 |
| GPS | `isHasSportGPS` b1.7, `isHasRYAGPS` 34F1 b14.6 (AGPS, đồng hồ xin `01 E9 AC 03 01 02` mỗi 60 s) |
| Gọi điện, danh bạ | `isHasBluetooth3` b2.2, `isHasContact` b6.5, `isHasContactMax20` b2.3, `isHasContactDel` 34F1 b18.2, `isHasHangup` b17.6 |
| Thông báo | `isHasSocialNotification` b16.6, `isHasSocialNotification2` b12.3, `isHasIconANCS` b6.3, trả lời SMS (b3.1, F6 `0x200`), tin dài 240 byte (b2.6, F6 `0x400000`) |
| Cài đặt | `isHasMulClock` b17.1 + `isHasLocalAlarmClock` b4.0, `isHasSilence` b19.3, `isHasHandLight` b19.6, `isHasRemindSit` b17.0 + `isHasSitRemindDuration` b16.4, `isHasFindiPhone` b16.5, `isHasSwitchTempUnit` b12.4, nhóm ngôn ngữ (b16.3, b12.6, b13.5, b2.5, b6.0, b8.4), `isHasShortcutButton` b8.0, `isHasModifyBluetoothName` b9.6 |
| Thời tiết | `isHasWeatherSeven` b18.5, `isHasWeatherHumidityUV` b3.3 |
| Mặt đồng hồ | `isHasSwitchDialOnline` b12.0 (F3 `0x100`, GloryFitPro `isSupDial`) |
| Thể thao | ~20 môn (phụ lục A), `isHasFreeSport` b8.5, `isHasSportPause` b7.1, `isHasSportValidTime` b5.2, `isHasCustomSportIconList` b3.5, `isHasSwim` b19.4 |

Khác biệt với Android nằm ở UI, không nằm ở capability:

| Mục trên màn thiết bị | Android (`DeviceDetail.kt`) | iOS (`DeviceDetailView.swift`) |
|---|---|---|
| Ô capability | 4 ô. `STEPS`/`SLEEP` ghi "Xem ở mục Lịch sử" | 2 ô đo + 2 dòng "đồng bộ lịch sử · chưa có trong bản này" |
| Lịch sử | `HistorySection`: nút "Đồng bộ 7 ngày", chọn ngày, thẻ Hoạt động, Giấc ngủ, Nhịp tim, SpO2 | Không có (`Ute.swift` cuối file: "TODO: lịch sử… Core iOS chưa có HistoryPoint / SleepSession / syncHistory") |
| Mặt đồng hồ | Thẻ "Tuỳ chỉnh mặt đồng hồ" (`WatchFaceEditor`), `WatchFaceLibrarySection` (2 mặt, cài, đặt mặc định, tự cài) | Không có UI. `WatchFaceStore` tự cài Peacock 3D lúc kết nối, trạng thái không hiển thị |
| Ghép nối | `PairingOverlay` | SDK có `pairingPrompt`, UI là TODO (`GloryFitDriver.swift:61`) |

Đề xuất kiến trúc (cả hai nền tảng): thêm một lớp **tính năng phi đo lường**, ví dụ `DeviceFeature` /
`features: Set<DeviceFeature>`, do driver suy ra từ bảng bit. UI sẽ sinh mục "Cài đặt", "Thông báo", "Thể thao"
theo lớp này, giống cách đang sinh ô đo theo `Capability`. Không nhét các tính năng này vào `Capability`.

---

## 2. Hiện trạng theo tầng

| Tầng | Android | iOS |
|---|---|---|
| Core | `WearableDevice` có `syncHistory`, `history`, `syncProgress`, `supportsHistory`, `pairingPrompt`. `History.kt` (HistoryPoint, SleepSession, ActivityTotals, DeviceHistory). `WatchFace.kt` (`WatchFaceCustomizable`, style, widget, complication) | `WearableDevice` chỉ có connect/measure/battery/RSSI/log. **Không** có mô hình lịch sử, **không** có giao diện mặt đồng hồ chung |
| GloryFit SDK | Bắt tay `A3/A1/A2/A0/A9`, `F7 01` + `F7 09` (5 phút). Đo HR (đẩy `F7 03/0B` + `E5 11`), SpO2, BP, nhiệt độ. Lịch sử `B2 FA`, `B3 FA`, `F7 FA`/`E6 FA`, `34 FA`. Mặt đồng hồ: `26 01`, renderer ảnh → `.bin` (`WatchFaceRenderer.kt`, 505 dòng), cài `.bin`, kiểm mặt tuỳ chỉnh. `ota/RealtekImage.kt` chỉ đọc và kiểm chữ ký, không nối vào app | Bắt tay, đo, `F7 01/09` giống Android. `queryDialParams`, `installWatchFaceFile` (đã theo iOS gốc: `26 03 03` chờ 600 ms). **Không** có lịch sử, **không** có renderer |
| QRing SDK | Bắt tay, pin, đo 6 loại (`69/6A`). Lịch sử: tổng hôm nay `0x48`, bước `0x43`, HR `0x15`, HRV `0x39`, stress `0x37`, nhiệt độ big-data `0x77`, ngủ `0x27` + ngủ trưa `0x3E`, SpO2 `0x2A` | Bắt tay kiểu iOS (`04 01`, retry), pin, pin đẩy `73 0C`, đo 6 loại, MAC từ 2A23. **Không** có lịch sử, `requestStream`, `requestBigDataMulti` |
| App lab | Thiết bị, Thêm (quét nhiều), Khả thi, Đo đồng loạt, màn thiết bị (đo, ô capability, pin, ngắt/quên, mặt đồng hồ, lịch sử, chi tiết kỹ thuật + log gói), `PairingOverlay`, `ConnectionService` (foreground) | Thiết bị, Thêm, Khả thi (đo đồng loạt), màn thiết bị (đo, dữ liệu đồng bộ "chưa có", pin & thông tin, chi tiết kỹ thuật + log gói, Giữ kết nối, Bỏ khỏi danh sách), tự cài mặt đồng hồ ngầm, `bluetooth-central` nền + khôi phục thiết bị |

---

## 3. Y25 và HT43 (GloryFit / UTE)

### 3.1 Đo tức thời

| Tính năng | Bit / bằng chứng | Y25 | HT43 | Android | iOS | Port | Ghi chú |
|---|---|---|---|---|---|---|---|
| Nhịp tim | `b17.3` F1 `0x080000` | ✓ | ✓ | ✓ | ✓ | – | Hai máy là "HR 24h" (`b15.6`) và thiếu `isHasHRMTimedMeasurement` (`34F1 b8.7` = 0). SDK iOS gốc chặn `E5 11`/`D6 01`. Driver lấy nhịp tim từ `F7 03` (đo định kỳ) và `F7 0B` (đo trên đồng hồ). HT43 chưa kiểm chứng |
| SpO2 đo tay | `b7.6` F5 `0x40`, lệnh `34 11` | ✓ | ✓ | ✓ | ✓ | – | |
| Huyết áp | `b17.4` F1 `0x100000`, lệnh `C7 11` | ✓ | n/a | ✓ | ✓ | – | Ước lượng từ PPG, không có cảm biến riêng (08 §1) |
| Nhiệt độ | `b7.3` F5 `0x08` = 0 | n/a | n/a | SDK | SDK | – | Firmware Y25 có driver thermistor nhưng bit tắt |
| Stress, HRV, ECG, đường huyết, nhịp thở | `b4.5`, `34F1 b10.5/b17.2`, `b12.5`, `34F1 b17.1`, `b6.6` đều = 0 | n/a | n/a | – | – | – | |
| Đo SpO2/HR tự động theo lịch (app đặt) | `isHasHRMAndBloodOxygenAuto` `34F1 b10.0` = 0; `isSupOxygenInterval` F9 `0x1000` = 0 | n/a | n/a | – | – | – | Chỉ có HR 24h (dòng dưới) |
| HR 24h: bật + chu kỳ | `b15.6` F2 `0x4000`, `F7 01`, `F7 09 en mmH mmL` | ✓ | ✓ | SDK | SDK | S | Cả hai cố định 5 phút. Thiếu UI bật/tắt (`F7 02`) và chọn chu kỳ (5…1440 phút) |
| Trạng thái đo HR | `E5 AA` | ✓ | ✓ | SDK | SDK | – | `heartRateMeasuring()` |
| Cảnh báo nhịp tim cao / thấp | `b19.7` F1 `0x80`, `b9.3` F4 `0x800`; byte 11/18 của `A9` | ✓ | ✓ | – | – | S | `Ute.userInfo` gửi cố định `FF` (tắt) và `00`. Chỉ cần thêm tham số và UI |
| Pin | `A2` | ✓ | ✓ | ✓ | ✓ | – | |

### 3.2 Lịch sử / đồng bộ

| Tính năng | Bit / lệnh | Y25 | HT43 | Android | iOS | Port | Ghi chú |
|---|---|---|---|---|---|---|---|
| Hạ tầng lịch sử (mô hình + `syncHistory` + tiến độ) | – | – | – | ✓ | – | M | Port `History.kt`, `WearableDevice.syncHistory/history/syncProgress`, `DeviceManager.syncHistory` |
| Màn Lịch sử | – | – | – | ✓ | – | M | Port `HistorySection.kt` (chọn ngày, thẻ Hoạt động/Ngủ/chuỗi). Swift Charts làm phần biểu đồ |
| Bước theo giờ | HT43: `B2 FA`. Y25: `EB 02 FA` trên `34F1` vì có CyWee `34F1 b19.5` (F8 `0x20`) | ✓ | ✓ | ½ | – | M | Android chỉ gửi `B2 FA` ⇒ với Y25 nhiều khả năng không có dữ liệu (01 §10). HT43 có `isHasWalkRun` (F1 `0x100`): gói `B2` có phần mở rộng chạy/đi, parser vẫn đọc được 7 byte đầu |
| Giấc ngủ | `isHasResolveSleep` `b8.2` (F4 `0x040000`) ⇒ `31 01` / `32 …` / `31 02`. Y25 (CyWee) ⇒ `EC 01` | ✓ | ✓ | ½ | – | M | Android chỉ gửi `B3 FA`. SDK mới không gửi `B3 FA` khi có bit này. Cần định dạng `31 01` (01 §5.3). Có ngủ REM (`b1.3`): parser hiện chỉ ra DEEP/LIGHT/AWAKE |
| Ngủ rải rác (ban ngày) | `isHasSleepSporadic` `34F1 b19.5` | ✓ | n/a | – | – | S | Đi kèm CyWee |
| Nhịp tim 24h (ô 10 phút) | `F7 FA` (có `b15.6`) | ✓ | ✓ | ✓ | – | S | Đã kiểm chứng trên Y25 (01 §10) |
| SpO2 | `34 FA` | ✓ | ✓ | ✓ | – | S | |
| Huyết áp | `C8 FA` | ✓ | n/a | – | – | S | Android cũng chưa đồng bộ |
| Tổng hôm nay (bước, calo, quãng đường) | `isHasALLCalories` `34F1 b11.0`, `isHasNewCalculate` `b15.4`; bước realtime `B1 …` (đồng hồ tự đẩy) | ✓ | ✓ | – | – | S | `DeviceHistory.today` của GloryFit đang để null |
| Đồng bộ từ mốc thời gian | F4 `0x2000` = `b9.5` (Android `SyncDateUtils`; iOS gọi là `isHasDataStatus`) | ✓ | ✓ | – | – | S | Hiện luôn lấy toàn bộ (`xx FA` không mốc) |
| Bài tập / GPS | `F4 FA` (đa môn), `47 73` (GPS), dữ liệu GPS | ✓ | ✓ | – | – | L | Xem §3.6 |

### 3.3 Mặt đồng hồ

| Tính năng | Bit / lệnh | Y25 | HT43 | Android | iOS | Port | Ghi chú |
|---|---|---|---|---|---|---|---|
| Đọc thông số `26 01` | luôn có; 466 × 466 tròn, 1 MB, level 2, 1 khe | ✓ | ✓ | SDK | SDK | – | |
| Cài file `.bin` dựng sẵn | `26 02/03` + `27` | ✓ | ✓ | ✓ | SDK | – | HT43 đã cài được (02 §5). iOS đã theo bản gốc: `26 03 03` ⇒ chờ 600 ms |
| Thư viện mặt (Peacock 3D, Peacock Atelier), chọn mặc định | – | ✓ | ✓ | ✓ | ½ | S | iOS: `WatchFaceStore` và 2 file `.bin` đã có, thiếu mục UI (ảnh xem trước, nút cài, tiến độ, "đặt mặc định") |
| Tự cài mặt mặc định khi kết nối | – | ✓ | ✓ | ✓ | ½ | S | iOS tự cài nhưng không có công tắc bật/tắt và trạng thái không hiện ra |
| Trình chỉnh mặt tuỳ biến (ảnh nền, màu, vị trí giờ, 10 thành phần, kéo thả, AM/PM) | `WatchFaceCustomizable` | ✓ | ✓ | ✓ | – | L | Port `WatchFaceRenderer.kt` (Bitmap → CoreGraphics, RGB565 BE, nén level 2) + `WatchFaceEditor.kt` (484 dòng) + lưu theo thiết bị (`WatchFaceStore.kt`) |
| Chuyển giữa các mặt có sẵn / mặt online | `isHasSwitchDialOnline` `b12.0` (F3 `0x100`) | ✓ | ✓ | – | – | M | Lệnh trong `WriteCommandToBLE.switchWatchFace` (GloryFit 4.0.12) |
| Kho mặt online của UTE | server, `research/watchstore` | ✓ | ✓ | – | – | L | Đã tải và giải mã thử ở `research/watchstore`; nhóm mặt trên server là 0 (08 §3.1) |
| Ghi không phản hồi 10 gói / 20 ms (nhanh hơn) | 09 §3 | ✓ | ✓ | – | – | S | Tối ưu, không bắt buộc |

### 3.4 Cài đặt / điều khiển

> **Cập nhật 2026-10-15: đã làm trên cả Android và iOS** (`UteSettings.kt/.swift`, mục "Cài đặt" trong màn chi tiết).
> Có: tìm đồng hồ (`AB 00 00 00 01 02 07 01`), đồng hồ tìm điện thoại (`D1 0A`, app đổ chuông), nâng tay, thời gian
> sáng màn, 12/24h, °C/°F, ngôn ngữ (`AF AB n`), HR 24h bật/tắt + chu kỳ, cảnh báo nhịp tim cao/thấp, nhắc vận động
> (+ khung giờ, nghỉ trưa), không làm phiền (`D7`), mục tiêu bước/kcal/km (`A9` + `3F`), hồ sơ (`A9`), chu kỳ kinh
> nguyệt (`29`, `MENSTRUATION` đã ánh xạ). Ẩn theo cờ: uống nước (`D4`, b5.3) và SpO2 tự động (`34 03`, F9 `0x1000`).
> Đồng hồ không cho đọc lại nên SDK lưu theo thiết bị. Kiểm chứng trên Y25/HT43 thật: `AB…` (tìm), `A9`, `F7 09`
> được nhận. Chưa làm: báo thức (Y25/HT43 có `isHasLocalAlarmClock` = đặt trên đồng hồ), thời tiết (cần nguồn dữ
> liệu), danh bạ, tắt máy/khởi động lại (bit tắt).

| Tính năng | Bit / lệnh | Y25 | HT43 | Android | iOS | Port | Ghi chú |
|---|---|---|---|---|---|---|---|
| Đặt giờ | `A3 YYYY MM DD hh mm ss [tz]` | ✓ | ✓ | SDK | SDK | – | Byte múi giờ sau cờ debug |
| Đơn vị, 12/24h | `A0 01 01` | ✓ | ✓ | SDK | SDK | S | Cố định metric + 24h. `isSupHoursSetting` của GloryFitPro phụ thuộc danh sách phím tắt (`b8.0`) |
| Đơn vị nhiệt °C/°F | `isHasSwitchTempUnit` `b12.4`; `A9` byte 17 | ✓ | ✓ | SDK | SDK | S | Cố định °C |
| Thông tin người dùng (cao, nặng, tuổi, giới, mục tiêu bước, thời gian tắt màn) | `A9` 19 byte (01 §5.2); mục tiêu `isHasActivityGoal` `b5.5` | ✓ | ✓ | SDK | SDK | S | Cố định 170 cm/65 kg/30 tuổi/nam/8000 bước/5 s. Cần form |
| Nâng tay sáng màn | `isHasHandLight` `b19.6` (F1 `0x40`); `A9` byte 10 | ✓ | ✓ | SDK | SDK | S | Cố định bật |
| Không làm phiền | `isHasSilence` `b19.3` (F1 `0x08`); `D7 …` | ✓ | ✓ | – | – | S | `sendDisturbToBle` |
| Nhắc ngồi lâu (+ khung giờ, nghỉ trưa) | `isHasRemindSit` `b17.0`, `isHasSitRemindDuration` `b16.4`; `D3 …` | ✓ | ✓ | – | – | S | |
| Báo thức | `isHasMulClock` `b17.1`, `isHasLocalAlarmClock` `b4.0`; `AB cycle …` | ✓ | ✓ | – | – | M | GloryFitPro **ẩn** cài báo thức từ app khi có `b4.0` mà không có `isHasClockTitle` (`b2.1` = 0) ⇒ báo thức đặt trên đồng hồ **(suy luận)**. Ưu tiên thấp |
| Tìm đồng hồ (rung) | `AB 00 00 00 01 xx 07 01` | ✓ | ✓ | – | – | S | Không cần bit |
| Đồng hồ tìm điện thoại | `isHasFindiPhone` `b16.5` (F2 `0x20`); `D1 0A en` | ✓ | ✓ | – | – | S | iOS: phát âm thanh / local notification. Ở nền bị giới hạn · **Kiểm chứng 16/10/2026 trên Y25 + iPhone 11: bấm trên đồng hồ → iPhone đổ chuông; bấm "Đã tìm thấy" → `D1 0A 01 00` → đồng hồ tắt màn tìm** |
| Ngôn ngữ đồng hồ | `b16.3`, `b12.6`, `b13.5`, `b2.5`, `b6.0`, `b8.4`; `AF AB n` | ✓ | ✓ | – | – | S | |
| Thời tiết 7 ngày + độ ẩm/UV | `isHasWeatherSeven` `b18.5`, `isHasWeatherHumidityUV` `b3.3`; `CA …` | ✓ | ✓ | – | – | M | Cần nguồn thời tiết (iOS: WeatherKit) |
| Chu kỳ kinh nguyệt | `isHasMenstruationReminder` `b12.7` (F3 `0x8000`) | ✓ | ✓ | – | – | M | Thêm `MENSTRUATION` vào `capabilities()` (S) + lệnh cài chu kỳ (`setPhysiologicalPeriod`) |
| Phím tắt / màn hình nhanh | `isHasShortcutButton` `b8.0` (F4 `0x10000`) | ✓ | ✓ | – | – | M | |
| Đổi tên Bluetooth | `isHasModifyBluetoothName` `b9.6` | ✓ | ✓ | – | – | S | |
| Tắt máy / khởi động lại | `isHasShutdown` `b13.3` = 0, `isHasReboot` `b3.4` = 0 (`E8 11/12`) | n/a | n/a | – | – | – | Bit tắt, không nên làm |
| Xoá dữ liệu trên đồng hồ | `AD` | ✓ | ✓ | – | – | S | Nguy hiểm, chỉ để trong mục kỹ thuật |
| Chế độ nhà máy | `isHasFactoryMode` `b11.4` | ✓ | ✓ | – | – | – | Không làm |

> **Cập nhật 2026-10-15 (tối):**
> - **Báo thức Y25/HT43:** đã thử thật. Không ghi được: `AB` được đồng hồ báo nhận nhưng không vào danh sách,
>   không kêu; `51` không phản hồi. Cũng không đọc được: `readUTEAlarm` của SDK iOS đòi cờ `isHasClockTitle`,
>   máy này không có. Kết luận: báo thức chỉ đặt trên đồng hồ.
> - **Danh bạ** (`37 FA/FB/FC`, tối đa 70): đã làm cả iOS và Android, đã kiểm chứng trên Y25.
> - **Gọi điện qua đồng hồ:** kênh Bluetooth cổ điển, trạng thái đọc qua `38 01`.
>   - Kiểm chứng: gọi điện và Siri chạy sau khi ghép trong Cài đặt iOS.
>   - Android tự ghép (`createBond`).
>   - Cờ ghép/kết nối đồng hồ báo về không đáng tin.
> - **Thời tiết 7 ngày** (`CB 01/02/03`, kênh 34F1): đã kiểm chứng trên Y25/HT43.

### 3.5 Thông báo / cuộc gọi

| Tính năng | Bit / lệnh | Y25 | HT43 | Android | iOS | Port | Ghi chú |
|---|---|---|---|---|---|---|---|
| Thông báo ứng dụng | `isHasSocialNotification` `b16.6`, `…2` `b12.3`, `isHasIconANCS` `b6.3`; tin dài 240 byte `b2.6` (F6 `0x400000`); `C5 …` | ✓ | ✓ | 🟡 `UteNotify` + `WatchNotificationListener` (chưa thử trên máy) | – | S | iOS: app không đọc được thông báo của app khác. Đồng hồ nhận qua **ANCS** sau khi ghép đôi với iPhone (09 §6). Việc của app là hướng dẫn ghép đôi + tuỳ chọn `RequiresANCS` khi connect. Android cần NotificationListener + `C5` (M) |
| Cuộc gọi đến: báo, từ chối | `isHasHangup` `b17.6` (F1 `0x400000`); RK: `C5` loại 0 + `45 FA` số, `C1 04` khi kết thúc; từ chối `D1 02` + bit 3 `D7` | ✓ | ✓ | 🟡 `GloryFitDevice.incomingCall/callEnded/rejectCallRequests` + `PhoneBridge` (chưa thử) | – | S | iOS: qua ANCS. `AB … 02 01` là luồng app cũ (không RK) |
| Gọi điện trên đồng hồ (BT Classic) | `isHasBluetooth3` `b2.2` (F6 `0x40000`) | ✓ | ✓ | – | – | S | Ghép đôi HFP trong Cài đặt hệ thống. App chỉ hướng dẫn |
| Danh bạ | `isHasContact` `b6.5`, `isHasContactMax20` `b2.3`, `isHasContactDel` `34F1 b18.2` | ✓ | ✓ | – | – | M | Contacts framework + gói danh bạ (`sendContactStart…`) |
| Trả lời SMS nhanh | b3.1 (F6 `0x200`, `isSupSmsReply`) | ✓ | ✓ | 🟡 `UteSmsReply` + `setSmsReply`/`smsReplyRequests` (chưa thử) | n/a | – | iOS không cho app gửi SMS ngầm |
| Điều khiển nhạc / tên bài | b6.4 (F5 `0x1000`, GloryFit cũ `MusicControl`); `isHasControlMusic` `b17.7` = 0 | ✓ | ✓ | 🟡 `UteMusic` + `PhoneBridge` (MediaSession, chưa thử) | ½ n/a | L | iOS không cho điều khiển app nhạc khác. Không khuyến nghị |

### 3.6 Thể thao, GPS, AGPS

| Tính năng | Bit / lệnh | Y25 | HT43 | Android | iOS | Port | Ghi chú |
|---|---|---|---|---|---|---|---|
| ~20 môn thể thao trên đồng hồ | đi bộ máy, gập bụng, cricket, bóng bầu dục Mỹ, khúc côn cầu, đạp xe trong nhà, yoga, leo núi, đi bộ đường dài, bóng rổ, bóng đá, bóng chày, bóng chuyền, chèo thuyền, bật nhảy, đạp xe, cầu lông, quần vợt, bơi (phụ lục A) | ✓ | ✓ | – | – | L | Đồng bộ `F4 FA` + parser từng môn |
| Tạm dừng, thời gian hiệu quả, môn tự do, danh sách icon môn | `b7.1`, `b5.2`, `b8.5`, `b3.5` | ✓ | ✓ | – | – | M | |
| Kiểu bơi | `isHasSwimCategory` `34F1 b15.1` | ✓ | n/a | – | – | S | Đi kèm CyWee |
| GPS khi tập | `isHasSportGPS` `b1.7` | ✓ | ✓ | – | – | L | HT43 có CC1165W. Y25 có driver, chưa chắc có lắp (08 §0) |
| **AGPS** (ephemeris) | `isHasRYAGPS` `34F1 b14.6` (F9 `0x400000`); `01 E9 …` | ✓ | ✓ | – | – | M–L | HT43 xin `01 E9 AC 03 01 02` mỗi 60 s. Luồng: `AA 01` ⇒ server `getAgpsFile` ⇒ `AB 03 01 03` ⇒ `AB 04` khối 4 KB (09 §4). Cần người dùng đồng ý trước khi gọi API UTE |

### 3.7 OTA / firmware

| Tính năng | Bit / lệnh | Y25 | HT43 | Android | iOS | Port | Ghi chú |
|---|---|---|---|---|---|---|---|
| Phiên bản firmware, DSP | `A1`, `A1 01` | ✓ | ✓ | SDK | SDK | – | DSP chưa đọc |
| OTA Realtek | `b0.3` (F7 `0x0800`, "8762Cx"/RK) | ✓ | ✓ | ½ | – | L | Android: `RealtekImage` chỉ đọc + kiểm chữ ký. Server không có firmware HT43 (09 §5). Ưu tiên thấp |

### 3.8 Kết nối và mục kỹ thuật (app lab)

| Tính năng | Android | iOS | Port | Ghi chú |
|---|---|---|---|---|
| Bind mã 4 số / account ID | ✓ (`PairingOverlay`) | SDK (UI TODO) | S | Y25/HT43 không cần (F1 `0x01` = 0, F10 `0x080000` = 0). Chỉ để bằng Android |
| Nối lại khi mất kết nối, giữ kết nối | ✓ (`autoConnect`, foreground service) | ✓ (`retrievePeripherals`, `bluetooth-central`) | – | |
| Chi tiết kỹ thuật: bảng `33F1`/`34F1`, log gói | ✓ | ✓ | – | iOS hiện thêm "Độ dài ghi iOS" |
| Bảng tính năng đã giải mã (tên bit) | – | – | S | Hiện danh sách tên bit đang bật (phụ lục A), như `Cờ khả năng` của QRing iOS |
| Đo đồng loạt, tab Khả thi | ✓ | ✓ | – | |

---

## 4. R09 (nhẫn) và DS500 / HS500A (vòng tay) (QRing)

Bảng khả năng (devices.md, giải mã theo 02-commands §4.2, §4.4):
- **R09**: SetTime `01 00 00 02 00 00 00 00 01 00 20 00 00 30`, DeviceSupport `00 AC 27 00 …`.
- **DS500**: SetTime `00 00 01 16 00 00 00 00 01 00 20 00 00 30`, DeviceSupport `00 40 00 A0 00 00 08 30 …`.

Ký hiệu: `t[i]` = byte i của SetTime, `s[i]` = byte i của DeviceSupport.

### 4.1 Đo tức thời

| Tính năng | Bit / lệnh | R09 | DS500 | Android | iOS | Port | Ghi chú |
|---|---|---|---|---|---|---|---|
| Nhịp tim | luôn có; `69 01` | ✓ | ✓ | ✓ | ✓ | – | R09 ~25 s ra kết quả |
| SpO2 | `t3` b1; `69 03` | ✓ | ✓ | ✓ | ✓ | – | |
| Nhiệt độ | `t0 = 1`; `69 0B` | ✓ | n/a | ✓ | ✓ | – | DS500 không có nhiệt độ |
| Huyết áp | `t3` b2; `69 02` | n/a | ✓ | ✓ | ✓ | – | |
| Stress | `t13` b4; `69 08` | ✓ | ✓ | ✓ | ✓ | – | |
| HRV | `t13` b5; `69 0A` | ✓ | ✓ | ✓ | ✓ | – | |
| Đo một chạm (nhiều chỉ số) | `t3` b4 `oneKeyCheck`; `69 05` | n/a | ✓ | – | – | S | |
| Pin + pin đẩy `73 0C` | `03`, `73 0C xx` | ✓ | ✓ | ✓ | ✓ | – | |

### 4.2 Lịch sử / đồng bộ

| Tính năng | Lệnh | R09 | DS500 | Android | iOS | Port | Ghi chú |
|---|---|---|---|---|---|---|---|
| Hạ tầng: `requestStream`, `requestBigDataMulti`, `HistoryParser` | – | – | – | ✓ | – | M | `HistoryParser.kt` 235 dòng, có test (`HistoryParserTest.kt`) để port kèm |
| Tổng hôm nay | `0x48` | ✓ | ✓ | ✓ | – | S | |
| Bước (khung 15 phút) | `0x43` | ✓ | ✓ | ✓ | – | S | |
| Nhịp tim | `0x15` | ✓ | ✓ | ✓ | – | S | |
| HRV, stress | `0x39`, `0x37` | ✓ | ✓ | ✓ | – | S | |
| Nhiệt độ | big-data `0x77` (phân trang) | ✓ | n/a | ✓ | – | S | R09 trả `00` khi chưa có dữ liệu |
| Giấc ngủ + ngủ trưa | big-data `0x27` + `0x3E` (`t8 = 1`, `newSleepProtocol`) | ✓ | ✓ | ✓ | – | S | `0x3E` cùng định dạng `0x27` (devices.md) |
| SpO2 | big-data `0x2A` | ✓ | ✓ | ✓ | – | S | |
| Huyết áp | tự động `0x0D` (+ xác nhận `0x0E`), đo tay `0x14` | n/a | ✓ | – | – | S | Giá trị `0x0D` là nhịp tim, app QRing **tự sinh** SBP/DBP (03 §5.5). Chỉ nên lấy `0x14` |
| Kinh nguyệt | `0x2B` | n/a | ✓ (`t2 = 1`) | – | – | M | `Capability.MENSTRUATION` đã được ánh xạ nhưng chưa có lệnh hay UI |
| Bài tập (SportPlus) | big-data `BC 41..45` | ? | ? | – | – | L | Chưa rõ thiết bị nào có. Không có bit riêng |

### 4.3 Cài đặt / điều khiển

> **Cập nhật 2026-10-15: đã làm trên cả Android và iOS** (`QRingSettings.kt/.swift`). Driver đọc lại cài đặt khi kết
> nối (`16/2C/36/38/3A/21/0A` + với vòng tay `06/05/26`) rồi ghi giữ nguyên các byte không đổi. Kiểm chứng trên R09
> thật: đọc ra tuổi 31, cao 175 cm, mục tiêu 5000 bước; ghi `21` rồi đọc lại khớp. R09 **không** bật cờ `noScreen`,
> nên nhận nhẫn theo phần cứng/tên (`RT0x`, `R0x`): nhẫn ẩn DND / nâng tay / nhắc ngồi (R09 trả rác cho `26`).
> Tìm nhẫn/vòng `50 55 AA`; nhẫn/vòng tìm điện thoại `22 01/02`.

| Tính năng | Lệnh | R09 | DS500 | Android | iOS | Port | Ghi chú |
|---|---|---|---|---|---|---|---|
| Hồ sơ người dùng, 12/24h, đơn vị | `0x0A` | ✓ | ✓ | – | – | S | |
| Mục tiêu (bước, calo, quãng đường, phút) | `0x21` | ✓ | ✓ | – | – | S | |
| Đo HR tự động (chu kỳ, ngưỡng thấp/cao) | `0x16` | ✓ | ✓ | – | – | S | Ảnh hưởng mật độ dữ liệu lịch sử |
| SpO2 / stress / HRV tự động | `0x2C`, `0x36`, `0x38` | ✓ | ✓ | – | – | S | |
| Nhiệt độ tự động | `0x3A` type 3 | ✓ | n/a | – | – | S | |
| Huyết áp tự động | `0x0C` | n/a | ✓ | – | – | S | |
| Chạm / cử chỉ (nhạc, video ngắn, ebook, game) | `0x3B`; `s1` b7 gesture, `s2 = 0x27` | ✓ | n/a | – | – | M | R09 báo `GESTURE`. Cả hai app có capability nhưng không có màn cài đặt |
| Hiệu chỉnh đeo | `A1 06` / `A1 02`; `s1` b2 `appRevision` | ✓ | n/a | – | – | M | Không chạy khi đang sạc, timeout 120 s |
| Ghép đôi BLE hệ thống | `s1` b3 `blePair` | ✓ | n/a | ½ | ½ | S | iOS tự hiện hộp thoại ghép khi chạm characteristic cần mã hoá. App nên báo trạng thái |
| Tìm thiết bị (rung) | `50 55 AA` | ? | ✓ | – | – | S | Nhẫn có thể không có motor **(suy luận)** |
| Thông báo | `s3` b5 `supportNotification`; iOS: `04 01` + ANCS. Android: `0x60`/`0x72` | n/a | ✓ | – | – | S–M | DS500 không màn hình: chỉ rung theo loại thông báo **(suy luận)** |
| Báo thức, không làm phiền | `s6` b6/b7 = 0 | n/a | n/a | – | – | – | Bit tắt |
| Tắt nguồn / khôi phục gốc | `08 01`, `FF 66 66` | ✓ | ✓ | – | – | S | Chỉ để trong mục kỹ thuật |
| AI phân tích, lover space, bạn bè | `s3` b7, `s6` b3, `s7` b5 | n/a | ✓ | – | – | – | Tính năng cloud của app QRing, ngoài phạm vi |

---

## 5. Backlog iOS theo thứ tự ưu tiên

### 5.1 P0: bằng Android

| # | Việc | Thiết bị | Port | Phụ thuộc | Ghi chú |
|---|---|---|---|---|---|
| 1 | **Core lịch sử iOS**: `HistoryPoint`, `SleepSession/Segment/Stage`, `ActivityTotals`, `DeviceHistory`, `SyncProgress`; `WearableDevice.supportsHistory/history/syncProgress/syncHistory(days:)`; `DeviceManager.syncHistory` | tất cả | M | – | Giữ đúng tên Android (docs/architecture.md) |
| 2 | **Lịch sử QRing iOS**: port `HistoryParser.kt` + `HistoryParserTest.kt`, thêm `requestStream`, `requestBigDataMulti`, đồng bộ theo trình tự `QRingDriver.syncHistoryImpl` | R09, DS500 | M | 1 | Android đã chạy thật trên cả hai (devices.md). Port an toàn nhất |
| 3 | **Lịch sử GloryFit iOS**: port `Ute.parse*` + `stream()` | Y25, HT43 | M | 1 | Port **kèm** sửa đường lấy dữ liệu theo bit (việc 9). Không chép nguyên `B2/B3` |
| 4 | **Màn Lịch sử** (`HistorySection`): nút đồng bộ 7 ngày, chọn ngày, thẻ Hoạt động/Ngủ, chuỗi HR/SpO2/HRV/Stress/Nhiệt độ, lỗi từng bước | tất cả | M | 1 | Thay dòng "đồng bộ lịch sử · chưa có" bằng "Xem ở mục Lịch sử" như Android |
| 5 | **Thư viện mặt đồng hồ có UI** trong màn thiết bị: ảnh xem trước 2 mặt, cài + tiến độ, đặt mặc định, công tắc tự cài, trạng thái của `WatchFaceStore` | Y25, HT43 | S | – | Mọi phần SDK/store đã có |
| 6 | **Trình chỉnh mặt đồng hồ**: port `WatchFaceRenderer.kt` sang CoreGraphics, `WatchFaceCustomizable` trong core iOS, màn chỉnh (ảnh nền PhotosPicker, màu, vị trí giờ, 10 thành phần, kéo thả), lưu theo thiết bị | Y25, HT43 | L | 5 | Đối chiếu từng byte với renderer Android bằng test (ảnh mẫu ⇒ cùng `.bin`) |
| 7 | **UI ghép nối** (`pairingPrompt`: nhập mã 4 số, xác nhận trên đồng hồ) | GloryFit khác | S | – | 4 thiết bị này không cần, làm cho đủ |

### 5.2 P1: sửa chung cả hai nền tảng (phát hiện từ bảng bit)

| # | Việc | Thiết bị | Công | Ghi chú |
|---|---|---|---|---|
| 8 | Thêm `MENSTRUATION` vào `Ute.Features.capabilities()` (F3 `0x008000`) | Y25, HT43 | S | Một dòng mỗi nền tảng + test |
| 9 | Chọn lệnh đồng bộ theo bit: ngủ `31 01` khi có F4 `0x040000`; bước `EB 02 FA` (kênh 34F1) và ngủ `EC 01` khi có F8 `0x20`; parser REM | Y25, HT43 | M | Cần kiểm chứng trên đồng hồ. Định dạng `31 01/32` ở `BluetoothLeService.java:7640-7681`, `EC 01` cần đọc thêm trong `utesdk` |
| 10 | Lớp `DeviceFeature` (tính năng phi đo lường) suy từ bit, để UI sinh mục Cài đặt/Thông báo/Thể thao | tất cả | M | Nền cho P2 |

### 5.3 P2: vượt Android (phần cứng có, cả hai app chưa có)

| # | Việc | Thiết bị | Công | Ghi chú |
|---|---|---|---|---|
| 11 | **Cài đặt người dùng**: hồ sơ, đơn vị, 12/24h, °C/°F, mục tiêu bước, nâng tay sáng màn, thời gian tắt màn, cảnh báo HR cao/thấp (GloryFit `A0`/`A9`; QRing `0x0A`/`0x21`) | tất cả | M | Hiện đang gửi giá trị cố định lúc kết nối |
| 12 | **HR 24h / đo tự động**: bật/tắt + chu kỳ (GloryFit `F7 01/02/09`; QRing `0x16`, `0x2C`, `0x36`, `0x38`, `0x3A`, `0x0C`) | tất cả | S–M | Quyết định mật độ dữ liệu lịch sử |
| 13 | **Tìm thiết bị + đồng hồ tìm điện thoại** (GloryFit `AB…07 01`, nghe `D1 0A`; QRing `50 55 AA`, nghe `22`) | tất cả | S | |
| 14 | **Thông báo qua ANCS trên iOS**: hướng dẫn ghép đôi, `RequiresANCS`, kiểm tra cuộc gọi/từ chối | Y25, HT43, DS500 | S–M | Trên iOS, đây là cách duy nhất. Android cần làm riêng (NotificationListener) |
| 15 | **Không làm phiền, nhắc ngồi lâu, ngôn ngữ** (`D7`, `D3`, `AF AB`) | Y25, HT43 | S | |
| 16 | **Lịch sử huyết áp** (`C8 FA` Y25; `0x14` DS500) | Y25, DS500 | S | Bỏ dữ liệu "tự sinh" `0x0D` |
| 17 | **Thời tiết** 7 ngày + độ ẩm/UV (`CA …`, WeatherKit) | Y25, HT43 | M | |
| 18 | **AGPS** cho HT43 (09 §4) | HT43 (Y25) | M–L | Hết cảnh báo "AGPS has expired". Cần đồng ý trước khi gọi `getAgpsFile` |
| 19 | **Cử chỉ/chạm và hiệu chỉnh đeo** của R09 (`0x3B`, `A1`) | R09 | M | |
| 20 | **Kinh nguyệt** (GloryFit `setPhysiologicalPeriod`; QRing `0x2B`) | Y25, HT43, DS500 | M | |
| 21 | **Danh bạ** (Contacts framework) | Y25, HT43 | M | |
| 22 | **Thể thao + GPS**: đồng bộ bài tập, đường đi | Y25, HT43 | L | |
| 23 | **Chuyển/kho mặt đồng hồ online** | Y25, HT43 | M–L | |
| 24 | **OTA Realtek** | Y25, HT43 | L | Chưa có firmware HT43 trên server |

Không làm trên iOS: trả lời SMS nhanh, điều khiển nhạc của app khác (nền tảng không cho), tắt máy/khởi động lại
GloryFit (bit tắt), chế độ nhà máy.

---

## Phụ lục A: mọi bit đang bật trên Y25 / HT43

Tên lấy từ setter mà `checkBleFunction:` / `checkBleFunction34F1:` gọi cho từng bit (SDK iOS gốc). Bit nào SDK iOS
không gán tên thì lấy theo Android.

| Bit | Nhóm Android | Tên (SDK iOS) | Y25 | HT43 |
|---|---|---|---|---|
| `33F1` b0.3 | F7 `0x000800` | `isDevicesRTL8762Cx` / `isRKDevices` (nền tảng Realtek) | ✓ | ✓ |
| `33F1` b1.3 | F7 `0x000008` | `isHasSleepREM` | ✓ | ✓ |
| `33F1` b1.7 | F7 `0x000080` | `isHasSportGPS` | ✓ | ✓ |
| `33F1` b2.2 | F6 `0x040000` | `isHasBluetooth3` | ✓ | ✓ |
| `33F1` b2.3 | F6 `0x080000` | `isHasContactMax20` | ✓ | ✓ |
| `33F1` b2.5 | F6 `0x200000` | `isHasLocalLanguage` | ✓ | ✓ |
| `33F1` b2.6 | F6 `0x400000` | (không tên) Android: tin nhắn 240 byte | ✓ | ✓ |
| `33F1` b3.1 | F6 `0x000200` | (chỉ log "sms reply") Android `isSupSmsReply` | ✓ | ✓ |
| `33F1` b3.3 | F6 `0x000800` | `isHasWeatherHumidityUV` | ✓ | ✓ |
| `33F1` b3.5 | F6 `0x002000` | `isHasCustomSportIconList` | ✓ | ✓ |
| `33F1` b4.0 | F6 `0x000001` | `isHasLocalAlarmClock` | ✓ | ✓ |
| `33F1` b5.2 | F5 `0x040000` | `isHasSportValidTime` | ✓ | ✓ |
| `33F1` b5.5 | F5 `0x200000` | `isHasActivityGoal` | ✓ | ✓ |
| `33F1` b6.0 | F5 `0x000100` | `isHasReadSupportLanguage` | ✓ | ✓ |
| `33F1` b6.3 | F5 `0x000800` | `isHasIconANCS` | ✓ | ✓ |
| `33F1` b6.4 | F5 `0x001000` | (không tên) Android: nhạc / tên bài | ✓ | ✓ |
| `33F1` b6.5 | F5 `0x002000` | `isHasContact` | ✓ | ✓ |
| `33F1` b7.0 | F5 `0x000001` | (không tên, chưa rõ) | ✓ | ✓ |
| `33F1` b7.1 | F5 `0x000002` | `isHasSportPause` | ✓ | ✓ |
| `33F1` b7.6 | F5 `0x000040` | `isHasBloodOxygen` | ✓ | ✓ |
| `33F1` b8.0 | F4 `0x010000` | `isHasShortcutButton` | ✓ | ✓ |
| `33F1` b8.2 | F4 `0x040000` | `isHasResolveSleep` (ngủ tính trên đồng hồ, `31 01`) | ✓ | ✓ |
| `33F1` b8.4 | F4 `0x100000` | `isHasLanguageSwitchDirectly` | ✓ | ✓ |
| `33F1` b8.5 | F4 `0x200000` | `isHasFreeSport` | ✓ | ✓ |
| `33F1` b8.6 | F4 `0x400000` | `isHasAddAllDataDisplay` | ✓ | ✓ |
| `33F1` b9.1 | F4 `0x000200` | `isHasBoating` | ✓ | ✓ |
| `33F1` b9.2 | F4 `0x000400` | `isHasJumping_Jacks` | ✓ | ✓ |
| `33F1` b9.3 | F4 `0x000800` | `isHasMinHeartAlert` | ✓ | ✓ |
| `33F1` b9.5 | F4 `0x002000` | `isHasDataStatus` (Android: đồng bộ theo mốc) | ✓ | ✓ |
| `33F1` b9.6 | F4 `0x004000` | `isHasModifyBluetoothName` | ✓ | ✓ |
| `33F1` b10.0 | F4 `0x000001` | `isHasTreadmill` | ✓ | ✓ |
| `33F1` b10.1 | F4 `0x000002` | `isHasSit_Ups` | ✓ | ✓ |
| `33F1` b10.2 | F4 `0x000004` | `isHasCricket` | ✓ | ✓ |
| `33F1` b10.3 | F4 `0x000008` | `isHasFootball_USA` | ✓ | ✓ |
| `33F1` b10.4 | F4 `0x000010` | `isHasHockey` | ✓ | ✓ |
| `33F1` b10.6 | F4 `0x000040` | `isHasSpinningCycling` | ✓ | ✓ |
| `33F1` b10.7 | F4 `0x000080` | `isHasYoga` | ✓ | ✓ |
| `33F1` b11.1 | F3 `0x020000` | `isHasMountaineering` | ✓ | ✓ |
| `33F1` b11.2 | F3 `0x040000` | `isHasTramp` | ✓ | ✓ |
| `33F1` b11.3 | F3 `0x080000` | `isHasBasketball` | ✓ | ✓ |
| `33F1` b11.4 | F3 `0x100000` | `isHasFactoryMode` | ✓ | ✓ |
| `33F1` b11.5 | F3 `0x200000` | `isHasSoccer_USA` | ✓ | ✓ |
| `33F1` b11.6 | F3 `0x400000` | `isHasBaseball` | ✓ | ✓ |
| `33F1` b11.7 | F3 `0x800000` | `isHasVolleyball` | ✓ | ✓ |
| `33F1` b12.0 | F3 `0x000100` | `isHasSwitchDialOnline` | ✓ | ✓ |
| `33F1` b12.3 | F3 `0x000800` | `isHasSocialNotification2` | ✓ | ✓ |
| `33F1` b12.4 | F3 `0x001000` | `isHasSwitchTempUnit` | ✓ | ✓ |
| `33F1` b12.6 | F3 `0x004000` | `isHasMoreLanguage` | ✓ | ✓ |
| `33F1` b12.7 | F3 `0x008000` | `isHasMenstruationReminder` | ✓ | ✓ |
| `33F1` b13.0 | F3 `0x000001` | `isHasSportHRM` | ✓ | ✓ |
| `33F1` b13.5 | F3 `0x000020` | `isHasReadLanguage` | ✓ | ✓ |
| `33F1` b15.0 | F2 `0x000100` | `isHasBicycle` | ✓ | ✓ |
| `33F1` b15.2 | F2 `0x000400` | `isHasBadminton` | ✓ | ✓ |
| `33F1` b15.3 | F2 `0x000800` | `isHasTennis` | ✓ | ✓ |
| `33F1` b15.4 | F2 `0x001000` | `isHasNewCalculate` | ✓ | ✓ |
| `33F1` b15.6 | F2 `0x004000` | `isHas24HourHRM` | ✓ | ✓ |
| `33F1` b16.3 | F2 `0x000008` | `isHasMultiLanguage` | ✓ | ✓ |
| `33F1` b16.4 | F2 `0x000010` | `isHasSitRemindDuration` | ✓ | ✓ |
| `33F1` b16.5 | F2 `0x000020` | `isHasFindiPhone` | ✓ | ✓ |
| `33F1` b16.6 | F2 `0x000040` | `isHasSocialNotification` | ✓ | ✓ |
| `33F1` b17.0 | F1 `0x010000` | `isHasRemindSit` | ✓ | ✓ |
| `33F1` b17.1 | F1 `0x020000` | `isHasMulClock` | ✓ | ✓ |
| `33F1` b17.3 | F1 `0x080000` | `isHasHRM` | ✓ | ✓ |
| `33F1` b17.4 | F1 `0x100000` | `isHasBlood` | ✓ | – |
| `33F1` b17.6 | F1 `0x400000` | `isHasHangup` | ✓ | ✓ |
| `33F1` b18.0 | F1 `0x000100` | `isHasWalkRun` | – | ✓ |
| `33F1` b18.5 | F1 `0x002000` | `isHasWeatherSeven` | ✓ | ✓ |
| `33F1` b18.7 | F1 `0x008000` | (không tên, chưa rõ) | ✓ | ✓ |
| `33F1` b19.2 | F1 `0x000004` | `ishasAllFont` | ✓ | ✓ |
| `33F1` b19.3 | F1 `0x000008` | `isHasSilence` | ✓ | ✓ |
| `33F1` b19.4 | F1 `0x000010` | `isHasSwim` | ✓ | ✓ |
| `33F1` b19.6 | F1 `0x000040` | `isHasHandLight` | ✓ | ✓ |
| `33F1` b19.7 | F1 `0x000080` | `isHasMaxHeartAlert` | ✓ | ✓ |
| `34F1` b0..1 | maxLen | `sendMaxLenght` = 244 | ✓ | ✓ |
| `34F1` b11.0 | F10 `0x010000` | `isHasALLCalories` | ✓ | ✓ |
| `34F1` b11.2 | F10 `0x040000` | (không tên) Android: gói dài theo maxLen | ✓ | ✓ |
| `34F1` b14.6 | F9 `0x400000` | `isHasRYAGPS` (Android `isSupEphemerisService`) | ✓ | ✓ |
| `34F1` b15.1 | F9 `0x000200` | `isHasSwimCategory` (Android: dữ liệu bơi CyWee) | ✓ | – |
| `34F1` b18.2 | F8 `0x000400` | `isHasContactDel` | ✓ | ✓ |
| `34F1` b19.5 | F8 `0x000020` | `isHasWalkRun` + `isHasSleepSporadic` (Android `isSupCywee`) | ✓ | – |

Bit **tắt** đáng chú ý (cả hai máy): nhiệt độ `b7.3`, stress `b4.5`, ECG `b12.5`, HRV `34F1 b10.5/b17.2`,
đường huyết `34F1 b17.1`, nhịp thở `b6.6`, uống nước `b5.3`, SOS `b14.7`, tắt máy `b13.3`, khởi động lại `b3.4`,
điều khiển nhạc `b17.7`, AGPS kiểu cũ `b8.1`, GPS kiểu cũ `b16.1`, HR tĩnh/động `b14.3`, đo HR hẹn giờ `34F1 b8.7`,
HR + SpO2 tự động `34F1 b10.0`, nhịp tim nghỉ `34F1 b19.1`, account ID `34F1 b9.3`, mật khẩu `b19.0`.

## Phụ lục B: cách giải mã bảng bit của SDK iOS

`UTESmartBandApi` build `-O0`, nên mỗi bit có cùng một khuôn mã:
1. `ldrb w8, [x8, #byte]` đọc byte, rồi `tbz w8, #bit, …` kiểm bit.
2. Nếu bit bật: gọi `objc_msgSend$setIsHasXxx:` trên `connectedDevicesModel`, hoặc `strb` vào một ivar
   (`_isHasPassword`, `_isHasUserID`…), rồi ghi log `"Function - Device Support … (isHasXxx)"`.

Các bước đã làm:
1. Lấy mã máy bằng `otool -arch arm64 -tV -p "-[UTESmartBandClient checkBleFunction:]"` (tương tự cho `…34F1:`).
2. Script Python đi tuần tự qua mã: ghi lại cặp (byte, bit) ở mỗi `tbz`, rồi gom các setter/ivar phía sau.
3. Đổi offset ivar sang tên bằng `otool -ov`.

Kết quả khớp với các bit đã biết trong 09 §2.1 (`isHas24HourHRM` b15.6, `isHasRYAGPS` 34F1 b14.6,
`isHasHRMTimedMeasurement` 34F1 b8.7, `isHasHRMAndBloodOxygenAuto` 34F1 b10.0, `isHasDataStatus` b9.5). Cũng khớp với
Android: F2 `0x20` tìm điện thoại, F6 `0x200` SMS, F5 `0x2000` danh bạ, F6 `0x40000` gọi điện, F1 `0x08/0x40/0x80`,
F4 `0x800`, F3 `0x8000`, F8 `0x20`. Bốn bit đang bật mà SDK iOS không đặt tên (`b2.6`, `b6.4`, `b7.0`, `b18.7`) đã được
ghi theo Android nếu có.
