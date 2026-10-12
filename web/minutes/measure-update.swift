// 使用例: KIKIGAKI_DIAGRAM_UPDATE_CAPTURE=/tmp/kikigaki-diagram-update/after.json swift web/minutes/measure-update.swift
// swift test内で進まない実requestAnimationFrameを、非永続WKWebViewのアプリイベントループで測る。
import AppKit
import WebKit

@MainActor final class UpdateMeasurement: NSObject, WKURLSchemeHandler, WKScriptMessageHandler {
    let assets: URL
    let observer: String
    let output: URL
    var web: WKWebView!
    var window: NSWindow!
    var started = false

    init(output: URL) throws {
        self.output = output
        let directory = URL(fileURLWithPath:#filePath).deletingLastPathComponent()
        if let path = ProcessInfo.processInfo.environment["KIKIGAKI_DIAGRAM_UPDATE_ASSETS"] {
            let custom = URL(fileURLWithPath:path).standardizedFileURL
            guard custom.path.hasPrefix("/tmp/") || custom.path.hasPrefix("/private/tmp/") else { throw CocoaError(.fileReadNoPermission) }
            assets = custom
        } else { assets = directory.appendingPathComponent("../../Sources/Kikigaki/MinutesAssets").standardizedFileURL }
        observer = try String(contentsOf:directory.appendingPathComponent("observe-update.js"),encoding:.utf8)
        super.init()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(self,forURLScheme:"minutes-app")
        config.userContentController.add(self,name:"minutes")
        web = WKWebView(frame:NSRect(x:0,y:0,width:900,height:850),configuration:config)
        web.allowsMagnification = false
        window = NSWindow(contentRect:web.frame,styleMask:[.titled],backing:.buffered,defer:false)
        window.title = "図更新の使い捨て計測"
        window.contentView = web; window.makeKeyAndOrderFront(nil)
        web.load(URLRequest(url:URL(string:"minutes-app://preview/index.html")!))
    }
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        do {
            let file = assets.appendingPathComponent(task.request.url!.path.trimmingCharacters(in:CharacterSet(charactersIn:"/"))).standardizedFileURL
            guard file.path.hasPrefix(assets.path + "/") else { throw CocoaError(.fileReadNoPermission) }
            let data = try Data(contentsOf:file)
            let mime = ["html":"text/html","css":"text/css","js":"application/javascript","woff2":"font/woff2","woff":"font/woff"][file.pathExtension] ?? "application/octet-stream"
            task.didReceive(URLResponse(url:task.request.url!,mimeType:mime,expectedContentLength:data.count,textEncodingName:"utf-8"))
            task.didReceive(data); task.didFinish()
        } catch { task.didFailWithError(error) }
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard !started, (message.body as? [String:Any])?["kind"] as? String == "ready" else { return }
        started = true
        Task { @MainActor in
            do {
                _ = try await web.evaluateJavaScript(observer)
                var results: [[String:Any]] = []
                let graph = "```mermaid\nflowchart TB\n" + (1...60).map { "T\($0)[\"T\($0) 更新前の論点\"]" }.joined(separator:"\n") + "\n" + (1..<60).filter { $0 % 6 != 0 }.map { "T\($0) --> T\($0+1)" }.joined(separator:"\n") + "\n```"
                let other = "\n## 補足\n```mermaid\nmindmap\n  root((更新前))\n    選択肢\n    判断\n```\n```mermaid\ntimeline\n  10時 : 更新前\n  11時 : 確認\n```"
                for board in [true,false] {
                    for scale in [1,2] {
                        web.pageZoom = CGFloat(scale)
                        let source = graph + (board ? "" : other)
                        _ = try await web.callAsyncJavaScript("window.minutes.setTextScale(scale); return await window.minutes.render(source,'test',true,1,null,board,board)",arguments:["source":source,"board":board,"scale":scale],contentWorld:.page)
                        // 初期表示を実フレームへ載せてから更新を始める。
                        _ = try await web.callAsyncJavaScript("await new Promise(requestAnimationFrame); await new Promise(requestAnimationFrame); return true",arguments:[:],contentWorld:.page)
                        let next = source.replacingOccurrences(of:"更新前",with:"更新後")
                        var result = try await web.callAsyncJavaScript("return await observeDiagramUpdate(source,board)",arguments:["source":next,"board":board],contentWorld:.page) as! [String:Any]
                        result["board"] = board; result["scale"] = scale
                        results.append(result)
                        print("計測: \(board ? "ボード" : "議事録3図") \(scale*100)% \(result)")
                    }
                }
                try FileManager.default.createDirectory(at:output.deletingLastPathComponent(),withIntermediateDirectories:true)
                try JSONSerialization.data(withJSONObject:results,options:[.prettyPrinted,.sortedKeys]).write(to:output)
                print("保存: \(output.path)")
                NSApp.terminate(nil)
            } catch { fputs("計測失敗: \(error)\n",stderr); exit(1) }
        }
    }
}

guard let path = ProcessInfo.processInfo.environment["KIKIGAKI_DIAGRAM_UPDATE_CAPTURE"] else { exit(0) }
let output = URL(fileURLWithPath:path).standardizedFileURL
guard output.path.hasPrefix("/tmp/") || output.path.hasPrefix("/private/tmp/") else { exit(1) }
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let measurement = try MainActor.assumeIsolated { try UpdateMeasurement(output:output) }
app.activate(ignoringOtherApps:true)
DispatchQueue.main.asyncAfter(deadline:.now()+60) { fputs("計測が60秒で終了しませんでした\n",stderr); exit(1) }
app.run()
