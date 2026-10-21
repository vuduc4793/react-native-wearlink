# 06 — Firmware cùng họ với Y25 / HT43 trên server UTE (14/10/2026)

> Mục tiêu: gom các image firmware cùng họ với Y25 (`RB370L73AC`) và HT43 (`RH370L73ACC`) để so sánh, chuẩn bị cho việc tự làm OTA.
> Chỉ truy vấn mạng dạng đọc và tải file. Không chạm thiết bị BLE, không adb, không flash.
> Cách gọi API: xem `04-firmware.md` §1, §4. Bố cục header: xem `05-firmware-analysis.md` §1.
> Nhật ký đầy đủ 229 truy vấn: `research/firmware/api-queries-2026-10-14.jsonl`; các bản ghi trúng: `research/firmware/api-hits-2026-10-14.json`.
> Phần nào không đọc thẳng từ byte, từ code app hoặc từ phản hồi server thì ghi **(suy luận)**.

---

## 0. Kết luận nhanh

| Câu hỏi | Trả lời |
|---|---|
| Có firmware anh em của Y25 / HT43 không? | **Không.** Trong họ `R?3xxL73…` server chỉ phát đúng `RB370L73AC` (Y25). HT43 (`RH370L73ACC`) và mọi biến thể đã thử đều trả `no new version` |
| Có bao nhiêu kết quả trúng? | **10 btname** có firmware (`getBtVersionUpdate`) + **1 bản vá ROM** (`getPatchlicationUpdate`, RH110). Tất cả đều dưới app key **GloryFit** `dcd05f…45c2`. Key GloryFitPro (`75662f…`, `aafe1d…`) không trả gì |
| Image nào gần Y25 nhất? | **`RB303JD` V003810**: cùng họ chip **RTL8763E (Bee3)**, cùng định dạng header 0x600 byte, image id `0x2793` (App) |
| Khoá công khai có giống nhau không? | **Không có image nào dùng chung khoá với Y25.** Y25 ký **ECDSA P-256**; RB303JD ký **RSA-2048-PSS** bằng khoá khác hẳn; 8 image Bee2 (RTL8762C) **không có chữ ký và khoá** trong header |
| Gói UI / bản vá cho họ 370? | **Không.** `getBtUIVersionUpdate` và `getPatchlicationUpdate` đều trả `no new version` cho `RB370L73AC`, `RH370L73ACC` và cả 9 btname trúng khác (trừ bản vá RH110) |

---

## 1. Quy tắc đặt tên btname (firmware string = `btname` + `V` + 6 chữ số)

| Vị trí | Ví dụ Y25 / HT43 | Ý nghĩa | Nguồn |
|---|---|---|---|
| Ký tự 1 | `R` | Tiền tố nền tảng. Code chỉ kiểm `MH`/`RH`/`UH` ⇒ có ít nhất 3 tiền tố `M`, `R`, `U`. Mọi image `R…` tải được đều là chip **Realtek** (suy luận: `R` = Realtek) | `SyncParameterUtils.java:721`, `utesdk/ble/open/DeviceMode.java:358` |
| Ký tự 2 | `B` / `H` | Tính năng đo: `H` = có nhịp tim; `B` = có huyết áp (và nhịp tim). App cũ suy ra "hỗ trợ huyết áp" khi btname bắt đầu `RB`, "hỗ trợ nhịp tim" khi chứa `RH`/`MH`/`UH` | `SyncParameterUtils.java:698`, `:721` |
| Số 3 chữ số | `370` | Mã dự án / phần cứng. Y25 và HT43 **cùng `370`** ⇒ rất có thể cùng bo mạch, khác cấu hình cảm biến (suy luận) | — |
| Cụm sau số | `L73`, `LC`, `LD`, `LA`, `LM`, `CQ`, `TSG`, `JD`, `FP`… | Mã cấu hình (màn hình / chip / phiên bản bo). `L73` có thể ứng với RTL**8773** (Y25 chứa chuỗi `RTL8773EWE`) **(suy luận)** | Danh sách btname trong `com/yc/zhichi/ShowFloatWinProjectChecker.java` |
| Các chữ cuối | `AC`, `ACC` | Biến thể khách hàng / lô hàng, có thể lồng nhau: `RH281LCC` → `RH281LCCY` → `RH281LCCYA`. HT43 `RH370L73ACC` = biến thể `C` của `RH370L73AC` (suy luận) | Cùng file trên |

