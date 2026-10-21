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
| iOS | **15.1** (từ bản 0.1.1; bản 0.1.0 cần 17.0) |

## 3. Cài đặt

```sh
npm install react-native-wearlink      # hoặc yarn add react-native-wearlink
```

Gói npm đã kèm mã SDK trong `node_modules/react-native-wearlink/vendor/sdks`.

### Android

Không phải khai báo module Gradle. Manifest của thư viện chỉ có phần tối thiểu: quyền Bluetooth, foreground service giữ
kết nối (`connectedDevice`), `POST_NOTIFICATIONS`. `bluetooth_le` để `required="false"`, nên Google Play không lọc máy
không có BLE (app tự kiểm lúc chạy qua `onScanState`). App phải:

1. **Xin quyền lúc chạy, trước khi gọi `SmartWear.start()`** (mục 4):
   - Android 12 trở lên: `BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT`.
   - Android 11 trở xuống: `ACCESS_FINE_LOCATION`.
   - Android 13 trở lên: `POST_NOTIFICATIONS` (thông báo thường trực của dịch vụ giữ kết nối).
2. Chỉ khi dùng cầu nối điện thoại (mục 10), **tự khai báo trong `AndroidManifest.xml` của app** phần mình dùng, rồi xin
   quyền lúc chạy. Thư viện không khai báo sẵn để app không dùng thì không bị Google Play hỏi:

   ```xml
   <!-- Báo cuộc gọi đến (calls: true) -->
   <uses-permission android:name="android.permission.READ_PHONE_STATE" />
   <uses-permission android:name="android.permission.READ_CALL_LOG" />      <!-- số gọi đến -->
   <uses-permission android:name="android.permission.READ_CONTACTS" />      <!-- tên danh bạ -->
   <uses-permission android:name="android.permission.ANSWER_PHONE_CALLS" /> <!-- từ chối cuộc gọi từ thiết bị -->
   <!-- Trả lời SMS nhanh (smsReply: true) -->
   <uses-permission android:name="android.permission.SEND_SMS" />

   <application>
     <!-- Chuyển thông báo app / SMS, điều khiển nhạc (apps, sms, music) -->
     <service
       android:name="com.smartwear.core.phone.PhoneNotificationListener"
       android:exported="true"
       android:permission="android.permission.BIND_NOTIFICATION_LISTENER_SERVICE">
       <intent-filter>
         <action android:name="android.service.notification.NotificationListenerService" />
       </intent-filter>
     </service>
   </application>
   ```

   Thiếu mục nào thì tính năng tương ứng tự bỏ qua, không crash. Không khai báo dịch vụ thì `hasNotificationAccess()`
   luôn `false` và app không hiện trong màn "Truy cập thông báo".
3. Google Play, Android 14 trở lên: khai báo loại foreground service **connectedDevice** trong Play Console (giữ kết nối
   với thiết bị đeo khi app ở nền).
4. App tải JS qua OTA (CodePush, Expo Updates…): JS có thư viện có thể chạy trên bản build cũ chưa có native. Kiểm
   `SmartWear.isAvailable` trước khi gọi hàm nào khác (từ 0.1.2; bản cũ ném lỗi ngay lúc import).

### iOS

1. `ios/Podfile`:

   ```ruby
   platform :ios, min_ios_version_supported   # 15.1

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
2. Deployment Target của target app ≥ **15.1**.
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

### Nhịp tim liên tục khi chạy (từ 0.1.3)

`measure(id, 'HEART_RATE')` đo **một lần**. Khi ghi bài chạy bằng GPS điện thoại (như Strava ghép dây đo nhịp tim), dùng luồng liên tục:

```ts
const devices = await SmartWear.getDevices();
const hr = devices.find(d => d.state === 'CONNECTED' && d.features.heartRateStream);

