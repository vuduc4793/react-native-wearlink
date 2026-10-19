import Observation
import SmartWearCore
import SwiftUI

/// Popup kiểu AirPods: đưa thiết bị hỗ trợ (Y25, HT43, nhẫn R09, vòng tay GE54) chưa kết nối SÁT iPhone thì hiện thẻ có mô hình 3D và nút
/// "Kết nối". Nhiều thiết bị ở sát cùng lúc thì thẻ thành carousel trượt ngang.
///
/// Chỉ chạy khi app đang mở (iOS không cho app bên thứ ba hiện popup hệ thống như AirPods). Y25 chỉ quảng bá một
/// quãng ngắn sau khi bật / bị ngắt / được đánh thức (docs/case-studies/2026-10-15-y25-khong-tim-thay.md §5b).
@MainActor
@Observable
final class NearbyPrompt {
    /// Dòng thiết bị có popup: tiền tố tên quảng bá → mô hình 3D (`apps/shared/watch3d/<model>`) + mô tả.
    /// `nearRSSI`: ngưỡng "sát" như AirPods (vài cm) RIÊNG từng dòng vì công suất phát khác nhau. Đo 15/10/2026 trên
    /// iPhone 11: HT43 sát máy -42…-46 dBm; Y25 sát máy chỉ -58…-59 dBm (yếu hơn ~15 dB) và quảng bá thưa hơn ~50 lần
    /// (21 gói so với 1068 gói của HT43 cùng quãng) ⇒ Y25 chỉ cần 1 lần đạt ngưỡng.
    struct Model: Sendable {
        let driverId: String
        let prefix: String
        let model3D: String
        let subtitle: String
        let nearRSSI: Int
        let hitsNeeded: Int
    }

    static let models = [
        Model(driverId: "gloryfit", prefix: "Y25", model3D: "y25", subtitle: "Đồng hồ thông minh", nearRSSI: -60, hitsNeeded: 1),
        Model(driverId: "gloryfit", prefix: "HT43", model3D: "ht43", subtitle: "Đồng hồ GPS", nearRSSI: -47, hitsNeeded: 2),
        Model(driverId: "qring", prefix: "R09", model3D: "r09", subtitle: "Nhẫn thông minh", nearRSSI: -50, hitsNeeded: 2),
        // DS500/HS500A chưa đo độ sát; tạm theo nhẫn, chỉnh bằng `-nearRSSI` khi có log `[NEARBY]`.
        Model(driverId: "qring", prefix: "DS500", model3D: "ds500", subtitle: "Vòng tay thông minh", nearRSSI: -50, hitsNeeded: 2),
        // PALREDIL GE54 (Veepoo): sát Redmi đo -46 dBm (19/10/2026, Android); iPhone chưa đo, tạm như nhẫn.
        Model(driverId: "veepoo", prefix: "GE54", model3D: "ge54", subtitle: "Vòng tay thông minh", nearRSSI: -50, hitsNeeded: 2),
    ]

    struct Candidate: Identifiable, Equatable {
        let id: UUID
        let name: String
        let rssi: Int
        let model3D: String
        let subtitle: String
    }

    /// Ngưỡng của một dòng; `-nearRSSI <dBm>` ghi đè cho mọi dòng (để hiệu chỉnh theo log `[NEARBY]`).
    static func nearRSSI(_ m: Model) -> Int {
        let v = UserDefaults.standard.integer(forKey: "nearRSSI")
        return v < 0 ? v : m.nearRSSI
    }
    /// Bấm "Để sau" thì không hỏi lại thiết bị đó trong chừng này.
    static let snooze: TimeInterval = 5 * 60

    /// Thiết bị đang hiện trong thẻ (rỗng = không hiện).
    var candidates: [Candidate] = []
    var isPresented: Bool { !candidates.isEmpty }

    @ObservationIgnored private var hits: [UUID: Int] = [:]
    @ObservationIgnored private var snoozedUntil: [UUID: Date] = [:]
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var lastReport = Date.distantPast

