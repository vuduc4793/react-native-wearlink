# Tổng hợp tính năng Y25 / HT43 / GE54 theo app gốc, và trạng thái SDK (21/10/2026)

> Chỉ đọc tài liệu và mã trong repo (nhánh `main`, RN `react-native-wearlink` **0.1.5**).
>
> **Ký hiệu ô thiết bị:** **Có** / **Không** / **?** (chưa chắc), kèm căn cứ ngắn: bit cờ (`b17.3` = byte 17 bit 3 của `33F1`;
> `34F1 b14.6`; Veepoo `A7.3 b7` = gói A7 số 3 byte 7, `B8.0 b4`, `AD`) hoặc mã app.
> **Ký hiệu cột SDK/RN:** **ĐK** = đã làm và đã kiểm trên máy thật · **CK** = đã làm, chưa kiểm trên máy (chỉ unit test / gói dựng) ·
> **CL** = chưa làm · **KAD** = không áp dụng. "A" = Android, "i" = iOS. RN = `SmartWear.*` trong `sdks/react-native/src/index.ts`.

---

## 1. Tóm tắt (10 dòng)

1. **Y25** (đồng hồ AMOLED tròn 466×466, GloryFit): HR, SpO2, huyết áp PPG, ngủ có REM, 50 môn, thông báo, gọi Bluetooth (HFP) + danh bạ 70, trả lời SMS nhanh, nhạc, camera, thời tiết 7 ngày, mặt đồng hồ, OTA Realtek.
2. **Y25 không có:** nhiệt độ, stress, HRV, ECG, đường huyết, SOS, đồng hồ thế giới, nhắc uống nước. Báo thức chỉ đặt được trên đồng hồ. Có chip GPS riêng hay không thì **chưa rõ** (cờ báo có, người dùng nói không).
3. **HT43** (đồng hồ GPS, GloryFitPro): giống Y25 nhưng **không có huyết áp**. **Có GNSS thật** và hỏi AGPS mỗi 60 s. Quảng bá liên tục. Thực tế không OTA được vì server UTE không phát firmware.
4. **GE54** (vòng không màn hình, G Band): mạnh về sức khoẻ: HR, SpO2, HA, nhiệt độ, stress, đường huyết, acid uric/mỡ máu, thành phần cơ thể, lịch sử HRV + RR, MET. Có 8 loại nhắc nhở, 10 báo thức có nhãn, thông báo 17 app + "khác", tìm vòng, camera.
5. **GE54 không có** (vì không màn hình hoặc cờ = 0): mặt đồng hồ, thời tiết, ngôn ngữ, danh bạ, gọi BT, GPS/AGPS, DND, chu kỳ phụ nữ, trả lời SMS. ECG là **?**.
6. **SDK đã có** gần đủ mọi tính năng BLE mà 3 máy bật cờ. RN 0.1.3–0.1.4 thêm `startHeartRateStream`, `workouts[].samples/track`, AGPS (không gọi server hãng). 0.1.5 thêm `getSportCatalog` (245 môn) + `getSportListLimits`.
7. **Đã kiểm trên máy:** GE54 Android gần như toàn bộ (19/10). Y25 một phần (HR, bước/kcal, HA lịch sử, thời tiết, danh bạ, HFP, tìm 2 chiều, mặt đồng hồ, lệnh bài tập, danh sách môn). HT43 ít (kết nối, mặt đồng hồ, thời tiết).
8. **Lỗ hổng lớn nhất là chưa kiểm** (code đã có): ngủ Y25/HT43; bài tập + đường GPS thật; thông báo, cuộc gọi, nhạc, SMS reply trên Y25/HT43; AGPS trên HT43. GE54 iOS chưa từng chạy trên iPhone.
9. **Chưa làm:** chợ mặt đồng hồ UTE, quãng đường/kcal của HT43, đồng bộ tăng dần + lưu quá 3 ngày (GE54), số liệu realtime bài tập GE54, nguồn file AGPS, OTA iOS, mặt-từ-ảnh iOS, đổi tên BT.
10. **Chỉ có trong app gốc, không qua BLE** (app mình phải tự làm): chạy bằng GPS điện thoại + bản đồ, kế hoạch tập, báo cáo tuần/tháng, Strava, Health Connect/Google Fit/Apple Health, WeChat/WeRun, AI, gia đình/chia sẻ, tài khoản/đám mây.

---

## 2. Bảng chính

### 2.1 Kết nối & ghép đôi

