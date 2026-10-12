import AppKit
import WebKit
import Testing
import KikigakiCore
@testable import Kikigaki

@Suite(.serialized) @MainActor struct BoardCanvasTests {
    private func wait(_ condition: () async throws -> Bool) async throws {
        for _ in 0..<500 {
            if try await condition() { return }
            try await Task.sleep(for:.milliseconds(20))
        }
        throw CocoaError(.coderReadCorrupt)
    }
    private func board(updated: Bool = false, omit: Int? = nil) -> String {
        let nodes = (1...30).filter { $0 != omit }.map { "T\($0)[\"T\($0) 論点の確認\"]" }
        var edges = (1...30).filter { $0 % 6 != 0 && $0 != omit && $0 + 1 != omit }.map { "T\($0) --> T\($0+1)" }
        if updated { edges += ["T31[\"新しい論点\"] --> T1", "T31 --> T7", "T31 --> T13"] }
        return "```mermaid\nflowchart TB\n" + (nodes + edges).joined(separator:"\n") + "\n```"
    }
    private func coloredBoard(count: Int, palette: Bool = false, custom: Bool = false) -> String {
        let names = ["done", "hold", "now", "rejected", ""]
        let labels = ["✅ 決定・実行済み", "🟠 保留", "今の話題", "❌ 却下", "通常の論点"]
        var styles = BoardPrompt.builtIn.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("classDef ") }
        if custom { styles = styles.map { $0.hasPrefix("classDef done ") ? "classDef done fill:#cee9dd,stroke:#447766,stroke-width:4px,stroke-dasharray:7 4,stroke-dashoffset:5" : $0 } }
        let nodes = (1...count).map { "T\($0)[\"T\($0) \(labels[($0 - 1) % 5])\"]" }
        let edges = palette ? [] : (1...count).filter { $0 % 6 != 0 }.map { "T\($0) --> T\($0+1)" }
        let classes = (1...count).compactMap { index -> String? in
            let name = names[(index - 1) % 5]
            return name.isEmpty ? nil : "class T\(index) \(name)"
        }
        return "```mermaid\nflowchart TB\n" + (styles + nodes + edges + classes).joined(separator: "\n") + "\n```"
    }
    private func render(_ source: String, in document: MinutesWebView, reset: Bool) async throws {
        var rendered = false
        document.onRendered = { _ in rendered = true }
        document.render(source,reset:reset)
        try await wait { rendered }
        try await installBoardFrameClock(document.webView)
        _ = try await document.webView.evaluateJavaScript("""
        window.canvas=document.querySelector('.board-canvas');
        window.matrix=()=>{flushDiagramFrames();return new DOMMatrix(canvas.querySelector('.diagram-stage').style.transform);};
        window.node=id=>canvas.querySelector('[data-node-id="'+id+'"]');
        window.point=id=>{flushDiagramFrames();const r=node(id).getBoundingClientRect();return {x:(r.left+r.right)/2,y:(r.top+r.bottom)/2};};
        window.fits=()=>{const s=canvas.querySelector('.diagram-stage > svg').getBoundingClientRect(),f=canvas.getBoundingClientRect();
          return s.left>=f.left-1 && s.top>=f.top-1 && s.right<=f.right+1 && s.bottom<=f.bottom+1;};
        window.press=label=>canvas.querySelector('[data-label="'+label+'"]').click();
        window.wheel=(ctrl,dx,dy)=>{const e=new WheelEvent('wheel',{bubbles:true,cancelable:true,ctrlKey:ctrl,deltaX:dx,deltaY:dy,clientX:innerWidth/2,clientY:innerHeight/2});
          canvas.dispatchEvent(e);return e.defaultPrevented;};
        void 0;
        """)
    }
    private func capture(_ name: String, source: String, web: WKWebView) async throws {
        guard let path = ProcessInfo.processInfo.environment["KIKIGAKI_BOARD_CANVAS_CAPTURE"] else { return }
        let directory = URL(fileURLWithPath:path).standardizedFileURL
        try #require(directory.path.hasPrefix("/tmp/") || directory.path.hasPrefix("/private/tmp/"))
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try source.write(to:directory.appendingPathComponent(name + ".md"),atomically:true,encoding:.utf8)
        try await Task.sleep(for:.milliseconds(150))
        let image = try await web.takeSnapshot(configuration:WKSnapshotConfiguration())
        let data = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data:data))
        try #require(bitmap.representation(using:.png,properties:[:])).write(to:directory.appendingPathComponent(name + ".png"))
    }
    @Test func キャンバスは小さい図を最大200パーセント大きい図を最低25パーセントへ収める() async throws {
        let document = MinutesWebView(frame:NSRect(x:0,y:0,width:900,height:850))
        document.boardLinksEnabled = true; document.boardCanvasEnabled = true
        let window = NSWindow(contentRect:document.frame,styleMask:[.titled],backing:.buffered,defer:false)
        window.contentView = document; window.orderFront(nil)
        defer { document.invalidate(); window.orderOut(nil) }
        let huge = "```mermaid\nflowchart LR\n" + (1...40).map { "T\($0)[\"論点\($0)の確認\"]" }.joined(separator:" --> ") + "\n```"
        for source in ["```mermaid\nflowchart TB\nT1[小さい図]\n```",board(),huge] {
            try await render(source,in:document,reset:true)
            let web = document.webView
            #expect(try await web.evaluateJavaScript("Math.abs(canvas.clientWidth-innerWidth)<1 && Math.abs(canvas.clientHeight-innerHeight)<1 && !canvas.querySelector('.diagram-edges') && getComputedStyle(canvas.querySelector('.diagram-controls')).display==='flex'") as? Bool == true)
            if source == huge {
                #expect(try await web.evaluateJavaScript("matrix().a===0.25 && !fits() && !canvas.querySelector('.board-minimap').hidden") as? Bool == true)
            } else if source == board() {
                #expect(try await web.evaluateJavaScript("matrix().a>=0.25 && matrix().a<1 && fits() && canvas.querySelector('.board-minimap').hidden") as? Bool == true)
            } else {
                #expect(try await web.evaluateJavaScript("matrix().a===2 && fits() && canvas.querySelector('.board-minimap').hidden") as? Bool == true)
            }
            #expect(try await web.evaluateJavaScript("wheel(true,0,-30)") as? Bool == true)
            let zoomed = try await web.evaluateJavaScript("matrix().a") as? Double
            _ = try await web.evaluateJavaScript("""
            window.before=matrix();
            for(const [type,x,y] of [['pointerdown',100,100],['pointermove',140,125],['pointerup',140,125]])
              canvas.dispatchEvent(new PointerEvent(type,{bubbles:true,cancelable:true,pointerId:1,button:0,clientX:x,clientY:y}));
            canvas.click(); void 0;
            """)
            #expect(try await web.evaluateJavaScript("Math.abs(matrix().e-before.e-40)<1 && Math.abs(matrix().f-before.f-25)<1") as? Bool == true)
            #expect(try await web.evaluateJavaScript("matrix().a") as? Double == zoomed)
            _ = try await web.evaluateJavaScript("press('全体'); press('戻す')")
            #expect(try await web.evaluateJavaScript("matrix().a===1 && matrix().e===0 && matrix().f===0 && getComputedStyle(canvas.querySelector('.diagram-controls')).display==='flex'") as? Bool == true)
        }
    }
    @Test func フォーカスと中央付近のノードを更新後も同じ位置へ保ちミニマップで移動する() async throws {
        let document = MinutesWebView(frame:NSRect(x:0,y:0,width:900,height:850))
        document.boardLinksEnabled = true; document.boardCanvasEnabled = true
        let window = NSWindow(contentRect:document.frame,styleMask:[.titled],backing:.buffered,defer:false)
        window.contentView = document; window.orderFront(nil)
        defer { document.invalidate(); window.orderOut(nil) }
        let web = document.webView
        for scale in [1,2] {
            document.setTextScale(CGFloat(scale))
            try await render(board(),in:document,reset:true)
            #expect(try await web.evaluateJavaScript("fits()") as? Bool == true)
            try await capture("canvas-\(scale*100)-initial",source:board(),web:web)
            // 全体のまま更新すると、新しい自然寸法へ収め直す。
            try await render(board(updated:true),in:document,reset:false)
            #expect(try await web.evaluateJavaScript("fits() && canvas.querySelector('.board-minimap').hidden") as? Bool == true)
            _ = try await web.evaluateJavaScript("window.beforeFocus=canvas.querySelector('.diagram-stage').style.transform; node('T1').dispatchEvent(new MouseEvent('click',{bubbles:true})); void 0")
            #expect(try await web.evaluateJavaScript("node('T1').querySelector('.board-focus-ring')!==null && canvas.querySelector('.diagram-stage').style.transform===beforeFocus") as? Bool == true)
            #expect(try await web.evaluateJavaScript("getComputedStyle(node('T1').querySelector('.board-focus-ring')).fill==='none'") as? Bool == true)
            try await capture("canvas-\(scale*100)-focused",source:board(updated:true),web:web)
            _ = try await web.evaluateJavaScript("wheel(true,0,-Math.log(2)/0.01); wheel(false,35,20); window.savedPoint=point('T1'); window.savedScale=matrix().a; void 0")
            try await capture("canvas-\(scale*100)-zoom-before",source:board(updated:true),web:web)
            try await render(board(),in:document,reset:false)
            #expect(try await web.evaluateJavaScript("matrix().a===savedScale && Math.abs(point('T1').x-savedPoint.x)<1 && Math.abs(point('T1').y-savedPoint.y)<1 && node('T1').querySelector('.board-focus-ring')!==null") as? Bool == true)
            try await capture("canvas-\(scale*100)-zoom-after",source:board(),web:web)
            // フォーカス解除後は、中央に近いノードを同じ位置へ置き直す。
            _ = try await web.evaluateJavaScript("""
            document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true}));
            wheel(false,80,25);
            window.nearest=[...canvas.querySelectorAll('[data-node-id]')].sort((a,b)=>{
              const p=point(a.dataset.nodeId),q=point(b.dataset.nodeId);
              return Math.hypot(p.x-innerWidth/2,p.y-innerHeight/2)-Math.hypot(q.x-innerWidth/2,q.y-innerHeight/2);
            })[0].dataset.nodeId;
            window.savedPoint=point(nearest); void 0;
            """)
            #expect(try await web.evaluateJavaScript("!canvas.querySelector('.board-focus-ring') && wheel(false,0,0)") as? Bool == true)
            try await render(board(updated:true),in:document,reset:false)
            #expect(try await web.evaluateJavaScript("matrix().a===savedScale && Math.abs(point(nearest).x-savedPoint.x)<1 && Math.abs(point(nearest).y-savedPoint.y)<1") as? Bool == true)
            // 覚えたノードが消えた場合は、数値をそのまま保つ。
            _ = try await web.evaluateJavaScript("node('T1').dispatchEvent(new MouseEvent('click',{bubbles:true})); window.savedTransform=canvas.querySelector('.diagram-stage').style.transform; void 0")
            try await render(board(omit:1),in:document,reset:false)
            #expect(try await web.evaluateJavaScript("canvas.querySelector('.diagram-stage').style.transform===savedTransform && !canvas.querySelector('.board-focus-ring')") as? Bool == true)
            _ = try await web.evaluateJavaScript("press('戻す'); wheel(true,0,-40); void 0")
            _ = try await web.evaluateJavaScript("flushDiagramFrames(); void 0")
            try await wait { try await web.evaluateJavaScript("!canvas.querySelector('.board-minimap').hidden") as? Bool == true }
            #expect(try await web.evaluateJavaScript("canvas.querySelector('.board-minimap svg svg').querySelectorAll('rect').length===29 && canvas.querySelector('.board-minimap svg svg path')!==null && !canvas.querySelector('.board-minimap :is(use,text,tspan,style,marker,[id])')") as? Bool == true)
            #expect(try await web.evaluateJavaScript("new Set([...canvas.querySelectorAll('.board-minimap svg svg rect')].map(r=>r.getBoundingClientRect().x)).size>1 && [...canvas.querySelectorAll('.board-minimap svg svg [transform]')].every(e=>e.getAttribute('transform').startsWith('matrix('))") as? Bool == true)
            try await capture("canvas-\(scale*100)-minimap",source:board(omit:1),web:web)
            _ = try await web.evaluateJavaScript("""
            window.map=canvas.querySelector('.board-minimap'); window.before=matrix();
            {const r=map.getBoundingClientRect();map.dispatchEvent(new MouseEvent('click',{bubbles:true,clientX:r.left+r.width*0.75,clientY:r.top+r.height*0.65}));}
            void 0;
            """)
            #expect(try await web.evaluateJavaScript("matrix().a===before.a && (Math.abs(matrix().e-before.e)>5 || Math.abs(matrix().f-before.f)>5)") as? Bool == true)
            _ = try await web.evaluateJavaScript("""
            window.before=matrix();
            {const r=map.getBoundingClientRect();
              for(const [type,x,y] of [['pointerdown',r.left+10,r.top+10],['pointermove',r.right-10,r.bottom-10],['pointerup',r.right-10,r.bottom-10]])
                map.dispatchEvent(new PointerEvent(type,{bubbles:true,cancelable:true,pointerId:2,button:0,clientX:x,clientY:y}));}
            void 0;
            """)
            #expect(try await web.evaluateJavaScript("matrix().a===before.a && (Math.abs(matrix().e-before.e)>5 || Math.abs(matrix().f-before.f)>5)") as? Bool == true)
            _ = try await web.evaluateJavaScript("press('全体')")
            #expect(try await web.evaluateJavaScript("fits() && canvas.querySelector('.board-minimap').hidden") as? Bool == true)
        }
    }
    @Test func 旧ボードの複数図と本文も開いて読める() async throws {
        let document = MinutesWebView(frame:NSRect(x:0,y:0,width:900,height:850))
        document.boardLinksEnabled = true; document.boardCanvasEnabled = true
        let window = NSWindow(contentRect:document.frame,styleMask:[.titled],backing:.buffered,defer:false)
        window.contentView = document; window.orderFront(nil)
        defer { document.invalidate(); window.orderOut(nil) }
        let source = """
        ```mermaid
        flowchart TB
          T1[全体図]
          click T1 "#詳細"
        ```
        [[#詳細]]
        ### 詳細
        ```mermaid
        flowchart TB
          T2[詳細の論点]
        ```
        ### 立場
        意見が割れている論点。
        ### 直近の動き
        T2が決まった。
        """
        try await render(source,in:document,reset:true)
        let web = document.webView
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('.board-canvas').length===1 && document.querySelector('.board-legacy').textContent.includes('T2が決まった。') && document.querySelector('.board-legacy .diagram')!==null") as? Bool == true)
        _ = try await web.evaluateJavaScript("node('T1').dispatchEvent(new MouseEvent('click',{bubbles:true})); node('T1').dispatchEvent(new MouseEvent('click',{bubbles:true})); void 0")
        #expect(try await web.evaluateJavaScript("document.querySelector('.board-legacy').open && document.querySelector('h3').getBoundingClientRect().top>=0") as? Bool == true)
        try await capture("canvas-legacy",source:source,web:web)
        // 図の無い旧ボードは文書表示へ戻す。
        var rendered = false
        document.onRendered = { _ in rendered = true }
        document.render("### 立場\n図のない古い記録",reset:true)
        try await wait { rendered }
        #expect(try await web.evaluateJavaScript("!document.querySelector('.board-canvas') && !document.body.classList.contains('board-canvas-mode') && document.body.innerText.includes('図のない古い記録')") as? Bool == true)
    }
    @Test func ミニマップはカードの色と点線を写し操作中は色を読み直さない() async throws {
        let document = MinutesWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 850))
        document.boardCanvasEnabled = true
        let window = NSWindow(contentRect: document.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = document; window.orderFront(nil)
        defer { document.invalidate(); window.orderOut(nil) }
        let web = document.webView
        for scale in [1, 2] {
            document.setTextScale(CGFloat(scale))
            for count in [30, 60] {
                let source = coloredBoard(count: count)
                try await render(source, in: document, reset: true)
                try await capture("colors-\(count)-\(scale*100)-whole", source: source, web: web)
                _ = try await web.evaluateJavaScript("press('戻す'); void 0")
                #expect(try await web.evaluateJavaScript("""
                (()=>{
                  const nodes=[...canvas.querySelectorAll('.diagram-stage g.node')], map=canvas.querySelector('.board-minimap'),
                    boxes=[...map.querySelectorAll('svg svg rect')], outer=map.querySelector('svg');
                  const properties=['fill','fill-opacity','stroke','stroke-opacity','stroke-width','stroke-dasharray','stroke-dashoffset'];
                  const equal=nodes.every((node,i)=>{
                    const shape=node.querySelector('.label-container') || node.querySelector('rect,polygon,circle,ellipse,path');
                    return properties.every(key=>getComputedStyle(shape).getPropertyValue(key)===getComputedStyle(boxes[i]).getPropertyValue(key));
                  });
                  const w=parseFloat(outer.style.width),h=parseFloat(outer.style.height),vb=outer.viewBox.baseVal,
                    ratio=Math.min(canvas.getBoundingClientRect().width*.50/vb.width,canvas.getBoundingClientRect().height*.40/vb.height);
                  return nodes.length===\(count) && boxes.length===\(count) && equal && !map.hidden &&
                    !map.querySelector('use,text,tspan') && Math.abs(w-vb.width*ratio)<.01 && Math.abs(h-vb.height*ratio)<.01;
                })()
                """) as? Bool == true)
                try await capture("colors-\(count)-\(scale*100)-minimap", source: source, web: web)
                _ = try await web.evaluateJavaScript("""
                window.cardStyleReads=0;window.savedGetComputedStyle=window.getComputedStyle;
                window.getComputedStyle=function(element,...rest){
                  if(element.closest('.diagram-stage g.node'))cardStyleReads++;
                  return savedGetComputedStyle.call(window,element,...rest);
                };
                for(let i=0;i<20;i++)wheel(false,2,1);
                flushDiagramFrames();void 0;
                """)
                try await Task.sleep(for: .milliseconds(150))
                let reads = try await web.evaluateJavaScript("window.getComputedStyle=savedGetComputedStyle;cardStyleReads") as? Int
                #expect(reads == 0)
                // 独自classDefへの変更も再描画時に拾う。色表の固定値で写していないことを確かめる。
                try await render(coloredBoard(count: count, custom: true), in: document, reset: false)
                #expect(try await web.evaluateJavaScript("""
                (()=>{const r=canvas.querySelector('.board-minimap svg svg rect'),s=getComputedStyle(r),original=getComputedStyle(node('T1').querySelector('.label-container'));
                  return s.fill==='rgb(206, 233, 221)' && s.stroke==='rgb(68, 119, 102)' && s.strokeWidth==='4px' && s.strokeDasharray===original.strokeDasharray && s.strokeDashoffset===original.strokeDashoffset;})()
                """) as? Bool == true)
            }
        }
    }
    @Test func 横長と縦長のミニマップを広いキャンバスで表示する() async throws {
        let document = MinutesWebView(frame: NSRect(x:0,y:0,width:1200,height:850))
        document.boardCanvasEnabled = true
        let window = NSWindow(contentRect:document.frame,styleMask:[.titled],backing:.buffered,defer:false)
        window.contentView = document; window.orderFront(nil)
        defer { document.invalidate(); window.orderOut(nil) }
        let web = document.webView
        for scale in [1,2] {
            document.setTextScale(CGFloat(scale))
            for direction in ["LR","TB"] {
                let source = coloredBoard(count:60).replacingOccurrences(of:"flowchart TB",with:"flowchart \(direction)")
                // 6ノードずつの枝だけでなく、60ノードが一本につながる極端な縦横比も撮る。
                let chain = (1..<60).filter { $0 % 6 == 0 }.map { "T\($0) --> T\($0+1)" }.joined(separator:"\n")
                let connected = source.replacingOccurrences(of:"\n```",with:"\n"+chain+"\n```")
                try await render(connected,in:document,reset:true)
                try await capture("long-\(direction)-60-\(scale*100)",source:connected,web:web)
                #expect(try await web.evaluateJavaScript("""
                (()=>{const map=canvas.querySelector('.board-minimap'),s=map.querySelector('svg'),r=canvas.getBoundingClientRect();
                  return !map.hidden && (Math.abs(parseFloat(s.style.width)-r.width*.5)<1 || Math.abs(parseFloat(s.style.height)-r.height*.4)<1);})()
                """) as? Bool == true)
            }
            // カードを右下へ動かし、フォーカスしたときにミニマップが避けることを確かめる。
            let source = coloredBoard(count:30)
            try await render(source,in:document,reset:true)
            _ = try await web.evaluateJavaScript("""
            (()=>{press('戻す');
              const r=canvas.getBoundingClientRect(),p=point('T4');
              wheel(false,p.x-r.width*.85,p.y-r.height*.85);flushDiagramFrames();
              node('T4').dispatchEvent(new MouseEvent('click',{bubbles:true}));})();void 0;
            """)
            #expect(try await web.evaluateJavaScript("""
            (()=>{const n=node('T4').getBoundingClientRect(),m=canvas.querySelector('.board-minimap').getBoundingClientRect();
              return n.right<=m.left || n.left>=m.right || n.bottom<=m.top || n.top>=m.bottom;})()
            """) as? Bool == true)
            try await capture("minimap-avoids-focus-\(scale*100)",source:source,web:web)
        }
    }
}
