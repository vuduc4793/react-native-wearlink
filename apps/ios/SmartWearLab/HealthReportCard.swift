import SmartWearCore
import SwiftUI

/// Thẻ "Báo cáo AI" trong màn chi tiết: nút "Hôm nay" / "7 ngày" chạy `HealthReportService` (đồng bộ nếu cũ → số liệu
/// + luật → LLM viết chữ) rồi hiện tiêu đề, tóm tắt, các mục theo màu trạng thái, lời khuyên, miễn trừ.
/// nil nếu thiết bị không lưu lịch sử, để màn chi tiết chèn thẳng `HealthReportCard(device)`.
struct HealthReportCard: View {
    @Environment(AppState.self) private var app
    let device: WearableDevice

    init?(_ device: WearableDevice) {
        guard device.supportsHistory else { return nil }
        self.device = device
    }

    static func color(_ s: HealthSeverity) -> Color {
        switch s {
        case .ok: return Color(hex: 0x30D158)
        case .notice: return Color(hex: 0xFF9F0A)
        case .warn: return Color(hex: 0xFF453A)
        }
    }

    var body: some View {
        let svc = app.healthReport
        let phase = svc.phase[device.id]
        let entry = svc.entries[device.id]
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: "Báo cáo AI", trailing: entry.map { label($0.report) })
            VStack(alignment: .leading, spacing: 12) {
                if !svc.configured {
                    Text("Chưa cấu hình máy chủ AI").font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                    Text("Đẩy file llm.env (LLM_API_BASE, LLM_MODEL, LLM_API_KEY) vào thư mục Documents của app.")
                        .font(.caption).foregroundStyle(Palette.secondary)
                }
                HStack(spacing: 10) {
                    ForEach(HealthPeriod.allCases, id: \.self) { p in
                        GlassButton(title: p.title, symbol: p == .day ? "sparkles" : "calendar") {
                            Task { await svc.run(device, period: p, manager: app.manager) }
                        }
                        .frame(maxWidth: .infinity)
                        .disabled(phase != nil || !svc.configured)
                        .opacity(phase != nil || !svc.configured ? 0.4 : 1)
                    }
                }
                if let phase {
                    HStack(spacing: 8) {
                        ProgressView().tint(.white)
                        Text(phase == .syncing ? "Đang đồng bộ lịch sử…" : "AI đang viết báo cáo…")
                            .font(.footnote).foregroundStyle(Palette.secondary)
                    }
                }
                if let err = svc.errors[device.id] {
                    Text(err).font(.footnote).foregroundStyle(.orange)
                }
                if let entry { report(entry.report) }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
        .task { svc.refreshConfig() }
    }

    private func label(_ r: HealthReport) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(r.generatedAt) ? "HH:mm" : "dd/MM HH:mm"
        return "\(r.period.title) · \(f.string(from: r.generatedAt))"
    }

    @ViewBuilder
    private func report(_ r: HealthReport) -> some View {
        Divider().overlay(Palette.hairline)
        Text(r.title).font(.headline)
        if !r.summary.isEmpty { Text(r.summary).font(.callout) }
        ForEach(Array(r.sections.enumerated()), id: \.offset) { _, s in
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle().fill(Self.color(s.status)).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.title).font(.subheadline.weight(.semibold)).foregroundStyle(Self.color(s.status))
                    Text(s.text).font(.footnote).foregroundStyle(Palette.secondary)
                }
            }
        }
        if !r.tips.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Lời khuyên").font(.subheadline.weight(.semibold))
                ForEach(r.tips, id: \.self) { t in Text("• \(t)").font(.footnote) }
            }
        }
        Text(r.disclaimer).font(.caption2).foregroundStyle(Palette.tertiary)
    }
}