| Tính năng | Y25 (GloryFit) | HT43 (GloryFitPro) | GE54 (G Band) | SDK/RN |
|---|---|---|---|---|
| Nhận diện khi quét | Có: UUID `0x55xx` hoặc tên `Y25` | Có: UUID `0x55xx` | Có: mfr `F8F8` + tên (cắt 2 byte rác) | `startScan`, `onDiscovered`. **ĐK** cả 3 |
| Kiểu quảng bá | Từng đợt ~4–6 s mỗi lần đánh thức | Liên tục | Liên tục | `onScanState`; nối chờ `connect(id, true)`. **ĐK** |
| Kết nối, giữ kết nối, tự nối lại | Có (cần lệnh chờ `autoConnect`) | Có | Có | `connect`, `setKeepConnected`, `DeviceManager`. **ĐK** Y25 (A 19/10, i 15/10), HT43 (i 15/10); GE54: nối lại **CK** |
| Bind / mật khẩu | Không bind UTE (`b19.0` = 0); iOS hiện popup ghép đôi hệ thống; Android SDK tự bond | Không (`b19.0` = 0) | Mật khẩu `0000` trong `A1`; iOS xin bond qua `A1` byte 12 / `BC 01` | Tự động. GE54 iOS `runAction('notify.pair')` **CK** (Q9); `pairingPrompt`/`submitPairingCode` **KAD** cho 3 máy |
| MTU / kiểu ghi | maxLen 244; `34F1` chỉ nhận ghi không phản hồi | maxLen 244; `34F1` ? | MTU 247, ghi có phản hồi | Nội bộ driver (tự chuyển kiểu ghi). **ĐK** Y25, GE54 |
| Pin | Có (`A2`) | Có | Có (`A0`) | `refreshBattery`, `Device.battery`. **ĐK** ×3 |
| Đang sạc | Không (`34F1 b12.2` = 0) | Không | Có (`A0` byte 1, vòng tự đẩy) | `Device.charging`. **ĐK** GE54 |
| Firmware / model / phần cứng | Có firmware; model lấy từ tên (ra cả `Y25(ID-6E1B)`) | Như Y25 | Có firmware + device number 5980 + chip JieLi | `Device.firmware/model/hardware`. **ĐK**. Lỗi nhỏ: model UTE nên cắt ở `(` |
| Bảng cờ tính năng | `33F1` + `34F1` (78 bit bật) | 76 bit bật | `A7`×5, `AD`×2, `B8`×2 (58 cờ) | `Device.capabilities`, `Device.features`. **ĐK** |
| RSSI | Có | Có | Có | `Device.rssi`. **ĐK** |

### 2.2 Đo trực tiếp (đo tay)

| Tính năng | Y25 | HT43 | GE54 | SDK/RN |
|---|---|---|---|---|
| Nhịp tim (một lần) | Có `b17.3` | Có, nhưng **không trả lời `E5 11`**: chỉ có giá trị khi đo trên đồng hồ (`F7 03`) | Có `A7.1 b18` | `measure(id,'HEART_RATE')`, `onReading`. **ĐK** Y25 (84 bpm), GE54 (75–77); HT43 **CK** |
| Nhịp tim liên tục (khi chạy) | Có (lặp `E5 11`, ≥ 1 mẫu/25 s) | **Không**: HT43 chỉ tự đẩy HR theo chu kỳ, bỏ qua `E5 11` ⇒ từ 0.1.5 `features.heartRateStream = false` | Có (`D0` liên tục ~1 mẫu/s) | `startHeartRateStream`/`stopHeartRateStream`/`onHeartRate`, `features.heartRateStream` (0.1.3). **CK** cả 3 |
| SpO2 | Có `b7.6` | Có `b7.6` | Có `A7.1 b8` | `measure(id,'SPO2')`. **ĐK** GE54 (97–99 %); Y25/HT43 **CK** |
| Huyết áp (ước lượng PPG) | Có `b17.4` | **Không** (`b17.4` = 0, firmware chữ `H`) | Có `A7.1 b1` | `measure(id,'BLOOD_PRESSURE')`. **ĐK** GE54 (119/86); Y25 **CK** |
| Nhiệt độ | Không `b7.3` = 0 (firmware có driver nhưng tắt) | Không | Có `A7.3 b7` | `measure(id,'TEMPERATURE')`. **ĐK** GE54 (37,0 °C) |
| Stress | Không `b4.5` | Không | Có `A7.3 b18` | `measure(id,'STRESS')`. **ĐK** GE54 (21) |
| HRV đo tay | Không (`34F1 b10.5`) | Không | Không đo tay (chỉ có trong lịch sử; `89 07` cần kiểu 7/8) | **KAD** |
| ECG | Không `b12.5` | Không | **?** cờ `A7.2 b15` = 0B nhưng vòng không màn, chưa biết có điện cực | **CL** (Android bỏ capability, Swift vẫn báo `.ecg`: lệch) |
| Đường huyết | Không `34F1 b17.1` | Không | Có `A7.3 b15` (cần hiệu chuẩn) | `measure(id,'BLOOD_SUGAR')`. **ĐK** A (8,21 mmol/L); i **CK** |
| Acid uric + mỡ máu (TC/TG/HDL/LDL) | Không | Không | Có `A7.4 b1` | `measure(id,'URIC_ACID' / 'BLOOD_LIPIDS')`, `Reading.extra`. **ĐK** A |
| Thành phần cơ thể (BMI, mỡ, cơ, nước…) | Không | Không | Có `A7.4 b2` (chạm điện cực, cần hồ sơ thật) | `measure(id,'BODY_COMPOSITION')`. **ĐK** A (19/10 21:45) |
| Nhịp thở | Không `b6.6` | Không | Không `A7.2 b7` | **KAD** |
| MET tức thời | Không | Không | Không (`89 08` không trả lời; MET chỉ có trong lịch sử) | **KAD** |
| HR nghỉ, PAI | Không (`34F1 b19.1`, F12/F13 = 0) | Không | Không | **KAD** |

### 2.3 Đo tự động & cảnh báo

