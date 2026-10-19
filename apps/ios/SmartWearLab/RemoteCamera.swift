import AVFoundation
import Photos
import SmartWearCore
import SwiftUI

/// Chụp ảnh từ xa (bản iOS của `CameraActivity` GloryFit): mở màn chụp thì báo thiết bị (`setRemoteCamera(true)`, Y25
/// hiện nút chụp), bấm chụp trên thiết bị thì chụp bằng camera sau và lưu vào Ảnh. Như GloryFit, chỉ chụp khi màn chụp
/// đang mở; thiết bị tự mở màn chụp (`opened`) thì app mở theo.
@MainActor
@Observable
final class RemoteCamera {
    /// Thiết bị đang điều khiển; nil khi màn chụp đóng.
    private(set) var device: WearableDevice?
    /// Kết quả lần chụp gần nhất.
    var status: String?
    @ObservationIgnored let capture = CameraCapture()

    /// Gắn vào thiết bị vừa kết nối.
    func attach(_ device: WearableDevice) {
        guard device.supportsRemoteCamera else { return }
        device.onRemoteCamera = { [weak self, weak device] event in
            guard let self, let device else { return }
            switch event {
            case .opened: self.open(device)
            case .closed: if self.device === device { self.close(notify: false) }
            case .shutter: if self.device != nil { self.shoot() }
            }
        }
    }

    func open(_ device: WearableDevice) {
        self.device = device
        status = "Bấm nút chụp trên \(device.name)"
        Task { await device.setRemoteCamera(true) }
    }

    /// Đóng màn chụp; `notify` = báo thiết bị ẩn nút chụp (không cần khi chính thiết bị đóng).
    func close(notify: Bool = true) {
        if notify, let device { Task { await device.setRemoteCamera(false) } }
        device = nil
        status = nil
    }

    func shoot() {
        status = "Đang chụp…"
        capture.takePhoto { [weak self] result in
            Task { @MainActor in
                switch result {
                case .success: self?.status = "Đã lưu ảnh vào Ảnh lúc \(Date().formatted(date: .omitted, time: .standard))"
                case .failure(let e): self?.status = "Chụp lỗi: \(e.localizedDescription)"
                }
            }
        }
    }
}

/// Camera sau + chụp ảnh, lưu vào thư viện Ảnh (chỉ quyền thêm ảnh).
final class CameraCapture: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "smartwear.camera")
    private var configured = false
    private var completion: ((Result<Void, Error>) -> Void)?

    struct CameraError: LocalizedError {
        let errorDescription: String?
    }

    func start() {
        queue.async { [self] in
            if !configured {
                session.beginConfiguration()
                session.sessionPreset = .photo
                if let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                   let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) {
                    session.addInput(input)
                }
                if session.canAddOutput(output) { session.addOutput(output) }
                session.commitConfiguration()
                configured = true
            }
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        queue.async { [self] in if session.isRunning { session.stopRunning() } }
    }

    func takePhoto(_ done: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [self] in
            guard session.isRunning, !session.inputs.isEmpty else {
                return done(.failure(CameraError(errorDescription: "Camera chưa sẵn sàng (cấp quyền Camera trong Cài đặt)")))
            }
            completion = done
            output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let done = completion
        completion = nil
        if let error { return done?(.failure(error)) ?? () }
        guard let data = photo.fileDataRepresentation() else {
            return done?(.failure(CameraError(errorDescription: "Không đọc được ảnh"))) ?? ()
        }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                return done?(.failure(CameraError(errorDescription: "Chưa cho phép lưu vào Ảnh"))) ?? ()
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            } completionHandler: { ok, error in
                done?(ok ? .success(()) : .failure(error ?? CameraError(errorDescription: "Lưu ảnh lỗi")))
            }
        }
    }
}

/// Màn chụp ảnh từ xa toàn màn hình.
struct RemoteCameraView: View {
    let camera: RemoteCamera

    var body: some View {
        ZStack {
            CameraPreview(session: camera.capture.session).ignoresSafeArea()
            VStack {
                HStack {
                    Spacer()
                    GlassButton(title: nil, symbol: "xmark") { camera.close() }
                }
                .padding()
                Spacer()
                if let status = camera.status {
                    Text(status).font(.footnote).padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                Button { camera.shoot() } label: {
                    Circle().stroke(.white, lineWidth: 4).frame(width: 74, height: 74)
                        .overlay(Circle().fill(.white).padding(8))
                }
                .padding(.bottom, 30)
            }
        }
        .background(.black)
        .onAppear { camera.capture.start() }
        .onDisappear { camera.capture.stop() }
    }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
