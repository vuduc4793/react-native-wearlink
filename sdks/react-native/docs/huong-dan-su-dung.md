# Hướng dẫn dùng react-native-wearlink

Thư viện React Native (TurboModule, kiến trúc mới) nối app với thiết bị đeo qua Bluetooth Low Energy. Mã native là SDK Kotlin
(Android) và Swift (iOS) dùng chung với các app lab. Thư viện không có logic giao thức riêng.

Đọc kèm: [Lỗi thường gặp](loi-thuong-gap.md) · [Báo lỗi thư viện](bao-loi.md) · kiểu dữ liệu đầy đủ ở [`src/types.ts`](../src/types.ts).

## 1. Thiết bị hỗ trợ

| Thiết bị | Driver | Loại | Đã thử thật |
|---|---|---|---|
| **Y25** | `gloryfit` | Đồng hồ (GloryFit / UTE) | Android 19–20/10/2026, iOS lab |
| **GE54** | `veepoo` | Vòng tay không màn hình (G Band) | Android 19–20/10/2026. iOS: build + test, chưa chạy iPhone |
| R09, DS500 / HS500A | `qring` | Nhẫn, vòng | Trước 19/10, hiện không ưu tiên |
| Thiết bị có dịch vụ 180D / 180F | `standard` | Dây đo nhịp tim, thiết bị báo pin | Trước 19/10 |

Tính năng từng máy khác nhau. **Đừng hard-code theo tên máy**: đọc `device.capabilities`, `device.measurable`,
`device.features`, `getControls()` rồi chỉ hiện những gì có (mục 6).

## 2. Yêu cầu

| | Tối thiểu |
|---|---|
| React Native | 0.76 trở lên, **bật kiến trúc mới** (`newArchEnabled=true`, `RCT_NEW_ARCH_ENABLED=1`) |
| Android | `minSdkVersion` 26, JDK 17, Kotlin 2.x |
| iOS | **17.0** (SDK dùng Observation). App có target thấp hơn phải nâng lên 17 |

## 3. Cài đặt

```sh
npm install react-native-wearlink      # hoặc yarn add react-native-wearlink
```

Gói npm đã kèm mã SDK trong `node_modules/react-native-wearlink/vendor/sdks`.

### Android

Không phải khai báo module Gradle. Manifest của thư viện đã có quyền Bluetooth, foreground service, thông báo,
`READ_PHONE_STATE`. App phải:

1. **Xin quyền lúc chạy, trước khi gọi `SmartWear.start()`** (mục 4):
   - Android 12 trở lên: `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT`.
   - Android 11 trở xuống: `ACCESS_FINE_LOCATION`.
   - Android 13 trở lên: `POST_NOTIFICATIONS` (thông báo thường trực của dịch vụ giữ kết nối).
2. Chỉ khi dùng cầu nối điện thoại (chuyển cuộc gọi, tên danh bạ, trả lời SMS), **tự khai báo trong `AndroidManifest.xml`
   của app** rồi xin lúc chạy: `READ_CALL_LOG`, `READ_CONTACTS`, `ANSWER_PHONE_CALLS`, `SEND_SMS`. Thư viện không khai báo
   sẵn các quyền này để app không dùng thì không bị Google Play hỏi.

### iOS

1. `ios/Podfile`:

   ```ruby
   platform :ios, '17.0'

   target 'YourApp' do
     config = use_native_modules!
     sdks = '../node_modules/react-native-wearlink/vendor/sdks'
     pod 'SmartWearCore', :path => sdks
     pod 'SmartWearQRing', :path => sdks
     pod 'SmartWearGloryFit', :path => sdks
     pod 'SmartWearStandard', :path => sdks
     pod 'SmartWearVeepoo', :path => sdks
     # ...
   ```

   Thiếu pod nào thì build báo `No such module 'SmartWear…'`. Phải đủ cả 5 pod, kể cả driver app không dùng.
2. Đặt Deployment Target của target app thành **17.0** trong Xcode.
3. `Info.plist`:
   - `NSBluetoothAlwaysUsageDescription`: câu giải thích vì sao dùng Bluetooth. Thiếu dòng này thì app crash khi quét lần đầu.
   - `UIBackgroundModes` có `bluetooth-central`, để giữ kết nối và tự nối lại khi app ở nền.
4. `cd ios && pod install`.

## 4. Khởi động