| Tính năng | Y25 | HT43 | GE54 | SDK/RN |
|---|---|---|---|---|
| HR tự động 24h | Có `b15.6`, chu kỳ chỉnh được (`F7 09`) | Có | Có `B8.0 b4`, chu kỳ cố định 5 phút | `setControl('hr24.interval')` (UTE), `'auto.hr'` (GE54). **CK**: lệnh đã được nhận, chưa đo hiệu quả |
| Khung giờ đo HR/SpO2 | Có (`F7 0F`, `34 04`; app gốc không dùng) | Có | Không (`A7.4 b12` = 0) | `setControl('hr24Range.range')`. **CK** |
| SpO2 tự động | Có (`34 03`) | Có | Có, luôn đo, không có công tắc | `setControl('spo2Auto.enabled')`. **CK** UTE; GE54 dữ liệu **ĐK** |
| HA tự động | Không `b9.4` | Không | Có `B8.0 b5` | `'auto.bp'`. **CK** (đọc được, chưa ghi) |
| Nhiệt độ / HRV / stress / đường huyết / thành phần máu tự động | Không | Không | Có (`B8.1 b4`, `B8.0 b12`, `B8.1 b9/b7/b11`) | `'auto.*'`. **CK** |
| Cảnh báo HR cao / thấp | Có `b19.7` / `b9.3` | Có | Có cao + thấp (`AC`) | `'hrHigh.value'`, `'hrLow.value'` (UTE), `'hrAlarm.*'` (GE54). Đọc GE54 **ĐK** (100/55); ghi + rung **CK** |
| Nhắc SpO2 thấp | Không | Không | Có `B8.0 b10` | `'alert.spo2Low'`. **CK** |
| Hiệu chuẩn HA / đường huyết / thành phần máu | Không | Không | Có (G Band "Health & Monitor") | `'calibrate.*'`. Đọc **ĐK**, ghi **CK** (chỉ unit test) |
| Phát hiện ngã, "giấc ngủ khoa học" | Không | Không | Ngã: Không (`B8`). "Scientific Sleep" = ngủ chính xác (có) | **KAD** |

### 2.4 Lịch sử / đồng bộ

| Tính năng | Y25 | HT43 | GE54 | SDK/RN |
|---|---|---|---|---|
| Bước theo giờ / ngày | Có (CyWee `EB 02`) | Có (`B2 FA`, tách chạy/đi `b18.0`) | Có (`DF` 5 phút, vòng giữ **3 ngày**) | `syncHistory` → `series.STEPS`, `getHistory`. **ĐK** Y25, GE54 (564 bản ghi); HT43 **CK** |
| Quãng đường / kcal hôm nay | Có | Có (`b15.4`, `b8.6`) | Có (`D8`) | `DeviceHistory.today`. **ĐK** Y25 (132 bước / 9,5 kcal), GE54; **HT43: CL** (`parseSteps` chỉ đọc bước) |
| Ngủ (giai đoạn, REM, ngủ trưa) | Có REM `b1.3`, ngủ rải rác `34F1 b19.5` | Có REM; không ngủ rải rác | Có REM (`E0`); ngủ trưa không tách riêng | `DeviceHistory.sleep`. **ĐK** GE54 (17–18/10); **Y25/HT43 CK** (chưa có gói thật) |
| HR | Có | Có | Có (`DF` tag `B4`) | `series.HEART_RATE`. **ĐK** Y25, GE54; HT43 **CK** |
| SpO2 | Có | Có | Có | `series.SPO2`. **ĐK** GE54; Y25/HT43 **CK** |
| Huyết áp | Có | Không | Có | `series.BLOOD_PRESSURE`. **ĐK** Y25 (122/72), GE54 |
| Nhiệt độ | Không | Không | Có (`DF` tag `C3`) | `series.TEMPERATURE`. **ĐK** |
| Stress, HRV + RR (Lorenz) | Không | Không | Có | `series.STRESS`, `series.HRV` (`extra.rr*`). **ĐK** |
| MET | Không | Không | Có (`DF` tag `BF`) | `series.MET`. **ĐK** |
| Acid uric, mỡ máu | Không | Không | Có (`DF` tag `C2`) | `series.URIC_ACID`, `series.BLOOD_LIPIDS`. **ĐK** |
| Chu kỳ phụ nữ (lịch sử) | Không (`34F1 b12.5`) | Không | Không (`A7.1 b12`) | **KAD** |
| Bơi chi tiết (sải, SWOLF, kiểu bơi) | Có `34F1 b15.1` (`4A FA`) | Không | Không | **CL** |
| Đồng bộ tăng dần (từ mốc / vị trí) | Có `b9.5` (`33F3` + mốc thời gian) | Có | Có, theo vị trí gói (`DF`/`E0` pos) | UTE: sau cờ debug, **CK**; GE54 luôn đọc lại cả 3 ngày, **CL**. RN chỉ có `syncHistory(id, days)`, không có tham số mốc |
| Lưu lịch sử lâu dài | ? (chưa biết đồng hồ giữ bao nhiêu ngày) | ? | Vòng chỉ giữ 3 ngày | `getHistory` chỉ là bộ đệm lần cuối ⇒ app phải tự lưu. **CL** (phía app) |

### 2.5 Bài tập & GPS

