# react-native-wearlink

SDK kết nối điện thoại với thiết bị đeo (đồng hồ, vòng tay, nhẫn) qua Bluetooth Low Energy — Kotlin (Android), Swift (iOS) và
thư viện React Native dùng chung một mã SDK.

| Họ thiết bị | Driver | Thiết bị đã thử |
|---|---|---|
| GloryFit / UTE | `gloryfit` | Y25 (đồng hồ) |
| Veepoo (G Band) | `veepoo` | GE54 (vòng tay) |
| QRing / oudmon | `qring` | R09 (nhẫn), DS500 / HS500A (vòng) |
| Bluetooth chuẩn (HR, pin) | `standard` | thiết bị có dịch vụ 180D / 180F |

## Cấu trúc

| Thư mục | Nội dung |
|---|---|
| `sdks/core` | Lớp BLE chung + interface tính năng (đo, lịch sử, cài đặt, thông báo, cuộc gọi, nhạc, báo thức, bài tập…) |
| `sdks/<họ>/{android,ios,docs}` | Driver từng họ thiết bị + tài liệu giao thức |
| `sdks/react-native` | Thư viện npm **`react-native-wearlink`** (TurboModule Android + iOS) — xem [README](sdks/react-native/README.md) |
| `apps/android`, `apps/ios` | App lab để thử trên máy thật |
| `docs/devices` | Bảng tính năng từng thiết bị + checklist chống sót tính năng |
| `docs/case-studies` | Ghi chép lỗi đã gặp và cách sửa |

## Build và test

```sh
scripts/android.sh test     # unit test Kotlin (chạy trên máy build Android)
scripts/ios.sh test         # swift test
scripts/rn.sh typecheck     # TypeScript thư viện + app mẫu
scripts/rn.sh android       # build app mẫu React Native
```