```ts
import SmartWear from 'react-native-wearlink';
import {PermissionsAndroid, Platform} from 'react-native';

async function requestBlePermissions() {
  if (Platform.OS !== 'android') return true;
  const P = PermissionsAndroid.PERMISSIONS;
  const perms = Number(Platform.Version) >= 31 ? [P.BLUETOOTH_SCAN, P.BLUETOOTH_CONNECT] : [P.ACCESS_FINE_LOCATION];
  if (Number(Platform.Version) >= 33) perms.push(P.POST_NOTIFICATIONS);
  const r = await PermissionsAndroid.requestMultiple(perms);
  return perms.slice(0, Number(Platform.Version) >= 31 ? 2 : 1).every(p => r[p] === 'granted');
}

export async function initWearables() {
  await requestBlePermissions();
  SmartWear.start();   // dựng lại thiết bị đã lưu và tự nối lại thiết bị đang giữ kết nối
}
```

- Gọi `start()` **một lần** khi app khởi động, **sau** khi đã có quyền. Gọi trước khi có quyền thì Android không nối
  lại thiết bị cũ. Khi người dùng cấp quyền muộn hơn, gọi `start()` lại.
- Trên iOS, hộp thoại xin quyền Bluetooth hiện lần đầu khi thư viện chạm vào Bluetooth (`start` / `startScan`).

### Nghe sự kiện trong component

Sự kiện chỉ có một luồng cho mọi thiết bị. Lọc theo `deviceId`, và luôn `remove()` khi component unmount:

```tsx
useEffect(() => {
  const subs = [
    SmartWear.onDevicesChanged(setDevices),                 // trạng thái, pin, RSSI… (chỉ gửi khi đổi)
    SmartWear.onReading(r => { if (r.deviceId === id) onReading(r); }),
    SmartWear.onScanState(setScanState),                   // Bluetooth tắt / chưa cấp quyền / lỗi quét
  ];
  SmartWear.getDevices().then(setDevices);                 // lấy trạng thái hiện tại; sự kiện chỉ báo thay đổi
  return () => subs.forEach(s => s.remove());
}, [id]);
```

## 5. Quét, kết nối, quên thiết bị

```ts
const sub = SmartWear.onDiscovered(list => setFound(list));  // danh sách thiết bị tìm thấy (có rssi)
SmartWear.startScan(20);                                      // giây; tự dừng

try {
  await SmartWear.connect(found[0].id);  // mặc định giữ kết nối: mất thì tự nối lại, kể cả lần mở app sau
} catch (e: any) {
  if (e.code === 'timeout') {
    // Chưa nối được trong 40 s, thư viện VẪN đang thử ở nền. Hiện "Đang chờ thiết bị…", đừng báo lỗi cứng.
  }
}

await SmartWear.disconnect(id);        // ngắt, thôi giữ kết nối, vẫn nhớ thiết bị
await SmartWear.forget(id);            // xoá khỏi danh sách đã lưu
```

- `id` là địa chỉ MAC trên Android, UUID CoreBluetooth trên iOS. Cùng một thiết bị có `id` khác nhau trên mỗi điện thoại.
  Đừng gửi `id` lên server để dùng ở máy khác.
- `connect` cần thiết bị đã có trong kết quả quét hoặc trong danh sách đã lưu. Nếu không, Promise bị từ chối với mã `not_found`.
- `device.state`: `DISCONNECTED` → `CONNECTING` → `CONNECTED`. Chỉ gọi đo / đồng bộ / cài đặt khi đã `CONNECTED`.

### Ghép đôi (pairing)

- **Y25 trên Android:** lần đầu kết nối, thư viện tự gọi ghép đôi hệ thống. Android hiện hộp thoại "Ghép nối với Y25…?". Người dùng
  **phải bấm Ghép nối**. Chưa ghép thì Y25 chỉ quảng bá vài giây sau mỗi lần sáng màn, nên lần sau rất khó tự nối lại.
- **Y25 trên iOS:** iOS tự hiện hộp thoại ghép đôi. Người dùng bấm **Ghép đôi**, không bấm Huỷ.
- **GE54:** không cần ghép đôi hệ thống. Mật khẩu kết nối mặc định `0000` do thư viện tự gửi.
- Nếu `device.pairingPrompt` khác null, thiết bị đang chờ mã hoặc xác nhận. App hiện ô nhập rồi gọi
  `SmartWear.submitPairingCode(id, code)`.

## 6. Biết thiết bị làm được gì

```ts
const d = (await SmartWear.getDevices()).find(x => x.id === id)!;
d.measurable;          // ['HEART_RATE', 'SPO2', 'BLOOD_PRESSURE', …] đo trực tiếp được
d.capabilities;        // có dữ liệu (đo hoặc lịch sử)
d.supportsHistory;     // syncHistory được
d.features.alarms;     // getAlarms / setAlarm
d.features.watchFace;  // mặt đồng hồ
d.features.musicControl, d.features.remoteCamera, d.features.maxContacts …
```

