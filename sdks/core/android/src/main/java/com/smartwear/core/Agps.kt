package com.smartwear.core

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow

/** Thiết bị có GPS hỏi điện thoại về AGPS (dữ liệu hỗ trợ bắt vệ tinh). */
enum class AgpsRequestType {
    /** Hỏi điện thoại đã có file dữ liệu vệ tinh chưa. Đồng hồ hết dữ liệu thì hỏi định kỳ (HT43: mỗi 60 s). */
    STATUS,
    /** Thiết bị sẵn sàng nhận file (sau khi điện thoại báo đã có file). */
    DOWNLOAD,
    /** Thiết bị xin vị trí điện thoại. */
    POSITION,
}

/** Một lần thiết bị hỏi AGPS. [handled] = driver đã tự trả lời bằng file / vị trí app đặt sẵn. */
data class AgpsRequest(val type: AgpsRequestType, val handled: Boolean)

/**
 * Thông tin AGPS thiết bị báo. [files] = tên file dữ liệu vệ tinh thiết bị cần (gửi đúng tên này); [version] = mã nền tảng GNSS;
 * [interval] = giá trị chu kỳ thiết bị báo (đơn vị chưa rõ); [ephemerisValid] = thiết bị còn dữ liệu vệ tinh hợp lệ, null = không hỏi được.
 */
data class AgpsInfo(val files: List<String>, val version: Int?, val interval: Int?, val ephemerisValid: Boolean?)

/** Một file dữ liệu vệ tinh. [name] lấy từ [AgpsInfo.files]. Nội dung do app tự lấy từ nguồn được phép, SDK chỉ chuyển. */
class AgpsFile(val name: String, val data: ByteArray)

/**
 * AGPS cho thiết bị có GPS riêng. SDK không gọi mạng: app tự lấy file dữ liệu vệ tinh rồi gửi qua [uploadAgpsFiles] (hoặc đặt sẵn
 * bằng [setAgpsFiles] để driver tự gửi khi thiết bị xin). Không có file, vị trí điện thoại ([sendAgpsPosition]) vẫn giúp bắt vệ
 * tinh nhanh hơn.
 */
interface AgpsSupport {
    val supportsAgps: Boolean get() = false

    /** Thiết bị hỏi AGPS. Driver tự trả lời khi có thể ([AgpsRequest.handled]); app nghe để tự lấy file khi cần. */
    val agpsRequests: Flow<AgpsRequest> get() = emptyFlow()

    /** Thông tin AGPS của thiết bị (tên file cần, phiên bản, dữ liệu còn hợp lệ không). */
    suspend fun agpsInfo(): AgpsInfo = throw UnsupportedOperationException("Thiết bị không hỗ trợ AGPS")

    /**
     * Vị trí điện thoại (WGS-84) lúc [timestampMs]. Gửi ngay nếu đang kết nối; driver giữ lại để tự gửi khi thiết bị hỏi
     * (vị trí cũ hơn vài giờ thì bỏ).
     */
    suspend fun sendAgpsPosition(latitude: Double, longitude: Double, timestampMs: Long = System.currentTimeMillis()): Unit =
        throw UnsupportedOperationException("Thiết bị không hỗ trợ AGPS")

    /** Gửi [files] lên thiết bị (một lần truyền gồm mọi file). [progress] 0–1. Lỗi nếu thiết bị từ chối. */
    suspend fun uploadAgpsFiles(files: List<AgpsFile>, progress: (Float) -> Unit = {}): Unit =
        throw UnsupportedOperationException("Thiết bị không hỗ trợ AGPS")

    /** Đặt sẵn [files] (chỉ trong bộ nhớ) để driver tự trả lời "đã có file" và tự gửi khi thiết bị xin; null = bỏ. */
    fun setAgpsFiles(files: List<AgpsFile>?) {}
}
