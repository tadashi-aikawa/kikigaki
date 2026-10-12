// 使用例: KIKIGAKI_BOARD_PERF_CAPTURE=/tmp/kikigaki-board-performance/before.json swift web/minutes/measure-canvas.swift
// swift testでは実rAFが進まないため、独立した非永続WKWebViewのアプリイベントループで計測する。
import AppKit
import WebKit

@MainActor final class CanvasMeasurement: NSObject, WKURLSchemeHandler, WKScriptMessageHandler {
    let assets: URL
    let script: String
    let output: URL
    var web: WKWebView!
    var window: NSWindow!
    var started = false

    init(output: URL) throws {
        self.output = output
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        if let path = ProcessInfo.processInfo.environment["KIKIGAKI_BOARD_PERF_ASSETS"] {
            let custom = URL(fileURLWithPath: path).standardizedFileURL
            guard custom.path.hasPrefix("/tmp/") || custom.path.hasPrefix("/private/tmp/") else { throw CocoaError(.fileReadNoPermission) }
            assets = custom
        } else { assets = directory.appendingPathComponent("../../Sources/Kikigaki/MinutesAssets").standardizedFileURL }
        script = try String(contentsOf: directory.appendingPathComponent("measure-canvas.js"), encoding: .utf8)
        super.init()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(self, forURLScheme: "minutes-app")
        config.userContentController.add(self, name: "minutes")
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 850), configuration: config)
        window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "ボード入力の使い捨て計測"
        window.contentView = web
        window.makeKeyAndOrderFront(nil)
        web.load(URLRequest(url: URL(string: "minutes-app://preview/index.html")!))
    }
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        do {
            let url = task.request.url!
            let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let file = assets.appendingPathComponent(path).standardizedFileURL
            guard file.path.hasPrefix(assets.path + "/") else { throw CocoaError(.fileReadNoPermission) }
            let data = try Data(contentsOf: file)
            let mime = ["html": "text/html", "css": "text/css", "js": "application/javascript", "woff2": "font/woff2", "woff": "font/woff"][file.pathExtension] ?? "application/octet-stream"
            task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: "utf-8"))
            task.didReceive(data); task.didFinish()
        } catch { task.didFailWithError(error) }
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !started, (message.body as? [String: Any])?["kind"] as? String == "ready" else { return }
        started = true
        Task { @MainActor in
            do {
                var results: [[String: Any]] = []
                for count in [30, 60] {
                    let nodes = (1...count).map { "T\($0)[\"T\($0) 論点の確認と運用の判断\"]" }
                    let edges = (1...count).filter { $0 % 6 != 0 }.map { "T\($0) --> T\($0+1)" }
                    let source = "```mermaid\nflowchart TB\n" + (nodes + edges).joined(separator: "\n") + "\n```"
                    _ = try await web.callAsyncJavaScript("return await window.minutes.render(source,'test',true,1,null,true,true)", arguments: ["source": source], contentWorld: .page)
                    for input in ["scroll", "drag", "pinch"] {
                        guard let result = try await web.callAsyncJavaScript(script, arguments: ["count": count, "input": input], contentWorld: .page) as? [String: Any] else {
                            throw CocoaError(.coderReadCorrupt)
                        }
                        results.append(result)
                        print("計測: \(count)ノード \(input)")
                    }
                }
                try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]).write(to: output)
                print("保存: \(output.path)")
                NSApp.terminate(nil)
            } catch { fputs("計測失敗: \(error)\n", stderr); exit(1) }
        }
    }
}

guard let path = ProcessInfo.processInfo.environment["KIKIGAKI_BOARD_PERF_CAPTURE"] else { exit(0) }
let output = URL(fileURLWithPath: path).standardizedFileURL
guard output.path.hasPrefix("/tmp/") || output.path.hasPrefix("/private/tmp/") else { exit(1) }
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let measurement = try MainActor.assumeIsolated { try CanvasMeasurement(output: output) }
app.activate(ignoringOtherApps: true)
DispatchQueue.main.asyncAfter(deadline: .now() + 60) { fputs("計測が60秒で終了しませんでした\n", stderr); exit(1) }
app.run()
