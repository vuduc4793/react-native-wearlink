package com.smartwear.gloryfit.ota

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * Protocol 0x0014 (gói `p/` của SDK Realtek), dữ liệu đọc thật từ Y25 RB370L73ACV001205 (MAC 78:02:B7:03:6E:1B) bằng `otaProbe`.
 * Đặc tả và dẫn chứng file:dòng: sdks/gloryfit/docs/07-ota-realtek.md §8.2.
 */
class RealtekDfuX0014Test {

    private fun hex(s: String): ByteArray = s.replace(" ", "").chunked(2).map { it.toInt(16).toByte() }.toByteArray()
    private fun ByteArray.h() = joinToString("") { "%02x".format(it) }

    // ---------- Giá trị đọc thật hôm nay ----------

    private val fff3 = hex("14 00")
    private val fff1 = hex("11 02 1d 00 ad 01 00 f7 00 01 00 00 00")
    private val ffd2 = hex("78 02 b7 03 6e 1b 78 02 b7 03 6e 1b")
    private val ffe0 = hex(
        "00 0b 8f 27 00 70 0e 00 90 27 01 00 00 00 93 27 40 10 a0 96 94 27 1e 01 00 01 95 27 1e 01 00 01 96 27 00 00 00 00 " +
            "97 27 11 3d 68 00 98 27 00 00 00 00 9c 27 00 f0 0e 00 9d 27 00 f0 02 00 fe ff 00 00 00 00",
    )
    private val ffe1 = ByteArray(0)
    private val fff4 = hex(
        "0a 90 27 01 00 00 00 93 27 00 b0 1a 00 94 27 00 00 02 00 95 27 00 20 03 00 96 27 00 20 00 00 97 27 00 50 00 00 " +
            "98 27 00 20 03 00 9c 27 00 a0 01 00 9d 27 00 c0 02 00 fe ff 00 c0 96 00",
    )
    private val fff5 = ByteArray(0)

    private fun realCaps() = DfuCapabilities.parse(fff1, RealtekDfuSpec.u16(fff3, 0))
    private fun realVersions() = DfuImageVersions.parseX0014(listOf(ffe0, ffe1), listOf(fff4, fff5), realCaps().longImageVersion)

    @Test fun decodeFff1() {
        assertEquals(0x0014, RealtekDfuSpec.u16(fff3, 0))
        val c = realCaps()
        assertEquals(RealtekDfuSpec.PROTOCOL_X0014, c.protocol)
        assertEquals(0x11, c.ic)
        assertEquals(2, c.spec)
        // cờ 0x1D = 0001 1101
        assertTrue(c.buffer)               // b0
        assertFalse(c.aes)                 // b1
        assertEquals(1, c.aesMode)         // b2 (không dùng vì AES tắt)
        assertEquals(1, c.updateImageFlag) // b3
        assertTrue(c.leNormalMode)         // b4
        assertFalse(c.nandFlash)           // b5
        assertFalse(c.compression)         // b6
        assertFalse(c.longImageVersion)    // b7
        assertEquals(0, c.rwsMode); assertFalse(c.rws)
        assertEquals(0x01AD * 4096L, c.tempBufferBytes) // 429 × 4 KB = 1 757 184
        assertEquals(1716, c.tempKb)
        assertEquals(0, c.bank)            // bank normal: không
        assertEquals(247, c.mtu)
        assertEquals(1, c.bootBank)        // boot: active bank 0, update bank 1
        assertEquals(3, c.updateMechanism) // all-in-one qua temp buffer
        assertTrue(c.report)
        assertFalse(c.copy)
    }

    @Test fun decodeFfd2() {
        // parseDeviceMacV2: 6 byte MAC + 6 byte địa chỉ "RWS"; ở đây hai lần cùng MAC, đúng thứ tự hiển thị.
        assertEquals("78:02:B7:03:6E:1B", ffd2.copyOfRange(0, 6).joinToString(":") { "%02X".format(it) })
        assertArrayEquals(ffd2.copyOfRange(0, 6), ffd2.copyOfRange(6, 12))
    }

