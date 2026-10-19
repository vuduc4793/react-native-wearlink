# react-native-smartwear

TurboModule (React Native kiến trúc mới, RN ≥ 0.76) bọc SmartWear SDK:

| Driver | Thiết bị đã thử | Có gì |
|---|---|---|
| `qring` | R09 (nhẫn), DS500 / HS500A (vòng) | Đo HR, SpO2, nhiệt độ, căng thẳng, HRV; lịch sử; cài đặt đọc lại được |
| `gloryfit` | Y25, HT43 | Đo HR, SpO2, huyết áp; lịch sử + bài tập; cài đặt; thời tiết; danh bạ; gọi điện qua đồng hồ |
| `standard` | Thiết bị Bluetooth chuẩn (HR, pin) | Đo nhịp tim |

Mã native gọi thẳng SDK trong repo: Kotlin `sdks/*/android`, Swift `sdks/*/ios`. Thư viện không chứa logic giao thức
riêng, nên Android, iOS và thư viện RN luôn chạy cùng một mã SDK.

## Cài vào app React Native thuần

```sh
npm install react-native-smartwear                                  # từ npm (gói đã kèm mã SDK trong vendor/sdks)
# hoặc từ repo (dev):
npm install file:<đường-dẫn>/smart-wear-sdk/sdks/react-native
```

Gói npm được `prepack` (`scripts/vendor.js`) chép sẵn mã SDK Kotlin + Swift + podspec vào `vendor/sdks/`; Android tự dùng nó,
iOS khai báo pod từ đó (dưới). Cài từ repo thì dùng thẳng `sdks/`.

### iOS

1. `ios/Podfile`: iOS 17 (SDK dùng Observation) và 5 pod SDK:

   ```ruby
   platform :ios, '17.0'

   target 'YourApp' do
     config = use_native_modules!
     sdks = '../node_modules/react-native-smartwear/vendor/sdks'   # cài từ repo: '<đường-dẫn>/smart-wear-sdk/sdks'
     pod 'SmartWearCore', :path => sdks
     pod 'SmartWearQRing', :path => sdks
     pod 'SmartWearGloryFit', :path => sdks
     pod 'SmartWearStandard', :path => sdks
     pod 'SmartWearVeepoo', :path => sdks
     # ...
   ```

2. Đặt **iOS Deployment Target = 17.0** cho target app trong Xcode.
3. `Info.plist`:
   - `NSBluetoothAlwaysUsageDescription`: lý do dùng Bluetooth.
   - `UIBackgroundModes` = `bluetooth-central`, để giữ kết nối và tự nối lại khi app chạy nền.
4. `cd ios && pod install`.

### Android

Không cần khai báo thêm module Gradle: thư viện biên dịch kèm mã SDK. Chỉ cần:

- `minSdkVersion` ≥ 26.
- Quyền Bluetooth đã có sẵn trong manifest của thư viện. App phải **xin quyền lúc chạy**: `BLUETOOTH_SCAN` +
  `BLUETOOTH_CONNECT` từ Android 12 trở lên, `ACCESS_FINE_LOCATION` cho Android 11 trở xuống. Xem `example/App.tsx`.

## Dùng

```ts
import SmartWear, {fetchOpenMeteoForecast} from 'react-native-smartwear';

SmartWear.start();                                   // gọi 1 lần: dựng lại thiết bị đã lưu, tự nối lại cái đang giữ
const subs = [
  SmartWear.onDiscovered(list => setFound(list)),    // kết quả quét
  SmartWear.onDevicesChanged(list => setDevices(list)), // trạng thái, pin, RSSI… (chỉ gửi khi đổi)
  SmartWear.onReading(r => console.log(r.capability, r.status, r.value)),
  SmartWear.onFindPhone(e => e.ringing && playRingtone()),
];

SmartWear.startScan(20);
await SmartWear.connect(id);            // mặc định GIỮ kết nối: mất thì tự nối lại, cả lần mở app sau
SmartWear.measure(id, 'HEART_RATE');    // kết quả qua onReading; stopMeasure để dừng
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

Đã kiểm chứng 15/10/2026:
- Typecheck qua.
- Android build APK thành công.
- iOS build Simulator thành công; app mở được, TurboModule nạp được.

Chưa chạy trên thiết bị thật. Lý do: nếu chạy song song với app SmartWear Lab đang giữ kết nối, hai app sẽ giành thiết bị.
