import AppKit
import WebKit
import Testing
@testable import Kikigaki

extension AppKitTests {
@Suite(.serialized) @MainActor struct DiagramInteractionTests {
    private func wait(_ condition: () async throws -> Bool) async throws {
        for _ in 0..<500 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CocoaError(.coderReadCorrupt)
    }
    private let fixture = """
    # 議事録

    ```swift
    let value = 1
    ```

    ## ボード

    ### 横に長い図

    ```mermaid
    flowchart LR
      T1["T1 料金体系"] --> T2["T2 国内の改定"] --> T3["T3 値上げ幅"] --> T4["T4 海外の扱い"] --> T5["T5 開始時期"] --> T6["T6 顧客への案内"]
      click T1 "#縦に長い図"
    ```

    ### 縦に長い図

    ```mermaid
    flowchart TB
      T1["T1 料金体系"] --> T2["T2 国内の改定"] --> T3["T3 値上げ幅"] --> T4["T4 海外の扱い"] --> T5["T5 開始時期"] --> T6["T6 顧客への案内"]
    ```
    """

    // 実機のボードと同じ、複数の親から3段以上へ伸びる図。利用者の会議は読まない。
    private func growingBoard(updated: Bool) -> String {
        let extra = updated ? "T3 --> T7[\"確認項目を\\n議事録で細分化\"]\nT4 --> T8[\"声で答えた確認\"]\nT5 --> T9[\"図の操作の詳細\"]\nT8 --> T10[\"実機確認の結果\"]" : ""
        return """
        # ボード

        ```mermaid
        flowchart TB
          T1["新KIKIGAKIの動作確認"] --> T3["下の画面の文字サイズ"]
          T1 --> T4["フッターは他は問題なさそう"]
          T1 --> T5["図のピンチとドラッグ"]
          T2["parliamentで起動を明示"] --> T5
          \(extra)
          classDef active fill:#ede0cd,stroke:#9b72c6,stroke-width:3px
          class \(updated ? "T9,T10" : "T3,T5") active
        ```

        [図の操作の詳細](#詳細)

        ## 詳細
        更新後も図の下に置く本文。
        """
    }

