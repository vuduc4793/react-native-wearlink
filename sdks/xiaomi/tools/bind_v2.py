"""Xiaomi wear V2 (Smart Band 11): ghép cục bộ (ECDH, không cần tài khoản Xiaomi) + xác thực + đọc pin/thông tin.

    python -I bind_v2.py bind     # band vừa reset: ghép, lưu khoá vào ~/.smartwear/xiaomi-<mac>.json (quyền 600)
    python -I bind_v2.py auth     # dùng khoá đã lưu: xác thực rồi đọc pin + thông tin thiết bị
    python -I bind_v2.py import MAC  # nhập khoá (encryptKey 32 hex, lấy từ Mi Fitness) từ stdin, không in ra

Band 11 bản quốc tế (miwear.watch.q66gl) trả verifyMode=1 ⇒ KHÔNG ghép cục bộ được, phải ghép bằng Mi Fitness
(server Xiaomi) rồi nhập khoá bằng `import`.

Giao thức: sdks/xiaomi/docs/01-protocol.md (§2.3 V2, §4.2 local bind, §4.3 auth).
"""
import asyncio, hashlib, hmac, json, os, struct, sys
from pathlib import Path
from bleak import BleakScanner, BleakClient
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.ciphers.aead import AESCCM
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives import hashes

U = lambda x: f'0000{x:04x}-0000-1000-8000-00805f9b34fb'
WR, NT = U(0x5F), U(0x5E)
USER_ID = 'smartwear-lab'
BIND_NONCE = bytes(range(0x10, 0x1C))
KEY_DIR = Path.home() / '.smartwear'


# ---------- protobuf tối giản ----------
def varint(n):
    out = b''
    while True:
        b = n & 0x7F; n >>= 7
        out += bytes([b | (0x80 if n else 0)])
        if not n: return out
def fv(f, v): return varint(f << 3) + varint(v)
def fb(f, b): return varint(f << 3 | 2) + varint(len(b)) + (b.encode() if isinstance(b, str) else b)
def ff(f, x): return varint(f << 3 | 5) + struct.pack('<f', x)

def parse(b):
    """→ {field: [value…]}; length-delimited giữ bytes."""
    i, out = 0, {}
    def rv():
        nonlocal i
        v = s = 0
        while True:
            x = b[i]; i += 1; v |= (x & 0x7F) << s; s += 7
            if not x & 0x80: return v
    while i < len(b):
        k = rv(); f, w = k >> 3, k & 7
        if w == 0: v = rv()
        elif w == 2: n = rv(); v = b[i:i + n]; i += n
        elif w == 5: v = b[i:i + 4]; i += 4
        elif w == 1: v = b[i:i + 8]; i += 8
        else: raise ValueError(f'wire {w}')
        out.setdefault(f, []).append(v)
    return out
def g(m, *path):
    for f in path:
        if m is None or f not in m: return None
        v = m[f][0]
        m = parse(v) if isinstance(v, bytes) and f != path[-1] else v
    return m

def packet(typ, sub, field=None, body=b''):
    return fv(1, typ) + fv(2, sub) + (fb(field, body) if field else b'')


# ---------- crypto ----------
def hm(k, d): return hmac.new(k, d, hashlib.sha256).digest()
def hkdf(info, ikm, salt): return HKDF(hashes.SHA256(), 64, salt, info.encode()).derive(ikm)
def ctr(key, data):
    c = Cipher(algorithms.AES(key), modes.CTR(key)).encryptor()
    return c.update(data) + c.finalize()


# ---------- V2 transport ----------
def crc16(b):
    c = 0
    for x in b:
        c ^= x
        for _ in range(8): c = (c >> 1) ^ 0xA001 if c & 1 else c >> 1
    return c

