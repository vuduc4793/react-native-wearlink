#!/usr/bin/env python3
"""Experimental Realtek X0010 silent OTA client. No BLE access on import."""
import argparse
import asyncio
import hashlib
import json
import logging
from pathlib import Path
import struct
import sys
import time

LOG = logging.getLogger('dfu')
BASE = '-0000-1000-8000-00805f9b34fb'
INFO, PROTOCOL, BATTERY = '0000fff1'+BASE, '0000fff3'+BASE, '00002a19'+BASE
SERVICE = '00006287-3c17-d293-8e48-14fe2e4da212'
DATA = '00006387-3c17-d293-8e48-14fe2e4da212'
CONTROL = '00006487-3c17-d293-8e48-14fe2e4da212'
# Transport key from UteOtaUtils.java; this is NOT a firmware signing key.
UTE_KEY = bytes(v & 255 for v in [78,70,-8,-59,9,85,84,69,95,82,75,12,-47,-10,16,-5,31,103,99,-33,-128,122,126,112,-106,13,76,-45,17,-114,96,26])

class DfuError(Exception):
    pass

def crc_arc(data):
    c = 0
    for v in data:
        c ^= v
        for _ in range(8):
            c = (c >> 1) ^ (0xA001 if c & 1 else 0)
    return c

def buffer_crc(data):
    c = 0
    for i in range(0, len(data)-1, 2):
        c ^= data[i] | data[i+1] << 8
    return ((c & 255) << 8) | (c >> 8)

class Image:
    def __init__(self, raw):
        raw = bytes(raw)
        self.raw = raw
        if len(raw) < 0x600 or raw[:3] != b'\x01\x00\x02':
            raise DfuError('Chỉ hỗ trợ image App Realtek có MP header 512 byte.')
        self.mp = {}
        i = 0
        while i+3 <= 512:
            tag, size = struct.unpack_from('<HB', raw, i)
            if tag == 0:
                break
            if i+3+size > 512 or tag in self.mp:
                raise DfuError('MP TLV hỏng hoặc trùng trường.')
            self.mp[tag] = raw[i+3:i+3+size]
            i += 3+size
            if tag == 0xFE:
                break
        self.wire = raw[512:]  # auth header IS transferred; MP header is NOT.
        self.ctrl = raw[0x330:0x33c]
        self.crc, self.ic, self.secure, self.flags, self.id, self.payload = struct.unpack('<HBBHHI', self.ctrl)
        self.key = raw[0x3a0:0x3e1]
        self.key_hash = hashlib.sha256(self.key).digest()[-4:]
        if self.ic != 0x11 or self.id != 0x2793 or self.flags & 2:
            raise DfuError('Chỉ hỗ trợ App ic=0x11, imageId=0x2793, image không mã hóa.')
        if struct.unpack_from('<I', raw, 0x360)[0] != 0x5A5A12A5:
            raise DfuError('Magic Realtek không đúng.')
        if self.payload != len(raw)-0x600:
            raise DfuError('Độ dài payload không khớp.')
        for tag in (4, 0x14):
            if self.mp.get(tag) != struct.pack('<I', len(self.wire)):
                raise DfuError(f'MP length 0x{tag:02x} không khớp.')
        if self.mp.get(0x12) != struct.pack('<H', self.id):
            raise DfuError('MP imageId không khớp.')
        if self.mp.get(0x1d) != self.key_hash:
            raise DfuError('Hash public key không khớp MP header.')
        if crc_arc(raw[0x332:]) != self.crc:
            raise DfuError('CRC16 sai.')
        if hashlib.sha256(raw[0x330:]).digest() != raw[0x310:0x330]:
            raise DfuError('SHA256 sai.')
        from cryptography.hazmat.primitives.asymmetric import ec, utils
        from cryptography.hazmat.primitives import hashes
        from cryptography.exceptions import InvalidSignature
        try:
            key = ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), self.key)
            r = int.from_bytes(raw[0x210:0x230], 'big')
            s = int.from_bytes(raw[0x230:0x250], 'big')
            key.verify(utils.encode_dss_signature(r, s), raw[0x310:], ec.ECDSA(hashes.SHA256()))
        except (ValueError, InvalidSignature) as exc:
            raise DfuError('Chữ ký ECDSA không hợp lệ.') from exc

    def summary(self):
        return {'bytes':len(self.raw), 'sha256':hashlib.sha256(self.raw).hexdigest(),
                'image_id':hex(self.id), 'ic_type':hex(self.ic),
                'public_key_hash':self.key_hash.hex(), 'crc_sha_signature':'OK',
                'trust':'Chữ ký khớp khóa trong file; thiết bị quyết định có tin khóa đó không.'}

