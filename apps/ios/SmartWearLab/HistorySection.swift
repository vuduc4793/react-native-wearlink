import Charts
import SmartWearCore
import SwiftUI

/// Mục "Lịch sử" trong màn chi tiết: đồng bộ và xem dữ liệu đã lưu trên thiết bị theo ngày (bản iOS của
/// `HistorySection.kt`). Cột bước 7 ngày (chạm để chọn ngày), giấc ngủ theo giai đoạn, chuỗi HR/SpO2/HA/HRV/…
struct HistorySection: View {
    @Environment(AppState.self) private var app
    let device: WearableDevice
    @State private var dayOffset = 0

    private static let syncDays = 7
    private static let vi = Locale(identifier: "vi_VN")
    private var calendar: Calendar { .current }

    var body: some View {
        if device.supportsHistory {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(text: "Lịch sử", trailing: syncedLabel)
                if let p = device.syncProgress {
                    progressCard(p)
                } else {
                    syncButton
                }
                if let h = device.history {
                    content(h)
                }
            }
            .onChange(of: device.id) { dayOffset = 0 }
        }
    }

    // MARK: - Đồng bộ

    private var syncedLabel: String {
        guard let t = device.lastSyncedAt else { return "chưa đồng bộ" }
        let f = DateFormatter()
        f.dateFormat = calendar.isDateInToday(t) ? "HH:mm" : "dd/MM HH:mm"
        return "đồng bộ lúc " + f.string(from: t)
    }

    private var canSync: Bool { device.isConnected && device.measuring.isEmpty }

    @ViewBuilder
    private var syncButton: some View {
        if device.history == nil {
            PrimaryButton(title: "Đồng bộ \(Self.syncDays) ngày", symbol: "arrow.triangle.2.circlepath", enabled: canSync) {
                app.manager.syncHistory(device, days: Self.syncDays)
            }
        } else {
            GlassButton(title: "Đồng bộ lại", symbol: "arrow.triangle.2.circlepath") {
                app.manager.syncHistory(device, days: Self.syncDays)
            }
            .frame(maxWidth: .infinity)
            .disabled(!canSync)
            .opacity(canSync ? 1 : 0.4)
        }
        if !device.isConnected {
            Text("Kết nối để đồng bộ dữ liệu lưu trên thiết bị.").font(.footnote).foregroundStyle(Palette.tertiary)
        }
    }

    private func progressCard(_ p: SyncProgress) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Đang đồng bộ · \(p.step)").font(.callout.weight(.semibold))
            ProgressView(value: p.fraction).tint(.white)
            Text("\(p.done + 1)/\(p.total) bước").font(.footnote).foregroundStyle(Palette.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    // MARK: - Nội dung theo ngày

    private func dayStart(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: Date())) ?? Date()
    }

    private func content(_ h: DeviceHistory) -> some View {
        let days = max(h.days, 1)
        let offset = min(dayOffset, days - 1)
        let start = dayStart(offset)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        return VStack(alignment: .leading, spacing: 12) {
            weekCard(h, days: days, selected: offset)
            activityCard(h, offset: offset, start: start, end: end)
            sleepCard(h, start: start, end: end)
            if device.capabilities.contains(.heartRate) || !h.workouts.isEmpty {
                workoutCard(h.workouts.filter { $0.start >= start && $0.start < end })
            }
            ForEach([Capability.heartRate, .spo2, .bloodPressure, .hrv, .stress, .temperature], id: \.self) { cap in
                if h.series[cap] != nil { seriesCard(cap, h.points(cap, from: start, to: end), start: start, end: end) }
            }
            if !h.errors.isEmpty { errorsCard(h.errors) }
        }
    }

    /// Bước của một ngày: ngày hôm nay ưu tiên tổng thiết bị báo (QRing `0x48`), còn lại cộng các khung.
    private func steps(_ h: DeviceHistory, offset: Int) -> Int {
        if offset == 0, let t = h.today { return t.steps }
        let s = dayStart(offset)
        let e = calendar.date(byAdding: .day, value: 1, to: s) ?? s
        return Int(h.points(.steps, from: s, to: e).reduce(0) { $0 + $1.value })
    }

    private func dayLabel(_ offset: Int) -> String {
        switch offset {
        case 0: return "Hôm nay"
        case 1: return "Hôm qua"
        default:
            let f = DateFormatter()
            f.locale = Self.vi
            f.dateFormat = "EEE d"
            return f.string(from: dayStart(offset)).capitalized
        }
    }

    private func shortDay(_ offset: Int) -> String {
        let f = DateFormatter()
        f.locale = Self.vi
        f.dateFormat = "d/M"
        return offset == 0 ? "Nay" : f.string(from: dayStart(offset))
    }

    /// Cột bước 7 ngày; chạm cột hoặc chip để chọn ngày.
    private func weekCard(_ h: DeviceHistory, days: Int, selected: Int) -> some View {
        let tint = Capability.steps.tint
        let bars = (0..<days).reversed().map { (offset: $0, label: shortDay($0), steps: steps(h, offset: $0)) }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Bước \(days) ngày", systemImage: Capability.steps.symbol).font(.headline).foregroundStyle(tint)
                Spacer()
                Text("tổng \(bars.reduce(0) { $0 + $1.steps }.formatted(.number.locale(Self.vi)))")
                    .font(.footnote).foregroundStyle(Palette.secondary)
            }
            Chart(bars, id: \.offset) { b in
                BarMark(x: .value("Ngày", b.label), y: .value("Bước", b.steps))
                    .foregroundStyle(b.offset == selected ? tint : tint.opacity(0.35))
                    .cornerRadius(4)
            }
            .chartYAxis { AxisMarks(position: .leading) { _ in AxisGridLine().foregroundStyle(Palette.hairline); AxisValueLabel() } }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onTapGesture { location in
                            guard let frame = proxy.plotFrame.map({ geo[$0] }) else { return }
                            if let label: String = proxy.value(atX: location.x - frame.origin.x),
                               let hit = bars.first(where: { $0.label == label }) {
                                dayOffset = hit.offset
                            }
                        }
                }
            }
            .frame(height: 120)
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(0..<days, id: \.self) { d in
                        Button { dayOffset = d } label: {
                            Text(dayLabel(d)).font(.footnote.weight(.semibold))
                                .foregroundStyle(d == selected ? .black : .white)
                                .padding(.horizontal, 12).frame(height: 30)
                                .background(d == selected ? Color.white : Palette.card, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(16)
        .card()
    }

    private func activityCard(_ h: DeviceHistory, offset: Int, start: Date, end: Date) -> some View {
        let tint = Capability.steps.tint
        let slots = h.points(.steps, from: start, to: end)
        let totals = offset == 0 ? h.today : nil
        let steps = totals?.steps ?? Int(slots.reduce(0) { $0 + $1.value })
        let calories = totals?.calories ?? Int(slots.reduce(0) { $0 + ($1.extra["calories"] ?? 0) })
        let distance = totals?.distanceMeters ?? Int(slots.reduce(0) { $0 + ($1.extra["distance"] ?? 0) })
        // Gộp khung 15 phút / theo giờ thành 24 cột.
        var hourly = [Double](repeating: 0, count: 24)
        for p in slots { hourly[min(max(calendar.component(.hour, from: p.timestamp), 0), 23)] += p.value }
        return VStack(alignment: .leading, spacing: 6) {
            Text("Hoạt động").font(.headline).foregroundStyle(tint)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(steps.formatted(.number.locale(Self.vi))).font(.system(size: 44, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("bước").font(.title3).foregroundStyle(Palette.secondary)
            }
            Text("\(Format.number(Double(calories) / 1000, decimals: 0)) kcal · \(Format.number(Double(distance) / 1000, decimals: 2)) km")
                .font(.callout).foregroundStyle(Palette.secondary)
            if slots.isEmpty {
                Text("Không có dữ liệu bước theo giờ.").font(.footnote).foregroundStyle(Palette.tertiary).padding(.top, 6)
            } else {
                Chart(Array(hourly.enumerated()), id: \.offset) { item in
                    BarMark(x: .value("Giờ", Double(item.offset)), y: .value("Bước", item.element), width: .ratio(0.7))
                        .foregroundStyle(item.element > 0 ? tint : Color.white.opacity(0.1))
                        .cornerRadius(3)
                }
                .chartXScale(domain: -0.5...23.5)
                .chartXAxis {
                    AxisMarks(values: [0.0, 6, 12, 18, 23]) { v in
                        AxisValueLabel { Text("\(Int(v.as(Double.self) ?? 0))h") }
                    }
                }
                .chartYAxis(.hidden)
                .frame(height: 90)
                .padding(.top, 8)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    // MARK: - Giấc ngủ

    private static let stages: [(SleepStage, String, Color)] = [
        (.awake, "Thức", Color(hex: 0xFF9F0A)), (.rem, "REM", Color(hex: 0x64D2FF)),
        (.light, "Nông", Color(hex: 0x7D7AFF)), (.deep, "Sâu", Color(hex: 0x4B3FD8)),
    ]

    private static func stageInfo(_ s: SleepStage) -> (String, Color) {
        stages.first { $0.0 == s }.map { ($0.1, $0.2) } ?? ("Khác", Palette.tertiary)
    }

    /// Bài tập trong ngày đang chọn (chạy, đạp xe, yoga… ghi trên đồng hồ).
    private func workoutCard(_ workouts: [Workout]) -> some View {
        let hm = DateFormatter()
        hm.dateFormat = "HH:mm"
        return VStack(alignment: .leading, spacing: 6) {
            Text("Bài tập").font(.headline).foregroundStyle(.orange)
            if workouts.isEmpty {
                Text("Không có bài tập trong ngày này. Bắt đầu một bài trên đồng hồ rồi đồng bộ lại.")
                    .font(.callout).foregroundStyle(Palette.secondary)
            }
            ForEach(workouts) { w in
                let parts = [
                    "\(hm.string(from: w.start)) · \(w.activeSeconds / 60) phút \(w.activeSeconds % 60) giây",
                    w.distanceMeters.map { String(format: "%.2f km", Double($0) / 1000) },
                    w.calories.map { "\($0) kcal" },
                    w.steps.map { "\($0) bước" },
                    w.avgHeartRate.map { "nhịp tim tb \($0)" + (w.maxHeartRate.map { " · max \($0)" } ?? "") },
                    w.paceSecondsPerKm.map { String(format: "pace %d'%02d\"/km", $0 / 60, $0 % 60) },
                ].compactMap { $0 }
                VStack(alignment: .leading, spacing: 2) {
                    Text(w.name).font(.callout.weight(.semibold))
                    Text(parts.joined(separator: " · ")).font(.footnote).foregroundStyle(Palette.secondary)
                }
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .card()
    }

    private func sleepCard(_ h: DeviceHistory, start: Date, end: Date) -> some View {
        let tint = Capability.sleep.tint
        let main = h.sleep.last { !$0.nap && $0.end >= start && $0.end < end }
        let naps = h.sleep.filter { $0.nap && $0.end >= start && $0.end < end }
        let hm = DateFormatter()
        hm.dateFormat = "HH:mm"
        return VStack(alignment: .leading, spacing: 6) {
            Text("Giấc ngủ").font(.headline).foregroundStyle(tint)
            ForEach(Array(naps.enumerated()), id: \.offset) { item in
                Text("Ngủ trưa \(hm.string(from: item.element.start))–\(hm.string(from: item.element.end)) · \(item.element.asleepMinutes) phút")
                    .font(.callout)
            }
            if let s = main {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(s.asleepMinutes / 60)").font(.system(size: 44, weight: .semibold, design: .rounded))
                    Text("giờ").font(.title3).foregroundStyle(Palette.secondary)
                    Text("\(s.asleepMinutes % 60)").font(.system(size: 44, weight: .semibold, design: .rounded))
                    Text("phút").font(.title3).foregroundStyle(Palette.secondary)
                }
                .monospacedDigit()
                Text("\(hm.string(from: s.start)) – \(hm.string(from: s.end))").font(.callout).foregroundStyle(Palette.secondary)
                // Thanh giai đoạn theo thời gian thật.
                Chart(Array(s.segments.enumerated()), id: \.offset) { item in
                    let seg = item.element
                    let info = Self.stageInfo(seg.stage)
                    RectangleMark(
                        xStart: .value("Bắt đầu", seg.start), xEnd: .value("Kết thúc", seg.end),
                        y: .value("Giai đoạn", info.0)
                    )
                    .foregroundStyle(info.1)
                    .cornerRadius(3)
                }
                .chartYScale(domain: Self.stages.map(\.1))
                .chartXScale(domain: s.start...max(s.end, s.start.addingTimeInterval(60)))
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisValueLabel(format: .dateTime.hour().minute()) } }
                .frame(height: 110)
                .padding(.top, 8)
                HStack {
                    ForEach(Self.stages, id: \.1) { st in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Circle().fill(st.2).frame(width: 8, height: 8)
                                Text(st.1).font(.caption).foregroundStyle(Palette.secondary)
                            }
                            Text("\(s.minutes(st.0) / 60)g \(s.minutes(st.0) % 60)p").font(.callout)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, 4)
            } else {
                Text(naps.isEmpty ? "Không có dữ liệu giấc ngủ cho ngày này." : "Không có giấc ngủ đêm.")
                    .font(.subheadline).foregroundStyle(Palette.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    // MARK: - Chuỗi theo thời gian

    private func fmt(_ cap: Capability, _ v: Double) -> String {
        Format.number(v, decimals: cap == .temperature ? 1 : 0)
    }

    private func seriesCard(_ cap: Capability, _ points: [HistoryPoint], start: Date, end: Date) -> some View {
        let values = points.map(\.value)
        let lows = points.map { $0.extra["min"] ?? $0.extra["diastolic"] ?? $0.value }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(cap.title, systemImage: cap.symbol).font(.headline).foregroundStyle(cap.tint)
                Spacer()
                Text("\(points.count) điểm").font(.footnote).foregroundStyle(Palette.secondary)
            }
            if points.isEmpty {
                Text("Không có dữ liệu cho ngày này.").font(.subheadline).foregroundStyle(Palette.secondary)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    if cap == .bloodPressure {
                        let dia = points.compactMap { $0.extra["diastolic"] }
                        Text("\(fmt(cap, values.reduce(0, +) / Double(values.count)))/\(fmt(cap, dia.reduce(0, +) / Double(max(dia.count, 1))))")
                            .font(.system(size: 30, weight: .semibold, design: .rounded))
                    } else {
                        Text(fmt(cap, values.reduce(0, +) / Double(values.count))).font(.system(size: 30, weight: .semibold, design: .rounded))
                    }
                    Text("\(cap.defaultUnit) trung bình").font(.footnote).foregroundStyle(Palette.secondary)
                }
                .monospacedDigit()
                Text("thấp \(fmt(cap, lows.min() ?? 0)) · cao \(fmt(cap, values.max() ?? 0))")
                    .font(.footnote).foregroundStyle(Palette.secondary)
                Chart(Array(points.enumerated()), id: \.offset) { item in
                    let p = item.element
                    // SpO2: đoạn thấp–cao trong giờ; huyết áp: tâm trương–tâm thu.
                    if let low = p.extra["min"] ?? p.extra["diastolic"], low < p.value {
                        RuleMark(x: .value("Giờ", p.timestamp), yStart: .value("Thấp", low), yEnd: .value("Cao", p.value))
                            .lineStyle(StrokeStyle(lineWidth: 4, lineCap: .round))
                            .foregroundStyle(cap.tint.opacity(0.45))
                    }
                    PointMark(x: .value("Giờ", p.timestamp), y: .value(cap.title, p.value))
                        .symbolSize(18)
                        .foregroundStyle(cap.tint)
                }
                .chartXScale(domain: start...end)
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXAxis {
                    AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                        AxisGridLine().foregroundStyle(Palette.hairline)
                        AxisValueLabel(format: .dateTime.hour())
                    }
                }
                .frame(height: 110)
                .padding(.top, 8)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func errorsCard(_ errors: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Không đồng bộ được").font(.callout.weight(.semibold)).foregroundStyle(.orange)
            ForEach(errors, id: \.self) { e in Text("· \(e)").font(.footnote).foregroundStyle(Palette.secondary) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}
