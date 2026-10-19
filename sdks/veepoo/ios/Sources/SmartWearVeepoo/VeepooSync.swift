import Foundation
import SmartWearCore

extension VeepooDevice {
    /// Đồng bộ lịch sử theo thứ tự của G Band (`BleReadManager1$startSyncOriginData$1.java:99-268`): ngủ `E0` từng ngày →
    /// 5 phút `D1`/`DF` từng ngày → bước hiện tại `A8`/`D8` → buổi tập `D3` → `D4`. Vòng tay chỉ giữ `watchDays` ngày
    /// (A7 trang 2 byte 2). Mỗi bước lỗi ghi vào `errors`, các bước khác vẫn chạy.
    func runHistorySync(days: Int, progress: @escaping @MainActor (SyncProgress) -> Void) async throws -> DeviceHistory {
        guard isConnected else { throw VeepooError("Chưa kết nối") }
        let calendar = Calendar.current
        let now = Date()
        let f = features
        let dayCount = min(max(days, 1), f.watchDays)
        let from = calendar.date(byAdding: .day, value: -(max(days, 1) - 1), to: calendar.startOfDay(for: now)) ?? now
        let height = settings["profile.height"]
        var records: [VeepooHistory.FiveMinute] = []
        var sleep: [SleepSession] = []
        var workouts: [Workout] = []
        var today: ActivityTotals?
        var bodyComposition: [HistoryPoint] = []

        var steps: [HistoryStep] = []
        if f.sleep {
            steps.append(HistoryStep("Giấc ngủ") { [unowned self] in
                for day in 0..<dayCount {
                    // `E0` có timeout 30 s cho cả ngày (doc 02 §6); ở đây dừng khi im lặng 5 s hoặc gặp gói cuối.
                    let packets = try await self.collect(VeepooHistory.sleepRequest(day: day), idle: 5, end: VeepooHistory.isSleepEnd) {
                        $0.first == 0xE0 && $0.count >= 20
                    }
                    let s = f.preciseSleep
                        ? VeepooHistory.parsePreciseSleep(packets, day: day, now: now, calendar: calendar)
                        : VeepooHistory.parseNormalSleep(packets, day: day, now: now, calendar: calendar)
                    self.note("ngủ ngày -\(day): \(packets.count) gói → \(s.count) giấc (\(f.preciseSleep ? "chính xác" : "thường"))")
                    for x in s where !sleep.contains(where: { $0.start == x.start }) { sleep.append(x) }
                }
            })
        }
        steps.append(HistoryStep("Dữ liệu 5 phút") { [unowned self] in
            for day in 0..<dayCount {
                let readDate = calendar.date(byAdding: .day, value: -day, to: calendar.startOfDay(for: now)) ?? now
                if f.usesDf {
                    // `DF pos day` (originProtocol 3/5) → khối TLV tới gói `DF FF FF`; im lặng 5 s thì dừng (như app gốc).
                    let packets = try await self.collect(VeepooHistory.dfRequest(day: day), idle: 5, end: VeepooHistory.isDfEnd) {
                        $0.first == 0xDF && $0.count >= 4
                    }
                    let blocks = VeepooHistory.assembleDf(packets, protocol5: f.originProtocolVersion == 5)
                    let bad = blocks.filter { !$0.crcOk }.count
                    let r = blocks.filter(\.crcOk).compactMap {
                        VeepooHistory.parseFiveMinute($0.payload, readDate: readDate, calendar: calendar, glucoseRiskBits: f.bloodGlucoseType == 5)
                    }
                    self.note("DF ngày -\(day): \(packets.count) gói, \(blocks.count) khối\(bad > 0 ? ", \(bad) khối sai CRC" : "") → \(r.count) bản ghi")
                    records += r
                } else {
                    // Kiểu cũ `D1` (chưa có thiết bị thật để kiểm; Android chưa làm).
                    let packets = try await self.collect(VeepooHistory.d1Request(day: day), idle: 5, end: VeepooHistory.isD1End) {
                        $0.first == 0xD1 && $0.count >= 20
                    }
                    let r = packets.compactMap {
                        VeepooHistory.parseD1($0, sportLayout: f.parseSportModel, heightCm: height, now: now, calendar: calendar)
                    }
                    self.note("D1 ngày -\(day): \(packets.count) gói → \(r.count) bản ghi")
                    records += r
                }
            }
        })
        steps.append(HistoryStep("Bước hôm nay") { [unowned self] in
            if f.parseSportModel {
                let p = try await self.request(VeepooHistory.sportModelStepsRead) { $0.first == 0xD8 && $0.count >= 14 }
                today = VeepooHistory.parseSportModelSteps(p)
            } else {
                let p = try await self.request(VeepooHistory.currentStepsRead) { $0.first == 0xA8 && $0.count >= 6 }
                if let n = VeepooHistory.parseCurrentSteps(p) {
                    // `A8` không có quãng đường / calo: tự tính theo chiều cao như `SportUtil` của app gốc.
                    let e = VeepooHistory.estimate(steps: n, heightCm: height)
                    today = ActivityTotals(steps: n, calories: e.calories, distanceMeters: e.distanceMeters)
                }
            }
        })
        // Buổi tập: kiểu cổ điển hoặc TLV (`multiSportType` 4/5/6, GE54 = 5) như Android.
        if f.sportModel {
            steps.append(HistoryStep("Bài tập") { [unowned self] in
                let crcPacket = try? await self.request(VeepooHistory.sportCrcRead) { $0.first == 0xD3 }
                let crcs = crcPacket.flatMap { VeepooHistory.parseSportCrc($0, slots: f.sportModelSlots) }
                // CRC 0 / FFFF = khe trống (suy luận); không đọc được CRC thì đọc mọi khe.
                let slots = crcs.map { c in c.indices.filter { c[$0] != 0 && c[$0] != 0xFFFF } } ?? Array(0..<f.sportModelSlots)
                for slot in slots {
                    let packets = try await self.collect(VeepooHistory.workoutRequest(slot: slot), idle: 5, end: VeepooHistory.isWorkoutEnd) {
                        $0.first == 0xD4 && $0.count >= 20
                    }
                    let w = f.tlvWorkout ? VeepooHistory.parseTlvWorkout(packets) : VeepooHistory.parseWorkout(packets, calendar: calendar)
                    if let w { workouts.append(w) }
                    self.note("bài tập khe \(slot): \(packets.count) gói")
                }
            })
        }

        // Thành phần cơ thể đo nhanh đã lưu trên vòng tay (không có trong `DF`), như `readBodyComponentData` của G Band.
        if f.bodyComponent {
            steps.append(HistoryStep("Thành phần cơ thể") { [unowned self] in
                let p = try await self.request(VeepooHistory.bodyCompositionIdsRead) { $0.count >= 3 && $0[0] == 0x93 && $0[1] == 0x05 && $0[2] != 0xA1 }
                let ids = VeepooHistory.parseBodyCompositionIds(p) ?? []
                for id in ids {
                    let packets = try await self.collect(VeepooHistory.bodyCompositionRecordRead(id: id), idle: 3,
                                                         end: VeepooHistory.isBodyCompositionRecordEnd) { $0.count >= 5 && $0[0] == 0x93 && $0[1] == 0x06 }
                    if let point = VeepooHistory.parseBodyCompositionRecord(packets, calendar: calendar) { bodyComposition.append(point) }
                }
                self.note("thành phần cơ thể: \(ids.count) bản ghi → \(bodyComposition.count) điểm")
            })
        }

        let errors = await HistoryStep.runAll(steps, progress: progress)
        var all = VeepooHistory.series(records)
        if !bodyComposition.isEmpty { all[.bodyComposition] = DeviceHistory.normalized(bodyComposition) }
        let series = all.mapValues { $0.filter { $0.timestamp >= from } }
        return DeviceHistory(
            series: series,
            sleep: sleep.filter { $0.end >= from }.sorted { $0.start < $1.start },
            workouts: workouts.filter { $0.end >= from }.sorted { $0.start > $1.start },
            today: today ?? VeepooHistory.todayTotals(all, now: now, calendar: calendar),
            days: dayCount,
            syncedAt: Date(),
            errors: errors
        )
    }

    /// Ghi chú đồng bộ vào nhật ký gói (mục "Chi tiết kỹ thuật") và log SDK.
    func note(_ message: String) {
        record(.info, "", Data(), "Đồng bộ \(message)")
        SmartWearLog.i("[\(name)] đồng bộ \(message)")
    }
}