def capabilities(raw, protocol):
    if protocol != 0x10 or len(raw) < 10:
        raise DfuError('Chỉ hỗ trợ protocol 0x0010 với FFF1 ít nhất 10 byte.')
    spec, flags = raw[1] & 15, raw[2]
    if not 4 <= spec <= 8:
        raise DfuError(f'Spec {spec} chưa được hỗ trợ (hỗ trợ 4–8).')
    return dict(ic=raw[0], spec=spec, buffer=bool(flags&1), aes=bool(flags&2),
                aes_mode=(flags>>2)&1, copy=bool(flags&8), report=bool(flags&128),
                bank=raw[5], temp_kb=raw[4], mtu=struct.unpack_from('<H',raw,6)[0],
                rws=bool(raw[3]&16), compression=bool(raw[9]&4))

def encrypt_packet(data, caps):
    if not caps['aes']:
        return data
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
    out = bytearray(data)
    count = len(data)//16 if caps['aes_mode'] else min(1, len(data)//16)
    encryptor = Cipher(algorithms.AES(UTE_KEY), modes.ECB()).encryptor()
    for i in range(count):
        out[i*16:i*16+16] = encryptor.update(data[i*16:i*16+16])
    encryptor.finalize()
    return bytes(out)

class Dfu:
    def __init__(self, client, timeout=15):
        self.client, self.timeout = client, timeout
        self.responses = asyncio.Queue()
        self.ready = asyncio.Event()
        self.ready.set()

    def notification(self, _, value):
        value = bytes(value)
        LOG.debug('RX %s', value.hex())
        if len(value) >= 3 and value[:2] == b'\x10\x08':
            self.ready.clear() if value[2] == 1 else self.ready.set()
        elif len(value) >= 3 and value[0] == 0x10:
            self.responses.put_nowait(value)

    async def send(self, command):
        await asyncio.wait_for(self.ready.wait(), self.timeout)
        LOG.debug('TX control %s', command.hex())
        char = self.client.services.get_characteristic(CONTROL)
        response = 'write' in char.properties
        await self.client.write_gatt_char(CONTROL, command, response=response)

    async def request(self, command, timeout=None, statuses=(1,)):
        await self.send(command)
        deadline = time.monotonic() + (timeout or self.timeout)
        while True:
            remaining = deadline-time.monotonic()
            if remaining <= 0:
                raise DfuError(f'Không có phản hồi opcode 0x{command[0]:02x}.')
            try:
                rsp = await asyncio.wait_for(self.responses.get(), remaining)
            except asyncio.TimeoutError as exc:
                raise DfuError(f'Hết thời gian opcode 0x{command[0]:02x}.') from exc
            if rsp[1] != command[0]:
                LOG.debug('Bỏ phản hồi opcode khác: %s', rsp.hex())
                continue
            if rsp[2] not in statuses:
                extra = ' (khóa không được thiết bị tin cậy)' if command[0] == 0x12 else ''
                raise DfuError(f'Opcode 0x{command[0]:02x} bị từ chối: status=0x{rsp[2]:02x}{extra}')
            return rsp[2:]

    async def upload(self, image, caps, delay=0.01, activate=True):
        if caps['ic'] != image.ic or caps['rws']:
            raise DfuError('Chip không khớp hoặc thiết bị RWS chưa hỗ trợ.')
        if caps['spec'] >= 6:
            await self.request(b'\x12\x01'+struct.pack('<H',image.id)+image.key_hash)
        block_size = 0
        if caps['buffer']:
            rsp = await self.request(b'\x09')
            if len(rsp) < 3:
                raise DfuError('Đáp buffer-check quá ngắn.')
            block_size = struct.unpack_from('<H',rsp,1)[0]
            if not 16 <= block_size <= 65520 or block_size % 16:
                raise DfuError('Buffer size không hỗ trợ.')
        rsp = await self.request(b'\x06'+struct.pack('<H',image.id))
        if len(rsp) < 9:
            raise DfuError('Đáp target image info quá ngắn; không đoán offset.')
        offset = struct.unpack_from('<I',rsp,5)[0]
        if not 0 <= offset <= len(image.wire):
            raise DfuError('Resume offset ngoài image.')
        if offset and offset < 12:
            raise DfuError('Resume offset không hợp lệ.')
        if caps['report']:
            await self.send(b'\x13'+struct.pack('<HBB',image.id,1,1))
        if offset == 0:
            header = image.ctrl + bytes(4)  # mode=0, padding=0
            await self.request(b'\x01'+encrypt_packet(header,caps))
        await self.send(b'\x02'+struct.pack('<HI',image.id,offset))
        LOG.info('Truyền %d byte; bắt đầu tại %d.',len(image.wire),offset)
        packet_size = 16 if block_size else 20
        last_progress = -1
        while offset < len(image.wire):
            end = min(offset+(block_size or packet_size),len(image.wire))
            # Mã hóa cả buffer một lần như SDK (mode 0: chỉ 16 byte đầu buffer; mode 1: mọi block 16 byte),
            # rồi mới cắt thành gói ghi. CRC buffer cũng tính trên dữ liệu ĐÃ mã hóa (BaseDfuTask.a + s/h.java).
            block = encrypt_packet(image.wire[offset:end],caps)
            for attempt in range(3):
                for i in range(0,len(block),packet_size):
                    await asyncio.wait_for(self.ready.wait(),self.timeout)
                    await self.client.write_gatt_char(DATA,block[i:i+packet_size],response=False)
                    await asyncio.sleep(delay)
                if not block_size:
                    break
                rsp = await self.request(b'\x0a'+struct.pack('<HH',len(block),buffer_crc(block)),statuses=(1,5,6))
                if len(rsp) < 5:
                    raise DfuError('Đáp buffer CRC quá ngắn.')
                target = struct.unpack_from('<I',rsp,1)[0]
                if rsp[0] == 1:
                    if target != end:
                        raise DfuError(f'Offset ACK {target} khác dự kiến {end}; dừng truyền.')
                    break
                if attempt == 2:
                    raise DfuError('Buffer CRC lỗi sau 3 lần gửi.')
                if target != offset:
                    raise DfuError('Offset retry không khớp; dừng để tránh gửi sai vị trí.')
                await self.send(b'\x02'+struct.pack('<HI',image.id,offset))
                LOG.warning('Gửi lại buffer tại %d.',offset)
            offset = end
            progress = offset*100//len(image.wire)
            if progress != last_progress:
                LOG.info('Tiến độ %d%% (%d/%d)',progress,offset,len(image.wire))
                last_progress = progress
        await self.request(b'\x03'+struct.pack('<HB',image.id,1),timeout=30)
        LOG.info('Thiết bị xác thực image thành công.')
        if activate:
            await self.send(b'\x04')
            LOG.info('Đã gửi kích hoạt/khởi động lại. Cần kết nối lại để xác nhận phiên bản.')
        else:
            LOG.info('Chưa kích hoạt (--no-activate).')