| Tính năng | Y25 | HT43 | GE54 | SDK/RN |
|---|---|---|---|---|
| Bản ghi bài tập trên thiết bị (tổng: môn, giờ, bước, kcal, m, HR avg/max/min, pace) | Có `b13.0`, `b5.2` | Có | Có 3 khe (`D3`/`D4` TLV) | `DeviceHistory.workouts`. **ĐK** GE54 A (3 bài 19/10); GE54 i **CK** (đã thêm TLV); **Y25/HT43 CK** (bài 19/10 chưa đồng bộ về) |
| Chi tiết: mẫu HR/pace/cadence, vùng HR, sải bước | Có (F7 `0x80`) | Có | Không (chỉ tổng) | `workouts[].samples`, `heartRateZoneSeconds`, `avg/max/minStrideCm` (0.1.4). **CK** (giải mã theo mã app + gói dựng) |
| Đường GPS do đồng hồ tự ghi | **?** cờ `b1.7` + firmware có driver CC1165W, chưa thấy tự xin AGPS | **Có** (GNSS thật) | Không (`A7.3 b10` = 0) | `workouts[].track` (0.1.4). **CK**: cần một bài chạy ngoài trời thật |
| Bắt đầu / tạm dừng / tiếp / dừng từ điện thoại | Có `b7.1` | Có | Có `A7.4 b13` (`DA`) | `startWorkout`, `pauseWorkout`, `resumeWorkout`, `stopWorkout`, `features.workoutControl`. **ĐK** Y25 (4 lệnh ack 19/10); HT43 **CK**; GE54 A **CK**, **i CL** |
| Số liệu realtime khi tập | Có theo mã app (bố cục 14 B chưa xác nhận) | Có | Có (`DA 03` TLV) | `onWorkoutEvent`. UTE **CK** (gói thật 19/10 không hợp lệ); GE54 **CL** (chưa parse `DA 03`) |
| GPS điện thoại cho đồng hồ (đồng hồ xin, app gửi `FD 02`) | Có `b1.7` | Có | Không | `onLocationRequest`, `sendLocation`, `features.phoneLocation`. **CK** (chưa thấy `FD 01 AA`); không có UI, không lưu đường |
| Danh sách môn trên thiết bị (chọn, ẩn, sắp xếp) | Có `b3.5` + 20 bit môn; đồng hồ giữ **50 môn**, hiện 4..50 | Có (chưa đọc `FD 48 AA`) | Không (Veepoo không có bảng môn) | `getSportTypes` **ĐK** Y25; `setSportList` **CK** (chưa ghi thử); 0.1.5: `getSportListLimits` (**đang làm**) |
| Danh mục "100+ môn" của app | Chỉ là bảng tên trong app (GloryFit 115 tên); đồng hồ không nhận môn ngoài 50 môn của nó | GloryFitPro: 245 ID | KAD | 0.1.5: `getSportCatalog` 245 tên VI/EN, `getSportListLimits` **CK** |
| AGPS (dữ liệu vệ tinh) | Có cờ `34F1 b14.6`, chưa thấy tự xin | **Có**, xin `01 E9 AC 03` mỗi 60 s ("AGPS has expired") | Không (`A7.3 b9` = 0) | `getAgpsStatus`, `sendAgpsPosition`, `uploadAgpsFiles`, `setAgpsFiles`, `onAgpsRequest`, `features.agps` (0.1.4). **CK**. Không có nguồn file: server UTE cần khoá của app hãng |
| Mục tiêu theo bài tập, độ cao, tự nhận diện môn | Không (`b3.7`, `34F1 b12.6` = 0) | Không | ? (không thấy trong G Band) | **KAD** |

### 2.6 Thông báo, cuộc gọi, SMS, nhạc, danh bạ, camera, tìm điện thoại

| Tính năng | Y25 | HT43 | GE54 | SDK/RN |
|---|---|---|---|---|
| Thông báo app (Android) | Có `b16.6`, `b12.3`; UCS-2, 240 B, icon động `DB AA` | Có | Có `AD`: 17 app + "khác" (Zalo đi dạng "khác") | `setPhoneLinkConfig({apps})`, `sendNotification`, `getNotificationApps`. **ĐK** GE54 (gửi tay 19/10); chạy nền thật **CK**; Y25/HT43 **CK** |
| Thông báo iOS (ANCS) | Có `b6.3` | Có | Có (sau khi vòng xin bond) | Hệ thống tự gửi; `features.ancsAuthorized`. Y25 **ĐK** cấp quyền (16/10), hiển thị chưa ghi nhận; HT43 **CK**; GE54 **CK** (Q9) |
| SMS | Có (+ tên người gửi `C6`) | Có | Có (`AD` byte 3) | `sendSms`, `PhoneLinkConfig.sms`. **ĐK** GE54; Y25/HT43 **CK** |
| Cuộc gọi đến (Android) | Có | Có | Có | `notifyIncomingCall`, `notifyCallEnded`. **ĐK** GE54; Y25/HT43 **CK** |
| Từ chối cuộc gọi trên thiết bị | Có `b17.6` (`D1 02`) | Có | Có theo mã app (`C1 02`) | `onRejectCall`. **CK** ×3 |
| Tắt tiếng / trả lời từ thiết bị | ? (`D1 12`, chưa rõ bit) | ? | ? (`C1 03/04` theo mã app) | **CL** |
| Trả lời SMS nhanh (Android) | Có `b3.1` | Có | Không (không có lệnh) | `getSmsReply`, `setSmsReply`, `onSmsReplyRequest`, `sendSmsReplyResult`. **CK**; iOS **KAD** |
| Danh bạ lên đồng hồ | Có, tối đa 70, tên 20 ký tự, xoá hết | Có | Không (`A7.3 b4` = 0) | `syncContacts`, `clearContacts`, `features.maxContacts`. **ĐK** Y25 (gửi 15/10); xoá + HT43 **CK** |
| Gọi điện qua đồng hồ (HFP), Siri/Google | Có `b2.2` | Có | Không (không loa/mic) | `getCallBluetoothState`, `pairCallBluetooth`, `setCallBluetooth`. **ĐK** Y25 iOS 15/10; HT43 **CK** |
| SOS | Không (`b1.1`, `b14.7`) | Không | Không | `onDeviceEvent` vẫn nghe. **KAD** |
| Điều khiển nhạc điện thoại | Có (F5 `0x1`) | Có | Có giao thức `99`, nhưng `B8.0 b18` = 0 ⇒ **?** vòng có phím nhạc | `onMusicCommand`, `setMusicVolume`, `features.musicControl`. **CK** (iOS chỉ điều khiển trình phát của chính app) |
| Tên bài hát trên thiết bị | Có (F5 `0x1000`) | Có | **?** (vòng không màn; `99 01` được ack) | `setMusicState`, `features.trackInfo`. GE54 lệnh **ĐK**; Y25/HT43 **CK** |
| Chụp ảnh từ xa | Có (`C4`, không cần cờ) | Có | Có `A7.1 b6` | `setRemoteCamera`, `onRemoteCamera`. GE54 mở màn **ĐK**, nút chụp **CK**; Y25/HT43 **CK** |
| Tìm thiết bị (rung) | Có | Có | Có `A7.3 b8` | `runAction(id,'find.start'/'find.stop')`. **ĐK** ×3 |
| Thiết bị tìm điện thoại | Có `b16.5` | Có | Không theo cờ (`A1` byte 18 = 0); driver vẫn nghe `B5 00` | `onFindPhone`, `setPhoneRinging`. **ĐK** Y25 (16/10, iPhone đổ chuông); HT43 **CK** |
| Nút / sự kiện thiết bị | Có (`D1 01/04/06`) | Có | ? (không màn) | `onDeviceEvent`. **CK** |
| Chống thất lạc / nhắc mất kết nối | Chỉ là phím tắt trên đồng hồ (`BE` `0x100000`), app không đặt (`b16.2` = 0) | như Y25 | Không (`B8`) | **KAD** |

