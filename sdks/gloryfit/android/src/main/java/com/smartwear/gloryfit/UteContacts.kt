package com.smartwear.gloryfit

/**
 * Danh bạ trên đồng hồ (bản Kotlin của `UteContacts.swift`; SDK Realtek trong GloryFitPro: `syncContactsToDevice`), kênh 34F1:
 * - `37 FA n` → đồng hồ trả `37 FA n`
 * - các gói `37 FB k` + k bản ghi `37 FB lenSố lenTên số(ASCII) tên(UTF-16BE)`, đệm 0 tới độ dài gói tối đa → `37 FB k`
 * - `37 FC FD` kết thúc → `37 FC FD`.
 * F6 `0x80000` (Y25/HT43): tên tối đa 20 ký tự (bản ghi 59 byte), tối đa 70 liên hệ; không thì 10 ký tự (39 byte), 100.
 * Số tối đa 15 ký tự. Kiểm chứng trên Y25 15/10/2026.
 */
object UteContacts {
    data class Contact(val name: String, val phone: String)

    /** `isHasContact` (33F1 b6.5 = F5 `0x2000`). */
    fun supported(f: Ute.Features) = f.has(5, 0x002000)
    fun longNames(f: Ute.Features) = f.has(6, 0x080000)
    fun maxContacts(f: Ute.Features) = if (longNames(f)) 70 else 100

    /** `isHasContactDel` (34F1 b18.2 = F8 `0x000400`): xoá hết danh bạ bằng [CLEAR]. */
    fun clearSupported(f: Ute.Features) = supported(f) && f.has(8, 0x000400)

    /** `37 BA` lên 34F1 (`T:1158-1161` `deleteAllContacts`); đồng hồ trả `37 BA` (`uterkfinal.java:365-368`, trạng thái 4 = đã xoá). */
    val CLEAR = byteArrayOf(0x37, 0xBA.toByte())

    /** Số chỉ giữ chữ số, `+`, `*`, `#`. */
    fun cleanPhone(s: String) = s.filter { it.isDigit() || it in "+*#" }.take(15)

    private fun record(c: Contact, maxName: Int): ByteArray {
        val phone = cleanPhone(c.phone).toByteArray(Charsets.US_ASCII)
        // Cắt theo ký tự (code point) như bản iOS, rồi mã hoá UTF-16BE.
        val cps = c.name.codePoints().toArray().take(maxName)
        val name = String(cps.toIntArray(), 0, cps.size).toByteArray(Charsets.UTF_16BE)
        return byteArrayOf(0x37, 0xFB.toByte(), phone.size.toByte(), name.size.toByte()) + phone + name
    }

    /** Các gói `37 FB` (chưa gồm `37 FA` và `37 FC FD`). */
    fun segments(contacts: List<Contact>, f: Ute.Features, packetLength: Int): List<ByteArray> {
        val recSize = if (longNames(f)) 59 else 39
        val perPacket = maxOf(1, (packetLength - 3) / recSize)
        return contacts.take(maxContacts(f)).chunked(perPacket).map { chunk ->
            var p = byteArrayOf(0x37, 0xFB.toByte(), chunk.size.toByte())
            for (c in chunk) p += record(c, if (longNames(f)) 20 else 10)
            p + ByteArray(maxOf(0, packetLength - p.size))
        }
    }

    /** Kênh gọi điện Bluetooth cổ điển (`DeviceBt3StateInfo`). */
    data class CallBluetoothState(val name: String, val address: String, val enabled: Boolean, val paired: Boolean, val connected: Boolean)

    /** `38 01 tên(20) MAC(6) bật ghép kết-nối`. */
    fun parseCallBluetooth(p: ByteArray): CallBluetoothState? {
        if (p.size < 31 || Ute.u(p, 0) != 0x38 || Ute.u(p, 1) != 0x01) return null
        val nameBytes = p.copyOfRange(2, 22).takeWhile { it != 0.toByte() }.toByteArray()
        val mac = (22 until 28).joinToString(":") { "%02X".format(Ute.u(p, it)) }
        return CallBluetoothState(nameBytes.decodeToString(), mac, Ute.u(p, 28) == 1, Ute.u(p, 29) == 1, Ute.u(p, 30) == 1)
    }
}
