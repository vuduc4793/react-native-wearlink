# 08 — Cấu hình phần cứng Y25 và HT43

> Mục đích: biết linh kiện bên trong hai đồng hồ để chuẩn bị cho việc làm firmware sau này.
> Phương pháp: **chỉ đọc**. Nguồn gồm:
> - chuỗi và bảng driver trong firmware Y25 (`research/firmware/RB370L73AC_V001205.bin`);
> - code GloryFit 4.0.12 (`research/jadx-out/sources`) và GloryFitPro 1.9.0.2 (`research/xapk-pro/jadx-out/sources`);
> - bảng tính năng `33F1/34F1` đã đọc từ đồng hồ (01-protocol §10, §11);
> - tra cứu web, có ghi URL.
>
> Không kết nối BLE, không chạy adb/ssh, không flash.
> Offset firmware tính từ đầu file. Địa chỉ chạy = offset + `0x0209BE00` (xem 05-firmware-analysis §1).
> Phần nào không đọc thẳng từ dữ liệu thì ghi **(suy luận)**.
> Độ tin cậy:
> - **Cao**: đọc thẳng từ byte hoặc code, hoặc in trên chip.
> - **TB** (trung bình): có nhiều dấu hiệu gián tiếp.
> - **Thấp**: phỏng đoán hoặc chỉ có một nguồn bán hàng.

---

## 0. Kết luận nhanh

| | Y25 (`Y25(ID-6E1B)`, `RB370L73ACV001205`) | HT43 (`HT43(ID-2750)`, `RH370L73ACCV000788`) |
|---|---|---|
| SoC | Realtek **RTL8773EWE-VP**: dòng RTL87x3E, lõi ARM Cortex-M4F + DSP audio, BT 5.3 hai chế độ, IC "BB2_PLUS" | Như Y25 **(suy luận)** |
| Flash | 128 Mbit = **16 MB** QSPI NOR (trong gói hoặc ngoài), chạy 4-bit DTR 160 MHz | Như Y25 **(suy luận)** |
| Màn hình | AMOLED tròn 466 × 466, IC **ICNA3310** (Chipone) | 466 × 466 tròn; bản rao bán ghi 1,32″ |
| Cảm ứng | Hynitron **CST816S/T/D** (firmware tự dò; bản rao bán ghi CST820) | Như Y25 **(suy luận)** |
| Gia tốc | Sensortek **STK8321** (hoặc STK8325/8327, tự dò) | Như Y25 **(suy luận)** |
| PPG (HR/SpO2) | Vcare **VC30F-S** | VC30F(-S) **(suy luận)**; firmware báo **không có huyết áp** |
| GNSS | Firmware có driver **ICOE CC1165W** và luồng AGPS. Bit "ephemeris" bật. Có lắp hay không: **chưa chắc** | **Có GPS, chip ICOE CC1165W** (đồng hồ xin AGPS; bản rao bán ghi CC1165W) |
| Gọi điện BT | Có: HFP/A2DP, codec trong SoC, mic + loa | Có |
| La bàn / áp kế | Có code và cấu hình, **không** thấy tên driver | Bản rao bán ghi có la bàn |
| OUI MAC `78:02:B7` | ShenZhen **Ultra Easy** Technology (UTE, hãng làm GloryFit) | Như Y25 |

Hai máy dùng **chung một nền tảng phần mềm của UTE**: dòng "370", hậu tố "L73".
- Bảng `33F1` giống hệt nhau, chỉ khác nhóm F1.
- `34F1` chỉ khác 2 bit thuật toán CyWee.
- Chưa có file firmware HT43 (server không phát, xem 04-firmware §4). Vì vậy mọi linh kiện của HT43 không ghi nguồn riêng đều **suy ra từ Y25**.

---

## 1. Y25: bảng linh kiện