### 2.7 Cài đặt thiết bị

| Tính năng | Y25 | HT43 | GE54 | SDK/RN |
|---|---|---|---|---|
| Giờ | Có (`A3`, tự đặt khi nối) | Có | Có (`A1`, kèm múi giờ 15 phút) | Tự động. **ĐK** ×3. Byte múi giờ của UTE: sau cờ debug, **CK** |
| Múi giờ / đồng hồ thế giới | Không (`b4.4` = 0) | Không | Không (`A7.4 b3` = 0) | **KAD** |
| 12/24h | Có | Có | Có `B8.0 b3` | `setControl('unit.hour12'/'unit.hour24')`. **ĐK** GE54 (ghi + đọc lại); Y25/HT43 **CK** (lệnh nhận, hiển thị chưa kiểm) |
| Đơn vị km/mile, °C/°F | Có (°C/°F `b12.4`; SDK để cố định metric) | Có | Có (+ đơn vị đường huyết/uric/mỡ máu `B8.1`) | `'unit.*'`. **CK**; đơn vị đường huyết/uric/mỡ máu GE54 **CL** |
| Ngôn ngữ thiết bị | Có (đọc + đặt, có tiếng Việt) | Có | Không (không màn) | `setControl('language')`. Đọc Y25 **ĐK** (English); đặt **CK** |
| Hồ sơ cơ thể | Có (`A9`) | Có | Có (`A3`) | `'profile.*'`. **ĐK** ×3 (lệnh được nhận) |
| Mục tiêu | Bước/kcal/m (`b5.5`, `3F`) | Có | Bước + giờ ngủ (`A3`); không có mục tiêu m/kcal | `'goal.*'`. `A9`/`A3` **ĐK**; `3F` **CK** |
| Nâng tay sáng màn | Có `b19.6` (lịch theo giờ chỉ SDK) | Có | Không | `'display.raise'`. **CK** |
| Thời gian sáng màn / độ sáng | Thời gian: Có (5–30 s). Độ sáng: Không (không có lệnh) | như Y25 | Không | `'display.screenOff'`. **CK** |
| Không làm phiền | Có `b19.3` (kèm bit tự từ chối cuộc gọi) | Có | Không (Veepoo không có lệnh) | `'dnd.*'`. **CK** (đồng hồ không trả lời, không đọc lại được) |
| Nhắc ngồi lâu | Có `b17.0` + khung giờ | Có | Có (`E7` loại 1) | `'sedentary.*'` / `'remind.sedentary.*'`. GE54 đọc **ĐK**; Y25/HT43 **CK** |
| Nhắc uống nước | Không `b5.3` | Không | Có (`E7` loại 2) | `'remind.drink.*'`. **ĐK** GE54 (ghi + đọc lại) |
| Nhắc nhìn xa / vận động / uống thuốc / đọc sách / ra ngoài / rửa tay | Không | Không | Có (`E7` loại 3–8) | `'remind.<loại>.*'`. **ĐK** GE54 |
| Báo thức | Chỉ đặt trên đồng hồ (`b2.1` = 0; `AB` không vào danh sách, thử 15/10) | như Y25 | Có, 10 cái có nhãn (`B9`, CRC) | `getAlarms`, `setAlarm`, `deleteAlarm`, `features.alarms/maxAlarms`. **ĐK** GE54 A (thêm/xoá 19/10); i **CK**; UTE **KAD** |
| Chu kỳ phụ nữ (cài đặt) | Có `b12.7` | Có | Không (`A7.1 b12` = 0) | `'period.*'`. **CK** |
| Phím tắt nhanh | Có `b8.0` (chỉ đọc) | Có | Không | `getControls` (`shortcut.*`, chỉ đọc). **ĐK** Y25 (`0x980000`) |
| Sắp xếp menu | Không `b3.6` | Không | Không | **KAD** |
| Thời tiết | Có 7 ngày + độ ẩm/UV (`b18.5`, `b3.3`) | Có | Không (`A7.2 b9` = 0) | `setWeather`, `fetchOpenMeteoForecast`. **ĐK** Y25, HT43 (15/10). Tên thành phố hiện chưa đúng |
| Khôi phục gốc / xoá dữ liệu | Có (`AD`) | Có | Có (`FF 55 01 73 40`) | `runAction('data.reset')` + xác nhận. **CK** (chưa chạy, cần người dùng đồng ý) |
| Tắt máy / khởi động lại | Không (`b13.3`, `b3.4`) | Không | Tắt máy: Có (`F2 04`) | `runAction('device.powerOff')`. **CK** |
| Đổi tên Bluetooth | ? (`b9.6` bật, chưa tìm thấy lệnh) | ? | ? (lệnh `84` có trong SDK Veepoo, G Band không có màn) | **CL** |

