import AppKit
import WebKit
import Testing
@testable import Kikigaki

@Suite(.serialized) @MainActor struct DiagramUpdateTests {
    private func ready(_ document: MinutesWebView, source: String) async throws {
        var rendered = false
        document.onRendered = { _ in rendered = true }
        document.render(source, reset: true)
        for _ in 0..<500 {
            if rendered { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CocoaError(.coderReadCorrupt)
    }
    private func source(_ label: String) -> String {
        let nodes = (1...30).map { "T\($0)[\"T\($0) \(label)\"]" }
        let edges = (1..<30).filter { $0 % 6 != 0 }.map { "T\($0) --> T\($0+1)" }
        return "# 議論\n```mermaid\nflowchart TB\n" + (nodes + edges).joined(separator: "\n") + "\n```\n本文も\(label)"
    }
    @Test func 議事録とボードの更新途中も前の図を残して定義文と一時SVGを見せない() async throws {
        let document = MinutesWebView(frame: NSRect(x:0,y:0,width:900,height:850))
        let window = NSWindow(contentRect:document.frame,styleMask:[.titled],backing:.buffered,defer:false)
        window.contentView = document; window.orderFront(nil)
        defer { document.invalidate(); window.orderOut(nil) }
        let observerURL = URL(fileURLWithPath:#filePath).deletingLastPathComponent()
            .appendingPathComponent("../../web/minutes/observe-update.js").standardizedFileURL
        let observer = try String(contentsOf:observerURL,encoding:.utf8)
        for board in [false,true] {
            document.boardCanvasEnabled = board; document.boardLinksEnabled = board
            for scale in [1,2] {
                document.setTextScale(CGFloat(scale))
                try await ready(document,source:source("更新前"))
                _ = try await document.webView.evaluateJavaScript(observer)
                let result = try #require(try await document.webView.callAsyncJavaScript(
                    "return await observeDiagramUpdate(source,board)",
                    arguments:["source":source("更新後"),"board":board],contentWorld:.page) as? [String:Any])
                #expect((result["samples"] as? Int ?? 0) > 3)
                #expect((result["previousSamples"] as? Int ?? 0) > 2)
                #expect(result["sourceSamples"] as? Int == 0)
                #expect(result["emptySamples"] as? Int == 0)
                #expect(result["temporarySVGSamples"] as? Int == 0)
                #expect(try await document.webView.evaluateJavaScript("document.getElementById('minutes').textContent.includes('本文も更新後') && !document.getElementById('minutes').textContent.includes('更新前')") as? Bool == true)
            }
        }
    }
    @Test func 描画待ちの操作を引き継ぎ古い更新と取消を表示へ戻さない() async throws {
        let document = MinutesWebView(frame: NSRect(x:0,y:0,width:900,height:850))
        document.boardCanvasEnabled = true; document.boardLinksEnabled = true
        let window = NSWindow(contentRect:document.frame,styleMask:[.titled],backing:.buffered,defer:false)
        window.contentView = document; window.orderFront(nil)
        defer { document.invalidate(); window.orderOut(nil) }
        try await ready(document,source:source("更新前"))
        try await installBoardFrameClock(document.webView)
        let result = try await document.webView.callAsyncJavaScript("""
        const root=document.getElementById('minutes'), old=root.querySelector('.board-canvas');
        const rendering=window.minutes.render(source,'test',false,2,null,true,true);
        old.querySelector('[data-label="戻す"]').click();
        old.dispatchEvent(new WheelEvent('wheel',{bubbles:true,cancelable:true,deltaX:35,deltaY:20}));
        old.querySelector('[data-node-id="T1"]').dispatchEvent(new MouseEvent('click',{bubbles:true}));
        flushDiagramFrames();
        const before=old.querySelector('[data-node-id="T1"]').getBoundingClientRect();
        await rendering;
        flushDiagramFrames();
        const after=root.querySelector('[data-node-id="T1"]').getBoundingClientRect();
        const dx=(before.left+before.right-after.left-after.right)/2;
        const dy=(before.top+before.bottom-after.top-after.bottom)/2;
        const retained=root.querySelector('.board-focus-ring')!==null && Math.abs(dx)<1 && Math.abs(dy)<1;
        const stale=window.minutes.render(source+'\\n古い更新','test',false,3,null,true,true);
        const latest=window.minutes.render(source+'\\n最新の更新','test',false,4,null,true,true);
        await Promise.all([stale,latest]);
        const latestOnly=root.textContent.includes('最新の更新') && !root.textContent.includes('古い更新');
        const cancelled=window.minutes.render(source+'\\n取り消した更新','test',false,5,null,true,true);
        window.minutes.invalidate(); const html=root.innerHTML; await cancelled;
        return {retained,dx,dy,latestOnly,cancelled:root.innerHTML===html};
        """,arguments:["source":source("更新後")],contentWorld:.page)
        let checks = try #require(result as? [String:Any])
        #expect(checks["retained"] as? Bool == true, "\(checks)")
        #expect(checks["latestOnly"] as? Bool == true)
        #expect(checks["cancelled"] as? Bool == true)
    }
    @Test func 描画失敗時は定義文を残し図がないボードは文書へ戻る() async throws {
        let document = MinutesWebView(frame: NSRect(x:0,y:0,width:900,height:850))
        document.boardCanvasEnabled = true; document.boardLinksEnabled = true
        let window = NSWindow(contentRect:document.frame,styleMask:[.titled],backing:.buffered,defer:false)
        window.contentView = document; window.orderFront(nil)
        defer { document.invalidate(); window.orderOut(nil) }
        try await ready(document,source:source("更新前"))
        let invalid = "```mermaid\nflowchart TB\nT1[\n```"
        _ = try await document.webView.callAsyncJavaScript("return await window.minutes.render(source,'test',false,2,null,true,true)",arguments:["source":invalid],contentWorld:.page)
        #expect(try await document.webView.evaluateJavaScript("document.querySelector('.mermaid-source')?.title==='図を描画できないため、記法を表示しています' && !document.body.classList.contains('board-canvas-mode') && !document.querySelector('body > div svg')") as? Bool == true)
        _ = try await document.webView.callAsyncJavaScript("return await window.minutes.render('# 文書だけ','test',false,3,null,true,true)",arguments:[:],contentWorld:.page)
        #expect(try await document.webView.evaluateJavaScript("document.getElementById('minutes').innerText.includes('文書だけ') && !document.querySelector('.diagram') && !document.body.classList.contains('board-canvas-mode')") as? Bool == true)
    }
}
