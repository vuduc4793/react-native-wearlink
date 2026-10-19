import Foundation
import SmartWearCore

extension QRingDevice {
    /// Đồng bộ lịch sử theo trình tự của app QRing (03-history-sync.md §6), bản iOS của `QRingDriver.syncHistoryImpl`.
    /// Mỗi bước độc lập: bước lỗi được ghi vào `DeviceHistory.errors`, các bước khác vẫn chạy.
    func runHistorySync(days: Int, progress: @escaping @MainActor (SyncProgress) -> Void) async throws -> DeviceHistory {
        guard isConnected, let caps = client.deviceInfo?.qringCapabilities else { throw QRingError("Chưa kết nối") }
        let parser = HistoryParser()
        let dayCount = min(max(days, 1), 7)
        let today = Date()
        let calendar = parser.calendar
        var series: [Capability: [HistoryPoint]] = [:]
        var errors: [String] = []
        var sleep: [SleepSession] = []
        var totals: ActivityTotals?
        let client = self.client

        var steps: [HistoryStep] = []
        steps.append(HistoryStep("Tổng hôm nay") {
            totals = parser.parseTodayTotals(try await client.request(Packet.of(HistoryParser.cmdTodayTotals)))
        })
        for d in 0..<dayCount {
            let date = calendar.date(byAdding: .day, value: -d, to: calendar.startOfDay(for: today)) ?? today
            let label = d == 0 ? "hôm nay" : "\(d) ngày trước"
            steps.append(HistoryStep("Bước chân \(label)") {
                let packets = try await client.requestStream(parser.stepsRequest(d), isComplete: parser.stepsComplete)
                series[.steps, default: []] += parser.parseSteps(packets)
            })
            steps.append(HistoryStep("Nhịp tim \(label)") {
                let packets = try await client.requestStream(parser.heartRateRequest(date), isComplete: parser.heartRateComplete)
                series[.heartRate, default: []] += parser.parseHeartRate(packets, day: date)
            })
            if caps.hrv {
                steps.append(HistoryStep("HRV \(label)") {
                    let packets = try await client.requestStream(parser.hrvRequest(d), isComplete: parser.dailyComplete)
                    series[.hrv, default: []] += parser.parseDaily(packets, day: date)
                })
            }
            if caps.stress {
                steps.append(HistoryStep("Stress \(label)") {
                    let packets = try await client.requestStream(parser.stressRequest(d), isComplete: parser.dailyComplete)
                    series[.stress, default: []] += parser.parseDaily(packets, day: date)
                })
            }
            if caps.temperature {
                steps.append(HistoryStep("Nhiệt độ \(label)") {
                    var pages: [HistoryParser.IntervalPage] = []
                    for page in 0..<16 {
                        let frame = try await client.requestBigData(parser.intervalRequest(HistoryParser.cmdTemperatureInterval, dayIndex: d, page: page))
                        guard let parsed = parser.parseIntervalPage(frame.payload, twoByteValues: true), parsed.count > 0 else { break }
                        pages.append(parsed)
                        if parsed.index >= parsed.count - 1 { break }
                    }
                    series[.temperature, default: []] += parser.intervalPoints(pages, today: today)
                })
            }
        }
        if caps.newSleepProtocol {
            steps.append(HistoryStep("Giấc ngủ") {
                let frames = try await client.requestBigDataMulti(
                    parser.sleepRequest(), expect: [HistoryParser.cmdSleep, HistoryParser.cmdNap]
                )
                sleep = (frames[HistoryParser.cmdSleep].map { parser.parseSleep($0.payload, today: today) } ?? [])
                    + (frames[HistoryParser.cmdNap].map { parser.parseSleep($0.payload, today: today, nap: true) } ?? [])
            })
        } else {
            errors.append("Giấc ngủ: thiết bị dùng giao thức cũ (0x44), SDK chưa hỗ trợ")
        }
        if caps.spo2 {
            steps.append(HistoryStep("SpO2") {
                series[.spo2, default: []] += parser.parseSpo2(try await client.requestBigData(parser.spo2Request()).payload, today: today)
            })
        }
        // Chỉ lấy HA đo tay `0x14` (DS500); `0x0D` là nhịp tim, app QRing tự sinh SBP/DBP (03 §5.5). Android chưa có bước này.
        if caps.bloodPressure {
            steps.append(HistoryStep("Huyết áp") {
                let packets = try await client.requestStream(parser.bloodPressureRequest(), isComplete: parser.bloodPressureComplete)
                let from = calendar.date(byAdding: .day, value: -(dayCount - 1), to: calendar.startOfDay(for: today)) ?? today
                series[.bloodPressure, default: []] += parser.parseBloodPressure(packets).filter { $0.timestamp >= from }
            })
        }

        errors += await HistoryStep.runAll(steps, progress: progress)
        return DeviceHistory(
            series: series.mapValues(DeviceHistory.normalized),
            sleep: sleep.sorted { $0.start < $1.start },
            today: totals,
            days: dayCount,
            syncedAt: Date(),
            errors: errors
        )
    }
}
