# react-native-wearlink

TurboModule (React Native kiến trúc mới, RN ≥ 0.76) bọc SmartWear SDK:

| Driver | Thiết bị đã thử | Có gì |
|---|---|---|
| `gloryfit` | Y25 (đồng hồ), HT43 | Đo HR, SpO2, huyết áp; lịch sử + bài tập; cài đặt; thời tiết; danh bạ; gọi điện qua đồng hồ; mặt đồng hồ; firmware |
| `veepoo` | GE54 (vòng tay G Band) | Đo HR, SpO2, huyết áp, nhiệt độ, stress, đường huyết, acid uric + mỡ máu, thành phần cơ thể; lịch sử; báo thức; cài đặt |
| `qring` | R09 (nhẫn), DS500 / HS500A (vòng) | Đo HR, SpO2, nhiệt độ, căng thẳng, HRV; lịch sử; cài đặt đọc lại được |
| `standard` | Thiết bị Bluetooth chuẩn (HR, pin) | Đo nhịp tim |

**Tài liệu:**
- [Hướng dẫn sử dụng](https://github.com/vuduc4793/react-native-wearlink/blob/main/sdks/react-native/docs/huong-dan-su-dung.md)
- [Lỗi thường gặp](https://github.com/vuduc4793/react-native-wearlink/blob/main/sdks/react-native/docs/loi-thuong-gap.md)
- [Báo lỗi](https://github.com/vuduc4793/react-native-wearlink/blob/main/sdks/react-native/docs/bao-loi.md)

Mã native gọi thẳng SDK trong repo: Kotlin `sdks/*/android`, Swift `sdks/*/ios`. Thư viện không chứa logic giao thức
riêng, nên Android, iOS và thư viện RN luôn chạy cùng một mã SDK.

## Cài vào app React Native thuần

```sh
npm install react-native-wearlink                                  # từ npm (gói đã kèm mã SDK trong vendor/sdks)
# hoặc từ repo (dev):
npm install file:<đường-dẫn>/smart-wear-sdk/sdks/react-native
```

Gói npm được `prepack` (`scripts/vendor.js`) chép sẵn mã SDK Kotlin + Swift + podspec vào `vendor/sdks/`; Android tự dùng nó,
iOS khai báo pod từ đó (dưới). Cài từ repo thì dùng thẳng `sdks/`.

### iOS

1. `ios/Podfile`: iOS 15.1 trở lên (mức tối thiểu của React Native) và 5 pod SDK:

   ```ruby
   platform :ios, min_ios_version_supported   # 15.1

   target 'YourApp' do
     config = use_native_modules!
     sdks = '../node_modules/react-native-wearlink/vendor/sdks'   # cài từ repo: '<đường-dẫn>/smart-wear-sdk/sdks'
     pod 'SmartWearCore', :path => sdks
     pod 'SmartWearQRing', :path => sdks
     pod 'SmartWearGloryFit', :path => sdks
     pod 'SmartWearStandard', :path => sdks
     pod 'SmartWearVeepoo', :path => sdks
     # ...
   ```

2. iOS Deployment Target của target app ≥ **15.1** (từ bản 0.1.1; bản 0.1.0 cần 17.0).
3. `Info.plist`:
   - `NSBluetoothAlwaysUsageDescription`: lý do dùng Bluetooth.
   - `UIBackgroundModes` = `bluetooth-central`, để giữ kết nối và tự nối lại khi app chạy nền.
4. `cd ios && pod install`.

### Android

Không cần khai báo thêm module Gradle: thư viện biên dịch kèm mã SDK. Chỉ cần:

- `minSdkVersion` ≥ 26.
- Quyền Bluetooth đã có sẵn trong manifest của thư viện. App phải **xin quyền lúc chạy**: `BLUETOOTH_SCAN` +
  `BLUETOOTH_CONNECT` từ Android 12 trở lên, `ACCESS_FINE_LOCATION` cho Android 11 trở xuống. Xem `example/App.tsx`.
- Manifest thư viện chỉ có Bluetooth + foreground service giữ kết nối; `bluetooth_le` là `required="false"`. Cầu nối điện
  thoại (`READ_PHONE_STATE`, dịch vụ đọc thông báo, SMS, cuộc gọi) app tự khai báo khi dùng, xem
  [hướng dẫn §3](docs/huong-dan-su-dung.md#android).
- App cập nhật JS qua OTA: kiểm `SmartWear.isAvailable` trước khi gọi (false khi binary chưa có module native).
- App đã có foreground service riêng (vd vị trí lúc chạy bộ): gọi `setForegroundService(false)` trong lúc dịch vụ đó chạy để
  chỉ còn một thông báo; kết nối BLE vẫn sống vì nằm trong tiến trình app. Xem [hướng dẫn §7](docs/huong-dan-su-dung.md#nhịp-tim-liên-tục-khi-chạy-từ-013).

## Dùng

```ts
import SmartWear, {fetchOpenMeteoForecast} from 'react-native-wearlink';

SmartWear.start();                                   // gọi 1 lần: dựng lại thiết bị đã lưu, tự nối lại cái đang giữ
const subs = [
  SmartWear.onDiscovered(list => setFound(list)),    // kết quả quét
  SmartWear.onDevicesChanged(list => setDevices(list)), // trạng thái, pin, RSSI… (chỉ gửi khi đổi)
  SmartWear.onReading(r => console.log(r.capability, r.status, r.value)),
  SmartWear.onFindPhone(e => e.ringing && playRingtone()),
];

SmartWear.startScan(20);
await SmartWear.connect(id);            // mặc định GIỮ kết nối: mất thì tự nối lại, cả lần mở app sau
SmartWear.measure(id, 'HEART_RATE');    // đo một lần, kết quả qua onReading; stopMeasure để dừng
await SmartWear.startHeartRateStream(id); // nhịp tim liên tục khi chạy, qua onHeartRate (features.heartRateStream)
const h = await SmartWear.syncHistory(id, 7);

const controls = await SmartWear.getControls(id);    // mục cài đặt theo đúng tính năng của thiết bị
await SmartWear.setControl(id, 'sedentary.enabled', true);
await SmartWear.setControl(id, 'dnd.range', {from: 22 * 60, to: 7 * 60});
await SmartWear.runAction(id, 'find.start');         // thiết bị rung để tìm

await SmartWear.setWeather(id, await fetchOpenMeteoForecast(lat, lon, 'Ha Noi'));
await SmartWear.syncContacts(id, [{name: 'Mẹ', phone: '0912345678'}]); // GloryFit, tối đa 70 liên hệ
subs.forEach(s => s.remove());
```

Kiểu dữ liệu đầy đủ ở `src/types.ts`. Id thiết bị là địa chỉ MAC trên Android và UUID CoreBluetooth trên iOS.

**Phép đo cần chạm cảm biến** (Veepoo/GE54: `URIC_ACID`, `BLOOD_LIPIDS` — một lần đo `8A` cho cả acid uric và mỡ máu — và
`BODY_COMPOSITION`): trong lúc đo `onReading` nhận `status: 'MEASURING'`, `note: 'TOUCH_SENSOR'`, `extra.progress` 0–100.
App hiện "Đặt ngón tay lên cảm biến của vòng tay" (+ tiến độ). Kết quả là `status: 'OK'` (`value` + `extra.uricAcid`,
`totalCholesterol`, `triglycerides`, `hdl`, `ldl`); `'NOT_WORN'`/`'ERROR'` kèm `note: 'TOUCH_SENSOR'` = hỏng vì không chạm.

```ts
SmartWear.onReading(r => {
  if (r.status === 'MEASURING' && r.note === 'TOUCH_SENSOR') showTouchPrompt(r.extra?.progress ?? 0);
});
```

### Ghi chú theo nền tảng

- **Gọi điện qua đồng hồ (GloryFit):**
  - Android: `pairCallBluetooth(id)` tự ghép kênh Bluetooth cổ điển.
  - iOS: Apple không cho app tự ghép. `pairCallBluetooth` trả lỗi kèm hướng dẫn: người dùng vào Cài đặt → Bluetooth,
    chọn tên đồng hồ → Ghép đôi.
  - Cờ `paired`/`connected` đồng hồ Y25 báo về không đáng tin: gọi vẫn được khi đồng hồ báo `false`.
- **Báo thức trên Y25/HT43:** chỉ đặt được trên đồng hồ (cờ `isHasLocalAlarmClock`). App không đọc/ghi được, app
  chính hãng cũng vậy.
- **Thông báo ứng dụng trên iOS:** đồng hồ nhận qua ANCS sau khi ghép trong Cài đặt → Bluetooth. App không đọc được
  thông báo của app khác.
- **Tìm điện thoại:** thư viện chỉ báo sự kiện `onFindPhone`, app tự phát chuông. Khi bắt đầu và khi người dùng tắt chuông,
  gọi `setPhoneRinging(id, true/false)` để đồng hồ tắt màn "đang tìm điện thoại" (Y25: `D1 0A 01 01/00`).

## App mẫu

`example/` là app RN 0.79 thuần dùng thư viện qua `file:..`. Build trên MacBook bằng `scripts/rn.sh`:

```sh
scripts/rn.sh install     # npm install
scripts/rn.sh typecheck   # tsc thư viện + app mẫu
scripts/rn.sh android     # APK debug (codegen + Kotlin + SDK)
scripts/rn.sh ios         # pod install + build Simulator
```

Đã kiểm chứng 19–20/10/2026: typecheck qua; Android (Redmi Note 7 Pro) chạy `selfTest` OK trên Y25 và GE54; gói npm cài vào app
mới build được Android và iOS Simulator. Chưa chạy trên iPhone thật.
