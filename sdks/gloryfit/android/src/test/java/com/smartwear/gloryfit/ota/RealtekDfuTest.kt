package com.smartwear.gloryfit.ota

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * Bản Kotlin của `firmware-flasher/tests/test_flasher.py`. Vector AES/CRC/lệnh lấy bằng cách chạy chính flasher.py
 * (`.venv/bin/python -I`, cryptography 50.0.2) trên `RB370L73AC_V001205.bin`.
 */
class RealtekDfuTest {

    private fun hex(s: String): ByteArray = s.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
    private fun ByteArray.h() = joinToString("") { "%02x".format(it) }

    private fun reason(raw: ByteArray): RealtekImageException.Reason? =
        try {
            RealtekImage.load(raw)
            null
        } catch (e: RealtekImageException) {
            e.reason
        }

    // ---------- Image (ImageTests) ----------

    @Test fun realSignedImage() {
        val raw = Y25Firmware.bytes()
        val image = RealtekImage.load(raw)
        assertEquals("985B8AC4", image.pubKeyHash.joinToString("") { "%02X".format(it) })
        assertArrayEquals(raw.copyOfRange(512, raw.size), image.wire)
        assertEquals(Y25Firmware.SHA256, image.fileSha256)
        val dfu = DfuImage.from(image)
        assertEquals(0x2793, dfu.id)
        assertEquals(0x11, dfu.ic)
        assertEquals("7bca11000101932774ab1900", dfu.ctrl.h())
        assertEquals(1_683_316, dfu.wire.size)
    }

    @Test fun tamperedPayload() {
        val raw = Y25Firmware.bytes(); raw[0x700] = (raw[0x700].toInt() xor 1).toByte()
        assertEquals(RealtekImageException.Reason.CRC, reason(raw))
    }

    @Test fun tamperedLastByte() {
        val raw = Y25Firmware.bytes(); raw[raw.size - 1] = (raw[raw.size - 1] + 1).toByte()
        assertEquals(RealtekImageException.Reason.CRC, reason(raw))
    }

    @Test fun tamperedSignature() {
        val raw = Y25Firmware.bytes(); raw[0x210] = (raw[0x210].toInt() xor 1).toByte()
        assertEquals(RealtekImageException.Reason.SIGNATURE, reason(raw))
    }

    @Test fun tamperedShaField() {
        val raw = Y25Firmware.bytes(); raw[0x31F] = (raw[0x31F].toInt() xor 1).toByte()
        assertEquals(RealtekImageException.Reason.SHA, reason(raw))
    }

    @Test fun truncated() {
        val raw = Y25Firmware.bytes()
        assertEquals(RealtekImageException.Reason.LENGTH, reason(raw.copyOf(raw.size - 1)))
        assertEquals(RealtekImageException.Reason.FORMAT, reason(raw.copyOf(0x5FF)))
    }

    @Test fun keyHashMismatch() {
        val raw = Y25Firmware.bytes(); raw[0x62] = (raw[0x62].toInt() xor 1).toByte()
        assertEquals(RealtekImageException.Reason.KEY_HASH, reason(raw))
    }

    @Test fun wrongImageIdOrChip() {
        val raw = Y25Firmware.bytes(); raw[0x332] = 0x12 // ic_type
        assertEquals(RealtekImageException.Reason.CHIP, reason(raw))
        val raw2 = Y25Firmware.bytes(); raw2[0x336] = 0x94.toByte() // image id 0x2794
        assertEquals(RealtekImageException.Reason.CHIP, reason(raw2))
    }

    @Test fun everySingleByteFlipInSignedRangeIsRejected() {
        // Mẫu vài vị trí trong vùng được ký/băm (0x310 → hết) và trong MP header được kiểm.
        val base = Y25Firmware.bytes()
        for (pos in listOf(0x32, 0x3D, 0x42, 0x310, 0x330, 0x338, 0x360, 0x3A0, 0x600, 0x10000, base.size / 2, base.size - 2)) {
            val raw = base.copyOf(); raw[pos] = (raw[pos].toInt() xor 0x40).toByte()
            assertNotEquals("byte 0x%X".format(pos), null, reason(raw))
        }
    }

    @Test fun crcVectors() {
        val b = "123456789".toByteArray()
        assertEquals(0xBB3D, RealtekImage.crc16Arc(b, 0, b.size))
        assertEquals(0x0206, RealtekDfuSpec.bufferCrc(byteArrayOf(1, 2, 3, 4)))
        assertEquals(0x0202, RealtekDfuSpec.bufferCrc(ByteArray(37) { it.toByte() })) // byte lẻ cuối bị bỏ, như Python
    }

