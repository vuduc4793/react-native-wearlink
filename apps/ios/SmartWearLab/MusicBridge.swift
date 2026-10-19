import AVFoundation
import MediaPlayer
import SmartWearCore

/// Nút nhạc trên đồng hồ ↔ trình phát iPhone (`MusicRemote` của core). Giới hạn iOS: app KHÔNG điều khiển được trình
/// phát của app khác (Spotify, YouTube…) và không đọc được bài họ đang phát. Ở đây dùng `systemMusicPlayer` = app Nhạc
/// (Apple Music / nhạc trong máy): phát/tạm dừng/bài sau/bài trước và tên bài. Âm lượng: app không đặt được âm lượng hệ
/// thống, nên `VOLUME_UP/DOWN` chỉ ghi nhận; âm lượng hiện tại (`AVAudioSession.outputVolume`) vẫn gửi lên đồng hồ.
/// Khi đồng hồ đã ghép Bluetooth cổ điển, nút nhạc có thể đi thẳng qua AVRCP (hệ thống lo, chưa kiểm).
@MainActor
@Observable
final class MusicBridge {
    /// Lệnh / trạng thái gần nhất, để hiển thị.
    private(set) var status: [UUID: String] = [:]
    @ObservationIgnored private var devices: [UUID: WeakDevice] = [:]
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var volumeObservation: NSKeyValueObservation?
    @ObservationIgnored private var started = false
    private let player = MPMusicPlayerController.systemMusicPlayer

    private struct WeakDevice { weak var device: WearableDevice? }

    func attach(_ device: WearableDevice) {
        if device.supportsRejectCall {
            // iOS không cho app cúp cuộc gọi di động: chỉ ghi nhận (ANCS lo việc từ chối khi đã ghép đôi).
            device.onRejectCall = { [weak self, weak device] in
                guard let device else { return }
                self?.status[device.id] = "Đồng hồ bấm từ chối cuộc gọi (iOS: app không cúp được, ANCS xử lý)"
            }
        }
        guard device.supportsMusicControl else { return }
        devices[device.id] = WeakDevice(device: device)
        device.onMusicCommand = { [weak self, weak device] cmd in
            guard let self, let device else { return }
            self.handle(cmd, from: device)
        }
        startObserving()
        Task { await push(to: device) }
    }

    private func handle(_ cmd: MusicCommand, from device: WearableDevice) {
        switch cmd {
        case .playPause: player.playbackState == .playing ? player.pause() : player.play()
        case .next: player.skipToNextItem()
        case .previous: player.skipToPreviousItem()
        case .volumeUp, .volumeDown: break // iOS không cho app đặt âm lượng hệ thống.
        }
        status[device.id] = "Đồng hồ: \(Self.label(cmd))"
    }

    private static func label(_ cmd: MusicCommand) -> String {
        switch cmd {
        case .playPause: "phát / tạm dừng (app Nhạc)"
        case .next: "bài sau (app Nhạc)"
        case .previous: "bài trước (app Nhạc)"
        case .volumeUp: "tăng âm lượng (iOS không cho app đổi)"
        case .volumeDown: "giảm âm lượng (iOS không cho app đổi)"
        }
    }

    private func startObserving() {
        guard !started else { return }
        started = true
        player.beginGeneratingPlaybackNotifications()
        let center = NotificationCenter.default
        for name in [Notification.Name.MPMusicPlayerControllerNowPlayingItemDidChange, .MPMusicPlayerControllerPlaybackStateDidChange] {
            observers.append(center.addObserver(forName: name, object: player, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.pushAll() }
            })
        }
        volumeObservation = AVAudioSession.sharedInstance().observe(\.outputVolume) { [weak self] session, _ in
            let percent = Int((session.outputVolume * 100).rounded())
            Task { @MainActor in
                guard let self else { return }
                for d in self.connected() { await d.setMusicVolume(percent) }
            }
        }
    }

    private func connected() -> [WearableDevice] {
        devices.values.compactMap(\.device).filter { $0.state == .connected && $0.supportsMusicControl }
    }

    private func pushAll() async {
        for d in connected() { await push(to: d) }
    }

    /// Trạng thái + bài đang phát của app Nhạc (tên bài cần quyền thư viện nhạc; không có thì chỉ gửi trạng thái).
    private func push(to device: WearableDevice) async {
        guard device.state == .connected else { return }
        let item = player.nowPlayingItem
        await device.setMusicState(MusicState(
            playing: player.playbackState == .playing, title: item?.title, artist: item?.artist,
            durationSec: item.map { Int($0.playbackDuration) }, positionSec: Int(player.currentPlaybackTime.isFinite ? player.currentPlaybackTime : 0)
        ))
    }
}