    @Test fun decodeImageVersionsAndSections() {
        val v = realVersions()
        assertEquals(
            linkedMapOf(
                0x278F to 0x000E7000L, 0x2790 to 0x01000000L, 0x2793 to 0x96A01040L, 0x2794 to 0x0100011EL, 0x2795 to 0x0100011EL,
                0x2796 to 0L, 0x2797 to 0x00683D11L, 0x2798 to 0L, 0x279C to 0x000EF000L, 0x279D to 0x0002F000L, 0xFFFE to 0L,
            ),
            v.active,
        )
        assertTrue(v.inactive.isEmpty())
        assertEquals(
            linkedMapOf(
                0x2790 to 1L, 0x2793 to 0x1AB000L, 0x2794 to 0x20000L, 0x2795 to 0x32000L, 0x2796 to 0x2000L, 0x2797 to 0x5000L,
                0x2798 to 0x32000L, 0x279C to 0x1A000L, 0x279D to 0x2C000L, 0xFFFE to 0x96C000L,
            ),
            v.sectionSizes,
        )
        assertEquals(1_748_992L, v.sectionSizes[0x2793])
    }

    @Test fun inactiveAndLongVersions() {
        val v = DfuImageVersions.parseX0014(listOf(hex("01 01 93 27 01 02 03 04")), emptyList(), longVersion = false)
        assertTrue(v.active.isEmpty())
        assertEquals(0x04030201L, v.inactive[0x2793])
        val l = DfuImageVersions.parseX0014(listOf(hex("00 01 93 27 01 02 03 04 05 06 07 08")), emptyList(), longVersion = true)
        assertEquals(0x0807060504030201L, l.active[0x2793])
    }

    @Test fun capabilityRejections() {
        expectDfuError { DfuCapabilities.parse(fff1, 0x15) }
        expectDfuError { DfuCapabilities.parse(fff1.copyOf(9), 0x14) }
        expectDfuError { DfuCapabilities.parse(fff1.copyOf().also { it[1] = 0 }, 0x14) } // spec 0
        expectDfuError { DfuCapabilities.parse(fff1.copyOf().also { it[1] = 4 }, 0x14) } // spec 4: START_DFU có byte nén
        // FFF1 0x0014 KHÔNG được hiểu theo 0x0010 (spec 2 ⇒ bị từ chối ở đó).
        expectDfuError { DfuCapabilities.parse(fff1, 0x10) }
    }

    @Test fun bufferCheckPacketSize() {
        assertEquals(240, RealtekDfuSpec.bufferCheckPacketSize(247))
        assertEquals(240, RealtekDfuSpec.bufferCheckPacketSize(256))
        assertEquals(512, RealtekDfuSpec.bufferCheckPacketSize(517))
        assertEquals(16, RealtekDfuSpec.bufferCheckPacketSize(23))
        assertEquals(16, RealtekDfuSpec.bufferCheckPacketSize(19))
        assertEquals(16, RealtekDfuSpec.bufferCheckPacketSize(null))
    }

    // ---------- Kiểm trước (image thật + giá trị thật) ----------

    @Test fun realImageIsValidForThisDevice() {
        val image = DfuImage.from(RealtekImage.load(Y25Firmware.bytes()))
        assertEquals(0x96A01040L, image.version)
        val pre = RealtekDfu.preflightX0014(image, realCaps(), realVersions())
        assertEquals(0x96A01040L, pre.deviceVersion)
        assertEquals(0x96A01040L, pre.fileVersion)
        assertTrue(pre.sameVersion)                              // cùng phiên bản đang chạy: nạp lại
        assertEquals(1_748_992L, pre.sectionSize)
        assertTrue(image.wire.size <= pre.sectionSize!!)         // 1 683 316 ≤ 1 748 992
        assertTrue(image.wire.size <= realCaps().tempBufferBytes) // ≤ 1 757 184
    }