Mỗi cờ `false` nghĩa là thiết bị hoặc nền tảng không làm được. Gọi hàm tương ứng thì Promise bị từ chối với mã `unsupported`.
Mã lỗi chung của các hàm trả Promise: `unsupported`, `not_found`, `bad_value`, `failed`, `timeout`.

Tóm tắt hai máy chính (chi tiết: `docs/devices/y25.md`, `docs/devices/ge54.md` trong repo):

| | Y25 | GE54 |
|---|---|---|
| Đo tay | HR, SpO2, huyết áp | HR, SpO2, huyết áp, nhiệt độ, stress, đường huyết, MET, acid uric + mỡ máu (chạm cảm biến), thành phần cơ thể (chạm điện cực) |
| Lịch sử | bước, kcal, quãng đường, ngủ, HR, SpO2, HA, bài tập | bước, ngủ, HR, SpO2, HA, HRV, nhiệt độ, stress, đường huyết, mỡ máu… (3 ngày) |
| Màn hình | Có (466×466 tròn): mặt đồng hồ, thời tiết, danh bạ, gọi điện | Không màn hình: không mặt đồng hồ, không thời tiết, không danh bạ |
| Báo thức | Chỉ đặt trên đồng hồ, app không đọc/ghi | `getAlarms` / `setAlarm` |

## 7. Đo trực tiếp

```ts
SmartWear.onReading(r => {
  if (r.deviceId !== id) return;
  switch (r.status) {
    case 'MEASURING': showProgress(r); break;                   // có thể kèm value tạm thời
    case 'OK':        showResult(r.value, r.systolic, r.diastolic, r.extra); break;
    case 'NOT_WORN':  showError('Hãy đeo thiết bị sát cổ tay'); break;
    case 'ERROR':     showError(r.note ?? 'Đo thất bại'); break;
  }
});
SmartWear.measure(id, 'HEART_RATE');      // không trả Promise: kết quả đến qua onReading
SmartWear.stopMeasure(id, 'HEART_RATE');  // khi rời màn hình đo
```

- Huyết áp: `systolic` / `diastolic`. `value` để trống.
- Một phép đo mất vài giây đến khoảng 1 phút (nhiệt độ GE54 lâu nhất). Trong lúc đó `status` là `MEASURING`.
- Gọi `measure` lại cho cùng thiết bị và chỉ số thì phép đo cũ bị huỷ.

### Phép đo phải chạm cảm biến (GE54)

`URIC_ACID`, `BLOOD_LIPIDS` (chung một lần đo) và `BODY_COMPOSITION` cần người dùng **đặt ngón tay của tay kia lên cảm biến hoặc điện cực
của vòng** suốt lúc đo. Chỉ đeo là chưa đủ.

```ts
SmartWear.onReading(r => {
  if (r.note === 'TOUCH_SENSOR') {
    if (r.status === 'MEASURING') showTouchPrompt('Đặt ngón tay lên cảm biến của vòng tay', r.extra?.progress ?? 0);
    else if (r.status !== 'OK') showError('Chưa chạm cảm biến. Đặt ngón tay rồi đo lại');
  }
  if (r.status === 'OK' && r.capability === 'BLOOD_LIPIDS') {
    const {uricAcid, totalCholesterol, triglycerides, hdl, ldl} = r.extra!;  // μmol/L và mmol/L
  }
});
SmartWear.measure(id, 'BLOOD_LIPIDS');
```

`BODY_COMPOSITION`: `value` là % mỡ. `extra` có `bmi`, `bodyFatRate`, `muscleMass`, `basalMetabolicRate`… (xem `Reading.extra` trong `types.ts`).
Kết quả thành phần cơ thể dựa trên hồ sơ người dùng (chiều cao, cân nặng, tuổi, giới). Đặt hồ sơ trước khi đo: `setControl(id, 'profile.height' | 'profile.weight' | 'profile.age' | 'profile.gender', …)`.

## 8. Lịch sử

```ts
const sub = SmartWear.onSyncProgress(p => setProgress(p.done / p.total));
const h = await SmartWear.syncHistory(id, 7);   // số ngày muốn lấy; GE54 chỉ giữ 3 ngày
h.today;                    // {steps, calories (kcal), distanceMeters, activeMinutes} hoặc null
h.series.HEART_RATE;        // [{t: ms, v: bpm}, …]
h.series.BLOOD_PRESSURE;    // v = tâm thu, extra.diastolic
h.sleep;                    // phiên ngủ + từng đoạn LIGHT/DEEP/REM/AWAKE
h.workouts;                 // bài tập
h.errors;                   // bước nào lỗi (các bước khác vẫn có dữ liệu)
const cached = await SmartWear.getHistory(id);  // kết quả lần đồng bộ gần nhất, không đồng bộ lại
```

