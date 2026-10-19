import ContactsUI
import SmartWearCore
import SmartWearGloryFit
import SwiftUI

/// Gọi điện qua đồng hồ (Bluetooth cổ điển) + danh bạ, cho đồng hồ GloryFit có `isHasBluetooth3` / `isHasContact`.
/// Kênh gọi phải ghép một lần trong Cài đặt → Bluetooth của iPhone (iOS không cho app tự ghép thiết bị âm thanh).
/// Danh bạ: người dùng chọn liên hệ bằng khung chọn của iOS (app chỉ thấy liên hệ được chọn, không cần quyền Danh bạ).
struct CallContactsCard: View {
    let watch: GloryFitDevice
    @State private var call: CallBluetoothState?
    @State private var callError: String?
    @State private var picking = false
    @State private var status: String?
    @State private var busy = false

    init?(_ device: WearableDevice) {
        guard let g = device as? GloryFitDevice, g.supportsCallBluetooth || g.supportsContacts else { return nil }
        watch = g
    }

    private static let green = Color(hex: 0x30D158)
    private var connected: Bool { watch.state == .connected }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: "Gọi điện & danh bạ")
            VStack(alignment: .leading, spacing: 12) {
                notificationsRow
                Divider().overlay(Color.white.opacity(0.08))
                if watch.supportsCallBluetooth { callRow }
                if watch.supportsCallBluetooth && watch.supportsContacts { Divider().overlay(Color.white.opacity(0.08)) }
                if watch.supportsContacts { contactsRow }
            }
            .padding(16)
            .card()
        }
        .task(id: watch.state) { await refresh() }
        .sheet(isPresented: $picking) {
            ContactPicker { contacts in
                picking = false
                Task { await send(contacts) }
            } onCancel: { picking = false }
        }
    }

    private var callRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Gọi điện, Siri qua đồng hồ").font(.subheadline.weight(.semibold))
                    Text(callText).font(.caption).foregroundStyle(call?.connected == true ? Self.green : Palette.secondary)
                }
                Spacer()
                GlassButton(title: nil, symbol: "arrow.clockwise") { Task { await refresh() } }
            }
            if let call, !call.paired || !call.connected {
                Text("Mở Cài đặt → Bluetooth trên iPhone, chọn \"\(call.name)\" ở mục Thiết bị khác → Ghép đôi, cho phép đồng bộ danh bạ. Chỉ cần làm một lần.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    /// Thông báo app + cuộc gọi đến trên iOS đi qua ANCS (đồng hồ tự đọc từ iPhone, app không gửi gì), như app GloryFit iOS.
    private var notificationsRow: some View {
        let authorized = watch.ancsAuthorized
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Thông báo & cuộc gọi đến").font(.subheadline.weight(.semibold))
                    Text(authorized == true ? "Đồng hồ đang nhận thông báo và cuộc gọi của iPhone"
                         : authorized == false ? "iOS chưa cho đồng hồ đọc thông báo" : "Kết nối đồng hồ để xem trạng thái")
                        .font(.caption).foregroundStyle(authorized == true ? Self.green : Palette.secondary)
                }
                Spacer()
            }
            if authorized == false {
                Text("Mở Cài đặt → Bluetooth, bấm (i) cạnh \"\(watch.name)\" → bật \"Chia sẻ thông báo hệ thống\". Từ chối cuộc gọi trên đồng hồ cũng đi qua đường này.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var callText: String {
        if let callError { return "Lỗi: \(callError)" }
        guard let call else { return connected ? "Đang đọc trạng thái…" : "Kết nối đồng hồ để xem trạng thái" }
        if !call.enabled { return "Kênh gọi đang tắt trên đồng hồ" }
        if call.connected { return "Đang kết nối với iPhone (\(call.name))" }
        if call.paired { return "Đã ghép, chưa kết nối — bật Bluetooth iPhone / mở Cài đặt → Bluetooth" }
        return "Chưa ghép với iPhone"
    }

    private var contactsRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Danh bạ trên đồng hồ").font(.subheadline.weight(.semibold))
                Text(status ?? "Chọn tối đa \(UteContacts.maxContacts(watch.features)) liên hệ; thay toàn bộ danh bạ trên đồng hồ")
                    .font(.caption).foregroundStyle(Palette.secondary)
            }
            Spacer()
            GlassButton(title: busy ? "Đang gửi…" : "Chọn", symbol: "person.crop.circle.badge.plus") { picking = true }
                .opacity(connected && !busy ? 1 : 0.4)
                .disabled(!connected || busy)
        }
    }

    private func refresh() async {
        guard watch.supportsCallBluetooth, connected else { return }
        do {
            call = try await watch.callBluetoothState()
            callError = nil
        } catch {
            callError = error.localizedDescription
        }
    }

    private func send(_ picked: [CNContact]) async {
        let list = picked.compactMap { c -> UteContacts.Contact? in
            let number = (c.phoneNumbers.first { $0.label == CNLabelPhoneNumberMobile } ?? c.phoneNumbers.first)?.value.stringValue
            guard let number else { return nil }
            let name = CNContactFormatter.string(from: c, style: .fullName) ?? number
            return UteContacts.Contact(name: name, phone: number)
        }
        guard !list.isEmpty else { status = "Các liên hệ đã chọn không có số điện thoại"; return }
        busy = true
        defer { busy = false }
        do {
            let n = try await watch.syncContacts(list) { p in status = "Đang gửi \(Int(p * 100)) %" }
            status = "Đã gửi \(n) liên hệ lúc \(Date().formatted(date: .omitted, time: .shortened))"
        } catch {
            status = "Lỗi: \(error.localizedDescription)"
        }
    }
}

/// Khung chọn nhiều liên hệ của iOS (không cần quyền Danh bạ).
struct ContactPicker: UIViewControllerRepresentable {
    var onSelect: ([CNContact]) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let vc = CNContactPickerViewController()
        vc.delegate = context.coordinator
        vc.displayedPropertyKeys = [CNContactPhoneNumbersKey]
        vc.predicateForEnablingContact = NSPredicate(format: "phoneNumbers.@count > 0")
        return vc
    }

    func updateUIViewController(_ vc: CNContactPickerViewController, context: Context) {}

    final class Coordinator: NSObject, CNContactPickerDelegate {
        let parent: ContactPicker
        init(_ parent: ContactPicker) { self.parent = parent }
        func contactPicker(_ picker: CNContactPickerViewController, didSelect contacts: [CNContact]) { parent.onSelect(contacts) }
        func contactPickerDidCancel(_ picker: CNContactPickerViewController) { parent.onCancel() }
    }
}