    @Test fun crcVectorsOnRealImage() {
        val wire = RealtekImage.load(Y25Firmware.bytes()).wire.copyOfRange(0, 256)
        assertEquals(0x5BEE, RealtekDfuSpec.bufferCrc(wire))
        assertEquals(0xE5FC, RealtekDfuSpec.bufferCrc(RealtekDfuSpec.encryptPacket(wire, aes = true, aesMode = 1)))
    }

    @Test fun capabilities() {
        val caps = DfuCapabilities.parse(byteArrayOf(17, 6, 0x87.toByte(), 0, 64, 1, 0, 1, 0, 0), 16)
        assertTrue(caps.aes); assertTrue(caps.buffer); assertTrue(caps.report)
        assertEquals(1, caps.aesMode); assertEquals(17, caps.ic); assertEquals(6, caps.spec); assertEquals(256, caps.mtu)
        assertFalse(caps.rws)
        expectDfuError { DfuCapabilities.parse(ByteArray(10), 17) }
        expectDfuError { DfuCapabilities.parse(ByteArray(2), 16) }
        expectDfuError { DfuCapabilities.parse(byteArrayOf(17, 3, 0, 0, 0, 0, 0, 0, 0, 0), 16) } // spec 3
    }

    // ---------- AES: vector cố định từ flasher.py ----------

    @Test fun encryptionTailAndModes() {
        val data = ByteArray(37) { it.toByte() }
        val first = RealtekDfuSpec.encryptPacket(data, aes = true, aesMode = 0)
        val all = RealtekDfuSpec.encryptPacket(data, aes = true, aesMode = 1)
        assertArrayEquals(data.copyOfRange(16, 37), first.copyOfRange(16, 37))
        assertArrayEquals(first.copyOfRange(0, 16), all.copyOfRange(0, 16))
        assertFalse(all.copyOfRange(16, 32).contentEquals(data.copyOfRange(16, 32)))
        assertArrayEquals(data.copyOfRange(32, 37), all.copyOfRange(32, 37))
        assertArrayEquals(data, RealtekDfuSpec.encryptPacket(data, aes = false, aesMode = 1))
    }

    @Test fun encryptionMatchesPython() {
        val data = ByteArray(37) { it.toByte() }
        assertEquals("96c7032c2ae01d70d857935b0a2d73e9101112131415161718191a1b1c1d1e1f2021222324",
            RealtekDfuSpec.encryptPacket(data, aes = true, aesMode = 0).h())
        assertEquals("96c7032c2ae01d70d857935b0a2d73e9989c3ca1583e030b4286b126e23d187c2021222324",
            RealtekDfuSpec.encryptPacket(data, aes = true, aesMode = 1).h())
        val ff = ByteArray(48) { 0xFF.toByte() }
        assertEquals("0ac8b7a58ba6132322f17c0e9f90d823" + "ff".repeat(32), RealtekDfuSpec.encryptPacket(ff, aes = true, aesMode = 0).h())
        assertEquals("0ac8b7a58ba6132322f17c0e9f90d823".repeat(3), RealtekDfuSpec.encryptPacket(ff, aes = true, aesMode = 1).h())
    }

    @Test fun encryptionOfRealImageMatchesPython() {
        val image = RealtekImage.load(Y25Firmware.bytes())
        val wire = image.wire.copyOfRange(0, 256)
        val mode0 = RealtekDfuSpec.encryptPacket(wire, aes = true, aesMode = 0).h()
        assertTrue(mode0.startsWith("0ac8b7a58ba6132322f17c0e9f90d8237cf5a340d9a923448461749026b3260e"))
        assertEquals(wire.copyOfRange(16, 256).h(), mode0.substring(32))
        val mode1 = RealtekDfuSpec.encryptPacket(wire, aes = true, aesMode = 1).h()
        assertEquals(
            "0ac8b7a58ba6132322f17c0e9f90d82313ba9d514133074219ff17b9eb186cdf79d1f252012a9f3aa712a688c5f51182a0466c9cd35c68beb5bee96edcda48f3" +
                "f3af5fd9313ab344b20e8ac01d99510b" + "6ba293620e0b71f92fc1bb955bc8f506".repeat(11),
            mode1,
        )
        // START_DFU: [01] + AES(ctrl header 12 B + 4 byte 0); vector `plan` của flasher.py.
        val header = DfuImage.from(image).ctrl + ByteArray(4)
        assertEquals("017bca11000101932774ab190000000000", (byteArrayOf(1) + header).h())
        assertEquals("015d898067da8c6598f8b63eb7b6adbec2", (byteArrayOf(1) + RealtekDfuSpec.encryptPacket(header, aes = true, aesMode = 0)).h())
        assertEquals("015d898067da8c6598f8b63eb7b6adbec2", (byteArrayOf(1) + RealtekDfuSpec.encryptPacket(header, aes = true, aesMode = 1)).h())
    }