    /// Bắt đầu theo dõi (app vào foreground). Quét liên tục, kiểm tra mỗi giây.
    func start(_ manager: DeviceManager) {
        guard loop == nil else { return }
        print("[NEARBY] bắt đầu theo dõi (app ở foreground)")
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                if manager.bluetoothState == .poweredOn, !manager.isScanning { manager.startScan(duration: nil) }
                self?.check(manager)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    /// Dừng khi app vào nền (quét liên tục tốn pin).
    func stop(_ manager: DeviceManager) {
        print("[NEARBY] dừng theo dõi (app vào nền)")
        loop?.cancel()
        loop = nil
        manager.stopScan()
        hits.removeAll()
    }

    /// Đóng cả thẻ; `snoozing` = "Để sau" cho mọi thiết bị đang hiện.
    func dismissAll(snoozing: Bool) {
        if snoozing { for c in candidates { snoozedUntil[c.id] = Date().addingTimeInterval(Self.snooze) } }
        candidates = []
    }

    /// Bỏ một thiết bị khỏi carousel (đã nối xong / "Để sau" riêng nó).
    func remove(_ id: UUID, snoozing: Bool) {
        if snoozing { snoozedUntil[id] = Date().addingTimeInterval(Self.snooze) }
        candidates.removeAll { $0.id == id }
    }

    /// Thẻ thử, không cần thiết bị (`-nearbyDemo YES`, hoặc `-nearbyDemo 2` để xem carousel).
    func showDemo(count: Int, only: String? = nil) {
        candidates = [
            Candidate(id: UUID(), name: "Y25(ID-6E1B)", rssi: -42, model3D: "y25", subtitle: "Đồng hồ thông minh"),
            Candidate(id: UUID(), name: "HT43(ID-2750)", rssi: -44, model3D: "ht43", subtitle: "Đồng hồ GPS"),
            Candidate(id: UUID(), name: "R09_8404", rssi: -48, model3D: "r09", subtitle: "Nhẫn thông minh"),
            Candidate(id: UUID(), name: "DS500_4E00", rssi: -47, model3D: "ds500", subtitle: "Vòng tay thông minh"),
            Candidate(id: UUID(), name: "GE54", rssi: -46, model3D: "ge54", subtitle: "Vòng tay thông minh"),
        ].filter { only == nil || $0.model3D == only }.prefix(max(1, count)).map { $0 }
    }

    static func model(for d: DiscoveredDevice) -> Model? {
        let name = (d.scanned.name ?? d.match.model ?? "").uppercased()
        return models.first { $0.driverId == d.driverId && name.hasPrefix($0.prefix) }
    }

    private func check(_ manager: DeviceManager) {
        let now = Date()
        // Mỗi 5 s in trạng thái từng thiết bị hỗ trợ và lý do (không) hiện popup, để chẩn đoán trên máy thật.
        if now.timeIntervalSince(lastReport) >= 5 {
            lastReport = now
            let rows = manager.discovered.values.compactMap { d -> String? in
                guard let m = Self.model(for: d) else { return nil }
                let age = Int(now.timeIntervalSince(d.lastSeen))
                let why: String
                if manager.device(d.id)?.isConnected == true { why = "đã kết nối" }
                else if manager.isKept(d.id) { why = "đang giữ kết nối (app tự nối, không hỏi)" }
                else if d.scanned.rssi == 0 { why = "iOS đang giữ kết nối hệ thống (không quảng bá)" }
                else if age >= 3 { why = "không thấy quảng bá \(age) s" }
                else if d.scanned.rssi < Self.nearRSSI(m) { why = "chưa đủ sát (\(d.scanned.rssi) < \(Self.nearRSSI(m)))" }
                else { why = "đủ sát" }
                return "\(d.displayName) rssi=\(d.scanned.rssi) → \(why)"
            }
            print("[NEARBY] quét=\(manager.isScanning ? "bật" : "TẮT") bluetooth=\(manager.bluetoothState.rawValue) · " +
                  (rows.isEmpty ? "không thấy Y25/HT43/R09/GE54 nào" : rows.joined(separator: " | ")))
        }
        for d in manager.discovered.values {
            // iOS đang giữ kết nối hệ thống (không quảng bá, rssi 0) mà app chưa dùng: chắc chắn ở gần và nối được ngay
            // (vd R09 sau khi app khác/lần chạy trước để lại) ⇒ hiện luôn, không đo độ sát.
            if let model = Self.model(for: d), d.scanned.rssi == 0, manager.device(d.id)?.isConnected != true,
               !manager.isKept(d.id), !candidates.contains(where: { $0.id == d.id }),
               (snoozedUntil[d.id] ?? .distantPast) <= now {
                print("[NEARBY] \(d.displayName): iOS đang giữ kết nối sẵn ⇒ hiện thẻ")
                candidates.append(Candidate(id: d.id, name: d.displayName, rssi: 0, model3D: model.model3D, subtitle: model.subtitle))
                continue
            }
            guard let model = Self.model(for: d), now.timeIntervalSince(d.lastSeen) < 3, d.scanned.rssi != 0 else {
                hits[d.id] = 0
                continue
            }
            // Đã kết nối hoặc đang giữ kết nối (app tự nối) thì không hỏi; đã có trong thẻ thì bỏ qua.
            if manager.device(d.id)?.isConnected == true || manager.isKept(d.id) { continue }
            if candidates.contains(where: { $0.id == d.id }) { continue }
            if let until = snoozedUntil[d.id], until > now { continue }
            let threshold = Self.nearRSSI(model)
            hits[d.id] = d.scanned.rssi >= threshold ? (hits[d.id] ?? 0) + 1 : 0
            print("[NEARBY] \(d.displayName) rssi=\(d.scanned.rssi) ngưỡng=\(threshold) đạt=\(hits[d.id] ?? 0)/\(model.hitsNeeded)")
            if (hits[d.id] ?? 0) >= model.hitsNeeded {
                hits[d.id] = 0
                candidates.append(Candidate(id: d.id, name: d.displayName, rssi: d.scanned.rssi, model3D: model.model3D, subtitle: model.subtitle))
            }
        }
    }
}

/// Thẻ "thiết bị ở gần": một thiết bị thì một trang, nhiều thiết bị thì carousel trượt ngang (có chấm trang).
struct NearbySheet: View {
    @Environment(AppState.self) private var app
    @State private var page: UUID?