| Bộ phận | Linh kiện | Bằng chứng / nguồn | Tin cậy |
|---|---|---|---|
| SoC | Realtek **RTL8773EWE-VP** | In trên chip (01-protocol §0). Firmware có chuỗi `RTL8773EWE`, `RTL8773EWE LE`, `RTL8773E` (`0x18C0xx`, hai bản). MP header `partNumber = "RTL8763E"` (05 §1.1) | Cao |
| Họ chip | Dòng **RTL8763E** (watch + TWS), lõi Realtek "BBPro" | Ctrl header `ic_type = 0x11` = 17. Bảng tên IC trong SDK DFU (`com/realsil/sdk/dfu/l/a.java`): 17 = **`BB2_PLUS`**. Firmware có `Welcome to Realtek BBPRO Terminal`, `root@BBPRO`. Chứng nhận PSA "RTL8763E Series" gồm RTL8753E/8763E/8773E, "two-in-one Watch and TWS", BLE + BT Classic, LE Audio: https://products.psacertified.org/products/rtl8763e-series | Cao |
| Bluetooth | BT 5.3 hai chế độ (BLE + Classic) | Firmware có HFP (`+CIND`, `AT+XAPL=005D-8763-E`; 0x005D = mã hãng Realtek), A2DP/AVRCP/AVDTP, PBAP (`Phonebook Access PCE`), ANCS. BT 5.3 theo TechInsights cho RTL8763EWE: https://techinsights.com/ja/node/59041 | Cao (BT Classic) / TB (5.3) |
| CPU / RAM | **ARM Cortex-M4F** (có FPU, MPU) + DSP audio (HiFi). RAM cho app khoảng 116 KB ITCM + 60 KB DTCM, cộng 80 KB RAM chia sẻ với DSP (con số của dự án mẫu trong SDK). Có bộ điều khiển PSRAM | SDK Realtek RTL87x3E công khai (mục 6): `inc/rtl87x3e/platform/rtl876x.h` (`__CM4_REV`, `__FPU_PRESENT 1`), `board/evb/gui_demo/inc/rtl87x3e/mem_config.h`, `PSRAM_REG_BASE`. Firmware: mã Thumb, `dsp_mailbox_process`, `psram_spi_config_spic`. Spec nhà tích hợp ghi "160KB RAM + 128Mb FLASH": https://p.globalsources.com/IMAGES/PDT/SPEC/652/K1228028652.pdf. Không có datasheet công khai | Cao (lõi), TB (RAM). Y25 có PSRAM hay không: chưa rõ |
| Flash | **128 Mbit (16 MB)** NOR QSPI, ánh xạ vào `0x02000000–0x03000000` | Chuỗi `flash switch 4bit dtr success`, `set flash clock 160M success`, `flash_nor_*`. Bản đồ con trỏ trải hết 16 MB (05 §3.2). Khớp "128Mb FLASH" ở link globalsources trên. Hãng flash (MXIC/GD…) **chưa rõ**; chuỗi `MXIC doesn't support OTP` chỉ là code SDK chung | Cao (16 MB), Thấp (hãng) |
| Hệ file | LittleFS (`..\ute\thrid_lib\little_fs\lfs.c`) | Chuỗi firmware | Cao |
| GUI | Realtek **HoneyGUI** (`gui_*`, `hw_acc_imdc_decode`, `hw_acc_blit`: giải nén ảnh và blit bằng phần cứng) | Chuỗi firmware. HoneyGUI: https://gitee.com/realmcu/HoneyGUI | Cao |
| Màn hình | AMOLED tròn **466 × 466**, driver IC **ICNA3310** | Bảng driver `0x182054…`: chuỗi `466X466amoledIcna3310` (`0x18206C`), được tham chiếu bởi struct driver `0x11ACC0` (kèm 7 con trỏ hàm). `26 01` trả 466 × 466 tròn. ICNA3310 dùng cho tấm AMOLED tròn 454/466 qua QSPI/MIPI: https://www.displaymodule.com/products/1-39-inch-round-amoled-display-454x454-full-color-narrow-margin-with-mipi-i2c | Cao (IC). Hãng Chipone: TB (theo tên dòng "ICNA", không có datasheet) |
| Kích thước màn | 1,32″ (bản rao "Goodluck Tech Y25": 1,32″ 466 × 466) hoặc 1,43″ | https://www.bestbuy.ca/en-ca/product/goodluck-tech-y25-aluminum-smartwatch-with-heart-rate-monitor-and-gps/19581190 (chỉ đọc được đoạn trích). Có nhiều đồng hồ khác cũng tên "Y25" | Thấp |
| Giao tiếp màn | **QSPI** **(suy luận)** | HoneyGUI ghi RTL8773E hỗ trợ 8080 / QSPI / RGB / SPI, **không có MIPI DSI** (`src/sample/gui/doc/en/Porting/Platform.rst` trong SDK). AMOLED 466 × 466 với IC ICNA33xx gần như luôn đi QSPI. Struct driver trong firmware có số `0x3C` (60) và `0x1E0` (480), chưa rõ nghĩa | TB |
| Cảm ứng | Hynitron **CST816S / CST816T / CST816D**, I²C 0x15 | Bảng driver: `CST816S`, `CST816T`, `CST816D` (`0x182098–0x1820A8`), mỗi chuỗi có struct riêng (`0x11AD28`, `0x11AD44`, `0x11AD60`) với cùng bộ hàm. Tức firmware **dò chip ID lúc chạy** (0xB4/0xB5/0xB6 ở thanh ghi 0xA7: https://raw.githubusercontent.com/esphome/esphome/dev/esphome/components/cst816/touchscreen/cst816_touchscreen.h). Bản rao Best Buy ghi "CST820B" (chip ID 0xB7, không có trong bảng của firmware này) | Cao (họ CST816). Mẫu cụ thể: chưa rõ |
| Gia tốc | Sensortek **STK8321** (hoặc STK8325 / STK8327) | Struct driver `0x11AC08 {0x0F23, "STK8321", …}`, `0x11AC2C {0x0F25, "STK8325"}`, `0x11AC50 {0x0FE6, "STK8327"}`. Với STK8321: 0x0F = địa chỉ I²C, 0x23 = CHIP_ID, khớp datasheet https://cdn.hackaday.io/files/1822057795458720/STK8321.pdf. Firmware tự dò 1 trong 3 | Cao (họ STK832x) |
| Thuật toán cảm biến | Thư viện **CyWee** (CWM/DML: bước, ngủ, bơi, PAI, VO2max) | `sensorAlgo_cywee_InputGnssData`, `uteModuleCwm*`, `cwmGsensorCaliValue`, `DML: …`. Bit `34F1` F8 `0x20` (`RkSupportUtils.isSupCywee`) bật | Cao |
| PPG | Vcare **VC30F-S**: LED xanh/đỏ/hồng ngoại + PD, HR + SpO2, I²C 0x33 | In trên chip (01-protocol §0). Firmware có `vc30fx_sc` (struct `0x18469C`), `spo2_VC30F_S&VC30F_int_v01`, `lib_BIODetect_V14_1` (phát hiện đeo), `RspRateEst_V1.02` (nhịp thở), menu test "Heart BIO". Datasheet VC30F (Vcare / 成都维客昕): https://atta.szlcsc.com/upload/public/pdf/source/20230801/244778E513C3486333E0411205047030.pdf | Cao |
| Huyết áp | **Không có cảm biến riêng**. Huyết áp ước lượng từ PPG **(suy luận)** | F1 `0x100000` bật. Chữ thứ 2 của mã firmware là `B` ⇒ app bật huyết áp (`DeviceMode.java:340-350`, `SyncParameterUtils.java:698`). Menu test có `BloodP?` | TB |
| Nhiệt độ | Có driver `infrared thermistor` (struct `0x11ACF0`), nhưng **tính năng tắt** | F5 `0x08` = 0; app không hiện nhiệt độ. Có thể là driver chung, không lắp linh kiện **(suy luận)** | TB |
| GNSS | **ICOE (芯与物) CC1165W**: một tần (L1/B1/E1), GPS + BDS + GLONASS + Galileo + QZSS, giao tiếp UART NMEA + giao thức riêng | Chuỗi firmware: `cc1165w` (`0x248F0`, `0x1820BC`), `N1000R3.39.1.1165Build13177` (phiên bản FW của chip), lệnh `$AIDPOS`/`$AIDTIME`/`AIDINFO`, `FCTATEST`, `$ReqRecvFlash` (nạp FW cho chip GNSS), `gpsmodule/CC1165APFLASH`, file ephemeris `ephemeris_f1e1{G3,E3,C3,J3}`, `uteTaskGpsSendMsg`, menu test GPS/GLONASS/GALILEO. Hãng: https://www.icoe-tech.com/news/detail?id=29 ; thông số họ CC11: https://www.icoe-tech.com/product/detail?id=19 | Cao (driver có trong FW). Có lắp trên Y25 hay không: **TB, nghiêng về có** |
| La bàn / áp kế | Có cấu hình `compass/calibration`, `barometer/*`, log `mag=… baro=…`. **Không** thấy tên driver cảm biến từ hay áp suất | Bản "Y25 Pro" rao có la bàn + đo độ cao: https://www.exito.com/reloj-inteligente-y25-pro-gps-amoled-132-pulgadas-3atm-llamadas-bluetooth-brujula-altimetro-sport-smartwatch-105000006-mp/p | Thấp |
| Âm thanh / gọi điện | Codec trong SoC: chân `MIC1..3_P/N`, `DAOUT_P/N`, `LOUT/ROUT`, `MICBIAS`; có `anc_drv_*`, `codec_drv_*`. Mic + loa ngoài | Menu test `MicSpeaker?`, `Speaker?`. F6 `0x040000` (BT call), F5 `0x2000` (danh bạ), F1 `0x400000` (kết thúc cuộc gọi) | Cao |
| Sạc / nguồn | Mạch sạc Li-ion và PMU **nằm trong SoC**: có API sạc, giới hạn dòng adapter, 2 đầu vào thermistor pin | SDK: `inc/rtl87x3e/platform/charger_api.h`. Firmware: `adp_update_isr_cb` (phát hiện cắm sạc), `systemparam/shipMode`, test `Charging?`. Không thấy tên IC sạc rời | TB (có thể vẫn có IC bảo vệ pin riêng) |
| Rung, nút | Motor rung (`systemparam/motorVibration`, test `Motor?`); quét phím (`drvKeysScanTimer`). Không thấy núm xoay | Chuỗi firmware | TB |
| NFC | Có khoá `systemparam/nfcSwitch` nhưng chưa có dấu hiệu phần cứng | Chuỗi firmware | Thấp (có lẽ không có) |

---

## 2. HT43: bảng linh kiện

| Bộ phận | Linh kiện | Bằng chứng / nguồn | Tin cậy |
|---|---|---|---|
| SoC | Realtek RTL8773E (cùng nền tảng Y25) | Mã firmware `RH370L73ACC` cùng dòng "370 / L73" với `RB370L73AC`. `33F1` F2…F7 giống hệt Y25, gồm F7 `0x0800` (cờ nền tảng Realtek của UTE, mục 3.1). Dùng SDK RK (`utesdk`) qua `55FF/56FF`, không dùng SDK JX. Gói mặt đồng hồ giống hệt (466 × 466, 1 MB) | TB |
| Màn hình | AMOLED 466 × 466 tròn, **1,32″** theo bản rao bán | `26 01` (01-protocol §11). Bản rao TVCMALL "HT43 1.32 inch AMOLED … GPS BT calling compass": https://www.tvcmall.com/details/ht43-1-32-inch-amoled-smart-watch-gps-bt-calling-compass-outdoor-sports-tracker-band-for-women-white-sku6805003147a.html (chỉ đọc được đoạn trích) | Cao (độ phân giải), TB (kích thước) |
| GNSS | **ICOE CC1165W** (một tần) | Đồng hồ tự đẩy `01 E9 AC 03 01 02` mỗi 60 s. Theo `uterkif/uterkcase.java:162-163`, đó là `EphemerisRequired(2)` = hỏi trạng thái file AGPS. App trả lời ở `MainService.java:552-563` và `ServicePresenter.java:776-783`. Bit F9 `0x400000` (`isSupEphemerisService`). Bản rao TVCMALL ghi "GPS Chip: CC1165W (Single frequency)" | Cao |
| PPG | VC30F / VC30F-S **(suy luận)**; có HR + SpO2; **không huyết áp** | F1 `0x080000` (HR), F5 `0x40` (SpO2). F1 `0x100000` = 0 và chữ thứ 2 của mã firmware là `H` (chỉ có nhịp tim) | TB |
| Thuật toán | **Không** dùng gói CyWee như Y25 | F8 `0x20` (isSupCywee) và F9 `0x0200` (dữ liệu bơi CyWee) đều = 0. Có F1 `0x0100` (bước tách chạy/đi) | Cao (cờ), TB (ý nghĩa) |
| Gọi điện BT | Có | F6 `0x040000`, F5 `0x2000`, F1 `0x400000` (giống Y25) | Cao |
| La bàn | Có, theo bản rao bán | Link TVCMALL trên | Thấp |
| Pin / chống nước | 450 mAh, 3 ATM, theo bản rao bán | Link TVCMALL trên | Thấp |
| Cảm ứng, gia tốc, flash | Như Y25 **(suy luận)** | Chưa có firmware HT43 | Thấp |

---

## 3. App nhận diện nền tảng thế nào

### 3.1 Nền tảng chip trong GloryFitPro

| Bước | Quy tắc | Code |
|---|---|---|
| Lúc quét | Gói quảng bá có `55 55` hoặc tên bắt đầu `AT` ⇒ platform 1 = **JX** (Actions ATS3085, SDK `nadalsdk`). Có `55 55 22 22` ⇒ 4 (JX_RK). Có `33 55`/`36 55`/`3C 55`/`LBOO` ⇒ 2 = **RK** (Realtek, SDK `utesdk`). Có `55 55 34 12` ⇒ chỉ OTA JieLi | `ui/activity/scan/SearchDeviceActivity.java:397-406`, `:228` |
| Lớp app | `isRKPlatform()` = platform 2, 4 hoặc 5 (ZK). `isJLPlatform()` = F7 JX `0x4000` | `com/yc/gloryfitpro/config/DevicePlatform.java` |
| Cờ trong `34F1` F13 | `0x010000` ATS3085S · `0x020000` **RTL8773EWE** · `0x040000` JieLi AC707 · `0x080000` ZK AB569x · `0x100000` ZK FR8003D · `0x200000` nhẫn | `com/yc/utesdk/ble/open/DeviceMode.java:5-19`, `DevicePlatform.java` |
| Cờ trong `33F1` F7 | `0x0100` DA (Dialog) · `0x0200` RTL8762Ax · `0x0400` nRF · `0x0800` **RTL8762Cx** · `0x2000` FRK · `0x4000` JieLi AC701 · `0x8000` ATS3085L | `DeviceMode.java` (hằng `IS_PLATFORM_*`). F7 `0x0800` được dùng ở `uterkfor/uterkfinal.java:486` và GloryFit cũ `BluetoothLeService.java:962` |
| Mã firmware | Chữ thứ 2 là `B` ⇒ có huyết áp; chứa `MH`/`RH`/`UH` ⇒ có nhịp tim | `DeviceMode.java:340-360` |

Kết quả cho hai máy:
- F13 = 0, nên app **không** gắn cờ "RTL8773EWE". Nhóm mặt đồng hồ trên server vì vậy là 0 (`watchface/close/uterktry.java:102`).
- F7 = `0x0888` có bit `0x0800`. UTE gọi bit này là "RTL8762Cx", nhưng thực chất là cờ chung cho đời chip Realtek. Chip thật là RTL8773E.
- OTA đi đường Realtek DFU. Firmware cũng xác nhận chip: `ic_type 17 = BB2_PLUS`.

### 3.2 Bảng bit (theo bố cục `Ute.kt` `Features.parse`)

| Nhóm | HT43 | Y25 | Khác nhau |
|---|---|---|---|
| F1 | `0x4BA1DC` | `0x5BA0DC` | HT43 thêm `0x000100` (bước tách chạy/đi), thiếu `0x100000` (huyết áp) |
| F2 | `0x005D78` | `0x005D78` | |
| F3 | `0xFED921` | `0xFED921` | |
| F4 | `0x756EDF` | `0x756EDF` | |
| F5 | `0x243943` | `0x243943` | |
| F6 | `0x6C2A01` | `0x6C2A01` | |
| F7 | `0x0888` | `0x0888` | |
| F8 | `0x000400` | `0x000420` | Y25 thêm `0x20` (CyWee) |
| F9 | `0x400000` | `0x400200` | Y25 thêm `0x0200` (dữ liệu bơi CyWee, `uterkfor/uterkshort.java:193`) |
| F10 | `0x050000` | `0x050000` | |
| F11–F13 | 0 | 0 | |

Các bit liên quan phần cứng (cả hai máy, trừ khi ghi khác). Tên hàm lấy từ `com/yc/gloryfitpro/config/RkSupportUtils.java`, trừ khi ghi khác:

| Bit | Ý nghĩa | Nguồn |
|---|---|---|
| F1 `0x080000` | Nhịp tim (PPG) | GloryFit `SyncParameterUtils.java:715` |
| F1 `0x100000` | Huyết áp (chỉ **Y25**) | `isSupBp` |
| F1 `0x000100` | Bước tách chạy/đi (chỉ **HT43**) | `uterkdo/uterkbyte.java:47` |
| F1 `0x400000` | Kết thúc cuộc gọi từ đồng hồ | GloryFit `CallRemindActivity.java:194` |
| F2 `0x004000` | HR 24 h | `isSup24HrFun` |
| F5 `0x000040` | SpO2 (LED đỏ/IR) | `isSupOxygenFun` |
| F5 `0x000008` | Nhiệt độ: **không bật** | `isSupTemperatureFun` |
| F5 `0x001000` | Điều khiển nhạc | GloryFit `MusicControl.java:144` |
| F5 `0x002000` | Danh bạ (gọi điện) | `isSupContacts` |
| F6 `0x040000` | BT 3.0 / gọi điện qua BT Classic | `isSupBtCall` |
| F6 `0x400000` | Tin nhắn dài 240 byte | GloryFit `WriteCommandToBLE.java:1188` |
| F7 `0x0008` | Ngủ có REM | `isSupSleepRemFun` |
| F7 `0x0800` | Cờ nền tảng Realtek ("RTL8762Cx") | `DeviceMode.IS_PLATFORM_RTL8762Cx` |
| F8 `0x000020` | Thuật toán CyWee (chỉ **Y25**) | `isSupCywee` |
| F9 `0x400000` | **Dịch vụ ephemeris / AGPS** (có GNSS) | `isSupEphemerisService` |
| F10 `0x040000` | Gói dài theo `maxLen` (MTU 55FF BLE 5.0) | `DeviceMode.IS_SUPPORT_MTU_55FF_5_0` |

Các bit còn lại chủ yếu là loại thể thao (F3/F4, `SportModeSupList.java`) và tính năng app (thời tiết, báo thức, ngôn ngữ, nhắc ngồi lâu…). Chúng không cho biết thêm về phần cứng.

### 3.3 GNSS và AGPS trong GloryFitPro

- Luồng hoạt động:
  1. Đồng hồ gửi `01 E9 AC 03 <op>`: op 1 = đòi tải, op 2 = hỏi trạng thái (`com/yc/utesdk/bean/EphemerisRequired.java`).
  2. App đọc `EphemerisParams` từ đồng hồ: `version`, `interval` và **danh sách tên file** (`uterkif/uterkcase.java:107-122`).
  3. App POST `https://www.ute-tech.com.cn/ci-yc/index.php/api/client/getAgpsFile` với `btname`, `country`, `gpsPlatform = version`, rồi tải file trùng tên (`utils/gpsstatus/GpsUtils.java`).
  4. App gửi file xuống đồng hồ (`uploadEphemerisRk`).
- Bản ghi trạng thái: `EphemerisStatus` có 1 = chuẩn bị, 2 = đang làm, 3 = xong, 4 = lỗi, 5 = không hỗ trợ.
- `EphemerisParams.version` chỉ định nghĩa **0 = Broadcom, 1 = Sony, 2 = Airoha**. **Không** có hằng cho ICOE.
- APK **không** kèm SDK GNSS nào: không có Airoha, Allystar, Goke hay u-blox. Việc chọn file do server UTE quyết định theo `btname`/`gpsPlatform`.
- Firmware Y25 dùng tên file `ephemeris_f1e1G3/E3/C3/J3`, tức một tần L1/E1 cho GPS, Galileo, BDS, QZSS **(suy luận)**. Như vậy CC1165W (ICOE) đi đường "version" do server UTE xử lý **(suy luận)**.
- Hệ quả cho driver: HT43 sẽ gửi `01 E9 AC 03 01 02` mỗi phút cho tới khi nhận được câu trả lời trạng thái. Nếu không nạp AGPS, GPS vẫn chạy nhưng bắt vệ tinh chậm. Firmware có thông báo "The AGPS has expired and the location speed is slow".

---

## 4. Thông tin khác

| Mục | Kết quả | Nguồn | Tin cậy |
|---|---|---|---|
| OUI `78:02:B7` | **ShenZhen Ultra Easy Technology Co., Ltd** (MA-L, đăng ký 2016-06-27), tức UTE / 优创亿, hãng làm GloryFit. Nghĩa là MAC do UTE cấp, không phải hãng chip | https://maclookup.app/macaddress/7802b7 , https://api.macvendors.com/78:02:B7 | Cao |
| UTE | 深圳市优创亿科技有限公司, Bảo An, Thâm Quyến. Làm GloryFit, GloryFitPro, DayBand… Banner trang chủ ghi nền tảng Realtek RTL8763E | https://www.ute.top , https://www.mwcbarcelona.com/exhibitors/35662-shenzhen-ultra-easy-technology-co-ltd | Cao |
| Mã firmware | `R?370L73A…`: chữ 2 `B` = có huyết áp, `H` = chỉ nhịp tim (theo code app). "370" có lẽ là mã nền tảng/bo mạch. "L73" có lẽ ứng với RTL87**73** **(suy luận)**. Web không có kết quả nào cho `RB370L73AC` / `RH370L73ACC` | Code app (mục 3.1) | TB (chữ 2), Thấp (phần còn lại) |
| FCC ID / bài tháo máy | Không tìm thấy cho cả hai | Tìm web 14/10/2026 | |
| Datasheet RTL8773E | Không công khai (Realtek chỉ cấp theo NDA). Đừng nhầm với **RTL8773J** (Cortex-M55 + M33, ra năm 2026) | https://www.cnx-software.com/2026/09/21/realtek-rtl8773j-a-bluetooth-7-ready-cortex-m55-m33-microcontroller-with-hdt-support/ | Cao |

---

## 5. Còn chưa biết / cách kiểm chứng an toàn

| Câu hỏi | Cách kiểm chứng (chỉ đọc) |
|---|---|
| Y25 có lắp CC1165W thật không | Xem máy có tự đẩy `01 E9 AC 03` không. Xem menu đồng hồ có mục GPS, hoặc trong chế độ test có màn GPS/GLONASS/GALILEO |
| Mẫu cảm ứng / gia tốc / thông số màn của HT43 | Cần file firmware HT43 (server UTE chưa phát) hoặc tháo máy |
| Tên cảm biến PPG của HT43 | Gửi lệnh đọc `44 0F` (query sensor type, 01-protocol §1.4); lệnh này chỉ đọc |
| Hãng chip flash, có PSRAM không, IC sạc, loại motor (ERM/LRA), la bàn/áp kế | Chỉ biết được khi tháo máy và đọc mã in trên chip |
| Kích thước màn Y25 (1,32″ hay 1,43″) | Đo trực tiếp. Có nhiều máy khác cũng mang tên "Y25" |
| CPU/RAM chính xác của RTL8773E | Không có tài liệu công khai |

---

## 6. Đối chiếu với SDK Realtek RTL87x3E công khai, và điểm cần tìm khi mở máy

Nguồn: https://github.com/rtkconnectivity/RTL87x3E-Common-SDK (commit `ae842d0`, 22/09/2026, SDK v3.13.0.95). Đã clone vào scratchpad, chỉ đọc.
Tài liệu `docs.realmcu.com/sdk/rtl87x3e/…` và tài liệu phần cứng `realmcu.com/en/Resources/Hardware/RTL8763E-Series` **phải đăng nhập**, nên chưa đọc được.

### 6.1 Chip và bộ nhớ

| Mục | SDK nói gì | Khớp với firmware Y25? |
|---|---|---|
| Họ chip | SDK cho dòng "RTL87x3E". `feature_check.h` liệt kê theo kiểu vỏ: RTL8773EFE/EFL (QFN-46), RTL8773ESL (QFN-50), **RTL8763EWE / RTL8763EWE_VP (QFN-68)**, RTL8763EW/_VP (BGA-149)… Thư mục `bin/rtl87x3e/` có `8763EWE-VP` (chỉ cấu hình **16M**), `8763EWE` (16M, 1M), `8773ESL` (4M) | SDK **không** có tên "RTL8773EWE". Dựa theo cặp `8763EWE` / `8763EWE-VP`: RTL8773EWE-VP có lẽ dùng vỏ QFN-68 và đi với flash 16 MB **(suy luận)**. Firmware Y25 dùng 16 MB, khớp |
| PartNumber trong MP header | `mp.ini` mặc định `PartNumber=RTL8763E` | Y25 cũng ghi `RTL8763E` (05 §1.1). **Khớp**: UTE build bằng chính SDK này |
| Tên chân | `rtl876x.h`: `P0_0…P10_x`, `MIC1_P/N`, `MIC2_P/N`, `MIC3_P/N`, `MICBIAS`, `DAOUT`, `LOUT/ROUT` | Firmware Y25 có bảng tên chân giống hệt (`P10_0`, `NULL_PIN`, `MIC1_N`…) |
| Lõi | Cortex-M4F (`__CM4_REV 0x0001`, FPU, MPU) + DSP (`BIT_DSP_CORE_EN`, ảnh `dsp_sys_image_RTL8763EO`) | Firmware có `dsp_mailbox_*`, `dsp_ipc_*` |
| RAM (dự án `gui_demo`) | ITCM1 116 KB (`0x200000`), DTCM1 60 KB (`0x2C0000`), RAM chia sẻ DSP 80 KB (`0x300000`). Có PSRAM controller (`0x40017000`) và 4 bộ SPIC (`0x40080000…0x4008C000`) | Firmware có `psram_spi_config_spic` |
| Flash 16 MB (`flash_map_config/16M`) | XIP từ `0x02000000`. `OEM_CFG 0x02002000`, `BOOT_PATCH 0x02004000`, `UPPERSTACK 0x02015000` (252 KB), OTA bank0/bank1, `VP_DATA`, `FTL`, `USER_DATA1` (~9,6 MB, nơi để tài nguyên GUI) | Y25: `UPPER_STACK 0x02016000` dài `0x3F000` (cùng kích thước), App `0x0209C000`, VP `0x022A0000`, tài nguyên GUI ~9,4 MB từ `0x02694000`. Bố cục **cùng kiểu**, nhưng UTE đã đổi địa chỉ và có vẻ dùng 1 bank (05 §3.2) |
| Màn hình | `app_gui.h`: `LCD_INTERFACE_QSPI / 8080 / QSPI_1_BIT / SPI`. Driver mẫu: SH8601Z, RM69330, ST77916, ST7801… HoneyGUI cho RTL8773E: 8080 / QSPI / RGB / SPI, **không MIPI**. Có bộ `IF8080` | ICNA3310 không có trong SDK: driver do UTE tự viết. Giao tiếp QSPI **(suy luận)** |
| Cảm ứng | SDK có driver CST816T (mặc định), CST816D, CHSC6417 | Trùng họ CST816 của UTE |
| Ngoại vi khác | `rtl876x_qdec.h` (núm xoay), `keyscan`, `captouch`, `i2c`, `spi`, `uart`, `adc`, `charger_api.h` (sạc trong chip, có thermistor) | Firmware chỉ có quét phím, không thấy dùng QDEC |

### 6.2 Cách nạp và debug Realtek có ghi trong tài liệu

| Kênh | Chi tiết | Nguồn | Tin cậy |
|---|---|---|---|
| UART "MP mode" (nạp bằng MPPGTool / MP Tool) | ROM đọc chân **LOG** lúc cấp nguồn: mức thấp ⇒ bỏ qua flash và vào MP mode, nạp qua UART. Trên họ **RTL87x2** chân này mặc định là **P0_3**, UART là **P3_0/P3_1**. Với RTL87x3E thì **chưa có tài liệu công khai** | Hướng dẫn RTL87x2x: https://www.manualslib.com/guide/4427583/rtl87x2x-quick-start-user-guide.html ; EVB RTL87x2G (P0_3 nối GND, UART P3_0/P3_1): https://nrfconnectdocs.nordicsemi.com/ncs/latest/zephyr/boards/realtek/rtl87x2g_evb_a/doc/index.html. Release note SDK 87x3E có MPPGTool v6.1.180.0 và "uart dfu support" | Cách làm: TB. Số chân cho 87x3E: **Thấp (suy luận)** |
| SWD (J-Link / Keil) | Pinmux có chức năng `SWD_CLK` (56) và `SWD_DIO` (57). `Pinmux_Reset()` "cũng reset 2 chân SWD". SDK kèm thuật toán nạp flash `tool/flash/RTL87X3E_FLASH.FLM` (Keil/J-Link) | `inc/rtl87x3e/io/rtl876x_pinmux.h:89-90`, `:681` | Có SWD: Cao. Chân mặc định: chưa rõ |
| Log / console | UART log (`LOG_UART_REG_BASE 0x40011000`), đọc bằng DebugAnalyzer. Firmware Y25 còn có shell `Welcome to Realtek BBPRO Terminal` (lệnh `help`, `mode`, `exit`) | `rtl876x.h:3097`, chuỗi firmware | Cao |
| OTA BLE (đường hiện tại) | Realtek DFU, image ký ECDSA P-256 (05 §2) | | Cao |

### 6.3 Những thứ cần tìm trên bo khi mở máy (suy luận)

| Thứ cần tìm | Lý do / cách nhận ra |
|---|---|
| Mã in trên SoC (`RTL8773EWE-VP`, vỏ QFN-68?) và **có chip flash rời không** | Không có chip SPI-NOR 8 chân ⇒ flash nằm trong gói (SiP). Nếu có (GD25/XM25/P25… 128 Mbit) thì ghi lại mã. Kiểm tra có PSRAM rời không |
| Pad **VBAT / GND / VBUS** (chân sạc pogo) | Chân sạc thường chỉ có VBUS + GND. Pad test VBAT thường nằm gần đầu nối pin |
| 2 pad UART log (TX/RX) | Dùng cho DebugAnalyzer / console BBPRO và MP mode. Trên RTL87x2 là P3_0/P3_1. Tìm 2 pad cạnh nhau, đo khi khởi động có xung 2 Mbaud / 115200 |
| Pad **LOG/boot** (kéo xuống GND khi cấp nguồn để vào MP mode) | RTL87x2 dùng P0_3. Với 87x3E: chưa biết, cần sơ đồ EVB chính hãng |
| Pad **SWDIO / SWCLK** | Có thể dùng chung chân với GPIO. Nhận ra bằng điện trở kéo, hoặc dò bằng J-Link (`JTAGulator`/SWD scan) **chỉ khi đã có bản dump và cách cứu máy** |
| **RESET / CHIP_EN, MFB** | Dòng audio Realtek có chân MFB (nút đa năng / bật nguồn) (`rtl8763_syson_reg.h`: "MFB Power detect"). Nút cạnh của đồng hồ có thể nối vào MFB |
| Linh kiện cảm biến | Mặt đáy: PPG VC30F-S (I²C 0x33), gia tốc STK832x (LGA 2 × 2 mm, I²C 0x0F), GNSS CC1165W (WLCSP 1,8 × 2,1 mm hoặc QFN36) + anten GPS + có thể có LNA/SAW. Cáp màn (ICNA3310 nằm trên FPC/COG của màn), cảm ứng CST816x/CST820 |
| Mic, loa, motor | Xác nhận gọi điện (MIC1, DAOUT/LOUT) và loại motor (ERM hay LRA, có IC driver rời không) |

> Lưu ý an toàn: secure boot của Y25 chưa biết (05 §2). Nạp qua MP mode hoặc SWD có thể tránh được bước so khoá của DFU, nhưng nếu eFuse bật kiểm tra chữ ký lúc boot thì image không ký đúng vẫn không chạy. **Phải đọc và lưu toàn bộ flash 16 MB trước khi ghi bất cứ thứ gì.**
