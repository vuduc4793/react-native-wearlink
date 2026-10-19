"""Quét BLE từ một máy thứ ba (Mac) để chẩn đoán thiết bị đeo "lúc thấy lúc không".

Dùng (cần bleak; venv có sẵn ở firmware-flasher/.venv):
  python3 -I tools/ble_scan.py timeline [giây]   # mốc thời gian mỗi lần thấy Y25/HT43/R09/DS500/GPS 103
  python3 -I tools/ble_scan.py ute [giây]        # mọi gói có dịch vụ UTE 0x55xx/0x56xx hoặc MAC 78:02:B7 (kể cả không tên)
  python3 -I tools/ble_scan.py raw [giây]        # toàn bộ thiết bị, sắp theo RSSI, kèm manufacturer data

Thiết bị BLE đang có máy khác kết nối thì NGỪNG quảng bá: không thấy trong scan nghĩa là
"đang bị giữ" hoặc "đang ngủ", không phải "đã hỏng". Xem docs/case-studies/2026-10-15-y25-khong-tim-thay.md.
"""
import asyncio
import sys
import time

from bleak import BleakScanner

WATCH = ("Y25", "HT43", "R09", "DS500", "GPS 103")


def is_ute(name, uuids, md_hex):
    return (any(u.startswith(("55", "56")) for u in uuids) or "7802b7" in md_hex
            or (name or "").startswith(WATCH))


async def main(mode, seconds):
    t0, last, seen = time.time(), {}, {}

    def cb(d, a):
        name = a.local_name or d.name
        uuids = [u[4:8] for u in a.service_uuids]
        md = {k: v.hex() for k, v in a.manufacturer_data.items()}
        md_hex = "".join(md.values())
        t = time.time() - t0
        if mode == "timeline":
            for k in WATCH:
                if (name or "").startswith(k):
                    if t - last.get(k, -99) > 3:
                        print(f"{t:6.1f}s {k:8s} rssi={a.rssi}", flush=True)
                    last[k] = t
            return
        if mode == "ute" and not is_ute(name, uuids, md_hex):
            return
        if d.address not in seen:
            seen[d.address] = [0, name, a.rssi, uuids, md]
        seen[d.address][0] += 1
        seen[d.address][2] = a.rssi

    async with BleakScanner(cb):
        await asyncio.sleep(seconds)
    if mode == "timeline":
        print("lần cuối thấy:", {k: round(v, 1) for k, v in last.items()} or "không thấy thiết bị nào")
        return
    for addr, (count, name, rssi, uuids, md) in sorted(seen.items(), key=lambda x: -x[1][2]):
        print(f"{rssi:4d} x{count:<3d} {str(name)[:24]:24s} {addr} {uuids} {md}")


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "timeline"
    secs = float(sys.argv[2]) if len(sys.argv) > 2 else 30
    if mode not in ("timeline", "ute", "raw"):
        sys.exit(__doc__)
    asyncio.run(main(mode, secs))