const sub = SmartWear.onHeartRate(e => {
  if (e.deviceId !== hr.id) return;
  if (!e.connected) return markGap(e.t);              // mất kết nối: bắt đầu khoảng trống, thư viện tự nối lại
  if (e.error === 'unsupported') return hideHeartRate();
  if (e.bpm == null) return showHint(e.contact === false ? 'Đeo sát cổ tay' : 'Đang đo…');
  addSample(e.t, e.bpm, e.rrMs);                     // tối đa ~1 mẫu/giây
});
await SmartWear.startHeartRateStream(hr.id);         // khi bấm "Bắt đầu chạy"
// …
await SmartWear.stopHeartRateStream(hr.id);          // khi kết thúc / huỷ buổi chạy
sub.remove();
```

- Lưu nhịp tim thành bảng riêng theo `t` (giờ điện thoại lúc nhận), ghép với lộ trình theo thời gian. Quá **5 giây** không có
  mẫu thì coi giá trị đang hiện là cũ và đánh dấu khoảng trống.
- Gọi được trước khi thiết bị kết nối xong: thư viện chờ, rồi tự mở lại luồng sau mỗi lần nối lại cho tới `stopHeartRateStream`.
- Không tạo bài tập trên đồng hồ / vòng (không dùng `startWorkout`), nên không bị trùng buổi tập khi đồng bộ lịch sử.
- Đừng gọi `measure(id, 'HEART_RATE')` trong lúc stream. Y25 còn đẩy thêm giá trị qua `onReading` (HEART_RATE) trong lúc stream: bỏ qua.

| Thiết bị | Cách lấy | Tần suất | Đã kiểm trên thiết bị thật |
|---|---|---|---|
| Dây đo / đồng hồ phát nhịp tim chuẩn 0x180D (Polar, Coospo, Magene, Garmin "Broadcast HR"…) | notify 0x2A37, có RR và tiếp xúc da nếu dây gửi | ~1 mẫu/giây | Chưa (đã test bộ giải mã) |
| GE54 (`veepoo`) | lệnh đo nhịp tim `D0 01` chạy liên tục tới khi dừng | ~1 mẫu/giây (theo vòng) | Chưa |
| Y25 (`gloryfit`) | đo lặp `E5 11` → `E5 00`, tạm tắt HR 24h trong lúc stream, bật lại khi dừng | ít nhất 1 mẫu/25 s; nếu đồng hồ đẩy giá trị giữa chừng thì ~1/giây | Chưa |
| HT43 (`gloryfit`) | **không hỗ trợ** (`features.heartRateStream = false`): đồng hồ chỉ tự đẩy HR theo chu kỳ, bỏ qua lệnh đo `E5 11` | – | – |
| R09 (`qring`) | | | Không hỗ trợ (`unsupported`) |

Màn ghép thiết bị đo nhịp tim lúc bắt đầu chạy: lọc kết quả quét bằng `d.heartRateService || d.driver === 'gloryfit' || d.driver === 'veepoo'`, sau khi kết nối thì kiểm lại `device.features.heartRateStream` (HT43 = false).

**Android, khi app đã có foreground service riêng** (vd dịch vụ vị trí lúc chạy): kết nối BLE nằm trong tiến trình app, dịch vụ
`KeepConnectedService` của thư viện chỉ giữ tiến trình sống ở nền. Nếu dịch vụ của app đang chạy thì gọi `setForegroundService(false)`
để chỉ còn một thông báo, kết nối vẫn sống. Khi app tắt dịch vụ của mình (kết thúc buổi chạy) mà vẫn muốn giữ kết nối ở nền, gọi
lại `setForegroundService(true)`.

**iOS:** app chạy nền nhờ chế độ nền `location` lúc ghi GPS, nên luồng nhịp tim vẫn chạy. Thư viện có khôi phục trạng thái
CoreBluetooth (`bluetooth-central`): iOS có thể mở lại app ở nền để nối lại thiết bị đang giữ, nhưng luồng nhịp tim **không tự mở
lại** sau khi app bị hệ thống huỷ; JS phải gọi `start()` và `startHeartRateStream` lại. Người dùng vuốt tắt app thì iOS không mở lại.

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

### Chi tiết bài tập và đường GPS do đồng hồ ghi (từ 0.1.4)

Bài tập ghi **trên đồng hồ** (người dùng bấm bắt đầu trên đồng hồ) có thêm chi tiết khi thiết bị gửi:

```ts
for (const w of h.workouts) {
  w.samples;              // [{t, heartRate, paceSecondsPerKm, speedKmh, cadence, latitude, longitude}], mỗi w.sampleIntervalSeconds giây
  w.track;                // [{t, latitude, longitude}]: đường đi GPS của đồng hồ, rỗng nếu đồng hồ không có GPS
  w.heartRateZoneSeconds; // [khởi động, đốt mỡ, ưa khí, kỵ khí, tối đa] (giây) hoặc null
  w.avgStrideCm;          // sải bước, cũng có maxStrideCm, minStrideCm
}
// Vẽ: <Polyline coordinates={w.track.map(p => ({latitude: p.latitude, longitude: p.longitude}))} />
```

| Thiết bị | `samples` / vùng HR | `track` (GPS) |
|---|---|---|
| HT43 (gloryfit) | có | có (đồng hồ có chip GPS) |
| Y25 (gloryfit) | có | chỉ khi đồng hồ có GPS riêng: chưa xác nhận |
| GE54, R09, dây HR | không | không |

- Đây là đường GPS **đồng hồ tự ghi**, khác với chạy bằng GPS điện thoại (app tự ghi, xem báo cáo chạy bộ).
- Các trường đều tuỳ chọn: bản native cũ hơn 0.1.4 không gửi. Viết `w.track ?? []`.
- Bố cục gói đã giải mã theo mã app hãng, **chưa đối chiếu với bản ghi thật có GPS**. Thấy đường lệch hoặc rỗng dù đồng hồ có GPS
  thì [báo lỗi](bao-loi.md) kèm log (app lab Android: `--ez workoutPackets true` in hex từng gói bài tập).

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

### Môn tập hiện trên đồng hồ (Y25, HT43)

"Hơn 100 chế độ tập" trong app GloryFit/GloryFitPro là **danh mục tên môn của app** (GloryFitPro biết 245 môn), không phải số
môn đồng hồ chứa. Y25 giữ **50 môn**. App hãng (và thư viện) chỉ cho bật/tắt hiện và đổi thứ tự trong 50 môn đó, không thêm được
môn ngoài danh sách đồng hồ giữ. Kiểm `device.features.sportList` trước khi hiện màn này.

```ts
const sports = await SmartWear.getSportTypes(id);        // [{type, name, nameEn, shown, position}] — 50 môn của Y25
const limits = await SmartWear.getSportListLimits(id);   // {minShown: 4, maxShown: 50} (từ 0.1.5)
const catalog = await SmartWear.getSportCatalog(id);     // 245 môn {type, name, nameEn}: chỉ để tra tên (từ 0.1.5)