### 2.8 Mặt đồng hồ

| Tính năng | Y25 | HT43 | GE54 | SDK/RN |
|---|---|---|---|---|
| Kiểu màn hình | Tròn 466×466, tối đa 1 MB, 1 khe | Như Y25 | Không có màn hình | `getWatchFaceInfo`. **ĐK** Y25, HT43 |
| Cài mặt `.bin` | Có `b12.0` | Có | Không | `installWatchFace`, `onTransferProgress`. **ĐK** Y25 (13/10), HT43 (14/10, 1 MB / 2′45″) |
| Mặt từ ảnh (custom dial) | Có | Có | Không | `setWatchFaceImage`. **ĐK** A (Y25 13/10); **i CL** (chưa có renderer) |
| Khe mặt đã cài (xem/xoá) | Có `b12.0` | Có | Không | `getWatchFaceSlots`, `deleteWatchFaceSlot`. **CK** |
| Chợ mặt đồng hồ (server UTE) | Có trong app | Có trong app | Không (G Band có chợ, nhưng GE54 0 mặt) | **CL** (cần client server UTE + đồng ý pháp lý) |
| Mặt AI, widget, đổi mặt cài sẵn, mặt video | Không (F10 `0x4` = 0, `34F1 b19.4` = 0) | Không | Không | **KAD** |

### 2.9 Firmware / OTA

| Tính năng | Y25 | HT43 | GE54 | SDK/RN |
|---|---|---|---|---|
| Cập nhật firmware chính hãng | Có (Realtek DFU `b0.3`, image ký ECDSA UTE; server UTE có phát) | Giao thức có, nhưng **server UTE không phát firmware HT43** ⇒ thực tế Không | Có trong app (JieLi RCSP `.ufw`, cần `libjl_auth.so`, server Veepoo) | `checkFirmware`, `updateFirmware`, `cancelFirmwareUpdate`, `features.firmwareUpdate` (chỉ A, chỉ Y25). Đọc thử **ĐK** (19/10), nạp thật **CK** (cần đồng ý); iOS **CL**; HT43 chặn; GE54 **không làm** (chính sách) |

### 2.10 Tính năng chỉ có trong app (không qua Bluetooth)

Các mục dưới đây app gốc làm trên điện thoại / server. SDK không cần lệnh mới; app mình phải tự làm nếu muốn.

| Tính năng | GloryFit (Y25) | GloryFitPro (HT43) | G Band (GE54) | SDK/RN |
|---|---|---|---|---|
| Tài khoản, đăng nhập, đám mây | Có | Có (email + mã) | Có (Log In) | **KAD** (app) |
| Màn chính dạng thẻ, chỉnh thẻ | Có | Có (Edit card) | Có (thẻ theo cờ) | Dữ liệu từ `syncHistory`. **KAD** |
| Chạy / đi bộ / đạp xe / bơi bằng GPS điện thoại + bản đồ | Có (Outdoor running/cycle, Swimming) | Có (Outdoor run/walk/cycle, Pool swimming; Google Map) | Có ("App Workout", AMap/Google) | SDK chỉ cấp nhịp tim (`startHeartRateStream`); app tự ghi GPS + lưu + vẽ. **CL** (phía app) |
| Lịch sử bài tập + chia sẻ | Có | Có (`SportShared`) | Có | **KAD** (app) |
| Kế hoạch tập luyện | Có, chỉ trên điện thoại (`TrainSet…`, không gửi BLE) | Có màn "Training schedule"; kế hoạch gửi xuống đồng hồ chỉ cho đồng hồ JieLi (`RkSupportUtils:564`) ⇒ không cho HT43 | Không thấy | **KAD** (app) |
| Báo cáo tuần / tháng, thống kê | ? (không thấy trong ảnh màn đã chụp) | Có ("Weekly exercise", `WeekReport`, `HealthReport`) | Có (ngày/tuần/tháng mỗi chỉ số) | **KAD** (app) |
| Phân tích sâu: OSAHS/ngưng thở từ SpO2, Lorenz HRV, báo cáo ECG | Không | Không | Có (app tính từ dữ liệu; ECG phụ thuộc phần cứng **?**) | Dữ liệu SpO2/HRV+RR có trong `series`. **KAD** |
| Strava | Có | Có | Có | **KAD** (app + OAuth) |
| Health Connect / Google Fit / Apple Health | Có (Google Fit, Health Connect) | Có (Health Connect) | Có (Health Connect; iOS Apple Health) | **KAD** (app) |
| WeChat Sports / QQ Health / WeRun, bạn bè, PK xếp hạng | Có | Có (WeChat) | Có (WeRun) | **KAD** (Trung Quốc) |
| AI: mặt đồng hồ AI, AI agent/ChatGPT, phân tích AI | Có mặt AI (server); không áp dụng cho Y25 | Có màn, nhưng chỉ cho đồng hồ JieLi | Có "AI Analysis" (LLM qua server) | **KAD** |
| Gia đình, chia sẻ sức khoẻ, bảo vệ an toàn (vị trí) | Không thấy | Không thấy | Có (Health sharing, Family guardianship) | **KAD** |
| Alipay / QR / Tmall Genie / cầu nguyện / trò chơi / bản đồ offline | Không | Có màn, nhưng cờ tắt hoặc chỉ cho JieLi | Không | **KAD** |
| Quyền chạy nền, FAQ, phản hồi | Có | Có | Có | **KAD** |

