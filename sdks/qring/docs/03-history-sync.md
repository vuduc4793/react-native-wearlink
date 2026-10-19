# 03 — Đồng bộ dữ liệu lịch sử (History Sync)

> Nguồn: APK QRing đã decompile bằng jadx (`sdks/qring/research/jadx-out/sources`). Vendor SDK: `com/oudmon/ble`, app: `com/qcwireless/smart`.
> Tài liệu chỉ dựa trên việc **đọc code**, chưa đối chiếu với log BLE thật. Chỗ nào là suy đoán thì có đánh dấu **(suy luận)**.

**Viết tắt đường dẫn** (tất cả nằm dưới `sdks/qring/research/jadx-out/sources/com/`):

| Viết tắt | Đường dẫn đầy đủ |
|---|---|
| `comm/` | `oudmon/ble/base/communication/` |
| `bt/` | `oudmon/ble/base/bluetooth/` |
| `utils/` | `oudmon/qc_utils/` |
| `app/` | `qcwireless/smart/` |
| `repo/` | `qcwireless/smart/ui/base/repository/healthy/` |
| `HVM` | `qcwireless/smart/ui/home/healthy/vm/HealthyViewModel` |

---

## 0. Tóm tắt nhanh

| Loại dữ liệu | Kênh | Lệnh (dec / hex) | Request | Độ phân giải | Đơn vị / scale |
|---|---|---|---|---|---|
| Bước chân / calo / quãng đường (chi tiết) | 16-byte | 67 / `0x43` | `dayOffset, 0x0F, startSlot, endSlot, 0x01` | 15 phút (96 slot/ngày) | calo: cal (×10 nếu "calorie new protocol"), quãng đường: m |
| Tổng bước hôm nay | 16-byte | 72 / `0x48` | không payload | — | big-endian 24-bit |
| Ngủ (cũ) | 16-byte | 68 / `0x44` | `dayOffset, 0x0F, 0, 95` | 15 phút | mã trạng thái + chất lượng |
| Ngủ (mới) | bigData | 39 / `0x27` | `[0x00 | 0xFF, 0x01]` | phân đoạn (giai đoạn, số phút) | 2=light, 3=deep, 4=REM, 5=awake |
| Ngủ trưa | bigData | 62 / `0x3E` | (đi kèm request 39) | phân đoạn | — |
| Nhịp tim lịch sử | 16-byte | 21 / `0x15` | timestamp 4 byte LE (giờ local) | `range` phút (mặc định 5) | bpm, uint8 |
| Nhịp tim theo interval (máy mới) | bigData | 117 / `0x75` | `[dayIndex, packetIndex]` | `interval` phút | bpm, uint8 |
| HRV | 16-byte | 57 / `0x39` | `[dayOffset]` | `range` phút (mặc định 30) | ms (suy luận), uint8 |
| Stress (pressure) | 16-byte | 55 / `0x37` | `[dayOffset]` | `range` phút (mặc định 30) | điểm 0–100 (suy luận), uint8 |
| SpO2 tự động | bigData | 42 / `0x2A` | `[0x00 | 0xFF…]` (app gửi 255) | 24 cặp mỗi ngày, có lẽ theo giờ (suy luận) | %, cặp (max, min) |
| SpO2 theo interval | bigData | 95 / `0x5F` | `[dayIndex, packetIndex]` | `interval` phút | %, uint8 |
| SpO2 đo tay | bigData | 73 / `0x49` | `[0x00 | 0xFF]` | từng lần đo | phút trong ngày + giá trị |
| Nhịp tim đo tay | bigData | 40 / `0x28` | `[0x00 | 0xFF]` | từng lần đo | phút trong ngày + giá trị |
| Nhiệt độ cơ thể | bigData | 119 / `0x77` | `[dayIndex, packetIndex]` | `interval` phút | uint16 LE / 100 = °C |
| Đường huyết | bigData | 71 / `0x47` | `[dayIndex]` (app gửi 255) | 24 cặp/ngày | (chưa rõ scale) |
| Huyết áp tự động | 16-byte | 13 / `0x0D` | không payload | bitmap × `timeDelay` phút | **giá trị là HR; app tự "ước tính" HA** |
| Huyết áp đo tay | 16-byte | 20 / `0x14` | `ts(4) 0x00 0x32` | từng bản ghi | mmHg |
| Bài tập (SportPlus) | bigData | 65→66, 67→68/69 | `ts(4)` / `type, ts(4)` | bản ghi bài tập + chuỗi HR | TLV |

---

## 1. Hai kênh truyền: đóng gói và ghép gói

### 1.1 Kênh lệnh 16 byte (service `6e40fff0`, write `6e400002`, notify `6e400003`)

**Request** (`comm/req/BaseReqCmd.java:23-32`): luôn đúng 16 byte.

| Byte | Ý nghĩa |
|---|---|
| 0 | `cmd` (bit 7 = cờ lỗi khi ring trả lời, xem `Constants.FLAG_MASK_ERROR = 128`, `comm/Constants.java:115`) |
| 1..14 | sub-data, phần còn lại điền 0 |
| 15 | checksum = `(Σ byte[0..14]) & 0xFF` (`BaseReqCmd.java:15-21`) |

**Response / notify** (`bt/QCBluetoothCallbackReceiver.java:19-22`, `bt/QCDataParser.java`):
- Chỉ nhận gói có **độ dài đúng 16** và checksum hợp lệ (`QCDataParser.checkCrc`, `:16-22`).
- `key = byte[0] & 0x7F` (`:48`). Lấy request đang chờ có cùng key, tạo bean qua `BeanFactory.createBean(key)` (`bt/BeanFactory.java:51-165`).
- Gọi `bean.acceptData(packet[1..14])`, tức là **payload 14 byte đã bỏ byte cmd và checksum** (`QCDataParser.java:62`).
  - Trả về `true`: còn gói tiếp theo. Bean được giữ trong `tempRspDataSparseArray` (`:63-64`).
  - Trả về `false`: bean đã đủ dữ liệu và callback `onDataResponse` được gọi (`:66-67`).
- Ghép nhiều gói vì vậy là **stateful theo cmd**: mỗi cmd chỉ có một bean đang dở dang.

> Ghi chú về offset trong tài liệu này: các bảng dưới đây dùng **offset trong gói 16 byte** (byte 0 = cmd). Trong code thì `bArr[i]` của `acceptData` tương ứng với **byte `i+1`** của gói.