    @Test fun preflightRejections() {
        val img = DfuImage(0x2793, 0x11, ByteArray(12), ByteArray(4), ByteArray(2000), version = 1)
        val v = DfuImageVersions(mapOf(0x2793 to 1L), emptyMap(), mapOf(0x2793 to 1000L))
        expectDfuError { RealtekDfu.preflightX0014(img, realCaps(), v) } // vượt section
        val big = DfuImage(0x2793, 0x11, ByteArray(12), ByteArray(4), ByteArray(4096 * 430), version = 1)
        expectDfuError { RealtekDfu.preflightX0014(big, realCaps(), DfuImageVersions.EMPTY) } // vượt temp buffer
        val small = DfuImage(0x2793, 0x11, ByteArray(12), ByteArray(4), ByteArray(100), version = 2)
        expectDfuError { RealtekDfu.preflightX0014(small, realCaps().copy(nandFlash = true), v) }
        expectDfuError { RealtekDfu.preflightX0014(small, realCaps().copy(ic = 0x12), v) }
        expectDfuError { RealtekDfu.preflightX0014(small, realCaps().copy(protocol = 0x10), v) }
        // Khác phiên bản (cao hơn hay thấp hơn) không bị chặn, chỉ báo.
        val other = RealtekDfu.preflightX0014(small, realCaps(), v)
        assertFalse(other.sameVersion)
        // Thiếu FFE0/FFF4: không chặn (SDK cũng bỏ qua), không biết phiên bản.
        val none = RealtekDfu.preflightX0014(small, realCaps(), DfuImageVersions.EMPTY)
        assertNull(none.deviceVersion); assertFalse(none.sameVersion)
    }

    // ---------- Thiết bị giả protocol 0x0014 ----------

    /** Trả lời đồng bộ trong lúc ghi control, theo đáp của `p/d` (`m/h`, `t/d`, `0x0A`). */
    private class FakeX0014(
        val bufferSize: Int = 256,
        val reportedOffset: Int = 0,
        val infoLength: Int = 7,
        val reject: Int? = null,
        val answerReport: Boolean = false,
        var retry: Boolean = false,
    ) : DfuLink {
        lateinit var dfu: RealtekDfu
        val commands = mutableListOf<ByteArray>()
        val packets = mutableListOf<Int>()
        val received = java.io.ByteArrayOutputStream()
        private val buffer = java.io.ByteArrayOutputStream()
        private var offset = -1
        var onData: (() -> Unit)? = null

        override suspend fun writeData(value: ByteArray) {
            check(offset >= 0) { "dữ liệu trước 0x02" }
            packets += value.size
            buffer.write(value); received.write(value)
            onData?.invoke()
        }

        override suspend fun writeControl(value: ByteArray) {
            commands += value.copyOf()
            val op = value[0].toInt() and 0xFF
            var status = if (op == reject) 2 else 1
            val body: ByteArray? = when (op) {
                0x09 -> byteArrayOf(status.toByte()) + RealtekDfuSpec.le16(bufferSize)
                0x06 -> when (infoLength) {
                    7 -> byteArrayOf(status.toByte()) + RealtekDfuSpec.le16(0x1040) + RealtekDfuSpec.le32(reportedOffset)
                    11 -> byteArrayOf(status.toByte()) + RealtekDfuSpec.le32(0x96A01040.toInt()) + RealtekDfuSpec.le32(reportedOffset) + RealtekDfuSpec.le16(0)
                    else -> byteArrayOf(status.toByte()) + ByteArray(infoLength - 1)
                }
                0x12 -> if (answerReport) byteArrayOf(1) else null
                0x01 -> byteArrayOf(status.toByte())
                0x02 -> {
                    offset = RealtekDfuSpec.u32(value, 3); buffer.reset(); null
                }
                0x0A -> {
                    val data = buffer.toByteArray()
                    check(RealtekDfuSpec.u16(value, 1) == data.size && RealtekDfuSpec.u16(value, 3) == RealtekDfuSpec.bufferCrc(data))
                    if (retry) {
                        retry = false; status = 5
                    } else {
                        offset += data.size
                    }
                    buffer.reset()
                    byteArrayOf(status.toByte()) + RealtekDfuSpec.le32(offset)
                }
                0x03 -> byteArrayOf(status.toByte())
                0x04 -> null
                else -> error("opcode lạ 0x%02x".format(op))
            }
            body?.let { dfu.onControlNotification(byteArrayOf(0x10, op.toByte()) + it) }
        }

        fun hexCommands() = commands.map { c -> c.joinToString("") { "%02x".format(it) } }
        fun ops() = commands.map { it[0].toInt() and 0xFF }
    }

    private val fakeImage = DfuImage(id = 0x2793, ic = 0x11, ctrl = ByteArray(12) { (0xA0 + it).toByte() }, keyHash = ByteArray(4), wire = ByteArray(100) { it.toByte() })

