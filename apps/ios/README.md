# SmartWear Lab (iOS)

SwiftUI app for the SmartWear SDK. It uses five Swift libraries from the `SmartWearKit` package
(`sdks/Package.swift`). Each device type has its own SDK, and its source lives next to the Android version:

| Product | Source | Contents |
|---|---|---|
| `SmartWearCore` | `sdks/core/ios/Sources` | `Capability`, `ScannedDevice`, `DeviceDriver`, `DeviceRegistry`, `WearableDevice`, `DeviceInfo`, `Reading`, `LinkStats`, `DeviceManager`, `BleCentral`, `GattConnection` (sequential GATT queue with timeouts) |
| `SmartWearQRing` | `sdks/qring/ios/Sources` | 16-byte `Packet`, `BigDataFrame` + CRC16/MODBUS, `QRingClient` (handshake, battery, 0x69/0x6A measurement), `QRingCapabilities`, `QRingDriver`/`QRingDevice` |
| `SmartWearStandard` | `sdks/standard/ios/Sources` | Battery 180F/2A19, Device Info 180A, Heart Rate 180D/2A37, `StandardDriver`/`StandardDevice` |
| `SmartWearVeepoo` | `sdks/veepoo/ios/Sources` | Veepoo / G Band protocol (F0080001: write F0080003, notify F0080002; UI F0030001), `VeepooFeatures` (A7), `VeepooMessageSwitches` (AD), `VeepooCustomSettings` (B8), `VeepooDriver`/`VeepooDevice` (handshake A1, HR/SpO2/BP/temperature/stress/HRV, history D1/DF/E0/D4, settings, contacts, weather, native watch face) |
| `SmartWearGloryFit` | `sdks/gloryfit/ios/Sources` | UTE protocol (55FF/33F1, 56FF/34F1), `Ute.Features`, `UteWatchFace` (.bin builder, CRC-32, validation), `GloryFitDriver`/`GloryFitDevice` (handshake A3/A1/A2/A0/A9, HR/SpO2/BP/temperature, `queryDialParams`, `installWatchFaceFile`) |

Concept names match the Android side (see `docs/architecture.md`). `Capability.rawValue` uses the
Android enum names (`HEART_RATE`, ...).

## Requirements

- Xcode 26 (iOS 26 SDK) and XcodeGen (`/opt/homebrew/bin/brew install xcodegen`).
- Deployment target: iOS 17. Liquid Glass (`glassEffect`, `GlassEffectContainer`) is only used behind
  `if #available(iOS 26, *)`. On iOS 17–18 it falls back to `.ultraThinMaterial` with a highlighted edge.
- A real iPhone (the simulator has no Bluetooth). Team `WW7SVG7456`, automatic signing.

## Build and run (from the Mac mini, everything runs on the MacBook Pro)

`scripts/ios.sh` rsyncs only the iOS parts to `ducvu@cs-macbook-pro:~/smart-wear-sdk-ios`. It never
touches `~/smart-wear-sdk`, which the Android side owns.

```bash
scripts/ios.sh test        # swift test for SmartWearKit (on macOS)
scripts/ios.sh build       # xcodegen + xcodebuild (DerivedData in ~/smart-wear-sdk-ios/build)
scripts/ios.sh install     # build + install on "iPhone của Đức" (DEVICE=<devicectl id> to change)
scripts/ios.sh run         # open the app, attach the console
scripts/ios.sh screenshot detail   # pull Documents/detail.png into build/ios-shots/
```

To work directly on the MacBook: `cd ~/smart-wear-sdk-ios/apps/ios && xcodegen generate && open SmartWearLab.xcodeproj`.

### Signing over SSH (required once)

Over SSH, the MacBook's login keychain is locked, so `codesign` fails with `errSecInternalComponent`
even though provisioning works (Xcode fetches the "iOS Team Provisioning Profile: *"). Pick one:

1. On the MacBook: `printf '%s' '<login password>' > ~/.smartwear-keychain-password && chmod 600 ~/.smartwear-keychain-password`.
   `scripts/ios.sh build` then runs `security unlock-keychain` before every build.
2. Or SSH into the MacBook yourself, run `security unlock-keychain ~/Library/Keychains/login.keychain-db`
   (enter the password), then run `xcodebuild` / `scripts/ios.sh install` in that same session.

### Screenshots on the simulator (no signing, no Bluetooth)

```bash
scripts/ios.sh sim 26 ios26-home -demo YES                     # iOS 26: real Liquid Glass
scripts/ios.sh sim 18 ios18-detail -demo YES -demoDetail YES   # iOS 18: material fallback
scripts/ios.sh sim-off
```

`-demo YES` loads sample devices labelled "Dữ liệu mẫu" (sample data). Every number in it was recorded
from the real devices (devices.md, plus the COROS connection on 2026-10-13).

## Auto-test mode (launch arguments)

```bash
scripts/ios.sh run -autoConnect 32:35:45:37:4E:00,COROS -measure HEART_RATE -screenshot YES -autoExit YES
```