**Bean factory cho các cmd lịch sử** (`bt/BeanFactory.java`): 13→`BpDataRsp` (:70), 20→`ReadBlePressureRsp` (:144), 21→`ReadHeartRateRsp` (:146), 55→`PressureRsp` (:114), 57→`HRVRsp` (:118), 67→`ReadDetailSportDataRsp` (:85), 68→`ReadSleepDetailsRsp` (:88), 72→`TodaySportDataRsp` (:126).
Các cmd **7, 19, 70** (`TotalSportDataRsp`, `ReadSportRsp`, `QueryDataDistributionRsp`) **không có trong BeanFactory**, và app cũng không dùng chúng. Đây là code cũ/chết; xem §7.

### 1.2 Kênh "serial port" / bigData (service `de5bf728-…`, notify `de5bf729`, write `de5bf72a`)

**Frame** (`comm/LargeDataHandler.java:186-199`; bản sao y hệt ở `bt/queue/BleConsumer.java:22-35` và `comm/sport/SportPlusHandle.java:129-142`):

| Offset | Size | Ý nghĩa |
|---|---|---|
| 0 | 1 | Magic `0xBC` (ghi trong code là `-68`) |
| 1 | 1 | `cmd`/action |
| 2..3 | 2 | `len` = độ dài payload, **little-endian** |
| 4..5 | 2 | CRC16 của payload, **little-endian** |
| 6.. | len | payload |

- **CRC16** (`comm/utils/CRC16.java:7-19`): init `0xFFFF`, đa thức phản xạ `0xA001`, không XOR đầu ra. Đây là **CRC-16/MODBUS**.
- **Payload rỗng**: `len = 0x0000` và CRC = `FF FF` (`LargeDataHandler.java:190-193`).
- **Chiều ghi**: frame được cắt thành các mảnh dài `JPackageManager.getLength()` (mặc định 20, tối thiểu 20; `comm/JPackageManager.java:6,25-27`). Các mảnh được ghi **write-without-response** liên tiếp (`BleConsumer.java:44-61`; `WriteRequest.getNoRspInstance`). Giá trị độ dài lấy từ cmd 47 `PackageLengthRsp` (`comm/responseImpl/PackageLengthListener.java:14`), tức là MTU mà ring báo về. Hàng đợi có dung lượng 20 frame (`bt/queue/BleThreadManager.java:13`).
- **Chiều nhận, ghép frame** (`bt/LargeDataParser.java:33-60`):
  1. Notification có `len ≥ 6` và `byte0 == 0xBC` khi đang ở trạng thái "intact": đọc `len` (byte 2..3).
     - Nếu `notif.length - 6 < len`: lưu vào `tempData` và chờ tiếp.
     - Nếu đủ: dispatch ngay.
  2. Ngược lại: nối vào `tempData` và dispatch khi `tempData.length - 6 == len`.
  3. Dispatch (`:62-69`): `respMap.get(byte[1])`, rồi `parseData(cmd, toànBộFrame)`. Vì frame **còn nguyên header**, các parser đọc payload bắt đầu từ `bArr[6]`.
- **Ring trả lời không được kiểm CRC**: parser không tính lại CRC16. Không có ACK, sequence number hay continuation ở tầng frame. Tầng frame chỉ có `len`.
- **Phân trang ở tầng ứng dụng**: một số lệnh (95/117/119) có trường `packetCount`/`packetIndex` trong payload. App phải **gửi lại request với `packetIndex+1`** để lấy trang kế tiếp (§5.2).
- `respMap` là map `cmd → callback`, mỗi cmd chỉ có một callback. Request mới cùng cmd sẽ ghi đè callback cũ (`LargeDataHandler.java:93`). Khi mất kết nối thì map bị xoá (`bt/QCBluetoothCallbackBigDataCloneReceiver.java:15`).
- Phải bật notify trên `de5bf729` trước (`LargeDataHandler.initEnable()`, `:587-590`). App làm việc này ngay khi discover service (`app/ui/base/receiver/MyBluetoothReceiver.java:287-314`).

---

## 2. Bước chân / calo / quãng đường

### 2.1 Chi tiết theo slot 15 phút: cmd 67 (`0x43`)

**Request** (`comm/req/ReadDetailSportDataReq.java:9-18`):

| Byte | Giá trị | Ghi chú |
|---|---|---|
| 0 | `0x43` | |
| 1 | `dayOffset` | 0 = hôm nay, 1 = hôm qua… Tối đa **29** (`:11-13`) |
| 2 | `0x0F` | 15 = độ dài slot (phút) (suy luận từ hằng số 15 và 96 slot) |
| 3 | `startSlot` | 0..95 |
| 4 | `endSlot` | ≤ 95 (`:14`) |
| 5 | `0x01` | chưa rõ ý nghĩa (suy luận: cờ báo app hỗ trợ "calorie new protocol") |
| 15 | checksum | |

App luôn gọi `ReadDetailSportDataReq(off, 0, 95)` (`repo/StepDetailRepository.java:354,373`).

**Response** (`comm/rsp/ReadDetailSportDataRsp.java:15-48`), nhiều gói:

| Gói | Nhận dạng | Bố cục |
|---|---|---|
| Không có dữ liệu | byte1 = `0xFF` khi đang ở gói đầu | kết thúc với danh sách rỗng (`:18-21`) |
| Header | byte1 = `0xF0` khi đang ở gói đầu | byte3 == `0x01` thì bật `calorieNewProtocol` (`:22-27`). byte2 có lẽ là số gói dữ liệu (suy luận, code không đọc) |
| Dữ liệu | các gói còn lại | xem bảng dưới |

Gói dữ liệu:

| Byte | Trường | Mã hoá |
|---|---|---|
| 1 | năm | BCD, +2000 (`:30`; `DeserializerCache.DEFAULT_MAX_CACHE_SIZE = 2000`) |
| 2 | tháng | BCD |
| 3 | ngày | BCD |
| 4 | `timeIndex` | 0..95, slot 15 phút từ 00:00 local |
| 5 | chỉ số gói hiện tại | |
| 6 | tổng số gói | kết thúc khi `byte5 == byte6 - 1` (`:43-45`) |
| 7..8 | calorie | uint16 **LE**. Nếu `calorieNewProtocol` thì **×10** (`:34-38`) |
| 9..10 | walkSteps | uint16 LE (`:39`) |
| 11..12 | distance | uint16 LE, mét (suy luận: app hiển thị `/1000` thành km) |
| 13..14 | không dùng | |