    var body: some View {
        let list = app.nearby.candidates
        VStack(spacing: 0) {
            HStack {
                if list.count > 1 {
                    Text("\(list.count) thiết bị ở gần").font(.footnote.weight(.semibold)).foregroundStyle(Palette.secondary)
                }
                Spacer()
                Button { app.nearby.dismissAll(snoozing: true) } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .bold))
                        .frame(width: 30, height: 30).background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Đóng")
            }
            .padding(.horizontal, 22).padding(.top, 18)
            TabView(selection: $page) {
                ForEach(list) { c in
                    NearbyCard(candidate: c).tag(Optional(c.id))
                }
            }
            .tabViewStyle(.page(indexDisplayMode: list.count > 1 ? .always : .never))
        }
    }
}

/// Một trang: mô hình 3D tự xoay, tên, nút Kết nối / Để sau, trạng thái kết nối.
struct NearbyCard: View {
    @Environment(AppState.self) private var app
    let candidate: NearbyPrompt.Candidate

    private enum Phase: Equatable { case idle, connecting, done(Int?), failed(String) }
    @State private var phase: Phase = .idle

    var body: some View {
        VStack(spacing: 14) {
            Watch3DView(model: candidate.model3D)
                .frame(height: 250)
                .allowsHitTesting(false)
            VStack(spacing: 4) {
                Text(candidate.name).font(.title3.weight(.semibold))
                Text(subtitle).font(.subheadline).foregroundStyle(Palette.secondary)
            }
            switch phase {
            case .idle:
                PrimaryButton(title: "Kết nối", symbol: "link") { connect() }
                Button("Để sau") { app.nearby.remove(candidate.id, snoozing: true) }
                    .font(.subheadline).foregroundStyle(Palette.secondary)
            case .connecting:
                ProgressView("Đang kết nối…").padding(.vertical, 12)
            case .done:
                Label("Đã kết nối", systemImage: "checkmark.circle.fill")
                    .font(.headline).foregroundStyle(Color(hex: 0x30D158)).padding(.vertical, 12)
            case .failed(let message):
                Text(message).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
                PrimaryButton(title: "Thử lại", symbol: "arrow.clockwise") { connect() }
            }
            Spacer(minLength: 28) // chỗ cho chấm trang của carousel
        }
        .padding(.horizontal, 22)
    }

    private var subtitle: String {
        switch phase {
        case .done(let battery): return candidate.subtitle + (battery.map { " · pin \($0)%" } ?? "")
        default: return candidate.subtitle + " · ở gần"
        }
    }

    private func connect() {
        phase = .connecting
        Task { @MainActor in
            let error = await app.manager.connect([candidate.id], keep: true)[candidate.id] ?? nil
            if let error {
                phase = .failed("Chưa nối được: \(error.localizedDescription). App vẫn tự chờ và nối khi đồng hồ phát tín hiệu.")
                return
            }
            let d = app.manager.device(candidate.id)
            phase = .done(d?.battery)
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            app.nearby.remove(candidate.id, snoozing: false)
            // Còn thiết bị khác trong carousel thì để người dùng nối tiếp; hết thì mở màn chi tiết.
            if app.nearby.candidates.isEmpty, let d { app.open(d) }
        }
    }
}