async def read_device(client):
    result = {'address':client.address, 'characteristics':[]}
    for service in client.services:
        for char in service.characteristics:
            result['characteristics'].append({'uuid':char.uuid,'properties':char.properties})
    for name, uuid in [('protocol',PROTOCOL),('info',INFO),('battery',BATTERY)]:
        if client.services.get_characteristic(uuid):
            result[name] = bytes(await client.read_gatt_char(uuid)).hex()
    if 'protocol' in result and 'info' in result:
        p = bytes.fromhex(result['protocol'])
        if len(p) < 2:
            raise DfuError('Protocol characteristic quá ngắn.')
        result['capabilities'] = capabilities(bytes.fromhex(result['info']),int.from_bytes(p[:2],'little'))
    return result

async def bluetooth(args, image=None):
    from bleak import BleakClient, BleakScanner
    if args.command == 'scan':
        devices = await BleakScanner.discover(timeout=args.timeout,return_adv=True)
        for device, adv in devices.values():
            print(json.dumps({'address':device.address,'name':adv.local_name or device.name,'rssi':adv.rssi},ensure_ascii=False))
        return
    async with BleakClient(args.address,timeout=args.timeout) as client:
        result = await read_device(client)
        print(json.dumps(result,indent=2,ensure_ascii=False))
        if args.command == 'probe':
            return
        caps = result.get('capabilities')
        if caps is None:
            raise DfuError('Thiếu FFF1/FFF3; không thể chọn giao thức.')
        for uuid in (CONTROL,DATA):
            if not client.services.get_characteristic(uuid):
                raise DfuError('Thiếu dịch vụ DFU silent; không tự chuyển sang normal mode.')
        battery_hex = result.get('battery')
        battery = int(battery_hex[:2],16) if battery_hex else None
        if battery is None:
            if args.battery is None:
                raise DfuError('Không đọc được pin. Dùng --battery N theo mức pin trên đồng hồ.')
            battery = args.battery
        if not 50 <= battery <= 100:
            raise DfuError('Yêu cầu pin ít nhất 50%.')
        dfu = Dfu(client,args.timeout)
        await client.start_notify(CONTROL,dfu.notification)
        await dfu.upload(image,caps,args.delay,not args.no_activate)


