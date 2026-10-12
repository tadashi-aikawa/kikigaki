import AppKit
import WebKit
import Testing
@testable import Kikigaki

extension AppKitTests {
@Suite(.serialized) @MainActor struct BoardFocusTests {
    private func wait(_ condition: () async throws -> Bool) async throws {
        for _ in 0..<500 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CocoaError(.coderReadCorrupt)
    }
    private func capture(_ name: String, web: WKWebView) async throws {
        guard let path = ProcessInfo.processInfo.environment["KIKIGAKI_BOARD_FOCUS_CAPTURE"] else { return }
        let directory = URL(fileURLWithPath: path).standardizedFileURL
        try #require(directory.path.hasPrefix("/tmp/") || directory.path.hasPrefix("/private/tmp/"))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await Task.sleep(for: .milliseconds(150))
        let image = try await web.takeSnapshot(configuration: WKSnapshotConfiguration())
        let data = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: data))
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
    }
    @Test func 墨の四隅ブラケットはノードの状態を変えずクリックの位置と倍率を保つ() async throws {
        let document = MinutesWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 850))
        document.boardCanvasEnabled = true
        let window = NSWindow(contentRect: document.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = document; window.orderFront(nil)
        defer { document.invalidate(); window.orderOut(nil) }
        let nodes = (1...30).map { "T\($0)[\"T\($0) 論点の状態と確認事項\"]" }
        let edges = (1...30).filter { $0 % 6 != 0 }.map { "T\($0) --> T\($0+1)" }
        let styles = ["classDef now fill:#efe6f8,stroke:#9b72c6,stroke-width:3px", "classDef done fill:#e3f4e1,stroke:#2e8b57,stroke-width:1px", "classDef hold fill:#fff1d6,stroke:#e67e22,stroke-width:2px,stroke-dasharray:5 3", "class T7 now", "class T13 done", "class T19 hold"]
        var rendered = false
        document.onRendered = { _ in rendered = true }
        document.render("```mermaid\nflowchart TB\n" + (nodes + edges + styles).joined(separator: "\n") + "\n```", reset: true)
        try await wait { rendered }
        let web = document.webView
        try await installBoardFrameClock(web)
        _ = try await web.evaluateJavaScript("""
        window.canvas=document.querySelector('.board-canvas');
        window.stage=canvas.querySelector('.diagram-stage');
        window.node=id=>canvas.querySelector('[data-node-id="'+id+'"]');
        window.press=label=>canvas.querySelector('[data-label="'+label+'"]').click();
        window.shapeStyle=n=>{const shape=n.querySelector('rect');const s=getComputedStyle(shape);return [s.fill,s.stroke,s.strokeWidth,s.strokeDasharray].join('|');};
        void 0;
        """)
        for mode in ["100", "fit"] {
            if mode == "fit" {
                window.setContentSize(NSSize(width: 600, height: 550))
                document.layoutSubtreeIfNeeded()
                try await wait { try await web.evaluateJavaScript("innerWidth<=600 && innerHeight<=550") as? Bool == true }
                try await Task.sleep(for: .milliseconds(50))
            }
            for (id, state) in [("T1", "normal"), ("T7", "now"), ("T13", "done"), ("T19", "hold")] {
                _ = try await web.evaluateJavaScript("""
                press('\(mode == "100" ? "戻す" : "全体")');
                // 等倍の撮影は、クリック前の手動スクロールで対象を画面内へ置く。
                if('\(mode)'==='100') {
                  const r=node('\(id)').getBoundingClientRect(),f=canvas.getBoundingClientRect();
                  canvas.dispatchEvent(new WheelEvent('wheel',{bubbles:true,cancelable:true,deltaX:(r.left+r.right-f.left-f.right)/2,deltaY:(r.top+r.bottom-f.top-f.bottom)/2}));
                  flushDiagramFrames();
                }
                window.before=stage.style.transform;window.beforeStyle=shapeStyle(node('\(id)'));window.box=node('\(id)').getBBox();
                node('\(id)').dispatchEvent(new MouseEvent('click',{bubbles:true}));void 0;
                """)
                #expect(try await web.evaluateJavaScript("""
                (()=>{const n=node('\(id)'),marks=canvas.querySelectorAll('.board-focus-ring'),m=marks[0],s=getComputedStyle(m);
                  const scale=new DOMMatrix(stage.style.transform).a,arm=Math.max(14,10/scale),x0=box.x-6,y0=box.y-6,x1=box.x+box.width+6,y1=box.y+box.height+6;
                  const expected=`M${x0},${y0+arm}V${y0}H${x0+arm} M${x1-arm},${y0}H${x1}V${y0+arm} M${x1},${y1-arm}V${y1}H${x1-arm} M${x0+arm},${y1}H${x0}V${y1-arm}`;
                  // CSSのtransform文字列は倍率を丸める。pathは図の座標を0.001の誤差で照合する。
                  const numbers=d=>d.match(/[-+]?[0-9]*\\.?[0-9]+(?:e[-+]?[0-9]+)?/gi).map(Number),actual=numbers(m.getAttribute('d')),wanted=numbers(expected);
                  return marks.length===1 && m.tagName==='path' && actual.length===wanted.length && actual.every((v,i)=>Math.abs(v-wanted[i])<0.001) && m.getAttribute('d').split(' M').length===4 && s.fill==='none' && s.stroke==='rgb(43, 36, 32)' && s.strokeWidth==='3px' && s.strokeLinecap==='square' && s.vectorEffect==='non-scaling-stroke' && s.pointerEvents==='none' && stage.style.transform===before && shapeStyle(n)===beforeStyle && n.getAttribute('aria-pressed')==='true';})()
                """) as? Bool == true, "\(mode) \(state)")
                if mode == "fit" { #expect(try await web.evaluateJavaScript("new DOMMatrix(stage.style.transform).a<0.7") as? Bool == true) }
                try await capture("focus-\(mode)-\(state)", web: web)
            }
        }
        // 25%のズームでも腕は10 CSS px以上。装飾はノード本体の外に残る。
        _ = try await web.evaluateJavaScript("""
        window.mark=node('T19').querySelector('.board-focus-ring');window.beforePath=mark.getAttribute('d');
        canvas.dispatchEvent(new WheelEvent('wheel',{bubbles:true,cancelable:true,ctrlKey:true,deltaY:10000}));flushDiagramFrames();void 0;
        """)
        #expect(try await web.evaluateJavaScript("new DOMMatrix(stage.style.transform).a===0.25 && mark.getAttribute('d')!==beforePath && mark.getAttribute('d').split(' M').length===4 && canvas.querySelectorAll('.board-focus-ring').length===1") as? Bool == true)
        // 同一フレームの8入力は最後の位置へ1回だけ描画する。
        _ = try await web.evaluateJavaScript("""
        window.writes=0;window.reads=0;window.originalRect=Element.prototype.getBoundingClientRect;
        Element.prototype.getBoundingClientRect=function(){reads++;return originalRect.call(this);};
        window.observer=new MutationObserver(records=>writes+=records.length);observer.observe(stage,{attributes:true,attributeFilter:['style']});
        window.previous=new DOMMatrix(stage.style.transform);
        for(let i=0;i<8;i++)canvas.dispatchEvent(new WheelEvent('wheel',{bubbles:true,cancelable:true,deltaX:2,deltaY:3}));
        window.queued=diagramFrames.size;flushDiagramFrames();void 0;
        """)
        #expect(try await web.evaluateJavaScript("queued===1 && writes===1 && reads===0 && Math.abs(new DOMMatrix(stage.style.transform).e-previous.e+16)<0.01 && Math.abs(new DOMMatrix(stage.style.transform).f-previous.f+24)<0.01") as? Bool == true)
        _ = try await web.evaluateJavaScript("observer.disconnect();Element.prototype.getBoundingClientRect=originalRect;void 0")
    }
}
}
