import AudioToolbox
import SmartWearCore
import SwiftUI

/// Đồng hồ/vòng bấm "tìm điện thoại": phát âm báo + rung lặp lại tối đa 30 giây (bản iOS của `FindPhoneRinger` Android),
/// dừng khi thiết bị báo dừng hoặc người dùng bấm "Đã tìm thấy". Chỉ kêu khi app đang chạy (iOS không cho phát âm thanh
/// tuỳ ý ở nền). Báo thiết bị lúc bắt đầu và lúc dừng (`setPhoneRinging`) để đồng hồ tắt màn "đang tìm điện thoại".
@MainActor
@Observable
final class FindPhoneRinger {
    /// Tên thiết bị đang tìm điện thoại, nil khi không đổ chuông.
    private(set) var ringing: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Thiết bị đang tìm điện thoại.
    @ObservationIgnored private weak var source: WearableDevice?

    /// Gắn vào thiết bị vừa kết nối.
    func attach(_ device: WearableDevice) {
        device.onFindPhone = { [weak self, weak device] on in
            guard let self else { return }
            if on { self.ring(device) } else { self.stop() }
        }
    }

    func ring(_ device: WearableDevice?) {
        let name = device?.name ?? "Thiết bị"
        SmartWearLog.i("[\(name)] tìm điện thoại")
        ringing = name
        source = device
        if let device { Task { await device.setPhoneRinging(true) } }
        task?.cancel()
        task = Task { [weak self] in
            let until = Date().addingTimeInterval(30)
            while !Task.isCancelled, Date() < until {
                AudioServicesPlayAlertSound(SystemSoundID(1005))
                AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
            if !Task.isCancelled { self?.stop() }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        ringing = nil
        if let device = source {
            source = nil
            Task { await device.setPhoneRinging(false) }
        }
    }
}
