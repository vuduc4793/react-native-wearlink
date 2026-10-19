# Firmware Y25 (RB370L73AC) — trích xuất và đánh giá

## 1. Lấy file firmware

App GloryFit kiểm tra cập nhật qua API của UTE (`com/yc/server/yc_sdk/Agent.java:255-320`, `com/yc/pedometer/update/Updates.java:333-358`):

```
POST https://www.ute-tech.com.cn/ci-yc/index.php/api/client/getBtVersionUpdate
Content-Type: application/x-www-form-urlencoded
content={"appkey":"<YCAPPKEY trong AndroidManifest>","btname":"RB370L73AC","versionname":"V001205","language":"en"}
```

- `btname` = chuỗi firmware `A1` cắt trước chữ `V`; `versionname` = phần từ `V`. Trường `mac` là tuỳ chọn (không gửi).
- Server chỉ trả file khi có bản mới hơn. Gửi `versionname` cũ (ví dụ `V000001`) thì nhận được bản mới nhất.
- Kết quả ngày 13/10/2026: `V001205`, phát hành 2026-09-16, "修复已知问题" (sửa lỗi đã biết), đúng phiên bản đang chạy trên Y25.
  - URL: `https://update.ute-tech.com.cn/ble/<appkey>/RB370L73AC/1789544413_1645.bin` (có bản sao trên S3 `uteap.s3.ap-south-1.amazonaws.com`).
  - Lưu tại `sdks/gloryfit/research/firmware/RB370L73AC_V001205.bin`, 1 683 828 byte,
    SHA-256 `7d477c2d76f3f4040cf3f0b08f68bb5734efbbc889a2a057eff2b3472eb83e55`.
- Còn 2 API cùng họ chưa thử: `getPatchVersionUpdates` (bản vá ROM Realtek, app gọi khi chip là Realtek) và
  `getBtUIVersionUpdate` (gói giao diện; app chỉ gọi khi F5 `0x400000` bật, Y25 thì không).

## 2. Đánh giá nhanh

| Câu hỏi | Kết quả |
|---|---|
| Header | Bắt đầu bằng bảng image Realtek, có chuỗi `RTL8763E` (họ chip của RTL8773E) |
| Mã hoá | **Không**: độ hỗn loạn khoảng 7,0 bit/byte (mã ARM thường); có 1 884 chuỗi đọc được |
| Nguồn gốc code | UTE tự viết trên SDK Realtek: `..\ute\thrid_lib\little_fs\lfs.c`, `uteModule…Timer`, `UTE_WATCH`, `RTL8773EWE` |
| Hệ thống file | LittleFS (`lfs.c`); các khoá cấu hình kiểu `systemparam/softVersion`, `barometer/…` |
| Ký số | Chưa thấy dấu hiệu rõ (chuỗi `iap_signature` là của Apple iAP, không phải chữ ký firmware). Cần phân tích định dạng header Realtek để chắc chắn (suy luận) |
| Mặt đồng hồ mặc định | **Gần như chắc chắn không nằm trong file này**: 1,6 MB quá nhỏ cho tài nguyên 466 × 466 (mỗi ảnh toàn màn RGB565 = 434 KB). Tài nguyên giao diện nằm ở gói riêng trên flash ngoài (suy luận, có API `getBtUIVersionUpdate`) |
| Mã nguồn công khai | Một phần: SDK + bộ công cụ của **họ RTL8763E/RTL87x3E** là **công khai** (`github.com/rtkconnectivity/RTL87x3E-Common-SDK`, có `prepend_header`/`resign_tool`/`rsa_key_generator`/khoá RSA mặc định). SDK đúng cho **RTL8773E** thì repo này **không** có; firmware là mã độc quyền của UTE, ký bằng khoá riêng của UTE. Xem `07-ota-realtek.md` §4 |

## 3. Hệ quả cho việc đặt mặt đồng hồ mặc định

- Thay đổi mặt đồng hồ mặc định là **thay gói tài nguyên giao diện**, không phải file firmware chính. Gói này cần công cụ đóng gói tài nguyên của UTE/Realtek.
- **Cách 1 (khuyến nghị):** liên hệ UTE (`ute-tech.com.cn`, đơn vị làm app GloryFit và firmware) hoặc nhà máy bán Y25, cung cấp:
  - model `RB370L73AC`, firmware `V001205`, màn 466 × 466;
  - thiết kế mặt đồng hồ (ảnh + bố cục các thành phần, xem `03-watchface-elements.md`);
  - yêu cầu: đặt làm mặt mặc định (và logo khởi động nếu cần), giao gói OTA.
- **Cách 2 (tự làm):** cần tải và phân tích gói giao diện (nếu server cấp) cùng công cụ đóng gói tài nguyên. Rủi ro làm hỏng máy, cần dụng cụ cứu máy (xem trao đổi ngày 13/10).

## 4. HT43 (`RH370L73ACCV000788`), kiểm tra ngày 14/10/2026

- App key: GloryFit `dcd05f241b65ec7b6af0bbe6f05145c2`; GloryFitPro `75662fe33c4ee9d582b611eac9599ae5` (`com/yc/gloryfitpro/bean/AppBaseInfo.java`).
  Manifest GloryFitPro còn ghi `YCAPPKEY` = `aafe1db321715820098d9b19cbf8acd4` (SDK dùng).
- GloryFitPro gửi `content` = JSON `{appkey, btname, language, mac, versionname}` mã hoá RSA/PKCS1 (khoá công khai trong
  `com/yc/gloryfitpro/utils/RSAUtils.java`) theo từng đoạn 32 ký tự, ghép base64, gửi multipart. Ở đây `versionname` là cả chuỗi firmware
  (`RH370L73ACCV000788`), `btname` là phần trước chữ `V`. Công cụ: `tools/ute_ota_check.py`. Server nhận cả hai kiểu (đã thử lại bằng Y25: trả `V001205`).
- Kết quả HT43: **cả 3 app key, cả dạng thường lẫn mã hoá, `btname` `RH370L73ACC`/`RH370L73AC`, `versionname` `V000001`:
  `no new version`**. `getBtUIVersionUpdate` cũng không có. Server không phát firmware nào cho HT43 qua các app key này.