| Argument | Meaning |
|---|---|
| `-autoConnect a,b` | Each entry matches the MAC from the advertisement (QRing), the CoreBluetooth UUID, or part of the name. Only devices a driver recognises are considered. |
| `-measure HEART_RATE,SPO2` | After connecting, run a bulk measurement for each capability on every device that supports it |
| `-measureTimeout 60` / `-scanTimeout 30` | Timeouts in seconds |
| `-screenshot YES` | The app captures its own window into `Documents/home.png`, `detail.png`, `detail-done.png` |
| `-autoExit YES` | Disconnect and exit when done, so `--console` returns |
| `-verboseLog YES` | Also print SDK logs and every byte sent and received |
| `-keep YES` | Keep the connected devices connected (auto-reconnect, also on the next launch). Default: not kept, so the iPhone does not fight other phones for the devices after a test |
| `-sync 7` | After connecting, sync N days of history on every device that supports it and print one `[AUTO] … LỊCH SỬ` summary per device (today's totals, sleep, series counts, failed steps) |
| `-e2e YES` | End-to-end check per device after connecting: full handshake (firmware, battery, capabilities) → user disconnect → reconnect (timed) → forget (remove + ask iOS to release) → verify iOS no longer holds it. Prints `[AUTO] E2E <name>: ĐẠT/LỖI` and a total |
| `-forgetAll YES` / `-releaseAll YES` | Start clean: forget every saved device (or just stop keeping them), and ask iOS to release every connection it still holds for this app |

Every line is printed with `print()` and the `[AUTO]` prefix, and ends with `[AUTO] DONE (code N)`.

## Screens

- **Signal field** (top half): the phone sits at the centre and each device is an orb. The closer to
  the centre, the stronger the RSSI. A ring pulses out from the orb for every packet received.
- **Draggable sheet** (drag or tap the handle). Tabs:
  - **Thiết bị**: live device list, "Đo đồng loạt" (bulk measurement) with a capability picker,
    connect/disconnect.
  - **Thêm**: scan, multi-select, "Kết nối song song N thiết bị" (parallel connect), grouped by driver.
  - **Khả thi**: `n / 7` connections, bulk measurement, live RSSI / packets/s / errors / latency table.
- **Device detail**: its own screen for each device, generated from that device's capabilities. It has a
  chip switcher across devices, a large hero number with packet bars, a grid of every measurement the
  device supports, synced data (steps/sleep: history sync isn't in this version), battery and device
  info, and "Chi tiết kỹ thuật" (technical details: driver, UUID, MAC, raw capability bytes, decoded
  bits, LinkStats, raw packet log), and a "Chẩn đoán kết nối" button (see below).

## Connection diagnostics ("Chẩn đoán")

Use this to debug a watch that stops advertising, a device held by another phone or app, a dismissed iOS
pairing popup, a device saved with the wrong driver, or notify timeouts.

- **SDK** (`SmartWearCore/Diagnostics.swift`):
  - Each `WearableDevice` keeps a `timeline`: a ring buffer of the last 200 timestamped events. It covers
    sightings (RSSI, advert or system-connected), connect attempts (interactive or background, plus the link
    timeout), link up, service discovery, notify OK or timeout, handshake steps, and disconnects with the
    `CBError`/ATT code. It also covers scheduled reconnects, driver corrections and user actions.
  - `DeviceManager.events` is the global log (500 entries).
  - `ConnectionDiagnostics.explain` maps a failure to a Vietnamese title, explanation and suggested action.
    Example: CBError 14/15 or ATT 0x05/0x0F gives "Cần ghép đôi lại → Cài đặt → Bluetooth → Quên <tên>".
  - A link timeout is explained by whether adverts were seen ("không quảng bá" vs "popup ghép đôi bị bỏ
    qua"), or by iOS holding the device.
  - `pairingLikelyPending` flags a connect stuck for more than 10 s in the link or discovery phase while
    the device still advertises, or one that hits encryption errors.
  - `device.diagnosis` is refreshed every second. `DeviceManager.onConnectFailed` fires on every failed
    attempt.
- **App**:
  - In the device list, an orange summary row appears under a device that has a problem. Tap it to open
    the diagnostics screen.
  - In device detail, open it with "Chẩn đoán kết nối".
  - The "Chẩn đoán" sheet shows the current state and phase, the last advert (time and RSSI), whether iOS
    holds the device, keep-connected, the driver, the last error explained with an action, and the
    timeline (this device or all devices).
  - Buttons: Thử lại ngay (interactive connect), Giữ kết nối, Xuất nhật ký (a `.txt` file with app/iOS
    version, device info and timelines, shared through the share sheet), and Quên thiết bị.
  - While the sheet is open the app scans, so you can see whether the device is still advertising.
- **Auto-test**: every failed connect prints `[AUTO] <name>: CHẨN ĐOÁN (...): <title> — <detail> → <action>`.

## Notes

- iOS hides the MAC address. For QRing, the real MAC is read from manufacturer data (company `0x1234`,
  `FE E7` + 6 bytes).
- Phone-info command `0x04` sends `02 0A` + the machine model (same as the verified Android build;
  the iOS-specific code is still unknown).
- First launch: iOS asks for Bluetooth permission. Tap **Cho phép** (Allow). If you see "Untrusted
  Developer": Settings → General → VPN & Device Management → Apple Development: Đức Vũ → Trust.