---

## 3. App gốc có mà SDK chưa có / chưa kiểm (xếp ưu tiên)

Công sức: một người, có máy thật; "+ máy" = cần người dùng thao tác / đeo / ra ngoài trời.

| # | Việc | Máy | Loại | Công |
|---|---|---|---|---|
| **P0** | | | | |
| 1 | Kiểm ngủ (`EC 01` Y25, `31 01` HT43), bước + HR + SpO2 trên HT43, so số với app gốc cùng ngày | Y25, HT43 | Chưa kiểm | 0,5 ngày + máy (sau 1 đêm đeo) |
| 2 | Quãng đường/kcal HT43 từ gói `B2` mở rộng (cần log gói thật) | HT43 | Chưa làm | 0,5–1 ngày |
| 3 | Thông báo / cuộc gọi / từ chối / nhạc / SMS reply chạy nền thật trên Android (tiếng Việt có dấu, Zalo, Messenger) | Y25, HT43 (GE54 chỉ còn chạy nền + từ chối) | Chưa kiểm | 1–2 ngày |
| 4 | Bài chạy ngoài trời thật: đồng bộ `FD FA` có `workoutPackets`, đối chiếu `samples/track`; kiểm 2 phút Y25 có GNSS không | HT43, Y25 | Chưa kiểm | 1 ngày + máy |
| 5 | Driver GE54 trên iPhone thật: bond/ANCS (Q9), đo, lịch sử, báo thức, hiệu chuẩn | GE54 | Chưa kiểm | 1–2 ngày |
| 6 | Nhịp tim liên tục: kiểm trên 3 máy; HT43 có thể lỗi vì bỏ qua `E5 11` ⇒ cần đường dự phòng (`F7 09` chu kỳ ngắn / giá trị đẩy) | ×3 | Chưa kiểm / có thể sai | 0,5–1 ngày |
| **P1** | | | | |
| 7 | Đồng bộ tăng dần + tham số mốc trong RN (`syncHistory(id, {since})`); GE54 đọc tiếp theo vị trí gói; app lưu lịch sử quá 3 ngày | ×3 | Chưa làm | 2–3 ngày |
| 8 | Màn "chạy bằng GPS điện thoại" trong app: GPS + `startHeartRateStream` + lưu + bản đồ; trả lời `FD 01 AA` bằng `sendLocation` khi đồng hồ xin | app; Y25/HT43 | Chưa làm (phía app) | 2–3 ngày |
| 9 | Danh mục 245 môn + giới hạn + UI chọn/sắp xếp môn + ghi thử `setSportList` (0.1.5) | Y25, HT43 | Đã làm 0.1.5 (còn ghi thử `setSportList` trên máy) | 0,5 ngày |
| 10 | AGPS: nguồn file hợp lệ (thoả thuận UTE hoặc nhà cung cấp GNSS), kiểm HT43 thôi hỏi khi trả `st = 5`, gửi vị trí | HT43 (Y25 nếu có GNSS) | Chưa kiểm + thiếu nguồn | 1 ngày kỹ thuật + quyết định pháp lý |
| 11 | GE54: parse số liệu realtime `DA 03`, thử `DA` bắt đầu/dừng, thêm điều khiển bài tập trên iOS | GE54 | Chưa làm | 1 ngày |
| 12 | Khe mặt đồng hồ: UI + kiểm `26 09`/`26 08` | Y25, HT43 | Chưa kiểm | 0,5 ngày |
| 13 | Chợ mặt đồng hồ UTE (client server, tải `.bin`, cài) | Y25, HT43 | Chưa làm | 2–4 ngày + đồng ý pháp lý |
| **P2** | | | | |
| 14 | Mặt đồng hồ từ ảnh trên iOS (renderer CoreGraphics) | Y25, HT43 | Chưa làm | ≥ 1 tuần |
| 15 | OTA: nạp thật trên Android (có đồng ý); OTA iOS | Y25 | Chưa kiểm / chưa làm | A 0,5 ngày; iOS ≥ 1 tuần |
| 16 | Bơi chi tiết CyWee `4A FA` | Y25 | Chưa làm | 0,5 ngày + bơi thật |
| 17 | Tắt tiếng / trả lời cuộc gọi từ thiết bị (`D1 12`, `C1 03/04`) | ×3 | Chưa làm | 0,5 ngày |
| 18 | Đổi tên Bluetooth (tìm lệnh UTE trong SDK iOS gốc; thử `84` Veepoo) | ×3 | Chưa làm | 0,5–1 ngày nghiên cứu |
| 19 | Control đơn vị đường huyết/acid uric/mỡ máu; ghi thử công tắc đo tự động `B8`, cảnh báo `AC` + rung | GE54 | Chưa làm / chưa kiểm | 0,5 ngày |
| 20 | Lịch nâng tay theo giờ (`69 AB`), byte múi giờ `A3`, tên thành phố thời tiết, cắt model ở `(` | Y25, HT43 | Chưa kiểm / lỗi nhỏ | 0,5 ngày |
| 21 | Thống nhất ECG GE54 (Android bỏ, Swift báo `.ecg`) | GE54 | Lệch | 0,1 ngày |
| 22 | Tích hợp ngoài (phía app): Health Connect / Apple Health (2–3 ngày), Strava (2–3 ngày + OAuth), báo cáo tuần (2–3 ngày), kế hoạch tập (3–5 ngày) | app | Chưa làm | như ghi |

