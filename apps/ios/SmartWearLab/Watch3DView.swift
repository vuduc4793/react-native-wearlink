import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Mô hình 3D đồng hồ Y25 (Three.js, `apps/shared/watch3d`, dùng chung với Android; thư mục `watch3d` trong bundle) tự xoay trên nền trong suốt.
/// Phục vụ file qua scheme riêng `watch3d://`: WKWebView chặn `<script type="module">` khi mở thẳng từ file://.
struct Watch3DView: UIViewRepresentable {
    /// Thư mục mô hình trong `watch3d/` (vd "y25", "ht43").
    var model = "y25"

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(BundleSchemeHandler(folder: "watch3d"), forURLScheme: BundleSchemeHandler.scheme)
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        if let url = URL(string: "\(BundleSchemeHandler.scheme)://app/\(model)/index.html") { web.load(URLRequest(url: url)) }
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}
}

/// Trả file trong một thư mục của bundle cho WKWebView.
private final class BundleSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "watch3d"
    private let root: URL?

    init(folder: String) {
        root = Bundle.main.resourceURL?.appendingPathComponent(folder, isDirectory: true)
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let root, let url = task.request.url else { return fail(task) }
        let path = url.path.isEmpty || url.path == "/" ? "index.html" : String(url.path.dropFirst())
        let file = root.appendingPathComponent(path).standardizedFileURL
        // Chỉ trả file nằm trong thư mục gốc.
        guard file.path.hasPrefix(root.standardizedFileURL.path), let data = try? Data(contentsOf: file) else { return fail(task) }
        let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType
            ?? (file.pathExtension == "js" ? "text/javascript" : "application/octet-stream")
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": mime, "Content-Length": "\(data.count)"])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private func fail(_ task: WKURLSchemeTask) {
        task.didFailWithError(URLError(.fileDoesNotExist))
    }
}