Server so khớp `btname` **chính xác, không phân biệt hoa thường** (`rb370l73ac` trúng; `RB370L73A`, `RB370L73`, `RB370L73ACC` trượt). Gửi cả chuỗi `RB370L73ACV001205` làm `btname` cũng trúng (server tự cắt ở `V`). Firmware **gắn với app key**: cùng `RB370L73AC` nhưng key GloryFitPro thì trả `no new version`.

Danh sách btname có trong hai app (dùng làm "hạt giống"): `RB112TEE RB112TSG RB112W RB303JD RB303P RB378L73B RH110 RH112TG RH112WAA RH122A RH158D RH158F RH266FP RH276N RH281L…(≈40 biến thể) RH287C… RH291B RH291C RH302 RH304 RH306L73I/IA/IB RH306LA/LAD/LAG/LD/LDB/LDC/LDE RH316 RH355L73E/EA/EB RH377L73E RS256`.
Trong app có danh sách sản phẩm do server cấp (`GetYaMeiProductResult`, `ShowFloatWinProjectChecker.replaceProduct()`), nhưng đây là danh sách "cửa sổ nổi" của một khách hàng, không phải danh mục firmware.

### App key tìm thấy

| Key | Chỗ dùng | Kết quả với API firmware |
|---|---|---|
| `<khoá app hãng, không công bố>` | GloryFit `YCAPPKEY`, `GlobalVariable.YC_APPKEY`; GloryFitPro `ConstantOtaStatus.testAppkey` (kèm `testBtname = RB112TSG`) | **Có firmware** (mọi kết quả trúng) |
| `<khoá app hãng, không công bố>` | GloryFitPro `AppBaseInfo.appKey` | Không trúng lần nào (13 truy vấn) |
| `<khoá app hãng, không công bố>` | GloryFitPro manifest `YCAPPKEY` (theo ghi chú trước) | Không trúng (thử RB370L73AC) |
| Các chuỗi 32 hex khác | `19e0d8a6…` (API đo huyết áp EL), `e9f1349d…` (ZhiChi CSKH), `1210e11e…`/`93301e30…` (open_id WeChat), `3408f41e…`, `32bdc32f…`, `31d92951…`, `9ccc8c41…` (secret), `2c92f3bc…` (ECG Jianyou) | **Không phải** app key firmware UTE, không dùng |

---

## 2. Những gì đã thử (229 truy vấn API, ~1,1 giây/lần, 10 lần tải file)

| Nhóm | Tên đã thử | Key | Kết quả |
|---|---|---|---|
| Kiểm tra cơ chế | `RB370L73AC` (3 key), `RB370L73A`, `RB370L73`, `RB370L73ACC`, `RB370L73ACV001205`, `rb370l73ac` | gf/pro/proman | Chỉ trúng `RB370L73AC` (và 2 dạng tương đương) với key GloryFit |
| Họ L73 trong app | `RB378L73B RH377L73E RH355L73E/EA/EB RH306L73I/IA/IB` | gf + pro | Không |
| Chữ cuối Y25 | `RB370L73A[A-Z]` (25), `RB370L73[B-Z]` (25), `RB370L73[B-E][A-D]` (16) | gf | Không |
| Chữ thứ 2 | `R[A-Z]370L73AC` (25) | gf | Không |
| Số dự án | `RB{360,362,365–369,371–380,385,390}L73AC` (19) | gf | Không |
| Mã cấu hình | `RB370L7{0,1,2,4,5,6,7,8}AC`, `RB370L{C,D,A,M}AC` | gf | Không |
| Họ HT43 | `RH370L73AC[A-Z]` (25), `RH370L73A`, `RH370L73`, `RH370L73B`, `RH370L73BC` | gf | Không |
| Tiền tố khác | `MB370L73AC UB370L73AC MH370L73ACC UH370L73ACC` | gf | Không |
| btname khác trong app | `RB112TSG RB303JD RH281LCCA RH287CQ RH291B RH291C RH302 RH304 RH316 RH276N RH266FP RH112TG RH122A RH110 RB112W RB303P RH158D RH158F RS256 RH112WAA RB112TEE` | gf (+pro cho 4 tên đầu) | **Trúng 9**, xem §3 |
| UI (`getBtUIVersionUpdate`, `versionname=V000001U000001` / `V000001`) | `RB370L73AC` + 9 btname trúng | gf | Không |
| Bản vá (`getPatchlicationUpdate`, `versioncode=00000` / `0`) | `RB370L73AC`, `RH370L73ACC` + 9 btname trúng | gf | **Trúng `RH110`** |