---

## 4. App gốc có nói tới nhưng máy KHÔNG có (để khỏi kỳ vọng sai)

**Y25 và HT43** (cờ = 0 hoặc chỉ dành cho đồng hồ JieLi):
- Stress/mood (`b4.5`), HRV (`34F1 b10.5`), ECG (`b12.5`), đường huyết (`34F1 b17.1`), nhịp thở (`b6.6`), HR nghỉ, PAI.
- Nhiệt độ (`b7.3`): firmware có driver nhưng bị tắt.
- **HT43 không có huyết áp** (`b17.4` = 0). Y25 có nhưng chỉ là ước lượng PPG.
- Nhắc uống nước/rửa tay, đồng hồ thế giới/múi giờ, SOS, sắp xếp menu, tiết kiệm pin, chống thất lạc từ app.
- Báo thức đặt từ app: đồng hồ không nhận. Độ sáng màn từ app: không có lệnh. Tắt máy / khởi động lại từ app: không có.
- "100+ môn": đồng hồ chỉ giữ 50 môn. 115/245 môn chỉ là bảng tên trong app.
- Mục tiêu theo bài tập, độ cao/khí áp: không có cờ. Firmware có chuỗi la bàn/khí áp nhưng không có driver.
- Nhạc lưu trên đồng hồ, ghi âm, AI agent/ChatGPT/dịch, mặt AI, bản đồ offline, kế hoạch tập gửi xuống đồng hồ, cầu nguyện, trò chơi, sách, NFC, Alipay/WeChat Pay/QR, 4G.
- Lịch sử chu kỳ phụ nữ: chỉ có cài đặt, không đọc được lịch sử.
- **Y25 có chip GPS riêng hay không: chưa chắc.** Cờ và firmware nói có. Người dùng nói không, và chưa thấy Y25 xin AGPS.
- OTA HT43: không có image chính hãng.

**GE54** (vòng không màn hình):
- Mặt đồng hồ, thời tiết, ngôn ngữ, nâng tay/thời gian sáng/độ sáng màn, menu, tên bài hát trên vòng (lệnh được nhận nhưng không có màn để hiện).
- Danh bạ, gọi Bluetooth, trả lời SMS, SOS, GPS/AGPS (G Band có mục "GPS Ephemeris", nhưng cờ = 0), đồng hồ thế giới, DND, chu kỳ phụ nữ, nhịp thở, GSR, phát hiện ngã, đếm ngược.
- Tìm điện thoại từ vòng: cờ = 0. Phím nhạc trên vòng: `B8.0 b18` = 0, **?** chưa thử.
- Đo HRV / MET tức thời: không có. HRV và MET chỉ có trong lịch sử.
- ECG: **?** (cờ có nhưng chưa chắc có điện cực). Báo cáo ECG/PTT của G Band đừng coi là có.
- Danh sách môn trên vòng: không có (chỉ có 3 khe bản ghi).
- Zalo không có icon riêng: hiện dạng "khác".
- Vòng chỉ giữ 3 ngày lịch sử.
- Đường huyết, acid uric, mỡ máu, thành phần cơ thể, HA là **ước lượng PPG / điện cực, phụ thuộc hiệu chuẩn và hồ sơ**, không phải số y tế. Chế độ "hiệu chuẩn riêng" từng cho số sai bám giá trị hiệu chuẩn (19/10).
- AI Analysis, Family/Care, bảo vệ an toàn là dịch vụ server của Veepoo, không phải tính năng của vòng.

---

## 5. Nguồn

- `docs/devices/README.md`, `docs/devices/y25.md`, `docs/devices/ht43.md`, `docs/devices/ge54.md` (19/10, có chỉnh 21/10)
- `docs/feature-matrix.md` (15/10, cũ hơn các file thiết bị)
- `sdks/gloryfit/docs/10-y25-feature-audit.md` (§0, §2.4–§2.9, §3–§4)
- `sdks/veepoo/docs/02-features.md` (màn G Band, cờ, driver iOS)
- `sdks/react-native/src/index.ts`, `sdks/react-native/src/types.ts` (`DeviceFeatures`), `sdks/react-native/docs/huong-dan-su-dung.md` §7–§11
- Mã: `sdks/gloryfit/android/.../GloryFitDriver.kt` (`supportsHeartRateStream` :578, `heartRateStream` :586, `supportsFirmwareUpdate` :1510, `supportsAgps` :1784), `Ute.kt` (`parseSteps` :418), `sdks/veepoo/android/.../VeepooDriver.kt` (:417–425, :819), `sdks/veepoo/ios/Sources/SmartWearVeepoo/` (`VeepooAlarm.swift`, `VeepooCalibration.swift`, `VeepooControls.swift`, `VeepooSync.swift:79`)
- Màn app gốc: `sdks/gloryfit/research/screens/gf-*.all|txt` (GloryFit 4.0.12 + Y25), `gfp-*` (GloryFitPro 1.9.0.2); `sdks/veepoo/research/screens/gband-*` (G Band 2.3.12 + GE54)
- Danh sách màn GloryFitPro: `sdks/gloryfit/research/xapk-pro/jadx-out/sources/com/yc/gloryfitpro/ui/activity/main/{home,sport,mine,device}/*Activity.java`
- Chuỗi app: `sdks/gloryfit/research/jadx-out/resources/res/values/strings.xml` (Strava, Google Fit, Health Connect, WeChat, PK, Training Plan, AI dial); `sdks/veepoo/research/android-gplusband-2.3.12/jadx-out/resources/res/values/strings.xml` (Strava, WeRun, Health Connect, Apple Health, Family, AI Analysis)
