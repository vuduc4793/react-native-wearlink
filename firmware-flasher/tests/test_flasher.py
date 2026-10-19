import asyncio
from pathlib import Path
import struct
import unittest
from unittest.mock import patch
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from flasher import Image, Dfu, DfuError, capabilities, crc_arc, buffer_crc, encrypt_packet

FIRMWARE = Path(__file__).resolve().parents[2]/'sdks/gloryfit/research/firmware/RB370L73AC_V001205.bin'

class ImageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.raw = FIRMWARE.read_bytes()
    def test_real_signed_image(self):
        image = Image(self.raw)
        self.assertEqual(image.key_hash.hex(),'985b8ac4')
        self.assertEqual(image.wire,self.raw[512:])
        self.assertEqual(image.summary()['sha256'],'7d477c2d76f3f4040cf3f0b08f68bb5734efbbc889a2a057eff2b3472eb83e55')
    def test_tampered_payload(self):
        raw = bytearray(self.raw); raw[0x700] ^= 1
        with self.assertRaisesRegex(DfuError,'CRC16'): Image(raw)
    def test_tampered_signature(self):
        raw = bytearray(self.raw); raw[0x210] ^= 1
        with self.assertRaisesRegex(DfuError,'ECDSA'): Image(raw)
    def test_truncated(self):
        with self.assertRaises(DfuError): Image(self.raw[:-1])
    def test_key_hash_mismatch(self):
        raw = bytearray(self.raw); raw[0x62] ^= 1
        with self.assertRaisesRegex(DfuError,'Hash'): Image(raw)
    def test_crc_vectors(self):
        self.assertEqual(crc_arc(b'123456789'),0xbb3d)
        self.assertEqual(buffer_crc(bytes([1,2,3,4])),0x0206)
    def test_capabilities(self):
        caps = capabilities(bytes([17,6,0x87,0,64,1,0,1,0,0]),16)
        self.assertTrue(caps['aes']); self.assertTrue(caps['buffer'])
        self.assertTrue(caps['report']); self.assertEqual(caps['aes_mode'],1)
        with self.assertRaises(DfuError): capabilities(bytes(10),17)
        with self.assertRaises(DfuError): capabilities(bytes(2),16)
    def test_encryption_tail_and_modes(self):
        data = bytes(range(37))
        first = encrypt_packet(data,dict(aes=True,aes_mode=0))
        all_blocks = encrypt_packet(data,dict(aes=True,aes_mode=1))
        self.assertEqual(first[16:],data[16:])
        self.assertEqual(first[:16],all_blocks[:16])
        self.assertNotEqual(all_blocks[16:32],data[16:32])
        self.assertEqual(all_blocks[32:],data[32:])

class FakeImage:
    id=0x2793; ic=17; ctrl=bytes(12); key_hash=b'abcd'; wire=bytes(range(100))

class FakeServices:
    def get_characteristic(self,uuid):
        return type('Char',(),{'properties':['write']})()

class FakeClient:
    def __init__(self,reject=None,offset=0,retry=False):
        self.services=FakeServices(); self.commands=[]; self.stream=bytearray()
        self.reject=reject; self.offset=offset; self.retry=retry; self.received=bytearray()
    async def write_gatt_char(self,uuid,data,response=False):
        from flasher import CONTROL
        if uuid != CONTROL:
            self.stream.extend(data); self.received.extend(data); return
        self.commands.append(data)
        op=data[0]; status=2 if op==self.reject else 1
        body=bytes([status])
        if op==6: body+=bytes(4)+struct.pack('<I',self.offset)
        if op==9: body+=struct.pack('<H',32)
        if op==2:
            self.offset=struct.unpack_from('<I',data,3)[0]; self.stream.clear()
            return
        if op==10:
            size,crc=struct.unpack_from('<HH',data,1)
            assert size==len(self.stream) and crc==buffer_crc(self.stream)
            if self.retry:
                self.retry=False; status=5
            else:
                self.offset+=len(self.stream)
            body=bytes([status])+struct.pack('<I',self.offset); self.stream.clear()
        if op in (4,19): return
        self.dfu.notification(None,b'\x10'+bytes([op])+body)

class ProtocolTests(unittest.IsolatedAsyncioTestCase):
    def caps(self,buffer=False):
        return dict(ic=17,spec=6,buffer=buffer,aes=False,aes_mode=0,rws=False,report=True)
    async def run_upload(self,client,buffer=False,activate=True):
        client.dfu=Dfu(client,timeout=.1)
        await client.dfu.upload(FakeImage(),self.caps(buffer),delay=0,activate=activate)
    async def test_full_plain_flow(self):
        c=FakeClient(); await self.run_upload(c)
        self.assertEqual(c.received,FakeImage.wire)
        self.assertEqual([x[0] for x in c.commands],[18,6,19,1,2,3,4])
    async def test_resume(self):
        c=FakeClient(offset=40); await self.run_upload(c)
        self.assertEqual(c.received,FakeImage.wire[40:])
        self.assertNotIn(1,[x[0] for x in c.commands])
    async def test_buffer_flow(self):
        c=FakeClient(); await self.run_upload(c,buffer=True)
        self.assertEqual(c.received,FakeImage.wire)
        self.assertEqual([x[0] for x in c.commands].count(10),4)
    async def test_buffer_flow_aes(self):
        # SDK mã hóa cả buffer một lần rồi mới cắt gói; CRC tính trên dữ liệu đã mã hóa.
        for mode in (0,1):
            c=FakeClient(); c.dfu=Dfu(c,timeout=.1)
            caps=dict(ic=17,spec=6,buffer=True,aes=True,aes_mode=mode,rws=False,report=True)
            await c.dfu.upload(FakeImage(),caps,delay=0,activate=True)
            expect=bytearray(); off=0
            while off<len(FakeImage.wire):
                end=min(off+32,len(FakeImage.wire))
                expect+=encrypt_packet(FakeImage.wire[off:end],caps); off=end
            self.assertEqual(bytes(c.received),bytes(expect))
    async def test_crc_retry(self):
        c=FakeClient(retry=True); await self.run_upload(c,buffer=True)
        self.assertEqual([x[0] for x in c.commands].count(10),5)
    async def test_key_rejection_never_writes_data(self):
        c=FakeClient(reject=18)
        with self.assertRaises(DfuError): await self.run_upload(c)
        self.assertEqual(c.received,b''); self.assertEqual(len(c.commands),1)
    async def test_validation_rejection_never_activates(self):
        c=FakeClient(reject=3)
        with self.assertRaises(DfuError): await self.run_upload(c)
        self.assertNotIn(4,[x[0] for x in c.commands])
    async def test_no_activate(self):
        c=FakeClient(); await self.run_upload(c,activate=False)
        self.assertNotIn(4,[x[0] for x in c.commands])
    async def test_invalid_resume(self):
        c=FakeClient(offset=9999)
        with self.assertRaises(DfuError): await self.run_upload(c)
        self.assertEqual(c.received,b'')
    async def test_timeout(self):
        c=FakeClient(); d=Dfu(c,timeout=.01)
        with patch.object(c,'write_gatt_char',new=unittest.mock.AsyncMock()):
            with self.assertRaisesRegex(DfuError,'thời gian'): await d.request(b'\x06')
    async def test_busy_notification(self):
        d=Dfu(FakeClient()); d.notification(None,b'\x10\x08\x01')
        self.assertFalse(d.ready.is_set())
        d.notification(None,b'\x10\x08\x00'); self.assertTrue(d.ready.is_set())

if __name__=='__main__': unittest.main()
