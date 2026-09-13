import AppKit
import WebKit
import UniformTypeIdentifiers
import Darwin

/// 1回の描画で読むローカル画像を直列化し、同時読込によるメモリの膨張を抑える。
actor MinutesImageReader {
    private var remaining = 96 * 1_048_576
    func read(_ url: URL) throws -> Data {
        guard remaining > 0 else { throw CocoaError(.fileReadTooLarge) }
        let data = try MinutesResourceHandler.bytes(url, limit: min(24 * 1_048_576, remaining))
        remaining -= data.count
        return data
    }
}

/// 本文へファイルシステムのreadAccessを渡さず、同梱資産と画像だけを配信する。
/// パス切替ごとにhostを変え、前のページの遅い画像要求が次の議事録を読まないようにする。
@MainActor final class MinutesResourceHandler: NSObject, WKURLSchemeHandler {
    var context = UUID().uuidString.lowercased()
    var file: URL?
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var imageTasks: [ObjectIdentifier: WKURLSchemeTask] = [:]
    private var imageReader = MinutesImageReader()
    private var imagesActive = false
    static var assets: URL {
        let bundled = Bundle.main.url(forResource: "Kikigaki_Kikigaki", withExtension: "bundle").flatMap(Bundle.init(url:))
        return (bundled ?? Bundle.module).resourceURL!.appendingPathComponent("MinutesAssets")
    }
    func setFile(_ url: URL?) {
        guard file != url else { return }
        file = url; context = UUID().uuidString.lowercased()
        stop()
    }
    nonisolated static func imageFile(_ written: String, relativeTo file: URL) -> URL? {
        guard !written.isEmpty, !written.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        let url: URL
        if written.hasPrefix("file:///"), let value = URL(string: written), value.isFileURL { url = value }
        else if written.hasPrefix("/") || written.hasPrefix("~/") {
            url = URL(fileURLWithPath: (written as NSString).expandingTildeInPath)
        } else {
            guard URL(string: written)?.scheme == nil else { return nil }
            url = file.deletingLastPathComponent().appendingPathComponent(written)
        }
        let ext = url.pathExtension.lowercased()
        guard ["png", "jpg", "jpeg", "gif", "webp", "svg", "avif", "bmp", "tif", "tiff"].contains(ext) else { return nil }
        return url
    }
    nonisolated static func bytes(_ url: URL, limit: Int = 24 * 1_048_576) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= limit else { throw CocoaError(.fileReadCorruptFile) }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            try Task.checkCancellation()
            let count = read(fd, &buffer, buffer.count)
            if count == 0 { return data }
            if count < 0 { if errno == EINTR { continue }; throw CocoaError(.fileReadUnknown) }
            guard data.count <= limit - count else { throw CocoaError(.fileReadTooLarge) }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask)
        guard let request = urlSchemeTask.request.url else { return }
        let url: URL
        let mime: String
        if request.scheme == "minutes-app", request.host == "bundle" {
            let relative = request.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let candidate = Self.assets.appendingPathComponent(relative).standardizedFileURL
            guard candidate.path.hasPrefix(Self.assets.standardizedFileURL.path + "/"),
                  ["html", "js", "css", "woff", "woff2", "ttf"].contains(candidate.pathExtension) else {
                urlSchemeTask.didFailWithError(CocoaError(.fileReadNoPermission)); return
            }
            url = candidate
            mime = ["js": "text/javascript", "css": "text/css", "html": "text/html",
                    "woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf"][url.pathExtension]!
        } else if request.scheme == "minutes-image", imagesActive, request.host == context, let file,
                  let written = URLComponents(url: request, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "path" })?.value,
                  let image = Self.imageFile(written, relativeTo: file) {
            url = image; mime = UTType(filenameExtension: image.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        } else { urlSchemeTask.didFailWithError(CocoaError(.fileReadNoPermission)); return }
        let isImage = request.scheme == "minutes-image", reader = imageReader
        if isImage { imageTasks[key] = urlSchemeTask }
        tasks[key] = Task { [weak self] in
            let read = Task.detached(priority: .utility) {
                if isImage { return try await reader.read(url) }
                return try Self.bytes(url)
            }
            do {
                let data = try await withTaskCancellationHandler(operation: { try await read.value }, onCancel: { read.cancel() })
                guard !Task.isCancelled else { return }
                urlSchemeTask.didReceive(URLResponse(url: request, mimeType: mime, expectedContentLength: data.count, textEncodingName: nil))
                urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
            } catch {
                guard !Task.isCancelled else { return }
                urlSchemeTask.didFailWithError(error)
            }
            self?.tasks.removeValue(forKey: key)
            self?.imageTasks.removeValue(forKey: key)
        }
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        tasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
        imageTasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))
    }
    func stop() {
        imagesActive = false
        let stopping = imageTasks
        imageTasks.removeAll()
        for (key, request) in stopping {
            tasks.removeValue(forKey: key)?.cancel()
            // WebKit自身のstopではないため、待っている要求へ取消を返す。
            request.didFailWithError(URLError(.cancelled))
        }
    }
    func beginImages() {
        stop(); imageReader = MinutesImageReader(); context = UUID().uuidString.lowercased(); imagesActive = true
    }
}