class V2:
    def __init__(self, client):
        self.c, self.buf, self.tx, self.q = client, bytearray(), 0, asyncio.Queue()
        self.enc_key = self.dec_key = None

    def _on(self, _, b):
        self.buf.extend(b)
        while len(self.buf) >= 8:
            if self.buf[0:2] != b'\xa5\xa5': del self.buf[0]; continue
            n = struct.unpack_from('<H', self.buf, 4)[0]
            if len(self.buf) < 8 + n: break
            pkt = bytes(self.buf[:8 + n]); del self.buf[:8 + n]
            typ, seq, pl = pkt[2] & 0xF, pkt[3], pkt[8:]
            if typ == 3:
                asyncio.get_event_loop().create_task(self._raw(1, seq))   # ACK
                self.q.put_nowait(('data', pl))
            elif typ == 2:
                self.q.put_nowait(('cmd', pl))

    async def _raw(self, typ, seq, payload=b''):
        frame = struct.pack('<HBBHH', 0xA5A5, typ, seq, len(payload), crc16(payload) if payload else 0) + payload
        mtu = max(23, self.c.mtu_size) - 3
        for i in range(0, len(frame), mtu):
            await self.c.write_gatt_char(WR, frame[i:i + mtu], response=False)

    async def start(self):
        await self.c.start_notify(NT, self._on)
        tlv = bytes.fromhex('01030001000002020000fc03020020000402001027')
        await self._raw(2, 0, b'\x01' + tlv)
        kind, pl = await asyncio.wait_for(self.q.get(), 8)
        assert kind == 'cmd' and pl[0] == 2, f'START_RSP? {pl.hex()}'

    async def call(self, pb, encrypted=False, timeout=15, want=None):
        body = ctr(self.enc_key, pb) if encrypted else pb
        await self._raw(3, self.tx, bytes([1, 2 if encrypted else 1]) + body); self.tx = (self.tx + 1) & 0xFF
        while True:
            kind, pl = await asyncio.wait_for(self.q.get(), timeout)
            if kind != 'data' or pl[0] != 1: continue
            msg = pl[2:]
            if pl[1] == 2: msg = ctr(self.dec_key, msg)
            m = parse(msg)
            if want is None or (g(m, 1), g(m, 2)) == want: return m
            print('   (bỏ qua gói khác)', g(m, 1), g(m, 2))


def account(m):
    acc = parse(m[3][0]) if 3 in m else {}
    err = g(acc, 3)
    if err: raise RuntimeError(f'thiết bị báo lỗi {err}')
    return acc


async def find():
    d = await BleakScanner.find_device_by_filter(lambda d, a: (a.local_name or '').startswith('Xiaomi Smart Band 11'), timeout=20)
    if not d: sys.exit('không thấy band')
    return d


async def bind():
    d = await find()
    async with BleakClient(d, timeout=20) as c:
        t = V2(c); await t.start()
        info = account(await t.call(packet(1, 17, 3, fb(11, fv(1, 0) + fb(2, hashlib.md5(USER_ID.encode()).digest()))), want=(1, 17)))
        bi = parse(info[12][0])
        verify, oob = g(bi, 1), g(bi, 5)
        mac, model, sn, did = (g(bi, k).decode() if g(bi, k) else '' for k in (3, 4, 2, 7))
        print(f'bindInfo: verifyMode={verify} oobMode={oob} model={model} mac={mac} sn={sn} did={did}')
        if verify != 2 or oob not in (2, 3): sys.exit('band không cho ghép cục bộ (cần server Xiaomi)')

        priv = ec.generate_private_key(ec.SECP256R1())
        pub = priv.public_key().public_numbers()
        pub64 = pub.x.to_bytes(32, 'big') + pub.y.to_bytes(32, 'big')
        app_dev_id = hashlib.md5((mac.upper() + USER_ID).encode()).hexdigest()
        if oob == 3: print('>>> BẤM XÁC NHẬN TRÊN VÒNG TAY <<<')
        r = account(await t.call(packet(1, 18, 3, fb(17, fb(1, app_dev_id) + fb(2, pub64))), timeout=60, want=(1, 18)))
        y = parse(r[18][0]); dpub, drand, dsign = g(y, 1), g(y, 2), g(y, 3)
        peer = ec.EllipticCurvePublicNumbers(int.from_bytes(dpub[:32], 'big'), int.from_bytes(dpub[32:], 'big'), ec.SECP256R1()).public_key()
        shared = priv.exchange(ec.ECDH(), peer)
        if hm(shared, drand) != dsign: sys.exit('chữ ký thiết bị sai')
        print('ECDH OK, chữ ký thiết bị khớp')

        arand = os.urandom(16)
        okm = hkdf('miwear-bind', shared, arand + drand)
        if oob == 3: print('>>> BẤM XÁC NHẬN TRÊN VÒNG TAY (nếu vòng đang hỏi) <<<')
        r = account(await t.call(packet(1, 19, 3, fb(19, fb(1, arand) + fb(2, hm(shared, arand)))), timeout=60, want=(1, 19)))
        if not g(parse(r[20][0]), 1): sys.exit('vòng không xác nhận')
        print('vòng đã xác nhận')

        companion = fv(1, 0) + ff(2, 34.0) + fb(3, 'SmartWear Lab')
        bind_data = AESCCM(okm[16:32], tag_length=4).encrypt(BIND_NONCE, fb(1, USER_ID) + fb(2, companion), b'bind-data')
        m = await t.call(packet(1, 25, 3, fb(29, fb(1, bind_data))), timeout=30, want=(1, 25))
        if 3 in m: account(m)
        auth_key = okm[40:56]
        KEY_DIR.mkdir(mode=0o700, exist_ok=True)
        f = KEY_DIR / f'xiaomi-{mac.replace(":", "")}.json'
        f.write_text(json.dumps({'mac': mac, 'model': model, 'sn': sn, 'did': did, 'userId': USER_ID,
                                 'appDeviceId': app_dev_id, 'authKey': auth_key.hex()}))
        f.chmod(0o600)
        print(f'GHÉP XONG. Khoá lưu ở {f} (không in ra).')