    @Test fun checkKeyCommandMatchesPython() = runBlocking {
        val image = DfuImage.from(RealtekImage.load(Y25Firmware.bytes()))
        val link = FakeLink(reject = 0x12)
        val dfu = RealtekDfu(link, timeoutMs = 100).also { link.dfu = it }
        expectDfuError { dfu.upload(image, caps(), packetDelayMs = 0) }
        assertEquals("12019327985b8ac4", link.commands.single().h())
        assertEquals(0, link.received.size())
    }

    // ---------- Giao thức với thiết bị giả (ProtocolTests) ----------

    private val fakeImage = DfuImage(id = 0x2793, ic = 17, ctrl = ByteArray(12), keyHash = "abcd".toByteArray(), wire = ByteArray(100) { it.toByte() })

    private fun caps(buffer: Boolean = false, aes: Boolean = false, aesMode: Int = 0) =
        DfuCapabilities(ic = 17, spec = 6, buffer = buffer, aes = aes, aesMode = aesMode, copy = false, report = true,
            bank = 0, tempKb = 0, mtu = 0, rws = false, compression = false)

    /** Như `FakeClient` của test Python: trả lời đồng bộ ngay trong lúc ghi control. */
    private class FakeLink(val reject: Int? = null, var offset: Int = 0, var retry: Boolean = false) : DfuLink {
        lateinit var dfu: RealtekDfu
        val commands = mutableListOf<ByteArray>()
        val stream = java.io.ByteArrayOutputStream()
        val received = java.io.ByteArrayOutputStream()
        var onData: (() -> Unit)? = null

        override suspend fun writeData(value: ByteArray) {
            stream.write(value); received.write(value)
            onData?.invoke()
        }

        override suspend fun writeControl(value: ByteArray) {
            commands += value
            val op = value[0].toInt() and 0xFF
            var status = if (op == reject) 2 else 1
            var body = byteArrayOf(status.toByte())
            when (op) {
                6 -> body += ByteArray(4) + RealtekDfuSpec.le32(offset)
                9 -> body += RealtekDfuSpec.le16(32)
                2 -> {
                    offset = RealtekDfuSpec.u32(value, 3); stream.reset(); return
                }
                10 -> {
                    val size = RealtekDfuSpec.u16(value, 1)
                    val crc = RealtekDfuSpec.u16(value, 3)
                    val data = stream.toByteArray()
                    check(size == data.size && crc == RealtekDfuSpec.bufferCrc(data))
                    if (retry) {
                        retry = false; status = 5
                    } else {
                        offset += data.size
                    }
                    body = byteArrayOf(status.toByte()) + RealtekDfuSpec.le32(offset); stream.reset()
                }
            }
            if (op == 4 || op == 19) return
            dfu.onControlNotification(byteArrayOf(0x10, op.toByte()) + body)
        }

        fun ops() = commands.map { it[0].toInt() and 0xFF }
    }

    private suspend fun runUpload(link: FakeLink, buffer: Boolean = false, activate: Boolean = true, aes: Boolean = false, aesMode: Int = 0): Boolean {
        val dfu = RealtekDfu(link, timeoutMs = 100).also { link.dfu = it }
        return dfu.upload(fakeImage, caps(buffer, aes, aesMode), packetDelayMs = 0, activate = activate)
    }

    @Test fun fullPlainFlow() = runBlocking {
        val c = FakeLink()
        val progress = mutableListOf<Int>()
        val dfu = RealtekDfu(c, timeoutMs = 100).also { c.dfu = it }
        assertTrue(dfu.upload(fakeImage, caps(), packetDelayMs = 0) { sent, _ -> progress += sent })
        assertArrayEquals(fakeImage.wire, c.received.toByteArray())
        assertEquals(listOf(18, 6, 19, 1, 2, 3, 4), c.ops())
        assertEquals(0, progress.first()); assertEquals(100, progress.last())
    }

    @Test fun resume() = runBlocking {
        val c = FakeLink(offset = 40)
        runUpload(c)
        assertArrayEquals(fakeImage.wire.copyOfRange(40, 100), c.received.toByteArray())
        assertFalse(1 in c.ops())
    }

    @Test fun bufferFlow() = runBlocking {
        val c = FakeLink()
        runUpload(c, buffer = true)
        assertArrayEquals(fakeImage.wire, c.received.toByteArray())
        assertEquals(4, c.ops().count { it == 10 })
    }