Không thử: liệt kê bucket S3, đoán URL file, `getBtImgUpdate` (chỉ có `appkey`+`versioncode`, dành cho chip đời cũ), các key của app khác (không có).

---

## 3. Kết quả trúng và file đã tải

Tất cả lấy từ `urladdress` chính (`update.ute-tech.com.cn` hoặc `dl-oss.ute-tech.com.cn`), không cần dùng bản sao S3 `urladdressBg`. Lưu ở `research/firmware/<btname>/`.

| btname | Phiên bản | Ngày phát hành | Mô tả server | Tệp | Byte | SHA-256 |
|---|---|---|---|---|---|---|
| **RB370L73AC** (Y25) | V001205 | 2026-09-16 15:40 | 修复已知问题！ | `RB370L73AC/1789544413_1645.bin` (chép từ bản đã tải) | 1 683 828 | `7d477c2d76f3f4040cf3f0b08f68bb5734efbbc889a2a057eff2b3472eb83e55` |
| **RB303JD** | V003810 | 2023-06-03 12:05 | (trống) | `RB303JD/1685765148_2378.bin` | 962 332 | `f402aaccc69fc47f1310e959a0a0573c9abfa1f0f59d6a85626f57b343da6f23` |
| RB112TSG | V004887 | 2022-01-22 22:43 | Optimize the known issues of the system | `RB112TSG/1642862565_4596.bin` | 320 528 | `98201e4ddebf150cafba755eed4b52bc9e3062413e1e69d81d73315f05dc9286` |
| RH291B | V001112 | 2022-03-12 17:11 | 1. Upgrade the latest firmware. | `RH291B/1647076283_7524.bin` | 703 604 | `3355656faa8972670ead94173cb7f52f800654a9702662310cf0e694654a02c6` |
| RH291C | V001237 | 2022-04-10 16:46 | 1、测试OTA升级； | `RH291C/1649580374_3222.bin` | 555 272 | `498125555cb28063ba6b5042b01292889ac661584ed9dd5f7c45ddb14882d787` |
| RH302 | V001263 | 2022-06-13 15:59 | 1. Optimize some known issues; | `RH302/1655107186_7624.bin` | 666 888 | `683348a88c202c0a49f2d10c1dd29b58f913a124bf670c198447b30b2cd2240a` |
| RH276N | V002218 | 2024-06-21 11:52 | (trống) | `RH276N/1718941919_7696.bin` | 542 736 | `4f10ed0ce50284c2ba5864aa9e245b5e276cb940596b92d36d046275129c248f` |
| RH158F | V005984 | 2025-03-14 15:10 | (trống) | `RH158F/1741936206_3762.bin` | 155 452 | `f515c98e21271afbfe9d189a26e9bb968e68317e59752719f055cab0aa0e2f3f` |
| RH112WAA | V001397 | 2022-06-08 17:36 | Improve user experience | `RH112WAA/1654681010_2837.bin` | 655 612 | `1f0347bd3f6651780f1c32d90c593a32ace873466e13580157b0451e0b811ba5` |
| RH110 | V000011 | 2018-12-13 16:43 | 1.修复一些BUG; | `RH110/1544690586_RH110_2_0.0.11.0_339c7fe6-….bin` (`dl-oss`, không có S3) | 94 568 | `2ca6d120875a7bcfe7df7877e98d651960d09698615e505744ac01d367d1256c` |
| RH110 (bản vá ROM) | 1077 | 2018-11-02 11:46 | 8762Cpatch升级测试 | `RH110/patch/1541130396_Patch_MP_master_1.0.107.7.bin` | 35 740 | `fa3ca3957e0e96d21c635f273953ba871d7d7a0606c6d4744801647936a7a8a4` |

