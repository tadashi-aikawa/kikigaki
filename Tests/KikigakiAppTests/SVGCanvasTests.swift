import AppKit
import WebKit
import Testing
@testable import Kikigaki

// SVGの図を切り離したiframeで描く。仕様は docs/svg-canvas.md。
extension AppKitTests {
@Suite(.serialized) @MainActor struct SVGCanvasTests {
    private func wait(_ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(Bool(false), "WebKitの表示が30秒以内に完了しません")
    }
    private func open(_ fixture: String, in root: URL, width: CGFloat = 900) async throws -> (MinutesPreviewView, NSWindow, URL) {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let file = root.appendingPathComponent("議事録.md")
        try Data(fixture.utf8).write(to: file)
        let preferences = MinutesTestDefaults()
        let preview = MinutesPreviewView(frame: NSRect(x: 0, y: 0, width: width, height: 900), defaults: preferences.value)
        let window = NSWindow(contentRect: preview.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = preview; window.orderFront(nil); preview.layoutSubtreeIfNeeded()
        preview.update(path: file.path, source: .human, active: true)
        return (preview, window, file)
    }
    private func ready(_ web: WKWebView, count: Int) async throws {
        try await wait {
            try await web.evaluateJavaScript("document.querySelectorAll('.svg-canvas[data-ready]').length") as? Int == count
        }
    }

    @Test func 図をiframeで描き外のファイルへの参照を絞る() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("shots"), withIntermediateDirectories: true)
        let pixel = #"<svg xmlns="http://www.w3.org/2000/svg" width="4" height="4"><rect width="4" height="4" fill="red"/></svg>"#
        try Data(pixel.utf8).write(to: root.appendingPathComponent("shots/画面.svg"))
        let absolute = root.appendingPathComponent("絶対.svg"); try Data(pixel.utf8).write(to: absolute)
        let fixture = """
        # 図の確認

        ## 決定事項 {#decisions}

        本文。

        <svg id="kpt" viewBox="0 0 1000 400" onload="parent.postMessage('attr','*')">
          <defs>
            <linearGradient id="g"><stop offset="0" stop-color="#d9efc9"/><stop offset="1" stop-color="#fbd9cf"/></linearGradient>
            <style>
              @import url("https://example.invalid/a.css");
              .note { fill: url(#g); }
              .bad { fill: url(https://example.invalid/b.svg#x); background: u\\72l(https://example.invalid/c.png); }
              .var { --p: "https://example.invalid/d.png"; background-image: image-set(var(--p) 1x); }
            </style>
          </defs>
          <script>parent.postMessage('inline','*')</script>
          <script src="minutes-app://bundle/canvas.js"></script>
          <rect class="note" width="1000" height="400" fill="url(#g)" filter="url(https://example.invalid/e.svg#f)"/>
          <g id="k1" data-kind="note" style="fill:url(#g);background:url(https://example.invalid/f.png)"><rect width="100" height="60"/></g>
          <image id="relative" x="10" y="10" width="40" height="40" xlink:href="ignored.png" href="shots/画面.svg"/>
          <image id="absolute" x="60" y="10" width="40" height="40" xlink:href="\(absolute.path)"/>
          <image id="missing" x="110" y="10" width="40" height="40" href="無い.png"/>
          <image id="own" x="160" y="10" width="40" height="40" href="minutes-image://forged/?path=/etc/hosts.png"/>
          <use href="https://example.invalid/g.svg#x"/><use href="#k1" x="200"/>
          <foreignObject x="300" y="10" width="200" height="100"><div xmlns="http://www.w3.org/1999/xhtml">折り返す文<img src="shots/画面.svg" srcset="https://example.invalid/h.png 2x"><iframe srcdoc="x"></iframe><form><input></form></div></foreignObject>
          <a href="#decisions"><rect id="inner" x="0" y="300" width="500" height="100" fill="blue"/></a>
          <a xlink:href="https://example.com/page"><rect id="outer" x="500" y="300" width="500" height="100" fill="green"/></a>
          <circle r="5"><animate attributeName="cx" values="0;10" dur="1s"/><set attributeName="href" to="https://example.invalid/i.png"/></circle>
        </svg>

        ~~~svg
        <svg width="200" height="100" viewBox="0 0 1000 500"><text x="10" y="40">受付&nbsp;&copy;</text></svg>
        ~~~
        """
        let (preview, window, _) = try await open(fixture, in: root, width: 700)
        defer { preview.stop(); window.orderOut(nil) }
        let web = preview.document.webView
        try await wait { preview.document.renderedText.contains("図の確認") }
        try await ready(web, count: 2)
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('main img').length") as? Int == 0)
        let document = try #require(try await web.evaluateJavaScript("document.querySelector('.svg-canvas iframe').srcdoc") as? String)
        // 外のファイルを指せるのは image・img・a だけ。CSSの url() は同じ図の中の参照だけが残る。
        #expect(!document.contains("example.invalid"))
        #expect(!document.contains("example.com"))
        #expect(!document.contains("postMessage"))
        #expect(!document.contains("<iframe") && !document.contains("<form") && !document.contains("<input"))
        #expect(!document.contains("forged") && !document.contains("ignored.png") && !document.contains("xlink:href"))
        #expect(!document.contains("srcset") && !document.contains("onload"))
        #expect(document.contains(##"url("#g")"##))
        #expect(document.contains("attributeName=\"cx\"") && !document.contains("attributeName=\"href\""))
        #expect(document.contains(##"<use href="#k1""##))
        #expect(document.components(separatedBy: "minutes-image://").count == 5)
        #expect(document.components(separatedBy: "<script").count == 2)
        // 読めなかった画像は、図の下に件数で出る。
        try await wait {
            try await web.evaluateJavaScript("document.querySelector('.svg-canvas + .image-error')?.textContent") as? String == "図の中の画像を表示できません: 1件"
        }
        // 表示する大きさは width と height が先。ペイン幅を超える図は幅へ収め、小さい図は引き伸ばさない。
        let sizes = try #require(try await web.evaluateJavaScript("""
            [...document.querySelectorAll('.svg-canvas')].map(h => { const r = h.getBoundingClientRect(), f = h.querySelector('iframe').getBoundingClientRect();
              return [r.width, r.height, f.width, f.height, document.querySelector('main').clientWidth]; })
            """) as? [[Double]])
        #expect(abs(sizes[0][0] - sizes[0][4]) < 1 && abs(sizes[0][1] - sizes[0][0] * 0.4) < 1)
        #expect(abs(sizes[0][2] - sizes[0][0]) < 1 && abs(sizes[0][3] - sizes[0][1]) < 1)
        #expect(abs(sizes[1][0] - 200) < 1 && abs(sizes[1][1] - 100) < 1 && abs(sizes[1][2] - 200) < 1)
    }

    @Test func 折りたたんだ節の図は開くと幅へ収まり続けて描き直しても最後の図だけが残る() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        // 幅へ収めると倍率の下限25%を下回る、大きな図。
        let figure = ##"<svg id="wide" viewBox="0 0 4000 1000"><rect width="4000" height="1000" fill="#d9efc9"/><a href="https://example.com/"><rect width="4000" height="1000" fill-opacity="0"/></a></svg>"##
        let fixture = "# 図\n\n## 節\n\n本文その1\n\n\(figure)\n"
        let (preview, window, _) = try await open(fixture, in: root, width: 700)
        defer { preview.stop(); window.orderOut(nil) }
        final class Opened { var urls: [URL] = [] }
        let opened = Opened()
        preview.document.openURL = { opened.urls.append($0) }
        let web = preview.document.webView
        try await wait { preview.document.renderedText.contains("本文その1") }
        try await ready(web, count: 1)
        // 節を折りたたんで描き直す。幅を測れない間に作った図も、開いたときにペイン幅へ収まる。
        _ = try await web.evaluateJavaScript("document.querySelectorAll('.heading-toggle')[1].click()")
        preview.document.render(fixture.replacingOccurrences(of: "本文その1", with: "本文その2"), reset: false)
        try await wait { preview.document.renderedText.contains("図") && !preview.document.renderedText.contains("本文その1") }
        try await ready(web, count: 1)
        _ = try await web.evaluateJavaScript("document.querySelectorAll('.heading-toggle')[1].click()")
        try await wait {
            try await web.evaluateJavaScript("""
                (() => { const f = document.querySelector('.svg-canvas'), r = f.getBoundingClientRect(), main = document.querySelector('main').clientWidth;
                  const scale = new DOMMatrix(getComputedStyle(f.querySelector('.diagram-stage')).transform).a;
                  return Math.abs(r.width - main) < 1 && Math.abs(r.height - main / 4) < 1 && Math.abs(scale - main / 4000) < 0.005; })()
                """) as? Bool == true
        }
        // 「全体」は、本文の中ではペイン幅へ、広げた図ではペイン全体へ収める。倍率の下限25%へ拡大してはみ出さない。
        #expect(try await web.evaluateJavaScript("""
            (() => { const f = document.querySelector('.svg-canvas'), main = document.querySelector('main').clientWidth;
              const scale = () => new DOMMatrix(getComputedStyle(f.querySelector('.diagram-stage')).transform).a;
              const r = f.getBoundingClientRect();
              f.dispatchEvent(new MouseEvent('click', { bubbles:true, cancelable:true, clientX:r.left + 20, clientY:r.top + 20 }));
              f.dispatchEvent(new WheelEvent('wheel', { bubbles:true, cancelable:true, ctrlKey:true, deltaY:-80, clientX:r.left + 20, clientY:r.top + 20 }));
              const zoomed = scale();
              f.querySelector('[data-label=全体]').click();
              const fitted = scale();
              f.querySelector('[data-label=広げる]').click();
              const expanded = scale();
              f.querySelector('[data-label=全体]').click();
              const refitted = scale();
              f.querySelector('[data-label=たたむ]').click();
              document.dispatchEvent(new KeyboardEvent('keydown', { key:'Escape', bubbles:true, cancelable:true }));
              return zoomed > main / 4000 + 0.01 && Math.abs(fitted - main / 4000) < 0.005
                && Math.abs(expanded - Math.min(innerWidth / 4000, innerHeight / 1000)) < 0.005 && Math.abs(refitted - expanded) < 0.001
                && Math.abs(scale() - main / 4000) < 0.005; })()
            """) as? Bool == true)
        // 続けて描き直す。前の描画の図は捨てられ、最後の図だけがクリックに答える。
        for round in 3...6 {
            preview.document.render(fixture.replacingOccurrences(of: "本文その1", with: "本文その\(round)"), reset: false)
        }
        try await wait { preview.document.renderedText.contains("本文その6") }
        try await ready(web, count: 1)
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('.svg-canvas').length === 1 && document.querySelectorAll('.svg-canvas iframe').length === 1") as? Bool == true)
        _ = try await web.evaluateJavaScript("""
            { const f = document.querySelector('.svg-canvas'), r = f.getBoundingClientRect();
              for (let i = 0; i < 2; i++) f.dispatchEvent(new MouseEvent('click', { bubbles:true, cancelable:true, clientX:r.left + 20, clientY:r.top + 20 })); } void 0
            """)
        try await wait { opened.urls.count == 1 }
        try await Task.sleep(for: .milliseconds(200))
        #expect(opened.urls.map(\.absoluteString) == ["https://example.com/"])
        // 取消で本文を隠したあとは、遅れて届いた返答でリンクを開かない。
        _ = try await web.evaluateJavaScript("""
            { const f = document.querySelector('.svg-canvas'), r = f.getBoundingClientRect();
              f.dispatchEvent(new MouseEvent('click', { bubbles:true, cancelable:true, clientX:r.left + 20, clientY:r.top + 20 }));
              window.minutes.invalidate(); } void 0
            """)
        try await Task.sleep(for: .milliseconds(400))
        #expect(opened.urls.count == 1)
    }

    @Test func ボードタブで描く文書の図は従来どおり画像にする() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let document = MinutesWebView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        document.boardLinksEnabled = true
        let window = NSWindow(contentRect: document.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = document; window.orderFront(nil)
        defer { window.orderOut(nil) }
        document.render("""
            ボードの本文