- `BLEDataFormatUtils.bytes2Int` là big-endian (`comm/utils/BLEDataFormatUtils.java:9-16`). Code truyền vào `{b[7], b[6]}` nên giá trị trên dây là **little-endian**.
- Đơn vị calo là **cal** (calo nhỏ): app hiển thị `getCarolie()/1000` thành kcal (`app/ui/home/healthy/adapter/MultipleItemQuickAdapter.java:1742`) (suy luận cho đơn vị ở mức slot).
- Thời điểm của slot = `localMidnight(Y-M-D) + timeIndex*900 s`. App lưu `StepDetail` với interval 900 (`repo/StepDetailRepository.java:132`; `repo/d.java:568-648`).
- Chỉ những slot có dữ liệu mới được gửi (sparse). Vì vậy `timeIndex` mới là khoá, không phải thứ tự gói.

**Ví dụ hex** (tự dựng, checksum đã tính đúng thuật toán):

```
TX  43 00 0F 00 5F 01 00 00 00 00 00 00 00 00 00 B2     ; hôm nay, slot 0..95
TX  43 01 0F 00 5F 01 00 00 00 00 00 00 00 00 00 B3     ; hôm qua
RX  43 F0 05 01 00 00 00 00 00 00 00 00 00 00 00 39     ; header, calorieNewProtocol=1
RX  43 26 10 12 20 00 05 23 00 F4 01 72 01 00 00 3B
     │  └─2026-10-12   │  │  │  └calo 0x0023=35 → ×10 = 350 cal
     │           slot 0x20=32 → 08:00–08:15      │  └steps 0x01F4=500, dist 0x0172=370 m
     │              gói 0 / tổng 5
```

### 2.2 Tổng hôm nay: cmd 72 (`0x48`)

- Request: `SimpleKeyReq(72)`, không payload, tức là `48 00 … 00 48` (`repo/StepDetailRepository.java:369`).
- Response gồm **1 gói** (`comm/rsp/TodaySportDataRsp.java:12-26`). Tất cả các trường đều **big-endian**:

| Byte | Trường |
|---|---|
| 1..3 | totalSteps (BE 24-bit) |
| 4..6 | runningSteps |
| 7..9 | calorie (cal) |
| 10..12 | walkDistance (m) |
| 13..14 | sportDuration (phút; SDK nhân ×60 thành giây) |

Ngày được gán bằng ngày hiện tại của điện thoại (`:20-24`).

---

## 3. Giấc ngủ

### 3.1 Giao thức cũ: cmd 68 (`0x44`)

**Request** (`comm/req/ReadSleepDetailsReq.java:11-22`): `[0x44, dayOffset(≤29), 0x0F, start, end]`. App dùng `(off, 0, 95)` (`repo/SleepDetailRepository.java:859,877`).

**Response** (`comm/rsp/ReadSleepDetailsRsp.java:15-45`) có cơ chế header `0xF0` / no-data `0xFF` giống cmd 67. Gói dữ liệu:

| Byte | Trường |
|---|---|
| 1..3 | năm/tháng/ngày BCD (+2000) |
| 4 | `timeIndex` (slot 15 phút) |
| 5 / 6 | chỉ số gói / tổng gói (kết thúc khi `b5 == b6-1`) |
| 7..13 | `sleepQualities[1..7]` (`iArr[i] = bArr[i+5]`, i=1..7; `[0]` luôn bằng 0) (`:33-37`) |

App chỉ dùng 3 giá trị (`repo/SleepDetailRepository.java:174-177`). Nó mã hoá chúng thành `q1*100000 + q2*1000 + q3` rồi giải mã ở `:290-400`:

| Trường | Ý nghĩa (theo cách app vẽ biểu đồ) |
|---|---|
| `q1` (byte 7) | Trạng thái slot: **1** = bắt đầu ngủ, **2** = kết thúc/thức dậy, **3/4/5** = đang ngủ, **6** = khoảng trống 15 phút (vẽ là "thức") |
| `q2` (byte 8) | Số phút ngủ trong slot (0..15). Khi bắt đầu ngủ, giờ vào giấc = `slotStart + (15 - q2)` phút (`f1/a.b(15,q2,60,idx*900)`) |
| `q3` (byte 9) | Chỉ số chất lượng: **≤ 50 thì deep**, **> 50 thì light**, **128** hoặc `q2 < 15` thì awake (`:309-342`) |

**Qua đêm**: app ghép `index` của **hôm qua** với `index + 96` của **hôm nay**, rồi chỉ xét cửa sổ index **71..167**, tức là từ 17:45 hôm qua đến 17:45 hôm nay (`:252, 283`). Nếu giây ≥ 64800 (18:00) thì tính là ngày hôm trước (`:302-304`). Vì thế mỗi lần đồng bộ, app luôn lấy lại cả **hôm qua** (`SleepDetailRepository.java:843-850`).

Ví dụ: `TX 44 00 0F 00 5F 00 … 00 B2`. Gói dữ liệu tự dựng: `44 26 10 13 5C 03 08 01 0A 28 00 00 00 00 00 27` nghĩa là 2026-10-13, slot 92 (23:00), q1=1 (bắt đầu ngủ), q2=10 phút, q3=40 (deep). Từ đó app suy ra giờ vào giấc là 23:05.

### 3.2 Giao thức mới: bigData cmd 39 (`0x27`) và ngủ trưa cmd 62 (`0x3E`)

App chọn giao thức này khi `SetTimeRsp.mNewSleepProtocol` (byte 9 của gói trả lời cmd 1 bằng 1; `comm/rsp/SetTimeRsp.java:67`).

**Request** (`comm/LargeDataHandler.java:891-931`): payload 2 byte `[sel, 0x01]`.
- `sel = 0x00` khi tham số `i == 0` (app gọi khi đồng bộ "hôm nay").
- `sel = 0xFF` khi khác 0 (app gọi khi đồng bộ lịch sử).
- Byte thứ hai luôn là `0x01`.
- Ý nghĩa đúng của `sel` là (suy luận): `0x00` = chỉ ngày gần nhất, `0xFF` = tất cả các ngày ring còn lưu.
- Cùng lúc, SDK đăng ký callback cho cả **39** (giấc chính) và **62** (ngủ trưa). Ring có thể đẩy cả hai frame về.

**Response 39**, payload (offset tính trong frame):

| Offset | Trường |
|---|---|
| 6 | `dayCount` (0 → callback `null`, `:896-904`) |
| 7.. | lặp lại `dayCount` bản ghi ngày, xem bảng dưới |

Bản ghi ngày (`parseDaySleep`, `:262-304`):

