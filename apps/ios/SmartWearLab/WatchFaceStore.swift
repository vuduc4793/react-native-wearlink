import Foundation
import Observation
import UIKit
import SmartWearCore
import SmartWearGloryFit

/// Mặt đồng hồ mặc định của từng đồng hồ GloryFit, tự cài khi kết nối (cùng ý với `WatchFaceStore` Android).
///
/// Mọi mặt tuỳ chỉnh đều báo id `FFFFFFFE` qua `26 01`, nên app không phân biệt được hai mặt tuỳ chỉnh với nhau.
/// Vì vậy chỉ tự cài khi: đồng hồ đang hiện mặt có sẵn (vừa reset, người dùng đổi mặt), hoặc mặc định đã đổi
/// trong app này. Lần đầu thấy một đồng hồ đã có mặt tuỳ chỉnh thì coi là đúng, không gửi lại 1 MB.
@MainActor
@Observable
final class WatchFaceStore {
    struct Preset: Identifiable {
        let id: String
        let name: String
        let note: String
    }

    static let presets = [
        Preset(id: "peacock-3d", name: "Peacock 3D", note: "Nền 3D phủ kín · giờ, ngày, bước, nhịp tim, pin"),
        Preset(id: "peacock-atelier", name: "Peacock Atelier", note: "Kim giờ/phút/giây trên nền đồng · bước, nhịp tim, pin"),
        Preset(id: "ben10", name: "Ben 10 Biến hình", note: "Thử nghiệm · nhân vật đổi mỗi giây, vòng trong xoay · giờ, pin"),
    ]

    static func find(_ id: String?) -> Preset? { presets.first { $0.id == id } }
    static let defaultId = "peacock-3d"
    /// File trong thư viện đều là màn tròn 466 × 466.
    static let size = 466

    /// Trạng thái tự cài theo thiết bị, cho UI (nil = không làm gì).
    private(set) var status: [UUID: String] = [:]
    private(set) var progress: [UUID: Double] = [:]
    /// Tăng mỗi lần lưu (bộ mặc định, đã cài, tự cài lại), để UI đọc lại giá trị trong UserDefaults.
    private(set) var revision = 0

    @ObservationIgnored private var running: Set<UUID> = []
    @ObservationIgnored private let defaults = UserDefaults.standard

    private func key(_ id: UUID, _ field: String) -> String { "watchface.\(id.uuidString).\(field)" }

    /// Bộ mặc định của đồng hồ (đã chọn, hoặc Peacock 3D).
    func preset(for id: UUID) -> String { defaults.string(forKey: key(id, "preset")) ?? Self.defaultId }

    /// Bộ đã cài thành công gần nhất (theo app này).
    func pushed(for id: UUID) -> String? { defaults.string(forKey: key(id, "pushed")) }

    func setPreset(_ preset: String, for id: UUID) {
        defaults.set(preset, forKey: key(id, "preset"))
        revision += 1
    }

    /// Tự cài lại mặt mặc định mỗi lần kết nối (mặc định bật).
    func autoApply(for id: UUID) -> Bool { defaults.object(forKey: key(id, "autoApply")) as? Bool ?? true }

    func setAutoApply(_ enabled: Bool, for id: UUID) {
        defaults.set(enabled, forKey: key(id, "autoApply"))
        revision += 1
    }

    /// Đang cài (tự cài hoặc người dùng bấm) lên thiết bị này.
    func isInstalling(_ id: UUID) -> Bool { progress[id] != nil }

    static func bin(_ preset: String) -> Data? {
        let url = Bundle.main.url(forResource: preset, withExtension: "bin")
            ?? Bundle.main.url(forResource: preset, withExtension: "bin", subdirectory: "WatchFaces")
        return url.flatMap { try? Data(contentsOf: $0) }
    }

    private static var previewCache: [String: UIImage] = [:]

    /// Ảnh xem trước `<preset>.png` (320 × 320) trong bundle.
    static func preview(_ preset: String) -> UIImage? {
        if let cached = previewCache[preset] { return cached }
        let url = Bundle.main.url(forResource: preset, withExtension: "png")
            ?? Bundle.main.url(forResource: preset, withExtension: "png", subdirectory: "WatchFaces")
        guard let image = url.flatMap({ UIImage(contentsOfFile: $0.path) }) else { return nil }
        previewCache[preset] = image
        return image
    }

    /// Gọi sau khi một thiết bị vừa kết nối.
    func onConnected(_ device: WearableDevice) {
        guard let watch = device as? GloryFitDevice, autoApply(for: device.id), !running.contains(device.id) else { return }
        running.insert(device.id)
        Task {
            defer { running.remove(device.id) }
            await ensure(watch)
        }
    }

    private func ensure(_ watch: GloryFitDevice) async {
        let id = watch.id
        let preset = preset(for: id)
        do {
            try await Task.sleep(nanoseconds: 2_000_000_000) // để các lệnh lúc kết nối chạy xong trước
            guard watch.isConnected, autoApply(for: id), !isInstalling(id) else { return }
            let params = try await watch.queryDialParams()
            guard params.width == Self.size, params.height == Self.size else { return } // thư viện chỉ có bộ 466 × 466
            let active = params.currentId == Ute.customFaceId
            let pushed = pushed(for: id)
            if active, pushed == nil || pushed == preset {
                if pushed == nil { defaults.set(preset, forKey: key(id, "pushed")); revision += 1 }
                SmartWearLog.i("[\(watch.name)] mặt đồng hồ đã đúng, không cần cài lại")
                return
            }
            try await install(preset, on: watch, reason: active ? "mặt mặc định đã đổi" : "đồng hồ đang hiện mặt có sẵn")
        } catch {
            status[id] = "Tự cài mặt đồng hồ lỗi: \(error.localizedDescription)"
        }
    }

    /// Cài một bộ và đặt làm mặc định của đồng hồ.
    func install(_ preset: String, on watch: GloryFitDevice, reason: String? = nil) async throws {
        let id = watch.id
        guard let bin = Self.bin(preset) else { throw GloryFitError("Không thấy \(preset).bin trong app") }
        guard !isInstalling(id) else { throw GloryFitError("Đang cài một mặt khác, chờ xong rồi thử lại") }
        if let reason { SmartWearLog.i("[\(watch.name)] tự cài \(preset): \(reason)") }
        status[id] = (reason == nil ? "" : "Tự cài lại: ") + "Đang cài \(Self.presets.first { $0.id == preset }?.name ?? preset)…"
        progress[id] = 0
        defer { progress[id] = nil }
        do {
            try await watch.installWatchFaceFile(bin) { [weak self] p in
                Task { @MainActor in if self?.progress[id] != nil { self?.progress[id] = p } }
            }
        } catch {
            status[id] = "Cài mặt đồng hồ lỗi: \(error.localizedDescription)"
            throw error
        }
        defaults.set(preset, forKey: key(id, "pushed"))
        setPreset(preset, for: id)
        status[id] = (reason == nil ? "" : "Tự cài lại: ") + "Đã cài \(Self.presets.first { $0.id == preset }?.name ?? preset)"
    }
}