def main(argv=None):
    parser = argparse.ArgumentParser(description='Realtek firmware OTA — thử nghiệm, protocol 0x10 silent mode.')
    parser.add_argument('--log',help='Lưu log giao thức (không ghi payload firmware).')
    sub = parser.add_subparsers(dest='command',required=True)
    sub.add_parser('scan').add_argument('--timeout',type=float,default=10)
    for name in ('inspect','plan'):
        sub.add_parser(name).add_argument('firmware',type=Path)
    for name in ('probe','flash'):
        p = sub.add_parser(name)
        p.add_argument('address',help='Địa chỉ BLE; macOS dùng UUID từ lệnh scan.')
        p.add_argument('--timeout',type=float,default=15)
        if name == 'flash':
            p.add_argument('firmware',type=Path)
            p.add_argument('--battery',type=int,help='Mức pin đọc trên đồng hồ nếu không có BLE Battery Service.')
            p.add_argument('--delay',type=float,default=0.01,help='Khoảng nghỉ giữa gói (giây, mặc định 0.01).')
            p.add_argument('--no-activate',action='store_true')
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.INFO,format='%(asctime)s %(levelname)s %(message)s')
    if args.log:
        handler = logging.FileHandler(args.log,encoding='utf-8')
        handler.setLevel(logging.DEBUG)
        handler.setFormatter(logging.Formatter('%(asctime)s %(levelname)s %(message)s'))
        LOG.addHandler(handler)
        LOG.setLevel(logging.DEBUG)
        # Console remains concise; detailed protocol goes to the file.
        for h in logging.getLogger().handlers:
            h.setLevel(logging.INFO)
    try:
        image = Image(args.firmware.read_bytes()) if hasattr(args,'firmware') else None
        if image:
            print(json.dumps(image.summary(),indent=2,ensure_ascii=False))
        if args.command == 'inspect':
            return 0
        if args.command == 'plan':
            print(json.dumps({'mode':'silent','stream_bytes':len(image.wire),
                'check_key_command':(b'\x12\x01'+struct.pack('<H',image.id)+image.key_hash).hex(),
                'start_dfu_before_transport_encryption':(b'\x01'+image.ctrl+bytes(4)).hex(),
                'sequence':['read capabilities','check key if spec>=6','enable buffer if supported','target offset','report count if supported','start if offset=0','receive','stream','validate','activate'],
                'note':'Không kết nối Bluetooth. AES/buffer/resume phụ thuộc thiết bị.'},indent=2,ensure_ascii=False))
            return 0
        if args.timeout <= 0 or (hasattr(args,'delay') and args.delay < 0):
            raise DfuError('Timeout phải dương; delay không được âm.')
        asyncio.run(bluetooth(args,image))
        return 0
    except KeyboardInterrupt:
        LOG.warning('Đã dừng. Không gửi kích hoạt hoặc tự thử lại.')
        return 130
    except (DfuError, OSError, ImportError, asyncio.TimeoutError) as exc:
        LOG.error('%s',exc)
        return 1
    except Exception as exc:
        LOG.error('Bluetooth/DFU thất bại: %s',exc)
        LOG.debug('Chi tiết lỗi',exc_info=True)
        return 1

if __name__ == '__main__':
    sys.exit(main())
