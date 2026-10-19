"""Tách file mặt đồng hồ UTE (.bin) thành ảnh từng element.

Dùng: python3 -I tools/ute_face_decode.py <file.bin> <thư_mục_ra>
Ra: <type>_<tên>.png (các frame xếp ngang), elements.json, composite.png (frame 0 của mọi element, trừ preview).
Định dạng: xem sdks/gloryfit/docs/02-watchface.md và 03-watchface-elements.md.
"""
import json
import struct
import sys
from pathlib import Path

from PIL import Image

NO_COMPRESS = set(range(1, 4)) | set(range(35, 47)) | set(range(52, 71))
# Tên ghi "(suy luận)" trong 03-watchface-elements.md là đoán từ ảnh + vị trí trong các mặt đồng hồ của kho.
NAMES = {
    1: "hour_hand", 2: "minute_hand", 3: "second_hand", 4: "hour_number", 5: "minute_number", 6: "second_number",
    7: "colon", 8: "battery", 9: "bluetooth", 10: "preview", 11: "month_number", 13: "day_number", 14: "date_sep",
    15: "week", 16: "ampm", 17: "background", 18: "heart_icon", 19: "heart_number", 20: "weather_icon",
    21: "temperature_number", 22: "temperature_unit", 23: "heart_bpm_label", 24: "step_icon", 25: "step_number",
    26: "step_label", 29: "kcal_icon", 30: "kcal_number", 31: "kcal_label", 32: "step_progress",
    33: "battery_number", 34: "battery_percent", 47: "distance_number", 51: "distance_icon",
    71: "progress_71", 72: "progress_72",
    57: "hour_tens", 58: "hour_units", 59: "minute_tens", 60: "minute_units", 61: "second_tens", 62: "second_units",
    63: "month_tens", 64: "month_units", 65: "day_tens", 66: "day_units",
}


def rgb(hi, lo):
    v = (hi << 8) | lo
    return ((v >> 11) & 31) * 255 // 31, ((v >> 5) & 63) * 255 // 63, (v & 31) * 255 // 31, 0 if v == 0 else 255


def raw_frame(b, p, w, h):
    px = [rgb(b[p + 2 * i], b[p + 2 * i + 1]) for i in range(w * h)]
    return px, p + w * h * 2


def rle_frame(b, p, w, h):
    size = struct.unpack_from("<I", b, p)[0]
    table = p + 4
    px = []
    for r in range(h):
        q = table + struct.unpack_from("<I", b, table + 4 * r)[0]  # offset tính từ đầu bảng
        row = []
        while len(row) < w:
            n, count = b[q], b[q + 1]
            q += 2
            for _ in range(n):
                row += [rgb(b[q], b[q + 1])] * count
                q += 2
        px += row[:w]
    return px, table + size


def decode(path, out):
    b = Path(path).read_bytes()
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    width, height = struct.unpack_from("<HH", b, 12)
    level = b[19]
    count = b[20]
    if count == 0xFF:  # file cũ (và file app tự dựng) không ghi số element: bảng kết thúc ở địa chỉ dữ liệu đầu tiên - 2
        count = (struct.unpack_from("<I", b, 28)[0] - 26) // 24
    elements = []
    for k in range(count):
        p = 24 + 24 * k
        t, w, addr, h, x, y, z, frames = struct.unpack_from("<HHIHHHHB", b, p)
        extra = b[p + 17:p + 24]
        e = dict(type=t, name=NAMES.get(t, f"type{t}"), w=w, h=h, x=x, y=y, z=z, frames=frames, addr=addr, extra=extra.hex(" "))
        if t in (1, 2, 3):  # kim: (x, y) = tâm xoay trên màn; extra[5] = toạ độ y của tâm trong ảnh kim (thẳng đứng, chỉ 12 giờ)
            e["pivot_in_image"] = [w // 2, extra[5]]
        elements.append(e)
    composite = Image.new("RGBA", (width, height), (0, 0, 0, 255))
    # Thứ tự vẽ: nền, các khối, rồi kim giờ → phút → giây trên cùng.
    for e in sorted(elements, key=lambda e: (e["type"] != 17, e["type"] in (1, 2, 3), e["type"])):
        q = e["addr"]  # tính từ đầu file
        compressed = level >= 2 and e["type"] not in NO_COMPRESS
        strip = Image.new("RGBA", (e["w"] * e["frames"], e["h"]))
        try:
            for f in range(e["frames"]):
                px, q = (rle_frame if compressed else raw_frame)(b, q, e["w"], e["h"])
                img = Image.new("RGBA", (e["w"], e["h"]))
                img.putdata(px)
                strip.paste(img, (f * e["w"], 0))
                if f == 0 and e["type"] != 10:
                    ox, oy = e.get("pivot_in_image", (0, 0))
                    composite.alpha_composite(img, (max(0, min(e["x"] - ox, width - 1)), max(0, min(e["y"] - oy, height - 1))))
            e["compressed"] = compressed
        except (IndexError, struct.error) as err:
            e["error"] = str(err)
        strip.save(out / f"{e['type']:02d}_{e['name']}.png")
    composite.save(out / "composite.png")
    meta = dict(file=Path(path).name, width=width, height=height, level=level, header=b[:24].hex(" "), elements=elements)
    (out / "elements.json").write_text(json.dumps(meta, indent=1))
    return meta


if __name__ == "__main__":
    m = decode(sys.argv[1], sys.argv[2])
    for e in m["elements"]:
        print(f"{e['type']:3d} {e['name']:14s} {e['w']:3d}x{e['h']:<3d} @({e['x']},{e['y']}) frames={e['frames']} extra={e['extra']}"
              + (f" ERROR {e['error']}" if "error" in e else ""))