| Offset trong bản ghi | Size | Trường |
|---|---|---|
| 0 | 1 | `daysAgo` (0 = đêm kết thúc hôm nay) |
| 1 | 1 | `recLen`; độ dài bản ghi = `recLen + 2` |
| 2..3 | 2 | `startMinute` (LE) — **SDK đọc nhưng bỏ qua** (`:269`) |
| 4..5 | 2 | `endMinute` (LE), số phút tính từ 00:00 local của ngày `today - daysAgo` |
| 6.. | 2×n | các cặp `(t, d)`: `t` = giai đoạn, `d` = số phút (uint8) |

**Tính thời gian** (`:267-289`):
- `et = localMidnight(today − daysAgo) + endMinute*60`
- `st = et − Σd*60`

Đêm vượt qua nửa đêm được xử lý **tự nhiên**: chỉ neo theo giờ kết thúc rồi lùi lại theo tổng thời lượng. `startMinute` (ví dụ 1380 = 23:00) chỉ để tham khảo.

**Mã giai đoạn** (`repo/SleepDetailRepository.java:138-162` dùng để tính tổng; `:716-740` để vẽ; `app/ui/base/repository/entity/SleepTotalHistory.java:110-129` cho tên trường):

| `t` | Ý nghĩa | Trường lưu |
|---|---|---|
| 0, 1 | không có dữ liệu / chưa xác định (vẽ như "awake", `c=4`) (suy luận) | — |
| **2** | **Light** | `lightSleep` |
| **3** | **Deep** | `deepSleep` |
| **4** | **REM** | `rapidSleep` |
| **5** | **Awake** | `awake` |

`totalSleep` của app = tổng của 2+3+4+5 (có tính cả awake, `:159-167`).

Lưu ý về điều kiện lặp: bản ghi tiếp theo chỉ được parse khi `offsetTuyệtĐốiKếtThúc < len` (`:294`), tức là phải còn hơn 6 byte payload. Một bản ghi ngày ≤ 6 byte (không có cặp giai đoạn nào) ở cuối frame sẽ bị bỏ qua.

**Response 62 (ngủ trưa)** dùng cùng khung (`:908-923`, `parseDaySleepLunch` `:307-403`):
- `lunchSt = midnight + startMinute*60`, `lunchEt = midnight + endMinute*60`.
- Các byte từ offset 6 được đọc theo cặp `(flag, phút)`. `flag != 0` nghĩa là đang ngủ và cộng dồn vào đoạn hiện tại. `flag == 0` đóng đoạn đó lại và mở đoạn mới sau `phút`. Kết quả là danh sách `LunchSleepBean{startTime,endTime}`.

**Ví dụ hex** (tự dựng, CRC16/MODBUS đã tính):

```
TX  BC 27 02 00 C0 70 00 01                    ; sel=0x00 (hôm nay), 0x01
RX  BC 27 19 00 91 FF                          ; len=25, crc=0xFF91
    01                                         ; 1 ngày
    00 16 64 05 A4 01                          ; daysAgo=0, recLen=22, start=0x0564=1380 (23:00), end=0x01A4=420 (07:00)
    02 3C 03 5A 02 3C 04 1E 02 5A 03 3C 04 28 05 0A 02 28
    ; light60 deep90 light60 REM30 light90 deep60 REM40 awake10 light40 → Σ=480 phút
```

Kết quả: `et` = hôm nay 07:00 local, `st = et − 480 phút` = hôm qua 23:00.

---

## 4. Nhịp tim lịch sử: cmd 21 (`0x15`)

**Request** (`comm/req/ReadHeartRateReq.java:9-12`): 4 byte timestamp **LE** (`DataParseUtils.intToByteArray`, `comm/utils/DataParseUtils.java:11-18`).

App truyền vào **"local epoch"** của 00:00 ngày cần lấy, tức là `localMidnight_unix + tzOffsetSec` (giờ tường local mã hoá như thể là UTC):
- Lịch sử: `repo/HeartRateDetailRepository$syncHistoryHeartDetail$2.java:54-66`.
- Hôm nay: `now + tzOffset` (`repo/HeartRateDetailRepository.java:588`).

**Response** (`comm/rsp/ReadHeartRateRsp.java:22-57`):

| Gói (byte1) | Bố cục |
|---|---|
| `0xFF` | không có dữ liệu → kết thúc |
| `0x00` | byte2 = `size` (tổng số gói, kể cả gói 0), byte3 = `range` (phút/điểm, mặc định 5) |
| `0x01` | byte2..5 = timestamp LE (**local epoch**), byte6..14 = 9 giá trị HR đầu tiên |
| `k` = 2..size−1 | byte2..14 = 13 giá trị HR. Kết thúc khi `k == size−1` (`:42-45`) |

- **Múi giờ**: SDK lấy `mUtcTime = raw − tzOffset` (`:35-36`, `getTimeZone()` ở `:17-19`). Ring lưu thời gian theo **giờ tường local** và không biết timezone. `SetTimeReq` chỉ gửi Y-M-D-h-m-s dạng BCD theo giờ local, không có trường TZ (`comm/req/SetTimeReq.java:26-31`).
- Mảng giá trị: điểm thứ `i` ứng với thời điểm `localMidnight + i*range` phút. App lưu tối đa `1439/range + 1` điểm (`app/ui/base/repository/entity/HeartRateDetailPayloadGuard.java` `safePointCount`; `repo/d.java:200-229`). `getmHeartRateArray()` cắt hoặc độn mảng về 288 điểm (`ReadHeartRateRsp.java:63-93`).
- Với `range=5`: 288 điểm = 9 + 13×21 = 282, cộng thêm gói cuối, nên `size = 24` (gói 0..23).
- Quirk: nếu ngày là **hôm nay** và nhận được gói số 23 thì SDK kết thúc mà **không chép** gói đó (`:26`). Gói này chứa slot 23:30–23:55, vốn nằm trong tương lai.
- Giá trị 0 nghĩa là không đo (app bỏ qua khi vẽ) (suy luận).

**Ví dụ hex** (UTC+7, ngày 2026-10-13 00:00 local, local-epoch = `0x6ACD7480`):

```
TX  15 80 74 CD 6A 00 00 00 00 00 00 00 00 00 00 40
RX  15 00 18 05 00 00 00 00 00 00 00 00 00 00 00 32    ; size=24, range=5 phút
RX  15 01 80 74 CD 6A 00 00 00 00 00 3C 3E 40 3B 36    ; ts local, HR[0..8] (00:00..00:40); 00:25=60 bpm…
RX  15 02 3A 3A 3A 3A 3A 3A 3A 3A 3A 3A 3A 3A 3A 09    ; HR[9..21] = 58 bpm
…   (đến gói 0x17)
```

Thời điểm UTC thật = `0x6ACD7480 − 7*3600` = `0x6ACD1210`.

