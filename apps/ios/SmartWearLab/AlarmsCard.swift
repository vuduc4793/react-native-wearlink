import SmartWearCore
import SwiftUI

/// Báo thức trên thiết bị (API chung `WearableDevice.alarms/setAlarm/deleteAlarm`): đọc danh sách, bật/tắt, xoá, thêm mới
/// (giờ, lặp hằng ngày / ngày thường / một lần, nhãn). nil nếu thiết bị không có báo thức.
struct AlarmsCard: View {
    let device: WearableDevice
    @State private var alarms: [Alarm] = []
    @State private var loading = false
    @State private var error: String?
    @State private var newTime = Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var newRepeat = Alarm.everyDay
    @State private var newLabel = ""

    init?(_ device: WearableDevice) {
        guard device.supportsAlarms else { return nil }
        self.device = device
    }

    private static let repeats: [(String, Int)] = [("Hằng ngày", Alarm.everyDay), ("Thứ 2–6", Alarm.weekdays), ("Một lần", 0)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Báo thức (tối đa \(device.maxAlarms))").font(.subheadline.weight(.semibold))
                Spacer()
                Button(loading ? "Đang đọc…" : "Đọc lại") { Task { await reload() } }
                    .font(.caption).disabled(loading || device.state != .connected)
            }
            ForEach(alarms) { a in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(formatMinuteOfDay(a.hour * 60 + a.minute)).font(.title3.monospacedDigit())
                        Text([Self.describe(a.repeatDays), a.label].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(Palette.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { a.enabled }, set: { on in
                        var x = a
                        x.enabled = on
                        run { try await device.setAlarm(x) }
                    })).labelsHidden()
                    Button(role: .destructive) { run { try await device.deleteAlarm(a.id) } } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }
            }
            if alarms.count < device.maxAlarms {
                Divider().overlay(Color.white.opacity(0.08))
                HStack {
                    DatePicker("", selection: $newTime, displayedComponents: .hourAndMinute).labelsHidden()
                    Picker("", selection: $newRepeat) {
                        ForEach(Self.repeats, id: \.1) { Text($0.0).tag($0.1) }
                    }.labelsHidden()
                }
                HStack {
                    TextField("Nhãn (tuỳ chọn)", text: $newLabel).textFieldStyle(.roundedBorder)
                    Button("Thêm") {
                        let c = Calendar.current.dateComponents([.hour, .minute], from: newTime)
                        let label = newLabel.trimmingCharacters(in: .whitespaces)
                        run {
                            try await device.setAlarm(Alarm(hour: c.hour ?? 7, minute: c.minute ?? 0, repeatDays: newRepeat,
                                                            label: label.isEmpty ? nil : label))
                        }
                    }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .padding(16)
        .card()
        .disabled(device.state != .connected)
        .task { await reload() }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        Task {
            do {
                try await work()
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
            await reload()
        }
    }

    private func reload() async {
        guard device.state == .connected else { return }
        loading = true
        defer { loading = false }
        do {
            alarms = try await device.alarms().sorted { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    static func describe(_ days: Int) -> String {
        if days == 0 { return "Một lần" }
        if days & Alarm.everyDay == Alarm.everyDay { return "Hằng ngày" }
        if days & Alarm.everyDay == Alarm.weekdays { return "Thứ 2–6" }
        let names = ["T2", "T3", "T4", "T5", "T6", "T7", "CN"]
        return names.indices.filter { days & (1 << $0) != 0 }.map { names[$0] }.joined(separator: ", ")
    }
}