@MainActor private final class MinutesMessageRelay: NSObject, WKScriptMessageHandler {
    weak var owner: MinutesWebView?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame else { return }
        owner?.receive(message.body)
    }
}

/// 議事録専用のWebKit。AIの返事行のTextKit描画とは寿命・幅・検索を共有しない。
@MainActor final class MinutesWebView: NSView, WKNavigationDelegate {
    private var loadedWebView: WKWebView?
    var hasLoadedWebView: Bool { loadedWebView != nil }
    var webView: WKWebView { loadWebView() }
    // WebKitは本文・リンク・余白のカーソルを自身で設定する。
    // 表示更新時のcursorUpdateを親へ渡すと、NSSplitViewの矢印で上書きされるため、
    // WebKitを包むここで伝播だけを止める。カーソルの形はアプリ側で設定しない。
    override func cursorUpdate(with event: NSEvent) {}
    private let resources = MinutesResourceHandler()
    private let relay = MinutesMessageRelay()
    private var ready = false
    private var pending: (String, Bool, Int)?
    /// WebKitは最初の本文描画まで作らない。描ける前の基準の置き直しは、次に描き終えた本文へ送る。
    private(set) var pendingBaseline = false
    private var ticket = 0
    private(set) var renderedText = ""
    var onRendered: ((String) -> Void)?
    var onError: ((String) -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        relay.owner = self
    }
    private func loadWebView() -> WKWebView {
        if let loadedWebView { return loadedWebView }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(resources, forURLScheme: "minutes-app")
        config.setURLSchemeHandler(resources, forURLScheme: "minutes-image")
        config.userContentController.add(relay, name: "minutes")
        let webView = WKWebView(frame: .zero, configuration: config)
        loadedWebView = webView
        webView.navigationDelegate = self
        webView.setAccessibilityLabel("議事録")
        addSubview(webView); webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor), webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor), webView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        webView.load(URLRequest(url: URL(string: "minutes-app://bundle/index.html")!))
        return webView
    }
    required init?(coder: NSCoder) { fatalError() }
    func setFile(_ url: URL?) { resources.setFile(url) }
    func render(_ source: String, reset: Bool) {
        ticket += 1; pending = (source, reset, ticket)
        _ = webView
        sendPending()
    }
    /// 強調の基準を今の本文へ置き直し、それまでの強調を消す。AIへの送信と編集の観測から呼ぶ。
    func markUpdateBaseline() {
        guard hasLoadedWebView, ready else { pendingBaseline = true; return }
        pendingBaseline = false
        webView.evaluateJavaScript("window.minutes.markBaseline()")
    }
    private func sendPending() {
        guard ready, let (source, reset, current) = pending else { return }
        pending = nil
        resources.beginImages()
        webView.callAsyncJavaScript("return await window.minutes.render(source, context, reset, ticket);",
            arguments: ["source": source, "context": resources.context, "reset": reset, "ticket": current],
            in: nil, in: .page) { [weak self] result in
                guard let self, self.ticket == current else { return }
                if case .failure = result { self.onError?("議事録を描画できません。再読込してください") }
                // 持ち越した基準は描き終えてから置く。描く前に置くと、対象切替の描画が基準を捨てる。
                // 中断された描画では消費せず、次に描き終えた描画で1回だけ置く。
                else if self.pendingBaseline { self.markUpdateBaseline() }
            }
    }
    fileprivate func receive(_ body: Any) {
        guard let value = body as? [String: Any], let kind = value["kind"] as? String else { return }
        switch kind {
        case "ready": ready = true; sendPending()
        case "focus":
            if !isHiddenOrHasHiddenAncestor, window?.firstResponder !== webView { window?.makeFirstResponder(webView) }
        case "rendered":
            guard value["ticket"] as? Int == ticket, let text = value["text"] as? String else { return }
            renderedText = text.trimmingCharacters(in: .newlines); onRendered?(renderedText)
        case "link":
            guard let href = value["href"] as? String, let url = URL(string: href),
                  ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return }
            NSWorkspace.shared.open(url)
        default: break
        }
    }
    func invalidate() {
        ticket += 1; pending = nil
        if ready { webView.evaluateJavaScript("window.minutes.invalidate()") }
        resources.stop()
    }
    func clear() {
        invalidate(); renderedText = ""; pendingBaseline = false
        if ready { webView.evaluateJavaScript("window.minutes.clear()") }
    }
    func search(_ query: String, direction: Int = 0, reveal: Bool = true, completion: @escaping (Int, Int) -> Void) {
        guard ready else { completion(0, 0); return }
        webView.callAsyncJavaScript("return window.minutes.search(query, direction, reveal);",
            arguments: ["query": query, "direction": direction, "reveal": reveal], in: nil, in: .page) { result in
                if case .success(let data as [String: Any]) = result {
                    completion(data["current"] as? Int ?? 0, data["count"] as? Int ?? 0)
                } else { completion(0, 0) }
            }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // 本文内のリンクは専用messageで人のクリックだけを扱う。別HTMLの読み込みは許可しない。
        decisionHandler(navigationAction.request.url?.absoluteString == "minutes-app://bundle/index.html" ? .allow : .cancel)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ready = false; onError?("議事録の表示が終了しました。再読込してください")
        webView.load(URLRequest(url: URL(string: "minutes-app://bundle/index.html")!))
    }
}
