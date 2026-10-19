"""Thử giao thức Xiaomi wear V2 (BLE FE95 0x5F/0x5E) với Smart Band 11: START + getBindInfo (1/17). Không ghép."""
import asyncio, hashlib, struct, sys
from bleak import BleakScanner, BleakClient

U = lambda x: f'0000{x:04x}-0000-1000-8000-00805f9b34fb'
WR, NT = U(0x5F), U(0x5E)

def crc16(b):
    c = 0
    for x in b:
        c ^= x
        for _ in range(8): c = (c >> 1) ^ 0xA001 if c & 1 else c >> 1
    return c

def l1(typ, seq, payload=b'', frx=0):
    return struct.pack('<HBBHH', 0xA5A5, (frx << 4) | typ, seq, len(payload), crc16(payload) if payload else 0) + payload

# protobuf tối giản
def varint(n):
    out = b''
    while True:
        b = n & 0x7F; n >>= 7
        out += bytes([b | (0x80 if n else 0)])
        if not n: return out
def f_varint(f, v): return varint(f << 3) + varint(v)
def f_bytes(f, b): return varint(f << 3 | 2) + varint(len(b)) + b

def parse(b):
    i, out = 0, []
    while i < len(b):
        k = 0; s = 0
        while True:
            x = b[i]; i += 1; k |= (x & 0x7F) << s; s += 7
            if not x & 0x80: break
        f, w = k >> 3, k & 7
        if w == 0:
            v = 0; s = 0
            while True:
                x = b[i]; i += 1; v |= (x & 0x7F) << s; s += 7
                if not x & 0x80: break
        elif w == 2:
            n = 0; s = 0
            while True:
                x = b[i]; i += 1; n |= (x & 0x7F) << s; s += 7
                if not x & 0x80: break
            v = b[i:i + n]; i += n
        elif w == 5: v = b[i:i + 4]; i += 4
        elif w == 1: v = b[i:i + 8]; i += 8
        else: raise ValueError(f'wire {w}')
        out.append((f, w, v))
    return out

def show(b, ind='  '):
    try: fields = parse(b)
    except Exception: return print(ind + 'raw', b.hex())
    for f, w, v in fields:
        if w == 2:
            txt = v.decode('utf-8', 'strict') if v and all(32 <= c < 127 for c in v) else None
            if txt: print(f'{ind}{f}: "{txt}"')
            else:
                print(f'{ind}{f}: ({len(v)}B) {v.hex()}')
                if v: show(v, ind + '    ')
        else: print(f'{ind}{f}: {v if w == 0 else v.hex()}')

async def main():
    d = await BleakScanner.find_device_by_filter(lambda d, a: (a.local_name or '').startswith('Xiaomi Smart Band 11'), timeout=20)
    if not d: return print('không thấy band')
    q = asyncio.Queue()
    buf = bytearray()
    def on(_, b):
        buf.extend(b)
        while len(buf) >= 8:
            if buf[0:2] != b'\xa5\xa5':
                del buf[0]; continue
            n = struct.unpack_from('<H', buf, 4)[0]
            if len(buf) < 8 + n: break
            pkt = bytes(buf[:8 + n]); del buf[:8 + n]
            q.put_nowait(pkt)
    async with BleakClient(d, timeout=20) as c:
        print('kết nối', d.address, 'mtu', c.mtu_size, 'ver', (await c.read_gatt_char(U(0x50))).hex())
        await c.start_notify(NT, on)
        # START_REQ TLV: 01 version 1.0.0 | 02 MPS 64512 | 03 TX window 32 | 04 timeout 10000 ms
        start = bytes([1]) + bytes.fromhex('010300010000') + bytes.fromhex('02020000fc') + bytes.fromhex('0302002000') + bytes.fromhex('0402001027')
        await c.write_gatt_char(WR, l1(2, 0, start), response=False)
        print('>> START', start.hex())
        txseq = 0
        async def recv(timeout=8):
            pkt = await asyncio.wait_for(q.get(), timeout)
            typ, seq, n = pkt[2] & 0xF, pkt[3], struct.unpack_from('<H', pkt, 4)[0]
            frx = pkt[2] >> 4
            pl = pkt[8:]
            print(f'<< type={typ} frx={frx} seq={seq} len={n} {pl.hex()}')
            if typ == 3:
                await c.write_gatt_char(WR, l1(1, seq), response=False)  # ACK
            return typ, pl
        try:
            while True:
                typ, pl = await recv()
                if typ == 2 and pl[:1] == b'\x02': print('   START_RSP OK'); break
        except asyncio.TimeoutError:
            return print('không có START_RSP')
        user = sys.argv[1] if len(sys.argv) > 1 else 'smartwear-lab'
        acc = f_bytes(11, f_varint(1, 0) + f_bytes(2, hashlib.md5(user.encode()).digest()))
        pb = f_varint(1, 1) + f_varint(2, 17) + f_bytes(3, acc)
        l2 = bytes([1, 1]) + pb
        await c.write_gatt_char(WR, l1(3, txseq, l2), response=False); txseq += 1
        print('>> getBindInfo', l2.hex())
        try:
            for _ in range(6):
                typ, pl = await recv()
                if typ == 3:
                    print(f'   L2 channel={pl[0]} op={pl[1]}'); show(pl[2:]); break
        except asyncio.TimeoutError:
            print('hết giờ chờ phản hồi')
asyncio.run(main())
