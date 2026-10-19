package com.smartwear.qring.protocol

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ProtocolTest {

    private fun hex(s: String) = s.split(" ").map { it.toInt(16).toByte() }.toByteArray()

    @Test
    fun setTimeExampleFromDocs() {
        // sdks/qring/docs/01-connection.md §4.2: 2025-01-15 10:30:45, tiếng Anh
        val p = Packet.of(0x01, 0x25, 0x01, 0x15, 0x10, 0x30, 0x45, 0x01)
        assertArrayEquals(hex("01 25 01 15 10 30 45 01 00 00 00 00 00 00 00 C2"), p.bytes)
    }

    @Test
    fun batteryRequestAndResponse() {
        assertArrayEquals(hex("03 00 00 00 00 00 00 00 00 00 00 00 00 00 00 03"), Packet.of(0x03).bytes)
        val rsp = Packet.parse(hex("03 55 00 00 00 00 00 00 00 00 00 00 00 00 00 58"))!!
        assertEquals(3, rsp.command)
        assertEquals(85, rsp.u8(0))
    }

    @Test
    fun parseRejectsBadChecksumAndLength() {
        assertNull(Packet.parse(hex("03 55 00 00 00 00 00 00 00 00 00 00 00 00 00 59")))
        assertNull(Packet.parse(hex("03 55")))
    }

    @Test
    fun errorFlag() {
        val p = Packet.parse(Packet.of(0x83).bytes)!!
        assertTrue(p.isError)
        assertEquals(3, p.command)
    }

    @Test
    fun crc16ModbusCheckValue() {
        assertEquals(0x4B37, BigDataFrame.crc16Modbus("123456789".toByteArray()))
    }

    @Test
    fun bigDataExamplesFromDocs() {
        assertArrayEquals(hex("BC 2C 01 00 7E 80 01"), BigDataFrame(0x2C, hex("01")).encode())
        assertArrayEquals(hex("BC 27 02 00 C0 70 00 01"), BigDataFrame(0x27, hex("00 01")).encode())
        assertArrayEquals(hex("BC 01 00 00 FF FF"), BigDataFrame(0x01, ByteArray(0)).encode())
    }

    @Test
    fun assemblerJoinsChunks() {
        val payload = ByteArray(50) { it.toByte() }
        val frames = mutableListOf<BigDataFrame>()
        val assembler = BigDataAssembler { frames += it }
        BigDataFrame(0x27, payload).chunks(20).forEach(assembler::feed)
        assertEquals(1, frames.size)
        assertEquals(0x27, frames[0].command)
        assertArrayEquals(payload, frames[0].payload)
    }
}