async def auth():
    files = sorted(KEY_DIR.glob('xiaomi-*.json'))
    if not files: sys.exit('chưa có khoá, chạy bind trước')
    cfg = json.loads(files[-1].read_text()); key = bytes.fromhex(cfg['authKey'])
    d = await find()
    async with BleakClient(d, timeout=20) as c:
        t = V2(c); await t.start()
        arand = os.urandom(16)
        r = account(await t.call(packet(1, 26, 3, fb(30, fb(1, arand) + (fb(2, cfg['appDeviceId']) if cfg.get('appDeviceId') else b'') + fv(3, 0))), want=(1, 26)))
        h = parse(r[31][0]); drand, dsign = g(h, 1), g(h, 2)
        okm = hkdf('miwear-auth', key, arand + drand)
        dec_key, enc_key, dec_iv, enc_iv = okm[0:16], okm[16:32], okm[32:36], okm[36:40]
        if hm(dec_key, drand + arand) != dsign: sys.exit('chữ ký thiết bị sai (khoá không khớp)')
        info = fv(1, 0) + ff(2, 34.0) + fb(3, 'SmartWear Lab') + fv(4, 224) + fb(5, 'VN')
        enc_info = AESCCM(enc_key, tag_length=4).encrypt(enc_iv + bytes(8), info, None)
        r = account(await t.call(packet(1, 27, 3, fb(32, fb(1, hm(enc_key, arand + drand)) + fb(2, enc_info))), want=(1, 27)))
        e = parse(r[33][0])
        print(f'XÁC THỰC: success={g(e, 1)} capability={g(e, 2)} capabilityV2={g(e, 3)}')
        t.enc_key, t.dec_key = enc_key, dec_key

        m = await t.call(packet(2, 1), encrypted=True, want=(2, 1))
        sysm = parse(m[4][0]); bat = parse(g(sysm, 2))
        print(f'PIN: {g(bat, 1)}%  sạc={g(bat, 2)}')
        m = await t.call(packet(2, 2), encrypted=True, want=(2, 2))
        di = parse(parse(m[4][0])[3][0])
        print('THIẾT BỊ:', {k: (v[0].decode() if isinstance(v[0], bytes) else v[0]) for k, v in sorted(di.items())})


async def import_key():
    mac = sys.argv[2].upper()
    key = sys.stdin.readline().strip().lower().removeprefix('0x')
    if len(key) != 32 or any(c not in '0123456789abcdef' for c in key): sys.exit('khoá phải là 32 ký tự hex')
    KEY_DIR.mkdir(mode=0o700, exist_ok=True)
    f = KEY_DIR / f'xiaomi-{mac.replace(":", "").lower()}.json'
    f.write_text(json.dumps({'mac': mac, 'userId': '', 'appDeviceId': '', 'authKey': key}))
    f.chmod(0o600)
    print(f'đã lưu khoá vào {f}')


if __name__ == '__main__':
    asyncio.run({'bind': bind, 'auth': auth, 'import': import_key}[sys.argv[1] if len(sys.argv) > 1 else 'auth']())
