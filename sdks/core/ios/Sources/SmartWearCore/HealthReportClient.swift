import Foundation

/// Cấu hình máy chủ LLM (OpenAI-compatible) do bên gọi tiêm vào. KHÔNG đóng khoá vào mã nguồn hay gói app:
/// app đọc từ file `KEY=VALUE` (`LLM_API_BASE`, `LLM_MODEL`, `LLM_API_KEY`) mà nhà phát triển tự đẩy vào máy.
public struct HealthLLMConfig: Sendable, Equatable, CustomStringConvertible {
    /// Gốc API, vd `https://llm.minhtrithanh.net/v1` (yêu cầu gửi tới `{base}/chat/completions`).
    public var baseURL: URL
    public var model: String
    public var apiKey: String

    public init(baseURL: URL, model: String, apiKey: String) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
    }

    /// Đọc nội dung file env: bỏ dòng trống / `#`, bỏ `export `, bỏ nháy quanh giá trị. Thiếu base hoặc khoá thì nil;
    /// thiếu model thì dùng `Qwen/Qwen3.6-35B-A3B-FP8`.
    public static func parse(env text: String) -> HealthLLMConfig? {
        var kv: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line.removeFirst(7) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            var v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if v.count >= 2, let f = v.first, f == "\"" || f == "'", v.last == f { v = String(v.dropFirst().dropLast()) }
            kv[line[..<eq].trimmingCharacters(in: .whitespaces)] = v
        }
        guard let base = kv["LLM_API_BASE"].flatMap({ URL(string: $0.hasSuffix("/") ? String($0.dropLast()) : $0) }),
              let key = kv["LLM_API_KEY"], !key.isEmpty else { return nil }
        let model = kv["LLM_MODEL"].flatMap { $0.isEmpty ? nil : $0 } ?? "Qwen/Qwen3.6-35B-A3B-FP8"
        return HealthLLMConfig(baseURL: base, model: model, apiKey: key)
    }

    /// Đọc file env; không có file hoặc thiếu khoá thì nil.
    public static func load(_ url: URL) -> HealthLLMConfig? {
        (try? String(contentsOf: url, encoding: .utf8)).flatMap(parse(env:))
    }

    /// Không bao giờ in khoá.
    public var description: String { "HealthLLMConfig(base: \(baseURL.absoluteString), model: \(model), key: ***)" }
}

/// Lỗi gọi LLM, thông điệp tiếng Việt để hiện thẳng cho người dùng (không chứa khoá).
public enum HealthReportError: LocalizedError, Equatable, Sendable {
    case notConfigured
    case unauthorized
    case blocked
    case restarting
    case busy
    case timeout
    case offline
    case http(Int)
    case network(String)
    case emptyResponse

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "Chưa cấu hình máy chủ AI"
        case .unauthorized: return "Khoá máy chủ AI sai hoặc đã hết hạn"
        case .blocked: return "Cloudflare chặn yêu cầu tới máy chủ AI (User-Agent)"
        case .restarting: return "Máy chủ AI đang khởi động lại, thử lại sau vài phút"
        case .busy: return "Máy chủ AI đang bận, thử lại sau ít phút"
        case .timeout: return "Máy chủ AI phản hồi quá lâu, thử lại sau"
        case .offline: return "Không có kết nối mạng"
        case .http(let code): return "Máy chủ AI lỗi (HTTP \(code))"
        case .network(let m): return "Không gọi được máy chủ AI: \(m)"
        case .emptyResponse: return "Máy chủ AI không trả nội dung"
        }
    }

    /// Mã HTTP → lỗi. `body` để nhận ra Cloudflare 1010 (chặn User-Agent).
    public static func from(status: Int, body: String) -> HealthReportError {
        switch status {
        case 401: return .unauthorized
        case 403: return body.contains("1010") ? .blocked : .unauthorized
        case 429: return .busy
        case 502, 503: return .restarting
        case 504, 522, 524: return .timeout
        default: return .http(status)
        }
    }
}

/// Gọi LLM viết báo cáo sức khoẻ: `POST {base}/chat/completions`, khoá ở `X-API-Key`, User-Agent kiểu trình duyệt
/// (Cloudflare chặn UA lạ bằng 403/1010), hết giờ sau `timeout` (Cloudflare tự cắt ở ~100 s).
public struct HealthReportClient: Sendable {
    public static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 SmartWearLab/0.1"

    public let config: HealthLLMConfig
    public var timeout: TimeInterval
    public var session: URLSession

    public init(config: HealthLLMConfig, timeout: TimeInterval = 90, session: URLSession = .shared) {
        self.config = config
        self.timeout = timeout
        self.session = session
    }

    public func urlRequest(body: Data) -> URLRequest {
        var r = URLRequest(url: config.baseURL.appendingPathComponent("chat/completions"), timeoutInterval: timeout)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(config.apiKey, forHTTPHeaderField: "X-API-Key")
        r.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        r.httpBody = body
        return r
    }

    /// Gửi thân yêu cầu, trả chữ trả lời của model.
    public func complete(_ body: Data) async throws -> String {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest(body: body))
        } catch let e as URLError {
            switch e.code {
            case .timedOut: throw HealthReportError.timeout
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                throw HealthReportError.offline
            default: throw HealthReportError.network(e.localizedDescription)
            }
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw HealthReportError.from(status: status, body: String(decoding: data.prefix(300), as: UTF8.self))
        }
        guard let text = HealthReportPrompt.content(fromResponse: data), !text.isEmpty else { throw HealthReportError.emptyResponse }
        return text
    }

    /// Cả luồng: dựng prompt từ số liệu + phát hiện, gọi LLM, đọc báo cáo.
    public func report(summary: HealthSummary, findings: [HealthFinding]) async throws -> HealthReport {
        let body = HealthReportPrompt.requestBody(model: config.model, summary: summary, findings: findings)
        let text = try await complete(body)
        return HealthReportPrompt.parse(text, findings: findings, period: summary.period, now: summary.generatedAt)
    }
}