    @Test func 続きのある辺だけを示し全体で収めて操作を透過する() async throws {
        let document = MinutesWebView(frame:NSRect(x:0,y:0,width:650,height:1500))
        let window = NSWindow(contentRect:document.frame,styleMask:[.titled],backing:.buffered,defer:false)
        window.contentView = document; window.orderFront(nil)
        defer { document.invalidate(); window.orderOut(nil) }
        let web = document.webView
        let chain = (1...5).map { "T\($0)[\"T\($0) 論点の確認\"]" }.joined(separator:" --> ")
        let branches = (1...5).map { branch in
            (1...4).map { "T\(branch)\($0)[\"論点\(branch)-\($0)の進捗確認\"]" }.joined(separator:" --> ")
        }.joined(separator:"\n")
        let fixtures = [("right","flowchart LR\n" + chain), ("down","flowchart TB\n" + chain),
                        ("both","flowchart TB\n" + branches), ("small","flowchart TB\nA[開始] --> B[終了]")]
        func capture(_ name: String, source: String) async throws {
            guard let path = ProcessInfo.processInfo.environment["KIKIGAKI_DIAGRAM_CAPTURE"] else { return }
            let directory = URL(fileURLWithPath:path).standardizedFileURL
            // 利用者の保存先へ検証データを書かない。PNGは画素比較用の中間物。
            try #require(directory.path.hasPrefix("/tmp/") || directory.path.hasPrefix("/private/tmp/"))
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            try source.write(to:directory.appendingPathComponent(name + ".md"),atomically:true,encoding:.utf8)
            try await Task.sleep(for:.milliseconds(150))
            let image = try await web.takeSnapshot(configuration:WKSnapshotConfiguration())
            let data = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data:data))
            try #require(bitmap.representation(using:.png,properties:[:])).write(to:directory.appendingPathComponent(name + ".png"))
        }
        for scale in [1,2] {
            document.setTextScale(CGFloat(scale))
            for (name,definition) in fixtures {
                let source = "```mermaid\n\(definition)\n```"
                var rendered = false
                document.onRendered = { _ in rendered = true }
                document.render(source,reset:true)
                try await wait { rendered }
                _ = try await web.evaluateJavaScript("""
                window.diagram=document.querySelector('.diagram');
                window.matrix=()=>new DOMMatrix(diagram.querySelector('.diagram-stage').style.transform);
                window.sides=()=>[...diagram.querySelectorAll('.diagram-edge:not([hidden])')].map(e=>e.dataset.side).sort().join(',');
                window.edgesMatch=()=>{
                  const f=diagram.getBoundingClientRect(),s=diagram.querySelector('svg').getBoundingClientRect();
                  const scrollbar=!diagram.classList.contains('diagram-window') && diagram.scrollWidth>diagram.clientWidth+1 ? diagram.offsetHeight-diagram.clientHeight : 0;
                  const expected=[];
                  if(s.left<f.left-1) expected.push('left');
                  if(s.right>f.right+1) expected.push('right');
                  if(s.top<f.top-1) expected.push('top');
                  if(s.bottom>f.bottom-scrollbar+1) expected.push('bottom');
                  return sides()===expected.sort().join(',');
                };
                window.fits=()=>{
                  const f=diagram.getBoundingClientRect(),s=diagram.querySelector('svg').getBoundingClientRect();
                  return s.left>=f.left-1 && s.right<=f.right+1 && s.top>=f.top-1 && s.bottom<=f.bottom+1;
                };
                window.originalBox=diagram.querySelector('svg').getBoundingClientRect().toJSON();
                window.originalSides=sides();
                window.pan=(dx,dy)=>{
                  const r=diagram.getBoundingClientRect();
                  for(const [type,x,y] of [['pointerdown',0,0],['pointermove',dx,dy],['pointerup',dx,dy]]) {
                    diagram.dispatchEvent(new PointerEvent(type,{bubbles:true,cancelable:true,pointerId:1,button:0,clientX:r.left+100+x,clientY:r.top+80+y}));
                  }
                  diagram.click();
                };
                void 0;
                """)
                try await wait { try await web.evaluateJavaScript("edgesMatch()") as? Bool == true }
                #expect(try await web.evaluateJavaScript("matrix().a===1") as? Bool == true)
                let initialGeometry = try await web.evaluateJavaScript("JSON.stringify({sides:sides(),frame:diagram.getBoundingClientRect().toJSON(),svg:diagram.querySelector('svg').getBoundingClientRect().toJSON(),scroll:diagram.scrollLeft})")
                #expect(try await web.evaluateJavaScript("sides()") as? String == (name == "right" || name == "both" ? "right" : ""),"\(name) \(scale): \(initialGeometry ?? "nil")")
                // 初期状態の装飾も本文へ混ぜず、操作を透過する。
                #expect(try await web.evaluateJavaScript("""
                [...diagram.querySelectorAll('.diagram-edges,.diagram-edge')].every(e=>getComputedStyle(e).pointerEvents==='none') &&
                diagram.querySelector('.diagram-edges').getAttribute('aria-hidden')==='true' &&
                diagram.querySelector('.diagram-edges').textContent===''
                """) as? Bool == true)
                #expect(try await web.evaluateJavaScript("window.minutes.search('全体',0,false).count") as? Int == 0)
                try await capture("edges-\(name)-\(scale*100)-before",source:source)
                // 非選択の横スクロールで、左端と右端の表示が入れ替わる。
                if name == "right" || name == "both" {
                    _ = try await web.evaluateJavaScript("diagram.scrollLeft=diagram.scrollWidth; void 0")
                    try await wait { try await web.evaluateJavaScript("sides()==='left' && edgesMatch()") as? Bool == true }
                    #expect(try await web.evaluateJavaScript("""
                    { const f=diagram.getBoundingClientRect(),e=diagram.querySelector('.diagram-edges').getBoundingClientRect();
                      const hit=document.elementFromPoint(f.left+8,f.top+Math.min(40,diagram.clientHeight/2));
                      Math.abs(e.left-f.left)<1 && Math.abs(e.width-diagram.clientWidth)<1 && hit?.closest('.diagram')===diagram && !hit?.closest('.diagram-edges'); }
                    """) as? Bool == true)
                    _ = try await web.evaluateJavaScript("diagram.scrollLeft=0; void 0")
                    try await wait { try await web.evaluateJavaScript("edgesMatch() && sides()===originalSides") as? Bool == true }
                }
                _ = try await web.evaluateJavaScript("diagram.click(); diagram.querySelector('[data-label=\"全体\"]').click()")
                #expect(try await web.evaluateJavaScript("fits() && sides()==='' && edgesMatch()") as? Bool == true,"\(name) \(scale)")
                #expect(try await web.evaluateJavaScript("[...diagram.querySelector('.diagram-controls').children].map(e=>e.dataset.label).join(' ')==='− '+Math.round(matrix().a*100)+'% + 全体 戻す'") as? Bool == true)
                try await capture("edges-\(name)-\(scale*100)-fit",source:source)
                _ = try await web.evaluateJavaScript("pan(-diagram.clientWidth/2,-diagram.clientHeight/2)")
                #expect(try await web.evaluateJavaScript("edgesMatch() && sides().includes('left') && sides().includes('top') && diagram.classList.contains('diagram-selected')") as? Bool == true)
                try await capture("edges-\(name)-\(scale*100)-drag",source:source)
                // 移動した図にも再び全体が効き、戻すは等倍・初期位置へ戻る。
                _ = try await web.evaluateJavaScript("diagram.querySelector('[data-label=\"全体\"]').click()")
                #expect(try await web.evaluateJavaScript("fits() && sides()===''") as? Bool == true,"\(name) \(scale)")
                _ = try await web.evaluateJavaScript("diagram.querySelector('[data-label=\"戻す\"]').click()")
                #expect(try await web.evaluateJavaScript("matrix().a===1 && matrix().e===0 && matrix().f===0 && sides()===originalSides && edgesMatch()") as? Bool == true,"\(name) \(scale)")
                // 拡大で上下の続きも表示し、ホイールは装飾の下へ届く。
                _ = try await web.evaluateJavaScript("""
                for(let i=0;i<4;i++) diagram.querySelector('[data-label="+"]').click();
                window.oldSides=sides();
                window.beforeX=matrix().e;
                { const f=diagram.getBoundingClientRect();
                  const target=document.elementFromPoint(f.left+8,f.top+Math.min(40,diagram.clientHeight/2));
                  const event=new WheelEvent('wheel',{bubbles:true,cancelable:true,deltaX:25,deltaY:20});
                  target.dispatchEvent(event); window.wheelPrevented=event.defaultPrevented; }
                void 0;
                """)
                let geometry = try await web.evaluateJavaScript("JSON.stringify({sides:sides(),oldSides,wheelPrevented,beforeX,x:matrix().e,frame:diagram.getBoundingClientRect().toJSON(),svg:diagram.querySelector('svg').getBoundingClientRect().toJSON()})")
                #expect(try await web.evaluateJavaScript("edgesMatch() && oldSides.includes('top') && oldSides.includes('bottom') && wheelPrevented && Math.abs(matrix().e-beforeX+25)<1") as? Bool == true,"\(name) \(scale): \(geometry ?? "nil")")
                #expect(web.pageZoom == CGFloat(scale))
            }
        }
    }

    @Test func 全体が25パーセントでも収まらない図は中央へ置く() async throws {
        let document = MinutesWebView(frame:NSRect(x:0,y:0,width:480,height:500))
        let window = NSWindow(contentRect:document.frame,styleMask:[.titled],backing:.buffered,defer:false)
        window.contentView = document; window.orderFront(nil)
        defer { document.invalidate(); window.orderOut(nil) }
        let chain = (1...30).map { "T\($0)[\"論点\($0)を確認する\"]" }.joined(separator:" --> ")
        var rendered = false
        document.onRendered = { _ in rendered = true }
        document.render("```mermaid\nflowchart LR\n\(chain)\n```",reset:true)
        try await wait { rendered }
        let web = document.webView
        _ = try await web.evaluateJavaScript("document.querySelector('.diagram').click(); document.querySelector('[data-label=\"全体\"]').click()")
        #expect(try await web.evaluateJavaScript("""
        { const d=document.querySelector('.diagram'),s=d.querySelector('svg').getBoundingClientRect(),f=d.getBoundingClientRect();
          new DOMMatrix(d.querySelector('.diagram-stage').style.transform).a===0.25 &&
          s.width>d.clientWidth && Math.abs((s.left+s.right)/2-(f.left+d.clientWidth/2))<1 &&
          Math.abs((s.top+s.bottom)/2-(f.top+d.clientHeight/2))<1 &&
          [...d.querySelectorAll('.diagram-edge:not([hidden])')].map(e=>e.dataset.side).sort().join(',')==='left,right'; }
        """) as? Bool == true)
        _ = try await web.evaluateJavaScript("document.querySelector('[data-label=\"戻す\"]').click()")
        #expect(try await web.evaluateJavaScript("new DOMMatrix(document.querySelector('.diagram-stage').style.transform).a===1") as? Bool == true)
    }

    @Test func 図の自然寸法へ枠が追従し選択解除でフォーカスも消える() async throws {
        let document = MinutesWebView(frame:NSRect(x:0,y:0,width:1350,height:1000))
        let window = NSWindow(contentRect:document.frame,styleMask:[.titled],backing:.buffered,defer:false)
        window.contentView = document; window.orderFront(nil)
        defer { document.invalidate(); window.orderOut(nil) }
        let web = document.webView
        func render(_ updated: Bool, reset: Bool) async throws {
            var rendered = false
            document.onRendered = { _ in rendered = true }
            document.render(growingBoard(updated:updated),reset:reset)
            try await wait { rendered }
            _ = try await web.evaluateJavaScript("window.diagram=document.querySelector('.diagram'); void 0")
        }
        func capture(_ name: String, scale: Int) async throws {
            guard let path = ProcessInfo.processInfo.environment["KIKIGAKI_DIAGRAM_CAPTURE"] else { return }
            let directory = URL(fileURLWithPath:path)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            try growingBoard(updated:false).write(to:directory.appendingPathComponent("growing-before.md"),atomically:true,encoding:.utf8)
            try growingBoard(updated:true).write(to:directory.appendingPathComponent("growing-after.md"),atomically:true,encoding:.utf8)
            _ = try await web.evaluateJavaScript("diagram.scrollIntoView({block:'start'}); scrollBy(0,-64); window.minutes.search('',0,false)")
            try await Task.sleep(for:.milliseconds(150))
            let image = try await web.takeSnapshot(configuration:WKSnapshotConfiguration())
            let data = try #require(image.tiffRepresentation)
            let bitmap = try #require(NSBitmapImageRep(data:data))
            try #require(bitmap.representation(using:.png,properties:[:])).write(to:
                directory.appendingPathComponent("growing-\(scale*100)-\(name).png"))
        }
        for scale in [1,2] {
            document.setTextScale(CGFloat(scale))
            for mode in ["unselected","selected","deselected"] {
                try await render(false,reset:true)
                _ = try await web.evaluateJavaScript("""
                window.beforeHeight=diagram.getBoundingClientRect().height;
                window.beforeSVG=diagram.querySelector('svg').getBoundingClientRect().toJSON();
                window.edgesFit=()=>{
                  const frame=diagram.getBoundingClientRect(),svg=diagram.querySelector('svg');
                  const viewport=svg.getBoundingClientRect();
                  const nodes=[...svg.querySelectorAll('g.node > rect')];
                  return nodes.length>0 && nodes.every(node=>{
                    const r=node.getBoundingClientRect(),stroke=parseFloat(getComputedStyle(node).strokeWidth)/2;
                    return r.top-stroke>=Math.max(frame.top,viewport.top)+4 &&
                      r.bottom+stroke<=Math.min(frame.bottom,viewport.bottom)-4 &&
                      r.left-stroke>=Math.max(frame.left,viewport.left)+4 &&
                      r.right+stroke<=Math.min(frame.right,viewport.right)-4;
                  });
                };
                void 0;
                """)
                #expect(try await web.evaluateJavaScript("edgesFit()") as? Bool == true)
                try await capture("\(mode)-before",scale:scale)
                if mode != "unselected" {
                    _ = try await web.evaluateJavaScript("diagram.click()")
                    #expect(try await web.evaluateJavaScript("""
                    Math.abs(diagram.getBoundingClientRect().height-beforeHeight)<0.1 &&
                    Math.abs(diagram.querySelector('svg').getBoundingClientRect().x-beforeSVG.x)<0.1 &&
                    Math.abs(diagram.querySelector('svg').getBoundingClientRect().y-beforeSVG.y)<0.1
                    """) as? Bool == true)
                    if mode == "deselected" {
                        _ = try await web.evaluateJavaScript("document.body.click()")
                        #expect(try await web.evaluateJavaScript("!diagram.classList.contains('diagram-selected') && !diagram.contains(document.activeElement) && getComputedStyle(diagram).outlineStyle==='none'") as? Bool == true)
                    }
                }
                try await render(true,reset:false)
                #expect(try await web.evaluateJavaScript("diagram.getBoundingClientRect().height>beforeHeight+100") as? Bool == true)
                #expect(try await web.evaluateJavaScript("edgesFit()") as? Bool == true)
                #expect(try await web.evaluateJavaScript("diagram.classList.contains('diagram-selected')") as? Bool == (mode == "selected"))
                try await capture("\(mode)-after",scale:scale)
                _ = try await web.evaluateJavaScript("diagram.click()")
                try await capture("\(mode)-selection",scale:scale)
                // ズームは枠を変えず、更新は高さだけを変える。倍率と移動量を保つ。
                _ = try await web.evaluateJavaScript("""
                window.grownHeight=diagram.getBoundingClientRect().height;
                diagram.querySelector('[data-label="+"]').click();
                { const r=diagram.getBoundingClientRect();
                diagram.dispatchEvent(new WheelEvent('wheel',{bubbles:true,cancelable:true,deltaX:20,deltaY:30,clientX:r.left+100,clientY:r.top+40}));
                }
                window.transformBeforeUpdate=diagram.querySelector('.diagram-stage').style.transform;
                void 0;
                """)
                #expect(try await web.evaluateJavaScript("Math.abs(diagram.getBoundingClientRect().height-grownHeight)<0.1") as? Bool == true)
                try await render(false,reset:false)
                #expect(try await web.evaluateJavaScript("Math.abs(diagram.getBoundingClientRect().height-beforeHeight)<0.1 && diagram.querySelector('.diagram-stage').style.transform===transformBeforeUpdate") as? Bool == true)
                try await render(true,reset:false)
                _ = try await web.evaluateJavaScript("diagram.querySelector('[data-label=\"戻す\"]').click(); diagram.focus(); document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true}))")
                #expect(try await web.evaluateJavaScript("!diagram.classList.contains('diagram-selected') && !diagram.contains(document.activeElement) && getComputedStyle(diagram).outlineStyle==='none'") as? Bool == true)
                #expect(try await web.evaluateJavaScript("edgesFit()") as? Bool == true)
                try await capture("\(mode)-escape",scale:scale)
                _ = try await web.evaluateJavaScript("diagram.click(); diagram.querySelector('button').focus(); document.body.click()")
                #expect(try await web.evaluateJavaScript("!diagram.classList.contains('diagram-selected') && !diagram.contains(document.activeElement)") as? Bool == true)
                // 非選択の図へもTabで入り直せる。非アクティブな検証用WebViewでは
                // :focusが一致しないため、ここはフォーカスの受入を検証する。
                _ = try await web.evaluateJavaScript("diagram.focus()")
                #expect(try await web.evaluateJavaScript("document.activeElement===diagram && diagram.tabIndex===0") as? Bool == true)
                // 選択履歴のある図が折り畳まれたまま更新されても、高さを0で固定しない。
                _ = try await web.evaluateJavaScript("document.querySelector('.heading-toggle').click()")
                try await render(true,reset:false)
                _ = try await web.evaluateJavaScript("document.querySelector('.heading-toggle').click()")
                #expect(try await web.evaluateJavaScript("diagram.getBoundingClientRect().height>beforeHeight+100 && edgesFit()") as? Bool == true)
            }
        }
    }

    @Test func 図の倍率操作は両タブと文字倍率と目次の開閉によらず重ならない() async throws {
        let preferences = MinutesTestDefaults()
        let preview = MinutesPreviewView(frame:NSRect(x:0,y:0,width:1350,height:1000),defaults:preferences.value)
        // 旧ボード本文の図は議事録と同じ選択操作を使う。全面キャンバスは別suiteで検証する。
        preview.boardDocument.boardCanvasEnabled = false
        let window = NSWindow(contentRect:preview.frame,styleMask:[.titled],backing:.buffered,defer:false)
        window.contentView = preview; window.orderFront(nil); preview.layoutSubtreeIfNeeded()
        defer { preview.stop(); window.orderOut(nil) }
        let tail = Array(repeating:"図の後にも本文が続きます。",count:30).joined(separator:"\n\n")
        let body = growingBoard(updated:true).replacingOccurrences(of:"# ボード\n\n",with:"")
            .replacingOccurrences(of:"## 詳細",with:"### 詳細") + "\n\n" + tail
        preview.update(path:"/tmp/kikigaki-diagram-controls.md",source:.human,active:false,boardHeading:"## ボード")
        preview.receive(.body("# 議事録\n\n" + body + "\n\n## ボード\n\n" + body,[],modifiedAt:Date()))
        try await wait { preview.minutesDocument.renderedText.contains("実機確認の結果") && preview.boardDocument.renderedText.contains("実機確認の結果") }
        for width in [1350,480] {
            window.setContentSize(NSSize(width:width,height:1000)); preview.layoutSubtreeIfNeeded()
            for board in [false,true] {
                preview.selectBoard(board)
                let document = preview.document, web = document.webView
                for scale in [1,2] {
                    preview.setTextScale(CGFloat(scale))
                    var rendered = false
                    document.onRendered = { _ in rendered = true }
                    document.render((board ? "# ボード\n\n" : "# 議事録\n\n") + body,reset:true)
                    try await wait { rendered }
                    _ = try await web.evaluateJavaScript("""
                    window.diagram=document.querySelector('.diagram');
                    window.testTOC=document.getElementById('toc');
                    testTOC.open=false;
                    diagram.click();
                    scrollTo(0,scrollY+diagram.getBoundingClientRect().top-8);
                    window.controlsClear=()=>{
                      const controls=diagram.querySelector('.diagram-controls'),c=controls.getBoundingClientRect();
                      const t=testTOC.getBoundingClientRect(),f=diagram.getBoundingClientRect();
                      const separate=c.right<=t.left-5 || c.left>=t.right+5 || c.bottom<=t.top-5 || c.top>=t.bottom+5;
                      return diagram.classList.contains('diagram-selected') && separate &&
                        c.left>=f.left+5 && c.right<=f.right-5 && c.top>=Math.max(0,f.top)+5 &&
                        [...controls.querySelectorAll('button')].every(button=>{
                          const r=button.getBoundingClientRect();
                          return document.elementFromPoint(r.left+r.width/2,r.top+r.height/2)?.closest('button')===button;
                        });
                    };
                    void 0;
                    """)
                    for open in [false,true,false] {
                        _ = try await web.evaluateJavaScript("testTOC.open=\(open); void 0")
                        try await Task.sleep(for:.milliseconds(150))
                        rendered = false
                        document.render((board ? "# ボード\n\n" : "# 議事録\n\n") + body,reset:false)
                        try await wait { rendered }
                        _ = try await web.evaluateJavaScript("window.diagram=document.querySelector('.diagram'); void 0")
                        let boxes = try await web.evaluateJavaScript("({frame:diagram.getBoundingClientRect().toJSON(),controls:diagram.querySelector('.diagram-controls').getBoundingClientRect().toJSON(),toc:testTOC.getBoundingClientRect().toJSON()})")
                        #expect(try await web.evaluateJavaScript("Math.abs(diagram.getBoundingClientRect().top-8)<1 && controlsClear()") as? Bool == true,"\(boxes ?? "nil")")
                        if let path = ProcessInfo.processInfo.environment["KIKIGAKI_DIAGRAM_CAPTURE"] {
                            let directory = URL(fileURLWithPath:path)
                            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                            let image = try await web.takeSnapshot(configuration:WKSnapshotConfiguration())
                            let data = try #require(image.tiffRepresentation)
                            let bitmap = try #require(NSBitmapImageRep(data:data))
                            try #require(bitmap.representation(using:.png,properties:[:])).write(to:directory.appendingPathComponent(
                                "controls-\(board ? "board" : "minutes")-\(width)-\(scale*100)-\(open ? "open" : "closed").png"))
                        }
                    }
                    // 横長の低い図でも、目次の下へ逃がした操作列を枠で切らない。
                    if width == 480 && scale == 2 {
                        rendered = false
                        document.render((board ? "# ボード\n\n" : "# 議事録\n\n") +
                            "```mermaid\nflowchart LR\nA[開始] --> B[終了]\n```\n\n### 詳細\n\n" + tail,reset:false)
                        try await wait { rendered }
                        _ = try await web.evaluateJavaScript("window.diagram=document.querySelector('.diagram'); testTOC.open=true; scrollTo(0,scrollY+diagram.getBoundingClientRect().top-8); void 0")
                        try await Task.sleep(for:.milliseconds(150))
                        #expect(try await web.evaluateJavaScript("controlsClear() && diagram.querySelector('.diagram-controls').getBoundingClientRect().bottom>diagram.getBoundingClientRect().bottom") as? Bool == true)
                        if let path = ProcessInfo.processInfo.environment["KIKIGAKI_DIAGRAM_CAPTURE"] {
                            let image = try await web.takeSnapshot(configuration:WKSnapshotConfiguration())
                            let data = try #require(image.tiffRepresentation)
                            let bitmap = try #require(NSBitmapImageRep(data:data))
                            try #require(bitmap.representation(using:.png,properties:[:])).write(to:
                                URL(fileURLWithPath:path).appendingPathComponent("controls-\(board ? "board" : "minutes")-short-200-open.png"))
                        }
                    }
                    _ = try await web.evaluateJavaScript("document.body.click(); testTOC.open=false; void 0")
                }
            }
        }
    }

    @Test func WKWebViewはページ拡大を無効にしてもネイティブピンチをDOMへ送る() async throws {
        let document = MinutesWebView(frame:NSRect(x:0,y:0,width:900,height:850))
        let window = NSWindow(contentRect:document.frame,styleMask:[.titled],backing:.buffered,defer:false)
        window.contentView = document; window.orderFront(nil)
        defer { document.invalidate(); window.orderOut(nil) }
        document.render("```mermaid\nflowchart LR\nT1[\"料金\"] --> T2[\"海外\"]\n```",reset:true)
        try await wait { document.renderedText.contains("海外") }
        let web = document.webView
        let rect = try #require(try await web.evaluateJavaScript("""
        window.nativeGestures=[];
        for (const type of ['gesturestart','gesturechange','gestureend']) {
          document.addEventListener(type,e=>nativeGestures.push({type,scale:e.scale}),true);
        }
        document.querySelector('.diagram').click();
        const r=document.querySelector('.diagram').getBoundingClientRect();
        ({x:r.left+100,y:r.top+40});
        """) as? [String:Double])
        let point = web.convert(NSPoint(x:try #require(rect["x"]),y:try #require(rect["y"])),to:nil)
        for (phase, amount) in [(NSEvent.Phase.began,CGFloat(0)),(.changed,0.5),(.ended,0)] {
            web.magnify(with:DiagramMagnifyEvent(location:point,window:window,amount:amount,phase:phase))
            try await Task.sleep(for:.milliseconds(30))
        }
        try await wait { try await web.evaluateJavaScript("nativeGestures.length===3") as? Bool == true }
        #expect(try await web.evaluateJavaScript("nativeGestures.map(e=>e.type).join(',')==='gesturestart,gesturechange,gestureend'") as? Bool == true)
        #expect(try await web.evaluateJavaScript("new DOMMatrix(document.querySelector('.diagram-stage').style.transform).a > 1") as? Bool == true)
        #expect(!web.allowsMagnification && web.magnification == 1 && web.pageZoom == 1)
    }

    @Test func Mermaid図を選択してズームと移動を行い再描画で保持する() async throws {
        let preferences = MinutesTestDefaults()
        let preview = MinutesPreviewView(frame: NSRect(x:0, y:0, width:900, height:850), defaults:preferences.value)
        preview.boardDocument.boardCanvasEnabled = false
        let window = NSWindow(contentRect:preview.frame, styleMask:[.titled], backing:.buffered, defer:false)
        window.contentView = preview; window.orderFront(nil); preview.layoutSubtreeIfNeeded()
        defer { preview.stop(); window.orderOut(nil) }
        let parts = fixture.components(separatedBy:"## ボード\n\n")
        let boardSource = try #require(parts.last)
        let minutesSource = try #require(parts.first) + boardSource
        preview.update(path:"/tmp/kikigaki-diagram-fixture.md", source:.human, active:false, boardHeading:"## ボード")
        preview.receive(.body(minutesSource + "\n\n## ボード\n\n" + boardSource, [], modifiedAt:Date()))
        try await wait { preview.boardDocument.renderedText.contains("T6 顧客への案内") && preview.minutesDocument.renderedText.contains("T6 顧客への案内") }
        // 両タブとも同じ操作を使う。通常テストでは撮影しない。
        for board in [false, true] {
            preview.selectBoard(board)
            let document = preview.document, web = document.webView
            #expect(!web.allowsMagnification)
            #expect(try await web.evaluateJavaScript("document.querySelectorAll('.diagram').length") as? Int == 2,
                    "\(document.renderedText)")
            _ = try await web.evaluateJavaScript("""
            window.diagram = document.querySelector('.diagram');
            window.matrix = () => new DOMMatrix(diagram.querySelector('.diagram-stage').style.transform);
            window.wheel = (ctrl, deltaX, deltaY) => {
              const r = diagram.getBoundingClientRect();
              const e = new WheelEvent('wheel', {bubbles:true,cancelable:true,ctrlKey:ctrl,deltaX,deltaY,clientX:r.left+100,clientY:r.top+40});
              window.wheelPoint={x:e.clientX-r.left,y:e.clientY-r.top};
              diagram.dispatchEvent(e); return e.defaultPrevented;
            };
            window.gesture = (type, scale) => {
              const r = diagram.getBoundingClientRect();
              const e = new Event(type, {bubbles:true,cancelable:true});
              Object.defineProperties(e,{scale:{value:scale},clientX:{value:r.left+100},clientY:{value:r.top+40}});
              diagram.dispatchEvent(e); return e.defaultPrevented;
            };
            window.drag = () => {
              const r = diagram.getBoundingClientRect();
              for (const [type,x,y] of [['pointerdown',100,45],['pointermove',135,70],['pointerup',135,70]]) {
                diagram.dispatchEvent(new PointerEvent(type,{bubbles:true,cancelable:true,pointerId:1,button:0,clientX:r.left+x,clientY:r.top+y}));
              }
              diagram.click();
            };
            window.originalHeight = diagram.getBoundingClientRect().height;
            window.originalSVG = diagram.querySelector('svg').getBoundingClientRect().toJSON();
            """)
            #expect(try await web.evaluateJavaScript("wheel(false, 0, 50) || wheel(true, 0, -50) || gesture('gesturestart',1) || gesture('gesturechange',2)") as? Bool == false)
            #expect(try await web.evaluateJavaScript("matrix().a === 1 && matrix().e === 0 && matrix().f === 0") as? Bool == true)
            _ = try await web.evaluateJavaScript("diagram.scrollLeft=35; window.originalSVG=diagram.querySelector('svg').getBoundingClientRect().toJSON()")
            _ = try await web.evaluateJavaScript("diagram.click()")
            #expect(try await web.evaluateJavaScript("diagram.classList.contains('diagram-selected') && getComputedStyle(diagram).cursor === 'grab'") as? Bool == true)
            #expect(try await web.evaluateJavaScript("Math.abs(diagram.getBoundingClientRect().height-originalHeight)<0.1 && Math.abs(diagram.querySelector('svg').getBoundingClientRect().x-originalSVG.x)<0.1") as? Bool == true)
            _ = try await web.evaluateJavaScript("diagram.querySelector('[data-label=\"戻す\"]').click()")
            #expect(try await web.evaluateJavaScript("wheel(true,0,-Math.log(2)/0.01)") as? Bool == true)
            #expect(try await web.evaluateJavaScript("Math.abs(matrix().a-2)<0.001 && Math.abs(matrix().e+wheelPoint.x)<0.01 && Math.abs(matrix().f+wheelPoint.y)<0.01") as? Bool == true)
            // 上限下限と戻す。文字倍率は変えない。
            _ = try await web.evaluateJavaScript("wheel(true,0,-10000)")
            #expect(try await web.evaluateJavaScript("matrix().a") as? Double == 4)
            _ = try await web.evaluateJavaScript("wheel(true,0,10000)")
            #expect(try await web.evaluateJavaScript("matrix().a") as? Double == 0.25)
            _ = try await web.evaluateJavaScript("diagram.querySelector('[data-label=\"戻す\"]').click()")
            #expect(try await web.evaluateJavaScript("matrix().a===1 && matrix().e===0 && matrix().f===0") as? Bool == true)
            #expect(try await web.evaluateJavaScript("gesture('gesturestart',1) && gesture('gesturechange',2) && matrix().a===2") as? Bool == true)
            _ = try await web.evaluateJavaScript("wheel(true,0,-50)")
            #expect(try await web.evaluateJavaScript("matrix().a") as? Double == 2)
            _ = try await web.evaluateJavaScript("gesture('gestureend',2); wheel(false,20,30); drag()")
            #expect(try await web.evaluateJavaScript("Math.abs(matrix().e+85)<0.01 && Math.abs(matrix().f+45)<0.01 && !diagram.classList.contains('diagram-dragging')") as? Bool == true)
            #expect(web.pageZoom == 1)
            #expect(try await web.evaluateJavaScript("window.minutes.search('戻す',0,false).count") as? Int == 0)
            #expect(try await web.evaluateJavaScript("window.minutes.search('T1 料金体系',0,false).count") as? Int == 2)
            _ = try await web.evaluateJavaScript("window.savedTransform=diagram.querySelector('.diagram-stage').style.transform")
            document.markUpdateBaseline()
            let source = board ? boardSource : minutesSource
            var rendered = false
            let original = document.onRendered
            document.onRendered = { text in original?(text); rendered = true }
            document.render(source, reset:false)
            try await wait { rendered }
            document.onRendered = original
            _ = try await web.evaluateJavaScript("window.diagram=document.querySelector('.diagram'); void 0")
            #expect(try await web.evaluateJavaScript("diagram.classList.contains('diagram-selected') && diagram.querySelector('.diagram-stage').style.transform===savedTransform") as? Bool == true)
            #expect(try await web.evaluateJavaScript("!CSS.highlights.has('updated')") as? Bool == true)
            // 本文更新でも図の状態と検索を維持する。
            document.render(source.replacingOccurrences(of:"T3 値上げ幅",with:"T3 更新した幅"), reset:false)
            try await wait { document.renderedText.contains("T3 更新した幅") }
            _ = try await web.evaluateJavaScript("window.diagram=document.querySelector('.diagram'); void 0")
            #expect(try await web.evaluateJavaScript("diagram.querySelector('.diagram-stage').style.transform===savedTransform && CSS.highlights.has('updated')") as? Bool == true)
            #expect(try await web.evaluateJavaScript("window.minutes.search('更新した幅',0,false).count") as? Int == 2)
            _ = try await web.evaluateJavaScript("document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true}))")
            #expect(try await web.evaluateJavaScript("!diagram.classList.contains('diagram-selected') && !wheel(false,20,30) && !wheel(true,0,-50) && !gesture('gesturestart',1) && diagram.querySelector('.diagram-stage').style.transform===savedTransform") as? Bool == true)
            _ = try await web.evaluateJavaScript("diagram.click(); document.body.click()")
            #expect(try await web.evaluateJavaScript("!diagram.classList.contains('diagram-selected')") as? Bool == true)
            _ = try await web.evaluateJavaScript("diagram.click(); document.querySelectorAll('.diagram')[1].click()")
            #expect(try await web.evaluateJavaScript("document.querySelectorAll('.diagram-selected').length===1 && !diagram.classList.contains('diagram-selected')") as? Bool == true)
            document.render(source, reset:true)
            try await wait { !document.renderedText.contains("更新した幅") }
            #expect(try await web.evaluateJavaScript("[...document.querySelectorAll('.diagram-stage')].every(s=>new DOMMatrix(s.style.transform).a===1) && !document.querySelector('.diagram-selected')") as? Bool == true)
        }
        if let path = ProcessInfo.processInfo.environment["KIKIGAKI_DIAGRAM_CAPTURE"] {
            preview.selectBoard(true)
            let directory = URL(fileURLWithPath:path)
            try FileManager.default.createDirectory(at:directory, withIntermediateDirectories:true)
            try fixture.write(to:directory.appendingPathComponent("fixture.md"), atomically:true, encoding:.utf8)
            let document = preview.document, web = document.webView
            for scale in [1,2] {
                preview.setTextScale(CGFloat(scale))
                var rendered = false
                let original = document.onRendered
                document.onRendered = { text in original?(text); rendered = true }
                document.render(fixture, reset:true)
                try await wait { rendered }
                document.onRendered = original
                for (index, name) in ["wide","tall"].enumerated() {
                    _ = try await web.evaluateJavaScript("window.diagram=document.querySelectorAll('.diagram')[\(index)]; diagram.scrollIntoView({block:'start'}); window.minutes.search('',0,false)")
                    for mode in ["before","enlarged","reduced","dragged"] {
                        switch mode {
                        case "before": _ = try await web.evaluateJavaScript("document.body.click()")
                        case "enlarged": _ = try await web.evaluateJavaScript("diagram.click(); wheel(true,0,-Math.log(2)/0.01)")
                        case "reduced": _ = try await web.evaluateJavaScript("wheel(true,0,Math.log(4)/0.01)")
                        default: _ = try await web.evaluateJavaScript("drag()")
                        }
                        try await Task.sleep(for:.milliseconds(150))
                        let image = try await web.takeSnapshot(configuration:WKSnapshotConfiguration())
                        let data = try #require(image.tiffRepresentation)
                        let bitmap = try #require(NSBitmapImageRep(data:data))
                        try #require(bitmap.representation(using:.png, properties:[:])).write(to:
                            directory.appendingPathComponent("\(name)-\(scale*100)-\(mode).png"))
                    }
                }
            }
        }
    }
}
}

// WebKitのEventSenderProxyと同様にmagnifyWithEventへ渡す、テスト専用NSEvent。
// 必要な値を公開プロパティのoverrideで供給し、AppKitの私有生成APIは使わない。
private final class DiagramMagnifyEvent: NSEvent {
    private let eventLocation: NSPoint
    private let eventWindow: NSWindow
    private let amount: CGFloat
    private let eventPhase: NSEvent.Phase
    init(location:NSPoint,window:NSWindow,amount:CGFloat,phase:NSEvent.Phase) {
        eventLocation=location; eventWindow=window; self.amount=amount; eventPhase=phase
        super.init()
    }
    required init?(coder:NSCoder) { fatalError() }
    override var type:NSEvent.EventType { .magnify }
    override var locationInWindow:NSPoint { eventLocation }
    override var window:NSWindow? { eventWindow }
    override var windowNumber:Int { eventWindow.windowNumber }
    override var magnification:CGFloat { amount }
    override var phase:NSEvent.Phase { eventPhase }
    override var momentumPhase:NSEvent.Phase { [] }
    override var timestamp:TimeInterval { ProcessInfo.processInfo.systemUptime }
    override var modifierFlags:NSEvent.ModifierFlags { [] }
}