`forceupdate` = `0` ở mọi kết quả. URL mẫu: `https://update.ute-tech.com.cn/ble/<appkey>/<btname>/<unix>_<rand>.bin`, bản sao `https://uteap.s3.ap-south-1.amazonaws.com/ble/…` (cùng đường dẫn).

---

## 4. So sánh header (0x000–0x5FF)

### 4.1 MP header (TLV) và ctrl header

| Image | Chip (TLV `0x03`) | binId | ic_type | ctrl_flag | image id | imageVersion (TLV `0x16`) | TLV `0x1D` pubKeyHash | Định dạng |
|---|---|---|---|---|---|---|---|---|
| **RB370L73AC** | RTL8763E | `0x0300` | `0x11` (RTL8773E) | `0x0101` | `0x2793` App | `0x96A01040` | **có** `98 5B 8A C4` | Bee3, header như `05` §1 |
| **RB303JD** | RTL8763E | `0x0300` | `0x0B` | `0x0101` | `0x2793` App | `0x000E2000` | **không có** | Bee3, cùng bố cục, khác loại chữ ký |
| RB112TSG, RH110, RH158F | RTL8762C | `0x0300` | `0x05` | `0x0101` | `0x2793` App | — (TLV chỉ có `01 02 03 04 FE`) | không | Bee2 |
| RH291B, RH291C, RH302, RH276N, RH112WAA | RTL8762C | `0x0300` | `0x09` | `0x0901` | `0x2793` App | — | không | Bee2 |
| RH110 patch | RTL8762C | `0x0200` | `0x05` | `0x0116` | `0x2792` Patch | — | không | Bee2 ROM patch |

Mọi image đều có MP header 512 byte và `mpDataLength` (TLV `0x04`) = độ dài file − `0x200`.

### 4.2 Hai image Bee3 (RTL8763E / RTL8773E)

| Trường (offset file) | RB370L73AC (Y25) | RB303JD |
|---|---|---|
| `0x200` dành riêng | `FF ×16` | `FF ×16` |
| `0x210` chữ ký | **64 byte** dùng: ECDSA P-256 `r‖s` | **256 byte** dùng: **RSA-2048** |
| `0x310` SHA-256(file `0x330`→hết) | khớp | khớp |
| `0x330` CRC-16/ARC(file `0x332`→hết) | `0xCA7B`, khớp | `0x21A4`, khớp |
| `0x338` payload_len | `0x19AB74` | `0xEA91C` |
| `0x34C` exe/load base | `0x0209C400` | `0x020A9400` |
| `0x358` địa chỉ header trong flash | `0x0209C000` | `0x020A9000` |
| `0x360` magic | `0x5A5A12A5` | `0x5A5A12A5` |
| `0x374`… thông số vùng nhớ | `0x0209C400, 0x0020A800, 0x00028000, 0x0000C000, 0x00004000` | `0x020A9400, 0x00208C00, 0x00007C00, 0x00003400, 0` |
| `0x390` version + 4 byte | `40 10 A0 96` + `B2 36 00 85` | `00 20 0E 00` + **`B2 36 00 85`** (giống nhau ⇒ có thể là mã SDK/công cụ, không phải hash git riêng, suy luận) |
| `0x3A0` khoá | `04 B1 8F A9 … ED E7 B9` (65 B, P-256 không nén) | Modulus RSA 256 B big-endian `83 43 EF AE …` + `0x4A0` số mũ `00 01 00 01` (65537) |
| Kiểm chữ ký | **Đúng** (ECDSA, e = SHA-256(file `0x310`→hết), xem `05`) | **Đúng**: RSA-PSS, MGF1-SHA-256, salt 32, thông điệp = file `0x310`→hết |
| SHA-256 của khoá | `38941a7f421c9050b11498a800f6d409828020e4d0b169775c37a942985b8ac4` | n‖e: `ec00f141599e3f234081e845de470200cb1f3aed1e69d986148ca0bfabb87b22` |