    private suspend fun flash(link: FakeX0014, caps: DfuCapabilities = realCaps(), image: DfuImage = fakeImage, activate: Boolean = true, mtu: Int? = 247): Boolean {
        val dfu = RealtekDfu(link, timeoutMs = 200).also { link.dfu = it }
        return dfu.upload(image, caps, packetDelayMs = 0, activate = activate, mtu = mtu)
    }

    /** Toàn bộ chuỗi với image Y25 thật, caps thật, MTU 247: đúng byte SDK sẽ gửi. */
    @Test fun fullFlowRealImageExactBytes() = runBlocking {
        val image = DfuImage.from(RealtekImage.load(Y25Firmware.bytes()))
        val c = FakeX0014()
        val progress = mutableListOf<Int>()
        val dfu = RealtekDfu(c, timeoutMs = 1_000).also { c.dfu = it }
        assertTrue(dfu.upload(image, realCaps(), packetDelayMs = 0, mtu = 247) { sent, _ -> progress += sent })
        val cmds = c.hexCommands()
        assertEquals("09", cmds[0])                                   // ENABLE_BUFFER_CHECK
        assertEquals("069327", cmds[1])                               // REPORT_TARGET_IMAGE_INFO 0x2793
        assertEquals("1293270101", cmds[2])                           // ReportImageNumber (opcode 0x12 ở protocol 20), 1/1
        assertEquals("017bca11000101932774ab190000000000", cmds[3])   // START_DFU: ctrl 12 B + 4 byte 0, không AES
        assertEquals("02932700000000", cmds[4])                       // RECEIVE_FW_IMAGE id 0x2793 offset 0
        assertEquals("0a0001ee5b", cmds[5])                           // CRC khối 256 B đầu = 0x5BEE
        val crcs = cmds.count { it.startsWith("0a") }
        assertEquals((image.wire.size + 255) / 256, crcs)             // 6576 khối
        assertEquals("0a7400", cmds[cmds.size - 3].substring(0, 6))   // khối cuối 116 B
        assertEquals("03932701", cmds[cmds.size - 2])                 // VALIDATE, flag 1
        assertEquals("0400", cmds.last())                             // ACTIVE_IMAGE_RESET protocol 20 = 04 00
        assertEquals(5 + crcs + 2, cmds.size)
        assertArrayEquals(image.wire, c.received.toByteArray())
        assertEquals(listOf(240, 16, 240, 16), c.packets.take(4))     // khối 256 = gói 240 + 16
        assertEquals(116, c.packets.last())
        assertTrue(c.packets.all { it <= 240 })
        assertEquals(0, progress.first()); assertEquals(image.wire.size, progress.last())
    }

    @Test fun noPublicKeyCommandInX0014() = runBlocking {
        // 0x12 ở protocol 20 là ReportImageNumber 5 byte, không phải CHECK_PUB_KEYS `12 01 id hash`.
        val c = FakeX0014()
        flash(c)
        val twelve = c.commands.filter { it[0].toInt() == 0x12 }
        assertEquals(1, twelve.size)
        assertEquals("1293270101", twelve.single().h())
        // Có đồng hồ trả lời 0x12 cũng không sao (phản hồi bị bỏ qua).
        val c2 = FakeX0014(answerReport = true)
        assertTrue(flash(c2))
        assertArrayEquals(fakeImage.wire, c2.received.toByteArray())
    }

    @Test fun plainFlow() = runBlocking {
        val c = FakeX0014()
        assertTrue(flash(c, caps = realCaps().copy(buffer = false)))
        assertEquals(listOf("069327", "1293270101", "01a0a1a2a3a4a5a6a7a8a9aaab00000000", "02932700000000", "03932701", "0400"), c.hexCommands())
        assertEquals(List(5) { 20 }, c.packets)
        assertArrayEquals(fakeImage.wire, c.received.toByteArray())
    }

    @Test fun bufferFlowSmallBlockAndNoMtu() = runBlocking {
        val c = FakeX0014(bufferSize = 32)
        flash(c, mtu = null)
        assertArrayEquals(fakeImage.wire, c.received.toByteArray())
        assertEquals(4, c.ops().count { it == 0x0A })
        assertTrue(c.packets.all { it <= 16 }) // chưa đổi MTU ⇒ gói 16 B
    }