### 4.1 HR theo interval (máy mới, cờ `supportRealTimeHr`): bigData 117 (`0x75`)

Xem §5.2. App dùng đường này thay cho cmd 21 khi `DeviceSupportFunctionRsp.supportRealTimeHr` (`repo/HeartRateDetailRepository.java:108-189`).

### 4.2 HR đo tay: bigData 40 (`0x28`)

Xem §5.3.

---

## 5. Các chỉ số khác

### 5.1 HRV (cmd 57 `0x39`) và Stress (cmd 55 `0x37`), cùng khuôn

- Request: `[cmd, dayOffset]` (`comm/req/HRVReq.java:7-10`, `comm/req/PressureReq.java:7-10`, qua `MixtureReq`).
- Response (`comm/rsp/HRVRsp.java:15-52`, `comm/rsp/PressureRsp.java:15-52`):

| Gói (byte1) | Bố cục |
|---|---|
| `0xFF` | không có dữ liệu |
| `0x00` | byte2 = `size`, byte3 = `range` (phút, mặc định 30) |
| `0x01` | byte2 = `dayOffset` (SDK tính ngày = hôm nay − offset, `:36-37`), byte3..14 = 12 giá trị đầu |
| `k ≥ 2` | byte2..14 = 13 giá trị. Kết thúc khi `k == size−1` |

- Giá trị là uint8 (app chuyển `byteToInt`). Điểm `i` ứng với `localMidnight + i*range` phút (suy luận từ cách app lưu `index_str = 0,1,2…` kèm `interval = range`, `repo/d.java:111-140, 383-412`).
- Với range = 30 có 48 điểm = 12 + 13×3, nên `size = 5`.
- Đơn vị: HRV có lẽ là ms; stress là điểm 0–100 (suy luận, code không nói rõ).

```
TX  39 01 00 00 00 00 00 00 00 00 00 00 00 00 00 3A      ; HRV hôm qua
RX  39 00 05 1E 00 00 00 00 00 00 00 00 00 00 00 5C      ; size=5, range=30
RX  39 01 01 2A 30 2D 00 00 00 00 00 00 00 00 33 F5      ; offset=1; 00:00=42, 00:30=48, 01:00=45 … 05:30=51
TX  37 00 00 00 00 00 00 00 00 00 00 00 00 00 00 37      ; stress hôm nay
```

### 5.2 Chuỗi theo interval qua bigData: SpO2 95 (`0x5F`), HR 117 (`0x75`), nhiệt độ 119 (`0x77`)

**Request**: payload `[dayIndex, packetIndex]` (`LargeDataHandler.java:479-496`). App bắt đầu với `packetIndex = 0`.

> Lưu ý: hàm private `syncIntervalHeartRate` (`:484-486`) gọi nhầm `syncIntervalBloodOxygenReal`, nhưng hàm public `syncIntervalHeartRateWithCallback` (`:1027-1081`) dùng đúng cmd 117.

**Response payload**:

| Offset (frame) | Trường |
|---|---|
| 6 | `dayIndex` |
| 7 | `interval` (phút) |
| 8 | `packetCount` |
| 9 | `packetIndex` |
| 10.. | giá trị: **uint8** cho SpO2 và HR (`getIntervalOxygen`, `:222-228`); **uint16 LE / 100 = °C** cho nhiệt độ (`getIntervalTemperature`, `:231-241`) |

**Phân trang** (`:996-1019`, `:1053-1076`, `:153-176`):
- `packetCount == 0`: không có dữ liệu.
- `packetIndex == packetCount−1`: trang cuối.
- `packetIndex < packetCount−1`: SDK tự gửi lại request với `packetIndex+1` rồi nối mảng.

Điểm `i` ứng với phút `i*interval` trong ngày `today − dayIndex`. App lọc `i*interval < 1440` và với hôm nay thì chỉ giữ ≤ phút hiện tại (`repo/TemperatureRepository.java:182-224`).

```
TX  BC 77 02 00 01 B0 00 00                     ; nhiệt độ, hôm nay, trang 0
RX  BC 77 0A 00 2A 7D 00 1E 01 00 3C 0E 4E 0E 00 00
    ; day0, interval=30, 1 trang, trang 0: 0x0E3C=3644→36.44°C (00:00), 0x0E4E=36.62°C (00:30), 0 (không đo)
TX  BC 75 02 00 01 B0 00 00                     ; HR interval hôm nay
TX  BC 5F 02 00 01 B0 00 00                     ; SpO2 interval hôm nay
```

### 5.3 Đo tay: HR 40 (`0x28`), SpO2 73 (`0x49`)

- Request payload 1 byte: `0x00` nếu tham số = 0, ngược lại `0xFF` (`LargeDataHandler.java:852-856, 884-888`). App gửi 255 nếu hôm qua chưa có dữ liệu, ngược lại gửi 0.
- Response (`:827-851`, `:859-883`):

| Offset | Trường |
|---|---|
| 6 | `index` = số ngày trước (app: `today − index`, `repo/b.java:60,113`) |
| 7.. | bộ 3 byte: `m` = uint16 LE (phút trong ngày, 0..1439), `v` = uint8 |

App tính `ts = localMidnight + m*60` (`repo/b.java:68-76`).

```
TX  BC 28 01 00 BF 40 00
RX  BC 28 07 00 E7 9A 00 E0 01 48 1C 02 50     ; hôm nay: 08:00 (480)=72 bpm, 09:00 (540)=80 bpm
```

### 5.4 SpO2 tự động: bigData 42 (`0x2A`); đường huyết 71 (`0x47`) cùng khuôn

- Request payload `[i]` (`LargeDataHandler.java:732-740`). App luôn gửi `255` (`0xFF`).
- Response: phần **parse nằm trong app** (`repo/a.java:45-111` cho SpO2, `:120-187` cho đường huyết). Payload là `len/49` bản ghi, mỗi bản ghi 49 byte:

| Offset trong bản ghi | Trường |
|---|---|
| 0 | `daysAgo` |
| 1,3,5,…,47 (lẻ) | `maxArray[0..23]` |
| 2,4,6,…,48 (chẵn) | `minArray[0..23]` |

(Tên trường lấy theo constructor `BloodOxygenEntity(…, minArray, maxArray, …)`, `app/ui/base/repository/entity/BloodOxygenEntity.java:49-57`.) 24 cặp có lẽ ứng với 24 giờ trong ngày (suy luận).
- `len == 0` (không bản ghi nào): app xoá bản ghi hôm nay.