### 4.3 Các image Bee2 (RTL8762C)

- Header image 1 KB bắt đầu ở `0x200`: ctrl header `[ic][secver][flag u16][id u16][crc16 u16][payload_len u32]` (crc16 luôn `0`), UUID, các địa chỉ, ở `0x260` là version + 4 byte + chuỗi `sdk#####` (`master##` ở bản vá).
- Trường duy nhất có dạng băm: **32 byte ở file `0x374`** (app đọc SHA-256 ở offset 372 của image cho ic khác 11/17/19, `BaseBinInputStream.java:595-603`). Chưa tái tạo được phạm vi băm (đã thử mọi điểm bắt đầu chia hết cho 4 trong header, có/không xoá trường).
- **Không có chữ ký, không có khoá công khai** trong 0x600 byte đầu: phần còn lại toàn `00`, `0x4E0–0x5FF` toàn `FF`. Bee2 chỉ kiểm toàn vẹn bằng băm, trừ khi máy bật secure boot bằng eFuse (không thấy được từ file, suy luận).

### 4.4 Kết luận về khoá

- **Không có hai image nào dùng chung khoá.** Khoá ECDSA của Y25 chỉ xuất hiện trong image Y25.
- RB303JD (cũng Bee3, cũng UTE, cùng app key) dùng **thuật toán khác (RSA-2048-PSS) và khoá khác**. Như vậy UTE **không** dùng một khoá ký chung cho mọi sản phẩm Realtek. Khoá đi theo dự án hoặc theo đời SDK/công cụ (suy luận).
- Chưa thấy image nào **chưa ký** trong nhóm Bee3. Nhóm Bee2 thì không có chữ ký trong header.
- Chưa có bằng chứng nào cho "khoá mặc định của Realtek": hai khoá Bee3 khác nhau, và không có mẫu thứ ba để đối chiếu.
- Hệ quả cho OTA tự làm: Y25 (và rất có thể HT43, cùng dự án `370`, suy luận) cần chữ ký ECDSA P-256 bằng khoá có hash `98 5B 8A C4`. Các image tải được **không** giúp có khoá đó. Muốn biết HT43 có cùng khoá không thì cần chính image của HT43 (server không phát).

---

## 5. Image liên quan nhất

| Đồng hồ | Image liên quan | Lý do |
|---|---|---|
| **Y25** | `RB370L73AC` V001205 (chính nó) | Bản duy nhất của họ 370 trên server |
| **HT43** | Không có image riêng. Gần nhất: `RB370L73AC` (cùng dự án `370` + cấu hình `L73A`, khác cảm biến `B`/`H` và biến thể `C`, suy luận) | Server không phát gì cho `RH370L73ACC` hay biến thể |
| Đối chứng cùng họ chip | `RB303JD` V003810 | Image Bee3 duy nhất khác; cho thấy UTE dùng khoá/thuật toán khác giữa các dự án |
| Đối chứng đời cũ | 7 image + 1 bản vá Bee2 (RTL8762C) | Không ký; hữu ích nếu cần tham khảo định dạng Bee2, không dùng được cho Y25/HT43 |

## 6. Việc có thể làm tiếp (chỉ đọc)

1. Lấy image HT43 bằng cách khác: hỏi nhà bán / UTE, hoặc tìm app đi kèm HT43 (nếu không phải GloryFit/GloryFitPro thì app đó có `YCAPPKEY` riêng; chỉ cần đọc manifest).
2. Khi có app key mới: chạy lại các nhóm ở §2 với key đó (log và script mẫu nằm trong nhật ký JSONL).
3. Muốn biết HT43 có tin khoá của Y25 không thì phải hỏi đồng hồ qua lệnh DFU `CHECK_PUB_KEYS` (hash `98 5B 8A C4`). Lệnh này nằm trong luồng DFU (phải vào chế độ OTA), **không** phải lệnh chỉ đọc thông thường, nên **chưa làm** và cần cân nhắc rủi ro trước khi thử.
