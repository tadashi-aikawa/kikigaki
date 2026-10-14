import AppKit
import WebKit
import Testing
import KikigakiCore
@testable import Kikigaki

extension AppKitTests {
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
        // 実機で欠けたIDと英字本文を別行にし、textContentの空白消失を再現する。
        let wrappedLabels = [8: "💬 T8<br/>AI時代はどう変わる", 9: "💬 T9<br/>Neovimやエディタ", 11: "✅ T11<br/>AIを使う", 13: "T13<br/>APIの確認"]
        let nodes = (1...count).map { "T\($0)[\"\(wrappedLabels[$0] ?? "T\($0) \(labels[($0 - 1) % 5])")\"]" }
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
        let metrics = try #require(await web.evaluateJavaScript("""
        (()=>{const map=document.querySelector('.board-minimap'),outer=map?.querySelector('svg'),
          frame=document.querySelector('.board-canvas')?.getBoundingClientRect();
          if(!outer || !frame || !outer.style.width)return {};
          const sizes=[...map.querySelectorAll('text')].map(t=>parseFloat(t.getAttribute('font-size'))*t.getScreenCTM().a*\(web.pageZoom));
          return {width:parseFloat(outer.style.width),height:parseFloat(outer.style.height),
            canvasWidth:frame.width,canvasHeight:frame.height,pageZoom:\(web.pageZoom),hidden:map.hidden,screenFontSizes:sizes};})()
        """))
        let metricsData = try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys])
        try metricsData.write(to: directory.appendingPathComponent(name + ".metrics.json"))
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
                #expect(try await web.evaluateJavaScript("canvas.querySelectorAll('.board-minimap text').length===40") as? Bool == true)
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
            #expect(try await web.evaluateJavaScript("canvas.querySelector('.board-minimap svg svg').querySelectorAll('rect').length===29 && canvas.querySelector('.board-minimap svg svg path')!==null && canvas.querySelectorAll('.board-minimap text').length===29 && !canvas.querySelector('.board-minimap :is(use,tspan,style,marker,[id])')") as? Bool == true)
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
    @Test func ミニマップはノードIDを優先し数字始まりの折り返し本文を混ぜず旧図はラベルから読む() async throws {
        let document = MinutesWebView(frame:NSRect(x:0,y:0,width:900,height:850))
        document.boardCanvasEnabled = true
        let window = NSWindow(contentRect:document.frame,styleMask:[.titled],backing:.buffered,defer:false)
        window.contentView = document; window.orderFront(nil)
        defer { document.invalidate(); window.orderOut(nil) }
        let source = """
        ```mermaid
        flowchart TB
          T1["✅ T3 決定"]
          Other["🟠 T5 保留"]
          Legacy["旧ボードの箱"]
          OtherLong["❌ T12345678901234567890<br/>却下"]
          T4["✅ T4<br/>23番は警告も消す"]
          T423["T423 数字の多いID"]
          T6["💬 T6 所感"]
          T7["番号なしの本文"]
          T1 --> Other --> Legacy --> OtherLong --> T4 --> T423 --> T6 --> T7
          classDef dark fill:#221f1c,stroke:#221f1c
          class T1 dark
        ```
        """
        let web = document.webView
        for scale in [1,2] {
            document.setTextScale(CGFloat(scale))
            try await render(source,in:document,reset:true)
            _ = try await web.evaluateJavaScript("press('戻す');void 0")
            _ = try await web.evaluateJavaScript("wheel(true,0,-Math.log(2)/0.01);flushDiagramFrames();void 0")
            try await wait { try await web.evaluateJavaScript("!canvas.querySelector('.board-minimap').hidden") as? Bool == true }
            #expect(try await web.evaluateJavaScript("""
            (()=>{const texts=[...canvas.querySelectorAll('.board-minimap text')];
              const label=node('T4').querySelector('.nodeLabel, .label');
              return label.querySelectorAll('.text-outer-tspan').length>=2 && label.textContent==='✅ T423番は警告も消す' &&
                texts.map(t=>t.textContent).join('|')==='T1|T5|T12345678901234567890|T4|T423|T6|T7' &&
                getComputedStyle(texts[0]).fill==='rgb(238, 233, 226)' && getComputedStyle(texts[1]).fill==='rgb(61, 57, 53)' &&
                texts.every(t=>{const p=t.parentElement,b=t.getBBox(),v=p.viewBox.baseVal;
                  const r=t.getBoundingClientRect(),vp=p.getBoundingClientRect();
                  return b.width>0 && b.height>0 && getComputedStyle(p).overflow==='hidden' &&
                    b.x>=0 && b.y>=0 && b.x+b.width<=v.width && b.y+b.height<=v.height &&
                    r.left>=vp.left-.1 && r.right<=vp.right+.1 && r.top>=vp.top-.1 && r.bottom<=vp.bottom+.1;});})()
            """) as? Bool == true)
            // 問題の本文とミニマップのT4を同じ画面で見比べられる位置へ寄せる。
            _ = try await web.evaluateJavaScript("""
            {const map=canvas.querySelector('.board-minimap'),
              text=[...map.querySelectorAll('text')].find(t=>t.textContent==='T4'),r=text.getBoundingClientRect();
              map.dispatchEvent(new MouseEvent('click',{bubbles:true,clientX:(r.left+r.right)/2,clientY:(r.top+r.bottom)/2}));}
            void 0;
            """)
            try await capture("minimap-node-ids-\(scale*100)",source:source,web:web)
        }
    }
    @Test func ミニマップはカードの色とIDを写し操作中はラベルと色を読み直さない() async throws {
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
                // 背景だけを透かす。親のopacityで箱・ID・表示範囲まで薄くしない。
                #expect(try await web.evaluateJavaScript("""
                (()=>{const map=canvas.querySelector('.board-minimap'),s=getComputedStyle(map),
                  sample=document.createElement('canvas');sample.width=sample.height=1;
                  const context=sample.getContext('2d');context.fillStyle=s.backgroundColor;context.fillRect(0,0,1,1);
                  const alpha=context.getImageData(0,0,1,1).data[3]/255;
                  return Math.abs(alpha-.90)<.01 && s.opacity==='1' && s.backdropFilter==='none' &&
                    [...map.querySelectorAll('rect,text')].every(e=>getComputedStyle(e).opacity==='1') &&
                    [...map.querySelectorAll('svg svg rect')].every(e=>getComputedStyle(e).fillOpacity==='1');})()
                """) as? Bool == true)
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
                    ratio=Math.min(canvas.getBoundingClientRect().width*\(count == 30 ? "0.33" : "0.5")/vb.width,
                      canvas.getBoundingClientRect().height*\(count == 30 ? "0.27" : "0.4")/vb.height);
                  const labels=[...map.querySelectorAll('text')];
                  return nodes.length===\(count) && boxes.length===\(count) && equal && !map.hidden &&
                    labels.length===\(count) && labels.every((t,i)=>t.textContent==='T'+(i+1) && getComputedStyle(t.parentElement).overflow==='hidden') &&
                    [8,9,11,13].every(id=>{const label=node('T'+id).querySelector('.nodeLabel, .label');
                      return label.querySelectorAll('.text-outer-tspan').length>=2 && new RegExp('T'+id+'[A-Z]').test(label.textContent);}) &&
                    !map.querySelector('use,tspan') && Math.abs(w-vb.width*ratio)<.01 && Math.abs(h-vb.height*ratio)<.01;
                })()
                """) as? Bool == true)
                // 決定済みの2行ラベルと1行ラベルが混ざっても、IDの大きさは揃える。
                #expect(try await web.evaluateJavaScript("""
                (()=>{const map=canvas.querySelector('.board-minimap'),boxes=[...map.querySelectorAll('svg svg rect')],
                  labels=[...map.querySelectorAll('text')];
                  return new Set(boxes.map(r=>r.getAttribute('height'))).size>1 &&
                    new Set(labels.map(t=>getComputedStyle(t).fontSize)).size===1 &&
                    labels.every(t=>getComputedStyle(t).fontWeight==='400');})()
                """) as? Bool == true)
                try await capture("colors-\(count)-\(scale*100)-minimap", source: source, web: web)
                if ProcessInfo.processInfo.environment["KIKIGAKI_BOARD_CANVAS_CAPTURE"] != nil {
                    // 空白の上では透け具合を判断できないため、カード本文をミニマップの背後へ動かす。
                    _ = try await web.evaluateJavaScript("""
                    (()=>{const m=canvas.querySelector('.board-minimap').getBoundingClientRect(),p=point('T28');
                      window.overlapPan={x:p.x-(m.left+m.width/2),y:p.y-(m.top+m.height/2)};
                      wheel(false,overlapPan.x,overlapPan.y);flushDiagramFrames();})()
                    """)
                    #expect(try await web.evaluateJavaScript("""
                    (()=>{const m=canvas.querySelector('.board-minimap').getBoundingClientRect(),
                      label=node('T28').querySelector('.nodeLabel, .label').getBoundingClientRect();
                      return label.left>=m.left && label.right<=m.right && label.top>=m.top && label.bottom<=m.bottom;})()
                    """) as? Bool == true)
                    try await capture("colors-\(count)-\(scale*100)-minimap-overlap", source: source, web: web)
                    _ = try await web.evaluateJavaScript("wheel(false,-overlapPan.x,-overlapPan.y);flushDiagramFrames();void 0")
                }
                _ = try await web.evaluateJavaScript("""
                window.cardStyleReads=0;window.savedGetComputedStyle=window.getComputedStyle;
                window.getComputedStyle=function(element,...rest){
                  if(element.closest('.diagram-stage g.node'))cardStyleReads++;
                  return savedGetComputedStyle.call(window,element,...rest);
                };
                window.cardLabelReads=0;window.savedTextContent=Object.getOwnPropertyDescriptor(Node.prototype,'textContent');
                Object.defineProperty(Node.prototype,'textContent',{configurable:true,
                  get(){if(this.nodeType===1 && this.closest('.diagram-stage g.node'))cardLabelReads++;
                    return savedTextContent.get.call(this);},set:savedTextContent.set});
                for(let i=0;i<20;i++)wheel(false,2,1);
                wheel(true,0,-10);
                flushDiagramFrames();void 0;
                """)
                try await Task.sleep(for: .milliseconds(150))
                let reads = try await web.evaluateJavaScript("window.getComputedStyle=savedGetComputedStyle;cardStyleReads") as? Int
                let labelReads = try await web.evaluateJavaScript("Object.defineProperty(Node.prototype,'textContent',savedTextContent);cardLabelReads") as? Int
                #expect(reads == 0)
                #expect(labelReads == 0)
                // 独自classDefへの変更も再描画時に拾う。色表の固定値で写していないことを確かめる。
                try await render(coloredBoard(count: count, custom: true), in: document, reset: false)
                #expect(try await web.evaluateJavaScript("""
                (()=>{const r=canvas.querySelector('.board-minimap svg svg rect'),s=getComputedStyle(r),original=getComputedStyle(node('T1').querySelector('.label-container'));
                  return s.fill==='rgb(206, 233, 221)' && s.stroke==='rgb(68, 119, 102)' && s.strokeWidth==='4px' && s.strokeDasharray===original.strokeDasharray && s.strokeDashoffset===original.strokeDashoffset;})()
                """) as? Bool == true)
            }
            let palette = coloredBoard(count: 5, palette: true)
            try await render(palette, in: document, reset: true)
            try await capture("cards-palette-\(scale*100)", source: palette, web: web)
            #expect(try await web.evaluateJavaScript("getComputedStyle(node('T4').querySelector('.label-container')).fill==='rgb(249, 230, 227)'") as? Bool == true)
        }
    }
    @Test func 古い却下色をボードとミニマップへ上書きし他の節には当てない() async throws {
        let document = MinutesWebView(frame:NSRect(x:0,y:0,width:900,height:850))
        document.boardCanvasEnabled = true
        let window = NSWindow(contentRect:document.frame,styleMask:[.titled],backing:.buffered,defer:false)
        window.contentView = document; window.orderFront(nil)
        defer { document.invalidate(); window.orderOut(nil) }
        let web = document.webView
        let source = coloredBoard(count:30).replacingOccurrences(of:
            "classDef rejected fill:#f9e6e3,color:#9a9a9a,stroke:#c98b84,stroke-width:1px,stroke-dasharray:2 2",
            with:"classDef rejected fill:#f2f2f2,color:#666666,stroke:#b5b5b5,stroke-width:5px,stroke-dasharray:9 7")
        for scale in [1,2] {
            document.setTextScale(CGFloat(scale)); document.boardCanvasEnabled = true
            try await render(source,in:document,reset:true)
            _ = try await web.evaluateJavaScript("press('戻す');void 0")
            #expect(try await web.evaluateJavaScript("""
            (()=>{const s=getComputedStyle(node('T4').querySelector('.label-container')),
              m=getComputedStyle(canvas.querySelectorAll('.board-minimap svg svg rect')[3]),t=getComputedStyle(node('T4').querySelector('text'));
              return s.fill==='rgb(249, 230, 227)' && s.stroke==='rgb(201, 139, 132)' && s.strokeWidth==='1px' &&
                m.fill===s.fill && m.stroke===s.stroke && m.strokeWidth===s.strokeWidth && m.strokeDasharray===s.strokeDasharray &&
                s.strokeDasharray==='\(scale == 1 ? "2px, 2px" : "1px, 1px")' && t.fill==='rgb(154, 154, 154)';})()
            """) as? Bool == true)
            try await capture("legacy-rejected-\(scale*100)-canvas",source:source,web:web)
            document.boardCanvasEnabled = false
            let palette = source.replacingOccurrences(of:"flowchart TB",with:"flowchart LR")
            let minutes = "## 普通の図\n"+palette+"\n## ボード(21:04 更新)\n"+palette+"\n## 別の図\n"+palette
            var rendered = false
            document.onRendered = { _ in rendered = true }; document.render(minutes,reset:true)
            try await wait { rendered }
            #expect(try await web.evaluateJavaScript("""
            (()=>{const diagrams=[...document.querySelectorAll('.diagram-stage')],colors=diagrams.map(d=>getComputedStyle(d.querySelector('g.rejected .label-container')).fill);
              return colors.join('|')==='rgb(242, 242, 242)|rgb(249, 230, 227)|rgb(242, 242, 242)';})()
            """) as? Bool == true)
            // 議事録タブは自然幅で横スクロールする。ボード節の却下が写る位置を撮る。
            _ = try await web.evaluateJavaScript("document.querySelectorAll('.diagram')[1].scrollIntoView();void 0")
            try await capture("legacy-rejected-\(scale*100)-minutes",source:minutes,web:web)
            document.boardHeading = "### 論点"
            rendered = false
            document.render("### 論点(21:04 更新)\n"+palette+"\n### 他の話\n"+palette,reset:true)
            try await wait { rendered }
            #expect(try await web.evaluateJavaScript("""
            [...document.querySelectorAll('.diagram-stage')].map(d=>getComputedStyle(d.querySelector('g.rejected .label-container')).fill).join('|')==='rgb(249, 230, 227)|rgb(242, 242, 242)'
            """) as? Bool == true)
            document.boardHeading = "## ボード"
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
                  const w=parseFloat(s.style.width),h=parseFloat(s.style.height);
                  return !map.hidden && w<=r.width*.5+.01 && h<=r.height*.4+.01 &&
                    (Math.abs(w-r.width*.5)<1 || Math.abs(h-r.height*.4)<1);})()
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
    @Test func 横一列の20論点はIDの下限まで連続的に広がる() async throws {
        // この20論点は1800px幅でも50%上限に達する。2600pxで下限へ届く途中の寸法を検証する。
        let document = MinutesWebView(frame: NSRect(x:0,y:0,width:2600,height:850))
        document.boardCanvasEnabled = true
        let window = NSWindow(contentRect:document.frame,styleMask:[.titled],backing:.buffered,defer:false)
        window.contentView = document; window.orderFront(nil)
        defer { document.invalidate(); window.orderOut(nil) }
        let source = "```mermaid\nflowchart LR\n" + (1...20).map { "T\($0)[\"T\($0)\"]" }.joined(separator:" --> ") + "\n```"
        for scale in [1,2] {
            document.setTextScale(CGFloat(scale))
            try await render(source,in:document,reset:true)
            _ = try await document.webView.evaluateJavaScript("press('戻す');void 0")
            #expect(try await document.webView.evaluateJavaScript("""
            (()=>{const map=canvas.querySelector('.board-minimap'),outer=map.querySelector('svg'),
              drawing=outer.querySelector('svg'),r=canvas.getBoundingClientRect(),vb=outer.viewBox.baseVal,
              w=parseFloat(outer.style.width),h=parseFloat(outer.style.height),texts=[...map.querySelectorAll('text')];
              const font=Number(drawing.dataset.fontSize),normal=Math.min(r.width*.33/vb.width,r.height*.27/vb.height),
                normalScreenFont=font*vb.height/drawing.viewBox.baseVal.height*normal*\(scale);
              return !map.hidden && texts.length===20 && normalScreenFont<7.5 &&
                w>r.width*.33 && w<r.width*.5 && h<=r.height*.4 &&
                Math.abs(w/h-vb.width/vb.height)<.001 &&
                texts.every(t=>Math.abs(parseFloat(t.getAttribute('font-size'))*t.getScreenCTM().a*\(scale)-7.5)<.01);})()
            """) as? Bool == true)
            try await capture("wide-LR-20-\(scale*100)-minimap",source:source,web:document.webView)
        }
    }
}
}