```
TX  BC 2A 01 00 BF 40 00
RX  BC 2A 31 00 FF 1D  00  62 5F 62 5F 00 00 …(×22)   ; daysAgo=0; 00h max98/min95; 01h 98/95
```

### 5.5 Huyết áp

**Tự động: cmd 13 (`0x0D`)**. Request `SimpleKeyReq(13)` = `0D 00…00 0D` (`repo/BloodPressureRepository.java:187`). Response (`comm/rsp/BpDataRsp.java:14-46`):

| Gói (byte1) | Bố cục |
|---|---|
| `0x00` | byte2 = năm (SDK tính `byte + (-48)`, `:20`; xem ghi chú), byte3 = tháng, byte4 = ngày, byte5 = `timeDelay` (phút), byte6..11 = **bitmap 48 bit**. Bit `n` = 1 nghĩa là có mẫu tại phút `n*timeDelay` (`:21-28`) |
| `0x01` | byte2..14 = 13 giá trị uint8, gán tuần tự vào các mẫu. Kết thúc khi đã đủ (`:30-41`). (byte1 luôn là `0x01` cho mọi gói tiếp nối, không có số thứ tự) |
| `0xFF` | kết thúc |

- Ghi chú về năm: `-48` là `(byte)(2000)`. Rất có thể ý định là `2000 + yy`, nhưng jadx/compiler đã ép kiểu thành byte. Khi tự cài đặt, nên dùng `2000 + byte2` (suy luận).
- Sau khi nhận xong, app gửi xác nhận `BpReadConformReq(true)`: `0E 00 … 0E` (lỗi thì gửi `0xFF`) (`comm/req/BpReadConformReq.java`; `repo/BloodPressureRepository$syncAutoBp$1$1.java:174`).
- **Quan trọng**: giá trị trong gói là **nhịp tim**. App **tự sinh SBP/DBP** từ HR + tuổi + `Math.random()` (`…$syncAutoBp$1$1.java:88-159`; nếu giá trị ≤ 50 thì thay bằng `70 + rand(5)`, `:93`). Không nên coi đây là số đo huyết áp thật.

**Đo tay: cmd 20 (`0x14`)**. Request (`comm/req/ReadPressureReq.java:9-18`): `ts(4 byte LE) 0x00 0x32` (0x32 = 50 bản ghi tối đa). App gửi `ts = 0`. Response (`comm/rsp/ReadBlePressureRsp.java:24-40`): **mỗi gói một bản ghi**.

| Byte | Trường |
|---|---|
| 1..4 | timestamp LE (**local epoch**; SDK trừ tzOffset, `:33-35`). `FF FF FF FF` = kết thúc |
| 5 | DBP (mmHg) |
| 6 | SBP (mmHg) (`new BlePressure(ts, sbp=b[5], dbp=b[4])`, `:36`) |

Dừng khi nhận đủ 50 gói (`Constants.BAND_PRESSURE_COUNT`).

```
TX  14 00 00 00 00 00 32 00 00 00 00 00 00 00 00 46
RX  14 08 EC CD 6A 4E 78 00 00 00 00 00 00 00 00 05   ; 2026-10-13 08:30 local, DBP 78, SBP 120
```

### 5.6 Bài tập (SportPlus) qua bigData: `comm/sport/SportPlusHandle.java`

Không đi qua `LargeDataParser`/`respMap`. `SportPlusHandle.init()` gắn callback vào `BleOperateManager.setCallback` (`:342-348`) để nhận **mọi** notification và tự lọc theo `0xBC` + cmd (`:36-116`).

| Bước | Hướng | Frame | Ghi chú |
|---|---|---|---|
| 1 | TX | `BC 41 04 00 crc ts(4 LE)` | `cmdSummary(ts)` (`:336-340`). `ts=0` = tất cả; app gửi `startTime` của bài tập cuối đã lưu (`repo/SportPlusRepository.java:182-184`) |
| 2 | RX | `BC 42 len crc …` | Summary, có thể dài qua nhiều notification (ghép theo `len`, `:41-74`) |
| 3 | TX | `BC 43 05 00 crc type ts(4 LE)` | `cmdRequest` cho từng bài tập (`:329-334`) |
| 4 | RX | `BC 44 …` | Mô tả chi tiết (`parseRequest`, `:199-228`): `[0]=status(≠0 thì bỏ qua)`, `[1..2]=packageCount LE`, `[3]=sampleSecond`, `[4..]` các cặp `(size, dataType)` |
| 5 | RX | `BC 45 …` | Dữ liệu chi tiết (`parseDetails`, `:165-196`): `[0..1]=packageId LE`, tiếp theo là các mẫu dài `Σsize`. App chỉ lấy `dataType 17` = `rate_real` (HR) |

**Summary** (`parseSummary`, `:231-269`):
- `[0] = số bài tập`. Mỗi bài tập: `[len][sportType][TLV…]`.
- Mỗi TLV: `[tlvLen][key][value(tlvLen−2), LE]`.
- Các key (`SportPlusData.java`): 1 start_time, 2 duration, 3 distance, 4 calories, 5/6 speed avg/max, 7/8/9 HR avg/min/max, 10 elevation, 11 uphill, 12 downhill, 13 step_rate, 14 sport_count, 19 steps.
- Loại bài tập (`SportPlusType.java`): 1 GPS run, 2 GPS ride, 3 GPS walk, 4 run, 5 jump, 6 swim, 7 run2, 8 walk, 9 ride, 10 train, 11 swing, 12–14 app run/ride/walk.
- App format ngày của `startTime` theo `Asia/Shanghai` (`repo/b.java:153`). Có lẽ là bug của app. Bản chất `startTime` (UTC thật hay local-epoch) **chưa xác định** (suy luận).

---

## 6. Trình tự đồng bộ thực tế của app

### 6.1 Sau khi kết nối

1. `MyBluetoothReceiver.onServiceDiscovered()` (`app/ui/base/receiver/MyBluetoothReceiver.java:287-314`) chạy theo thứ tự:
   1. `LargeDataHandler.initEnable()` (bật notify `de5bf729`).
   2. Đọc HW/FW revision.
   3. `SimpleKeyReq(3)` (pin).
   4. `DeviceCmdInit.a()`.
2. `DeviceCmdInit$initDeviceSetting$1` xếp hàng các lệnh mà **không chờ** trả lời:
   - `SetTimeReq` (`:146`): 7 byte BCD `[yy, MM, dd, hh, mm, ss, language]`, giờ **local**, không có TZ.
   - `BindAncsReq`, rồi `DeviceSupportReq` (cmd 60) (`:425-427`), rồi một loạt lệnh đọc cài đặt.
   - Sau đó post ngay `BluetoothSyncEvent` (`:998-1000`).
   - **Race**: cờ năng lực có thể vẫn là giá trị cache từ lần kết nối trước.
