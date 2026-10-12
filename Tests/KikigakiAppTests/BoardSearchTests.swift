import AppKit
import WebKit
import Testing
@testable import Kikigaki

extension AppKitTests {
@Suite(.serialized) @MainActor struct BoardSearchTests {
    private func wait(_ condition: () async throws -> Bool) async throws {
        for _ in 0..<500 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CocoaError(.coderReadCorrupt)
    }
    private func board(repeated: Bool = false, updated: Bool = false) -> String {
        let nodes = (1...30).map { index in
            let label = index == 1 ? (repeated ? "監視・監視" : "監視の基盤") : index == 7 ? "監視の通知" : "論点の確認"
            return "T\(index)[\"T\(index) \(label)\"]"
        }
        let edges = (1...30).filter { $0 % 6 != 0 }.map { "T\($0) --> T\($0+1)" }
        return "```mermaid\nflowchart TB\n" + (nodes + edges + ["T1 -->|辺だけの言葉| T7", "click T1 \"#会議詳細\""] +
            (updated ? ["T31[追加した論点] --> T1"] : [])).joined(separator: "\n") + "\n```\n### 以前の記録\n本文だけの言葉\n"
    }
    private func render(_ source: String, in document: MinutesWebView, reset: Bool) async throws {
        var rendered = false
        document.onRendered = { _ in rendered = true }
        document.render(source, reset: reset)
        try await wait { rendered }
        try await installBoardFrameClock(document.webView)
        _ = try await document.webView.evaluateJavaScript("""
        window.canvas=document.querySelector('.board-canvas');
        window.matrix=()=>{flushDiagramFrames();return new DOMMatrix(canvas.querySelector('.diagram-stage').style.transform);};
        window.node=id=>canvas.querySelector('[data-node-id="'+id+'"]');
        window.point=id=>{flushDiagramFrames();const r=node(id).getBoundingClientRect();return {x:(r.left+r.right)/2,y:(r.top+r.bottom)/2};};
        window.centered=id=>{const p=point(id),r=canvas.getBoundingClientRect();return Math.abs(p.x-(r.left+r.width/2))<1 && Math.abs(p.y-(r.top+r.height/2))<1;};
        window.press=label=>canvas.querySelector('[data-label="'+label+'"]').click(); void 0;
        """)
    }
    private func capture(_ name: String, web: WKWebView) async throws {
        guard let path = ProcessInfo.processInfo.environment["KIKIGAKI_BOARD_SEARCH_CAPTURE"] else { return }
        let directory = URL(fileURLWithPath: path).standardizedFileURL
        try #require(directory.path.hasPrefix("/tmp/") || directory.path.hasPrefix("/private/tmp/"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await Task.sleep(for: .milliseconds(150))
        // 既存のWKSnapshot撮影と同じ、画素比較用の一時PNG。
        let image = try await web.takeSnapshot(configuration: WKSnapshotConfiguration())
        let data = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
    }
    @Test func ノード文字を検索し次前で中央とフォーカスへ移動し閉じてもフォーカスは残る() async throws {
        let document = MinutesWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 850))
        document.boardLinksEnabled = true; document.boardCanvasEnabled = true
        let window = NSWindow(contentRect: document.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = document; window.orderFront(nil)
        defer { document.invalidate(); window.orderOut(nil) }
        let web = document.webView
        for scale in [1, 2] {
            document.setTextScale(CGFloat(scale))
            try await render(board(), in: document, reset: true)
            try await capture("search-\(scale*100)-before", web: web)
            for excluded in ["辺だけの言葉", "本文だけの言葉", "−", "全体"] {
                #expect(try await web.evaluateJavaScript("window.minutes.search('\(excluded)',0,false).count") as? Int == 0)
            }
            // 25%から検索した場合だけ100%へ上げる。文字の倍率は別に維持する。
            _ = try await web.evaluateJavaScript("press('戻す'); canvas.dispatchEvent(new WheelEvent('wheel',{bubbles:true,cancelable:true,ctrlKey:true,deltaY:Math.log(4)/0.01})); void 0")
            let first = try await web.evaluateJavaScript("window.minutes.search('監視')") as? [String: Int]
            #expect(first == ["count": 2, "current": 1])
            #expect(try await web.evaluateJavaScript("matrix().a===1 && centered('T1') && node('T1').getAttribute('aria-pressed')==='true' && canvas.querySelectorAll('.board-search-ring').length===2") as? Bool == true)
            #expect(web.pageZoom == CGFloat(scale))
            try await capture("search-\(scale*100)-first", web: web)
            let second = try await web.evaluateJavaScript("window.minutes.search('監視',1)") as? [String: Int]
            #expect(second == ["count": 2, "current": 2])
            #expect(try await web.evaluateJavaScript("matrix().a===1 && centered('T7') && node('T7').querySelector('.board-focus-ring')!==null && node('T7').querySelector('[data-current=true]')!==null") as? Bool == true)
            try await capture("search-\(scale*100)-second", web: web)
            _ = try await web.evaluateJavaScript("window.minutes.search('監視',-1); void 0")
            #expect(try await web.evaluateJavaScript("centered('T1') && node('T1').querySelector('.board-focus-ring')!==null") as? Bool == true)
            // 200%は保つ。前の一致は末尾へ循環する。
            _ = try await web.evaluateJavaScript("canvas.dispatchEvent(new WheelEvent('wheel',{bubbles:true,cancelable:true,ctrlKey:true,deltaY:-Math.log(2)/0.01})); void 0")
            _ = try await web.evaluateJavaScript("window.minutes.search('監視',-1); void 0")
            #expect(try await web.evaluateJavaScript("matrix().a===2 && centered('T7')") as? Bool == true)
            // 更新で検索の中央寄せを繰り返さず、ユーザーがずらした位置を保つ。
            _ = try await web.evaluateJavaScript("canvas.dispatchEvent(new WheelEvent('wheel',{bubbles:true,cancelable:true,deltaX:35,deltaY:20})); void 0")
            _ = try await web.evaluateJavaScript("window.savedPoint=point('T7'); void 0")
            try await render(board(updated: true), in: document, reset: false)
            #expect(try await web.evaluateJavaScript("matrix().a===2 && Math.abs(point('T7').x-savedPoint.x)<1 && Math.abs(point('T7').y-savedPoint.y)<1 && node('T7').querySelector('.board-focus-ring')!==null") as? Bool == true)
            _ = try await web.evaluateJavaScript("window.minutes.search(''); void 0")
            #expect(try await web.evaluateJavaScript("!canvas.querySelector('.board-search-ring') && CSS.highlights.get('matches').size===0 && CSS.highlights.get('current').size===0 && node('T7').querySelector('.board-focus-ring')!==null") as? Bool == true)
        }
        var navigated = false
        document.onBoardAnchor = { _ in navigated = true }
        try await render(board(repeated: true), in: document, reset: true)
        #expect(try await web.evaluateJavaScript("window.minutes.search('監視').count") as? Int == 3)
        #expect(try await web.evaluateJavaScript("window.minutes.search('監視',1).current") as? Int == 2)
        #expect(try await web.evaluateJavaScript("centered('T1') && node('T1').querySelector('.board-focus-ring')!==null") as? Bool == true)
        #expect(!navigated)
        // Mermaidの折り返しをまたぐ語は探せる。別ノード同士はつなげない。
        try await render(board().replacingOccurrences(of: "監視の基盤", with: "監視<br/>基盤"), in: document, reset: true)
        #expect(try await web.evaluateJavaScript("window.minutes.search('監視基盤',0,false).count") as? Int == 1)
        #expect(try await web.evaluateJavaScript("window.minutes.search('基盤T2',0,false).count") as? Int == 0)
    }
    @Test func 検索欄と件数はタブに追従し検索語を保ち閉じると両タブの強調を消す() async throws {
        let defaults = MinutesTestDefaults()
        let preview = MinutesPreviewView(frame: NSRect(x: 0, y: 0, width: 900, height: 900), defaults: defaults.value)
        let window = NSWindow(contentRect: preview.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = preview; window.orderFront(nil)
        defer { preview.stop(); window.orderOut(nil) }
        preview.update(path: nil, source: nil, active: true, boardHeading: "## ボード")
        preview.receive(.body("# 会議\n## 会議詳細\n監視の議事録\n## ボード\n" + board(), [], modifiedAt: Date()))
        try await wait { preview.boardDocument.renderedText.contains("T30") && preview.minutesDocument.renderedText.contains("監視の議事録") }
        preview.showSearch(); preview.searchField.stringValue = "監視"; preview.search()
        try await wait { preview.searchCount.stringValue == "1 / 1" }
        #expect(preview.searchField.placeholderString == "議事録を検索")
        preview.selectBoard(true)
        #expect(preview.searchField.placeholderString == "ボードを検索")
        #expect(preview.searchField.accessibilityLabel() == "ボードを検索")
        #expect(preview.searchField.stringValue == "監視")
        try await wait { preview.searchCount.stringValue == "1 / 2" }
        preview.search(direction: 1)
        try await wait { preview.searchCount.stringValue == "2 / 2" }
        #expect(try await preview.boardDocument.webView.evaluateJavaScript("document.querySelector('[data-node-id=T7]').getAttribute('aria-pressed')==='true'") as? Bool == true)
        preview.selectBoard(false)
        #expect(preview.searchField.placeholderString == "議事録を検索")
        try await wait { preview.searchCount.stringValue == "1 / 1" }
        preview.selectBoard(true)
        try await wait { preview.searchCount.stringValue == "2 / 2" }
        preview.closeSearch()
        #expect(!preview.isSearchOpen && preview.searchField.stringValue.isEmpty)
        for document in [preview.minutesDocument, preview.boardDocument] {
            try await wait { try await document.webView.evaluateJavaScript("CSS.highlights.get('matches').size===0 && !document.querySelector('.board-search-ring')") as? Bool == true }
        }
        #expect(try await preview.boardDocument.webView.evaluateJavaScript("document.querySelector('[data-node-id=T7] .board-focus-ring')!==null") as? Bool == true)
        // ボードが消えた場合も検索欄は議事録へ戻る。
        preview.receive(.body("# 会議\nボードが消えた", [], modifiedAt: Date()))
        #expect(preview.searchField.placeholderString == "議事録を検索")
    }
}
}