            <svg width="240" height="70">
              <rect width="240" height="70" fill="teal"/><text x="20" y="40">退場&nbsp;&copy;</text>
            </svg>
            """, reset: true)
        try await wait { document.renderedText.contains("ボードの本文") }
        let web = document.webView
        try await wait {
            try await web.evaluateJavaScript("[...document.querySelectorAll('main img')].length === 1 && document.querySelector('main img').complete && document.querySelector('main img').naturalWidth > 0") as? Bool == true
        }
        // xmlnsが無くHTMLだけの実体参照を含む図も、XMLへ書き直して画像として読める。
        #expect(try await web.evaluateJavaScript("document.querySelectorAll('.svg-canvas, main .image-error').length === 0 && decodeURIComponent(document.querySelector('main img').src).includes('退場\\u00a0©')") as? Bool == true)
    }

    // 無害化を通さない原文をiframeへ入れても、sandboxと子のCSPと遷移の判定が止めることを確かめる。
    @Test func 無害化が漏らしてもscriptと入れ子と遷移はiframeの中で止まる() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let (preview, window, _) = try await open("# 境界\n\n本文", in: root)
        defer { preview.stop(); window.orderOut(nil) }
        let web = preview.document.webView
        try await wait { preview.document.renderedText.contains("境界") }
        let markup = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10" onload="parent.postMessage('attr','*')">
          <script>parent.postMessage('inline','*')</script>
          <script href="minutes-app://bundle/canvas.js"></script>
          <script xlink:href="minutes-app://bundle/canvas.js"></script>
          <foreignObject width="10" height="10"><div xmlns="http://www.w3.org/1999/xhtml">
            <script src="minutes-app://bundle/canvas.js"></script>
            <iframe srcdoc="&lt;script&gt;top.postMessage('nested','*')&lt;/script&gt;"></iframe>
            <meta http-equiv="refresh" content="0;url=https://example.invalid/">
            <img src="x" onerror="parent.postMessage('handler','*')">
          </div></foreignObject>
          <a data-link="0"><rect width="10" height="10"/></a>
        </svg>
        """
        func run(childCSP: Bool) async throws -> [String] {
            try #require(try await web.callAsyncJavaScript("""
                const seen = [], listener = event => seen.push(typeof event.data === 'string' ? event.data : event.data?.kind);
                addEventListener('message', listener);
                const frame = document.createElement('iframe'); frame.setAttribute('sandbox', 'allow-scripts');
                frame.style.cssText = 'width:100px;height:100px';
                const source = window.minutes.figureDocument(markup);
                // 対照: 子のCSPだけを外す。継いだCSPは残る。
                frame.srcdoc = childCSP ? source : source.replace(/<meta http-equiv="Content-Security-Policy"[^>]*>/, '').replace(/ nonce="[^"]*"/, '');
                document.body.append(frame);
                await new Promise(resolve => setTimeout(resolve, 1500));
                // 遷移が止まっていれば、同じ文書がまだ返事をする。
                frame.contentWindow.postMessage({ kind:'hit', seq:1, x:5, y:5 }, '*');
                await new Promise(resolve => setTimeout(resolve, 500));
                removeEventListener('message', listener); frame.remove();
                return seen;
                """, arguments: ["markup": markup, "childCSP": childCSP], contentWorld: .page) as? [String])
        }
        #expect(try await run(childCSP: true).sorted() == ["hit", "ready"])
        // 子のCSPを外すと、SVGが書いた同梱のスクリプトへの参照が読まれる。上の結果が子のCSPの働きだと分かる。
        // inlineのscript・イベント属性・入れ子は、継いだCSPとsandboxが止めたまま。
        let control = try await run(childCSP: false)
        #expect(control.contains("duplicate"))
        #expect(control.filter { $0 != "duplicate" }.sorted() == ["hit", "ready"])
    }

    @Test func 図を選んで拡大縮小し広げてたたみ図の中のリンクを開く() async throws {
        let root = try testDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let fixture = """
        # 操作

        ## 決定事項 {#decisions}

        本文その1

        <svg id="kpt" viewBox="0 0 1000 400">
          <rect width="1000" height="400" fill="#fafaf7"/>
          <a href="#decisions"><rect x="0" y="300" width="300" height="100" fill="blue"/></a>
          <a href="https://example.com/page"><rect x="350" y="300" width="300" height="100" fill="green"/></a>
          <a href="file:///etc/hosts"><rect x="700" y="300" width="300" height="100" fill="red"/></a>
        </svg>
        """
        let (preview, window, file) = try await open(fixture, in: root, width: 700)
        defer { preview.stop(); window.orderOut(nil) }
        final class Opened { var urls: [URL] = [] }
        let opened = Opened()
        preview.document.openURL = { opened.urls.append($0) }
        let web = preview.document.webView
        try await wait { preview.document.renderedText.contains("操作") }
        try await ready(web, count: 1)
        _ = try await web.evaluateJavaScript("""
            window.figure = () => document.querySelector('.svg-canvas');
            window.scaleOf = () => new DOMMatrix(getComputedStyle(figure().querySelector('.diagram-stage')).transform).a;
            // 図の中の座標 (viewBoxの単位) をクリックする。
            window.clickAt = (x, y) => { const r = figure().getBoundingClientRect(), m = new DOMMatrix(getComputedStyle(figure().querySelector('.diagram-stage')).transform);
              figure().dispatchEvent(new MouseEvent('click', { bubbles:true, cancelable:true, clientX:r.left + m.e + x * m.a, clientY:r.top + m.f + y * m.d })); };
            window.escape = () => document.dispatchEvent(new KeyboardEvent('keydown', { key:'Escape', bubbles:true, cancelable:true }));
            void 0;
            """)
        func check(_ script: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
            #expect(try await web.evaluateJavaScript(script) as? Bool == true, sourceLocation: sourceLocation)
        }
        for scale in [1, 2] {
            preview.document.setTextScale(CGFloat(scale))
            try await wait { try await web.evaluateJavaScript("Math.abs(scaleOf() - figure().clientWidth / 1000) < 0.01") as? Bool == true }
            // 最初のクリックは図を選ぶだけ。リンクは開かない。
            _ = try await web.evaluateJavaScript("clickAt(500, 350)")
            try await check("figure().classList.contains('diagram-selected') && getComputedStyle(figure().querySelector('.diagram-controls')).display === 'flex'")
            try await Task.sleep(for: .milliseconds(200))
            #expect(opened.urls.isEmpty)
            // 選んだ図の中のクリックは、iframeへ場所を尋ねてリンクを開く。
            _ = try await web.evaluateJavaScript("clickAt(500, 350)")
            try await wait { opened.urls.count == 1 }
            #expect(opened.urls.first?.absoluteString == "https://example.com/page")
            // file: のリンクはアプリが開かない。リンクの無い場所も何も開かない。
            _ = try await web.evaluateJavaScript("clickAt(850, 350); clickAt(500, 100)")
            try await Task.sleep(for: .milliseconds(300))
            #expect(opened.urls.count == 1)
            opened.urls.removeAll()
            // ピンチで拡大し、広げるとペイン全体になり、たたむと広げる前の倍率へ戻る。
            _ = try await web.evaluateJavaScript("""
                { const r = figure().getBoundingClientRect();
                  figure().dispatchEvent(new WheelEvent('wheel', { bubbles:true, cancelable:true, ctrlKey:true, deltaY:-50, clientX:r.left + 50, clientY:r.top + 50 })); }
                window.zoomed = scaleOf(); figure().querySelector('[data-label="広げる"]').click(); void 0;
                """)
            try await check("zoomed > Math.min(1, document.querySelector('main').clientWidth / 1000) + 0.05")
            try await check("""
                (() => { const r = figure().getBoundingClientRect();
                  return figure().classList.contains('diagram-expanded') && document.body.classList.contains('diagram-expanded-mode')
                    && Math.abs(r.width - innerWidth) < 1 && Math.abs(r.height - innerHeight) < 1
                    && !!figure().querySelector('[data-label="たたむ"]')
                    && Math.abs(scaleOf() - Math.min(innerWidth / 1000, innerHeight / 400)) < 0.01; })()
                """)
            // 広げた図の中の、本文の見出しへのリンクは、たたんでから移動する。
            _ = try await web.evaluateJavaScript("clickAt(150, 350)")
            try await wait { try await web.evaluateJavaScript("!figure().classList.contains('diagram-expanded')") as? Bool == true }
            try await check("!document.body.classList.contains('diagram-expanded-mode') && Math.abs(scaleOf() - zoomed) < 0.001 && figure().classList.contains('diagram-selected')")
            // Escは1回につき1つ戻る。広げた図はまずたたみ、次に選択を外す。
            _ = try await web.evaluateJavaScript("figure().querySelector('[data-label=広げる]').click(); escape()")
            try await check("!figure().classList.contains('diagram-expanded') && figure().classList.contains('diagram-selected')")
            _ = try await web.evaluateJavaScript("escape()")
            try await check("!figure().classList.contains('diagram-selected')")
            // 描き直しても、倍率と位置を引き継ぐ。
            try Data(fixture.replacingOccurrences(of: "本文その1", with: "本文その\(scale + 1)").utf8).write(to: file, options: .atomic)
            try await wait { preview.document.renderedText.contains("本文その\(scale + 1)") }
            try await ready(web, count: 1)
            try await check("Math.abs(scaleOf() - zoomed) < 0.001")
            // 「全体」でペイン幅へ収め直す。
            _ = try await web.evaluateJavaScript("clickAt(500, 100); figure().querySelector('[data-label=全体]').click(); escape()")
            try Data(fixture.utf8).write(to: file, options: .atomic)
            try await wait { preview.document.renderedText.contains("本文その1") }
            try await ready(web, count: 1)
        }
    }
}
}