    @Test fun crcRetry() = runBlocking {
        val c = FakeX0014(bufferSize = 32, retry = true)
        flash(c)
        assertEquals(5, c.ops().count { it == 0x0A })
        assertArrayEquals(fakeImage.wire.copyOfRange(0, 32) + fakeImage.wire, c.received.toByteArray())
    }

    @Test fun resumeOffsetIsIgnoredLikeSdk() = runBlocking {
        for (len in listOf(7, 11)) {
            val c = FakeX0014(reportedOffset = 48, infoLength = len)
            flash(c)
            assertTrue(0x01 in c.ops())
            assertEquals("02932700000000", c.hexCommands().first { it.startsWith("02") })
            assertArrayEquals(fakeImage.wire, c.received.toByteArray())
        }
    }

    @Test fun unknownTargetInfoLengthStopsBeforeStart() = runBlocking {
        val c = FakeX0014(infoLength = 9)
        expectDfuError { flash(c) }
        assertEquals(listOf(0x09, 0x06), c.ops())
        assertEquals(0, c.received.size())
    }

    @Test fun bufferCheckRejectedStopsEarly() = runBlocking {
        val c = FakeX0014(reject = 0x09)
        expectDfuError { flash(c) }
        assertEquals(listOf(0x09), c.ops())
        val c2 = FakeX0014(bufferSize = 100) // không chia hết 16
        expectDfuError { flash(c2) }
        assertEquals(0, c2.received.size())
    }

    @Test fun startRejectedNeverWritesData() = runBlocking {
        val c = FakeX0014(reject = 0x01)
        expectDfuError { flash(c) }
        assertEquals(0, c.received.size())
        assertFalse(0x02 in c.ops())
    }

    @Test fun validationRejectionNeverActivates() = runBlocking {
        val c = FakeX0014(reject = 0x03)
        expectDfuError { flash(c) }
        assertFalse(0x04 in c.ops())
    }

    @Test fun noActivate() = runBlocking {
        val c = FakeX0014()
        assertFalse(flash(c, activate = false))
        assertFalse(0x04 in c.ops())
        assertTrue(0x03 in c.ops())
    }

    @Test fun refusedBeforeAnyCommand() = runBlocking {
        for (caps in listOf(
            realCaps().copy(ic = 0x12), realCaps().copy(rws = true), realCaps().copy(spec = 4), realCaps().copy(nandFlash = true),
            realCaps().copy(protocol = 0x15),
        )) {
            val c = FakeX0014()
            expectDfuError { flash(c, caps = caps) }
            assertTrue(c.commands.isEmpty())
        }
    }

    @Test fun cancelMidTransferNeverValidatesOrActivates() = runBlocking {
        val c = FakeX0014(bufferSize = 32)
        val started = CompletableDeferred<Unit>()
        c.onData = { started.complete(Unit) }
        val dfu = RealtekDfu(c, timeoutMs = 1_000).also { c.dfu = it }
        val job = async { dfu.upload(fakeImage, realCaps(), packetDelayMs = 50, mtu = 247) }
        started.await()
        job.cancel()
        runCatching { job.await() }
        assertFalse(0x03 in c.ops()); assertFalse(0x04 in c.ops())
        assertTrue(c.received.size() < fakeImage.wire.size)
    }

    /** Cùng phiên bản: chuỗi lệnh y hệt (giao thức 20 không có bước so phiên bản nào trên dây). */
    @Test fun sameVersionUsesIdenticalSequence() = runBlocking {
        val same = DfuImage(0x2793, 0x11, fakeImage.ctrl, ByteArray(4), fakeImage.wire, version = 0x96A01040L)
        val newer = DfuImage(0x2793, 0x11, fakeImage.ctrl, ByteArray(4), fakeImage.wire, version = 0x96A01041L)
        assertTrue(RealtekDfu.preflightX0014(same, realCaps(), realVersions()).sameVersion)
        assertFalse(RealtekDfu.preflightX0014(newer, realCaps(), realVersions()).sameVersion)
        val a = FakeX0014().also { flash(it, image = same) }
        val b = FakeX0014().also { flash(it, image = newer) }
        assertEquals(a.hexCommands(), b.hexCommands())
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