3. `HealthyFragment.onMessageEvent(BluetoothSyncEvent)` kích hoạt pull-to-refresh (`app/ui/home/healthy/HealthyFragment.java:5070-5081`, `C()` tại `:4061`). Refresh listener (`com/realsil/sdk/bbpro/c0/d.java:321-347`):
   1. `FileHandle.start()` (danh sách file, cmd 48).
   2. Sau 3 s thì `HVM` msg 1.
   - `onResume` cũng gọi lại, có throttle **10 phút** (`Action_lastTenMinSyncTime`).

### 6.2 Chuỗi "hôm nay" (tuần tự: bước sau chạy trong callback của bước trước)

| # | Request | Nguồn |
|---|---|---|
| 1 | `SimpleKeyReq(72)` (tổng hôm nay), rồi `ReadDetailSportDataReq(0,0,95)` | `repo/StepDetailRepository.java:368-373`, `HVM.java:333-337` |
| 2 | Ngủ hôm nay. Cũ: `ReadSleepDetailsReq(0)` rồi `(1)`. Mới: `syncSleepList(0)` | `repo/SleepDetailRepository.java:877, 987-993` |
| 3 | `PressureReq(0)`, rồi `HRVReq(0)` | `repo/PressureRepository.java:232`, `repo/HRVRepository.java:274` |
| 4 | (nếu hỗ trợ Muslim) `MuslimReq(0)` | |
| 5 | HR hôm nay: `syncIntervalHeartRateWithCallback(0)` nếu `supportRealTimeHr`, ngược lại `ReadHeartRateReq(now+tz)` | `repo/HeartRateDetailRepository.java:506-588` |
| 6 | SportPlus hôm nay (`cmdSummary`). Callback, hoặc timeout 4 s, sẽ gọi `HVM.f()` | `HVM.java:719-757, 339-344` |

### 6.3 `HVM.f()` (`HVM.java:382-594`): chạy song song, mỗi việc được bật bằng một cờ

| Độ trễ | Việc | Cờ |
|---|---|---|
| 0 ms | SpO2 `syncBloodOxygen(255)` (+ đo tay `syncManualBloodOxygenList`) | `mSupportBloodOxygen` (SetTimeRsp byte4 bit1) |
| 800 ms | HR đo tay `syncManualHeartRateList(255/0)` | `mSupportManualHeart` (byte12 bit0) |
| 1600 ms | BP `SimpleKeyReq(13)`, rồi (nếu rỗng) `ReadPressureReq(0)` | `mSupportBloodPressure` (byte4 bit2) |
| 2400 ms | Đường huyết `syncBloodSugar(255)` | `mSupportBloodSugar` (byte12 bit7) |
| 3200 ms | Nhiệt độ: `syncIntervalTemperatureWithCallback(0..6)` nếu `supportIntervalTemp`, ngược lại `FileHandle.startObtainTemperatureSeries` | `mSupportTemperature` / `supportTempBoth` |
| song song | `syncHistoryData` (§6.4) | — |

(Vị trí byte theo gói 16 byte của cmd 1, `comm/rsp/SetTimeRsp.java:48-94`. Ví dụ `mSupportHrv` = byte14 bit5, `mSupportPressure` = byte14 bit4. Hai cờ này được lưu lại nhưng **không** dùng để chặn đồng bộ HRV/stress.)

### 6.4 Chuỗi lịch sử (tuần tự)

Thứ tự: **Steps → Sleep → (Muslim) → HRV → Stress → Heart rate**. Bước cuối ghi `LastSyncHistoryTimeStamp = now` và post `DataSyncEvent(false)` (`HVM$syncHistoryHeartDetail$1$1$2.java:49-55`).

- **Khi nào chạy** (`HVM$syncHistoryData$1`): nếu `DeviceSetting["com.qcwxkjvip.LastSyncHistoryTimeStamp"]` rỗng hoặc trước 00:00 hôm nay, **hoặc** một trong 6 ngày (hôm qua … 6 ngày trước) chưa có `HeartRateDetail` với `lastSyncTime` là hôm nay.
- **Chọn ngày**: mỗi loại tạo map `dateStr → offset` cho offset **1..6**. Sau đó bỏ những ngày đã có bản ghi DB với `lastSyncTime.isToday()` (ví dụ `repo/HeartRateDetailRepository$syncHistoryHeartDetail$2.java:60-69`).
  - Mỗi ngày gửi một request, request tiếp theo đi từ handler của response trước (`repo/d.java:144-160, 237-250, 413-432`).
  - Request theo loại: `ReadDetailSportDataReq(off,0,95)`, `ReadSleepDetailsReq(off,0,95)` hoặc `syncSleepList(0xFF)`, `HRVReq(off)`, `PressureReq(off)`, `ReadHeartRateReq(localMidnight(today−off)+tz)`.
- **Không có marker tăng dần phía ring**: không gửi "since timestamp". Lịch sử luôn là "lấy lại nguyên ngày theo offset". Ngày đầu tiên của mỗi ngày mới sẽ lấy lại toàn bộ 6 ngày. Hôm nay luôn được lấy lại.
- Ngoại lệ có tính "tăng dần": `cmdSummary(lastStartTime)` của SportPlus, và tham số 0/255 của manual HR.
- Timeout: các message 6/7/8/21/23/25/888 được post nhưng handler (`HVM.java:325-347`) chỉ xử lý 1 và 887. Thực tế **không có retry**: một bước bị treo sẽ dừng cả chuỗi. `SyncStatus` tự xoá sau 13 s.

### 6.5 Gợi ý cho SDK riêng (suy luận)

1. Bật notify trên cả `6e400003` và `de5bf729`. Đọc cmd 47 để lấy độ dài gói.
2. Gửi `SetTimeReq` (giờ local) rồi **chờ** `SetTimeRsp` để có cờ năng lực (`mNewSleepProtocol`, SpO2, BP, nhiệt độ…). Sau đó gửi `DeviceSupportReq` (cmd 60) để biết `supportRealTimeHr` và `supportIntervalTemp`.
3. Mỗi cmd chỉ có một request đang chờ. Nên làm tuần tự, có timeout khoảng 3–5 s cho mỗi cmd.
4. Lưu marker theo `(loại, ngày)`. Ngày hôm nay và hôm qua luôn lấy lại; các ngày cũ hơn thì có thể bỏ qua nếu đã lấy sau khi ngày đó kết thúc.
5. Mọi timestamp ring trả về đều là **local epoch**. Khi chuyển sang UTC phải trừ offset timezone **của ring lúc ghi**. Khi người dùng đổi múi giờ thì không có cách phân biệt (suy luận).

