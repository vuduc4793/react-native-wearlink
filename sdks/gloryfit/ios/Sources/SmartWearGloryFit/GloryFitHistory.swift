import Foundation
import SmartWearCore

extension GloryFitDevice {
    /// Đồng bộ lịch sử, bản iOS của `GloryFitDriver.syncHistoryImpl` Android, kèm chọn lệnh theo bit tính năng
    /// (`Ute.SyncPlan`): CyWee (Y25) ⇒ bước `EB 02 FA` trên 34F1, ngủ `EC 01`; có thuật toán ngủ trên đồng hồ
    /// (Y25, HT43) ⇒ ngủ `31 01`. Lệnh mới không có gói nào thì thử lệnh cũ (`B2 FA`, `B3 FA`) và ghi rõ vào log.
    func runHistorySync(days: Int, progress: @escaping @MainActor (SyncProgress) -> Void) async throws -> DeviceHistory {
        guard isConnected else { throw GloryFitError("Chưa kết nối") }
        let calendar = Calendar.current
        let dayCount = min(max(days, 1), 30)
        let from = calendar.date(byAdding: .day, value: -(dayCount - 1), to: calendar.startOfDay(for: Date())) ?? Date()
        let plan = Ute.SyncPlan(features: features, capabilities: capabilities)
        let hourlySleep = features.sleepHourlyFormat
        var series: [Capability: [HistoryPoint]] = [:]
        var sleep: [SleepSession] = []
        var workouts: [Workout] = []
        var today: ActivityTotals?

        var steps: [HistoryStep] = []
        steps.append(HistoryStep("Bước chân") { [unowned self] in
            series[.steps] = try await self.firstResponding(plan.steps, label: "bước") { cmd, packets in
                cmd == .stepsCywee ? Ute.parseCyweeSteps(packets, calendar: calendar) : Ute.parseSteps(packets, calendar: calendar)
            }
            if self.features.cywee {
                today = Ute.todayTotals(hourly: series[.steps] ?? [], current: await self.currentHourActivity(), calendar: calendar)
            }
        })
        if !plan.sleep.isEmpty {
            steps.append(HistoryStep("Giấc ngủ") { [unowned self] in
                sleep = try await self.firstResponding(plan.sleep, label: "ngủ") { cmd, packets in
                    switch cmd {
                    case .sleepResolve, .sleepCywee:
                        let days = Ute.sleepDays(packets, cywee: cmd == .sleepCywee)
                        for d in days where d.declaredCount != d.sectionCount {
                            // Byte [6] chưa rõ là số đoạn hay số giấc: chỉ ghi lại để đối chiếu trên đồng hồ thật.
                            self.note("\(cmd.hex) ngày \(d.year)-\(d.month)-\(d.day): byte n = \(d.declaredCount), nhận \(d.sectionCount) đoạn 6 byte")
                        }
                        return Ute.parseSleepDays(days, calendar: calendar)
                    default:
                        return Ute.parseSleep(packets, calendar: calendar, hourlyFormat: hourlySleep)
                    }
                }
            })
        }
        if let cmd = plan.heartRate {
            steps.append(HistoryStep("Nhịp tim") { [unowned self] in
                let packets = try await self.historyStream(cmd).packets
                series[.heartRate] = cmd == .heartRate24h
                    ? Ute.parseHeartRate24h(packets, calendar: calendar) : Ute.parseHeartRate(packets, calendar: calendar)
            })
        }
        if let cmd = plan.spo2 {
            steps.append(HistoryStep("SpO2") { [unowned self] in
                series[.spo2] = Ute.parseSpo2(try await self.historyStream(cmd).packets, calendar: calendar)
            })
        }
        // `C8 FA` (Y25 có huyết áp, HT43 không). Android trước đây chưa đồng bộ huyết áp.
        if let cmd = plan.bloodPressure {
            steps.append(HistoryStep("Huyết áp") { [unowned self] in
                series[.bloodPressure] = Ute.parseBloodPressure(try await self.historyStream(cmd).packets, calendar: calendar)
            })
        }

        // Bài tập đa môn (chạy, đạp xe, yoga…). F5 0x040000: thời gian tập hiệu quả ở byte 17–19.
        // F7 0x80 (b1.7 "GPS thể thao"): bản ghi có gói vùng nhịp tim / sải bước và chuỗi mẫu kèm toạ độ GPS.
        let endIsTimestamp = features.has(5, 0x040000)
        let hasDetail = features.has(7, 0x0080)
        steps.append(HistoryStep("Bài tập") { [unowned self] in
            workouts = Ute.parseWorkouts(
                try await self.workoutStream(), calendar: calendar, endIsTimestamp: endIsTimestamp, hasDetail: hasDetail
            )
        })

        let errors = await HistoryStep.runAll(steps, progress: progress)
        return DeviceHistory(
            series: series.mapValues { DeviceHistory.normalized($0.filter { $0.timestamp >= from }) },
            sleep: sleep.filter { $0.end >= from },
            workouts: workouts.filter { $0.end >= from },
            today: today,
            days: dayCount,
            syncedAt: Date(),
            errors: errors
        )
    }

    /// Thử lần lượt các lệnh trong `commands`: lệnh không có gói nào (kể cả gói kết thúc) hoặc lỗi gửi thì sang lệnh
    /// sau. Lệnh cuối không phản hồi thì trả về kết quả rỗng (như Android: đồng hồ chưa có dữ liệu).
    private func firstResponding<T: RangeReplaceableCollection>(
        _ commands: [Ute.SyncCommand], label: String, parse: (Ute.SyncCommand, [[UInt8]]) -> T
    ) async throws -> T {
        for (i, cmd) in commands.enumerated() {
            let isLast = i == commands.count - 1
            do {
                let r = try await historyStream(cmd)
                if r.packets.isEmpty, !r.ended, !isLast {
                    note("\(label): \(cmd.hex) không có gói nào trong 5 s, thử \(commands[i + 1].hex)")
                    continue
                }
                let parsed = parse(cmd, r.packets)
                note("\(label): dùng \(cmd.hex) → \(r.packets.count) gói\(r.ended ? "" : ", không có gói kết thúc"), \(parsed.count) mục")
                return parsed
            } catch {
                if isLast || error is CancellationError || !isConnected { throw error }
                note("\(label): \(cmd.hex) lỗi (\(error.localizedDescription)), thử \(commands[i + 1].hex)")
            }
        }
        return T()
    }

    /// Ghi chú đồng bộ vào nhật ký gói (mục "Chi tiết kỹ thuật") và log SDK.
    func note(_ message: String) {
        record(.info, "", Data(), "Đồng bộ \(message)")
        SmartWearLog.i("[\(name)] đồng bộ \(message)")
    }
}
