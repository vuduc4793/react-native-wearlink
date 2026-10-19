import SmartWearCore
import SmartWearGloryFit
import SwiftUI

/// Thư viện mặt đồng hồ dựng sẵn: chọn một bộ để cài, bộ vừa cài thành mặt mặc định (tự cài lại khi kết nối).
/// Cùng ý với `WatchFaceLibrarySection` Android.
struct WatchFaceLibrarySection: View {
    @Environment(AppState.self) private var app
    let device: GloryFitDevice
    @State private var selectedId: String?
    @State private var result: String?

    private static let orange = Color(hex: 0xFF9F0A)

    init(device: GloryFitDevice) { self.device = device }

    /// Chỉ có với đồng hồ GloryFit (nil với thiết bị khác), để màn chi tiết chèn thẳng `WatchFaceLibrarySection(device)`.
    init?(_ device: WearableDevice) {
        guard let watch = device as? GloryFitDevice else { return nil }
        self.device = watch
    }

    var body: some View {
        let store = app.watchFaces
        let _ = store.revision // đọc lại UserDefaults mỗi lần store lưu
        let current = store.preset(for: device.id)
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: "Thư viện", trailing: "\(WatchFaceStore.presets.count) mặt · \(WatchFaceStore.size) × \(WatchFaceStore.size)")
            ScrollView(.horizontal) {
                HStack(spacing: 14) {
                    ForEach(WatchFaceStore.presets) { p in thumbnail(p, isDefault: current == p.id) }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)

            if let preset = WatchFaceStore.find(selectedId) {
                detail(preset, isDefault: current == preset.id, store: store)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else if let status = store.status[device.id] {
                Text(status).font(.footnote).foregroundStyle(Palette.secondary)
            }

            Toggle(isOn: Binding(
                get: { store.autoApply(for: device.id) },
                set: { store.setAutoApply($0, for: device.id) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tự cài lại khi kết nối").font(.subheadline.weight(.semibold))
                    Text("Cài lại mặt mặc định nếu đồng hồ đã đổi sang mặt khác").font(.caption).foregroundStyle(Palette.secondary)
                }
            }
            .tint(Color(hex: 0x30D158))
            .padding(.horizontal, 4)
        }
        .onChange(of: device.id) {
            selectedId = nil
            result = nil
        }
    }

    // MARK: - Hàng ảnh thu nhỏ

    private func thumbnail(_ p: WatchFaceStore.Preset, isDefault: Bool) -> some View {
        let isSelected = selectedId == p.id
        return Button {
            withAnimation(.snappy) { selectedId = isSelected ? nil : p.id }
            result = nil
        } label: {
            VStack(spacing: 4) {
                FaceThumb(preset: p.id, size: 88)
                    .padding(4)
                    .overlay {
                        Circle().stroke(isSelected ? .white : (isDefault ? Self.orange : .clear), lineWidth: 2)
                    }
                    .padding(.bottom, 2)
                Text(p.name).font(.footnote).foregroundStyle(.white).lineLimit(1)
                Text(isDefault ? "Mặc định" : " ").font(.footnote).foregroundStyle(isDefault ? Self.orange : Palette.tertiary).lineLimit(1)
            }
            .frame(width: 104)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Thẻ chi tiết

    private func detail(_ preset: WatchFaceStore.Preset, isDefault: Bool, store: WatchFaceStore) -> some View {
        let progress = store.progress[device.id]
        let message = result ?? store.status[device.id]
        return VStack(spacing: 0) {
            FaceThumb(preset: preset.id, size: 220)
            Text(preset.name).font(.headline).padding(.top, 12)
            Text(preset.note).font(.footnote).foregroundStyle(Palette.secondary)
                .multilineTextAlignment(.center).padding(.top, 2)
            Group {
                if let progress {
                    VStack(spacing: 8) {
                        Text("Đang cài · \(Int(progress * 100)) %").font(.callout).monospacedDigit()
                        ProgressView(value: min(max(progress, 0), 1))
                            .progressViewStyle(.linear)
                            .tint(.white)
                    }
                } else {
                    PrimaryButton(
                        title: isDefault ? "Cài lại lên đồng hồ" : "Cài và đặt làm mặc định",
                        symbol: "applewatch",
                        enabled: device.isConnected
                    ) { install(preset, store: store) }
                }
            }
            .padding(.top, 14)
            if !device.isConnected, progress == nil {
                Text("Kết nối đồng hồ để cài.").font(.footnote).foregroundStyle(Palette.tertiary).padding(.top, 8)
            }
            if let message {
                Text(message).font(.footnote).foregroundStyle(Palette.secondary)
                    .multilineTextAlignment(.center).padding(.top, 10)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .glass(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private func install(_ preset: WatchFaceStore.Preset, store: WatchFaceStore) {
        result = nil
        let watch = device
        Task {
            do {
                try await store.install(preset.id, on: watch)
                result = "Đã cài \(preset.name)."
                    + (store.autoApply(for: watch.id) ? " Mỗi lần kết nối, app tự cài lại nếu đồng hồ đổi mặt." : "")
            } catch {
                result = "Không cài được: \(error.localizedDescription)"
            }
        }
    }
}

/// Ảnh xem trước tròn của một bộ; chưa có ảnh thì là vòng kính trống.
private struct FaceThumb: View {
    let preset: String
    let size: CGFloat

    var body: some View {
        Group {
            if let image = WatchFaceStore.preview(preset) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Circle().fill(Palette.card)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}
