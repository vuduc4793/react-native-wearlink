"""Quét mọi thiết bị BLE xung quanh, đánh dấu thiết bị có khả năng là nhẫn QRing/Colmi."""

import asyncio
import re
import sys

from bleak import BleakScanner

RING_SERVICE = "6e40fff0-b5a3-f393-e0a9-e50e24dcca9e"
RING_NAME = re.compile(r"^(R\d|COLMI|QRING|RING)", re.IGNORECASE)


async def main(seconds: float) -> None:
    print(f"Đang quét {seconds:.0f}s...")
    found = await BleakScanner.discover(timeout=seconds, return_adv=True)
    rows = []
    for device, adv in found.values():
        name = adv.local_name or device.name or ""
        uuids = [u.lower() for u in adv.service_uuids]
        is_ring = RING_SERVICE in uuids or bool(RING_NAME.match(name))
        manu = " ".join(f"{k:04x}:{v.hex()}" for k, v in adv.manufacturer_data.items())
        rows.append((is_ring, adv.rssi, device.address, name, uuids, manu))

    rows.sort(key=lambda r: (not r[0], -r[1]))
    for is_ring, rssi, address, name, uuids, manu in rows:
        mark = ">>" if is_ring else "  "
        print(f"{mark} {rssi:4d} dBm  {address}  {name or '(không tên)'}")
        if is_ring or uuids:
            print(f"           uuids={uuids}  manu={manu}")
    print(f"\nTổng: {len(rows)} thiết bị, {sum(r[0] for r in rows)} nghi là nhẫn (đánh dấu >>).")


if __name__ == "__main__":
    asyncio.run(main(float(sys.argv[1]) if len(sys.argv) > 1 else 15))
