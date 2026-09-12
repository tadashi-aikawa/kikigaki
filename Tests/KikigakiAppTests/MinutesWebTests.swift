import AppKit
import WebKit
import Darwin
import Testing
@testable import Kikigaki

@Suite(.serialized) @MainActor struct MinutesWebTests {
    @Test func 検索メニューはWebKit本文から議事録ペインへ届く() async throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = TranscriptWindowController(minutesDefaults: defaults)
        controller.window?.setFrameAutosaveName("")
        controller.show()
        if !controller.minutesSplit.isPreviewVisible { controller.toggleMinutes() }
        defer { controller.minutesSplit.preview.stop(); controller.window?.orderOut(nil) }
        let preview = controller.minutesSplit.preview
        #expect(controller.window?.makeFirstResponder(preview.document.webView) == true)
        let menu = ApplicationMenu.make()
        let edit = try #require(menu.items.first { $0.submenu?.title == "編集" }?.submenu)
        let action = try #require(edit.items.first { $0.keyEquivalent == "f" }?.action)
        // 非アクティブなテストプロセスでも、本文から実際のresponder chainをたどる。
        #expect(preview.document.webView.tryToPerform(action, with: nil))
        #expect(preview.searchField.currentEditor() != nil)
        #expect(!controller.searchOpen)
    }
    private func wait(_ condition: () async throws -> Bool) async throws {
        for _ in 0..<500 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("WebKitの表示が完了しません")
    }
    @Test func HTMLの安全境界と折りたたみ脚注画像目次を組み合わせる() async throws {
        let preview = MinutesPreviewView(frame: NSRect(x: 0, y: 0, width: 700, height: 600))
        let window = NSWindow(contentRect: preview.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = preview; window.orderFront(nil); preview.layoutSubtreeIfNeeded()
        defer { preview.stop(); window.orderOut(nil) }
        let fixture = """
        # 親

        ## 長い見出しで幅を測る対象

        隠れる本文[^one]。

        <span style="color:red;position:fixed;inset:0;background-image:url(https://example.invalid/evil);margin:-20px" onclick="window.INJECTED=true">赤いHTML</span>

        <div id="toc" class="heading-toggle" style="padding:8px;border:1px solid purple">HTMLの箱</div>

        <script>window.INJECTED=true</script>
        <iframe src="https://example.invalid"></iframe>
        <form><input autofocus onfocus="window.INJECTED=true"></form>
        <style>body{display:none}</style>

        :::{note}
        MySTの**本文**。
        :::

        ## 次の節

        次の本文。

        ~~~svg
        <svg xmlns="http://www.w3.org/2000/svg" width="100" height="50"><rect width="100" height="50" fill="purple"/></svg>
        ~~~

        [^one]: 着地点の脚注。
        """
        preview.document.render(fixture, reset: true)
        try await wait { preview.document.renderedText.contains("着地点の脚注") }
        let web = preview.document.webView
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('main script,main iframe,main form,main style,main [onclick]').length === 0 && !window.INJECTED") as? Bool == true)
        #expect(try await web.evaluateJavaScript("document.querySelector('main span[style]').style.color === 'red' && !document.querySelector('main span[style]').style.position && !document.querySelector('main span[style]').style.backgroundImage && !document.querySelector('main span[style]').style.margin") as? Bool == true)
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('#toc').length === 1 && document.getElementById('html-toc').className === ''") as? Bool == true)
        #expect(try await web.evaluateJavaScript("document.querySelector('.callout strong').textContent === '本文' && !!document.querySelector('.callout-title svg')") as? Bool == true)
        let closedWidth = try #require(try await web.evaluateJavaScript("document.getElementById('toc').getBoundingClientRect().width") as? Double)
        _ = try await web.evaluateJavaScript("document.querySelector('#toc summary').click()")
        #expect(try await web.evaluateJavaScript("document.getElementById('toc').getBoundingClientRect().width") as? Double == closedWidth)
        _ = try await web.evaluateJavaScript("document.querySelectorAll('.heading-toggle')[1].click()")
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('.section-body')[1].hidden && document.querySelectorAll('.section-body')[2].hidden === false") as? Bool == true)
        _ = try await web.evaluateJavaScript("window.minutes.search('隠れる本文')")
        #expect(try await web.evaluateJavaScript("!document.querySelectorAll('.section-body')[1].hidden") as? Bool == true)
        _ = try await web.evaluateJavaScript("document.querySelector('.footnote-ref a').click()")
        #expect(try await web.evaluateJavaScript("document.getElementById('fn1').getAnimations().length === 1") as? Bool == true)
        _ = try await web.evaluateJavaScript("document.querySelectorAll('.heading-toggle')[1].click(); document.querySelector('.footnote-backref').click()")
        #expect(try await web.evaluateJavaScript("!document.querySelectorAll('.section-body')[1].hidden && document.querySelector('.footnote-ref').getAnimations().length === 1") as? Bool == true)
        try await wait { try await web.evaluateJavaScript("document.querySelector('main img').naturalWidth > 0") as? Bool == true }
        _ = try await web.evaluateJavaScript("document.querySelector('main img').click()")
        #expect(try await web.evaluateJavaScript("document.getElementById('image-modal').open && document.querySelector('#image-modal img').src === document.querySelector('main img').src") as? Bool == true)
        _ = try await web.evaluateJavaScript("document.querySelector('#image-modal button').click(); document.querySelectorAll('.heading-toggle')[1].click()")
        preview.document.render(fixture + "\n\n追記", reset: false)
        try await wait { preview.document.renderedText.contains("追記") }
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('.section-body')[1].hidden && document.getElementById('toc').open && !document.getElementById('image-modal').open") as? Bool == true)
        _ = try await web.evaluateJavaScript("document.querySelectorAll('#toc nav a')[1].click()")
        #expect(try await web.evaluateJavaScript("!document.querySelectorAll('.section-body')[1].hidden || document.querySelectorAll('.heading-toggle')[1].getClientRects().length > 0") as? Bool == true)
        let paragraphs = (0..<80).map { "段落\($0)の本文" }.joined(separator: "\n\n")
        preview.document.render("# 更新位置\n\n" + paragraphs, reset: true)
        try await wait { preview.document.renderedText.contains("段落79") }
        _ = try await web.evaluateJavaScript("document.querySelectorAll('main p')[60].scrollIntoView({block:'start'})")
        let position = try #require(try await web.evaluateJavaScript("document.querySelectorAll('main p')[60].getBoundingClientRect().top") as? Double)
        preview.document.render("# 更新位置\n\n" + String(repeating: "上へ挿入\n\n", count: 10) + paragraphs, reset: false)
        try await wait { preview.document.renderedText.contains("上へ挿入") }
        let restored = try #require(try await web.evaluateJavaScript("document.querySelectorAll('main p')[70].getBoundingClientRect().top") as? Double)
        #expect(abs(position - restored) < 1)
        #expect(try await web.evaluateJavaScript("CSS.highlights.get('updated').size === 10") as? Bool == true)
        #expect(try await web.evaluateJavaScript("[...CSS.highlights.get('updated')].every(r => r.toString() === '上へ挿入')") as? Bool == true)
        if let capture = ProcessInfo.processInfo.environment["KIKIGAKI_MINUTES_CAPTURE"] {
            _ = try await web.evaluateJavaScript("scrollTo(0,0)")
            let screenshot = try await web.takeSnapshot(configuration:WKSnapshotConfiguration())
            let data = try #require(screenshot.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data:data))
            try #require(bitmap.representation(using:.png, properties:[:])).write(to:URL(fileURLWithPath:capture).appendingPathComponent("updated-lines.png"))
        }
        try await Task.sleep(for: .milliseconds(4200))
        #expect(try await web.evaluateJavaScript("!CSS.highlights.has('updated')") as? Bool == true)
        if let sample = ProcessInfo.processInfo.environment["KIKIGAKI_MINUTES_SAMPLE"],
           let capture = ProcessInfo.processInfo.environment["KIKIGAKI_MINUTES_CAPTURE"] {
            preview.update(path: sample, source: .human, active: true)
            try await wait { preview.document.renderedText.contains("MyST形式のnote") }
            #expect(try await web.evaluateJavaScript("document.querySelectorAll('.callout').length >= 6") as? Bool == true)
            try await wait { try await web.evaluateJavaScript("[...document.querySelectorAll('main img')].every(i => i.complete && i.naturalWidth > 0)") as? Bool == true }
            _ = try await web.evaluateJavaScript("document.querySelector('.callout').scrollIntoView({block:'start'})")
            let snapshot = try await web.takeSnapshot(configuration: WKSnapshotConfiguration())
            let imageData = try #require(snapshot.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: imageData))
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: capture).appendingPathComponent("user-sample-callouts.png"))
            _ = try await web.evaluateJavaScript("document.querySelector('main img').click()")
            try await wait { try await web.evaluateJavaScript("document.querySelector('#image-modal img').naturalWidth > 0") as? Bool == true }
            // 非アクティブなWebKitのアニメーション時計は止まるため、完成状態を撮影する。
            _ = try await web.evaluateJavaScript("document.getElementById('image-modal').getAnimations().forEach(a => a.finish())")
            _ = try await web.callAsyncJavaScript("await document.querySelector('#image-modal img').decode(); return true", arguments: [:], in: nil, contentWorld: .page)
            try await Task.sleep(for: .milliseconds(150))
            #expect(try await web.evaluateJavaScript("document.querySelector('#image-modal img').getBoundingClientRect().top >= 0 && document.querySelector('#image-modal button').getBoundingClientRect().right <= innerWidth") as? Bool == true)
            let modal = try await web.takeSnapshot(configuration: WKSnapshotConfiguration())
            let modalData = try #require(modal.tiffRepresentation)
            let modalBitmap = try #require(NSBitmapImageRep(data: modalData))
            try #require(modalBitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: capture).appendingPathComponent("user-sample-image.png"))
        }
    }
    @Test func 図と画像と数式を実際のWebKitで描いて検索する() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("会場 図.svg")
        try Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="240" height="70"><rect width="240" height="70" fill="tan"/><text x="20" y="40">会場</text></svg>"#.utf8).write(to: image)
        let file = root.appendingPathComponent("議事録.md")
        let fixture = """
        ---
        title: hidden
        ---
        # 体験会の準備会議

        9月18日の午後、社内10名を対象に試行する方針で合意しました。

        ## 決定事項 {#decisions}

        - [x] 社内で開催
          - **説明**と体験を合わせて30分
        - [ ] 受付担当を確認

        > [!NOTE] 開催条件
        > 接続テストを前日までに行います。

        | 担当 | 作業 | 期限 |
        | --- | --- | --- |
        | 佐藤 | 案内文の作成 | 9/10 |
        | 鈴木 | [[準備手順\\|確認事項]]の更新 | 9/11 |

        参加率は $r=\\frac{参加者数}{対象者数}$ とします。[^rate]

        [^rate]: 欠席の連絡も集計に含めます。

        ## 当日の流れ

        ~~~mermaid
        flowchart LR
          A[説明] --> B[体験] --> C[質問]
        ~~~

        ![[会場 図.svg|240]]

        ![絶対パスの図](<\(image.path)>)

        ~~~svg
        <svg xmlns="http://www.w3.org/2000/svg" width="240" height="70"><circle cx="35" cy="35" r="25" fill="purple"/><text x="75" y="40">受付</text></svg>
        ~~~

        <script>window.INJECTED = true</script>
        """
        try Data(fixture.utf8).write(to: file)
        let preview = MinutesPreviewView(frame: NSRect(x: 0, y: 0, width: 1200, height: 1500))
        let window = NSWindow(contentRect: preview.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = preview; window.orderFront(nil); preview.layoutSubtreeIfNeeded()
        defer { preview.stop(); window.orderOut(nil) }
        preview.update(path: file.path, source: .human, active: true)
        try await wait { preview.document.renderedText.contains("体験会の準備会議") }
        let web = preview.document.webView
        // チェックの有無で、本文に対する丸の縦位置が変わらないこと。
        let checkboxOffsets = try await web.evaluateJavaScript("[...document.querySelectorAll('.task-list-item-checkbox')].map(box => { const text = document.createRange(); text.selectNodeContents(box.nextSibling); return box.getBoundingClientRect().top - text.getBoundingClientRect().top; })") as? [Double]
        let offsets = try #require(checkboxOffsets)
        #expect(offsets.count == 2)
        #expect(abs(offsets[0] - offsets[1]) < 0.5)
        #expect(try await web.evaluateJavaScript("getComputedStyle(document.body).fontSize") as? String == "15px")
        #expect(try await web.evaluateJavaScript("!document.getElementById('toc').hidden && !document.getElementById('toc').open") as? Bool == true)
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('#toc nav a').length") as? Int == 3)
        window.setContentSize(NSSize(width: 1200, height: 400)); preview.layoutSubtreeIfNeeded()
        try await wait { try await web.evaluateJavaScript("innerHeight < 500") as? Bool == true }
        _ = try await web.evaluateJavaScript("document.querySelector('#toc summary').click(); document.querySelectorAll('#toc nav a')[2].click()")
        #expect(try await web.evaluateJavaScript("document.getElementById('toc').open && document.querySelector('#toc a[aria-current]').textContent === '当日の流れ'") as? Bool == true)
        _ = try await web.evaluateJavaScript("document.querySelector('main').dispatchEvent(new PointerEvent('pointerdown', {bubbles:true})); scrollTo(0,0)")
        #expect(try await web.evaluateJavaScript("document.getElementById('toc').open") as? Bool == true)
        window.setContentSize(NSSize(width: 1200, height: 1500)); preview.layoutSubtreeIfNeeded()
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('.diagram svg').length") as? Int == 1)
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('.katex').length") as? Int == 1)
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('.callout').length") as? Int == 1)
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('.footnotes').length") as? Int == 1)
        #expect(try await web.evaluateJavaScript("window.INJECTED === undefined") as? Bool == true)
        try await wait {
            try await web.evaluateJavaScript("[...document.querySelectorAll('main img')].length === 3 && [...document.querySelectorAll('main img')].every(i => i.complete && i.naturalWidth > 0)") as? Bool == true
        }
        let state = try await web.evaluateJavaScript("window.minutes.state()") as? [String: Any]
        #expect(try #require(state?["width"] as? Double) > 720)
        let search = try await web.evaluateJavaScript("window.minutes.search('説明と体験')") as? [String: Int]
        #expect(search?["count"] == 1)
        #expect(try await web.evaluateJavaScript("CSS.highlights.get('matches').size") as? Int == 1)
        #expect(window.makeFirstResponder(preview.pathField))
        _ = try await web.evaluateJavaScript("document.querySelector('main').dispatchEvent(new PointerEvent('pointerdown', { bubbles: true }))")
        try await wait { window.firstResponder === web }
        #expect(preview.hasSearchFocus)
        preview.showSearch()
        #expect(preview.searchField.currentEditor() != nil)
        preview.searchField.stringValue = "体験"; preview.search()
        #expect(preview.pathField.stringValue == file.path)
        preview.closeSearch()
        preview.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        #expect(web.bounds.width > 0 && web.bounds.height > 0)
        if let capture = ProcessInfo.processInfo.environment["KIKIGAKI_MINUTES_CAPTURE"] {
            _ = try await web.evaluateJavaScript("scrollTo(0, 0)")
            let snapshot = try await web.takeSnapshot(configuration: WKSnapshotConfiguration())
            let data = try #require(snapshot.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data: data))
            try #require(bitmap.representation(using: .png, properties: [:])).write(
                to: URL(fileURLWithPath: capture).appendingPathComponent("markdown-features.png"))
        }
        window.setContentSize(NSSize(width: 440, height: 700)); preview.layoutSubtreeIfNeeded()
        try await wait { try await web.evaluateJavaScript("innerWidth < 500") as? Bool == true }
        #expect(try await web.evaluateJavaScript("document.documentElement.scrollWidth <= innerWidth") as? Bool == true)
        preview.showSearch(); preview.searchField.stringValue = "体験"; preview.search()
        _ = try await web.evaluateJavaScript("scrollTo(0, 300)")
        let before = try await web.evaluateJavaScript("scrollY") as? Double
        try Data((fixture + "\n\n追記を確認").utf8).write(to: file, options: .atomic)
        try await wait { preview.document.renderedText.contains("追記を確認") }
        try await Task.sleep(for: .milliseconds(150))
        let after = try await web.evaluateJavaScript("scrollY") as? Double
        #expect(abs(try #require(before) - #require(after)) < 2)
        preview.document.render(String(repeating: "# 見出し\n\n", count: 1000), reset: true)
        try await wait { try await web.evaluateJavaScript("document.querySelectorAll('main h1').length === 1000") as? Bool == true }
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('#toc a').length") as? Int == 300)
        #expect(try await web.evaluateJavaScript("document.querySelector('#toc nav').textContent.includes('先頭300見出し')") as? Bool == true)
        preview.document.render("見出しなし", reset: true)
        try await wait { preview.document.renderedText == "見出しなし" }
        #expect(try await web.evaluateJavaScript("document.getElementById('toc').hidden") as? Bool == true)
    }
    @Test func 画像取得は通常ファイルと上限を守り非画像やFIFOを拒否する() throws {
        let preview = MinutesPreviewView(frame: .zero)
        preview.resetContext(); preview.stop()
        #expect(!preview.document.hasLoadedWebView)
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("定例.md")
        #expect(MinutesResourceHandler.imageFile("notes.md", relativeTo: file) == nil)
        #expect(MinutesResourceHandler.imageFile("javascript:evil.png", relativeTo: file) == nil)
        #expect(MinutesResourceHandler.imageFile("写真 a.png", relativeTo: file)?.lastPathComponent == "写真 a.png")
        #expect(MinutesResourceHandler.imageFile("写真%20a.png", relativeTo: file)?.lastPathComponent == "写真%20a.png")
        let fifo = root.appendingPathComponent("fifo.png")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: (any Error).self) { try MinutesResourceHandler.bytes(fifo) }
        let image = root.appendingPathComponent("x.png"); try Data(repeating: 1, count: 100).write(to: image)
        #expect(throws: (any Error).self) { try MinutesResourceHandler.bytes(image, limit: 99) }
    }
    @Test func 外部エディタのパス引用とワークスペース選択() async throws {
        let path = "/tmp/日本語 ' $(touch nope) \u{0060}echo x\u{0060}.md"
        #expect(try MinutesExternalEditor.command(path: path, executable: "/bin/nvim") == "'/bin/nvim' -- '/tmp/日本語 '\\'' $(touch nope) \u{0060}echo x\u{0060}.md'")
        let uri = try #require(URLComponents(url: MinutesExternalEditor.obsidianURL(path: path), resolvingAgainstBaseURL: false))
        #expect(uri.queryItems?.first?.value == path)
        #expect(throws: (any Error).self) { try MinutesExternalEditor.command(path: "/tmp/a\nb.md", executable: "/bin/nvim") }
        actor Recorder {
            var calls: [[String]] = []
            func run(_ args: [String]) -> AIProcessOutput {
                calls.append(args)
                let text: String
                switch args.prefix(2).joined(separator: " ") {
                case "workspace list": text = #"{"result":{"workspaces":[{"workspace_id":"w1","focused":false},{"workspace_id":"w2","focused":true}]}}"#
                case "tab create": text = #"{"result":{"root_pane":{"pane_id":"w2:p3"}}}"#
                default: text = "{}"
                }
                return AIProcessOutput(status: 0, stdout: Data(text.utf8), stderr: Data())
            }
        }
        let recorder = Recorder()
        try await MinutesExternalEditor.launch(path: path, executable: "/bin/nvim", run: { await recorder.run($0) })
        let calls = await recorder.calls
        #expect(calls[1].contains("w2")); #expect(calls[1].contains("/tmp"))
        #expect(calls[2].prefix(3) == ["pane", "run", "w2:p3"])
    }
}