- Đồng bộ mất vài giây đến cả phút. Đừng chặn UI. Không gọi `measure` trong lúc đồng bộ.
- `h.errors` không rỗng **không** có nghĩa là thất bại toàn bộ. Vẫn hiện phần đã có.
- Thời gian luôn là ms từ 1970, theo giờ điện thoại. Thiết bị được đặt giờ theo điện thoại mỗi lần kết nối.

## 9. Cài đặt thiết bị

Mọi cài đặt (nhắc ngồi, không làm phiền, đơn vị, hồ sơ, đo tự động, mục tiêu…) đi qua một danh sách chung, đúng với từng máy:

```ts
const controls = await SmartWear.getControls(id);
// {id: 'sedentary.enabled', group, title, kind: 'toggle'|'number'|'timeRange'|'choice'|'action', value, min, max, step, unit, options, confirm}
await SmartWear.setControl(id, 'sedentary.enabled', true);
await SmartWear.setControl(id, 'dnd.range', {from: 22 * 60, to: 7 * 60});   // phút trong ngày
await SmartWear.runAction(id, 'find.start');                                // kind === 'action'
```

- Dựng UI từ danh sách này (gom theo `group`, vẽ theo `kind`). Đừng hard-code `id`, vì mỗi máy có bộ `id` khác nhau.
- `confirm` khác null nghĩa là hành động nguy hiểm (xoá dữ liệu, khôi phục gốc, hiệu chuẩn). **Phải** hiện hộp thoại
  xác nhận với nội dung `confirm` trước khi gọi `runAction` / `setControl`.
- Hiệu chuẩn huyết áp (GE54) làm sai số đo của mọi lần đo sau. Chỉ để cho người dùng tự đặt, đừng ghi tự động.

## 10. Tính năng điện thoại ↔ thiết bị

| Tính năng | Android | iOS |
|---|---|---|
| Thông báo app, SMS | `setPhoneLinkConfig({apps, sms})` cộng quyền đọc thông báo (`openNotificationAccessSettings`). Chạy native, không cần JS sống | Hệ thống tự gửi qua ANCS sau khi ghép đôi. App không điều khiển được |
| Cuộc gọi đến, từ chối | `setPhoneLinkConfig({calls: true})` cộng quyền điện thoại | Hệ thống lo |
| Điều khiển nhạc | `setPhoneLinkConfig({music: true})` | `onMusicCommand` chỉ điều khiển trình phát của chính app |
| Trả lời SMS nhanh | `setPhoneLinkConfig({smsReply: true})` cộng `SEND_SMS` | Không có |
| Tìm điện thoại | `onFindPhone` → app tự phát chuông, gọi `setPhoneRinging(id, false)` khi tắt | Như Android |
| Gọi điện qua đồng hồ (Y25) | `pairCallBluetooth(id)` tự ghép kênh Bluetooth cổ điển | Người dùng tự ghép trong Cài đặt → Bluetooth |
| Giữ kết nối ở nền | Foreground service tự bật khi có thiết bị đang giữ (`setForegroundService(false)` để tắt) | `bluetooth-central` trong `UIBackgroundModes` |

Các mục khác (thời tiết, danh bạ, mặt đồng hồ, bài tập, vị trí khi tập, camera từ xa, báo thức, firmware) có chú thích ngay trên từng hàm
trong `src/index.ts`. Kiểm `device.features` trước khi hiện nút.

```ts
await SmartWear.setWeather(id, await fetchOpenMeteoForecast(lat, lon, 'Ha Noi'));  // Y25
await SmartWear.syncContacts(id, [{name: 'Mẹ', phone: '0912345678'}]);              // Y25, tối đa features.maxContacts
await SmartWear.setAlarm(id, {id: -1, hour: 6, minute: 30, repeatDays: 0b0011111, enabled: true, label: null}); // GE54
```

## 11. Firmware (Android)

`checkFirmware(id, path)` kiểm file trước. `updateFirmware(id, path)` nạp, tiến độ qua `onTransferProgress` (`what: 'firmware'`), có thể mất
khoảng 20 phút. **Chỉ dùng file firmware chính hãng** đúng model. Trong lúc nạp, giữ điện thoại sát thiết bị, không tắt app, không ngắt kết nối.

## 12. Kiểm nhanh khi tích hợp

App mẫu `example/App.tsx` có hàm `selfTest(device)`. Hàm chạy lần lượt các lệnh không phá dữ liệu và in `SWTEST <bước> OK|SKIP|FAIL`
ra console. Chép hàm này vào màn debug của app để thử trên máy thật, rồi gửi log khi [báo lỗi](bao-loi.md).