---

## 7. Lệnh cũ / không dùng (đọc từ SDK nhưng app không gọi)

| Cmd | Lớp | Bố cục (đọc từ code) |
|---|---|---|
| 7 `0x07` | `ReadTotalSportDataReq` / `TotalSportDataRsp` | Req `[dayOffset]`. Rsp 2 gói: gói 0 = `daysAgo(BCD), Y M D (BCD), totalSteps(3 BE), runningSteps(3 BE), calorie(3 BE)`; gói 1 = `daysAgo, Y M D, distance(3 BE), sportDuration(2 BE, phút), sleepDuration(2 BE, phút)` (`comm/rsp/TotalSportDataRsp.java:20-70`) |
| 19 `0x13` | `ReadBandSportReq` / `ReadSportRsp` | Req `ts(4 LE)`. Rsp có header `[0, size]`, sau đó các gói 13 byte. Bản ghi gồm 7 int32 LE: start, duration, type, steps, distance, calories, rateCount, rồi `rateCount` byte HR (`comm/rsp/ReadSportRsp.java:15-75`) |
| 70 `0x46` | `QueryDataDistributionRsp` | int32 BE. Bit `i` = 1 nghĩa là ngày `i` có dữ liệu (`:9-16`) |
| 44 `0x2C` (16-byte) | `BloodOxygenSettingRsp` | Chỉ là cài đặt SpO2 tự động (`enable`, `interval`), không phải lịch sử |

Ba cmd 7/19/70 **không có trong BeanFactory**, nên dù có gửi thì SDK cũng không parse được. Ring có thể vẫn hỗ trợ (suy luận).

---

## 8. Danh sách lệnh bigData trong `LargeDataHandler`

| Cmd (dec/hex) | Hằng | Hướng / payload request | Bean / callback |
|---|---|---|---|
| 32 / `0x20` | `ACTION_Location_Protocol` | ring hỏi vị trí, app gửi `writeLocation` | `ILargeDataResponse` thô |
| 39 / `0x27` | `ACTION_New_Sleep_Protocol` | `[0x00|0xFF, 0x01]` | `SleepNewProtoResp` (`st, et, list<DetailBean{t,d}>`) |
| 40 / `0x28` | `ACTION_ManualHeartRate_Protocol` | `[0x00|0xFF]` | `ManualHeartRate{index, data<DetailBean{m,v}>}` |
| 41 / `0x29` | `ACTION_Contacts_New` | ghi danh bạ (nhiều phần, chờ ACK `[6]==0`) | `BaseBean` |
| 42 / `0x2A` | `ACTION_Blood_Oxygen` | `[day|0xFF]` | thô (app parse, §5.4) |
| 44 / `0x2C` | `ACTION_Alarm` | đọc `[1]` / ghi `[2,…]` | thô |
| 45 / `0x2D` | `ACTION_Contact` | ghi | — |
| 46 / `0x2E` | `ACTION_BT_MAC_Protocol` | `[0]` | `ClassicBluetooth{mac=[6..11], name}` |
| 47 / `0x2F` | `ACTION_E_CARD_Protocol` | `[1,type]` / `[2,type,len,url]` | `ECardEntity` |
| 58 / `0x3A` | `ACTION_Custom_WatchFace` | đọc `[1]` / ghi `[2,…]` | thô |
| 62 / `0x3E` | `ACTION_New_Sleep_Protocol_Lunch` | (đi kèm 39) | `SleepNewProtoResp` (lunch) |
| 71 / `0x47` | `ACTION_Blood_Sugar` | `[day|0xFF]` | thô (app parse) |
| 72 / `0x48` | `ACTION_GPS_Navigation` | ghi | — |
| 73 / `0x49` | `ACTION_Manual_Oxygen` | `[0x00|0xFF]` | `ManualBloodOxygen{index, data<{m,v}>}` |
| 74 / `0x4A` | `ACTION_AVATAR_Device` | ghi nickname | — |
| 95 / `0x5F` | `ACTION_Interval_Blood_Oxygen` | `[day, pkt]` | `IntervalBloodOxygenEntity{dayIndex, interval, array<Int>}` |
| 117 / `0x75` | `ACTION_Interval_Heart_Rate` | `[day, pkt]` | `IntervalHeartRateEntity{…}` |
| 118 / `0x76` | `ACTION_Emergency_Contact` | `[i,1]` / ghi | thô |
| 119 / `0x77` | `ACTION_Interval_Temperature` | `[day, pkt]` | `IntervalTemperatureEntity{…, array<Float °C>}` |
| 120 / `0x78` | `ACTION_Single_Measure_ECG` | `[1, stop?1:0, durLo, durHi]` | `SingleMeasureEcgEntity{type=[6], status=[7], hr=[8], width=[9], len=[10..11], values (2 hoặc 4 byte LE có dấu)}` |
| −111 / `0x91` | `ACTION_WIFI_RECORD_TRANSFER` | `[subType(1..4), …]` | `WifiRecordFileResModel` |
| 65→66, 67→68/69 | (SportPlusHandle) | §5.6 | `SportPlusEntity` |

Nguồn: `comm/LargeDataHandler.java:52-76` (hằng số) và các hàm tương ứng `:517-1122`; các bean nằm trong `comm/bigData/bean/`, callback trong `comm/bigData/resp/`.

---

## 9. Phụ lục: tiện ích giải mã

| Hàm | Endianness | Nguồn |
|---|---|---|
| `BLEDataFormatUtils.bytes2Int(arr)` | **big-endian** theo thứ tự mảng truyền vào | `comm/utils/BLEDataFormatUtils.java:9-16` |
| `BLEDataFormatUtils.BCDToDecimal` | BCD | `:5-7` |
| `ByteUtil.bytesToInt` / `DataTransferUtils.bytesToInt` | **little-endian** (1–4 byte) | `comm/utils/ByteUtil.java:122-136`; `utils/bytes/DataTransferUtils.java:60-74` |
| `DataParseUtils.intToByteArray` / `byteArrayToInt` | little-endian 4 byte | `comm/utils/DataParseUtils.java:5-18` |
| `DateUtil.getZeroTime()` | unix giây của 00:00 local | `utils/date/DateUtil.java:622-624` |
| `ReadHeartRateRsp.getTimeZone()` | offset hiện tại của điện thoại, tính bằng giờ (float) | `comm/rsp/ReadHeartRateRsp.java:17-19` |
