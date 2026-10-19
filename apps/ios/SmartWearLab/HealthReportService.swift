import Foundation
import Observation
import SmartWearCore

/// "Báo cáo AI": đồng bộ lịch sử nếu đã cũ → tổng hợp + luật (`HealthSummary`, `HealthFindings` trong SmartWearCore) →
/// LLM của runpod-ai chỉ viết chữ → lưu báo cáo cuối của từng thiết bị (Application Support/SmartWear/reports).
/// Cấu hình máy chủ AI đọc từ `Documents/llm.env` (nhà phát triển đẩy vào bằng `devicectl device copy to`), KHÔNG đóng
/// trong gói app; đọc lại mỗi lần chạy nên đẩy file mới không cần mở lại app.
@MainActor
@Observable
final class HealthReportService {
    enum Phase: Equatable { case syncing, thinking }

    /// Báo cáo đã lưu kèm phát hiện và thời gian từng bước.
    struct Entry: Codable, Equatable {
        var report: HealthReport
        var findings: [HealthFinding]
        var syncSeconds: Double
        var llmSeconds: Double
    }

    enum FlowError: LocalizedError {
        case busy, noHistory
        var errorDescription: String? {
            switch self {
            case .busy: return "Đang tạo báo cáo cho thiết bị này"
            case .noHistory: return "Chưa có dữ liệu lịch sử: kết nối thiết bị rồi đồng bộ trước"
            }
        }
    }

    /// Lịch sử cũ hơn mốc này thì đồng bộ lại trước khi viết báo cáo.
    static let staleAfter: TimeInterval = 15 * 60

    private(set) var phase: [UUID: Phase] = [:]
    private(set) var errors: [UUID: String] = [:]
    private(set) var entries: [UUID: Entry] = [:]
    private(set) var configured = false

    @ObservationIgnored private let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("SmartWear/reports", isDirectory: true)
    }()

    static var configURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("llm.env")
    }

    init() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "json" {
            if let id = UUID(uuidString: f.deletingPathExtension().lastPathComponent),
               let data = try? Data(contentsOf: f), let e = try? JSONDecoder().decode(Entry.self, from: data) {
                entries[id] = e
            }
        }
        refreshConfig()
    }

    func refreshConfig() {
        configured = HealthLLMConfig.load(Self.configURL) != nil
    }

    /// Hồ sơ người dùng lấy từ cài đặt thiết bị (`profile.*`, `goal.steps`); giới tính: lựa chọn 0 = Nam.
    static func profile(_ d: WearableDevice) -> HealthProfile {
        func num(_ id: String) -> Int? {
            if case .number(let v)? = d.controls.first(where: { $0.id == id })?.value { return v }
            return nil
        }
        return HealthProfile(
            age: num("profile.age"), male: num("profile.gender").map { $0 == 0 }, heightCm: num("profile.height"),
            weightKg: num("profile.weight").map(Double.init), stepGoal: num("goal.steps") ?? 6000,
            device: [.ring: "nhẫn", .watch: "đồng hồ", .band: "vòng tay"][d.kind]
        )
    }

    /// Cả luồng cho một thiết bị. Lỗi cũng ghi vào `errors` để thẻ hiện.
    @discardableResult
    func run(_ device: WearableDevice, period: HealthPeriod, manager: DeviceManager) async -> Result<Entry, Error> {
        let id = device.id
        guard phase[id] == nil else { return .failure(FlowError.busy) }
        errors[id] = nil
        refreshConfig()
        guard let config = HealthLLMConfig.load(Self.configURL) else { return fail(id, HealthReportError.notConfigured) }

        let started = Date()
        var syncSeconds = 0.0
        let stale = device.lastSyncedAt.map { Date().timeIntervalSince($0) > Self.staleAfter } ?? true
        if device.isConnected, device.supportsHistory, device.syncProgress == nil, stale {
            phase[id] = .syncing
            _ = await manager.syncHistory(device, days: 7)?.value
            syncSeconds = Date().timeIntervalSince(started)
        }
        guard let history = device.history else { return fail(id, FlowError.noHistory) }

        let summary = HealthSummary.make(history: history, period: period, profile: Self.profile(device))
        let findings = HealthFindings.evaluate(summary)
        phase[id] = .thinking
        let asked = Date()
        do {
            let report = try await HealthReportClient(config: config).report(summary: summary, findings: findings)
            let entry = Entry(report: report, findings: findings, syncSeconds: syncSeconds, llmSeconds: Date().timeIntervalSince(asked))
            entries[id] = entry
            save(entry, id)
            phase[id] = nil
            return .success(entry)
        } catch {
            return fail(id, error)
        }
    }

    private func fail(_ id: UUID, _ error: Error) -> Result<Entry, Error> {
        phase[id] = nil
        errors[id] = error.localizedDescription
        return .failure(error)
    }

    private func save(_ entry: Entry, _ id: UUID) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(entry).write(to: directory.appendingPathComponent("\(id.uuidString).json"), options: .atomic)
        } catch {
            SmartWearLog.w("Lưu báo cáo AI lỗi: \(error.localizedDescription)")
        }
    }
}
