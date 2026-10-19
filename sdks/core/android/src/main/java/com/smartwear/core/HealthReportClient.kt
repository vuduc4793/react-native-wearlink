package com.smartwear.core

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
import java.net.ConnectException
import java.net.HttpURLConnection
import java.net.SocketTimeoutException
import java.net.URL
import java.net.UnknownHostException

/**
 * Cấu hình máy chủ LLM (OpenAI-compatible) do bên gọi tiêm vào. KHÔNG đóng khoá vào mã nguồn hay gói app:
 * app đọc từ file `KEY=VALUE` (`LLM_API_BASE`, `LLM_MODEL`, `LLM_API_KEY`) mà nhà phát triển tự đẩy vào máy.
 * [baseUrl] vd `https://llm.minhtrithanh.net/v1` (yêu cầu gửi tới `{base}/chat/completions`).
 */
data class HealthLLMConfig(val baseUrl: String, val model: String, val apiKey: String) {
    /** Không bao giờ in khoá. */
    override fun toString() = "HealthLLMConfig(base=$baseUrl, model=$model, key=***)"

    companion object {
        /**
         * Đọc nội dung file env: bỏ dòng trống / `#`, bỏ `export `, bỏ nháy quanh giá trị. Thiếu base hoặc khoá thì null;
         * thiếu model thì dùng `Qwen/Qwen3.6-35B-A3B-FP8`.
         */
        fun parseEnv(text: String): HealthLLMConfig? {
            val kv = mutableMapOf<String, String>()
            for (raw in text.lines()) {
                var line = raw.trim()
                if (line.isEmpty() || line.startsWith("#")) continue
                if (line.startsWith("export ")) line = line.removePrefix("export ")
                val eq = line.indexOf('=')
                if (eq < 0) continue
                var v = line.substring(eq + 1).trim()
                if (v.length >= 2 && (v[0] == '"' || v[0] == '\'') && v.last() == v[0]) v = v.substring(1, v.length - 1)
                kv[line.substring(0, eq).trim()] = v
            }
            val base = kv["LLM_API_BASE"]?.trimEnd('/')?.takeIf { it.isNotEmpty() } ?: return null
            val key = kv["LLM_API_KEY"]?.takeIf { it.isNotEmpty() } ?: return null
            return HealthLLMConfig(base, kv["LLM_MODEL"]?.takeIf { it.isNotEmpty() } ?: "Qwen/Qwen3.6-35B-A3B-FP8", key)
        }

        /** Đọc file env; không có file hoặc thiếu khoá thì null. */
        fun load(file: File): HealthLLMConfig? = runCatching { file.readText() }.getOrNull()?.let(::parseEnv)
    }
}

/** Lỗi gọi LLM, thông điệp tiếng Việt để hiện thẳng cho người dùng (không chứa khoá). */
sealed class HealthReportError(message: String) : IOException(message) {
    object NotConfigured : HealthReportError("Chưa cấu hình máy chủ AI")
    object Unauthorized : HealthReportError("Khoá máy chủ AI sai hoặc đã hết hạn")
    object Blocked : HealthReportError("Cloudflare chặn yêu cầu tới máy chủ AI (User-Agent)")
    object Restarting : HealthReportError("Máy chủ AI đang khởi động lại, thử lại sau vài phút")
    object Busy : HealthReportError("Máy chủ AI đang bận, thử lại sau ít phút")
    object Timeout : HealthReportError("Máy chủ AI phản hồi quá lâu, thử lại sau")
    object Offline : HealthReportError("Không có kết nối mạng")
    object EmptyResponse : HealthReportError("Máy chủ AI không trả nội dung")
    class Http(val code: Int) : HealthReportError("Máy chủ AI lỗi (HTTP $code)")
    class Network(detail: String) : HealthReportError("Không gọi được máy chủ AI: $detail")

    companion object {
        /** Mã HTTP → lỗi. [body] để nhận ra Cloudflare 1010 (chặn User-Agent). */
        fun from(status: Int, body: String): HealthReportError = when (status) {
            401 -> Unauthorized
            403 -> if (body.contains("1010")) Blocked else Unauthorized
            429 -> Busy
            502, 503 -> Restarting
            504, 522, 524 -> Timeout
            else -> Http(status)
        }
    }
}

/**
 * Gọi LLM viết báo cáo sức khoẻ: `POST {base}/chat/completions`, khoá ở `X-API-Key`, User-Agent kiểu trình duyệt
 * (Cloudflare chặn UA lạ bằng 403/1010), hết giờ sau [timeoutMs] (Cloudflare tự cắt ở ~100 s).
 */
class HealthReportClient(val config: HealthLLMConfig, private val timeoutMs: Int = 90_000) {
    companion object {
        const val USER_AGENT =
            "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Mobile Safari/537.36 SmartWearLab/0.1"
    }

    /** Gửi thân yêu cầu, trả chữ trả lời của model. */
    suspend fun complete(body: String): String = withContext(Dispatchers.IO) {
        val conn = try {
            (URL("${config.baseUrl}/chat/completions").openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                connectTimeout = 15_000
                readTimeout = timeoutMs
                doOutput = true
                setRequestProperty("Content-Type", "application/json")
                setRequestProperty("X-API-Key", config.apiKey)
                setRequestProperty("User-Agent", USER_AGENT)
            }
        } catch (e: IOException) {
            throw HealthReportError.Network(e.message ?: e.javaClass.simpleName)
        }
        try {
            conn.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            val status = conn.responseCode
            if (status != 200) {
                val err = runCatching { conn.errorStream?.bufferedReader()?.use { it.readText() } }.getOrNull().orEmpty()
                throw HealthReportError.from(status, err.take(300))
            }
            val text = conn.inputStream.bufferedReader(Charsets.UTF_8).use { it.readText() }
            HealthReportPrompt.contentFromResponse(text)?.takeIf { it.isNotEmpty() } ?: throw HealthReportError.EmptyResponse
        } catch (e: HealthReportError) {
            throw e
        } catch (e: SocketTimeoutException) {
            throw HealthReportError.Timeout
        } catch (e: UnknownHostException) {
            throw HealthReportError.Offline
        } catch (e: ConnectException) {
            throw HealthReportError.Offline
        } catch (e: IOException) {
            throw HealthReportError.Network(e.message ?: e.javaClass.simpleName)
        } finally {
            conn.disconnect()
        }
    }

    /** Cả luồng: dựng prompt từ số liệu + phát hiện, gọi LLM, đọc báo cáo. */
    suspend fun report(summary: HealthSummary, findings: List<HealthFinding>): HealthReport {
        val text = complete(HealthReportPrompt.requestBody(config.model, summary, findings))
        return HealthReportPrompt.parse(text, findings, summary.period, summary.generatedAt)
    }
}
