# Firmware Flasher — GloryFit / Realtek

Công cụ dòng lệnh OTA qua Bluetooth, tạo riêng cho image App của Y25
`RB370L73AC_V001205.bin`. Chạy trên macOS, Linux và Windows qua Bleak.

**Trạng thái: thử nghiệm.** Đã kiểm tra firmware thật và mô phỏng giao thức;
chưa thử nạp lên đồng hồ thật. Không phải công cụ mở khóa bootloader hoặc ký
firmware. Chữ ký hợp lệ với khóa trong file chưa chứng minh thiết bị tin khóa đó.

## Cài đặt

Mở terminal tại thư mục `firmware-flasher`:

```sh
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt
```

Windows: dùng `.venv\Scripts\activate` thay lệnh `source`.
macOS: cấp quyền Bluetooth cho ứng dụng terminal đang chạy Python.

## 1. Kiểm tra file, không dùng Bluetooth

```sh
python flasher.py inspect ../sdks/gloryfit/research/firmware/RB370L73AC_V001205.bin
python flasher.py plan ../sdks/gloryfit/research/firmware/RB370L73AC_V001205.bin
```

Kiểm tra MP header, image ID, chip, độ dài, magic, CRC-16/ARC,
SHA-256, hash public key và chữ ký ECDSA P-256. File sửa sai chữ ký bị từ chối.
`plan` in lệnh trước mã hóa đường truyền, không kết nối hoặc gửi lệnh.

## 2. Tìm và đọc thiết bị

Đóng/ngắt kết nối GloryFit hoặc ứng dụng khác đang giữ kết nối với đồng hồ.

```sh
python flasher.py scan --timeout 10
python flasher.py --log probe.log probe "DEVICE_ADDRESS"
```

`DEVICE_ADDRESS` lấy từ kết quả scan. Trên macOS đây thường là UUID, không phải
địa chỉ MAC. `probe` chỉ đọc các characteristic và in năng lực DFU; không bật
notify, không gửi opcode hoặc chuyển chế độ OTA. Nếu protocol khác 0x0010 hoặc
spec ngoài 4–8, công cụ báo chưa hỗ trợ.

## 3. Nạp firmware

Lệnh `flash` bắt đầu ghi thật, không có hộp xác nhận bổ sung. Dùng firmware gốc
đúng model trong lần thử đầu. Giữ pin ít nhất 50%, thiết bị ở gần và kết nối ổn
định. File OTA này không phải bản sao lưu toàn bộ flash để khôi phục qua dây.

```sh
python flasher.py --log flash.log flash "DEVICE_ADDRESS" ../sdks/gloryfit/research/firmware/RB370L73AC_V001205.bin
```

Nếu không có BLE Battery Service, đọc mức pin trên đồng hồ rồi cung cấp:

```sh
python flasher.py --log flash.log flash "DEVICE_ADDRESS" ../sdks/gloryfit/research/firmware/RB370L73AC_V001205.bin --battery 80
```

Nếu đọc được pin qua BLE, số đọc từ thiết bị được ưu tiên. `--battery` chỉ là
mức pin do người dùng khai báo, không phải phép đo của công cụ.

Tùy chọn:

- `--no-activate`: truyền và validate, không gửi kích hoạt/khởi động lại.
  Muốn kích hoạt sau đó, chạy lại lệnh flash bình thường; tool hỏi resume offset,
  có thể truyền lại nếu thiết bị không giữ image chờ.
- `--delay 0.02`: tăng khoảng nghỉ giữa gói nếu kết nối chậm.
- `--timeout 30`: thời gian chờ kết nối/phản hồi.

Chỉ gửi `ACTIVE_IMAGE_RESET` sau khi `VALIDATE_FW_IMAGE` thành công. Thông báo
"đã gửi kích hoạt" không khẳng định boot thành công: cần kiểm tra đồng hồ và
phiên bản sau khi kết nối lại. Không tự kích hoạt khi lỗi hoặc khi nhấn Ctrl+C.
Nếu ngắt giữa chừng, chạy lại với cùng file để thiết bị cung cấp offset resume.

## Phạm vi hỗ trợ

- Một image App có MP header 512 byte, IC 0x11, image ID 0x2793, không mã hóa
  nội dung image; đây là định dạng của file Y25 trong dự án.
- Realtek protocol 0x0010, spec 4–8, silent DFU đã hiện trong GATT.
- CHECK_PUB_KEYS ở spec ≥6, START/RECEIVE/VALIDATE/ACTIVE, report image count.
- AES-256 từng block theo cờ thiết bị; khóa transport trích từ app UTE.
  Chế độ AES cần được xác nhận bằng thử nghiệm thiết bị; chưa đối chiếu native
  RtkAesJni bằng vector thu thực tế.
- Buffer-check XOR16/byte-swap, ACK offset, tối đa 3 lần gửi một buffer;
  resume theo offset thiết bị. Offset bất thường sẽ dừng.
- Truyền đầy đủ image, không dùng tối ưu SHA-skip/copy bank.

Chưa hỗ trợ normal mode/reconnect bootloader, RWS, gói nhiều image, firmware
chip khác, image nén, tự chọn image theo model, kiểm tra kích thước phân vùng
hoặc mở khóa bảo mật. Tool không tự ghi eFuse, xóa toàn bộ flash hay ký lại file.
Cần tự xác nhận model đúng: IC/image ID giống nhau không chứng minh cùng bo.

## Kiểm tra tự động

Từ thư mục gốc dự án:

```sh
python3 -m unittest discover -s firmware-flasher/tests -v
```

Kiểm tra file Y25 gốc, từ chối file sửa/hỏng, AES packet, resume, busy, timeout,
buffer CRC/retry, lỗi khóa và việc không kích hoạt khi validate thất bại.
Đây là kiểm tra offline với thiết bị mô phỏng, không phải kiểm chứng phần cứng.

## Nguồn giao thức trong dự án

- `sdks/gloryfit/docs/05-firmware-analysis.md`
- `sdks/gloryfit/docs/07-ota-realtek.md`
- `sdks/gloryfit/research/xapk-pro/jadx-out/sources/com/realsil/sdk/dfu/s/{d,g,h}.java`
- `.../dfu/internal/base/BaseDfuTask.java`, `.../dfu/j/c.java`
- `.../com/yc/utesdk/ota/UteOtaUtils.java`