    @Test fun bufferFlowAes() = runBlocking {
        // SDK mã hoá cả buffer một lần rồi mới cắt gói; CRC tính trên dữ liệu đã mã hoá.
        for (mode in 0..1) {
            val c = FakeLink()
            runUpload(c, buffer = true, aes = true, aesMode = mode)
            val expect = java.io.ByteArrayOutputStream()
            var off = 0
            while (off < fakeImage.wire.size) {
                val end = minOf(off + 32, fakeImage.wire.size)
                expect.write(RealtekDfuSpec.encryptPacket(fakeImage.wire.copyOfRange(off, end), aes = true, aesMode = mode)); off = end
            }
            assertArrayEquals(expect.toByteArray(), c.received.toByteArray())
            // START_DFU cũng được mã hoá.
            val start = c.commands.first { it[0].toInt() == 1 }
            assertArrayEquals(byteArrayOf(1) + RealtekDfuSpec.encryptPacket(ByteArray(16), aes = true, aesMode = mode), start)
        }
    }

    @Test fun crcRetry() = runBlocking {
        val c = FakeLink(retry = true)
        runUpload(c, buffer = true)
        assertEquals(5, c.ops().count { it == 10 })
        // Khối đầu (32 B) bị báo CRC sai và được gửi lại đúng vị trí.
        assertArrayEquals(fakeImage.wire.copyOfRange(0, 32) + fakeImage.wire, c.received.toByteArray())
    }

    @Test fun keyRejectionNeverWritesData() = runBlocking {
        val c = FakeLink(reject = 18)
        expectDfuError { runUpload(c) }
        assertEquals(0, c.received.size()); assertEquals(1, c.commands.size)
    }

    @Test fun validationRejectionNeverActivates() = runBlocking {
        val c = FakeLink(reject = 3)
        expectDfuError { runUpload(c) }
        assertFalse(4 in c.ops())
    }

    @Test fun noActivate() = runBlocking {
        val c = FakeLink()
        assertFalse(runUpload(c, activate = false))
        assertFalse(4 in c.ops())
        assertTrue(3 in c.ops())
    }

    @Test fun invalidResume() = runBlocking {
        val c = FakeLink(offset = 9999)
        expectDfuError { runUpload(c) }
        assertEquals(0, c.received.size())
        val c2 = FakeLink(offset = 5) // 0 < offset < 12
        expectDfuError { runUpload(c2) }
        assertEquals(0, c2.received.size())
    }

    @Test fun chipMismatchSendsNothing() = runBlocking {
        val c = FakeLink()
        val dfu = RealtekDfu(c, timeoutMs = 100).also { c.dfu = it }
        expectDfuError { dfu.upload(fakeImage, caps().copy(ic = 0x12), packetDelayMs = 0) }
        expectDfuError { dfu.upload(fakeImage, caps().copy(rws = true), packetDelayMs = 0) }
        assertTrue(c.commands.isEmpty())
    }

    @Test fun cancelMidTransferNeverActivates() = runBlocking {
        val c = FakeLink()
        val started = CompletableDeferred<Unit>()
        c.onData = { started.complete(Unit) }
        val dfu = RealtekDfu(c, timeoutMs = 1_000).also { c.dfu = it }
        val job = async { dfu.upload(fakeImage, caps(), packetDelayMs = 50) }
        started.await()
        job.cancel()
        runCatching { job.await() }
        assertFalse(3 in c.ops()); assertFalse(4 in c.ops())
        assertTrue(c.received.size() < fakeImage.wire.size)
    }

    @Test fun disconnectFailsPendingRequestImmediately() = runBlocking {
        val silent = object : DfuLink {
            override suspend fun writeControl(value: ByteArray) {}
            override suspend fun writeData(value: ByteArray) {}
        }
        val dfu = RealtekDfu(silent, timeoutMs = 10_000)
        val t0 = System.currentTimeMillis()
        val pending = async { runCatching { dfu.request(byteArrayOf(6)) } }
        kotlinx.coroutines.delay(50)
        dfu.fail(DfuException("status=8"))
        val error = pending.await().exceptionOrNull()
        assertTrue(error is DfuException)
        assertTrue(System.currentTimeMillis() - t0 < 5_000)
    }

    @Test fun timeout() = runBlocking {
        val silent = object : DfuLink {
            override suspend fun writeControl(value: ByteArray) {}
            override suspend fun writeData(value: ByteArray) {}
        }
        val dfu = RealtekDfu(silent, timeoutMs = 50)
        val e = runCatching { dfu.request(byteArrayOf(6)) }.exceptionOrNull()
        assertTrue(e is DfuException && e.message!!.contains("Hết thời gian"))
    }

    @Test fun busyNotification() {
        val dfu = RealtekDfu(FakeLink())
        dfu.onControlNotification(hex("100801"))
        assertTrue(dfu.busy)
        dfu.onControlNotification(hex("100800"))
        assertFalse(dfu.busy)
    }

    private inline fun expectDfuError(block: () -> Unit) {
        try {
            block()
            fail("chờ DfuException")
        } catch (e: DfuException) {
            // đúng
        }
    }
}