// Hiện thêm môn 9, xếp lên đầu:
const next = sports.map(s => (s.type === 9 ? {...s, shown: true, position: 0} : s));
await SmartWear.setSportList(id, next);
```

- Truyền **mọi** môn của `getSportTypes` vào `setSportList`, kể cả môn ẩn: đồng hồ nhận cả danh sách một lần (như app hãng).
- Thứ tự hiện theo `position` (1, 2, 3…); thư viện đánh số lại 1..n, môn `position` 0 xếp cuối, môn ẩn luôn 0.
- Số môn hiện phải trong `getSportListLimits`, nếu không `setSportList` báo lỗi và không ghi gì.
- Hỏi người dùng trước khi ghi: danh sách trên đồng hồ đổi ngay.
- `name` là tiếng Việt, `nameEn` tiếng Anh (theo GloryFitPro). Tên bài tập trong lịch sử (`workouts[].name`) lấy từ cùng danh mục.
- App mẫu: phần "Môn tập" trong thẻ thiết bị (`example/App.tsx`, `SportListEditor`).

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

### AGPS cho đồng hồ có GPS riêng (từ 0.1.4)

Đồng hồ có GPS (HT43; Y25 có cờ nhưng chưa thấy tự xin) cần **AGPS** để bắt vệ tinh nhanh. Hết dữ liệu thì HT43 hỏi điện thoại mỗi 60 s.
Kiểm `device.features.agps`.

- **Thư viện không gọi mạng và không tải file dữ liệu vệ tinh.** File AGPS phải đến từ nguồn app được phép dùng (thoả thuận với hãng đồng hồ
  hoặc nhà cung cấp dữ liệu GNSS). Dùng khoá / API của app hãng khác là quyết định và trách nhiệm của bên tích hợp.
- Không có file, chỉ gửi **vị trí điện thoại** cũng giúp bắt vệ tinh nhanh hơn. Thư viện giữ vị trí lại và tự gửi khi đồng hồ hỏi.
- Chưa có file, thư viện trả lời đồng hồ "không hỗ trợ" để nó thôi hỏi mỗi phút (**chưa kiểm trên máy**).

```ts
const st = await SmartWear.getAgpsStatus(id);   // { files: ['…'], version, interval, ephemerisValid }
await SmartWear.sendAgpsPosition(id, { latitude: 21.0285, longitude: 105.8542 });  // vị trí điện thoại lúc gần nhất

// Có file từ nguồn được phép: gửi ngay (tiến độ onTransferProgress, what: 'agps') …
await SmartWear.uploadAgpsFiles(id, st.files.map(name => ({ name, base64: myFiles[name] })));
// … hoặc đặt sẵn để thư viện tự gửi khi đồng hồ xin (chỉ trong bộ nhớ, kể cả lúc JS không chạy).
await SmartWear.setAgpsFiles(id, st.files.map(name => ({ name, base64: myFiles[name] })));

SmartWear.onAgpsRequest(e => {
  // e.request: 'STATUS' | 'DOWNLOAD' | 'POSITION'; e.handled = thư viện đã tự trả lời bằng vị trí / file đặt sẵn.
});
```

Giới hạn: tối đa 16 file, mỗi file ≤ 256 KB, tổng ≤ 512 KB. Tên file lấy từ `getAgpsStatus().files`.

## 11. Firmware (Android)

`checkFirmware(id, path)` kiểm file trước. `updateFirmware(id, path)` nạp, tiến độ qua `onTransferProgress` (`what: 'firmware'`), có thể mất
khoảng 20 phút. **Chỉ dùng file firmware chính hãng** đúng model. Trong lúc nạp, giữ điện thoại sát thiết bị, không tắt app, không ngắt kết nối.

## 12. Kiểm nhanh khi tích hợp

App mẫu `example/App.tsx` có hàm `selfTest(device)`. Hàm chạy lần lượt các lệnh không phá dữ liệu và in `SWTEST <bước> OK|SKIP|FAIL`
ra console. Chép hàm này vào màn debug của app để thử trên máy thật, rồi gửi log khi [báo lỗi](bao-loi.md).
